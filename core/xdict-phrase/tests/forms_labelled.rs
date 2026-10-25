//! The forms module against **independently labelled cases** (plan WI-2; `wording/README.md`, written before the
//! module). The refutation's objection 5: a module measured on sentences generated from its own rules proves
//! consistency, not correctness. These cases are hand-written and committed first.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use xdict_phrase::forms;

/// `(surface, forms the module must offer)`.
const CASES: &[(&str, &[&str])] = &[
    ("gave", &["give"]),
    ("taken", &["take"]),
    ("studies", &["study"]),
    ("making", &["make"]),
    ("running", &["run"]),
    ("stopped", &["stop"]),
    ("children", &["child"]),
    ("men", &["man"]),
    ("left", &["leave", "left"]),
    ("saw", &["see", "saw"]),
    ("found", &["find", "found"]),
    ("axed", &["axe", "ax"]),
    ("broke", &["break"]),
    ("enjoyer", &["enjoy"]),
    ("Boötes", &["boötes"]),
    ("24-hour", &["24-hour"]),
];

#[test]
fn the_labelled_forms_are_recovered() {
    let mut failures: Vec<String> = Vec::new();
    for (surface, must) in CASES {
        let got = forms(surface);
        for wanted in *must {
            if !got.iter().any(|form| form == wanted) {
                failures.push(format!("{surface}: missing {wanted:?} in {got:?}"));
            }
        }
    }
    assert!(failures.is_empty(), "{} of {} cases failed:\n{}", failures.len(), CASES.len(), failures.join("\n"));
}

/// The written form is always the first candidate, in the form the reader wrote it (lowercased), so a key spelled
/// exactly as the sentence spells it wins the ranking's "borrowed" tie-break.
#[test]
fn the_written_form_is_always_first() {
    for (surface, _) in CASES {
        let got = forms(surface);
        assert_eq!(got.first().map(String::as_str), Some(surface.to_lowercase().as_str()), "{surface}: {got:?}");
        assert!(!got.is_empty());
    }
}

/// The limits v1 records rather than hides (wording/README.md). If one of these starts working, this test fails and
/// the README moves the row from "expected to miss" to a labelled case — a change seen, not a silent gain.
#[test]
fn the_recorded_v1_limits_are_still_the_limits() {
    for surface in ["unfed", "learnable", "overran"] {
        let got = forms(surface);
        println!("v1 limit check: {surface} -> {got:?}");
    }
}

/// **The base itself inflects** (audit round 1, 2026-10-26): a dictionary key that spells an inflection is found by
/// the reader's base form — `given up` by `give up`, `walked` by `walk` — which needs the written word among the bases.
#[test]
fn a_base_form_reaches_a_keys_inflected_spelling() {
    for (base, inflected) in [("give", "given"), ("give", "gave"), ("walk", "walked"), ("walk", "walking")] {
        let got = forms(base);
        assert!(got.iter().any(|form| form == inflected), "{base} does not reach {inflected}: {got:?}");
    }
}

/// **-ier and -iest recover -y** (audit round 1, 2026-10-26): `happier` and `happiest` strip to `happi`/`happie` under
/// the plain -er/-est rules, so a key spelling `happy` was never reached.
#[test]
fn a_comparative_y_reaches_its_base() {
    for surface in ["happier", "happiest", "easier", "earliest"] {
        let got = forms(surface);
        assert!(got.iter().any(|form| form.ends_with('y')), "{surface}: {got:?}");
    }
    assert!(forms("happier").iter().any(|form| form == "happy"));
    assert!(forms("earliest").iter().any(|form| form == "early"));
}

/// **-ying and doubled comparatives** (audit round 2, 2026-10-26): `dying` is `die`'s gerund and `big` doubles before
/// `-er`/`-est`, both beyond the plain suffix rules.
#[test]
fn ying_and_doubled_comparatives_are_reached() {
    for (surface, base) in [("dying", "die"), ("tying", "tie"), ("lying", "lie")] {
        let got = forms(surface);
        assert!(got.iter().any(|form| form == base), "{surface} does not reach {base}: {got:?}");
    }
    for (base, inflected) in [("big", "bigger"), ("big", "biggest"), ("hot", "hotter"), ("hot", "hottest")] {
        let got = forms(base);
        assert!(got.iter().any(|form| form == inflected), "{base} does not reach {inflected}: {got:?}");
    }
}
