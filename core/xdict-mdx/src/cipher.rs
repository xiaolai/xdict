//! The format's two block ciphers and the 3.0 key. They hide bytes from casual reading, not from a key
//! holder: the key is derived from the file itself.

/// The scheme 2.0 uses for its key index and 3.0 for most blocks: each byte's nibbles are swapped, then it
/// is mixed with the previous *stored* byte, its position and the key.
pub(crate) fn nibble_decrypt(bytes: &mut [u8], key: &[u8; 16]) {
    let mut previous = 0x36u8;
    for ((i, byte), k) in bytes.iter_mut().enumerate().zip(key.iter().cycle()) {
        let stored = *byte;
        *byte = stored.rotate_left(4) ^ previous ^ (i as u8) ^ k;
        previous = stored;
    }
}

/// Salsa20/8 with a 16-byte key and a zero nonce, as 3.0 uses for its record data: XORs the keystream
/// from block 0 onwards into `bytes`.
pub(crate) fn salsa8_xor(bytes: &mut [u8], key: &[u8; 16]) {
    for (counter, chunk) in bytes.chunks_mut(64).enumerate() {
        let stream = salsa_block(key, counter as u64, 8);
        for (byte, k) in chunk.iter_mut().zip(stream) {
            *byte ^= k;
        }
    }
}

/// The 3.0 key: xxh64 of the first half of the header's `UUID` text, then of the second half, each as 8
/// bytes big-endian (`dev-docs/format-v3-facts.md`).
pub(crate) fn v3_key(uuid: &str) -> [u8; 16] {
    let (first, second) = uuid.as_bytes().split_at(uuid.len() / 2);
    let mut key = [0u8; 16];
    let halves = [first, second].map(|half| xxhash_rust::xxh64::xxh64(half, 0).to_be_bytes());
    for (slot, byte) in key.iter_mut().zip(halves.iter().flatten()) {
        *slot = *byte;
    }
    key
}

/// One quarter-round. A macro so every index is a constant into a 16-word array, which cannot go out of
/// bounds.
macro_rules! quarter {
    ($x:ident, $a:literal, $b:literal, $c:literal, $d:literal) => {
        $x[$b] ^= $x[$a].wrapping_add($x[$d]).rotate_left(7);
        $x[$c] ^= $x[$b].wrapping_add($x[$a]).rotate_left(9);
        $x[$d] ^= $x[$c].wrapping_add($x[$b]).rotate_left(13);
        $x[$a] ^= $x[$d].wrapping_add($x[$c]).rotate_left(18);
    };
}

/// One 64-byte Salsa20 block for a 16-byte key (the "expand 16-byte k" constants) and a zero nonce.
fn salsa_block(key: &[u8; 16], counter: u64, rounds: usize) -> [u8; 64] {
    let words = |bytes: &[u8; 16]| {
        let mut out = [0u32; 4];
        for (word, chunk) in out.iter_mut().zip(bytes.as_chunks::<4>().0) {
            *word = u32::from_le_bytes(*chunk);
        }
        out
    };
    let [c0, c1, c2, c3] = words(b"expand 16-byte k");
    let [k0, k1, k2, k3] = words(key);
    let (low, high) = (counter as u32, (counter >> 32) as u32);
    let input = [c0, k0, k1, k2, k3, c1, 0, 0, low, high, c2, k0, k1, k2, k3, c3];
    let mut x = input;
    for _ in 0..rounds / 2 {
        quarter!(x, 0, 4, 8, 12);
        quarter!(x, 5, 9, 13, 1);
        quarter!(x, 10, 14, 2, 6);
        quarter!(x, 15, 3, 7, 11);
        quarter!(x, 0, 1, 2, 3);
        quarter!(x, 5, 6, 7, 4);
        quarter!(x, 10, 11, 8, 9);
        quarter!(x, 15, 12, 13, 14);
    }
    let mut out = [0u8; 64];
    for ((chunk, word), original) in out.as_chunks_mut::<4>().0.iter_mut().zip(x).zip(input) {
        *chunk = word.wrapping_add(original).to_le_bytes();
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// eSTREAM's Salsa20 test vectors, 128-bit key, set 1, vector 0: the full 20 rounds check the round
    /// function that 3.0's 8-round variant shares.
    #[test]
    fn salsa20_matches_the_published_vector() {
        let mut key = [0u8; 16];
        key[0] = 0x80;
        let block = salsa_block(&key, 0, 20);
        let expected = "4dfa5e481da23ea09a31022050859936da52fcee218005164f267cb65f5cfd7f\
                        2b4f97e0ff16924a52df269515110a07f9e460bc65ef95da58f740b7d1dbb0aa";
        let hex: String = block.iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(hex, expected);
    }

    #[test]
    fn the_nibble_scheme_inverts_its_encryption() {
        let key = [7u8; 16];
        let plain: Vec<u8> = (0u8..40).collect();
        // Encrypt as the format defines it, the inverse of `nibble_decrypt`.
        let mut previous = 0x36u8;
        let mut stored: Vec<u8> = Vec::new();
        for (i, &p) in plain.iter().enumerate() {
            let c = (p ^ previous ^ (i as u8) ^ 7).rotate_left(4);
            stored.push(c);
            previous = c;
        }
        nibble_decrypt(&mut stored, &key);
        assert_eq!(stored, plain);
    }
}
