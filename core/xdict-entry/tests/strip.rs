//! The element sweep's strip list (`dev-docs/element-sweep.md` §2.4, S1–S15) and the owner's Q6, as the core
//! applies them while it normalizes an entry. Every entry here is written in the test, no dictionary's.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use xdict_entry::{
    Counts, Style, css_normalized_within, css_styled_within, html_normalized_within, html_styled_within, script_purpose,
};

const BASE: &str = "xdict://d/";

fn html(text: &str, style: &Style) -> String {
    let (out, counts) = html_normalized_within(text, BASE, "", style, usize::MAX).unwrap();
    same_strips_in_original_style(text, style, &counts);
    out
}

fn counts(text: &str, style: &Style) -> Counts {
    let counts = html_normalized_within(text, BASE, "", style, usize::MAX).unwrap().1;
    same_strips_in_original_style(text, style, &counts);
    counts
}

/// ADR-0010 Q3 and ADR-0007 decision 14: "Original style" drops the normalization and nothing of the strip list.
/// Every case here is also rendered in it, and must strip exactly what the reading style strips.
fn same_strips_in_original_style(text: &str, style: &Style, normalized: &Counts) {
    let original = html_styled_within(text, BASE, "", style, false, true, usize::MAX).unwrap().1;
    assert_eq!(original.strip, normalized.strip, "{text}");
}

fn plain() -> Style {
    Style::of_sheets([])
}

