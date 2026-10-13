#![allow(clippy::unwrap_used, clippy::panic, clippy::indexing_slicing)]

use super::decompress;
use crate::Error;
use xdict_mdx_writer::lzo::{self, Step};

fn lit(bytes: &[u8]) -> Step {
    Step::Literals(bytes.to_vec())
}

fn copy(distance: usize, length: usize) -> Step {
    Step::Copy { distance, length }
}

/// Pseudo-random bytes, as literals to copy from.
fn noise(n: usize, seed: u32) -> Vec<u8> {
    let mut x = seed.wrapping_mul(2_654_435_761) | 1;
    (0..n)
        .map(|_| {
            x ^= x << 13;
            x ^= x >> 17;
            x ^= x << 5;
            x as u8
        })
        .collect()
}

fn round_trip(label: &str, steps: &[Step]) {
    let stream = lzo::assemble(steps).unwrap_or_else(|e| panic!("{label}: {e}"));
    let expected = lzo::expand(steps).unwrap();
    let got = decompress(&stream, expected.len(), "test").unwrap_or_else(|e| panic!("{label}: {e}"));
    assert_eq!(got, expected, "{label}");
}

/// Every instruction the format has, each in the state that selects it.
#[test]
fn every_instruction_decodes() {
    let far = noise(45_000, 1);
    let cases: Vec<(&str, Vec<Step>)> = vec![
        ("first-byte literal run", vec![lit(b"abcde")]),
        ("first run of 1..3, then a 2-byte copy in that state", vec![lit(b"ab"), copy(2, 2), lit(b"c"), copy(1, 2)]),
        (
            "2-byte copies in states 1, 2 and 3",
            vec![lit(b"a"), copy(1, 2), lit(b"xy"), copy(3, 2), lit(b"pqr"), copy(5, 2)],
        ),
        ("3-byte copy 2049..3072 back, after a long run", vec![lit(&far[..3000]), copy(2500, 3)]),
        ("3- and 4-byte copies within 2 kB", vec![lit(b"abcdefgh"), copy(8, 3), copy(5, 4)]),
        (
            "5- to 8-byte copies within 2 kB",
            vec![lit(&far[..2048]), copy(2048, 5), copy(100, 6), copy(7, 7), copy(9, 8)],
        ),
        (
            "copies within 16 kB, short and extended",
            vec![lit(&far[..16_384]), copy(16_384, 9), copy(3000, 33), copy(4000, 600)],
        ),
        ("copies 16..48 kB back, both high bits", vec![lit(&far), copy(20_000, 3), copy(40_000, 9), copy(45_009, 700)]),
        ("an overlapping copy repeats its source", vec![lit(b"ab"), copy(2, 300)]),
        (
            "trailing literals of 1, 2 and 3",
            vec![lit(b"abcd"), copy(4, 4), lit(b"x"), copy(5, 4), lit(b"yz"), copy(6, 4), lit(b"uvw")],
        ),
        ("a long run after a copy", vec![lit(b"abcd"), copy(4, 4), lit(&far[..500])]),
        ("a first run too long for the first byte", vec![lit(&far[..239]), copy(239, 3)]),
        ("a run long enough to need zero bytes", vec![lit(&far[..1000])]),
    ];
    for (label, steps) in &cases {
        round_trip(label, steps);
    }
}

/// The empty block: the end-of-stream instruction alone.
#[test]
fn an_empty_stream_decodes_to_nothing() {
    assert_eq!(decompress(&[0x11, 0, 0], 0, "test").unwrap(), Vec::<u8>::new());
}

#[test]
fn real_text_round_trips() {
    let text = "<div class=\"entry\"><span class=\"hw\">run</span> to move fast; <i>he ran home</i>. ".repeat(400);
    let stream = lzo::compress(text.as_bytes()).unwrap();
    assert_eq!(decompress(&stream, text.len(), "test").unwrap(), text.as_bytes());
}

fn refused(stream: &[u8], expected: usize) -> String {
    match decompress(stream, expected, "test") {
        Err(Error::Malformed(why)) => why,
        other => panic!("{stream:?} expected {expected}: {other:?}"),
    }
}

#[test]
fn a_damaged_stream_is_malformed_and_says_why() {
    let good = lzo::assemble(&[lit(b"abcd"), copy(4, 4)]).unwrap();
    // Cut short, at every length.
    for cut in 0..good.len() {
        refused(&good[..cut], 8);
    }
    // Bytes after the end of the stream.
    refused(&[good.clone(), vec![0]].concat(), 8);
    // A different declared size, either way.
    refused(&good, 7);
    refused(&good, 9);
    // A copy reaching before the start: "a", then 01LDDDSS with distance 2.
    let before_start = [18, b'a', 0x44, 0x00, 0x11, 0, 0];
    assert!(refused(&before_start, 4).contains("before"), "{}", refused(&before_start, 4));
}

/// Arbitrary bytes never panic and never produce more than declared.
#[test]
fn arbitrary_bytes_never_panic() {
    for seed in 0..2000u32 {
        let bytes = noise((seed % 64) as usize + 1, seed);
        if let Ok(out) = decompress(&bytes, 32, "test") {
            assert_eq!(out.len(), 32);
        }
    }
}
