//! What a dictionary is keyed by (ADR-0002): an **edition** is the SHA-256 of the whole `.mdx`; a resource
//! volume is recognised by a local **validation token**; a **location** is where a package was found, with
//! the file identity that tells whether it has changed since; a **lineage** is the dictionary the reader sees,
//! minted once per new edition. A path is never an identity.
//!
//! The [`Registry`] holds them. It is study data (ADR-0002 decision 4): the study ledger will implement the
//! trait; [`FileRegistry`] keeps it in one JSON document until then.

use std::collections::BTreeMap;
use std::io;
use std::path::PathBuf;
use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use xdict_mdx::Source;

/// The scheme an edition is written with (ADR-0002 decision 1).
pub const EDITION_SCHEME: &str = "mdx-sha256-v1:";
/// How much of a file one read takes while it is hashed, and the unit its chunk sums cover.
pub const CHUNK: u64 = 4 << 20;

/// A file's identity, as the platform reports it (ADR-0002 decision 2). Times in nanoseconds.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileIdentity {
    pub device: u64,
    pub inode: u64,
    pub size: u64,
    pub mtime_ns: i64,
    pub ctime_ns: i64,
}

/// A file hashed whole: its SHA-256, and the xxh3 of each [`CHUNK`], so that what is read from it later can
/// be checked to be the same bytes.
pub struct Hashed {
    pub digest: [u8; 32],
    pub sums: Vec<u64>,
}

impl Hashed {
    /// The edition: `mdx-sha256-v1:` and the digest in hex.
    pub fn edition(&self) -> String {
        format!("{EDITION_SCHEME}{}", hex(&self.digest))
    }
}

/// Hashes a whole file in one sequential pass, telling `progress` how many bytes each chunk was; an error
/// from it stops the pass.
pub fn hash<E: From<io::Error>>(
    source: &dyn Source,
    mut progress: impl FnMut(u64) -> Result<(), E>,
) -> Result<Hashed, E> {
    let mut sha = Sha256::new();
    let mut sums = Vec::new();
    each_chunk(source, |chunk| {
        sha.update(chunk);
        sums.push(xxhash_rust::xxh3::xxh3_64(chunk));
        progress(chunk.len() as u64)
    })?;
    Ok(Hashed { digest: sha.finalize().into(), sums })
}

/// A resource volume's validation token (ADR-0002 decision 5, as amended): from its identity where the
/// platform has one, from its whole content where it has none. Local only: never an identity, never synced.
pub fn volume_token<E: From<io::Error>>(
    identity: Option<FileIdentity>,
    source: &dyn Source,
    progress: impl FnMut(u64) -> Result<(), E>,
) -> Result<[u8; 32], E> {
    let mut token = [0u8; 32];
    match identity {
        Some(id) => {
            let mut h = Sha256::new();
            h.update(b"xdict-volume-identity-v1");
            for n in [id.device, id.inode, id.size] {
                h.update(n.to_le_bytes());
            }
            for n in [id.mtime_ns, id.ctime_ns] {
                h.update(n.to_le_bytes());
            }
            token = h.finalize().into();
        }
        None => {
            let mut progress = progress;
            let mut h = xxhash_rust::xxh3::Xxh3::new();
            each_chunk(source, |chunk| {
                h.update(chunk);
                progress(chunk.len() as u64)
            })?;
            token[0] = 1;
            token[8..16].copy_from_slice(&source.len().to_le_bytes());
            token[16..].copy_from_slice(&h.digest128().to_le_bytes());
        }
    }
    Ok(token)
}

fn each_chunk<E: From<io::Error>>(source: &dyn Source, mut each: impl FnMut(&[u8]) -> Result<(), E>) -> Result<(), E> {
    let total = source.len();
    let first = usize::try_from(CHUNK.min(total)).map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
    let mut buf = vec![0u8; first];
    let mut at = 0u64;
    while at < total {
        let n = usize::try_from((total - at).min(CHUNK)).map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
        let part = buf.get_mut(..n).ok_or_else(|| io::Error::from(io::ErrorKind::InvalidInput))?;
        source.read_exact_at(at, part)?;
        at += n as u64;
        each(part)?;
    }
    Ok(())
}

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// One resource volume of a registered package.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VolumeRecord {
    pub location: String,
    /// The validation token in hex; `None` when the volume could not be read at import.
    pub token: Option<String>,
}

/// Where a package was imported from, and what it was then.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LocationRecord {
    /// The MDX's location: a path, or the name of a shell's source.
    pub location: String,
    pub edition: String,
    /// The MDX's identity at import; `None` where the platform has none.
    pub identity: Option<FileIdentity>,
    /// The volumes, in search order.
    pub volumes: Vec<VolumeRecord>,
    pub sidecars: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RegistryError(pub String);

