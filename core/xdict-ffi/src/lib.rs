//! UniFFI bindings of `xdict-core`, for Swift (macOS, iOS) and Kotlin (Android).
//!
//! The core's records and enums are declared here as UniFFI *remote* types: the macro checks each
//! declaration against the core's own, so the two cannot drift apart silently. What a shell implements (a
//! [`ByteSource`], a [`Progress`]) is defined here, because UniFFI generates the foreign side of a trait
//! only for traits it owns, and adapted to the core's.
//!
//! The exported object is `Core`: UniFFI's Kotlin imports `com.sun.jna.*`, and an object named `Library`
//! collides with `com.sun.jna.Library` (ADR-0007 decision 1).

use std::sync::Arc;

use xdict_core as core;
use xdict_core::{
    BaseSource, BlockReason, Card, Config, CoreError, Day, DayLabel, DictInfo, DisplayOption, DisplayOptions, Entry,
    EntryRef, EntryText, Feature, FileIdentity, FindingKind, FontReason, Health, HealthClass, HealthExample,
    HealthFinding, History, Hit, HitProblem, How, ImportReason, Imported, IoKind, KeptFont, Limit, Link, LinkOrigin,
    LookupOptions, MatchMode, Missing, Opened, Page, Problem, Reading, ReadingSpan, ReadingStyle, RecordOutcome,
    Resource, SkipReason, SkippedSheet, StyleChanges, TextSpan, TextView, Versions, View,
};

uniffi::setup_scaffolding!("xdict");

#[uniffi::remote(Record)]
pub struct Config {
    pub data_dir: Option<String>,
    pub cache_dir: Option<String>,
    pub client_protocol: u32,
    pub entropy: Vec<u8>,
    #[uniffi(default = false)]
    pub strip_off_for_tests: bool,
}

#[uniffi::remote(Record)]
pub struct Versions {
    pub protocol: u32,
    pub core: String,
    pub index_format: u32,
    pub normalization: u32,
}

#[uniffi::remote(Record)]
pub struct FileIdentity {
    pub device: u64,
    pub inode: u64,
    pub size: u64,
    pub mtime_ns: i64,
    pub ctime_ns: i64,
}

#[uniffi::remote(Record)]
pub struct DictInfo {
    pub title: String,
    pub description: String,
    pub format_version: String,
    pub keys: u64,
}

#[uniffi::remote(Record)]
pub struct Imported {
    pub edition: String,
    pub lineage: String,
    pub info: DictInfo,
    pub problems: Vec<Problem>,
}

#[uniffi::remote(Record)]
pub struct EntryRef {
    pub edition: String,
    pub key: String,
    pub occurrence: u32,
}

#[uniffi::remote(Record)]
pub struct TextView {
    pub base_url: String,
    pub max_body_bytes: u64,
    pub max_text_bytes: u64,
    #[uniffi(default = false)]
    pub original_style: bool,
}

#[uniffi::remote(Record)]
pub struct TextSpan {
    pub start: u64,
    pub len: u64,
    pub role: Option<String>,
    pub label: Option<String>,
    pub section: Option<String>,
}

#[uniffi::remote(Record)]
pub struct EntryText {
    pub entry: EntryRef,
    pub text: String,
    pub spans: Vec<TextSpan>,
    pub complete: bool,
    pub omitted_bytes: u64,
    pub cut_at: u64,
    pub spans_dropped: u64,
}

#[uniffi::remote(Record)]
pub struct ReadingSpan {
    pub start: u32,
    pub len: u32,
}

#[uniffi::remote(Record)]
pub struct Reading {
    pub surface: String,
    pub lemma: String,
    pub sentence: String,
    pub span: Option<ReadingSpan>,
    pub cut: u8,
    pub quality: String,
    pub edition: String,
    pub entry_key: String,
    pub occurrence: u32,
    pub dictionary_name: String,
    pub language: String,
    pub at: f64,
    pub device: String,
}

/// What a record call did (ADR-0023): an uncertain commit is answered as such, and a retry settles it.
#[uniffi::remote(Enum)]
pub enum RecordOutcome {
    Recorded,
    Duplicate,
    Uncertain,
    SkippedLanguage,
}

#[uniffi::remote(Record)]
pub struct Card {
    pub reading: Reading,
    pub times: u32,
    /// The ids of the reading events the card collapses: what a removal names.
    pub events: Vec<String>,
}

#[uniffi::remote(Enum)]
pub enum DayLabel {
    Today,
    Yesterday,
    Weekday,
    Date,
}

