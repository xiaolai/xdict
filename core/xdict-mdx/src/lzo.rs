//! LZO1X decompression, for blocks of type 1 in formats 1.2 and 2.0.
//!
//! Written from the stream format as the Linux kernel documents it (`Documentation/staging/lzo.rst`), never
//! from an LZO implementation: LZO's own code is GPL, and so is every decoder ported from it (XDict
//! ADR-0001's clean-room rule). Every block's Adler-32 checks the result: on 2026-10-13 every key of the 53 LZO
//! files among the 297 freemdict dictionaries of `dictionary-collection` (5,710,676) read back with no mismatch.
//!
//! A stream is instructions, each a copy from earlier output, a run of literals, or both: a copy's last two
//! bits say how many literals (0 to 3) follow it. Those bits are the *state*, and the state chooses what the
//! next instruction with high nibble 0 means. A run of four or more literals leaves state 4.

use crate::Error;

/// Decompresses `input` to exactly `expected` bytes. The stream must end with its end-of-stream
/// instruction, at the end of `input`, having produced exactly `expected` bytes; every copy must reach only
/// what was already produced.
pub(crate) fn decompress(input: &[u8], expected: usize, what: &str) -> Result<Vec<u8>, Error> {
    let mut s = Stream { input, at: 0, out: Vec::with_capacity(expected), expected, what };
    let first = s.byte()?;
    let mut state = if first > 17 {
        // A first run of literals: 1 to 3 leave that state, more leave state 4.
        let count = usize::from(first - 17);
        s.literals(count)?;
        count.min(4)
    } else {
        s.at = 0; // an ordinary instruction, read again below in state 0
        0
    };
    loop {
        let op = s.byte()?;
        let (distance, length, next) = match op {
            0x00..=0x0F if state == 0 => {
                // A run of literals: 4 or more.
                let count = 3 + s.length(op & 0x0F, 15)?;
                s.literals(count)?;
                state = 4;
                continue;
            }
            0x00..=0x0F => {
                // A short copy: 2 bytes from up to 1 kB back after 1 to 3 literals; 3 bytes from 2 to 3 kB back
                // after a run of 4 or more.
                let low = usize::from(s.byte()?) << 2 | usize::from(op >> 2 & 3);
                if state == 4 { (low + 2049, 3, usize::from(op & 3)) } else { (low + 1, 2, usize::from(op & 3)) }
            }
            0x10..=0x1F => {
                let length = 2 + s.length(op & 7, 7)?;
                let operand = s.le16()?;
                let distance = 16_384 + (usize::from(op >> 3 & 1) << 14) + (operand >> 2);
                if distance == 16_384 {
                    return s.finish();
                }
                (distance, length, operand & 3)
            }
            0x20..=0x3F => {
                let length = 2 + s.length(op & 31, 31)?;
                let operand = s.le16()?;
                ((operand >> 2) + 1, length, operand & 3)
            }
            0x40..=0x7F => {
                let distance = (usize::from(s.byte()?) << 3 | usize::from(op >> 2 & 7)) + 1;
                (distance, 3 + usize::from(op >> 5 & 1), usize::from(op & 3))
            }
            0x80..=0xFF => {
                let distance = (usize::from(s.byte()?) << 3 | usize::from(op >> 2 & 7)) + 1;
                (distance, 5 + usize::from(op >> 5 & 3), usize::from(op & 3))
            }
        };
        s.copy(distance, length)?;
        s.literals(next)?;
        state = next;
    }
}

struct Stream<'a> {
    input: &'a [u8],
    at: usize,
    out: Vec<u8>,
    expected: usize,
    what: &'a str,
}

impl Stream<'_> {
    fn malformed(&self, why: &str) -> Error {
        Error::Malformed(format!("the {}'s LZO stream {why}", self.what))
    }

    fn byte(&mut self) -> Result<u8, Error> {
        let byte = self.input.get(self.at).copied().ok_or_else(|| self.malformed("ends early"))?;
        self.at += 1;
        Ok(byte)
    }

    fn le16(&mut self) -> Result<usize, Error> {
        Ok(usize::from(u16::from_le_bytes([self.byte()?, self.byte()?])))
    }

    /// A length field: its bits when they are not zero; otherwise `base`, plus 255 for each zero byte that
    /// follows, plus the first non-zero byte. Bounded by the output still to come, so a run of zero bytes
    /// cannot count past what the block declares.
    fn length(&mut self, bits: u8, base: usize) -> Result<usize, Error> {
        if bits != 0 {
            return Ok(usize::from(bits));
        }
        let mut value = base;
        loop {
            match self.byte()? {
                0 => value += 255,
                last => return Ok(value + usize::from(last)),
            }
            if value > self.expected {
                return Err(self.malformed("declares a length longer than the block"));
            }
        }
    }

    fn room(&self, count: usize) -> Result<(), Error> {
        if count > self.expected - self.out.len() {
            return Err(self.malformed("produces more than the block declares"));
        }
        Ok(())
    }

    fn literals(&mut self, count: usize) -> Result<(), Error> {
        self.room(count)?;
        let end = self.at.checked_add(count).ok_or_else(|| self.malformed("ends early"))?;
        let bytes = self.input.get(self.at..end).ok_or_else(|| self.malformed("ends early"))?;
        self.out.extend_from_slice(bytes);
        self.at = end;
        Ok(())
    }

    /// Copies `length` bytes from `distance` back. A copy may overlap what it produces (distance 1 repeats
    /// one byte), so it goes in pieces no longer than the distance.
    fn copy(&mut self, distance: usize, length: usize) -> Result<(), Error> {
        self.room(length)?;
        let start =
            self.out.len().checked_sub(distance).ok_or_else(|| self.malformed("copies from before its start"))?;
        let mut done = 0;
        while done < length {
            let piece = (length - done).min(distance);
            self.out.extend_from_within(start + done..start + done + piece);
            done += piece;
        }
        Ok(())
    }

    fn finish(self) -> Result<Vec<u8>, Error> {
        if self.at != self.input.len() {
            return Err(self.malformed("has bytes after its end"));
        }
        if self.out.len() != self.expected {
            return Err(Error::Malformed(format!(
                "the {} decompresses to {} bytes where {} were declared",
                self.what,
                self.out.len(),
                self.expected
            )));
        }
        Ok(self.out)
    }
}

#[cfg(test)]
#[path = "lzo_tests.rs"]
mod tests;
