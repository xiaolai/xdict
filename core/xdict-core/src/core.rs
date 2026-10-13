//! The [`Core`]: one per process, thread-safe, every call guarded so that no panic crosses the boundary.
//!
//! **No lock is held while the shell's code runs**: a `ByteSource`, a `Progress` callback, or a read through
//! either, so a callback may call back into the core without deadlocking (Codex objection 9).

use std::collections::HashMap;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::{Arc, Mutex, MutexGuard};

use sha2::{Digest, Sha256};
use xdict_mdx::{File, Kind};

use crate::error::{CoreError, Limit, Missing};
use crate::source::{Changed, Opened as OpenedSource, Verified, read_all};
#[cfg(not(target_family = "wasm"))]
use crate::store::Directory;
use crate::store::{IndexStorage, IndexStore, Memory, Shell};
use crate::types::*;
use xdict_mdx::index::Stale;

/// The protocol between shell and core (ADR-0007 decision 11). Raised by any change a shell must be rebuilt for.
pub const PROTOCOL: u32 = 1;
/// The per-edition index's format.
pub const INDEX_FORMAT: u32 = xdict_mdx::index::FORMAT;
/// The tier-2 normalisation's version; 0 until there is one.
pub const NORMALIZATION: u32 = 0;
/// The most hits one page holds.
pub const MAX_PAGE: u32 = 1_000;
/// The scheme version an edition is written with (ADR-0002 decision 1).
pub const EDITION_SCHEME: &str = "mdx-sha256-v1:";

/// The largest resource the core serves: one block of the reader's, the most an MDD record can be.
pub const MAX_RESOURCE_BYTES: u64 = xdict_mdx::limits::BLOCK_BYTES;

/// How much of a file one read takes during import.
const IMPORT_CHUNK: u64 = 4 << 20;

pub struct Core {
    nonce: u32,
    state: Mutex<State>,
    indexes: Box<dyn IndexStore>,
}

struct State {
    random: SplitMix,
    next_handle: u32,
    generation: u32,
    editions: HashMap<String, Edition>,
    locations: HashMap<String, Row>,
    open: HashMap<u32, Arc<Dict>>,
}

struct Edition {
    lineage: String,
}

/// What the registry knows of one location.
struct Row {
    edition: String,
    digest: [u8; 32],
    identity: Option<FileIdentity>,
    package: Package,
    /// Each volume's validation token (ADR-0002 decision 5, as amended), `None` where it could not be read.
    tokens: Vec<Option<[u8; 32]>>,
}

/// One opened package.
struct Dict {
    edition: String,
    mdx_source: OpenedSource,
    mdx: File,
    mdd: Vec<(OpenedSource, File)>,
    sidecars: Vec<(String, OpenedSource)>,
}

impl Core {
    /// A core for one process. Fails with `Incompatible` when the shell was built for another protocol.
    pub fn new(config: Config) -> Result<Self, CoreError> {
        Self::make(config, None)
    }

    /// A core whose indexes the shell stores ([`IndexStorage`]), where the core has no file system.
    pub fn with_index_storage(config: Config, storage: Arc<dyn IndexStorage>) -> Result<Self, CoreError> {
        Self::make(config, Some(storage))
    }

    fn make(config: Config, storage: Option<Arc<dyn IndexStorage>>) -> Result<Self, CoreError> {
        guard(|| {
            if config.client_protocol != PROTOCOL {
                return Err(CoreError::Incompatible {
                    core: PROTOCOL,
                    client: config.client_protocol,
                    detail: format!("the core speaks protocol {PROTOCOL}, the shell {}", config.client_protocol),
                });
            }
            let mut random = SplitMix::seeded(&config.entropy)?;
            let nonce = (random.next() >> 32) as u32;
            let state = State {
                random,
                next_handle: 1,
                generation: 1,
                editions: HashMap::new(),
                locations: HashMap::new(),
                open: HashMap::new(),
            };
            let indexes: Box<dyn IndexStore> = match (storage, &config.cache_dir) {
                (Some(storage), _) => Box::new(Shell(storage)),
                #[cfg(not(target_family = "wasm"))]
                (None, Some(dir)) => Box::new(Directory(dir.into())),
                _ => Box::new(Memory::default()),
            };
            Ok(Self { nonce, state: Mutex::new(state), indexes })
        })
    }

    pub fn versions() -> Versions {
        Versions {
            protocol: PROTOCOL,
            core: env!("CARGO_PKG_VERSION").into(),
            index_format: INDEX_FORMAT,
            normalization: NORMALIZATION,
        }
    }

