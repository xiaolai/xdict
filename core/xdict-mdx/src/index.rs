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
//! in file order); the record-block table (four `u64` per block); the public-key bitmap (bit `i % 8` of byte
//! `i / 8` set when key `i` is public); and the tier-2 order (`u32` key numbers of the keys whose tier-2 form
//! differs from their tier-1 one, sorted by it, ties in file order). What tier 2 is and which keys are
//! internal is a lookup policy's, not the reader's: the index stores what a [`Derive`] says, and the
//! derivation's version, so an index built under another is not used.

use std::borrow::Cow;
use std::sync::Arc;

use xxhash_rust::xxh3::{Xxh3, xxh3_64};

use crate::text::fold;
use crate::{Error, Kind, RecordBlock, Source, limits, malformed};

/// The index's own layout. Any change to what is written, or how, raises it.
pub const FORMAT: u32 = 2;
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

/// A file's keys, in file order, as a [`Derive`] is shown them.
pub trait KeyList {
    fn len(&self) -> usize;
    fn is_empty(&self) -> bool {
        self.len() == 0
    }
    fn key(&self, i: usize) -> Result<&str, Error>;
}

/// What a lookup policy derives from a file's keys when its index is built, and uses again to search it.
pub trait Derive: Send + Sync {
    /// The derivation's version, stored in the index: an index built under another is [`Stale::Reader`].
    fn version(&self) -> u32;
    /// A key or query without what a reader cannot type; the file's folding is applied after it. Must return
    /// the text itself, borrowed, when there is nothing to remove: most keys.
    fn unmark<'a>(&self, text: &'a str) -> Cow<'a, str>;
    /// The most [`Self::unmark`] holds while it works on a key, in bytes per byte of the key: the text it
    /// returns and any it builds on the way. An index build counts it against its memory before it unmarks
    /// (`keys::scratch_cost`), so it must be measured, not guessed.
    fn growth(&self) -> u64;
    /// Which of the file's keys are internal, never offered to a reader: one flag per key, and nothing else
    /// held but at most [`INTERNAL_BYTES`] a key beside the flags, which an index build counts.
    fn internal(&self, keys: &dyn KeyList) -> Result<Vec<bool>, Error>;
}

/// What [`Derive::internal`] may hold a key beside the flags it returns.
pub const INTERNAL_BYTES: u64 = 1;

/// No derivation: no tier 2, every key public. What the reader uses on its own, and for resource libraries.
pub struct Plain;

impl Derive for Plain {
    fn version(&self) -> u32 {
        0
    }
    fn unmark<'a>(&self, text: &'a str) -> Cow<'a, str> {
        Cow::Borrowed(text)
    }
    fn growth(&self) -> u64 {
        0
    }
    fn internal(&self, keys: &dyn KeyList) -> Result<Vec<bool>, Error> {
        filled(keys.len(), false)
    }
}

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
        let mut buf = filled(len, 0u8)?;
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

    /// [`Self::fold`]'s text appended to `out`, reserved fallibly: how an index build folds, so that one long
    /// key's folding is an error it can return, not an allocation that aborts.
    fn fold_into(&self, key: &str, out: &mut Vec<u8>) -> Result<(), Error> {
        crate::text::fold_into(key, self.case_sensitive, self.strip, out).map_err(crate::out_of_memory)
    }
}

impl KeyList for Keys {
    fn len(&self) -> usize {
        self.starts.len()
    }
    fn key(&self, i: usize) -> Result<&str, Error> {
        let (from, to) = (offset(&self.offsets, i)?, offset(&self.offsets, i + 1)?);
        let bytes = self.text.get(from..to).ok_or_else(|| malformed("key index"))?;
        std::str::from_utf8(bytes).map_err(|_| malformed("key text"))
    }
}

