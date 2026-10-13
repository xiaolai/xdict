//! LZO1X streams, for tests only: format 1.2 and 2.0 files mark such blocks type 1.
//!
//! Written from the stream format as the Linux kernel documents it (`Documentation/staging/lzo.rst`), never
//! from an LZO implementation: LZO's own code is GPL. [`assemble`] turns explicit steps into a stream, so a
//! test can name the instruction it wants; [`compress`] finds matches greedily and assembles them.

use crate::WriteError;

/// One step of a stream: bytes copied as they are, or bytes copied from `distance` back in the output.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Step {
    Literals(Vec<u8>),
    Copy { distance: usize, length: usize },
}

/// The farthest a copy may reach: 16384 + (1 << 14) + (1 << 14) - 1.
pub const MAX_DISTANCE: usize = 49_151;

/// The output `steps` describe, so a test can compare a decoder's answer with it.
pub fn expand(steps: &[Step]) -> Result<Vec<u8>, WriteError> {
    let mut out: Vec<u8> = Vec::new();
    for step in steps {
        match step {
            Step::Literals(bytes) => out.extend(bytes),
            Step::Copy { distance, length } => {
                let start =
                    out.len().checked_sub(*distance).ok_or(WriteError::Incompatible("a copy before the start"))?;
                for i in 0..*length {
                    let byte = *out.get(start + i).ok_or(WriteError::Incompatible("a copy before the start"))?;
                    out.push(byte);
                }
            }
        }
    }
    Ok(out)
}

/// Encodes `steps` as an LZO1X stream, ending with the end-of-stream instruction. Fails where the format has
/// no instruction for a step in its place: a copy first, two copies' worth of literals in a row, a copy of
/// two bytes outside the one place that allows it, or a distance beyond [`MAX_DISTANCE`].
pub fn assemble(steps: &[Step]) -> Result<Vec<u8>, WriteError> {
    let mut merged: Vec<Step> = Vec::new();
    for step in steps {
        match (merged.last_mut(), step) {
            (Some(Step::Literals(previous)), Step::Literals(more)) => previous.extend(more),
            (_, Step::Literals(bytes)) if bytes.is_empty() => {}
            _ => merged.push(step.clone()),
        }
    }
    let mut out = Vec::new();
    // `state`: 0 after a copy followed by no literals, 1 to 3 after a copy followed by that many, 4 after a
    // run of four or more literals.
    let mut state = 0u8;
    let mut produced = 0usize;
    let mut i = 0;
    match merged.first() {
        Some(Step::Literals(first)) if first.len() <= 238 => {
            out.push(17 + first.len() as u8);
            out.extend(first);
            state = if first.len() < 4 { first.len() as u8 } else { 4 };
            produced += first.len();
            i = 1;
        }
        Some(Step::Literals(_)) => {} // too long for the first-byte form: an ordinary run below, in state 0
        _ => return Err(WriteError::Incompatible("an LZO stream starts with literals")),
    }
    while let Some(step) = merged.get(i) {
        match step {
            Step::Literals(bytes) => {
                // Reached only for a run of four or more after a copy that announced none, or the first run.
                if state != 0 || bytes.len() < 4 {
                    return Err(WriteError::Incompatible("literals the stream cannot place here"));
                }
                push_length(&mut out, 0x00, bytes.len() - 3, 15);
                out.extend(bytes);
                produced += bytes.len();
                state = 4;
            }
            Step::Copy { distance, length } => {
                let (distance, length) = (*distance, *length);
                if distance == 0 || distance > produced || distance > MAX_DISTANCE {
                    return Err(WriteError::Incompatible("a copy distance the stream cannot hold"));
                }
                // Literals after the copy: up to three ride in its last two bits.
                let trailing = match merged.get(i + 1) {
                    Some(Step::Literals(bytes)) if bytes.len() <= 3 => bytes.clone(),
                    _ => Vec::new(),
                };
                let s = trailing.len() as u8;
                if length == 2 && (1..=3).contains(&state) && distance <= 1024 {
                    let d = distance - 1;
                    out.push((((d & 3) as u8) << 2) | s);
                    out.push((d >> 2) as u8);
                } else if length == 3 && state == 4 && (2049..=3072).contains(&distance) {
                    let d = distance - 2049;
                    out.push((((d & 3) as u8) << 2) | s);
                    out.push((d >> 2) as u8);
                } else if (3..=4).contains(&length) && distance <= 2048 {
                    let d = distance - 1;
                    out.push(0x40 | (((length - 3) as u8) << 5) | (((d & 7) as u8) << 2) | s);
                    out.push((d >> 3) as u8);
                } else if (5..=8).contains(&length) && distance <= 2048 {
                    let d = distance - 1;
                    out.push(0x80 | (((length - 5) as u8) << 5) | (((d & 7) as u8) << 2) | s);
                    out.push((d >> 3) as u8);
                } else if length >= 3 && distance <= 16_384 {
                    push_length(&mut out, 0x20, length - 2, 31);
                    out.extend(((((distance - 1) << 2) as u16) | u16::from(s)).to_le_bytes());
                } else if length >= 3 {
                    let far = distance - 16_384;
                    push_length(&mut out, 0x10 | (((far >> 14) as u8) << 3), length - 2, 7);
                    out.extend(((((far & 0x3FFF) << 2) as u16) | u16::from(s)).to_le_bytes());
                } else {
                    return Err(WriteError::Incompatible("a two-byte copy outside the one place allowing it"));
                }
                produced += length;
                out.extend(&trailing);
                produced += trailing.len();
                state = s;
                if s > 0 {
                    i += 1; // the literals went with the copy
                }
            }
        }
        i += 1;
    }
    out.extend([0x11, 0x00, 0x00]);
    Ok(out)
}

