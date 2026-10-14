//! The per-edition index: built, kept, read back, and never trusted (ADR-0007 decision 17). Whatever is
//! wrong with an index must make it `Stale` (build it again) or, at worst, make a key unreachable; it must
//! never give a key another key's record.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use std::borrow::Cow;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use xdict_mdx::index::{Derive, KeyList, Region, Stale};
use xdict_mdx::{Error, File, Kind};
use xdict_mdx_writer::{self as writer, Entry, Spec, Version};
use xxhash_rust::xxh3::xxh3_64;

const EDITION: [u8; 32] = [7; 32];
const HEADER_LEN: usize = 96 + 8 * 24 + 8;

fn entries() -> Vec<Entry> {
    let mut entries: Vec<Entry> =
        (0..200).map(|i| Entry::text(&format!("word{i:03}"), &format!("meaning {i}"))).collect();
    entries.extend([Entry::text("Run", "a name"), Entry::text("run", "to move"), Entry::text("run", "a score")]);
    entries.extend([
        Entry::text("café", "a place"),
        Entry::text("a--b--c", "composite"),
        Entry::text("@x", "internal"),
    ]);
    entries
}

/// A test policy: `é` is unmarked to `e`, and keys beginning with `@` are internal.
struct Marks(u32);

impl Derive for Marks {
    fn version(&self) -> u32 {
        self.0
    }
    fn unmark<'a>(&self, text: &'a str) -> Cow<'a, str> {
        if text.contains('é') { Cow::Owned(text.replace('é', "e")) } else { Cow::Borrowed(text) }
    }
    fn growth(&self) -> u64 {
        1
    }
    fn internal(&self, keys: &dyn KeyList) -> Result<Vec<bool>, Error> {
        (0..keys.len()).map(|i| Ok(keys.key(i)?.starts_with('@'))).collect()
    }
}

const MARKS: Marks = Marks(9);

fn build(file: &[u8]) -> Vec<u8> {
    File::build_index(&file.to_vec(), Some(Kind::Mdx), EDITION, &MARKS).unwrap()
}

fn mdx() -> Vec<u8> {
    writer::write(&Spec { block_size: 256, ..Spec::mdx() }, &entries()).unwrap()
}

fn open_with(file: &[u8], index: Vec<u8>) -> Result<File, Stale> {
    File::with_index(Box::new(file.to_vec()), Some(Kind::Mdx), Box::new(index), EDITION, Arc::new(Marks(9))).unwrap()
}

/// Every key's answer, as text: what a correct reader returns.
fn answers(file: &File) -> Vec<(String, Vec<String>)> {
    let mut keys: Vec<String> = file.keys().map(|k| k.unwrap().into_owned()).collect();
    keys.dedup();
    keys.into_iter()
        .map(|k| {
            let records = file.lookup(&k).unwrap();
            (k, records.iter().map(|r| format!("{}={}", r.key, String::from_utf8_lossy(&r.data))).collect())
        })
        .collect()
}

/// Rewrites a section's checksum and the header's, as a careful corrupter (or a bug) would.
fn reseal(index: &mut [u8], section: usize) {
    let at = 96 + section * 24;
    let start = u64::from_le_bytes(index[at..at + 8].try_into().unwrap()) as usize;
    let len = u64::from_le_bytes(index[at + 8..at + 16].try_into().unwrap()) as usize;
    let sum = xxh3_64(&index[start..start + len]);
    index[at + 16..at + 24].copy_from_slice(&sum.to_le_bytes());
    let head = xxh3_64(&index[..HEADER_LEN - 8]);
    index[HEADER_LEN - 8..HEADER_LEN].copy_from_slice(&head.to_le_bytes());
}

fn section(index: &[u8], which: usize) -> (usize, usize) {
    let at = 96 + which * 24;
    let start = u64::from_le_bytes(index[at..at + 8].try_into().unwrap()) as usize;
    let len = u64::from_le_bytes(index[at + 8..at + 16].try_into().unwrap()) as usize;
    (start, len)
}

