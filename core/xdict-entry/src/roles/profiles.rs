//! Per-markup role tables (owner, 2026-10-16: unification step 2, part of speech first). A table names one markup
//! (a publisher's or a converter's HTML, shared by every edition written in it) by classes its sheets style, and
//! that markup's own selectors for a role. Where a table matches, its selectors decide the role and mark it sure
//! (`data-xdict-sure`), which the frame styles strongly; the generic rule's guesses for that role are not written.
//! Where none matches, the generic rule stands, unmarked as sure, and the frame leaves it as the dictionary drew it.
//!
//! Keyed by markup, never by an edition's hash or a file's name: a new printing of the same markup is covered, and
//! nothing here names a reader's file. A table is promoted only where the holdout (`/tmp/unify-holdout`, measured
//! 2026-10-16) put its precision at 0.95 or more; the measurements are in `dev-docs/plan-macos-v1.md` WI-11.

use crate::facts::Facts;

/// One markup's table.
pub(crate) struct Profile {
    /// Classes (lower case) the edition's sheets must all style, as a rule's subject: what names the markup.
    signature: &'static [&'static str],
    /// The part of speech: element (`None`: any) and classes, all of which the element must carry.
    pos: &'static [(Option<&'static str>, &'static [&'static str])],
    /// The selector also holds other short labels: only text the generic part-of-speech words accept is one.
    pub(crate) pos_words: bool,
}

impl Profile {
    /// Whether an element of `tag` (lower case) and `classes` (lower case) is this markup's part of speech.
    pub(crate) fn is_pos(&self, tag: &str, classes: &[String]) -> bool {
        self.pos.iter().any(|(t, cs)| t.is_none_or(|t| t == tag) && cs.iter().all(|c| classes.iter().any(|k| k == c)))
    }
}

const SPAN_POS: &[(Option<&str>, &[&str])] = &[(Some("span"), &["pos"])];

/// The tables, the first match wins. Signatures are classes no other of the measured 24's sheets style.
pub(crate) const PROFILES: &[Profile] = &[
    // LDOCE 6 and its English–Chinese edition.
    Profile { signature: &["chwd", "collobox", "pos"], pos: SPAN_POS, pos_words: false },
    // OALD 10.
    Profile { signature: &["oup_icons", "ox3ksym_a1", "pos"], pos: SPAN_POS, pos_words: false },
    // ODE 3 with Chinese (ODECN): `div.pos` heads a part-of-speech block, and may hold its inflections too
    // ("modal verb 3rd sing. present will"): only one that holds the part of speech alone is.
    Profile {
        signature: &["odecn", "pos_inflections", "pos"],
        pos: &[(Some("span"), &["pos"]), (Some("div"), &["pos"])],
        pos_words: true,
    },
    // Collins English Dictionary.
    Profile {
        signature: &["dictentry", "gramgrp", "pos"],
        pos: &[(Some("span"), &["gramgrp", "pos"])],
        pos_words: false,
    },
    // Cambridge English Pronouncing Dictionary.
    Profile { signature: &["di-head", "sense-block", "pos"], pos: SPAN_POS, pos_words: false },
    // Chambers.
    Profile { signature: &["cb13_jp", "phrase_entry", "pos"], pos: SPAN_POS, pos_words: false },
    // COBUILD and its English–Chinese edition: `st` holds COBUILD's grammar codes (`ADJ-GRADED`, `N-COUNT`).
    Profile { signature: &["collins_en_cn", "tips_box", "st"], pos: &[(Some("span"), &["st"])], pos_words: false },
    // Merriam-Webster's Advanced Learner's and Unabridged: `fl`, the functional label.
    Profile { signature: &["scnt", "vi", "fl"], pos: &[(None, &["fl"])], pos_words: false },
    // Etymonline.
    Profile {
        signature: &["word__name", "related__word", "word_c"],
        pos: &[(Some("span"), &["word_c"])],
        pos_words: false,
    },
    // Macmillan English Dictionary.
    Profile {
        signature: &["boxsensefull", "base-form", "part-of-speech"],
        pos: &[(Some("span"), &["part-of-speech"])],
        pos_words: false,
    },
    // NOAD 3: `p` also holds grammar words (`obj.`).
    Profile { signature: &["m1", "m2", "opt", "p"], pos: &[(Some("span"), &["p"])], pos_words: true },
    // Oxford Collocations.
    Profile { signature: &["ocd_hw", "ocd_pos"], pos: &[(None, &["ocd_pos"])], pos_words: false },
    // ODE.
    Profile { signature: &["a8e", "aej", "xno"], pos: &[(Some("span"), &["xno"])], pos_words: false },
    // 21st Century English–Chinese (YHDCD).
    Profile { signature: &["cxa", "phmk", "cx"], pos: &[(Some("span"), &["cx"])], pos_words: false },
];

/// The table of the markup an edition's sheets name, if any.
pub(crate) fn of(facts: &Facts) -> Option<&'static Profile> {
    PROFILES.iter().find(|p| p.signature.iter().all(|c| facts.styles_class(c)))
}
