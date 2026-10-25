//! The [`Core`]: one per process, thread-safe, every call guarded so that no panic crosses the boundary.
//!
//! **No lock is held while the shell's code runs**: a `ByteSource`, a `Progress` callback, or a read through
//! either, so a callback may call back into the core without deadlocking (Codex objection 9).

use std::collections::{HashMap, HashSet};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};

use xdict_entry::{Style, StyleSheet};
#[cfg(not(target_family = "wasm"))]
use xdict_ledger::FileStore;
/// **A sync pass is a native shell's** (plan §2.6): the Web has no folder to merge through, so the type is unused there.
#[cfg(not(target_family = "wasm"))]
use xdict_ledger::SyncReport;
use xdict_ledger::{
    CardConflict, CardState, Compaction, DictionaryJoined, DictionarySplit, EraseReport, Frontier, GradeRecord,
    History, Ledger, MemoryStore, Note, Reading, ReanchorOutcome, ReanchorRecord, ReanchorReport, ReanchorResult,
    RecordOutcome, Removal, ResolutionRecord, ReviewOutcome, ReviewPolicy, ReviewSummary, ScheduleConfiguration, Stamp,
    Store, StudyCard, StudyGrade, StudyPhase, StudyTarget, TargetKind, UndoRecord,
};
use xdict_lookup::{How as LookupHow, Mode, Policy, Problem as LookupProblem};
use xdict_mdx::index::{Derive, Plain, Region};
use xdict_mdx::{Budget, File, Kind};
use xdict_schedule::{
    Card as ScheduleCard, DEFAULT_WEIGHTS, Grade as ScheduleGrade, Phase as SchedulePhase, Scheduler,
    VERSION as SCHEDULE_VERSION,
};

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

/// **A peer log over this size is refused, not read** (plan §2.6): a year of readings on a device that checks a hundred
/// words a day is far under it, and a stray file in the reader's sync folder must not exhaust the service.
#[cfg(not(target_family = "wasm"))]
pub const MAX_SYNC_BYTES: u64 = 256 * 1_024 * 1_024;

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
    /// Where the reading history's log lives; `None` keeps it in memory (the tests, the Web).
    ledger_path: Option<PathBuf>,
    /// Opened on first use; one writer for the process (ADR-0024).
    ledger: Mutex<Option<Ledger>>,
}

struct State {
    random: SplitMix,
    next_handle: u32,
    open: HashMap<u32, Arc<Dict>>,
    /// Phrase matchers by store name, decoded and indexed once per open edition and retained (plan WI-4; the
    /// refutation's objection 10: the examples store's per-call decode is not this).
    phrase_matchers: HashMap<String, Arc<xdict_phrase::Matcher>>,
    /// Editions whose inventory build failed: terminal until a build succeeds, never a perpetual "building".
    phrase_failures: HashSet<String>,
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
    /// The display options that apply to the edition (ADR-0013), read once, on first use.
    options: OnceLock<DisplayOptions>,
}

/// The version of the reading style's rules (ADR-0010): raised with any change to what normalization writes.
pub const STYLE: u32 = xdict_entry::STYLE;
/// The display options catalogue's version (ADR-0013): raised with any change to an option, a value or its CSS.
pub const DISPLAY_OPTIONS: u32 = xdict_entry::DISPLAY_OPTIONS;
/// The most sheets an edition's style is read from, and the most bytes in all.
const STYLE_SHEETS: usize = 256;
const STYLE_BYTES: usize = 32 << 20;
/// The entries an edition's base size is measured on, and the largest record read for it.
const CALIBRATION_ENTRIES: usize = 64;
const CALIBRATION_BYTES: u64 = 256 << 10;
/// The most a sampled entry's read may decompress: a short entry in a block shared with a huge one is passed over.
const CALIBRATION_BLOCK_BYTES: u64 = 8 << 20;
/// The ceiling on one entry the examples pass renders, and the text budget its projection reads (ADR-0031 d.3, d.6).
const EXAMPLES_TEXT_BYTES: usize = 16 << 20;
/// Entries read for the "does this edition carry Chinese at all" test, evenly spaced (ADR-0031 d.6).
const EXAMPLES_SAMPLE: usize = 64;
/// Records between progress reports in the examples pass: a check of the cancellation flag and one event.
const EXAMPLES_REPORT: usize = 1024;
/// The most text one word catalog keeps: every headword once, and each source's handle, edition and key. A budget
/// of the catalog's text, not a cap on peak memory: while it is built, the maps that place headwords and count
/// occurrences, and the allocations around them, come on top, bounded by the key entries counted. The scratch maps
/// (every distinct key, internal ones included) are held to this same bound, so they cannot grow unbudgeted (audit,
/// 2026-10-24).
const CATALOG_BYTES: u64 = crate::words::MAX_CATALOG_TEXT_BYTES;
/// Key entries read between two of a word catalog's progress reports, so one huge dictionary is still paced.
const CATALOG_PROGRESS_STEP: usize = 4_096;

/// An edition's reading style and the sheets it was read from.
#[derive(Debug, Clone)]
pub struct EditionStyle {
    pub style: Style,
    /// The sheets read, by path.
    pub sheets: Vec<String>,
    /// Sheets not read, and why: never passed over silently.
    pub skipped: Vec<SkippedSheet>,
}

/// What the normalization does to one edition, for the gallery and the About pane (ADR-0010).
#[derive(Debug, Clone)]
pub struct StyleReport {
    pub version: u32,
    pub edition: EditionStyle,
    /// What normalizing the edition's own sheets changed.
    pub counts: xdict_entry::Counts,
}

