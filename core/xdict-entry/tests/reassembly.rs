//! Markup reassembly: the rewriter removes pieces of an entry (comments, scripts, `meta`/`base`/`title`, page tags,
//! dropped images, private-use glyphs in a speaker, attributes) and inserts its own. Whatever it removes or inserts,
//! the output, read by a browser's HTML parser, must hold no markup the rewriter's own scan did not see: no
//! `<script>`, no `on*` handler, no `javascript:` URL, no `<meta http-equiv>` or `<base>` that it never met.
//!
//! The output is checked against an independent HTML5 parser, `html5ever` with `markup5ever_rcdom` (the Servo
//! project's tokenizer and tree builder, MIT/Apache-2.0, dev-dependencies only, never linked into the core). Our own
//! scanner cannot be its own oracle: the defect class is exactly where its reading and a browser's part. The tree
//! builder matters, not only the tokenizer: raw-text switches (`noscript` with scripting on, `xmp`, `textarea`) and
//! foreign content (`svg`, `math`, CDATA) are decided by it.
//!
//! Every dangerous word in these inputs is split by a removable piece, or sits where the rewriter reads it as text
//! or as an attribute's value, so any script, handler or `javascript:` URL in the parsed output was assembled, not
//! passed through. Every entry here is written in the test, no dictionary's.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use html5ever::tendril::TendrilSink;
use markup5ever_rcdom::{Handle, NodeData, RcDom};
use std::time::{Duration, Instant};
use xdict_entry::{Entry, Style, entry_normalized_within};

const BASE: &str = "xdict://d/";
/// The handlers these inputs spell, split: an `on`-name the rewriter wrote whole (`on\u{E000}error`) runs nothing.
const HANDLERS: [&str; 3] = ["onerror", "onclick", "onload"];

/// The entry as the core serves it: the strip list on, an image named `gone.png` missing from the package.
fn rewrite(text: &str) -> String {
    let style = Style::of_sheets([]);
    let has = |p: &str| !p.contains("gone");
    let entry = Entry { key: "w", resource: Some(&has), is_key: None, strip_off_for_tests: false };
    entry_normalized_within(text, BASE, "", &style, &entry, usize::MAX).unwrap().0
}

/// What a browser would build from `html` that the rewriter must never let through: each a sentence.
fn assembled(html: &str) -> Vec<String> {
    let dom = html5ever::parse_document(RcDom::default(), html5ever::ParseOpts::default()).one(html);
    let mut found = Vec::new();
    walk(&dom.document, &mut found);
    found
}

fn walk(node: &Handle, found: &mut Vec<String>) {
    if let NodeData::Element { name, attrs, template_contents, .. } = &node.data {
        let local: &str = &name.local;
        if local.eq_ignore_ascii_case("script") {
            found.push(format!("a <script> element ({:?})", name.ns));
        }
        for a in attrs.borrow().iter() {
            let attr: &str = &a.name.local;
            let value: &str = &a.value;
            let lower = attr.to_ascii_lowercase();
            if HANDLERS.contains(&lower.as_str()) {
                found.push(format!("a handler {attr}={value:?} on <{local}>"));
            }
            let squeezed: String = value
                .trim_start_matches(|c: char| c <= ' ')
                .chars()
                .filter(|c| !matches!(c, '\t' | '\n' | '\r'))
                .collect::<String>()
                .to_ascii_lowercase();
            if squeezed.starts_with("javascript:") {
                found.push(format!("a javascript: URL in {attr} on <{local}>"));
            }
            if local == "meta" && lower == "http-equiv" {
                found.push("a <meta http-equiv>".to_owned());
            }
        }
        if local == "base" {
            found.push("a <base>".to_owned());
        }
        if let Some(t) = template_contents.borrow().as_ref() {
            walk(t, found);
        }
    }
    for c in node.children.borrow().iter() {
        walk(c, found);
    }
}

fn assert_clean(input: &str) {
    let out = rewrite(input);
    let found = assembled(&out);
    assert!(found.is_empty(), "{found:?}\n  input:  {input:?}\n  output: {out:?}");
}

