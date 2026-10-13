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
//! **XDict sorts its own index** rather than searching the file's key order: only 79 of 276 real files are
//! sorted under the reader's folding (`core-api.md` §2.2), and a binary search under a guessed collation
//! would miss keys silently. The index ([`index`]) is built from every key block once, kept, and read at
//! every later open; records are read only when looked up.

use std::borrow::Cow;
use std::collections::HashMap;
use std::io;
#[cfg(any(unix, windows))]
use std::path::Path;
use std::sync::Arc;

mod block;
mod bytes;
mod cipher;
mod classic;
mod header;
pub mod index;
mod keys;
pub mod limits;
mod lzo;
mod text;
mod v3;

use bytes::length;
use index::{Binding, Derive, Index, Plain, Region, Rules, Stale};
use text::Codec;
use xxhash_rust::xxh3::xxh3_64;

/// Why a file could not be read. The `Display` text is a sentence a reader can be shown.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("the file could not be read: {0}")]
    Io(#[from] io::Error),
    #[error("this dictionary uses something XDict does not support: {0}")]
    Unsupported(Unsupported),
    #[error("the file is damaged: {0}")]
    Malformed(String),
    /// A valid file asking for more than XDict holds at once: a limit, not damage.
    #[error("this is more than XDict reads at once: {0}")]
    TooLarge(String),
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
    #[error("LZO compression in a format 3.0 file, which no real file has shown")]
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
    /// Bytes of an MDX record its encoding could not read, each run replaced by U+FFFD in `data`.
    pub lossy: u64,
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
    file: std::sync::Arc<std::fs::File>,
    len: u64,
}

#[cfg(any(unix, windows))]
impl DiskFile {
    pub fn open(path: &Path) -> io::Result<Self> {
        let file = std::fs::File::open(path)?;
        let len = file.metadata()?.len();
        Ok(Self { file: std::sync::Arc::new(file), len })
    }

    /// A file already open, read through that same descriptor, as `len` bytes long.
    pub fn shared(file: std::sync::Arc<std::fs::File>, len: u64) -> Self {
        Self { file, len }
    }
}