    /// Hashes, indexes and registers a package: the slow call, run in the background, once per edition.
    pub fn import(&self, package: Package, progress: &dyn Progress) -> Result<Imported, CoreError> {
        guard(|| {
            let opened = OpenedSource::open(&package.mdx)?;
            let volumes: Vec<Result<OpenedSource, CoreError>> = package.mdd.iter().map(OpenedSource::open).collect();
            let total = opened.source.len() + volumes.iter().flatten().map(|v| v.source.len()).sum::<u64>();
            let mut done = 0u64;
            let mut report = |n: u64| {
                done += n;
                if progress.progress(done, total) {
                    Ok(())
                } else {
                    Err(CoreError::Cancelled { detail: "the import was cancelled".into() })
                }
            };

            // One pass hashes the edition and records each chunk's xxh3; the index is then built through a
            // source that checks every chunk it reads against them.
            let mut hasher = Sha256::new();
            let mut sums = Vec::new();
            read_all(&*opened.source, IMPORT_CHUNK, |chunk, _, _| {
                hasher.update(chunk);
                sums.push(xxhash_rust::xxh3::xxh3_64(chunk));
                report(chunk.len() as u64)
            })?;
            let digest: [u8; 32] = hasher.finalize().into();
            let edition = format!("{EDITION_SCHEME}{}", hex(&digest));
            let verified =
                Verified { source: &*opened.source, chunk: IMPORT_CHUNK, sums: &sums, last: Mutex::new(None) };
            let index = File::build_index(&verified, Some(Kind::Mdx), digest).map_err(changed_or)?;
            opened.unchanged()?;
            self.indexes.put(&index_name(&digest, Kind::Mdx), &index)?;
            let info = {
                let region = Box::new(index);
                let file = File::with_index(opened.source, Some(Kind::Mdx), region, digest)?
                    .map_err(|stale| CoreError::internal(format!("an index just built does not load: {stale:?}")))?;
                info(&file)
            };

            let mut problems = Vec::new();
            let mut tokens = Vec::new();
            for (volume, location) in volumes.into_iter().zip(&package.mdd) {
                let indexed = volume.and_then(|v| {
                    let size = v.source.len();
                    let token = volume_token(&v, size)?;
                    let index = File::build_index(&*v.source, Some(Kind::Mdd), token)?;
                    v.unchanged()?;
                    self.indexes.put(&index_name(&token, Kind::Mdd), &index)?;
                    report(size)?;
                    Ok(token)
                });
                match indexed {
                    Ok(token) => tokens.push(Some(token)),
                    Err(error @ CoreError::Cancelled { .. }) => return Err(error),
                    Err(error) => {
                        tokens.push(None);
                        problems.push(Problem::VolumeUnreadable { name: location.name().into(), error });
                    }
                }
            }

            let mut state = self.lock()?;
            let lineage = match state.editions.get(&edition) {
                Some(known) => known.lineage.clone(),
                None => {
                    let lineage = state.random.uuid();
                    state.editions.insert(edition.clone(), Edition { lineage: lineage.clone() });
                    lineage
                }
            };
            let row =
                Row { edition: edition.clone(), digest, identity: opened.identity, package: package.clone(), tokens };
            state.locations.insert(location_key(&package.mdx), row);
            Ok(Imported { edition, lineage, info, problems })
        })
    }

    /// Opens a location already imported: checks its identity and maps its indexes, reading nothing of the
    /// files but their headers. Anything that would need more is `NeedsImport` (ADR-0007 decision 3).
    pub fn open(&self, location: Location) -> Result<Opened, CoreError> {
        guard(|| {
            let (edition, digest, recorded, package, tokens) = {
                let state = self.lock()?;
                match state.locations.get(&location_key(&location)) {
                    None => return Ok(Opened::NeedsImport { reason: ImportReason::New }),
                    Some(row) => {
                        (row.edition.clone(), row.digest, row.identity, row.package.clone(), row.tokens.clone())
                    }
                }
            };
            let mdx_source = OpenedSource::open(&location)?;
            match (recorded, mdx_source.identity) {
                (Some(then), Some(now)) if then == now => {}
                (Some(_), Some(_)) => return Ok(Opened::NeedsImport { reason: ImportReason::Changed }),
                _ => return Ok(Opened::NeedsImport { reason: ImportReason::NoIdentity }),
            }
            let reader = OpenedSource::open(&location)?;
            let mdx = match self.with_index(reader.source, Kind::Mdx, digest)? {
                Ok(file) => file,
                Err(reason) => return Ok(Opened::NeedsImport { reason }),
            };
            let mut mdd = Vec::new();
            for (volume, token) in package.mdd.iter().zip(tokens) {
                // A volume that could not be read was reported at import; its resources are missing.
                let Some(token) = token else { continue };
                let check = OpenedSource::open(volume)?;
                if check.identity.is_none() {
                    return Ok(Opened::NeedsImport { reason: ImportReason::NoIdentity });
                }
                if volume_token(&check, check.source.len())? != token {
                    return Ok(Opened::NeedsImport { reason: ImportReason::Changed });
                }
                let reader = OpenedSource::open(volume)?;
                match self.with_index(reader.source, Kind::Mdd, token)? {
                    Ok(file) => mdd.push((check, file)),
                    Err(reason) => return Ok(Opened::NeedsImport { reason }),
                }
            }
            let mut sidecars = Vec::new();
            for sidecar in &package.sidecars {
                if let Ok(opened) = OpenedSource::open(sidecar) {
                    sidecars.push((sidecar.name().to_owned(), opened));
                }
            }
            let info = info(&mdx);
            let dict = Dict { edition: edition.clone(), mdx_source, mdx, mdd, sidecars };
            let mut state = self.lock()?;
            let handle = state.next_handle;
            state.next_handle = handle.checked_add(1).ok_or_else(|| CoreError::internal("handles exhausted"))?;
            state.open.insert(handle, Arc::new(dict));
            Ok(Opened::Ready { dict: self.handle(handle), edition, info })
        })
    }

