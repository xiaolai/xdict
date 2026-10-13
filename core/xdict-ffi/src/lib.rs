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
    BlockReason, Config, CoreError, DictInfo, Entry, EntryRef, Feature, FileIdentity, Hit, HitProblem, How,
    ImportReason, Imported, IoKind, Limit, Link, LinkOrigin, LookupOptions, MatchMode, Missing, Opened, Page, Problem,
    Resource, Versions, View,
};

uniffi::setup_scaffolding!("xdict");

#[uniffi::remote(Record)]
pub struct Config {
    pub data_dir: Option<String>,
    pub cache_dir: Option<String>,
    pub client_protocol: u32,
    pub entropy: Vec<u8>,
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
    pub skin: Option<String>,
    pub max_body_bytes: u64,
}

#[uniffi::remote(Record)]
pub struct Entry {
    pub entry: EntryRef,
    pub html: String,
    pub csp: String,
    pub lossy_bytes: u64,
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

    pub fn link(&self, dict: String, url: String, origin: LinkOrigin, view: View) -> Result<Link, CoreError> {
        self.0.link(dict, url, origin, view)
    }

    pub fn resource(&self, dict: String, path: String, view: View) -> Result<Resource, CoreError> {
        self.0.resource(dict, path, view)
    }

    pub fn self_test_panic(&self) -> Result<(), CoreError> {
        self.0.self_test_panic()
    }
}
