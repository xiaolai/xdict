//! The matcher: every phrase of the inventory that covers the word under the pointer, best first. Ported from
//! XiaolaiDict's `PhraseSpans`.

use std::collections::{HashMap, HashSet};

use crate::template::{Separation, Slots, Template, tokens};

/// One phrase found around the pointer. **A candidate, never a verdict** (XiaolaiDict ADR-0007): the caller shows
/// it or not, and length does not choose the unit.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Match {
    /// The dictionary's own spelling — slots and all — which is the string to look up.
    pub phrase: String,
    /// First and last matched word of the sentence handed in, gap included.
    pub first: usize,
    pub last: usize,
    pub separation: Separation,
}

impl Match {
    pub fn gap(&self) -> usize {
        match self.separation {
            Separation::None => 0,
            Separation::Marked { words } | Separation::Inferred { words } => {
                usize::try_from(words).unwrap_or(usize::MAX)
            }
        }
    }
}

/// The inventory's phrases, indexed by the words they name.
pub struct Matcher {
    phrase_list: Vec<String>,
    /// **Each phrase's template, parsed once** (audit rounds 1–4, 2026-10-26): a lookup used to reparse every reachable
    /// phrase into a template, so a hover's cost grew with the inventory rather than with what it could match.
    templates: Vec<Template>,
    /// Literal word to the phrases containing it. A hover looks at the phrases naming the word under the pointer and
    /// at nothing else, which keeps a million-phrase inventory a hash lookup rather than a scan.
    by_word: HashMap<String, Vec<usize>>,
}

impl Matcher {
    /// Multi-word phrases only; a phrase with fewer than two literal words is not a phrase (a single word is looked
    /// up directly).
    pub fn new<I: IntoIterator<Item = String>>(phrases: I, slots: Slots) -> Self {
        let mut phrase_list: Vec<String> = Vec::new();
        let mut templates: Vec<Template> = Vec::new();
        let mut by_word: HashMap<String, Vec<usize>> = HashMap::new();
        for phrase in phrases {
            let words = tokens(&phrase);
            if words.len() < 2 {
                continue;
            }
            let mut literals = 0usize;
            let mut seen: HashSet<&String> = HashSet::new();
            for word in &words {
                if slots.is_slot(word) {
                    continue;
                }
                literals += 1;
                seen.insert(word);
            }
            if literals <= 1 {
                continue;
            }
            // **A phrase with no template is no phrase at all**: the template is what a lookup matches against, so it
            // is built here once, and a phrase it refuses is left out of the index rather than parsed on every hover.
            let Some(template) = Template::new(&phrase, &slots) else { continue };
            let index = phrase_list.len();
            phrase_list.push(phrase);
            templates.push(template);
            for word in seen {
                by_word.entry(word.clone()).or_default().push(index);
            }
        }
        Self { phrase_list, templates, by_word }
    }

    pub fn len(&self) -> usize {
        self.phrase_list.len()
    }

    pub fn is_empty(&self) -> bool {
        self.phrase_list.is_empty()
    }

    /// **Every phrase covering `word`, best first.** Ranked by how much of the phrase is written out, then by the
    /// narrowest gap, then by the reader's own spelling over the dictionary's form, then by phrase so the same
    /// sentence always answers the same way. Nothing is dropped — this is the order the caller receives them in.
    ///
    /// `words` are the sentence's positions, each one's candidate forms (lowercase), as [`crate::forms`] supplies.
    pub fn matches(
        &self,
        words: &[Vec<String>],
        word: usize,
        widest_gap: usize,
        widest_inferred_gap: usize,
    ) -> Vec<Match> {
        let Some(forms) = words.get(word) else { return Vec::new() };
        let mut reachable: Vec<usize> = Vec::new();
        let mut seen = HashSet::new();
        for form in forms {
            if let Some(indices) = self.by_word.get(form) {
                for index in indices {
                    if seen.insert(*index) {
                        reachable.push(*index);
                    }
                }
            }
        }
        let mut found: Vec<(usize, usize, Match)> = Vec::new();
        for index in reachable {
            let Some(template) = self.templates.get(index) else { continue };
            if let Some((hit, borrowed)) = tightest(template, words, word, widest_gap, widest_inferred_gap) {
                found.push((template.literals(), borrowed, hit));
            }
        }
        found.sort_by(|first, second| {
            second
                .0
                .cmp(&first.0)
                .then_with(|| first.2.gap().cmp(&second.2.gap()))
                .then_with(|| first.1.cmp(&second.1))
                .then_with(|| first.2.phrase.cmp(&second.2.phrase))
        });
        found.into_iter().map(|(_, _, hit)| hit).collect()
    }
}

