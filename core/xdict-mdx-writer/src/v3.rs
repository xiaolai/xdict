//! Format 3.0, as `dev-docs/format-v3-facts.md` describes what MdxBuilder 4.0 writes. Written from that
//! note, not from the reader: the ciphers below are spelled out again here for the same reason as the
//! checksum in `lib.rs`.

use crate::{Compression, Defect, Entry, Spec, WriteError, adler32, escape, fit, split, zlib};

const UUID: &str = "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0";

const RECORD_DATA: u32 = 0x0100_0000;
const RECORD_INDEX: u32 = 0x0200_0000;
const KEY_DATA: u32 = 0x0300_0000;
const KEY_INDEX: u32 = 0x0400_0000;

/// The two ciphers a stored block may name in its high nibble.
#[derive(Clone, Copy)]
enum Cipher {
    /// The 2.0 key-index scheme.
    Nibble = 1,
    /// Salsa20/8.
    Salsa = 2,
}

pub(crate) fn write(spec: &Spec, sorted: &[&Entry]) -> Result<Vec<u8>, WriteError> {
    let key = key();
    let (records, key_rows) = encode(sorted);
    let mut record_count = sorted.len();
    if spec.defect == Some(Defect::OverfullKeyBlock) {
        record_count -= 1;
    }
    let (record_units, record_index) = record_units(spec, &records, &key)?;
    let (key_units, key_index) = key_units(spec, &key_rows, &key)?;

    let utf8 = r#"encoding="UTF-8""#;
    let mut out = header(spec)?;
    out.extend(section(
        RECORD_DATA,
        &record_units,
        &format!("<RecordData {utf8} recordCount=\"{record_count}\"/>\r\n"),
        Cipher::Salsa,
        &key,
    )?);
    let index_unit = unit(&record_index, spec.compression, Cipher::Nibble, &key)?;
    out.extend(section(
        RECORD_INDEX,
        &[index_unit],
        &format!("<RecordIndex {utf8} recordCount=\"{record_count}\"/>\r\n"),
        Cipher::Nibble,
        &key,
    )?);
    out.extend(section(
        KEY_DATA,
        &key_units,
        &format!("<KeyData {utf8} locale=\"\" keyCount=\"{record_count}\"/>\r\n"),
        Cipher::Nibble,
        &key,
    )?);
    let key_index_unit = unit(&key_index, spec.compression, Cipher::Nibble, &key)?;
    out.extend(section(
        KEY_INDEX,
        &[key_index_unit],
        &format!("<KeyBlockIndex {utf8} locale=\"\" blockCount=\"{}\"/>\r\n", key_units.len()),
        Cipher::Nibble,
        &key,
    )?);
    Ok(out)
}

/// A key, and its row in the key data: its record's offset, the key and a null.
struct KeyRow<'a> {
    key: &'a [u8],
    row: Vec<u8>,
}

/// The records back to back, each followed by a null, and each key's row.
fn encode<'a>(sorted: &[&'a Entry]) -> (Vec<u8>, Vec<KeyRow<'a>>) {
    let mut records = Vec::new();
    let mut key_rows = Vec::new();
    for entry in sorted {
        let mut row = (records.len() as u64).to_be_bytes().to_vec();
        row.extend(entry.key.as_bytes());
        row.push(0);
        key_rows.push(KeyRow { key: entry.key.as_bytes(), row });
        records.extend(&entry.record);
        records.push(0);
    }
    (records, key_rows)
}

/// Record data cut into units of at most `block_size`, the first damaged where the spec asks, and the
/// record index. Whole records are not kept together: offsets address the concatenation, so a record may
/// span units, as in 2.0.
fn record_units(spec: &Spec, records: &[u8], key: &[u8; 16]) -> Result<(Vec<Vec<u8>>, Vec<u8>), WriteError> {
    let mut units = Vec::new();
    let mut index = Vec::new();
    for (position, chunk) in records.chunks(spec.block_size.max(1)).enumerate() {
        let mut unit = unit(chunk, spec.compression, Cipher::Salsa, key)?;
        if position == 0 {
            match spec.defect {
                Some(Defect::LzoRecordBlock) => {
                    if let Some(flags) = unit.get_mut(8) {
                        *flags = (*flags & 0xF0) | 1;
                    }
                }
                // The payload follows 16 bytes of sizes, flags and checksum; with none, nothing to corrupt.
                Some(defect @ Defect::CorruptRecordBlock) if unit.len() <= 16 => {
                    return Err(WriteError::DefectNotApplicable { defect, why: "the first record block is empty" });
                }
                Some(Defect::CorruptRecordBlock) => {
                    if let Some(last) = unit.last_mut() {
                        *last ^= 0xFF;
                    }
                }
                _ => {}
            }
        }
        index.extend((unit.len() as u64).to_be_bytes());
        index.extend((chunk.len() as u64).to_be_bytes());
        units.push(unit);
    }
    Ok((units, index))
}