/// Writes the index of a file whose keys and record blocks have been read, holding at most `budget` bytes. Each
/// table is made when it is needed and let go once used, and every one is taken from a [`Ledger`] before it is
/// made, so the budget holds whatever the keys and `derive` do to them; `keys::cost_of`, checked first, only
/// refuses early what could not fit. The output is reserved whole and written in place.
pub(crate) fn build(
    keys: Keys,
    blocks: &[RecordBlock],
    rules: Rules,
    binding: Binding,
    derive: &dyn Derive,
    budget: u64,
) -> Result<Vec<u8>, Error> {
    let n = keys.starts.len();
    if keys.offsets.len() != n + 1 {
        return Err(malformed("key index"));
    }
    let cost = crate::keys::cost_of(n as u64, keys.text.len() as u64)
        .saturating_add((blocks.len() as u64).saturating_mul(crate::keys::BLOCK_COST));
    if cost > budget {
        return Err(Error::TooLarge(format!("the key index would take more than {budget} bytes")));
    }
    let total = blocks.last().map_or(0, |b| b.records_offset + b.len as u64);
    let held = [
        keys.text.capacity() as u64,
        bytes_of::<u32>(keys.offsets.capacity()),
        bytes_of::<u64>(keys.starts.capacity()),
        std::mem::size_of_val(blocks) as u64,
    ];
    let mut ledger = Ledger::new(budget, held.iter().fold(0u64, |all, &b| all.saturating_add(b)))?;
    let tier2 = tier2_order(&keys, rules, derive, &mut ledger)?;
    let folded = Folded::of(&keys, rules, &mut ledger)?;
    let order = folded.order(&mut ledger)?;
    ledger.give(folded.held());
    drop(folded);
    let ends = record_ends(&keys.starts, total, &mut ledger)?;
    let public = public_bitmap(&keys, derive, &mut ledger)?;

    let sizes = [keys.text.len(), 4 * (n + 1), 8 * n, 8 * n, 4 * n, 32 * blocks.len(), public.len(), 4 * tier2.len()];
    let whole = sizes.iter().fold(HEADER_LEN, |at, len| at.next_multiple_of(8) + len);
    ledger.take(whole as u64)?;
    let mut out: Vec<u8> = Vec::new();
    out.try_reserve_exact(whole).map_err(crate::out_of_memory)?;
    out.resize(HEADER_LEN, 0);
    let mut table = [(0u64, 0u64, 0u64); SECTIONS];
    let mut section = |out: &mut Vec<u8>, which: usize, write: &mut dyn FnMut(&mut Vec<u8>)| -> Result<(), Error> {
        out.resize(out.len().next_multiple_of(8), 0);
        let at = out.len();
        write(out);
        let bytes = out.get(at..).ok_or_else(|| malformed("index"))?;
        *table.get_mut(which).ok_or_else(|| malformed("index"))? = (at as u64, bytes.len() as u64, xxh3_64(bytes));
        Ok(())
    };
    section(&mut out, TEXT, &mut |out| out.extend_from_slice(&keys.text))?;
    section(&mut out, OFFSETS, &mut |out| keys.offsets.iter().for_each(|v| out.extend_from_slice(&v.to_le_bytes())))?;
    section(&mut out, STARTS, &mut |out| keys.starts.iter().for_each(|v| out.extend_from_slice(&v.to_le_bytes())))?;
    section(&mut out, ENDS, &mut |out| ends.iter().for_each(|v| out.extend_from_slice(&v.to_le_bytes())))?;
    section(&mut out, ORDER, &mut |out| order.iter().for_each(|v| out.extend_from_slice(&v.to_le_bytes())))?;
    section(&mut out, BLOCKS, &mut |out| {
        for b in blocks {
            for v in [b.file_offset, b.stored_len as u64, b.records_offset, b.len as u64] {
                out.extend_from_slice(&v.to_le_bytes());
            }
        }
    })?;
    section(&mut out, PUBLIC, &mut |out| out.extend_from_slice(&public))?;
    section(&mut out, TIER2, &mut |out| tier2.iter().for_each(|v| out.extend_from_slice(&v.to_le_bytes())))?;

    let head = header(rules, &binding, derive, [n as u64, blocks.len() as u64, total], &table);
    out.get_mut(..HEADER_LEN).ok_or_else(|| malformed("index"))?.copy_from_slice(&head);
    Ok(out)
}

/// What an index build holds against what it may: each table that grows with the file is taken from it before
/// it is made, and given back when it is let go. `TooLarge` when one would pass the budget.
struct Ledger {
    budget: u64,
    left: u64,
}

impl Ledger {
    /// A ledger for `budget` bytes, `held` of them already taken by what the build is given.
    fn new(budget: u64, held: u64) -> Result<Self, Error> {
        let mut ledger = Self { budget, left: budget };
        ledger.take(held)?;
        Ok(ledger)
    }

    fn take(&mut self, bytes: u64) -> Result<(), Error> {
        self.left = self.left.checked_sub(bytes).ok_or_else(|| {
            Error::TooLarge(format!("the key index would take more than {} bytes to build", self.budget))
        })?;
        Ok(())
    }

    fn give(&mut self, bytes: u64) {
        self.left = self.left.saturating_add(bytes).min(self.budget);
    }
}

/// The bytes `n` values of `T` take.
fn bytes_of<T>(n: usize) -> u64 {
    (n as u64).saturating_mul(std::mem::size_of::<T>() as u64)
}

/// Where each record ends: the next larger start, or the end of all records.
fn record_ends(starts: &[u64], total: u64, ledger: &mut Ledger) -> Result<Vec<u64>, Error> {
    ledger.take(bytes_of::<u64>(starts.len()).saturating_mul(2))?;
    let mut sorted = Vec::new();
    sorted.try_reserve_exact(starts.len()).map_err(crate::out_of_memory)?;
    sorted.extend_from_slice(starts);
    sorted.sort_unstable();
    sorted.dedup();
    let mut ends = Vec::new();
    ends.try_reserve_exact(starts.len()).map_err(crate::out_of_memory)?;
    for &start in starts {
        if start > total {
            return Err(Error::Malformed("a key points past the end of the records".into()));
        }
        let next = sorted.partition_point(|&s| s <= start);
        ends.push(sorted.get(next).copied().unwrap_or(total));
    }
    // The sorted starts are let go; the ends are the index's.
    ledger.give(bytes_of::<u64>(starts.len()));
    Ok(ends)
}

