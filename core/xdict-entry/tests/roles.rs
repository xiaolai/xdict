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
