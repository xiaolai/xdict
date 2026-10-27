//! **The collocations one entry writes** (plan-word-exploration WI-6): the Oxford Collocations Dictionary heads every
//! group of collocates with a frame — `ADJECTIVE`, `VERB + BLOOD VESSEL`, `… OF STYLE` — and this reads them as pairs of
//! a **closed** frame and a collocate, for the per-edition store to keep.
//!
//! **The vocabulary is closed and small on purpose.** A frame outside it is dropped and counted, never widened to fit:
//! an unrecognised frame is a gap in this extractor, and quietly coercing it would make a wrong frame look like a
//! measured one. Measured on 120 evenly spaced entries of the 2nd edition (2026-10-27): 40 entries carry frames, about
//! 1,373 pairs, and 10 frames (0.7%) fall outside the list.
//!
//! The headword's own name in a frame is `HW`: `VERB + BLOOD VESSEL` and `VERB + TRUSTEE` are one frame, and the frame
//! is compared with case, hyphens and spaces taken out, since the dictionary writes `ELECTRIC-SHOCK` for `electric
//! shock`.

/// One frame the dictionary heads a collocate group with, with the headword itself as `HW`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Frame {
    /// Collocates that are adjectives of the headword: `major` for *blood vessel*.
    Adjective,
    Adverb,
    Noun,
    /// Verbs that take the headword: `block` for *blood vessel*.
    Verb,
    /// The plural spelling the dictionary uses for the same frame.
    Verbs,
    Preposition,
    /// Whole phrases the headword appears in.
    Phrases,
    /// `ADJECTIVE + HW`, where the headword is the noun: `parliamentary` for *agent*.
    AdjectivePlusHeadword,
    /// `VERB + HW`.
    VerbPlusHeadword,
    /// `HW + VERB`: what the headword does.
    HeadwordPlusVerb,
    /// `HW + NOUN`.
    HeadwordPlusNoun,
    /// `NOUN + HW`.
    NounPlusHeadword,
    /// `… OF HW`: the headword's own phrase, as the dictionary writes it.
    PhraseOfHeadword,
}

impl Frame {
    /// The frame a squashed label names, or `None` when the closed vocabulary has no such frame.
    fn of(squashed: &str) -> Option<Self> {
        Some(match squashed {
            "ADJECTIVE" => Self::Adjective,
            "ADVERB" => Self::Adverb,
            "NOUN" => Self::Noun,
            "VERB" => Self::Verb,
            "VERBS" => Self::Verbs,
            "PREPOSITION" => Self::Preposition,
            "PHRASES" => Self::Phrases,
            "ADJECTIVE+HW" => Self::AdjectivePlusHeadword,
            "VERB+HW" => Self::VerbPlusHeadword,
            "HW+VERB" => Self::HeadwordPlusVerb,
            "HW+NOUN" => Self::HeadwordPlusNoun,
            "NOUN+HW" => Self::NounPlusHeadword,
            "…OFHW" => Self::PhraseOfHeadword,
            _ => return None,
        })
    }
}

/// What one entry's markup held.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Collocations {
    /// The entry's headword, as its own span spells it.
    pub headword: String,
    /// Every collocate, under its frame, in document order.
    pub pairs: Vec<(Frame, String)>,
    /// Frames outside the closed vocabulary, dropped. **Counted, so a gap in this extractor is visible** rather than
    /// looking like a dictionary that has no collocations there.
    pub dropped: u32,
}

/// **The pairs one rendered entry holds**: `ocd_hw` is the headword, `ocd_ps` heads a group, `ocd_co` is a collocate
/// and a comma list is split. A collocate with no frame before it is dropped and counted with the frames outside the
/// vocabulary, since it belongs to a group this extractor could not name.
pub fn extract(html: &str) -> Collocations {
    let headword = spans(html, "ocd_hw").first().map(|(_, text)| (*text).to_string()).unwrap_or_default();
    let frames = spans(html, "ocd_ps");
    let mut pairs = Vec::new();
    let mut dropped = 0u32;
    for (at, text) in spans(html, "ocd_co") {
        let frame = frames.iter().rev().find(|(start, _)| start < &at).and_then(|(_, label)| frame(label, &headword));
        for word in text.split(',') {
            let word = word.trim();
            if word.is_empty() {
                continue;
            }
            match frame {
                Some(frame) => pairs.push((frame, word.to_string())),
                None => dropped += 1,
            }
        }
    }
    Collocations { headword, pairs, dropped }
}

