//! Writes MDX and MDD files, for tests only.
//!
//! Written from the MIT-licensed format description and writer of writemdict
//! (<https://github.com/zhansliu/writemdict>, © 2015 zhansliu), never from a GPL reader. It shares no code
//! with `xdict-mdx` on purpose: a fixture produced by the reader's own logic could not catch the reader's
//! mistakes. The checksum and the key-index obfuscation are written out again here for the same reason.
//!
//! It also writes files that are *wrong* in named ways (`Defect`), so the reader's refusals can be tested.

use std::io::Write;

use flate2::Compression as Level;
use flate2::write::ZlibEncoder;
use ripemd::{Digest, Ripemd128};

mod v3;

/// The format version written into the header.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Version {
    V1_2,
    V2_0,
    /// MdxBuilder 4's layout, from `dev-docs/format-v3-facts.md`: always UTF-8, every block encrypted. An
    /// MDD written as 3.0 gets the same layout, since no real one has been seen.
    V3_0,
}

/// How every block is stored.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Compression {
    None,
    Zlib,
}

/// The text encoding of an MDX file's keys and records. An MDD file's keys are always UTF-16.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TextEncoding {
    Utf8,
    Utf16,
}

/// What the file is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Mdx(TextEncoding),
    Mdd,
}

/// A deliberate fault, for testing what the reader refuses.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Defect {
    /// Writes `GeneratedByEngineVersion="4.0"`, a version that does not exist.
    UnknownFormatVersion,
    /// Sets `Encrypted`'s registration-code bit (1) without encrypting anything.
    RegistrationCodeBit,
    /// Marks the first record block as LZO (type 1) while its bytes stay as written.
    LzoRecordBlock,
    /// Flips one byte inside the first record block's payload.
    CorruptRecordBlock,
    /// Writes a wrong header checksum.
    HeaderChecksum,
    /// Declares one key fewer than the first key block holds, and one fewer in the file, so every count
    /// adds up and only the block itself shows the lie.
    OverfullKeyBlock,
}

/// Everything about a file to write.
#[derive(Clone, Debug)]
pub struct Spec {
    pub version: Version,
    pub compression: Compression,
    pub kind: Kind,
    /// `Encrypted="2"`: obfuscate the key index (version 2.0 only).
    pub obfuscate_key_index: bool,
    pub title: String,
    pub description: String,
    pub key_case_sensitive: bool,
    /// Written as `StripKey="Yes"`/`"No"` when set; omitted otherwise.
    pub strip_key: Option<bool>,
    /// The largest decompressed size a block aims for. Small values force many blocks.
    pub block_size: usize,
    pub defect: Option<Defect>,
}

impl Spec {
    /// A plain version 2.0 UTF-8 MDX with zlib blocks and an obfuscated key index: the shape of most of
    /// the owner's collection.
    pub fn mdx() -> Self {
        Self {
            version: Version::V2_0,
            compression: Compression::Zlib,
            kind: Kind::Mdx(TextEncoding::Utf8),
            obfuscate_key_index: true,
            title: "Test Dictionary".into(),
            description: "Written by xdict-mdx-writer".into(),
            key_case_sensitive: false,
            strip_key: Some(true),
            block_size: 64,
            defect: None,
        }
    }

    pub fn mdd() -> Self {
        Self { kind: Kind::Mdd, ..Self::mdx() }
    }
}

/// One keyword and its record. For an MDX file the record is text; for an MDD file, bytes.
pub struct Entry {
    pub key: String,
    pub record: Vec<u8>,
}

impl Entry {
    pub fn text(key: &str, record: &str) -> Self {
        Self { key: key.into(), record: record.as_bytes().to_vec() }
    }

    pub fn bytes(key: &str, record: &[u8]) -> Self {
        Self { key: key.into(), record: record.to_vec() }
    }
}

