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

/// Base → inflections a rule cannot produce, for the same verbs and nouns.
const IRREGULAR_FORMS: &[(&str, &[&str])] = &[
    ("be", &["am", "is", "are", "was", "were", "been", "being"]),
    ("have", &["has", "had", "having"]),
    ("do", &["does", "did", "done", "doing"]),
    ("go", &["goes", "went", "gone", "going"]),
    ("say", &["says", "said"]),
    ("get", &["gets", "got", "gotten", "getting"]),
    ("make", &["made", "making"]),
    ("know", &["knew", "known"]),
    ("think", &["thought"]),
    ("take", &["took", "taken", "taking"]),
    ("see", &["saw", "seen", "seeing"]),
    ("come", &["came", "coming"]),
    ("give", &["gave", "given", "giving"]),
    ("find", &["found"]),
    ("tell", &["told"]),
    ("become", &["became", "becoming"]),
    ("show", &["showed", "shown"]),
    ("leave", &["left", "leaving"]),
    ("feel", &["felt"]),
    ("put", &["putting"]),
    ("bring", &["brought"]),
    ("begin", &["began", "begun", "beginning"]),
    ("keep", &["kept"]),
    ("hold", &["held"]),
    ("write", &["wrote", "written", "writing"]),
    ("stand", &["stood"]),
    ("hear", &["heard"]),
    ("mean", &["meant"]),
    ("meet", &["met"]),
    ("run", &["ran", "running"]),
    ("pay", &["paid"]),
    ("sit", &["sat", "sitting"]),
    ("speak", &["spoke", "spoken", "speaking"]),
    ("lie", &["lay", "lain", "lying", "lied"]),
    ("lead", &["led"]),
    ("grow", &["grew", "grown"]),
    ("lose", &["lost", "losing"]),
    ("fall", &["fell", "fallen"]),
    ("send", &["sent"]),
    ("build", &["built"]),
    ("understand", &["understood"]),
    ("draw", &["drew", "drawn"]),
    ("break", &["broke", "broken"]),
    ("spend", &["spent"]),
    ("cut", &["cutting"]),
    ("rise", &["rose", "risen", "rising"]),
    ("drive", &["drove", "driven", "driving"]),
    ("buy", &["bought"]),
    ("wear", &["wore", "worn"]),
    ("choose", &["chose", "chosen", "choosing"]),
    ("eat", &["ate", "eaten"]),
    ("drink", &["drank", "drunk"]),
    ("sing", &["sang", "sung"]),
    ("swim", &["swam", "swum", "swimming"]),
    ("fly", &["flew", "flown"]),
    ("forget", &["forgot", "forgotten", "forgetting"]),
    ("forgive", &["forgave", "forgiven", "forgiving"]),
    ("freeze", &["froze", "frozen", "freezing"]),
    ("teach", &["taught"]),
    ("catch", &["caught"]),
    ("fight", &["fought"]),
    ("seek", &["sought"]),
    ("sell", &["sold"]),
    ("shoot", &["shot"]),
    ("sleep", &["slept"]),
    ("wake", &["woke", "woken", "waking"]),
    ("win", &["won", "winning"]),
    ("throw", &["threw", "thrown"]),
    ("bear", &["bore", "borne", "born"]),
    ("beat", &["beaten", "beating"]),
    ("bend", &["bent"]),
    ("bind", &["bound"]),
    ("bite", &["bit", "bitten", "biting"]),
    ("blow", &["blew", "blown"]),
    ("burn", &["burnt"]),
    ("deal", &["dealt"]),
    ("dig", &["dug", "digging"]),
    ("dream", &["dreamt"]),
    ("feed", &["fed"]),
    ("hide", &["hid", "hidden", "hiding"]),
    ("lay", &["laid"]),
    ("lend", &["lent"]),
    ("light", &["lit"]),
    ("ride", &["rode", "ridden", "riding"]),
    ("ring", &["rang", "rung"]),
    ("shake", &["shook", "shaken", "shaking"]),
    ("shine", &["shone"]),
    ("sink", &["sank", "sunk"]),
    ("slide", &["slid"]),
    ("steal", &["stole", "stolen"]),
    ("stick", &["stuck"]),
    ("strike", &["struck"]),
    ("swear", &["swore", "sworn"]),
    ("sweep", &["swept"]),
    ("tear", &["tore", "torn"]),
    ("man", &["men"]),
    ("woman", &["women"]),
    ("child", &["children"]),
    ("foot", &["feet"]),
    ("tooth", &["teeth"]),
    ("goose", &["geese"]),
    ("mouse", &["mice"]),
    ("louse", &["lice"]),
    ("person", &["people"]),
    ("ox", &["oxen"]),
    ("life", &["lives"]),
    ("wife", &["wives"]),
    ("knife", &["knives"]),
    ("leaf", &["leaves"]),
    ("half", &["halves"]),
    ("shelf", &["shelves"]),
    ("wolf", &["wolves"]),
    ("calf", &["calves"]),
    ("loaf", &["loaves"]),
    ("thief", &["thieves"]),
    ("self", &["selves"]),
    ("analysis", &["analyses"]),
    ("crisis", &["crises"]),
    ("thesis", &["theses"]),
    ("datum", &["data"]),
    ("criterion", &["criteria"]),
    ("phenomenon", &["phenomena"]),
    ("index", &["indices"]),
];