/// **The frame a label names**, with the headword's own name taken out of it: case, hyphens and spaces go before the
/// comparison (`ELECTRIC-SHOCK + NOUN` is `electric shock`'s), and a leading `…` is the headword's own phrase.
fn frame(label: &str, headword: &str) -> Option<Frame> {
    let squash =
        |text: &str| -> String { text.to_uppercase().chars().filter(|c| c.is_alphanumeric() || *c == '+').collect() };
    let head = squash(headword);
    let mut squashed = squash(label);
    if !head.is_empty() {
        squashed = squashed.replace(&head, "HW");
    }
    // A leading ellipsis stands for the headword: `… OF STYLE` is the headword's own phrase.
    if let Some(rest) = squashed.strip_prefix('…') {
        squashed = format!("…OF{}", rest.trim_start_matches('+'));
    }
    Frame::of(&squashed)
}

/// Every marked span of one class, in document order: its byte offset and its text.
fn spans<'a>(html: &'a str, class: &str) -> Vec<(usize, &'a str)> {
    let needle = format!("class=\"{class}\"");
    let mut out = Vec::new();
    let mut from = 0;
    while let Some(at) = html[from..].find(&needle) {
        let at = from + at;
        let Some(open) = html[at..].find('>') else { break };
        let body = at + open + 1;
        let Some(end) = html[body..].find('<') else { break };
        out.push((at, html[body..body + end].trim()));
        from = body + end;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// One entry as the dictionary writes it: a headword, its part of speech, two frames, a comma list, and a phrase.
    fn blood_vessel() -> &'static str {
        r#"<link rel="stylesheet" href="ocd.css"/>
<span class="ocd_hw">blood vessel</span>
<span class="ocd_class"><span class="ocd_pos">noun</span></span>
<span class="ocd_m2"><span class="ocd_ps">ADJECTIVE</span></span>
<span class="ocd_m3s"><span class="ocd_m3"><span class="ocd_cc"><span class="ocd_co">major</span></span></span></span>
<span class="ocd_m3s"><span class="ocd_m3"><span class="ocd_cc"><span class="ocd_co">broken</span>, <span class="ocd_co">burst</span></span></span></span>
<span class="ocd_m2"><span class="ocd_ps">VERB + BLOOD VESSEL</span></span>
<span class="ocd_m3s"><span class="ocd_m3"><span class="ocd_cc"><span class="ocd_co">block</span>, <span class="ocd_co">constrict</span></span></span></span>
<span class="ocd_m2"><span class="ocd_ps">… OF BLOOD VESSELS</span></span>
<span class="ocd_m3s"><span class="ocd_m3"><span class="ocd_cc"><span class="ocd_co">the walls of a blood vessel</span></span></span></span>"#
    }

    /// **A frame heads the collocates that follow it, and a comma list is a list**: each word its own pair.
    #[test]
    fn a_frame_heads_the_collocates_after_it() {
        let found = extract(blood_vessel());
        assert_eq!(found.headword, "blood vessel");
        assert_eq!(
            found.pairs,
            vec![
                (Frame::Adjective, "major".to_string()),
                (Frame::Adjective, "broken".to_string()),
                (Frame::Adjective, "burst".to_string()),
                (Frame::VerbPlusHeadword, "block".to_string()),
                (Frame::VerbPlusHeadword, "constrict".to_string()),
            ],
            "the phrase frame's list is a plural the vocabulary does not name, so it is dropped and counted"
        );
        assert_eq!(found.dropped, 1, "the elided plural frame is counted, not coerced");
    }

    /// **The comparison is the spelling after case, hyphens and spaces**: the dictionary writes `ELECTRIC-SHOCK` for
    /// `electric shock`, and both sides must meet.
    #[test]
    fn a_hyphenated_frame_finds_its_headword() {
        let html = r#"<span class="ocd_hw">electric shock</span>
<span class="ocd_m2"><span class="ocd_ps">ELECTRIC-SHOCK + NOUN</span></span>
<span class="ocd_m3s"><span class="ocd_m3"><span class="ocd_cc"><span class="ocd_co">treatment</span></span></span></span>"#;
        assert_eq!(extract(html).pairs, vec![(Frame::HeadwordPlusNoun, "treatment".to_string())]);
    }

    /// **A frame the vocabulary does not hold is dropped and counted**, never squeezed into a neighbour: a wrong frame
    /// that looks measured is worse than a gap.
    #[test]
    fn an_unknown_frame_is_dropped_and_counted() {
        let html = r#"<span class="ocd_hw">engage</span>
<span class="ocd_m2"><span class="ocd_ps">VERB + ENGAGE IN</span></span>
<span class="ocd_m3s"><span class="ocd_m3"><span class="ocd_cc"><span class="ocd_co">attempt</span>, <span class="ocd_co">discussion</span></span></span></span>
<span class="ocd_m2"><span class="ocd_ps">ADVERB</span></span>
<span class="ocd_m3s"><span class="ocd_m3"><span class="ocd_cc"><span class="ocd_co">actively</span></span></span></span>"#;
        let found = extract(html);
        assert_eq!(found.pairs, vec![(Frame::Adverb, "actively".to_string())]);
        assert_eq!(found.dropped, 2, "both words of the unnamed group are counted");
    }
}
