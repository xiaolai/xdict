//! XDict's canonical roles (`dev-docs/element-sweep.md` §2.1, the generic rules only), as the core marks them on an
//! entry. The entries are written here, no dictionary's.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use xdict_entry::{Counts, Entry, Style, entry_normalized_within};

const BASE: &str = "xdict://d/";

fn entry(text: &str, key: &str) -> (String, Counts) {
    let style = Style::of_sheets([".pos{font-style:italic}"]);
    entry_normalized_within(
        text,
        BASE,
        "",
        &style,
        &Entry { key, resource: None, is_key: None, strip_off_for_tests: false, original: false },
        usize::MAX,
    )
    .unwrap()
}

/// The role written on the first element of class `class`.
fn role_of(out: &str, class: &str) -> Option<String> {
    let at = out.find(&format!("class=\"{class}\"")).unwrap_or_else(|| panic!("{class} not in {out}"));
    let from = out[..at].rfind('<').unwrap();
    let tag = &out[from..at];
    let r = tag.find("data-xdict-role=\"")?;
    let v = &tag[r + 17..];
    let mut role = v[..v.find('"').unwrap()].to_owned();
    for kind in ["data-xdict-section=\"", "data-xdict-label=\""] {
        if let Some(k) = tag.find(kind) {
            let v = &tag[k + kind.len()..];
            role = format!("{role}:{}", &v[..v.find('"').unwrap()]);
        }
    }
    Some(role)
}

const RUN: &str = r#"<div class="e"><div class="top"><b class="hw">run</b> <span class="pos">verb</span> <span class="ph">/rʌn/</span> <a class="snd" href="sound://run.mp3"><img src="spk.png"></a></div><div class="s"><b>1.</b> <span class="d">to move fast on your feet</span> <i class="x">She runs to school every day.</i> <span class="tr">她每天跑步去学校。</span></div><div class="s"><b>2.</b> <span class="lb">informal</span> <span class="d">to manage a business or a shop</span></div><div class="id"><b>IDIOMS</b><p><b class="sub">run a risk</b> to be in danger of something happening</p></div></div><div class="foot">© 2020 A Publisher. All rights reserved.</div>"#;

