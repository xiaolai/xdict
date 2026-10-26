//! English word forms for the matcher (plan WI-2): the base forms a surface may come from, and the inflections a base
//! may wear. Rules plus a curated irregular table; **over-generation is a false candidate the ranking weighs, and
//! under-generation loses a match.** The rules are measured against `tests/forms_labelled.rs`, written before them,
//! and `wording/README.md` records the v1 limits (prefix derivations and `-able` are not recovered).
//!
//! The written form is always the first candidate, so a key spelled exactly as the sentence spells it wins the
//! ranking's `borrowed` tie-break.

use std::collections::HashSet;

/// Surface → base, for the irregular verbs and nouns a phrase's key may spell in either form.
const IRREGULAR: &[(&str, &str)] = &[
    ("am", "be"),
    ("is", "be"),
    ("are", "be"),
    ("was", "be"),
    ("were", "be"),
    ("been", "be"),
    ("being", "be"),
    ("has", "have"),
    ("had", "have"),
    ("having", "have"),
    ("does", "do"),
    ("did", "do"),
    ("done", "do"),
    ("doing", "do"),
    ("goes", "go"),
    ("went", "go"),
    ("gone", "go"),
    ("going", "go"),
    ("says", "say"),
    ("said", "say"),
    ("gets", "get"),
    ("got", "get"),
    ("gotten", "get"),
    ("getting", "get"),
    ("made", "make"),
    ("making", "make"),
    ("knew", "know"),
    ("known", "know"),
    ("thought", "think"),
    ("took", "take"),
    ("taken", "take"),
    ("taking", "take"),
    ("saw", "see"),
    ("seen", "see"),
    ("seeing", "see"),
    ("came", "come"),
    ("coming", "come"),
    ("gave", "give"),
    ("given", "give"),
    ("giving", "give"),
    ("found", "find"),
    ("told", "tell"),
    ("became", "become"),
    ("becoming", "become"),
    ("showed", "show"),
    ("shown", "show"),
    ("left", "leave"),
    ("leaving", "leave"),
    ("felt", "feel"),
    ("put", "put"),
    ("putting", "put"),
    ("brought", "bring"),
    ("began", "begin"),
    ("begun", "begin"),
    ("beginning", "begin"),
    ("kept", "keep"),
    ("held", "hold"),
    ("wrote", "write"),
    ("written", "write"),
    ("writing", "write"),
    ("stood", "stand"),
    ("heard", "hear"),
    ("let", "let"),
    ("letting", "let"),
    ("meant", "mean"),
    ("set", "set"),
    ("setting", "set"),
    ("met", "meet"),
    ("ran", "run"),
    ("running", "run"),
    ("paid", "pay"),
    ("sat", "sit"),
    ("sitting", "sit"),
    ("spoke", "speak"),
    ("spoken", "speak"),
    ("speaking", "speak"),
    ("lay", "lie"),
    ("lain", "lie"),
    ("lying", "lie"),
    ("lied", "lie"),
    // **`singe` keeps its e before `-ing`** — `singeing`, never `singing`, which is `sing`'s (audit round 4, 2026-10-26).
    ("singeing", "singe"),
    ("led", "lead"),
    ("grew", "grow"),
    ("grown", "grow"),
    ("lost", "lose"),
    ("losing", "lose"),
    ("fell", "fall"),
    ("fallen", "fall"),
    ("sent", "send"),
    ("built", "build"),
    ("understood", "understand"),
    ("drew", "draw"),
    ("drawn", "draw"),
    ("broke", "break"),
    ("broken", "break"),
    ("spent", "spend"),
    ("cut", "cut"),
    ("cutting", "cut"),
    ("rose", "rise"),
    ("risen", "rise"),
    ("rising", "rise"),
    ("drove", "drive"),
    ("driven", "drive"),
    ("driving", "drive"),
    ("bought", "buy"),
    ("wore", "wear"),
    ("worn", "wear"),
    ("chose", "choose"),
    ("chosen", "choose"),
    ("choosing", "choose"),
    ("ate", "eat"),
    ("eaten", "eat"),
    ("drank", "drink"),
    ("drunk", "drink"),
    ("sang", "sing"),
    ("sung", "sing"),
    ("swam", "swim"),
    ("swum", "swim"),
    ("swimming", "swim"),
    ("flew", "fly"),
    ("flown", "fly"),
    ("forgot", "forget"),
    ("forgotten", "forget"),
    ("forgetting", "forget"),
    ("forgave", "forgive"),
    ("forgiven", "forgive"),
    ("forgiving", "forgive"),
    ("froze", "freeze"),
    ("frozen", "freeze"),
    ("freezing", "freeze"),
    ("taught", "teach"),
    ("caught", "catch"),
    ("fought", "fight"),
    ("sought", "seek"),
    ("sold", "sell"),
    ("shot", "shoot"),
    ("slept", "sleep"),
    ("woke", "wake"),
    ("woken", "wake"),
    ("waking", "wake"),
    ("won", "win"),
    ("winning", "win"),
    ("threw", "throw"),
    ("thrown", "throw"),
    ("bore", "bear"),
    ("borne", "bear"),
    ("born", "bear"),
    ("beaten", "beat"),
    ("beating", "beat"),
    ("bent", "bend"),
    ("bet", "bet"),
    ("betting", "bet"),
    ("bound", "bind"),
    ("bit", "bite"),
    ("bitten", "bite"),
    ("biting", "bite"),
    ("blew", "blow"),
    ("blown", "blow"),
    ("burnt", "burn"),
    ("dealt", "deal"),
    ("dug", "dig"),
    ("digging", "dig"),
    ("dreamt", "dream"),
    ("fed", "feed"),
    ("hid", "hide"),
    ("hidden", "hide"),
    ("hiding", "hide"),
    ("hit", "hit"),
    ("hitting", "hit"),
    ("hurt", "hurt"),
    ("hurting", "hurt"),
    ("laid", "lay"),
    ("lent", "lend"),
    ("lit", "light"),
    ("rode", "ride"),
    ("ridden", "ride"),
    ("riding", "ride"),
    ("rang", "ring"),
    ("rung", "ring"),
    ("shook", "shake"),
    ("shaken", "shake"),
    ("shaking", "shake"),
    ("shone", "shine"),
    ("shut", "shut"),
    ("shutting", "shut"),
    ("sank", "sink"),
    ("sunk", "sink"),
    ("slid", "slide"),
    ("split", "split"),
    ("splitting", "split"),
    ("spread", "spread"),
    ("spreading", "spread"),
    ("stole", "steal"),
    ("stolen", "steal"),
    ("stuck", "stick"),
    ("struck", "strike"),
    ("swore", "swear"),
    ("sworn", "swear"),
    ("swept", "sweep"),
    ("tore", "tear"),
    ("torn", "tear"),
    ("men", "man"),
    ("women", "woman"),
    ("children", "child"),
    ("feet", "foot"),
    ("teeth", "tooth"),
    ("geese", "goose"),
    ("mice", "mouse"),
    ("lice", "louse"),
    ("people", "person"),
    ("oxen", "ox"),
    ("lives", "life"),
    ("wives", "wife"),
    ("knives", "knife"),
    ("leaves", "leaf"),
    ("halves", "half"),
    ("shelves", "shelf"),
    ("wolves", "wolf"),
    ("calves", "calf"),
    ("loaves", "loaf"),
    ("thieves", "thief"),
    ("selves", "self"),
    ("analyses", "analysis"),
    ("crises", "crisis"),
    ("theses", "thesis"),
    ("data", "datum"),
    ("criteria", "criterion"),
    ("phenomena", "phenomenon"),
    ("indices", "index"),
    ("axes", "axis"),
];