#[test]
fn a_kept_index_answers_as_the_file_does() {
    let file = mdx();
    let index = build(&file);
    let kept = open_with(&file, index).unwrap();
    let fresh = File::from_source(Box::new(file), Some(Kind::Mdx)).unwrap();
    assert_eq!(answers(&kept), answers(&fresh));
    assert_eq!(kept.lookup("RUN").unwrap().len(), 3, "folding works through a kept index");
}

/// Versions 1.2, 2.0 and 3.0 and both compressions and encodings index alike.
#[test]
fn every_layout_indexes() {
    for version in [Version::V1_2, Version::V2_0, Version::V3_0] {
        for compression in [writer::Compression::Zlib, writer::Compression::None, writer::Compression::Lzo] {
            if version == Version::V3_0 && compression == writer::Compression::Lzo {
                continue;
            }
            let spec = Spec { version, compression, block_size: 256, ..Spec::mdx() };
            let file = writer::write(&spec, &entries()).unwrap();
            let index = build(&file);
            let kept = open_with(&file, index).unwrap();
            assert_eq!(kept.lookup("word123").unwrap()[0].data, b"meaning 123", "{version:?} {compression:?}");
        }
    }
}

/// A flipped byte anywhere is noticed: every byte of the header, and bytes through every section.
#[test]
fn a_flipped_byte_makes_the_index_stale() {
    let file = mdx();
    let index = build(&file);
    let mut positions: Vec<usize> = (0..HEADER_LEN).collect();
    positions.extend((HEADER_LEN..index.len()).step_by(7));
    for at in positions {
        let mut damaged = index.clone();
        damaged[at] ^= 0x40;
        // Padding between sections is covered by no checksum; changing it changes nothing.
        let padding = (0..8).all(|s| {
            let (start, len) = section(&index, s);
            !(start..start + len).contains(&at)
        }) && at >= HEADER_LEN;
        match open_with(&file, damaged) {
            Err(_) => {}
            Ok(read) if padding => assert_eq!(answers(&read), answers(&open_with(&file, index.clone()).unwrap())),
            Ok(_) => panic!("a flipped byte at {at} went unnoticed"),
        }
    }
}

#[test]
fn a_short_index_is_stale() {
    let file = mdx();
    let index = build(&file);
    for len in [0, 8, HEADER_LEN - 1, HEADER_LEN, index.len() / 2, index.len() - 1] {
        assert!(open_with(&file, index[..len].to_vec()).is_err(), "an index cut to {len} bytes loaded");
    }
}

#[test]
fn another_version_is_stale() {
    let file = mdx();
    let index = build(&file);
    let mut format = index.clone();
    format[8] ^= 1;
    assert_eq!(open_with(&file, format).err(), Some(Stale::Format));
    let mut reader = index.clone();
    reader[12] ^= 1;
    reseal(&mut reader, 0);
    assert_eq!(open_with(&file, reader).err(), Some(Stale::Reader));
}

/// An index built under another derivation (another tier-2 algorithm or internal-key rule) is not used.
#[test]
fn another_derivation_is_stale() {
    let file = mdx();
    let index = build(&file);
    let other =
        File::with_index(Box::new(file.clone()), Some(Kind::Mdx), Box::new(index), EDITION, Arc::new(Marks(10)));
    assert_eq!(other.unwrap().err(), Some(Stale::Reader));
}

