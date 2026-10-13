//! A clean-room reader for MDict `.mdx` and `.mdd` files.
//!
//! Versions 1.2 and 2.0 are written from the MIT-licensed format description of writemdict
//! (<https://github.com/zhansliu/writemdict>); 3.0 from XDict's own facts note, made by inspecting a file
//! the official MdxBuilder 4.0 built. Never from a GPL reader (XDict ADR-0001, ADR-0005).
//!
//! **A dictionary file is untrusted input.** Every length the file declares is checked against the file's
//! real size and against [`limits`] before anything is allocated, every checksum is verified, and nothing
//! here panics on bad input: each failure is an [`Error`] that names what was wrong.
//!
//! **The key index is built here, at open**, rather than searched in the file's own order: the order
//! MdxBuilder sorts keys in is not documented, and a binary search under a guessed collation would miss
//! keys silently. Opening reads every key block once; records are read only when looked up.

use std::collections::HashMap;
use std::io;
#[cfg(any(unix, windows))]
use std::path::Path;

mod block;
mod bytes;
mod cipher;
mod classic;
mod header;
mod keys;
pub mod limits;
mod text;
mod v3;

use bytes::length;
use text::{Codec, fold};

/// Why a file could not be read. The `Display` text is a sentence a reader can be shown.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("the file could not be read: {0}")]
    Io(#[from] io::Error),
    #[error("this dictionary uses something XDict does not support: {0}")]
    Unsupported(Unsupported),
    #[error("the file is damaged: {0}")]
    Malformed(String),
}

/// A feature of the format XDict refuses, named so the refusal can say which.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum Unsupported {
    #[error("format version {0} (XDict reads 1.2, 2.0 and 3.0)")]
    FormatVersion(String),
    #[error("a format 3.0 resource library (.mdd), which XDict has not yet been able to check against a real one")]
    ResourceLibraryV3,
    #[error("registration-code encryption")]
    RegistrationCode,
    #[error("the encryption flags {0}")]
    EncryptionFlags(u8),
    #[error("LZO-compressed blocks")]
    Lzo,
    #[error("compression type {0}")]
    CompressionType(u32),
    #[error("block encryption type {0}")]
    BlockEncryption(u8),
    #[error("the text encoding \"{0}\"")]
    Encoding(String),
}

/// What the file is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// A dictionary: text keys, text records.
    Mdx,
    /// A resource library: path keys, binary records.
    Mdd,
}

/// The format version from `GeneratedByEngineVersion`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FormatVersion {
    V1_2,
    V2_0,
    V3_0,
}

/// The header, as the file declares it.
#[derive(Debug, Clone)]
pub struct Header {
    pub kind: Kind,
    pub version: FormatVersion,
    /// The raw `Encrypted` value. Only bit 2 (key-index obfuscation) is ever accepted.
    pub encrypted: u8,
    /// Empty where the file declares none, which OALD10 does.
    pub title: String,
    pub description: String,
    pub key_case_sensitive: bool,
    /// `None` where the file does not say.
    pub strip_key: Option<bool>,
    /// The `StyleSheet` attribute, for the compact format; empty where unused.
    pub stylesheet: String,
    /// Every attribute, as written, for anything not named above.
    pub attributes: Vec<(String, String)>,
}

/// One record found for a key.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Record {
    /// The key as the file spells it.
    pub key: String,
    /// The record's bytes. For an MDX file, its text as UTF-8 with the terminating null removed; for an
    /// MDD file, the bytes as stored.
    pub data: Vec<u8>,
}

/// Random access to a file's bytes. A path on disk is one source; the Web build supplies its own.
pub trait Source: Send + Sync {
    fn len(&self) -> u64;
    fn is_empty(&self) -> bool {
        self.len() == 0
    }
    /// Fills `buf` from `offset`, or fails; never a short read.
    fn read_exact_at(&self, offset: u64, buf: &mut [u8]) -> io::Result<()>;
}

/// Bytes already in memory.
impl Source for Vec<u8> {
    fn len(&self) -> u64 {
        self.as_slice().len() as u64
    }
    fn read_exact_at(&self, offset: u64, buf: &mut [u8]) -> io::Result<()> {
        let start = usize::try_from(offset).map_err(|_| io::ErrorKind::UnexpectedEof)?;
        let end = start.checked_add(buf.len()).ok_or(io::ErrorKind::UnexpectedEof)?;
        let slice = self.get(start..end).ok_or(io::ErrorKind::UnexpectedEof)?;
        buf.copy_from_slice(slice);
        Ok(())
    }
}