/// Every key folded once (tier 1), its text concatenated.
struct Folded {
    text: Vec<u8>,
    at: Vec<u32>,
}

impl Folded {
    /// The text is measured first, taken from the ledger and reserved once, exactly, then each key is folded
    /// straight into it: no key's folding is held as a string of its own.
    fn of(keys: &Keys, rules: Rules, ledger: &mut Ledger) -> Result<Self, Error> {
        let n = keys.starts.len();
        let mut room = 0usize;
        for i in 0..n {
            let len = crate::text::fold_len(keys.key(i)?, rules.case_sensitive, rules.strip);
            room = room.checked_add(len).ok_or_else(too_large)?;
        }
        ledger.take((room as u64).saturating_add(bytes_of::<u32>(n + 1)))?;
        let mut folded = Self { text: Vec::new(), at: Vec::new() };
        folded.text.try_reserve_exact(room).map_err(crate::out_of_memory)?;
        folded.at.try_reserve_exact(n + 1).map_err(crate::out_of_memory)?;
        folded.at.push(0);
        for i in 0..n {
            rules.fold_into(keys.key(i)?, &mut folded.text)?;
            folded.at.push(u32::try_from(folded.text.len()).map_err(|_| too_large())?);
        }
        Ok(folded)
    }

    /// What it holds, for the ledger.
    fn held(&self) -> u64 {
        (self.text.capacity() as u64).saturating_add(bytes_of::<u32>(self.at.capacity()))
    }

    /// Key `i` folded.
    fn get(&self, i: u32) -> &[u8] {
        let (from, to) = (self.at.get(i as usize).copied(), self.at.get(i as usize + 1).copied());
        from.zip(to).and_then(|(f, t)| self.text.get(f as usize..t as usize)).unwrap_or(&[])
    }

    /// The tier-1 order: sorted stably, so keys that fold together stay in file order. The sort's own scratch,
    /// which the standard library allocates and cannot be asked to do fallibly, is at most the order's size, and
    /// is taken from the ledger for as long as it sorts.
    fn order(&self, ledger: &mut Ledger) -> Result<Vec<u32>, Error> {
        let count = u32::try_from(self.at.len().saturating_sub(1)).map_err(|_| too_large())?;
        let (table, scratch) = (bytes_of::<u32>(count as usize), bytes_of::<u32>(count as usize));
        ledger.take(table.saturating_add(scratch))?;
        let mut order: Vec<u32> = Vec::new();
        order.try_reserve_exact(count as usize).map_err(crate::out_of_memory)?;
        order.extend(0..count);
        order.sort_by(|&a, &b| self.get(a).cmp(self.get(b)));
        ledger.give(scratch);
        Ok(order)
    }
}

/// The tier-2 order, over the keys tier 2 changes: few (under 2 % of the 25's, `core-api.md` §1a). Made before
/// the tier-1 folding is held, comparing with each such key's tier-1 form folded again; their tier-2 forms are
/// kept in one text, not a string each, sorted stably so ties stay in file order. The text and its entries are
/// measured in a first pass, taken from the ledger and reserved exactly, so neither grows past what is counted,
/// however long `derive` makes a key. Each key's unmarking and its two foldings are held one key at a time, in
/// buffers used again for every key: [`tier2_scratch`] of the longest key, taken first.
fn tier2_order(keys: &Keys, rules: Rules, derive: &dyn Derive, ledger: &mut Ledger) -> Result<Vec<u32>, Error> {
    let count = u32::try_from(keys.starts.len()).map_err(|_| too_large())?;
    let mut longest = 0u64;
    for i in 0..keys.starts.len() {
        longest = longest.max(keys.key(i)?.len() as u64);
    }
    let scratch_bytes = tier2_scratch(longest, derive.growth());
    ledger.take(scratch_bytes)?;
    let mut scratch = Tier2 { form: Vec::new(), tier1: Vec::new() };
    let (mut entries, mut bytes) = (0usize, 0usize);
    for i in 0..count {
        if scratch.changes(keys, rules, derive, i)? {
            entries += 1;
            bytes = bytes.checked_add(scratch.form.len()).ok_or_else(too_large)?;
        }
    }
    // The forms and their entries, the stable sort's scratch (at most the entries again), and the order.
    let held = (bytes as u64)
        .saturating_add(bytes_of::<(u32, u32, u32)>(entries).saturating_mul(2))
        .saturating_add(bytes_of::<u32>(entries));
    ledger.take(held)?;
    let mut text: Vec<u8> = Vec::new();
    let mut changed: Vec<(u32, u32, u32)> = Vec::new();
    text.try_reserve_exact(bytes).map_err(crate::out_of_memory)?;
    changed.try_reserve_exact(entries).map_err(crate::out_of_memory)?;
    for i in 0..count {
        if scratch.changes(keys, rules, derive, i)? {
            if changed.len() == entries || text.len() + scratch.form.len() > bytes {
                return Err(Error::Malformed("a key's tier-2 form changed between two readings".into()));
            }
            let from = u32::try_from(text.len()).map_err(|_| too_large())?;
            text.extend_from_slice(&scratch.form);
            changed.push((from, u32::try_from(text.len()).map_err(|_| too_large())?, i));
        }
    }
    let form = |&(from, to, _): &(u32, u32, u32)| text.get(from as usize..to as usize).unwrap_or(&[]);
    changed.sort_by(|a, b| form(a).cmp(form(b)));
    let mut order = Vec::new();
    order.try_reserve_exact(changed.len()).map_err(crate::out_of_memory)?;
    order.extend(changed.into_iter().map(|(_, _, i)| i));
    // All but the order is let go.
    ledger.give(held.saturating_sub(bytes_of::<u32>(entries)).saturating_add(scratch_bytes));
    Ok(order)
}