/// The two sections a policy fills: the tier-2 order, searched with the query unmarked the same way, and the
/// public-key bitmap.
#[test]
fn the_index_keeps_tier_2_and_the_public_keys() {
    let file = mdx();
    let read = open_with(&file, build(&file)).unwrap();
    let key = |i: usize| read.key(i).unwrap().into_owned();
    assert!(read.find("cafe").unwrap().is_empty(), "tier 1 keeps the accent");
    assert_eq!(read.find_unmarked("cafe").unwrap().iter().map(|&i| key(i)).collect::<Vec<_>>(), ["café"]);
    assert_eq!(read.find_unmarked("Cafe").unwrap().iter().map(|&i| key(i)).collect::<Vec<_>>(), ["café"]);
    assert!(read.find_unmarked("run").unwrap().is_empty(), "only keys tier 2 changes are in its order");
    let internal: Vec<String> = (0..read.len()).filter(|&i| !read.is_public(i).unwrap()).map(key).collect();
    assert_eq!(internal, ["@x"]);
    let mut prefixed = Vec::new();
    read.prefixed("RU", |i| {
        prefixed.push(key(i));
        Ok(true)
    })
    .unwrap();
    assert_eq!(prefixed, ["Run", "run", "run"], "folded order, ties in file order");
}

/// A tier-2 order that names a key twice is caught; one resealed into the wrong order can hide a key from tier
/// 2 but never return another.
#[test]
fn a_wrong_tier_2_order_never_answers_wrongly() {
    let entries: Vec<Entry> = ["é1", "é2", "é3", "plain"].iter().map(|k| Entry::text(k, k)).collect();
    let file = writer::write(&Spec::mdx(), &entries).unwrap();
    let index = build(&file);
    let (tier2, len) = section(&index, 7);
    assert_eq!(len, 12, "three keys are changed by tier 2");
    let mut repeated = index.clone();
    let first = repeated[tier2..tier2 + 4].to_vec();
    repeated[tier2 + 4..tier2 + 8].copy_from_slice(&first);
    reseal(&mut repeated, 7);
    assert!(matches!(open_with(&file, repeated).err(), Some(Stale::Damaged(_))));
    let mut swapped = index.clone();
    let (a, b) = (swapped[tier2..tier2 + 4].to_vec(), swapped[tier2 + 8..tier2 + 12].to_vec());
    swapped[tier2..tier2 + 4].copy_from_slice(&b);
    swapped[tier2 + 8..tier2 + 12].copy_from_slice(&a);
    reseal(&mut swapped, 7);
    let read = open_with(&file, swapped).unwrap();
    for query in ["e1", "e2", "e3"] {
        for i in read.find_unmarked(query).unwrap() {
            assert_eq!(read.key(i).unwrap().replace('é', "e"), query);
        }
    }
}

#[test]
fn an_index_of_another_file_is_stale() {
    let file = mdx();
    let index = build(&file);
    let other =
        File::with_index(Box::new(file.clone()), Some(Kind::Mdx), Box::new(index.clone()), [8; 32], Arc::new(Marks(9)))
            .unwrap();
    assert_eq!(other.err(), Some(Stale::OtherFile));
    let changed = writer::write(&Spec { block_size: 256, ..Spec::mdx() }, &entries()[1..]).unwrap();
    let wrong =
        File::with_index(Box::new(changed), Some(Kind::Mdx), Box::new(index), EDITION, Arc::new(Marks(9))).unwrap();
    assert_eq!(wrong.err(), Some(Stale::OtherFile));
}

