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
use xdict_core::collocations::{Collocation, Frame};
use xdict_core::explore::{ExploreAnswer, ExploreReason, ExploreRow, ExploreState};
use xdict_core::words::WordMode;
use xdict_core::{
    BaseSource, BlockReason, Card, CardConflict, CardState, Config, ConflictCandidate, CoreError, Coverage,
    CoverageEntry, Day, DayLabel, DictInfo, DisplayOption, DisplayOptions, Entry, EntryRef, EntryText, EraseReport,
    ExampleHit, ExampleSource, Examples, ExamplesBuilt, Feature, FileIdentity, FindingKind, FontReason, Health,
    HealthClass, HealthExample, HealthFinding, History, Hit, HitProblem, How, ImportReason, Imported, IoKind, KeptFont,
    Limit, Link, LinkOrigin, LookupOptions, MatchMode, Missing, Note, Opened, Page, PhraseAnswer, PhraseBuilt,
    PhraseMatch, PhraseState, Problem, Reading, ReadingSpan, ReadingStyle, ReanchorOutcome, ReanchorReport,
    ReanchorResult, RecordOutcome, Recoverability, Removal, Resource, ReviewOutcome, ReviewPolicy, ReviewSummary,
    Sense, Separation, SkipReason, SkippedSheet, Stamp, StudyCard, StudyGrade, StudyPhase, StudyTarget, StyleChanges,
    SyncReport, TargetKind, TextSpan, TextView, Versions, View, Words,
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
    /// The innermost sense containing this run (ADR-0029 d.2).
    pub sense: Option<u32>,
}

/// One sense the entry's markup names (ADR-0029 d.2).
#[uniffi::remote(Record)]
pub struct Sense {
    pub id: u32,
    pub start: u64,
    pub len: u64,
    pub label: Option<String>,
    pub section: Option<String>,
    pub parent: Option<u32>,
    pub whole: bool,
}