/// What ordering tier 2 holds for one key at a time, sized by the longest key (`longest` bytes) and how much
/// `derive` may lengthen one (`growth`, [`Derive::growth`]): what unmarking holds, the unmarked form folded (at
/// most [`crate::text::FOLD_GROWTH`] times the unmarked text, which is at most the key or `growth` times it),
/// and the key itself folded.
fn tier2_scratch(longest: u64, growth: u64) -> u64 {
    let fold = crate::text::FOLD_GROWTH;
    longest.saturating_mul(growth.saturating_add(fold.saturating_mul(growth.max(1))).saturating_add(fold))
}

/// The two foldings `tier2_order` compares for one key at a time, in buffers it uses again for every key.
struct Tier2 {
    /// The key's tier-2 form: its unmarked spelling folded.
    form: Vec<u8>,
    /// The key itself folded: its tier-1 form.
    tier1: Vec<u8>,
}

impl Tier2 {
    /// Whether tier 2 changes key `i`, its tier-2 form left in `form` when it does.
    fn changes(&mut self, keys: &Keys, rules: Rules, derive: &dyn Derive, i: u32) -> Result<bool, Error> {
        let k = keys.key(i as usize)?;
        let plain = derive.unmark(k);
        if plain.as_ref() == k {
            return Ok(false);
        }
        self.form.clear();
        rules.fold_into(&plain, &mut self.form)?;
        self.tier1.clear();
        rules.fold_into(k, &mut self.tier1)?;
        Ok(self.form != self.tier1)
    }
}

/// One bit per key, set for the keys `derive` leaves public. What `derive` holds to decide (its flags, and at
/// most [`INTERNAL_BYTES`] a key beside them) is taken from the ledger while it does.
fn public_bitmap(keys: &Keys, derive: &dyn Derive, ledger: &mut Ledger) -> Result<Vec<u8>, Error> {
    let n = keys.starts.len();
    let deciding = bytes_of::<bool>(n).saturating_add((n as u64).saturating_mul(INTERNAL_BYTES));
    ledger.take(deciding.saturating_add(n.div_ceil(8) as u64))?;
    let internal = derive.internal(keys)?;
    if internal.len() != n {
        return Err(Error::Malformed("the internal keys were not marked one per key".into()));
    }
    let mut public = filled(n.div_ceil(8), 0u8)?;
    for (i, _) in internal.iter().enumerate().filter(|(_, internal)| !**internal) {
        if let Some(byte) = public.get_mut(i / 8) {
            *byte |= 1 << (i % 8);
        }
    }
    ledger.give(deciding);
    Ok(public)
}

/// The header: what the index is of and how it was built, its counts (keys, blocks, records' total size),
/// the section table, and its own checksum.
fn header(
    rules: Rules,
    binding: &Binding,
    derive: &dyn Derive,
    [keys, blocks, total]: [u64; 3],
    table: &[(u64, u64, u64); SECTIONS],
) -> Vec<u8> {
    let mut head = Vec::with_capacity(HEADER_LEN);
    head.extend_from_slice(MAGIC);
    head.extend_from_slice(&FORMAT.to_le_bytes());
    head.extend_from_slice(&READER.to_le_bytes());
    head.extend_from_slice(&derive.version().to_le_bytes());
    head.push(u8::from(binding.kind == Kind::Mdd));
    head.push(u8::from(rules.case_sensitive) | u8::from(rules.strip) << 1);
    head.extend_from_slice(&[0, 0]);
    head.extend_from_slice(&binding.identity);
    head.extend_from_slice(&binding.header.to_le_bytes());
    head.extend_from_slice(&binding.source_len.to_le_bytes());
    head.extend_from_slice(&keys.to_le_bytes());
    head.extend_from_slice(&blocks.to_le_bytes());
    head.extend_from_slice(&total.to_le_bytes());
    debug_assert_eq!(head.len(), TABLE_AT);
    for (at, len, sum) in table {
        head.extend_from_slice(&at.to_le_bytes());
        head.extend_from_slice(&len.to_le_bytes());
        head.extend_from_slice(&sum.to_le_bytes());
    }
    head.extend_from_slice(&xxh3_64(&head).to_le_bytes());
    head
}