/// A file on disk, read with positioned reads so lookups need no shared cursor.
#[cfg(any(unix, windows))]
pub struct DiskFile {
    file: std::fs::File,
    len: u64,
}

#[cfg(any(unix, windows))]
impl DiskFile {
    pub fn open(path: &Path) -> io::Result<Self> {
        let file = std::fs::File::open(path)?;
        let len = file.metadata()?.len();
        Ok(Self { file, len })
    }
}

#[cfg(any(unix, windows))]
impl Source for DiskFile {
    fn len(&self) -> u64 {
        self.len
    }
    #[cfg(unix)]
    fn read_exact_at(&self, offset: u64, buf: &mut [u8]) -> io::Result<()> {
        std::os::unix::fs::FileExt::read_exact_at(&self.file, buf, offset)
    }
    #[cfg(windows)]
    fn read_exact_at(&self, mut offset: u64, mut buf: &mut [u8]) -> io::Result<()> {
        while !buf.is_empty() {
            let n = std::os::windows::fs::FileExt::seek_read(&self.file, buf, offset)?;
            if n == 0 {
                return Err(io::ErrorKind::UnexpectedEof.into());
            }
            offset += n as u64;
            let rest = std::mem::take(&mut buf);
            buf = rest.get_mut(n..).ok_or(io::ErrorKind::UnexpectedEof)?;
        }
        Ok(())
    }
}

/// One key: how the file spells it, and where its record starts in the concatenated records.
pub(crate) struct Key {
    text: String,
    offset: u64,
}

/// Where one record block sits in the file, and in the concatenated records.
pub(crate) struct RecordBlock {
    file_offset: u64,
    stored_len: usize,
    records_offset: u64,
    len: usize,
}

/// What one lookup may return: its records' bytes, keys included, and how many records.
#[derive(Clone, Copy)]
struct Budget {
    bytes: u64,
    records: usize,
}

/// How a layout's record blocks are stored.
#[derive(Clone, Copy)]
pub(crate) enum Scheme {
    /// 1.2 and 2.0: a type, a checksum of the decompressed data, the payload.
    Classic,
    /// 3.0: sizes, then a stored block whose first bytes are encrypted under this key.
    V3([u8; 16]),
}

/// What a layout's reader hands back for the lookup code, which is the same for every version.
pub(crate) struct Parts {
    codec: Codec,
    keys: Vec<Key>,
    blocks: Vec<RecordBlock>,
    scheme: Scheme,
}

/// An open MDX or MDD file.
pub struct File {
    source: Box<dyn Source>,
    header: Header,
    codec: Codec,
    keys: Vec<Key>,
    /// For each key, where its record ends: the next larger offset, or the end of all records.
    ends: Vec<u64>,
    exact: HashMap<String, Vec<usize>>,
    folded: HashMap<String, Vec<usize>>,
    blocks: Vec<RecordBlock>,
    scheme: Scheme,
}

impl File {
    /// Opens a file on disk and reads its header and key index.
    #[cfg(any(unix, windows))]
    pub fn open(path: &Path) -> Result<Self, Error> {
        let mdd = path.extension().is_some_and(|e| e.eq_ignore_ascii_case("mdd"));
        Self::from_source(Box::new(DiskFile::open(path)?), mdd.then_some(Kind::Mdd))
    }