impl std::fmt::Display for RegistryError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for RegistryError {}

/// Lineages, editions and locations (ADR-0002 decisions 3 and 4). Writes are atomic: two imports of one
/// edition at once register one lineage.
pub trait Registry: Send + Sync {
    /// Records a location and its edition, returning the edition's lineage: the one it has, or, for an edition
    /// seen for the first time, the one `mint` makes.
    fn register(&self, record: LocationRecord, mint: &mut dyn FnMut() -> String) -> Result<String, RegistryError>;
    fn location(&self, location: &str) -> Result<Option<LocationRecord>, RegistryError>;
    fn lineage(&self, edition: &str) -> Result<Option<String>, RegistryError>;
}

#[derive(Default, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Contents {
    /// The document's own version.
    version: u32,
    /// Edition → lineage.
    lineages: BTreeMap<String, String>,
    /// Location → what was found there.
    locations: BTreeMap<String, LocationRecord>,
}

impl Contents {
    fn register(&mut self, record: LocationRecord, mint: &mut dyn FnMut() -> String) -> String {
        let lineage = self.lineages.entry(record.edition.clone()).or_insert_with(mint).clone();
        self.locations.insert(record.location.clone(), record);
        lineage
    }
}

/// A registry in memory: for tests, and for a session with nowhere to keep one.
#[derive(Default)]
pub struct MemoryRegistry(Mutex<Contents>);

impl Registry for MemoryRegistry {
    fn register(&self, record: LocationRecord, mint: &mut dyn FnMut() -> String) -> Result<String, RegistryError> {
        Ok(self.0.lock().map_err(poisoned)?.register(record, mint))
    }
    fn location(&self, location: &str) -> Result<Option<LocationRecord>, RegistryError> {
        Ok(self.0.lock().map_err(poisoned)?.locations.get(location).cloned())
    }
    fn lineage(&self, edition: &str) -> Result<Option<String>, RegistryError> {
        Ok(self.0.lock().map_err(poisoned)?.lineages.get(edition).cloned())
    }
}

fn poisoned<T>(_: T) -> RegistryError {
    RegistryError("the registry was left inconsistent by an earlier fault".into())
}

const VERSION: u32 = 1;

/// A registry in one JSON document, `registry.json` in a directory of the reader's data: written whole to a
/// temporary file and renamed, so a crash leaves the old document or the new one. A document that cannot be
/// read is an error, never an empty registry: it holds the reader's lineages.
pub struct FileRegistry {
    path: PathBuf,
    contents: Mutex<Contents>,
}

impl FileRegistry {
    pub fn open(dir: impl Into<PathBuf>) -> Result<Self, RegistryError> {
        let dir = dir.into();
        let path = dir.join("registry.json");
        let contents = match std::fs::read(&path) {
            Ok(bytes) => {
                let contents: Contents = serde_json::from_slice(&bytes)
                    .map_err(|e| RegistryError(format!("{} cannot be read: {e}", path.display())))?;
                if contents.version != VERSION {
                    return Err(RegistryError(format!(
                        "{} is version {}, not {VERSION}",
                        path.display(),
                        contents.version
                    )));
                }
                contents
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => Contents { version: VERSION, ..Contents::default() },
            Err(e) => return Err(RegistryError(format!("{} cannot be read: {e}", path.display()))),
        };
        Ok(Self { path, contents: Mutex::new(contents) })
    }

    fn write(&self, contents: &Contents) -> Result<(), RegistryError> {
        use std::io::Write;
        let fail = |e: io::Error| RegistryError(format!("{} cannot be written: {e}", self.path.display()));
        let dir = self.path.parent().ok_or_else(|| RegistryError("the registry has no directory".into()))?;
        std::fs::create_dir_all(dir).map_err(fail)?;
        let temporary = self.path.with_extension(format!("json.{}.tmp", std::process::id()));
        let bytes = serde_json::to_vec_pretty(contents).map_err(|e| RegistryError(e.to_string()))?;
        let written = (|| {
            let mut file = std::fs::File::create(&temporary)?;
            file.write_all(&bytes)?;
            file.sync_all()?;
            std::fs::rename(&temporary, &self.path)
        })();
        if written.is_err() {
            let _ = std::fs::remove_file(&temporary);
        }
        written.map_err(fail)
    }
}

impl Registry for FileRegistry {
    fn register(&self, record: LocationRecord, mint: &mut dyn FnMut() -> String) -> Result<String, RegistryError> {
        let mut contents = self.contents.lock().map_err(poisoned)?;
        let mut next = contents.clone();
        let lineage = next.register(record, mint);
        self.write(&next)?;
        *contents = next;
        Ok(lineage)
    }
    fn location(&self, location: &str) -> Result<Option<LocationRecord>, RegistryError> {
        Ok(self.contents.lock().map_err(poisoned)?.locations.get(location).cloned())
    }
    fn lineage(&self, edition: &str) -> Result<Option<String>, RegistryError> {
        Ok(self.contents.lock().map_err(poisoned)?.lineages.get(edition).cloned())
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::indexing_slicing)]
mod tests {
    use super::*;

