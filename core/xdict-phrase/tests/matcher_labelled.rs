//! The matcher, against the predecessor's cases (`../xiaolaidict/Tests/AppleDictionaryFormatTests/PhraseSpanTests.swift`)
//! plus the plan's own. The inventory is the same list of keys; the sentences are written as the reader met them and
//! every position goes through the forms module, as the service will do it.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use xdict_phrase::{DEFAULT_WIDEST_GAP, DEFAULT_WIDEST_INFERRED_GAP, Match, Matcher, Separation, Slots, forms};

const KNOWN: &[&str] = &[
    "purple passage",
    "purple prose",
    "give up",
    "give in",
    "take off",
    "take on",
    "kick the bucket",
    "red herring",
    "beat around the bush",
    "hold out",
    "hold up",
    "give up the ghost",
    "give something up",
    "take something into account",
    "account for something",
    "look something up",
    "bear something in mind",
    "turn down",
    "give away",
    "look after",
];

fn index() -> Matcher {
    Matcher::new(KNOWN.iter().map(|phrase| (*phrase).to_string()), Slots::english())
}

fn sentence(text: &str) -> Vec<Vec<String>> {
    text.split_whitespace().map(forms).collect()
}

fn leading(matches: &[Match]) -> Option<&Match> {
    matches.first()
}

fn phrase_of(words: &[Vec<String>], word: usize) -> Option<String> {
    leading(&index().matches(words, word, DEFAULT_WIDEST_GAP, DEFAULT_WIDEST_INFERRED_GAP))
        .map(|found| found.phrase.clone())
}

#[test]
fn the_phrase_around_the_hovered_word_is_found() {
    for (text, word, expected) in [
        ("the review was full of purple passage nobody could follow", 5, "purple passage"),
        ("that argument is a red herring", 5, "red herring"),
        ("the plane will take off shortly", 3, "take off"),
    ] {
        assert_eq!(phrase_of(&sentence(text), word).as_deref(), Some(expected), "{text}");
    }
}

#[test]
fn the_longest_known_span_wins() {
    let words = sentence("they give up the ghost eventually");
    assert_eq!(phrase_of(&words, 1).as_deref(), Some("give up the ghost"));
    assert_eq!(phrase_of(&words, 4).as_deref(), Some("give up the ghost"), "from the far end too");
}

#[test]
fn the_shorter_phrase_wins_when_the_longer_is_absent() {
    assert_eq!(phrase_of(&sentence("they give up easily"), 1).as_deref(), Some("give up"));
}

#[test]
fn an_ordinary_word_finds_no_phrase() {
    assert_eq!(phrase_of(&sentence("i read a long passage aloud"), 4), None);
}

#[test]
fn a_phrase_elsewhere_in_the_sentence_is_not_the_answer() {
    assert_eq!(phrase_of(&sentence("she gave up on the difficult idea"), 5), None);
}

#[test]
fn the_right_phrase_among_neighbours_that_share_a_word() {
    assert_eq!(phrase_of(&sentence("they give in easily"), 1).as_deref(), Some("give in"));
    assert_eq!(phrase_of(&sentence("they give up easily"), 1).as_deref(), Some("give up"));
}

#[test]
fn the_first_and_last_word_are_reachable() {
    assert_eq!(phrase_of(&sentence("take off now"), 0).as_deref(), Some("take off"));
    assert_eq!(phrase_of(&sentence("now take off"), 2).as_deref(), Some("take off"));
    assert_eq!(phrase_of(&[], 0), None);
    assert_eq!(phrase_of(&sentence("take"), 5), None, "an index past the end is not a crash");
}

#[test]
fn a_single_word_is_not_a_phrase() {
    let single = Matcher::new(["take".to_string()], Slots::english());
    assert!(single.matches(&sentence("take it"), 0, DEFAULT_WIDEST_GAP, DEFAULT_WIDEST_INFERRED_GAP).is_empty());
}

