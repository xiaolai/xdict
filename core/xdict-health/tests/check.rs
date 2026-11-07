//! The health check on dictionaries the test writer makes: each class the census found, counted where it is and
//! nowhere else. Every record here is written in the test, no dictionary's.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use std::sync::Arc;
use std::time::Instant;

use xdict_health::{Report, Stop, check, resource_key};
use xdict_lookup::Policy;
use xdict_mdx::{File, Kind};
use xdict_mdx_writer::{self as writer, Entry, Spec};

fn file(entries: &[(&str, &str)]) -> File {
    let entries: Vec<Entry> = entries.iter().map(|(k, v)| Entry::text(k, v)).collect();
    let bytes = writer::write(&Spec::mdx(), &entries).unwrap();
    let index = File::build_index(&bytes, Some(Kind::Mdx), [1; 32], &Policy).unwrap();
    File::with_index(Box::new(bytes), Some(Kind::Mdx), Box::new(index), [1; 32], Arc::new(Policy)).unwrap().unwrap()
}

fn report(entries: &[(&str, &str)]) -> Report {
    let held = ["\\a.css", "\\hello.mp3"].map(String::from);
    let has = |p: &str| held.contains(&resource_key(p));
    check(&file(entries), &has, &mut |_, _| true).unwrap()
}

#[test]
fn a_clean_edition_has_no_class_that_reports() {
    let r = report(&[("apple", "<b>apple</b> a fruit <a href=\"entry://pear\">pear</a>"), ("pear", "a fruit")]);
    assert_eq!(r.records, 2);
    let reported: Vec<&String> = r.classes.keys().collect();
    assert!(reported.is_empty(), "{reported:?}");
}

#[test]
fn links_count_broken_only_after_folding() {
    let r = report(&[
        ("abbé", "an abbot"),
        ("x", "<a href=\"entry://abbe\">a</a> <a href=\"entry://nowhere\">b</a> <a href=\"bword://none\">c</a>"),
    ]);
    assert_eq!(r.count("link.entry_missing_key"), 1);
    assert_eq!(r.count("link.bword_missing_key"), 1);
    assert_eq!(r.count("link.entry_found_by_folding"), 1);
    assert_eq!(r.classes["link.entry_missing_key"].examples[0].0, "x");
}

#[test]
fn oxford_lookup_links_are_links_not_files() {
    let r = report(&[("a", "x"), ("b", "<xhtml:a href=\"d:a\">a</xhtml:a><xhtml:a href=\"d:zz\">zz</xhtml:a>")]);
    assert_eq!(r.count("link.entry_missing_key"), 1);
    assert_eq!(r.count("link.other_missing_resource"), 0);
}

#[test]
fn missing_files_are_counted_and_named() {
    let r = report(&[
        ("a", "<link rel=stylesheet href=\"OED.css\"><link href=\"a.css\"><script src=\"OED.js\"></script>x"),
        (
            "b",
            "<link rel=stylesheet href=\"OED.css\"><a href=\"sound://hello.mp3\">s</a><a href=\"sound://gone.mp3\">s</a>",
        ),
        ("c", "<img src=\"pic.png\">"),
    ]);
    assert_eq!(r.count("link.stylesheet_missing_resource"), 2);
    assert_eq!(r.count("link.script_missing_resource"), 1);
    assert_eq!(r.count("link.sound_missing"), 1);
    assert_eq!(r.count("link.img_missing_resource"), 1);
    assert_eq!(r.missing_files.get("oed.css"), Some(&2));
    assert_eq!(r.missing_files.get("oed.js"), Some(&1));
    assert_eq!(r.missing_files.len(), 2);
}