/// Key data cut into units of whole keys, and the key index describing each unit.
fn key_units(spec: &Spec, key_rows: &[KeyRow<'_>], key: &[u8; 16]) -> Result<(Vec<Vec<u8>>, Vec<u8>), WriteError> {
    let mut units = Vec::new();
    let mut index = Vec::new();
    for block in split(key_rows, |k| k.row.len(), spec.block_size) {
        let data: Vec<u8> = block.iter().flat_map(|k| k.row.iter().copied()).collect();
        let unit = unit(&data, spec.compression, Cipher::Nibble, key)?;
        let mut declared = block.len() as u64;
        if spec.defect == Some(Defect::OverfullKeyBlock) && units.is_empty() {
            declared -= 1;
        }
        index.extend(fit::<u32>(declared, "key block's key count")?.to_be_bytes());
        let (Some(first), Some(last)) = (block.first(), block.last()) else { continue };
        for word in [first.key, last.key] {
            index.extend(fit::<u16>(word.len() as u64, "key length")?.to_be_bytes());
            index.extend(word);
            index.push(0);
        }
        index.extend(fit::<u32>(unit.len() as u64, "key block size")?.to_be_bytes());
        index.extend(fit::<u32>(data.len() as u64, "key block size")?.to_be_bytes());
        units.push(unit);
    }
    Ok((units, index))
}

fn header(spec: &Spec) -> Result<Vec<u8>, WriteError> {
    let version = if spec.defect == Some(Defect::UnknownFormatVersion) { "4.0" } else { "3.0" };
    let yes = |b: bool| if b { "Yes" } else { "No" };
    let strip = spec.strip_key.map(|s| format!(r#"StripKey="{}" "#, yes(s))).unwrap_or_default();
    let text = format!(
        r#"<ZDB GeneratedByEngineVersion="{version}" RequiredEngineVersion="{version}" ContentType="Html" RegisterBy="EMail" Description="{}" Title="{}" DefaultSortingLocale="" UUID="{UUID}" CreationDate="2026-10-13" Compact="No" KeyCaseSensitive="{}" {strip}DataSourceFormat="107" StyleSheet=""/>"#,
        escape(&spec.description),
        escape(&spec.title),
        yes(spec.key_case_sensitive),
    );
    let bytes = format!("{text}\r\n\0").into_bytes();
    let mut checksum = adler32(&bytes);
    if spec.defect == Some(Defect::HeaderChecksum) {
        checksum ^= 1;
    }
    let mut out = fit::<u32>(bytes.len() as u64, "header length")?.to_be_bytes().to_vec();
    out.extend(&bytes);
    out.extend(checksum.to_le_bytes());
    Ok(out)
}

/// A section: type, payload length, block count, the units' length, the units, then the descriptor unit.
fn section(
    kind: u32,
    units: &[Vec<u8>],
    descriptor: &str,
    cipher: Cipher,
    key: &[u8; 16],
) -> Result<Vec<u8>, WriteError> {
    let units_len: usize = units.iter().map(Vec::len).sum();
    let mut payload = fit::<u32>(units.len() as u64, "section block count")?.to_be_bytes().to_vec();
    payload.extend((units_len as u64).to_be_bytes());
    for unit in units {
        payload.extend(unit);
    }
    payload.extend(unit(descriptor.as_bytes(), Compression::None, cipher, key)?);
    let mut out = kind.to_be_bytes().to_vec();
    out.extend((payload.len() as u64).to_be_bytes());
    out.extend(payload);
    Ok(out)
}

/// A unit: decompressed size, stored size, then the stored block — cipher and compression in byte 0, the
/// encrypted length in byte 1, two zero bytes, the Adler-32 of the compressed payload, the payload with its
/// first 16 bytes encrypted.
fn unit(data: &[u8], compression: Compression, cipher: Cipher, key: &[u8; 16]) -> Result<Vec<u8>, WriteError> {
    let (code, mut payload) = match compression {
        Compression::None => (0u8, data.to_vec()),
        Compression::Zlib => (2u8, zlib(data)?),
    };
    let checksum = adler32(&payload);
    let encrypted = payload.len().min(16);
    let (head, _) = payload.split_at_mut(encrypted);
    match cipher {
        Cipher::Nibble => nibble_encrypt(head, key),
        Cipher::Salsa => {
            for (byte, k) in head.iter_mut().zip(salsa8_keystream(key)) {
                *byte ^= k;
            }
        }
    }
    let mut stored = vec![((cipher as u8) << 4) | code, encrypted as u8, 0, 0];
    stored.extend(checksum.to_be_bytes());
    stored.extend(payload);
    let mut out = fit::<u32>(data.len() as u64, "block size")?.to_be_bytes().to_vec();
    out.extend(fit::<u32>(stored.len() as u64, "block size")?.to_be_bytes());
    out.extend(stored);
    Ok(out)
}

/// xxh64 of each half of the UUID's text, big-endian, end to end.
fn key() -> [u8; 16] {
    let text = UUID.as_bytes();
    let (first, second) = text.split_at(text.len() / 2);
    let [a, b] = [first, second].map(|half| xxhash_rust::xxh64::xxh64(half, 0).to_be_bytes());
    let mut key = [0u8; 16];
    for (slot, byte) in key.iter_mut().zip(a.iter().chain(&b)) {
        *slot = *byte;
    }
    key
}

/// The inverse of the 2.0 key-index scheme: each byte is mixed with the previous *ciphertext* byte, its
/// position and the key, then its nibbles are swapped.
fn nibble_encrypt(bytes: &mut [u8], key: &[u8; 16]) {
    let mut previous = 0x36u8;
    for ((i, byte), k) in bytes.iter_mut().enumerate().zip(key.iter().cycle()) {
        // `i as u8`: the position wraps at 256, as the format does.
        *byte = (*byte ^ previous ^ (i as u8) ^ k).rotate_left(4);
        previous = *byte;
    }
}

/// The first 64 bytes of Salsa20/8 for a 16-byte key, a zero nonce and block 0.
fn salsa8_keystream(key: &[u8; 16]) -> [u8; 64] {
    let [t0, t1, t2, t3] = le_words(b"expand 16-byte k");
    let [k0, k1, k2, k3] = le_words(key);
    let input = [t0, k0, k1, k2, k3, t1, 0, 0, 0, 0, t2, k0, k1, k2, k3, t3];
    let [mut x0, mut x1, mut x2, mut x3, mut x4, mut x5, mut x6, mut x7] = [t0, k0, k1, k2, k3, t1, 0, 0];
    let [mut x8, mut x9, mut x10, mut x11, mut x12, mut x13, mut x14, mut x15] = [0, 0, t2, k0, k1, k2, k3, t3];
    for _ in 0..4 {
        // Columns, then rows.
        [x0, x4, x8, x12] = quarter([x0, x4, x8, x12]);
        [x5, x9, x13, x1] = quarter([x5, x9, x13, x1]);
        [x10, x14, x2, x6] = quarter([x10, x14, x2, x6]);
        [x15, x3, x7, x11] = quarter([x15, x3, x7, x11]);
        [x0, x1, x2, x3] = quarter([x0, x1, x2, x3]);
        [x5, x6, x7, x4] = quarter([x5, x6, x7, x4]);
        [x10, x11, x8, x9] = quarter([x10, x11, x8, x9]);
        [x15, x12, x13, x14] = quarter([x15, x12, x13, x14]);
    }
    let x = [x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14, x15];
    let mut out = [0u8; 64];
    for ((chunk, word), original) in out.as_chunks_mut::<4>().0.iter_mut().zip(x).zip(input) {
        *chunk = word.wrapping_add(original).to_le_bytes();
    }
    out
}

/// Four little-endian words from sixteen bytes.
fn le_words(bytes: &[u8; 16]) -> [u32; 4] {
    let mut out = [0u32; 4];
    for (word, chunk) in out.iter_mut().zip(bytes.as_chunks::<4>().0) {
        *word = u32::from_le_bytes(*chunk);
    }
    out
}

/// One Salsa20 quarter-round on four words, in the order the round names them.
fn quarter([a, b, c, d]: [u32; 4]) -> [u32; 4] {
    let b = b ^ a.wrapping_add(d).rotate_left(7);
    let c = c ^ b.wrapping_add(a).rotate_left(9);
    let d = d ^ c.wrapping_add(b).rotate_left(13);
    let a = a ^ d.wrapping_add(c).rotate_left(18);
    [a, b, c, d]
}
