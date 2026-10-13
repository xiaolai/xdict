//! The 3.0 layout, as `dev-docs/format-v3-facts.md` describes it from a file the official MdxBuilder 4.0
//! built: after the header, typed sections, each a run of *units* and a closing XML descriptor. A unit is
//! two sizes and a stored block whose first bytes are encrypted under a key derived from the header's UUID.

use crate::bytes::{Cursor, adler32, length};
use crate::keys::{self, KeyBlock, Keys};
use crate::text::Codec;
use crate::{
    Error, Header, Parts, RecordBlock, Scheme, Source, Unsupported, block, cipher, header, limits, malformed, read,
};

/// The four section types in file order, with the element name of each one's descriptor.
const SECTIONS: [(u32, &str); 4] = [
    (0x0100_0000, "RecordData"),
    (0x0200_0000, "RecordIndex"),
    (0x0300_0000, "KeyData"),
    (0x0400_0000, "KeyBlockIndex"),
];

/// A unit's two sizes, ahead of its stored block.
const UNIT_PREFIX: u64 = 8;
/// The least a unit can be: its sizes, then the stored block's flags, two reserved bytes and checksum.
const UNIT_FRAMING: u64 = UNIT_PREFIX + 8;

/// One section: where its units start in the file, how many there are, how many bytes they take, and the
/// attributes of its descriptor.
struct Section {
    units_at: u64,
    count: u64,
    units_len: u64,
    attributes: Vec<(String, String)>,
}

pub(crate) fn parts(source: &dyn Source, at: u64, header: &Header) -> Result<Parts, Error> {
    let uuid = header
        .attributes
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case("UUID"))
        .map(|(_, v)| v.as_str())
        .ok_or_else(|| Error::Malformed("the header has no UUID, which a 3.0 file's blocks are keyed by".into()))?;
    let key = cipher::v3_key(uuid);

    let [record_data, record_index, key_data, key_index] = sections(source, at, &key)?;
    let key_count = check_descriptors(&record_data, &record_index, &key_data, &key_index)?;
    let blocks = record_blocks(source, &record_data, &record_index, &key)?;
    let key_blocks = key_blocks(source, &key_index, &key_data, key_count, &key)?;

    let mut keys = Keys::new(key_count, Codec::Utf8, true, limits::INDEX_BYTES);
    let mut at = key_data.units_at;
    for b in &key_blocks {
        let raw = read(source, &mut at, length(b.stored, limits::BLOCK_BYTES, "key block")?, "key block")?;
        let decompressed = length(b.decompressed, limits::BLOCK_BYTES, "key block")?;
        keys.add_block(&decode_unit(&raw, decompressed, &key, "key block")?, b.entries)?;
    }
    Ok(Parts { codec: Codec::Utf8, keys: keys.finish()?, blocks, scheme: Scheme::V3(key) })
}

/// Reads every section's framing and descriptor. The sections tile the rest of the file, each type once.
fn sections(source: &dyn Source, mut at: u64, key: &[u8; 16]) -> Result<[Section; 4], Error> {
    let mut found: [Option<Section>; 4] = [None, None, None, None];
    while at < source.len() {
        let prefix = read(source, &mut at, 12, "section")?;
        let mut p = Cursor::new(&prefix, "section");
        let kind = p.u32()?;
        let payload_len = p.u64()?;
        let (slot, (_, name)) = SECTIONS
            .iter()
            .enumerate()
            .find(|(_, (k, _))| *k == kind)
            .ok_or_else(|| Error::Malformed(format!("the file has a section of unknown type {kind:#010x}")))?;
        let payload_end = at.checked_add(payload_len).ok_or_else(|| malformed("section"))?;
        if payload_end > source.len() {
            return Err(Error::Malformed("a section runs past the end of the file".into()));
        }
        let counts = read(source, &mut at, 12, "section")?;
        let mut c = Cursor::new(&counts, "section");
        let count = c.u32().map(u64::from)?;
        let units_len = c.u64()?;
        let units_at = at;
        let mut descriptor_at = units_at.checked_add(units_len).ok_or_else(|| malformed("section"))?;
        if descriptor_at > payload_end {
            return Err(Error::Malformed("a section's blocks run past the section".into()));
        }
        let descriptor_len = length(payload_end - descriptor_at, limits::HEADER_BYTES, "section descriptor")?;
        let unit = read(source, &mut descriptor_at, descriptor_len, "section descriptor")?;
        let expected = length(
            u64::from(Cursor::new(&unit, "section descriptor").u32()?),
            limits::HEADER_BYTES,
            "section descriptor",
        )?;
        let attributes = parse_descriptor(&decode_unit(&unit, expected, key, "section descriptor")?, name)?;
        let slot = found.get_mut(slot).ok_or_else(|| malformed("section"))?;
        if slot.replace(Section { units_at, count, units_len, attributes }).is_some() {
            return Err(Error::Malformed(format!("the file has two sections of type {kind:#010x}")));
        }
        at = payload_end;
    }
    let [Some(a), Some(b), Some(c), Some(d)] = found else {
        return Err(Error::Malformed("the file lacks one of the four sections a 3.0 file has".into()));
    };
    Ok([a, b, c, d])
}