#[uniffi::remote(Record)]
pub struct EntryText {
    pub entry: EntryRef,
    pub text: String,
    pub spans: Vec<TextSpan>,
    pub senses: Vec<Sense>,
    pub style: u32,
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
    /// The card was not in the state the caller saw, or was not due: nothing was written.
    Ineligible,
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

#[uniffi::remote(Enum)]
pub enum TargetKind {
    Entry,
}

#[uniffi::remote(Record)]
pub struct StudyTarget {
    pub lineage: String,
    pub entry_key: String,
    pub occurrence: u32,
    pub kind: TargetKind,
    pub edition: String,
    pub definition_hash: String,
}

/// When and by which device: the pair every study event carries.
#[uniffi::remote(Record)]
pub struct Stamp {
    pub at: f64,
    pub device: String,
}

/// The reader's scheduling settings for a grade.
#[uniffi::remote(Record)]
pub struct ReviewPolicy {
    pub retention: f64,
    pub maximum_days: i64,
}

#[uniffi::remote(Enum)]
pub enum StudyGrade {
    Again,
    Hard,
    Good,
    Easy,
}

#[uniffi::remote(Enum)]
pub enum StudyPhase {
    New,
    Learning,
    Review,
    Relearning,
}

#[uniffi::remote(Record)]
pub struct CardState {
    pub stability: Option<f64>,
    pub difficulty: Option<f64>,
    pub phase: StudyPhase,
    pub last_review: Option<f64>,
    pub due: Option<f64>,
}

#[uniffi::remote(Record)]
pub struct Note {
    pub target: StudyTarget,
    pub text: String,
    pub at: f64,
    pub device: String,
}

#[uniffi::remote(Record)]
pub struct StudyCard {
    pub target: StudyTarget,
    pub note: Note,
    pub state: CardState,
    pub head: String,
    pub note_head: String,
    pub grades: u64,
}

#[uniffi::remote(Enum)]
pub enum Recoverability {
    FreeBlocks,
}

#[uniffi::remote(Record)]
pub struct EraseReport {
    pub cleared_readings: u64,
    pub cleared_notes: u64,
    pub cleared_grades: u64,
    pub recoverable: Recoverability,
}

#[uniffi::remote(Record)]
pub struct ReviewSummary {
    pub due: u64,
    pub next_due: Option<u64>,
}

#[uniffi::remote(Record)]
pub struct ReviewOutcome {
    pub outcome: RecordOutcome,
    pub card: StudyCard,
}

#[uniffi::remote(Enum)]
pub enum ReanchorResult {
    Reanchored,
    Reordered,
    Changed,
    Missing,
}

#[uniffi::remote(Record)]
pub struct ReanchorOutcome {
    pub target: StudyTarget,
    pub result: ReanchorResult,
}

#[uniffi::remote(Record)]
pub struct ReanchorReport {
    pub outcomes: Vec<ReanchorOutcome>,
}

#[uniffi::remote(Record)]
pub struct ConflictCandidate {
    pub id: String,
    pub grade: StudyGrade,
    pub at: f64,
    pub device: String,
    pub after: CardState,
}

#[uniffi::remote(Record)]
pub struct CardConflict {
    pub target: StudyTarget,
    pub note: Note,
    pub candidates: Vec<ConflictCandidate>,
}

#[uniffi::remote(Record)]
pub struct Removal {
    pub event_ids: Vec<String>,
    pub at: f64,
    pub device: String,
}

#[uniffi::remote(Record)]
pub struct SyncReport {
    pub exported: u64,
    pub peers: u64,
    pub added: u64,
    pub skipped: u64,
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

/// **One dictionary's words, a page at a time** (plan-setup-v2 WI-6, ADR-0028): what Core Spotlight indexes.
#[uniffi::remote(Record)]
pub struct Words {
    pub edition: String,
    pub words: Vec<String>,
    pub total: u64,
    pub next: u64,
}

/// **The reverse-example query's answer** (ADR-0031, plan-reverse-examples WI-4).
#[uniffi::remote(Record)]
pub struct Examples {
    pub hits: Vec<ExampleHit>,
    pub total: u64,
    pub not_ready: Vec<String>,
    pub capped: bool,
}

#[uniffi::remote(Record)]
pub struct ExampleHit {
    pub english: String,
    pub chinese: String,
    pub start: u64,
    pub len: u64,
    pub sentence: bool,
    pub sources: Vec<ExampleSource>,
}

#[uniffi::remote(Record)]
pub struct ExampleSource {
    pub dict: String,
    pub entry: EntryRef,
    pub headword: String,
}

/// **What building one dictionary's store did** (ADR-0031 d.3, d.6).
#[uniffi::remote(Record)]
pub struct ExamplesBuilt {
    pub edition: String,
    pub pairs: u64,
    pub roles: u64,
    pub fallback: u64,
    pub entries: u64,
    pub failed: u64,
    pub no_chinese: bool,
    pub cached: bool,
}

/// **One phrase found around the captured term** (`dev-docs/plan-phrase-recognition.md` WI-6): the dictionary's own
/// spelling, the sentence span in UTF-16 units, and how far the words were allowed to separate.
#[uniffi::remote(Record)]
pub struct PhraseMatch {
    pub dict: String,
    /// The dictionary's own spelling, slots and all — the string to look up.
    pub phrase: String,
    pub location: u64,
    pub length: u64,
    pub separation: Separation,
    pub gap: u64,
}

#[uniffi::remote(Enum)]
pub enum Separation {
    None,
    Marked { words: u64 },
    Inferred { words: u64 },
}

#[uniffi::remote(Record)]
pub struct CoverageEntry {
    pub dict: String,
    pub state: Coverage,
}

#[uniffi::remote(Enum)]
pub enum Coverage {
    Ready,
    Building,
    Unavailable,
}

/// **What [`Core::phrases`] answers**: what was searched, and what was found.
#[uniffi::remote(Record)]
pub struct PhraseAnswer {
    pub state: PhraseState,
    pub matches: Vec<PhraseMatch>,
    pub coverage: Vec<CoverageEntry>,
    /// Every match found before the cap; `matches` holds `total` when it is at or under it.
    pub total: u64,
    pub capped: bool,
}

#[uniffi::remote(Enum)]
pub enum PhraseState {
    NotAsked,
    Building,
    Unavailable,
    None,
    Found,
}

/// **What building one dictionary's phrase inventory did.**
#[uniffi::remote(Record)]
pub struct PhraseBuilt {
    pub edition: String,
    pub phrases: u64,
    pub cached: bool,
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
    /// A sentence longer than the phrase question accepts.
    Sentence,
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

/// **A collocation's frame** (plan-word-exploration WI-6): the closed vocabulary, with the headword written `HW`.
#[uniffi::remote(Enum)]
pub enum Frame {
    Adjective,
    Adverb,
    Noun,
    Verb,
    Verbs,
    Preposition,
    Phrases,
    AdjectivePlusHeadword,
    VerbPlusHeadword,
    HeadwordPlusVerb,
    HeadwordPlusNoun,
    NounPlusHeadword,
    PhraseOfHeadword,
}

/// One collocation a dictionary writes.
#[uniffi::remote(Record)]
pub struct Collocation {
    pub lemma: String,
    pub frame: Frame,
    pub partner: String,
    pub dict: String,
    pub entry: EntryRef,
}

/// What to look for: the words a reader can explore by.
#[uniffi::remote(Enum)]
pub enum WordMode {
    /// Headwords whose spelling ends with the query's.
    EndsWith,
    /// Headwords within `max_distance` (1 to 3) edits.
    Fuzzy { max_distance: u8 },
    /// Headwords sharing the query's rime (pack data only).
    Rhyme,
    /// Members of every paradigm the query belongs to (pack data only).
    Inflections,
    /// The query's derivational family (pack data only).
    Derivations,
    /// Headwords sharing a historical ancestor within `max_depth` (pack data only).
    Roots { max_depth: u8 },
    /// Headwords the pack's synsets call this word's synonyms.
    Synonyms,
    /// Headwords the pack's synsets call its antonyms.
    Antonyms,
}

/// **Word exploration across the boundary** (plan-word-exploration WI-4): a row is the word, the dictionary and entry
/// it opens, and a *label* — never a sentence, since the core holds no text in any language.
#[uniffi::remote(Record)]
pub struct ExploreRow {
    pub word: String,
    pub dict: String,
    pub entry: EntryRef,
    pub reason: ExploreReason,
}

/// Why a row is in the answer.
#[uniffi::remote(Enum)]
pub enum ExploreReason {
    Exact,
    EndsWith,
    Spelling { distance: u8 },
    Rhyme,
    Inflection,
    Derivation,
    SharedOrigin,
    Synonym,
    Antonym,
}

/// Whether the dictionaries could be searched at all: absence of data is never absence of relatives.
#[uniffi::remote(Enum)]
pub enum ExploreState {
    Answered,
    NoData,
    Unknown,
}

/// One page of an exploration.
#[uniffi::remote(Record)]
pub struct ExploreAnswer {
    pub state: ExploreState,
    pub rows: Vec<ExploreRow>,
    pub next: Option<u32>,
    pub exhausted: bool,
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