/// **The reverse table, derived from [`IRREGULAR`]** (audit rounds 1–4, 2026-10-26): one row per base, its surfaces in
/// the order the forward table names them. One source of truth, so a pair added above is a form generated below, and
/// there is no second table to forget.
fn irregular_forms() -> &'static [(&'static str, Vec<&'static str>)] {
    static FORMS: std::sync::OnceLock<Vec<(&'static str, Vec<&'static str>)>> = std::sync::OnceLock::new();
    FORMS.get_or_init(|| {
        let mut rows: Vec<(&'static str, Vec<&'static str>)> = Vec::new();
        for &(surface, base) in IRREGULAR {
            if surface == base {
                continue;
            }
            match rows.iter_mut().find(|(known, _)| *known == base) {
                Some((_, listed)) => listed.push(surface),
                None => rows.push((base, vec![surface])),
            }
        }
        rows
    })
}

/// The written form, lowercased, first; then the base forms it may come from and their inflections.
pub fn forms(word: &str) -> Vec<String> {
    let written = word.to_lowercase();
    let mut out: Vec<String> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    push(&mut out, &mut seen, written.clone());

    // **The written word is a base too**: a key that spells an inflection (`given up`) must be found by the reader's
    // `give up`, whose forms include `given` only if `give` itself inflects.
    let mut bases: Vec<String> = Vec::new();
    add_base(&mut bases, &written);
    for (surface, base) in IRREGULAR {
        if *surface == written {
            add_base(&mut bases, base);
        }
    }
    for candidate in strip_candidates(&written) {
        add_base(&mut bases, &candidate);
    }
    for base in &bases {
        push(&mut out, &mut seen, base.clone());
        for inflection in inflections(base) {
            push(&mut out, &mut seen, inflection);
        }
        for (known, irregular) in irregular_forms() {
            if *known == base {
                for form in irregular {
                    push(&mut out, &mut seen, (*form).to_string());
                }
            }
        }
    }
    out
}