#[uniffi::remote(Record)]
pub struct Day {
    pub id: String,
    pub start: f64,
    pub label: DayLabel,
    pub cards: Vec<Card>,
}

#[uniffi::remote(Record)]
pub struct History {
    pub days: Vec<Day>,
}

#[uniffi::remote(Record)]
pub struct LookupOptions {
    pub limit: u32,
    pub offset: u32,
    pub mode: MatchMode,
    pub generation: Option<u32>,
}

#[uniffi::remote(Record)]
pub struct Page {
    pub hits: Vec<Hit>,
    pub total: u64,
    pub generation: u32,
    pub problems: Vec<HitProblem>,
}

#[uniffi::remote(Record)]
pub struct Hit {
    pub dict: String,
    pub entry: EntryRef,
    pub headword: String,
    pub how: How,
    pub problems: Vec<HitProblem>,
}

#[uniffi::remote(Record)]
pub struct View {
    pub base_url: String,
    pub max_body_bytes: u64,
    #[uniffi(default = false)]
    pub original_style: bool,
}

#[uniffi::remote(Record)]
pub struct Entry {
    pub entry: EntryRef,
    pub html: String,
    pub csp: String,
    pub lossy_bytes: u64,
}

#[uniffi::remote(Record)]
pub struct Health {
    pub version: u32,
    pub entries: u64,
    pub findings: Vec<HealthFinding>,
    pub classes: Vec<HealthClass>,
}

#[uniffi::remote(Record)]
pub struct HealthFinding {
    pub kind: FindingKind,
    pub count: u64,
    pub name: Option<String>,
    pub examples: Vec<HealthExample>,
}

#[uniffi::remote(Record)]
pub struct HealthExample {
    pub key: String,
    pub text: String,
}

#[uniffi::remote(Record)]
pub struct HealthClass {
    pub name: String,
    pub count: u64,
}

#[uniffi::remote(Enum)]
pub enum FindingKind {
    MissingFile,
    MissingSounds,
    MissingImages,
    MissingWords,
    CodeAsText,
    CommentMarks,
    StyleAsText,
    BrokenRedirects,
    DoubleEncoded,
    Undecodable,
    EmptyEntries,
    HugeEntries,
    RepeatedEntries,
    OddHeadwords,
    Repaired,
}

#[uniffi::remote(Record)]
pub struct DisplayOptions {
    pub version: u32,
    pub options: Vec<DisplayOption>,
    pub css: String,
}

#[uniffi::remote(Record)]
pub struct DisplayOption {
    pub id: String,
    pub attribute: String,
    pub values: Vec<String>,
    pub default_value: String,
}

#[uniffi::remote(Record)]
pub struct ReadingStyle {
    pub version: u32,
    pub base_px: f64,
    pub base_from: BaseSource,
    pub fonts: Vec<KeptFont>,
    pub sheets: Vec<String>,
    pub skipped: Vec<SkippedSheet>,
    pub changes: StyleChanges,
}

#[uniffi::remote(Record)]
pub struct SkippedSheet {
    pub path: String,
    pub reason: SkipReason,
}

#[uniffi::remote(Enum)]
pub enum SkipReason {
    TooMany { limit: u64 },
    TooLarge { limit: u64, detail: String },
    NotFound,
    Unreadable { detail: String },
}

#[uniffi::remote(Enum)]
pub enum BaseSource {
    Page { selector: String },
    Prose { weight: u64 },
    Text { chars: u64, share: f64 },
    BrowserDefault,
}

#[uniffi::remote(Record)]
pub struct KeptFont {
    pub family: String,
    pub reason: FontReason,
    pub selector: String,
}

#[uniffi::remote(Enum)]
pub enum FontReason {
    PrivateUse,
    PseudoContent,
    Phonetic,
}

#[uniffi::remote(Record)]
pub struct StyleChanges {
    pub important: u64,
    pub page: u64,
    pub family: u64,
    pub size: u64,
    pub line_height: u64,
    pub colour: u64,
    pub weight: u64,
    pub space: u64,
    pub dropped: u64,
}

#[uniffi::remote(Enum)]
pub enum How {
    Exact,
    Folded,
    Unmarked,
    Redirect { chain: Vec<String> },
}

#[uniffi::remote(Enum)]
pub enum HitProblem {
    DanglingRedirect { from: String, target: String },
    RedirectLoop { chain: Vec<String> },
    RedirectLimit { chain: Vec<String> },
}

#[uniffi::remote(Enum)]
pub enum MatchMode {
    Reader,
    Link,
}