#[test]
fn a_phrasal_verb_split_by_a_long_object_is_still_the_same_phrase() {
    let words = sentence("take what people think and other possible edge cases all into account");
    let found = leading(&index().matches(&words, 0, DEFAULT_WIDEST_GAP, DEFAULT_WIDEST_INFERRED_GAP)).cloned();
    let found = found.expect("the long split phrase is not found");
    assert_eq!(found.phrase, "take something into account");
    assert_eq!((found.first, found.last), (0, 11), "the span reaches from the verb to the end of the phrase");
    assert_eq!(found.gap(), 9, "and says how far it reached");
    assert_eq!(phrase_of(&words, 11).as_deref(), Some("take something into account"), "found from the far end too");
}

#[test]
fn a_word_inside_the_slot_is_not_part_of_the_phrase() {
    let words = sentence("take what people think and other possible edge cases all into account");
    assert_eq!(phrase_of(&words, 2), None);
    assert_eq!(phrase_of(&words, 8), None);
}

#[test]
fn a_separated_phrasal_verb_is_found() {
    for (text, word, expected) in [
        ("they give the plan up eventually", 1, "give something up"),
        ("she look the unfamiliar word up", 5, "look something up"),
        ("bear the deadline in mind", 0, "bear something in mind"),
        ("bear the deadline in mind", 4, "bear something in mind"),
    ] {
        assert_eq!(phrase_of(&sentence(text), word).as_deref(), Some(expected), "{text}");
    }
}

#[test]
fn the_nearest_filling_of_the_slot_wins() {
    let words = sentence("we take care to take everything into account");
    let found = leading(&index().matches(&words, 7, DEFAULT_WIDEST_GAP, DEFAULT_WIDEST_INFERRED_GAP)).cloned();
    let found = found.expect("no placement found");
    assert_eq!((found.first, found.last), (4, 7));
    assert_eq!(found.gap(), 1);
}

#[test]
fn a_trailing_slot_is_an_ordinary_contiguous_phrase() {
    let words = sentence("we account for the difference");
    let found = leading(&index().matches(&words, 1, DEFAULT_WIDEST_GAP, DEFAULT_WIDEST_INFERRED_GAP)).cloned();
    let found = found.expect("the trailing-slot phrase is not found");
    assert_eq!(found.phrase, "account for something");
    assert_eq!((found.first, found.last), (1, 2));
    assert_eq!(found.gap(), 0);
}

#[test]
fn the_more_literal_phrase_beats_the_slotted_one() {
    assert_eq!(phrase_of(&sentence("they give up the ghost"), 1).as_deref(), Some("give up the ghost"));
}

#[test]
fn a_gap_wider_than_allowed_is_not_a_match() {
    let words = sentence("take what people think and other possible edge cases all into account");
    assert!(index().matches(&words, 0, 3, DEFAULT_WIDEST_INFERRED_GAP).is_empty());
    assert_eq!(index().matches(&words, 0, 9, DEFAULT_WIDEST_INFERRED_GAP).first().map(Match::gap), Some(9));
}

#[test]
fn a_slot_is_not_allowed_to_match_nothing() {
    let slotted = Matcher::new(["give something up".to_string()], Slots::english());
    assert!(slotted.matches(&sentence("they give up"), 1, DEFAULT_WIDEST_GAP, DEFAULT_WIDEST_INFERRED_GAP).is_empty());
}

#[test]
fn every_phrase_covering_the_word_is_returned() {
    let words = sentence("they give up the ghost");
    let all = index().matches(&words, 1, DEFAULT_WIDEST_GAP, DEFAULT_WIDEST_INFERRED_GAP);
    let phrases: Vec<&str> = all.iter().map(|found| found.phrase.as_str()).collect();
    assert_eq!(phrases, ["give up the ghost", "give up"], "got {phrases:?}");
    assert_eq!(leading(&all).map(|found| found.phrase.as_str()), Some("give up the ghost"));
}

#[test]
fn an_ordinary_word_returns_no_matches() {
    assert!(
        index().matches(&sentence("i read a passage"), 3, DEFAULT_WIDEST_GAP, DEFAULT_WIDEST_INFERRED_GAP).is_empty()
    );
}