fn push(out: &mut Vec<String>, seen: &mut HashSet<String>, form: String) {
    if seen.insert(form.clone()) {
        out.push(form);
    }
}

fn add_base(bases: &mut Vec<String>, base: &str) {
    if !base.is_empty() && !bases.iter().any(|known| known == base) {
        bases.push(base.to_string());
    }
}

/// The bases a surface may have been inflected from, by suffix rules. Over-generation here is measured, not feared.
fn strip_candidates(surface: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let push = |out: &mut Vec<String>, candidate: String| {
        if candidate.chars().count() >= 2 && !out.contains(&candidate) {
            out.push(candidate);
        }
    };
    if let Some(stem) = surface.strip_suffix("ies") {
        push(&mut out, format!("{stem}y"));
        push(&mut out, format!("{stem}ie"));
    }
    if let Some(stem) = surface.strip_suffix("ied") {
        push(&mut out, format!("{stem}y"));
    }
    // **-ying is -ie's gerund** (`dying` → `die`, `tying` → `tie`), which stripping -ing alone cannot recover.
    if let Some(stem) = surface.strip_suffix("ying") {
        push(&mut out, format!("{stem}ie"));
    }
    if let Some(stem) = surface.strip_suffix("ing") {
        for form in stem_forms(stem) {
            push(&mut out, form);
        }
    }
    if let Some(stem) = surface.strip_suffix("ed") {
        for form in stem_forms(stem) {
            push(&mut out, form);
        }
    }
    // **-ier/-iest reverse -y** (`happier` → `happy`), which stripping -er/-est alone cannot recover.
    if let Some(stem) = surface.strip_suffix("iest") {
        push(&mut out, format!("{stem}y"));
    }
    if let Some(stem) = surface.strip_suffix("ier") {
        push(&mut out, format!("{stem}y"));
    }
    if let Some(stem) = surface.strip_suffix("est") {
        for form in stem_forms(stem) {
            push(&mut out, form);
        }
    } else if let Some(stem) = surface.strip_suffix("er") {
        for form in stem_forms(stem) {
            push(&mut out, form);
        }
    }
    if let Some(stem) = surface.strip_suffix("es") {
        push(&mut out, stem.to_string());
        // **`-zzes` is a doubled `z`**: `quizzes` → `quizz` → `quiz` (audit round 4, 2026-10-26).
        if let Some(base) = undouble(stem).filter(|base| base.ends_with('z')) {
            push(&mut out, base);
        }
    }
    if !surface.ends_with("ss")
        && let Some(stem) = surface.strip_suffix("s")
    {
        push(&mut out, stem.to_string());
    }
    out
}

