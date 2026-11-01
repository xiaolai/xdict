//! **An entry's first gloss** (ADR-0037): the first sense's own definition, or its translation when the dictionary prints
//! no definition body before it, as one short piece of text for the reading history's cards. The renderer deliberately
//! does not write `Role::Def` (ADR-0029; `roles.rs`, `written()`), so this reads what the projection does carry: runs with
//! their roles, labels, sections and innermost sense, and the senses' ranges. A dictionary whose markup gives nothing
//! usable yields no gloss; it never yields a guess.

use crate::text::{Sense, TextRun};

/// Where a gloss's words came from: the dictionary's definition body, or the translation it prints for it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GlossSource {
    Definition,
    Translation,
}

/// One brief gloss. `truncated` says the clamp cut it; the card's two-line limit may cut it again visually.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Gloss {
    pub text: String,
    /// The entry's part of speech, when one is printed before the selected sense.
    pub pos: Option<String>,
    pub source: GlossSource,
    pub truncated: bool,
}

/// The extractor revision: a change to the rules is a new revision, and a durable cache would key on it (none is kept
/// today: the shell's cache is process-lifetime). **2**: the audit's rules (2026-10-31) — the first sense decides, cut
/// senses give their completed definitions, a sense's own POS wins, wrapper roles are body text, inline labels do not
/// split a definition, and the ellipsis is inside the clamp.
pub const GLOSS_EXTRACTOR: u32 = 2;

/// The most characters a gloss carries on the wire. The card shows two lines; this bound is the memory and message's.
pub const GLOSS_MAX_CHARS: usize = 240;

/// **The range the extractor works within** (audit 2026-10-31): a sense's byte range and id, or the whole projection
/// when the entry names no senses. `whole` is false when the projection cut the sense.
#[derive(Clone, Copy)]
struct Scope {
    start: usize,
    end: usize,
    sense: Option<u32>,
    whole: bool,
}

/// **The first sense's gloss**, or none. `key` is the entry's key, rejected when a candidate is merely the headword again.
///
/// **The first sense decides** (ADR-0037; audit 2026-10-31): the first top-level sense that is not in an excluded
/// section, whether or not the projection carries it whole. A later sense is another meaning and is never shown as the
/// entry's gloss; a sense the projection cut supplies only the definitions it completed before the cut.
pub fn first_gloss(text: &str, runs: &[TextRun], senses: &[Sense], key: &str, max_chars: usize) -> Option<Gloss> {
    first_gloss_after(text, runs, senses, None, key, max_chars)
}

/// The same, given **the first run the projection dropped** (`Projection::next_dropped`): a cut sense's final segment
/// is offered only when that run proves the definition ended before the cut — another kind, another sense, or no run
/// that may continue it. Without it the segment stays unoffered, as a cut may have taken its remaining words
/// (audit 2026-10-31).
pub fn first_gloss_after(
    text: &str,
    runs: &[TextRun],
    senses: &[Sense],
    next: Option<&TextRun>,
    key: &str,
    max_chars: usize,
) -> Option<Gloss> {
    let first = senses.iter().find(|sense| sense.parent.is_none() && !excluded_section(sense.section.as_deref()));
    let scope = match first {
        Some(sense) => Scope {
            start: sense.start,
            end: sense.start.saturating_add(sense.len).min(text.len()),
            sense: Some(sense.id),
            whole: sense.whole,
        },
        // An entry that names no senses at all: its first definition-like block is still readable. An entry whose senses
        // were all nested, or whose every top-level sense is excluded, gets no gloss rather than a piece of one.
        None if senses.is_empty() => Scope { start: 0, end: text.len(), sense: None, whole: true },
        None => return None,
    };
    if scope.start >= text.len() {
        return None;
    }
    let pos = part_of_speech(text, runs, scope);
    let (gloss, source, truncated) = gloss_in(text, runs, scope, next, key, max_chars)?;
    Some(Gloss { text: gloss, pos, source, truncated })
}

