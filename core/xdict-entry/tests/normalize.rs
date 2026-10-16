//! ADR-0010 decision 2: every dictionary's CSS normalized in the passes that rewrite its URLs. Each rule has its
//! test here; the sheets are written in the test, no dictionary's.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use xdict_entry::{
    BaseFrom, Counts, KeptReason, Style, TOKENS, Transcriptions, css_normalized_within, html_normalized_within,
};

const BASE: &str = "xdict://d/";

fn css(text: &str, style: &Style) -> String {
    css_normalized_within(text, BASE, "", style, usize::MAX).unwrap().0
}

fn html(text: &str, style: &Style) -> String {
    html_normalized_within(text, BASE, "", style, usize::MAX).unwrap().0
}

fn counts(text: &str, style: &Style) -> Counts {
    css_normalized_within(text, BASE, "", style, usize::MAX).unwrap().1
}

fn plain() -> Style {
    Style::of_sheets([])
}

const TEXT: &str = "var(--xdict-text, #1d1d1f)";
const FONT: &str = "var(--xdict-font)";

/// R2: `!important` goes only where the frame must win (the page, an image's size, what is dropped); folding's
/// `display:none !important` keeps it.
#[test]
fn important_is_removed_only_where_the_frame_must_win() {
    let s = plain();
    assert_eq!(css(".a{display:none !important}", &s), ".a{display:none !important}");
    assert_eq!(css(".a{float:left!IMPORTANT}", &s), ".a{float:left!IMPORTANT}");
    assert_eq!(css("img{max-width:none!important;width:5000px !important}", &s), "img{max-width:none;width:5000px}");
    assert_eq!(css("body{display:none !important}", &s), "body{}");
    assert_eq!(css(".a{zoom:2 !important;display:block}", &s), ".a{display:block}");
    assert_eq!(css(r#".a{content:"!important"}"#, &s), r#".a{content:"!important"}"#, "a string is text");
    assert_eq!(counts("img{width:1px !important} .b{display:none !important}", &s).important, 1);
}

/// R1: the page keeps only what cannot hurt it; `display`, `zoom`, `filter` and the rest are the frame's.
#[test]
fn the_page_belongs_to_the_frame() {
    let s = plain();
    assert_eq!(css("html{display:none} body{zoom:5;filter:invert(1);margin:-9999px;opacity:0}", &s), "html{} body{}");
    assert_eq!(
        css(":root{--accent:#c00;word-wrap:break-word;color:red}", &s),
        ":root{--accent:#c00;word-wrap:break-word}"
    );
    assert_eq!(css("html, body { width:600px; overflow:auto }", &s), "html, body {}");
    // Only the page: what is inside it, or shares the rule with it, keeps its own.
    assert_eq!(css("body .x{display:none}", &s), "body .x{display:none}");
    assert_eq!(css(".body{display:none}", &s), ".body{display:none}");
    assert_eq!(html(r#"<body style="margin:0;display:block">x</body>"#, &s), "x", "a record's own body goes");
    assert_eq!(html("<HTML><Body bgcolor=black text=black><p>x</p></BODY></html>", &s), "<p>x</p>");
    assert_eq!(html("<bodyx>y</bodyx>", &s), "<bodyx>y</bodyx>");
}

/// R3: every family is XDict's, monospace is XDict's monospace, a Unicode IPA face is XDict's IPA face.
#[test]
fn a_font_family_becomes_xdicts() {
    let s = plain();
    assert_eq!(css(r#".a{font-family:"Open Sans", serif}"#, &s), format!(".a{{font-family:{FONT}}}"));
    assert_eq!(css(".a{font-family: inherit}", &s), ".a{font-family: inherit}");
    assert_eq!(css(".a{font-family:Courier, monospace}", &s), ".a{font-family:var(--xdict-font-mono)}");
    assert_eq!(css(".a{font-family:'Gentium Plus'}", &s), ".a{font-family:var(--xdict-font-phon)}");
    // Only a list that asks first for an IPA face is IPA: a wide-coverage face as a fallback is a prose list (MWU's
    // `.container{font-family:"Lucida Grande","Lucida Sans Unicode"}` set its whole entry in the IPA face).
    assert_eq!(
        css(r#".container{font-family:"Lucida Grande", "Lucida Sans Unicode", sans-serif}"#, &s),
        format!(".container{{font-family:{FONT}}}")
    );
    assert_eq!(
        css(r#".uni{font-family:"Lucida Sans Unicode", Arial}"#, &s),
        ".uni{font-family:var(--xdict-font-phon)}"
    );
    assert_eq!(counts(".a{font-family:A}.b{font-family:B}", &s).family, 2);
    // A face no kept rule uses is not loaded.
    assert_eq!(css("@font-face{font-family:Optima;src:url(o.ttf)}", &s), "@font-face{}");
}

/// R3.1: an icon face is kept only on the rule that draws the glyph, never on the element around it.
#[test]
fn an_icon_face_is_kept_only_where_it_draws() {
    let sheet =
        r#"@font-face{font-family:"Dict Icons";src:url(i.ttf)} .i:before{font-family:"Dict Icons";content:"\e900"}"#;
    let s = Style::of_sheets([sheet]);
    let kept = s.kept();
    assert_eq!(
        (kept[0].family.as_str(), kept[0].reason, kept[0].selector.as_str()),
        ("Dict Icons", KeptReason::PrivateUse, ".i:before")
    );
    // Its glyph is dropped (the icon sweep's §7.6, the owner's answers in ADR-0010): XDict's control or label draws
    // what it meant.
    let out = css(sheet, &s);
    assert!(
        out.starts_with(r#"@font-face{font-family:"Dict Icons";src:url("xdict://d/r/i.ttf")} .i:before{"#),
        "{out}"
    );
    assert!(!out.contains("content"), "{out}");
    assert_eq!(css(".i{font-family:'dict icons'}", &s), format!(".i{{font-family:{FONT}}}"));
    let s = Style::of_sheets([
        r#"@font-face{font-family:Marks;src:url(m.woff)} .m::after{content:"\2731";font-family:Marks}"#,
    ]);
    let out = css(r#".m::after{content:"\2731";font-family:Marks}"#, &s);
    assert!(out.starts_with(".m::after{") && out.contains("font-family:Marks") && !out.contains("content"), "{out}");
    assert_eq!(css(".m{font-family:Marks}", &s), format!(".m{{font-family:{FONT}}}"));
    // A prose face drawing letters, digits or punctuation is not an icon face (OALECD's Optima drew the "/" around
    // its transcriptions, ODE's ODESans a bullet): it is not kept, there or anywhere.
    for content in [r#""/""#, r#""\2022""#, r#"" (""#, r#""1.""#, "counter(n)"] {
        let s = Style::of_sheets([format!(
            "@font-face{{font-family:Optima;src:url(o.ttf)}} .p:after{{content:{content};font-family:Optima}}"
        )
        .as_str()]);
        assert!(s.kept().is_empty(), "{content}: {:?}", s.kept());
    }
}

/// R3.2: an ASCII-mapped phonetic face is kept wherever it is used, and its runs marked.
#[test]
fn an_ascii_phonetic_face_is_kept() {
    let s = Style::of_sheets([
        r#"@font-face{font-family:"Kingsoft Phonetic Plain";src:url(k.ttf)} .x{font-family:"Kingsoft Phonetic Plain"}"#,
        "@font-face{font-family:Gentium;src:url(g.ttf)} span.phon{font-family:Gentium}",
    ]);
    let kept: Vec<_> = s.kept().iter().map(|k| (k.family.as_str(), k.reason)).collect();
    assert_eq!(kept, [("Gentium", KeptReason::Phonetic), ("Kingsoft Phonetic Plain", KeptReason::Phonetic)]);
    assert_eq!(css(".y{font-family:'Kingsoft Phonetic Plain'}", &s), ".y{font-family:'Kingsoft Phonetic Plain'}");
    assert_eq!(
        css(".y{font-family:Gentium}", &s),
        ".y{font-family:var(--xdict-font-phon)}",
        "Unicode IPA: XDict's face"
    );
    let s = Style::of_sheets(["@font-face{font-family:Book;src:url(b.ttf)} .principal{font-family:Book}"]);
    assert!(s.kept().is_empty(), "{:?}", s.kept());
}

/// R4: every size is on the scale: absolute ones by their ratio to the base, relative ones clamped.
#[test]
fn sizes_go_onto_the_scale() {
    let s = Style::of_sheets(["body{font-size:16px}"]);
    assert_eq!(s.base().px, 16.0);
    assert_eq!(css(".a{font-size:16px}", &s), ".a{font-size:var(--xdict-fs-m, 1rem)}");
    assert_eq!(css(".a{font-size: 9pt}", &s), ".a{font-size: var(--xdict-fs-xs, 0.75rem)}");
    assert_eq!(css(".a{font-size:small}", &s), ".a{font-size:var(--xdict-fs-s, 0.875rem)}");
    assert_eq!(
        css(".a{font-size:80PX}", &s),
        ".a{font-size:var(--xdict-fs-xxl, 1.5rem);line-height:var(--xdict-leading-tight, 1.3)}"
    );
    assert_eq!(
        css(".a{font-size:90%}", &s),
        ".a{font-size:clamp(var(--xdict-fs-min, .75rem), 0.875em, var(--xdict-fs-max, 1.5rem))}"
    );
    assert_eq!(
        css(".a{font-size:2em}", &s),
        ".a{font-size:clamp(var(--xdict-fs-min, .75rem), 1.5em, var(--xdict-fs-max, 1.5rem));line-height:var(--xdict-leading-tight, 1.3)}"
    );
    for kept in [".a{font-size:0}", ".a{font-size:calc(2px + 1em)}", ".a{font-size:inherit}"] {
        assert_eq!(css(kept, &s), kept);
    }
    assert_eq!(counts(".a{font-size:12px}.b{font-size:1em}", &s).size, 2);
}

/// R5: line heights are the frame's, except where a rule sets a height (a centring trick), kept there in `em`.
#[test]
fn line_heights_are_dropped() {
    let s = Style::of_sheets(["body{font-size:16px}"]);
    assert_eq!(css(".a{line-height:30px;color:inherit}", &s), ".a{color:inherit}");
    assert_eq!(css(".b{line-height:1.4}", &s), ".b{}");
    assert_eq!(css(".c{height:20px;line-height:20px}", &s), ".c{height:20px;line-height:1.25em}");
    assert_eq!(css(".c{height:9px;line-height:9px}", &s), ".c{height:9px;line-height:1em}", "below 1 would overlap");
    assert_eq!(counts(".b{line-height:21px}", &s).line_height, 1);
}

#[test]
fn the_font_shorthand_is_normalized_part_by_part() {
    let s = Style::of_sheets(["body{font-size:12px}"]);
    assert_eq!(
        css(".a{font:bold 12px/18px Arial, sans-serif}", &s),
        format!(".a{{font:var(--xdict-weight-bold, 600) var(--xdict-fs-m, 1rem) {FONT}}}")
    );
    assert_eq!(
        css(".a{font:italic 1em Arial}", &s),
        format!(".a{{font:italic clamp(var(--xdict-fs-min, .75rem), 1em, var(--xdict-fs-max, 1.5rem)) {FONT}}}")
    );
    assert_eq!(css(".a{font:caption}", &s), ".a{font:caption}");
}

/// R6: one bold; thin is regular; oblique is italic.
#[test]
fn weights_and_styles_are_xdicts() {
    let s = plain();
    assert_eq!(css(".a{font-weight:bold}", &s), ".a{font-weight:var(--xdict-weight-bold, 600)}");
    assert_eq!(css(".a{font-weight:300}", &s), ".a{font-weight:400}");
    assert_eq!(css(".a{font-weight:normal;font-style:oblique 10deg}", &s), ".a{font-weight:normal;font-style:italic}");
}

/// R7: vertical spacing on the space steps; horizontal spacing as written.
#[test]
fn vertical_spacing_goes_onto_the_steps() {
    let s = Style::of_sheets(["body{font-size:16px}"]);
    assert_eq!(css(".a{margin-top:4em}", &s), ".a{margin-top:var(--xdict-space-5, 1.5rem)}");
    assert_eq!(css(".a{padding-bottom:8px}", &s), ".a{padding-bottom:var(--xdict-space-2, 0.5rem)}");
    assert_eq!(css(".a{margin:12px 2em 0 1em}", &s), ".a{margin:var(--xdict-space-3, 0.75rem) 2em 0 1em}");
    assert_eq!(
        css(".a{margin:4px 1em}", &s),
        ".a{margin:var(--xdict-space-1, 0.25rem) 1em var(--xdict-space-1, 0.25rem)}"
    );
    assert_eq!(css(".a{margin-top:-0.07em}", &s), ".a{margin-top:0}");
    assert_eq!(css(".a{margin-top:-0.5em}", &s), ".a{margin-top:calc(-1 * var(--xdict-space-2, 0.5rem))}");
    assert_eq!(css(".a{margin-top:-3em}", &s), ".a{margin-top:0}");
    for kept in [".a{margin-left:2em}", ".a{margin:0 auto}", ".a{margin-top:5%}"] {
        assert_eq!(css(kept, &s), kept);
    }
}

/// Layout is kept.
#[test]
fn layout_is_kept() {
    let s = plain();
    let kept = ".a{display:none;float:left;position:absolute;width:30px;color:inherit;transition:all 1s}";
    assert_eq!(css(kept, &s), kept);
    assert_eq!(counts(kept, &s), Counts::default());
}

/// §4: every colour becomes a palette token, in every place a dictionary writes one.
#[test]
fn colours_become_palette_tokens() {
    let s = plain();
    assert_eq!(
        css(".a{color:#c00000} .b{color:navy}", &s),
        ".a{color:var(--xdict-red, #af342f)} .b{color:var(--xdict-blue-deep, #02489f)}"
    );
    assert_eq!(css(".c{color:transparent}", &s), ".c{color:transparent}");
    // A chip loses its band, and its white text takes the band's family, so the label keeps its meaning.
    assert_eq!(css(".d{color:white;background:#602090}", &s), ".d{color:var(--xdict-purple-deep, #622c91)}");
    assert_eq!(
        html(r#"<span style="color:rgb(0,0,0)">x</span>"#, &s),
        format!(r#"<span style="color:{TEXT}">x</span>"#)
    );
    assert_eq!(
        html("<style>.e{color:hsl(0,100%,25%)}</style>", &s),
        "<style>.e{color:var(--xdict-red-deep, #901114)}</style>"
    );
    assert_eq!(counts(".a{color:red;background:#eee}", &s).colour, 1);
}

/// Plain by default (the owner, 2026-10-15): every background, border, outline and shadow goes; the frame's surface
/// is the only background. Decorative images and CSS images go; content images stay; undecided ones are reported.
#[test]
fn entries_are_plain() {
    let s = plain();
    assert_eq!(
        css(
            ".a{background:#fff8dc url(x.png) !important;background-image:linear-gradient(red,blue);border:1px solid navy;border-bottom:0;outline:1px dotted;box-shadow:0 0 2px #000;text-shadow:1px 1px red;display:block}",
            &s
        ),
        ".a{display:block}"
    );
    assert_eq!(css(r#".b::before{content:url(speaker.png);margin-left:2px}"#, &s), ".b::before{margin-left:2px}");
    assert_eq!(html(r##"<td bgcolor="#fff8dc" background="x.png">x</td>"##, &s), "<td>x</td>");
    assert_eq!(html(r#"x <img src="img/icon_uk.png"> y"#, &s), "x  y");
    assert_eq!(html("<img src=a.png width=12 height=12>", &s), "");
    assert_eq!(html("<img src=pics/skate.jpg>", &s), r#"<img src="xdict://d/r/pics/skate.jpg">"#);
    assert_eq!(
        html("<a href=sound://a.mp3><img src=icon_sp.png></a>", &s),
        r#"<a data-xdict-control="speaker" data-xdict-control-mode="replace" href="xdict://d/sound/a.mp3"><span data-xdict-icon="speaker" aria-hidden="true"></span><img src="xdict://d/r/icon_sp.png"></a>"#,
        "a control is left for §5"
    );
    let (_, c) =
        html_normalized_within("<img src=x.png><img src=icon.png><img src=a.jpg>", BASE, "", &s, usize::MAX).unwrap();
    assert_eq!((c.images_dropped, c.images_kept), (1, 1));
    assert_eq!(c.images_undecided.iter().collect::<Vec<_>>(), ["x.png"]);
}

/// R22: presentational attributes become the element's style; dropped ones go.
#[test]
fn presentational_html_becomes_style() {
    let s = plain();
    assert_eq!(
        html(r##"<font color="#c00000" size=2 face="Times">x</font>"##, &s),
        format!(
            r#"<font style="color:var(--xdict-red, #af342f);font-size:var(--xdict-fs-s, 0.875rem);font-family:{FONT}">x</font>"#
        )
    );
    assert_eq!(html("<font size=+2>x</font>", &s), r#"<font style="font-size:var(--xdict-fs-xl, 1.25rem)">x</font>"#);
    assert_eq!(
        html(r#"<td bgcolor=white style="color:red">x</td>"#, &s),
        r#"<td style="color:var(--xdict-red, #af342f)">x</td>"#
    );
    assert_eq!(html("<p align=center>x</p>", &s), r#"<p style="text-align:center">x</p>"#);
    assert_eq!(html("<img align=left src=a.png border=0>", &s), r#"<img src="xdict://d/r/a.png" style="float:left">"#);
    assert_eq!(
        html("<table border=1 cellspacing=0 width=500><tr><td width=50>x</td></tr></table>", &s),
        r#"<table data-xdict-table="layout"><tr><td>x</td></tr></table>"#
    );
    // Q9: a rule is a gap, never a line, whatever draws it: the UA's border, an attribute or the element's own style
    // (AHD, NCECD, OED). A sheet's class rule loses to the inline gap.
    let gap = "border:0;height:0;margin-block:var(--xdict-space-3, 0.75rem)";
    assert_eq!(html("<hr color=red size=2 noshade>", &s), format!(r#"<hr style="{gap}">"#));
    assert_eq!(html(r#"<hr align="left" width="25%"/>"#, &s), format!(r#"<hr style="{gap}"/>"#));
    assert_eq!(html(r#"<hr class="t">"#, &s), format!(r#"<hr class="t" style="{gap}">"#));
    assert_eq!(
        html(r#"<hr style=" border-top:3px solid div;    margin:4px 2px 4px 2px;">"#, &s),
        format!(r#"<hr style="{gap}">"#)
    );
    assert_eq!(css("hr.x{border-top:1px solid red;height:1px;color:red}", &s), "hr.x{}");
    assert_eq!(html(r#"<p color="red">x</p>"#, &s), r#"<p color="red">x</p>"#, "only a font's color is a colour");
    assert_eq!(html("<font color=nonsense>x</font>", &s), "<font>x</font>", "a legacy colour HTML would parse");
}

/// R10: data tables are marked and wrapped to scroll; layout tables are marked only.
#[test]
fn data_tables_scroll_in_their_own_box() {
    let s = plain();
    let data = "<table><tr><td>run</td><td>ran</td></tr><tr><td>go</td><td>went</td></tr></table>";
    assert_eq!(
        html(data, &s),
        r#"<div data-xdict-scroll><table data-xdict-table="data"><tr><td>run</td><td>ran</td></tr><tr><td>go</td><td>went</td></tr></table></div>"#
    );
    assert!(
        html(&format!("<p>{data}</p>"), &s).starts_with(r#"<p><table data-xdict-table="data">"#),
        "not inside an open p"
    );
    let header = "<table><tr><th>a</th></tr><tr><td><div>b</div></td></tr></table>";
    assert!(html(header, &s).contains(r#"data-xdict-table="layout""#), "one column is layout");
    let blocks = "<table><tr><td><div>a</div></td><td><img src=x></td></tr><tr><td><ul></ul></td><td><div>b</div></td></tr></table>";
    assert!(html(blocks, &s).contains(r#"data-xdict-table="layout""#));
    let nested =
        format!("<table role=presentation><tr><td>{data}</td><td>x</td></tr><tr><td>y</td><td>z</td></tr></table>");
    let out = html(&nested, &s);
    assert!(
        out.starts_with(
            r#"<table data-xdict-table="layout" role=presentation><tr><td><table data-xdict-table="data">"#
        ),
        "{out}"
    );
    assert!(!out.contains("data-xdict-scroll"), "a nested table is not wrapped: {out}");
    let (_, c) = html_normalized_within(data, BASE, "", &s, usize::MAX).unwrap();
    assert_eq!((c.data_tables, c.layout_tables), (1, 0));
}

#[test]
fn urls_are_still_rewritten_in_a_normalized_block() {
    let s = plain();
    assert_eq!(
        css(".a{list-style:url(x.png) !important;font-family:F}", &s),
        format!(r#".a{{list-style:url("xdict://d/r/x.png") !important;font-family:{FONT}}}"#)
    );
}

#[test]
fn the_base_size_comes_from_the_page_then_the_prose() {
    assert!((Style::of_sheets(["html{font-size:10pt} .a{font-size:12px}"]).base().px - 40.0 / 3.0).abs() < 1e-9);
    assert!(matches!(Style::of_sheets(["body{font-size:13px}"]).base().from, BaseFrom::Page { .. }));
    // No page size: the size most rules use, weighed by their selectors; headings and pronunciation are not prose.
    let s =
        Style::of_sheets(["h1{font-size:30px} .a,.b{font-size:13px} .c{font-size:15px} .hw,.hw2,.hw3{font-size:20px}"]);
    assert_eq!(s.base().px, 13.0);
    assert!(matches!(s.base().from, BaseFrom::Prose { weight: 2 }));
    let s = Style::of_sheets([".a{color:red}"]);
    assert_eq!((s.base().px, s.base().from.clone()), (16.0, BaseFrom::Default));
    // A hidden rule never votes.
    let s =
        Style::of_sheets([".a{display:none;font-size:10px} .b{visibility:hidden;font-size:10px} .c{font-size:15px}"]);
    assert_eq!(s.base().px, 15.0);
}

/// With entries, the base is the size most of their visible text is set in: each rule weighs what it covers, a
/// container holding the whole entry wins, and hidden or tiny selectors weigh their few characters (Chambers: three
/// 10px rules that are hidden or tiny against one 15px container).
#[test]
fn the_base_size_is_the_size_most_text_is_set_in() {
    let sheet = ".pos_explain{display:none;font-size:10px} .def_hide>.m_hide{font-size:10px} \
                 .hidden_entry_title{font-size:10px} cb13_entry{font-size:15px} .lab{font-size:10px}";
    let entry = r#"<cb13_entry><span class="hidden_entry_title">run</span><h2>run</h2>
        <span class="pos_explain">a verb: a word that names an action, a long hidden explanation</span>
        <div class="def">to move swiftly on foot so that both feet leave the ground during each stride</div>
        <span class="lab">n.</span><div class="def_hide"><span class="m_hide">x</span></div></cb13_entry>"#;
    let s = Style::of_edition([sheet], [entry]);
    assert_eq!(s.base().px, 15.0);
    assert!(matches!(s.base().from, BaseFrom::Text { .. }), "{:?}", s.base().from);
    // A page size is checked the same way: the text sits in a 14px container inside the 12px body.
    let s = Style::of_edition(
        ["body{font-size:12px} .content{font-size:14px}"],
        ["<div class=content>the definition text, which is all of the entry's prose</div><b>x</b>"],
    );
    assert_eq!(s.base().px, 14.0);
    // Relative sizes compound from their container; inline `display:none` hides (counted, the hidden 15px text
    // would outweigh the 12px).
    let s = Style::of_edition(
        [".e{font-size:15px} .x{font-size:80%}"],
        [r#"<div class=e><p class=x>most of the visible text, at eighty per cent</p>
        <p style="display:none">hidden, which must not count here</p>okay</div>"#],
    );
    assert_eq!(s.base().px, 12.0);
    // Text mostly hidden is revealed by a script (Chambers' `cb13`): then all of it counts.
    let s = Style::of_edition(
        [".e{display:none;font-size:15px} .x{font-size:12px}"],
        [r#"<div class=e>all of the entry, shown by its script when it runs</div><p class=x>a note</p>"#],
    );
    assert_eq!(s.base().px, 15.0);
    // A descendant selector matches only in its context.
    let s = Style::of_edition(
        [".e .x{font-size:20px} .y{font-size:13px}"],
        [r#"<p class=x>outside its container, this is not twenty</p><div class=y>short</div>"#],
    );
    assert_eq!(s.base().px, 16.0);
    // An attribute selector is not read, so it matches nothing (COBUILD's `[class^="sound-"]{font-size:1.3em}` grew
    // every element by 1.3 when read as any element).
    let s = Style::of_edition(
        [r#"[class^="sound-"]{font-size:1.3em} .y{font-size:13px}"#],
        [r#"<div><div><p>nested text that stays at the page's size</p></div></div><div class=y>short</div>"#],
    );
    assert_eq!(s.base().px, 16.0);
    // No sized text at all: the selector votes.
    assert_eq!(Style::of_edition([".a{font-size:13px}"], ["<p>plain</p>"]).base().px, 16.0);
}

#[test]
fn calibration_is_bounded() {
    linear("<div class=a>t", |page| {
        let _ = Style::of_edition([".a{font-size:15px}"], [page]);
    });
    linear("</b>", |page| {
        let _ = Style::of_edition([".a{font-size:15px}"], [page]);
    });
}

/// Hostile input costs time in proportion to its length, and the ceiling holds as it does for URLs.
#[test]
fn hostile_sheets_are_bounded() {
    let s = plain();
    for unit in
        ["{", "a:b !important;", "}", ".a{font:1px/1px a,", "@media{", ".a{color:rgb(", "x{background:#abc #def "]
    {
        linear(unit, |sheet| {
            let _ = css_normalized_within(sheet, BASE, "", &s, usize::MAX).unwrap();
            let _ = html_normalized_within(&format!("<p style=\"{sheet}\">"), BASE, "", &s, usize::MAX).unwrap();
        });
    }
    let grows = ".a{font-size:1px}".repeat(1 << 16);
    assert!(css_normalized_within(&grows, BASE, "", &s, grows.len()).is_err());
    linear(".a,.b{font-family:x;content:'\\e000'} ", |sheet| assert_eq!(Style::of_sheets([sheet]).kept().len(), 1));
}

/// That `run` costs time in proportion to its input: `unit` repeated 4n times takes well under 16 times (what a
/// quadratic cost would take) what n takes. A ratio, not a fixed duration, so a loaded machine does not fail it.
fn linear(unit: &str, run: impl Fn(&str)) {
    linear_at(unit, (1 << 20) / unit.len(), run);
}

/// The check fails a quadratic cost: its positive control.
#[test]
#[should_panic(expected = "for n/4")]
fn a_quadratic_cost_fails_the_linear_check() {
    linear_at("ab", 1 << 13, |text| {
        let hits = (0..text.len())
            .filter(|&i| text.get(i..).is_some_and(|t| t.bytes().filter(|&b| b == b'b').count() > 0))
            .count();
        assert!(hits > 0);
    });
}

/// Timing tests run one at a time: another test's load on the same cores slows one side of a ratio and not the
/// other, which failed both a bound and its positive control under `cargo test`'s parallel threads.
static TIMING: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn timing() -> std::sync::MutexGuard<'static, ()> {
    TIMING.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

fn linear_at(unit: &str, n: usize, run: impl Fn(&str)) {
    let _serial = timing();
    // The fastest of five runs each, the two sizes taken in turn: a loaded machine slows a run, never speeds one, and
    // a burst of load (a load average past 200 on the build Mac, 2026-10-15) then falls on both sizes alike rather than
    // on whichever ran during it. Linear is 4x, quadratic 16x; the bound sits between.
    let (texts, mut best) = ([unit.repeat(n / 4), unit.repeat(n)], [std::time::Duration::MAX; 2]);
    for _ in 0..5 {
        for (text, best) in texts.iter().zip(best.iter_mut()) {
            let started = std::time::Instant::now();
            run(text);
            *best = (*best).min(started.elapsed());
        }
    }
    let [small, large] = best;
    assert!(large < small * 10, "{unit:?}: {small:?} for n/4, {large:?} for n");
}

/// Transcriptions are marked for one IPA font, their text and delimiters untouched.
#[test]
fn transcriptions_are_marked_not_changed() {
    let s = plain();
    assert_eq!(
        html(r#"<span class="phon">/ˈæp(ə)l/</span> apple"#, &s),
        r#"<span data-xdict-phon data-xdict-phon-system="slash" class="phon">/ˈæp(ə)l/</span> apple"#
    );
    // The outermost element whose text is the transcription, entities decoded.
    assert_eq!(
        html("<b>[<i>ˈ</i>&#230;pl]</b>", &s),
        r#"<b data-xdict-phon data-xdict-phon-system="bracket">[<i>ˈ</i>&#230;pl]</b>"#
    );
    assert_eq!(
        html(r"<em>\ˈa-pəl\</em>", &s),
        r#"<em data-xdict-phon data-xdict-phon-system="backslash">\ˈa-pəl\</em>"#
    );
    for kept in ["<p>apple, n. a fruit</p>", "<p>the schwa ə</p>", "<span>苹果ə</span>", "<p>ˈ</p>"] {
        assert_eq!(html(kept, &s), kept);
    }
    // A mixed paragraph keeps its transcription's own element marked.
    let mixed = html("<p>apple <span>/ˈæpl/</span> fruit</p>", &s);
    assert!(mixed.contains(r#"<span data-xdict-phon data-xdict-phon-system="slash">"#), "{mixed}");
    let (_, counts) = html_normalized_within("<a>/ˈæ/</a><a>[ð]</a><a>/ŋ/</a>", BASE, "", &s, usize::MAX).unwrap();
    let t: &Transcriptions = &counts.transcriptions;
    assert_eq!(t.marked, 3);
    assert_eq!(t.systems.get("slash"), Some(&2));
    assert_eq!(t.characters.iter().collect::<String>(), "æðŋˈ");
}

/// A transcription that is no element of its own (loose text beside other content, its delimiters outside the
/// element holding its letters) is wrapped whole: CALD's `/ˈvɪʒ.<sup>ə</sup>n/`, OED's labelled wrapper.
#[test]
fn a_transcription_among_other_content_is_wrapped_whole() {
    let s = plain();
    let wrap = |system: &str, inner: &str| {
        format!(r#"<span data-xdict-phon data-xdict-phon-system="{system}">{inner}</span>"#)
    };
    // CALD: the headword, a speaker and the transcription in one element; the superscript only a part of it.
    assert_eq!(
        html("<font>—<b>vision</b> <a>uk</a> /ˈvɪʒ.<sup>ə</sup>n/</font>", &s),
        format!("<font>—<b>vision</b> <a>uk</a> {}</font>", wrap("slash", "/ˈvɪʒ.<sup>ə</sup>n/"))
    );
    // OED: a label and a speaker beside the delimiters, the letters in their own element. Only the transcription.
    assert_eq!(
        html(r#"<div>Brit.<a>sound</a>/<span class="phonetics">ˈdʌɪnə</span>/</div>"#, &s),
        format!(r#"<div>Brit.<a>sound</a>{}</div>"#, wrap("slash", r#"/<span class="phonetics">ˈdʌɪnə</span>/"#))
    );
    assert_eq!(
        html(r#"<div>Brit./<span class="phonetics">ˌantimʌɪˈtɒtɪk</span>/</div>"#, &s),
        format!(r#"<div>Brit.{}</div>"#, wrap("slash", r#"/<span class="phonetics">ˌantimʌɪˈtɒtɪk</span>/"#))
    );
    // The delimiters in an element of their own beside the label: that element is the mark, not the label's.
    assert_eq!(
        html(r#"<div>Brit.<a>sound</a><span class="sup">/<span>ˌsuːdəʊ</span>/</span></div>"#, &s),
        r#"<div>Brit.<a>sound</a><span data-xdict-phon data-xdict-phon-system="slash" class="sup">/<span>ˌsuːdəʊ</span>/</span></div>"#
    );
    // In prose, two of them, brackets too; entities decoded.
    assert_eq!(
        html("<p>say /ˈæpl/ or [ˈ&#230;pl] here</p>", &s),
        format!("<p>say {} or {} here</p>", wrap("slash", "/ˈæpl/"), wrap("bracket", "[ˈ&#230;pl]"))
    );
    // Not transcriptions: no phonetic letter, a broken element between, a stray slash, a word outside the bounds.
    for kept in ["<p>and/or /apple/ 1/2</p>", "<p>/ˈæ <b>苹</b> pl/</p>", "<p>x / ə/</p>", "<p>/ə 苹果/</p>"] {
        assert_eq!(html(kept, &s), kept);
    }
    let (_, counts) = html_normalized_within("<p>a /ˈæ<i>p</i>l/ b</p>", BASE, "", &s, usize::MAX).unwrap();
    assert_eq!(counts.transcriptions.marked, 1);
    assert_eq!(counts.transcriptions.systems.get("slash"), Some(&1));
}

/// A dictionary drawing IPA over ASCII through its phonetic font is marked with that font and left alone.
#[test]
fn a_phonetic_font_marks_its_elements() {
    let s = Style::of_sheets([
        r#"@font-face{font-family:"Kingsoft Phonetic";src:url(k.ttf)} .phon{font-family:"Kingsoft Phonetic"}"#,
    ]);
    assert_eq!(
        html(r#"<span class="phon">[5pl]</span>"#, &s),
        r#"<span data-xdict-phon data-xdict-phon-system="font:Kingsoft Phonetic" class="phon">[5pl]</span>"#
    );
}

#[test]
fn transcription_marking_is_bounded() {
    let s = plain();
    for unit in ["<b>", "<b>/ə/", "<i>/ə/</i>", "</b>", "<font color=red>"] {
        linear(unit, |page| {
            let _ = html_normalized_within(page, BASE, "", &s, usize::MAX).unwrap();
        });
    }
    let many = "<i>/ə/</i>".repeat(1000);
    assert!(html_normalized_within(&many, BASE, "", &s, many.len() + 10).is_err(), "the marks are held to the ceiling");
}

/// Every `var(--xdict-…)` the core writes is a token `dev-docs/reading-style.md` §1 defines ([`TOKENS`]): a name the
/// frame does not define falls back silently.
#[test]
fn every_token_written_is_one_the_frame_defines() {
    let s = Style::of_sheets(["body{font-size:16px}"]);
    let mut sheet = String::new();
    for colour in [
        "#000", "#333", "#999", "#fff", "red", "#c00000", "#8b0000", "orange", "#ffd700", "green", "teal", "navy",
        "blue", "purple", "#800080", "pink", "#c71585", "#fff8dc", "#602090", "#dddddd", "#e0ffff",
    ] {
        sheet.push_str(&format!(".a{{color:{colour};background:{colour};border:1px solid {colour}}} "));
        sheet.push_str(&format!(".c{{color:{colour};background:#602090}} .d{{background:{colour};padding:1px}} "));
    }
    for size in ["6px", "12px", "16px", "18px", "20px", "40px", "small", "x-large", "70%", "1.3em", "3em", "5vw"] {
        sheet.push_str(&format!(".b{{font-size:{size}}} .f{{font:bold {size}/2 x}} "));
    }
    for space in ["1px", "4px", "8px", "12px", "16px", "40px", "-4px", "-0.5em"] {
        sheet.push_str(&format!(".g{{margin:{space} 0;padding-top:{space}}} "));
    }
    sheet.push_str(".h{font-family:monospace} .i{font-family:Gentium} .j{font-weight:700} .k{font-family:x}");
    let mut written = css(&sheet, &s);
    for n in ["1", "2", "3", "4", "5", "6", "7", "+1", "-1"] {
        written.push_str(&html(&format!("<font size={n} color=red face=x>x</font><td bgcolor=#eee>"), &s));
    }
    let mut seen = 0;
    for (at, _) in written.match_indices("var(--xdict-") {
        let name: String = written[at + 4..].chars().take_while(|c| c.is_ascii_alphanumeric() || *c == '-').collect();
        assert!(TOKENS.contains(&name.as_str()), "{name} is no §1 token");
        seen += 1;
    }
    assert!(seen > 100, "only {seen} tokens written");
}

/// §5.2: a sound link is a speaker the frame draws, whatever the dictionary drew it with; its accent is told by the
/// first decisive signal (§5.3). An image of a speaker is pixels the palette cannot reach (CEPD's, LDOCE-EC's dark
/// tails), so every icon-only sound link is replaced, never only the ones measured.
#[test]
fn a_sound_link_is_xdicts_speaker() {
    let s = plain();
    let glyph = r#"<span data-xdict-icon="speaker" aria-hidden="true"></span>"#;
    let tag = r#"<span data-xdict-tag aria-hidden="true"></span>"#;
    let speaker = |mode: &str| format!(r#" data-xdict-control="speaker" data-xdict-control-mode="{mode}""#);
    // An image, its accent from the icon's file stem (CEPD).
    assert_eq!(
        html(r#"<a href="sound://UKA_001.spx"><img src="uk_sound.png"></a>"#, &s),
        format!(
            r#"<a{} data-xdict-accent="uk" href="xdict://d/sound/UKA_001.spx">{glyph}{tag}<img src="xdict://d/r/uk_sound.png"></a>"#,
            speaker("replace")
        )
    );
    // The accent from the sound's folders when the icon says nothing (LDOCE-EC's `spkr_b.png`, `/ame/`).
    let out = html(r#"<a href="sound://hwd/ame/0/x.mp3"><img src="img/spkr_b.png"></a>"#, &s);
    assert!(out.contains(r#"data-xdict-accent="us""#), "{out}");
    // An emoji in a custom element named for its accent (OALECD).
    let out = html(r#"<a href="sound://_x__gbs_1.mp3"><audio-gb-liju>🔊</audio-gb-liju></a>"#, &s);
    assert!(out.contains(&speaker("replace")) && out.contains(r#"data-xdict-accent="uk""#), "{out}");
    // Text inside: the glyph goes first and the text stays; no signal, no tag.
    assert_eq!(
        html(r#"<a href="sound://run.mp3">play</a>"#, &s),
        format!(r#"<a{} href="xdict://d/sound/run.mp3">{glyph}play</a>"#, speaker("prefix"))
    );
    // Conflicting signals at one level: no accent.
    let out = html(r#"<a href="sound://x.mp3"><img src="uk.png"><img src="us.png"></a>"#, &s);
    assert!(out.contains(&speaker("replace")) && !out.contains("data-xdict-accent"), "{out}");
    // A block inside, a link that is not a sound, an unclosed link past the bound: left alone.
    for entry in [r#"<a href="sound://x.mp3"><div>a</div></a>"#, r#"<a href="entry://run"><img src="uk.png"></a>"#] {
        assert!(!html(entry, &s).contains("data-xdict-control"), "{entry}");
    }
    let long = format!(r#"<a href="sound://x.mp3">{}"#, "x".repeat(5000));
    assert!(!html(&long, &s).contains("data-xdict-control"));
}

/// A private-use character inside a speaker is the dictionary's icon-font glyph, drawn in a face XDict does not load:
/// it would show as a missing-glyph box beside XDict's own speaker, so it is removed, written raw or as a reference
/// (COBUILD's `icomoon` U+EA27 in `span.icon-speak-uk`, beside the transcription it keeps; icon sweep 2026-10-15).
/// Outside a speaker, and any other character inside one, stay.
#[test]
fn a_speakers_private_use_glyph_is_removed() {
    let s = plain();
    let out = html(
        "<a href=\"sound://COLmp3/1.mp3\"> <span class=\"pron\">rʌn </span> <span class=\"icon-speak-uk\">\u{EA27}</span></a> \u{EA27}",
        &s,
    );
    assert!(out.contains(r#"data-xdict-control-mode="prefix""#), "{out}");
    assert!(out.contains("<span class=\"icon-speak-uk\"></span></a> \u{EA27}"), "{out}");
    assert!(out.contains("rʌn "), "{out}");
    let out = html(r#"<a href="sound://1.mp3">runs<span>&#xea27;</span> ★</a>"#, &s);
    assert!(out.contains("runs<span></span> ★</a>"), "{out}");
}

/// Reading ahead for a link's content is bounded: many unclosed sound links cost time in proportion to their length.
#[test]
fn speaker_reading_is_bounded() {
    linear(r#"<a href="sound://x.mp3">"#, |page| {
        let _ = html(page, &plain());
    });
}

/// Calibration's cost is linear in the sheet's selectors and the entries' elements together: 100k selectors on the
/// key every element carries cost their count once each until the match budget, never selectors x elements.
#[test]
fn calibration_is_linear_in_selectors_and_elements() {
    // An entry is read to 256 KiB, so the elements stop growing with it: the hostile case is measured against the
    // same sheet with elements no rule names, and must cost about what that costs.
    let sheet = ".a{font-size:15px}".repeat(100_000);
    let serial = timing();
    let time = |entry: &str| {
        let entries = [entry; 8];
        (0..3)
            .map(|_| {
                let started = std::time::Instant::now();
                let _ = Style::of_edition([sheet.as_str()], entries.iter().copied());
                started.elapsed()
            })
            .min()
            .unwrap_or_default()
    };
    let (hostile, benign) = (time(&"<p class=a>t</p>".repeat(16_000)), time(&"<p class=b>t</p>".repeat(16_000)));
    assert!(hostile < benign * 10 + std::time::Duration::from_millis(50), "{hostile:?} against {benign:?}");
    drop(serial);
    // Elements with many classes against compounds with many classes: each match costs a constant.
    let classes: String = (0..2000).map(|i| format!(".c{i}")).collect();
    let tag_classes: String = (0..2000).map(|i| format!("c{i} ")).collect();
    linear(&format!("{classes}{{font-size:15px}} "), |sheet| {
        let entry = format!("<p class=\"{tag_classes}\">t</p>").repeat(sheet.len() / 20_000 + 1);
        let _ = Style::of_edition([sheet], [entry.as_str()]);
    });
    // 100k nested elements, each matched against a descendant selector.
    linear("<div class=a>", |entry| {
        let _ = Style::of_edition([".a .a .a .a{font-size:15px} .a{font-size:12px}"], [entry]);
    });
}

/// Only the sheets an entry links are named by it: each `<link>` read once.
#[test]
fn linked_sheets_are_read_from_link_tags() {
    assert_eq!(
        xdict_entry::linked_sheets(r#"<LINK rel=stylesheet href="css/A.css?v=2"><linker href=b.css><a href=c.css>"#),
        ["a.css"]
    );
    assert_eq!(xdict_entry::file_name(r"x\y\Z.CSS"), "z.css");
    linear("<link href=", |entry| {
        let _ = xdict_entry::linked_sheets(entry);
    });
    linear("<<<<", |entry| {
        let _ = xdict_entry::linked_sheets(entry);
    });
}

/// 100k sound links cost their length: each link reads ahead only to the next link, and a link's content full of
/// unclosed `<` costs no more than plain text of the same length (it once cost its square per link).
#[test]
fn speakers_are_linear_in_links() {
    linear(r#"<a href="sound://x/uk/a.mp3"><img src="spkr_b.png" alt="us"></a>"#, |page| {
        let _ = html(page, &plain());
    });
    let _serial = timing();
    let time = |page: &str| {
        (0..3)
            .map(|_| {
                let started = std::time::Instant::now();
                let _ = html(page, &plain());
                started.elapsed()
            })
            .min()
            .unwrap_or_default()
    };
    let hostile = format!("<a href=sound://x.mp3>{}</a>", "<x".repeat(2000)).repeat(64);
    let benign = format!("<a href=sound://x.mp3>{}</a>", "xx".repeat(2000)).repeat(64);
    let (h, b) = (time(&hostile), time(&benign));
    assert!(h < b * 10 + std::time::Duration::from_millis(50), "{h:?} against {b:?}");
}

/// One palette: a text colour the core writes is a palette token or a keyword that names no colour of its own
/// (`currentColor`, `inherit`, `transparent`). A system colour, a vendor keyword, `color-mix()`, `light-dark()` or a
/// dictionary's own variable would reach the page as the engine resolves it (WebKit's dark link colour is
/// `rgb(158,158,255)`), so the declaration goes; a `<font color>` HTML would parse as a legacy colour goes too.
#[test]
fn a_text_colour_is_only_a_token() {
    let s = plain();
    for v in [
        "-webkit-link",
        "LinkText",
        "GrayText",
        "ButtonText",
        "VisitedText",
        "CanvasText",
        "windowtext",
        "Highlight",
        "-apple-system-blue",
        "color-mix(in srgb, red, blue)",
        "light-dark(#000, #fff)",
        "var(--x)",
        "var(--x, #9e9eff)",
        "initial",
        "revert",
        "revert-layer",
    ] {
        for property in ["color", "-webkit-text-fill-color", "text-decoration-color", "caret-color"] {
            assert_eq!(css(&format!(".a{{{property}:{v}}}"), &s), ".a{}", "{property}: {v}");
        }
        assert_eq!(css(&format!(".a{{text-decoration:underline {v}}}"), &s), ".a{}", "{v}");
        assert_eq!(html(&format!("<font color=\"{v}\">x</font>"), &s), "<font>x</font>", "{v}");
    }
    // `all` resets the colour to the engine's own (`initial` is CanvasText).
    assert_eq!(css(".a{all:initial;color:red}", &s), ".a{color:var(--xdict-red, #af342f)}");
    for v in ["currentColor", "inherit", "transparent", "unset"] {
        assert_eq!(css(&format!(".a{{color:{v}}}"), &s), format!(".a{{color:{v}}}"));
    }
    assert_eq!(css(".a{color:navy}", &s), ".a{color:var(--xdict-blue-deep, #02489f)}");
    assert_eq!(css(".a{text-decoration:underline dotted}", &s), ".a{text-decoration:underline dotted}");
    assert_eq!(css(".a{color:var(--xdict-red, #af342f)}", &s), ".a{color:var(--xdict-red, #af342f)}");
    assert_eq!(html(r#"<p style="color:LinkText">x</p>"#, &s), r#"<p style="">x</p>"#);
}

/// ADR-0010 Q3: in "Original style" a sheet, a `<style>`, a `style=""` and the presentational attributes are left as
/// the dictionary wrote them: no token, no dropped declaration, no face, no `!important` taken; URLs are still the
/// view's. A CSS image drawn as content is a mark's work (XDict's marks replace it), so it goes in either style.
#[test]
fn original_style_leaves_the_dictionarys_declarations_as_written() {
    let s = Style::of_sheets(["body{font-size:14px}"]);
    let sheet = "body{font-size:14px;margin:0} .p{font-size:12px !important;color:#123456;line-height:28px} \
                 @font-face{font-family:Q;src:url(q.ttf)} .i:before{content:url(i.png)}";
    let (out, _) = xdict_entry::css_styled_within(sheet, BASE, "", &s, true, usize::MAX).unwrap();
    assert_eq!(
        out,
        "body{font-size:14px;margin:0} .p{font-size:12px !important;color:#123456;line-height:28px} \
         @font-face{font-family:Q;src:url(\"xdict://d/r/q.ttf\")} .i:before{}"
    );
    assert_ne!(css(sheet, &s), out, "the reading style does change it");
    let page = r#"<style>.q{font-family:Ic;color:red}</style><font color="red" size="5">r</font><p style="color:#123456;line-height:28px">p</p><table width="300" border="1"><tr><td>t</td></tr></table>"#;
    let (html, _) = xdict_entry::html_styled_within(page, BASE, "", &s, false, true, usize::MAX).unwrap();
    for kept in [
        ".q{font-family:Ic;color:red}",
        r#"<font color="red" size="5">"#,
        r#"style="color:#123456;line-height:28px""#,
        r#"width="300" border="1">"#,
    ] {
        assert!(html.contains(kept), "{kept} in {html}");
    }
}
