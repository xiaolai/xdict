//! Collecting a file's keys from its key blocks, the same for every version.
//!
//! **Nothing is reserved from a count the file declares** but a table its index has already been read to hold
//! ([`block_table`]), and every key is checked against its block's declared count and the file's before it is
//! stored. A small file that lies about its counts therefore costs no more memory than the keys it really holds.
//!
//! ## What reading the keys holds
//!
//! Against `limits::INDEX_BYTES`, each counted before it is made: the record-block table
//! (`block::weigh`), the key-block table ([`block_table`]), the keys ([`cost_of`], which is also what the
//! build is expected to take, then held to by its own ledger, `index::build`), and each key's decoding, weighed
//! before it decodes, into exactly the room weighed ([`Codec::decoded_capacity`]).
//!
//! Beside it, bounded by named limits and let go before the index is built:
//!
//! - **the blocks being read**: at most three times `limits::BLOCK_BYTES` at once. A key index or key block
//!   is held stored and decompressed (two); a 3.0 index section, joined and reserved whole, beside the one
//!   unit being decoded and what it decodes to (three, since all a section's units decode to at most one
//!   block's size together). A 3.0 unit is decrypted where it lies, and zlib output is never grown past its
//!   declared size, so neither holds a copy more. The decompressor's own state is fixed, about 80 KB;
//! - **the header**: its bytes, at most `limits::HEADER_BYTES`, a copy as UTF-16 units, its text (at most half
//!   as long again), and its attributes and the fields taken from them (each no longer than the text): under
//!   six times `limits::HEADER_BYTES` while it is parsed, half that kept, and at most
//!   `limits::HEADER_ATTRIBUTES` attribute entries, 48 bytes each in a list that may have doubled. A 3.0
//!   file's four section descriptors are each at most `limits::HEADER_BYTES`, stored and decoded, their
//!   attributes kept, under the same limit.

use crate::bytes::Cursor;
use crate::text::Codec;
use crate::{Error, limits};

/// What an index says about one key block.
pub(crate) struct KeyBlock {
    /// Keys the block declares.
    pub(crate) entries: u64,
    /// Bytes the block occupies in the file.
    pub(crate) stored: u64,
    /// Bytes it decompresses to.
    pub(crate) decompressed: u64,
}

/// What one key block costs while the keys are read: its entry, in a table reserved exactly.
pub(crate) const KEY_BLOCK_COST: u64 = std::mem::size_of::<KeyBlock>() as u64;

/// An empty table for the `count` key blocks a key index of `index_len` bytes declares, each block taking at
/// least `least` bytes of it, and what the table costs. `Malformed` when the index is too short to hold them and
/// `TooLarge` when the table would pass `budget`, both before anything is reserved; then reserved exactly.
pub(crate) fn block_table(
    count: u64,
    index_len: usize,
    least: u64,
    budget: u64,
) -> Result<(Vec<KeyBlock>, u64), Error> {
    if count.saturating_mul(least) > index_len as u64 {
        return Err(Error::Malformed(format!("a key index of {index_len} bytes cannot hold {count} blocks")));
    }
    let cost = count.saturating_mul(KEY_BLOCK_COST);
    if cost > budget {
        return Err(Error::TooLarge(format!("{count} key blocks would take the key index past its memory")));
    }
    let mut table = Vec::new();
    table
        .try_reserve_exact(usize::try_from(count).map_err(|_| crate::malformed("key index"))?)
        .map_err(crate::out_of_memory)?;
    Ok((table, cost))
}

/// Checks the blocks' counts and sizes add up to what the file declares, without overflow, before any
/// block is read.
pub(crate) fn check_blocks(blocks: &[KeyBlock], key_count: u64, stored_total: u64) -> Result<(), Error> {
    if key_count > limits::KEYS {
        return Err(Error::Malformed(format!("the file declares {key_count} keys")));
    }
    let sum = |field: fn(&KeyBlock) -> u64| blocks.iter().try_fold(0u64, |total, b| total.checked_add(field(b)));
    if sum(|b| b.entries) != Some(key_count) {
        return Err(Error::Malformed("the key blocks' counts do not add up to the file's".into()));
    }
    if sum(|b| b.stored) != Some(stored_total) {
        return Err(Error::Malformed("the key blocks' sizes do not add up".into()));
    }
    Ok(())
}

/// Memory one key costs while its index is built, estimated on the high side: [`cost_of`] for one key.
pub(crate) fn index_cost(text: &str) -> u64 {
    cost_of(1, text.len() as u64)
}