    /// A file through its stored index, or why it needs importing again.
    fn with_index(
        &self,
        source: Box<dyn xdict_mdx::Source>,
        kind: Kind,
        identity: [u8; 32],
    ) -> Result<Result<File, ImportReason>, CoreError> {
        let Some(region) = self.indexes.get(&index_name(&identity, kind))? else {
            return Ok(Err(ImportReason::IndexMissing));
        };
        Ok(match File::with_index(source, Some(kind), region, identity)? {
            Ok(file) => Ok(file),
            Err(Stale::Format | Stale::Reader) => Err(ImportReason::IndexOutdated),
            Err(Stale::OtherFile) => Err(ImportReason::Changed),
            Err(Stale::Damaged(_)) => Err(ImportReason::IndexMissing),
        })
    }

    /// Closes a handle. Closing one already closed is not an error; one from another core is.
    pub fn close(&self, dict: String) -> Result<(), CoreError> {
        guard(|| {
            let handle = self.parse_handle(&dict)?;
            self.lock()?.open.remove(&handle);
            Ok(())
        })
    }

    /// Looks `query` up in `dicts`, in that order, and returns one page of references.
    pub fn lookup(&self, query: String, dicts: Vec<String>, options: LookupOptions) -> Result<Page, CoreError> {
        guard(|| {
            if options.limit > MAX_PAGE {
                return Err(CoreError::TooLarge {
                    limit: Limit::Page,
                    detail: format!("a page holds at most {MAX_PAGE} hits, {} were asked", options.limit),
                });
            }
            let generation = self.lock()?.generation;
            if options.generation.is_some_and(|g| g != generation) {
                return Err(CoreError::stale("the page belongs to another generation"));
            }
            let mut hits = Vec::new();
            let mut problems = Vec::new();
            for id in &dicts {
                let dict = self.dict(id)?;
                let found = dict.mdx.find(&query)?;
                let targets = redirect_targets(&dict.mdx, &found)?;
                let mut seen: HashMap<String, u32> = HashMap::new();
                for &i in &found {
                    let key = dict.mdx.key(i)?.into_owned();
                    let occurrence = next_occurrence(&mut seen, &key);
                    let Some(target) = targets.get(&i).cloned().flatten() else {
                        let how = if key == query { How::Exact } else { How::Folded };
                        let entry = EntryRef { edition: dict.edition.clone(), key: key.clone(), occurrence };
                        hits.push(Hit { dict: id.clone(), entry, headword: key, how, problems: vec![] });
                        continue;
                    };
                    let landed = dict.mdx.find(&target)?;
                    let landed_targets = redirect_targets(&dict.mdx, &landed)?;
                    let mut found_any = false;
                    let mut seen_target: HashMap<String, u32> = HashMap::new();
                    for &j in &landed {
                        let landed_key = dict.mdx.key(j)?.into_owned();
                        let occurrence = next_occurrence(&mut seen_target, &landed_key);
                        if landed_targets.get(&j).is_some_and(Option::is_some) {
                            continue;
                        }
                        found_any = true;
                        let entry = EntryRef { edition: dict.edition.clone(), key: landed_key.clone(), occurrence };
                        let how = How::Redirect { chain: vec![key.clone(), landed_key.clone()] };
                        hits.push(Hit { dict: id.clone(), entry, headword: landed_key, how, problems: vec![] });
                    }
                    if !found_any {
                        problems.push(HitProblem::DanglingRedirect { from: key.clone(), target });
                    }
                }
            }
            let total = hits.len() as u64;
            let hits = hits.into_iter().skip(options.offset as usize).take(options.limit as usize).collect();
            Ok(Page { hits, total, generation, problems })
        })
    }