/// The part of speech that governs the selected sense. **The sense's own first** (audit 2026-10-31): a POS printed inside
/// the selected sense governs it whatever a heading above says; a heading printed before it governs only when it belongs
/// to no sense of its own (a previous sense's POS must not label this one), and text in an excluded section never does.
fn part_of_speech(text: &str, runs: &[TextRun], scope: Scope) -> Option<String> {
    let is_pos = |run: &&TextRun| run.role.as_deref() == Some("pos") && !excluded_section(run.section.as_deref());
    let own = runs.iter().find(|run| {
        is_pos(run)
            && run.start >= scope.start
            && run.start < scope.end
            && (run.sense.is_none() || scope.sense.is_some_and(|id| run.sense == Some(id)))
    });
    let heading = runs.iter().rev().find(|run| is_pos(run) && run.start < scope.start && run.sense.is_none());
    let run = own.or(heading)?;
    let raw = text.get(run.start..run.start.saturating_add(run.len))?;
    let text = collapse(raw);
    if text.is_empty() { None } else { Some(text) }
}

/// The first usable definition segment in the scope, else its first translation. Definitions win because they are the
/// dictionary's printed meaning; a translation is used only when the dictionary prints no definition body for the sense.
///
/// `scope.whole` is false when the projection cut the sense: the segment the loop is still holding at the range's end may
/// have lost text to the cut, so it is not offered — only definitions the markup itself ended are (audit 2026-10-31).
fn gloss_in(
    text: &str,
    runs: &[TextRun],
    scope: Scope,
    next: Option<&TextRun>,
    key: &str,
    max_chars: usize,
) -> Option<(String, GlossSource, bool)> {
    let mut definitions: Vec<String> = Vec::new();
    let mut translations: Vec<String> = Vec::new();
    let mut segment = String::new();
    let mut kind: Option<GlossSource> = None;
    let mut last_end: Option<usize> = None;

    for run in runs {
        let run_end = run.start.saturating_add(run.len);
        if run.start < scope.start || run_end > scope.end {
            continue;
        }
        // A nested sense's text is its own gloss, never its parent's — and the parent's segment ends there: the gap
        // after it must not carry the child back in (audit 2026-10-31).
        if scope.sense.is_some_and(|id| run.sense.is_some_and(|run_id| run_id != id)) {
            flush(&mut segment, &mut kind, &mut definitions, &mut translations);
            last_end = None;
            continue;
        }
        let Some(next) = run_kind(run) else {
            // **An inline label is an annotation, not a boundary** (audit 2026-10-31): a definition interrupted by a
            // `<label>` continues after it. The gap before the label is this definition's text — the projection keeps a
            // separator outside the runs, so skipping the gap as well would concatenate the words around the label. A
            // label that opens a block — the segment is empty — still ends the one before, as every structural run does.
            if is_label(run) && !segment.is_empty() && !excluded_section(run.section.as_deref()) {
                if let Some(previous) = last_end
                    && let Some(gap) = text.get(previous..run.start)
                {
                    segment.push_str(gap);
                }
                last_end = Some(run_end);
                continue;
            }
            flush(&mut segment, &mut kind, &mut definitions, &mut translations);
            last_end = None;
            continue;
        };
        if kind.is_some_and(|current| current != next) {
            flush(&mut segment, &mut kind, &mut definitions, &mut translations);
            last_end = None;
        }
        if let Some(previous) = last_end {
            match text.get(previous..run.start) {
                // A newline is a block boundary: the next block is another definition, not this one's continuation.
                Some(gap) if gap.contains('\n') => {
                    flush(&mut segment, &mut kind, &mut definitions, &mut translations);
                }
                Some(gap) => segment.push_str(gap),
                None => {
                    flush(&mut segment, &mut kind, &mut definitions, &mut translations);
                }
            }
        }
        if let Some(part) = text.get(run.start..run_end) {
            segment.push_str(part);
        }
        kind = Some(next);
        last_end = Some(run_end);
    }
    // **The loop's last segment is the one the range's end may have cut.** It is offered when the sense is whole, or
    // when the first dropped run proves the definition ended before the cut; a run that may continue it — a
    // definition-kind run in the same sense, an inline label, or no evidence at all — leaves it unoffered, because the
    // cut may have taken its remaining words (audit 2026-10-31).
    let continues = !scope.whole && next.is_none_or(|dropped| continues_definition(dropped, scope, kind));
    if !continues {
        flush(&mut segment, &mut kind, &mut definitions, &mut translations);
    }

    for (candidates, source) in [(definitions, GlossSource::Definition), (translations, GlossSource::Translation)] {
        for candidate in candidates {
            if let Some((gloss, truncated)) = clean(&candidate, key, max_chars) {
                return Some((gloss, source, truncated));
            }
        }
    }
    None
}