/// The narrowest placement of one template that covers the word: the phrase as the publisher spelled it first, then
/// — only for a separable two-word verb, and only if nothing unbroken was found — the inferred split.
fn tightest(
    template: &Template,
    words: &[Vec<String>],
    word: usize,
    widest_gap: usize,
    widest_inferred_gap: usize,
) -> Option<(Match, usize)> {
    let mut best = consider(template, template.runs(), words, word, widest_gap, false);
    if best.is_none()
        && template.separable()
        && let Some(run) = template.runs().first()
        && let (Some(first), Some(second)) = (run.first(), run.get(1))
    {
        let split = vec![vec![first.clone()], vec![second.clone()]];
        best = consider(template, &split, words, word, widest_inferred_gap, true);
    }
    best
}

fn consider(
    template: &Template,
    runs: &[Vec<String>],
    words: &[Vec<String>],
    word: usize,
    cap: usize,
    inferred: bool,
) -> Option<(Match, usize)> {
    let mut best: Option<(Match, usize)> = None;
    let mut starts: Vec<usize> = Vec::with_capacity(runs.len());
    // **Each placement is weighed as it is found** (audit round 4, 2026-10-26): collecting them first made seven runs
    // around one word allocate tens of thousands of vectors, and almost all covered nothing the reader pointed at.
    placements_covering(runs, words, 0, cap, word, &mut starts, &mut |starts| {
        let (Some(first), Some(last), Some(tail)) = (starts.first(), starts.last(), runs.last()) else { return };
        let end = last + tail.len();
        let span = end.saturating_sub(*first);
        let Some(gap) = span.checked_sub(template.literals()) else { return };
        if gap > cap {
            return;
        }
        let separation = if gap == 0 {
            Separation::None
        } else if inferred {
            Separation::Inferred { words: gap as u64 }
        } else {
            Separation::Marked { words: gap as u64 }
        };
        let taken = borrowed_forms(runs, starts, words);
        let better = match &best {
            None => true,
            Some((current, current_borrowed)) => {
                gap < current.gap() || (gap == current.gap() && taken < *current_borrowed)
            }
        };
        if better {
            best = Some((
                Match { phrase: template.phrase().to_string(), first: *first, last: end - 1, separation },
                taken,
            ));
        }
    });
    best
}

/// **Every placement of the runs that can cover the word**, visited one at a time in order: a slot filled by at least
/// one word, and the first run starting at or before the word. A branch whose next run would begin past the word, with
/// no run before it covering it, is dropped: every later run begins later still (audit round 4, 2026-10-26).
fn placements_covering(
    runs: &[Vec<String>],
    words: &[Vec<String>],
    from: usize,
    budget: usize,
    word: usize,
    starts: &mut Vec<usize>,
    visit: &mut impl FnMut(&[usize]),
) {
    let Some(run) = runs.first() else { return };
    let rest = runs.get(1..).unwrap_or(&[]);
    let first_run = starts.is_empty();
    let last =
        if first_run { word.min(words.len().saturating_sub(run.len())) } else { words.len().saturating_sub(run.len()) };
    let mut start = from;
    while start <= last {
        let gap = if first_run { 0 } else { start.saturating_sub(from) + 1 };
        if gap > budget {
            break;
        }
        // **Past the word with nothing covering it, no later start can**: the runs are in order.
        let covered = starts.iter().zip(runs).any(|(start, run)| (*start..start + run.len()).contains(&word));
        if !first_run && !covered && start > word {
            break;
        }
        let matches = words.get(start..start + run.len()).is_some_and(|slice| {
            slice.iter().zip(run.iter()).all(|(forms, expected)| forms.iter().any(|form| form == expected))
        });
        if matches {
            starts.push(start);
            let end = start + run.len();
            if rest.is_empty() {
                visit(starts);
            } else if let Some(next_budget) = budget.checked_sub(gap) {
                placements_covering(rest, words, end + 1, next_budget, word, starts, visit);
            }
            starts.pop();
        }
        start += 1;
    }
}

/// How many positions matched a form the reader did not write; zero when the key is spelled exactly as the sentence
/// spells it (the written form is first in each position's forms).
fn borrowed_forms(runs: &[Vec<String>], starts: &[usize], words: &[Vec<String>]) -> usize {
    let mut borrowed = 0;
    for (start, run) in starts.iter().zip(runs.iter()) {
        for (offset, expected) in run.iter().enumerate() {
            let written = words.get(start + offset).and_then(|forms| forms.first());
            if written != Some(expected) {
                borrowed += 1;
            }
        }
    }
    borrowed
}
