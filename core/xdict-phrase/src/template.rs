//! A phrase as the dictionary spells it: literal runs and the slots a publisher wrote between them
//! (`take something into account` is `[take] [into, account]`). Ported from XiaolaiDict's `PhraseSpans.Template`.

use std::collections::BTreeSet;

/// How far apart the literal words of one phrase may sit where the publisher marked the slot: the predecessor's
/// measured cap, above real prose (its question sentence put nine words in one slot).
pub const DEFAULT_WIDEST_GAP: usize = 12;

/// How far apart a bare two-word phrasal verb may be broken on the matcher's own inference: tight, because nobody
/// marked this gap (the predecessor's p99 of 598 measured fillings).
pub const DEFAULT_WIDEST_INFERRED_GAP: usize = 3;

/// The particles a two-word phrasal verb may be broken around. Deliberately short: every word here is adverbial in
/// the separable construction (`turn the light on`); the prepositional ones are out on purpose (`look after` is not
/// separable, and admitting `after` would match *look* at the child *after* lunch).
const PARTICLES: [&str; 13] =
    ["up", "down", "out", "off", "in", "on", "over", "away", "back", "together", "apart", "aside", "forward"];

/// **The slot vocabulary of one edition** (plan D5): what a publisher writes where the reader writes an object.
/// The caller builds it from its own measured table; the English long forms are the predecessor's measured set,
/// and the abbreviations are the MDX corpus's own (`sb`, `sth`), which v1 offers as a separate class.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Slots {
    words: BTreeSet<String>,
}

impl Slots {
    /// The predecessor's measured set: `something`, `someone`, `somebody`, `someone's`, `somebody's`, `one's`,
    /// `oneself`.
    pub fn english() -> Self {
        Self::from(["something", "someone", "somebody", "someone's", "somebody's", "one's", "oneself"])
    }

    /// Plus the MDX abbreviations, in their spelled and punctuated forms.
    pub fn with_abbreviations(self) -> Self {
        self.with(["sb", "sth", "sb's", "sth's", "sb.", "sth."])
    }

    pub fn with<I: IntoIterator<Item = S>, S: AsRef<str>>(mut self, words: I) -> Self {
        for word in words {
            self.words.insert(word.as_ref().to_lowercase());
        }
        self
    }

    pub fn from<I: IntoIterator<Item = S>, S: AsRef<str>>(words: I) -> Self {
        Self::default().with(words)
    }

    pub fn is_slot(&self, word: &str) -> bool {
        self.words.contains(word)
    }

    /// The vocabulary, sorted, as a store records it.
    pub fn words(&self) -> &BTreeSet<String> {
        &self.words
    }
}

/// Whether the words of the phrase sat together, and on whose authority they were allowed not to.
///
/// The payload is `u64`, and the variants carry named fields, because this type crosses the bindings: UniFFI has no
/// `usize`, and the Web binding serialises it as a tagged object (`{"type":"marked","words":2}`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(rename_all = "camelCase", rename_all_fields = "camelCase", tag = "type"))]
pub enum Separation {
    /// Written unbroken, exactly as the dictionary spells it.
    None,
    /// The publisher wrote a slot here, and this many words of the sentence filled it.
    Marked { words: u64 },
    /// The publisher wrote the phrase unbroken; the gap is the matcher's own inference.
    Inferred { words: u64 },
}

/// One phrase, split at its slots.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Template {
    phrase: String,
    runs: Vec<Vec<String>>,
    literals: usize,
}

impl Template {
    /// Nil when the phrase has fewer than two literal words: one word is never a phrase here, however many slots
    /// surround it (the bridge already looks a single word up).
    pub fn new(phrase: &str, slots: &Slots) -> Option<Self> {
        let mut runs: Vec<Vec<String>> = Vec::new();
        let mut run: Vec<String> = Vec::new();
        for word in tokens(phrase) {
            if slots.is_slot(&word) {
                if !run.is_empty() {
                    runs.push(std::mem::take(&mut run));
                }
            } else {
                run.push(word);
            }
        }
        if !run.is_empty() {
            runs.push(run);
        }
        let literals = runs.iter().map(Vec::len).sum();
        if literals <= 1 {
            return None;
        }
        Some(Self { phrase: phrase.to_string(), runs, literals })
    }

    pub fn phrase(&self) -> &str {
        &self.phrase
    }

    pub fn literals(&self) -> usize {
        self.literals
    }

    pub(crate) fn runs(&self) -> &[Vec<String>] {
        &self.runs
    }

    /// **A two-word phrasal verb the publisher wrote unbroken, which English lets a reader break.** The one place
    /// this crate infers anything; restricted to exactly two literal words whose second is a particle.
    pub(crate) fn separable(&self) -> bool {
        self.runs.len() == 1
            && self
                .runs
                .first()
                .is_some_and(|run| run.len() == 2 && run.get(1).is_some_and(|word| PARTICLES.contains(&word.as_str())))
    }
}

/// A phrase's words, as the dictionary wrote them, lowercased for matching. **Whitespace, and nothing else** — the
/// predecessor measured that finer tokenisation disagrees with the key (`24-hour`, `one's`).
pub fn tokens(phrase: &str) -> Vec<String> {
    phrase.split_whitespace().map(str::to_lowercase).collect()
}