/// Whether the run is a label: a renderer label attribute, or the `label` role a profile writes.
fn is_label(run: &TextRun) -> bool {
    run.label.is_some() || run.role.as_deref() == Some("label")
}

/// Whether the first dropped run may continue the definition segment: a definition-kind run of the same segment, or an
/// inline label (the text after it is still the definition's). A run of another kind, of another sense, or in an
/// excluded section proves the definition ended.
fn continues_definition(run: &TextRun, scope: Scope, kind: Option<GlossSource>) -> bool {
    let in_scope = match scope.sense {
        Some(id) => run.sense.is_none() || run.sense == Some(id),
        None => true,
    };
    if !in_scope {
        return false;
    }
    if is_label(run) && !excluded_section(run.section.as_deref()) {
        return true;
    }
    kind.is_some() && run_kind(run) == kind
}

/// The segment a run belongs to, or none when the run is structure the gloss must not quote.
fn run_kind(run: &TextRun) -> Option<GlossSource> {
    if run.label.is_some() || excluded_section(run.section.as_deref()) {
        return None;
    }
    match run.role.as_deref() {
        // Unclassified text is the entry's body; `sense`, `def`, `entry` and `section` are the wrapper roles the
        // renderer and the projection write around a body (ADR-0029: it never writes `Role::Def`). Structure the gloss
        // must not quote is excluded below and by its section above.
        None | Some("sense") | Some("def") | Some("entry") | Some("section") => Some(GlossSource::Definition),
        Some("trans") => Some(GlossSource::Translation),
        Some(_) => None,
    }
}

fn flush(
    segment: &mut String,
    kind: &mut Option<GlossSource>,
    definitions: &mut Vec<String>,
    translations: &mut Vec<String>,
) {
    if segment.is_empty() {
        *kind = None;
        return;
    }
    let text = collapse(segment);
    match kind {
        Some(GlossSource::Definition) => definitions.push(text),
        Some(GlossSource::Translation) => translations.push(text),
        None => {}
    }
    segment.clear();
    *kind = None;
}

/// A segment as a gloss: non-empty, not the headword repeated, clamped. `raw` is already whitespace-collapsed by
/// `flush`; nothing here normalises it again (audit 2026-10-31).
fn clean(raw: &str, key: &str, max_chars: usize) -> Option<(String, bool)> {
    // Zero is no gloss, never unlimited text.
    if max_chars == 0 || raw.is_empty() || !raw.chars().any(char::is_alphabetic) {
        return None;
    }
    // The headword itself is not its gloss. A one-word translation that differs from the key is a gloss ("run" →
    // "sprint"), so a word count is not the test. The candidate is compared as it is and without its surrounding
    // punctuation, against the key unchanged and case-folded (audit 2026-10-31): `C++`, `.NET` and `ÉTÉ` / `été`
    // repetitions are the headword, while a distinct `C` for `C++` is still a gloss.
    let key_folded = key.to_lowercase();
    let candidate_folded = raw.to_lowercase();
    let candidate_trimmed = raw.trim_matches(|c: char| !c.is_alphanumeric()).to_lowercase();
    if candidate_folded == key_folded || candidate_trimmed == key_folded {
        return None;
    }
    let (text, truncated) = clamp(raw.to_string(), max_chars);
    // A clamp this tight can leave only the ellipsis: that is no meaning, so it is no gloss.
    if !text.chars().any(char::is_alphabetic) {
        return None;
    }
    Some((text, truncated))
}

