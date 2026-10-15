//! What crosses the boundary: plain records and enums (ADR-0007 decision 1). Long-lived things are handles.

use std::sync::Arc;

pub use xdict_identity::FileIdentity;

use crate::source::ByteSource;

/// Serialisation for the Web binding: camel-case fields and a `type` tag, the shape TypeScript expects.
macro_rules! message {
    ($($item:item)*) => {$(
        #[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
        #[cfg_attr(feature = "serde", serde(rename_all = "camelCase", rename_all_fields = "camelCase", tag = "type"))]
        $item
    )*};
}

/// A record, with camel-case fields; or a unit-only enum, as a plain camel-case string.
macro_rules! record {
    ($($item:item)*) => {$(
        #[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
        #[cfg_attr(feature = "serde", serde(rename_all = "camelCase"))]
        $item
    )*};
}

record! {
    /// What a shell passes to [`crate::Core::new`].
    #[derive(Debug, Clone, PartialEq, Eq, Default)]
    pub struct Config {
        /// Where the registry (study data, ADR-0002 decision 4) is kept. `None`: in memory only.
        pub data_dir: Option<String>,
        /// Where per-edition indexes are kept. `None`: in memory only.
        pub cache_dir: Option<String>,
        /// The protocol the shell was built against; a mismatch is [`crate::CoreError::Incompatible`].
        pub client_protocol: u32,
        /// Random bytes for handles and lineage ids, where the core has no random source of its own (the
        /// Web). Empty natively.
        pub entropy: Vec<u8>,
        /// **Test-only**: the strip list (`dev-docs/element-sweep.md` §2.4, S1–S14, and Q6's script rules) is not
        /// applied to entries or the pages and scripts they load: comments, scripts, `javascript:` links and the rest
        /// stay as written. Only the hostile battery's lab sets it, so that its layer runs prove the shell's own
        /// layers against what the rewriter would have removed (it is compatibility, not the boundary: ADR-0007
        /// decision 14). No shell sets it; `false` when absent, in every binding.
        #[cfg_attr(feature = "serde", serde(default))]
        pub strip_off_for_tests: bool,
    }

    /// The versions a shell may need to compare, each separately (ADR-0007 decision 11).
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct Versions {
        pub protocol: u32,
        pub core: String,
        pub index_format: u32,
        pub normalization: u32,
    }

    /// What the header of an imported or opened dictionary says.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct DictInfo {
        /// Empty where the file declares none.
        pub title: String,
        pub description: String,
        /// `1.2`, `2.0` or `3.0`.
        pub format_version: String,
        pub keys: u64,
    }

    /// The result of an import.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct Imported {
        pub edition: String,
        pub lineage: String,
        pub info: DictInfo,
        pub problems: Vec<Problem>,
    }

    /// Where an entry is, in the only form a shell stores (ADR-0007 decision 2).
    #[derive(Debug, Clone, PartialEq, Eq, Hash)]
    pub struct EntryRef {
        pub edition: String,
        /// The key exactly as the file spells it.
        pub key: String,
        /// Among the records under exactly this key, 0-based, in file order. A locator, never an identity.
        pub occurrence: u32,
    }

    /// How a lookup is asked.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct LookupOptions {
        /// At most [`crate::MAX_PAGE`].
        pub limit: u32,
        pub offset: u32,
        pub mode: MatchMode,
        /// The generation of the page this one continues; `None` for a first page.
        pub generation: Option<u32>,
    }

    /// A page of references, never bodies (`core-api.md` finding 9).
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct Page {
        pub hits: Vec<Hit>,
        pub total: u64,
        /// Pages of one generation agree; an offset into another is refused.
        pub generation: u32,
        /// Problems that left no hit to carry them.
        pub problems: Vec<HitProblem>,
    }

    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct Hit {
        pub dict: String,
        pub entry: EntryRef,
        pub headword: String,
        pub how: How,
        pub problems: Vec<HitProblem>,
    }

    /// The render context, passed to everything that produces something a view shows (ADR-0007 decision 6).
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct View {
        /// Every URL the core writes is under it: `xdict://d/` natively, the Worker's own path on the Web.
        pub base_url: String,
        /// The shell's ceiling on one body, within the core's own limit: an entry, or a stylesheet, script or
        /// page it loads, as served rewritten. Images and recordings are held only to the core's limit.
        pub max_body_bytes: u64,
        /// The reader's "Original style" for this dictionary (ADR-0010 Q3): its entries and the sheets and pages they
        /// load keep the dictionary's own styles. The URL rewrite, the strip list, the roles and the CSP are the same
        /// either way (ADR-0007 decision 14). `false` when absent, in every binding.
        #[cfg_attr(feature = "serde", serde(default))]
        pub original_style: bool,
    }

    /// One entry for the entry view.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct Entry {
        pub entry: EntryRef,
        pub html: String,
        /// The Content-Security-Policy the shell must apply to the view (ADR-0007 decision 14).
        pub csp: String,
        /// Bytes the text decoder could not read and replaced.
        pub lossy_bytes: u64,
    }
}