/// S1 and Q6: a tracker's or an ad's script goes, and the slot it leaves empty with it.
#[test]
fn s1_ad_and_tracker_scripts_go() {
    let s = plain();
    let out = html(r#"<div class="slot"><script>googletag.cmd.push(function(){});</script></div>x"#, &s);
    assert_eq!(out, "x");
    assert_eq!(counts(r#"<script>gtag('config','x')</script>"#, &s).strip.scripts_tracker, 1);
}

/// Q6: a script that makes something work (a fold, a tab) is kept; one that only plays audio, and the rest, go.
#[test]
fn q6_only_scripts_that_make_something_work_are_kept() {
    let s = plain();
    let fold = "<script>function t(e){e.nextSibling.style.display='none'}</script>";
    assert_eq!(html(fold, &s), fold);
    assert_eq!(html("a<script>new Audio('a.mp3').play()</script>b", &s), "ab");
    assert_eq!(html("a<script>var x = 1;</script>b", &s), "ab");
    let mut with_file = Style::of_sheets([]);
    with_file.add_scripts(["function ode(){ $('.tile').toggle() }"]);
    assert_eq!(html("<script>ode();</script>", &with_file), "<script>ode();</script>", "it starts a kept script");
    assert_eq!(html("<script>ode();</script>", &s), "", "nothing kept defines it");
    let external = r#"<script src="a.js"></script>"#;
    assert!(html(external, &s).contains("<script src="), "a file is judged when it is served");
    assert_eq!(script_purpose("function f(){document.getElementById('a').classList.toggle('open')}"), Ok("fold"));
    assert_eq!(script_purpose("$('.tab').click(function(){ show(this) })"), Ok("fold"));
    assert!(script_purpose("var s = new Audio(u); s.play();").is_err());
    assert!(script_purpose("(adsbygoogle = window.adsbygoogle || []).push({})").is_err());
}

/// S2: comments go.
#[test]
fn s2_comments_go() {
    let s = plain();
    assert_eq!(html("a<!-- note -->b<!---->c", &s), "abc");
    assert_eq!(counts("a<!-- x -->b", &s).strip.comments, 1);
}

/// S3: a record's document wrappers go: `head` is unwrapped, `meta`, `base` and `title` dropped.
#[test]
fn s3_document_wrappers_go() {
    let s = plain();
    let out = html(
        r#"<head><meta charset="utf-8"><title>t</title><base href="x"><link rel="stylesheet" href="a.css"></head><p>x</p>"#,
        &s,
    );
    assert_eq!(out, r#"<link rel="stylesheet" href="xdict://d/r/a.css"><p>x</p>"#);
}

/// S4: `<x/>` on an element that is not void is closed, as its author meant; inside SVG it already is.
#[test]
fn s4_self_closed_elements_are_closed() {
    let s = plain();
    assert_eq!(html(r#"<b>a</b><span class="k"/>b"#, &s), r#"<b>a</b>b"#, "closed, then empty, then gone");
    assert_eq!(html(r#"<span id="k"/>b"#, &s), r#"<span id="k"></span>b"#);
    assert_eq!(html(r#"<svg><path d="M0"/></svg>"#, &s), r#"<svg><path d="M0"/></svg>"#);
    assert_eq!(html("a<br/>b", &s), "a<br/>b");
}

/// S5: audio hidden in a `data-*` attribute, or in a handler's `new Audio('…')`, becomes a sound link; the handler
/// that played it goes.
#[test]
fn s5_audio_in_attributes_becomes_a_sound_link() {
    let s = plain();
    let out = html(r#"<img data-src-mp3="snd/a.mp3" src="uk.png">"#, &s);
    assert!(out.starts_with(r#"<a href="xdict://d/sound/snd/a.mp3" data-xdict-control="speaker""#), "{out}");
    assert!(out.ends_with(r#"<img data-src-mp3="snd/a.mp3" src="xdict://d/r/uk.png"></a>"#), "{out}");
    let out = html(r#"<span class="p" onclick="new Audio('b.mp3').play()">x</span>"#, &s);
    assert!(out.contains(r#"<a href="xdict://d/sound/b.mp3""#), "{out}");
    assert!(!out.contains("onclick"), "the handler goes: {out}");
    let out =
        html(r#"<a class="p" data-mp3="c.mp3" onclick="new Audio(this.getAttribute('data-mp3')).play()">x</a>"#, &s);
    assert!(out.starts_with(r#"<a href="xdict://d/sound/c.mp3" data-xdict-control="speaker""#), "{out}");
    let fold = r#"<span onclick="toggle(this)">more</span>"#;
    let marked = r#"<span data-xdict-control="disclosure" onclick="toggle(this)">more</span>"#;
    assert_eq!(html(fold, &s), marked, "a fold's handler stays (and it is marked a fold control)");
}

/// S5 never puts a link inside a link: an image whose attribute names a recording, inside a sound link already, is that
/// link's drawing. HTML does not nest `<a>`, so a parser closes the outer link at the inner one, and the reader saw a
/// second speaker, raised above the line (MED's `<a href="sound://…"><img data-src-mp3="https://…" src="uk.png"></a>`,
/// 30 of 40 sampled entries; the gallery sweep of 2026-10-17).
#[test]
fn s5_never_wraps_an_image_already_in_a_link() {
    let s = plain();
    for inner in [
        r#"<img data-src-mp3="https://example.com/a.mp3" src="uk.png">"#,
        r#"<img data-src-mp3="snd/a.mp3" src="uk.png">"#,
    ] {
        let out = html(&format!(r#"<span class="p"><a href="sound://a_uk.mp3">{inner}</a></span>"#), &s);
        assert_eq!(out.matches("<a ").count(), 1, "a link inside a link: {out}");
        assert_eq!(out.matches("data-xdict-icon=\"speaker\"").count(), 1, "one speaker: {out}");
    }
}

/// AHD's pronunciation key in Minion's Private Use Area (`<span class="MinionNew">` U+E01F, U+E013, U+E012; 595 of 839
/// sampled entries) has no glyph on a Mac, so the reader saw boxes. Written as Unicode: U+E013 o͞o and U+E012 o͝o (the
/// tie bars above), U+E01F the primary stress, a bold prime, beside the light prime AHD writes for secondary stress.
/// A Private Use character outside that markup is the dictionary's and stays.
#[test]
fn minion_private_use_is_written_as_unicode() {
    let s = plain();
    let out = html(
        "(lə-k<span class=\"MinionNew\">\u{e013}</span><span class=\"MinionNew\">\u{e01f}</span>nə, \
         w<span class=\"MinionNew\">\u{e012}</span>m)",
        &s,
    );
    assert!(!out.chars().any(|c| ('\u{e000}'..='\u{f8ff}').contains(&c)), "Private Use left: {out}");
    assert!(out.contains("o\u{35e}o"), "{out}");
    assert!(out.contains("o\u{35d}o"), "{out}");
    assert!(out.contains("<b>\u{2032}</b>"), "{out}");
    let other = html("<span class=\"icon\">\u{e01f}</span>", &s);
    assert!(other.contains('\u{e01f}'), "{other}");
}

/// S6: a `javascript:` link does nothing: its `href` goes, its text stays.
#[test]
fn s6_javascript_links_are_unlinked() {
    let s = plain();
    assert_eq!(html(r#"<a href="javascript:void(0)" class="x">see</a>"#, &s), r#"<a class="x">see</a>"#);
    assert_eq!(html(r#"<a href=" JavaScript:f()">see</a>"#, &s), "<a>see</a>");
}

/// S9: the element that wraps every entry, hidden until a script reveals it, is shown.
#[test]
fn s9_an_entry_hidden_until_its_script_runs_is_shown() {
    let sheet = "w{display:none;float:left} w.js_loaded{display:block} .x{display:none}";
    let s = Style::of_edition([sheet], ["<link href=a.css><w hw=a><b>a</b></w>", "<w><b>b</b></w>"]);
    let out = css_normalized_within(sheet, BASE, "", &s, usize::MAX).unwrap().0;
    assert_eq!(out, "w{float:left} w.js_loaded{display:block} .x{display:none}");
    // In "Original style" too: S9 is the strip list's, not the reading style's.
    let original = css_styled_within(sheet, BASE, "", &s, true, usize::MAX).unwrap().0;
    assert_eq!(original, "w{float:left} w.js_loaded{display:block} .x{display:none}");
}

/// S10: an element that draws nothing (empty or blank, no id, no rule draws it, no script names it) goes; its
/// spaces stay.
#[test]
fn s10_empty_elements_that_draw_nothing_go() {
    let s = plain();
    assert_eq!(html("a<span class=\"x\"></span>b<i> </i>c<em><b></b></em>d", &s), "ab cd");
    assert_eq!(
        html(r#"<span id="k"></span><a name="n"></a><td></td>"#, &s),
        r#"<span id="k"></span><a name="n"></a><td></td>"#
    );
    let drawn = Style::of_sheets([".dot::before{content:'*'} .js-fill{color:red}"]);
    assert_eq!(html(r#"<span class="dot"></span>"#, &drawn), r#"<span class="dot"></span>"#);
    let mut named = Style::of_sheets([]);
    named.add_scripts(["document.querySelector('.infl').textContent = x"]);
    assert_eq!(html(r#"<span class="infl"></span>"#, &named), r#"<span class="infl"></span>"#);
    assert_eq!(counts("<i></i><b> </b>", &s).strip.empty, 2);
}

/// S11: a hidden copy of a visible sibling's text goes.
#[test]
fn s11_hidden_duplicates_go() {
    let s = plain();
    let t = "words that say the same thing";
    let out = html(&format!(r#"<div><p>{t}</p><p style="display:none">{t}</p></div>"#), &s);
    assert_eq!(out, format!("<div><p>{t}</p></div>"));
    let folded = format!(r#"<div><p>{t}</p><p style="display:none">other words, folded away</p></div>"#);
    assert_eq!(html(&folded, &s), folded, "a fold is content");
}

/// S12: `<<word>>` is a cross-reference a browser would read as a tag; it becomes a link to the word.
#[test]
fn s12_double_angle_references_become_links() {
    let s = plain();
    assert_eq!(html("see ↑<<an>> and", &s), r#"see ↑<a href="xdict://d/entry/an">an</a> and"#);
    // The first `<` starts no tag: it is text, written `&lt;` so no removal can join it to what follows.
    assert_eq!(html("<<b>x</b>", &s), "&lt;<b>x</b>", "a tag after `<` is a tag");
}

/// S14: an image whose data arrives in another attribute gets it as its `src`.
#[test]
fn s14_base64_images_get_their_src() {
    let s = plain();
    let out = html(r#"<img class="pic" base64="data:image/png;base64,AAAA" src="">"#, &s);
    assert_eq!(out, r#"<img class="pic" src="data:image/png;base64,AAAA">"#);
}
