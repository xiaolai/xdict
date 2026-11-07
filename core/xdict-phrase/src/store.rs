//! **The per-edition inventory** (plan WI-4): the multi-word keys one edition carries, as templates, with the slot
//! vocabulary they were read under, and the versions that make the store disposable.
//!
//! Derived, disposable, never synced (ADR-0031 d.3's rule applied to phrases). The header carries the format, the
//! extractor and the two inputs that change the contents — the public-key predicate's version and the folding's — so
//! a store written under another build is refused and rebuilt, never read.

use crate::template::Template;

use crate::{Matcher, Slots};

/// The store's format, its extractor, and any change to either rebuilds every store.
pub const FORMAT: u32 = 1;
pub const EXTRACTOR: u32 = 1;

const MAGIC: &[u8; 4] = b"XDPH";

/// What the caller's build depended on, beyond this crate's own versions: the public-key predicate and the folding.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Versions {
    pub policy: u32,
    pub folding: u32,
}

/// One edition's phrases and the slot vocabulary they were read with.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Inventory {
    phrases: Vec<String>,
    slots: Slots,
}

impl Inventory {
    /// Every multi-word key that is a template: at least two words, at least two literal words. Duplicate spellings
    /// are one phrase — the occurrence identity is the lookup's business, not the matcher's.
    pub fn from_keys<I: IntoIterator<Item = String>>(keys: I, slots: Slots) -> Self {
        let mut phrases: Vec<String> = Vec::new();
        let mut seen = std::collections::HashSet::new();
        for key in keys {
            // **`Template::new` is the one filter**: it refuses a key with fewer than two literal words, which
            // includes every single word, so a token count here would only tokenize twice.
            if Template::new(&key, &slots).is_none() {
                continue;
            }
            if seen.insert(key.clone()) {
                phrases.push(key);
            }
        }
        phrases.sort();
        Self { phrases, slots }
    }

    pub fn phrases(&self) -> &[String] {
        &self.phrases
    }

    pub fn slots(&self) -> &Slots {
        &self.slots
    }

    /// The matcher over this inventory. Built once per open edition and retained, not decoded per call.
    pub fn matcher(&self) -> Matcher {
        Matcher::new(self.phrases.iter().cloned(), self.slots.clone())
    }

    /// The store's bytes: header, slots, phrases, and one checksum over everything before it. `Err` when the store is
    /// larger than its 32-bit offsets can name — an edition that big cannot be expressed, and wrong boundaries must
    /// never be written instead.
    pub fn encode(&self, edition: &str, versions: Versions) -> Result<Vec<u8>, TooLarge> {
        let mut out = Vec::with_capacity(256 + self.phrases.iter().map(String::len).sum::<usize>());
        out.extend_from_slice(MAGIC);
        out.extend_from_slice(&FORMAT.to_le_bytes());
        out.extend_from_slice(&EXTRACTOR.to_le_bytes());
        out.extend_from_slice(&versions.policy.to_le_bytes());
        out.extend_from_slice(&versions.folding.to_le_bytes());
        push_str(&mut out, edition)?;

        let slots = self.slots.words();
        out.extend_from_slice(&u32::try_from(slots.len()).map_err(|_| TooLarge)?.to_le_bytes());
        for slot in slots {
            push_str(&mut out, slot)?;
        }

        out.extend_from_slice(&u64::try_from(self.phrases.len()).map_err(|_| TooLarge)?.to_le_bytes());
        let mut arena: Vec<u8> = Vec::new();
        let mut offsets: Vec<u32> = Vec::with_capacity(self.phrases.len() + 1);
        for phrase in &self.phrases {
            offsets.push(u32::try_from(arena.len()).map_err(|_| TooLarge)?);
            arena.extend_from_slice(phrase.as_bytes());
        }
        offsets.push(u32::try_from(arena.len()).map_err(|_| TooLarge)?);
        for offset in offsets {
            out.extend_from_slice(&offset.to_le_bytes());
        }
        out.extend_from_slice(&u64::try_from(arena.len()).unwrap_or(u64::MAX).to_le_bytes());
        out.extend_from_slice(&arena);

        let checksum = xxhash_rust::xxh3::xxh3_64(&out);
        out.extend_from_slice(&checksum.to_le_bytes());
        Ok(out)
    }

    /// The store, or why it is not one to read: another format, extractor, versions, edition or slot vocabulary than
    /// this build's, or bytes that are truncated or checksum-broken. A refused store is one to build again.
    pub fn decode(bytes: &[u8], edition: &str, versions: Versions, slots: &Slots) -> Result<Self, Refused> {
        let checksum_at = bytes.len().checked_sub(8).ok_or(Refused::Damaged)?;
        let (body, checksum) = (bytes.get(..checksum_at).ok_or(Refused::Damaged)?, bytes.get(checksum_at..));
        if Some(xxhash_rust::xxh3::xxh3_64(body).to_le_bytes().as_slice()) != checksum {
            return Err(Refused::Damaged);
        }
        let mut read = Reader { bytes: body, at: 0 };
        if read.take(4).ok_or(Refused::Damaged)? != MAGIC {
            return Err(Refused::NotAStore);
        }
        let format = read.u32().ok_or(Refused::Damaged)?;
        if format != FORMAT {
            return Err(Refused::Format(format));
        }
        let extractor = read.u32().ok_or(Refused::Damaged)?;
        if extractor != EXTRACTOR {
            return Err(Refused::Extractor(extractor));
        }
        let policy = read.u32().ok_or(Refused::Damaged)?;
        let stored = Versions { policy, folding: read.u32().ok_or(Refused::Damaged)? };
        if stored != versions {
            return Err(Refused::Versions(stored));
        }
        if read.str().ok_or(Refused::Damaged)? != edition {
            return Err(Refused::Edition);
        }
        let inventory = Self::rest(read, body.len()).ok_or(Refused::Damaged)?;
        // **The slot list is the store's layout of meaning** (audit 2026-11-05, G9): it decided which keys became
        // templates, so a store written under another list is not this build's, however well it reads.
        if &inventory.slots != slots {
            return Err(Refused::Slots);
        }
        Ok(inventory)
    }