/// What building the index of `keys` keys whose text is `text` bytes (t) is expected to hold at once, block
/// tables aside ([`BLOCK_COST`]): 65 bytes a key and five times its text. An estimate, made while the keys are
/// read so that a file too large is refused before it all is; what holds the build to its budget is its own
/// ledger (`index::build`), which counts each table as it is made, whatever unmarking and folding make of the
/// keys. What a loaded index may declare, too, since `index::build` checks it first. Phase by phase, per key:
///
/// - read from the blocks: text, offset (4) and record start (8), in vectors that grow by doubling, so up to
///   twice that held after reading: 2t + 24;
/// - tier 2: the forms of the keys it changes (few: under 2 % of the 25's), taken as up to three times their
///   text, with 12 bytes of entry and 6 of stable sorting: 3t + 18, its result then 4;
/// - tier 1: the folded text (at most [`crate::text::FOLD_GROWTH`] t) and its offsets (4), the order (4) and its
///   sorting (4): 3t + 12;
/// - written out: the record ends (8, and 8 of sorted starts while they are found), the public bitmap, and the
///   index itself, reserved whole: the text and 28 bytes of tables a key: 3t + 64.
pub(crate) fn cost_of(keys: u64, text: u64) -> u64 {
    keys.saturating_mul(65).saturating_add(text.saturating_mul(5))
}

/// What ordering tier 2 is expected to add beside [`cost_of`] for the longest key, folding alone counted: the
/// ledger counts it with what unmarking adds (`index::tier2_scratch`).
pub(crate) fn scratch_cost(longest: u64) -> u64 {
    longest.saturating_mul(6)
}

/// What one record block adds to building an index: its entry as read (32) in a vector that may have doubled,
/// and in the index written (32).
pub(crate) const BLOCK_COST: u64 = 96;

/// The keys of a file, as its blocks are decoded.
pub(crate) struct Keys {
    keys: crate::index::Keys,
    declared: u64,
    codec: Codec,
    /// Record offsets are 8 bytes wide from 2.0, 4 before.
    wide: bool,
    /// What the index may cost, and what it costs so far, by `index_cost`.
    budget: u64,
    cost: u64,
    /// The longest key's text so far, for [`scratch_cost`].
    longest: u64,
}

impl Keys {
    pub(crate) fn new(declared: u64, codec: Codec, wide: bool, budget: u64) -> Self {
        let mut keys = crate::index::Keys::default();
        keys.offsets.push(0);
        Self { keys, declared, codec, wide, budget, cost: 0, longest: 0 }
    }

    fn count(&self) -> u64 {
        self.keys.starts.len() as u64
    }

    /// Adds one decompressed key block: per key, its record's offset and the key, null-terminated.
    pub(crate) fn add_block(&mut self, data: &[u8], entries: u64) -> Result<(), Error> {
        let mut c = Cursor::new(data, "key block");
        let mut found = 0u64;
        while !c.is_at_end() {
            if found == entries || self.count() == self.declared {
                return Err(Error::Malformed(format!("a key block holds more than the {entries} keys it declares")));
            }
            let offset = c.number(self.wide)?;
            let raw = c.until_null(self.codec.unit())?;
            // What decoding holds, weighed before it does, beside what the keys already cost.
            let capacity = self.codec.decoded_capacity(raw)?;
            if self.spent().saturating_add(capacity as u64) > self.budget {
                return Err(Error::TooLarge(format!("the key index would take more than {} bytes", self.budget)));
            }
            let text = self.codec.decode_exact(raw, capacity)?;
            self.cost = self.cost.saturating_add(index_cost(&text));
            self.longest = self.longest.max(text.len() as u64);
            if self.cost.saturating_add(scratch_cost(self.longest)) > self.budget {
                return Err(Error::TooLarge(format!("the key index would take more than {} bytes", self.budget)));
            }
            let keys = &mut self.keys;
            keys.text.try_reserve(text.len()).map_err(crate::out_of_memory)?;
            keys.offsets.try_reserve(1).map_err(crate::out_of_memory)?;
            keys.starts.try_reserve(1).map_err(crate::out_of_memory)?;
            keys.text.extend_from_slice(text.as_bytes());
            let end = u32::try_from(keys.text.len())
                .map_err(|_| Error::TooLarge("the keys' text would pass 4 GiB".into()))?;
            keys.offsets.push(end);
            keys.starts.push(offset);
            found += 1;
        }
        if found != entries {
            return Err(Error::Malformed(format!("a key block holds {found} keys where {entries} were declared")));
        }
        Ok(())
    }

    /// What the keys read so far cost the build, their tier-2 scratch with them: what is left of the budget is
    /// what the record-block table may take.
    pub(crate) fn spent(&self) -> u64 {
        self.cost.saturating_add(scratch_cost(self.longest))
    }

