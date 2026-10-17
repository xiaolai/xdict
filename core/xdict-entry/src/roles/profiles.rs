//! Per-markup role tables (owner, 2026-10-16: unification step 2, part of speech first). A table names one markup
//! (a publisher's or a converter's HTML, shared by every edition written in it) by classes its sheets style, and
//! that markup's own selectors for a role. Where a table matches, its selectors decide the role and mark it sure
//! (`data-xdict-sure`), which the frame styles strongly; the generic rule's guesses for that role are not written.
//! Where none matches, or a table names nothing for a role, the generic rule stands for it, unmarked as sure, and the
//! frame leaves it as the dictionary drew it.
//!
//! Keyed by markup, never by an edition's hash or a file's name: a new printing of the same markup is covered, and
//! nothing here names a reader's file. A role's selectors are in a table only where the holdout
//! (`/tmp/unify-holdout`, measured 2026-10-16) put that table's precision for the role at 0.95 or more; the
//! measurements are in `dev-docs/plan-macos-v1.md` WI-11.

use crate::facts::Facts;

/// Selectors: element (`None`: any) and classes, all of which the element must carry.
type Sel = &'static [(Option<&'static str>, &'static [&'static str])];

/// A role a table makes sure; `data-xdict-sure` repeats the role written.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum Sure {
    Pos,
    Sensenum,
    Example,
    Heading,
    /// A translation, a sense's or an example's: which of the two is the generic rule's call.
    Trans,
    /// Inside an example, text that is not the example's own (a gloss, a grammar pattern, a label): it keeps the
    /// dictionary's look. Not a role; written `data-xdict-sure="keep"`, and only inside an example.
    Keep,
}

impl Sure {
    pub(crate) const ALL: [Sure; 5] = [Sure::Pos, Sure::Sensenum, Sure::Example, Sure::Heading, Sure::Trans];
}

/// One markup's table.
pub(crate) struct Profile {
    /// Classes (lower case) the edition's sheets must all style, as a rule's subject: what names the markup.
    signature: &'static [&'static str],
    /// The part of speech.
    pos: Sel,
    /// The selector also holds other short labels: only text the generic part-of-speech words accept is one.
    pub(crate) pos_words: bool,
    /// Sense numbers: only an element whose text is a number (`roles::numbered`) is one.
    sensenum: Sel,
    /// Examples.
    example: Sel,
    /// Inside an example, what is not its own text (`Sure::Keep`).
    example_keep: Sel,
    /// Section headings: a box's or a block's title ("Word Origin", "EXAMPLES FROM THE CORPUS").
    heading: Sel,
    /// Translations in a bilingual dictionary, of a sense or of an example.
    trans: Sel,
}

/// A table that names nothing: a role a table leaves out stays the generic rule's.
const NONE: Profile = Profile {
    signature: &[],
    pos: &[],
    pos_words: false,
    sensenum: &[],
    example: &[],
    example_keep: &[],
    heading: &[],
    trans: &[],
};

fn matches(sel: Sel, tag: &str, classes: &[String]) -> bool {
    sel.iter().any(|(t, cs)| t.is_none_or(|t| t == tag) && cs.iter().all(|c| classes.iter().any(|k| k == c)))
}

impl Profile {
    /// The role this markup's table gives an element of `tag` (lower case) and `classes` (lower case), if any.
    pub(crate) fn sure(&self, tag: &str, classes: &[String]) -> Option<Sure> {
        if matches(self.pos, tag, classes) {
            Some(Sure::Pos)
        } else if matches(self.sensenum, tag, classes) {
            Some(Sure::Sensenum)
        } else if matches(self.example, tag, classes) {
            Some(Sure::Example)
        } else if matches(self.heading, tag, classes) {
            Some(Sure::Heading)
        } else if matches(self.trans, tag, classes) {
            Some(Sure::Trans)
        } else if matches(self.example_keep, tag, classes) {
            Some(Sure::Keep)
        } else {
            None
        }
    }