/// An instruction whose length field is `bits` wide: the value itself, or, when it does not fit, zero bits
/// followed by a zero byte per 255 and a last non-zero byte.
fn push_length(out: &mut Vec<u8>, opcode: u8, value: usize, bits_max: usize) {
    if (1..=bits_max).contains(&value) {
        out.push(opcode | value as u8);
        return;
    }
    out.push(opcode);
    let mut rest = value - bits_max;
    while rest > 255 {
        out.push(0);
        rest -= 255;
    }
    out.push(rest as u8);
}

/// Greedy compression: at each position, the longest earlier match of at least three bytes found through a
/// table of the last position each three-byte prefix was seen.
pub fn compress(data: &[u8]) -> Result<Vec<u8>, WriteError> {
    let steps = steps(data);
    if steps.is_empty() {
        // An empty block: the end-of-stream instruction alone.
        return Ok(vec![0x11, 0x00, 0x00]);
    }
    assemble(&steps)
}

/// The steps [`compress`] assembles.
pub fn steps(data: &[u8]) -> Vec<Step> {
    let mut steps = Vec::new();
    let mut literals = Vec::new();
    let mut last_seen = std::collections::HashMap::new();
    let mut at = 0;
    while at < data.len() {
        let prefix = data.get(at..at + 3);
        let found = prefix.and_then(|p| last_seen.get(p).copied()).filter(|&from: &usize| at - from <= MAX_DISTANCE);
        if let Some(prefix) = prefix {
            last_seen.insert(prefix, at);
        }
        let rest = data.get(at..).unwrap_or(&[]);
        let length = found
            .map_or(0, |from| rest.iter().zip(data.get(from..).unwrap_or(&[])).take_while(|(a, b)| a == b).count());
        match found {
            Some(from) if length >= 3 => {
                if !literals.is_empty() {
                    steps.push(Step::Literals(std::mem::take(&mut literals)));
                }
                steps.push(Step::Copy { distance: at - from, length });
                at += length;
            }
            _ => {
                literals.extend(data.get(at).copied());
                at += 1;
            }
        }
    }
    if !literals.is_empty() {
        steps.push(Step::Literals(literals));
    }
    steps
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::indexing_slicing)]
mod tests {
    use super::*;

    /// Hand-assembled from the format description, so the assembler is checked against something it did
    /// not produce: literal run "abcde" (17 + 5), then end of stream.
    #[test]
    fn a_literal_run_is_the_first_byte_form() {
        let steps = [Step::Literals(b"abcde".to_vec())];
        assert_eq!(assemble(&steps).unwrap(), [22, b'a', b'b', b'c', b'd', b'e', 0x11, 0, 0]);
    }

    /// "abcd" then a copy of 4 bytes from 4 back, 0 literals after: 01LDDDSS with L = 1, D = 3, S = 0, then
    /// H = 0. So 0x40 | 0x20 | 0x0C = 0x6C.
    #[test]
    fn a_short_near_copy_is_one_byte_and_a_distance_byte() {
        let steps = [Step::Literals(b"abcd".to_vec()), Step::Copy { distance: 4, length: 4 }];
        assert_eq!(assemble(&steps).unwrap(), [21, b'a', b'b', b'c', b'd', 0x6C, 0x00, 0x11, 0, 0]);
    }

    /// A copy of 40 bytes from 1 back: 001LLLLL with L = 0 (38 does not fit 31 bits' worth), extension 7, and
    /// the distance operand (0 << 2) | 2 for the two literals after it.
    #[test]
    fn a_long_copy_extends_its_length() {
        let steps =
            [Step::Literals(b"x".to_vec()), Step::Copy { distance: 1, length: 40 }, Step::Literals(b"yz".to_vec())];
        assert_eq!(assemble(&steps).unwrap(), [18, b'x', 0x20, 7, 0x02, 0x00, b'y', b'z', 0x11, 0, 0]);
        assert_eq!(expand(&steps).unwrap(), [b"x".repeat(41), b"yz".to_vec()].concat());
    }

    #[test]
    fn steps_the_format_cannot_hold_are_refused() {
        assert!(assemble(&[Step::Copy { distance: 1, length: 3 }]).is_err());
        let two_in_state_four = [Step::Literals(b"abcd".to_vec()), Step::Copy { distance: 1, length: 2 }];
        assert!(assemble(&two_in_state_four).is_err());
    }

    #[test]
    fn compression_describes_its_input_and_shrinks_repetition() {
        let data: Vec<u8> = b"the cat sat on the mat; the cat sat on the hat. ".repeat(50);
        assert_eq!(expand(&steps(&data)).unwrap(), data);
        let stream = compress(&data).unwrap();
        assert!(stream.len() < data.len() / 4, "{} bytes for {}", stream.len(), data.len());
    }
}