fn collapse(raw: &str) -> String {
    raw.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Clamp at a character boundary, preferring the last whitespace within a short distance so a Latin gloss ends on a
/// word; CJK, which has no spaces, is cut at the character. **The ellipsis is part of `max_chars`** (audit 2026-10-31):
/// the advertised limit is the whole gloss, not the words before it.
fn clamp(text: String, max_chars: usize) -> (String, bool) {
    if text.chars().count() <= max_chars {
        return (text, false);
    }
    let limit = max_chars.saturating_sub(1);
    let cut = text.char_indices().nth(limit).map_or(text.len(), |(index, _)| index);
    // The workspace forbids slice indexing in library code: a cut index is a boundary the loop above proved, but the
    // rule is the rule, so the head is asked for by range.
    let Some(head) = text.get(..cut) else { return (text, false) };
    let mut end = cut;
    if let Some(space) = head.rfind(char::is_whitespace).filter(|space| cut.saturating_sub(*space) <= 32) {
        end = space;
    }
    let mut out = text.get(..end).unwrap_or("").trim_end().to_string();
    out.push('…');
    (out, true)
}

/// Sections whose text is not a meaning: a word's etymology, usage notes, examples, idioms and the rest. A sense whose
/// section is one of these never supplies a gloss, and a run inside one is skipped even when its sense is not.
fn excluded_section(section: Option<&str>) -> bool {
    matches!(
        section,
        Some(
            "etym"
                | "examples"
                | "usage"
                | "derivatives"
                | "idioms"
                | "phrasal"
                | "thesaurus"
                | "colloc"
                | "synonyms"
                | "antonyms"
                | "pron"
                | "pronunciation"
                | "translations"
                | "grammar"
                | "inflections"
                | "notes"
                | "help"
                | "other"
        )
    )
}

#[cfg(test)]
mod tests {
    // The same allowance the sibling test modules take: a test's fixture is its own evidence, and a panic there is a
    // failed test, not a library panic.
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

    use super::*;

    fn run(start: usize, text: &str, role: Option<&str>, section: Option<&str>, sense: Option<u32>) -> TextRun {
        TextRun {
            start,
            len: text.len(),
            role: role.map(str::to_owned),
            label: None,
            section: section.map(str::to_owned),
            sense,
        }
    }

    fn sense(id: u32, start: usize, len: usize, section: Option<&str>, whole: bool) -> Sense {
        Sense { id, start, len, label: Some("1".into()), section: section.map(str::to_owned), parent: None, whole }
    }

    #[test]
    fn the_first_sense_gives_the_gloss() {
        let text = "run\nnoun\n1. move fast; go quickly\nexample";
        let runs = [
            run(0, "run", Some("headword"), None, None),
            run(4, "noun", Some("pos"), None, None),
            run(9, "1.", Some("sensenum"), None, Some(1)),
            run(12, "move fast; go quickly", None, None, Some(1)),
            run(33, "example", Some("example"), None, Some(1)),
        ];
        let senses = [sense(1, 9, 31, None, true)];
        let gloss = first_gloss(text, &runs, &senses, "run", GLOSS_MAX_CHARS).unwrap();
        assert_eq!(gloss.text, "move fast; go quickly");
        assert_eq!(gloss.pos.as_deref(), Some("noun"));
        assert_eq!(gloss.source, GlossSource::Definition);
        assert!(!gloss.truncated);
    }

    #[test]
    fn a_nested_senses_text_is_not_the_parents_definition() {
        let text = "1. parent 2. child gloss";
        let runs = [
            run(0, "1.", Some("sensenum"), None, Some(1)),
            run(3, "parent", None, None, Some(1)),
            run(10, "2.", Some("sensenum"), None, Some(2)),
            run(13, "child gloss", None, None, Some(2)),
        ];
        let senses = [
            sense(1, 0, 24, None, true),
            Sense { id: 2, start: 10, len: 14, label: Some("2".into()), section: None, parent: Some(1), whole: true },
        ];
        let gloss = first_gloss(text, &runs, &senses, "run", GLOSS_MAX_CHARS).unwrap();
        assert_eq!(gloss.text, "parent");
    }

    #[test]
    fn sensenum_pos_labels_pronunciations_and_examples_are_excluded() {
        let text = "run /rʌn/ 1. noun move fast she ran";
        let runs = [
            run(0, "run", Some("headword"), None, None),
            run(4, "/rʌn/", Some("pron"), None, None),
            run(11, "1.", Some("sensenum"), None, Some(1)),
            run(14, "noun", Some("pos"), None, Some(1)),
            run(19, "move fast", None, None, Some(1)),
            run(29, "she ran", Some("example"), None, Some(1)),
        ];
        let senses = [sense(1, 11, 27, None, true)];
        let gloss = first_gloss(text, &runs, &senses, "run", GLOSS_MAX_CHARS).unwrap();
        assert_eq!(gloss.text, "move fast");
    }

    #[test]
    fn excluded_sections_never_supply_a_gloss() {
        let text = "run noun from Old English rinnan";
        let runs = [
            run(0, "run", Some("headword"), Some("etym"), None),
            run(4, "noun", Some("pos"), Some("etym"), None),
            run(9, "from Old English rinnan", None, Some("etym"), Some(1)),
        ];
        let senses = [sense(1, 0, 29, Some("etym"), true)];
        assert!(first_gloss(text, &runs, &senses, "run", GLOSS_MAX_CHARS).is_none());
    }

    #[test]
    fn a_translation_is_used_only_when_there_is_no_definition_body() {
        let text = "run 跑步";
        let runs = [run(0, "run", Some("headword"), None, None), run(4, "跑步", Some("trans"), None, Some(1))];
        let senses = [sense(1, 0, 10, None, true)];
        let gloss = first_gloss(text, &runs, &senses, "run", GLOSS_MAX_CHARS).unwrap();
        assert_eq!(gloss.text, "跑步");
        assert_eq!(gloss.source, GlossSource::Translation);
    }

    #[test]
    fn a_definition_body_wins_over_a_translation_in_the_same_sense() {
        let text = "run 跑步 to move fast";
        let runs = [
            run(0, "run", Some("headword"), None, None),
            run(4, "跑步", Some("trans"), None, Some(1)),
            run(11, "to move fast", None, None, Some(1)),
        ];
        let senses = [sense(1, 0, 23, None, true)];
        let gloss = first_gloss(text, &runs, &senses, "run", GLOSS_MAX_CHARS).unwrap();
        assert_eq!(gloss.text, "to move fast");
        assert_eq!(gloss.source, GlossSource::Definition);
    }

    #[test]
    fn an_entry_with_no_senses_falls_back_to_its_first_definition_block() {
        let text = "run\nto move fast\nanother line";
        let runs = [
            run(0, "run", Some("headword"), None, None),
            run(4, "to move fast", None, None, None),
            run(17, "another line", None, None, None),
        ];
        let gloss = first_gloss(text, &runs, &[], "run", GLOSS_MAX_CHARS).unwrap();
        assert_eq!(gloss.text, "to move fast");
    }

    #[test]
    fn a_cut_sense_is_not_used() {
        let text = "run to move fast";
        let runs = [run(0, "run", Some("headword"), None, None), run(4, "to move fast", None, None, Some(1))];
        let senses = [sense(1, 0, 17, None, false)];
        assert!(first_gloss(text, &runs, &senses, "run", GLOSS_MAX_CHARS).is_none());
    }

    #[test]
    fn the_key_itself_is_not_a_gloss() {
        let text = "hold hold";
        let runs = [run(0, "hold", Some("headword"), None, None), run(5, "hold", None, None, Some(1))];
        let senses = [sense(1, 0, 9, None, true)];
        assert!(first_gloss(text, &runs, &senses, "hold", GLOSS_MAX_CHARS).is_none());
    }

    #[test]
    fn whitespace_collapses_and_blocks_join_with_spaces() {
        let text = "run move\n   very\n fast";
        let runs = [
            run(0, "run", Some("headword"), None, None),
            run(4, "move", None, None, Some(1)),
            run(11, "very", None, None, Some(1)),
            run(18, "fast", None, None, Some(1)),
        ];
        let senses = [sense(1, 0, 22, None, true)];
        let gloss = first_gloss(text, &runs, &senses, "run", GLOSS_MAX_CHARS).unwrap();
        assert_eq!(gloss.text, "move");
    }

    #[test]
    fn clamping_does_not_split_a_character_and_marks_truncation() {
        let text = "run move fast and then keep moving for a very long time";
        let runs = [
            run(0, "run", Some("headword"), None, None),
            run(4, "move fast and then keep moving for a very long time", None, None, Some(1)),
        ];
        let senses = [sense(1, 0, 58, None, true)];
        let gloss = first_gloss(text, &runs, &senses, "run", 12).unwrap();
        assert!(gloss.truncated);
        assert!(gloss.text.ends_with('…'));
        assert!(gloss.text.chars().count() <= 12, "the ellipsis is inside the clamp: {}", gloss.text);
    }

    #[test]
    fn cjk_and_emoji_are_clamped_safely() {
        let text = "跑 跑步是一种快速移动的方式，常常用于日常锻炼和比赛。";
        let runs = [
            run(0, "跑", Some("headword"), None, None),
            run(4, "跑步是一种快速移动的方式，常常用于日常锻炼和比赛。", None, None, Some(1)),
        ];
        let senses = [sense(1, 0, 79, None, true)];
        let gloss = first_gloss(text, &runs, &senses, "跑", 8).unwrap();
        assert!(gloss.text.ends_with('…'));
        assert!(gloss.text.chars().count() <= 8);
    }

    #[test]
    fn no_candidate_returns_none() {
        let text = "run";
        let runs = [run(0, "run", Some("headword"), None, None)];
        let senses = [sense(1, 0, 3, None, true)];
        assert!(first_gloss(text, &runs, &senses, "run", GLOSS_MAX_CHARS).is_none());
    }

    #[test]
    fn an_empty_entry_returns_none() {
        assert!(first_gloss("", &[], &[], "run", GLOSS_MAX_CHARS).is_none());
    }

    /// **The first sense decides** (ADR-0037; audit 2026-10-31): a first sense with no usable text does not hand its
    /// place to a later meaning.
    #[test]
    fn a_later_sense_is_not_the_first_senses_gloss() {
        let text = "run 1. she ran 2. move fast";
        let runs = [
            run(0, "run", Some("headword"), None, None),
            run(4, "1.", Some("sensenum"), None, Some(1)),
            run(7, "she ran", Some("example"), None, Some(1)),
            run(15, "2.", Some("sensenum"), None, Some(2)),
            run(18, "move fast", None, None, Some(2)),
        ];
        let senses = [sense(1, 4, 11, None, true), sense(2, 15, 12, None, true)];
        assert!(first_gloss(text, &runs, &senses, "run", GLOSS_MAX_CHARS).is_none());
    }

    /// **A cut sense still gives the definitions it completed before the cut** (audit 2026-10-31): the sense is not
    /// whole, but the definition ended at a block boundary, so it is not a guess.
    #[test]
    fn a_cut_sense_gives_the_definition_it_completed() {
        let text = "run to move fast\nmore text after the cut";
        let runs = [
            run(0, "run", Some("headword"), None, None),
            run(4, "to move fast", None, None, Some(1)),
            run(17, "more text after the cut", None, None, Some(1)),
        ];
        let senses = [sense(1, 4, 100, None, false)];
        let gloss = first_gloss(text, &runs, &senses, "run", GLOSS_MAX_CHARS).unwrap();
        assert_eq!(gloss.text, "to move fast");
    }

    /// **A cut sense's final segment is offered when the dropped run proves the definition ended** (audit 2026-10-31):
    /// the budget dropped the example that followed, not the definition's words.
    #[test]
    fn a_cut_sense_offers_the_segment_the_dropped_run_ends() {
        let text = "run to move fast";
        let runs = [run(0, "run", Some("headword"), None, None), run(4, "to move fast", None, None, Some(1))];
        let senses = [sense(1, 4, 100, None, false)];
        let example = run(17, "she ran far", Some("example"), None, Some(1));
        let gloss = first_gloss_after(text, &runs, &senses, Some(&example), "run", GLOSS_MAX_CHARS).unwrap();
        assert_eq!(gloss.text, "to move fast");
        // Without that evidence — a cut may have taken the definition's remaining words — it stays unoffered.
        assert!(first_gloss(text, &runs, &senses, "run", GLOSS_MAX_CHARS).is_none());
    }

    /// **A dropped run that may continue the definition keeps its final segment unoffered** (audit 2026-10-31).
    #[test]
    fn a_cut_sense_keeps_a_segment_a_dropped_run_may_continue() {
        let text = "run to move fast";
        let runs = [run(0, "run", Some("headword"), None, None), run(4, "to move fast", None, None, Some(1))];
        let senses = [sense(1, 4, 100, None, false)];
        let continuation = run(17, "and keep going", None, None, Some(1));
        assert!(first_gloss_after(text, &runs, &senses, Some(&continuation), "run", GLOSS_MAX_CHARS).is_none());
    }

    /// **The projection's own dropped run decides a cut sense's final segment** (audit 2026-10-31): from HTML to gloss,
    /// a definition followed by an example the budget drops is still the gloss.
    #[test]
    fn a_dropped_example_after_a_definition_leaves_the_definition() {
        let html = concat!(
            r#"<div data-xdict-role="sense" data-xdict-sense="1">"#,
            r#"<span data-xdict-role="sensenum">1</span> <span data-xdict-role="def">to move fast</span>"#,
            r#"<div data-xdict-role="example">she ran far today</div></div>"#,
        );
        let projection = crate::text::entry_text_from_html(html, 14);
        assert!(!projection.complete, "the budget did not cut the example");
        let gloss = first_gloss_after(
            &projection.text,
            &projection.runs,
            &projection.senses,
            projection.next_dropped.as_ref(),
            "run",
            GLOSS_MAX_CHARS,
        );
        assert_eq!(gloss.map(|gloss| gloss.text), Some("to move fast".to_string()));
    }

    /// **An inline label in the projection's own markup keeps one definition** (audit 2026-10-31): the separator before
    /// the label lives outside the runs and must survive it.
    #[test]
    fn an_inline_label_in_projected_markup_keeps_the_definition_whole() {
        let html = concat!(
            r#"<div data-xdict-role="sense" data-xdict-sense="1">"#,
            r#"<span data-xdict-role="def">a <span data-xdict-role="label">technical</span>measuring instrument</span>"#,
            r#"</div>"#,
        );
        let projection = crate::text::entry_text_from_html(html, usize::MAX);
        let gloss = first_gloss_after(
            &projection.text,
            &projection.runs,
            &projection.senses,
            projection.next_dropped.as_ref(),
            "run",
            GLOSS_MAX_CHARS,
        );
        assert_eq!(gloss.map(|gloss| gloss.text), Some("a measuring instrument".to_string()));
    }

    /// **A nested sense's text never returns to its parent's segment** (audit 2026-10-31): the gap after a skipped child
    /// is not the parent's text.
    #[test]
    fn a_nested_senses_text_never_returns_to_the_parents_gloss() {
        let text = "1. parent one child text parent two";
        let runs = [
            run(0, "1.", Some("sensenum"), None, Some(1)),
            run(3, "parent one ", None, None, Some(1)),
            run(14, "child text ", None, None, Some(2)),
            run(25, "parent two", None, None, Some(1)),
        ];
        let senses = [
            sense(1, 0, 35, None, true),
            Sense { id: 2, start: 14, len: 11, label: Some("2".into()), section: None, parent: Some(1), whole: true },
        ];
        let gloss = first_gloss(text, &runs, &senses, "run", GLOSS_MAX_CHARS).unwrap();
        assert_eq!(gloss.text, "parent one");
    }

    /// **The sense's own POS wins over a heading above it** (audit 2026-10-31).
    #[test]
    fn the_senses_own_pos_wins_over_a_heading_before_it() {
        let text = "noun 1. verb move fast";
        let runs = [
            run(0, "noun", Some("pos"), None, None),
            run(5, "1.", Some("sensenum"), None, Some(1)),
            run(8, "verb", Some("pos"), None, Some(1)),
            run(13, "move fast", None, None, Some(1)),
        ];
        let senses = [sense(1, 5, 17, None, true)];
        let gloss = first_gloss(text, &runs, &senses, "run", GLOSS_MAX_CHARS).unwrap();
        assert_eq!(gloss.pos.as_deref(), Some("verb"));
        assert_eq!(gloss.text, "move fast");
    }

    /// **A body wrapper's role is still the definition** (audit 2026-10-31): the renderer never writes `Role::Def`, and a
    /// `section`/`entry` role reaches the text under it.
    #[test]
    fn a_body_wrapper_role_is_still_the_definition() {
        let text = "run move fast";
        let runs = [
            run(0, "run", Some("headword"), None, None),
            run(4, "move fast", Some("section"), Some("definitions"), Some(1)),
        ];
        let senses = [sense(1, 0, 13, None, true)];
        let gloss = first_gloss(text, &runs, &senses, "run", GLOSS_MAX_CHARS).unwrap();
        assert_eq!(gloss.text, "move fast");
    }

    /// **An inline label does not split the definition** (audit 2026-10-31). The projection keeps the separator before
    /// the label outside the runs, so the gap is part of the definition's text.
    #[test]
    fn an_inline_label_does_not_split_the_definition() {
        let text = "run a technicalmeasuring instrument";
        let runs = [
            run(0, "run", Some("headword"), None, None),
            run(4, "a", None, None, Some(1)),
            run(6, "technical", Some("label"), None, Some(1)),
            run(15, "measuring instrument", None, None, Some(1)),
        ];
        let senses = [sense(1, 4, 31, None, true)];
        let gloss = first_gloss(text, &runs, &senses, "run", GLOSS_MAX_CHARS).unwrap();
        assert_eq!(gloss.text, "a measuring instrument");
    }

    /// **Zero characters is no gloss**, never unlimited text (audit 2026-10-31).
    #[test]
    fn a_zero_limit_is_no_gloss() {
        let text = "run move fast";
        let runs = [run(0, "run", Some("headword"), None, None), run(4, "move fast", None, None, Some(1))];
        let senses = [sense(1, 0, 13, None, true)];
        assert!(first_gloss(text, &runs, &senses, "run", 0).is_none());
    }

    /// **A repeated headword is not a gloss, whatever its punctuation or case** (audit 2026-10-31).
    #[test]
    fn a_repeated_key_with_punctuation_or_unicode_case_is_not_a_gloss() {
        for (key, text) in [("C++", "C++ C++"), (".NET", ".NET .NET"), ("ÉTÉ", "ÉTÉ été")] {
            let headword_len = key.len();
            let runs = [
                run(0, key, Some("headword"), None, None),
                run(headword_len + 1, &text[headword_len + 1..], None, None, Some(1)),
            ];
            let senses = [sense(1, 0, text.len(), None, true)];
            assert!(first_gloss(text, &runs, &senses, key, GLOSS_MAX_CHARS).is_none(), "{text}");
        }
    }

    /// **A distinct candidate for a punctuated key is still a gloss** (audit 2026-10-31): rejecting `C++` as the
    /// headword must not reject `C`, which says something.
    #[test]
    fn a_distinct_candidate_for_a_punctuated_key_is_still_a_gloss() {
        let text = "C++ C";
        let runs = [run(0, "C++", Some("headword"), None, None), run(4, "C", None, None, Some(1))];
        let senses = [sense(1, 0, 5, None, true)];
        let gloss = first_gloss(text, &runs, &senses, "C++", GLOSS_MAX_CHARS).unwrap();
        assert_eq!(gloss.text, "C");
    }
}
