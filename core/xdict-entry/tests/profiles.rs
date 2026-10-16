//! Per-markup role tables (`roles/profiles.rs`): an edition whose sheets carry a known markup's classes has its part
//! of speech named by that markup's own selectors, marked sure (`data-xdict-sure="pos"`) for strong styling; there the
//! generic rule writes no part of speech. An edition no table names keeps the generic rule, unmarked as sure.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing, clippy::string_slice)]

use xdict_entry::{Entry, Style, entry_normalized_within};

const BASE: &str = "xdict://d/";

/// Classes of Longman's sheets (`chwd`, `collobox`), as a rule's subject: what names the markup.
const LONGMAN: &str = ".chwd{font-weight:bold}.collobox{border:1px solid}.pos{font-style:italic}";

fn render(sheet: &str, text: &str, key: &str) -> String {
    let style = Style::of_sheets([sheet]);
    entry_normalized_within(
        text,
        BASE,
        "",
        &style,
        &Entry { key, resource: None, is_key: None, strip_off_for_tests: false, original: false },
        usize::MAX,
    )
    .unwrap()
    .0
}

/// The start tag of the first element of class `class`.
fn tag_of<'a>(out: &'a str, class: &str) -> &'a str {
    let at = out.find(&format!("class=\"{class}\"")).unwrap_or_else(|| panic!("{class} not in {out}"));
    let from = out[..at].rfind('<').unwrap();
    let end = at + out[at..].find('>').unwrap();
    &out[from..end]
}

const ENTRY: &str = r#"<div><span class="hw">run</span> <span class="pos">verb</span> <i class="gen">noun</i> <span class="d">to move fast on foot</span></div>"#;

#[test]
fn a_known_markup_names_its_part_of_speech_sure() {
    let out = render(LONGMAN, ENTRY, "run");
    let pos = tag_of(&out, "pos");
    assert!(pos.contains(r#"data-xdict-role="pos""#), "{out}");
    assert!(pos.contains(r#"data-xdict-sure="pos""#), "{out}");
    // The generic rule's guess is not written where the markup's table speaks.
    assert!(!tag_of(&out, "gen").contains(r#"data-xdict-role="pos""#), "{out}");
}

#[test]
fn an_unknown_markup_keeps_the_generic_rule_unsure() {
    let out = render(".pos{font-style:italic}", ENTRY, "run");
    assert!(tag_of(&out, "pos").contains(r#"data-xdict-role="pos""#), "{out}");
    assert!(tag_of(&out, "gen").contains(r#"data-xdict-role="pos""#), "{out}");
    assert!(!out.contains("data-xdict-sure"), "{out}");
}

/// A table that asks for the part-of-speech words (NOAD's `.p` also holds `obj.`) leaves other text alone.
#[test]
fn a_table_that_asks_for_the_words_leaves_other_text() {
    let sheet = ".m1{margin:0}.m2{margin:0}.opt{color:gray}.p{font-style:italic}";
    let out =
        render(sheet, r#"<div><b>run</b> <span class="p">v.</span> <i><span class="p x">obj.</span></i></div>"#, "run");
    assert!(tag_of(&out, "p").contains(r#"data-xdict-sure="pos""#), "{out}");
    assert!(!tag_of(&out, "p x").contains("data-xdict-sure"), "{out}");
}

/// The table decides inside a link too: LDOCE's word lists write their parts of speech in their links.
#[test]
fn a_part_of_speech_in_a_link_is_the_tables() {
    let out = render(
        LONGMAN,
        r#"<div><b>run</b> <a href="entry://walk">walk <span class="pos">verb</span></a></div>"#,
        "run",
    );
    assert!(tag_of(&out, "pos").contains(r#"data-xdict-sure="pos""#), "{out}");
}
