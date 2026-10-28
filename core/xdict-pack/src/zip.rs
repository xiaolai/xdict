//! A minimal zip reader: the end-of-central-directory record, the central directory, a local header, and the two
//! methods the pinned archive uses — stored and deflate, through `flate2`.
//!
//! The archive is read whole (the pinned one is 10 MB) and its integrity is the manifest's SHA-256, checked before
//! any of this runs, so no per-member CRC is recomputed. A member this reader cannot inflate, a record it cannot
//! parse, and an archive with no central directory are `malformed`.

use std::io::Read;
use std::path::Path;

use crate::error::{PackError, PackErrorKind, PackResult};
use crate::limits::MAX_ZIP_MEMBER_BYTES;

const EOCD_SIGNATURE: u32 = 0x0605_4b50;
const CENTRAL_SIGNATURE: u32 = 0x0201_4b50;
const LOCAL_SIGNATURE: u32 = 0x0403_4b50;

/// One member of the archive, as its central directory declares it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    /// The member's path inside the archive.
    pub name: String,
    /// 0 for stored, 8 for deflate.
    pub method: u16,
    /// The member's size once inflated.
    pub uncompressed: u64,
    /// The member's size in the archive.
    pub compressed: u64,
    /// Where the member's local header sits.
    pub offset: u64,
}

/// A zip archive in memory, with its central directory read.
#[derive(Debug)]
pub struct Zip {
    data: Vec<u8>,
    entries: Vec<Entry>,
}

fn u16_at(data: &[u8], at: usize) -> Option<u16> {
    let bytes = data.get(at..at + 2)?;
    Some(u16::from_le_bytes([*bytes.first()?, *bytes.get(1)?]))
}

fn u32_at(data: &[u8], at: usize) -> Option<u32> {
    let bytes = data.get(at..at + 4)?;
    Some(u32::from_le_bytes([*bytes.first()?, *bytes.get(1)?, *bytes.get(2)?, *bytes.get(3)?]))
}

impl Zip {
    /// Reads the archive at `path`.
    pub fn open(path: &Path, source: &str) -> PackResult<Zip> {
        let data = std::fs::read(path).map_err(|error| {
            PackError::at_source(PackErrorKind::Missing, source, format!("{}: {error}", path.display()))
        })?;
        Self::from_bytes(data, source)
    }

    /// Reads an archive from an open handle — the one a build has already hashed, so what is parsed is what was
    /// verified even if the path is replaced meanwhile.
    pub fn from_file(mut file: std::fs::File, source: &str) -> PackResult<Zip> {
        let mut data = Vec::new();
        std::io::Read::read_to_end(&mut file, &mut data)
            .map_err(|error| PackError::at_source(PackErrorKind::Missing, source, format!("{error}")))?;
        Self::from_bytes(data, source)
    }

    /// Reads an archive already in memory.
    pub fn from_bytes(data: Vec<u8>, source: &str) -> PackResult<Zip> {
        let fail =
            |message: &str| PackError::at_source(PackErrorKind::Malformed, source, format!("not a zip: {message}"));
        let end = find_eocd(&data).ok_or_else(|| fail("no end-of-central-directory record"))?;
        let count = u16_at(&data, end + 10).ok_or_else(|| fail("a truncated end record"))? as usize;
        let directory_size = u32_at(&data, end + 12).ok_or_else(|| fail("a truncated end record"))?;
        let directory_at = u32_at(&data, end + 16).ok_or_else(|| fail("a truncated end record"))? as usize;
        if count == u16::MAX as usize || directory_size == u32::MAX || directory_at == u32::MAX as usize {
            return Err(fail("a zip64 archive, which this reader does not take"));
        }
        let directory_end =
            directory_at.checked_add(directory_size as usize).ok_or_else(|| fail("a directory past the file"))?;
        if directory_end > data.len() {
            return Err(fail("a directory past the file"));
        }
        let mut entries = Vec::with_capacity(count);
        let mut at = directory_at;
        for _ in 0..count {
            if u32_at(&data, at) != Some(CENTRAL_SIGNATURE) {
                return Err(fail("a central directory entry that is not one"));
            }
            let method = u16_at(&data, at + 10).ok_or_else(|| fail("a truncated entry"))?;
            let compressed = u32_at(&data, at + 20).ok_or_else(|| fail("a truncated entry"))? as u64;
            let uncompressed = u32_at(&data, at + 24).ok_or_else(|| fail("a truncated entry"))? as u64;
            let name_length = u16_at(&data, at + 28).ok_or_else(|| fail("a truncated entry"))? as usize;
            let extra_length = u16_at(&data, at + 30).ok_or_else(|| fail("a truncated entry"))? as usize;
            let comment_length = u16_at(&data, at + 32).ok_or_else(|| fail("a truncated entry"))? as usize;
            let offset = u32_at(&data, at + 42).ok_or_else(|| fail("a truncated entry"))? as u64;
            let name_at = at + 46;
            let name = data.get(name_at..name_at + name_length).ok_or_else(|| fail("a name past the file"))?;
            let name = String::from_utf8(name.to_vec()).map_err(|_| fail("a name that is not UTF-8"))?;
            entries.push(Entry { name, method, uncompressed, compressed, offset });
            at = name_at + name_length + extra_length + comment_length;
        }
        Ok(Zip { data, entries })
    }