    /// Keys beginning with `prefix`, for a search field.
    pub fn suggest(&self, prefix: String, dicts: Vec<String>, limit: u32) -> Result<Vec<String>, CoreError> {
        guard(|| {
            let wanted = prefix.to_lowercase();
            let mut out: Vec<String> = Vec::new();
            for id in &dicts {
                let dict = self.dict(id)?;
                for key in dict.mdx.keys() {
                    if out.len() >= limit as usize {
                        return Ok(out);
                    }
                    let key = key?;
                    if key.to_lowercase().starts_with(&wanted) && !out.iter().any(|k| *k == key) {
                        out.push(key.into_owned());
                    }
                }
            }
            Ok(out)
        })
    }

    /// One entry's HTML for the entry view.
    pub fn entry(&self, dict: String, entry: EntryRef, view: View) -> Result<Entry, CoreError> {
        guard(|| {
            let opened = self.dict(&dict)?;
            if opened.edition != entry.edition {
                return Err(CoreError::EditionMismatch {
                    detail: format!("{} is not the edition open as {dict}", entry.edition),
                });
            }
            opened.mdx_source.unchanged()?;
            // The one record asked for, its size checked before it is read (the view's ceiling bounds what is
            // allocated, not only what is returned).
            let mut same_key = Vec::new();
            for i in opened.mdx.find(&entry.key)? {
                if opened.mdx.key(i)? == entry.key {
                    same_key.push(i);
                }
            }
            let i = same_key.get(entry.occurrence as usize).copied().ok_or_else(|| CoreError::NotFound {
                what: Missing::Entry,
                detail: format!("{:?} has no record {}", entry.key, entry.occurrence),
            })?;
            let size = opened.mdx.record_size(i)?;
            if size > view.max_body_bytes {
                return Err(CoreError::TooLarge {
                    limit: Limit::Body,
                    detail: format!("the entry is {size} bytes, the view takes {}", view.max_body_bytes),
                });
            }
            let record = opened.mdx.record(i)?;
            let html = String::from_utf8_lossy(&record.data).into_owned();
            Ok(Entry { entry, html, csp: csp(&view.base_url), lossy_bytes: 0 })
        })
    }

    /// What a URL an entry or its script produced means. Takes the URL raw, `.tts` and all.
    pub fn link(&self, dict: String, url: String, origin: LinkOrigin, view: View) -> Result<Link, CoreError> {
        guard(|| {
            self.dict(&dict)?;
            let _ = (&origin, &view);
            Ok(classify(&url))
        })
    }

    /// A resource's bytes: the sidecars first, then the volumes in order. Missing is a value.
    pub fn resource(&self, dict: String, path: String, view: View) -> Result<Resource, CoreError> {
        guard(|| {
            let _ = &view;
            let opened = self.dict(&dict)?;
            let path = normalize_path(&path);
            for (name, sidecar) in &opened.sidecars {
                if name.eq_ignore_ascii_case(&path) {
                    sidecar.unchanged()?;
                    let size = sidecar.source.len();
                    if size > MAX_RESOURCE_BYTES {
                        return Err(CoreError::TooLarge {
                            limit: Limit::Body,
                            detail: format!("{path} is {size} bytes, more than {MAX_RESOURCE_BYTES}"),
                        });
                    }
                    let mut bytes = Vec::new();
                    read_all(&*sidecar.source, IMPORT_CHUNK, |chunk, _, _| {
                        bytes.extend_from_slice(chunk);
                        Ok(())
                    })?;
                    return Ok(Resource::Found { mime: mime(&path).into(), path, bytes });
                }
            }
            let key = format!("\\{}", path.replace('/', "\\"));
            for (check, volume) in &opened.mdd {
                check.unchanged()?;
                if let Some(record) = volume.lookup(&key)?.into_iter().next() {
                    return Ok(Resource::Found { mime: mime(&path).into(), path, bytes: record.data });
                }
            }
            Ok(Resource::Missing { path })
        })
    }

    /// Panics on purpose, so that each binding can prove a panic reaches it as `Internal`.
    pub fn self_test_panic(&self) -> Result<(), CoreError> {
        guard(|| -> Result<(), CoreError> {
            #[allow(clippy::panic)]
            {
                panic!("the deliberate panic of self_test_panic")
            }
        })
    }

    fn lock(&self) -> Result<MutexGuard<'_, State>, CoreError> {
        self.state.lock().map_err(|_| CoreError::internal("the core's state was left inconsistent by an earlier fault"))
    }

    fn handle(&self, handle: u32) -> String {
        format!("{:08x}{handle:08x}", self.nonce)
    }

    fn parse_handle(&self, dict: &str) -> Result<u32, CoreError> {
        let raw = u64::from_str_radix(dict, 16).map_err(|_| CoreError::stale(format!("{dict:?} is not a handle")))?;
        if dict.len() != 16 || (raw >> 32) as u32 != self.nonce {
            return Err(CoreError::stale(format!("{dict} belongs to another core")));
        }
        Ok(raw as u32)
    }

    fn dict(&self, dict: &str) -> Result<Arc<Dict>, CoreError> {
        let handle = self.parse_handle(dict)?;
        self.lock()?.open.get(&handle).cloned().ok_or_else(|| CoreError::stale(format!("{dict} is closed")))
    }
}

