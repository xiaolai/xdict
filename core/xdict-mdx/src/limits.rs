//! The largest things a file may declare, checked before anything is allocated.
//!
//! Generous against real files (the largest block in the owner's 63-file collection is far below these) and
//! small enough that a hostile header cannot make the reader allocate gigabytes.

/// The header's XML, in bytes.
pub const HEADER_BYTES: u64 = 1 << 20;
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
/// Memory the key index may take, as `keys::index_cost` estimates it (232 bytes and five times the text a
/// key): about 3.8 million keys of 10 bytes, five times OED's 706,524. Bounds what a small, highly
/// compressed file can make the reader hold.
pub const INDEX_BYTES: u64 = 1 << 30;
