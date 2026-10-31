//! **One edition's collocations, as a derived store** (plan-word-exploration WI-6; ADR-0031's shape): extracted once
//! per edition from the dictionary's own markup, keyed by a version, disposable, and never synced. A reader's
//! dictionaries are where collocations come from — no redistributable lexicon exists — so the store's coverage *is* the
//! reader's library, and a dictionary without collocation markup contributes nothing.
//!
//! **A frame outside the extractor's closed vocabulary is dropped there and counted here**: the count travels in the
//! store, so a gap in the extractor is visible instead of looking like a dictionary that has no collocations there.

use std::collections::BTreeMap;
use std::fmt;

/// **The frame vocabulary is the entry crate's**: extraction and storage must not drift into two lists.
pub use xdict_entry::collocations::Frame;
use xdict_entry::collocations::{Collocations, extract};
use xdict_mdx::File;

use crate::CoreError;
use crate::sampling::{SIGNATURE_RECORD_BYTES, SIGNATURE_SAMPLES, any_sampled_record, with_record};
use crate::types::EntryRef;

/// **The extractor and frame vocabulary together**, stored in every store built under them: raised by any change to
/// either, so a store built before is rebuilt rather than read under rules it was not built with.
pub const COLLOCATION_VERSION: u32 = 1;

/// **The most one store may hold and read** (audit, 2026-10-28): the build walks every record of the file with no
/// other bound, so a huge or pathological dictionary would hold the calling thread for as long as it takes. The pair
/// count bounds what is retained, the byte count what is read, and both refuse the whole store rather than truncate it
/// — half a dictionary's collocations would look like a dictionary that has fewer.
pub const MAX_COLLOCATION_PAIRS: usize = 2_000_000;
pub const MAX_COLLOCATION_BYTES: u64 = 512 << 20;

/// **What a collocation dictionary has and nothing else does** (the owner's performance defect, 2026-10-31): one
/// record's headword, frame and collocate classes — the three the extractor needs to make a pair. A record without all
/// three contributes nothing however it is read, so a dictionary whose sample has none can be answered without its
/// store. The needles are the extractor's own (`class="ocd_hw"`, `class="ocd_ps"`, `class="ocd_co"` exactly), and a
/// looser test here would answer "no collocations" for markup the extractor does read.
pub fn carries_signature(markup: &str) -> bool {
    markup.contains("class=\"ocd_hw\"") && markup.contains("class=\"ocd_ps\"") && markup.contains("class=\"ocd_co\"")
}

/// **Whether a dictionary carries the collocation markup at all**, from a bounded, evenly spaced sample of its
/// records: the extractor's signature without a store. `false` for an empty file, and only when every sampled record
/// was examined and none carried it. **`true` otherwise** — any sample carrying the signature, and an incomplete
/// sample too (a record skipped as oversized) — so the store's full read decides rather than the sampler guessing.
pub fn carries_markup(file: &File) -> Result<bool, CoreError> {
    if file.is_empty() {
        return Ok(false);
    }
    Ok(any_sampled_record(file, SIGNATURE_SAMPLES, SIGNATURE_RECORD_BYTES, carries_signature)?.unwrap_or(true))
}

/// One collocation a dictionary writes: the word it is filed under, its frame, the partner, and the entry that said so.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Collocation {
    /// The headword the collocation is filed under, as the dictionary spells it (the group's `ocd_hw`).
    pub lemma: String,
    pub frame: Frame,
    /// The collocate, as the dictionary spells it.
    pub partner: String,
    /// The dictionary that said so.
    pub dict: String,
    /// The entry it was read from.
    pub entry: EntryRef,
}

/// Every collocation one edition holds, in file order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Store {
    pairs: Vec<Collocation>,
    /// Collocates dropped because their frame was outside the vocabulary. **Counted, never guessed at.**
    dropped: u32,
}

