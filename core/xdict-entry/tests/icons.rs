//! The icon sweep's rules (`dev-docs/measurements/2026-10-15-icon-sweep/` §7, the owner's answers in ADR-0010): meaning
//! drawn as a graphic becomes XDict's label, symbols are treated by role, speakers named by a handler or `data-*`
//! become XDict's speaker, fold controls are marked `disclosure`, and empty website links go. Every entry here is
//! written in the test, no dictionary's.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use xdict_entry::{Counts, Entry, Style, css_normalized_within, entry_normalized_within};

const BASE: &str = "xdict://d/";

fn entry_with(text: &str, style: &Style, resource: Option<&dyn Fn(&str) -> bool>) -> (String, Counts) {
    entry_normalized_within(
        text,
        BASE,
        "",
        style,
        &Entry { key: "about", resource, is_key: None, strip_off_for_tests: false },
        usize::MAX,
    )
    .unwrap()
}

fn out(text: &str, sheet: &str) -> String {
    entry_with(text, &Style::of_sheets([sheet]), None).0
}

fn label(kind: &str, value: &str, text: &str) -> String {
    format!(r#"<span data-xdict-role="label" data-xdict-label="{kind}" data-xdict-value="{value}">{text}</span>"#)
}

fn frequency(value: u32, max: u32) -> String {
    format!(
        r#"<span data-xdict-role="label" data-xdict-label="frequency" data-xdict-value="{value}" data-xdict-max="{max}">Frequency {value}/{max}</span>"#
    )
}

// 1. Meaning drawn as a graphic becomes XDict's label, which replaces it.

#[test]
fn a_level_and_word_list_badge_becomes_labels_and_its_empty_link_goes() {
    let sheet = ".ox3ksym_a1{background:url(a1.svg);width:48px;height:27px}";
    let o = out(
        r#"<div class="symbols"><a href="entry://@ox3000&level=a1"><span class="ox3ksym_a1"> </span></a></div>"#,
        sheet,
    );
    assert!(o.contains(&(label("wordlist", "oxford3000", "Oxford 3000") + &label("level", "A1", "A1"))), "{o}");
    assert!(o.contains(r#"<span hidden data-xdict-labelled class="ox3ksym_a1">"#), "the graphic is hidden, kept: {o}");
    assert!(!o.contains("<a "), "the link that held only the badge is unwrapped: {o}");
}

#[test]
fn a_run_of_frequency_dots_becomes_one_label_counting_the_marked_ones() {
    let sheet = ".level{width:9px;height:9px;border-radius:50%} .roundRed{background:red}";
    let dots = r#"<span class="level level1 roundRed"></span><span class="level level2 roundRed"></span><span class="level level3 roundRed"></span><span class="level level4"></span><span class="level level5"></span>"#;
    let o = out(
        &format!(r#"<div class="title_frequency_container"><span class="word-frequency-img">{dots}</span></div>"#),
        sheet,
    );
    assert_eq!(o.matches("data-xdict-label=").count(), 1, "one label for the group: {o}");
    assert!(
        o.contains(&(frequency(3, 5) + r#"<span hidden data-xdict-labelled class="level level1 roundRed">"#)),
        "{o}"
    );
    assert_eq!(o.matches("data-xdict-labelled").count(), 5, "{o}");
    let all = dots.replace(r#"level4""#, r#"level4 roundRed""#).replace(r#"level5""#, r#"level5 roundRed""#);
    let o = out(&format!(r#"<div class="word-frequency-img" title="Extremely Common">{all}</div>"#), sheet);
    assert!(o.contains(&frequency(5, 5)), "{o}");
}

#[test]
fn a_frequency_band_link_becomes_its_label() {
    let o = out(
        r#"<div>Frequency: <a href="/frequencybandinformation/7" onclick="viewFrequencyPopup(); return false;" class="frequencyBand7" title="Frequency Band 7" id="f"><span/></a></div>"#,
        "",
    );
    assert_eq!(o, format!("<div>Frequency: {}</div>", frequency(7, 8)));
}

#[test]
fn a_new_badge_and_a_key_symbol_become_labels() {
    let o = out(r#"<b>w</b><img src="/assets/update-new.jpg">"#, "");
    assert!(o.contains(&(label("new", "new", "New") + "<img hidden data-xdict-labelled ")), "{o}");
    let o = out(r#"<a href="help:keyword"><symbol type="key">🔑</symbol></a> <h>about</h>"#, "");
    assert!(o.contains(&label("wordlist", "oxford3000", "Oxford 3000")), "{o}");
    assert!(o.contains(r#"<symbol hidden data-xdict-labelled type="key">"#), "{o}");
}

#[test]
fn a_control_or_prose_is_never_a_label() {
    let fav = r#"<span class="save_faves"><div class="save_faves_star"><i class="fa fa-star"></i><i class="fa fa-star-o"></i></div></span>"#;
    let sheet = ".fa{font-family:x} .save_faves{width:9px}";
    assert!(!out(fav, sheet).contains("data-xdict-label"), "a website's favourite star");
    assert!(!out(r#"<span class="level">Advanced</span>"#, "").contains("data-xdict-label"), "words are text");
    assert!(!out(r#"<img src="pics/news-stand.jpg">"#, "").contains("data-xdict-label"), "news is not new");
    let stars = r#"<div class="stars_grp"><div class="icon_star">★</div><div class="icon_star">★</div></div>"#;
    assert!(!out(stars, "").contains("data-xdict-value"), "stars written as text are words");
}

// 2. Symbols by role.

#[test]
fn a_bullet_a_sheet_draws_becomes_xdicts_marker_and_an_arrow_its_lookup_mark() {
    let sheet = r#".x-g::before{content:"•"} .xr::before{content:"☞ "} .nb::after{content:"※"}"#;
    let o = out(r#"<span class="x-g">a</span><span class="xr">see</span><span class="nb">b</span>"#, sheet);
    assert!(o.contains(r#"<span data-xdict-before="marker" class="x-g">"#), "{o}");
    assert!(o.contains(r#"<span data-xdict-before="lookup" class="xr">"#), "{o}");
    assert!(o.contains(r#"<span class="nb">"#), "a note sign is kept: {o}");
    let o = out(r#"<div class="sec"><span class="x-g">a</span></div>"#, r#".other .x-g::before{content:"•"}"#);
    assert!(!o.contains("data-xdict-before"), "an ancestor the selector names is missing: {o}");
}

#[test]
fn an_icon_faces_glyph_is_dropped_from_the_sheet() {
    let sheet = r#"@font-face{font-family:ic;src:url(ic.ttf)} .v::before{font-family:ic;content:"\f028"} .e > h2::before{font-family:ic;content:"\1F447"} .t::before{content:"see "}"#;
    let style = Style::of_sheets([sheet]);
    let (css, counts) = css_normalized_within(sheet, BASE, "", &style, usize::MAX).unwrap();
    assert!(!css.contains("f028") && !css.contains("1F447"), "{css}");
    assert!(css.contains("see "), "words drawn by a sheet stay: {css}");
    assert_eq!(counts.icons.get("glyph-dropped"), Some(&2), "{counts:?}");
}

#[test]
fn a_sense_number_drawn_as_a_symbol_becomes_a_plain_number() {
    let o = out("<span>❶ to go</span><span>🄰 x</span><span>⑫ y</span>", "");
    assert_eq!(
        o,
        r#"<span><span data-xdict-role="sensenum">1</span> to go</span><span><span data-xdict-role="sensenum">A</span> x</span><span><span data-xdict-role="sensenum">12</span> y</span>"#
    );
}

#[test]
fn a_symbol_written_as_text_stays() {
    for (text, kept) in [
        ("<span>→ see run</span>", "→ see run"),
        ("<b>★★★</b> common", ">★★★</b>"),
        ("<i>† obsolete</i>", "† obsolete"),
        ("<span>ⓘ note</span>", "ⓘ note"),
    ] {
        let o = out(text, "");
        assert!(o.contains(kept) && !o.contains("data-xdict-before") && !o.contains("sensenum"), "{o}");
    }
}

#[test]
fn a_private_use_glyph_left_in_a_speaker_goes() {
    let o = out(
        r#"<a href="sound://a.mp3">/əˈbaʊt/<span class="icon-speak-uk">&#xea27;</span><span class="i"></span></a>"#,
        "",
    );
    let o2 = out("<a href=\"sound://a.mp3\">/əˈbaʊt/<span class=\"icon-speak-uk\">\u{ea27}</span></a>", "");
    assert!(o.contains("data-xdict-control=\"speaker\""), "{o}");
    assert!(!o2.contains('\u{ea27}'), "{o2}");
}

// 3. Speakers named by a handler or a `data-*` attribute.

#[test]
fn a_speaker_named_by_a_handler_key_or_data_attribute_is_xdicts_speaker() {
    let ode = r#"<img src="pr.png" onclick="o0e.a(this,0,'a/a__/a__gb/a__gb_2')" class="a8e"/>"#;
    let holds = |p: &str| p == "mp3/a_gb_2.mp3" || p == "pr.png";
    let (o, _) = entry_with(ode, &Style::of_sheets([]), Some(&holds));
    assert!(o.starts_with(r#"<a href="xdict://d/sound/mp3/a_gb_2.mp3" data-xdict-control="speaker""#), "{o}");
    assert!(o.contains(r#"data-xdict-accent="uk""#), "{o}");
    let (o, _) = entry_with(ode, &Style::of_sheets([]), None);
    assert!(o.contains(r#"data-xdict-control="speaker""#), "no recording found: spoken: {o}");
    assert!(o.contains("about.tts"), "{o}");
    let ced = r#"<a class="hwd_sound sound" data-mp3="https://x.example/s/00003.mp3" onclick="new Audio(this.getAttribute('data-mp3')).play()"></a>"#;
    let (o, _) = entry_with(ced, &Style::of_sheets([]), None);
    assert!(o.contains(r#"data-xdict-control="speaker""#), "{o}");
    let (o, _) = entry_with(
        r#"<span onclick="o0e.a(this,0,'b/bed/bedford_cord_1_gb_1_8')">x</span>"#,
        &Style::of_sheets([]),
        None,
    );
    assert!(o.contains(r#"data-xdict-control="speaker""#), "a key with more after its accent: {o}");
    let (o, _) = entry_with(r#"<span onclick="pron_key(1)">key</span>"#, &Style::of_sheets([]), None);
    assert!(!o.contains("speaker"), "a function's name is not a recording: {o}");
}

// 4. Fold controls.

#[test]
fn a_fold_control_is_marked_disclosure_and_keeps_its_hook() {
    let o = out(r#"<span class="box_title" onclick="toggle_active(this);">Extra examples</span>"#, "");
    assert_eq!(
        o,
        r#"<span data-xdict-control="disclosure" data-xdict-role="fold" class="box_title" onclick="toggle_active(this);">Extra examples</span>"#
    );
    for not in [
        r#"<img src="a.png" onclick="toggle(this)">"#,
        r#"<a class="info" onclick="showPopup(this)">i</a>"#,
        r#"<span class="tab_icon_close" onclick="switchTab(1)">x</span>"#,
    ] {
        assert!(!out(not, "").contains("disclosure"), "{not}");
    }
    let o = out(r#"<span class="sdh" onclick="toggle(this)">► Phrases</span>"#, "");
    assert_eq!(
        o,
        r#"<span data-xdict-control="disclosure" data-xdict-role="fold" class="sdh" onclick="toggle(this)"> Phrases</span>"#
    );
    let mut s = Style::of_sheets([".cc_addon_foldButton{width:9px}"]);
    s.add_scripts(["$('.cc_addon_foldButton').click(function(){ $(this).next().toggle() })"]);
    let (o, _) = entry_with(r#"<div class="cc_addon_foldButton"><div class="vline"></div></div>"#, &s, None);
    assert!(o.starts_with(r#"<div data-xdict-control="disclosure" class="cc_addon_foldButton">"#), "{o}");
}

// 5. Empty website links.

#[test]
fn an_empty_website_link_goes_an_anchor_stays() {
    let oseo = r#"x<a href="javascript:void(0);" id="13" onClick="return(viewOseoPopup('13'));" class="popup oseo" title="View more context">   </a>y"#;
    assert_eq!(out(oseo, ""), "xy");
    assert_eq!(out(r#"<a name="n"></a><a id="k"></a>"#, ""), r#"<a name="n"></a><a id="k"></a>"#);
}

// Bounds.

/// Hostile shapes stay linear: a wide run of dots, a deep nest of badges, many glyph rules over many elements, a long
/// run of sense numbers. Each timed at n and 4n: linear grows about 4 times, quadratic 16 (a ratio, not a clock).
#[test]
fn hostile_icons_stay_linear() {
    let rules: String =
        (0..2000).map(|i| format!(".c{i}::before{{content:\"•\"}} .a .c{i}::after{{content:\"→\"}} ")).collect();
    let glyphs = Style::of_sheets([rules.as_str()]);
    let dots = Style::of_sheets([".level{width:9px} .on{background:red}"]);
    type Shape = fn(usize) -> String;
    let shapes: [(&str, Shape, &Style); 4] = [
        ("dots", |n| format!("<span class=\"freq\">{}</span>", "<span class=\"level on\"></span>".repeat(n)), &dots),
        ("nest", |n| "<a href=\"entry://x\"><span class=\"ox3ksym_b2\">".repeat(n) + &"</span></a>".repeat(n), &dots),
        (
            "glyphs",
            |n| (0..n).map(|i| format!("<span class=\"a c{} c{}\">x</span>", i % 2000, (i * 7) % 2000)).collect(),
            &glyphs,
        ),
        ("numbers", |n| format!("<p>{}</p>", "❶①🄰 ".repeat(n * 8)), &dots),
    ];
    for (name, shape, style) in shapes {
        let time = |n: usize| {
            let text = shape(n);
            (0..3)
                .map(|_| {
                    let started = std::time::Instant::now();
                    entry_with(&text, style, None);
                    started.elapsed().as_secs_f64()
                })
                .fold(f64::MAX, f64::min)
        };
        time(500);
        let (small, large) = (time(2_000).max(1e-3), time(8_000));
        assert!(large / small < 10.0, "{name}: {small:.3}s at n, {large:.3}s at 4n");
    }
}

// 5. Punctuation the source sets against an element stays against it (coordinator's review, 2026-10-16): the element
// closed right before a `,` `;` or `.` is marked, so the frame drops the inline end spacing a badge's box had.

#[test]
fn an_element_closed_right_before_punctuation_is_marked_to_hug_it() {
    let o = out(
        r#"<p><a href="entry://x"><span class="c">b1</span></a><span class="sep">,</span> <b>z</b> ; <i>w</i>. <u>v</u><img src="a.png">, <em>q</em>&#44;</p>"#,
        ".c{padding:0 4px;margin:0 4px}",
    );
    assert_eq!(o.matches("data-xdict-hug").count(), 2, "the link before `,` and the italic before `.`: {o}");
    assert!(o.contains("<i data-xdict-hug"), "{o}");
    assert!(!o.contains("<b data-xdict-hug"), "a space the source wrote stays: {o}");
    assert!(!o.contains("<u data-xdict-hug"), "an image between is not punctuation: {o}");
}
