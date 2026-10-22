//! What a dictionary is keyed by (ADR-0002): an **edition** is the SHA-256 of the whole `.mdx`; a resource
//! volume is recognised by a local **validation token**; a **location** is where a package was found, with
//! the file identity that tells whether it has changed since; a **lineage** is the dictionary the reader sees,
//! minted once per new edition, and joined or split only by the reader, each act recorded and none rewritten. A path
//! is never an identity.
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
            let (len, sum) = (source.len().to_le_bytes(), h.digest128().to_le_bytes());
            let tagged = [1u8, 0, 0, 0, 0, 0, 0, 0];
            for (slot, byte) in token.iter_mut().zip(tagged.iter().chain(&len).chain(&sum)) {
                *slot = *byte;
            }
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
    /// Kept because version 2's document shape carries it; a build that dropped it would fail to load on one that
    /// still expects it. The reader resolves sidecars by name, so nothing reads it today.
    #[serde(default)]
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
    /// The lineage the edition has now: the last one the reader associated it with, else the one minted for it.
    fn lineage(&self, edition: &str) -> Result<Option<String>, RegistryError>;
    /// Associates an edition with a lineage, as the reader asked (ADR-0002 decision 3): recorded as an act of the
    /// reader's, never a rewrite of the lineage the edition was minted with, so every association can be undone by
    /// another. Answers the lineage the edition now has. Idempotent: an edition already in `lineage` records nothing.
    fn associate(&self, edition: &str, lineage: &str, target: Target)
    -> Result<Result<String, Refused>, RegistryError>;
}

/// Which lineages an association may name.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Target {
    /// Only one the registry holds: a join, so that a stale or mistaken id never makes a dictionary of its own.
    Existing,
    /// A new one, or one this edition had before: a split, to a lineage the shell has just minted, or back to where a
    /// join took the edition from. Never another dictionary's, which would be a join no one asked for.
    NewOrOwn,
}

/// Why an association was refused. Nothing is recorded.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refused {
    /// No location of this edition was ever registered.
    Edition,
    /// No edition was ever minted in, joined to or split to this lineage.
    Lineage,
    /// A split named a lineage of other editions that this one never had.
    Foreign,
}

/// One act of the reader's: an edition associated with a lineage.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Association {
    edition: String,
    lineage: String,
}

#[derive(Default, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Contents {
    /// The document's own version.
    version: u32,
    /// Edition → the lineage minted for it when it was first seen. Never rewritten.
    lineages: BTreeMap<String, String>,
    /// The reader's joins and splits, in the order made, never rewritten either: an edition's lineage is the one its
    /// last association names, else the one minted for it. Absent from a version 1 document.
    #[serde(default)]
    associations: Vec<Association>,
    /// Location → what was found there.
    locations: BTreeMap<String, LocationRecord>,
}

impl Contents {
    fn register(&mut self, record: LocationRecord, mint: &mut dyn FnMut() -> String) -> String {
        let minted = self.lineages.entry(record.edition.clone()).or_insert_with(mint).clone();
        let lineage = self.associated(&record.edition).cloned().unwrap_or(minted);
        self.locations.insert(record.location.clone(), record);
        lineage
    }

    /// The lineage the reader last associated the edition with, if any.
    fn associated(&self, edition: &str) -> Option<&String> {
        self.associations.iter().rev().find(|a| a.edition == edition).map(|a| &a.lineage)
    }

    fn lineage(&self, edition: &str) -> Option<&String> {
        self.associated(edition).or_else(|| self.lineages.get(edition))
    }

    /// Whether any edition was ever minted in, joined to or split to `lineage`: a lineage left with no edition is
    /// still one, so that an edition can return to it.
    fn holds_lineage(&self, lineage: &str) -> bool {
        self.lineages.values().any(|l| l == lineage) || self.associations.iter().any(|a| a.lineage == lineage)
    }

    /// Whether the edition was ever in `lineage`: minted in it, or associated with it.
    fn has_had(&self, edition: &str, lineage: &str) -> bool {
        self.lineages.get(edition).is_some_and(|l| l == lineage)
            || self.associations.iter().any(|a| a.edition == edition && a.lineage == lineage)
    }