    /// The slots and phrases after the header; `None` when they do not read whole.
    fn rest(mut read: Reader<'_>, end: usize) -> Option<Self> {
        let slot_count = read.u32()? as usize;
        let mut slots = Slots::default();
        for _ in 0..slot_count {
            slots = slots.with([read.str()?]);
        }

        let count = usize::try_from(read.u64()?).ok()?;
        // **The count is bounded by the bytes that are left before anything is reserved**: a checksum-valid header
        // could otherwise name `usize::MAX` phrases and make the decoder allocate (or overflow) before it reads one.
        let offsets_needed = count.checked_add(1)?;
        let remaining = end.checked_sub(read.at)?;
        if offsets_needed > remaining / 4 {
            return None;
        }
        let mut offsets: Vec<u32> = Vec::with_capacity(offsets_needed);
        for _ in 0..=count {
            offsets.push(read.u32()?);
        }
        let arena_len = usize::try_from(read.u64()?).ok()?;
        let arena = read.take(arena_len)?;
        if read.at != end {
            return None;
        }
        // **The offsets must cover the arena exactly and name nonempty phrases** (audit round 2): `[0, 0]` over a
        // nonempty arena is a checksum away from being valid, and would silently discard it.
        if offsets.first().copied()? != 0 || offsets.last().copied()? as usize != arena.len() {
            return None;
        }
        let mut phrases: Vec<String> = Vec::with_capacity(count);
        for pair in offsets.windows(2) {
            let (start, end) = (*pair.first()? as usize, *pair.get(1)? as usize);
            if start >= end || end > arena.len() {
                return None;
            }
            phrases.push(std::str::from_utf8(arena.get(start..end)?).ok()?.to_string());
        }
        Some(Self { phrases, slots })
    }
}

/// Why a store was not read: each a reason to build it again, said in a sentence.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Refused {
    /// Truncated, checksum-broken, or inconsistent inside.
    Damaged,
    /// Not a phrase store at all.
    NotAStore,
    /// Written in another format of the store, which this build does not read.
    Format(u32),
    /// Written by another extractor.
    Extractor(u32),
    /// Written under another public-key predicate or folding.
    Versions(Versions),
    /// Another edition's.
    Edition,
    /// Written under another slot vocabulary, so its templates are not the ones this build would make.
    Slots,
}

impl std::fmt::Display for Refused {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Damaged => f.write_str("the phrase store is damaged"),
            Self::NotAStore => f.write_str("the file is not a phrase store"),
            Self::Format(found) => write!(f, "the phrase store is format {found}; this build reads format {FORMAT}"),
            Self::Extractor(found) => {
                write!(f, "the phrase store was made by extractor {found}; this build's is {EXTRACTOR}")
            }
            Self::Versions(found) => write!(
                f,
                "the phrase store was made under policy {} and folding {}, not this build's",
                found.policy, found.folding
            ),
            Self::Edition => f.write_str("the phrase store is another edition's"),
            Self::Slots => f.write_str("the phrase store was made under another slot vocabulary"),
        }
    }
}

impl std::error::Error for Refused {}

/// A store larger than its format holds: a phrase or the arena over 4 GiB.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TooLarge;

impl std::fmt::Display for TooLarge {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("a phrase store larger than its 32-bit offsets can name")
    }
}

impl std::error::Error for TooLarge {}

fn push_str(out: &mut Vec<u8>, text: &str) -> Result<(), TooLarge> {
    let len = u32::try_from(text.len()).map_err(|_| TooLarge)?;
    out.extend_from_slice(&len.to_le_bytes());
    out.extend_from_slice(text.as_bytes());
    Ok(())
}

struct Reader<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl<'a> Reader<'a> {
    fn take(&mut self, count: usize) -> Option<&'a [u8]> {
        let end = self.at.checked_add(count)?;
        let slice = self.bytes.get(self.at..end)?;
        self.at = end;
        Some(slice)
    }

    fn u32(&mut self) -> Option<u32> {
        let bytes = self.take(4)?;
        Some(u32::from_le_bytes([*bytes.first()?, *bytes.get(1)?, *bytes.get(2)?, *bytes.get(3)?]))
    }

    fn u64(&mut self) -> Option<u64> {
        let bytes = self.take(8)?;
        let mut array = [0u8; 8];
        for (slot, byte) in array.iter_mut().zip(bytes.iter()) {
            *slot = *byte;
        }
        Some(u64::from_le_bytes(array))
    }

    fn str(&mut self) -> Option<&'a str> {
        let len = self.u32()? as usize;
        let bytes = self.take(len)?;
        std::str::from_utf8(bytes).ok()
    }
}