#[cfg(any(unix, windows))]
impl Source for DiskFile {
    fn len(&self) -> u64 {
        self.len
    }
    #[cfg(unix)]
    fn read_exact_at(&self, offset: u64, buf: &mut [u8]) -> io::Result<()> {
        std::os::unix::fs::FileExt::read_exact_at(&*self.file, buf, offset)
    }
    #[cfg(windows)]
    fn read_exact_at(&self, mut offset: u64, mut buf: &mut [u8]) -> io::Result<()> {
        while !buf.is_empty() {
            let n = std::os::windows::fs::FileExt::seek_read(&*self.file, buf, offset)?;
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

/// Where one record block sits in the file, and in the concatenated records.
pub(crate) struct RecordBlock {
    file_offset: u64,
    stored_len: usize,
    records_offset: u64,
    len: usize,
}

/// What one lookup may read: its records' bytes, keys included, and how many records. Spent as records are
/// read, so a caller that reads several sets of records for one answer (a lookup and the targets of its
/// redirects) passes the same budget to each and is bounded as a whole.
#[derive(Clone, Copy, Debug)]
pub struct Budget {
    bytes: u64,
    records: usize,
}

impl Budget {
    /// At most `bytes` of records, keys included, and `records` records.
    pub const fn new(bytes: u64, records: usize) -> Self {
        Budget { bytes, records }
    }

    /// The reader's own: [`limits::LOOKUP_BYTES`] and [`limits::LOOKUP_RECORDS`].
    pub const fn lookup() -> Self {
        Budget::new(limits::LOOKUP_BYTES, limits::LOOKUP_RECORDS)
    }

    /// Takes `n` records, all or none.
    fn take_records(&mut self, n: usize) -> Result<(), Error> {
        self.records = self.records.checked_sub(n).ok_or_else(|| {
            Error::TooLarge(format!("{n} records are more than the {} this lookup has left to read", self.records))
        })?;
        Ok(())
    }

    /// Refuses a read of `n` bytes the budget could not return, before it is made.
    fn afford(&self, n: u64) -> Result<(), Error> {
        if n > self.bytes {
            return Err(Error::TooLarge(format!("a {n}-byte record is more than the {} bytes left", self.bytes)));
        }
        Ok(())
    }

    /// Takes `n` bytes.
    fn take_bytes(&mut self, n: u64) -> Result<(), Error> {
        self.afford(n)?;
        self.bytes -= n;
        Ok(())
    }
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
    keys: index::Keys,
    blocks: Vec<RecordBlock>,
}

/// An open MDX or MDD file: its header, and its index.
pub struct File {
    source: Box<dyn Source>,
    header: Header,
    codec: Codec,
    scheme: Scheme,
    index: Index,
}

/// A file's header as read: the header, where the rest of the file starts, and the xxh3 of its bytes, which
/// binds an index to the file it was built from.
struct Opening {
    header: Header,
    at: u64,
    digest: u64,
}

fn read_header(source: &dyn Source, declared: Option<Kind>) -> Result<Opening, Error> {
    let mut at = 0u64;
    let header_len = read_u32(source, &mut at, "header length")?;
    let header_len = length(u64::from(header_len), limits::HEADER_BYTES, "header")?;
    let header_bytes = read(source, &mut at, header_len, "header")?;
    let header_checksum = u32::from_le_bytes(read_array(source, &mut at, "header checksum")?);
    let header = header::parse(&header_bytes, header_checksum)?;
    // A 3.0 header does not say whether it is a dictionary or a resource library.
    if header.version == FormatVersion::V3_0 && declared == Some(Kind::Mdd) {
        return Err(Error::Unsupported(Unsupported::ResourceLibraryV3));
    }
    Ok(Opening { digest: xxh3_64(&header_bytes), header, at })
}

/// How a file's keys compare: an MDX by its own `KeyCaseSensitive` and `StripKey`; an MDD's paths
/// case-insensitively and never stripped (`core-api.md` finding 24).
fn rules(header: &Header) -> Rules {
    match header.kind {
        Kind::Mdd => Rules { case_sensitive: false, strip: false },
        Kind::Mdx => Rules { case_sensitive: header.key_case_sensitive, strip: header.strip_key != Some(false) },
    }
}

impl File {
    /// Opens a file on disk and builds its index in memory.
    #[cfg(any(unix, windows))]
    pub fn open(path: &Path) -> Result<Self, Error> {
        let mdd = path.extension().is_some_and(|e| e.eq_ignore_ascii_case("mdd"));
        Self::from_source(Box::new(DiskFile::open(path)?), mdd.then_some(Kind::Mdd))
    }

    /// Opens any source of bytes, building its index in memory. `declared` is what the file's name says it
    /// is, where there is a name: a 3.0 header does not say, so a 3.0 file declared [`Kind::Mdd`] is refused,
    /// and one declared nothing is read as a dictionary.
    pub fn from_source(source: Box<dyn Source>, declared: Option<Kind>) -> Result<Self, Error> {
        let index = Self::build_index(&*source, declared, [0; 32], &Plain)?;
        Self::with_index(source, declared, Box::new(index), [0; 32], Arc::new(Plain))?
            .map_err(|stale| Error::Malformed(format!("an index just built does not load ({stale:?})")))
    }

    /// Reads every key block of a file and writes its index, bound to `identity` (an edition, or an MDD's
    /// validation token), with what `derive` says of its keys: the slow step, done once per edition.
    pub fn build_index(
        source: &dyn Source,
        declared: Option<Kind>,
        identity: [u8; 32],
        derive: &dyn Derive,
    ) -> Result<Vec<u8>, Error> {
        let opening = read_header(source, declared)?;
        let header = &opening.header;
        let parts = match header.version {
            FormatVersion::V3_0 => v3::parts(source, opening.at, header)?,
            FormatVersion::V1_2 | FormatVersion::V2_0 => classic::parts(source, opening.at, header)?,
        };
        let binding = Binding { identity, header: opening.digest, source_len: source.len(), kind: header.kind };
        index::build(parts.keys, &parts.blocks, rules(header), binding, derive)
    }

    /// Opens a file through an index built for it under `derive`: reads the file's header and nothing else of
    /// it. The outer error is the file's; the inner [`Stale`] says the index cannot be used and must be built
    /// again.
    pub fn with_index(
        source: Box<dyn Source>,
        declared: Option<Kind>,
        region: Box<dyn Region>,
        identity: [u8; 32],
        derive: Arc<dyn Derive>,
    ) -> Result<Result<Self, Stale>, Error> {
        let opening = read_header(&*source, declared)?;
        let header = opening.header;
        let (codec, scheme) = match header.version {
            FormatVersion::V3_0 => (Codec::Utf8, Scheme::V3(v3::block_key(&header)?)),
            FormatVersion::V1_2 | FormatVersion::V2_0 => (classic::codec(&header)?, Scheme::Classic),
        };
        let binding = Binding { identity, header: opening.digest, source_len: source.len(), kind: header.kind };
        let index = match Index::load(region, &binding, derive) {
            Ok(index) => index,
            Err(stale) => return Ok(Err(stale)),
        };
        if index.rules != rules(&header) {
            return Ok(Err(Stale::Damaged("its folding rules are not the file's".into())));
        }
        let past_end = index.blocks.iter().any(|b| b.file_offset.saturating_add(b.stored_len as u64) > source.len());
        if past_end {
            return Ok(Err(Stale::Damaged("a record block lies past the end of the file".into())));
        }
        Ok(Ok(Self { source, header, codec, scheme, index }))
    }

    pub fn header(&self) -> &Header {
        &self.header
    }

    /// How many keys the file holds.
    pub fn len(&self) -> usize {
        self.index.len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Key `i`, in file order, as the file spells it.
    pub fn key(&self, i: usize) -> Result<Cow<'_, str>, Error> {
        self.index.key(i)
    }

    /// Every key, in file order.
    pub fn keys(&self) -> impl Iterator<Item = Result<Cow<'_, str>, Error>> {
        (0..self.len()).map(|i| self.key(i))
    }

    /// The numbers of every key matching `key` under the file's own rules: case-insensitive unless
    /// `KeyCaseSensitive="Yes"`, and ignoring everything but letters and digits unless `StripKey="No"` (an
    /// MDD's paths: case-insensitive, never stripped). Exact matches first, then folded ones, each in file
    /// order. Cheap: no record is read, so a caller can count and page what [`Self::lookup`] would refuse.
    pub fn find(&self, key: &str) -> Result<Vec<usize>, Error> {
        self.index.find(key)
    }

    /// The keys equal to `query` at tier 2 only: once both are unmarked by the index's [`Derive`], where the
    /// key's tier-2 form differs from its tier-1 one. In file order. [`Self::find`] of the unmarked query
    /// gives the rest of tier 2.
    pub fn find_unmarked(&self, query: &str) -> Result<Vec<usize>, Error> {
        self.index.find_unmarked(query)
    }

    /// `text` as the index's [`Derive`] unmarks it.
    pub fn unmark<'a>(&self, text: &'a str) -> Cow<'a, str> {
        self.index.derive().unmark(text)
    }