    /// Records the act, unless the edition already has `lineage`.
    fn associate(&mut self, edition: &str, lineage: &str, target: Target) -> Result<(), Refused> {
        let current = self.lineage(edition).ok_or(Refused::Edition)?;
        if current == lineage {
            return Ok(());
        }
        match target {
            Target::Existing if !self.holds_lineage(lineage) => return Err(Refused::Lineage),
            Target::NewOrOwn if self.holds_lineage(lineage) && !self.has_had(edition, lineage) => {
                return Err(Refused::Foreign);
            }
            Target::Existing | Target::NewOrOwn => {}
        }
        self.associations.push(Association { edition: edition.to_owned(), lineage: lineage.to_owned() });
        Ok(())
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
        Ok(self.0.lock().map_err(poisoned)?.lineage(edition).cloned())
    }
    fn associate(
        &self,
        edition: &str,
        lineage: &str,
        target: Target,
    ) -> Result<Result<String, Refused>, RegistryError> {
        let mut contents = self.0.lock().map_err(poisoned)?;
        Ok(contents.associate(edition, lineage, target).map(|()| lineage.to_owned()))
    }
}

fn poisoned<T>(_: T) -> RegistryError {
    RegistryError("the registry was left inconsistent by an earlier fault".into())
}

/// The document's version: 2 added the reader's associations. A build reads every version up to its own and writes
/// its own, so a build that knows no associations refuses a document holding them rather than writing it back
/// without them.
const VERSION: u32 = 2;

/// What tells whether the document on disk is the one read last: a write renames a new file into place, so the
/// file's identity changes with every write, this registry's or another's.
#[derive(Clone, Copy, PartialEq, Eq)]
struct Stamp {
    len: u64,
    modified: Option<std::time::SystemTime>,
    /// The file's identity, where stable Rust gives one: the inode on Unix. Windows' file index is not in stable
    /// `std`, and its length and time alone can stay the same across a write, so there it is `None`.
    file: Option<u64>,
}

impl Stamp {
    fn of(meta: &std::fs::Metadata) -> Self {
        #[cfg(unix)]
        let file = Some(std::os::unix::fs::MetadataExt::ino(meta));
        #[cfg(not(unix))]
        let file = None;
        Self { len: meta.len(), modified: meta.modified().ok(), file }
    }

    /// Whether the document at `now` is surely the one stamped `then`: never when the file has no identity.
    fn unchanged(now: Option<Self>, then: Option<Self>) -> bool {
        match (now, then) {
            (None, None) => true,
            (Some(now), Some(then)) => now.file.is_some() && now == then,
            _ => false,
        }
    }
}

/// The document as last read, and the stamp of the file it was read from (`None`: there was none).
struct Cached {
    contents: Contents,
    stamp: Option<Stamp>,
}

/// A registry in one JSON document, `registry.json` in a directory of the reader's data: written whole to a
/// temporary file and renamed, so a crash leaves the old document or the new one. A document that cannot be
/// read is an error, never an empty registry: it holds the reader's lineages.
///
/// Several registries may share the directory (two cores, two processes): a write holds an exclusive lock on
/// `registry.lock` and reads the document again under it, so no write is built on a stale copy; a read reloads
/// the document whenever the file on disk is not the one it read last.
pub struct FileRegistry {
    path: PathBuf,
    cached: Mutex<Cached>,
    /// Makes a renamed document durable: [`confirm`], except where a test makes it fail.
    confirm: fn(std::fs::File, &std::path::Path) -> io::Result<()>,
}

impl FileRegistry {
    pub fn open(dir: impl Into<PathBuf>) -> Result<Self, RegistryError> {
        let path = dir.into().join("registry.json");
        let cached = load(&path)?;
        Ok(Self { path, cached: Mutex::new(cached), confirm })
    }

