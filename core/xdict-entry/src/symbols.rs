//! The icon sweep's symbol rule (`dev-docs/measurements/2026-10-15-icon-sweep/` §7.1, `symbols.py`): what XDict does
//! with one symbol an entry draws, from the character and its context only. No dictionary is named here.
//!
//! The principle: a glyph a stylesheet draws is the dictionary's decoration and becomes XDict's marker (or its
//! control, or nothing); a glyph written as text is the dictionary's words and stays. The owner's answers (ADR-0010,
//! the icon sweep's questions) refine two hard cases of a drawn glyph: a pointing hand is XDict's `lookup` mark, and a
//! pictograph that is not a speaker is dropped ([`owned`]).

/// What XDict does with one symbol.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Treatment {
    Speaker,
    Wordlist,
    Drop,
    Frequency,
    SenseNumber,
    Disclosure,
    Xref,
    Keep,
    Marker,
}

impl Treatment {
    pub(crate) fn name(self) -> &'static str {
        match self {
            Treatment::Speaker => "speaker",
            Treatment::Wordlist => "wordlist",
            Treatment::Drop => "drop",
            Treatment::Frequency => "frequency",
            Treatment::SenseNumber => "sense-number",
            Treatment::Disclosure => "disclosure",
            Treatment::Xref => "xref",
            Treatment::Keep => "keep",
            Treatment::Marker => "marker",
        }
    }
}

const ARROWS: &str = "→⇒⇨➔➞➡➤☞↑⇑➜➝➙⟶⇾⟹⇢➪➫➭➯➲➳➵➸➺➻➼➽⇛⇰";
const TRIANGLES: &str = "▶►▸▹▷▾▼▲△◀◁◂◄⊕⊖";
const BULLETS: &str = "•●■▪◆◇♦❑❏◊○□▫◘◙・∙‣⁃❖◦◎❒❐";
const STARS: &str = "★☆⭐✩✪✫✬✭✮✯✰";
const DOTS: &str = "●○◉◯⚫⚪";
pub(crate) const SPEAKERS: &str = "🔊🔉🔈📢📣♪♫♬🎵";
const NOTES: &str = "※☞☜ⓘℹ✎✍📝⚠❗❕";
const MARKS: &str = "✗✘✕✖❌✓✔†‡↔¦§¶‖";

/// What a symbol's context says, as the sweep's census wrote it (`icons.py`).
#[derive(Debug, Clone, Default)]
pub(crate) struct Ctx<'a> {
    /// Drawn by `::before`/`::after`.
    pub(crate) pseudo: bool,
    /// A glyph of an icon face.
    pub(crate) icon_font: bool,
    /// The element's classes and the drawing rule's selector, as one text.
    pub(crate) classes: &'a str,
    /// The element is clickable.
    pub(crate) click: bool,
    /// The kind of the link it is in (`sound`, `lookup`, `script`, …), or empty.
    pub(crate) link: &'a str,
    /// The kind of the link right after it, or empty.
    pub(crate) before_link: &'a str,
    pub(crate) alone: bool,
    pub(crate) first: bool,
    pub(crate) run: u32,
    pub(crate) title: bool,
    /// It is inside a speaker.
    pub(crate) control: bool,
}

pub(crate) fn private_use(c: char) -> bool {
    matches!(u32::from(c), 0xE000..=0xF8FF | 0xF0000..=0x10FFFD)
}

/// An enclosed alphanumeric (❶, ①, 🄰, ㉑), as the sweep reads one.
fn enclosed(c: char) -> bool {
    matches!(
        u32::from(c),
        0x2460..=0x24FF | 0x2776..=0x2793 | 0x1F100..=0x1F1FF | 0x3251..=0x325F | 0x32B1..=0x32BF | 0x3280..=0x3289
    )
}

/// The plain number or letter an enclosed sense number stands for: `❶` 1, `🄰` A, `⑫` 12, `㊀` 1. `None` for what
/// encloses no number or letter (ⓘ is "information", flags are not numbers).
pub(crate) fn sense_value(c: char) -> Option<String> {
    let o = u32::from(c);
    let n = |base: u32| Some((o - base + 1).to_string());
    let letter = |base: u32, upper: bool| {
        let a = if upper { b'A' } else { b'a' };
        char::from_u32(u32::from(a) + o - base).map(String::from)
    };
    match o {
        0x24D8 => None,
        0x2460..=0x2473 => n(0x2460),
        0x2474..=0x2487 => n(0x2474),
        0x2488..=0x249B => n(0x2488),
        0x249C..=0x24B5 => letter(0x249C, false),
        0x24B6..=0x24CF => letter(0x24B6, true),
        0x24D0..=0x24E9 => letter(0x24D0, false),
        0x24EA | 0x24FF => Some("0".into()),
        0x24EB..=0x24F4 => Some((o - 0x24EB + 11).to_string()),
        0x24F5..=0x24FE => n(0x24F5),
        0x2776..=0x277F => n(0x2776),
        0x2780..=0x2789 => n(0x2780),
        0x278A..=0x2793 => n(0x278A),
        0x3251..=0x325F => Some((o - 0x3251 + 21).to_string()),
        0x32B1..=0x32BF => Some((o - 0x32B1 + 36).to_string()),
        0x3280..=0x3289 => n(0x3280),
        0x1F110..=0x1F129 | 0x1F130..=0x1F149 | 0x1F150..=0x1F169 | 0x1F170..=0x1F189 => {
            letter(o - (o - 0x1F110) % 0x20, true).filter(|_| (o - 0x1F110) % 0x20 < 26)
        }
        _ => None,
    }
}

