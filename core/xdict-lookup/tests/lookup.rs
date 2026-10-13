//! Lookup through an index built under XDict's policy, on dictionaries the test writer makes: the shapes real
//! dictionaries have (`core-api.md` findings 8, 10 and 11) and Codex's objections 19–23.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use std::sync::Arc;

use xdict_lookup::{How, Mode, Policy, Problem, matches, resolve, suggest};
use xdict_mdx::{Budget, File, Kind};
use xdict_mdx_writer::{self as writer, Entry, Spec};

fn file(entries: &[(&str, &str)]) -> File {
    let entries: Vec<Entry> = entries.iter().map(|(k, v)| Entry::text(k, v)).collect();
    let bytes = writer::write(&Spec::mdx(), &entries).unwrap();
    let index = File::build_index(&bytes, Some(Kind::Mdx), [1; 32], &Policy).unwrap();
    File::with_index(Box::new(bytes), Some(Kind::Mdx), Box::new(index), [1; 32], Arc::new(Policy)).unwrap().unwrap()
}

fn keys(file: &File, query: &str, mode: Mode) -> Vec<(String, How)> {
    matches(file, query, mode).unwrap().into_iter().map(|(i, how)| (file.key(i).unwrap().into_owned(), how)).collect()
}

fn names(file: &File, chain: &[usize]) -> Vec<String> {
    chain.iter().map(|&i| file.key(i).unwrap().into_owned()).collect()
}

/// Codex 19: the tier each key is found by, for the superscript and accent fixtures.
#[test]
fn tiers_for_homographs_formulas_and_accents() {
    let f = file(&[("AAA", "a"), ("AAA²", "b"), ("AAA2", "c"), ("H²O", "d"), ("cafe\u{301}", "e"), ("café", "f")]);
    assert_eq!(keys(&f, "AAA", Mode::Reader), [("AAA".into(), How::Exact), ("AAA²".into(), How::Unmarked)]);
    assert_eq!(keys(&f, "AAA²", Mode::Reader), [("AAA²".into(), How::Exact), ("AAA".into(), How::Unmarked)]);
    assert_eq!(keys(&f, "AAA2", Mode::Reader), [("AAA2".into(), How::Exact)], "a homograph number is not a 2");
    assert_eq!(keys(&f, "H2O", Mode::Reader), [("H²O".into(), How::Unmarked)]);
    let cafe: Vec<String> = keys(&f, "cafe", Mode::Reader).into_iter().map(|(k, _)| k).collect();
    assert_eq!(cafe.len(), 2, "decomposed and precomposed: {cafe:?}");
    assert_eq!(keys(&f, "café", Mode::Reader)[0], ("café".into(), How::Exact));
}

/// Codex 20: a link is matched at tier 1 alone; a reader's query at both.
#[test]
fn a_link_never_falls_into_tier_2() {
    let f = file(&[("abbé", "an abbot")]);
    assert_eq!(keys(&f, "abbe", Mode::Reader), [("abbé".into(), How::Unmarked)]);
    assert!(keys(&f, "abbe", Mode::Link).is_empty());
}

/// Codex 21 and finding 8: internal keys are reached by links, never offered to a reader.
#[test]
fn internal_keys_are_links_only() {
    let mut entries: Vec<(String, String)> = (0..150).map(|i| (format!("@sense{i}"), format!("sense {i}"))).collect();
    entries.extend((0..1000).map(|i| (format!("word{i}"), "w".to_owned())));
    entries.push(("sense1".into(), "a public sense".into()));
    let pairs: Vec<(&str, &str)> = entries.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
    let f = file(&pairs);
    assert_eq!(keys(&f, "sense1", Mode::Reader), [("sense1".into(), How::Exact)], "@sense1 folds to sense1");
    assert_eq!(keys(&f, "@sense1", Mode::Link)[0], ("@sense1".into(), How::Exact));
    let mut out = Vec::new();
    suggest(&f, "sens", 500, &mut out).unwrap();
    assert_eq!(out, ["sense1"]);
}

fn hits(f: &File, query: &str) -> xdict_lookup::Resolved {
    resolve(f, query, Mode::Reader, &mut Budget::lookup()).unwrap()
}

