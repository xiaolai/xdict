//! The wire contract's Rust side: the envelope, the operation bodies, and what a reply carries
//! (`apps/windows/contract/CONTRACT.md`, contract 1).

use serde::Deserialize;
use serde_json::Value;

use xdict_core::{EntryRef, FileIdentity, LinkOrigin, LookupOptions, View};

#[cfg(not(feature = "acceptance-contract2"))]
pub const CONTRACT: u32 = 1;
#[cfg(feature = "acceptance-contract2")]
pub const CONTRACT: u32 = 2;

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

/// The served base every entry URL is rewritten under (ADR-0022; the spike's WebView2 answer).
pub const BASE_URL: &str = "xdict://d/";

/// The contract's ceiling on one rendered body (`contract.json` `limits.bodyMax`).
pub const BODY_MAX: u64 = 16 * 1024 * 1024;

/// A request's answer: the record, and the bytes that travel beside it in a kind-2 frame.
pub struct Answer {
    pub record: Value,
    pub payload: Option<(Vec<u8>, String)>,
}
