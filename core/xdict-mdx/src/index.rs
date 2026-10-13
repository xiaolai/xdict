//! The per-edition index (`core-api.md` §2.3; ADR-0007 decision 17): a file's keys, where their records lie,
//! and the keys' order under the file's own folding, written once at import and read at every open instead
//! of the file's key blocks.
//!
//! **It is derived, untrusted and disposable.** It is checked when it is loaded (each section's xxh3, every
//! offset's bounds, the order a permutation) and anything wrong with it is [`Stale`]: build it again. A search
//! compares every candidate it returns with the query, so a wrong order can make a key unreachable but can
//! never return the wrong one.
//!
//! Layout, little-endian: a fixed header (`HEADER_LEN` bytes, ending with the xxh3 of what precedes it),
//! then the sections the header's table places: key text in file order; text offsets (`u32`, one more than
//! the keys); record starts and ends (`u64`); the tier-1 order (`u32` key numbers sorted by folded key, ties
//! in file order); the record-block table (four `u64` per block); the public-key bitmap (empty until the
//! core marks internal keys); and a section reserved for the tier-2 order.

use std::borrow::Cow;
use std::cmp::Ordering;

use xxhash_rust::xxh3::xxh3_64;

use crate::text::fold;
use crate::{Error, Kind, RecordBlock, Source, limits, malformed};

/// The index's own layout. Any change to what is written, or how, raises it.
pub const FORMAT: u32 = 1;
/// The reader's interpretation of a file: raised when the keys, offsets or folding it derives would differ.
pub const READER: u32 = 1;

const MAGIC: &[u8; 8] = b"XDICTIX1";
const SECTIONS: usize = 8;
const TABLE_AT: usize = 96;
const HEADER_LEN: usize = TABLE_AT + SECTIONS * 24 + 8;

const TEXT: usize = 0;
const OFFSETS: usize = 1;
const STARTS: usize = 2;
const ENDS: usize = 3;
const ORDER: usize = 4;
const BLOCKS: usize = 5;
const PUBLIC: usize = 6;
const TIER2: usize = 7;

/// Bytes the index can be read from: a mapped or loaded file, or one read piece by piece (the Web).
pub trait Region: Send + Sync {
    fn len(&self) -> u64;
    fn is_empty(&self) -> bool {
        self.len() == 0
    }
    /// `len` bytes from `offset`: borrowed where the bytes are in memory, read where they are not.
    fn bytes(&self, offset: u64, len: usize) -> Result<Cow<'_, [u8]>, Error>;
}

impl Region for Vec<u8> {
    fn len(&self) -> u64 {
        self.as_slice().len() as u64
    }
    fn bytes(&self, offset: u64, len: usize) -> Result<Cow<'_, [u8]>, Error> {
        slice(self, offset, len).map(Cow::Borrowed)
    }
}

/// Any bytes in memory, a mapped file among them.
pub struct Slice<T>(pub T);

impl<T: AsRef<[u8]> + Send + Sync> Region for Slice<T> {
    fn len(&self) -> u64 {
        self.0.as_ref().len() as u64
    }
    fn bytes(&self, offset: u64, len: usize) -> Result<Cow<'_, [u8]>, Error> {
        slice(self.0.as_ref(), offset, len).map(Cow::Borrowed)
    }
}

/// An index read piece by piece through a [`Source`], as the Web reads its private files.
pub struct SourceRegion(pub Box<dyn Source>);

impl Region for SourceRegion {
    fn len(&self) -> u64 {
        self.0.len()
    }
    fn bytes(&self, offset: u64, len: usize) -> Result<Cow<'_, [u8]>, Error> {
        let end = offset.checked_add(len as u64).ok_or_else(|| malformed("index"))?;
        if end > self.0.len() {
            return Err(Error::Malformed("a read runs past the end of the index".into()));
        }
        let mut buf = vec![0u8; len];
        self.0.read_exact_at(offset, &mut buf)?;
        Ok(Cow::Owned(buf))
    }
}

fn slice(bytes: &[u8], offset: u64, len: usize) -> Result<&[u8], Error> {
    let start = usize::try_from(offset).map_err(|_| malformed("index"))?;
    let end = start.checked_add(len).ok_or_else(|| malformed("index"))?;
    bytes.get(start..end).ok_or_else(|| Error::Malformed("a read runs past the end of the index".into()))
}