/// Runs a call so that a panic inside it comes back as `Internal` (ADR-0003 decision 4).
fn guard<T>(call: impl FnOnce() -> Result<T, CoreError>) -> Result<T, CoreError> {
    catch_unwind(AssertUnwindSafe(call)).unwrap_or_else(|payload| {
        let message = payload
            .downcast_ref::<&str>()
            .map(|s| (*s).to_owned())
            .or_else(|| payload.downcast_ref::<String>().cloned())
            .unwrap_or_else(|| "a panic with no message".into());
        Err(CoreError::internal(message))
    })
}

fn info(file: &File) -> DictInfo {
    let header = file.header();
    let format_version = match header.version {
        xdict_mdx::FormatVersion::V1_2 => "1.2",
        xdict_mdx::FormatVersion::V2_0 => "2.0",
        xdict_mdx::FormatVersion::V3_0 => "3.0",
    };
    DictInfo {
        title: header.title.clone(),
        description: header.description.clone(),
        format_version: format_version.into(),
        keys: file.len() as u64,
    }
}

/// An index's name in the store: its identity, and what it indexes.
fn index_name(identity: &[u8; 32], kind: Kind) -> String {
    let kind = if kind == Kind::Mdd { "mdd" } else { "mdx" };
    format!("{}.{kind}.xdidx", hex(identity))
}

/// A resource volume's validation token (ADR-0002 decision 5, as amended): its identity where the platform
/// has one, its whole content's xxh3-128 where it has none. Local only, never an identity, never synced.
fn volume_token(volume: &OpenedSource, size: u64) -> Result<[u8; 32], CoreError> {
    let mut token = [0u8; 32];
    match volume.identity {
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
            let mut h = xxhash_rust::xxh3::Xxh3::new();
            read_all(&*volume.source, IMPORT_CHUNK, |chunk, _, _| {
                h.update(chunk);
                Ok(())
            })?;
            token[0] = 1;
            token[16..].copy_from_slice(&h.digest128().to_le_bytes());
            token[8..16].copy_from_slice(&size.to_le_bytes());
        }
    }
    Ok(token)
}

/// A reader error from a verified read: the file changed under the import, or the file's own error.
fn changed_or(error: xdict_mdx::Error) -> CoreError {
    match &error {
        xdict_mdx::Error::Io(e) if e.get_ref().is_some_and(|inner| inner.is::<Changed>()) => {
            CoreError::SourceChanged { detail: Changed.to_string() }
        }
        _ => error.into(),
    }
}

fn location_key(location: &Location) -> String {
    match location {
        Location::Path { path } => format!("path:{path}"),
        Location::Source { name, .. } => format!("source:{name}"),
    }
}

fn next_occurrence(seen: &mut HashMap<String, u32>, key: &str) -> u32 {
    let n = seen.entry(key.to_owned()).or_insert(0);
    let occurrence = *n;
    *n += 1;
    occurrence
}

/// For each of `keys`, its record's redirect target, if it is one: every block read once.
fn redirect_targets(file: &File, keys: &[usize]) -> Result<HashMap<usize, Option<String>>, CoreError> {
    let mut targets = HashMap::with_capacity(keys.len());
    file.for_each_record(keys, |i, record| {
        targets.insert(i, redirect_target(&String::from_utf8_lossy(&record.data)).map(str::to_owned));
        Ok(())
    })?;
    Ok(targets)
}

/// The target of an `@@@LINK=` record.
fn redirect_target(text: &str) -> Option<&str> {
    let rest = text.trim_start().strip_prefix("@@@LINK=")?;
    let target = rest.lines().next().unwrap_or("").trim();
    (!target.is_empty()).then_some(target)
}

