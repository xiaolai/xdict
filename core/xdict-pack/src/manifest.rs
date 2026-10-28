//! The pinned-sources manifest and its raw files: what is read, checked, and what it says for the notices.

use std::path::{Path, PathBuf};

use serde_json::Value as Json;
use sha2::{Digest, Sha256};

use crate::error::{PackError, PackErrorKind, PackResult};
use crate::json::hex;
use crate::limits::{MANIFEST_FORMAT, MANIFEST_VERSION, MAX_MANIFEST_BYTES, MAX_NOTICE_BYTES, PROVIDERS};
use crate::text::https_host;

/// A notice file a source ships beside it, pinned by hash and recognised by a marker string.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NoticeFile {
    /// The plain file name, beside the manifest's raw directory.
    pub file: String,
    /// A string the file must contain, so a wrong file fails here and not in a reader's hands.
    pub marker: String,
    /// The pinned SHA-256.
    pub sha256: String,
}

/// One source the manifest pins.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Source {
    /// The source id, which is also the prefix of every record it contributes.
    pub id: String,
    /// The provider, which chooses the parser.
    pub provider: String,
    /// The source's name as the header lists it.
    pub name: String,
    /// The https URL, or a Kaikki source's url prefix.
    pub url: String,
    /// The pinned version.
    pub version: String,
    /// The pinned SHA-256 of the raw download.
    pub sha256: String,
    /// The plain file name inside the raw directory.
    pub file: String,
    /// The pinned size in bytes.
    pub bytes: u64,
    /// The licence expression.
    pub licence: String,
    /// A short attribution.
    pub attribution: String,
    /// The complete notice, when the source carries one inline.
    pub notice: Option<String>,
    /// Notice files beside the raw download.
    pub notice_files: Vec<NoticeFile>,
    /// What the source covers, when it says.
    pub coverage: Option<String>,
}

/// One complete notice, as the notices sidecar writes it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Notice {
    /// The file name, or `None` for an inline notice.
    pub file: Option<String>,
    /// The text, verbatim.
    pub text: String,
    /// The SHA-256 of the file as read, or `None` for an inline notice.
    pub sha256: Option<String>,
}

impl Source {
    /// Whether this source is one a build reads: a Kaikki source is only read through a receipt, which this crate
    /// does not take.
    pub fn is_kaikki(&self) -> bool {
        self.provider == "kaikki"
    }

    /// The raw file's path inside `raw_dir`.
    pub fn path(&self, raw_dir: &Path) -> PathBuf {
        raw_dir.join(&self.file)
    }
}