/// The most of a section read at once to check it: through a source, a read is an allocation of its size.
const CHECK_CHUNK: u64 = 1 << 20;

/// The least a record block takes in its file: its framing, a 4-byte type and a 4-byte checksum (the 8 bytes
/// of version 3.0's unit sizes are framing too, with more after them).
const BLOCK_FRAMING: u64 = 8;

/// The most record blocks a file the reader opens can list: a record index of [`limits::BLOCK_BYTES`] at the
/// narrowest, version 1.2's 8 bytes a block.
const MOST_BLOCKS: u64 = limits::BLOCK_BYTES / 8;

/// One 32-byte entry of the record-block table.
fn record_block(entry: &[u8; 32]) -> Option<RecordBlock> {
    let words = entry.as_chunks::<8>().0;
    let word = |i: usize| words.get(i).map(|w| u64::from_le_bytes(*w));
    Some(RecordBlock {
        file_offset: word(0)?,
        stored_len: usize::try_from(word(1)?).ok()?,
        records_offset: word(2)?,
        len: usize::try_from(word(3)?).ok()?,
    })
}

/// A section's checksum, read a piece at a time.
fn checksum(region: &dyn Region, span: Span) -> Result<u64, Error> {
    let mut hasher = Xxh3::new();
    let mut at = 0;
    while at < span.len {
        let len = usize::try_from((span.len - at).min(CHECK_CHUNK)).map_err(|_| malformed("index"))?;
        hasher.update(&region.bytes(span.at + at, len)?);
        at += len as u64;
    }
    Ok(hasher.digest())
}

fn offset(offsets: &[u32], i: usize) -> Result<usize, Error> {
    offsets.get(i).map(|&o| o as usize).ok_or_else(|| malformed("key index"))
}

fn too_large() -> Error {
    Error::TooLarge("the key index would pass 4 GiB of key text".into())
}

/// `n` copies of `value`, or an error, not an abort, when there is not the memory.
fn filled<T: Clone>(n: usize, value: T) -> Result<Vec<T>, Error> {
    let mut out = Vec::new();
    out.try_reserve_exact(n).map_err(crate::out_of_memory)?;
    out.resize(n, value);
    Ok(out)
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
    public: Span,
    tier2: Span,
    derive: Arc<dyn Derive>,
    pub(crate) blocks: Vec<RecordBlock>,
    pub(crate) total_records: u64,
    pub(crate) rules: Rules,
}

/// What an index's header says, once its checksum, its versions and the file it was built for are checked.
struct Head {
    rules: Rules,
    keys: usize,
    block_count: usize,
    total_records: u64,
    spans: [Span; SECTIONS],
    sums: [u64; SECTIONS],
}

impl Head {
    /// The header of the index in `region`, if it is an index of this format, intact, built by this reader
    /// under `derive`, for the file `binding` describes, with counts a build could have written.
    fn read(region: &dyn Region, binding: &Binding, derive: &dyn Derive) -> Result<Self, Stale> {
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
        if u32_at(12)? != READER || u32_at(16)? != derive.version() {
            return Err(Stale::Reader);
        }
        let kind = if field(20, 1)? == [1] { Kind::Mdd } else { Kind::Mdx };
        let flags = field(21, 1)?.first().copied().unwrap_or(0);
        if kind != binding.kind
            || field(24, 32)? != binding.identity
            || u64_at(56)? != binding.header
            || u64_at(64)? != binding.source_len
        {
            return Err(Stale::OtherFile);
        }
        let keys = usize::try_from(u64_at(72)?).map_err(|_| damaged("the key count"))?;
        let block_count = usize::try_from(u64_at(80)?).map_err(|_| damaged("the block count"))?;
        if keys as u64 > limits::KEYS {
            return Err(damaged("the key count"));
        }
        // A block the reader made takes at least its framing in the file, and the reader lists no more blocks
        // than a record index it accepts can hold; a count past either was never written by `build`. Checked
        // before the table is read, which through a source is an allocation of its declared size.
        if block_count as u64 > MOST_BLOCKS || (block_count as u64).saturating_mul(BLOCK_FRAMING) > binding.source_len {
            return Err(damaged("the block count"));
        }
        let mut spans = [Span { at: 0, len: 0 }; SECTIONS];
        let mut sums = [0u64; SECTIONS];
        for (i, (span, sum)) in spans.iter_mut().zip(&mut sums).enumerate() {
            let at = TABLE_AT + i * 24;
            (*span, *sum) = (Span { at: u64_at(at)?, len: u64_at(at + 8)? }, u64_at(at + 16)?);
        }
        Ok(Self {
            rules: Rules { case_sensitive: flags & 1 != 0, strip: flags & 2 != 0 },
            keys,
            block_count,
            total_records: u64_at(88)?,
            spans,
            sums,
        })
    }