/// Codex 22: a diamond gives its end once, by the shortest way, and is not a loop.
#[test]
fn a_diamond_is_one_hit_and_no_loop() {
    let f = file(&[("A", "@@@LINK=B\r\n@@@LINK=C"), ("B", "@@@LINK=D"), ("C", "@@@LINK=D"), ("D", "the end")]);
    let r = hits(&f, "A");
    assert_eq!(r.hits.len(), 1, "{r:?}");
    let How::Redirect { chain } = &r.hits[0].how else { panic!("{r:?}") };
    assert_eq!(names(&f, chain), ["A", "B", "D"]);
    assert!(r.hits[0].problems.is_empty() && r.problems.is_empty(), "{r:?}");
}

/// Codex 22: a self-loop and a dangling target are problems; with no hit left, the page carries them.
#[test]
fn loops_and_dangling_targets_are_data() {
    let f = file(&[("A", "@@@LINK=A"), ("B", "@@@LINK=nowhere")]);
    let r = hits(&f, "A");
    assert!(r.hits.is_empty());
    assert!(matches!(&r.problems[..], [Problem::Loop { chain }] if names(&f, chain) == ["A", "A"]), "{r:?}");
    let r = hits(&f, "B");
    assert!(matches!(&r.problems[..], [Problem::Dangling { target, .. }] if target == "nowhere"), "{r:?}");
}

/// Codex 22: a key that is both an entry and a redirect gives both; a target also matched directly is given
/// once, as matched.
#[test]
fn a_key_both_entry_and_redirect_gives_both() {
    let f = file(&[("run", "an entry"), ("run", "@@@LINK=sprint"), ("sprint", "to run fast")]);
    let r = hits(&f, "run");
    let got: Vec<(String, bool)> =
        r.hits.iter().map(|h| (f.key(h.key).unwrap().into_owned(), matches!(h.how, How::Redirect { .. }))).collect();
    assert_eq!(got, [("run".into(), false), ("sprint".into(), true)]);
    let f = file(&[("a", "@@@LINK=b"), ("b", "the b")]);
    let both = resolve(&f, "a", Mode::Reader, &mut Budget::lookup()).unwrap();
    assert_eq!(both.hits.len(), 1);
}

/// A chain longer than the hop limit stops with a problem, not a hang.
#[test]
fn a_long_chain_stops_at_the_hop_limit() {
    let names: Vec<String> = (0..=xdict_lookup::HOPS + 2).map(|i| format!("k{i:02}")).collect();
    let mut entries: Vec<(String, String)> =
        names.windows(2).map(|w| (w[0].clone(), format!("@@@LINK={}", w[1]))).collect();
    entries.push((names.last().unwrap().clone(), "the end".into()));
    let pairs: Vec<(&str, &str)> = entries.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
    let f = file(&pairs);
    let r = hits(&f, "k00");
    assert!(r.hits.is_empty());
    assert!(matches!(&r.problems[..], [Problem::Limit { .. }]), "{r:?}");
}

#[test]
fn suggestions_are_folded_order_once_each() {
    let f = file(&[("Run", "a"), ("run", "b"), ("run", "c"), ("rune", "d"), ("café", "e")]);
    let mut out = Vec::new();
    suggest(&f, "RU", 10, &mut out).unwrap();
    assert_eq!(out, ["Run", "run", "rune"]);
    let mut out = Vec::new();
    suggest(&f, "", 2, &mut out).unwrap();
    assert_eq!(out, ["café", "Run"]);
}

/// A record may name any number of targets within the byte budget: each costs a search, so one key's targets
/// are followed only to the fan-out limit, and every target of a lookup counts against one step limit.
#[test]
fn many_targets_cost_at_most_the_limits() {
    let many: String = (0..5_000).map(|i| format!("@@@LINK=missing{i}\r\n")).collect();
    let f = file(&[("a", many.as_str())]);
    let r = hits(&f, "a");
    assert!(r.problems.len() <= xdict_lookup::FAN_OUT + 1, "{} problems", r.problems.len());
    assert!(matches!(r.problems.last(), Some(Problem::Limit { .. })), "{:?}", r.problems.last());

    let some: String = (0..1_000).map(|i| format!("@@@LINK=missing{i}\r\n")).collect();
    let entries: Vec<(&str, &str)> = (0..(xdict_lookup::STEPS / 1_000 + 1)).map(|_| ("a", some.as_str())).collect();
    let f = file(&entries);
    let refused = resolve(&f, "a", Mode::Reader, &mut Budget::lookup());
    assert!(matches!(refused, Err(xdict_mdx::Error::TooLarge(_))), "{:?}", refused.map(|r| r.problems.len()));
}