/// Why an index cannot be used. Every case means the same thing to the caller, "build it again"; the reason
/// is for logs and for tests.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Stale {
    /// Not an index, or written by another index format.
    Format,
    /// Written by a reader that derived the file differently.
    Reader,
    /// Built for another file: another identity, header or length.
    OtherFile,
    /// Damaged or inconsistent: a checksum, a bound, the order.
    Damaged(String),
}

/// What an index must have been built from to be used for a file.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Binding {
    /// The edition (SHA-256) of an MDX, or the validation token of an MDD.
    pub identity: [u8; 32],
    /// xxh3 of the file's header bytes.
    pub header: u64,
    pub source_len: u64,
    pub kind: Kind,
}

/// Every key of a file, collected from its key blocks: the key text in file order, where each key's text
/// starts in it (with one more entry, the end), and where each key's record starts.
#[derive(Default)]
pub(crate) struct Keys {
    pub(crate) text: Vec<u8>,
    pub(crate) offsets: Vec<u32>,
    pub(crate) starts: Vec<u64>,
}

/// How a file's keys are compared: under its own rules for an MDX; for an MDD, case-insensitively and never
/// stripped, since a path's punctuation is part of it (`core-api.md` finding 24).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Rules {
    pub(crate) case_sensitive: bool,
    pub(crate) strip: bool,
}

impl Rules {
    pub(crate) fn fold<'a>(&self, key: &'a str) -> Cow<'a, str> {
        fold(key, self.case_sensitive, self.strip)
    }
}

/// Writes the index of a file whose keys and record blocks have been read.
pub(crate) fn build(keys: Keys, blocks: &[RecordBlock], rules: Rules, binding: Binding) -> Result<Vec<u8>, Error> {
    let n = keys.starts.len();
    if keys.offsets.len() != n + 1 {
        return Err(malformed("key index"));
    }
    let total = blocks.last().map_or(0, |b| b.records_offset + b.len as u64);
    let key = |i: usize| -> Result<&str, Error> {
        let (from, to) = (offset(&keys.offsets, i)?, offset(&keys.offsets, i + 1)?);
        let bytes = keys.text.get(from..to).ok_or_else(|| malformed("key index"))?;
        std::str::from_utf8(bytes).map_err(|_| malformed("key text"))
    };

    // Where each record ends: the next larger start, or the end of all records.
    let mut sorted = keys.starts.clone();
    sorted.sort_unstable();
    sorted.dedup();
    let mut ends = Vec::new();
    ends.try_reserve_exact(n).map_err(crate::out_of_memory)?;
    for &start in &keys.starts {
        if start > total {
            return Err(Error::Malformed("a key points past the end of the records".into()));
        }
        let next = sorted.partition_point(|&s| s <= start);
        ends.push(sorted.get(next).copied().unwrap_or(total));
    }

    // The tier-1 order: folded once, then sorted stably, so keys that fold together stay in file order.
    let mut folded_text: Vec<u8> = Vec::new();
    let mut folded_at: Vec<u32> = Vec::new();
    folded_at.try_reserve_exact(n + 1).map_err(crate::out_of_memory)?;
    folded_at.push(0);
    for i in 0..n {
        folded_text.extend_from_slice(rules.fold(key(i)?).as_bytes());
        folded_at.push(u32::try_from(folded_text.len()).map_err(|_| too_large())?);
    }
    let folded = |i: u32| -> &[u8] {
        let (from, to) = (folded_at.get(i as usize).copied(), folded_at.get(i as usize + 1).copied());
        from.zip(to).and_then(|(f, t)| folded_text.get(f as usize..t as usize)).unwrap_or(&[])
    };
    let count = u32::try_from(n).map_err(|_| too_large())?;
    let mut order: Vec<u32> = (0..count).collect();
    order.sort_by(|&a, &b| folded(a).cmp(folded(b)));

    let mut table = [(0u64, 0u64, 0u64); SECTIONS];
    let mut out: Vec<u8> = vec![0; HEADER_LEN];
    let mut section = |out: &mut Vec<u8>, which: usize, bytes: &[u8]| -> Result<(), Error> {
        while !out.len().is_multiple_of(8) {
            out.push(0);
        }
        let slot = table.get_mut(which).ok_or_else(|| malformed("index"))?;
        *slot = (out.len() as u64, bytes.len() as u64, xxh3_64(bytes));
        out.try_reserve(bytes.len()).map_err(crate::out_of_memory)?;
        out.extend_from_slice(bytes);
        Ok(())
    };
    section(&mut out, TEXT, &keys.text)?;
    section(&mut out, OFFSETS, &le(&keys.offsets, |v| v.to_le_bytes()))?;
    section(&mut out, STARTS, &le(&keys.starts, |v| v.to_le_bytes()))?;
    section(&mut out, ENDS, &le(&ends, |v| v.to_le_bytes()))?;
    section(&mut out, ORDER, &le(&order, |v| v.to_le_bytes()))?;
    let block_table: Vec<u64> =
        blocks.iter().flat_map(|b| [b.file_offset, b.stored_len as u64, b.records_offset, b.len as u64]).collect();
    section(&mut out, BLOCKS, &le(&block_table, |v| v.to_le_bytes()))?;
    section(&mut out, PUBLIC, &[])?;
    section(&mut out, TIER2, &[])?;

    let mut head = Vec::with_capacity(HEADER_LEN);
    head.extend_from_slice(MAGIC);
    head.extend_from_slice(&FORMAT.to_le_bytes());
    head.extend_from_slice(&READER.to_le_bytes());
    head.extend_from_slice(&0u32.to_le_bytes());
    head.push(u8::from(binding.kind == Kind::Mdd));
    head.push(u8::from(rules.case_sensitive) | u8::from(rules.strip) << 1);
    head.extend_from_slice(&[0, 0]);
    head.extend_from_slice(&binding.identity);
    head.extend_from_slice(&binding.header.to_le_bytes());
    head.extend_from_slice(&binding.source_len.to_le_bytes());
    head.extend_from_slice(&(n as u64).to_le_bytes());
    head.extend_from_slice(&(blocks.len() as u64).to_le_bytes());
    head.extend_from_slice(&total.to_le_bytes());
    debug_assert_eq!(head.len(), TABLE_AT);
    for (at, len, sum) in table {
        head.extend_from_slice(&at.to_le_bytes());
        head.extend_from_slice(&len.to_le_bytes());
        head.extend_from_slice(&sum.to_le_bytes());
    }
    head.extend_from_slice(&xxh3_64(&head).to_le_bytes());
    out.get_mut(..HEADER_LEN).ok_or_else(|| malformed("index"))?.copy_from_slice(&head);
    Ok(out)
}