/// What a URL means, read the way the entry's web view reads it (the WHATWG URL Standard): otherwise the
/// core could call "local" a URL the view fetches from the network (`/\\host/x`, `ht<TAB>tp://host`).
fn classify(url: &str) -> Link {
    let url = preprocess(url);
    if let Some((scheme, rest)) = scheme(&url) {
        let body = rest.strip_prefix("//").unwrap_or(rest);
        return match scheme.as_str() {
            "entry" | "bword" => {
                let (query, anchor) = match body.split_once('#') {
                    Some((q, a)) => (q.to_owned(), Some(a.to_owned())),
                    None => (body.to_owned(), None),
                };
                Link::Lookup { query, anchor }
            }
            "sound" => match body
                .len()
                .checked_sub(4)
                .filter(|&n| body.get(n..).is_some_and(|t| t.eq_ignore_ascii_case(".tts")))
            {
                Some(n) => Link::Speak { text: body.get(..n).unwrap_or("").to_owned() },
                None => Link::Sound { path: body.to_owned() },
            },
            "javascript" => Link::Blocked { why: BlockReason::Script },
            // The URL Standard's special schemes other than `file`: each reaches the network, with or
            // without slashes after the colon.
            "http" | "https" | "ws" | "wss" | "ftp" => Link::Blocked { why: BlockReason::Remote { url } },
            "file" | "mdd" => Link::Resource { path: normalize_path(body) },
            _ => Link::Blocked { why: BlockReason::UnknownScheme { scheme } },
        };
    }
    if let Some(name) = url.strip_prefix('#') {
        return Link::Anchor { name: name.into() };
    }
    // Without a scheme, two leading slashes in either direction name another host.
    if url.replace('\\', "/").starts_with("//") {
        return Link::Blocked { why: BlockReason::Remote { url } };
    }
    Link::Resource { path: normalize_path(&url) }
}

/// A URL as a browser's parser takes it in: leading and trailing C0 controls and spaces trimmed, and every
/// tab and newline removed, wherever it is.
fn preprocess(url: &str) -> String {
    url.trim_matches(|c: char| c <= ' ').chars().filter(|c| !matches!(c, '\t' | '\n' | '\r')).collect()
}

/// The URL's scheme, lower-cased, and what follows its colon: an ASCII letter, then letters, digits, `+`,
/// `-` or `.`, then `:`.
fn scheme(url: &str) -> Option<(String, &str)> {
    let (head, rest) = url.split_once(':')?;
    let mut chars = head.chars();
    let first = chars.next()?;
    let valid = first.is_ascii_alphabetic() && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'));
    valid.then(|| (head.to_ascii_lowercase(), rest))
}

/// A resource path as the core compares it: forward slashes, no leading separator.
fn normalize_path(path: &str) -> String {
    path.replace('\\', "/").trim_start_matches('/').to_owned()
}

fn mime(path: &str) -> &'static str {
    let ext = path.rsplit('.').next().unwrap_or("").to_ascii_lowercase();
    match ext.as_str() {
        "css" => "text/css",
        "js" => "text/javascript",
        "html" | "htm" => "text/html",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "svg" => "image/svg+xml",
        "webp" => "image/webp",
        "mp3" => "audio/mpeg",
        "ogg" => "audio/ogg",
        "wav" => "audio/wav",
        "ttf" => "font/ttf",
        "otf" => "font/otf",
        "woff" => "font/woff",
        "woff2" => "font/woff2",
        _ => "application/octet-stream",
    }
}