fn sha256_hex(text: &str) -> bool {
    text.len() == 64 && text.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn plain_file(text: &str) -> bool {
    let mut bytes = text.bytes();
    let Some(first) = bytes.next() else { return false };
    first.is_ascii_alphanumeric() && bytes.all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

fn source_prefix(text: &str) -> bool {
    let mut bytes = text.bytes();
    let Some(first) = bytes.next() else { return false };
    (first.is_ascii_lowercase()) && bytes.all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}

/// Whether `text` is a source id the loader reads: letters, digits and `- _ . :`.
pub fn source_id(text: &str) -> bool {
    let Some((prefix, part)) = text.split_once(':') else { return source_prefix(text) && !text.is_empty() };
    if !source_prefix(prefix) {
        return false;
    }
    if let Some(hex_part) = part.strip_prefix("sha256:") {
        return sha256_hex(hex_part);
    }
    !part.is_empty() && part.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

fn text_field<'a>(entry: &'a Json, key: &str) -> Option<&'a str> {
    entry.get(key).and_then(Json::as_str)
}

fn malformed(where_: &str, message: impl Into<String>) -> PackError {
    PackError::at_source(PackErrorKind::Malformed, where_.to_string(), message)
}

fn licence(where_: &str, message: impl Into<String>) -> PackError {
    PackError::at_source(PackErrorKind::Licence, where_.to_string(), message)
}

/// Whether a value is still `pending`, which the reference implementation refuses by name.
fn pending(value: &Json) -> bool {
    value.as_str().is_some_and(|text| text.trim().to_lowercase() == "pending")
}

/// Reads and validates the manifest at `path`, its sources sorted by id.
///
/// A wrong format or version is `version`; a `pending` value anywhere is `pending`; a missing licence, attribution
/// or notice is `licence`; anything else out of shape (a URL not https, a SHA-256 not 64 lowercase hex digits, a
/// file name with a path in it, a duplicate id, an unknown provider) is `malformed`.
pub fn read_manifest(path: &Path) -> PackResult<Vec<Source>> {
    // Read through a cap: a manifest is a few KiB, and one that is not is refused rather than held.
    let text = std::fs::File::open(path)
        .and_then(|file| {
            use std::io::Read as _;
            let mut held = Vec::new();
            file.take(MAX_MANIFEST_BYTES).read_to_end(&mut held)?;
            Ok(held)
        })
        .map_err(|error| {
            PackError::at_source(PackErrorKind::Malformed, "manifest", format!("unreadable manifest: {error}"))
        })?;
    let text = String::from_utf8(text).map_err(|error| {
        PackError::at_source(PackErrorKind::Malformed, "manifest", format!("unreadable manifest: {error}"))
    })?;
    let parsed: Json = serde_json::from_str(&text).map_err(|error| {
        PackError::at_source(PackErrorKind::Malformed, "manifest", format!("unreadable manifest: {error}"))
    })?;
    load_manifest(&parsed)
}

/// Validates a parsed manifest and returns its sources, sorted by id.
pub fn load_manifest(manifest: &Json) -> PackResult<Vec<Source>> {
    if manifest.as_object().is_none() {
        return Err(malformed("manifest", "manifest is not an object"));
    }
    let format = manifest.get("format");
    let version = manifest.get("version");
    if format.and_then(Json::as_str) != Some(MANIFEST_FORMAT)
        || version.and_then(Json::as_u64) != Some(MANIFEST_VERSION)
    {
        return Err(PackError::at_source(
            PackErrorKind::Version,
            "manifest",
            format!(
                "expected format '{MANIFEST_FORMAT}' version {MANIFEST_VERSION}, found {} version {}",
                describe(format),
                describe(version)
            ),
        ));
    }
    let Some(sources) = manifest.get("sources").and_then(Json::as_array) else {
        return Err(malformed("manifest", "no sources"));
    };
    if sources.is_empty() {
        return Err(malformed("manifest", "no sources"));
    }
    let mut seen: Vec<String> = Vec::new();
    let mut out: Vec<Source> = Vec::new();
    for entry in sources {
        let Some(object) = entry.as_object() else {
            return Err(malformed("manifest", "a source is not an object"));
        };
        let id = text_field(entry, "id").unwrap_or("");
        let where_ = format!("manifest:{id}");
        if !source_prefix(id) {
            return Err(malformed("manifest", format!("bad source id '{}'", id)));
        }
        if seen.iter().any(|other| other == id) {
            return Err(malformed(&where_, "duplicate source id"));
        }
        seen.push(id.to_string());
        for (key, value) in object {
            if pending(value) {
                return Err(PackError::at_source(
                    PackErrorKind::Pending,
                    where_.clone(),
                    format!("{key} is still pending"),
                ));
            }
        }
        let provider = text_field(entry, "provider").unwrap_or("");
        if !PROVIDERS.contains(&provider) {
            return Err(malformed(&where_, format!("unknown provider '{}'", provider)));
        }
        for key in ["name", "licence", "attribution"] {
            if !text_field(entry, key).is_some_and(|value| !value.trim().is_empty()) {
                return Err(if key == "name" {
                    malformed(&where_, format!("missing {key}"))
                } else {
                    licence(&where_, format!("missing {key}"))
                });
            }
        }
        let notice = text_field(entry, "notice").filter(|text| !text.trim().is_empty());
        let files = entry.get("notice_files").and_then(Json::as_array);
        let has_files = files.is_some_and(|list| !list.is_empty());
        if notice.is_none() && !has_files {
            return Err(licence(&where_, "no notice and no notice_files"));
        }
        let notice_files = validate_notice_files(entry, &where_)?;
        if entry.get("coverage").is_some_and(|value| !value.is_string()) {
            return Err(malformed(&where_, "coverage is not a string"));
        }
        let (url, version, sha256, file, bytes) = validate_provider_entry(entry, provider, &where_)?;
        out.push(Source {
            id: id.to_string(),
            provider: provider.to_string(),
            name: text_field(entry, "name").unwrap_or("").to_string(),
            url,
            version,
            sha256,
            file,
            bytes,
            licence: text_field(entry, "licence").unwrap_or("").to_string(),
            attribution: text_field(entry, "attribution").unwrap_or("").to_string(),
            notice: notice.map(str::to_string),
            notice_files,
            coverage: entry.get("coverage").and_then(Json::as_str).map(str::to_string),
        });
    }
    out.sort_by(|left, right| left.id.cmp(&right.id));
    Ok(out)
}

fn describe(value: Option<&Json>) -> String {
    match value {
        None => "None".to_string(),
        Some(Json::String(text)) => format!("'{text}'"),
        Some(other) => other.to_string(),
    }
}

/// A source's notice files: a non-empty list of plain names, each with a marker and a pinned lowercase hash.
fn validate_notice_files(entry: &Json, where_: &str) -> PackResult<Vec<NoticeFile>> {
    let Some(files) = entry.get("notice_files") else { return Ok(Vec::new()) };
    let Some(list) = files.as_array() else {
        return Err(malformed(where_, "notice_files is not a non-empty list"));
    };
    if list.is_empty() {
        return Err(malformed(where_, "notice_files is not a non-empty list"));
    }
    let mut out = Vec::new();
    for item in list {
        let file = text_field(item, "file").unwrap_or("");
        let marker = text_field(item, "marker").unwrap_or("");
        if !plain_file(file) || marker.trim().is_empty() {
            return Err(malformed(where_, "a notice_files item needs a plain file and a marker"));
        }
        let sha = item.get("sha256");
        if sha.is_some_and(pending) {
            return Err(PackError::at_source(
                PackErrorKind::Pending,
                where_.to_string(),
                format!("notice file {file}: sha256 is still pending"),
            ));
        }
        let Some(sha) = sha.and_then(Json::as_str).filter(|text| sha256_hex(text)) else {
            return Err(malformed(where_, format!("notice file {file}: sha256 is not 64 lowercase hex digits")));
        };
        out.push(NoticeFile { file: file.to_string(), marker: marker.to_string(), sha256: sha.to_string() });
    }
    Ok(out)
}

/// A source's provider-specific fields: Kaikki's prefix, or a pinned download.
fn validate_provider_entry(
    entry: &Json,
    provider: &str,
    where_: &str,
) -> PackResult<(String, String, String, String, u64)> {
    if provider == "kaikki" {
        let prefix = text_field(entry, "url_prefix").unwrap_or("");
        if https_host(prefix).is_none() {
            return Err(malformed(where_, "kaikki needs an https url_prefix"));
        }
        return Ok((prefix.to_string(), String::new(), String::new(), String::new(), 0));
    }
    let url = text_field(entry, "url").unwrap_or("");
    if https_host(url).is_none() {
        return Err(malformed(where_, "url is not an https address with a host"));
    }
    let version = text_field(entry, "version").unwrap_or("");
    if version.trim().is_empty() {
        return Err(malformed(where_, "missing version"));
    }
    let sha256 = text_field(entry, "sha256").unwrap_or("");
    if !sha256_hex(sha256) {
        return Err(malformed(where_, "sha256 is not 64 lowercase hex digits"));
    }
    let file = text_field(entry, "file").unwrap_or("");
    if !plain_file(file) {
        return Err(malformed(where_, "file must be a plain file name"));
    }
    let Some(bytes) = entry.get("bytes").and_then(Json::as_u64).filter(|size| *size > 0) else {
        return Err(malformed(where_, "bytes must be a positive integer"));
    };
    Ok((url.to_string(), version.to_string(), sha256.to_string(), file.to_string(), bytes))
}

/// A file's SHA-256 and size.
pub fn sha256_file(path: &Path) -> PackResult<(String, u64)> {
    let file = std::fs::File::open(path)
        .map_err(|error| PackError::new(PackErrorKind::Missing, format!("{}: {error}", path.display())))?;
    let mut reader = std::io::BufReader::new(file);
    let mut digest = Sha256::new();
    let mut size = 0u64;
    let mut chunk = vec![0u8; 1 << 20];
    loop {
        let read = std::io::Read::read(&mut reader, &mut chunk)
            .map_err(|error| PackError::new(PackErrorKind::Missing, format!("{}: {error}", path.display())))?;
        if read == 0 {
            break;
        }
        let Some(used) = chunk.get(..read) else { break };
        digest.update(used);
        size += read as u64;
    }
    Ok((hex(&digest.finalize()), size))
}

/// Hashes `path` and returns **the open handle it hashed**, rewound to the start: what is parsed is then the very
/// bytes that were checked, even if the path is replaced under the build meanwhile.
pub fn verify_open(path: &Path, sha256: &str, size: Option<u64>, source: &str) -> PackResult<std::fs::File> {
    use std::io::{Read as _, Seek as _, SeekFrom};
    if !path.is_file() {
        return Err(PackError::at_source(PackErrorKind::Missing, source, format!("{} is not a file", path.display())));
    }
    let mut file = std::fs::File::open(path).map_err(|error| {
        PackError::at_source(PackErrorKind::Missing, source, format!("{}: {error}", path.display()))
    })?;
    let mut digest = Sha256::new();
    let mut actual_size = 0u64;
    let mut chunk = vec![0u8; 1 << 20];
    loop {
        let read = file.read(&mut chunk).map_err(|error| {
            PackError::at_source(PackErrorKind::Missing, source, format!("{}: {error}", path.display()))
        })?;
        if read == 0 {
            break;
        }
        if let Some(used) = chunk.get(..read) {
            digest.update(used);
        }
        actual_size += read as u64;
    }
    let actual = hex(&digest.finalize());
    if let Some(size) = size
        && actual_size != size
    {
        return Err(PackError::at_source(
            PackErrorKind::Hash,
            source,
            format!("{}: {actual_size} bytes, expected {size}", path.display()),
        ));
    }
    if actual != sha256 {
        return Err(PackError::at_source(
            PackErrorKind::Hash,
            source,
            format!("{}: sha256 {actual}, expected {sha256}", path.display()),
        ));
    }
    file.seek(SeekFrom::Start(0)).map_err(|error| {
        PackError::at_source(PackErrorKind::Missing, source, format!("{}: {error}", path.display()))
    })?;
    Ok(file)
}

/// Hashes `path` and returns its SHA-256 if it and the size match; `missing` or `hash` otherwise.
pub fn verify_file(path: &Path, sha256: &str, size: Option<u64>, source: &str) -> PackResult<String> {
    if !path.is_file() {
        return Err(PackError::at_source(PackErrorKind::Missing, source, format!("{} is not a file", path.display())));
    }
    let (actual, actual_size) = sha256_file(path)?;
    if let Some(size) = size
        && actual_size != size
    {
        return Err(PackError::at_source(
            PackErrorKind::Hash,
            source,
            format!("{}: {actual_size} bytes, expected {size}", path.display()),
        ));
    }
    if actual != sha256 {
        return Err(PackError::at_source(
            PackErrorKind::Hash,
            source,
            format!("{}: sha256 {actual}, expected {sha256}", path.display()),
        ));
    }
    Ok(actual)
}

/// The source's complete notices: the inline `notice`, then each `notice_files` file verbatim, which must match its
/// pinned `sha256` and contain its `marker`.
pub fn read_notices(source: &Source, notice_dir: &Path) -> PackResult<Vec<Notice>> {
    let mut out = Vec::new();
    if let Some(text) = source.notice.as_ref().filter(|text| !text.trim().is_empty()) {
        out.push(Notice { file: None, text: text.clone(), sha256: None });
    }
    for item in &source.notice_files {
        let path = notice_dir.join(&item.file);
        if !path.is_file() {
            return Err(PackError::at_source(
                PackErrorKind::Missing,
                source.id.clone(),
                format!("notice file {} not found", path.display()),
            ));
        }
        // Read through a cap: a notice file that is not the one pinned must not be held whole to find that out.
        let mut data = Vec::new();
        std::fs::File::open(&path)
            .and_then(|file| {
                use std::io::Read as _;
                file.take(MAX_NOTICE_BYTES + 1).read_to_end(&mut data)
            })
            .map_err(|error| {
                PackError::at_source(PackErrorKind::Missing, source.id.clone(), format!("{}: {error}", path.display()))
            })?;
        if data.len() as u64 > MAX_NOTICE_BYTES {
            return Err(PackError::at_source(
                PackErrorKind::Bound,
                source.id.clone(),
                format!("notice file {} is over {MAX_NOTICE_BYTES} bytes", path.display()),
            ));
        }
        let actual = hex(&Sha256::digest(&data));
        if actual != item.sha256 {
            return Err(PackError::at_source(
                PackErrorKind::Hash,
                source.id.clone(),
                format!("notice file {}: sha256 {actual}, expected {}", path.display(), item.sha256),
            ));
        }
        let text = String::from_utf8(data).map_err(|_| {
            PackError::at_source(
                PackErrorKind::Malformed,
                source.id.clone(),
                format!("notice file {} is not UTF-8", path.display()),
            )
        })?;
        if !text.contains(&item.marker) {
            return Err(PackError::at_source(
                PackErrorKind::Licence,
                source.id.clone(),
                format!("notice file {} lacks '{}'", path.display(), item.marker),
            ));
        }
        out.push(Notice { file: Some(item.file.clone()), text, sha256: Some(actual) });
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::indexing_slicing)]

    use super::*;

    fn manifest() -> Json {
        serde_json::json!({
            "format": MANIFEST_FORMAT,
            "version": MANIFEST_VERSION,
            "sources": [{
                "id": "cmu",
                "provider": "cmudict",
                "name": "The CMU Pronouncing Dictionary",
                "url": "https://example.org/cmudict.dict",
                "version": "cmu@1",
                "sha256": "81917843c7f44ce2b094ac63873c2c7a4cf802040792c455ba3ca406891c3d22",
                "file": "cmudict.dict",
                "bytes": 3618488,
                "licence": "BSD-2-Clause",
                "attribution": "Carnegie Mellon University",
                "notice": "Copyright"
            }]
        })
    }

    #[test]
    fn a_manifest_reads_into_its_sources() {
        let sources = load_manifest(&manifest()).unwrap();
        assert_eq!(sources.len(), 1);
        assert_eq!(sources[0].id, "cmu");
        assert_eq!(sources[0].bytes, 3618488);
    }

    #[test]
    fn a_wrong_version_is_a_version_failure() {
        let mut value = manifest();
        value["version"] = serde_json::json!(1);
        let error = load_manifest(&value).unwrap_err();
        assert_eq!(error.kind(), PackErrorKind::Version);
    }

    #[test]
    fn a_pending_value_is_refused_by_name() {
        let mut value = manifest();
        value["sources"][0]["sha256"] = serde_json::json!("pending");
        assert_eq!(load_manifest(&value).unwrap_err().kind(), PackErrorKind::Pending);
    }

    #[test]
    fn a_source_without_a_notice_is_a_licence_failure() {
        let mut value = manifest();
        value["sources"][0].as_object_mut().unwrap().remove("notice");
        assert_eq!(load_manifest(&value).unwrap_err().kind(), PackErrorKind::Licence);
    }

    #[test]
    fn a_url_without_a_host_is_refused() {
        let mut value = manifest();
        value["sources"][0]["url"] = serde_json::json!("https://");
        assert_eq!(load_manifest(&value).unwrap_err().kind(), PackErrorKind::Malformed);
    }

    #[test]
    fn a_file_name_with_a_path_in_it_is_refused() {
        let mut value = manifest();
        value["sources"][0]["file"] = serde_json::json!("a/b.dict");
        assert_eq!(load_manifest(&value).unwrap_err().kind(), PackErrorKind::Malformed);
    }

    #[test]
    fn a_duplicate_id_is_refused() {
        let mut value = manifest();
        let first = value["sources"][0].clone();
        value["sources"].as_array_mut().unwrap().push(first);
        assert_eq!(load_manifest(&value).unwrap_err().kind(), PackErrorKind::Malformed);
    }

    #[test]
    fn an_id_is_what_the_loader_reads() {
        assert!(source_id("cmu"));
        assert!(source_id("morphynet-infl"));
        assert!(source_id("kaikki:impossible"));
        assert!(source_id(&format!("kaikki:sha256:{}", "a".repeat(64))));
        assert!(!source_id("Cmu"));
        assert!(!source_id("kaikki:"));
        assert!(!source_id("kaikki:a b"));
    }
}