    /// The document, read again if the file changed since it was last read, or always where a file has no
    /// identity to tell (Windows): the registry is read only at import and open, so this costs little.
    fn current(&self) -> Result<std::sync::MutexGuard<'_, Cached>, RegistryError> {
        let mut cached = self.cached.lock().map_err(poisoned)?;
        let now = match std::fs::metadata(&self.path) {
            Ok(meta) => Some(Stamp::of(&meta)),
            Err(e) if e.kind() == io::ErrorKind::NotFound => None,
            Err(e) => return Err(RegistryError(format!("{} cannot be read: {e}", self.path.display()))),
        };
        if !Stamp::unchanged(now, cached.stamp) {
            *cached = load(&self.path)?;
        }
        Ok(cached)
    }

    /// Writes the document whole, under the caller's lock, and makes the rename durable.
    fn write(&self, dir: &std::path::Path, contents: &Contents) -> Result<(), RegistryError> {
        use std::io::Write;
        let fail = |e: io::Error| RegistryError(format!("{} cannot be written: {e}", self.path.display()));
        let bytes = serde_json::to_vec_pretty(contents).map_err(|e| RegistryError(e.to_string()))?;
        let (temporary, mut file) = create_temporary(&self.path).map_err(fail)?;
        // Only a file this write created is removed on failure.
        let written = (|| {
            file.write_all(&bytes)?;
            file.sync_all()?;
            std::fs::rename(&temporary, &self.path)?;
            Ok::<_, io::Error>(file)
        })();
        let file = match written {
            Ok(file) => file,
            Err(e) => {
                let _ = std::fs::remove_file(&temporary);
                return Err(fail(e));
            }
        };
        // From here the new document is in place, so a failure says that, not that nothing changed.
        (self.confirm)(file, dir).map_err(|e| {
            RegistryError(format!(
                "the new registry document was installed at {}, but its durability could not be confirmed: {e}",
                self.path.display()
            ))
        })
    }
}

/// Makes a renamed document durable, given the handle that wrote it and its directory: without this, a power
/// failure can bring back the old document after the registration was reported.
///
/// Unix flushes the directory, which holds the name. Windows flushes the renamed file through the handle that
/// wrote it, which writes its metadata (`FlushFileBuffers`), as PostgreSQL's `durable_rename` does; keeping the
/// handle means no new open that a reader holding the file could refuse. `std::fs::rename` is `MoveFileExW`
/// without `MOVEFILE_WRITE_THROUGH` (Rust 1.99, `library/std/src/sys/fs/windows.rs`), and no documented
/// directory-flush durability contract is relied upon; write-through renaming needs `unsafe`, which this crate
/// does not allow. The Web keeps no registry on disk.
fn confirm(file: std::fs::File, dir: &std::path::Path) -> io::Result<()> {
    #[cfg(unix)]
    {
        drop(file);
        std::fs::File::open(dir)?.sync_all()
    }
    #[cfg(windows)]
    {
        let _ = dir;
        file.sync_all()
    }
    #[cfg(not(any(unix, windows)))]
    {
        let _ = (file, dir);
        Ok(())
    }
}

/// The number of the next temporary file: unique within the process as well, so two registries of one process
/// never share one.
static NEXT_TEMPORARY: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// Temporary file `n` of this process beside the document at `path`.
fn temporary_path(path: &std::path::Path, n: u64) -> PathBuf {
    path.with_extension(format!("json.{}.{n}.tmp", std::process::id()))
}

/// How many taken temporary names a write passes over before it gives up.
const TEMPORARY_ATTEMPTS: u32 = 64;

/// Creates a new temporary file beside the document at `path`, passing over a name that is taken (left by a
/// crashed process of the same number, say) rather than removing what it did not create.
fn create_temporary(path: &std::path::Path) -> io::Result<(PathBuf, std::fs::File)> {
    for _ in 0..TEMPORARY_ATTEMPTS {
        let temporary = temporary_path(path, NEXT_TEMPORARY.fetch_add(1, std::sync::atomic::Ordering::Relaxed));
        match std::fs::OpenOptions::new().write(true).create_new(true).open(&temporary) {
            Ok(file) => return Ok((temporary, file)),
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(e),
        }
    }
    Err(io::Error::new(io::ErrorKind::AlreadyExists, format!("{TEMPORARY_ATTEMPTS} temporary names were all taken")))
}