/// Codex objection 25: an index whose checksums are right and whose structure is not. A repeated key number
/// is caught; a reordered order, which is still a permutation, can hide keys but never answer wrongly.
#[test]
fn a_consistent_but_wrong_order_never_answers_wrongly() {
    let file = mdx();
    let index = build(&file);
    let truth = answers(&open_with(&file, index.clone()).unwrap());
    let (order, len) = section(&index, 4);

    let mut repeated = index.clone();
    let first = repeated[order..order + 4].to_vec();
    repeated[order + 4..order + 8].copy_from_slice(&first);
    reseal(&mut repeated, 4);
    assert!(matches!(open_with(&file, repeated).err(), Some(Stale::Damaged(_))));

    for (a, b) in [(0, len / 4 - 1), (3, 150), (10, 11), (100, 7)] {
        let mut swapped = index.clone();
        let (pa, pb) = (order + a * 4, order + b * 4);
        let (va, vb) = (swapped[pa..pa + 4].to_vec(), swapped[pb..pb + 4].to_vec());
        swapped[pa..pa + 4].copy_from_slice(&vb);
        swapped[pb..pb + 4].copy_from_slice(&va);
        reseal(&mut swapped, 4);
        let read = open_with(&file, swapped).unwrap();
        for (key, expected) in &truth {
            let got: Vec<String> = read
                .lookup(key)
                .unwrap()
                .iter()
                .map(|r| format!("{}={}", r.key, String::from_utf8_lossy(&r.data)))
                .collect();
            assert!(got.iter().all(|g| expected.contains(g)), "{key:?}: {got:?} is not within {expected:?}");
        }
    }

    let mut descending = index.clone();
    let (starts, _) = section(&index, 2);
    let (ends, _) = section(&index, 3);
    let end0 = descending[ends..ends + 8].to_vec();
    let past: u64 = u64::from_le_bytes(end0.try_into().unwrap()) + 1;
    descending[starts..starts + 8].copy_from_slice(&past.to_le_bytes());
    reseal(&mut descending, 2);
    assert!(matches!(open_with(&file, descending).err(), Some(Stale::Damaged(_))), "a record ending before it starts");
}

/// The index is read through a source as well as from memory: the Web's way.
#[test]
fn an_index_reads_through_a_source() {
    let file = mdx();
    let index = build(&file);
    let region = xdict_mdx::index::SourceRegion(Box::new(index.clone()));
    let read = File::with_index(Box::new(file.clone()), Some(Kind::Mdx), Box::new(region), EDITION, Arc::new(Marks(9)))
        .unwrap()
        .unwrap();
    assert_eq!(answers(&read), answers(&open_with(&file, index).unwrap()));
}

/// An MDD's paths are matched case-insensitively and never stripped, whatever its header says.
#[test]
fn resource_paths_are_never_stripped() {
    let spec = Spec { strip_key: Some(true), ..Spec::mdd() };
    let file = writer::write(&spec, &[Entry::bytes("\\a.mp3", b"one"), Entry::bytes("\\a_mp3", b"two")]).unwrap();
    let read = File::from_source(Box::new(file), Some(Kind::Mdd)).unwrap();
    let found = read.lookup("\\A.MP3").unwrap();
    assert_eq!(found.len(), 1);
    assert_eq!(found[0].data, b"one");
}

/// `find` counts what `lookup` would refuse, so a caller can page it (the sentence library's 66,355 records
/// under one key).
#[test]
fn find_pages_what_lookup_refuses() {
    let many: Vec<Entry> = (0..10_001).map(|i| Entry::text("EC", &format!("{i}"))).collect();
    let file = writer::write(&Spec { block_size: 1 << 16, ..Spec::mdx() }, &many).unwrap();
    let read = File::from_source(Box::new(file), None).unwrap();
    assert!(read.lookup("EC").is_err());
    let found = read.find("EC").unwrap();
    assert_eq!(found.len(), 10_001);
    assert_eq!(read.record(found[10_000]).unwrap().data, b"10000");
}

/// A key number past the end is an error from every call that takes one, never a wrapped read of another key
/// (audit 2026-10-14: `i * width` was unchecked).
#[test]
fn a_key_number_past_the_end_is_an_error() {
    let file = mdx();
    let read = open_with(&file, build(&file)).unwrap();
    for i in [read.len(), usize::MAX / 8 + 1, usize::MAX / 4 + 1, usize::MAX / 2, usize::MAX] {
        assert!(read.key(i).is_err(), "key {i}");
        assert!(read.record_size(i).is_err(), "record_size {i}");
        assert!(read.record(i).is_err(), "record {i}");
    }
}

