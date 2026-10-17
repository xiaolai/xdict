//! The [`Core`]: one per process, thread-safe, every call guarded so that no panic crosses the boundary.
//!
//! **No lock is held while the shell's code runs**: a `ByteSource`, a `Progress` callback, or a read through
//! either, so a callback may call back into the core without deadlocking (Codex objection 9).

use std::collections::{HashMap, HashSet};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};

use xdict_entry::{Style, StyleSheet};
use xdict_lookup::{How as LookupHow, Mode, Policy, Problem as LookupProblem};
use xdict_mdx::index::{Derive, Plain};
use xdict_mdx::{Budget, File, Kind};

use crate::error::{CoreError, Limit, Missing};
use crate::health::HEALTH;
use crate::source::{Changed, Opened as OpenedSource, Verified, buffer, read_all};
#[cfg(not(target_family = "wasm"))]
use crate::store::Directory;
use crate::store::{IndexStorage, IndexStore, Memory, Shell};
use crate::types::*;
use xdict_identity::{CHUNK, FileRegistry, LocationRecord, MemoryRegistry, Refused, Registry, Target, VolumeRecord};
use xdict_mdx::index::Stale;

/// The protocol between shell and core (ADR-0007 decision 11). Raised by any change a shell must be rebuilt for.
pub const PROTOCOL: u32 = 1;
/// The per-edition index's format.
pub const INDEX_FORMAT: u32 = xdict_mdx::index::FORMAT;
/// The lookup policy's version: tier 2 and internal keys (ADR-0007 decisions 15 and 16).
pub const NORMALIZATION: u32 = xdict_lookup::NORMALIZATION;
/// The most hits one page holds.
pub const MAX_PAGE: u32 = 1_000;
/// The most suggestions one call returns: a page's worth, so a search field cannot ask the core to walk every key.
pub const MAX_SUGGEST: u32 = MAX_PAGE;
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
    /// [`Config::strip_off_for_tests`]: the hostile battery's lab only.
    strip_off_for_tests: bool,
    state: Mutex<State>,
    indexes: Box<dyn IndexStore>,
    registry: Box<dyn Registry>,
}

struct State {
    random: SplitMix,
    next_handle: u32,
    open: HashMap<u32, Arc<Dict>>,
}

/// One opened package.
struct Dict {
    edition: String,
    mdx_source: OpenedSource,
    mdx: File,
    mdd: Vec<(OpenedSource, File)>,
    /// Each sidecar by name, or why it could not be opened: reported when it is asked for, so that one unreadable
    /// stylesheet neither stops the dictionary opening nor is passed over for a volume's copy.
    sidecars: Vec<(String, Result<OpenedSource, CoreError>)>,
    /// The MDX header's compact styles, applied to every entry.
    sheet: StyleSheet,
    /// What the edition's sheets decide for its reading style (ADR-0010), read once, on first use.
    style: OnceLock<Arc<EditionStyle>>,
}

/// The version of the reading style's rules (ADR-0010): raised with any change to what normalization writes.
pub const STYLE: u32 = xdict_entry::STYLE;
/// The most sheets an edition's style is read from, and the most bytes in all.
const STYLE_SHEETS: usize = 256;
const STYLE_BYTES: usize = 32 << 20;
/// The entries an edition's base size is measured on, and the largest record read for it.
const CALIBRATION_ENTRIES: usize = 64;
const CALIBRATION_BYTES: u64 = 256 << 10;
/// The most a sampled entry's read may decompress: a short entry in a block shared with a huge one is passed over.
const CALIBRATION_BLOCK_BYTES: u64 = 8 << 20;

/// An edition's reading style and the sheets it was read from.
#[derive(Debug, Clone)]
pub struct EditionStyle {
    pub style: Style,
    /// The sheets read, by path.
    pub sheets: Vec<String>,
    /// Sheets not read, and why: never passed over silently.
    pub skipped: Vec<String>,
}