    /// Opens any source of bytes. `declared` is what the file's name says it is, where there is a name: a
    /// 3.0 header does not say, so a 3.0 file declared [`Kind::Mdd`] is refused, and one declared nothing
    /// is read as a dictionary.
    pub fn from_source(source: Box<dyn Source>, declared: Option<Kind>) -> Result<Self, Error> {
        let mut at = 0u64;
        let header_len = read_u32(&*source, &mut at, "header length")?;
        let header_len = length(u64::from(header_len), limits::HEADER_BYTES, "header")?;
        let header_bytes = read(&*source, &mut at, header_len, "header")?;
        let header_checksum = u32::from_le_bytes(read_array(&*source, &mut at, "header checksum")?);
        let header = header::parse(&header_bytes, header_checksum)?;
        let parts = match header.version {
            FormatVersion::V3_0 => {
                if declared == Some(Kind::Mdd) {
                    return Err(Error::Unsupported(Unsupported::ResourceLibraryV3));
                }
                v3::parts(&*source, at, &header)?
            }
            FormatVersion::V1_2 | FormatVersion::V2_0 => classic::parts(&*source, at, &header)?,
        };
        let Parts { codec, keys, blocks, scheme } = parts;
        let total_records = blocks.last().map_or(0, |b| b.records_offset + b.len as u64);

        // Where each record ends: the next larger start, or the end of all records.
        let mut starts: Vec<u64> = Vec::new();
        starts.try_reserve_exact(keys.len()).map_err(out_of_memory)?;
        starts.extend(keys.iter().map(|k| k.offset));
        starts.sort_unstable();
        starts.dedup();
        let mut ends = Vec::new();
        ends.try_reserve_exact(keys.len()).map_err(out_of_memory)?;
        for key in &keys {
            if key.offset > total_records {
                return Err(Error::Malformed("a key points past the end of the records".into()));
            }
            let next = starts.partition_point(|&s| s <= key.offset);
            ends.push(starts.get(next).copied().unwrap_or(total_records));
        }

        let strip = header.strip_key != Some(false);
        let mut exact: HashMap<String, Vec<usize>> = HashMap::new();
        let mut folded: HashMap<String, Vec<usize>> = HashMap::new();
        exact.try_reserve(keys.len()).map_err(out_of_memory)?;
        folded.try_reserve(keys.len()).map_err(out_of_memory)?;
        for (i, key) in keys.iter().enumerate() {
            exact.entry(key.text.clone()).or_default().push(i);
            folded.entry(fold(&key.text, header.key_case_sensitive, strip)).or_default().push(i);
        }

        Ok(Self { source, header, codec, keys, ends, exact, folded, blocks, scheme })
    }

    pub fn header(&self) -> &Header {
        &self.header
    }

    /// How many keys the file holds.
    pub fn len(&self) -> usize {
        self.keys.len()
    }

    pub fn is_empty(&self) -> bool {
        self.keys.is_empty()
    }

    /// Every key, in file order.
    pub fn keys(&self) -> impl Iterator<Item = &str> {
        self.keys.iter().map(|k| k.text.as_str())
    }

    /// Every record whose key matches `key` under the file's own rules: case-insensitive unless
    /// `KeyCaseSensitive="Yes"`, and ignoring everything but letters and digits unless `StripKey="No"`.
    /// Exact matches come first, then folded ones, each in file order. Empty when nothing matches; an
    /// error when a matching record could not be read, or when the matches together exceed
    /// [`limits::LOOKUP_BYTES`].
    pub fn lookup(&self, key: &str) -> Result<Vec<Record>, Error> {
        self.lookup_within(key, Budget { bytes: limits::LOOKUP_BYTES, records: limits::LOOKUP_RECORDS })
    }

    fn lookup_within(&self, key: &str, budget: Budget) -> Result<Vec<Record>, Error> {
        let strip = self.header.strip_key != Some(false);
        let exact = self.exact.get(key).map(Vec::as_slice).unwrap_or(&[]);
        let folded_key = fold(key, self.header.key_case_sensitive, strip);
        let folded = self.folded.get(&folded_key).map(Vec::as_slice).unwrap_or(&[]);
        // The folded matches include the exact ones, which are exactly those spelled as asked.
        let rest = folded.iter().filter(|&&i| self.keys.get(i).is_some_and(|k| k.text != key));
        let order: Vec<usize> = exact.iter().chain(rest).copied().collect();
        if order.len() > budget.records {
            return Err(Error::Malformed(format!("\"{key}\" matches more than {} records", budget.records)));
        }
        // Read in file order, so the blocks are touched in rising order and each is decompressed once
        // however the answer is ordered; then answer in the promised order.
        let mut by_offset: Vec<(u64, usize)> = Vec::with_capacity(order.len());
        for (slot, &i) in order.iter().enumerate() {
            by_offset.push((self.span(i)?.0, slot));
        }
        by_offset.sort_unstable();
        let over = || Error::Malformed(format!("the records for \"{key}\" total more than {} bytes", budget.bytes));
        let mut answers: Vec<Option<Record>> = order.iter().map(|_| None).collect();
        let (mut total, mut cache) = (0u64, Vec::new());
        for (_, slot) in by_offset {
            let i = order.get(slot).copied().ok_or_else(|| malformed("key index"))?;
            // The stored size bounds what is read; the returned size, which decoding may enlarge, is what
            // is kept, so both are counted.
            let (start, end) = self.span(i)?;
            if total.saturating_add(end.saturating_sub(start)) > budget.bytes {
                return Err(over());
            }
            let record = self.record(i, &mut cache)?;
            total = total.saturating_add((record.key.len() + record.data.len()) as u64);
            if total > budget.bytes {
                return Err(over());
            }
            if let Some(answer) = answers.get_mut(slot) {
                *answer = Some(record);
            }
        }
        answers.into_iter().map(|a| a.ok_or_else(|| malformed("lookup"))).collect()
    }