    /// Every section within the index (`len` bytes) and of the size its counts make it, before any is read.
    fn check_sections(&self, len: u64) -> Result<(), Stale> {
        let damaged = |what: &str| Stale::Damaged(what.to_owned());
        for span in &self.spans {
            let end = span.at.checked_add(span.len).ok_or_else(|| damaged("a section's bounds"))?;
            if span.at < HEADER_LEN as u64 || end > len {
                return Err(damaged("a section's bounds"));
            }
        }
        let [text, offsets, starts, ends, order, blocks, public, tier2] = self.spans;
        let keys = self.keys;
        let sized = |span: Span, width: u64, count: usize| (count as u64).checked_mul(width) == Some(span.len);
        if !sized(offsets, 4, keys + 1)
            || !sized(starts, 8, keys)
            || !sized(ends, 8, keys)
            || !sized(order, 4, keys)
            || !sized(blocks, 32, self.block_count)
            || text.len > u64::from(u32::MAX)
            || crate::keys::cost_of(keys as u64, text.len) > limits::INDEX_BYTES
            || public.len != keys.div_ceil(8) as u64
            || !tier2.len.is_multiple_of(4)
            || tier2.len > 4 * keys as u64
        {
            return Err(damaged("a section's size"));
        }
        Ok(())
    }
}

impl Index {
    /// Loads and checks an index for the file `binding` describes, built under `derive`: its header, every
    /// section's bounds, size and checksum, then its tables' structure and its record blocks.
    pub(crate) fn load(region: Box<dyn Region>, binding: &Binding, derive: Arc<dyn Derive>) -> Result<Self, Stale> {
        let head = Head::read(&*region, binding, &*derive)?;
        head.check_sections(region.len())?;
        for (i, (span, sum)) in head.spans.iter().zip(head.sums).enumerate() {
            if checksum(&*region, *span).map_err(|_| Stale::Damaged("a section".into()))? != sum {
                return Err(Stale::Damaged(format!("section {i}'s checksum")));
            }
        }
        let [text, offsets, starts, ends, order, blocks, public, tier2] = head.spans;
        let index = Self {
            region,
            keys: head.keys,
            text,
            offsets,
            starts,
            ends,
            order,
            public,
            tier2,
            derive,
            blocks: Vec::new(),
            total_records: head.total_records,
            rules: head.rules,
        };
        index.check_structure()?;
        let blocks = index.read_blocks(blocks)?;
        Ok(Self { blocks, ..index })
    }

    /// One pass over each table, no folding: text offsets rise within the text, no key longer than a block
    /// (where every key was read from), records lie within the records, the order names every key once, and
    /// the tier-2 order names keys, none twice.
    fn check_structure(&self) -> Result<(), Stale> {
        let damaged = |what: &str| Stale::Damaged(what.to_owned());
        let mut previous = 0u32;
        let mut first = true;
        let offsets_rise = self.each_word::<4>(self.offsets, |word| {
            let value = u32::from_le_bytes(word);
            let ok = (!first || value == 0)
                && value >= previous
                && u64::from(value) <= self.text.len
                && u64::from(value - previous) <= limits::BLOCK_BYTES;
            (first, previous) = (false, value);
            ok
        })?;
        if !offsets_rise || u64::from(previous) != self.text.len {
            return Err(damaged("the text offsets"));
        }
        // Each start against its end, a piece of each table at a time: the two tables have a word per key.
        let mut at = 0u64;
        while at < self.starts.len {
            let len = (self.starts.len - at).min(CHECK_CHUNK);
            let (starts, ends) = (self.piece(self.starts, at, len)?, self.piece(self.ends, at, len)?);
            for (s, e) in starts.as_chunks::<8>().0.iter().zip(ends.as_chunks::<8>().0) {
                let (s, e) = (u64::from_le_bytes(*s), u64::from_le_bytes(*e));
                if s > e || e > self.total_records {
                    return Err(damaged("a record's bounds"));
                }
            }
            at += len;
        }
        // The order has a word per key (its size is checked), so naming each key once makes it a permutation.
        if !self.names_keys_once(self.order)? {
            return Err(damaged("the order is not a permutation"));
        }
        if !self.names_keys_once(self.tier2)? {
            return Err(damaged("the tier-2 order names a key twice, or none"));
        }
        Ok(())
    }