fn le<T: Copy, const N: usize>(values: &[T], bytes: impl Fn(T) -> [u8; N]) -> Vec<u8> {
    values.iter().flat_map(|&v| bytes(v)).collect()
}

fn offset(offsets: &[u32], i: usize) -> Result<usize, Error> {
    offsets.get(i).map(|&o| o as usize).ok_or_else(|| malformed("key index"))
}

fn too_large() -> Error {
    Error::TooLarge("the key index would pass 4 GiB of key text".into())
}

/// A section's place in the index.
#[derive(Clone, Copy)]
struct Span {
    at: u64,
    len: u64,
}

/// A loaded, checked index.
pub(crate) struct Index {
    region: Box<dyn Region>,
    keys: usize,
    text: Span,
    offsets: Span,
    starts: Span,
    ends: Span,
    order: Span,
    pub(crate) blocks: Vec<RecordBlock>,
    pub(crate) total_records: u64,
    pub(crate) rules: Rules,
}

impl Index {
    /// Loads and checks an index for the file `binding` describes.
    pub(crate) fn load(region: Box<dyn Region>, binding: &Binding) -> Result<Self, Stale> {
        let damaged = |what: &str| Stale::Damaged(what.to_owned());
        let head = region.bytes(0, HEADER_LEN).map_err(|_| Stale::Format)?;
        let field = |at: usize, len: usize| head.get(at..at + len).ok_or(Stale::Format);
        let u32_at = |at: usize| -> Result<u32, Stale> {
            Ok(u32::from_le_bytes(field(at, 4)?.try_into().map_err(|_| Stale::Format)?))
        };
        let u64_at = |at: usize| -> Result<u64, Stale> {
            Ok(u64::from_le_bytes(field(at, 8)?.try_into().map_err(|_| Stale::Format)?))
        };
        if field(0, 8)? != MAGIC || u32_at(8)? != FORMAT {
            return Err(Stale::Format);
        }
        if xxh3_64(field(0, HEADER_LEN - 8)?) != u64_at(HEADER_LEN - 8)? {
            return Err(damaged("the header's checksum"));
        }
        if u32_at(12)? != READER {
            return Err(Stale::Reader);
        }
        let kind = if field(20, 1)? == [1] { Kind::Mdd } else { Kind::Mdx };
        let flags = field(21, 1)?.first().copied().unwrap_or(0);
        let rules = Rules { case_sensitive: flags & 1 != 0, strip: flags & 2 != 0 };
        if kind != binding.kind
            || field(24, 32)? != binding.identity
            || u64_at(56)? != binding.header
            || u64_at(64)? != binding.source_len
        {
            return Err(Stale::OtherFile);
        }
        let keys = usize::try_from(u64_at(72)?).map_err(|_| damaged("the key count"))?;
        let block_count = usize::try_from(u64_at(80)?).map_err(|_| damaged("the block count"))?;
        let total_records = u64_at(88)?;
        if keys as u64 > limits::KEYS {
            return Err(damaged("the key count"));
        }

        let mut spans = [Span { at: 0, len: 0 }; SECTIONS];
        for (i, span) in spans.iter_mut().enumerate() {
            let at = TABLE_AT + i * 24;
            *span = Span { at: u64_at(at)?, len: u64_at(at + 8)? };
            let end = span.at.checked_add(span.len).ok_or_else(|| damaged("a section's bounds"))?;
            if span.at < HEADER_LEN as u64 || end > region.len() {
                return Err(damaged("a section's bounds"));
            }
            let len = usize::try_from(span.len).map_err(|_| damaged("a section's bounds"))?;
            let bytes = region.bytes(span.at, len).map_err(|_| damaged("a section"))?;
            if xxh3_64(&bytes) != u64_at(at + 16)? {
                return Err(Stale::Damaged(format!("section {i}'s checksum")));
            }
        }
        let [text, offsets, starts, ends, order, blocks, _, _] = spans;
        let sized = |span: Span, width: u64, count: usize| span.len == width * count as u64;
        if !sized(offsets, 4, keys + 1)
            || !sized(starts, 8, keys)
            || !sized(ends, 8, keys)
            || !sized(order, 4, keys)
            || !sized(blocks, 32, block_count)
        {
            return Err(damaged("a section's size"));
        }
        drop(head);

        let index = Self { region, keys, text, offsets, starts, ends, order, blocks: Vec::new(), total_records, rules };
        index.check_structure()?;
        let blocks = index.read_blocks(blocks, block_count)?;
        Ok(Self { blocks, ..index })
    }

