//! The largest things a file may declare, checked before anything is allocated.
//!
//! Generous against real files (the largest block in the owner's 63-file collection is far below these) and
//! small enough that a hostile header cannot make the reader allocate gigabytes.

/// The header's XML, in bytes.
pub const HEADER_BYTES: u64 = 1 << 20;
/// Attributes in one header or 3.0 section descriptor. The most in the owner's 359 files is 17 (2026-10-14);
/// a megabyte of short ones would otherwise hold twenty times its size in entries, and checking each for a
/// repeat of the ones before takes time growing with their square.
pub const HEADER_ATTRIBUTES: usize = 1024;
/// One decompressed key or record block, or the decompressed key index.
pub const BLOCK_BYTES: u64 = 64 << 20;
/// Keys in one file: 14 times OED's 706,524, the largest in the owner's collection. A count check made
/// before anything is read; the memory the keys really take is bounded by [`INDEX_BYTES`], which a file
/// reaches first. Nothing is reserved from a declared count (`keys.rs`).
pub const KEYS: u64 = 10_000_000;
/// The records one lookup may return, together: four records of the largest size a block allows. A file
/// where thousands of keys lead to one large record would otherwise multiply it without bound.
pub const LOOKUP_BYTES: u64 = 4 * BLOCK_BYTES;
/// Records one lookup may return. A file where millions of keys fold together would otherwise build millions
/// of results. Real files do reach it: a sentence library on freemdict ("6万多个句子飞跃6.0句库导出") files all
/// 66,355 of its records under the one key "EC", so going past it is [`crate::Error::TooLarge`], not damage.
pub const LOOKUP_RECORDS: usize = 10_000;
/// Memory building the key index may take, as `keys::cost_of` estimates it (65 bytes and five times the
/// text a key, phase by phase): about 9 million keys of 10 bytes. TLD, the largest file measured (4,362,467
/// keys, 73 MB of key text), estimates at 0.60 GiB and builds at a peak of 474 MiB resident (2026-10-14; the
/// estimate of 36 bytes and four times the text before then, 0.42 GiB, was under its 506 MiB peak); the old
/// hash-map index estimated it at 1.6 GiB and refused it. Bounds what a small, highly compressed file can make
/// the reader hold.
pub const INDEX_BYTES: u64 = 1 << 30;