/// A block count whose table size wraps to zero is a damaged index, not an allocation of 2^59 blocks.
#[test]
fn a_wrapping_block_count_is_stale() {
    let file = mdx();
    let mut index = build(&file);
    index[80..88].copy_from_slice(&(1u64 << 59).to_le_bytes());
    let at = 96 + 5 * 24;
    index[at + 8..at + 16].copy_from_slice(&0u64.to_le_bytes());
    reseal(&mut index, 5);
    assert!(matches!(open_with(&file, index).err(), Some(Stale::Damaged(_))));
}

/// An index region that records the largest single read asked of it.
struct Recording(Vec<u8>, Arc<AtomicUsize>);

impl Region for Recording {
    fn len(&self) -> u64 {
        self.0.len() as u64
    }
    fn bytes(&self, offset: u64, len: usize) -> Result<Cow<'_, [u8]>, Error> {
        self.1.fetch_max(len, Ordering::SeqCst);
        let from = offset as usize;
        self.0.get(from..from + len).map(|b| Cow::Owned(b.to_vec())).ok_or(Error::Malformed("past the end".into()))
    }
}

/// Opening checks every section's checksum without reading the key text whole: through a source (the Web's
/// way) a whole read is an allocation of the section's declared size, which only the index file bounds.
#[test]
fn an_index_is_checked_in_pieces() {
    let long: Vec<Entry> =
        (0..40_000).map(|i| Entry::text(&format!("{i:06}{}", "x".repeat(70)), "a meaning")).collect();
    let file = writer::write(&Spec { block_size: 1 << 16, ..Spec::mdx() }, &long).unwrap();
    let index = build(&file);
    assert!(section(&index, 0).1 > 2 << 20, "the key text is over 2 MiB");
    let largest = Arc::new(AtomicUsize::new(0));
    let region = Box::new(Recording(index, largest.clone()));
    let read = File::with_index(Box::new(file), Some(Kind::Mdx), region, EDITION, Arc::new(Marks(9))).unwrap().unwrap();
    assert_eq!(read.len(), 40_000);
    let largest = largest.load(Ordering::SeqCst);
    assert!(largest <= 1 << 20, "a read of {largest} bytes");
}

/// An index region with `extra` bytes of zeros past its real end, as a sparse file reads, counting every byte
/// read from it.
struct Sparse(Vec<u8>, u64, Arc<AtomicUsize>);

impl Region for Sparse {
    fn len(&self) -> u64 {
        self.0.len() as u64 + self.1
    }
    fn bytes(&self, offset: u64, len: usize) -> Result<Cow<'_, [u8]>, Error> {
        self.2.fetch_add(len, Ordering::SeqCst);
        let mut out = vec![0u8; len];
        for (i, byte) in out.iter_mut().enumerate() {
            if let Some(b) = self.0.get(offset as usize + i) {
                *byte = *b;
            }
        }
        Ok(Cow::Owned(out))
    }
}

/// A block count no file the reader opens could have is refused before the block table is read or checked:
/// through a source every byte of a declared section is a read, and only the region's length bounds it (audit
/// 2026-10-14, row 30). The table here is 512 MiB of a sparse region, sealed with its true checksum.
#[test]
fn a_block_count_the_file_cannot_hold_is_refused_unread() {
    let file = mdx();
    let mut index = build(&file);
    let count: u64 = 1 << 24;
    let table_len = count * 32;
    let at = index.len() as u64;
    index[80..88].copy_from_slice(&count.to_le_bytes());
    let slot = 96 + 5 * 24;
    index[slot..slot + 8].copy_from_slice(&at.to_le_bytes());
    index[slot + 8..slot + 16].copy_from_slice(&table_len.to_le_bytes());
    let mut zeros = xxhash_rust::xxh3::Xxh3::new();
    let chunk = vec![0u8; 1 << 20];
    for _ in 0..table_len >> 20 {
        zeros.update(&chunk);
    }
    index[slot + 16..slot + 24].copy_from_slice(&zeros.digest().to_le_bytes());
    let head = xxh3_64(&index[..HEADER_LEN - 8]);
    index[HEADER_LEN - 8..HEADER_LEN].copy_from_slice(&head.to_le_bytes());

    let read = Arc::new(AtomicUsize::new(0));
    let region = Box::new(Sparse(index, table_len, read.clone()));
    let opened = File::with_index(Box::new(file), Some(Kind::Mdx), region, EDITION, Arc::new(Marks(9))).unwrap();
    assert!(matches!(opened.err(), Some(Stale::Damaged(_))));
    let read = read.load(Ordering::SeqCst);
    assert!(read < 8 << 20, "{read} bytes read");
}