    /// Where key `i`'s record starts and ends in the concatenated records.
    fn span(&self, i: usize) -> Result<(u64, u64), Error> {
        let key = self.keys.get(i).ok_or_else(|| malformed("key index"))?;
        let end = self.ends.get(i).copied().ok_or_else(|| malformed("key index"))?;
        Ok((key.offset, end))
    }

    fn record(&self, i: usize, cache: &mut Vec<(usize, Vec<u8>)>) -> Result<Record, Error> {
        let key = self.keys.get(i).ok_or_else(|| malformed("key index"))?;
        let (start, end) = self.span(i)?;
        let mut data = self.records(start, end, cache)?;
        if self.header.kind == Kind::Mdx {
            data = self.codec.decode(&trim_terminators(data, self.codec.unit())?).into_bytes();
        }
        Ok(Record { key: key.text.clone(), data })
    }

    /// The bytes from `start` to `end` of the concatenated records, decompressing every block they touch.
    /// `cache` holds the blocks the previous record touched, so records of one lookup that share blocks
    /// (matches sit next to each other, or lead to the same record) decompress each block once. It never
    /// holds more than one record's blocks.
    fn records(&self, start: u64, end: u64, cache: &mut Vec<(usize, Vec<u8>)>) -> Result<Vec<u8>, Error> {
        let len = length(end.saturating_sub(start), limits::BLOCK_BYTES, "record")?;
        let mut out = Vec::with_capacity(len);
        let mut previous: HashMap<usize, Vec<u8>> = std::mem::take(cache).into_iter().collect();
        let mut touched = Vec::new();
        let first = self.blocks.partition_point(|b| b.records_offset + b.len as u64 <= start);
        for (index, block) in self.blocks.iter().enumerate().skip(first) {
            if block.records_offset >= end {
                break;
            }
            let decoded = match previous.remove(&index) {
                Some(decoded) => decoded,
                None => {
                    let mut at = block.file_offset;
                    let raw = read(&*self.source, &mut at, block.stored_len, "record block")?;
                    match self.scheme {
                        Scheme::Classic => block::decode(&raw, block.len, "record block")?,
                        Scheme::V3(key) => v3::decode_unit(&raw, block.len, &key, "record block")?,
                    }
                }
            };
            touched.push((index, decoded));
            let data = touched.last().map(|(_, data)| data.as_slice()).unwrap_or(&[]);
            let from = usize::try_from(start.saturating_sub(block.records_offset)).unwrap_or(usize::MAX);
            let to = usize::try_from(end - block.records_offset).unwrap_or(usize::MAX).min(data.len());
            out.extend_from_slice(data.get(from..to).ok_or_else(|| malformed("record block"))?);
        }
        *cache = touched;
        if out.len() != len {
            return Err(Error::Malformed("a record runs past the end of the records".into()));
        }
        Ok(out)
    }
}

/// An MDX record without its terminating nulls, removed in whole code units: a UTF-16 record of odd length
/// is malformed, since trimming it would split a code unit.
fn trim_terminators(mut data: Vec<u8>, unit: usize) -> Result<Vec<u8>, Error> {
    if !data.len().is_multiple_of(unit.max(1)) {
        return Err(Error::Malformed("a record is not a whole number of code units".into()));
    }
    while data.len() >= unit && data.get(data.len() - unit..).is_some_and(|t| t.iter().all(|&b| b == 0)) {
        data.truncate(data.len() - unit);
    }
    Ok(data)
}

/// An allocation the index needed and could not get, reported rather than aborting the process.
pub(crate) fn out_of_memory(_: std::collections::TryReserveError) -> Error {
    Error::Io(io::ErrorKind::OutOfMemory.into())
}

pub(crate) fn malformed(what: &str) -> Error {
    Error::Malformed(format!("the {what} is inconsistent"))
}

pub(crate) fn read(source: &dyn Source, at: &mut u64, len: usize, what: &str) -> Result<Vec<u8>, Error> {
    let end = at.checked_add(len as u64).ok_or_else(|| malformed(what))?;
    if end > source.len() {
        return Err(Error::Malformed(format!("the {what} runs past the end of the file")));
    }
    let mut buf = vec![0u8; len];
    source.read_exact_at(*at, &mut buf)?;
    *at = end;
    Ok(buf)
}