#[test]
fn text_defects_and_what_the_render_repairs() {
    let r = report(&[
        ("a", "bulbs\u{85}which"),
        ("b", "x\u{feff}y\u{1}z"),
        ("c", "rated ★★★☆☆\\n"),
        ("d", "such\\n\\t\\ta"),
        ("e", "&lt;i&gt;A Title&lt;/i&gt;"),
    ]);
    assert_eq!(r.count("text.control_c1"), 1);
    assert_eq!(r.count("text.control_c0"), 1);
    assert_eq!(r.count("text.bom_inside"), 1);
    assert_eq!(r.count("text.literal_backslash_n"), 2);
    assert_eq!(r.count("text.repaired"), 4, "the C1, the BOM, the C0 and spring's \\n");
    assert_eq!(r.count("markup.escaped_tag_as_text"), 2);
}

#[test]
fn comment_marks_are_counted_never_mended() {
    let r = report(&[("a", "---> 甲 ---> 乙"), ("b", "<---线--->"), ("c", "a<!--note--b<!-- x -->c")]);
    assert_eq!(r.count("comment.stray_close"), 3);
    assert_eq!(r.count("comment.malformed_open_lt_dashes"), 1);
    assert_eq!(r.count("comment.nested"), 1);
}

#[test]
fn redirects_duplicates_and_keys() {
    let r = report(&[
        ("a", "@@@LINK=b"),
        ("b", "@@@LINK=a"),
        ("c", "@@@LINK=gone"),
        ("d", "@@@LINK=e"),
        ("e", "@@@LINK=f"),
        ("f", "an entry"),
        ("same", "one"),
        ("same", "one"),
        ("homograph", "noun"),
        ("homograph", "verb"),
        (" spaced", "x"),
        ("empty", ""),
    ]);
    assert_eq!(r.count("redirect.loop"), 2);
    assert_eq!(r.count("redirect.missing_target"), 1);
    assert_eq!(r.count("redirect.chained_ok"), 1);
    assert_eq!(r.count("key.duplicate_identical_records"), 1);
    assert_eq!(r.count("key.duplicate_differing_records"), 1);
    assert_eq!(r.count("key.edge_whitespace"), 1);
    assert_eq!(r.count("record.empty"), 1);
}

#[test]
fn a_cancelled_check_gives_no_report() {
    let entries: Vec<(String, String)> = (0..5000).map(|i| (format!("k{i:05}"), "x".into())).collect();
    let entries: Vec<(&str, &str)> = entries.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
    let f = file(&entries);
    let mut asked = Vec::new();
    let got = check(&f, &|_| false, &mut |done, total| {
        asked.push((done, total));
        false
    });
    assert!(matches!(got, Err(Stop::Cancelled)), "{got:?}");
    assert_eq!(asked, [(4096, 5000)], "asked once, after the first chunk");
}

/// Every check is linear in the record: hostile shapes take, per byte, no longer at eight times the size.
#[test]
fn the_check_is_linear_on_hostile_records() {
    let shapes = ["<script ", "--> ", "<b><b></i>", "{ a:b; ", "&lt;b&gt;", "<a href=\"entry://w\">", "\u{1}\\n "];
    for shape in shapes {
        let time = |n: usize| {
            let record = format!("{}}}<!--", shape.repeat(n));
            let f = file(&[("k", &record)]);
            let mut best = f64::MAX;
            for _ in 0..3 {
                let t = Instant::now();
                check(&f, &|_| false, &mut |_, _| true).unwrap();
                best = best.min(t.elapsed().as_secs_f64());
            }
            best
        };
        let small = time(4_000);
        let large = time(32_000);
        assert!(large < small * 8.0 * 3.0, "{shape:?}: 8x the input took {:.1}x the time", large / small);
    }
}