    /// Whether key `i` is offered to a reader, not marked internal by the index's [`Derive`].
    pub fn is_public(&self, i: usize) -> Result<bool, Error> {
        self.index.is_public(i)
    }

    /// The keys whose folded form begins with `prefix`'s, in folded order (ties in file order), passed to
    /// `each` until it returns `false`.
    pub fn prefixed(&self, prefix: &str, each: impl FnMut(usize) -> Result<bool, Error>) -> Result<(), Error> {
        self.index.prefixed(prefix, each)
    }

    /// The size of key `i`'s record as stored, before any decoding: what reading it will take.
    pub fn record_size(&self, i: usize) -> Result<u64, Error> {
        let (start, end) = self.span(i)?;
        Ok(end.saturating_sub(start))
    }

    /// Key `i`'s record.
    pub fn record(&self, i: usize) -> Result<Record, Error> {
        self.read_record(i, &mut Vec::new())
    }

    /// Reads the records of `keys` (key numbers), in the order they lie in the file, so that each block is
    /// decompressed once however many of them share it; `each` gets every key number and its record. Spends
    /// `budget`: the records are refused together, before any is read, when there are more than it has left;
    /// each record's stored size is checked before it is read, and its returned size (which decoding may
    /// enlarge) is what is taken.
    pub fn for_each_record(
        &self,
        keys: &[usize],
        budget: &mut Budget,
        mut each: impl FnMut(usize, Record) -> Result<(), Error>,
    ) -> Result<(), Error> {
        budget.take_records(keys.len())?;
        let mut by_offset: Vec<(u64, usize)> = Vec::with_capacity(keys.len());
        for &i in keys {
            by_offset.push((self.span(i)?.0, i));
        }
        by_offset.sort_unstable();
        let mut cache = Vec::new();
        for (_, i) in by_offset {
            budget.afford(self.record_size(i)?)?;
            let record = self.read_record(i, &mut cache)?;
            budget.take_bytes((record.key.len() + record.data.len()) as u64)?;
            each(i, record)?;
        }
        Ok(())
    }

