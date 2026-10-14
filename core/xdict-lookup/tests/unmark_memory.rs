//! What `unmark` really holds, measured by the allocator: the strings it builds with their spare capacity and
//! the buffers normalization keeps inside its iterators, which no length can show. An index build counts
//! [`Policy::growth`] of the longest key for it (`xdict_mdx::index::Derive::growth`).
//!
//! A measure, not a proof: the bound holds for what is swept here. The rate has a reason (`Policy::growth`'s
//! doc: two strings collected by doubling, each at most `NFKD_GROWTH` times the key); the fixed part does not.

#![allow(clippy::unwrap_used)]

use xdict_lookup::{Policy, unmark};
use xdict_mdx::index::Derive;

/// The most `unmark` holds at once, its result included, counted in this thread alone.
fn held(text: &str) -> u64 {
    allocation_counter::measure(|| drop(std::hint::black_box(unmark(text)))).bytes_max
}

/// What was measured so far: the most held a byte over long text, and the most held beyond the rate.
struct Most {
    rate: (f64, String),
    fixed: (i64, String),
}

impl Most {
    fn check(&mut self, text: &str, at: impl Fn() -> String) {
        let growth = Policy.growth();
        let (bytes, most) = (text.len() as u64, held(text));
        assert!(most <= growth.of(bytes), "{}: {bytes} bytes held {most}, past {}", at(), growth.of(bytes));
        if bytes >= 600 && most as f64 / bytes as f64 > self.rate.0 {
            self.rate = (most as f64 / bytes as f64, at());
        }
        let beyond = most as i64 - (growth.per_byte * bytes) as i64;
        if beyond > self.fixed.0 {
            self.fixed = (beyond, at());
        }
    }
}

/// Every scalar value, alone, in runs (every length to 16, and either side of each power of two to 1025, where
/// a string grown by doubling holds most beside its text), as a run after a starter, and beside U+FDFA, the
/// longest decomposition: a run of combining marks waits in normalization's buffer until a starter, and short
/// text is where least capacities weigh most. Then U+FDFA runs mixed with runs of combining marks kept by
/// unmarking, in descending combining class so normalization must reorder them. A character `unmark` holds
/// nothing for, alone or twice, is plain, and so is any run of it. `Policy::growth` must hold every one, and be
/// what was measured: its rate the ceiling of the most held a byte over long text, its fixed part the most held
/// beyond that rate.
#[test]
fn unmark_holds_within_its_growth_by_the_allocator() {
    let growth = Policy.growth();
    let mut most = Most { rate: (0.0, String::new()), fixed: (0, String::new()) };
    let powers: Vec<usize> = (5..=10).flat_map(|k| [(1 << k) - 1, 1 << k, (1 << k) + 1]).collect();
    let times: Vec<usize> = (1..=16).chain(powers).chain([300, 1000]).collect();
    for c in (0..=0x10FFFFu32).filter_map(char::from_u32).filter(|c| !c.is_ascii()) {
        let one = c.to_string();
        if held(&one) == 0 && held(&one.repeat(2)) == 0 {
            continue;
        }
        for &n in &times {
            most.check(&one.repeat(n), || format!("U+{:04X} ×{n}", c as u32));
        }
        most.check(&format!("a{}", one.repeat(200)), || format!("a, U+{:04X} ×200", c as u32));
        most.check(&format!("\u{FDFA}{}", one.repeat(20)), || format!("U+FDFA, U+{:04X} ×20", c as u32));
        most.check(&format!("{}\u{FDFA}", one.repeat(20)), || format!("U+{:04X} ×20, U+FDFA", c as u32));
    }
    // Hebrew points, kept by unmarking, from the highest combining class down (U+05BD is 22, U+05B0 10).
    let marks: String = ('\u{05B0}'..='\u{05BD}').rev().collect();
    for k in [1, 2, 3, 7, 8, 9, 31, 32, 33] {
        for m in [1, 2, 3, 15, 16, 17, 63, 64, 65] {
            let text = format!("{}{}", "\u{FDFA}".repeat(k), marks.repeat(m));
            most.check(&text, || format!("U+FDFA ×{k}, marks ×{m}"));
            let text = format!("{}{}", marks.repeat(m), "\u{FDFA}".repeat(k)).repeat(2);
            most.check(&text, || format!("(marks ×{m}, U+FDFA ×{k}) ×2"));
        }
    }
    println!(
        "unmark holds {:.2} bytes a byte at most over long text ({}), and {} more ({})",
        most.rate.0, most.rate.1, most.fixed.0, most.fixed.1
    );
    assert_eq!(most.rate.0.ceil() as u64, growth.per_byte, "the rate is not the measured one");
    assert_eq!(most.fixed.0.max(0) as u64, growth.fixed, "the fixed part is not the measured one");
}