/// The bases a stripped stem may stand for: itself, plus a restored `e` (`making` → `make`) and an undone doubling
/// (`stopped` → `stop`). One helper for every suffix that inflects this way.
fn stem_forms(stem: &str) -> Vec<String> {
    let mut forms = vec![stem.to_string(), format!("{stem}e")];
    if let Some(double) = undouble(stem) {
        forms.push(double);
    }
    // **`-ck` is how `-c` inflects**: `panicked` → stem `panick` → `panic` (audit round 3, 2026-10-26).
    if let Some(base) = stem.strip_suffix('k').filter(|base| base.ends_with('c')) {
        forms.push(base.to_string());
    }
    forms
}

/// `stopped` → stem `stopp` → `stop`; only for a doubled ASCII consonant.
fn undouble(stem: &str) -> Option<String> {
    let mut chars = stem.chars().rev();
    let last = chars.next()?;
    let before = chars.next()?;
    if last.eq_ignore_ascii_case(&before) && last.is_ascii_alphabetic() && !matches!(last, 'e' | 'o') {
        let mut out = stem.to_string();
        out.pop();
        return Some(out);
    }
    None
}

/// The regular inflections of a base: plural/third person, past, gerund, comparative and superlative.
fn inflections(base: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let push = |out: &mut Vec<String>, candidate: String| {
        if candidate != base && !out.contains(&candidate) {
            out.push(candidate);
        }
    };
    let ends = |suffix: &str| base.ends_with(suffix);

    // Plural and third person singular.
    if ends("s") || ends("x") || ends("z") || ends("ch") || ends("sh") {
        // **A single `-z` also doubles before `-es`** (audit round 4, 2026-10-26): `quiz` → `quizzes` beside `quizes`,
        // which over-generation tolerates, while `waltz` keeps its ordinary `waltzes` — only some words double, and no
        // rule here can tell which. A doubled `-zz` only adds `-es` (`buzzes`).
        push(&mut out, format!("{base}es"));
        if ends("z") && !ends("zz") {
            push(&mut out, format!("{base}zes"));
        }
    } else if let Some(stem) = base.strip_suffix("y") {
        let vowel_before = stem.chars().last().is_some_and(|c| "aeiou".contains(c));
        if vowel_before {
            push(&mut out, format!("{base}s"));
        } else {
            push(&mut out, format!("{stem}ies"));
        }
    } else {
        push(&mut out, format!("{base}s"));
    }

    // Past.
    if ends("e") {
        push(&mut out, format!("{base}d"));
    } else if let Some(stem) = base.strip_suffix("y") {
        let vowel_before = stem.chars().last().is_some_and(|c| "aeiou".contains(c));
        if vowel_before {
            push(&mut out, format!("{base}ed"));
        } else {
            push(&mut out, format!("{stem}ied"));
        }
    } else {
        push(&mut out, format!("{base}ed"));
        // **A base ending in `-c` also spells its past with `-cked`**: `panic` → `panicked`, `arc` → `arcked` beside
        // `arced` (audit round 3's verification, 2026-10-26). Never doubled by the CVC rule, which would write
        // `panicced`.
        if ends("c") {
            push(&mut out, format!("{base}ked"));
        } else if is_cvc(base)
            && let Some(last) = base.chars().last()
        {
            push(&mut out, format!("{base}{last}ed"));
        }
    }

    // Gerund.
    if ends("ie") {
        push(&mut out, format!("{}ying", base.trim_end_matches("ie")));
    } else if ends("e") {
        // **A base ending in `-ee`, `-ye` or `-oe` keeps its e**: seeing, dyeing, shoeing (audit round 3, 2026-10-26).
        if ends("ee") || ends("ye") || ends("oe") {
            push(&mut out, format!("{base}ing"));
            // **`eye` keeps both spellings** (audit round 3's verification): after a vowel the dropped e is a form of
            // its own — `eying` beside `eyeing` — while `dye` has none: `dying` is `die`'s.
            if let Some(stem) = base.strip_suffix("ye")
                && stem.chars().last().is_some_and(|c| "aeiou".contains(c))
            {
                push(&mut out, format!("{}ing", base.trim_end_matches('e')));
            }
        } else {
            push(&mut out, format!("{}ing", base.trim_end_matches('e')));
        }
    } else {
        push(&mut out, format!("{base}ing"));
        // **`-c` also takes a `k` before `-ing`**: `panic` → `panicking`, `arc` → `arcking` beside `arcing`.
        if ends("c") {
            push(&mut out, format!("{base}king"));
        } else if is_cvc(base)
            && let Some(last) = base.chars().last()
        {
            push(&mut out, format!("{base}{last}ing"));
        }
    }

    // Comparative and superlative.
    if ends("e") {
        push(&mut out, format!("{base}r"));
        push(&mut out, format!("{base}st"));
    } else if let Some(stem) = base.strip_suffix("y") {
        let vowel_before = stem.chars().last().is_some_and(|c| "aeiou".contains(c));
        if vowel_before {
            // **A vowel before the `y` keeps it**: `gray` → `grayer`/`grayest` (audit round 3, 2026-10-26).
            push(&mut out, format!("{base}er"));
            push(&mut out, format!("{base}est"));
        } else {
            push(&mut out, format!("{stem}ier"));
            push(&mut out, format!("{stem}iest"));
        }
    } else {
        push(&mut out, format!("{base}er"));
        push(&mut out, format!("{base}est"));
        // **A CVC base doubles**: `big` → `bigger`/`biggest`, `hot` → `hotter`/`hottest`.
        if is_cvc(base)
            && let Some(last) = base.chars().last()
        {
            push(&mut out, format!("{base}{last}er"));
            push(&mut out, format!("{base}{last}est"));
        }
    }
    out
}