#[uniffi::remote(Enum)]
pub enum Problem {
    VolumeUnreadable { name: String, error: CoreError },
}

#[uniffi::remote(Enum)]
pub enum Opened {
    Ready { dict: String, edition: String, info: DictInfo },
    NeedsImport { reason: ImportReason },
}

#[uniffi::remote(Enum)]
pub enum ImportReason {
    New,
    Changed,
    IndexMissing,
    IndexOutdated,
    NoIdentity,
}

#[uniffi::remote(Enum)]
pub enum LinkOrigin {
    Entry { entry: EntryRef },
    Resource { path: String },
}

#[uniffi::remote(Enum)]
pub enum Link {
    Lookup { query: String, anchor: Option<String> },
    Resource { path: String },
    Sound { path: String },
    Speak { text: String },
    Anchor { name: String },
    Blocked { why: BlockReason },
}

#[uniffi::remote(Enum)]
pub enum BlockReason {
    Remote { url: String },
    Script,
    UnknownScheme { scheme: String },
}

#[uniffi::remote(Enum)]
pub enum Resource {
    Found { path: String, mime: String, bytes: Vec<u8> },
    Missing { path: String },
}

#[uniffi::remote(Error)]
pub enum CoreError {
    Unsupported { feature: Feature, detail: String },
    Malformed { detail: String },
    TooLarge { limit: Limit, detail: String },
    NotFound { what: Missing, detail: String },
    Io { kind: IoKind, detail: String },
    StaleHandle { detail: String },
    EditionMismatch { detail: String },
    SourceChanged { detail: String },
    Cancelled { detail: String },
    Incompatible { core: u32, client: u32, detail: String },
    Internal { detail: String },
}

#[uniffi::remote(Enum)]
pub enum Feature {
    FormatVersion { version: String },
    ResourceLibraryV3,
    RegistrationCode,
    EncryptionFlags { flags: u8 },
    LzoInV3,
    CompressionType { code: u32 },
    BlockEncryption { code: u8 },
    Encoding { name: String },
}

#[uniffi::remote(Enum)]
pub enum Limit {
    File,
    Page,
    Body,
}

#[uniffi::remote(Enum)]
pub enum Missing {
    File,
    Entry,
    Edition,
    Lineage,
}

#[uniffi::remote(Enum)]
pub enum IoKind {
    NotFound,
    PermissionDenied,
    ShortRead,
    OutOfMemory,
    Other,
}

/// Random access to a file the shell holds (`xdict_core::ByteSource`). **Called from the core's threads,
/// several at once**: an implementation must not depend on a shared cursor or on the main thread.
#[uniffi::export(with_foreign)]
pub trait ByteSource: Send + Sync {
    fn size(&self) -> u64;
    /// Exactly `len` bytes from `offset`; fewer is reported as a short read.
    fn read_at(&self, offset: u64, len: u32) -> Result<Vec<u8>, CoreError>;
    fn identity(&self) -> Option<FileIdentity>;
}

/// Told how an import is going; answering `false` cancels it. Called with no lock held.
#[uniffi::export(with_foreign)]
pub trait Progress: Send + Sync {
    fn progress(&self, done: u64, total: u64) -> bool;
}

/// Where a file is (`xdict_core::Location`).
#[derive(uniffi::Enum)]
pub enum Location {
    Path { path: String },
    Source { name: String, source: Arc<dyn ByteSource> },
}

/// A dictionary as a set of files (`xdict_core::Package`).
#[derive(uniffi::Record)]
pub struct Package {
    pub mdx: Location,
    pub mdd: Vec<Location>,
    pub sidecars: Vec<Location>,
}

struct Source(Arc<dyn ByteSource>);

impl core::ByteSource for Source {
    fn size(&self) -> u64 {
        self.0.size()
    }
    fn read_at(&self, offset: u64, len: u32) -> Result<Vec<u8>, CoreError> {
        self.0.read_at(offset, len)
    }
    fn identity(&self) -> Option<FileIdentity> {
        self.0.identity()
    }
}

struct Watcher(Arc<dyn Progress>);

impl core::Progress for Watcher {
    fn progress(&self, done: u64, total: u64) -> bool {
        self.0.progress(done, total)
    }
}

impl From<Location> for core::Location {
    fn from(location: Location) -> Self {
        match location {
            Location::Path { path } => Self::Path { path },
            Location::Source { name, source } => Self::Source { name, source: Arc::new(Source(source)) },
        }
    }
}

