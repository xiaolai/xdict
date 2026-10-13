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

/// A unit-only enum: a plain camel-case string.
macro_rules! unit {
    ($($item:item)*) => {$(
        #[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
        #[cfg_attr(feature = "serde", serde(rename_all = "camelCase"))]
        $item
    )*};
}

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

/// Told how an import is going; answering `false` cancels it (ADR-0007 decision 3).
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

unit! {
    /// Which matching a lookup uses (ADR-0007 decision 7).
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub enum MatchMode {
        /// What a reader typed: both tiers, public keys.
        Reader,
        /// What a link named: tier 1 only, internal keys included.
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