/// The written form, lowercased, first; then the base forms it may come from and their inflections.
pub fn forms(word: &str) -> Vec<String> {
    let written = word.to_lowercase();
    let mut out: Vec<String> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    push(&mut out, &mut seen, written.clone());

    let mut bases: Vec<String> = Vec::new();
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
        for (known, irregular) in IRREGULAR_FORMS {
            if known == base {
                for form in *irregular {
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
    if let Some(stem) = surface.strip_suffix("ing") {
        push(&mut out, stem.to_string());
        push(&mut out, format!("{stem}e"));
        if let Some(double) = undouble(stem) {
            push(&mut out, double);
        }
    }
    if let Some(stem) = surface.strip_suffix("ed") {
        push(&mut out, stem.to_string());
        push(&mut out, format!("{stem}e"));
        if let Some(double) = undouble(stem) {
            push(&mut out, double);
        }
    }
    if let Some(stem) = surface.strip_suffix("est") {
        push(&mut out, stem.to_string());
        push(&mut out, format!("{stem}e"));
        if let Some(double) = undouble(stem) {
            push(&mut out, double);
        }
    } else if let Some(stem) = surface.strip_suffix("er") {
        push(&mut out, stem.to_string());
        push(&mut out, format!("{stem}e"));
        if let Some(double) = undouble(stem) {
            push(&mut out, double);
        }
    }
    if let Some(stem) = surface.strip_suffix("es") {
        push(&mut out, stem.to_string());
    }
    if !surface.ends_with("ss")
        && let Some(stem) = surface.strip_suffix("s")
    {
        push(&mut out, stem.to_string());
    }
    out
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
        push(&mut out, format!("{base}es"));
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
        if is_cvc(base)
            && let Some(last) = base.chars().last()
        {
            push(&mut out, format!("{base}{last}ed"));
        }
    }

    // Gerund.
    if ends("ie") {
        push(&mut out, format!("{}ying", base.trim_end_matches("ie")));
    } else if ends("e") && !ends("ee") {
        push(&mut out, format!("{}ing", base.trim_end_matches('e')));
    } else {
        push(&mut out, format!("{base}ing"));
        if is_cvc(base)
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
        if !vowel_before {
            push(&mut out, format!("{stem}ier"));
            push(&mut out, format!("{stem}iest"));
        }
    } else {
        push(&mut out, format!("{base}er"));
        push(&mut out, format!("{base}est"));
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