pub(crate) fn read_array<const N: usize>(source: &dyn Source, at: &mut u64, what: &str) -> Result<[u8; N], Error> {
    read(source, at, N, what)?.try_into().map_err(|_| malformed(what))
}

pub(crate) fn read_u32(source: &dyn Source, at: &mut u64, what: &str) -> Result<u32, Error> {
    Ok(u32::from_be_bytes(read_array(source, at, what)?))
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::indexing_slicing)]
mod tests {
    use super::*;
    use xdict_mdx_writer::{self as writer, Entry, Spec};

    /// Many keys may lead to one record; what a lookup returns is bounded all the same.
    #[test]
    fn a_lookup_stops_at_its_byte_budget() {
        let record = "x".repeat(100);
        let entries: Vec<Entry> = (0..3).map(|_| Entry::text("bank", &record)).collect();
        let file = File::from_source(Box::new(writer::write(&Spec::mdx(), &entries).unwrap()), None).unwrap();
        // Each stored record is its 100 bytes and a terminating null; each returned one, 100 bytes and its key.
        let bytes = |n| Budget { bytes: n, records: 10 };
        assert_eq!(file.lookup_within("bank", bytes(312)).unwrap().len(), 3);
        assert!(matches!(file.lookup_within("bank", bytes(311)), Err(Error::Malformed(_))));
        assert!(matches!(file.lookup_within("bank", Budget { bytes: 1 << 20, records: 2 }), Err(Error::Malformed(_))));
    }

    /// The budget counts what a lookup returns, after decoding: an invalid byte becomes a 3-byte U+FFFD.
    #[test]
    fn the_lookup_budget_counts_decoded_text() {
        let entries = [Entry::bytes("bad", &[0xFF; 100])];
        let file = File::from_source(Box::new(writer::write(&Spec::mdx(), &entries).unwrap()), None).unwrap();
        let records = file.lookup_within("bad", Budget { bytes: 1 << 20, records: 10 }).unwrap();
        assert_eq!(records[0].data.len(), 300);
        assert!(matches!(file.lookup_within("bad", Budget { bytes: 200, records: 10 }), Err(Error::Malformed(_))));
    }

    #[test]
    fn terminators_are_trimmed_in_whole_code_units() {
        assert_eq!(trim_terminators(vec![0x41, 0, 0, 0], 2).unwrap(), [0x41, 0]);
        assert_eq!(trim_terminators(vec![b'a', 0, 0], 1).unwrap(), b"a");
        assert!(matches!(trim_terminators(vec![0x41, 0, 0], 2), Err(Error::Malformed(_))));
    }

    /// A source that records where each read starts.
    struct Counting(Vec<u8>, std::sync::Arc<std::sync::Mutex<Vec<u64>>>);

    impl Source for Counting {
        fn len(&self) -> u64 {
            self.0.len() as u64
        }
        fn read_exact_at(&self, offset: u64, buf: &mut [u8]) -> io::Result<()> {
            self.1.lock().unwrap().push(offset);
            self.0.read_exact_at(offset, buf)
        }
    }

    /// Records: B, then b twice, spread over two 8-byte blocks so that b's first record shares block 0 with
    /// B. A lookup for "b" returns b, b, then B: blocks 0+1, 1, then 0 again, unless it reads in file order.
    #[test]
    fn a_lookup_reads_each_block_once() {
        let spec = Spec { version: writer::Version::V3_0, compression: writer::Compression::None, block_size: 8, ..Spec::mdx() };
        let entries = [Entry::text("B", "xxxx"), Entry::text("b", "yyyy"), Entry::text("b", "zzzz")];
        let reads = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let source = Counting(writer::write(&spec, &entries).unwrap(), reads.clone());
        let file = File::from_source(Box::new(source), None).unwrap();
        reads.lock().unwrap().clear();
        let found = file.lookup("b").unwrap();
        let texts: Vec<&[u8]> = found.iter().map(|r| r.data.as_slice()).collect();
        assert_eq!(texts, [b"yyyy".as_slice(), b"zzzz", b"xxxx"]);
        let mut offsets = reads.lock().unwrap().clone();
        let all = offsets.len();
        offsets.sort_unstable();
        offsets.dedup();
        assert_eq!(offsets.len(), all, "a block was read twice: {:?}", reads.lock().unwrap());
    }
}