/// Tier 1: headword, part of speech, pronunciation, audio, sense numbers, translations of examples.
#[test]
fn tier_one_roles_are_marked() {
    let (out, counts) = entry(RUN, "run");
    assert_eq!(role_of(&out, "hw"), Some("headword".into()), "{out}");
    assert_eq!(role_of(&out, "pos"), Some("pos".into()));
    assert_eq!(role_of(&out, "ph"), Some("pron".into()));
    assert_eq!(role_of(&out, "snd"), Some("audio".into()));
    assert!(out.contains(r#"<b data-xdict-role="sensenum">1.</b>"#), "{out}");
    assert_eq!(role_of(&out, "tr"), Some("example-trans".into()));
    assert_eq!(counts.roles.get("headword"), Some(&1));
}

/// Tier 2, styled mildly: examples, labels with their kind, senses, headings with their section's kind, subheads,
/// the entry, and the website's chrome (Q5).
#[test]
fn tier_two_roles_are_marked_with_their_kinds() {
    let (out, _) = entry(RUN, "run");
    assert_eq!(role_of(&out, "x"), Some("example".into()), "{out}");
    assert_eq!(role_of(&out, "lb"), Some("label:register".into()));
    assert_eq!(role_of(&out, "s"), Some("sense".into()));
    assert!(out.contains(r#"<b data-xdict-role="heading">IDIOMS</b>"#), "{out}");
    assert_eq!(role_of(&out, "id"), Some("section:idioms".into()));
    assert_eq!(role_of(&out, "sub"), Some("subhead".into()));
    assert_eq!(role_of(&out, "e"), Some("entry".into()));
    assert_eq!(role_of(&out, "foot"), Some("chrome".into()));
}

/// A translation that follows no example; a homograph number; a fold; a content image (Q7).
#[test]
fn translations_homographs_folds_and_images() {
    let (out, _) = entry(
        r#"<p><b class="h">bank<sup class="n">2</sup></b></p><p><span class="t">银行</span></p><span class="m" onclick="toggle(this)">more</span><img class="pic" src="bank.jpg" width="300" height="200">"#,
        "bank",
    );
    assert_eq!(role_of(&out, "h"), Some("headword".into()), "{out}");
    assert_eq!(role_of(&out, "n"), Some("homograph".into()));
    assert_eq!(role_of(&out, "t"), Some("trans".into()));
    assert_eq!(role_of(&out, "m"), Some("fold".into()));
    assert_eq!(role_of(&out, "pic"), Some("image".into()));
}

/// A page that is not an entry gets no roles: only an entry has a key.
#[test]
fn only_an_entry_gets_roles() {
    let style = Style::of_sheets([]);
    let out = xdict_entry::html_normalized_within(RUN, BASE, "", &style, usize::MAX).unwrap().0;
    assert!(!out.contains("data-xdict-role"), "{out}");
}

/// S5 with the key: a recording only a website holds cannot play, so the word is spoken.
#[test]
fn a_remote_recording_speaks_the_word() {
    let (out, counts) = entry(r#"<a class="s" data-mp3="https://x.example/r.mp3">x</a>"#, "run");
    assert!(out.contains(r#"href="xdict://d/sound/run.tts""#), "{out}");
    assert_eq!(counts.strip.audio_links, 1);
}

/// S13: an image the package does not hold goes; its `alt` stays as text.
#[test]
fn a_missing_image_leaves_its_alt() {
    let style = Style::of_sheets([]);
    let has = |p: &str| p == "here.png";
    let e = Entry { key: "x", resource: Some(&has), is_key: None, strip_off_for_tests: false, original: false };
    let text = r#"<img src="here.png"><img src="gone.png" alt="a picture">"#;
    let (out, counts) = entry_normalized_within(text, BASE, "", &style, &e, usize::MAX).unwrap();
    assert!(out.contains("here.png") && !out.contains("gone.png") && out.contains("a picture"), "{out}");
    assert_eq!(counts.strip.missing_images, 1);
}

/// Hostile shapes stay linear: a deep nest, a wide run of siblings, a long run of `<<` (quadratic before 24629ad:
/// each `<` scanned to the end of the entry, which hung a debug run for over an hour), long texts. Each shape is
/// timed at n and 4n: linear grows about 4 times, quadratic 16. A ratio, not a clock, so a loaded machine cannot
/// fail it.
#[test]
fn hostile_entries_stay_linear() {
    type Shape = fn(usize) -> String;
    let shapes: [(&str, Shape); 4] = [
        ("deep", |n| "<span>".repeat(n) + &"run ".repeat(n / 10) + &"</span>".repeat(n)),
        ("wide", |n| "<b>run</b><i></i><p style=\"display:none\">the same twenty characters</p>".repeat(n / 4)),
        ("arrows", |n| "<<".repeat(n * 4)),
        ("texty", |n| format!("<div>{}</div>", "<span>a run of text words that is long enough</span>".repeat(n / 4))),
    ];
    for (name, shape) in shapes {
        let time = |n: usize| {
            let text = shape(n);
            let started = std::time::Instant::now();
            entry(&text, "run");
            started.elapsed().as_secs_f64()
        };
        time(2_000);
        let (small, large) = (time(5_000).max(1e-3), time(20_000));
        assert!(large / small < 10.0, "{name}: {small:.3}s at n, {large:.3}s at 4n");
    }
}

/// A headword is not a transcription: stress marks and syllable dots on it do not make it one. An undelimited
/// transcription beside the headword stays marked (ODE's `ˈpet`), even when it spells the key.
#[test]
fn a_headword_with_stress_marks_is_not_a_transcription() {
    let phon = |out: &str| out.matches("data-xdict-phon ").count();
    // CALD: the headword, stressed.
    let (out, c) = entry(r#"<b class="hw">ˌcounty ˈcouncil</b> <span class="d">a council</span>"#, "county council");
    assert_eq!((phon(&out), c.transcriptions.marked), (0, 0), "{out}");
    // OED: stressed inside the word, case and syllable dots folded.
    let (out, _) = entry(r#"<h1 class="hw">Cata·ˈractical</h1> <span class="d">of a cataract</span>"#, "cataractical");
    assert_eq!(phon(&out), 0, "{out}");
    // A part inside the headword's element.
    let (out, _) =
        entry(r#"<b class="hw">ˌcounty <i>ˈcouncil</i></b> <span class="d">a council</span>"#, "county council");
    assert_eq!(phon(&out), 0, "{out}");
    // ODE: the transcription undelimited beside a plain headword.
    let (out, c) =
        entry(r#"<b class="hw">pet</b> <span class="ph">ˈpɛt</span> <span class="d">an animal</span>"#, "pet");
    assert!(out.contains(r#"data-xdict-phon-system="none" class="ph""#), "{out}");
    assert_eq!(c.transcriptions.marked, 1);
    let (out, _) =
        entry(r#"<b class="hw">pet</b> <span class="ph">ˈpet</span> <span class="d">an animal</span>"#, "pet");
    assert!(out.contains(r#"data-xdict-phon-system="none" class="ph""#), "{out}");
}

/// A text that is a key of the edition once its stress marks are gone is a headword or a derived form written with
/// stress (CALD's phrases, Chambers' derived forms), not a transcription; except the record's own key as one word
/// stressed only before it (`ˈpet`).
#[test]
fn a_key_of_the_edition_written_with_stress_is_not_a_transcription() {
    let keys = ["county council", "autobiographer", "pet", "petal"];
    let is_key = |k: &str| keys.iter().any(|x| x.eq_ignore_ascii_case(k));
    let marked = |text: &str, key: &str| {
        let style = Style::of_sheets([".pos{font-style:italic}"]);
        let e = Entry { key, resource: None, is_key: Some(&is_key), strip_off_for_tests: false, original: false };
        entry_normalized_within(text, BASE, "", &style, &e, usize::MAX).unwrap().1.transcriptions.marked
    };
    // The record's headword in its own element first, as the dictionaries write it.
    let marked_in = |inner: &str, key: &str| {
        marked(
            &format!(r#"<b class="hw">{key}</b> <span class="d">a sense</span> <span class="r">{inner}</span>"#),
            key,
        )
    };
    // CALD: a phrase inside another record, stressed only before its words.
    assert_eq!(marked_in("ˌcounty ˈcouncil", "county"), 0);
    // Chambers: a derived form stressed inside the word.
    assert_eq!(marked_in("autobiogˈrapher", "autobiography"), 0);
    // Another record's key, one word, stressed before it: a headword there, not this record's transcription.
    assert_eq!(marked_in("ˈpet", "petal"), 0);
    // The record's own key, one word, stressed before it: ODE's transcription.
    assert_eq!(marked_in("ˈpet", "pet"), 1);
    // Not a key: a transcription.
    assert_eq!(marked_in("ˈpɛtl̩", "petal"), 1);
    assert_eq!(marked_in("ˌdaʊn ˈvest", "down"), 1);
}

/// The entry's first headword is the lead (unification R, 2026-10-16): the one headword mark precise enough for strong
/// styling (0.92 on the holdout, where headwords as a whole are 0.59). A homograph's headword, written in the same
/// markup as the first (OALD's second `h1.headword` of *bloody*), is a lead too, so every homograph looks the same
/// (WI-11 Q2, 2026-10-17); a headword in other markup (an idiom's) is not.
#[test]
fn the_first_headword_and_its_homographs_are_leads() {
    let two = r#"<div><b class="hw">run</b> <span class="d">to move fast</span></div><div><b class="hw">run</b> <span class="d">to manage</span></div>"#;
    let (out, _) = entry(two, "run");
    assert_eq!(out.matches("data-xdict-lead").count(), 2, "{out}");
    let lead = out.find("data-xdict-lead").unwrap();
    let first = out.find("data-xdict-role=\"headword\"").unwrap();
    assert!(out[..lead].rfind('<') == out[..first].rfind('<'), "the lead is not the first headword: {out}");
    let other = r#"<div><b class="hw">run</b> <span class="d">to move fast</span></div><p><b class="idm">run</b> to manage</p>"#;
    let (out, _) = entry(other, "run");
    assert!(out.matches("data-xdict-role=\"headword\"").count() == 2, "both are headwords: {out}");
    assert_eq!(out.matches("data-xdict-lead").count(), 1, "{out}");
    let (none, _) = entry(r#"<p>no headword here at all, only a sentence of prose.</p>"#, "zzz");
    assert!(!none.contains("data-xdict-lead"), "{none}");
}

/// A line break before anything else in a block goes: the block already starts a line, so the break only drew a blank
/// one (COBUILD-EC's `<div><br>【语法信息】：V n</div>`, WI-11 R8). A break after text stays, and so does one alone in its
/// block, a spacer the dictionary meant.
#[test]
fn a_break_leading_a_block_goes() {
    let cobuild = r#"<div class="caption">If you <b>bank</b> money. <span><div id="g"><div><div><br>【语法信息】：V n</div></div></div></span></div>"#;
    let (out, _) = entry(cobuild, "bank");
    assert!(out.contains(">【语法信息】") && !out.contains("<br>"), "{out}");
    let (after, _) = entry(r#"<div>one<br>two</div>"#, "zzz");
    assert!(after.contains("one<br>two"), "{after}");
    let (spaced, _) = entry(r#"<div> <br>two</div>"#, "zzz");
    assert!(spaced.contains("<div> two</div>"), "{spaced}");
    let (alone, _) = entry(r#"<p>one</p><p><br></p><p>two</p>"#, "zzz");
    assert!(alone.contains("<p><br></p>"), "{alone}");
}

/// Punctuation alone between two blocks stays with the block before it (OED's "," between its Brit. and U.S.
/// pronunciation wrappers stood on a line of its own); inside an inline run it is left where it is.
#[test]
fn punctuation_between_blocks_stays_with_the_block_before() {
    let oed =
        r#"<div class="pw">Brit. /ˈbaŋkə/</div>, <div class="pw">U.S. /ˈbæŋkər/</div><p>a person who keeps a bank</p>"#;
    let (out, _) = entry(oed, "banker");
    assert!(out.contains("/ˈbaŋkə/,"), "{out}");
    assert!(!out.contains("</div>,"), "{out}");
    let (inline, _) = entry(r#"<p><b>run</b>, <i>verb</i></p>"#, "run");
    assert!(inline.contains("</b>, <i"), "{inline}");
}

/// Space alone between two blocks, a no-break space included, is a line of its own: it goes (OED's "&nbsp;" between
/// its Brit. and U.S. pronunciation wrappers drew a blank line). Between inline elements it is a word space and stays.
#[test]
fn space_alone_between_two_blocks_goes() {
    let oed = r#"<div class="pw">Brit. /ˈbaŋkə/</div>,&nbsp;<div class="pw">U.S. /ˈbæŋkər/</div>"#;
    let (out, _) = entry(oed, "banker");
    assert!(out.contains("</div><div"), "{out}");
    let (raw, _) = entry("<div>Brit. /a/</div>\u{a0} <div>U.S. /b/</div>", "banker");
    assert!(raw.contains("</div><div"), "{raw:?}");
    let (inline, _) = entry("<p><b>run</b>&nbsp;<i>verb</i></p>", "run");
    assert!(inline.contains("</b>&nbsp;<i"), "{inline}");
    let (word, _) = entry("<div>one</div> two <div>three</div>", "one");
    assert!(word.contains("</div> two <div"), "{word}");
}

/// The lead is never a link: LDOCE's homograph strip (`<a href="#…_2">bloody²</a>`) is navigation, and the entry's own
/// headword after it is the lead.
#[test]
fn the_lead_is_never_a_link() {
    let ldoce = concat!(
        r##"<div class="chwd"><a href="#LDOCE6_bloody_1"><span class="hw">bloody<sup>1</sup></span> <i>adjective, adverb</i></a>"##,
        r##"<a href="#LDOCE6_bloody_2"><span class="hw">bloody<sup>2</sup></span> <i>adjective</i></a></div>"##,
        r#"<span class="entry"><span class="entryhead"><span class="hw">bloody</span>"#,
        r#"<span class="homnum">1</span> <span class="pos">adjective</span></span> used to emphasize what you are saying</span>"#
    );
    let (out, _) = entry(ldoce, "bloody");
    // The strip's links are headwords, and none of them is the lead (the entry's own headword, where the core reads
    // one, is: LDOCE's "blood‧y" in the gallery's holdout).
    assert!(out.contains(r##"<a data-xdict-role="headword" href="#LDOCE6_bloody_1">"##), "{out}");
    let strip = &out[..out.find("</div>").unwrap()];
    assert!(!strip.contains("data-xdict-lead"), "a link is the lead: {out}");
    // MWU: the strip's items hold the links (`<li><a href="#mwu_…">¹finesse (noun)</a></li>`); an item that is only a
    // link is one too.
    let mwu = concat!(
        r##"<ul class="tab multi"><li><a href="#mwu_1"><span class="entry-text"><sup>1</sup>finesse</span>"##,
        r##"<span class="word-class">(noun)</span></a></li><li><a href="#mwu_2"><span class="entry-text"><sup>2</sup>finesse</span>"##,
        r##"<span class="word-class">(verb)</span></a></li></ul><div class="main"><div id="mwu_1">"##,
        r#"<h1 class="hw">fi·nesse</h1><span class="fl">noun</span> refinement or delicacy of workmanship</div></div>"#
    );
    let (out, _) = entry(mwu, "finesse");
    let strip = &out[..out.find("</ul>").unwrap()];
    assert!(strip.contains("data-xdict-role=\"headword\""), "{out}");
    assert!(!strip.contains("data-xdict-lead"), "an item that is only a link is the lead: {out}");
}

/// A space between an inline element and the full stop after it goes (COBUILD's "is called a <b>row</b> ."). Only a
/// lone full stop: an ellipsis, a comma (OED's own "bankier , banquier") and space after a block stay as written.
#[test]
fn a_space_before_a_full_stop_after_an_inline_element_goes() {
    let (out, _) = entry("<div>each line of seats is called a <b>row</b> . <span>next</span></div>", "row");
    assert!(out.contains("</b>. <span"), "{out}");
    let (nbsp, _) = entry("<p>called a <b>row</b>\u{a0}.</p>", "row");
    assert!(nbsp.contains("</b>.</p>"), "{nbsp:?}");
    let (ellipsis, _) = entry("<p>a <i>row</i> ...of cottages</p>", "row");
    assert!(ellipsis.contains("</i> ...of"), "{ellipsis}");
    let (comma, _) = entry("<p><i>bankier</i> , banquier</p>", "banker");
    assert!(comma.contains("</i> , banquier"), "{comma}");
}

/// An empty element goes with its blank content (OED's `<span class="ieWhitespace">&nbsp;</span>` left a no-break space
/// beside the source's own: "banc␣␣␣bench"); one space stays, so words it separated stay apart.
#[test]
fn an_empty_element_goes_with_its_blank_content() {
    let (out, _) = entry("<p><em>banc</em> <span class=\"w\">\u{a0}</span> bench, a<span>\u{a0}</span>b</p>", "banc");
    assert!(!out.contains('\u{a0}'), "{out:?}");
    assert!(out.contains("a b"), "{out:?}");
}
