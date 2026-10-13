//! The [`Core`]: one per process, thread-safe, every call guarded so that no panic crosses the boundary.
//!
//! **No lock is held while the shell's code runs**: a `ByteSource`, a `Progress` callback, or a read through
//! either, so a callback may call back into the core without deadlocking (Codex objection 9).

use std::collections::HashMap;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

use xdict_entry::StyleSheet;
use xdict_lookup::{How as LookupHow, Mode, Policy, Problem as LookupProblem};
use xdict_mdx::index::{Derive, Plain};
use xdict_mdx::{Budget, File, Kind};

use crate::error::{CoreError, Limit, Missing};
use crate::source::{Changed, Opened as OpenedSource, Verified, read_all};
#[cfg(not(target_family = "wasm"))]
use crate::store::Directory;
use crate::store::{IndexStorage, IndexStore, Memory, Shell};
use crate::types::*;
use xdict_identity::{CHUNK, FileRegistry, LocationRecord, MemoryRegistry, Registry, VolumeRecord};
use xdict_mdx::index::Stale;

/// The protocol between shell and core (ADR-0007 decision 11). Raised by any change a shell must be rebuilt for.
pub const PROTOCOL: u32 = 1;
/// The per-edition index's format.
pub const INDEX_FORMAT: u32 = xdict_mdx::index::FORMAT;
/// The lookup policy's version: tier 2 and internal keys (ADR-0007 decisions 15 and 16).
pub const NORMALIZATION: u32 = xdict_lookup::NORMALIZATION;
/// The most hits one page holds.
pub const MAX_PAGE: u32 = 1_000;
/// The scheme version an edition is written with (ADR-0002 decision 1).
pub use xdict_identity::EDITION_SCHEME;

/// The largest resource the core serves: one block of the reader's, the most an MDD record can be.
pub const MAX_RESOURCE_BYTES: u64 = xdict_mdx::limits::BLOCK_BYTES;

/// Candidates one lookup may read, redirect targets included. Larger than the reader's own
/// [`xdict_mdx::limits::LOOKUP_RECORDS`], which bounds records it returns: the core reads each candidate only
/// for its redirect and keeps a reference, so a paged lookup can answer a key that many records share (a
/// sentence library files 66,355 under "EC", the most measured; this is about 16 times that).
pub const LOOKUP_CANDIDATES: usize = 1 << 20;
/// Bytes of records one lookup may read, redirect targets included: the reader's own bound.
pub const LOOKUP_BYTES: u64 = xdict_mdx::limits::LOOKUP_BYTES;

/// How much of a file one read takes during import.
const IMPORT_CHUNK: u64 = CHUNK;

pub struct Core {
    nonce: u32,
    state: Mutex<State>,
    indexes: Box<dyn IndexStore>,
    registry: Box<dyn Registry>,
}

struct State {
    random: SplitMix,
    next_handle: u32,
    generation: u32,
    open: HashMap<u32, Arc<Dict>>,
}

/// One opened package.
struct Dict {
    edition: String,
    mdx_source: OpenedSource,
    mdx: File,
    mdd: Vec<(OpenedSource, File)>,
    sidecars: Vec<(String, OpenedSource)>,
    /// The MDX header's compact styles, applied to every entry.
    sheet: StyleSheet,
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
            let state = State { random, next_handle: 1, generation: 1, open: HashMap::new() };
            let indexes: Box<dyn IndexStore> = match (storage, &config.cache_dir) {
                (Some(storage), _) => Box::new(Shell(storage)),
                #[cfg(not(target_family = "wasm"))]
                (None, Some(dir)) => Box::new(Directory(xdict_mmap::OwnDirectory::new(dir))),
                _ => Box::new(Memory::default()),
            };
            let registry: Box<dyn Registry> = match &config.data_dir {
                Some(dir) => Box::new(FileRegistry::open(dir).map_err(registry_error)?),
                None => Box::new(MemoryRegistry::default()),
            };
            Ok(Self { nonce, state: Mutex::new(state), indexes, registry })
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