/// Why a file could not be written as asked. The writer refuses rather than write something other than
/// what the test requested: a fixture that silently differs from its spec tests nothing.
#[derive(Debug, thiserror::Error)]
pub enum WriteError {
    #[error("the {what} is {value}, more than the format's field holds")]
    TooLarge { what: &'static str, value: u64 },
    #[error("the key {0:?} contains a null, which ends a key in the format")]
    NulInKey(String),
    #[error("{defect:?} cannot be written here: {why}")]
    DefectNotApplicable { defect: Defect, why: &'static str },
    #[error("the record for {0:?} is not UTF-8 text")]
    RecordNotUtf8(String),
    #[error("the spec asks for what the format cannot hold: {0}")]
    Incompatible(&'static str),
    #[error("compression failed: {0}")]
    Compression(#[from] std::io::Error),
}

/// A count or size converted to the width of the field that holds it.
pub(crate) fn fit<T: TryFrom<u64>>(value: u64, what: &'static str) -> Result<T, WriteError> {
    T::try_from(value).map_err(|_| WriteError::TooLarge { what, value })
}

/// Writes a complete file.
///
/// Entries are sorted by key, as the format expects. An MDX record arrives as UTF-8 text and is
/// re-encoded into the file's encoding.
pub fn write(spec: &Spec, entries: &[Entry]) -> Result<Vec<u8>, WriteError> {
    if let Some(entry) = entries.iter().find(|e| e.key.contains('\0')) {
        return Err(WriteError::NulInKey(entry.key.clone()));
    }
    match spec.defect {
        Some(defect @ (Defect::LzoRecordBlock | Defect::CorruptRecordBlock | Defect::OverfullKeyBlock))
            if entries.is_empty() =>
        {
            return Err(WriteError::DefectNotApplicable { defect, why: "a file with no entries has no blocks" });
        }
        Some(defect @ Defect::RegistrationCodeBit) if spec.version == Version::V3_0 => {
            return Err(WriteError::DefectNotApplicable { defect, why: "a 3.0 header has no Encrypted attribute" });
        }
        _ => {}
    }
    if spec.version == Version::V3_0 && spec.kind == Kind::Mdx(TextEncoding::Utf16) {
        return Err(WriteError::Incompatible("a 3.0 file is UTF-8"));
    }
    let mut sorted: Vec<&Entry> = entries.iter().collect();
    sorted.sort_by(|a, b| a.key.cmp(&b.key));
    if spec.version == Version::V3_0 { v3::write(spec, &sorted) } else { classic(spec, &sorted) }
}

/// One entry as stored: its key in the file's encoding, and where its record starts in the concatenated
/// records.
struct Row {
    key: Vec<u8>,
    key_units: u64,
    offset: u64,
    record: Vec<u8>,
}

/// The widths of a 1.2 or 2.0 file.
#[derive(Clone, Copy)]
struct Widths {
    /// Bytes per code unit of a key, and of its terminating null.
    unit: usize,
    /// 2.0: 8-byte numbers, 2-byte key lengths, terminated first and last keys, a compressed key index.
    v2: bool,
}

impl Widths {
    fn number(self, n: u64, what: &'static str) -> Result<Vec<u8>, WriteError> {
        Ok(if self.v2 { n.to_be_bytes().to_vec() } else { fit::<u32>(n, what)?.to_be_bytes().to_vec() })
    }

    fn null(self) -> Vec<u8> {
        vec![0u8; self.unit]
    }
}

fn classic(spec: &Spec, sorted: &[&Entry]) -> Result<Vec<u8>, WriteError> {
    let unit = if spec.kind == Kind::Mdx(TextEncoding::Utf8) { 1 } else { 2 };
    let w = Widths { unit, v2: spec.version == Version::V2_0 };
    let rows = rows(spec, sorted, w)?;
    let (key_index, key_blocks) = key_blocks(spec, &rows, w)?;
    let (record_index, record_blocks) = record_blocks(spec, &rows, w)?;

    let key_index_len = key_index.len() as u64;
    let key_index_stored = if w.v2 {
        let compressed = compress(&key_index, spec.compression)?;
        if spec.obfuscate_key_index { obfuscate(compressed) } else { compressed }
    } else {
        key_index
    };
    let mut key_count = rows.len() as u64;
    if spec.defect == Some(Defect::OverfullKeyBlock) {
        key_count -= 1;
    }
    let mut preamble = Vec::new();
    preamble.extend(w.number(key_blocks.len() as u64, "key block count")?);
    preamble.extend(w.number(key_count, "key count")?);
    preamble.extend(w.number(key_index_len, "key index size")?);
    if w.v2 {
        preamble.extend(w.number(key_index_stored.len() as u64, "key index size")?);
    }
    preamble.extend(w.number(key_blocks.iter().map(Vec::len).sum::<usize>() as u64, "key blocks size")?);

    let mut out = header(spec)?;
    out.extend(&preamble);
    if w.v2 {
        out.extend(adler32(&preamble).to_be_bytes());
    }
    out.extend(&key_index_stored);
    out.extend(key_blocks.concat());
    out.extend(w.number(record_blocks.len() as u64, "record block count")?);
    out.extend(w.number(key_count, "record count")?);
    out.extend(w.number(record_index.len() as u64, "record index size")?);
    out.extend(w.number(record_blocks.iter().map(Vec::len).sum::<usize>() as u64, "record blocks size")?);
    out.extend(&record_index);
    out.extend(record_blocks.concat());
    Ok(out)
}

/// Each entry encoded: keys in the file's encoding, MDX records re-encoded and null-terminated.
fn rows(spec: &Spec, sorted: &[&Entry], w: Widths) -> Result<Vec<Row>, WriteError> {
    let mut rows = Vec::with_capacity(sorted.len());
    let mut offset = 0u64;
    for entry in sorted {
        let key = match spec.kind {
            Kind::Mdx(TextEncoding::Utf8) => entry.key.as_bytes().to_vec(),
            Kind::Mdx(TextEncoding::Utf16) | Kind::Mdd => utf16le(&entry.key),
        };
        let record = match spec.kind {
            Kind::Mdd => entry.record.clone(),
            Kind::Mdx(TextEncoding::Utf8) => [entry.record.as_slice(), &w.null()].concat(),
            Kind::Mdx(TextEncoding::Utf16) => {
                let text =
                    std::str::from_utf8(&entry.record).map_err(|_| WriteError::RecordNotUtf8(entry.key.clone()))?;
                [utf16le(text), w.null()].concat()
            }
        };
        let key_units = (key.len() / w.unit) as u64;
        let len = record.len() as u64;
        rows.push(Row { key, key_units, offset, record });
        offset += len;
    }
    Ok(rows)
}

/// Splits rows into blocks by size, as writemdict does: a block closes before the row that would take it
/// past `block_size`. Every block holds at least one row.
pub(crate) fn split<T>(rows: &[T], size: impl Fn(&T) -> usize, block_size: usize) -> Vec<&[T]> {
    let mut blocks = Vec::new();
    let mut rest = rows;
    while !rest.is_empty() {
        let mut total = 0;
        let count = rest
            .iter()
            .enumerate()
            .take_while(|(i, row)| {
                total += size(row);
                *i == 0 || total <= block_size
            })
            .count();
        let (block, tail) = rest.split_at_checked(count).unwrap_or((rest, &[]));
        blocks.push(block);
        rest = tail;
    }
    blocks
}

/// The key blocks, and the key index describing them (not yet compressed).
fn key_blocks(spec: &Spec, rows: &[Row], w: Widths) -> Result<(Vec<u8>, Vec<Vec<u8>>), WriteError> {
    let offset_width = if w.v2 { 8 } else { 4 };
    let mut blocks = Vec::new();
    let mut index = Vec::new();
    for block_rows in split(rows, |r| offset_width + r.key.len() + w.unit, spec.block_size) {
        let mut data = Vec::new();
        for row in block_rows {
            data.extend(w.number(row.offset, "record offset")?);
            data.extend(&row.key);
            data.extend(w.null());
        }
        let compressed = compress(&data, spec.compression)?;
        let mut declared = block_rows.len() as u64;
        if spec.defect == Some(Defect::OverfullKeyBlock) && blocks.is_empty() {
            declared -= 1;
        }
        index.extend(w.number(declared, "key block's key count")?);
        let (Some(first), Some(last)) = (block_rows.first(), block_rows.last()) else { continue };
        for word in [first, last] {
            if w.v2 {
                index.extend(fit::<u16>(word.key_units, "key length")?.to_be_bytes());
                index.extend(&word.key);
                index.extend(w.null());
            } else {
                index.push(fit::<u8>(word.key_units, "key length")?);
                index.extend(&word.key);
            }
        }
        index.extend(w.number(compressed.len() as u64, "key block size")?);
        index.extend(w.number(data.len() as u64, "key block size")?);
        blocks.push(compressed);
    }
    Ok((index, blocks))
}

/// The record blocks, with the first one damaged where the spec asks, and the record index.
fn record_blocks(spec: &Spec, rows: &[Row], w: Widths) -> Result<(Vec<u8>, Vec<Vec<u8>>), WriteError> {
    let mut blocks = Vec::new();
    let mut index = Vec::new();
    for (position, block_rows) in split(rows, |r| r.record.len(), spec.block_size).into_iter().enumerate() {
        let data: Vec<u8> = block_rows.iter().flat_map(|r| r.record.iter().copied()).collect();
        let mut compressed = compress(&data, spec.compression)?;
        if position == 0 {
            match spec.defect {
                Some(Defect::LzoRecordBlock) => {
                    if let Some(kind) = compressed.first_mut() {
                        *kind = 1;
                    }
                }
                // The payload follows the 8-byte type and checksum; with none, there is nothing to corrupt.
                Some(defect @ Defect::CorruptRecordBlock) if compressed.len() <= 8 => {
                    return Err(WriteError::DefectNotApplicable { defect, why: "the first record block is empty" });
                }
                Some(Defect::CorruptRecordBlock) => {
                    if let Some(last) = compressed.last_mut() {
                        *last ^= 0xFF;
                    }
                }
                _ => {}
            }
        }
        index.extend(w.number(compressed.len() as u64, "record block size")?);
        index.extend(w.number(data.len() as u64, "record block size")?);
        blocks.push(compressed);
    }
    Ok((index, blocks))
}

fn header(spec: &Spec) -> Result<Vec<u8>, WriteError> {
    let version = match (spec.defect, spec.version) {
        (Some(Defect::UnknownFormatVersion), _) => "4.0",
        (_, Version::V1_2) => "1.2",
        (_, Version::V2_0 | Version::V3_0) => "2.0",
    };
    let mut encrypted = if spec.obfuscate_key_index && spec.version == Version::V2_0 { 2 } else { 0 };
    if spec.defect == Some(Defect::RegistrationCodeBit) {
        encrypted |= 1;
    }
    let yes = |b: bool| if b { "Yes" } else { "No" };
    let strip = spec.strip_key.map(|s| format!(r#"StripKey="{}" "#, yes(s))).unwrap_or_default();
    let text = match spec.kind {
        Kind::Mdx(encoding) => format!(
            r#"<Dictionary GeneratedByEngineVersion="{version}" RequiredEngineVersion="{version}" Encrypted="{encrypted}" Encoding="{}" Format="Html" CreationDate="2026-10-13" Compact="No" Compat="No" KeyCaseSensitive="{}" {strip}Description="{}" Title="{}" DataSourceFormat="106" StyleSheet="" RegisterBy="" RegCode=""/>"#,
            match encoding {
                TextEncoding::Utf8 => "UTF-8",
                TextEncoding::Utf16 => "UTF-16",
            },
            yes(spec.key_case_sensitive),
            escape(&spec.description),
            escape(&spec.title),
        ),
        Kind::Mdd => format!(
            r#"<Library_Data GeneratedByEngineVersion="{version}" RequiredEngineVersion="{version}" Encrypted="{encrypted}" Format="" CreationDate="2026-10-13" Compact="No" Compat="No" KeyCaseSensitive="{}" {strip}Description="{}" Title="{}" DataSourceFormat="106" StyleSheet="" RegisterBy="" RegCode=""/>"#,
            yes(spec.key_case_sensitive),
            escape(&spec.description),
            escape(&spec.title),
        ),
    };
    let bytes = utf16le(&format!("{text}\r\n\0"));
    let mut checksum = adler32(&bytes);
    if spec.defect == Some(Defect::HeaderChecksum) {
        checksum ^= 1;
    }
    let mut out = fit::<u32>(bytes.len() as u64, "header length")?.to_be_bytes().to_vec();
    out.extend(&bytes);
    out.extend(checksum.to_le_bytes());
    Ok(out)
}

fn compress(data: &[u8], compression: Compression) -> Result<Vec<u8>, WriteError> {
    let (kind, payload) = match compression {
        Compression::None => (0u32, data.to_vec()),
        Compression::Zlib => (2u32, zlib(data)?),
    };
    let mut out = kind.to_le_bytes().to_vec();
    out.extend(adler32(data).to_be_bytes());
    out.extend(payload);
    Ok(out)
}

pub(crate) fn zlib(data: &[u8]) -> Result<Vec<u8>, WriteError> {
    let mut encoder = ZlibEncoder::new(Vec::new(), Level::default());
    encoder.write_all(data)?;
    Ok(encoder.finish()?)
}

/// The `Encrypted="2"` key-index obfuscation, applied after compression to everything past the 8-byte
/// type-and-checksum prefix.
fn obfuscate(mut block: Vec<u8>) -> Vec<u8> {
    let mut hasher = Ripemd128::new();
    hasher.update(block.get(4..8).unwrap_or_default());
    hasher.update([0x95, 0x36, 0x00, 0x00]);
    let key = hasher.finalize();
    let mut previous = 0x36u8;
    let body = block.get_mut(8..).unwrap_or_default();
    for ((i, byte), k) in body.iter_mut().enumerate().zip(key.iter().cycle()) {
        // `i as u8`: the position wraps at 256, as the format does.
        let t = *byte ^ previous ^ (i as u8) ^ k;
        *byte = t.rotate_left(4);
        previous = *byte;
    }
    block
}

pub(crate) fn adler32(data: &[u8]) -> u32 {
    let (mut a, mut b) = (1u32, 0u32);
    for &byte in data {
        a = (a + u32::from(byte)) % 65521;
        b = (b + a) % 65521;
    }
    (b << 16) | a
}

fn utf16le(text: &str) -> Vec<u8> {
    text.encode_utf16().flat_map(u16::to_le_bytes).collect()
}

pub(crate) fn escape(text: &str) -> String {
    text.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;

    fn refused(spec: &Spec, entries: &[Entry]) -> WriteError {
        write(spec, entries).err().unwrap()
    }

    #[test]
    fn a_key_too_long_for_its_length_field_is_refused() {
        let v1 = Spec { version: Version::V1_2, obfuscate_key_index: false, ..Spec::mdx() };
        assert!(write(&v1, &[Entry::text(&"k".repeat(255), "r")]).is_ok());
        assert!(matches!(refused(&v1, &[Entry::text(&"k".repeat(256), "r")]), WriteError::TooLarge { .. }));
        let v3 = Spec { version: Version::V3_0, block_size: 1 << 20, ..Spec::mdx() };
        assert!(matches!(refused(&v3, &[Entry::text(&"k".repeat(65_536), "r")]), WriteError::TooLarge { .. }));
    }

    #[test]
    fn a_key_with_a_null_is_refused() {
        assert!(matches!(refused(&Spec::mdx(), &[Entry::text("a\0b", "r")]), WriteError::NulInKey(_)));
    }

    #[test]
    fn a_defect_that_cannot_be_written_is_refused_rather_than_dropped() {
        let corrupt = Spec { defect: Some(Defect::CorruptRecordBlock), ..Spec::mdx() };
        assert!(matches!(refused(&corrupt, &[]), WriteError::DefectNotApplicable { .. }));
        let v3_code = Spec { version: Version::V3_0, defect: Some(Defect::RegistrationCodeBit), ..Spec::mdx() };
        assert!(matches!(refused(&v3_code, &[Entry::text("a", "r")]), WriteError::DefectNotApplicable { .. }));
    }

    #[test]
    fn record_text_that_is_not_utf_8_is_refused_for_utf_16() {
        let spec = Spec { kind: Kind::Mdx(TextEncoding::Utf16), ..Spec::mdx() };
        assert!(matches!(refused(&spec, &[Entry::bytes("a", &[0xFF])]), WriteError::RecordNotUtf8(_)));
    }

    #[test]
    fn a_corrupt_block_with_no_payload_to_corrupt_is_refused() {
        let spec = Spec { compression: Compression::None, defect: Some(Defect::CorruptRecordBlock), ..Spec::mdd() };
        let refused = refused(&spec, &[Entry::bytes("\\a", b"")]);
        assert!(matches!(refused, WriteError::DefectNotApplicable { .. }), "{refused}");
    }

    #[test]
    fn version_3_in_utf_16_is_refused() {
        let spec = Spec { version: Version::V3_0, kind: Kind::Mdx(TextEncoding::Utf16), ..Spec::mdx() };
        assert!(matches!(refused(&spec, &[Entry::text("a", "r")]), WriteError::Incompatible(_)));
    }

    /// Version 1.2 offsets are 4 bytes, so the same entries pack into fewer key blocks than in 2.0.
    #[test]
    fn version_1_2_key_blocks_are_sized_with_4_byte_offsets() {
        // Two 1-byte UTF-8 keys: 2 × (4 + 1 + 1) = 12 bytes in 1.2, 2 × (8 + 1 + 1) = 20 in 2.0.
        let entries = [Entry::text("a", "r"), Entry::text("b", "r")];
        let v1 = Spec { version: Version::V1_2, obfuscate_key_index: false, block_size: 12, ..Spec::mdx() };
        let rows = rows(&v1, &entries.iter().collect::<Vec<_>>(), Widths { unit: 1, v2: false }).unwrap();
        let (index, blocks) = key_blocks(&v1, &rows, Widths { unit: 1, v2: false }).unwrap();
        assert_eq!(blocks.len(), 1, "key index {index:?}");
    }
}
