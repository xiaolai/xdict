//! **Word exploration across the core's boundary** (plan-word-exploration WI-4; the owner's shape, 2026-10-27): a page
//! carries what a list draws — the word, the dictionary and entry it opens, a reason *label*, and whether the
//! dictionaries could answer at all — and nothing of the evidence behind it. A pronunciation, a derivation's steps and
//! an etymology path are asked for the one row the reader opens, so the shell's contract stays small and a page stays
//! cheap.
//!
//! **The reason is a value, never a sentence**: the core holds no text in any language, so a shell labels
//! [`ExploreReason`] in the reader's own words. A row always names a dictionary and an entry: exploration may explain a
//! query the dictionaries have nothing under, but it never offers a word that no dictionary holds (ADR-0032 d.1).

use crate::types::EntryRef;
use crate::words::{SenseRelation, WordHit, WordPage, WordReason, WordStatus};

/// Why a row is in the answer.
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(rename_all = "camelCase", rename_all_fields = "camelCase", tag = "type"))]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExploreReason {
    /// The same spelling, normalized.
    Exact,
    /// The spelling ends with the query's.
    EndsWith,
    /// `distance` edits away (optimal string alignment).
    Spelling { distance: u8 },
    /// The same rime, from the last stressed vowel to the end.
    Rhyme,
    /// In the same paradigm as the query.
    Inflection,
    /// In the query's sourced derivational family.
    Derivation,
    /// The same historical ancestor.
    SharedOrigin,
    /// A synset files them as synonyms (`words::SenseRelation::Synonym`).
    Synonym,
    /// A synset files them as antonyms.
    Antonym,
}

/// One row of the list: the word, the entry it opens, and why it is there.
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(rename_all = "camelCase"))]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExploreRow {
    /// The catalog's own spelling.
    pub word: String,
    /// The dictionary that holds it.
    pub dict: String,
    /// The entry to open, edition-qualified, with its occurrence.
    pub entry: EntryRef,
    pub reason: ExploreReason,
}

/// Whether the dictionaries could be searched at all — absence of data is never reported as absence of relatives.
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(rename_all = "camelCase", rename_all_fields = "camelCase", tag = "type"))]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExploreState {
    /// Searched: the rows are the answer, possibly none.
    Answered,
    /// No pack is attached, or the one attached holds none of this kind of data.
    NoData,
    /// The pack holds the kind, but nothing for this query.
    Unknown,
}

/// One page of an exploration.
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(rename_all = "camelCase"))]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExploreAnswer {
    pub state: ExploreState,
    /// At most one row per headword: its first source, in the reader's dictionary order. Every source, and the
    /// evidence a row stands on, come from the evidence call for the row the reader opens.
    pub rows: Vec<ExploreRow>,
    /// The offset of the next page, when the answer holds more rows than this page reached.
    pub next: Option<u32>,
    /// The answer was cut short by a work budget: what is here is not all there is.
    pub exhausted: bool,
}

impl ExploreAnswer {
    /// **An answer no dictionary had to be read for**: a mode that needs the word data, with none attached. The
    /// catalog is not built for it — that costs seconds and an answer of `NoData` is certain before it starts.
    pub(crate) fn no_data() -> Self {
        Self { state: ExploreState::NoData, rows: Vec::new(), next: None, exhausted: false }
    }

    /// One page of a word page, as the shell reads it.
    pub(crate) fn of(page: WordPage) -> Self {
        let state = match page.status {
            WordStatus::Answered => ExploreState::Answered,
            WordStatus::NoData { .. } => ExploreState::NoData,
            WordStatus::QueryUnknown { .. } => ExploreState::Unknown,
        };
        let rows = page.hits.into_iter().filter_map(Self::row).collect();
        Self { state, rows, next: page.next, exhausted: page.exhausted.is_some() }
    }

    /// A hit as one row: its first source and its first reason. A hit with no source cannot happen (the catalog
    /// refuses one), and a hit with no reason cannot either; both are dropped rather than invented.
    fn row(hit: WordHit) -> Option<ExploreRow> {
        let source = hit.sources.into_iter().next()?;
        let reason = Self::reason(hit.reasons.into_iter().next()?)?;
        Some(ExploreRow { word: hit.headword, dict: source.dict, entry: source.entry, reason })
    }