/// What reading an edition's sheets produced: the texts kept, their paths, and the sheets passed over and why.
type SheetSet = (Vec<String>, Vec<String>, Vec<SkippedSheet>);

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
                open: HashMap::new(),
                phrase_matchers: HashMap::new(),
                phrase_failures: HashSet::new(),
            };
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
            let ledger_path = config.data_dir.as_ref().map(|dir| Path::new(dir).join("ledger").join("history.log"));
            Ok(Self {
                nonce,
                strip_off_for_tests: config.strip_off_for_tests,
                state: Mutex::new(state),
                indexes,
                registry,
                ledger_path,
                ledger: Mutex::new(None),
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
            let dict = Dict {
                edition: record.edition.clone(),
                mdx_source,
                mdx,
                mdd,
                sidecars,
                sheet,
                style: OnceLock::new(),
                options: OnceLock::new(),
            };
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
            let mut state = self.lock()?;
            let removed = state.open.remove(&handle);
            if let Some(dict) = removed.as_ref() {
                // **An edition's matcher goes with its last open handle** (plan WI-4): two handles can name one
                // edition, and closing one must not take the matcher the other still answers from.
                if !state.open.values().any(|other| other.edition == dict.edition) {
                    state.phrase_matchers.remove(&crate::phrases::store_name(&dict.edition));
                }
            }
            drop(state);
            drop(removed);
            Ok(())
        })
    }

    /// Looks `query` up in `dicts`, in that order, and returns one page of references.
    pub fn lookup(&self, query: String, dicts: Vec<String>, options: LookupOptions) -> Result<Page, CoreError> {
        guard(|| self.lookup_within(&query, &dicts, options, Budget::new(LOOKUP_BYTES, LOOKUP_CANDIDATES)))
    }

    /// **One dictionary's words, a page at a time** (plan-setup-v2 WI-6, ADR-0028): `from` is a key position in the
    /// key block's order, and the page holds the public keys at and after it. An internal key is passed over by the
    /// index's own classification, never by a guess about its spelling.
    ///
    /// **One item per key entry, and a spelling may repeat** — a key block is not always sorted, so a repeated word is
    /// not always its neighbour (measured: "ACTH" twice, far apart, in the corpus's `ahd`). The consumer keys its items
    /// by the word, so a spelling reaches the index once; asking this call to do that would need a set the size of the
    /// dictionary held across pages.
    ///
    /// **A word is not always one a reader can type**: a public key may be punctuation alone (the corpus's `ahd` has
    /// `,`), which a reader-mode lookup folds away and finds nothing for. What to show is the consumer's decision —
    /// this call names the keys the index holds, whatever they are.
    ///
    /// **No body is read**: the words come from the index, so a page costs no decompression and the ceiling on a page
    /// is the caller's to pace. `total` counts key entries, not pages, so a caller pages until `from` reaches it.
    pub fn words(&self, dict: String, from: u64, limit: u32) -> Result<Words, CoreError> {
        guard(|| {
            if limit > MAX_PAGE {
                return Err(CoreError::TooLarge {
                    limit: Limit::Page,
                    detail: format!("a page holds at most {MAX_PAGE} words, {limit} were asked"),
                });
            }
            let opened = self.dict(&dict)?;
            // The file is checked before it is read, as a lookup checks it: words read from a file rewritten meanwhile
            // are never answered from the old index.
            opened.mdx_source.unchanged()?;
            let mdx = &opened.mdx;
            let total = mdx.len() as u64;
            let mut words: Vec<String> = Vec::new();
            let mut i = usize::try_from(from).unwrap_or(usize::MAX);
            while i < mdx.len() && words.len() < limit as usize {
                if mdx.is_public(i)? {
                    words.push(mdx.key(i)?.into_owned());
                }
                i += 1;
            }
            Ok(Words { edition: opened.edition.clone(), words, total, next: i as u64 })
        })
    }

    /// **The word catalog** (2026-10-24, word exploration): every public headword of `dicts`, each with every place
    /// it is keyed, as an immutable, edition-qualified [`crate::words::WordExplorer`]. Read from the indexes alone.
    ///
    /// **One headword per exact spelling** (`Alpha` is not `alpha`), its sources in the order `dicts` names the
    /// dictionaries and then in key-block order. A source's occurrence is its place among the keys spelt exactly as
    /// it is, in file order, as [`Core::entry`] counts it, wherever in the key block the repeats are. A handle named
    /// twice is read once, at its first place; two handles to one edition are two dictionaries.
    ///
    /// **Refused whole, never truncated**: a handle that does not resolve, one closed while a callback ran, a file
    /// changed meanwhile, or more than [`crate::words::MAX_CATALOG_ENTRIES`] key entries in all or
    /// `CATALOG_BYTES` of text, which is `TooLarge` with [`Limit::File`]. A public key longer than 4 KiB in UTF-8 is
    /// not refused: the explorer skips it with its sources and counts it in
    /// [`crate::words::WordStats::skipped_headwords`], its text still counted toward the byte bound.
    ///
    /// **Progress counts key entries**, internal ones included, of each dictionary once: a report every
    /// `CATALOG_PROGRESS_STEP` entries and at the end of each dictionary, the last one `(total, total)`. No lock is
    /// held while a callback runs, so it may call the core, closing a dictionary included.
    pub fn word_explorer(
        &self,
        dicts: Vec<String>,
        progress: &dyn Progress,
    ) -> Result<crate::words::WordExplorer, CoreError> {
        guard(|| self.word_explorer_within(&dicts, progress, CatalogLimits::DEFAULT))
    }

    /// [`Self::word_explorer`], holding no more than `limits` allows.
    fn word_explorer_within(
        &self,
        dicts: &[String],
        progress: &dyn Progress,
        limits: CatalogLimits,
    ) -> Result<crate::words::WordExplorer, CoreError> {
        use crate::words::{WordCatalogEntry, WordExplorer, WordSource};
        // Every handle resolved before anything is read, each once and in its canonical spelling: the dictionaries
        // are held by `Arc`, so no lock is held while they are read.
        let mut named = HashSet::new();
        let mut snapshot: Vec<(String, Arc<Dict>)> = Vec::new();
        for dict in dicts {
            let handle = self.parse_handle(dict)?;
            if named.insert(handle) {
                snapshot.push((self.handle(handle), self.dict(dict)?));
            }
        }
        let mut total: u64 = 0;
        for (dict, opened) in &snapshot {
            let keys = opened.mdx.len() as u64;
            total = total.checked_add(keys).filter(|&t| t <= limits.entries).ok_or_else(|| {
                catalog_too_large(format!(
                    "{dict} brings the catalog's key entries past {}; a word catalog holds no more",
                    limits.entries
                ))
            })?;
        }
        let report = |done: u64| {
            if progress.progress(done, total) {
                Ok(())
            } else {
                Err(CoreError::Cancelled { detail: "the word catalog was cancelled".into() })
            }
        };
        let mut catalog: Vec<WordCatalogEntry> = Vec::new();
        let mut placed: HashMap<String, usize> = HashMap::new();
        let mut bytes: u64 = 0;
        let mut scratch: u64 = 0;
        let mut done: u64 = 0;
        for (position, (dict, opened)) in snapshot.iter().enumerate() {
            let last = position + 1 == snapshot.len();
            opened.mdx_source.unchanged()?;
            let mdx = &opened.mdx;
            // Every key counted, internal ones too, so an occurrence is the one `render` finds.
            let mut counted: HashMap<String, u32> = HashMap::new();
            let mut until_report = CATALOG_PROGRESS_STEP;
            for i in 0..mdx.len() {
                let key = mdx.key(i)?;
                let occurrence = match counted.get_mut(&*key) {
                    Some(n) => {
                        let at = *n;
                        *n = n.checked_add(1).ok_or_else(|| {
                            catalog_too_large(format!("{dict} has more than {} records under one key", u32::MAX))
                        })?;
                        at
                    }
                    None => {
                        // **Every distinct key's text is bounded**, internal ones included: they are held in the scratch
                        // map even when no public key uses them (audit, 2026-10-24).
                        scratch = scratch.checked_add(key.len() as u64).filter(|&b| b <= limits.bytes).ok_or_else(|| {
                            catalog_too_large(format!(
                                "{dict} brings the catalog's scratch text past {} bytes; a word catalog holds no more",
                                limits.bytes
                            ))
                        })?;
                        counted.insert(key.clone().into_owned(), 1);
                        0
                    }
                };
                if mdx.is_public(i)? {
                    let at = placed.get(&*key).copied();
                    let headword = if at.is_some() { 0 } else { key.len() };
                    let grown = (dict.len() + opened.edition.len() + key.len() + headword) as u64;
                    bytes = bytes.checked_add(grown).filter(|&b| b <= limits.bytes).ok_or_else(|| {
                        catalog_too_large(format!(
                            "{dict} brings the catalog's text past {} bytes; a word catalog holds no more",
                            limits.bytes
                        ))
                    })?;
                    let entry = EntryRef { edition: opened.edition.clone(), key: key.clone().into_owned(), occurrence };
                    let source = WordSource { dict: dict.clone(), entry };
                    match at {
                        Some(at) => catalog
                            .get_mut(at)
                            .ok_or_else(|| CoreError::internal("a placed headword is not in the catalog"))?
                            .sources
                            .push(source),
                        None => {
                            placed.insert(key.clone().into_owned(), catalog.len());
                            catalog.push(WordCatalogEntry { headword: key.into_owned(), sources: vec![source] });
                        }
                    }
                }
                done += 1;
                until_report -= 1;
                if until_report == 0 && i + 1 < mdx.len() {
                    until_report = CATALOG_PROGRESS_STEP;
                    report(done)?;
                }
            }
            opened.mdx_source.unchanged()?;
            // **The last dictionary's (total, total) is reported after the explorer is built**, so no caller reads it as
            // completion before the explorer can answer; the other dictionaries report at their own end (audit,
            // 2026-10-24).
            if !last {
                report(done)?;
            }
        }
        // After the last callback, which may have closed a dictionary or rewritten any file already read: a catalog
        // naming a closed one is refused, never answered from the `Arc`, and one read from a file since changed is
        // not an answer about the file.
        for (dict, opened) in &snapshot {
            if !Arc::ptr_eq(&self.dict(dict)?, opened) {
                return Err(CoreError::stale(format!("{dict} was reopened while its words were read")));
            }
            opened.mdx_source.unchanged()?;
        }
        let explorer = WordExplorer::new(catalog, None).map_err(word_error)?;
        // **The last report comes after the explorer's indexes are built**, so a caller that shows completion at the
        // callback does not show it before the explorer can answer; a cancel here discards it (audit, 2026-10-24).
        report(done)?;
        // **The completion callback runs code too**: one that closes a dictionary or rewrites a file since read is
        // caught here, as the per-dictionary reports are (audit, 2026-10-24).
        for (dict, opened) in &snapshot {
            if !Arc::ptr_eq(&self.dict(dict)?, opened) {
                return Err(CoreError::stale(format!("{dict} was reopened while its words were read")));
            }
            opened.mdx_source.unchanged()?;
        }
        Ok(explorer)
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
                let dict = self.dict(id)?;
                // **A replaced file suggests nothing from its old index** (audit round 4, 2026-10-26), as `lookup` checks
                // before and after its own read.
                dict.mdx_source.unchanged()?;
                xdict_lookup::suggest(&dict.mdx, &prefix, limit as usize, &mut out)?;
            }
            Ok(out)
        })
    }

    /// One entry's HTML for the entry view.
    pub fn entry(&self, dict: String, entry: EntryRef, view: View) -> Result<Entry, CoreError> {
        guard(|| {
            let (entry, html, lossy) = self.render(&dict, entry, &view)?;
            Ok(Entry { entry, html, csp: csp(&view.base_url), lossy_bytes: lossy })
        })
    }

    /// **One entry as plain text, whole, under a budget** (ADR-0021 d.5): the same render [`Core::entry`] gives, then the
    /// roles it wrote projected to text with spans and completeness. A budget that cuts reports the cut; only a body over
    /// the view's own ceiling is an error.
    pub fn entry_text(&self, dict: String, entry: EntryRef, view: TextView) -> Result<EntryText, CoreError> {
        guard(|| {
            let render_view = View {
                base_url: view.base_url,
                max_body_bytes: view.max_body_bytes,
                original_style: view.original_style,
            };
            let (entry, html, _lossy) = self.render(&dict, entry, &render_view)?;
            let max = usize::try_from(view.max_text_bytes).unwrap_or(usize::MAX);
            let projection = xdict_entry::entry_text_from_html(&html, max);
            Ok(EntryText {
                entry,
                text: projection.text,
                spans: text_spans(projection.runs),
                senses: projection
                    .senses
                    .into_iter()
                    .map(|sense| crate::types::Sense {
                        id: sense.id,
                        start: sense.start as u64,
                        len: sense.len as u64,
                        label: sense.label,
                        section: sense.section,
                        parent: sense.parent,
                        whole: sense.whole,
                    })
                    .collect(),
                style: xdict_entry::STYLE,
                complete: projection.complete,
                omitted_bytes: projection.omitted_bytes,
                cut_at: projection.cut_at,
                spans_dropped: projection.runs_dropped,
            })
        })
    }

    /// One entry's HTML, from the record to what the view draws: what both [`Core::entry`] and [`Core::entry_text`] read.
    fn render(&self, dict: &str, entry: EntryRef, view: &View) -> Result<(EntryRef, String, u64), CoreError> {
        {
            let opened = self.dict(dict)?;
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
            let (html, lossy) = self.render_record(&opened, &entry.key, record.data, record.lossy, view)?;
            Ok((entry, html, lossy))
        }
    }

    /// **A record's bytes to what the entry view draws**, which both [`Core::entry`] and [`Core::entry_text`] use, and
    /// the examples pass reads once per record without looking its occurrence up again.
    fn render_record(
        &self,
        opened: &Dict,
        key: &str,
        data: Vec<u8>,
        lossy: u64,
        view: &View,
    ) -> Result<(String, u64), CoreError> {
        // The record's bytes become the text, not a copy of them.
        let text = String::from_utf8(data).unwrap_or_else(|e| String::from_utf8_lossy(e.as_bytes()).into_owned());
        // Expanded and rewritten within the view's ceiling: a small record of many style markers, or of many
        // short links, would otherwise be written whole before it could be refused.
        let max = usize::try_from(view.max_body_bytes).unwrap_or(usize::MAX);
        let too_large = |_| CoreError::TooLarge {
            limit: Limit::Body,
            detail: format!("the entry passes {} bytes expanded and rewritten, the view's ceiling", max),
        };
        let expanded = opened.sheet.apply_within(&text, max).map_err(too_large)?;
        let style = self.edition_style(opened)?;
        // The key finds the headword (the roles, element-sweep §2.1); the package says which images it holds (S13).
        let holds = |path: &str| self.holds(opened, path);
        // A transcription candidate that is a key is a headword written with stress (ADR-0010 Phonetics).
        let is_key = |word: &str| opened.mdx.find(word).is_ok_and(|found| !found.is_empty());
        let context = xdict_entry::Entry {
            key,
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
        Ok((html, lossy))
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
            let tries = resource_tries(resolved);
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
    /// The paths of one file kind the edition carries: the sidecars' first, then every volume's, deduped
    /// case-insensitively. Sheets and scripts both read their list this way.
    fn edition_paths(opened: &Dict, extension: &str) -> Result<Vec<String>, CoreError> {
        let mut paths: Vec<String> = Vec::new();
        for (name, _) in &opened.sidecars {
            if name.to_ascii_lowercase().ends_with(extension) {
                paths.push(name.clone());
            }
        }
        for (check, volume) in &opened.mdd {
            check.unchanged()?;
            for key in volume.keys() {
                let key = key?;
                if key.to_ascii_lowercase().ends_with(extension) {
                    let path = key.trim_start_matches('\\').replace('\\', "/");
                    if !paths.iter().any(|p| p.eq_ignore_ascii_case(&path)) {
                        paths.push(path);
                    }
                }
            }
        }
        Ok(paths)
    }

    /// The edition's sheets, read within the shared budget: their texts, the paths kept, and why each other was
    /// skipped. A sheet past what is left of the budget is passed over from its declared size, unread.
    fn read_sheets(&self, opened: &Dict) -> Result<SheetSet, CoreError> {
        let paths = Self::edition_paths(opened, ".css")?;
        let (mut texts, mut sheets, mut skipped, mut total) = (Vec::new(), Vec::new(), Vec::new(), 0usize);
        for path in paths {
            if sheets.len() >= STYLE_SHEETS {
                skipped.push(SkippedSheet { path, reason: SkipReason::TooMany { limit: STYLE_SHEETS as u64 } });
                continue;
            }
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
                    let reason = SkipReason::TooLarge { limit: STYLE_BYTES as u64, detail };
                    skipped.push(SkippedSheet { path, reason });
                }
                Ok(None) => skipped.push(SkippedSheet { path, reason: SkipReason::NotFound }),
                Err(e @ CoreError::SourceChanged { .. }) => return Err(e),
                Err(e) => skipped.push(SkippedSheet { path, reason: SkipReason::Unreadable { detail: e.to_string() } }),
            }
        }
        Ok((texts, sheets, skipped))
    }

    /// The edition's reading style, read from its sheets on first use: the sidecars' `.css`, then the volumes'.
    fn edition_style(&self, opened: &Dict) -> Result<Arc<EditionStyle>, CoreError> {
        if let Some(style) = opened.style.get() {
            return Ok(Arc::clone(style));
        }
        let (texts, sheets, skipped) = self.read_sheets(opened)?;
        let entries = sample(opened)?;
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
        let paths = Self::edition_paths(opened, ".js")?;
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

    /// The display options that apply to an open dictionary's edition, with its defaults, and their CSS (ADR-0013).
    /// An option applies where the edition's sample of entries (the reading style's) carries its markup contract;
    /// the defaults come from the edition's sheets. Read once per open dictionary.
    pub fn display_options(&self, dict: String) -> Result<DisplayOptions, CoreError> {
        guard(|| {
            let opened = self.dict(&dict)?;
            if let Some(options) = opened.options.get() {
                return Ok(options.clone());
            }
            let style = self.edition_style(&opened)?;
            let entries = sample(&opened)?;
            let declared = xdict_entry::declared(&style.style, entries.iter().map(String::as_str));
            let choices: Vec<(&str, &str)> = declared.iter().map(|d| (d.id, d.default)).collect();
            let css = xdict_entry::display_css(&choices)
                .map_err(|e| CoreError::internal(format!("the display options' own catalogue was refused: {e}")))?;
            let options = declared
                .into_iter()
                .map(|d| DisplayOption {
                    id: d.id.into(),
                    attribute: d.attribute.into(),
                    values: d.values.into_iter().map(String::from).collect(),
                    default_value: d.default.into(),
                })
                .collect();
            let made = DisplayOptions { version: DISPLAY_OPTIONS, options, css };
            Ok(opened.options.get_or_init(|| made).clone())
        })
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

    /// **The reverse-example query** (ADR-0031 d.4, d.9; plan WI-4): every pair in `dicts`, in that order, whose
    /// normalised Chinese contains the normalised query. The scan is a substring match, so a one-character query and a
    /// string that is not a word answer alike. A dictionary with no store is reported in `not_ready`, never an error;
    /// identical pairs from several dictionaries are one hit with every source. At most `limit` hits, ranked by the
    /// dictionary order and then by shorter Chinese; `total` counts the distinct pairs found, and `capped` says the
    /// scan stopped at its own bound.
    pub fn examples(&self, query: String, dicts: Vec<String>, limit: u32) -> Result<Examples, CoreError> {
        guard(|| {
            if limit > MAX_PAGE {
                return Err(CoreError::TooLarge {
                    limit: Limit::Page,
                    detail: format!("a page holds at most {MAX_PAGE} examples, {limit} were asked"),
                });
            }
            let needle = crate::examples::normalize(&query);
            let mut ranked: Vec<(usize, ExampleHit)> = Vec::new();
            let mut seen: HashMap<(String, String), usize> = HashMap::new();
            let mut not_ready = Vec::new();
            let mut scanned = 0usize;
            let mut capped = false;
            if !needle.trim().is_empty() {
                for (rank, id) in dicts.iter().enumerate() {
                    let opened = self.dict(id)?;
                    let Some(store) = self.examples_store(&opened)? else {
                        not_ready.push(id.clone());
                        continue;
                    };
                    let found = store.scan(&needle, crate::examples::MAX_HITS - scanned);
                    scanned += found.len();
                    let ordinals: Vec<usize> = found.iter().map(|found| found.ordinal as usize).collect();
                    let occurrences = xdict_lookup::occurrences(&opened.mdx, &ordinals)?;
                    for found in found {
                        let i = found.ordinal as usize;
                        let key = opened.mdx.key(i)?.into_owned();
                        let occurrence = occurrences.get(&i).copied().unwrap_or(0);
                        let source = ExampleSource {
                            dict: id.clone(),
                            entry: EntryRef { edition: opened.edition.clone(), key: key.clone(), occurrence },
                            headword: key,
                        };
                        let pair = (found.english.clone(), found.chinese.clone());
                        if let Some(&at) = seen.get(&pair) {
                            if let Some((_, hit)) = ranked.get_mut(at) {
                                hit.sources.push(source);
                            }
                            continue;
                        }
                        seen.insert(pair, ranked.len());
                        ranked.push((
                            rank,
                            ExampleHit {
                                english: found.english,
                                chinese: found.chinese,
                                start: found.start,
                                len: found.len,
                                sentence: found.sentence,
                                sources: vec![source],
                            },
                        ));
                    }
                    if scanned >= crate::examples::MAX_HITS {
                        capped = true;
                        break;
                    }
                }
            }
            // Dictionary order, then sentences before phrases (the owner's decision 3), then shorter Chinese; the
            // sort is stable, so the arena's order breaks a tie.
            ranked.sort_by(|a, b| {
                a.0.cmp(&b.0)
                    .then_with(|| b.1.sentence.cmp(&a.1.sentence))
                    .then_with(|| a.1.chinese.chars().count().cmp(&b.1.chinese.chars().count()))
            });
            let total = ranked.len() as u64;
            let hits = ranked.into_iter().take(limit as usize).map(|(_, hit)| hit).collect();
            Ok(Examples { hits, total, not_ready, capped })
        })
    }

    /// **A page of one dictionary's stored pairs**, in store order (ADR-0031 d.8): the per-dictionary audit reads an
    /// evenly spaced sample through this, never through a query, which can only show pairs a word matches. A shell
    /// never calls it. `from` past the end answers an empty page, as paging does.
    pub fn examples_page(&self, dict: String, from: u64, limit: u32) -> Result<ExamplePairs, CoreError> {
        guard(|| {
            if limit > MAX_PAGE {
                return Err(CoreError::TooLarge {
                    limit: Limit::Page,
                    detail: format!("a page holds at most {MAX_PAGE} pairs, {limit} were asked"),
                });
            }
            let opened = self.dict(&dict)?;
            let Some(store) = self.examples_store(&opened)? else {
                return Ok(ExamplePairs { edition: opened.edition.clone(), total: 0, pairs: Vec::new() });
            };
            let total = store.len() as u64;
            let start = usize::try_from(from).unwrap_or(usize::MAX);
            let end = start.saturating_add(limit as usize).min(store.len());
            let mut pairs = Vec::new();
            let mut ordinals = Vec::new();
            for i in start..end {
                let (english, chinese, sentence, ordinal) = store
                    .pair(i)
                    .ok_or_else(|| CoreError::internal("an examples record does not read after its checksums held"))?;
                let key = opened.mdx.key(ordinal as usize)?.into_owned();
                ordinals.push(ordinal as usize);
                pairs.push(ExamplePair {
                    english,
                    chinese,
                    sentence,
                    entry: EntryRef { edition: opened.edition.clone(), key, occurrence: 0 },
                });
            }
            let occurrences = xdict_lookup::occurrences(&opened.mdx, &ordinals)?;
            for (pair, ordinal) in pairs.iter_mut().zip(&ordinals) {
                pair.entry.occurrence = occurrences.get(ordinal).copied().unwrap_or(0);
            }
            Ok(ExamplePairs { edition: opened.edition.clone(), total, pairs })
        })
    }

    /// **Builds one dictionary's example store in the background** (ADR-0031 d.3, d.6; plan WI-3): every record read
    /// once through the entry view's own render, `progress` hearing records done and answering `false` to cancel, in
    /// which case nothing is written. A current store is answered from itself; a truncated, foreign or out-of-date one
    /// is built again. An edition whose sample carries no Chinese is read raw, every record, to confirm it; one that
    /// truly has none keeps an empty store and pays no render pass. Never at launch, never in a query: the shell
    /// schedules it (plan WI-1 decision 2).
    pub fn examples_build(&self, dict: String, progress: &dyn Progress) -> Result<ExamplesBuilt, CoreError> {
        guard(|| {
            let opened = self.dict(&dict)?;
            let digest = edition_digest(&opened.edition)?;
            let name = examples_name(&opened.edition);
            if let Some(region) = self.indexes.get(&name)?
                && let Some(store) = crate::examples::Store::decode(&*region, &digest)
            {
                return Ok(ExamplesBuilt {
                    edition: opened.edition.clone(),
                    pairs: store.len() as u64,
                    roles: store.roles,
                    fallback: store.fallback,
                    entries: store.entries,
                    failed: store.failed,
                    no_chinese: store.no_chinese,
                    cached: true,
                });
            }
            if opened.mdx.len() > u32::MAX as usize {
                return Err(CoreError::TooLarge {
                    limit: Limit::File,
                    detail: format!("the edition has {} records; a pair's ordinal is a u32", opened.mdx.len()),
                });
            }
            let total = opened.mdx.len() as u64;
            if !self.sample_has_chinese(&opened, progress)? {
                // The empty store is a result like any other: the source must not have changed under the sample,
                // and a cancelled pass writes nothing (audit, 2026-10-24).
                opened.mdx_source.unchanged()?;
                if !progress.progress(total, total) {
                    return Err(CoreError::Cancelled { detail: "the examples pass was cancelled".into() });
                }
                let bytes = crate::examples::Builder::new().finish(digest, 0, 0, true)?;
                self.indexes.put(&name, &bytes)?;
                return Ok(ExamplesBuilt {
                    edition: opened.edition.clone(),
                    pairs: 0,
                    roles: 0,
                    fallback: 0,
                    entries: 0,
                    failed: 0,
                    no_chinese: true,
                    cached: false,
                });
            }
            let view =
                View { base_url: "xdict://d/".into(), max_body_bytes: MAX_RESOURCE_BYTES, original_style: false };
            let mut builder = crate::examples::Builder::new();
            let mut failed = 0u64;
            let mut read = 0u64;
            for i in 0..opened.mdx.len() {
                if i % EXAMPLES_REPORT == 0 && !progress.progress(i as u64, total) {
                    return Err(CoreError::Cancelled { detail: "the examples pass was cancelled".into() });
                }
                let key = opened.mdx.key(i)?.into_owned();
                let raw = opened.mdx.record(i)?;
                if String::from_utf8_lossy(&raw.data).trim_start().starts_with("@@@LINK=") {
                    continue;
                }
                read += 1;
                let (html, _lossy) = match self.render_record(&opened, &key, raw.data, raw.lossy, &view) {
                    Ok(rendered) => rendered,
                    Err(CoreError::TooLarge { limit: Limit::Body, .. }) => {
                        failed += 1;
                        continue;
                    }
                    Err(error) => return Err(error),
                };
                let projection = xdict_entry::entry_text_from_html(&html, EXAMPLES_TEXT_BYTES);
                if !projection.complete {
                    failed += 1;
                    continue;
                }
                let spans = text_spans(projection.runs);
                for pair in crate::examples::extract(&projection.text, &spans) {
                    if crate::examples::is_expansion(&key, &pair.english) {
                        continue;
                    }
                    builder.push(i as u32, &pair)?;
                }
            }
            opened.mdx_source.unchanged()?;
            if !progress.progress(total, total) {
                return Err(CoreError::Cancelled { detail: "the examples pass was cancelled".into() });
            }
            let pairs = builder.len() as u64;
            let builder_roles = builder.roles();
            let builder_fallback = builder.fallback();
            let bytes = builder.finish(digest, read, failed, false)?;
            self.indexes.put(&name, &bytes)?;
            Ok(ExamplesBuilt {
                edition: opened.edition.clone(),
                pairs,
                roles: builder_roles,
                fallback: builder_fallback,
                entries: read,
                failed,
                no_chinese: false,
                cached: false,
            })
        })
    }

    // MARK: - Phrases (plan-phrase-recognition WI-4, WI-5)

    /// **Builds one edition's phrase inventory** (`dev-docs/plan-phrase-recognition.md` WI-4): every public multi-word
    /// key becomes a template, written through the index storage under a name that carries the format, the extractor,
    /// the public-key policy and the folding. Like the examples pass it reports progress, has no deadline and stops by
    /// `cancel`; a store that is already there and decodes is answered `cached` without a read of the keys.
    pub fn phrases_build(&self, dict: String, progress: &dyn Progress) -> Result<PhraseBuilt, CoreError> {
        let opened = self.dict(&dict)?;
        let edition = opened.edition.clone();
        // **No panic crosses the boundary**, as for every other public call: the progress and storage callbacks are
        // the shell's, and one that panics is an internal error, not a crash in the service.
        let outcome = guard(|| {
            match self.phrases_build_opened(&opened, progress) {
                // **The matcher is indexed here, on the background thread** (WI-4's lifetime): the first ask after a
                // build is warm, and an edition whose store was already there decodes it in this pass too.
                Ok((built, matcher)) => {
                    let handle = self.parse_handle(&dict)?;
                    let mut state = self.lock()?;
                    state.phrase_failures.remove(&edition);
                    // **A dictionary closed while its inventory built keeps nothing**: its matcher would outlive the
                    // handle, and the next open decodes the store instead.
                    if state.open.contains_key(&handle) {
                        state.phrase_matchers.insert(crate::phrases::store_name(&edition), matcher);
                    }
                    Ok(built)
                }
                Err(error) => Err(error),
            }
        });
        // **Every real failure is terminal for the edition, a panic included** (audit round 2): a panic used to unwind
        // past the branch that records it, and the next question answered "building" forever. A cancelled build is the
        // reader's choice, not the dictionary's failure (the refutation's #8).
        if let Err(error) = &outcome
            && !matches!(error, CoreError::Cancelled { .. })
            && let Ok(mut state) = self.lock()
        {
            state.phrase_failures.insert(edition);
        }
        outcome
    }

    fn phrases_build_opened(
        &self,
        opened: &Dict,
        progress: &dyn Progress,
    ) -> Result<(PhraseBuilt, Arc<xdict_phrase::Matcher>), CoreError> {
        opened.mdx_source.unchanged()?;
        let edition = opened.edition.clone();
        let name = crate::phrases::store_name(&edition);
        let versions = crate::phrases::versions();
        if let Some(region) = self.indexes.get(&name)? {
            let bytes = region_to_vec(&*region)?;
            if let Some(inventory) = xdict_phrase::Inventory::decode(&bytes, &edition, versions) {
                let built = PhraseBuilt { edition, phrases: inventory.phrases().len() as u64, cached: true };
                return Ok((built, Arc::new(inventory.matcher())));
            }
        }
        let count = opened.mdx.len();
        let mut keys: Vec<String> = Vec::new();
        for i in 0..count {
            if i % 4096 == 0 && !progress.progress(i as u64, count as u64) {
                return Err(CoreError::Cancelled { detail: "the phrase inventory build was cancelled".into() });
            }
            // **An unreadable key fails the build**: a store written without it would call itself complete.
            if !opened.mdx.is_public(i)? {
                continue;
            }
            let key = opened.mdx.key(i)?;
            if key.split_whitespace().count() < 2 {
                continue;
            }
            keys.push(key.into_owned());
        }
        let inventory = xdict_phrase::Inventory::from_keys(keys, crate::phrases::slots());
        let phrases = inventory.phrases().len() as u64;
        let bytes = inventory
            .encode(&edition, versions)
            .map_err(|_| CoreError::internal("a phrase inventory is larger than its store format holds"))?;
        if !progress.progress(count as u64, count as u64) {
            return Err(CoreError::Cancelled { detail: "the phrase inventory build was cancelled".into() });
        }
        // **The file may have changed under the build** (its progress callback runs the shell's code): a store written
        // from bytes the source no longer holds would answer for the wrong edition.
        opened.mdx_source.unchanged()?;
        self.indexes.put(&name, &bytes)?;
        Ok((PhraseBuilt { edition, phrases, cached: false }, Arc::new(inventory.matcher())))
    }

    /// **The phrases covering the term in this sentence** (`dev-docs/plan-phrase-recognition.md` WI-5): every phrase of
    /// every ready dictionary that covers the word under the term, best first, with the states of the dictionaries that
    /// could not answer. The sentence and the term are re-validated here (the capture contract's bounds); nothing is
    /// sent anywhere.
    pub fn phrases(
        &self,
        sentence: String,
        term_location: u64,
        term_length: u64,
        dicts: Vec<String>,
    ) -> Result<PhraseAnswer, CoreError> {
        guard(|| {
            let total = sentence.encode_utf16().count() as u64;
            if total > crate::phrases::MAX_SENTENCE_UTF16 {
                return Err(CoreError::TooLarge {
                    limit: Limit::Sentence,
                    detail: format!(
                        "a sentence holds at most {} UTF-16 units, {total} were given",
                        crate::phrases::MAX_SENTENCE_UTF16
                    ),
                });
            }
            // **An empty sentence is "no sentence", whatever range came with it**: the capture carried no context,
            // which is a state, not a bad request.
            if total == 0 {
                return Ok(PhraseAnswer {
                    state: PhraseState::NotAsked,
                    matches: Vec::new(),
                    coverage: Vec::new(),
                    total: 0,
                    capped: false,
                });
            }
            let end = term_location
                .checked_add(term_length)
                .ok_or_else(|| CoreError::Malformed { detail: "the term's range overflows".into() })?;
            if term_length == 0 || end > total {
                return Err(CoreError::Malformed {
                    detail: "the term's range does not lie inside the sentence".into(),
                });
            }
            // **Both ends sit on character boundaries**: a range inside a surrogate pair names no text — the capture
            // contract refuses one, and the service cannot trust its caller to have checked.
            if !utf16_boundaries(&sentence, term_location, end) {
                return Err(CoreError::Malformed { detail: "the term's range splits a character".into() });
            }
            let tokens = tokens_with_offsets(&sentence);
            let word = tokens
                .iter()
                .position(|(_, start, end)| *start <= term_location && term_location < *end)
                .or_else(|| tokens.iter().position(|(_, start, _)| *start >= term_location))
                .unwrap_or_else(|| tokens.len().saturating_sub(1));
            let forms: Vec<Vec<String>> = tokens.iter().map(|(token, _, _)| xdict_phrase::forms(token)).collect();
            let mut matches: Vec<PhraseMatch> = Vec::new();
            let mut coverage: Vec<CoverageEntry> = Vec::new();
            let mut total: u64 = 0;
            let mut building = false;
            let mut ready = 0usize;
            for id in &dicts {
                let opened = self.dict(id)?;
                // **A file replaced on disk answers nothing from its old store** (audit round 4, 2026-10-26): the matcher
                // indexes the file the reader opened, so a stale one names phrases that may have gone; the caller's own
                // reopen path is what makes the dictionary current again.
                opened.mdx_source.unchanged()?;
                let edition = opened.edition.clone();
                if self.lock()?.phrase_failures.contains(&edition) {
                    coverage.push(CoverageEntry { dict: id.clone(), state: Coverage::Unavailable });
                    continue;
                }
                let Some(matcher) = self.phrase_matcher(&opened)? else {
                    coverage.push(CoverageEntry { dict: id.clone(), state: Coverage::Building });
                    building = true;
                    continue;
                };
                ready += 1;
                coverage.push(CoverageEntry { dict: id.clone(), state: Coverage::Ready });
                for found in matcher.matches(
                    &forms,
                    word,
                    xdict_phrase::DEFAULT_WIDEST_GAP,
                    xdict_phrase::DEFAULT_WIDEST_INFERRED_GAP,
                ) {
                    // **Every match is counted, the list is what stops** (WI-8: the shell says how many were left out);
                    // counting costs nothing, and materializing them for a word every phrase names would.
                    total += 1;
                    if matches.len() >= crate::phrases::MAX_MATCHES {
                        continue;
                    }
                    let (Some((_, first, _)), Some((_, _, last))) = (tokens.get(found.first), tokens.get(found.last))
                    else {
                        continue;
                    };
                    let separation = found.separation;
                    let gap = found.gap() as u64;
                    matches.push(PhraseMatch {
                        dict: id.clone(),
                        phrase: found.phrase,
                        location: *first,
                        length: last.saturating_sub(*first),
                        separation,
                        gap,
                    });
                }
            }
            // **`none` only when every dictionary asked answered** (D4): one ready-and-empty beside one whose store
            // could not be built is `unavailable`, never a complete "nothing here".
            let unavailable = coverage.iter().any(|entry| entry.state == Coverage::Unavailable);
            let state = if !matches.is_empty() {
                PhraseState::Found
            } else if building {
                PhraseState::Building
            } else if unavailable || ready == 0 {
                PhraseState::Unavailable
            } else {
                PhraseState::None
            };
            let capped = total > matches.len() as u64;
            Ok(PhraseAnswer { state, matches, coverage, total, capped })
        })
    }

    /// One edition's matcher, decoded once and retained; `None` when the store is absent or does not decode, which
    /// both mean "build it".
    fn phrase_matcher(&self, opened: &Dict) -> Result<Option<Arc<xdict_phrase::Matcher>>, CoreError> {
        let name = crate::phrases::store_name(&opened.edition);
        if let Some(matcher) = self.lock()?.phrase_matchers.get(&name).cloned() {
            return Ok(Some(matcher));
        }
        let Some(region) = self.indexes.get(&name)? else { return Ok(None) };
        let bytes = region_to_vec(&*region)?;
        let Some(inventory) = xdict_phrase::Inventory::decode(&bytes, &opened.edition, crate::phrases::versions())
        else {
            return Ok(None);
        };
        let matcher = Arc::new(inventory.matcher());
        let mut state = self.lock()?;
        // **A close can land between the decode and here**: its matcher is not kept for a handle that is gone.
        if state.open.values().any(|other| other.edition == opened.edition) {
            state.phrase_matchers.insert(name, matcher.clone());
        }
        Ok(Some(matcher))
    }

    /// One edition's store, decoded, or `None` when it is absent or does not decode: both mean "build it".
    fn examples_store(&self, opened: &Dict) -> Result<Option<crate::examples::Store>, CoreError> {
        let Some(region) = self.indexes.get(&examples_name(&opened.edition))? else { return Ok(None) };
        let digest = edition_digest(&opened.edition)?;
        Ok(crate::examples::Store::decode(&*region, &digest))
    }

    /// Whether the edition carries Chinese anywhere (ADR-0031 d.6): a monolingual dictionary contributes no pairs
    /// and is not rendered. A spread sample comes first, cheap; when it finds none, every record is read raw, so a
    /// negative is confirmed rather than guessed — an empty store is cached, and a sampled negative could keep a
    /// dictionary with Chinese out of the feature forever (audit-fix, 2026-10-24).
    fn sample_has_chinese(&self, opened: &Dict, progress: &dyn Progress) -> Result<bool, CoreError> {
        let count = opened.mdx.len();
        if count == 0 {
            return Ok(false);
        }
        let asked = EXAMPLES_SAMPLE.min(count);
        for k in 0..asked {
            // Both ends are sampled, and every pair of neighbours spans the edition evenly.
            let i = if asked == 1 { 0 } else { (count - 1) * k / (asked - 1) };
            if has_chinese_record(opened, i)? {
                return Ok(true);
            }
        }
        for i in 0..count {
            if i % EXAMPLES_REPORT == 0 && !progress.progress(i as u64, count as u64) {
                return Err(CoreError::Cancelled { detail: "the examples pass was cancelled".into() });
            }
            if has_chinese_record(opened, i)? {
                return Ok(true);
            }
        }
        Ok(false)
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
        resource_tries(resolved).iter().any(|name| {
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

    // MARK: - The reading history (ADR-0023, ADR-0024)

    /// The ledger's slot. Opened on first use: a file store under `data_dir` (one writer, ADR-0024), else memory.
    fn ledger(&self) -> Result<MutexGuard<'_, Option<Ledger>>, CoreError> {
        self.ledger
            .lock()
            .map_err(|_| CoreError::internal("the ledger's lock was left inconsistent by an earlier fault"))
    }

    fn opened<'a>(&self, held: &'a mut Option<Ledger>) -> Result<&'a mut Ledger, CoreError> {
        if held.is_none() {
            let store = Self::ledger_store(&self.ledger_path)?;
            *held = Some(Ledger::open(store).map_err(ledger_error)?);
        }
        held.as_mut().ok_or_else(|| CoreError::internal("the ledger could not be opened"))
    }

    /// **Records a reading** (ADR-0023): the language filter runs before anything is written, and a retry (the
    /// same operation id) is one event. The sentence never leaves this call.
    pub fn ledger_record(
        &self,
        reading: Reading,
        operation_id: String,
        target_languages: Vec<String>,
    ) -> Result<RecordOutcome, CoreError> {
        let mut held = self.ledger()?;
        self.opened(&mut held)?.record(reading, &operation_id, &target_languages).map_err(ledger_error)
    }

    #[cfg(not(target_family = "wasm"))]
    fn ledger_store(path: &Option<PathBuf>) -> Result<Arc<dyn Store>, CoreError> {
        match path {
            Some(path) => Ok(Arc::new(FileStore::open(path).map_err(ledger_error)?)),
            None => Ok(Arc::new(MemoryStore::default())),
        }
    }

    #[cfg(target_family = "wasm")]
    fn ledger_store(_path: &Option<PathBuf>) -> Result<Arc<dyn Store>, CoreError> {
        Ok(Arc::new(MemoryStore::default()))
    }

    /// The days the drawer shows, in the reader's own zone.
    pub fn ledger_history(&self, now: f64, utc_offset_seconds: i32) -> Result<History, CoreError> {
        let mut held = self.ledger()?;
        Ok(self.opened(&mut held)?.history(now, utc_offset_seconds))
    }

    /// Everything the log holds, in causal order: the reader's export (ADR-0023).
    pub fn ledger_export(&self) -> Result<Vec<xdict_ledger::Event>, CoreError> {
        let mut held = self.ledger()?;
        Ok(self.opened(&mut held)?.export())
    }

    /// **The reader joined an edition to a dictionary lineage** (ADR-0025): the ledger owns the association the
    /// registry caches.
    pub fn ledger_join(&self, joined: DictionaryJoined, operation_id: String) -> Result<RecordOutcome, CoreError> {
        let mut held = self.ledger()?;
        self.opened(&mut held)?.join_dictionary(joined, &operation_id).map_err(ledger_error)
    }

    /// **The reader split an edition into a lineage of its own** (ADR-0025).
    pub fn ledger_split(&self, split: DictionarySplit, operation_id: String) -> Result<RecordOutcome, CoreError> {
        let mut held = self.ledger()?;
        self.opened(&mut held)?.split_dictionary(split, &operation_id).map_err(ledger_error)
    }

    /// **Hides readings behind a tombstone that carries no content** (ADR-0024).
    pub fn ledger_remove(&self, removal: Removal, operation_id: String) -> Result<RecordOutcome, CoreError> {
        let mut held = self.ledger()?;
        self.opened(&mut held)?.remove(removal, &operation_id).map_err(ledger_error)
    }

    /// Shows removed readings again (ADR-0024).
    pub fn ledger_restore(&self, restore: Removal, operation_id: String) -> Result<RecordOutcome, CoreError> {
        let mut held = self.ledger()?;
        self.opened(&mut held)?.restore(restore, &operation_id).map_err(ledger_error)
    }

    /// **Retention is compaction** (ADR-0024): readings past the drawer's bound leave the log itself.
    pub fn ledger_compact(&self, now: f64, utc_offset_seconds: i32) -> Result<Compaction, CoreError> {
        let mut held = self.ledger()?;
        self.opened(&mut held)?.compact(now, utc_offset_seconds).map_err(ledger_error)
    }

    /// **Erase is a rewrite** (ADR-0024): the readings leave the log; the receipt says what may remain recoverable.
    pub fn ledger_erase(&self, operation_id: String, at: f64, device: String) -> Result<EraseReport, CoreError> {
        let mut held = self.ledger()?;
        self.opened(&mut held)?.erase(&operation_id, at, &device).map_err(ledger_error)
    }

    /// The log's frontier: what a snapshot must match, and what an erase receipt records (ADR-0024).
    pub fn ledger_frontier(&self) -> Result<Frontier, CoreError> {
        let mut held = self.ledger()?;
        Ok(self.opened(&mut held)?.frontier())
    }

    /// The lineage the ledger associates with an edition, as its last join or split left it (ADR-0025).
    pub fn ledger_association(&self, edition: String) -> Result<Option<String>, CoreError> {
        let mut held = self.ledger()?;
        Ok(self.opened(&mut held)?.association(&edition).map(str::to_owned))
    }

    // MARK: - Study (plan-history-and-learning §5)

    /// The text view a definition hash is taken through: the whole entry, never cut.
    fn definition_view() -> TextView {
        TextView {
            base_url: "xdict://d/".into(),
            max_body_bytes: MAX_RESOURCE_BYTES,
            max_text_bytes: u64::MAX,
            original_style: false,
        }
    }

    /// **The edition's lineage** (ADR-0025): the ledger's association when it has one, else the registry's, written into
    /// the ledger as a join event so the ledger becomes the truth the registry caches. One operation, one event.
    fn study_lineage(&self, edition: &str, name: &str, at: f64, device: &str) -> Result<String, CoreError> {
        let mut held = self.ledger()?;
        let ledger = self.opened(&mut held)?;
        if let Some(lineage) = ledger.association(edition) {
            return Ok(lineage.to_string());
        }
        let Some(lineage) = self.registry.lineage(edition).map_err(registry_error)? else {
            return Err(CoreError::NotFound { what: Missing::Lineage, detail: format!("{edition} has no lineage") });
        };
        let joined = DictionaryJoined {
            lineage: lineage.clone(),
            edition: edition.to_string(),
            name: name.to_string(),
            language: String::new(),
            at,
            device: device.to_string(),
        };
        ledger.join_dictionary(joined, &format!("association:{edition}")).map_err(ledger_error)?;
        Ok(lineage)
    }

    /// The handle of the open dictionary of `edition`.
    fn dict_of_edition(&self, edition: &str) -> Result<String, CoreError> {
        let state = self.lock()?;
        state
            .open
            .iter()
            .find(|(_, dict)| dict.edition == edition)
            .map(|(handle, _)| self.handle(*handle))
            .ok_or_else(|| CoreError::NotFound { what: Missing::Edition, detail: format!("{edition} is not open") })
    }

    /// The hash of the definition at (key, occurrence) in an open dictionary, or `None` when it has no such record.
    fn occurrence_hash(
        &self,
        dict: &str,
        edition: &str,
        key: &str,
        occurrence: u32,
    ) -> Result<Option<String>, CoreError> {
        let entry = EntryRef { edition: edition.to_string(), key: key.to_string(), occurrence };
        match self.entry_text(dict.to_string(), entry, Self::definition_view()) {
            Ok(projected) => Ok(Some(xdict_ledger::definition_hash(&projected.text))),
            Err(CoreError::NotFound { what: Missing::Entry, .. }) => Ok(None),
            Err(error) => Err(error),
        }
    }

    /// **Saves the reader's note on an entry** (plan §5.1): the core computes the definition's hash and resolves the
    /// lineage, so the note carries evidence and never the definition.
    pub fn study_note(
        &self,
        dict: String,
        entry: EntryRef,
        text: String,
        name: String,
        stamp: Stamp,
        operation_id: String,
    ) -> Result<Note, CoreError> {
        guard(|| {
            let projected = self.entry_text(dict, entry.clone(), Self::definition_view())?;
            let lineage = self.study_lineage(&entry.edition, &name, stamp.at, &stamp.device)?;
            let note = Note {
                target: StudyTarget {
                    lineage,
                    entry_key: entry.key.clone(),
                    occurrence: entry.occurrence,
                    kind: TargetKind::Entry,
                    edition: entry.edition.clone(),
                    definition_hash: xdict_ledger::definition_hash(&projected.text),
                },
                text,
                at: stamp.at,
                device: stamp.device.clone(),
            };
            let key = note.target.key();
            let mut held = self.ledger()?;
            let ledger = self.opened(&mut held)?;
            ledger.save_note(note, &operation_id).map_err(ledger_error)?;
            ledger
                .notes()
                .into_iter()
                .find(|held| held.target.key() == key)
                .ok_or_else(|| CoreError::internal("the note was written and cannot be read back"))
        })
    }

    /// **Saves a note named by edition, key and occurrence** (plan §5.1): the history's cards carry those three, not a
    /// handle, so the core resolves the open dictionary of the edition itself.
    pub fn study_note_at(
        &self,
        entry: EntryRef,
        text: String,
        name: String,
        stamp: Stamp,
        operation_id: String,
    ) -> Result<Note, CoreError> {
        let dict = self.dict_of_edition(&entry.edition)?;
        self.study_note(dict, entry, text, name, stamp, operation_id)
    }

    /// **The log's events as the reader's export** (ADR-0023): one JSON document, the evidence included and no
    /// dictionary content.
    pub fn ledger_export_json(&self) -> Result<String, CoreError> {
        let mut held = self.ledger()?;
        let events = self.opened(&mut held)?.export();
        serde_json::to_string(&serde_json::json!({ "version": 1, "events": events }))
            .map_err(|error| CoreError::internal(format!("export: {error}")))
    }

    pub fn study_notes(&self) -> Result<Vec<Note>, CoreError> {
        let mut held = self.ledger()?;
        Ok(self.opened(&mut held)?.notes())
    }

    /// **The review queue**: due cards, soonest first, a new card at once.
    pub fn review_queue(&self, now: f64, limit: u32) -> Result<Vec<StudyCard>, CoreError> {
        let mut held = self.ledger()?;
        Ok(self.opened(&mut held)?.queue(now, usize::try_from(limit).unwrap_or(usize::MAX)))
    }

    pub fn review_summary(&self, now: f64) -> Result<ReviewSummary, CoreError> {
        let mut held = self.ledger()?;
        Ok(self.opened(&mut held)?.summary(now))
    }

    /// **Grades a card** (plan §5.3): the card must still be at `revision` and due; the scheduler transitions it under
    /// the reader's retention and cap, and the event records the configuration it used.
    pub fn review_grade(
        &self,
        target_key: String,
        revision: String,
        grade: u8,
        policy: ReviewPolicy,
        stamp: Stamp,
        operation_id: String,
    ) -> Result<ReviewOutcome, CoreError> {
        guard(|| {
            let grade = study_grade(grade)?;
            let scheduler = Scheduler::with_configuration(policy.retention, policy.maximum_days, DEFAULT_WEIGHTS)
                .map_err(|error| CoreError::Malformed { detail: format!("scheduler: {error}") })?;
            let (card, eligible) = {
                let mut held = self.ledger()?;
                let ledger = self.opened(&mut held)?;
                let card = ledger.card(&target_key).ok_or_else(|| CoreError::NotFound {
                    what: Missing::Entry,
                    detail: format!("no study card for {target_key}"),
                })?;
                let due = card.state.is_new() || card.state.due.is_some_and(|due| due <= stamp.at);
                // **A conflicted card waits for the reader's choice** (ADR-0027): a grade on it would be a third branch.
                let conflicted = ledger.conflict(&target_key).is_some();
                let eligible = card.head == revision && due && !conflicted;
                (card, eligible)
            };
            let after = scheduler
                .review(schedule_card(card.state), schedule_grade(grade), stamp.at)
                .map_err(|error| CoreError::Malformed { detail: format!("scheduler: {error}") })?;
            let record = GradeRecord {
                target: card.target.clone(),
                revision,
                grade,
                before: card.state,
                after: card_state(after),
                configuration: ScheduleConfiguration {
                    version: SCHEDULE_VERSION.to_string(),
                    retention: policy.retention,
                    maximum_days: policy.maximum_days,
                    weights: DEFAULT_WEIGHTS.to_vec(),
                },
                at: stamp.at,
                device: stamp.device,
            };
            let mut held = self.ledger()?;
            let ledger = self.opened(&mut held)?;
            let outcome = ledger.record_grade(record, &operation_id, eligible).map_err(ledger_error)?;
            let card = ledger.card(&target_key).ok_or_else(|| CoreError::internal("the study card went missing"))?;
            Ok(ReviewOutcome { outcome, card })
        })
    }

    /// **Voids the card's latest grade** (plan §5.3): only while the card is still in the state that grade produced.
    pub fn review_undo(
        &self,
        target_key: String,
        grade_event: String,
        stamp: Stamp,
        operation_id: String,
    ) -> Result<ReviewOutcome, CoreError> {
        guard(|| {
            let (card, eligible) = {
                let mut held = self.ledger()?;
                let ledger = self.opened(&mut held)?;
                let card = ledger.card(&target_key).ok_or_else(|| CoreError::NotFound {
                    what: Missing::Entry,
                    detail: format!("no study card for {target_key}"),
                })?;
                (card.clone(), !grade_event.is_empty() && card.head == grade_event)
            };
            let undo = UndoRecord { target: card.target.clone(), grade_event, at: stamp.at, device: stamp.device };
            let mut held = self.ledger()?;
            let ledger = self.opened(&mut held)?;
            let outcome = ledger.record_undo(undo, &operation_id, eligible).map_err(ledger_error)?;
            let card = ledger.card(&target_key).ok_or_else(|| CoreError::internal("the study card went missing"))?;
            Ok(ReviewOutcome { outcome, card })
        })
    }

    /// **One sync pass** (plan §2.6): every peer log in `input` merges into this one, then this device's whole log is
    /// written to `output` for the others. The two folders are the app group's (the service's sandbox cannot read the
    /// reader's storage): the app copies the reader's folder in, and this device's log back out. What travels is the log —
    /// readings, notes and evidence hashes — never a dictionary's text.
    #[cfg(not(target_family = "wasm"))]
    pub fn ledger_sync(&self, input: String, output: String, device: String) -> Result<SyncReport, CoreError> {
        guard(|| {
            if device.is_empty() || !device.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_') {
                return Err(CoreError::Malformed { detail: format!("a device name for a file: {device:?}") });
            }
            let source = std::path::PathBuf::from(&input);
            let sink = std::path::PathBuf::from(&output);
            std::fs::create_dir_all(&sink)
                .map_err(|error| CoreError::Malformed { detail: format!("{}: {error}", sink.display()) })?;
            let ours = sink.join(format!("xdict-{device}.xdlog"));
            let mut report = SyncReport { exported: 0, peers: 0, added: 0, skipped: 0 };
            let mut held = self.ledger()?;
            let ledger = self.opened(&mut held)?;
            let listing = std::fs::read_dir(&source)
                .map_err(|error| CoreError::Malformed { detail: format!("the sync folder: {error}") })?;
            for entry in listing {
                let path =
                    entry.map_err(|error| CoreError::Malformed { detail: format!("the sync folder: {error}") })?.path();
                let named =
                    path.file_name().and_then(|name| name.to_str()).is_some_and(|name| name.ends_with(".xdlog"));
                if path == ours || !named {
                    continue;
                }
                let length = std::fs::metadata(&path).map(|meta| meta.len()).unwrap_or(0);
                if length > MAX_SYNC_BYTES {
                    return Err(CoreError::Malformed {
                        detail: format!("{} is {length} bytes, over the sync bound", path.display()),
                    });
                }
                let bytes = std::fs::read(&path)
                    .map_err(|error| CoreError::Malformed { detail: format!("{}: {error}", path.display()) })?;
                let merged = ledger.merge(&bytes).map_err(ledger_error)?;
                report.peers += 1;
                report.added += merged.added;
                report.skipped += merged.skipped;
            }
            let bytes = ledger.log_bytes().map_err(ledger_error)?;
            let temporary = ours.with_extension("xdlog.tmp");
            std::fs::write(&temporary, &bytes)
                .map_err(|error| CoreError::Malformed { detail: format!("{}: {error}", temporary.display()) })?;
            std::fs::rename(&temporary, &ours)
                .map_err(|error| CoreError::Malformed { detail: format!("{}: {error}", ours.display()) })?;
            report.exported = bytes.len() as u64;
            Ok(report)
        })
    }

    /// **The cards two devices' answers left in two states** (ADR-0027): the reader chooses a branch, and nothing is
    /// retracted before they do. They are not in the queue.
    pub fn review_conflicts(&self) -> Result<Vec<CardConflict>, CoreError> {
        let mut held = self.ledger()?;
        Ok(self.opened(&mut held)?.conflicts())
    }

    /// **Keeps one branch of a conflict** (ADR-0027): `keep` names one of the card's candidates; replay voids the others
    /// and everything that descended from them. A keep that is not a candidate is answered `Ineligible`.
    pub fn review_resolve(
        &self,
        target_key: String,
        keep: String,
        stamp: Stamp,
        operation_id: String,
    ) -> Result<ReviewOutcome, CoreError> {
        guard(|| {
            let (target, eligible) = {
                let mut held = self.ledger()?;
                let ledger = self.opened(&mut held)?;
                let conflict = ledger.conflict(&target_key).ok_or_else(|| CoreError::NotFound {
                    what: Missing::Entry,
                    detail: format!("no conflict on {target_key}"),
                })?;
                let eligible = conflict.candidates.iter().any(|candidate| candidate.id == keep);
                (conflict.target.clone(), eligible)
            };
            let resolution = ResolutionRecord { target, keep, at: stamp.at, device: stamp.device };
            let mut held = self.ledger()?;
            let ledger = self.opened(&mut held)?;
            let outcome = ledger.resolve(resolution, &operation_id, eligible).map_err(ledger_error)?;
            let card = ledger.card(&target_key).ok_or_else(|| CoreError::internal("the study card went missing"))?;
            Ok(ReviewOutcome { outcome, card })
        })
    }

    /// The hash a note records for an entry's definition (plan §5.1); never the definition itself.
    pub fn definition_hash_of(&self, dict: String, entry: EntryRef) -> Result<String, CoreError> {
        let projected = self.entry_text(dict, entry, Self::definition_view())?;
        Ok(xdict_ledger::definition_hash(&projected.text))
    }

    /// **Re-anchors notes of `old_edition` to `new_edition`** (plan §5.1): the same occurrence holding the same
    /// definition hash moves; a moved definition, a reordered occurrence or a missing key leaves the note where it is
    /// and is reported, never silently bound to another record.
    pub fn study_reanchor(
        &self,
        old_edition: String,
        new_edition: String,
        stamp: Stamp,
        operation_prefix: String,
    ) -> Result<ReanchorReport, CoreError> {
        guard(|| {
            let dict = self.dict_of_edition(&new_edition)?;
            let notes: Vec<Note> = {
                let mut held = self.ledger()?;
                self.opened(&mut held)?.notes().into_iter().filter(|note| note.target.edition == old_edition).collect()
            };
            let mut outcomes = Vec::with_capacity(notes.len());
            for note in notes {
                let key = note.target.entry_key.clone();
                let occurrence = note.target.occurrence;
                let result = match self.occurrence_hash(&dict, &new_edition, &key, occurrence)? {
                    None => ReanchorResult::Missing,
                    Some(hash) if hash == note.target.definition_hash => {
                        self.record_reanchor(&note, &new_edition, &hash, stamp.at, &stamp.device, &operation_prefix)?;
                        ReanchorResult::Reanchored
                    }
                    Some(_) => {
                        let mut reordered = false;
                        for other in 0..64u32 {
                            if other == occurrence {
                                continue;
                            }
                            match self.occurrence_hash(&dict, &new_edition, &key, other)? {
                                Some(hash) if hash == note.target.definition_hash => {
                                    reordered = true;
                                    break;
                                }
                                None => break,
                                Some(_) => {}
                            }
                        }
                        if reordered { ReanchorResult::Reordered } else { ReanchorResult::Changed }
                    }
                };
                outcomes.push(ReanchorOutcome { target: note.target, result });
            }
            Ok(ReanchorReport { outcomes })
        })
    }

    fn record_reanchor(
        &self,
        note: &Note,
        to_edition: &str,
        hash: &str,
        at: f64,
        device: &str,
        prefix: &str,
    ) -> Result<(), CoreError> {
        let mut held = self.ledger()?;
        let ledger = self.opened(&mut held)?;
        let record = ReanchorRecord {
            target: note.target.clone(),
            to_edition: to_edition.to_string(),
            definition_hash: hash.to_string(),
            at,
            device: device.to_string(),
        };
        let operation = format!("{prefix}:{}:{}", note.target.entry_key, note.target.occurrence);
        ledger.record_reanchor(record, &operation).map_err(ledger_error)?;
        Ok(())
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

/// A fixed, evenly spaced sample of an edition's entries, the MDX header's compact styles applied: the same whichever
/// entry is opened first (ADR-0010 d.4). The reading style's base is measured on it, and the display options that
/// apply are read from it (ADR-0013). A redirect, or a record too large or unreadable, is passed over.
fn sample(opened: &Dict) -> Result<Vec<String>, CoreError> {
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
    Ok(entries)
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

/// What one word catalog may hold: key entries in all the dictionaries read, and bytes of text kept.
#[derive(Debug, Clone, Copy)]
struct CatalogLimits {
    entries: u64,
    bytes: u64,
}

impl CatalogLimits {
    const DEFAULT: Self = Self { entries: crate::words::MAX_CATALOG_ENTRIES, bytes: CATALOG_BYTES };
}

/// A word catalog over its limits: a limit of what the core holds of a file's index, as the reader's own are.
fn catalog_too_large(detail: String) -> CoreError {
    CoreError::TooLarge { limit: Limit::File, detail }
}

/// The explorer's constructor errors in the core's terms, each kind kept: its limits are the catalog's, its damage
/// the file's. Building a catalog asks no query, so an `InvalidQuery` here breaks an invariant and is `Internal`.
fn word_error(error: crate::words::WordError) -> CoreError {
    use crate::words::WordError as W;
    match error {
        W::TooLarge { limit, detail } => catalog_too_large(format!("the word explorer's {limit:?} limit: {detail}")),
        W::InvalidQuery { detail, .. } => CoreError::internal(format!(
            "the word explorer refused a query while building a catalog, which asks none: {detail}"
        )),
        W::Corrupt { detail, .. } | W::UnsupportedVersion { detail, .. } => {
            CoreError::Malformed { detail: format!("the word explorer: {detail}") }
        }
        W::Io { detail } => CoreError::Io { kind: crate::error::IoKind::Other, detail },
        W::Internal { detail } => CoreError::internal(format!("the word explorer: {detail}")),
    }
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

/// An index's name in the store: its identity, and what it indexes.
fn index_name(identity: &[u8; 32], kind: Kind) -> String {
    let kind = if kind == Kind::Mdd { "mdd" } else { "mdx" };
    format!("{}.{kind}.xdidx", xdict_identity::hex(identity))
}

/// An example store's name: the edition, the extractor and the normaliser (ADR-0031 d.3), so any of the three
/// changing rebuilds it. The format is in the name too, so an old format is never mistaken for a current store.
fn examples_name(edition: &str) -> String {
    let digest = edition.strip_prefix(EDITION_SCHEME).unwrap_or(edition);
    format!(
        "examples-v{}-e{}-n{}-{digest}.xdex",
        crate::examples::FORMAT,
        crate::examples::EXTRACTOR,
        crate::examples::NORMALIZER
    )
}

/// Whether one record's raw bytes carry Chinese and are not a cross-reference. Read decoded, never rendered: the
/// sample and its confirmation only decide whether the edition is worth the render pass (ADR-0031 d.6).
fn has_chinese_record(opened: &Dict, i: usize) -> Result<bool, CoreError> {
    let record = opened.mdx.record(i)?;
    let text = String::from_utf8_lossy(&record.data);
    Ok(!text.trim_start().starts_with("@@@LINK=") && crate::examples::has_cjk(&text))
}

/// The projection's runs as the API's spans; one conversion, so `entry_text` and the examples pass can never
/// disagree about what a span is (audit, 2026-10-24).
fn text_spans(runs: Vec<xdict_entry::TextRun>) -> Vec<TextSpan> {
    runs.into_iter()
        .map(|run| TextSpan {
            start: run.start as u64,
            len: run.len as u64,
            role: run.role,
            label: run.label,
            section: run.section,
            sense: run.sense,
        })
        .collect()
}

/// A stored region as its bytes: the phrase store's decoder takes a slice, and the storage hands regions.
fn region_to_vec(region: &dyn Region) -> Result<Vec<u8>, CoreError> {
    let len = usize::try_from(region.len())
        .map_err(|_| CoreError::internal("a stored region is larger than this process can hold"))?;
    region
        .bytes(0, len)
        .map(std::borrow::Cow::into_owned)
        .map_err(|error| CoreError::internal(format!("reading a stored region: {error}")))
}

/// Whether both UTF-16 offsets fall on character boundaries of `sentence`.
fn utf16_boundaries(sentence: &str, first: u64, second: u64) -> bool {
    let mut at = 0u64;
    let mut found = 0;
    for character in sentence.chars() {
        if at == first || at == second {
            found += 1;
        }
        at += character.len_utf16() as u64;
    }
    if at == first || at == second {
        found += 1;
    }
    found == 2
}

/// The sentence's words with their UTF-16 ranges: the capture contract counts in UTF-16 units, and a span the shell
/// draws is two of them.
fn tokens_with_offsets(sentence: &str) -> Vec<(String, u64, u64)> {
    let mut tokens: Vec<(String, u64, u64)> = Vec::new();
    let mut current = String::new();
    let mut start = 0u64;
    let mut at = 0u64;
    for character in sentence.chars() {
        let width = character.len_utf16() as u64;
        if character.is_whitespace() {
            if !current.is_empty() {
                tokens.push((std::mem::take(&mut current), start, at));
            }
        } else {
            if current.is_empty() {
                start = at;
            }
            current.push(character);
        }
        at += width;
    }
    if !current.is_empty() {
        tokens.push((current, start, at));
    }
    tokens
}

/// The edition's digest, from the one form an edition has (`mdx-sha256-v1:<hex>`).
fn edition_digest(edition: &str) -> Result<[u8; 32], CoreError> {
    let hex = edition
        .strip_prefix(EDITION_SCHEME)
        .ok_or_else(|| CoreError::internal(format!("{edition:?} is not an edition")))?;
    unhex(hex)
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

/// The names a resource path is tried under: as travelled, then without a web-style `?`/`#` suffix. MDict paths
/// may hold both, so `a.css?v=2` is looked for as written and as `a.css`.
fn resource_tries(resolved: &str) -> Vec<String> {
    let mut tries = vec![resolved.to_owned()];
    if let Some(cut) = resolved.find(['?', '#']).and_then(|at| resolved.get(..at)) {
        tries.push(cut.to_owned());
    }
    tries
}

fn mime(path: &str) -> &'static str {
    // A name with no dot has no extension: `rsplit('.').next()` returned the whole path, typing a resource named
    // "css" as a stylesheet and rewriting it.
    let Some((_, extension)) = path.rsplit_once('.') else {
        return "application/octet-stream";
    };
    let ext = extension.to_ascii_lowercase();
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

/// The scheduler's card from the ledger's state.
fn schedule_card(state: CardState) -> ScheduleCard {
    ScheduleCard {
        stability: state.stability,
        difficulty: state.difficulty,
        phase: match state.phase {
            StudyPhase::New => SchedulePhase::New,
            StudyPhase::Learning => SchedulePhase::Learning,
            StudyPhase::Review => SchedulePhase::Review,
            StudyPhase::Relearning => SchedulePhase::Relearning,
        },
        last_review: state.last_review,
        due: state.due,
    }
}

/// The ledger's state from the scheduler's card.
fn card_state(card: ScheduleCard) -> CardState {
    CardState {
        stability: card.stability,
        difficulty: card.difficulty,
        phase: match card.phase {
            SchedulePhase::New => StudyPhase::New,
            SchedulePhase::Learning => StudyPhase::Learning,
            SchedulePhase::Review => StudyPhase::Review,
            SchedulePhase::Relearning => StudyPhase::Relearning,
        },
        last_review: card.last_review,
        due: card.due,
    }
}

fn schedule_grade(grade: StudyGrade) -> ScheduleGrade {
    match grade {
        StudyGrade::Again => ScheduleGrade::Again,
        StudyGrade::Hard => ScheduleGrade::Hard,
        StudyGrade::Good => ScheduleGrade::Good,
        StudyGrade::Easy => ScheduleGrade::Easy,
    }
}

fn study_grade(number: u8) -> Result<StudyGrade, CoreError> {
    match number {
        1 => Ok(StudyGrade::Again),
        2 => Ok(StudyGrade::Hard),
        3 => Ok(StudyGrade::Good),
        4 => Ok(StudyGrade::Easy),
        other => Err(CoreError::Malformed { detail: format!("grade {other} is not 1, 2, 3 or 4") }),
    }
}

/// A ledger failure as a typed core error: a busy writer or an unreadable log is loud, never a silent empty history.
fn ledger_error(error: xdict_ledger::LedgerError) -> CoreError {
    CoreError::Io { kind: crate::error::IoKind::Other, detail: format!("ledger: {error}") }
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
        // Write the damage to a second file and rename it over the index: the open dictionary's map keeps the old
        // bytes (Windows refuses a write into a mapped file, by design), and the next `open` reads the new one, so
        // what refuses it is the checksum, not the map's sharing mode.
        let damaged_path = index.with_extension("damaged");
        std::fs::write(&damaged_path, damaged).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&damaged_path, std::fs::Permissions::from_mode(0o400)).unwrap();
        }
        std::fs::rename(&damaged_path, &index).unwrap();
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

    /// Progress that keeps every report and answers `go` to the first `go_for` of them.
    struct Kept {
        reports: Mutex<Vec<(u64, u64)>>,
        go_for: usize,
    }

    impl Progress for Kept {
        fn progress(&self, done: u64, total: u64) -> bool {
            let mut reports = self.reports.lock().unwrap();
            reports.push((done, total));
            reports.len() <= self.go_for
        }
    }

    fn kept(go_for: usize) -> Kept {
        Kept { reports: Mutex::new(Vec::new()), go_for }
    }

    fn catalog_of(
        core: &Core,
        dicts: &[String],
        progress: &dyn Progress,
        entries: u64,
        bytes: u64,
    ) -> Result<(), CoreError> {
        core.word_explorer_within(dicts, progress, CatalogLimits { entries, bytes }).map(drop)
    }

    /// The catalog's key entries are bounded before any is read, a dictionary named twice counted once: one over is
    /// refused whole as a file limit, with no report and no byte read, never a catalog cut short.
    #[test]
    fn a_word_catalog_over_its_entries_is_refused_before_it_is_read() {
        use xdict_mdx_writer::Entry as W;
        let (core, dict, read) = counted(&[W::text("aa", "1"), W::text("bb", "2"), W::text("aa", "3")]);
        let twice = [dict.clone(), dict.clone()];
        let progress = kept(usize::MAX);
        let held = catalog_of(&core, &twice, &progress, 3, u64::MAX);
        assert_eq!(held, Ok(()), "a dictionary named twice is counted once");
        let progress = kept(usize::MAX);
        let refused = catalog_of(&core, &twice, &progress, 2, u64::MAX);
        assert!(matches!(refused, Err(CoreError::TooLarge { limit: Limit::File, .. })), "{refused:?}");
        assert!(progress.reports.lock().unwrap().is_empty(), "reported before the refusal");
        assert_eq!(read.load(Ordering::SeqCst), 0, "bytes were read for a catalog");
    }

    /// The text a catalog keeps is bounded to the byte: each source's handle, edition and key, and each headword
    /// once. At the bound it is held; one byte under, refused whole.
    #[test]
    fn a_word_catalog_over_its_bytes_is_refused_whole() {
        use xdict_mdx_writer::Entry as W;
        let (core, dict, _) = counted(&[W::text("aa", "1"), W::text("bb", "2"), W::text("aa", "3")]);
        let edition = core_edition(&core, &dict).len() as u64;
        let source = dict.len() as u64 + edition + 2;
        let needed = 3 * source + 2 + 2;
        let one = [dict];
        assert_eq!(catalog_of(&core, &one, &NoProgress, u64::MAX, needed), Ok(()));
        let refused = catalog_of(&core, &one, &NoProgress, u64::MAX, needed - 1);
        assert!(matches!(refused, Err(CoreError::TooLarge { limit: Limit::File, .. })), "{refused:?}");
    }

    /// One dictionary larger than a step is reported on while it is read, not only once it is done, and its
    /// cancellation is honoured there.
    #[test]
    fn one_large_dictionary_is_reported_on_while_it_is_read() {
        use xdict_mdx_writer::Entry as W;
        let count = CATALOG_PROGRESS_STEP + 904;
        let keys: Vec<String> = (0..count).map(|i| format!("w{i:05}")).collect();
        let entries: Vec<W> = keys.iter().map(|k| W::text(k, "x")).collect();
        let (core, dict, _) = counted(&entries);
        let (step, total) = (CATALOG_PROGRESS_STEP as u64, count as u64);
        let progress = kept(usize::MAX);
        assert_eq!(catalog_of(&core, std::slice::from_ref(&dict), &progress, u64::MAX, u64::MAX), Ok(()));
        // **The last (total, total) is after the explorer's indexes are built** (audit, 2026-10-24): the caller that
        // shows completion at it does not show it before the explorer can answer.
        assert_eq!(*progress.reports.lock().unwrap(), vec![(step, total), (total, total)]);
        let progress = kept(0);
        let got = catalog_of(&core, &[dict], &progress, u64::MAX, u64::MAX);
        assert!(matches!(got, Err(CoreError::Cancelled { .. })), "{got:?}");
        assert_eq!(*progress.reports.lock().unwrap(), vec![(step, total)], "a report after the cancellation");
    }

    /// The explorer's errors keep their kind: a limit stays a limit, damage stays damage, and a refused query, which
    /// building a catalog never asks, is an internal fault.
    #[test]
    fn the_explorers_errors_keep_their_kind() {
        use crate::words::{QueryProblem, WordError as E, WordLimit};
        let too_large = word_error(E::TooLarge { limit: WordLimit::CatalogEntries, detail: "x".into() });
        assert!(matches!(too_large, CoreError::TooLarge { limit: Limit::File, .. }), "{too_large:?}");
        assert!(matches!(word_error(E::Corrupt { line: 1, detail: "x".into() }), CoreError::Malformed { .. }));
        assert!(matches!(word_error(E::Io { detail: "x".into() }), CoreError::Io { .. }));
        assert!(matches!(word_error(E::Internal { detail: "x".into() }), CoreError::Internal { .. }));
        let query = word_error(E::InvalidQuery { problem: QueryProblem::Empty, detail: "x".into() });
        assert!(matches!(query, CoreError::Internal { .. }), "{query:?}");
    }
}