/// **A redirect is classed as the lookup follows it** (audit 2026-11-05, L8): the same walk `resolve` makes, with
/// its hop limit, so a chain a reader's click reaches is not reported too deep, and one past the lookup's limit is.
#[test]
fn redirect_chains_are_classed_by_the_lookups_own_walk() {
    let chain = |n: usize| -> Vec<(String, String)> {
        let mut entries: Vec<(String, String)> =
            (0..n).map(|i| (format!("r{i:02}"), format!("@@@LINK=r{:02}", i + 1))).collect();
        entries.push((format!("r{n:02}"), "the entry".into()));
        entries
    };
    let borrowed = |entries: &[(String, String)]| -> Report {
        let entries: Vec<(&str, &str)> = entries.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
        report(&entries)
    };
    let six = borrowed(&chain(6));
    assert_eq!(six.count("redirect.chain_too_deep"), 0, "six hops reach the entry by lookup's walk: {six:?}");
    assert_eq!(six.count("redirect.chained_ok"), 5, "every redirect but the last passes through another");
    let long = borrowed(&chain(xdict_lookup::HOPS + 2));
    assert!(long.count("redirect.chain_too_deep") > 0, "past the lookup's hops: {long:?}");
    // Broken is what a reader's lookup reaches nothing through; a dead end or a loop beside an entry reached is not.
    let mixed = report(&[
        ("a", "@@@LINK=gone\r\n@@@LINK=b"),
        ("b", "an entry"),
        ("gone2", "@@@LINK=nowhere"),
        ("p", "@@@LINK=q"),
        ("q", "@@@LINK=p"),
        ("self", "@@@LINK=self"),
        ("x", "@@@LINK=y"),
        ("y", "@@@LINK=x\r\n@@@LINK=b"),
    ]);
    assert_eq!(mixed.count("redirect.missing_target"), 1, "only gone2 reaches nothing: {mixed:?}");
    assert_eq!(mixed.count("redirect.loop"), 2, "p and q reach nothing but each other: {mixed:?}");
    assert_eq!(mixed.count("redirect.to_itself"), 1, "{mixed:?}");
    assert_eq!(mixed.count("redirect.chained_ok"), 1, "x reaches b through y, past y's loop back: {mixed:?}");
}

/// **The chain pass reports progress and stops when told to** (audit 2026-11-05, L8): it runs after every record is
/// read, and may follow a million redirects; a cancel then was ignored and a report returned.
#[test]
fn the_chain_pass_can_be_cancelled() {
    let f = file(&[("a", "@@@LINK=b"), ("b", "an entry")]);
    let mut calls = 0;
    let got = check(&f, &|_| false, &mut |done, total| {
        calls += 1;
        assert!(done <= total, "{done} of {total}");
        calls == 1
    });
    assert!(matches!(got, Err(Stop::Cancelled)), "a cancel during the chains gave {got:?}");
}

/// **The walk is counted on after the records** (2026-11-05, found by the macOS service's health test on the merged
/// tree): the record pass reports records done of all; the walk then reports records plus redirects walked, of records
/// plus redirects, after each of its chunks and after the last partial one, never before any work; with no redirect it
/// reports nothing, so the record pass's last report stands and a reader's bar never sits at the end while the walk runs.
#[test]
fn the_walk_is_counted_after_the_records() {
    let f = file(&[("a", "@@@LINK=b"), ("b", "an entry"), ("c", "@@@LINK=nowhere")]);
    let mut heard = Vec::new();
    let report = check(&f, &|_| false, &mut |done, total| {
        heard.push((done, total));
        true
    })
    .unwrap_or_else(|stop| panic!("{stop:?}"));
    assert_eq!(heard, vec![(3, 3), (5, 5)], "the records, then the walk of two redirects: {heard:?}");
    assert_eq!(report.count("redirect.missing_target"), 1, "{report:?}");
    let plain = file(&[("a", "an entry"), ("b", "another")]);
    let mut heard = Vec::new();
    check(&plain, &|_| false, &mut |done, total| {
        heard.push((done, total));
        true
    })
    .unwrap_or_else(|stop| panic!("{stop:?}"));
    assert_eq!(heard, vec![(2, 2)], "no redirect, no walk report: {heard:?}");
}