/// A redirect lands on the keys spelt as its target where there are any, not on every key folded with it: in
/// COBUILD, `'m` → `m` would otherwise land on `M`, `-m` and the rest, each a redirect again, and `A` → `a`
/// would land on `A` itself and look like a loop.
#[test]
fn a_redirect_lands_on_its_exact_spelling() {
    let f = file(&[
        ("A", "@@@LINK=a"),
        ("a", "the letter"),
        ("'m", "@@@LINK=m"),
        ("m", "the letter m"),
        ("M", "@@@LINK=m"),
    ]);
    let r = resolve(&f, "A", Mode::Link, &mut Budget::lookup()).unwrap();
    assert!(r.problems.is_empty() && r.hits.iter().all(|h| h.problems.is_empty()), "{r:?}");
    let r = resolve(&f, "'m", Mode::Link, &mut Budget::lookup()).unwrap();
    let got: Vec<String> = r.hits.iter().map(|h| f.key(h.key).unwrap().into_owned()).collect();
    assert_eq!(got, ["m"], "{r:?}");
    assert!(r.problems.is_empty() && r.hits.iter().all(|h| h.problems.is_empty()), "{r:?}");
    let f = file(&[("x", "@@@LINK=Y"), ("y", "only folded")]);
    let r = resolve(&f, "x", Mode::Link, &mut Budget::lookup()).unwrap();
    assert_eq!(r.hits.len(), 1, "with no exact spelling, folded keys are landed on: {r:?}");
}

/// A hit reached again by a shorter way takes that way's chain and that way's problems together: a chain from
/// one matched key never carries the problems of another's. The longer way's problem, left with no hit, is the
/// page's.
#[test]
fn a_shorter_way_brings_its_own_problems() {
    let f = file(&[
        ("run", "@@@LINK=mid\r\n@@@LINK=nowhere"),
        ("RUN", "@@@LINK=end"),
        ("mid", "@@@LINK=end"),
        ("end", "the end"),
    ]);
    let r = hits(&f, "run");
    assert_eq!(r.hits.len(), 1, "{r:?}");
    let How::Redirect { chain } = &r.hits[0].how else { panic!("{r:?}") };
    assert_eq!(names(&f, chain), ["RUN", "end"]);
    assert!(r.hits[0].problems.is_empty(), "the shorter way met no problem: {r:?}");
    assert!(
        matches!(&r.problems[..], [Problem::Dangling { target, .. }] if target == "nowhere"),
        "the longer way's problem is kept, on the page: {r:?}"
    );
}

/// Each record is read once per lookup: a loop is caught before its key is read again, and two ways meeting at
/// one key read it once. A self-loop under a one-record budget is a loop, not a lookup too large.
#[test]
fn a_record_is_read_once_per_lookup() {
    let f = file(&[("A", "@@@LINK=A")]);
    let r = resolve(&f, "A", Mode::Reader, &mut Budget::new(1 << 20, 1)).unwrap();
    assert!(matches!(&r.problems[..], [Problem::Loop { chain }] if names(&f, chain) == ["A", "A"]), "{r:?}");
    // A → B, A → C, B → D, C → D: A, B, C and D are four records, not five.
    let f = file(&[("A", "@@@LINK=B\r\n@@@LINK=C"), ("B", "@@@LINK=D"), ("C", "@@@LINK=D"), ("D", "the end")]);
    let r = resolve(&f, "A", Mode::Reader, &mut Budget::new(1 << 20, 4)).unwrap();
    assert_eq!(r.hits.len(), 1, "{r:?}");
}

/// A record that is a redirect naming nothing is a dangling redirect, not an entry: matched directly, or landed
/// on along a chain. An empty line beside a named target is passed over.
#[test]
fn a_redirect_naming_nothing_is_dangling_not_an_entry() {
    let f = file(&[("A", "@@@LINK="), ("B", "@@@LINK=A"), ("C", "@@@LINK=\r\n@@@LINK=D"), ("D", "the d")]);
    let r = hits(&f, "A");
    assert!(r.hits.is_empty(), "{r:?}");
    assert!(matches!(&r.problems[..], [Problem::Dangling { target, .. }] if target.is_empty()), "{r:?}");
    let r = hits(&f, "B");
    assert!(r.hits.is_empty(), "{r:?}");
    let [Problem::Dangling { from, target }] = &r.problems[..] else { panic!("{r:?}") };
    assert!(target.is_empty() && names(&f, &[*from]) == ["A"], "{r:?}");
    let r = hits(&f, "C");
    let got: Vec<String> = r.hits.iter().map(|h| f.key(h.key).unwrap().into_owned()).collect();
    assert_eq!(got, ["D"], "{r:?}");
}