    pub(crate) fn finish(self) -> Result<crate::index::Keys, Error> {
        if self.count() != self.declared {
            return Err(Error::Malformed("the key blocks hold a different number of keys than declared".into()));
        }
        Ok(self.keys)
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;

    fn block(keys: &[&str]) -> Vec<u8> {
        keys.iter().flat_map(|k| [0u64.to_be_bytes().as_slice(), k.as_bytes(), &[0]].concat()).collect()
    }

    /// Keys a file really holds are bounded by memory, not only by their count, and the budget holds the
    /// scratch tier 2 folds the longest key into as well as the keys, and room to decode each.
    #[test]
    fn the_index_stops_at_its_memory_budget() {
        let data = block(&["alpha", "beta", "gamma"]);
        let keys_alone = 3 * index_cost("gamma");
        // Two keys and the scratch held as the third, five bytes, is decoded.
        let mut roomy = Keys::new(3, Codec::Utf8, true, keys_alone + scratch_cost(5) + 5);
        assert!(roomy.add_block(&data, 3).is_ok());
        let mut no_scratch = Keys::new(3, Codec::Utf8, true, keys_alone);
        assert!(matches!(no_scratch.add_block(&data, 3), Err(Error::TooLarge(_))));
        let mut tight = Keys::new(3, Codec::Utf8, true, 2 * index_cost("gamma"));
        assert!(matches!(tight.add_block(&data, 3), Err(Error::TooLarge(_))));
    }

    /// A key-block table is weighed and checked against the index that declares it before it is reserved, then
    /// reserved exactly: a file declaring millions of blocks in a short index costs nothing.
    #[test]
    fn a_key_block_table_is_weighed_before_it_is_reserved() {
        let (table, cost) = block_table(1000, 14_000, 14, 1000 * KEY_BLOCK_COST).unwrap();
        assert_eq!((table.capacity(), cost), (1000, 1000 * KEY_BLOCK_COST));
        let mut refused = None;
        let held = allocation_counter::measure(|| refused = Some(block_table(1001, 14_000, 14, u64::MAX)));
        assert!(matches!(refused, Some(Err(Error::Malformed(_)))), "an index too short for its blocks");
        assert!(held.bytes_max < 1000, "{} bytes", held.bytes_max);
        let held =
            allocation_counter::measure(|| refused = Some(block_table(1000, 14_000, 14, 1000 * KEY_BLOCK_COST - 1)));
        assert!(matches!(refused, Some(Err(Error::TooLarge(_)))), "a table past the budget");
        assert!(held.bytes_max < 1000, "{} bytes", held.bytes_max);
    }

    /// A key is weighed before it is decoded: one past the budget is refused without the text decoding would
    /// make, which may be several times the key (`Codec::decoded_capacity`).
    #[test]
    fn a_key_is_weighed_before_it_is_decoded() {
        let key = vec![0xFFu8; 100_000];
        let data = [0u64.to_be_bytes().as_slice(), &key, &[0]].concat();
        let capacity = Codec::Utf8.decoded_capacity(&key).unwrap() as u64;
        let mut keys = Keys::new(1, Codec::Utf8, true, capacity - 1);
        let mut refused = None;
        let held = allocation_counter::measure(|| refused = Some(keys.add_block(&data, 1)));
        assert!(matches!(refused, Some(Err(Error::TooLarge(_)))), "{refused:?}");
        assert!(held.bytes_max < 1000, "{} bytes were held to refuse it", held.bytes_max);
    }

    /// A key that fits the room weighed for its decoding holds no more than that room while it decodes, in every
    /// codec: Codex's case, 3,000 bad Big5 bytes, which a string grown by doubling decoded in 24,576 bytes
    /// where 21,083 had been weighed.
    #[test]
    fn a_key_decodes_within_what_was_weighed() {
        let key = vec![0xFFu8; 3000];
        let data = [0u64.to_be_bytes().as_slice(), &key, &[0]].concat();
        let big5 = Codec::Legacy(encoding_rs::BIG5);
        let capacity = big5.decoded_capacity(&key).unwrap() as u64;
        let mut keys = Keys::new(1, big5, true, capacity);
        let mut result = None;
        let held = allocation_counter::measure(|| result = Some(keys.add_block(&data, 1)));
        assert!(matches!(result, Some(Err(Error::TooLarge(_)))), "the key itself does not fit: {result:?}");
        // The decoded text, and the sentence that refuses the key once it is costed.
        assert!(held.bytes_max <= capacity + 128, "held {}, weighed {capacity}", held.bytes_max);
    }

    /// Case folding can triple a key's UTF-8 length (ΐ, 2 bytes, folds to 6), and the folded copy is kept
    /// beside the key while the order is sorted.
    #[test]
    fn the_index_cost_allows_for_folding_growth() {
        let key = "ΐ".repeat(100);
        let folded = crate::text::fold(&key, false, false);
        assert_eq!(folded.len(), 3 * key.len());
        assert!(index_cost(&key) >= key.len() as u64 + folded.len() as u64);
    }
}