message! {
    /// Why a lookup matched.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub enum How {
        /// Spelt as asked.
        Exact,
        /// Equal under the file's own rules (tier 1).
        Folded,
        /// Equal once marks a reader cannot type are removed (tier 2).
        Unmarked,
        /// Reached through `@@@LINK=`: the keys passed through, the query first.
        Redirect { chain: Vec<String> },
    }

    #[derive(Debug, Clone, PartialEq, Eq)]
    pub enum HitProblem {
        DanglingRedirect { from: String, target: String },
        RedirectLoop { chain: Vec<String> },
        /// The chain went past the hop limit, or one key's redirects past the fan-out limit.
        RedirectLimit { chain: Vec<String> },
    }

    /// Something an import met that did not stop it.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub enum Problem {
        /// A resource volume could not be read; its resources will be reported missing.
        VolumeUnreadable { name: String, error: crate::CoreError },
    }

    /// The answer of [`crate::Core::open`] (ADR-0007 decision 3).
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub enum Opened {
        Ready { dict: String, edition: String, info: DictInfo },
        NeedsImport { reason: ImportReason },
    }

    /// Where a link appeared, for resolving it (ADR-0007 decision 7).
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub enum LinkOrigin {
        Entry { entry: EntryRef },
        /// A stylesheet or script, by its resource path.
        Resource { path: String },
    }

    /// What a link in an entry, or a URL its script built, means.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub enum Link {
        /// Look this up, in link mode.
        Lookup { query: String, anchor: Option<String> },
        Resource { path: String },
        /// Play this recording.
        Sound { path: String },
        /// Speak this text (`sound://….tts`, MDict's own convention).
        Speak { text: String },
        /// Scroll to this anchor of the same entry.
        Anchor { name: String },
        Blocked { why: BlockReason },
    }

    #[derive(Debug, Clone, PartialEq, Eq)]
    pub enum BlockReason {
        /// Entries never reach the network.
        Remote { url: String },
        /// `javascript:` and the like.
        Script,
        UnknownScheme { scheme: String },
    }

    /// A resource's bytes, or the fact that it is missing: a value, not an error (ADR-0007 decision 8).
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub enum Resource {
        Found { path: String, mime: String, bytes: Vec<u8> },
        Missing { path: String },
    }
}

/// Where a file is: a path, or bytes the shell supplies (ADR-0007 decision 4).
#[derive(Clone)]
pub enum Location {
    Path { path: String },
    Source { name: String, source: Arc<dyn ByteSource> },
}

impl Location {
    /// The name a reader would recognise: the path's last component, or the source's name.
    pub fn name(&self) -> &str {
        match self {
            Self::Path { path } => path.rsplit(['/', '\\']).next().unwrap_or(path),
            Self::Source { name, .. } => name,
        }
    }
}

impl std::fmt::Debug for Location {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Path { path } => f.debug_struct("Path").field("path", path).finish(),
            Self::Source { name, .. } => f.debug_struct("Source").field("name", name).finish_non_exhaustive(),
        }
    }
}