/// The policy the view must apply: only the view's own base for every fetch, nothing remote.
fn csp(base: &str) -> String {
    format!(
        "default-src {base}; script-src {base} 'unsafe-inline' 'unsafe-eval'; style-src {base} 'unsafe-inline'; \
         img-src {base} data:; font-src {base} data:; media-src {base}; connect-src 'none'; form-action 'none'; \
         frame-src 'none'; object-src 'none'; base-uri 'none'"
    )
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// SplitMix64: unique handles and lineage ids, not secrets. Seeded from the shell's entropy, or natively from
/// the operating system's through the standard library's randomly keyed hasher.
struct SplitMix(u64);

impl SplitMix {
    fn seeded(entropy: &[u8]) -> Result<Self, CoreError> {
        let mut seed = 0u64;
        if entropy.is_empty() {
            if cfg!(target_family = "wasm") {
                return Err(CoreError::internal("this platform needs Config.entropy: the core has no random source"));
            }
            use std::hash::{BuildHasher, Hasher};
            seed = std::collections::hash_map::RandomState::new().build_hasher().finish();
        }
        for (i, byte) in entropy.iter().enumerate() {
            seed ^= u64::from(*byte).rotate_left((i % 8 * 8) as u32);
            seed = seed.wrapping_mul(0x9E37_79B9_7F4A_7C15);
        }
        Ok(Self(seed))
    }

    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// A version 4 UUID.
    fn uuid(&mut self) -> String {
        let (a, b) = (self.next(), self.next());
        let a = (a & !0xF000) | 0x4000;
        let b = (b & !(0b11 << 62)) | (0b10 << 62);
        format!(
            "{:08x}-{:04x}-{:04x}-{:04x}-{:012x}",
            a >> 32,
            (a >> 16) & 0xFFFF,
            a & 0xFFFF,
            b >> 48,
            b & 0xFFFF_FFFF_FFFF
        )
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::indexing_slicing, clippy::panic)]
mod tests {
    use super::*;

    fn remote(url: &str) -> bool {
        matches!(classify(url), Link::Blocked { why: BlockReason::Remote { .. } })
    }

    /// A URL is read the way the entry's web view will read it (the WHATWG URL Standard), or the core would
    /// call "local" what the view fetches from the network.
    #[test]
    fn urls_a_browser_reads_as_remote_are_remote() {
        for url in [
            "https://example.com/a.mp3",
            "HTTP://example.com/a.mp3",
            "//example.com/a.mp3",
            "/\\example.com/a.mp3",
            "\\\\example.com/a.mp3",
            "\\/example.com/a.mp3",
            " \u{1}https://example.com/a.mp3",
            "ht\ttps://example.com/a.mp3",
            "https\n://example.com/a.mp3",
            "http:example.com/a.mp3",
            "wss://example.com/socket",
            "ftp://example.com/a",
        ] {
            assert!(remote(url), "{url:?} was classified {:?}", classify(url));
        }
    }

    /// A source that claims a size and refuses to be read.
    struct Huge;

    impl crate::ByteSource for Huge {
        fn size(&self) -> u64 {
            1 << 40
        }
        fn read_at(&self, _: u64, _: u32) -> Result<Vec<u8>, CoreError> {
            Err(CoreError::internal("a resource over the limit was read"))
        }
        fn identity(&self) -> Option<FileIdentity> {
            None
        }
    }

    struct Fixed(Vec<u8>);

    impl crate::ByteSource for Fixed {
        fn size(&self) -> u64 {
            self.0.len() as u64
        }
        fn read_at(&self, offset: u64, len: u32) -> Result<Vec<u8>, CoreError> {
            Ok(self.0[offset as usize..offset as usize + len as usize].to_vec())
        }
        fn identity(&self) -> Option<FileIdentity> {
            Some(FileIdentity { device: 1, inode: 1, size: self.0.len() as u64, mtime_ns: 0, ctime_ns: 0 })
        }
    }

    fn view() -> View {
        View { base_url: "xdict://d/".into(), skin: None, max_body_bytes: 1 << 20 }
    }

    /// The limit is checked against the size the source declares, before anything is read or allocated.
    #[test]
    fn a_resource_over_the_limit_is_refused_before_it_is_read() {
        use xdict_mdx_writer::{Entry as W, Spec, write};
        let core = Core::new(Config { client_protocol: PROTOCOL, ..Config::default() }).unwrap();
        let mdx = Location::Source {
            name: "a.mdx".into(),
            source: Arc::new(Fixed(write(&Spec::mdx(), &[W::text("a", "b")]).unwrap())),
        };
        let huge = Location::Source { name: "huge.css".into(), source: Arc::new(Huge) };
        core.import(Package { mdx: mdx.clone(), mdd: vec![], sidecars: vec![huge] }, &NoProgress).unwrap();
        let Opened::Ready { dict, .. } = core.open(mdx).unwrap() else { panic!("not open") };
        let refused = core.resource(dict, "huge.css".into(), view());
        assert!(matches!(refused, Err(CoreError::TooLarge { limit: Limit::Body, .. })), "{refused:?}");
    }

    /// Counts the bytes read through it.
    struct Counting(Vec<u8>, Arc<std::sync::atomic::AtomicU64>);

    impl crate::ByteSource for Counting {
        fn size(&self) -> u64 {
            self.0.len() as u64
        }
        fn read_at(&self, offset: u64, len: u32) -> Result<Vec<u8>, CoreError> {
            self.1.fetch_add(u64::from(len), std::sync::atomic::Ordering::SeqCst);
            Ok(self.0[offset as usize..offset as usize + len as usize].to_vec())
        }
        fn identity(&self) -> Option<FileIdentity> {
            Some(FileIdentity { device: 1, inode: 2, size: self.0.len() as u64, mtime_ns: 0, ctime_ns: 0 })
        }
    }

    /// An entry over the view's ceiling is refused from its size in the index, before its block is read.
    #[test]
    fn an_entry_over_the_view_ceiling_is_refused_before_it_is_read() {
        use xdict_mdx_writer::{Entry as W, Spec, write};
        let core = Core::new(Config { client_protocol: PROTOCOL, ..Config::default() }).unwrap();
        let read = Arc::new(std::sync::atomic::AtomicU64::new(0));
        let bytes = write(&Spec::mdx(), &[W::text("big", &"x".repeat(5000))]).unwrap();
        let mdx = Location::Source { name: "a.mdx".into(), source: Arc::new(Counting(bytes, read.clone())) };
        let imported = core.import(Package { mdx: mdx.clone(), mdd: vec![], sidecars: vec![] }, &NoProgress).unwrap();
        let Opened::Ready { dict, .. } = core.open(mdx).unwrap() else { panic!("not open") };
        read.store(0, std::sync::atomic::Ordering::SeqCst);
        let entry = EntryRef { edition: imported.edition, key: "big".into(), occurrence: 0 };
        let small = View { max_body_bytes: 100, ..view() };
        let refused = core.entry(dict, entry, small);
        assert!(matches!(refused, Err(CoreError::TooLarge { limit: Limit::Body, .. })), "{refused:?}");
        assert_eq!(read.load(std::sync::atomic::Ordering::SeqCst), 0, "the record was read before it was refused");
    }

    /// Serves one file to the first read and another, of the same size, to every read after.
    struct Switching(Vec<u8>, Vec<u8>, std::sync::atomic::AtomicUsize);

    impl crate::ByteSource for Switching {
        fn size(&self) -> u64 {
            self.0.len() as u64
        }
        fn read_at(&self, offset: u64, len: u32) -> Result<Vec<u8>, CoreError> {
            let n = self.2.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            let bytes = if n == 0 { &self.0 } else { &self.1 };
            Ok(bytes[offset as usize..offset as usize + len as usize].to_vec())
        }
        fn identity(&self) -> Option<FileIdentity> {
            None
        }
    }

    /// Codex objection 4: the edition and the index come from the same bytes, or the import fails.
    #[test]
    fn a_file_that_changes_during_import_is_caught() {
        use xdict_mdx_writer::{Entry as W, Spec, write};
        let a = write(&Spec::mdx(), &[W::text("run", "AAAA")]).unwrap();
        let b = write(&Spec::mdx(), &[W::text("run", "BBBB")]).unwrap();
        assert_eq!(a.len(), b.len());
        let core = Core::new(Config { client_protocol: PROTOCOL, ..Config::default() }).unwrap();
        let source = Arc::new(Switching(a, b, std::sync::atomic::AtomicUsize::new(0)));
        let mdx = Location::Source { name: "a.mdx".into(), source };
        let result = core.import(Package { mdx, mdd: vec![], sidecars: vec![] }, &NoProgress);
        assert!(matches!(result, Err(CoreError::SourceChanged { .. })), "{result:?}");
    }

    /// A missing or damaged index on disk is never read: `open` asks for an import, and the import repairs it.
    #[test]
    fn a_missing_or_damaged_index_asks_for_an_import() {
        use xdict_mdx_writer::{Entry as W, Spec, write};
        let dir = std::env::temp_dir().join(format!("xdict-core-cache-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let config =
            Config { client_protocol: PROTOCOL, cache_dir: Some(dir.to_string_lossy().into()), ..Config::default() };
        let core = Core::new(config).unwrap();
        let bytes = write(&Spec::mdx(), &[W::text("run", "to move")]).unwrap();
        let mdx = Location::Source { name: "a.mdx".into(), source: Arc::new(Fixed(bytes)) };
        let package = Package { mdx: mdx.clone(), mdd: vec![], sidecars: vec![] };
        core.import(package.clone(), &NoProgress).unwrap();
        let index = std::fs::read_dir(&dir)
            .unwrap()
            .map(|e| e.unwrap().path())
            .find(|p| p.extension().is_some_and(|e| e == "xdidx"))
            .unwrap();
        assert!(matches!(core.open(mdx.clone()).unwrap(), Opened::Ready { .. }));

        std::fs::remove_file(&index).unwrap();
        assert_eq!(core.open(mdx.clone()).unwrap(), Opened::NeedsImport { reason: ImportReason::IndexMissing });
        core.import(package.clone(), &NoProgress).unwrap();
        assert!(matches!(core.open(mdx.clone()).unwrap(), Opened::Ready { .. }));

        let mut damaged = std::fs::read(&index).unwrap();
        let last = damaged.len() - 1;
        damaged[last] ^= 1;
        std::fs::write(&index, damaged).unwrap();
        assert_eq!(core.open(mdx).unwrap(), Opened::NeedsImport { reason: ImportReason::IndexMissing });
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn script_urls_are_blocked_however_they_are_spelt() {
        for url in ["javascript:void(0)", "JavaScript:alert(1)", "java\nscript:alert(1)", " \tjavascript:x"] {
            assert_eq!(classify(url), Link::Blocked { why: BlockReason::Script }, "{url:?}");
        }
    }

    #[test]
    fn dictionary_links_survive_the_same_reading() {
        assert_eq!(classify(" entry://run#n1 "), Link::Lookup { query: "run".into(), anchor: Some("n1".into()) });
        assert_eq!(classify("sound://a\tb.mp3"), Link::Sound { path: "ab.mp3".into() });
        assert_eq!(classify("styles/main.css"), Link::Resource { path: "styles/main.css".into() });
        assert_eq!(classify("/x.css"), Link::Resource { path: "x.css".into() });
    }
}