    /// Every record whose key matches `key` under the file's own rules ([`Self::find`]), in that order. Empty
    /// when nothing matches; an error when a matching record could not be read, or when the matches
    /// together exceed [`limits::LOOKUP_BYTES`] or [`limits::LOOKUP_RECORDS`].
    pub fn lookup(&self, key: &str) -> Result<Vec<Record>, Error> {
        self.lookup_within(key, Budget::lookup())
    }

    fn lookup_within(&self, key: &str, mut budget: Budget) -> Result<Vec<Record>, Error> {
        let order = self.find(key)?;
        // Grown as records are read, so a lookup the budget refuses reserves nothing for every match first.
        let mut by_key: HashMap<usize, Record> = HashMap::new();
        self.for_each_record(&order, &mut budget, |i, record| {
            by_key.insert(i, record);
            Ok(())
        })
        .map_err(|e| match e {
            Error::TooLarge(why) => Error::TooLarge(format!("\"{key}\": {why}")),
            other => other,
        })?;
        order.iter().map(|i| by_key.remove(i).ok_or_else(|| malformed("lookup"))).collect()
    }

    /// Where key `i`'s record starts and ends in the concatenated records.
    fn span(&self, i: usize) -> Result<(u64, u64), Error> {
        self.index.span(i)
    }

    fn read_record(&self, i: usize, cache: &mut Vec<(usize, Vec<u8>)>) -> Result<Record, Error> {
        let key = self.index.key(i)?.into_owned();
        let (start, end) = self.span(i)?;
        let mut data = self.records(start, end, cache)?;
        let mut lossy = 0;
        if self.header.kind == Kind::Mdx {
            let (text, bad) = self.codec.decode_counted(&trim_terminators(data, self.codec.unit())?);
            data = text.into_bytes();
            lossy = bad;
        }
        Ok(Record { key, data, lossy })
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
        let blocks = &self.index.blocks;
        let first = blocks.partition_point(|b| b.records_offset + b.len as u64 <= start);
        for (index, block) in blocks.iter().enumerate().skip(first) {
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
        let bytes = |n| Budget::new(n, 10);
        assert_eq!(file.lookup_within("bank", bytes(312)).unwrap().len(), 3);
        assert!(matches!(file.lookup_within("bank", bytes(311)), Err(Error::TooLarge(_))));
        assert!(matches!(file.lookup_within("bank", Budget::new(1 << 20, 2)), Err(Error::TooLarge(_))));
    }

    /// One budget passed to several reads bounds them together, and too many records are refused unread.
    #[test]
    fn a_budget_is_spent_across_reads() {
        let entries = [Entry::text("a", &"x".repeat(100)), Entry::text("b", &"y".repeat(100))];
        let file = File::from_source(Box::new(writer::write(&Spec::mdx(), &entries).unwrap()), None).unwrap();
        let mut budget = Budget::new(1 << 20, 2);
        file.for_each_record(&[0], &mut budget, |_, _| Ok(())).unwrap();
        file.for_each_record(&[1], &mut budget, |_, _| Ok(())).unwrap();
        let mut read = 0;
        let third = file.for_each_record(&[0], &mut budget, |_, _| {
            read += 1;
            Ok(())
        });
        assert!(matches!(third, Err(Error::TooLarge(_))), "{third:?}");
        assert_eq!(read, 0, "a refused set reads nothing");
        let mut budget = Budget::new(150, 10);
        file.for_each_record(&[0], &mut budget, |_, _| Ok(())).unwrap();
        assert!(matches!(file.for_each_record(&[1], &mut budget, |_, _| Ok(())), Err(Error::TooLarge(_))));
    }

    /// The budget counts what a lookup returns, after decoding: an invalid byte becomes a 3-byte U+FFFD.
    #[test]
    fn the_lookup_budget_counts_decoded_text() {
        let entries = [Entry::bytes("bad", &[0xFF; 100])];
        let file = File::from_source(Box::new(writer::write(&Spec::mdx(), &entries).unwrap()), None).unwrap();
        let records = file.lookup_within("bad", Budget::new(1 << 20, 10)).unwrap();
        assert_eq!(records[0].data.len(), 300);
        assert!(matches!(file.lookup_within("bad", Budget::new(200, 10)), Err(Error::TooLarge(_))));
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
        let spec = Spec {
            version: writer::Version::V3_0,
            compression: writer::Compression::None,
            block_size: 8,
            ..Spec::mdx()
        };
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