    /// Hashes, indexes and registers a package: the slow call, run in the background. A known edition whose
    /// index still loads is not indexed again.
    pub fn import(&self, package: Package, progress: &dyn Progress) -> Result<Imported, CoreError> {
        guard(|| {
            let opened = OpenedSource::open(&package.mdx)?;
            let volumes: Vec<Result<OpenedSource, CoreError>> = package.mdd.iter().map(OpenedSource::open).collect();
            let total = opened.source.len() + volumes.iter().flatten().map(|v| v.source.len()).sum::<u64>();
            let (done, stopped) = (AtomicU64::new(0), AtomicBool::new(false));
            // Called from every thread of the import; one `false` stops them all at their next report.
            let report = |n: u64| -> Result<(), CoreError> {
                let cancelled = || CoreError::Cancelled { detail: "the import was cancelled".into() };
                if stopped.load(Ordering::SeqCst) {
                    return Err(cancelled());
                }
                if progress.progress(done.fetch_add(n, Ordering::SeqCst) + n, total) {
                    Ok(())
                } else {
                    stopped.store(true, Ordering::SeqCst);
                    Err(cancelled())
                }
            };

            let indexed = self.index_all(&opened, volumes, &report);
            let (edition, info) = indexed.mdx?;
            let (records, problems) = volume_records(indexed.volumes, &package.mdd)?;
            let record = LocationRecord {
                location: location_key(&package.mdx),
                edition: edition.clone(),
                identity: opened.identity,
                volumes: records,
                sidecars: package.sidecars.iter().map(location_key).collect(),
            };
            // A lineage is minted before the registry is asked, so that no lock of the core is held inside it.
            let candidate = self.lock()?.random.uuid();
            let lineage = self.registry.register(record, &mut || candidate.clone()).map_err(registry_error)?;
            Ok(Imported { edition, lineage, info, problems })
        })
    }

    /// Hashes and indexes the MDX and every volume. The volumes need nothing of the MDX's: natively each is
    /// indexed on a thread of its own while the MDX is hashed and indexed.
    fn index_all(
        &self,
        mdx: &OpenedSource,
        volumes: Vec<Result<OpenedSource, CoreError>>,
        report: &(dyn Fn(u64) -> Result<(), CoreError> + Sync),
    ) -> Indexed {
        #[cfg(not(target_family = "wasm"))]
        return std::thread::scope(|scope| {
            let threads: Vec<_> = volumes
                .into_iter()
                .map(|volume| scope.spawn(|| volume.and_then(|v| self.import_volume(&v, report))))
                .collect();
            let indexed_mdx = self.import_mdx(mdx, report);
            let indexed = threads
                .into_iter()
                .map(|t| t.join().unwrap_or_else(|_| Err(CoreError::internal("a volume's import panicked"))))
                .collect();
            Indexed { mdx: indexed_mdx, volumes: indexed }
        });
        #[cfg(target_family = "wasm")]
        {
            let indexed =
                volumes.into_iter().map(|volume| volume.and_then(|v| self.import_volume(&v, report))).collect();
            Indexed { mdx: self.import_mdx(mdx, report), volumes: indexed }
        }
    }

    /// Hashes an MDX in one pass, summing each chunk, and indexes it through a source that checks every chunk it
    /// reads against those sums, unless an index of that edition still loads. Returns the edition and its info.
    fn import_mdx(
        &self,
        opened: &OpenedSource,
        report: &(dyn Fn(u64) -> Result<(), CoreError> + Sync),
    ) -> Result<(String, DictInfo), CoreError> {
        let hashed = xdict_identity::hash(&*opened.source, report)?;
        let digest = hashed.digest;
        let info = match self.with_index(opened.reader(), Kind::Mdx, digest)? {
            Ok(file) => info(&file),
            Err(_) => {
                let verified =
                    Verified { source: &*opened.source, chunk: CHUNK, sums: &hashed.sums, last: Mutex::new(None) };
                let index = File::build_index(&verified, Some(Kind::Mdx), digest, &Policy).map_err(changed_or)?;
                self.indexes.put(&index_name(&digest, Kind::Mdx), &index)?;
                let file =
                    File::with_index(opened.reader(), Some(Kind::Mdx), Box::new(index), digest, derive(Kind::Mdx))?
                        .map_err(|stale| {
                            CoreError::internal(format!("an index just built does not load: {stale:?}"))
                        })?;
                info(&file)
            }
        };
        opened.unchanged()?;
        Ok((hashed.edition(), info))
    }