    /// `len` bytes of `span` from `at` within it.
    fn piece(&self, span: Span, at: u64, len: u64) -> Result<Cow<'_, [u8]>, Stale> {
        let len = usize::try_from(len).map_err(|_| Stale::Damaged("a section".into()))?;
        self.region.bytes(span.at + at, len).map_err(|_| Stale::Damaged("a section".into()))
    }

    /// Every `N`-byte word of `span`, read [`CHECK_CHUNK`] bytes at a time (a multiple of `N`), until `each`
    /// returns `false`: whether it never did.
    fn each_word<const N: usize>(&self, span: Span, mut each: impl FnMut([u8; N]) -> bool) -> Result<bool, Stale> {
        let mut at = 0u64;
        while at < span.len {
            let len = (span.len - at).min(CHECK_CHUNK);
            if !self.piece(span, at, len)?.as_chunks::<N>().0.iter().all(|w| each(*w)) {
                return Ok(false);
            }
            at += len;
        }
        Ok(true)
    }

    /// Whether a table of little-endian `u32` key numbers names only keys, none twice.
    fn names_keys_once(&self, table: Span) -> Result<bool, Stale> {
        let mut seen = filled(self.keys, false).map_err(|_| Stale::Damaged("the key count".into()))?;
        self.each_word::<4>(table, |word| match seen.get_mut(u32::from_le_bytes(word) as usize) {
            Some(slot @ false) => {
                *slot = true;
                true
            }
            _ => false,
        })
    }

    /// The record-block table, read a piece at a time like a checksum, so no read is larger than
    /// [`CHECK_CHUNK`] whatever the table's size.
    fn read_blocks(&self, span: Span) -> Result<Vec<RecordBlock>, Stale> {
        let damaged = |what: &str| Stale::Damaged(what.to_owned());
        let mut blocks = Vec::new();
        let mut expected = 0u64;
        let mut at = 0u64;
        while at < span.len {
            let len = usize::try_from((span.len - at).min(CHECK_CHUNK)).map_err(|_| damaged("the record blocks"))?;
            let bytes = self.region.bytes(span.at + at, len).map_err(|_| damaged("the record blocks"))?;
            at += len as u64;
            for b in bytes.as_chunks::<32>().0 {
                let block = record_block(b).ok_or_else(|| damaged("a record block"))?;
                if block.records_offset != expected
                    || block.len as u64 > limits::BLOCK_BYTES
                    || (block.stored_len as u64) < BLOCK_FRAMING
                    || block.stored_len as u64 > limits::BLOCK_BYTES
                {
                    return Err(damaged("the record blocks"));
                }
                expected = expected.checked_add(block.len as u64).ok_or_else(|| damaged("the record blocks"))?;
                blocks.try_reserve(1).map_err(|_| damaged("the record blocks"))?;
                blocks.push(block);
            }
        }
        if expected != self.total_records {
            return Err(damaged("the record blocks"));
        }
        Ok(blocks)
    }

    pub(crate) fn len(&self) -> usize {
        self.keys
    }

    /// Entry `i` of a table of `width`-byte words; an error past its end, however large `i` is.
    fn word(&self, span: Span, width: usize, i: usize) -> Result<u64, Error> {
        let from = i.checked_mul(width).ok_or_else(|| malformed("index"))?;
        let to = from.checked_add(width).ok_or_else(|| malformed("index"))?;
        if to as u64 > span.len {
            return Err(malformed("index"));
        }
        let at = span.at.checked_add(from as u64).ok_or_else(|| malformed("index"))?;
        let bytes = self.region.bytes(at, width)?;
        let mut value = [0u8; 8];
        value.get_mut(..width).ok_or_else(|| malformed("index"))?.copy_from_slice(&bytes);
        Ok(u64::from_le_bytes(value))
    }

    /// Key `i`, as the file spells it.
    pub(crate) fn key(&self, i: usize) -> Result<Cow<'_, str>, Error> {
        let next = i.checked_add(1).ok_or_else(|| malformed("key number"))?;
        let (from, to) = (self.word(self.offsets, 4, i)?, self.word(self.offsets, 4, next)?);
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

    /// Whether key `i` is offered to a reader: not one its [`Derive`] marked internal.
    pub(crate) fn is_public(&self, i: usize) -> Result<bool, Error> {
        if i >= self.keys {
            return Err(malformed("key number"));
        }
        let byte = self.region.bytes(self.public.at + (i / 8) as u64, 1)?;
        Ok(byte.first().is_some_and(|b| b & (1 << (i % 8)) != 0))
    }

    /// The first of `count` positions for which `less(j)` is false; `less` must be true and then false.
    fn lower_bound(count: usize, less: impl Fn(usize) -> Result<bool, Error>) -> Result<usize, Error> {
        let (mut low, mut high) = (0usize, count);
        while low < high {
            let mid = low + (high - low) / 2;
            if less(mid)? {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        Ok(low)
    }

    /// The key number at position `j` of the tier-1 order, and `f` of its folded key: borrowed, not copied.
    fn tier1<T>(&self, j: usize, f: impl FnOnce(&str) -> T) -> Result<(usize, T), Error> {
        let i = self.word(self.order, 4, j)? as usize;
        let key = self.key(i)?;
        Ok((i, f(&self.rules.fold(&key))))
    }

    /// The key number at position `j` of the tier-2 order, and `f` of its tier-2 form.
    fn tier2<T>(&self, j: usize, f: impl FnOnce(&str) -> T) -> Result<(usize, T), Error> {
        let i = self.word(self.tier2, 4, j)? as usize;
        let key = self.key(i)?;
        Ok((i, f(&self.rules.fold(&self.derive.unmark(&key)))))
    }

    /// Every key equal to `query` under the file's rules: those spelt exactly as asked first, then the rest,
    /// each in file order. Every candidate is compared with the query, whatever the order says.
    pub(crate) fn find(&self, query: &str) -> Result<Vec<usize>, Error> {
        let wanted = self.rules.fold(query);
        let run = self.equal_run(self.keys, |j| self.tier1(j, |f| f.cmp(wanted.as_ref())))?;
        let (mut exact, mut rest) = (Vec::new(), Vec::new());
        for i in run {
            if self.key(i)? == query { exact.push(i) } else { rest.push(i) }
        }
        exact.sort_unstable();
        rest.sort_unstable();
        exact.extend(rest);
        Ok(exact)
    }

    /// The keys whose tier-2 form differs from their tier-1 one and equals `query`'s, in file order. With
    /// [`Self::find`] of the unmarked query, every key equal to it at tier 2. Compared like [`Self::find`].
    pub(crate) fn find_unmarked(&self, query: &str) -> Result<Vec<usize>, Error> {
        let wanted = self.rules.fold(&self.derive.unmark(query)).into_owned();
        let count = (self.tier2.len / 4) as usize;
        let mut found = self.equal_run(count, |j| self.tier2(j, |f| f.cmp(wanted.as_str())))?;
        found.sort_unstable();
        Ok(found)
    }

    /// The key numbers of the run of positions, in a sorted table of `count`, whose form compares equal:
    /// `at(j)` gives position `j`'s key and how its form compares with the one wanted. The run is found by a
    /// binary search and checked position by position, so a wrong order loses keys but never adds one.
    fn equal_run(
        &self,
        count: usize,
        at: impl Fn(usize) -> Result<(usize, std::cmp::Ordering), Error>,
    ) -> Result<Vec<usize>, Error> {
        let low = Self::lower_bound(count, |j| Ok(at(j)?.1.is_lt()))?;
        let mut run = Vec::new();
        for j in low..count {
            let (i, ordering) = at(j)?;
            if ordering.is_ne() {
                break;
            }
            run.push(i);
        }
        Ok(run)
    }

    /// The keys whose folded form begins with `prefix`'s, in the tier-1 order, until `each` says stop.
    /// Every candidate is compared with the prefix.
    pub(crate) fn prefixed(
        &self,
        prefix: &str,
        mut each: impl FnMut(usize) -> Result<bool, Error>,
    ) -> Result<(), Error> {
        let wanted = self.rules.fold(prefix);
        let low = Self::lower_bound(self.keys, |j| Ok(self.tier1(j, |f| f < wanted.as_ref())?.1))?;
        for j in low..self.keys {
            let (i, starts) = self.tier1(j, |f| f.starts_with(wanted.as_ref()))?;
            if !starts || !each(i)? {
                break;
            }
        }
        Ok(())
    }

    /// The derivation the index was built under.
    pub(crate) fn derive(&self) -> &dyn Derive {
        &*self.derive
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;

    /// A derivation that makes every key a hundred times longer, and says so.
    struct Long;

    impl Derive for Long {
        fn version(&self) -> u32 {
            1
        }
        fn unmark<'a>(&self, text: &'a str) -> Cow<'a, str> {
            Cow::Owned(text.repeat(100))
        }
        fn growth(&self) -> u64 {
            100
        }
        fn internal(&self, keys: &dyn KeyList) -> Result<Vec<bool>, Error> {
            Ok(vec![false; keys.len()])
        }
    }

    fn keys(n: usize) -> Keys {
        let mut keys = Keys::default();
        keys.offsets.push(0);
        for i in 0..n {
            keys.text.extend_from_slice(format!("key{i}").as_bytes());
            keys.offsets.push(keys.text.len() as u32);
            keys.starts.push(i as u64);
        }
        keys
    }

    const BINDING: Binding = Binding { identity: [0; 32], header: 0, source_len: 0, kind: Kind::Mdx };
    const RULES: Rules = Rules { case_sensitive: false, strip: true };

    /// What tier 2 holds is counted as it is made, whatever the derivation does to a key: the estimate made
    /// while reading assumes what folding does, and a derivation may do more. One that lengthens every key a
    /// hundred times is refused within the estimate's budget, and built given room for its forms.
    #[test]
    fn a_build_counts_what_tier_two_holds() {
        let n = 1000;
        let blocks = [RecordBlock { file_offset: 0, stored_len: n, records_offset: 0, len: n }];
        let estimate = crate::keys::cost_of(n as u64, keys(n).text.len() as u64) + crate::keys::BLOCK_COST;
        build(keys(n), &blocks, RULES, BINDING, &Plain, estimate).unwrap();
        let refused = build(keys(n), &blocks, RULES, BINDING, &Long, estimate);
        assert!(matches!(refused, Err(Error::TooLarge(_))), "{:?}", refused.map(|i| i.len()));
        build(keys(n), &blocks, RULES, BINDING, &Long, 1000 * estimate).unwrap();
    }
}