/// What the normalization does to one edition, for the gallery and the About pane (ADR-0010).
#[derive(Debug, Clone)]
pub struct StyleReport {
    pub version: u32,
    pub edition: EditionStyle,
    /// What normalizing the edition's own sheets changed.
    pub counts: xdict_entry::Counts,
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
            let state = State { random, next_handle: 1, open: HashMap::new() };
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
            Ok(Self {
                nonce,
                strip_off_for_tests: config.strip_off_for_tests,
                state: Mutex::new(state),
                indexes,
                registry,
            })
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
            // The last moment to stop: nothing is registered yet, so a cancellation here leaves the registry as it
            // was (the Web binding answers `false` once a source of the import has thrown).
            report(0)?;
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
            let sidecars = package.sidecars.iter().map(|s| (s.name().to_owned(), OpenedSource::open(s))).collect();
            let info = info(&mdx);
            let sheet = StyleSheet::parse(&mdx.header().stylesheet);
            let dict =
                Dict { edition: record.edition.clone(), mdx_source, mdx, mdd, sidecars, sheet, style: OnceLock::new() };
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
            // Dropped once the lock is released: the last reference drops the shell's sources, whose destructors
            // may call the core.
            let removed = self.lock()?.open.remove(&handle);
            drop(removed);
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
        let generation = self.generation(query, dicts, options.mode);
        if options.generation.is_some_and(|g| g != generation) {
            return Err(CoreError::stale("the page continues another lookup: other dictionaries, query or mode"));
        }
        let mode = match options.mode {
            MatchMode::Reader => Mode::Reader,
            MatchMode::Link => Mode::Link,
        };
        let mut hits = Vec::new();
        let mut problems = Vec::new();
        for id in dicts {
            self.lookup_in(id, query, mode, &mut budget, &mut hits, &mut problems)?;
        }
        let total = hits.len() as u64;
        // A walk's problems travel with its first hit (`xdict_lookup`); a hit this page leaves out gives its
        // problems to the page, so that no page loses one.
        let (from, to) = (options.offset as usize, (options.offset as usize).saturating_add(options.limit as usize));
        let mut page = Vec::new();
        for (i, hit) in hits.into_iter().enumerate() {
            if (from..to).contains(&i) {
                page.push(hit);
            } else {
                problems.extend(hit.problems);
            }
        }
        Ok(Page { hits: page, total, generation, problems })
    }

    /// One dictionary's part of a lookup: its hits, in file order, and the problems that belong to no hit.
    fn lookup_in(
        &self,
        id: &str,
        query: &str,
        mode: Mode,
        budget: &mut Budget,
        hits: &mut Vec<Hit>,
        problems: &mut Vec<HitProblem>,
    ) -> Result<(), CoreError> {
        let dict = self.dict(id)?;
        let file = &dict.mdx;
        // Redirects are read from the file: it is checked before, and after, so that bytes read from a file
        // rewritten meanwhile are never answered from the old index.
        dict.mdx_source.unchanged()?;
        let resolved = xdict_lookup::resolve(file, query, mode, budget)?;
        let keys: Vec<usize> = resolved.hits.iter().map(|h| h.key).collect();
        let occurrences = xdict_lookup::occurrences(file, &keys)?;
        dict.mdx_source.unchanged()?;
        for hit in resolved.hits {
            let occurrence = occurrences.get(&hit.key).copied().ok_or_else(|| CoreError::internal("occurrence"))?;
            hits.push(boundary_hit(file, id, &dict.edition, hit, occurrence)?);
        }
        for problem in &resolved.problems {
            problems.push(hit_problem(file, problem)?);
        }
        Ok(())
    }

    /// Public keys beginning with `prefix` under each file's folding, for a search field: the dictionaries in
    /// the order given, each in folded order, each spelling once. At most [`MAX_SUGGEST`] in all; asking for more
    /// is `TooLarge { limit: Page }`, as for a page.
    pub fn suggest(&self, prefix: String, dicts: Vec<String>, limit: u32) -> Result<Vec<String>, CoreError> {
        guard(|| {
            if limit > MAX_SUGGEST {
                return Err(CoreError::TooLarge {
                    limit: Limit::Page,
                    detail: format!("a call suggests at most {MAX_SUGGEST} keys, {limit} were asked"),
                });
            }
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
            // The record's bytes become the text, not a copy of them.
            let lossy = record.lossy;
            let text =
                String::from_utf8(record.data).unwrap_or_else(|e| String::from_utf8_lossy(e.as_bytes()).into_owned());
            // Expanded and rewritten within the view's ceiling: a small record of many style markers, or of many
            // short links, would otherwise be written whole before it could be refused.
            let max = usize::try_from(view.max_body_bytes).unwrap_or(usize::MAX);
            let too_large = |_| CoreError::TooLarge {
                limit: Limit::Body,
                detail: format!("the entry passes {} bytes expanded and rewritten, the view's ceiling", max),
            };
            let expanded = opened.sheet.apply_within(&text, max).map_err(too_large)?;
            let style = self.edition_style(&opened)?;
            // The key finds the headword (the roles, element-sweep §2.1); the package says which images it holds (S13).
            let holds = |path: &str| self.holds(&opened, path);
            // A transcription candidate that is a key is a headword written with stress (ADR-0010 Phonetics).
            let is_key = |key: &str| opened.mdx.find(key).is_ok_and(|found| !found.is_empty());
            let context = xdict_entry::Entry {
                key: &entry.key,
                resource: Some(&holds),
                is_key: Some(&is_key),
                strip_off_for_tests: self.strip_off_for_tests,
                original: view.original_style,
            };
            // Given owned (the record's text, or its expansion), it is freed once it is read.
            let body = match expanded {
                std::borrow::Cow::Owned(expanded) => expanded,
                std::borrow::Cow::Borrowed(_) => text,
            };
            let (html, _) = xdict_entry::entry_normalized_within(body, &view.base_url, "", &style.style, &context, max)
                .map_err(too_large)?;
            // Q6 (ADR-0010, the owner's answers): every entry renders in standards mode.
            let html = with_doctype(html, max).map_err(too_large)?;
            Ok(Entry { entry, html, csp: csp(&view.base_url), lossy_bytes: lossy })
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
                let mime = mime(name);
                // A stylesheet, script or page is a body the view renders, held to the view's ceiling whether or
                // not it could be rewritten (text that is not UTF-8 is served as stored); nothing leaves larger
                // than the core's own. Checked from the declared size before the read, and again as served.
                let ceiling =
                    if renders(mime) { view.max_body_bytes.min(MAX_RESOURCE_BYTES) } else { MAX_RESOURCE_BYTES };
                if let Some(bytes) = self.find_resource(&opened, name, ceiling)? {
                    let style = if renders(mime) { Some(self.edition_style(&opened)?) } else { None };
                    let style = style.as_ref().map(|s| &s.style);
                    let bytes = served(bytes, mime, &view, travelled.dir(), style, self.strip_off_for_tests, ceiling)
                        .map_err(|_| CoreError::TooLarge {
                        limit: Limit::Body,
                        detail: format!("{name} passes {ceiling} bytes as served, the most it may be"),
                    })?;
                    return Ok(Resource::Found { mime: mime.into(), path: name.clone(), bytes });
                }
            }
            Ok(Resource::Missing { path: resolved.to_owned() })
        })
    }

    /// A resource's bytes by its resolved path: a sidecar of that name, else the first volume that holds it.
    /// One larger than `ceiling` is refused from its declared size, before it is read.
    /// The edition's reading style, read from its sheets on first use: the sidecars' `.css`, then the volumes'.
    fn edition_style(&self, opened: &Dict) -> Result<Arc<EditionStyle>, CoreError> {
        if let Some(style) = opened.style.get() {
            return Ok(Arc::clone(style));
        }
        let mut paths: Vec<String> = Vec::new();
        for (name, _) in &opened.sidecars {
            if name.to_ascii_lowercase().ends_with(".css") {
                paths.push(name.clone());
            }
        }
        for (check, volume) in &opened.mdd {
            check.unchanged()?;
            for key in volume.keys() {
                let key = key?;
                if key.to_ascii_lowercase().ends_with(".css") {
                    let path = key.trim_start_matches('\\').replace('\\', "/");
                    if !paths.iter().any(|p| p.eq_ignore_ascii_case(&path)) {
                        paths.push(path);
                    }
                }
            }
        }
        let (mut texts, mut sheets, mut skipped, mut total) = (Vec::new(), Vec::new(), Vec::new(), 0usize);
        for path in paths {
            if sheets.len() >= STYLE_SHEETS {
                skipped.push(format!("{path}: past the first {STYLE_SHEETS} sheets"));
                continue;
            }
            // What is left of the budget is the ceiling: a sheet past it is passed over from its declared size,
            // unread (reading 44 MiB only to drop it raised `resource()`'s peak by 40%).
            let room = STYLE_BYTES.saturating_sub(total);
            match self.find_resource(opened, &path, room as u64) {
                Ok(Some(bytes)) => {
                    total += bytes.len();
                    // Valid UTF-8, the usual case, is taken as it is, not copied.
                    texts.push(
                        String::from_utf8(bytes).unwrap_or_else(|e| String::from_utf8_lossy(e.as_bytes()).into_owned()),
                    );
                    sheets.push(path);
                }
                Err(CoreError::TooLarge { detail, .. }) => {
                    skipped.push(format!("{path}: past the {STYLE_BYTES} bytes read ({detail})"));
                }
                Ok(None) => skipped.push(format!("{path}: not found")),
                Err(e @ CoreError::SourceChanged { .. }) => return Err(e),
                Err(e) => skipped.push(format!("{path}: {e}")),
            }
        }
        // The base is measured on a fixed, evenly spaced sample of the edition's entries (ADR-0010 d.4): the same
        // whichever entry is opened first. A record too large or unreadable is passed over.
        let mut entries = Vec::new();
        let count = opened.mdx.len();
        let step = (count / CALIBRATION_ENTRIES).max(1);
        for i in (0..count).step_by(step).take(CALIBRATION_ENTRIES) {
            if opened.mdx.record_size(i).is_ok_and(|n| n <= CALIBRATION_BYTES)
                && opened.mdx.record_read_size(i).is_ok_and(|n| n <= CALIBRATION_BLOCK_BYTES)
                && let Ok(record) = opened.mdx.record(i)
            {
                let text = String::from_utf8_lossy(&record.data);
                if !text.trim_start().starts_with("@@@LINK=") {
                    entries.push(opened.sheet.apply(&text).into_owned());
                }
            }
        }
        opened.mdx_source.unchanged()?;
        // The base is measured under the sheets the sample links; if it links none, under all of them.
        let names: std::collections::HashSet<String> =
            entries.iter().flat_map(|e| xdict_entry::linked_sheets(e)).collect();
        let linked: Vec<bool> = sheets.iter().map(|p| names.contains(&xdict_entry::file_name(p))).collect();
        let any = linked.iter().any(|l| *l);
        let mut style = Style::of_linked_edition(
            texts.iter().map(String::as_str).zip(linked.iter().map(|l| *l || !any)),
            entries.iter().map(String::as_str),
        );
        // The names the edition's kept scripts use, so that an element one of them fills is never taken for one that
        // draws nothing (S10): its script files and the sample's inline scripts.
        let scripts = self.edition_scripts(opened)?;
        style.add_scripts(scripts.iter().map(String::as_str));
        style.add_inline_scripts(entries.iter().map(String::as_str));
        let made = Arc::new(EditionStyle { style, sheets, skipped });
        Ok(Arc::clone(opened.style.get_or_init(|| made)))
    }

    /// The text of an edition's scripts that run (Q6): the sidecars' `.js`, then the volumes', within
    /// [`STYLE_BYTES`] together.
    fn edition_scripts(&self, opened: &Dict) -> Result<Vec<String>, CoreError> {
        let mut paths: Vec<String> = Vec::new();
        for (name, _) in &opened.sidecars {
            if name.to_ascii_lowercase().ends_with(".js") {
                paths.push(name.clone());
            }
        }
        for (check, volume) in &opened.mdd {
            check.unchanged()?;
            for key in volume.keys() {
                let key = key?;
                if key.to_ascii_lowercase().ends_with(".js") {
                    let path = key.trim_start_matches('\\').replace('\\', "/");
                    if !paths.iter().any(|p| p.eq_ignore_ascii_case(&path)) {
                        paths.push(path);
                    }
                }
            }
        }
        let (mut texts, mut total) = (Vec::new(), 0usize);
        for path in paths.into_iter().take(STYLE_SHEETS) {
            // As for sheets: one past what is left of the budget is passed over from its declared size, unread.
            match self.find_resource(opened, &path, STYLE_BYTES.saturating_sub(total) as u64) {
                Ok(Some(bytes)) => {
                    total += bytes.len();
                    let text =
                        String::from_utf8(bytes).unwrap_or_else(|e| String::from_utf8_lossy(e.as_bytes()).into_owned());
                    if xdict_entry::script_purpose(&text).is_ok() {
                        texts.push(text);
                    }
                }
                Err(e @ CoreError::SourceChanged { .. }) => return Err(e),
                _ => {}
            }
        }
        Ok(texts)
    }

    /// What the reading style does to an open dictionary: its base size, the fonts it keeps and why, and what
    /// normalizing its own sheets changed (ADR-0010).
    pub fn style_report(&self, dict: String) -> Result<StyleReport, CoreError> {
        guard(|| {
            let opened = self.dict(&dict)?;
            let edition = self.edition_style(&opened)?;
            let mut counts = xdict_entry::Counts::default();
            for path in &edition.sheets {
                if let Some(bytes) = self.find_resource(&opened, path, MAX_RESOURCE_BYTES)? {
                    let text = String::from_utf8_lossy(&bytes);
                    let (_, c) = xdict_entry::css_normalized_within(&text, "", "", &edition.style, usize::MAX)
                        .map_err(|_| CoreError::internal("an unbounded normalization was refused"))?;
                    counts.add(c);
                }
            }
            Ok(StyleReport { version: STYLE, edition: (*edition).clone(), counts })
        })
    }

    /// [`Self::style_report`], flat, for the bindings: what the Library's details pane shows (ADR-0010).
    pub fn reading_style(&self, dict: String) -> Result<ReadingStyle, CoreError> {
        self.style_report(dict).map(|report| ReadingStyle::from(&report))
    }

    /// What the health check finds in an open dictionary's edition (plan-macos-v1 WI-12).
    /// Every record is read once, in file order, and checked (`xdict-health`); `progress` hears records done of all
    /// after each chunk, and answering `false` cancels the check, which then keeps nothing. The report is kept beside
    /// the edition's index under the checker's version, the edition and the package's resource names, so it is made
    /// once per edition and made again when the checker or the resources change. Never synced (ADR-0004).
    pub fn health(&self, dict: String, progress: &dyn Progress) -> Result<Health, CoreError> {
        guard(|| {
            let opened = self.dict(&dict)?;
            let (resources, sidecars) = self.resource_names(&opened)?;
            let name = health_name(&opened.edition, &resources, &sidecars);
            if let Some(region) = self.indexes.get(&name)?
                && region.len() <= crate::health::MAX_KEPT
                && let Some(kept) = crate::health::decode(&region.bytes(0, region.len() as usize)?)
            {
                return Ok(kept);
            }
            let has = |path: &str| {
                let key = xdict_health::resource_key(path);
                let name = key.trim_start_matches('\\');
                resources.contains(&key)
                    || sidecars.contains(name)
                    || name.rsplit('\\').next().is_some_and(|n| sidecars.contains(n))
            };
            let report = xdict_health::check(&opened.mdx, &has, &mut |done, total| progress.progress(done, total))
                .map_err(|stop| match stop {
                    xdict_health::Stop::Cancelled => {
                        CoreError::Cancelled { detail: "the health check was cancelled".into() }
                    }
                    xdict_health::Stop::Read(e) => e.into(),
                })?;
            opened.mdx_source.unchanged()?;
            let health = crate::health::of(&report);
            self.indexes.put(&name, &crate::health::encode(&health))?;
            Ok(health)
        })
    }

    /// The package's resource names as the health check compares them: each volume's keys and each sidecar's name
    /// (and its last segment), in lower case, keys with backslashes.
    fn resource_names(&self, opened: &Dict) -> Result<(HashSet<String>, HashSet<String>), CoreError> {
        let mut keys = HashSet::new();
        for (check, volume) in &opened.mdd {
            check.unchanged()?;
            for key in volume.keys() {
                keys.insert(key?.replace('/', "\\").to_lowercase());
            }
        }
        let mut sidecars = HashSet::new();
        for (name, _) in &opened.sidecars {
            let name = name.replace('\\', "/").to_lowercase();
            if let Some(last) = name.rsplit('/').next() {
                sidecars.insert(last.to_owned());
            }
            sidecars.insert(name.replace('/', "\\"));
        }
        Ok((keys, sidecars))
    }

    /// Whether the package holds a resource, by its path as it travels, as [`Self::resource`] would find it: a
    /// sidecar, or a key in a volume. Nothing is read. A volume that cannot answer counts as holding it, so an
    /// image is never dropped on an error (S13).
    fn holds(&self, opened: &Dict, path: &str) -> bool {
        let travelled = xdict_entry::travelled(path);
        let resolved = travelled.resolved();
        let mut tries = vec![resolved.to_owned()];
        if let Some(cut) = resolved.find(['?', '#']).and_then(|at| resolved.get(..at)) {
            tries.push(cut.to_owned());
        }
        tries.iter().any(|name| {
            opened.sidecars.iter().any(|(n, _)| n.eq_ignore_ascii_case(name)) || {
                let key = format!("\\{}", name.replace('/', "\\"));
                opened.mdd.iter().any(|(_, volume)| volume.find(&key).map_or(true, |found| !found.is_empty()))
            }
        })
    }

    fn find_resource(&self, opened: &Dict, path: &str, ceiling: u64) -> Result<Option<Vec<u8>>, CoreError> {
        for (name, sidecar) in &opened.sidecars {
            if name.eq_ignore_ascii_case(path) {
                let sidecar = sidecar.as_ref().map_err(Clone::clone)?;
                sidecar.unchanged()?;
                let size = sidecar.source.len();
                if size > ceiling {
                    return Err(CoreError::TooLarge {
                        limit: Limit::Body,
                        detail: format!("{path} is {size} bytes, more than {ceiling}"),
                    });
                }
                let mut bytes = buffer(size, path)?;
                read_all(&*sidecar.source, size, IMPORT_CHUNK, |chunk, _, _| {
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
            // The record's size is checked before it is read, as a sidecar's is.
            let Some(&i) = volume.find(&key)?.first() else { continue };
            let size = volume.record_size(i)?;
            if size > ceiling {
                return Err(CoreError::TooLarge {
                    limit: Limit::Body,
                    detail: format!("{path} is {size} bytes, more than {ceiling}"),
                });
            }
            let record = volume.record(i)?;
            check.unchanged()?;
            return Ok(Some(record.data));
        }
        Ok(None)
    }

    /// Joins an edition to a lineage the registry holds, as the reader asked (ADR-0002 decision 3, as amended
    /// 2026-10-14): the edition becomes part of that dictionary. Recorded as the reader's act, never a rewrite, so a
    /// split undoes it. Answers the lineage the edition now has, in lowercase; joining it again changes nothing.
    /// Refused: a lineage that is not a UUID (`Malformed`), an edition no import registered (`NotFound { Edition }`),
    /// and a lineage no edition was ever in (`NotFound { Lineage }`): a join never makes a dictionary.
    pub fn join_lineage(&self, edition: String, lineage: String) -> Result<String, CoreError> {
        guard(|| self.associate(&edition, &lineage, Target::Existing))
    }

    /// Moves an edition out of its lineage, to `new_lineage`: a UUID the shell has just minted, so that a retried split
    /// is the same split, or a lineage the edition had before, the one a join took it from above all, which undoes
    /// that join exactly. Answers the lineage the edition now has, in lowercase; splitting it again changes nothing.
    /// Refused: a lineage that is not a UUID, or that is another dictionary's and never was this edition's, which
    /// would be a join no one asked for (`Malformed`, both); an edition no import registered (`NotFound { Edition }`).
    pub fn split_lineage(&self, edition: String, new_lineage: String) -> Result<String, CoreError> {
        guard(|| self.associate(&edition, &new_lineage, Target::NewOrOwn))
    }

    /// The edition's lineage as the registry holds it now; `None` for an edition no import registered.
    pub fn lineage_of(&self, edition: String) -> Result<Option<String>, CoreError> {
        guard(|| self.registry.lineage(&edition).map_err(registry_error))
    }

    fn associate(&self, edition: &str, lineage: &str, target: Target) -> Result<String, CoreError> {
        let Some(lineage) = lineage_id(lineage) else {
            // The shell's text, bounded: a detail is for a log line.
            let shown: String = lineage.chars().take(64).collect();
            return Err(CoreError::Malformed { detail: format!("{shown:?} is not a lineage, which is a UUID") });
        };
        match self.registry.associate(edition, &lineage, target).map_err(registry_error)? {
            Ok(lineage) => Ok(lineage),
            Err(Refused::Edition) => {
                Err(CoreError::NotFound { what: Missing::Edition, detail: format!("{edition} was never imported") })
            }
            Err(Refused::Lineage) => Err(CoreError::NotFound {
                what: Missing::Lineage,
                detail: format!("no edition was ever in the lineage {lineage}"),
            }),
            Err(Refused::Foreign) => Err(CoreError::Malformed {
                detail: format!(
                    "{lineage} is another dictionary's lineage, which {edition} never had: a split goes to a new \
                     lineage or back to one the edition had, and a join is asked for as one"
                ),
            }),
        }
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

    /// The generation of a lookup: a digest of this core, the dictionaries in their order, the query and the mode,
    /// so a page continues only the lookup it came from (ADR-0007 decision 9). Offsets and limits may change
    /// between pages and are not in it. 32 bits make it a guard against a continuation passed to the wrong
    /// lookup, not a proof: two lookups' generations agree by chance one time in 2^32.
    fn generation(&self, query: &str, dicts: &[String], mode: MatchMode) -> u32 {
        let mut hasher = xxhash_rust::xxh3::Xxh3::new();
        let mut field = |bytes: &[u8]| {
            hasher.update(&(bytes.len() as u64).to_le_bytes());
            hasher.update(bytes);
        };
        field(&self.nonce.to_le_bytes());
        field(query.as_bytes());
        field(&[matches!(mode, MatchMode::Link) as u8]);
        for dict in dicts {
            field(dict.as_bytes());
        }
        hasher.digest() as u32
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
/// Where an edition's health report is kept: by the checker's version, the edition, and a digest of the package's
/// resource names, which a changed volume or sidecar changes.
fn health_name(edition: &str, resources: &HashSet<String>, sidecars: &HashSet<String>) -> String {
    let mut names: Vec<&String> = resources.iter().chain(sidecars.iter()).collect();
    names.sort_unstable();
    let mut hasher = xxhash_rust::xxh3::Xxh3::new();
    for name in names {
        hasher.update(name.as_bytes());
        hasher.update(&[0]);
    }
    // An edition is a scheme and a digest; the name keeps only its letters and digits.
    let edition: String = edition.chars().filter(char::is_ascii_alphanumeric).collect();
    format!("health-{HEALTH}-{edition}-{:016x}", hasher.digest())
}

fn index_name(identity: &[u8; 32], kind: Kind) -> String {
    let kind = if kind == Kind::Mdd { "mdd" } else { "mdx" };
    format!("{}.{kind}.xdidx", xdict_identity::hex(identity))
}

fn registry_error(error: xdict_identity::RegistryError) -> CoreError {
    CoreError::Io { kind: crate::IoKind::Other, detail: format!("the registry: {error}") }
}

/// A lineage in the one form the registry keeps: a UUID, 8-4-4-4-12 hexadecimal digits, in lowercase as the core mints
/// its own (RFC 9562 reads either case: Swift's `UUID` writes capitals). `None` for anything else, the nil UUID
/// included, which no shell mints on purpose.
fn lineage_id(text: &str) -> Option<String> {
    let groups: Vec<&str> = text.split('-').collect();
    let shaped = groups.len() == 5
        && groups.iter().zip([8, 4, 4, 4, 12]).all(|(g, n)| g.len() == n && g.bytes().all(|b| b.is_ascii_hexdigit()));
    let id = text.to_ascii_lowercase();
    (shaped && id != "00000000-0000-0000-0000-000000000000").then_some(id)
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

/// A resolver's hit as it crosses the boundary: its key, how it was found and its problems, by name.
fn boundary_hit(
    file: &File,
    id: &str,
    edition: &str,
    hit: xdict_lookup::Hit,
    occurrence: u32,
) -> Result<Hit, CoreError> {
    let key = file.key(hit.key)?.into_owned();
    let how = match hit.how {
        LookupHow::Exact => How::Exact,
        LookupHow::Folded => How::Folded,
        LookupHow::Unmarked => How::Unmarked,
        LookupHow::Redirect { chain } => How::Redirect { chain: key_names(file, &chain)? },
    };
    let problems = hit.problems.iter().map(|p| hit_problem(file, p)).collect::<Result<_, _>>()?;
    let entry = EntryRef { edition: edition.to_owned(), key: key.clone(), occurrence };
    Ok(Hit { dict: id.to_owned(), entry, headword: key, how, problems })
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

/// An entry with a doctype, so it renders in standards mode; one it already has is kept.
fn with_doctype(html: String, max: usize) -> Result<String, xdict_entry::Exceeded> {
    const DOCTYPE: &str = "<!DOCTYPE html>";
    let has = html.trim_start().get(..9).is_some_and(|w| w.eq_ignore_ascii_case("<!doctype"));
    if has {
        return Ok(html);
    }
    if html.len().saturating_add(DOCTYPE.len()) > max {
        return Err(xdict_entry::Exceeded);
    }
    let mut html = html;
    html.insert_str(0, DOCTYPE);
    Ok(html)
}

/// Whether a resource of this type is a body the view renders: a stylesheet, script or page.
fn renders(mime: &str) -> bool {
    matches!(mime, "text/css" | "text/javascript" | "text/html")
}

/// A resource as the view gets it: a stylesheet, script or page rewritten for the view, resolving against the
/// resource's own directory; anything else, and text that is not UTF-8, as stored. `Exceeded` as soon as it would
/// pass `ceiling`, before a rewrite is all written.
fn served(
    bytes: Vec<u8>,
    mime: &str,
    view: &View,
    dir: &str,
    style: Option<&Style>,
    strip_off_for_tests: bool,
    ceiling: u64,
) -> Result<Vec<u8>, xdict_entry::Exceeded> {
    let max = usize::try_from(ceiling).unwrap_or(usize::MAX);
    if bytes.len() > max {
        return Err(xdict_entry::Exceeded);
    }
    let (base, original) = (view.base_url.as_str(), view.original_style);
    let Ok(text) = std::str::from_utf8(&bytes) else { return Ok(bytes) };
    let rewritten = match mime {
        "text/css" => match style {
            Some(style) => xdict_entry::css_styled_within(text, base, dir, style, original, max)?.0,
            None => xdict_entry::css_text_within(text, base, dir, max)?,
        },
        // Q6 (the owner, 2026-10-15): only a script that makes something work (a fold, a tab) runs; a tracker's, an
        // audio player's and the rest are served empty.
        "text/javascript" => match style.map(|_| xdict_entry::script_purpose(text)) {
            Some(Err(why)) if !strip_off_for_tests => {
                format!("/* XDict does not run this script ({why}): only scripts that make something work do. */")
            }
            _ => xdict_entry::script_text_within(text, base, max)?,
        },
        "text/html" => match style {
            Some(style) => {
                xdict_entry::html_styled_within(text, base, dir, style, strip_off_for_tests, original, max)?.0
            }
            None => xdict_entry::html_text_within(text, base, dir, max)?,
        },
        _ => return Ok(bytes),
    };
    Ok(rewritten.into_bytes())
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

/// The policy the view must enforce: fetches from the view's base, and `data:` for images and fonts; no connection,
/// form, frame, object or worker; inline scripts and `eval` allowed. A base that is a path (the Web's `/x/`) is no
/// CSP source expression, so there the policy names the entry's own origin, which is the entry's alone
/// (`core-api.md` §5.3), and allows every path of it. It is not a sandbox for what a script does, and it does not
/// confine navigations: the shell refuses those itself (ADR-0007 decision 14).
fn csp(base: &str) -> String {
    let base = if base.starts_with('/') { "'self'" } else { base };
    format!(
        "default-src {base}; script-src {base} 'unsafe-inline' 'unsafe-eval'; style-src {base} 'unsafe-inline'; \
         img-src {base} data:; font-src {base} data:; media-src {base}; connect-src 'none'; form-action 'none'; \
         frame-src 'none'; object-src 'none'; worker-src 'none'; base-uri 'none'"
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

impl From<&StyleReport> for ReadingStyle {
    fn from(report: &StyleReport) -> Self {
        use xdict_entry::{BaseFrom, KeptReason};
        let base = report.edition.style.base();
        let base_from = match &base.from {
            BaseFrom::Page { selector } => BaseSource::Page { selector: selector.clone() },
            BaseFrom::Prose { weight } => BaseSource::Prose { weight: *weight },
            BaseFrom::Text { chars, share } => BaseSource::Text { chars: *chars, share: *share },
            BaseFrom::Default => BaseSource::BrowserDefault,
        };
        let fonts = report
            .edition
            .style
            .kept()
            .iter()
            .map(|k| KeptFont {
                family: k.family.clone(),
                reason: match k.reason {
                    KeptReason::PrivateUse => FontReason::PrivateUse,
                    KeptReason::PseudoContent => FontReason::PseudoContent,
                    KeptReason::Phonetic => FontReason::Phonetic,
                },
                selector: k.selector.clone(),
            })
            .collect();
        let c = &report.counts;
        Self {
            version: report.version,
            base_px: base.px,
            base_from,
            fonts,
            sheets: report.edition.sheets.clone(),
            skipped: report.edition.skipped.clone(),
            changes: StyleChanges {
                important: c.important,
                page: c.page,
                family: c.family,
                size: c.size,
                line_height: c.line_height,
                colour: c.colour,
                weight: c.weight,
                space: c.space,
                dropped: c.dropped,
            },
        }
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::indexing_slicing, clippy::panic)]
mod tests {
    use super::*;

    /// The doctype is written into the body's own buffer when it has room, not into a copy of it: the copy of a
    /// 70 MiB body was `entry()`'s peak.
    #[test]
    fn the_doctype_is_added_in_place() {
        let mut html = String::with_capacity(1024);
        html.push_str("<p>x</p>");
        let at = html.as_ptr();
        let out = with_doctype(html, usize::MAX).unwrap();
        assert_eq!(out, "<!DOCTYPE html><p>x</p>");
        assert_eq!(out.as_ptr(), at);
        assert!(with_doctype("<p>x</p>".into(), 20).is_err());
        assert_eq!(with_doctype(" <!doctype html><p>".into(), 0).unwrap(), " <!doctype html><p>");
    }

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

    /// A worker would otherwise fall back to `script-src`, load from the base, and run under the policy of its own
    /// response, which a view serves without one: `connect-src 'none'` would not reach it.
    #[test]
    fn the_policy_starts_no_worker() {
        for base in ["/x/", "xdict://d/"] {
            assert!(csp(base).contains("worker-src 'none'"), "{}", csp(base));
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

    /// A core with `run` open in a one-entry dictionary, its volume holding `mdd` (none when empty) and its
    /// sidecars `sidecars`: the setup the resource tests share.
    fn opened(mdd: &[xdict_mdx_writer::Entry], sidecars: Vec<Location>) -> (Core, String) {
        opened_with("to run", mdd, sidecars)
    }

    /// [`opened`], `run`'s record being `record`.
    fn opened_with(record: &str, mdd: &[xdict_mdx_writer::Entry], sidecars: Vec<Location>) -> (Core, String) {
        use xdict_mdx_writer::{Entry as W, Spec, write};
        let core = Core::new(Config { client_protocol: PROTOCOL, entropy: vec![1; 16], ..Config::default() }).unwrap();
        let source =
            |name: &str, bytes: Vec<u8>| Location::Source { name: name.into(), source: Arc::new(Fixed(bytes)) };
        let mdx = source("a.mdx", write(&Spec::mdx(), &[W::text("run", record)]).unwrap());
        let mdd = if mdd.is_empty() { vec![] } else { vec![source("a.mdd", write(&Spec::mdd(), mdd).unwrap())] };
        let package = Package { mdx, mdd, sidecars };
        core.import(package.clone(), &NoProgress).unwrap();
        let Opened::Ready { dict, .. } = core.open(package).unwrap() else { panic!("not open") };
        (core, dict)
    }

    /// Progress that counts its reports and answers `go`.
    struct Counted {
        asked: AtomicU64,
        go: bool,
    }

    impl Progress for Counted {
        fn progress(&self, _: u64, _: u64) -> bool {
            self.asked.fetch_add(1, Ordering::SeqCst);
            self.go
        }
    }

    /// WI-12: the check reports what the edition holds, is kept per edition and read back without a second pass,
    /// and a cancelled one keeps nothing.
    #[test]
    fn the_health_check_reports_keeps_and_cancels() {
        let sidecar = Location::Source { name: "a.css".into(), source: Arc::new(Fixed(b"b{}".to_vec())) };
        let record = "<link href=\"a.css\"><link href=\"OED.css\">x\u{1}y <a href=\"entry://nowhere\">n</a>";
        let (core, dict) = opened_with(record, &[], vec![sidecar]);
        let stop = Counted { asked: AtomicU64::new(0), go: false };
        let got = core.health(dict.clone(), &stop);
        assert!(matches!(got, Err(CoreError::Cancelled { .. })), "{got:?}");
        let go = Counted { asked: AtomicU64::new(0), go: true };
        let health = core.health(dict.clone(), &go).unwrap();
        assert_eq!(go.asked.load(Ordering::SeqCst), 1, "checked, after a cancellation kept nothing");
        assert_eq!((health.version, health.entries), (HEALTH, 1));
        let kinds: Vec<(FindingKind, u64, Option<&str>)> =
            health.findings.iter().map(|f| (f.kind, f.count, f.name.as_deref())).collect();
        assert_eq!(
            kinds,
            [
                (FindingKind::MissingFile, 1, Some("oed.css")),
                (FindingKind::MissingWords, 1, None),
                (FindingKind::Repaired, 1, None),
            ]
        );
        assert_eq!(health.findings[1].examples[0].key, "run");
        let again = Counted { asked: AtomicU64::new(0), go: true };
        assert_eq!(core.health(dict, &again).unwrap(), health);
        assert_eq!(again.asked.load(Ordering::SeqCst), 0, "read back, not checked again");
    }

    fn view() -> View {
        View { base_url: "xdict://d/".into(), max_body_bytes: 1 << 20, original_style: false }
    }

    /// ADR-0010 Q3: "Original style" is the dictionary's own look for one view, and nothing else moves: the entry and
    /// the sheet it loads keep their declarations, while the strip list, the URL rewrite, the roles and the CSP are
    /// exactly the reading style's.
    #[test]
    fn original_style_keeps_the_dictionarys_look_and_nothing_else() {
        let sidecar = Location::Source {
            name: "side.css".into(),
            source: Arc::new(Fixed(b"body{font-size:14px;margin:0} .p{font-size:12px !important}".to_vec())),
        };
        let record = concat!(
            r#"<style>.q{font-family:Ic;line-height:28px}</style><font color="red">r</font>"#,
            r#"<script>R('x')</script><a href="javascript:R('y')">j</a><!-- c --><img src="gone.png" alt="g">"#,
            r#"<a href="http://e.example/">w</a><span class="x">/ˈrʌn/</span>"#
        );
        let (core, dict) = opened_with(record, &[], vec![sidecar]);
        let entry = |original_style: bool| {
            let at = EntryRef { edition: core_edition(&core, &dict), key: "run".into(), occurrence: 0 };
            core.entry(dict.clone(), at, View { original_style, ..view() }).unwrap()
        };
        let (styled, original) = (entry(false), entry(true));
        assert!(original.html.contains(".q{font-family:Ic;line-height:28px}"), "{}", original.html);
        assert!(original.html.contains(r#"<font color="red">"#), "{}", original.html);
        assert!(!styled.html.contains(".q{font-family:Ic;line-height:28px}"), "{}", styled.html);
        // The strip list, the rewrite, the roles, the CSP: the same.
        for gone in ["R('x')", "javascript:", "<!-- c -->", "gone.png", "\"http://e.example/\""] {
            assert!(!original.html.contains(gone), "{gone} in {}", original.html);
        }
        assert!(original.html.contains(r#"data-xdict-role="pron""#), "{}", original.html);
        assert_eq!(original.csp, styled.csp);
        let sheet = |original_style: bool| match core
            .resource(dict.clone(), "side.css".into(), View { original_style, ..view() })
            .unwrap()
        {
            Resource::Found { bytes, .. } => String::from_utf8(bytes).unwrap(),
            other => panic!("{other:?}"),
        };
        assert_eq!(sheet(true), "body{font-size:14px;margin:0} .p{font-size:12px !important}");
        assert_ne!(sheet(false), sheet(true));
    }

    /// ADR-0010: entries and the sheets they load are normalized by the style the edition's own sheets decide, read
    /// from the sidecars and the volumes alike, and reported.
    #[test]
    fn entries_and_sheets_are_normalized_by_the_editions_style() {
        use xdict_mdx_writer::Entry as W;
        let sidecar = Location::Source {
            name: "side.css".into(),
            source: Arc::new(Fixed(b"body{font-size:14px;margin:0} .p{font-size:12px !important}".to_vec())),
        };
        let icons = br#"@font-face{font-family:Ic;src:url(i.ttf)} .i:before{font-family:Ic;content:"\e900"}"#;
        let record = r#"<style>.q{font-family:Ic;line-height:28px}</style><span class="x">/ˈrʌn/</span>"#;
        let (core, dict) = opened_with(record, &[W::bytes("\\in\\icons.css", icons)], vec![sidecar]);
        let entry = core
            .entry(
                dict.clone(),
                EntryRef { edition: core_edition(&core, &dict), key: "run".into(), occurrence: 0 },
                view(),
            )
            .unwrap();
        // Q6: standards mode; R3: an icon face only where it draws; R5: line heights are the frame's.
        assert!(entry.html.starts_with("<!DOCTYPE html>"), "{}", entry.html);
        assert!(entry.html.contains(".q{font-family:var(--xdict-font)}"), "{}", entry.html);
        assert!(
            entry
                .html
                .contains(r#"<span data-xdict-role="pron" data-xdict-phon data-xdict-phon-system="slash" class="x">"#),
            "{}",
            entry.html
        );
        let Resource::Found { bytes, .. } = core.resource(dict.clone(), "side.css".into(), view()).unwrap() else {
            panic!("missing")
        };
        // A size carries its leading (unification R).
        assert_eq!(
            String::from_utf8(bytes).unwrap(),
            "body{} .p{font-size:var(--xdict-fs-s, 0.875rem) !important;line-height:var(--xdict-leading, 1.6)}"
        );
        let report = core.style_report(dict.clone()).unwrap();
        // What the Library's details pane shows: the same report, flat, as the bindings carry it.
        let shown = core.reading_style(dict).unwrap();
        assert_eq!((shown.version, shown.base_px), (STYLE, 14.0));
        assert_eq!(shown.base_from, BaseSource::Text { chars: 6, share: 1.0 });
        assert_eq!(shown.sheets, ["side.css", "in/icons.css"]);
        assert_eq!(
            (shown.fonts[0].family.as_str(), shown.fonts[0].reason, shown.fonts.len()),
            ("Ic", FontReason::PrivateUse, report.edition.style.kept().len())
        );
        assert_eq!(shown.skipped, report.edition.skipped);
        assert_eq!((shown.changes.page, shown.changes.important, shown.changes.size), (2, 0, 1));
        assert_eq!(report.version, STYLE);
        assert_eq!(report.edition.style.base().px, 14.0);
        assert_eq!(report.edition.sheets, ["side.css", "in/icons.css"]);
        let kept = report.edition.style.kept();
        assert_eq!((kept[0].family.as_str(), kept[0].reason), ("Ic", xdict_entry::KeptReason::PrivateUse));
        assert_eq!((report.counts.page, report.counts.important, report.counts.size), (2, 0, 1));
    }

    /// The strip list (S1–S14) applies unless a core is made with `strip_off_for_tests`, which only the
    /// hostile battery's lab sets, so that its layer runs prove the shell's own layers against live scripts (the
    /// rewriter is compatibility, not the boundary). A core made by default strips.
    #[test]
    fn the_strip_list_applies_unless_the_core_is_made_without_it() {
        use xdict_mdx_writer::{Entry as W, Spec, write};
        let record = concat!(
            r#"<script>R('x')</script><a href="javascript:R('y')">j</a>"#,
            r#"<!-- c --><title>t</title><img src="gone.png" alt="g"><span></span>"#
        );
        let render = |strip_off_for_tests: bool| {
            let config =
                Config { client_protocol: PROTOCOL, entropy: vec![1; 16], strip_off_for_tests, ..Config::default() };
            let core = Core::new(config).unwrap();
            let source = Location::Source {
                name: "a.mdx".into(),
                source: Arc::new(Fixed(write(&Spec::mdx(), &[W::text("run", record)]).unwrap())),
            };
            let mdd = write(
                &Spec::mdd(),
                &[W::bytes("\\doc.html", b"<script>R('z')</script>"), W::bytes("\\a.js", b"R('w')")],
            )
            .unwrap();
            let mdd = Location::Source { name: "a.mdd".into(), source: Arc::new(Fixed(mdd)) };
            let package = Package { mdx: source, mdd: vec![mdd], sidecars: vec![] };
            core.import(package.clone(), &NoProgress).unwrap();
            let Opened::Ready { dict, .. } = core.open(package).unwrap() else { panic!("not open") };
            let entry = EntryRef { edition: core_edition(&core, &dict), key: "run".into(), occurrence: 0 };
            let served = |path: &str| match core.resource(dict.clone(), path.into(), view()).unwrap() {
                Resource::Found { bytes, .. } => String::from_utf8(bytes).unwrap(),
                other => panic!("{path}: {other:?}"),
            };
            let (doc, js) = (served("doc.html"), served("a.js"));
            (core.entry(dict.clone(), entry, view()).unwrap().html, doc, js)
        };
        let (entry, doc, js) = render(false);
        assert!(!entry.contains("R('x')") && !entry.contains("javascript:"), "{entry}");
        // S2 comments, S3 a title, S13 an image the package lacks: the strip list's other removals.
        assert!(!entry.contains("<!-- c -->") && !entry.contains("<title>") && !entry.contains("gone.png"), "{entry}");
        assert!(!doc.contains("R('z')") && !js.contains("R('w')"), "{doc} {js}");
        let (entry, doc, js) = render(true);
        assert!(entry.contains("<script>R('x')</script>") && entry.contains("javascript:R('y')"), "{entry}");
        assert!(
            entry.contains("<!-- c -->") && entry.contains("<title>t</title>") && entry.contains("gone.png"),
            "{entry}"
        );
        assert!(doc.contains("R('z')") && js.contains("R('w')"), "{doc} {js}");
        assert!(!Config::default().strip_off_for_tests);
    }

    fn core_edition(core: &Core, dict: &str) -> String {
        core.dict(dict).unwrap().edition.clone()
    }

    /// Suggestions are bounded as a page is: a shell asking for more than [`MAX_SUGGEST`] is refused before any key
    /// is read, as `lookup` refuses more than [`MAX_PAGE`] (Codex objection 2 on the macOS contract, 2026-10-14).
    #[test]
    fn suggestions_are_bounded_as_a_page_is() {
        let (core, dict) = opened(&[], vec![]);
        assert_eq!(core.suggest("r".into(), vec![dict.clone()], MAX_SUGGEST).unwrap(), vec!["run".to_owned()]);
        let refused = core.suggest("r".into(), vec![dict.clone()], MAX_SUGGEST + 1);
        assert!(matches!(refused, Err(CoreError::TooLarge { limit: Limit::Page, .. })), "{refused:?}");
        let most = core.suggest(String::new(), vec![dict], u32::MAX);
        assert!(matches!(most, Err(CoreError::TooLarge { limit: Limit::Page, .. })), "{most:?}");
    }

    /// A source that calls back into the core when it is dropped, as a shell's source may (a JavaScript object's
    /// finaliser, a Swift `deinit`).
    struct Reentrant(Vec<u8>, Arc<std::sync::OnceLock<std::sync::Weak<Core>>>);

    impl crate::ByteSource for Reentrant {
        fn size(&self) -> u64 {
            self.0.len() as u64
        }
        fn read_at(&self, offset: u64, len: u32) -> Result<Vec<u8>, CoreError> {
            Ok(self.0[offset as usize..offset as usize + len as usize].to_vec())
        }
        fn identity(&self) -> Option<FileIdentity> {
            Some(FileIdentity { device: 1, inode: 3, size: self.0.len() as u64, mtime_ns: 0, ctime_ns: 0 })
        }
    }

    impl Drop for Reentrant {
        fn drop(&mut self) {
            if let Some(core) = self.1.get().and_then(std::sync::Weak::upgrade) {
                let options = LookupOptions { limit: 1, offset: 0, mode: MatchMode::Reader, generation: None };
                let _ = core.lookup("run".into(), vec![], options);
            }
        }
    }

    /// Closing the last reference to a dictionary drops the shell's sources after the core's lock is released, so
    /// a source that calls the core from its destructor does not deadlock it.
    #[test]
    fn a_source_may_call_the_core_as_it_is_dropped() {
        use xdict_mdx_writer::{Entry as W, Spec, write};
        let core = Arc::new(Core::new(Config { client_protocol: PROTOCOL, ..Config::default() }).unwrap());
        let back = Arc::new(std::sync::OnceLock::new());
        let bytes = write(&Spec::mdx(), &[W::text("run", "to run")]).unwrap();
        let mdx = Location::Source { name: "a.mdx".into(), source: Arc::new(Reentrant(bytes, back.clone())) };
        let package = Package { mdx, mdd: vec![], sidecars: vec![] };
        core.import(package.clone(), &NoProgress).unwrap();
        let Opened::Ready { dict, .. } = core.open(package).unwrap() else { panic!("not open") };
        back.set(Arc::downgrade(&core)).unwrap();
        let (done, finished) = std::sync::mpsc::channel();
        let closing = core.clone();
        std::thread::spawn(move || done.send(closing.close(dict)).unwrap());
        let closed = finished.recv_timeout(std::time::Duration::from_secs(10));
        assert!(matches!(closed, Ok(Ok(()))), "close deadlocked or failed: {closed:?}");
    }

    /// The limit is checked against the size the source declares, before anything is read or allocated.
    #[test]
    fn a_resource_over_the_limit_is_refused_before_it_is_read() {
        let huge = Location::Source { name: "huge.css".into(), source: Arc::new(Huge) };
        let (core, dict) = opened(&[], vec![huge]);
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

    /// Codex objection 4: the edition and the index come from the same bytes, or the import fails.
    /// A stylesheet, script or page is a body the view renders, so the view's ceiling holds for it, rewritten; an
    /// image or a recording is not, and is served whole.
    #[test]
    fn a_rewritten_resource_is_held_to_the_views_ceiling() {
        use xdict_mdx_writer::Entry as W;
        let css = "b { background: url(a.png) }\n".repeat(100);
        let (core, dict) = opened(&[W::bytes("\\big.css", css.as_bytes()), W::bytes("\\big.png", &[7; 4000])], vec![]);
        let view = View { base_url: "xdict://d/".into(), max_body_bytes: 2000, original_style: false };
        let css = core.resource(dict.clone(), "big.css".into(), view.clone());
        assert!(matches!(css, Err(CoreError::TooLarge { limit: Limit::Body, .. })), "{:?}", css.map(|_| "found"));
        let png = core.resource(dict, "big.png".into(), view);
        assert!(matches!(&png, Ok(Resource::Found { bytes, .. }) if bytes.len() == 4000), "{:?}", png.map(|_| "found"));
    }

    /// A stylesheet that is not UTF-8 is served as stored, but it is still a body the view renders: the view's
    /// ceiling holds for it, and is checked from the declared size, before the read.
    #[test]
    fn a_text_resource_is_held_to_the_views_ceiling_before_it_is_read_whatever_its_encoding() {
        use xdict_mdx_writer::Entry as W;
        let read = Arc::new(std::sync::atomic::AtomicU64::new(0));
        let sidecar = Location::Source {
            name: "side.css".into(),
            source: Arc::new(Counting("b { color: red }\n".repeat(200).into_bytes(), read.clone())),
        };
        let (core, dict) = opened(&[W::bytes("\\gbk.css", &[0xB0; 3000])], vec![sidecar]);
        let view = View { base_url: "xdict://d/".into(), max_body_bytes: 2000, original_style: false };
        let gbk = core.resource(dict.clone(), "gbk.css".into(), view.clone());
        assert!(matches!(gbk, Err(CoreError::TooLarge { limit: Limit::Body, .. })), "{:?}", gbk.map(|_| "found"));
        read.store(0, std::sync::atomic::Ordering::SeqCst);
        let side = core.resource(dict, "side.css".into(), view);
        assert!(matches!(side, Err(CoreError::TooLarge { limit: Limit::Body, .. })), "{:?}", side.map(|_| "found"));
        assert_eq!(read.load(std::sync::atomic::Ordering::SeqCst), 0, "the stylesheet was read before it was refused");
    }

    /// Claims one size at first and a far larger one after, counting the bytes read through it.
    struct Growing(std::sync::atomic::AtomicU64, Arc<std::sync::atomic::AtomicU64>);

    impl crate::ByteSource for Growing {
        fn size(&self) -> u64 {
            if self.0.fetch_add(1, std::sync::atomic::Ordering::SeqCst) == 0 { 100 } else { 1 << 30 }
        }
        fn read_at(&self, _: u64, len: u32) -> Result<Vec<u8>, CoreError> {
            self.1.fetch_add(u64::from(len), std::sync::atomic::Ordering::SeqCst);
            Ok(vec![b'x'; len as usize])
        }
        fn identity(&self) -> Option<FileIdentity> {
            None
        }
    }

    /// A sidecar is read to the size its ceiling was checked against, and one whose size moves in between is
    /// `SourceChanged`, not read to whatever it claims next.
    #[test]
    fn a_sidecar_that_grows_after_its_size_is_checked_is_not_read_past_it() {
        let read = Arc::new(std::sync::atomic::AtomicU64::new(0));
        let growing = Arc::new(Growing(std::sync::atomic::AtomicU64::new(0), read.clone()));
        let sidecar = Location::Source { name: "grow.png".into(), source: growing.clone() };
        let (core, dict) = opened(&[], vec![sidecar]);
        growing.0.store(0, std::sync::atomic::Ordering::SeqCst);
        read.store(0, std::sync::atomic::Ordering::SeqCst);
        let got = core.resource(dict, "grow.png".into(), View { max_body_bytes: 2000, ..view() });
        assert!(matches!(got, Err(CoreError::SourceChanged { .. })), "{:?}", got.map(|_| "found"));
        assert!(read.load(std::sync::atomic::Ordering::SeqCst) <= 100, "read past the checked size");
    }

    /// A page served from a folder resolves its links against that folder, as a stylesheet does.
    #[test]
    fn a_page_resolves_against_its_own_folder() {
        use xdict_mdx_writer::Entry as W;
        let (core, dict) = opened(&[W::bytes("\\help\\page.html", br#"<img src="image.png">"#)], vec![]);
        let Ok(Resource::Found { bytes, .. }) = core.resource(dict, "help/page.html".into(), view()) else {
            panic!("not found")
        };
        let page = String::from_utf8(bytes).unwrap();
        assert!(page.contains("xdict://d/r/help/image.png"), "{page}");
    }

    /// A sidecar that cannot be opened is reported when it is asked for, not passed over for a volume's copy.
    #[test]
    fn an_unreadable_sidecar_is_reported_when_asked_for() {
        use xdict_mdx_writer::Entry as W;
        let gone = std::env::temp_dir().join(format!("xdict-no-such-{}", std::process::id())).join("a.css");
        let sidecar = Location::Path { path: gone.to_string_lossy().into_owned() };
        let (core, dict) = opened(&[W::bytes("\\a.css", b"b { color: red }")], vec![sidecar]);
        let css = core.resource(dict, "a.css".into(), view());
        assert!(matches!(css, Err(CoreError::NotFound { what: Missing::File, .. })), "{:?}", css.map(|_| "found"));
        // An MDX that is not there is the same: a file the package names, missing.
        let gone = Location::Path { path: gone.to_string_lossy().into_owned() };
        let result = core.import(Package { mdx: gone, mdd: vec![], sidecars: vec![] }, &NoProgress);
        assert!(matches!(result, Err(CoreError::NotFound { what: Missing::File, .. })), "{result:?}");
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

    /// The import asks its progress once more just before it registers: `false` there is a cancellation that
    /// registers nothing, so the location is still new.
    #[test]
    fn a_cancellation_at_the_last_report_registers_nothing() {
        use xdict_mdx_writer::{Entry as W, Spec, write};
        struct AtTheEnd(std::sync::atomic::AtomicU32);
        impl Progress for AtTheEnd {
            fn progress(&self, done: u64, total: u64) -> bool {
                done < total || self.0.fetch_add(1, std::sync::atomic::Ordering::SeqCst) == 0
            }
        }
        let core = Core::new(Config { client_protocol: PROTOCOL, ..Config::default() }).unwrap();
        let bytes = write(&Spec::mdx(), &[W::text("run", "to move")]).unwrap();
        let mdx = Location::Source { name: "a.mdx".into(), source: Arc::new(Fixed(bytes)) };
        let package = Package { mdx, mdd: vec![], sidecars: vec![] };
        let got = core.import(package.clone(), &AtTheEnd(0.into()));
        assert!(matches!(got, Err(CoreError::Cancelled { .. })), "{got:?}");
        assert_eq!(core.open(package).unwrap(), Opened::NeedsImport { reason: ImportReason::New });
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
        let bytes = write(&Spec::mdx(), &[W::text("runaway", "to move")]).unwrap();
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

        // The key text, a checksummed section, found by what it holds rather than where today's layout puts it
        // (padding between sections is in no checksum, and changing it changes nothing).
        let mut damaged = std::fs::read(&index).unwrap();
        let at: Vec<usize> = damaged.windows(7).enumerate().filter(|(_, w)| *w == b"runaway").map(|(i, _)| i).collect();
        assert_eq!(at.len(), 1, "the key text, once");
        damaged[at[0]] ^= 1;
        // An index is written read-only; damage it in place and make it read-only again, so that what refuses it
        // is the checksum, not its mode.
        #[cfg(unix)]
        let set_mode = |mode| {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&index, std::fs::Permissions::from_mode(mode)).unwrap();
        };
        #[cfg(unix)]
        set_mode(0o600);
        std::fs::write(&index, damaged).unwrap();
        #[cfg(unix)]
        set_mode(0o400);
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

    /// A walk's problems travel with its first hit; a page that leaves that hit out gives them as the page's own,
    /// so no page loses a problem of its lookup (with `limit` 0, every one is the page's).
    #[test]
    fn a_page_without_a_walks_first_hit_keeps_its_problems() {
        use xdict_mdx_writer::Entry as W;
        let (core, dict, _) =
            counted(&[W::text("a", "@@@LINK=b\r\n@@@LINK=gone"), W::text("b", "first"), W::text("b", "second")]);
        let page = |offset, limit| {
            let options = LookupOptions { limit, offset, mode: MatchMode::Reader, generation: None };
            core.lookup("a".into(), vec![dict.clone()], options).unwrap()
        };
        let dangling = |p: &[HitProblem]| p.iter().filter(|p| matches!(p, HitProblem::DanglingRedirect { .. })).count();
        let all = page(0, 10);
        assert_eq!(all.hits.len(), 2, "{all:?}");
        let on_hits = |p: &Page| p.hits.iter().map(|h| dangling(&h.problems)).sum::<usize>();
        assert_eq!(on_hits(&all) + dangling(&all.problems), 1, "{all:?}");
        for (offset, limit) in [(1, 1), (0, 0), (0, 1)] {
            let p = page(offset, limit);
            assert_eq!(on_hits(&p) + dangling(&p.problems), 1, "offset {offset}, limit {limit}: {p:?}");
        }
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
            let mut generation = None;
            let mut all = Vec::new();
            loop {
                let options =
                    LookupOptions { limit: 1000, offset: all.len() as u32, mode: MatchMode::Reader, generation };
                let page = core.lookup("EC".into(), vec![dict.to_owned()], options).unwrap();
                assert_eq!(page.total, u64::from(n));
                // Each page continues with the generation the first one gave.
                assert!(generation.is_none_or(|g| g == page.generation));
                generation = Some(page.generation);
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

    /// A page's generation continues only the lookup it came from: the same dictionaries in the same order, the
    /// same query and mode. Opening another dictionary does not disturb it; changing any of those does.
    #[test]
    fn a_continuation_belongs_to_its_own_lookup() {
        use xdict_mdx_writer::{Entry as W, Spec, write};
        let core = Core::new(Config { client_protocol: PROTOCOL, ..Config::default() }).unwrap();
        let open = |name: &str, entries: &[W]| {
            let bytes = write(&Spec::mdx(), entries).unwrap();
            let mdx = Location::Source { name: name.into(), source: Arc::new(Fixed(bytes)) };
            let package = Package { mdx, mdd: vec![], sidecars: vec![] };
            core.import(package.clone(), &NoProgress).unwrap();
            let Opened::Ready { dict, .. } = core.open(package).unwrap() else { panic!("not open") };
            dict
        };
        let a = open("a.mdx", &[W::text("run", "a")]);
        let b = open("b.mdx", &[W::text("run", "b"), W::text("run", "bb")]);
        let options = |offset, mode, generation| LookupOptions { limit: 1, offset, mode, generation };
        let first = core.lookup("run".into(), vec![a.clone(), b.clone()], options(0, MatchMode::Reader, None)).unwrap();
        let g = Some(first.generation);
        let _c = open("c.mdx", &[W::text("run", "c")]);
        assert!(core.lookup("run".into(), vec![a.clone(), b.clone()], options(1, MatchMode::Reader, g)).is_ok());
        let stale = |r: Result<Page, CoreError>| matches!(r, Err(CoreError::StaleHandle { .. }));
        assert!(stale(core.lookup("run".into(), vec![b.clone(), a.clone()], options(1, MatchMode::Reader, g))));
        assert!(stale(core.lookup("run".into(), vec![a.clone()], options(1, MatchMode::Reader, g))));
        assert!(stale(core.lookup("ran".into(), vec![a.clone(), b.clone()], options(1, MatchMode::Reader, g))));
        assert!(stale(core.lookup("run".into(), vec![a, b], options(1, MatchMode::Link, g))));
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