    /// **A page of one dictionary's words**, for Core Spotlight (plan-setup-v2 WI-6, ADR-0028: headwords only).
    /// Spotlight is macOS's, so `xdict-wasm`, the Web binding, does not carry it.
    pub fn words(&self, dict: String, from: u64, limit: u32) -> Result<Words, CoreError> {
        self.0.words(dict, from, limit)
    }

    /// **The collocations of a word** (plan-word-exploration WI-6), from the reader's own dictionaries.
    pub fn collocates(&self, query: String, dicts: Vec<String>, limit: u32) -> Result<Vec<Collocation>, CoreError> {
        self.0.collocates(query, dicts, limit)
    }

    /// **One page of word exploration** (plan-word-exploration WI-4): a miss, a rhyme, a family or a root, answered
    /// with the reader's own dictionaries' words — every row names the entry it opens.
    pub fn explore(
        &self,
        dicts: Vec<String>,
        mode: WordMode,
        text: String,
        offset: u32,
        limit: u32,
    ) -> Result<ExploreAnswer, CoreError> {
        self.0.explore(dicts, mode, text, offset, limit)
    }

    /// **The reverse-example query** (ADR-0031, plan-reverse-examples WI-4): the pairs whose Chinese carries the
    /// query, from the dictionaries with a store; one without is `not_ready`, never an error.
    pub fn examples(&self, query: String, dicts: Vec<String>, limit: u32) -> Result<Examples, CoreError> {
        self.0.examples(query, dicts, limit)
    }

    /// **Builds one dictionary's example store in the background** (ADR-0031 d.3, d.6): `progress` reports records
    /// done and answers `false` to cancel, in which case nothing is written.
    pub fn examples_build(
        &self,
        dict: String,
        progress: Option<Arc<dyn Progress>>,
    ) -> Result<ExamplesBuilt, CoreError> {
        match progress {
            Some(progress) => self.0.examples_build(dict, &Watcher(progress)),
            None => self.0.examples_build(dict, &core::NoProgress),
        }
    }

    /// **The phrases covering the term in a captured sentence** (plan-phrase-recognition WI-5): every ready
    /// dictionary's phrase that covers the term's word, best first, with the state of each dictionary that could not
    /// answer. The sentence and the term are re-validated here; nothing is sent anywhere.
    pub fn phrases(
        &self,
        sentence: String,
        term_location: u64,
        term_length: u64,
        dicts: Vec<String>,
    ) -> Result<PhraseAnswer, CoreError> {
        self.0.phrases(sentence, term_location, term_length, dicts)
    }