impl Store {
    /// **Reads one dictionary's entries**: every record whose headword group the extractor understands contributes its
    /// collocates; the rest contribute nothing and are not counted as errors.
    pub fn build(file: &File, dict: &str, edition: &str) -> Result<Self, CoreError> {
        {
            let mut pairs = Vec::new();
            let mut dropped = 0u32;
            let mut read: u64 = 0;
            let mut seen: BTreeMap<String, u32> = BTreeMap::new();
            for i in 0..file.len() {
                // **A read's kind survives the context it is given**: an I/O fault, a limit or an unsupported
                // compression used to be reported as `Malformed`, which blames the dictionary for a disk.
                let record = file.record(i).map_err(|e| with_record(CoreError::from(e), i))?;
                let key = file.key(i).map_err(|e| with_record(CoreError::from(e), i))?.into_owned();
                let occurrence = *seen.entry(key.clone()).and_modify(|n| *n += 1).or_insert(0);
                read = read.saturating_add(record.data.len() as u64);
                if read > MAX_COLLOCATION_BYTES {
                    return Err(CoreError::TooLarge {
                        limit: crate::error::Limit::File,
                        detail: format!(
                            "{dict} reads past {MAX_COLLOCATION_BYTES} bytes of entries for its collocations"
                        ),
                    });
                }
                let html = String::from_utf8_lossy(&record.data);
                let Collocations { headword, pairs: found, dropped: lost } = extract(&html);
                dropped += lost;
                if headword.is_empty() {
                    continue;
                }
                let entry = EntryRef { edition: edition.into(), key, occurrence };
                for (frame, partner) in found {
                    if pairs.len() >= MAX_COLLOCATION_PAIRS {
                        return Err(CoreError::TooLarge {
                            limit: crate::error::Limit::File,
                            detail: format!("{dict} holds more than {MAX_COLLOCATION_PAIRS} collocations"),
                        });
                    }
                    pairs.push(Collocation {
                        lemma: headword.clone(),
                        frame,
                        partner,
                        dict: dict.into(),
                        entry: entry.clone(),
                    });
                }
            }
            Ok(Self { pairs, dropped })
        }
    }

    /// Every collocation, in file order: the audit's sample walks this.
    pub fn all(&self) -> &[Collocation] {
        &self.pairs
    }

    /// The collocates of `lemma`, in the dictionary's own order: what the Explore panel's Collocations tab lists.
    pub fn collocates(&self, lemma: &str) -> Vec<&Collocation> {
        self.pairs.iter().filter(|pair| pair.lemma == lemma).collect()
    }

    pub fn len(&self) -> usize {
        self.pairs.len()
    }

    pub fn is_empty(&self) -> bool {
        self.pairs.is_empty()
    }

    /// Collocates dropped for a frame the vocabulary does not hold — the extractor's own gap, carried so it can be seen.
    pub fn dropped(&self) -> u32 {
        self.dropped
    }

    /// **The store as bytes**, for the edition's index: one collocation a line, tab-separated, with the version first.
    /// A field holding a tab or a newline cannot be written — dictionaries do not spell words with them — and is refused
    /// rather than corrupted.
    pub fn encode(&self) -> Result<Vec<u8>, CoreError> {
        {
            let mut out = format!("colloc\t{COLLOCATION_VERSION}\t{}\t{}\n", self.pairs.len(), self.dropped);
            for pair in &self.pairs {
                let frame = frame_name(pair.frame);
                for field in [&pair.lemma, &pair.partner, &pair.entry.key] {
                    if field.contains(['\t', '\n']) {
                        return Err(CoreError::Malformed {
                            detail: "a collocation field holds a tab or a newline".into(),
                        });
                    }
                }
                out.push_str(&format!(
                    "{}\t{frame}\t{}\t{}\t{}\n",
                    pair.lemma, pair.partner, pair.entry.key, pair.entry.occurrence
                ));
            }
            Ok(out.into_bytes())
        }
    }
}

impl fmt::Display for Collocation {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} | {:?} | {}", self.lemma, self.frame, self.partner)
    }
}