/// A record block shorter than its own framing (a type and a checksum, 8 bytes) is no block the reader made.
#[test]
fn a_block_shorter_than_its_framing_is_stale() {
    let file = mdx();
    let mut index = build(&file);
    let (start, _) = section(&index, 5);
    index[start + 8..start + 16].copy_from_slice(&7u64.to_le_bytes());
    reseal(&mut index, 5);
    assert!(matches!(open_with(&file, index).err(), Some(Stale::Damaged(_))));
}

/// The xxh3 of `len` zero bytes, as a sparse region reads them.
fn zeros_sum(len: u64) -> u64 {
    let mut zeros = xxhash_rust::xxh3::Xxh3::new();
    let chunk = vec![0u8; 1 << 20];
    let mut left = len;
    while left > 0 {
        let n = left.min(chunk.len() as u64) as usize;
        zeros.update(&chunk[..n]);
        left -= n as u64;
    }
    zeros.digest()
}

/// A key longer than any block the reader decompresses was never written by the reader's build, and through a
/// source reading it is an allocation of its length: the index is stale before any key is read (audit
/// 2026-10-14 round 2, row 24). The key text here is one key of 64 MiB and a byte, in a sparse region.
#[test]
fn a_key_longer_than_a_block_is_stale() {
    let file = mdx();
    let mut index = build(&file);
    let long = xdict_mdx::limits::BLOCK_BYTES + 1;
    let at = index.len() as u64;
    let slot = 96;
    index[slot..slot + 8].copy_from_slice(&at.to_le_bytes());
    index[slot + 8..slot + 16].copy_from_slice(&long.to_le_bytes());
    index[slot + 16..slot + 24].copy_from_slice(&zeros_sum(long).to_le_bytes());
    let (start, len) = section(&index, 1);
    for word in index[start + 4..start + len].as_chunks_mut::<4>().0 {
        *word = (long as u32).to_le_bytes();
    }
    reseal(&mut index, 1);
    let region = Box::new(Sparse(index, long, Arc::new(AtomicUsize::new(0))));
    let opened = File::with_index(Box::new(file), Some(Kind::Mdx), region, EDITION, Arc::new(Marks(9))).unwrap();
    let stale = opened.err();
    assert!(matches!(stale, Some(Stale::Damaged(_))), "{stale:?}");
}

/// Keys each within a block but together past what a build keeps within [`xdict_mdx::limits::INDEX_BYTES`]:
/// no index the reader wrote, so stale (row 24). Four keys of 64 MiB and one byte, in a sparse region.
#[test]
fn key_text_past_the_index_budget_is_stale() {
    let file = mdx();
    let mut index = build(&file);
    let block = xdict_mdx::limits::BLOCK_BYTES;
    let long = 4 * block + 1;
    let at = index.len() as u64;
    let slot = 96;
    index[slot..slot + 8].copy_from_slice(&at.to_le_bytes());
    index[slot + 8..slot + 16].copy_from_slice(&long.to_le_bytes());
    index[slot + 16..slot + 24].copy_from_slice(&zeros_sum(long).to_le_bytes());
    let (start, len) = section(&index, 1);
    for (k, word) in index[start..start + len].as_chunks_mut::<4>().0.iter_mut().enumerate() {
        *word = ((k as u64 * block).min(long) as u32).to_le_bytes();
    }
    reseal(&mut index, 1);
    let region = Box::new(Sparse(index, long, Arc::new(AtomicUsize::new(0))));
    let opened = File::with_index(Box::new(file), Some(Kind::Mdx), region, EDITION, Arc::new(Marks(9))).unwrap();
    let stale = opened.err();
    assert!(matches!(stale, Some(Stale::Damaged(_))), "{stale:?}");
}