    /// Whether the table names the role at all: then the generic rule's guesses of it are not written.
    pub(crate) fn decides(&self, sure: Sure) -> bool {
        match sure {
            Sure::Pos => !self.pos.is_empty(),
            Sure::Sensenum => !self.sensenum.is_empty(),
            Sure::Example => !self.example.is_empty(),
            Sure::Heading => !self.heading.is_empty(),
            Sure::Trans => !self.trans.is_empty(),
            Sure::Keep => false,
        }
    }
}

const SPAN_POS: Sel = &[(Some("span"), &["pos"])];

/// The tables, the first match wins. Signatures are classes no other of the measured 24's sheets style.
pub(crate) const PROFILES: &[Profile] = &[
    // LDOCE 6 and its English–Chinese edition.
    Profile {
        signature: &["chwd", "collobox", "pos"],
        pos: SPAN_POS,
        sensenum: &[(Some("span"), &["sensenum"])],
        // An example in a sense, and the corpus's examples (`ul.exas`); a gloss in one, "(=keeping its profits …)".
        example: &[(Some("span"), &["example"]), (Some("ul"), &["exas"])],
        example_keep: &[(Some("span"), &["gloss"])],
        // Its boxes' titles, a word set's name, a thesaurus section's.
        heading: &[
            (Some("span"), &["popheader"]),
            (Some("span"), &["secheading"]),
            (Some("span"), &["ws-head"]),
            (Some("span"), &["popverbs"]),
        ],
        // The English–Chinese edition's `<tran>`, and `<example>`, an example's Chinese inside its `span.example`.
        trans: &[(Some("tran"), &[]), (Some("example"), &[])],
        ..NONE
    },
    // OALD 10: its sense numbers are the sheet's counters, not text.
    Profile {
        signature: &["oup_icons", "ox3ksym_a1", "pos"],
        pos: SPAN_POS,
        // `span.x`, an example; `gloss`, its explanation in brackets ("(= Certainly not!)").
        example: &[(Some("span"), &["x"])],
        example_keep: &[(Some("span"), &["gloss"])],
        heading: &[(Some("span"), &["box_title"]), (Some("span"), &["idioms_heading"])],
        ..NONE
    },
    // ODE 3 with Chinese (ODECN): `div.pos` heads a part-of-speech block, and may hold its inflections too
    // ("modal verb 3rd sing. present will"): only one that holds the part of speech alone is.
    Profile {
        signature: &["odecn", "pos_inflections", "pos"],
        pos: &[(Some("span"), &["pos"]), (Some("div"), &["pos"])],
        pos_words: true,
        sensenum: &[(Some("span"), &["num"])],
        // `p.en`, an example's English; a grammar note inside it ("with clause") is a label.
        example: &[(Some("p"), &["en"])],
        example_keep: &[(Some("span"), &["grammatical-note"])],
        heading: &[(Some("div"), &["label"])],
        trans: &[(Some("div"), &["cn_def"]), (Some("p"), &["cn"])],
    },
    // Collins English Dictionary.
    Profile {
        signature: &["dictentry", "gramgrp", "pos"],
        pos: &[(Some("span"), &["gramgrp", "pos"])],
        sensenum: &[(Some("span"), &["sensenum"])],
        ..NONE
    },
    // Cambridge English Pronouncing Dictionary.
    Profile { signature: &["di-head", "sense-block", "pos"], pos: SPAN_POS, ..NONE },
    // Chambers.
    Profile { signature: &["cb13_jp", "phrase_entry", "pos"], pos: SPAN_POS, ..NONE },
    // COBUILD and its English–Chinese edition: `st` holds COBUILD's grammar codes (`ADJ-GRADED`, `N-COUNT`).
    // `text_blue` also holds its examples' headwords and its frequency band: only its numbers are sense numbers.
    Profile {
        signature: &["collins_en_cn", "tips_box", "st"],
        pos: &[(Some("span"), &["st"])],
        sensenum: &[(Some("span"), &["num"]), (Some("span"), &["text_blue"])],
        // A list item is an example, its English and its Chinese (a Chinese block is the translation: `roles`);
        // `tips_sentence`, a grammar pattern after it ("[+ to]").
        example: &[(Some("li"), &[])],
        example_keep: &[(Some("span"), &["tips_sentence"])],
        heading: &[(Some("div"), &["cc_addon_text"]), (Some("span"), &["ginfotitle"])],
        trans: &[(Some("span"), &["chinese-text"])],
        ..NONE
    },
    // Merriam-Webster's Advanced Learner's and Unabridged: `fl`, the functional label; `snum` and `sn`, a sense's
    // number and its letter.
    Profile {
        signature: &["scnt", "vi", "fl"],
        pos: &[(None, &["fl"])],
        sensenum: &[(Some("div"), &["snum"]), (Some("em"), &["sn"])],
        example: &[(Some("div"), &["vi_content"])],
        heading: &[(Some("span"), &["vfont"])],
        ..NONE
    },
    // Etymonline.
    Profile {
        signature: &["word__name", "related__word", "word_c"],
        pos: &[(Some("span"), &["word_c"])],
        heading: &[(Some("h3"), &["h3_title"])],
        ..NONE
    },
    // Macmillan English Dictionary.
    Profile {
        signature: &["boxsensefull", "base-form", "part-of-speech"],
        pos: &[(Some("span"), &["part-of-speech"])],
        sensenum: &[(Some("div"), &["sense-num"])],
        example: &[(Some("p"), &["example"])],
        // A block's title ("phrases", "derived word"). Not `span.h2`, a thesaurus link's label before its list of linked
        // words, nor `synonyms`, which holds that list.
        heading: &[(Some("h2"), &["title"])],
        ..NONE
    },
    // NOAD 3: `p` also holds grammar words (`obj.`). Its sense numbers are unclassed `b`.
    Profile {
        signature: &["m1", "m2", "opt", "p"],
        pos: &[(Some("span"), &["p"])],
        pos_words: true,
        example: &[(Some("span"), &["ex"])],
        ..NONE
    },
    // Oxford Collocations.
    Profile {
        signature: &["ocd_hw", "ocd_pos"],
        pos: &[(None, &["ocd_pos"])],
        example: &[(Some("span"), &["ocd_ex"])],
        heading: &[(Some("span"), &["ocd_ps"])],
        ..NONE
    },
    // ODE: `xv4`, an example in a sense; `lmn`, one in its list of further examples.
    Profile {
        signature: &["a8e", "aej", "xno"],
        pos: &[(Some("span"), &["xno"])],
        sensenum: &[(Some("span"), &["vkq"])],
        example: &[(Some("em"), &["xv4"]), (Some("li"), &["lmn"])],
        heading: &[(Some("span"), &["tki"])],
        ..NONE
    },
    // 21st Century English–Chinese (YHDCD).
    Profile {
        signature: &["cxa", "phmk", "cx"],
        pos: &[(Some("span"), &["cx"])],
        sensenum: &[(Some("span"), &["xha"])],
        trans: &[(Some("def"), &[]), (Some("span"), &["eb"])],
        ..NONE
    },
    // Practical English Usage: `hang` holds its section and point numbers, and a dash before a heading.
    // Its examples; inside one, a small-capitals label ("NOT") and an equivalent in brackets ("(= He's ill)").
    Profile {
        signature: &["peu-quote", "peu-btns", "hang"],
        sensenum: &[(Some("span"), &["hang"])],
        example: &[(Some("span"), &["example"])],
        example_keep: &[(Some("span"), &["smallcaps"]), (Some("span"), &["equivalent"])],
        ..NONE
    },
];

/// The table of the markup an edition's sheets name, if any.
pub(crate) fn of(facts: &Facts) -> Option<&'static Profile> {
    PROFILES.iter().find(|p| p.signature.iter().all(|c| facts.styles_class(c)))
}