/// A removed comment joins the text on either side.
#[test]
fn a_removed_comment_joins_nothing() {
    for input in [
        "<scr<!-- -->ipt>alert(1)</script>",
        "<<!---->script>alert(1)<<!---->/script>",
        "<<!-- x -->img src=x onerror=alert(1)>",
        "<img src=x on<!---->error=alert(1)>",
        "<a href=\"java<!---->script:alert(1)\">x</a>",
        "<a title='<!--'>x</a><img src=x title='-->' on<!---->error=alert(1)>",
        "<<!-->script>alert(1)</script>",
        "<<!--->script>alert(1)</script>",
        "<<!-- --!>script>alert(1)</script>",
        "a <!-- half open <img src=x onerror=alert(1)>",
    ] {
        assert_clean(input);
    }
}

/// Every piece the strip list removes, between `<` and a tag name.
#[test]
fn a_removed_element_joins_nothing() {
    for removed in [
        "<script>gtag('x')</script>",
        "<script>var a = 1</script>",
        "<meta charset=utf-8>",
        "<base href=x>",
        "<title>t</title>",
        "<html>",
        "</body>",
        "<head>",
        "<img src=\"gone.png\">",
        "<img src=\"icon.gif\" width=\"1\" height=\"1\">",
        "<?xml version='1.0'?>",
        "<!doctype html>",
    ] {
        assert_clean(&format!("<{removed}script>alert(1)</script>"));
        assert_clean(&format!("<{removed}img src=x onerror=alert(1)>"));
        assert_clean(&format!("<img src=x {removed}onerror=alert(1)>"));
    }
}

/// A missing image's `alt`, written as text, never closes or opens a tag.
#[test]
fn a_missing_images_alt_joins_nothing() {
    assert_clean("<<img src=\"gone.png\" alt=\"script\">>alert(1)</script>");
    assert_clean("<<img src=\"gone.png\" alt=\"img src=x onerror=alert(1)\">>");
}

/// Inside a speaker, the dictionary's private-use glyph is removed: nothing it separated may join.
#[test]
fn a_removed_glyph_joins_nothing() {
    for glyph in ["\u{E000}", "&#xE000;", "&#57344;", "&#xEA27"] {
        assert_clean(&format!("<a href=\"sound://a.mp3\">x<{glyph}script>alert(1)<{glyph}/script></a>"));
        assert_clean(&format!("<a href=\"sound://a.mp3\">x<{glyph}img src=x onerror=alert(1)></a>"));
    }
}

/// A raw-text or foreign context a tag scanner cannot follow: what the rewriter read as an attribute's value, a
/// stylesheet or a bogus comment must not become markup there.
#[test]
fn a_context_the_scanner_cannot_see_assembles_nothing() {
    for input in [
        "<noscript><p title=\"</noscript><img src=x onerror=alert(1)>\"></p></noscript>",
        "<xmp><p title=\"</xmp><img src=x onerror=alert(1)>\"></p></xmp>",
        "<textarea><p title=\"</textarea><img src=x onerror=alert(1)>\"></p></textarea>",
        "<iframe><p title=\"</iframe><img src=x onerror=alert(1)>\"></p></iframe>",
        "<noembed><p title=\"</noembed><img src=x onerror=alert(1)>\"></p></noembed>",
        "<svg><style><img src=x onerror=alert(1)></style></svg>",
        "<math><style><img src=x onerror=alert(1)></style></math>",
        "<noscript><style></noscript><img src=x onerror=alert(1)></style></noscript>",
        "<svg><![CDATA[ > <a title=\"]]><img src=x onerror=alert(1)>\">x</a> ]]></svg>",
        "<svg><desc><![CDATA[ > ]]><a title=\"]]><img src=x onerror=alert(1)>\">x</a></desc></svg>",
        "<template><p title=\"</template><img src=x onerror=alert(1)>\"></p></template>",
        "<plaintext><img src=x title=\"y\">",
        "<svg></math><style><img src=x onerror=alert(1)></style></svg>",
        "<svg><script/><img src=x onerror=alert(1)></script></svg>",
        "<noscript><script>toggle()</noscript><img src=x onerror=alert(1)></script></noscript>",
    ] {
        assert_clean(input);
    }
}

