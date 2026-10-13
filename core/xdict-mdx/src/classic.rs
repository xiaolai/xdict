//! The 1.2 and 2.0 layout: after the header, a keyword section (preamble, key index, key blocks), then a
//! record section (preamble, record index, record blocks). Numbers are 8 bytes wide from 2.0, 4 before.

use crate::bytes::{self, Cursor, length};
use crate::keys::{self, KeyBlock, Keys};
use crate::text::Codec;
use crate::{Error, FormatVersion, Header, Parts, RecordBlock, Scheme, Source, block, limits, read, read_array};

pub(crate) fn parts(source: &dyn Source, mut at: u64, header: &Header) -> Result<Parts, Error> {
    let encoding = header
        .attributes
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case("Encoding"))
        .map(|(_, v)| v.as_str())
        .unwrap_or("");
    let codec = Codec::for_file(header.kind, encoding)?;
    let wide = header.version == FormatVersion::V2_0;

    let (key_count, key_blocks) = keyword_section(source, &mut at, header, codec, wide)?;
    let mut keys = Keys::new(key_count, codec, wide, limits::INDEX_BYTES);
    for b in &key_blocks {
        let stored = length(b.stored, limits::BLOCK_BYTES, "key block")?;
        let decompressed = length(b.decompressed, limits::BLOCK_BYTES, "key block")?;
        let raw = read(source, &mut at, stored, "key block")?;
        keys.add_block(&block::decode(&raw, decompressed, "key block")?, b.entries)?;
    }
    let keys = keys.finish()?;
    let blocks = record_section(source, &mut at, key_count, wide)?;
    Ok(Parts { codec, keys, blocks, scheme: Scheme::Classic })
}

/// The keyword section's preamble and key index: the declared key count, and what each key block holds.
fn keyword_section(
    source: &dyn Source,
    at: &mut u64,
    header: &Header,
    codec: Codec,
    wide: bool,
) -> Result<(u64, Vec<KeyBlock>), Error> {
    let preamble = read(source, at, if wide { 40 } else { 16 }, "keyword section")?;
    if wide {
        let checksum = u32::from_be_bytes(read_array(source, at, "keyword section checksum")?);
        if bytes::adler32(&preamble) != checksum {
            return Err(Error::Malformed("the keyword section's checksum does not match".into()));
        }
    }
    let mut p = Cursor::new(&preamble, "keyword section");
    let block_count = p.number(wide)?;
    let key_count = p.number(wide)?;
    let index_len = p.number(wide)?;
    let index_stored_len = if wide { p.number(wide)? } else { index_len };
    let key_blocks_len = p.number(wide)?;
    if key_count > limits::KEYS {
        return Err(Error::Malformed(format!("the file declares {key_count} keys")));
    }
    if block_count > key_count.max(1) {
        return Err(Error::Malformed("the file declares more key blocks than keys".into()));
    }
    let index_len = length(index_len, limits::BLOCK_BYTES, "key index")?;
    let index_stored_len = length(index_stored_len, limits::BLOCK_BYTES, "key index")?;
    let mut index_stored = read(source, at, index_stored_len, "key index")?;
    let index = if wide {
        if header.encrypted & 2 != 0 {
            block::deobfuscate(&mut index_stored)?;
        }
        block::decode(&index_stored, index_len, "key index")?
    } else {
        index_stored
    };

    let unit = codec.unit() as u64;
    let mut blocks = Vec::new();
    let mut ix = Cursor::new(&index, "key index");
    for _ in 0..block_count {
        let entries = ix.number(wide)?;
        for _ in 0..2 {
            // First and last key: a length in code units, the key, and (from 2.0) a terminating null.
            let units = if wide { u64::from(ix.u16()?) } else { u64::from(ix.u8()?) };
            ix.take(length(units * unit, limits::BLOCK_BYTES, "key index")?)?;
            if wide {
                ix.null(codec.unit())?;
            }
        }
        let stored = ix.number(wide)?;
        let decompressed = ix.number(wide)?;
        blocks.push(KeyBlock { entries, stored, decompressed });
    }
    if !ix.is_at_end() {
        return Err(Error::Malformed("the key index has bytes past its last block".into()));
    }
    keys::check_blocks(&blocks, key_count, key_blocks_len)?;
    Ok((key_count, blocks))
}

/// The record section: its preamble, the block index, and where each record block lies.
fn record_section(source: &dyn Source, at: &mut u64, key_count: u64, wide: bool) -> Result<Vec<RecordBlock>, Error> {
    let preamble = read(source, at, if wide { 32 } else { 16 }, "record section")?;
    let mut p = Cursor::new(&preamble, "record section");
    let record_block_count = p.number(wide)?;
    let record_count = p.number(wide)?;
    let record_index_len = p.number(wide)?;
    let record_blocks_len = p.number(wide)?;
    if record_count != key_count {
        return Err(Error::Malformed("the record and keyword sections disagree on the entry count".into()));
    }
    let pair = if wide { 16 } else { 8 };
    if record_block_count.checked_mul(pair) != Some(record_index_len) {
        return Err(Error::Malformed("the record index has the wrong length".into()));
    }
    let record_index_len = length(record_index_len, limits::BLOCK_BYTES, "record index")?;
    let record_index = read(source, at, record_index_len, "record index")?;
    let mut ri = Cursor::new(&record_index, "record index");
    let pairs =
        (0..record_block_count).map(|_| Ok((ri.number(wide)?, ri.number(wide)?))).collect::<Result<Vec<_>, Error>>()?;
    // A stored block opens with its 4-byte type and 4-byte checksum.
    let (blocks, file_offset) = block::layout(pairs, *at, 8)?;
    if file_offset.checked_sub(*at) != Some(record_blocks_len) {
        return Err(Error::Malformed("the record blocks' sizes do not add up".into()));
    }
    if file_offset > source.len() {
        return Err(Error::Malformed("the record blocks run past the end of the file".into()));
    }
    Ok(blocks)
}