/// Checks the descriptors agree with each other and declare UTF-8, and returns the key count.
fn check_descriptors(
    record_data: &Section,
    record_index: &Section,
    key_data: &Section,
    key_index: &Section,
) -> Result<u64, Error> {
    for section in [record_data, record_index, key_data, key_index] {
        let encoding = get(&section.attributes, "encoding");
        if encoding.trim().is_empty() {
            return Err(Error::Malformed("a section descriptor does not say its encoding".into()));
        }
        if encoding.to_ascii_lowercase().replace(['-', '_'], "") != "utf8" {
            return Err(Error::Unsupported(Unsupported::Encoding(encoding.to_owned())));
        }
    }
    let key_count = count(&key_data.attributes, "keyCount")?;
    if count(&record_data.attributes, "recordCount")? != key_count
        || count(&record_index.attributes, "recordCount")? != key_count
    {
        return Err(Error::Malformed("the record and key sections disagree on the entry count".into()));
    }
    if count(&key_index.attributes, "blockCount")? != key_data.count {
        return Err(Error::Malformed("the key index and the key data disagree on the block count".into()));
    }
    Ok(key_count)
}

/// Where each record block lies, from the record index: per block, its unit's size and decompressed size.
fn record_blocks(
    source: &dyn Source,
    record_data: &Section,
    record_index: &Section,
    key: &[u8; 16],
) -> Result<Vec<RecordBlock>, Error> {
    let index = section_data(source, record_index, key, "record index")?;
    if Some(index.len() as u64) != record_data.count.checked_mul(16) {
        return Err(Error::Malformed("the record index has the wrong length".into()));
    }
    let mut ri = Cursor::new(&index, "record index");
    let pairs = (0..record_data.count).map(|_| Ok((ri.u64()?, ri.u64()?))).collect::<Result<Vec<_>, Error>>()?;
    let (blocks, end) = block::layout(pairs, record_data.units_at, UNIT_FRAMING)?;
    if end.checked_sub(record_data.units_at) != Some(record_data.units_len) {
        return Err(Error::Malformed("the record blocks' sizes do not add up".into()));
    }
    // Each unit's own sizes must agree with the index, checked now so a damaged block is refused at open
    // rather than at the lookup that happens to reach it.
    for b in &blocks {
        let sizes = read(source, &mut b.file_offset.clone(), UNIT_PREFIX as usize, "record block")?;
        let mut c = Cursor::new(&sizes, "record block");
        let (decompressed, stored) = (c.u32()?, c.u32()?);
        if decompressed as usize != b.len || u64::from(stored) + UNIT_PREFIX != b.stored_len as u64 {
            return Err(Error::Malformed("a record block's sizes disagree with the record index".into()));
        }
    }
    Ok(blocks)
}

/// What each key block holds, from the key index: per block, its key count, first and last key, unit
/// size and decompressed size.
fn key_blocks(
    source: &dyn Source,
    key_index: &Section,
    key_data: &Section,
    key_count: u64,
    key: &[u8; 16],
) -> Result<Vec<KeyBlock>, Error> {
    let index = section_data(source, key_index, key, "key index")?;
    let mut ki = Cursor::new(&index, "key index");
    let mut blocks = Vec::new();
    for _ in 0..key_data.count {
        let entries = u64::from(ki.u32()?);
        for _ in 0..2 {
            let bytes = usize::from(ki.u16()?);
            ki.take(bytes)?;
            ki.null(1)?;
        }
        let stored = u64::from(ki.u32()?);
        let decompressed = u64::from(ki.u32()?);
        blocks.push(KeyBlock { entries, stored, decompressed });
    }
    if !ki.is_at_end() {
        return Err(Error::Malformed("the key index has bytes past its last block".into()));
    }
    keys::check_blocks(&blocks, key_count, key_data.units_len)?;
    Ok(blocks)
}