/// A kept script holding `<!--` and then `<script` would, to a browser, stay open past its `</script>` and run the
/// markup after it: the one script stays one, and what follows it is an element.
#[test]
fn a_kept_script_ends_where_the_rewriter_ends_it() {
    let out = rewrite("<script>toggle()<!--<script></script><b>after</b><script>x()</script>");
    let dom = html5ever::parse_document(RcDom::default(), html5ever::ParseOpts::default()).one(out.as_str());
    let mut scripts = Vec::new();
    collect_scripts(&dom.document, &mut scripts);
    assert_eq!(scripts.len(), 1, "{out:?}");
    assert!(!scripts[0].contains("after"), "{out:?}");
}

fn collect_scripts(node: &Handle, found: &mut Vec<String>) {
    if let NodeData::Element { name, .. } = &node.data
        && name.local.as_ref().eq_ignore_ascii_case("script")
    {
        let text = node
            .children
            .borrow()
            .iter()
            .filter_map(|c| match &c.data {
                NodeData::Text { contents } => Some(contents.borrow().to_string()),
                _ => None,
            })
            .collect();
        found.push(text);
    }
    for c in node.children.borrow().iter() {
        collect_scripts(c, found);
    }
}

/// XDict's own insertions (a speaker's marks and glyph, a table's marks, an unwrapped headword) land between tags,
/// never inside one, also when the record ends inside a tag.
#[test]
fn an_insertion_lands_outside_any_tag() {
    for input in [
        "<a href=\"sound://a.mp3\">\u{E000}</a><img src=x",
        "<a href=\"sound://a.mp3\"><img src=\"uk.png\"></a><a title=\"",
        "<table><tr><td>a</td><td>b</td></tr></table><img alt=\"",
        "<b>w</b><span title='",
    ] {
        assert_clean(input);
    }
}

/// A seeded walk over random interleavings of removable pieces, tag fragments, quotes and glyphs: deterministic,
/// and bounded by count and by time.
#[test]
fn random_interleavings_assemble_nothing() {
    const CASES: usize = 20_000;
    const BUDGET: Duration = Duration::from_secs(60);
    // Halves of the dangerous words: never whole in an input, so whole in a parse only if assembled.
    const HALVES: [(&str, &str); 6] = [
        ("<scr", "ipt>alert(1)</script>"),
        ("<", "script>alert(1)</script>"),
        ("<img src=x on", "error=alert(1)>"),
        ("<", "img src=x onerror=alert(1)>"),
        ("<a href=\"java", "script:alert(1)\">x</a>"),
        ("<meta http-", "equiv=refresh content=0>"),
    ];
    const REMOVED: [&str; 16] = [
        "<!---->",
        "<!-- x -->",
        "<!-->",
        "<!--->",
        "<!-- --!>",
        "<script>gtag()</script>",
        "<script></script>",
        "<title>t</title>",
        "<meta charset=x>",
        "<base href=y>",
        "<html>",
        "</body>",
        "<img src=\"gone.png\">",
        "<img src=\"gone.png\" alt=\"<\">",
        "\u{E000}",
        "&#xE000;",
    ];
    const NOISE: [&str; 24] = [
        "<",
        ">",
        "\"",
        "'",
        "=",
        " ",
        "/",
        "<!--",
        "-->",
        "<b>",
        "</b>",
        "<a href=\"sound://a.mp3\">",
        "</a>",
        "<svg>",
        "</svg>",
        "<noscript>",
        "</noscript>",
        "<textarea>",
        "<style>",
        "</style>",
        "<![CDATA[",
        "]]>",
        "<p title=\"",
        "<table><tr><td>",
    ];
    let mut seed: u64 = 0x5EED_0FA5_5E4B_1E00;
    let mut next = |n: usize| {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        usize::try_from(seed % n as u64).unwrap()
    };
    let started = Instant::now();
    let mut run = 0;
    while run < CASES && started.elapsed() < BUDGET {
        let mut input = String::new();
        for _ in 0..1 + next(8) {
            match next(3) {
                0 => {
                    let (a, b) = HALVES[next(HALVES.len())];
                    input.push_str(a);
                    for _ in 0..1 + next(2) {
                        input.push_str(REMOVED[next(REMOVED.len())]);
                    }
                    input.push_str(b);
                }
                1 => input.push_str(REMOVED[next(REMOVED.len())]),
                _ => input.push_str(NOISE[next(NOISE.len())]),
            }
        }
        assert_clean(&input);
        run += 1;
    }
    assert!(run >= 1000, "only {run} cases in the budget");
}