impl From<Package> for core::Package {
    fn from(package: Package) -> Self {
        Self {
            mdx: package.mdx.into(),
            mdd: package.mdd.into_iter().map(Into::into).collect(),
            sidecars: package.sidecars.into_iter().map(Into::into).collect(),
        }
    }
}

/// The versions, callable before a `Core` exists.
#[uniffi::export]
pub fn versions() -> Versions {
    core::Core::versions()
}

/// The protocol this binding was generated for: what a shell passes as `Config.client_protocol`.
#[uniffi::export]
pub fn protocol_version() -> u32 {
    core::PROTOCOL
}

/// `xdict_core::Core`, one per process.
#[derive(uniffi::Object)]
pub struct Core(core::Core);

#[uniffi::export]
impl Core {
    #[uniffi::constructor]
    pub fn new(config: Config) -> Result<Arc<Self>, CoreError> {
        Ok(Arc::new(Self(core::Core::new(config)?)))
    }

    pub fn import(&self, package: Package, progress: Option<Arc<dyn Progress>>) -> Result<Imported, CoreError> {
        match progress {
            Some(progress) => self.0.import(package.into(), &Watcher(progress)),
            None => self.0.import(package.into(), &core::NoProgress),
        }
    }

    pub fn open(&self, package: Package) -> Result<Opened, CoreError> {
        self.0.open(package.into())
    }

    pub fn close(&self, dict: String) -> Result<(), CoreError> {
        self.0.close(dict)
    }

    pub fn lookup(&self, query: String, dicts: Vec<String>, options: LookupOptions) -> Result<Page, CoreError> {
        self.0.lookup(query, dicts, options)
    }

    pub fn suggest(&self, prefix: String, dicts: Vec<String>, limit: u32) -> Result<Vec<String>, CoreError> {
        self.0.suggest(prefix, dicts, limit)
    }

    pub fn entry(&self, dict: String, entry: EntryRef, view: View) -> Result<Entry, CoreError> {
        self.0.entry(dict, entry, view)
    }

    /// **The whole entry as plain text** (ADR-0021 d.5): spans, completeness and the budget's cut.
    pub fn entry_text(&self, dict: String, entry: EntryRef, view: TextView) -> Result<EntryText, CoreError> {
        self.0.entry_text(dict, entry, view)
    }

    pub fn link(&self, dict: String, url: String, origin: LinkOrigin, view: View) -> Result<Link, CoreError> {
        self.0.link(dict, url, origin, view)
    }

    pub fn resource(&self, dict: String, path: String, view: View) -> Result<Resource, CoreError> {
        self.0.resource(dict, path, view)
    }

    /// The edition's health report (WI-12): checked once and kept with its index; `progress` as for an import.
    pub fn health(&self, dict: String, progress: Option<Arc<dyn Progress>>) -> Result<Health, CoreError> {
        match progress {
            Some(progress) => self.0.health(dict, &Watcher(progress)),
            None => self.0.health(dict, &core::NoProgress),
        }
    }

    /// What the reading style does to an open dictionary (ADR-0010): shown in the Library's details pane.
    pub fn reading_style(&self, dict: String) -> Result<ReadingStyle, CoreError> {
        self.0.reading_style(dict)
    }

    /// The display options that apply to an open dictionary, with its defaults, and their CSS (ADR-0013).
    pub fn display_options(&self, dict: String) -> Result<DisplayOptions, CoreError> {
        self.0.display_options(dict)
    }

    /// **Records a reading** in the local history (ADR-0023): the language filter runs before anything is written, and
    /// a retry with the same operation id is one event.
    pub fn ledger_record(
        &self,
        reading: Reading,
        operation: String,
        target_languages: Vec<String>,
    ) -> Result<RecordOutcome, CoreError> {
        self.0.ledger_record(reading, operation, target_languages)
    }

    /// The days the drawer shows, in the reader's own zone: `utc_offset_seconds` east of UTC while `now` is the clock.
    pub fn ledger_history(&self, now: f64, utc_offset_seconds: i32) -> Result<History, CoreError> {
        self.0.ledger_history(now, utc_offset_seconds)
    }

    pub fn join_lineage(&self, edition: String, lineage: String) -> Result<String, CoreError> {
        self.0.join_lineage(edition, lineage)
    }

    pub fn split_lineage(&self, edition: String, new_lineage: String) -> Result<String, CoreError> {
        self.0.split_lineage(edition, new_lineage)
    }

    pub fn lineage_of(&self, edition: String) -> Result<Option<String>, CoreError> {
        self.0.lineage_of(edition)
    }

    pub fn self_test_panic(&self) -> Result<(), CoreError> {
        self.0.self_test_panic()
    }
}