    /// A resource volume's validation token, and its index, unless one for that token still loads.
    fn import_volume(
        &self,
        volume: &OpenedSource,
        report: &(dyn Fn(u64) -> Result<(), CoreError> + Sync),
    ) -> Result<[u8; 32], CoreError> {
        let token = xdict_identity::volume_token(volume.identity, &*volume.source, report)?;
        if self.with_index(volume.reader(), Kind::Mdd, token)?.is_err() {
            let index = File::build_index(&*volume.source, Some(Kind::Mdd), token, &Plain)?;
            self.indexes.put(&index_name(&token, Kind::Mdd), &index)?;
        }
        volume.unchanged()?;
        if volume.identity.is_some() {
            report(volume.source.len())?;
        }
        Ok(token)
    }

    /// Opens a package already imported: checks every file's identity against the registry and maps the
    /// indexes, reading nothing of the files but their headers. Anything that would need more is
    /// `NeedsImport` (ADR-0007 decision 3).
    pub fn open(&self, package: Package) -> Result<Opened, CoreError> {
        guard(|| {
            let Some(record) = self.registry.location(&location_key(&package.mdx)).map_err(registry_error)? else {
                return Ok(Opened::NeedsImport { reason: ImportReason::New });
            };
            let mdx_source = OpenedSource::open(&package.mdx)?;
            match (record.identity, mdx_source.identity) {
                (Some(then), Some(now)) if then == now => {}
                (Some(_), Some(_)) => return Ok(Opened::NeedsImport { reason: ImportReason::Changed }),
                _ => return Ok(Opened::NeedsImport { reason: ImportReason::NoIdentity }),
            }
            // The volumes are the ones imported, in the order imported: another set or order is another package.
            let same_volumes = record.volumes.len() == package.mdd.len()
                && record.volumes.iter().zip(&package.mdd).all(|(r, l)| r.location == location_key(l));
            if !same_volumes {
                return Ok(Opened::NeedsImport { reason: ImportReason::Changed });
            }
            let digest = unhex(record.edition.strip_prefix(EDITION_SCHEME).unwrap_or(""))?;
            // Read through the very descriptor whose identity was checked: a second open could find another file.
            let mdx = match self.with_index(mdx_source.reader(), Kind::Mdx, digest)? {
                Ok(file) => file,
                Err(reason) => return Ok(Opened::NeedsImport { reason }),
            };
            let mut mdd = Vec::new();
            for (volume, recorded) in package.mdd.iter().zip(&record.volumes) {
                // A volume that could not be read at import was reported then; its resources are missing.
                let Some(token) = &recorded.token else { continue };
                let token = unhex(token)?;
                let check = OpenedSource::open(volume)?;
                if check.identity.is_none() {
                    return Ok(Opened::NeedsImport { reason: ImportReason::NoIdentity });
                }
                if xdict_identity::volume_token::<CoreError>(check.identity, &*check.source, |_| Ok(()))? != token {
                    return Ok(Opened::NeedsImport { reason: ImportReason::Changed });
                }
                match self.with_index(check.reader(), Kind::Mdd, token)? {
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
            let sheet = StyleSheet::parse(&mdx.header().stylesheet);
            let dict = Dict { edition: record.edition.clone(), mdx_source, mdx, mdd, sidecars, sheet };
            let mut state = self.lock()?;
            let handle = state.next_handle;
            state.next_handle = handle.checked_add(1).ok_or_else(|| CoreError::internal("handles exhausted"))?;
            state.open.insert(handle, Arc::new(dict));
            Ok(Opened::Ready { dict: self.handle(handle), edition: record.edition, info })
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
        Ok(match File::with_index(source, Some(kind), region, identity, derive(kind))? {
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
        guard(|| self.lookup_within(&query, &dicts, options, Budget::new(LOOKUP_BYTES, LOOKUP_CANDIDATES)))
    }

    /// [`Self::lookup`], reading no more records than `budget` allows across every dictionary and redirect.
    fn lookup_within(
        &self,
        query: &str,
        dicts: &[String],
        options: LookupOptions,
        mut budget: Budget,
    ) -> Result<Page, CoreError> {
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
        let mode = match options.mode {
            MatchMode::Reader => Mode::Reader,
            MatchMode::Link => Mode::Link,
        };
        let mut hits = Vec::new();
        let mut problems = Vec::new();
        for id in dicts {
            let dict = self.dict(id)?;
            let file = &dict.mdx;
            // Redirects are read from the file: it is checked before, and after, so that bytes read from a file
            // rewritten meanwhile are never answered from the old index.
            dict.mdx_source.unchanged()?;
            let resolved = xdict_lookup::resolve(file, query, mode, &mut budget)?;
            let keys: Vec<usize> = resolved.hits.iter().map(|h| h.key).collect();
            let occurrences = xdict_lookup::occurrences(file, &keys)?;
            dict.mdx_source.unchanged()?;
            for hit in resolved.hits {
                let key = file.key(hit.key)?.into_owned();
                let occurrence = occurrences.get(&hit.key).copied().ok_or_else(|| CoreError::internal("occurrence"))?;
                let how = match hit.how {
                    LookupHow::Exact => How::Exact,
                    LookupHow::Folded => How::Folded,
                    LookupHow::Unmarked => How::Unmarked,
                    LookupHow::Redirect { chain } => How::Redirect { chain: key_names(file, &chain)? },
                };
                let problems = hit.problems.iter().map(|p| hit_problem(file, p)).collect::<Result<_, _>>()?;
                let entry = EntryRef { edition: dict.edition.clone(), key: key.clone(), occurrence };
                hits.push(Hit { dict: id.clone(), entry, headword: key, how, problems });
            }
            for problem in &resolved.problems {
                problems.push(hit_problem(file, problem)?);
            }
        }
        let total = hits.len() as u64;
        let hits = hits.into_iter().skip(options.offset as usize).take(options.limit as usize).collect();
        Ok(Page { hits, total, generation, problems })
    }

    /// Public keys beginning with `prefix` under each file's folding, for a search field: the dictionaries in
    /// the order given, each in folded order, each spelling once.
    pub fn suggest(&self, prefix: String, dicts: Vec<String>, limit: u32) -> Result<Vec<String>, CoreError> {
        guard(|| {
            let mut out: Vec<String> = Vec::new();
            for id in &dicts {
                xdict_lookup::suggest(&self.dict(id)?.mdx, &prefix, limit as usize, &mut out)?;
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
            opened.mdx_source.unchanged()?;
            let text = String::from_utf8_lossy(&record.data);
            let html = xdict_entry::html_text(&opened.sheet.apply(&text), &view.base_url);
            if html.len() as u64 > view.max_body_bytes {
                return Err(CoreError::TooLarge {
                    limit: Limit::Body,
                    detail: format!(
                        "the entry is {} bytes rewritten, the view takes {}",
                        html.len(),
                        view.max_body_bytes
                    ),
                });
            }
            Ok(Entry { entry, html, csp: csp(&view.base_url), lossy_bytes: record.lossy })
        })
    }

    /// What a URL an entry or its script produced means. Takes the URL raw, `.tts` and all.
    pub fn link(&self, dict: String, url: String, origin: LinkOrigin, view: View) -> Result<Link, CoreError> {
        guard(|| {
            self.dict(&dict)?;
            let dir = match &origin {
                LinkOrigin::Entry { .. } => String::new(),
                LinkOrigin::Resource { path } => xdict_entry::travelled(path).dir().to_owned(),
            };
            Ok(link(xdict_entry::classify(&url, &view.base_url, &dir)))
        })
    }

    /// A resource's bytes, by its path as it travels (decoded once here): the sidecars first, then the volumes in
    /// order. Missing is a value. A stylesheet, script or page is served rewritten for `view`.
    pub fn resource(&self, dict: String, path: String, view: View) -> Result<Resource, CoreError> {
        guard(|| {
            let opened = self.dict(&dict)?;
            let travelled = xdict_entry::travelled(&path);
            let resolved = travelled.resolved();
            // MDict paths may hold `?` and `#`; a web-style `a.css?v=2` is tried without its query after.
            let mut tries = vec![resolved.to_owned()];
            if let Some(cut) = resolved.find(['?', '#']).and_then(|at| resolved.get(..at)) {
                tries.push(cut.to_owned());
            }
            for name in &tries {
                if let Some(bytes) = self.find_resource(&opened, name)? {
                    let mime = mime(name);
                    let bytes = served(bytes, mime, &view.base_url, travelled.dir());
                    return Ok(Resource::Found { mime: mime.into(), path: name.clone(), bytes });
                }
            }
            Ok(Resource::Missing { path: resolved.to_owned() })
        })
    }

    /// A resource's bytes by its resolved path: a sidecar of that name, else the first volume that holds it.
    fn find_resource(&self, opened: &Dict, path: &str) -> Result<Option<Vec<u8>>, CoreError> {
        for (name, sidecar) in &opened.sidecars {
            if name.eq_ignore_ascii_case(path) {
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
                sidecar.unchanged()?;
                return Ok(Some(bytes));
            }
        }
        let key = format!("\\{}", path.replace('/', "\\"));
        for (check, volume) in &opened.mdd {
            check.unchanged()?;
            let found = volume.lookup(&key)?.into_iter().next();
            check.unchanged()?;
            if let Some(record) = found {
                return Ok(Some(record.data));
            }
        }
        Ok(None)
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
    format!("{}.{kind}.xdidx", xdict_identity::hex(identity))
}

fn registry_error(error: xdict_identity::RegistryError) -> CoreError {
    CoreError::Io { kind: crate::IoKind::Other, detail: format!("the registry: {error}") }
}

/// Bytes from their hex, as the registry stores them.
fn unhex(text: &str) -> Result<[u8; 32], CoreError> {
    let bad = || CoreError::internal(format!("the registry holds {text:?} where a digest belongs"));
    let mut out = [0u8; 32];
    if text.len() != 64 {
        return Err(bad());
    }
    for (i, byte) in out.iter_mut().enumerate() {
        *byte = text.get(2 * i..2 * i + 2).and_then(|h| u8::from_str_radix(h, 16).ok()).ok_or_else(bad)?;
    }
    Ok(out)
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

/// How a file of `kind` is indexed: dictionaries under the lookup policy, resource libraries plainly.
fn derive(kind: Kind) -> Arc<dyn Derive> {
    match kind {
        Kind::Mdx => Arc::new(Policy),
        Kind::Mdd => Arc::new(Plain),
    }
}

fn key_names(file: &File, chain: &[usize]) -> Result<Vec<String>, CoreError> {
    chain.iter().map(|&i| Ok(file.key(i)?.into_owned())).collect()
}

fn hit_problem(file: &File, problem: &LookupProblem) -> Result<HitProblem, CoreError> {
    Ok(match problem {
        LookupProblem::Dangling { from, target } => {
            HitProblem::DanglingRedirect { from: file.key(*from)?.into_owned(), target: target.clone() }
        }
        LookupProblem::Loop { chain } => HitProblem::RedirectLoop { chain: key_names(file, chain)? },
        LookupProblem::Limit { chain } => HitProblem::RedirectLimit { chain: key_names(file, chain)? },
    })
}

/// The core's link for the entry crate's.
fn link(link: xdict_entry::Link) -> Link {
    use xdict_entry::{Block, Link as L};
    match link {
        L::Lookup { query, anchor } => Link::Lookup { query, anchor },
        L::Resource { path } => Link::Resource { path },
        L::Sound { path } => Link::Sound { path },
        L::Speak { text } => Link::Speak { text },
        L::Anchor { name } => Link::Anchor { name },
        L::Blocked(Block::Remote { url }) => Link::Blocked { why: BlockReason::Remote { url } },
        L::Blocked(Block::Script) => Link::Blocked { why: BlockReason::Script },
        L::Blocked(Block::UnknownScheme { scheme }) => Link::Blocked { why: BlockReason::UnknownScheme { scheme } },
    }
}

/// A volume's validation token, or an MDX's digest.
type Token = [u8; 32];

/// What indexing a package gave: the MDX's edition and info, and each volume's token or why it failed.
struct Indexed {
    mdx: Result<(String, DictInfo), CoreError>,
    volumes: Vec<Result<Token, CoreError>>,
}

/// Each volume's registry record, and a problem for each that could not be read; a cancellation is the import's.
fn volume_records(
    indexed: Vec<Result<Token, CoreError>>,
    locations: &[Location],
) -> Result<(Vec<VolumeRecord>, Vec<Problem>), CoreError> {
    let mut problems = Vec::new();
    let mut records = Vec::new();
    for (result, location) in indexed.into_iter().zip(locations) {
        let token = match result {
            Ok(token) => Some(xdict_identity::hex(&token)),
            Err(error @ CoreError::Cancelled { .. }) => return Err(error),
            Err(error) => {
                problems.push(Problem::VolumeUnreadable { name: location.name().into(), error });
                None
            }
        };
        records.push(VolumeRecord { location: location_key(location), token });
    }
    Ok((records, problems))
}

/// A resource as the view gets it: a stylesheet, script or page rewritten for the view, resolving against the
/// resource's own directory; anything else, and text that is not UTF-8, as stored.
fn served(bytes: Vec<u8>, mime: &str, base: &str, dir: &str) -> Vec<u8> {
    let Ok(text) = std::str::from_utf8(&bytes) else { return bytes };
    match mime {
        "text/css" => xdict_entry::css_text(text, base, dir).into_bytes(),
        "text/javascript" => xdict_entry::script(text, base).text.into_bytes(),
        "text/html" => xdict_entry::html_text(text, base).into_bytes(),
        _ => bytes,
    }
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

/// The policy the view must apply: only the view's own base for every fetch, nothing remote. A base that is a
/// path (the Web's `/x/`) is no CSP source expression, so there the policy names the entry's own origin, which
/// is the entry's alone (`core-api.md` §5.3).
fn csp(base: &str) -> String {
    let base = if base.starts_with('/') { "'self'" } else { base };
    format!(
        "default-src {base}; script-src {base} 'unsafe-inline' 'unsafe-eval'; style-src {base} 'unsafe-inline'; \
         img-src {base} data:; font-src {base} data:; media-src {base}; connect-src 'none'; form-action 'none'; \
         frame-src 'none'; object-src 'none'; base-uri 'none'"
    )
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

    /// A CSP source expression cannot be a bare path: under a path-only base (the Web, where the entry has an
    /// origin of its own) the policy names the entry's own origin; under a scheme's base, that base.
    #[test]
    fn the_policy_names_a_source_a_browser_accepts() {
        let web = csp("/x/");
        assert!(web.contains("default-src 'self';") && !web.contains(" /x/"), "{web}");
        let native = csp("xdict://d/");
        assert!(native.contains("default-src xdict://d/;"), "{native}");
        assert!(native.contains("connect-src 'none'"), "{native}");
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
        let package = Package { mdx, mdd: vec![], sidecars: vec![huge] };
        core.import(package.clone(), &NoProgress).unwrap();
        let Opened::Ready { dict, .. } = core.open(package).unwrap() else { panic!("not open") };
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
        let package = Package { mdx, mdd: vec![], sidecars: vec![] };
        let imported = core.import(package.clone(), &NoProgress).unwrap();
        let Opened::Ready { dict, .. } = core.open(package).unwrap() else { panic!("not open") };
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

    /// An error a shell's source returns reaches the shell as itself, through the reader: not as `Io`.
    #[test]
    fn a_sources_own_error_comes_back_as_itself() {
        struct Failing(CoreError);
        impl crate::ByteSource for Failing {
            fn size(&self) -> u64 {
                4096
            }
            fn read_at(&self, _: u64, _: u32) -> Result<Vec<u8>, CoreError> {
                Err(self.0.clone())
            }
            fn identity(&self) -> Option<FileIdentity> {
                None
            }
        }
        let core = Core::new(Config { client_protocol: PROTOCOL, entropy: vec![1; 16], ..Config::default() }).unwrap();
        for error in [
            CoreError::SourceChanged { detail: "moved".into() },
            CoreError::Cancelled { detail: "the shell stopped".into() },
            CoreError::Io { kind: crate::IoKind::PermissionDenied, detail: "revoked".into() },
        ] {
            let mdx = Location::Source { name: "a.mdx".into(), source: Arc::new(Failing(error.clone())) };
            let result = core.import(Package { mdx, mdd: vec![], sidecars: vec![] }, &NoProgress);
            assert_eq!(result.map(|_| ()), Err(error));
        }
    }

    /// A lookup reads records to follow redirects, so a file rewritten after it was opened is refused there too,
    /// not answered from the old index over the new bytes.
    #[test]
    fn a_lookup_refuses_a_file_rewritten_since_it_was_opened() {
        use xdict_mdx_writer::{Entry as W, Spec, write};
        let entries = |gloss: &str| [W::text("colour", "@@@LINK=color"), W::text("color", gloss)];
        let a = write(&Spec::mdx(), &entries("AAAA")).unwrap();
        let b = write(&Spec::mdx(), &entries("BBBB")).unwrap();
        assert_eq!(a.len(), b.len());
        let dir = std::env::temp_dir().join(format!("xdict-rewritten-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("a.mdx");
        std::fs::write(&path, &a).unwrap();
        let core = Core::new(Config { client_protocol: PROTOCOL, ..Config::default() }).unwrap();
        let package = Package {
            mdx: Location::Path { path: path.to_string_lossy().into_owned() },
            mdd: vec![],
            sidecars: vec![],
        };
        core.import(package.clone(), &NoProgress).unwrap();
        let Opened::Ready { dict, .. } = core.open(package).unwrap() else { panic!("not open") };
        std::thread::sleep(std::time::Duration::from_millis(20));
        std::fs::OpenOptions::new()
            .write(true)
            .open(&path)
            .and_then(|mut f| std::io::Write::write_all(&mut f, &b))
            .unwrap();
        let options = LookupOptions { limit: 10, offset: 0, mode: MatchMode::Reader, generation: None };
        let result = core.lookup("colour".into(), vec![dict.clone()], options.clone());
        assert!(matches!(result, Err(CoreError::SourceChanged { .. })), "{result:?}");
        // A file moved or deleted since it was opened has changed too, not gone missing.
        std::fs::remove_file(&path).unwrap();
        let result = core.lookup("colour".into(), vec![dict], options);
        let _ = std::fs::remove_dir_all(&dir);
        assert!(matches!(result, Err(CoreError::SourceChanged { .. })), "{result:?}");
    }

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
        assert!(matches!(core.open(package.clone()).unwrap(), Opened::Ready { .. }));

        std::fs::remove_file(&index).unwrap();
        assert_eq!(core.open(package.clone()).unwrap(), Opened::NeedsImport { reason: ImportReason::IndexMissing });
        core.import(package.clone(), &NoProgress).unwrap();
        assert!(matches!(core.open(package.clone()).unwrap(), Opened::Ready { .. }));

        // The first byte of the key text, which follows the 296-byte header (padding between sections is in no
        // checksum, and changing it changes nothing).
        let mut damaged = std::fs::read(&index).unwrap();
        damaged[296] ^= 1;
        std::fs::write(&index, damaged).unwrap();
        assert_eq!(core.open(package).unwrap(), Opened::NeedsImport { reason: ImportReason::IndexMissing });
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// A tiny dictionary through a counting source, imported and opened: the core, its handle, the bytes read.
    fn counted(entries: &[xdict_mdx_writer::Entry]) -> (Core, String, Arc<std::sync::atomic::AtomicU64>) {
        let core = Core::new(Config { client_protocol: PROTOCOL, ..Config::default() }).unwrap();
        let read = Arc::new(std::sync::atomic::AtomicU64::new(0));
        let bytes = xdict_mdx_writer::write(&xdict_mdx_writer::Spec::mdx(), entries).unwrap();
        let mdx = Location::Source { name: "counted.mdx".into(), source: Arc::new(Counting(bytes, read.clone())) };
        let package = Package { mdx, mdd: vec![], sidecars: vec![] };
        core.import(package.clone(), &NoProgress).unwrap();
        let Opened::Ready { dict, .. } = core.open(package).unwrap() else { panic!("not open") };
        read.store(0, std::sync::atomic::Ordering::SeqCst);
        (core, dict, read)
    }

    fn page_of(core: &Core, dict: &str, query: &str, budget: Budget) -> Result<Page, CoreError> {
        let options = LookupOptions { limit: 10, offset: 0, mode: MatchMode::Reader, generation: None };
        core.lookup_within(query, &[dict.to_owned()], options, budget)
    }

    /// Codex 23: many records under one key, paged a thousand at a time, give every record once, in file order,
    /// and the same order from an index built again. 12,000 here, past the reader's own 10,000; the sentence
    /// library's 66,355 with `XDICT_PAGING_RECORDS=66355` (112 s in a debug build: each page resolves them all).
    #[test]
    fn pages_concatenate_to_the_whole_and_survive_a_rebuild() {
        use xdict_mdx_writer::Entry as W;
        let n: u32 = std::env::var("XDICT_PAGING_RECORDS").map_or(12_000, |v| v.parse().unwrap());
        let entries: Vec<W> = (0..n).map(|i| W::text("EC", &format!("{i}"))).collect();
        let pages = |core: &Core, dict: &str| -> Vec<u32> {
            let generation = Some(core.lock().unwrap().generation);
            let mut all = Vec::new();
            loop {
                let options =
                    LookupOptions { limit: 1000, offset: all.len() as u32, mode: MatchMode::Reader, generation };
                let page = core.lookup("EC".into(), vec![dict.to_owned()], options).unwrap();
                assert_eq!(page.total, u64::from(n));
                if page.hits.is_empty() {
                    return all;
                }
                all.extend(page.hits.iter().map(|h| h.entry.occurrence));
            }
        };
        let (core, dict, _) = counted(&entries);
        let first = pages(&core, &dict);
        assert_eq!(first, (0..n).collect::<Vec<u32>>());
        let (again, dict, _) = counted(&entries);
        assert_eq!(pages(&again, &dict), first, "a rebuilt index pages alike");
    }

    /// More candidates than the budget allows are refused before any record is read.
    #[test]
    fn a_lookup_over_its_candidates_reads_nothing() {
        use xdict_mdx_writer::Entry as W;
        let (core, dict, read) = counted(&[W::text("same", "1"), W::text("same", "2"), W::text("same", "3")]);
        assert_eq!(page_of(&core, &dict, "same", Budget::new(1 << 20, 3)).unwrap().total, 3);
        read.store(0, std::sync::atomic::Ordering::SeqCst);
        let refused = page_of(&core, &dict, "same", Budget::new(1 << 20, 2));
        assert!(matches!(refused, Err(CoreError::TooLarge { limit: Limit::File, .. })), "{refused:?}");
        assert_eq!(read.load(std::sync::atomic::Ordering::SeqCst), 0, "records were read before the refusal");
    }

    /// The candidates and the redirects' targets share one budget, of records and of bytes: without it, each
    /// of thousands of keys could lead to a target read again in full.
    #[test]
    fn redirects_spend_the_lookups_budget() {
        use xdict_mdx_writer::Entry as W;
        let body = "x".repeat(100);
        let (core, dict, _) = counted(&[W::text("a", "@@@LINK=b"), W::text("b", &body)]);
        let page = page_of(&core, &dict, "a", Budget::new(1 << 20, 2)).unwrap();
        assert_eq!(page.hits.len(), 1, "{page:?}");
        let refused = page_of(&core, &dict, "a", Budget::new(1 << 20, 1));
        assert!(matches!(refused, Err(CoreError::TooLarge { .. })), "the target's read was not counted: {refused:?}");
        let refused = page_of(&core, &dict, "a", Budget::new(100, 10));
        assert!(matches!(refused, Err(CoreError::TooLarge { .. })), "the target's bytes were not counted: {refused:?}");
    }
}