    fn record(location: &str, edition: &str) -> LocationRecord {
        LocationRecord {
            location: location.into(),
            edition: edition.into(),
            identity: None,
            volumes: vec![],
            sidecars: vec![],
        }
    }

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("xdict-identity-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    /// Two locations of one edition share a lineage; a lineage is minted once per new edition.
    #[test]
    fn one_edition_one_lineage() {
        let registry = MemoryRegistry::default();
        let mut minted = 0;
        let mut mint = || {
            minted += 1;
            format!("lineage-{minted}")
        };
        assert_eq!(registry.register(record("/a/x.mdx", "e1"), &mut mint).unwrap(), "lineage-1");
        assert_eq!(registry.register(record("/b/x.mdx", "e1"), &mut mint).unwrap(), "lineage-1");
        assert_eq!(registry.register(record("/c/y.mdx", "e2"), &mut mint).unwrap(), "lineage-2");
    }

    /// The registry outlives the process, and survives a lost cache: it is the reader's data.
    #[test]
    fn a_file_registry_persists() {
        let dir = scratch("persists");
        let first = FileRegistry::open(&dir).unwrap();
        first.register(record("/a/x.mdx", "e1"), &mut || "kept".into()).unwrap();
        drop(first);
        let again = FileRegistry::open(&dir).unwrap();
        assert_eq!(again.lineage("e1").unwrap().as_deref(), Some("kept"));
        assert_eq!(again.location("/a/x.mdx").unwrap().unwrap().edition, "e1");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// A damaged document is an error, never an empty registry that would mint lineages again.
    #[test]
    fn a_damaged_registry_is_refused_not_reset() {
        let dir = scratch("damaged");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("registry.json"), b"{ not json").unwrap();
        assert!(FileRegistry::open(&dir).is_err());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// Imports of one edition from several threads at once register one lineage.
    #[test]
    fn concurrent_imports_of_one_edition_register_one_lineage() {
        let dir = scratch("concurrent");
        let registry = std::sync::Arc::new(FileRegistry::open(&dir).unwrap());
        let lineages: Vec<String> = (0..8)
            .map(|n| {
                let registry = registry.clone();
                std::thread::spawn(move || {
                    registry.register(record(&format!("/{n}/x.mdx"), "same"), &mut || format!("minted-by-{n}")).unwrap()
                })
            })
            .collect::<Vec<_>>()
            .into_iter()
            .map(|t| t.join().unwrap())
            .collect();
        assert!(lineages.iter().all(|l| *l == lineages[0]), "{lineages:?}");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn hashing_matches_sha256_and_sums_each_chunk() {
        let bytes: Vec<u8> = (0..(CHUNK as usize + 10)).map(|i| (i % 251) as u8).collect();
        let hashed = hash::<io::Error>(&bytes, |_| Ok(())).unwrap();
        assert_eq!(hashed.digest, <[u8; 32]>::from(Sha256::digest(&bytes)));
        assert_eq!(hashed.sums.len(), 2);
        assert!(hashed.edition().starts_with(EDITION_SCHEME));
    }

    /// A volume without an identity is recognised by its content; with one, by the identity alone.
    #[test]
    fn volume_tokens_follow_identity_or_content() {
        let (a, b) = (vec![1u8; 100], vec![2u8; 100]);
        let none = |s: &Vec<u8>| volume_token::<io::Error>(None, s, |_| Ok(())).unwrap();
        assert_ne!(none(&a), none(&b));
        assert_eq!(none(&a), none(&a.clone()));
        let id = FileIdentity { device: 1, inode: 2, size: 100, mtime_ns: 3, ctime_ns: 4 };
        let by_id = |s: &Vec<u8>, id| volume_token::<io::Error>(Some(id), s, |_| Ok(())).unwrap();
        assert_eq!(by_id(&a, id), by_id(&b, id));
        assert_ne!(by_id(&a, id), by_id(&a, FileIdentity { ctime_ns: 5, ..id }));
    }
}
