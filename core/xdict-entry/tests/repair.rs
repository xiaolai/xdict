//! WI-12's repairs at render (`dev-docs/measurements/2026-10-15-mdx-health/`, "Disposition"): stray control
//! characters, a byte-order mark past the record's start and a literal `\n` standing for a line break are mended in
//! an entry's text, as is small-form CJK punctuation; nothing else is. Every entry here is written in the test, no
//! dictionary's.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use std::time::Instant;

use xdict_entry::{Style, html_normalized_within};

const BASE: &str = "xdict://d/";

fn render(text: &str) -> (String, u64) {
    let (html, counts) = html_normalized_within(text, BASE, "", &Style::of_sheets([]), usize::MAX).unwrap();
    (html, counts.strip.repairs)
}

fn html(text: &str) -> String {
    render(text).0
}

/// C0 controls, DEL and NUL, which never render as anything a reader wants, go from the text; tab, line feed and
/// carriage return stay.
#[test]
fn controls_go_from_text() {
    assert_eq!(html("a\u{0}b\u{1}c\u{8}d\u{b}e\u{c}f\u{e}g\u{1f}h\u{7f}i\u{81}j\u{9d}k"), "abcdefghijk");
    assert_eq!(html("a\tb\nc\rd"), "a\tb\nc\rd");
    assert_eq!(render("<b>x\u{85}y</b>\u{1}").1, 2);
    assert_eq!(render("plain <i>text</i>").1, 0);
}

/// A small form of CJK punctuation (U+FE50–FE57), which a CNS/Big5 converter wrote for an ordinary comma, is that
/// punctuation at full size: LDOCE-EC's "书﹐书籍" drew its comma as a dot at the baseline (WI-11, 2026-10-17). Other
/// compatibility forms stay as written.
#[test]
fn small_form_punctuation_is_full_size() {
    assert_eq!(html("书﹐书籍﹑本子﹔账目﹕好﹖是﹗"), "书，书籍、本子；账目：好？是！");
    assert_eq!(render("<b>书﹐书籍</b>").1, 1);
    assert_eq!(html("a﹒b ﹙c﹚"), "a﹒b ﹙c﹚");
}

/// A C1 control is a Windows-1252 byte read as Latin-1 (a lost dash between two words, curly quotes): it is
/// read as Windows-1252, unless that character follows it already (a dash written twice), when it goes. One Windows-1252
/// leaves undefined goes.
#[test]
fn c1_controls_are_read_as_windows_1252() {
    assert_eq!(html("bulbs\u{97}which"), "bulbs—which");
    assert_eq!(html("\u{93}OK\u{94} \u{85} \u{80}5 \u{9f}"), "“OK” … €5 Ÿ");
    assert_eq!(html("2\u{96}–3 m"), "2–3 m");
    assert_eq!(render("\u{93}OK\u{94}").1, 2);
}

/// A byte-order mark inside a record goes; one at its very start is the encoder's and stays.
#[test]
fn a_bom_past_the_start_goes() {
    assert_eq!(html("a\u{feff}b<i>\u{feff}c</i>"), "ab<i>c</i>");
    assert!(html("\u{feff}abc").starts_with('\u{feff}'));
}

/// A literal `\n` is a line break when what follows it is the record's end, a tag or whitespace and what precedes it
/// is no backslash; any other (`\n\t\ta`, MWU's `\t\` notation, `\\n`) is left as written.
#[test]
fn a_literal_backslash_n_before_a_break_becomes_one() {
    assert_eq!(html("rated ★★★☆☆\\n"), "rated ★★★☆☆\n");
    assert_eq!(html("one\\n<br>two\\n three"), "one\n<br>two\n three");
    assert_eq!(html("such\\n\\t\\ta"), "such\\n\\t\\ta");
    assert_eq!(html("a\\\\n"), "a\\\\n");
    assert_eq!(html("\\name"), "\\name");
    assert_eq!(render("x\\n").1, 1);
}

/// Only text is mended: a control inside a tag, an attribute value, a script or a style is left to the rewriter and
/// the browser, and a removal never joins a `<` to what follows into a tag.
#[test]
fn no_repair_turns_text_into_markup() {
    assert_eq!(html("&lt;\u{1}b&gt;"), "&lt;b&gt;");
    let out = html("<\u{1}script>alert(1)</script>");
    assert!(!out.contains("<script"), "{out}");
    let out = html("<\u{feff}b>x");
    assert!(!out.contains("<b>"), "{out}");
    let out = html("a<!\u{1}-- x -->b");
    assert!(!out.contains("<!--"), "{out}");
    assert!(html(r#"<span title="a\nb">x</span>"#).contains(r#"title="a\nb""#));
    // HTML shown as text stays text, and comment marks stay as written (the owner's 2026-10-15 decisions).
    assert_eq!(html("&lt;i&gt;A Title&lt;/i&gt;"), "&lt;i&gt;A Title&lt;/i&gt;");
    assert_eq!(html("a ---&gt; b --&gt; c"), "a ---&gt; b --&gt; c");
    assert!(html("---> 甲").contains("--->"));
    assert!(html("x <-- y").contains("--"));
}

/// The repairs are linear: a record made only of what they mend takes, per byte, no longer at eight times the size.
#[test]
fn the_repairs_are_linear_on_hostile_input() {
    let unit = "\u{1}\u{85}\\n <b>\u{feff}\\n</b>";
    let time = |n: usize| {
        let text = unit.repeat(n);
        let mut best = f64::MAX;
        for _ in 0..3 {
            let t = Instant::now();
            let (out, repairs) = render(&text);
            best = best.min(t.elapsed().as_secs_f64());
            assert_eq!(repairs, 5 * n as u64);
            assert!(out.len() < text.len());
        }
        best
    };
    let small = time(5_000);
    let large = time(40_000);
    assert!(large < small * 8.0 * 3.0, "8x the input took {:.1}x the time", large / small);
}