/// Reads the document, and the stamp of the very file read; an absent document is an empty registry.
fn load(path: &std::path::Path) -> Result<Cached, RegistryError> {
    use std::io::Read;
    let unreadable = |e: &dyn std::fmt::Display| RegistryError(format!("{} cannot be read: {e}", path.display()));
    let mut file = match std::fs::File::open(path) {
        Ok(file) => file,
        Err(e) if e.kind() == io::ErrorKind::NotFound => {
            return Ok(Cached { contents: Contents { version: VERSION, ..Contents::default() }, stamp: None });
        }
        Err(e) => return Err(unreadable(&e)),
    };
    let stamp = Stamp::of(&file.metadata().map_err(|e| unreadable(&e))?);
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes).map_err(|e| unreadable(&e))?;
    let document: serde_json::Value = serde_json::from_slice(&bytes).map_err(|e| unreadable(&e))?;
    let version = document.get("version").and_then(serde_json::Value::as_u64).unwrap_or(0);
    if !(1..=u64::from(VERSION)).contains(&version) {
        return Err(RegistryError(format!("{} is version {version}; this build reads 1 to {VERSION}", path.display())));
    }
    // Version 1 had no associations, so it may lack the field; a later version that lacks it lost it, and read as a
    // document with no joins it would return every joined edition to its own lineage.
    if version >= 2 && document.get("associations").is_none() {
        return Err(unreadable(&"it holds no associations, which its version has"));
    }
    let mut contents: Contents = serde_json::from_value(document).map_err(|e| unreadable(&e))?;
    // An earlier version is this one with nothing it added: written back, it is written as this one.
    contents.version = VERSION;
    Ok(Cached { contents, stamp: Some(stamp) })
}

impl FileRegistry {
    /// Changes the document as it is on disk now, under the directory's lock, and writes it back when `change` answers
    /// that it should be.
    fn update<T>(&self, change: impl FnOnce(&mut Contents) -> (T, bool)) -> Result<T, RegistryError> {
        let mut cached = self.cached.lock().map_err(poisoned)?;
        let dir = self.path.parent().ok_or_else(|| RegistryError("the registry has no directory".into()))?;
        let fail = |e: io::Error| RegistryError(format!("{} cannot be locked: {e}", dir.display()));
        std::fs::create_dir_all(dir).map_err(fail)?;
        // Another registry's write, in this process or another, waits here; the lock belongs to the open file
        // and is released when `lock` is dropped at the end of the call.
        let lock = std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(dir.join("registry.lock"))
            .map_err(fail)?;
        lock.lock().map_err(fail)?;
        let mut next = load(&self.path)?;
        let (answer, changed) = change(&mut next.contents);
        if changed {
            self.write(dir, &next.contents)?;
            next.stamp = std::fs::metadata(&self.path).ok().map(|m| Stamp::of(&m));
        }
        *cached = next;
        Ok(answer)
    }
}

