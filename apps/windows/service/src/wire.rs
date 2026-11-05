//! The wire contract's Rust side: the envelope, the operation bodies, and what a reply carries
//! (`apps/windows/contract/CONTRACT.md`, contract 5).

use serde::Deserialize;
use serde_json::Value;

use xdict_core::words::WordMode;
use xdict_core::{
    EntryRef, FileIdentity, LinkOrigin, LookupOptions, Reading, Removal, ReviewPolicy, Stamp,
    StudyGrade, View,
};

/// The product's contract. The acceptance build speaks the next one, so a mixed pair has a real mismatch to refuse.
#[cfg(not(feature = "acceptance-contract6"))]
pub const CONTRACT: u32 = 5;
#[cfg(feature = "acceptance-contract6")]
pub const CONTRACT: u32 = 6;

/// One JSON envelope's ceiling, read before it is decoded (`CONTRACT.md` §5). A maximum history of 400 cards with CJK
/// contexts must fit; the macOS envelope is the same 4 MiB.
pub const JSON_MAX: usize = 4 * 1024 * 1024;

/// One received frame: contract, id, operation, the files it may read, and its body.
#[derive(Debug, Deserialize)]
pub struct Request {
    pub id: u64,
    #[serde(default)]
    pub op: String,
    #[serde(default)]
    pub files: Vec<FileSpec>,
    #[serde(default)]
    pub operation: Value,
}

/// One file the app sends: its id, the core's name for it, a handle valid here, and the app's observation of its path.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileSpec {
    pub id: String,
    pub name: String,
    /// The value of a HANDLE the app duplicated into this process. 0 is refused at admission, never accepted.
    pub handle: u64,
    /// The app's observation of the path: `None` (JSON null) when nothing is at the path any more.
    #[serde(default)]
    pub identity: Option<FileIdentity>,
    /// A monotonic observation number; the newest wins per file.
    #[serde(default)]
    pub observed_at: u64,
    /// Contract 3: the one destination `ledgerSync` writes, opened by the app for writing. Every other file is
    /// read-only, and any other operation refuses a writable handle.
    #[serde(default)]
    pub write: bool,
}

/// A package's file: the id of an entry of `Request.files`.
#[derive(Debug, Clone, Deserialize)]
pub struct FileRef {
    pub file: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct PackageSpec {
    pub mdx: FileRef,
    #[serde(default)]
    pub mdd: Vec<FileRef>,
    #[serde(default)]
    pub sidecars: Vec<FileRef>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ImportBody {
    pub package: PackageSpec,
    #[serde(default)]
    pub progress: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenBody {
    pub package: PackageSpec,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CloseBody {
    pub dict: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LookupBody {
    pub query: String,
    #[serde(default)]
    pub dicts: Vec<String>,
    pub options: LookupOptions,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SuggestBody {
    pub prefix: String,
    #[serde(default)]
    pub dicts: Vec<String>,
    pub limit: u32,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EntryBody {
    pub dict: String,
    pub entry: EntryRef,
    pub view: View,
}

/// Contract 4: the entry view's ceiling, the text's budget and the reader's style choice. The service replaces the
/// base URL and bounds both ceilings; the app never chooses the served base.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TextViewBody {
    pub base_url: String,
    pub max_body_bytes: u64,
    pub max_text_bytes: u64,
    #[serde(default)]
    pub original_style: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EntryTextBody {
    pub dict: String,
    pub entry: EntryRef,
    pub view: TextViewBody,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LinkBody {
    pub dict: String,
    pub url: String,
    pub origin: LinkOrigin,
    pub view: View,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ResourceBody {
    pub dict: String,
    pub path: String,
    pub view: View,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DictBody {
    pub dict: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JoinLineageBody {
    pub edition: String,
    pub lineage: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SplitLineageBody {
    pub edition: String,
    pub new_lineage: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LineageOfBody {
    pub edition: String,
}

// MARK: - Contract 2: the learning set

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EntryGlossBody {
    pub entry: EntryRef,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LedgerRecordBody {
    pub reading: Reading,
    pub operation: String,
    #[serde(default)]
    pub target_languages: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LedgerHistoryBody {
    pub now: f64,
    pub utc_offset_seconds: i32,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LedgerRemovalBody {
    pub removal: Removal,
    pub operation: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EraseBody {
    pub stamp: Stamp,
    pub operation: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StudyNoteBody {
    pub dict: String,
    pub entry: EntryRef,
    pub text: String,
    pub name: String,
    pub stamp: Stamp,
    pub operation: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StudyNoteAtBody {
    pub entry: EntryRef,
    pub text: String,
    pub name: String,
    pub stamp: Stamp,
    pub operation: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DefinitionHashBody {
    pub dict: String,
    pub entry: EntryRef,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReanchorBody {
    pub old_edition: String,
    pub new_edition: String,
    pub stamp: Stamp,
    pub operation_prefix: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QueueBody {
    pub now: f64,
    pub limit: u32,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GradeBody {
    pub target: String,
    pub revision: String,
    pub grade: StudyGrade,
    pub policy: ReviewPolicy,
    pub stamp: Stamp,
    pub operation: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UndoBody {
    pub target: String,
    pub grade_event: String,
    pub stamp: Stamp,
    pub operation: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SummaryBody {
    pub now: f64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ResolveBody {
    pub target: String,
    pub keep: String,
    pub stamp: Stamp,
    pub operation: String,
}

/// Contract 3's one sync pass: the device names the output file; the request's files are the peers to merge and the
/// single writable destination. No path crosses the pipe.
#[derive(Debug, Deserialize)]
pub struct SyncBody {
    pub device: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExploreBody {
    pub dicts: Vec<String>,
    pub mode: WordMode,
    pub text: String,
    pub offset: u32,
    pub limit: u32,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CollocatesBody {
    pub query: String,
    pub dicts: Vec<String>,
    pub limit: u32,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExamplesBody {
    pub query: String,
    pub dicts: Vec<String>,
    pub limit: u32,
}

#[derive(Debug, Deserialize)]
pub struct PhraseTerm {
    pub location: u64,
    pub length: u64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PhrasesBody {
    pub sentence: String,
    pub term: PhraseTerm,
    pub dicts: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SetWordPackBody {
    pub file: FileRef,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BuildWordPackBody {
    pub sources: Vec<FileRef>,
    pub manifest: FileRef,
}

/// The served base every entry URL is rewritten under (ADR-0022; the spike's WebView2 answer).
pub const BASE_URL: &str = "xdict://d/";

/// The contract's ceiling on one rendered body (`contract.json` `limits.bodyMax`).
pub const BODY_MAX: u64 = 16 * 1024 * 1024;

/// A request's answer: the record, and the bytes that travel beside it in a kind-2 frame.
pub struct Answer {
    pub record: Value,
    pub payload: Option<(Vec<u8>, String)>,
}