/// Whether a character is a symbol the rule treats: what `content` draws or text holds that is not a letter, a
/// digit, space or ordinary punctuation.
pub(crate) fn symbol(c: char) -> bool {
    private_use(c)
        || enclosed(c)
        || [ARROWS, TRIANGLES, BULLETS, STARS, DOTS, SPEAKERS, NOTES, MARKS].iter().any(|s| s.contains(c))
        || matches!(u32::from(c), 0x2190..=0x2BFF | 0x1F000..=0x1FAFF)
}

/// Whether `text` holds `word` with no word character (`[A-Za-z0-9_]`) either side.
fn bounded(text: &str, word: &str) -> bool {
    let w = |c: Option<char>| c.is_some_and(|c| c.is_ascii_alphanumeric() || c == '_');
    text.match_indices(word).any(|(at, m)| {
        !w(text.get(..at).and_then(|b| b.chars().next_back()))
            && !w(text.get(at + m.len()..).and_then(|a| a.chars().next()))
    })
}

fn any(text: &str, words: &[&str]) -> bool {
    words.iter().any(|w| text.contains(w))
}

fn freq_class(c: &str) -> bool {
    any(c, &["level", "freq", "star", "rank", "grade", "core", "common"])
}

fn speak_class(c: &str) -> bool {
    any(c, &["speak", "sound", "audio", "volume", "pron", "tts", "play", "voice"])
}

fn wordlist_class(c: &str) -> bool {
    bounded(c, "key")
        || c.contains("ox3k")
        || c.contains("ox5k")
        || c.contains("oxford")
        || c.contains("awl")
        || bounded(c, "3000")
        || bounded(c, "5000")
        || c.contains("wordlist")
}

fn xref_class(c: &str) -> bool {
    let starts = |w: &str| {
        c.match_indices(w).any(|(at, _)| {
            !c.get(..at).and_then(|b| b.chars().next_back()).is_some_and(|p| p.is_ascii_alphanumeric() || p == '_')
        })
    };
    starts("xr")
        || starts("x-r")
        || c.contains("xref")
        || starts("ref")
        || c.contains("see")
        || c.contains("cross")
        || bounded(c, "wr")
        || c.contains("x-wr")
        || c.contains("arrow")
}

/// What XDict should do with one symbol, from the character and its context alone (`symbols.py`'s `treatment`).
pub(crate) fn treatment(ch: char, f: &Ctx<'_>) -> Treatment {
    let cls = f.classes.to_ascii_lowercase();
    let pua = private_use(ch);
    let in_link = matches!(f.link, "lookup" | "script");
    if f.control || SPEAKERS.contains(ch) || (pua && (f.link == "sound" || speak_class(&cls))) {
        return Treatment::Speaker;
    }
    if ch == '🔑' || (pua && wordlist_class(&cls)) {
        return Treatment::Wordlist;
    }
    if pua {
        return if f.icon_font { Treatment::Drop } else { Treatment::Keep };
    }
    if (STARS.contains(ch) || DOTS.contains(ch))
        && (freq_class(&cls) || f.title || (f.alone && (STARS.contains(ch) || f.run >= 2)))
    {
        return Treatment::Frequency;
    }
    if enclosed(ch) {
        return Treatment::SenseNumber;
    }
    if (TRIANGLES.contains(ch) || "＋－+-".contains(ch)) && f.click {
        return Treatment::Disclosure;
    }
    if in_link && !f.pseudo {
        return Treatment::Xref;
    }
    if ARROWS.contains(ch) || (TRIANGLES.contains(ch) && in_link) {
        if ch == '☞' && f.before_link.is_empty() && !in_link {
            return Treatment::Keep;
        }
        if in_link || !f.before_link.is_empty() || xref_class(&cls) || f.first || f.pseudo {
            return Treatment::Xref;
        }
        return Treatment::Keep;
    }
    if NOTES.contains(ch) || MARKS.contains(ch) {
        return Treatment::Keep;
    }
    if BULLETS.contains(ch) || TRIANGLES.contains(ch) {
        return if f.pseudo { Treatment::Marker } else { Treatment::Keep };
    }
    Treatment::Keep
}

/// The owner's answers on a glyph a sheet draws (ADR-0010, the icon sweep's question 2): a pointing hand is XDict's
/// `lookup` mark (OCD's), except on a list item, where it is the list's bullet (COBUILD's note list keeps it); a
/// pictograph that is not a speaker (Chambers' 👇) is dropped.
pub(crate) fn owned(ch: char, t: Treatment, list_item: bool) -> Treatment {
    if matches!(ch, '☞' | '☜') && !list_item {
        return Treatment::Xref;
    }
    if t == Treatment::Keep && matches!(u32::from(ch), 0x1F300..=0x1FAFF) {
        return Treatment::Drop;
    }
    t
}