/// A frame's stored name: the enum's own, so a store outlives a rename in the source only if the version is raised.
fn frame_name(frame: Frame) -> &'static str {
    match frame {
        Frame::Adjective => "adjective",
        Frame::Adverb => "adverb",
        Frame::Noun => "noun",
        Frame::Verb => "verb",
        Frame::Verbs => "verbs",
        Frame::Preposition => "preposition",
        Frame::Phrases => "phrases",
        Frame::AdjectivePlusHeadword => "adjective+hw",
        Frame::VerbPlusHeadword => "verb+hw",
        Frame::HeadwordPlusVerb => "hw+verb",
        Frame::HeadwordPlusNoun => "hw+noun",
        Frame::NounPlusHeadword => "noun+hw",
        Frame::PhraseOfHeadword => "of+hw",
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

    use super::*;
    use xdict_mdx::Kind;
    use xdict_mdx_writer::{Entry, Spec, write};

    fn dictionary() -> File {
        let entry = |key: &str, html: String| Entry::text(key, &html);
        let bodies = vec![
            (
                "blood vessel",
                r#"<span class="ocd_hw">blood vessel</span><span class="ocd_m2"><span class="ocd_ps">ADJECTIVE</span></span><span class="ocd_m3s"><span class="ocd_m3"><span class="ocd_cc"><span class="ocd_co">major</span>, <span class="ocd_co">broken</span></span></span></span><span class="ocd_m2"><span class="ocd_ps">VERB + BLOOD VESSEL</span></span><span class="ocd_m3s"><span class="ocd_m3"><span class="ocd_cc"><span class="ocd_co">block</span></span></span></span>"#,
            ),
            ("plain", "<b>plain</b> an entry with no collocations at all"),
        ];
        let entries: Vec<Entry> = bodies.into_iter().map(|(k, v)| entry(k, v.to_string())).collect();
        let bytes = write(&Spec::mdx(), &entries).unwrap();
        File::from_source(Box::new(bytes), Some(Kind::Mdx)).unwrap()
    }

    /// **The store holds what the entry said**: the frame, the partner, and the entry it was read from.
    #[test]
    fn a_store_holds_the_pairs_and_the_entry_that_said_so() {
        let file = dictionary();
        let store = Store::build(&file, "handle-1", "e1").unwrap();
        assert_eq!(store.len(), 3);
        let found = store.collocates("blood vessel");
        assert_eq!(found.len(), 3);
        assert_eq!(found[0].frame, Frame::Adjective);
        assert_eq!(found[0].partner, "major");
        assert_eq!(found[2].frame, Frame::VerbPlusHeadword);
        assert_eq!(found[0].entry.key, "blood vessel");
        assert_eq!(found[0].entry.edition, "e1");
        assert!(store.collocates("plain").is_empty(), "an entry with no frames has no collocates");
        assert_eq!(store.dropped(), 0);
    }

    /// **The store is bytes with its version in front**, so a store built under another extractor is refused rather
    /// than read under rules it was not built with.
    #[test]
    fn the_store_encodes_with_its_version() {
        let store = Store::build(&dictionary(), "handle-1", "e1").unwrap();
        let bytes = store.encode().unwrap();
        let text = String::from_utf8(bytes).unwrap();
        assert!(text.starts_with(&format!("colloc\t{COLLOCATION_VERSION}\t3\t0\n")), "{text}");
        assert!(text.contains("blood vessel\tverb+hw\tblock\tblood vessel\t0"), "{text}");
    }

    /// **The signature is the extractor's own markup, and a dictionary without it is answered without a store** (the
    /// owner's performance defect, 2026-10-31): a probe reads at most 64 records for the three `ocd_` classes, where a
    /// store's build reads every record — which the Explore panel paid once per non-collocation dictionary in the
    /// reader's library.
    #[test]
    fn a_dictionary_without_markup_has_no_signature() {
        assert!(
            carries_signature(
                r#"<span class="ocd_hw">blood vessel</span><span class="ocd_ps">ADJECTIVE</span><span class="ocd_co">major</span>"#
            ),
            "the collocation dictionary's own headword, frame and collocate"
        );
        // **The other dictionaries' markup is not a signature**: the Oxford Dictionary of English's headword and part
        // of speech, and the converted thesaurus's senses and clusters, carry no collocation class.
        assert!(!carries_signature(r#"<span class="hw">run</span><span class="se1">to move</span>"#));
        assert!(!carries_signature(
            r#"<span class="msThes"><span class="synGroup"><span class="syn">verdict</span></span></span>"#
        ));
        assert!(!carries_signature(r#"<span class="OCD_CO">major</span>"#), "classes are exact");
        // **All three are needed**: a record with two of them makes no pair, so it is not a signature.
        assert!(!carries_signature(r#"<span class="ocd_hw">blood vessel</span><span class="ocd_co">major</span>"#));
        assert!(!carries_signature(r#"<span class="ocd_hw">blood vessel</span><span class="ocd_ps">ADJECTIVE</span>"#));
        assert!(!carries_signature("an entry with no markup"));
        assert!(carries_markup(&dictionary()).unwrap(), "the fixture's collocation entry is a signature");
        let plain =
            xdict_mdx_writer::write(&Spec::mdx(), &[Entry::text("run", r#"<span class="hw">run</span>to move"#)])
                .unwrap();
        let plain = File::from_source(Box::new(plain), Some(Kind::Mdx)).unwrap();
        assert!(!carries_markup(&plain).unwrap(), "a plain dictionary is answered without a store");
    }
}