/// Decodes a unit: checks its two sizes, decrypts its stored block's leading bytes, verifies the checksum
/// of the still-compressed payload, and decompresses to exactly `expected` bytes.
pub(crate) fn decode_unit(unit: &[u8], expected: usize, key: &[u8; 16], what: &'static str) -> Result<Vec<u8>, Error> {
    let mut c = Cursor::new(unit, what);
    let decompressed = c.u32()?;
    let stored_len = c.u32()?;
    if u64::from(stored_len) + UNIT_PREFIX != unit.len() as u64 || decompressed as usize != expected {
        return Err(Error::Malformed(format!("the {what}'s sizes disagree with its index")));
    }
    let flags = c.u8()?;
    let encrypted = usize::from(c.u8()?);
    c.take(2)?;
    let checksum = c.u32()?;
    let mut payload = unit.get(16..).ok_or_else(|| Error::Malformed(format!("the {what} ends early")))?.to_vec();
    let head_len = encrypted.min(payload.len());
    let head = payload.get_mut(..head_len).ok_or_else(|| malformed(what))?;
    match flags >> 4 {
        0 => {}
        1 => cipher::nibble_decrypt(head, key),
        2 => cipher::salsa8_xor(head, key),
        other => return Err(Error::Unsupported(Unsupported::BlockEncryption(other))),
    }
    if adler32(&payload) != checksum {
        return Err(Error::Malformed(format!("the {what}'s checksum does not match")));
    }
    // LZO is type 1 in 2.0, but no real 3.0 file has shown it: refused rather than guessed (ADR-0005).
    if flags & 0x0F == 1 {
        return Err(Error::Unsupported(Unsupported::Lzo));
    }
    block::decompress(u32::from(flags & 0x0F), &payload, expected, what)
}

/// Every unit of a small section (an index), decoded and joined. Each unit must lie inside the section,
/// and the joined size is checked against the limit before each unit is decoded.
fn section_data(source: &dyn Source, section: &Section, key: &[u8; 16], what: &'static str) -> Result<Vec<u8>, Error> {
    let mut at = section.units_at;
    let end = at.checked_add(section.units_len).ok_or_else(|| malformed(what))?;
    let mut out = Vec::new();
    for _ in 0..section.count {
        if at.checked_add(UNIT_PREFIX).is_none_or(|e| e > end) {
            return Err(Error::Malformed(format!("the {what}'s blocks run past its section")));
        }
        let sizes = read(source, &mut at.clone(), UNIT_PREFIX as usize, what)?;
        let mut c = Cursor::new(&sizes, what);
        let decompressed = u64::from(c.u32()?);
        let unit_len = u64::from(c.u32()?) + UNIT_PREFIX;
        if at.checked_add(unit_len).is_none_or(|e| e > end) {
            return Err(Error::Malformed(format!("the {what}'s blocks run past its section")));
        }
        if (out.len() as u64).saturating_add(decompressed) > limits::BLOCK_BYTES {
            return Err(Error::Malformed(format!(
                "the {what} is larger than the {} bytes allowed",
                limits::BLOCK_BYTES
            )));
        }
        let unit = read(source, &mut at, length(unit_len, limits::BLOCK_BYTES, what)?, what)?;
        out.extend(decode_unit(&unit, length(decompressed, limits::BLOCK_BYTES, what)?, key, what)?);
    }
    if at != end {
        return Err(Error::Malformed(format!("the {what}'s blocks do not fill its section")));
    }
    Ok(out)
}

/// The attributes of a descriptor such as `<KeyData encoding="UTF-8" keyCount="4010"/>`, which must be the
/// element `name` and nothing else.
fn parse_descriptor(bytes: &[u8], name: &str) -> Result<Vec<(String, String)>, Error> {
    let text = std::str::from_utf8(bytes).map_err(|_| Error::Malformed("a section descriptor is not UTF-8".into()))?;
    let rest = header::element(text.trim(), name)
        .ok_or_else(|| Error::Malformed(format!("a section descriptor is not the <{name}> its section needs")))?;
    header::attributes(rest)
}

fn get<'a>(attributes: &'a [(String, String)], name: &str) -> &'a str {
    attributes.iter().find(|(k, _)| k.eq_ignore_ascii_case(name)).map(|(_, v)| v.as_str()).unwrap_or("")
}

fn count(attributes: &[(String, String)], name: &str) -> Result<u64, Error> {
    get(attributes, name)
        .trim()
        .parse()
        .map_err(|_| Error::Malformed(format!("a section descriptor's {name} is missing or not a number")))
}