    /// One pass over each table, no folding: text offsets rise within the text, records lie within the
    /// records, and the order names every key once.
    fn check_structure(&self) -> Result<(), Stale> {
        let damaged = |what: &str| Stale::Damaged(what.to_owned());
        let words = |span: Span| self.region.bytes(span.at, span.len as usize).map_err(|_| damaged("a section"));
        let offsets = words(self.offsets)?;
        let mut previous = 0u32;
        for (i, chunk) in offsets.as_chunks::<4>().0.iter().enumerate() {
            let value = u32::from_le_bytes(*chunk);
            if (i == 0 && value != 0) || value < previous || u64::from(value) > self.text.len {
                return Err(damaged("the text offsets"));
            }
            previous = value;
        }
        if u64::from(previous) != self.text.len {
            return Err(damaged("the text offsets"));
        }
        let (starts, ends) = (words(self.starts)?, words(self.ends)?);
        for (s, e) in starts.as_chunks::<8>().0.iter().zip(ends.as_chunks::<8>().0) {
            let (s, e) = (u64::from_le_bytes(*s), u64::from_le_bytes(*e));
            if s > e || e > self.total_records {
                return Err(damaged("a record's bounds"));
            }
        }
        let order = words(self.order)?;
        let mut seen = vec![false; self.keys];
        for chunk in order.as_chunks::<4>().0 {
            let i = u32::from_le_bytes(*chunk) as usize;
            match seen.get_mut(i) {
                Some(slot @ false) => *slot = true,
                _ => return Err(damaged("the order is not a permutation")),
            }
        }
        Ok(())
    }