    /// The archive's members, in the order its central directory lists them.
    pub fn entries(&self) -> &[Entry] {
        &self.entries
    }

    /// Reads one member whole.
    pub fn read(&self, entry: &Entry, source: &str) -> PackResult<Vec<u8>> {
        let fail = |message: String| PackError::at_source(PackErrorKind::Malformed, source, message);
        let header = entry.offset as usize;
        if u32_at(&self.data, header) != Some(LOCAL_SIGNATURE) {
            return Err(fail(format!("{}: no local header where the directory says", entry.name)));
        }
        let name_length = u16_at(&self.data, header + 26)
            .ok_or_else(|| fail(format!("{}: a truncated local header", entry.name)))?
            as usize;
        let extra_length = u16_at(&self.data, header + 28)
            .ok_or_else(|| fail(format!("{}: a truncated local header", entry.name)))?
            as usize;
        let start = header + 30 + name_length + extra_length;
        let size = usize::try_from(entry.compressed)
            .map_err(|_| fail(format!("{}: a member too large to hold", entry.name)))?;
        let body = self
            .data
            .get(
                start
                    ..start.checked_add(size).ok_or_else(|| fail(format!("{}: a member past the file", entry.name)))?,
            )
            .ok_or_else(|| fail(format!("{}: a member past the file", entry.name)))?;
        match entry.method {
            0 => Ok(body.to_vec()),
            8 => {
                // The header's size is a claim, not a bound: inflate through a cap and refuse what passes it, so a
                // member that lies about its size cannot exhaust the reader's memory before the check runs.
                let mut out = Vec::with_capacity(usize::try_from(entry.uncompressed).unwrap_or(0).min(1 << 20));
                flate2::read::DeflateDecoder::new(body)
                    .take(MAX_ZIP_MEMBER_BYTES + 1)
                    .read_to_end(&mut out)
                    .map_err(|error| fail(format!("{}: {error}", entry.name)))?;
                if out.len() as u64 > MAX_ZIP_MEMBER_BYTES {
                    return Err(PackError::at_source(
                        PackErrorKind::Bound,
                        source,
                        format!("{} is over {MAX_ZIP_MEMBER_BYTES} bytes", entry.name),
                    ));
                }
                Ok(out)
            }
            other => Err(fail(format!("{}: compression method {other}", entry.name))),
        }
    }
}

/// Where the end-of-central-directory record starts: the last one that fits its own comment length.
fn find_eocd(data: &[u8]) -> Option<usize> {
    if data.len() < 22 {
        return None;
    }
    let earliest = data.len().saturating_sub(22 + 0xFFFF);
    let mut at = data.len() - 22;
    loop {
        if u32_at(data, at) == Some(EOCD_SIGNATURE) {
            let comment = u16_at(data, at + 20)? as usize;
            if at + 22 + comment <= data.len() {
                return Some(at);
            }
        }
        if at == earliest {
            return None;
        }
        at -= 1;
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::indexing_slicing)]

    use super::*;

    /// A stored zip with one member, built by hand so the reader is tested against bytes, not against itself.
    fn stored_zip(name: &str, body: &str) -> Vec<u8> {
        let name = name.as_bytes();
        let body = body.as_bytes();
        let mut out = Vec::new();
        out.extend_from_slice(&LOCAL_SIGNATURE.to_le_bytes());
        out.extend_from_slice(&20u16.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out.extend_from_slice(&0u32.to_le_bytes());
        out.extend_from_slice(&(body.len() as u32).to_le_bytes());
        out.extend_from_slice(&(body.len() as u32).to_le_bytes());
        out.extend_from_slice(&(name.len() as u16).to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out.extend_from_slice(name);
        out.extend_from_slice(body);
        let directory_at = out.len();
        out.extend_from_slice(&CENTRAL_SIGNATURE.to_le_bytes());
        out.extend_from_slice(&20u16.to_le_bytes());
        out.extend_from_slice(&20u16.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out.extend_from_slice(&0u32.to_le_bytes());
        out.extend_from_slice(&(body.len() as u32).to_le_bytes());
        out.extend_from_slice(&(body.len() as u32).to_le_bytes());
        out.extend_from_slice(&(name.len() as u16).to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out.extend_from_slice(&0u32.to_le_bytes());
        out.extend_from_slice(&0u32.to_le_bytes());
        out.extend_from_slice(name);
        let directory_size = out.len() - directory_at;
        out.extend_from_slice(&EOCD_SIGNATURE.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out.extend_from_slice(&1u16.to_le_bytes());
        out.extend_from_slice(&1u16.to_le_bytes());
        out.extend_from_slice(&(directory_size as u32).to_le_bytes());
        out.extend_from_slice(&(directory_at as u32).to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out
    }

    #[test]
    fn a_stored_member_reads_back() {
        let zip = Zip::from_bytes(stored_zip("a.txt", "hello"), "test").unwrap();
        assert_eq!(zip.entries().len(), 1);
        assert_eq!(zip.entries()[0].name, "a.txt");
        assert_eq!(zip.read(&zip.entries()[0], "test").unwrap(), b"hello");
    }

    #[test]
    fn a_file_that_is_not_a_zip_is_malformed() {
        let error = Zip::from_bytes(b"not a zip at all, not even close".to_vec(), "oewn").unwrap_err();
        assert_eq!(error.kind(), PackErrorKind::Malformed);
    }
}