/// A dictionary as a set of files (`core-api.md` finding 1).
#[derive(Debug, Clone)]
pub struct Package {
    pub mdx: Location,
    /// Resource volumes, in the order they are searched.
    pub mdd: Vec<Location>,
    /// Loose files beside the dictionary, searched before the volumes.
    pub sidecars: Vec<Location>,
}

/// Told how an import is going; answering `false` cancels it (ADR-0007 decision 3). It is asked once more just
/// before the import registers anything, so `false` there still leaves the registry as it was.
pub trait Progress: Send + Sync {
    fn progress(&self, done: u64, total: u64) -> bool;
}

/// Progress nobody watches.
pub struct NoProgress;

impl Progress for NoProgress {
    fn progress(&self, _: u64, _: u64) -> bool {
        true
    }
}

record! {
    /// Which matching a lookup uses (ADR-0007 decision 7).
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub enum MatchMode {
        /// What a reader typed: both tiers, public keys.
        Reader,
        /// What a link named: tier 1, else tier 2, internal keys included.
        Link,
    }

    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub enum ImportReason {
        /// This location was never imported.
        New,
        /// Its identity differs from the one recorded.
        Changed,
        /// The edition's index is not in the cache.
        IndexMissing,
        /// The index was written by another index format.
        IndexOutdated,
        /// The location has no identity to compare, so only re-reading it can tell.
        NoIdentity,
    }
}

record! {
    /// What the health check found in an edition (plan-macos-v1 WI-12): the problems a reader is told of, each
    /// one sentence in the shell, and every class the check counts. Kept per edition beside its index.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct Health {
        /// The checker's version ([`crate::HEALTH`]).
        pub version: u32,
        /// Entries checked: every record of the edition.
        pub entries: u64,
        /// What the reader is told, most actionable first; empty when there is nothing to say.
        pub findings: Vec<HealthFinding>,
        /// Every class counted, by its census name, for the record: most are never shown.
        pub classes: Vec<HealthClass>,
    }

    /// One thing the reader is told about an edition.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct HealthFinding {
        pub kind: FindingKind,
        /// How many places: references, entries or characters, as the kind says.
        pub count: u64,
        /// The file a `MissingFile` names.
        pub name: Option<String>,
        /// Up to three places, as the dictionary has them.
        pub examples: Vec<HealthExample>,
    }

    /// One place a finding was met: the entry's key and up to 120 characters around it.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct HealthExample {
        pub key: String,
        pub text: String,
    }

    /// One class the check counts, by its census name.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct HealthClass {
        pub name: String,
        pub count: u64,
    }

    /// What a finding is about (`dev-docs/measurements/2026-10-15-mdx-health/`, "Disposition").
    #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
    pub enum FindingKind {
        /// A stylesheet or script the entries link is not in the package: `count` references to `name`.
        MissingFile,
        /// Recordings the entries play are not in the package.
        MissingSounds,
        /// Pictures the entries show are not in the package.
        MissingImages,
        /// Cross-references name words the edition does not have, even folded.
        MissingWords,
        /// HTML written as text (`&lt;i&gt;`), shown as code.
        CodeAsText,
        /// Comment marks shown as text (`-->`, `<--`) or a broken comment hiding text: reported, never mended.
        CommentMarks,
        /// Style rules shown as text, or a style left open.
        StyleAsText,
        /// Redirects (`@@@LINK=`) that reach no entry: missing, looping, or too deep.
        BrokenRedirects,
        /// Text encoded twice (`â€™`).
        DoubleEncoded,
        /// Bytes that are not text in the edition's encoding.
        Undecodable,
        EmptyEntries,
        /// Entries over 1 MiB.
        HugeEntries,
        /// The same entry stored twice under one key.
        RepeatedEntries,
        /// Keys with edge spaces, invisible characters or HTML.
        OddHeadwords,
        /// What XDict mends as it shows the entries: control characters, stray byte-order marks, literal `\n`.
        Repaired,
    }
}
