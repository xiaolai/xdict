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

/// A sense number the markup's table names is sure (`data-xdict-sure="sensenum"`); the generic rule's guesses of a
/// sense number are not written there.
#[test]
fn a_known_markup_names_its_sense_numbers_sure() {
    let out = render(
        LONGMAN,
        r#"<div><span class="hw">run</span> <span class="sensenum">2</span> <span class="d">to move fast</span> <b class="bn">3.</b> <span class="d">to flow</span></div>"#,
        "run",
    );
    let n = tag_of(&out, "sensenum");
    assert!(n.contains(r#"data-xdict-role="sensenum""#), "{out}");
    assert!(n.contains(r#"data-xdict-sure="sensenum""#), "{out}");
    assert!(!tag_of(&out, "bn").contains(r#"data-xdict-role="sensenum""#), "{out}");
}

/// A table's sense-number selector holds only numbers: PEU's `hang` also holds a dash; a section number of three
/// digits ("379") and a sub-sense ("1.1") are numbers.
#[test]
fn a_sense_number_selector_takes_only_numbers() {
    let peu = ".peu-quote{margin:0}.peu-btns{margin:0}.hang{float:left}";
    let out = render(
        peu,
        r#"<div><b>will</b> <span class="hang">379</span> <span class="hang x">–</span> <span class="hang y">1.1</span> <span>the text of the section that follows</span></div>"#,
        "will",
    );
    assert!(tag_of(&out, "hang").contains(r#"data-xdict-sure="sensenum""#), "{out}");
    assert!(tag_of(&out, "hang y").contains(r#"data-xdict-sure="sensenum""#), "{out}");
    assert!(!tag_of(&out, "hang x").contains("data-xdict-sure"), "{out}");
}

/// The generic rule's sense numbers still stand where no table names the markup, unmarked as sure.
#[test]
fn an_unknown_markup_keeps_its_sense_numbers_unsure() {
    let out = render(
        ".sensenum{font-weight:bold}",
        r#"<div><span class="hw">run</span> <span class="sensenum">2</span> <span class="d">to move fast</span></div>"#,
        "run",
    );
    assert!(tag_of(&out, "sensenum").contains(r#"data-xdict-role="sensenum""#), "{out}");
    assert!(!out.contains("data-xdict-sure"), "{out}");
}

/// An example the markup's table names is sure (`data-xdict-sure="example"`); the headword inside it is not marked.
#[test]
fn a_known_markup_names_its_examples_sure() {
    let macmillan = ".boxsensefull{margin:0}.base-form{font-weight:bold}.part-of-speech{font-style:italic}";
    let out = render(
        macmillan,
        r#"<div><span class="base-form">run</span> <span class="def">to move fast</span> <p class="example">She <b class="hl">ran</b> home.</p></div>"#,
        "run",
    );
    assert!(tag_of(&out, "example").contains(r#"data-xdict-sure="example""#), "{out}");
    assert!(!tag_of(&out, "hl").contains("data-xdict-sure"), "{out}");
}

/// A section heading the markup's table names is sure (`data-xdict-sure="heading"`).
#[test]
fn a_known_markup_names_its_headings_sure() {
    let out = render(
        LONGMAN,
        r#"<div><span class="hw">run</span> <span class="d">to move fast</span> <div class="box"><span class="popheader popexa">EXAMPLES FROM THE CORPUS</span> <span class="ex">They ran.</span></div></div>"#,
        "run",
    );
    assert!(tag_of(&out, "popheader popexa").contains(r#"data-xdict-sure="heading""#), "{out}");
}

/// OALD's idioms heading is a section heading; Macmillan's thesaurus title (`span.h2`), a link's label before its
/// list of linked words, is not marked.
#[test]
fn oald_idioms_is_a_heading_and_a_linked_title_is_not() {
    let oald = ".oup_icons{margin:0}.ox3ksym_a1{margin:0}.pos{font-style:italic}.idioms_heading{color:teal}";
    let out = render(
        oald,
        r#"<div><h1 class="headword">bloody</h1> <span class="def">covered with blood</span> <div class="idioms"><span class="idioms_heading">Idioms</span> <span class="idm">bloody well</span></div></div>"#,
        "bloody",
    );
    assert!(tag_of(&out, "idioms_heading").contains(r#"data-xdict-sure="heading""#), "{out}");
    let med =
        ".boxsensefull{margin:0}.base-form{font-weight:bold}.part-of-speech{font-style:italic}.h2{font-weight:bold}";
    let out = render(
        med,
        r#"<div><span class="base-form">flagellation</span> <span class="def">hitting yourself</span> <a href="entry://x"><span class="h2">Religious ceremonies and practices:</span></a><span class="synonyms"><a href="entry://anoint">anoint</a>, <a href="entry://bless">bless</a></span></div>"#,
        "flagellation",
    );
    assert!(!tag_of(&out, "h2").contains("data-xdict-sure"), "{out}");
}

/// A translation the markup's table names is sure (`data-xdict-sure="trans"`), a sense's or an example's, which the
/// generic rule's role tells apart: ODECN's `div.cn_def` and `p.cn`.
#[test]
fn a_known_markup_names_its_translations_sure() {
    let odecn = ".odecn{margin:0}.pos_inflections{margin:0}.pos{font-style:italic}";
    let out = render(
        odecn,
        r#"<div class="odecn"><span class="hw">will</span> <div class="defs"><span class="num">1</span><div class="en_def">expressing the future tense</div><div class="cn_def">表示一般将来时</div><div class="example"><p class="en">you will regret it when you are older.</p><p class="cn">等你长大些就会后悔的。</p></div></div></div>"#,
        "will",
    );
    assert!(tag_of(&out, "cn_def").contains(r#"data-xdict-sure="trans""#), "{out}");
    let cn = tag_of(&out, "cn");
    assert!(cn.contains(r#"data-xdict-role="example-trans""#), "{out}");
    assert!(cn.contains(r#"data-xdict-sure="trans""#), "{out}");
}

/// Where a table names no examples (Collins English Dictionary's), the generic rule's examples stand, unsure.
#[test]
fn a_table_without_examples_keeps_the_generic_ones() {
    let ced = ".dictentry{margin:0}.gramgrp{margin:0}.pos{font-style:italic}";
    let out = render(
        ced,
        r#"<div><span class="hw">run</span> <span class="d">to move fast</span> <span class="example">She ran home quickly after school.</span></div>"#,
        "run",
    );
    assert!(!tag_of(&out, "example").contains(r#"data-xdict-sure="example""#), "{out}");
}

/// LDOCE's examples (`span.example`) are its table's, sure: one look of examples in every dictionary (WI-11, owner
/// 2026-10-17). The headword inside one is not marked; its English–Chinese edition's translation inside one stays a
/// translation.
#[test]
fn ldoce_names_its_examples_sure() {
    let out = render(
        LONGMAN,
        r#"<div><span class="hw">run</span> <span class="d">to move fast</span> <span class="example">She <span class="nodeword">ran</span> home quickly.<example>她很快跑回家。</example></span></div>"#,
        "run",
    );
    assert!(tag_of(&out, "example").contains(r#"data-xdict-sure="example""#), "{out}");
    assert!(!tag_of(&out, "nodeword").contains("data-xdict-sure"), "{out}");
    let tr = &out[out.find("<example").unwrap()..];
    assert!(tr[..tr.find('>').unwrap()].contains(r#"data-xdict-sure="trans""#), "{out}");
}

/// What a table names as not an example's own text keeps the dictionary's look inside one (`data-xdict-sure="keep"`):
/// OALD's gloss in an example, "(= Certainly not!)". The same class outside an example is not marked.
#[test]
fn a_gloss_inside_an_example_is_kept() {
    let oald = ".oup_icons{margin:0}.ox3ksym_a1{margin:0}.pos{font-style:italic}";
    let out = render(
        oald,
        r#"<div><h1 class="headword">bloody</h1> <span class="def">used to emphasize <span class="gloss">(= rude)</span></span> <ul><li><span class="x">Not bloody likely! <span class="gloss">(= Certainly not!)</span></span></li></ul></div>"#,
        "bloody",
    );
    assert!(tag_of(&out, "x").contains(r#"data-xdict-sure="example""#), "{out}");
    let first = out.find(r#"class="gloss""#).unwrap();
    let second = first + 1 + out[first + 1..].find(r#"class="gloss""#).unwrap();
    let start = |at: usize| &out[out[..at].rfind('<').unwrap()..at + out[at..].find('>').unwrap()];
    assert!(!start(first).contains("data-xdict-sure"), "{out}");
    assert!(start(second).contains(r#"data-xdict-sure="keep""#), "{out}");
}

/// A block inside an example whose text is Chinese, digits and punctuation, with no Latin letter, is the example's
/// translation, sure: COBUILD's unclassed `<p>` after the English one ("其本质设计和100多年前…").
#[test]
fn a_chinese_block_inside_an_example_is_its_translation() {
    let cobuild = ".collins_en_cn{margin:0}.tips_box{margin:0}.st{font-style:italic}";
    let out = render(
        cobuild,
        r#"<div class="collins_en_cn"><span class="hw">basic</span> <span class="st">ADJ</span> <ul><li><p class="en">The basic design changed little in 100 years.</p><p class="zh"><span class="chinese-text">其本质设计和</span>100<span class="chinese-text">多年前相差无几。</span></p></li></ul></div>"#,
        "basic",
    );
    let li = &out[out.find("<li").unwrap()..];
    assert!(li[..li.find('>').unwrap()].contains(r#"data-xdict-sure="example""#), "{out}");
    assert!(tag_of(&out, "zh").contains(r#"data-xdict-sure="trans""#), "{out}");
    assert!(!tag_of(&out, "en").contains("data-xdict-sure"), "{out}");
}

/// COBUILD's example is a list item whose text is in blocks inside it; a list item with text of its own is not one:
/// COBUILD-EC's sense menu ("1. FINANCE AND STORAGE 金融；储藏", gallery 2026-10-17) and any other list of words.
#[test]
fn a_list_item_with_text_of_its_own_is_not_a_cobuild_example() {
    let cobuild = ".collins_en_cn{margin:0}.tips_box{margin:0}.st{font-style:italic}";
    let out = render(
        cobuild,
        r#"<div class="collins_en_cn"><span class="hw">bank</span> <ul class="menu"><li class="m">1. FINANCE AND STORAGE 金融；储藏</li><li class="m">2. AREAS AND MASSES 地区</li></ul> <span class="st">N-COUNT</span> <ul><li class="ex"><p>Which bank offers you the service?</p><p>哪家银行提供服务？</p></li></ul></div>"#,
        "bank",
    );
    assert!(!tag_of(&out, "m").contains("data-xdict-sure"), "{out}");
    assert!(tag_of(&out, "ex").contains(r#"data-xdict-sure="example""#), "{out}");
}

/// Apple's phrases and derived words (`span.l`, `span.drv`) are weight 600 (parity P24): a run-on head a markup's
/// table names is sure (`data-xdict-sure="subhead"`). OALD's idioms and phrasal verbs, LDOCE's phrases in a sense and
/// its derived words, ODE's and ODECN's derived words.
#[test]
fn a_known_markup_names_its_run_on_heads_sure() {
    let oald = ".oup_icons{margin:0}.ox3ksym_a1{margin:0}.pos{font-style:italic}";
    let out = render(
        oald,
        r#"<div><h1 class="headword">bloody</h1> <span class="def">covered with blood</span> <div class="idioms"><span class="idm">bloody well</span> <span class="def">used to emphasize</span></div> <span class="pv">bleed out</span></div>"#,
        "bloody",
    );
    assert!(tag_of(&out, "idm").contains(r#"data-xdict-sure="subhead""#), "{out}");
    assert!(tag_of(&out, "pv").contains(r#"data-xdict-sure="subhead""#), "{out}");
    let out = render(
        LONGMAN,
        r#"<div><span class="hw">apple</span> <span class="sense"><span class="sensenum">2</span><span class="lexunit">be the apple of somebody’s eye</span><span class="def"> to be loved very much</span></span><span class="runon"><span class="deriv"><span>—</span>appleness</span><span class="pos"> noun</span></span></div>"#,
        "apple",
    );
    assert!(tag_of(&out, "lexunit").contains(r#"data-xdict-sure="subhead""#), "{out}");
    assert!(tag_of(&out, "deriv").contains(r#"data-xdict-sure="subhead""#), "{out}");
    let odecn = ".odecn{margin:0}.pos_inflections{margin:0}.pos{font-style:italic}";
    let out = render(
        odecn,
        r#"<div class="odecn"><span class="hw">abject</span> <div class="derivatives"><div class="label">Derivatives</div><div class="body"> <h3 class="inflection">abjectly</h3><span class="pos">adverb</span></div></div></div>"#,
        "abject",
    );
    assert!(tag_of(&out, "inflection").contains(r#"data-xdict-sure="subhead""#), "{out}");
    let ode = ".a8e{margin:0}.aej{margin:0}.xno{font-style:italic}";
    let out = render(
        ode,
        r#"<div><span class="hw">abject</span> <span class="xno">adjective</span> <span class="d">without pride</span> <div class="b6i"><div class="ysl"><h4 class="drv">abjectly</h4></div> <span class="xno">adverb</span></div></div>"#,
        "abject",
    );
    assert!(tag_of(&out, "drv").contains(r#"data-xdict-sure="subhead""#), "{out}");
}

/// A heading a markup's table names opens its section as a generic heading does (parity P25): ODECN's "Origin" box is
/// the etymology, which the frame gives Apple's look.
#[test]
fn a_sure_heading_names_its_section() {
    let odecn = ".odecn{margin:0}.pos_inflections{margin:0}.pos{font-style:italic}";
    let out = render(
        odecn,
        r#"<div class="odecn"><span class="hw">happy</span> <span class="pos">adjective</span> <div class="en_def">feeling pleasure</div> <div class="origin"><div class="label">Origin</div><div class="body">Middle English (in the sense ‘lucky’): from the noun hap.</div></div></div>"#,
        "happy",
    );
    assert!(tag_of(&out, "label").contains(r#"data-xdict-sure="heading""#), "{out}");
    let origin = tag_of(&out, "origin");
    assert!(
        origin.contains(r#"data-xdict-role="section""#) && origin.contains(r#"data-xdict-section="etym""#),
        "{out}"
    );
}