#[test]
fn the_gap_budget_is_spent_not_reissued() {
    let spans = Matcher::new(["take something into someone account".to_string()], Slots::english());
    let words = sentence("take a b into c d account");
    assert!(spans.matches(&words, 0, 3, DEFAULT_WIDEST_INFERRED_GAP).is_empty());
    assert_eq!(spans.matches(&words, 0, 4, DEFAULT_WIDEST_INFERRED_GAP).first().map(Match::gap), Some(4));
}

#[test]
fn a_key_filed_with_an_inflection_is_found_by_what_the_reader_wrote() {
    let spans = Matcher::new(["by all accounts".to_string(), "keep a tight rein on".to_string()], Slots::english());
    let written = sentence("by all accounts it");
    assert_eq!(
        spans.matches(&written, 2, DEFAULT_WIDEST_GAP, DEFAULT_WIDEST_INFERRED_GAP).first().map(|m| m.phrase.as_str()),
        Some("by all accounts")
    );
    let lemmatised = sentence("kept a tight rein on");
    assert_eq!(
        spans
            .matches(&lemmatised, 0, DEFAULT_WIDEST_GAP, DEFAULT_WIDEST_INFERRED_GAP)
            .first()
            .map(|m| m.phrase.as_str()),
        Some("keep a tight rein on")
    );
}

#[test]
fn a_written_form_outranks_a_borrowed_one() {
    let spans = Matcher::new(["mass produce".to_string(), "mass produced".to_string()], Slots::english());
    assert_eq!(
        spans
            .matches(&sentence("mass produced"), 0, DEFAULT_WIDEST_GAP, DEFAULT_WIDEST_INFERRED_GAP)
            .first()
            .map(|m| m.phrase.as_str()),
        Some("mass produced")
    );
    assert_eq!(
        spans
            .matches(&sentence("mass produce"), 0, DEFAULT_WIDEST_GAP, DEFAULT_WIDEST_INFERRED_GAP)
            .first()
            .map(|m| m.phrase.as_str()),
        Some("mass produce")
    );
}

#[test]
fn one_form_per_position_is_unchanged() {
    let words: Vec<Vec<String>> = ["they", "give", "up"].iter().map(|word| vec![(*word).to_string()]).collect();
    assert_eq!(
        leading(&index().matches(&words, 1, DEFAULT_WIDEST_GAP, DEFAULT_WIDEST_INFERRED_GAP))
            .map(|m| m.phrase.as_str()),
        Some("give up")
    );
}

#[test]
fn a_template_of_one_literal_word_is_not_a_phrase() {
    let slotted = Matcher::new(["take something".to_string()], Slots::english());
    assert!(slotted.matches(&sentence("take it along"), 0, DEFAULT_WIDEST_GAP, DEFAULT_WIDEST_INFERRED_GAP).is_empty());
}

#[test]
fn a_bare_phrasal_verb_is_broken_only_by_inference() {
    let words = sentence("they turn the offer down");
    let found = leading(&index().matches(&words, 1, DEFAULT_WIDEST_GAP, DEFAULT_WIDEST_INFERRED_GAP)).cloned();
    let found = found.expect("the split phrasal verb is not found");
    assert_eq!(found.phrase, "turn down");
    assert_eq!((found.first, found.last), (1, 4));
    assert_eq!(found.separation, Separation::Inferred { words: 2 });
}

#[test]
fn an_unbroken_phrasal_verb_is_not_an_inference() {
    let words = sentence("they turn down the offer");
    let found = leading(&index().matches(&words, 1, DEFAULT_WIDEST_GAP, DEFAULT_WIDEST_INFERRED_GAP)).cloned();
    let found = found.expect("the unbroken phrase is not found");
    assert_eq!(found.separation, Separation::None);
    assert_eq!(found.gap(), 0);
}

#[test]
fn an_inferred_gap_is_held_tighter_than_a_marked_one() {
    assert!(
        index()
            .matches(
                &sentence("turn what people think and every other possibility down"),
                0,
                DEFAULT_WIDEST_GAP,
                DEFAULT_WIDEST_INFERRED_GAP
            )
            .is_empty()
    );
    let marked = sentence("take what people think and other possible edge cases all into account");
    assert_eq!(
        leading(&index().matches(&marked, 0, DEFAULT_WIDEST_GAP, DEFAULT_WIDEST_INFERRED_GAP)).map(|m| m.separation),
        Some(Separation::Marked { words: 9 })
    );
}

