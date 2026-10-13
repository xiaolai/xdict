//! Collecting a file's keys from its key blocks, the same for every version.
//!
//! **Nothing is reserved from a count the file declares**, and every key is checked against its block's
//! declared count and the file's before it is stored. A small file that lies about its counts therefore
//! costs no more memory than the keys it really holds.

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

/// Memory one key costs while its index is built, estimated on the high side: its text offset (4), record
/// start and end (8 each), place in the order (4), and its folded text's offset (4); its text, and its
/// folded copy, which full case folding can make three times longer in UTF-8 (ΐ, 2 bytes, folds to 6; the
/// most any character grows, measured over every code point on 2026-10-13); and the sorted copy of the
/// record starts made while finding ends (8). The finished index keeps 24 bytes and the text.
pub(crate) fn index_cost(text: &str) -> u64 {
    cost_of(1, text.len() as u64)
}

/// [`index_cost`] of `keys` keys whose text is `text` bytes together: what a loaded index may declare, since
/// no build that kept within [`limits::INDEX_BYTES`] wrote more.
pub(crate) fn cost_of(keys: u64, text: u64) -> u64 {
    keys.saturating_mul(4 + 8 + 8 + 4 + 4 + 8).saturating_add(text.saturating_mul(4))
}

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
}

impl Keys {
    pub(crate) fn new(declared: u64, codec: Codec, wide: bool, budget: u64) -> Self {
        let mut keys = crate::index::Keys::default();
        keys.offsets.push(0);
        Self { keys, declared, codec, wide, budget, cost: 0 }
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
            let text = self.codec.decode(c.until_null(self.codec.unit())?);
            self.cost = self.cost.saturating_add(index_cost(&text));
            if self.cost > self.budget {
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

    /// Keys a file really holds are bounded by memory, not only by their count.
    #[test]
    fn the_index_stops_at_its_memory_budget() {
        let data = block(&["alpha", "beta", "gamma"]);
        let mut roomy = Keys::new(3, Codec::Utf8, true, 3 * index_cost("gamma"));
        assert!(roomy.add_block(&data, 3).is_ok());
        let mut tight = Keys::new(3, Codec::Utf8, true, 2 * index_cost("gamma"));
        assert!(matches!(tight.add_block(&data, 3), Err(Error::TooLarge(_))));
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