    /// **Builds one dictionary's phrase inventory in the background** (plan-phrase-recognition WI-4): `progress`
    /// reports records done and answers `false` to cancel, in which case nothing is written.
    pub fn phrases_build(&self, dict: String, progress: Option<Arc<dyn Progress>>) -> Result<PhraseBuilt, CoreError> {
        match progress {
            Some(progress) => self.0.phrases_build(dict, &Watcher(progress)),
            None => self.0.phrases_build(dict, &core::NoProgress),
        }
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

    /// **Saves the reader's note on an entry** (plan §5.1) and enrols it for review.
    pub fn study_note(
        &self,
        dict: String,
        entry: EntryRef,
        text: String,
        name: String,
        stamp: Stamp,
        operation: String,
    ) -> Result<Note, CoreError> {
        self.0.study_note(dict, entry, text, name, stamp, operation)
    }

    /// A note named by the history card's facts (an `EntryRef`), resolved to the open dictionary of its edition.
    pub fn study_note_at(
        &self,
        entry: EntryRef,
        text: String,
        name: String,
        stamp: Stamp,
        operation: String,
    ) -> Result<Note, CoreError> {
        self.0.study_note_at(entry, text, name, stamp, operation)
    }

    /// The log's events as the reader's export: one JSON document, no dictionary content.
    pub fn ledger_export_json(&self) -> Result<String, CoreError> {
        self.0.ledger_export_json()
    }

    pub fn study_notes(&self) -> Result<Vec<Note>, CoreError> {
        self.0.study_notes()
    }

    /// The review queue: due cards, soonest first, a new card at once.
    pub fn review_queue(&self, now: f64, limit: u32) -> Result<Vec<StudyCard>, CoreError> {
        self.0.review_queue(now, limit)
    }

    /// One grade under the reader's configuration: the card transitions, and the event records the configuration.
    pub fn review_grade(
        &self,
        target_key: String,
        revision: String,
        grade: u8,
        policy: ReviewPolicy,
        stamp: Stamp,
        operation: String,
    ) -> Result<ReviewOutcome, CoreError> {
        self.0.review_grade(target_key, revision, grade, policy, stamp, operation)
    }

    /// Voids the card's latest grade while the card is still in the state it produced.
    pub fn review_undo(
        &self,
        target_key: String,
        grade_event: String,
        stamp: Stamp,
        operation: String,
    ) -> Result<ReviewOutcome, CoreError> {
        self.0.review_undo(target_key, grade_event, stamp, operation)
    }

    pub fn review_summary(&self, now: f64) -> Result<ReviewSummary, CoreError> {
        self.0.review_summary(now)
    }

    /// The hash a note records for an entry's definition; never the definition itself.
    pub fn definition_hash_of(&self, dict: String, entry: EntryRef) -> Result<String, CoreError> {
        self.0.definition_hash_of(dict, entry)
    }

    /// Re-anchors notes of one edition to another under the same lineage (plan §5.1).
    pub fn study_reanchor(
        &self,
        old_edition: String,
        new_edition: String,
        stamp: Stamp,
        operation_prefix: String,
    ) -> Result<ReanchorReport, CoreError> {
        self.0.study_reanchor(old_edition, new_edition, stamp, operation_prefix)
    }

    /// **The cards two devices left conflicted** (ADR-0027): the reader chooses a branch.
    pub fn review_conflicts(&self) -> Result<Vec<CardConflict>, CoreError> {
        self.0.review_conflicts()
    }

    /// Keeps one branch of a conflict; replay voids the others and what descended from them.
    pub fn review_resolve(
        &self,
        target: String,
        keep: String,
        stamp: Stamp,
        operation: String,
    ) -> Result<ReviewOutcome, CoreError> {
        self.0.review_resolve(target, keep, stamp, operation)
    }

    /// **One sync pass** (plan §2.6): merges every peer log in `input` and writes this device's log to `output`.
    pub fn ledger_sync(&self, input: String, output: String, device: String) -> Result<SyncReport, CoreError> {
        self.0.ledger_sync(input, output, device)
    }

    /// **Hides the readings a history card is made of**, behind a tombstone that carries no content (ADR-0024).
    pub fn ledger_remove(&self, removal: Removal, operation: String) -> Result<RecordOutcome, CoreError> {
        self.0.ledger_remove(removal, operation)
    }

    /// Shows them again: the same tombstone's shape, applied in reverse.
    pub fn ledger_restore(&self, restore: Removal, operation: String) -> Result<RecordOutcome, CoreError> {
        self.0.ledger_restore(restore, operation)
    }

    pub fn join_lineage(&self, edition: String, lineage: String) -> Result<String, CoreError> {
        self.0.join_lineage(edition, lineage)
    }

    pub fn split_lineage(&self, edition: String, new_lineage: String) -> Result<String, CoreError> {
        self.0.split_lineage(edition, new_lineage)
    }

    /// **Erase is a rewrite** (ADR-0024): readings, notes and grades leave the log; associations stay.
    pub fn ledger_erase(&self, operation: String, at: f64, device: String) -> Result<EraseReport, CoreError> {
        self.0.ledger_erase(operation, at, device)
    }

    pub fn lineage_of(&self, edition: String) -> Result<Option<String>, CoreError> {
        self.0.lineage_of(edition)
    }

    pub fn self_test_panic(&self) -> Result<(), CoreError> {
        self.0.self_test_panic()
    }
}