    fn reason(reason: WordReason) -> Option<ExploreReason> {
        Some(match reason {
            WordReason::Exact => ExploreReason::Exact,
            WordReason::EndsWith => ExploreReason::EndsWith,
            WordReason::Spelling { distance } => ExploreReason::Spelling { distance },
            WordReason::Rhyme { .. } => ExploreReason::Rhyme,
            WordReason::Inflection { .. } => ExploreReason::Inflection,
            WordReason::Derivation { .. } => ExploreReason::Derivation,
            WordReason::SharedOrigin { .. } => ExploreReason::SharedOrigin,
            WordReason::Sense { relation, .. } => match relation {
                SenseRelation::Synonym | SenseRelation::Hypernym | SenseRelation::Hyponym => ExploreReason::Synonym,
                SenseRelation::Antonym => ExploreReason::Antonym,
            },
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::EntryRef;

    fn entry() -> EntryRef {
        EntryRef { edition: "e1".into(), key: "accommodate".into(), occurrence: 0 }
    }

    fn hit(word: &str, reason: WordReason) -> WordHit {
        WordHit {
            headword: word.into(),
            sources: vec![crate::words::WordSource { dict: "handle-1".into(), entry: entry() }],
            reasons: vec![reason],
        }
    }

    fn page(status: WordStatus, hits: Vec<WordHit>, next: Option<u32>, cut: bool) -> WordPage {
        WordPage {
            mode: crate::words::WordMode::EndsWith,
            status,
            hits,
            total: None,
            next,
            exhausted: cut.then_some(crate::words::WordLimit::Work),
        }
    }

    /// **A row is a word, its entry and a label** — the first source and the first reason, and nothing else.
    #[test]
    fn a_hit_becomes_one_row_of_its_first_source() {
        let mine =
            page(WordStatus::Answered, vec![hit("accommodate", WordReason::Spelling { distance: 1 })], None, false);
        let answer = ExploreAnswer::of(mine);
        assert_eq!(answer.state, ExploreState::Answered);
        assert_eq!(answer.rows.len(), 1);
        assert_eq!(answer.rows.first().map(|r| r.word.as_str()), Some("accommodate"));
        assert_eq!(answer.rows.first().map(|r| r.dict.as_str()), Some("handle-1"));
        assert_eq!(answer.rows.first().map(|r| r.reason), Some(ExploreReason::Spelling { distance: 1 }));
        assert!(answer.next.is_none() && !answer.exhausted);
    }

    /// **Absence of data is not absence of relatives**: the three states cross as they are, and a cut answer says so.
    #[test]
    fn the_state_and_the_cut_cross_as_they_are() {
        for (status, state) in [
            (WordStatus::Answered, ExploreState::Answered),
            (WordStatus::NoData { data: crate::words::WordData::Pronunciation }, ExploreState::NoData),
            (WordStatus::QueryUnknown { data: crate::words::WordData::Origins }, ExploreState::Unknown),
        ] {
            assert_eq!(ExploreAnswer::of(page(status, Vec::new(), None, false)).state, state);
        }
        let cut = page(
            WordStatus::Answered,
            vec![hit(
                "station",
                WordReason::Rhyme {
                    query: crate::words::Pronunciation {
                        system: crate::words::PhoneSystem::Arpabet,
                        phonemes: vec!["EY1".into()],
                        pos: None,
                        dialect: None,
                        source: "cmu".into(),
                    },
                    hit: crate::words::Pronunciation {
                        system: crate::words::PhoneSystem::Arpabet,
                        phonemes: vec!["EY1".into()],
                        pos: None,
                        dialect: None,
                        source: "cmu".into(),
                    },
                    rime: vec!["EY1".into()],
                },
            )],
            Some(40),
            true,
        );
        let answer = ExploreAnswer::of(cut);
        assert!(answer.exhausted, "a cut answer says so");
        assert_eq!(answer.next, Some(40));
        assert_eq!(answer.rows.first().map(|r| r.reason), Some(ExploreReason::Rhyme));
    }
}