/// The rule on one occurrence of the sweep's census (`icons.py`): `kind` is `char`, `pseudo-symbol` or
/// `icon-font-glyph`, `ctx` the census's context text. For the measurement against the sweep's labels only; with
/// `owner`, the owner's answers ([`owned`]) apply to a drawn glyph.
#[doc(hidden)]
pub fn census_treatment(kind: &str, code_point: u32, ctx: &str, owner: bool) -> &'static str {
    let Some(ch) = char::from_u32(code_point) else { return "keep" };
    let pseudo = kind != "char" && (ctx.starts_with("before") || ctx.starts_with("after"));
    let word = |c: &char| c.is_alphanumeric() || *c == '_';
    let after = |prefix: &str, keep: &dyn Fn(&char) -> bool| -> String {
        ctx.find(prefix)
            .map(|at| ctx.get(at + prefix.len()..).unwrap_or("").chars().take_while(keep).collect())
            .unwrap_or_default()
    };
    let (el, sel, link, before_link, alone, first, run, title);
    if pseudo {
        el = after("@", &|c: &char| !c.is_whitespace());
        sel = ctx.split(" @").next().unwrap_or("").to_owned();
        link = after("link-", &word);
        before_link = String::new();
        (alone, first, run, title) = (true, false, 1, false);
    } else {
        el = ctx.split(' ').next().unwrap_or("").to_owned();
        sel = String::new();
        link = ctx
            .match_indices(" in ")
            .find_map(|(at, _)| {
                let rest = ctx.get(at + 4..)?;
                let w: String = rest.chars().take_while(word).collect();
                (!w.is_empty() && rest.get(w.len()..)?.starts_with(" link")).then_some(w)
            })
            .unwrap_or_default();
        before_link = ctx
            .find("before-")
            .and_then(|at| {
                let rest = ctx.get(at + 7..)?;
                let w: String = rest.chars().take_while(word).collect();
                rest.get(w.len()..)?.starts_with("-link").then_some(w)
            })
            .unwrap_or_default();
        alone = ctx.contains(" alone");
        first = ctx.contains(" first");
        run = ctx
            .find(" run")
            .and_then(|at| {
                let d: String = ctx.get(at + 4..)?.chars().take_while(char::is_ascii_digit).collect();
                d.parse().ok()
            })
            .unwrap_or(1);
        title = ctx.contains(" title");
    }
    let classes = format!("{el} {sel}");
    let f = Ctx {
        pseudo,
        icon_font: kind == "icon-font-glyph",
        classes: &classes,
        click: ctx.contains(" click"),
        link: &link,
        before_link: &before_link,
        alone,
        first,
        run,
        title,
        control: ctx.contains("[speaker"),
    };
    let t = treatment(ch, &f);
    let list_item = el == "li" || el.starts_with("li.");
    if owner && pseudo { owned(ch, t, list_item).name() } else { t.name() }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sense_numbers_read_as_numbers_and_letters() {
        let read: Vec<Option<String>> = "❶①⑫🄰🄱ⓐ㉑㊀➊".chars().map(sense_value).collect();
        let want = ["1", "1", "12", "A", "B", "a", "21", "1", "1"];
        assert_eq!(read, want.iter().map(|s| Some((*s).to_owned())).collect::<Vec<_>>());
        assert_eq!(sense_value('ⓘ'), None);
        assert_eq!(sense_value('🇬'), None, "a flag's letter is not a sense");
    }

    #[test]
    fn the_rule_reads_role_from_context() {
        let drawn = Ctx { pseudo: true, classes: "span.x-g .x-g::before", ..Ctx::default() };
        assert_eq!(treatment('•', &drawn), Treatment::Marker);
        assert_eq!(treatment('•', &Ctx::default()), Treatment::Keep);
        assert_eq!(treatment('⇒', &drawn), Treatment::Xref);
        assert_eq!(treatment('☞', &drawn), Treatment::Keep);
        assert_eq!(owned('☞', treatment('☞', &drawn), false), Treatment::Xref);
        assert_eq!(owned('👇', treatment('👇', &drawn), false), Treatment::Drop);
        let clicked = Ctx { click: true, ..Ctx::default() };
        assert_eq!(treatment('►', &clicked), Treatment::Disclosure);
        assert_eq!(treatment('\u{f028}', &Ctx { link: "sound", ..Ctx::default() }), Treatment::Speaker);
        assert_eq!(
            treatment('☆', &Ctx { pseudo: true, classes: "span.level", ..Ctx::default() }),
            Treatment::Frequency
        );
        assert_eq!(census_treatment("char", 0x2776, "span alone", false), "sense-number");
        assert_eq!(census_treatment("char", 0x2192, "span inline", false), "keep");
        assert_eq!(census_treatment("char", 0x2192, "span alone before-lookup-link", false), "xref");
    }
}