    fn read_blocks(&self, span: Span, count: usize) -> Result<Vec<RecordBlock>, Stale> {
        let damaged = |what: &str| Stale::Damaged(what.to_owned());
        let bytes = self.region.bytes(span.at, span.len as usize).map_err(|_| damaged("the record blocks"))?;
        let mut blocks = Vec::with_capacity(count);
        let mut expected = 0u64;
        for b in bytes.as_chunks::<32>().0 {
            let words = b.as_chunks::<8>().0;
            let word = |i: usize| -> Result<u64, Stale> {
                words.get(i).map(|w| u64::from_le_bytes(*w)).ok_or_else(|| damaged("the record blocks"))
            };
            let block = RecordBlock {
                file_offset: word(0)?,
                stored_len: usize::try_from(word(1)?).map_err(|_| damaged("a record block"))?,
                records_offset: word(2)?,
                len: usize::try_from(word(3)?).map_err(|_| damaged("a record block"))?,
            };
            if block.records_offset != expected
                || block.len as u64 > limits::BLOCK_BYTES
                || block.stored_len as u64 > limits::BLOCK_BYTES
            {
                return Err(damaged("the record blocks"));
            }
            expected = expected.checked_add(block.len as u64).ok_or_else(|| damaged("the record blocks"))?;
            blocks.push(block);
        }
        if expected != self.total_records {
            return Err(damaged("the record blocks"));
        }
        Ok(blocks)
    }

    pub(crate) fn len(&self) -> usize {
        self.keys
    }

    fn word(&self, span: Span, width: usize, i: usize) -> Result<u64, Error> {
        let at = span.at.checked_add((i * width) as u64).ok_or_else(|| malformed("index"))?;
        if (i * width + width) as u64 > span.len {
            return Err(malformed("index"));
        }
        let bytes = self.region.bytes(at, width)?;
        let mut value = [0u8; 8];
        value.get_mut(..width).ok_or_else(|| malformed("index"))?.copy_from_slice(&bytes);
        Ok(u64::from_le_bytes(value))
    }

    /// Key `i`, as the file spells it.
    pub(crate) fn key(&self, i: usize) -> Result<Cow<'_, str>, Error> {
        let (from, to) = (self.word(self.offsets, 4, i)?, self.word(self.offsets, 4, i + 1)?);
        let len = usize::try_from(to.checked_sub(from).ok_or_else(|| malformed("key index"))?)
            .map_err(|_| malformed("key index"))?;
        let at = self.text.at.checked_add(from).ok_or_else(|| malformed("key index"))?;
        match self.region.bytes(at, len)? {
            Cow::Borrowed(b) => std::str::from_utf8(b).map(Cow::Borrowed).map_err(|_| malformed("key text")),
            Cow::Owned(v) => String::from_utf8(v).map(Cow::Owned).map_err(|_| malformed("key text")),
        }
    }

    /// Where key `i`'s record starts and ends in the concatenated records.
    pub(crate) fn span(&self, i: usize) -> Result<(u64, u64), Error> {
        Ok((self.word(self.starts, 8, i)?, self.word(self.ends, 8, i)?))
    }

    /// Every key equal to `query` under the file's rules: those spelt exactly as asked first, then the rest,
    /// each in file order. Every candidate is compared with the query, whatever the order says.
    pub(crate) fn find(&self, query: &str) -> Result<Vec<usize>, Error> {
        let wanted = self.rules.fold(query);
        let folded_at = |j: usize| -> Result<(usize, Ordering), Error> {
            let i = self.word(self.order, 4, j)? as usize;
            Ok((i, self.rules.fold(&self.key(i)?).as_ref().cmp(wanted.as_ref())))
        };
        // The first position whose folded key is not less than the query's.
        let (mut low, mut high) = (0usize, self.keys);
        while low < high {
            let mid = low + (high - low) / 2;
            if folded_at(mid)?.1 == Ordering::Less {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        let (mut exact, mut rest) = (Vec::new(), Vec::new());
        for j in low..self.keys {
            let (i, ordering) = folded_at(j)?;
            if ordering != Ordering::Equal {
                break;
            }
            if self.key(i)? == query { exact.push(i) } else { rest.push(i) }
        }
        exact.sort_unstable();
        rest.sort_unstable();
        exact.extend(rest);
        Ok(exact)
    }
}