#[test]
fn a_prepositional_phrasal_verb_is_not_broken_apart() {
    assert!(
        index()
            .matches(&sentence("look at the child after lunch"), 0, DEFAULT_WIDEST_GAP, DEFAULT_WIDEST_INFERRED_GAP)
            .is_empty()
    );
    assert_eq!(phrase_of(&sentence("look after the child"), 0).as_deref(), Some("look after"));
}

#[test]
fn an_unbroken_reading_is_never_given_up_for_an_inferred_one() {
    let words = sentence("give away the prize and give away again");
    assert_eq!(
        leading(&index().matches(&words, 1, DEFAULT_WIDEST_GAP, DEFAULT_WIDEST_INFERRED_GAP)).map(|m| m.separation),
        Some(Separation::None)
    );
}

#[test]
fn a_longer_contiguous_phrase_is_never_inferred_apart() {
    let spans = Matcher::new(["give up the ghost".to_string()], Slots::english());
    assert!(
        spans
            .matches(&sentence("they give the thing up the ghost"), 1, DEFAULT_WIDEST_GAP, DEFAULT_WIDEST_INFERRED_GAP)
            .is_empty()
    );
}

/// **A placement counts only where the pointer is on one of its words** (audit 2026-11-05, M1; XiaolaiDict's `covers`):
/// "pick up" placed at 0 and 2 is a phrase of the first "up", not of the second, which "get up" holds.
#[test]
fn a_placement_away_from_the_word_is_not_its_phrase() {
    let spans = Matcher::new(["pick up".to_string(), "get up".to_string()], Slots::english());
    let words = sentence("pick it up and get up");
    let found = spans.matches(&words, 5, DEFAULT_WIDEST_GAP, DEFAULT_WIDEST_INFERRED_GAP);
    let spans_found: Vec<(&str, usize, usize)> = found.iter().map(|m| (m.phrase.as_str(), m.first, m.last)).collect();
    assert_eq!(spans_found, [("get up", 4, 5)], "the second \"up\" answered {spans_found:?}");
    let first = spans.matches(&words, 2, DEFAULT_WIDEST_GAP, DEFAULT_WIDEST_INFERRED_GAP);
    let first: Vec<(&str, usize, usize)> = first.iter().map(|m| (m.phrase.as_str(), m.first, m.last)).collect();
    assert_eq!(first, [("pick up", 0, 2)], "the first \"up\" is still the one \"pick\" was split from");
}

/// A word between two placed runs of a slotted phrase is the slot's filling, not the phrase, even when it spells one of
/// the phrase's words; a word on a placed run is covered; a word past the phrase is not.
#[test]
fn coverage_is_by_placed_words_at_every_level() {
    let spans = Matcher::new(["take something into account".to_string()], Slots::english());
    let between = sentence("take the take into account");
    assert_eq!(phrase_of_in(&spans, &between, 2), None, "the second \"take\" fills the slot");
    assert_eq!(phrase_of_in(&spans, &between, 3).as_deref(), Some("take something into account"), "\"into\" is placed");
    let outside = sentence("take the plan into account and take a break");
    assert_eq!(phrase_of_in(&spans, &outside, 6), None, "a \"take\" after the phrase is not in it");
    assert_eq!(phrase_of_in(&spans, &outside, 0).as_deref(), Some("take something into account"));
}

fn phrase_of_in(spans: &Matcher, words: &[Vec<String>], word: usize) -> Option<String> {
    let found = spans.matches(words, word, DEFAULT_WIDEST_GAP, DEFAULT_WIDEST_INFERRED_GAP);
    for hit in &found {
        assert!(hit.first <= word && word <= hit.last, "{} spans {}..={}, not {word}", hit.phrase, hit.first, hit.last);
    }
    leading(&found).map(|found| found.phrase.clone())
}