impl Registry for FileRegistry {
    fn register(&self, record: LocationRecord, mint: &mut dyn FnMut() -> String) -> Result<String, RegistryError> {
        self.update(|contents| (contents.register(record, mint), true))
    }
    fn location(&self, location: &str) -> Result<Option<LocationRecord>, RegistryError> {
        Ok(self.current()?.contents.locations.get(location).cloned())
    }
    fn lineage(&self, edition: &str) -> Result<Option<String>, RegistryError> {
        Ok(self.current()?.contents.lineage(edition).cloned())
    }
    fn associate(
        &self,
        edition: &str,
        lineage: &str,
        target: Target,
    ) -> Result<Result<String, Refused>, RegistryError> {
        // Written even when nothing new is recorded: a retry after a write whose durability was not confirmed is
        // what confirms it, so an answer is never given for a document that a power failure could still take back.
        self.update(|contents| match contents.associate(edition, lineage, target) {
            Ok(()) => (Ok(lineage.to_owned()), true),
            Err(refused) => (Err(refused), false),
        })
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

    /// A reader holding the document without sharing it for writing (an antivirus scan, a backup) does not stop
    /// the next registration: the new document replaces the held one, and is flushed through its own handle.
    #[cfg(windows)]
    #[test]
    fn a_reader_holding_the_document_does_not_fail_a_registration() {
        use std::os::windows::fs::OpenOptionsExt;
        let dir = scratch("held");
        let registry = FileRegistry::open(&dir).unwrap();
        registry.register(record("/a/x.mdx", "e1"), &mut || "first".into()).unwrap();
        let _held =
            std::fs::OpenOptions::new().read(true).share_mode(0x1 | 0x4).open(dir.join("registry.json")).unwrap();
        registry.register(record("/a/y.mdx", "e2"), &mut || "second".into()).unwrap();
        assert_eq!(registry.lineage("e2").unwrap().as_deref(), Some("second"));
        drop(_held);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// A flush that fails after the rename is reported, and says the new document is in place; a retry then
    /// finds the lineage it holds rather than minting another.
    #[test]
    fn a_flush_that_fails_after_the_rename_is_reported_and_the_document_kept() {
        let dir = scratch("unconfirmed");
        let mut registry = FileRegistry::open(&dir).unwrap();
        registry.confirm = |_, _| Err(io::Error::other("injected"));
        let failed = registry.register(record("/a/x.mdx", "e1"), &mut || "kept".into()).err().unwrap();
        assert!(failed.0.contains("was installed") && failed.0.contains("injected"), "{}", failed.0);
        let again = FileRegistry::open(&dir).unwrap();
        assert_eq!(again.lineage("e1").unwrap().as_deref(), Some("kept"));
        let retried = again.register(record("/a/x.mdx", "e1"), &mut || "minted again".into()).unwrap();
        assert_eq!(retried, "kept");
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

    /// Two registries opened on one directory (a second core, another process) see each other's writes: neither
    /// erases what the other registered, and an edition the other registered keeps its lineage.
    #[test]
    fn two_registries_on_one_directory_keep_each_others_registrations() {
        let dir = scratch("two");
        let (a, b) = (FileRegistry::open(&dir).unwrap(), FileRegistry::open(&dir).unwrap());
        assert_eq!(a.register(record("/a/x.mdx", "e1"), &mut || "by-a".into()).unwrap(), "by-a");
        assert_eq!(b.register(record("/b/y.mdx", "e2"), &mut || "by-b".into()).unwrap(), "by-b");
        assert_eq!(b.register(record("/b/x.mdx", "e1"), &mut || "minted-again".into()).unwrap(), "by-a");
        assert_eq!(a.location("/b/y.mdx").unwrap().map(|r| r.edition).as_deref(), Some("e2"));
        let again = FileRegistry::open(&dir).unwrap();
        for location in ["/a/x.mdx", "/b/y.mdx", "/b/x.mdx"] {
            assert!(again.location(location).unwrap().is_some(), "{location} was lost");
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// Several registries on one directory, each written from several threads at once: every registration is
    /// kept, and the edition has one lineage.
    #[test]
    fn concurrent_writers_through_several_registries_lose_nothing() {
        let dir = scratch("writers");
        let registries: Vec<_> = (0..3).map(|_| std::sync::Arc::new(FileRegistry::open(&dir).unwrap())).collect();
        let threads: Vec<_> = (0..24)
            .map(|n| {
                let registry = registries[n % 3].clone();
                std::thread::spawn(move || {
                    registry.register(record(&format!("/{n}/x.mdx"), "same"), &mut || format!("minted-by-{n}")).unwrap()
                })
            })
            .collect();
        let lineages: Vec<String> = threads.into_iter().map(|t| t.join().unwrap()).collect();
        assert!(lineages.iter().all(|l| *l == lineages[0]), "{lineages:?}");
        let again = FileRegistry::open(&dir).unwrap();
        let kept = (0..24).filter(|n| again.location(&format!("/{n}/x.mdx")).unwrap().is_some()).count();
        assert_eq!(kept, 24);
        let leftovers: Vec<_> = std::fs::read_dir(&dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .filter(|n| n.ends_with(".tmp"))
            .collect();
        assert!(leftovers.is_empty(), "{leftovers:?}");
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

    /// A content token's layout: 1, seven zero bytes, the length, then the xxh3-128 of the content.
    #[test]
    fn a_content_token_is_tagged_sized_and_summed() {
        let content = vec![7u8; 300];
        let token = volume_token::<io::Error>(None, &content, |_| Ok(())).unwrap();
        let mut expected = vec![1u8, 0, 0, 0, 0, 0, 0, 0];
        expected.extend_from_slice(&300u64.to_le_bytes());
        expected.extend_from_slice(&xxhash_rust::xxh3::xxh3_128(&content).to_le_bytes());
        assert_eq!(token.to_vec(), expected);
    }

    /// Another registry's write that leaves the document's length and modification time as they were is still
    /// seen: a stamp with no file identity (Windows) is never taken as proof that nothing changed.
    #[test]
    fn a_write_that_keeps_length_and_time_is_still_read() {
        let dir = scratch("same-stamp");
        let writer = FileRegistry::open(&dir).unwrap();
        writer.register(record("/a/x.mdx", "e1"), &mut || "kept".into()).unwrap();
        let reader = FileRegistry::open(&dir).unwrap();
        assert_eq!(reader.lineage("e1").unwrap().as_deref(), Some("kept"));
        // Another write of the same length, renamed into place as a registry writes, its time set back.
        let path = dir.join("registry.json");
        let before = std::fs::metadata(&path).unwrap().modified().unwrap();
        let text = std::fs::read_to_string(&path).unwrap().replace("\"kept\"", "\"lost\"");
        let temporary = dir.join("other.tmp");
        std::fs::write(&temporary, text).unwrap();
        std::fs::File::options().write(true).open(&temporary).unwrap().set_modified(before).unwrap();
        std::fs::rename(&temporary, &path).unwrap();
        assert_eq!(std::fs::metadata(&path).unwrap().modified().unwrap(), before);
        assert_eq!(reader.lineage("e1").unwrap().as_deref(), Some("lost"));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// Two editions, each with the lineage minted for it: `e1` in `L1`, `e2` in `L2`.
    fn two_editions(registry: &dyn Registry) {
        registry.register(record("/a/x.mdx", "e1"), &mut || "L1".into()).unwrap();
        registry.register(record("/b/y.mdx", "e2"), &mut || "L2".into()).unwrap();
    }

    /// The associations a document on disk holds, as `(edition, lineage)`.
    fn associations_on_disk(dir: &std::path::Path) -> Vec<(String, String)> {
        let text = std::fs::read_to_string(dir.join("registry.json")).unwrap();
        let document: serde_json::Value = serde_json::from_str(&text).unwrap();
        document["associations"]
            .as_array()
            .unwrap()
            .iter()
            .map(|a| (a["edition"].as_str().unwrap().to_owned(), a["lineage"].as_str().unwrap().to_owned()))
            .collect()
    }

    /// The reader joins an edition to another's lineage, and splits it back to the one it had: each act answers the
    /// lineage the edition now has, and repeating one changes nothing.
    #[test]
    fn a_join_moves_an_edition_and_a_split_returns_it() {
        let registry = MemoryRegistry::default();
        two_editions(&registry);
        assert_eq!(registry.associate("e2", "L1", Target::Existing).unwrap(), Ok("L1".to_owned()));
        assert_eq!(registry.lineage("e2").unwrap().as_deref(), Some("L1"));
        assert_eq!(registry.lineage("e1").unwrap().as_deref(), Some("L1"), "the lineage joined is not changed");
        assert_eq!(registry.associate("e2", "L1", Target::Existing).unwrap(), Ok("L1".to_owned()));
        assert_eq!(registry.associate("e2", "L2", Target::NewOrOwn).unwrap(), Ok("L2".to_owned()));
        assert_eq!(registry.lineage("e2").unwrap().as_deref(), Some("L2"));
        assert_eq!(registry.associate("e2", "L2", Target::NewOrOwn).unwrap(), Ok("L2".to_owned()));
    }

    /// An edition the registry never saw is refused; a join names only a lineage the registry holds, while a split may
    /// name a new one.
    #[test]
    fn an_association_names_a_known_edition_and_a_join_a_known_lineage() {
        let registry = MemoryRegistry::default();
        two_editions(&registry);
        assert_eq!(registry.associate("e9", "L1", Target::Existing).unwrap(), Err(Refused::Edition));
        assert_eq!(registry.associate("e9", "fresh", Target::NewOrOwn).unwrap(), Err(Refused::Edition));
        assert_eq!(registry.associate("e2", "never", Target::Existing).unwrap(), Err(Refused::Lineage));
        assert_eq!(registry.lineage("e2").unwrap().as_deref(), Some("L2"), "a refusal changes nothing");
        assert_eq!(registry.associate("e2", "fresh", Target::NewOrOwn).unwrap(), Ok("fresh".to_owned()));
    }

    /// A split goes to a new lineage or back to one the edition had; into another dictionary's it would be a join no
    /// one asked for, and is refused.
    #[test]
    fn a_split_never_moves_an_edition_into_another_dictionary() {
        let registry = MemoryRegistry::default();
        two_editions(&registry);
        assert_eq!(registry.associate("e2", "L1", Target::NewOrOwn).unwrap(), Err(Refused::Foreign));
        assert_eq!(registry.lineage("e2").unwrap().as_deref(), Some("L2"));
        assert_eq!(registry.associate("e2", "fresh", Target::NewOrOwn).unwrap(), Ok("fresh".to_owned()));
        registry.associate("e2", "L1", Target::Existing).unwrap().unwrap();
        assert_eq!(registry.associate("e2", "fresh", Target::NewOrOwn).unwrap(), Ok("fresh".to_owned()));
        assert_eq!(registry.associate("e2", "L2", Target::NewOrOwn).unwrap(), Ok("L2".to_owned()));
        assert_eq!(registry.associate("e1", "fresh", Target::NewOrOwn).unwrap(), Err(Refused::Foreign));
    }

    /// The durability a failed confirmation left unproven is proven by the retry, which therefore writes again,
    /// though it records nothing new (Codex, 2026-10-14, objection 1).
    #[test]
    fn a_retry_after_an_unconfirmed_association_confirms_it() {
        static CONFIRMED: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let dir = scratch("unconfirmed-association");
        let mut registry = FileRegistry::open(&dir).unwrap();
        two_editions(&registry);
        registry.confirm = |_, _| Err(io::Error::other("injected"));
        let failed = registry.associate("e2", "L1", Target::Existing).err().unwrap();
        assert!(failed.0.contains("was installed"), "{}", failed.0);
        registry.confirm = |file, dir| {
            CONFIRMED.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            confirm(file, dir)
        };
        assert_eq!(registry.associate("e2", "L1", Target::Existing).unwrap(), Ok("L1".to_owned()));
        assert_eq!(CONFIRMED.load(std::sync::atomic::Ordering::SeqCst), 1);
        assert_eq!(associations_on_disk(&dir), [("e2".to_owned(), "L1".to_owned())]);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// Importing a joined edition again answers the lineage it was joined to, never a new one (ADR-0002 decision 4).
    #[test]
    fn a_registration_after_a_join_answers_the_joined_lineage() {
        let registry = MemoryRegistry::default();
        two_editions(&registry);
        registry.associate("e2", "L1", Target::Existing).unwrap().unwrap();
        assert_eq!(registry.register(record("/c/y.mdx", "e2"), &mut || "minted again".into()).unwrap(), "L1");
    }

    /// A lineage left with no edition stays one: the edition can be split back to it, and another joined to it.
    #[test]
    fn a_lineage_left_empty_stays_reachable() {
        let registry = MemoryRegistry::default();
        two_editions(&registry);
        registry.associate("e2", "L1", Target::Existing).unwrap().unwrap();
        registry.register(record("/c/z.mdx", "e3"), &mut || "L3".into()).unwrap();
        assert_eq!(registry.associate("e3", "L2", Target::Existing).unwrap(), Ok("L2".to_owned()));
        registry.associate("e3", "fresh", Target::NewOrOwn).unwrap().unwrap();
        assert_eq!(registry.associate("e1", "fresh", Target::Existing).unwrap(), Ok("fresh".to_owned()));
    }

    /// Joins and splits outlive the process, each kept as one recorded act; repeating an act records nothing.
    #[test]
    fn associations_persist_and_a_repeated_act_records_nothing() {
        let dir = scratch("associations");
        let registry = FileRegistry::open(&dir).unwrap();
        two_editions(&registry);
        registry.associate("e2", "L1", Target::Existing).unwrap().unwrap();
        registry.associate("e2", "L1", Target::Existing).unwrap().unwrap();
        drop(registry);
        let again = FileRegistry::open(&dir).unwrap();
        assert_eq!(again.lineage("e2").unwrap().as_deref(), Some("L1"));
        assert_eq!(associations_on_disk(&dir), [("e2".to_owned(), "L1".to_owned())]);
        again.associate("e2", "L2", Target::NewOrOwn).unwrap().unwrap();
        drop(again);
        let last = FileRegistry::open(&dir).unwrap();
        assert_eq!(last.lineage("e2").unwrap().as_deref(), Some("L2"));
        let acts = [("e2".to_owned(), "L1".to_owned()), ("e2".to_owned(), "L2".to_owned())];
        assert_eq!(associations_on_disk(&dir), acts);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// A join through one registry is seen by another on the same directory, and the other's registration keeps it.
    #[test]
    fn two_registries_on_one_directory_keep_each_others_associations() {
        let dir = scratch("two-associations");
        let (a, b) = (FileRegistry::open(&dir).unwrap(), FileRegistry::open(&dir).unwrap());
        two_editions(&a);
        a.associate("e2", "L1", Target::Existing).unwrap().unwrap();
        assert_eq!(b.lineage("e2").unwrap().as_deref(), Some("L1"));
        b.register(record("/c/z.mdx", "e3"), &mut || "L3".into()).unwrap();
        assert_eq!(FileRegistry::open(&dir).unwrap().lineage("e2").unwrap().as_deref(), Some("L1"));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// A document written before associations existed (version 1) is read, and written back with them; one of a
    /// version this build does not know is refused, never rewritten without what it holds.
    #[test]
    fn a_version_1_document_is_read_and_a_later_one_refused() {
        let dir = scratch("version-1");
        std::fs::create_dir_all(&dir).unwrap();
        let old = r#"{"version":1,"lineages":{"e1":"L1","e2":"L2"},"locations":{}}"#;
        std::fs::write(dir.join("registry.json"), old).unwrap();
        let registry = FileRegistry::open(&dir).unwrap();
        assert_eq!(registry.lineage("e2").unwrap().as_deref(), Some("L2"));
        registry.associate("e2", "L1", Target::Existing).unwrap().unwrap();
        let text = std::fs::read_to_string(dir.join("registry.json")).unwrap();
        let document: serde_json::Value = serde_json::from_str(&text).unwrap();
        assert_ne!(document["version"], 1, "a build that knows no associations would drop them");
        assert_eq!(document["lineages"]["e2"], "L2", "the lineage minted is never rewritten");
        let later = text.replacen(&format!("\"version\": {VERSION}"), &format!("\"version\": {}", VERSION + 1), 1);
        assert_ne!(later, text);
        std::fs::write(dir.join("registry.json"), later).unwrap();
        assert!(FileRegistry::open(&dir).is_err());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// A document of a version that holds associations but holds none is damaged, not a document with no joins: read
    /// as one, every joined edition would fall back to its own lineage (Codex, 2026-10-14, objection 5).
    #[test]
    fn a_document_missing_its_associations_is_refused_and_left_as_it_was() {
        let dir = scratch("no-associations");
        std::fs::create_dir_all(&dir).unwrap();
        let damaged = format!(r#"{{"version":{VERSION},"lineages":{{"e1":"L1","e2":"L2"}},"locations":{{}}}}"#);
        std::fs::write(dir.join("registry.json"), &damaged).unwrap();
        let refused = FileRegistry::open(&dir).err().unwrap();
        assert!(refused.0.contains("associations"), "{}", refused.0);
        assert_eq!(std::fs::read_to_string(dir.join("registry.json")).unwrap(), damaged);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// A temporary file this write did not create is neither deleted nor a reason to fail: the write takes the
    /// next name.
    #[test]
    fn a_temporary_name_already_taken_is_skipped_not_deleted() {
        let dir = scratch("taken");
        let registry = FileRegistry::open(&dir).unwrap();
        registry.register(record("/a/x.mdx", "e1"), &mut || "first".into()).unwrap();
        let n = NEXT_TEMPORARY.load(std::sync::atomic::Ordering::Relaxed);
        let taken: Vec<PathBuf> = (n..n + 4).map(|n| temporary_path(&dir.join("registry.json"), n)).collect();
        for path in &taken {
            std::fs::write(path, b"not ours").unwrap();
        }
        registry.register(record("/a/y.mdx", "e2"), &mut || "second".into()).unwrap();
        assert_eq!(registry.lineage("e2").unwrap().as_deref(), Some("second"));
        for path in &taken {
            assert_eq!(std::fs::read(path).unwrap(), b"not ours");
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