/// Consonant–vowel–consonant in ASCII, the shape English doubles before `-ed`/`-ing`.
fn is_cvc(word: &str) -> bool {
    let chars: Vec<char> = word.chars().collect();
    let (Some(last), Some(mid), Some(first)) = (
        chars.len().checked_sub(1).and_then(|i| chars.get(i)),
        chars.len().checked_sub(2).and_then(|i| chars.get(i)),
        chars.len().checked_sub(3).and_then(|i| chars.get(i)),
    ) else {
        return false;
    };
    let vowel = |c: &char| "aeiou".contains(*c);
    let consonant = |c: &char| c.is_ascii_alphabetic() && !vowel(c);
    consonant(first) && vowel(mid) && consonant(last) && !matches!(last, 'w' | 'x' | 'y')
}

#[cfg(test)]
mod tests {
    use super::{IRREGULAR, irregular_forms};

    /// **The reverse table never lags its forward one** (audit round 1, 2026-10-26): every irregular surface maps back
    /// to a base, so every base must list that surface among its forms — `axes` was missing.
    #[test]
    fn every_irregular_reverse_is_listed() {
        for (surface, base) in IRREGULAR {
            if surface == base {
                continue;
            }
            // **A base with no row is a failure, not a skip** (audit round 2): the reverse table is derived from
            // `IRREGULAR`, and a quietly absent base is how `axes` went missing.
            let listed = irregular_forms().iter().find(|(known, _)| *known == *base).map(|(_, listed)| listed);
            assert!(listed.is_some(), "{base} has no row");
            assert!(listed.is_none_or(|listed| listed.contains(surface)), "{base} lists no {surface}");
            // **The behavior is the contract**: every irregular surface reaches its base through `forms`, whether or
            // not a reverse row lists it.
            assert!(super::forms(surface).iter().any(|form| form == base), "{surface} does not reach {base}");
        }
    }
}
