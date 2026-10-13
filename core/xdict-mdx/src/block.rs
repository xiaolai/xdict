//! A stored block: a 4-byte little-endian type, a 4-byte big-endian Adler-32 of the decompressed data, and
//! the payload.

use std::io::Read;

use ripemd::{Digest, Ripemd128};

use crate::bytes::{Cursor, adler32, length};
use crate::{Error, RecordBlock, Unsupported, cipher, limits, malformed};

/// Decompresses one block to exactly `expected` bytes and verifies its checksum.
pub(crate) fn decode(stored: &[u8], expected: usize, what: &'static str) -> Result<Vec<u8>, Error> {
    let mut cursor = Cursor::new(stored, what);
    let kind = u32::from_le_bytes(cursor.take(4)?.try_into().map_err(|_| short(what))?);
    let checksum = cursor.u32()?;
    let payload = stored.get(8..).ok_or_else(|| short(what))?;
    let data = decompress(kind, payload, expected, what)?;
    if adler32(&data) != checksum {
        return Err(Error::Malformed(format!("the {what}'s checksum does not match")));
    }
    Ok(data)
}

/// Decompresses a payload stored with compression `kind` to exactly `expected` bytes.
pub(crate) fn decompress(kind: u32, payload: &[u8], expected: usize, what: &str) -> Result<Vec<u8>, Error> {
    let data = match kind {
        // Sized before copying, so a wrong length is refused without a copy of it.
        0 if payload.len() != expected => {
            return Err(Error::Malformed(format!(
                "the {what} holds {} bytes where {expected} were declared",
                payload.len()
            )));
        }
        0 => payload.to_vec(),
        1 => crate::lzo::decompress(payload, expected, what)?,
        2 => {
            let mut out = Vec::with_capacity(expected);
            // One byte past the expected size, so an oversized stream is caught rather than truncated.
            let limit = u64::try_from(expected).unwrap_or(u64::MAX).saturating_add(1);
            let mut decoder = flate2::read::ZlibDecoder::new(payload);
            (&mut decoder)
                .take(limit)
                .read_to_end(&mut out)
                .map_err(|_| Error::Malformed(format!("the {what} does not decompress")))?;
            // Size first: a stream cut off at the limit has not consumed its input either.
            if out.len() != expected {
                return Err(Error::Malformed(format!(
                    "the {what} decompresses to {} bytes where {expected} were declared",
                    out.len()
                )));
            }
            // The stream must be the whole payload: bytes after its end would otherwise go unread.
            if decoder.total_in() != payload.len() as u64 {
                return Err(Error::Malformed(format!("the {what} has bytes after its compressed data")));
            }
            out
        }
        other => return Err(Error::Unsupported(Unsupported::CompressionType(other))),
    };
    if data.len() != expected {
        return Err(Error::Malformed(format!(
            "the {what} decompresses to {} bytes where {expected} were declared",
            data.len()
        )));
    }
    Ok(data)
}

/// Where each record block lies, from an index's (stored size, decompressed size) pairs: end to end from
/// `start` in the file, and in the concatenated records. Every stored size must hold at least `framing`
/// bytes, the block's own prefix. Returns the blocks and where the last one ends in the file.
pub(crate) fn layout(
    pairs: impl IntoIterator<Item = (u64, u64)>,
    start: u64,
    framing: u64,
) -> Result<(Vec<RecordBlock>, u64), Error> {
    let mut blocks = Vec::new();
    let (mut file_offset, mut records_offset) = (start, 0u64);
    for (stored, decompressed) in pairs {
        if stored < framing {
            return Err(Error::Malformed(format!("a record block declares {stored} bytes, too few for its framing")));
        }
        blocks.push(RecordBlock {
            file_offset,
            stored_len: length(stored, limits::BLOCK_BYTES, "record block")?,
            records_offset,
            len: length(decompressed, limits::BLOCK_BYTES, "record block")?,
        });
        file_offset = file_offset.checked_add(stored).ok_or_else(|| malformed("record index"))?;
        records_offset = records_offset.checked_add(decompressed).ok_or_else(|| malformed("record index"))?;
    }
    Ok((blocks, file_offset))
}

/// Reverses the `Encrypted="2"` obfuscation of the key index, which covers everything past the 8-byte
/// type-and-checksum prefix. The key is RIPEMD-128 of the checksum bytes followed by `95 36 00 00`.
pub(crate) fn deobfuscate(stored: &mut [u8]) -> Result<(), Error> {
    let seed = stored.get(4..8).ok_or_else(|| short("key index"))?;
    let mut hasher = Ripemd128::new();
    hasher.update(seed);
    hasher.update([0x95, 0x36, 0x00, 0x00]);
    let key: [u8; 16] = hasher.finalize().into();
    let body = stored.get_mut(8..).ok_or_else(|| short("key index"))?;
    cipher::nibble_decrypt(body, &key);
    Ok(())
}

fn short(what: &str) -> Error {
    Error::Malformed(format!("the {what} ends early"))
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use std::io::Write;

    use super::*;

    fn zlib(data: &[u8]) -> Vec<u8> {
        let mut encoder = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
        encoder.write_all(data).unwrap();
        encoder.finish().unwrap()
    }

    #[test]
    fn bytes_after_the_zlib_stream_are_malformed() {
        let mut payload = zlib(b"hello");
        assert_eq!(decompress(2, &payload, 5, "test").unwrap(), b"hello");
        payload.extend(b"junk");
        assert!(matches!(decompress(2, &payload, 5, "test"), Err(Error::Malformed(_))));
    }

    #[test]
    fn a_stream_longer_than_declared_says_so() {
        // Long and varied enough that decoding stops partway through the compressed input.
        let data: Vec<u8> = (0..200_000u32).map(|i| (i.wrapping_mul(2_654_435_761) >> 13) as u8).collect();
        let refused = decompress(2, &zlib(&data), 5, "test").err().unwrap().to_string();
        assert!(refused.contains("5 were declared"), "{refused}");
    }

    #[test]
    fn a_block_too_small_for_its_framing_is_malformed() {
        assert!(layout([(16, 4), (16, 9)], 100, 16).is_ok());
        assert!(matches!(layout([(16, 4), (8, 0)], 100, 16), Err(Error::Malformed(_))));
    }
}