/// The structural check reads its tables in pieces too, not each whole: 140,000 keys make the record starts
/// and ends over 1 MiB each, and no read through the region may be larger (row 25).
#[test]
fn the_tables_are_checked_in_pieces() {
    let many: Vec<Entry> = (0..140_000).map(|i| Entry::text(&format!("{i:07}"), "m")).collect();
    let file = writer::write(&Spec { block_size: 1 << 16, ..Spec::mdx() }, &many).unwrap();
    let index = build(&file);
    assert!(section(&index, 2).1 > 1 << 20, "the record starts are over 1 MiB");
    let largest = Arc::new(AtomicUsize::new(0));
    let region = Box::new(Recording(index, largest.clone()));
    let read = File::with_index(Box::new(file), Some(Kind::Mdx), region, EDITION, Arc::new(Marks(9))).unwrap().unwrap();
    assert_eq!(read.len(), 140_000);
    let largest = largest.load(Ordering::SeqCst);
    assert!(largest <= 1 << 20, "a read of {largest} bytes");
}

/// A kept index gives every key the definitions the writer wrote for it, checked against the writer's own list
/// rather than against another read through the same builder: duplicate keys, keys folding together, Unicode
/// keys, and records long enough to cross blocks. A bug in the build that sealed a key to another's record
/// would show here, since the index's own checks cannot catch what the build wrote wrongly (audit 2026-10-14
/// round 2, rows 23 and 28: a resealed index is outside the threat model, a builder's mistake is not).
#[test]
fn a_kept_index_gives_every_key_what_the_writer_wrote() {
    let long = "a long definition ".repeat(40);
    let mut written: Vec<(String, String)> = vec![
        ("run".into(), "to move fast".into()),
        ("run".into(), "a score in cricket".into()),
        ("RUN".into(), "an abbreviation".into()),
        ("café".into(), "a coffee shop".into()),
        ("cafe\u{301}".into(), "the same, decomposed".into()),
        ("ΐ".into(), "folds to three characters".into()),
        ("日本".into(), "Japan".into()),
        ("long".into(), long.clone()),
        ("long".into(), format!("{long}, again")),
    ];
    written.extend((0..300).map(|i| (format!("key{i:03}"), format!("definition {i} {}", "x".repeat(i % 50)))));
    let entries: Vec<Entry> = written.iter().map(|(k, v)| Entry::text(k, v)).collect();
    let file = writer::write(&Spec { block_size: 64, ..Spec::mdx() }, &entries).unwrap();
    let kept = open_with(&file, build(&file)).unwrap();
    let mut keys: Vec<&str> = written.iter().map(|(k, _)| k.as_str()).collect();
    keys.sort_unstable();
    keys.dedup();
    for key in keys {
        let mut wanted: Vec<&str> = written.iter().filter(|(k, _)| k == key).map(|(_, v)| v.as_str()).collect();
        let found = kept.lookup(key).unwrap();
        let mut got: Vec<String> =
            found.iter().filter(|r| r.key == key).map(|r| String::from_utf8_lossy(&r.data).into_owned()).collect();
        wanted.sort_unstable();
        got.sort_unstable();
        assert_eq!(got, wanted, "{key:?}");
    }
}
