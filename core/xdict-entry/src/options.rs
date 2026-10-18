//! Display options a dictionary's markup declares and the reader chooses (ADR-0013 decisions 2, 3, 6 and 7).
//!
//! A bounded catalogue, beside the role tables and not inside them: each option names its fixed values, the markup
//! contract that makes it applicable (shared by every dictionary written that way, never one dictionary's file), its
//! contract default, and the CSS it emits. A dictionary-specific default is a separate table keyed by markup, as the
//! role tables are (never by an edition's hash or a file's name).
//!
//! **Display only.** The CSS is keyed on one root attribute per option (`data-xdict-opt-<id>`) that the shell sets on
//! the entry document's root; the entry's text is never rewritten. An absent attribute, or one holding a value the
//! catalogue does not list, means the declared default, so a shell that sets nothing still shows it.
//!
//! **Bounded.** No option id, selector, attribute or value is taken from a dictionary: the markup is only compared
//! with the catalogue's constants, and the CSS is written from those constants alone, each checked to be a plain
//! token before it is written ([`display_css`] refuses anything else).
//!
//! **The excluded variant** (d.3) is `display: none`: not drawn, not found by Find, not selected, copied or printed,
//! and absent from the accessibility tree. A variant is hidden only beside a sibling of the chosen one, so an entry
//! that carries one variant always shows it, whatever the choice (d.4: never hide the only variant).
//!
//! **"Both"** (d.7) shows every variant in the dictionary's own order and grouping (the element that holds them),
//! with a separator, ` | `, drawn before each variant that follows another as generated content: shown and printed,
//! never selected, copied or found, and silent to accessibility (its alternative text is empty where the browser
//! reads one).
//!
//! **Original style** (d.7): an option holds under it. Its selectors read only the dictionary's own markers, never
//! the reading style's `data-xdict-*` marks, and the render keeps those markers in both styles (tested in
//! `xdict-core`).

use crate::Style;

/// The catalogue's version: raised when an option, a value, a contract or the CSS changes.
pub const DISPLAY_OPTIONS: u32 = 1;

/// The separator "both" draws between variants.
const SEPARATOR: &str = " | ";

/// One variant an option shows alone: the value that chooses it, and the markup that carries it (an element with
/// `class` among its classes and `marker` = `marker_value` exactly).
struct Variant {
    value: &'static str,
    class: &'static str,
    marker: &'static str,
    marker_value: &'static str,
}

/// One option of the catalogue.
struct Opt {
    id: &'static str,
    /// The root attribute a shell sets to the reader's choice.
    attribute: &'static str,
    /// The variants, each shown alone by its own value.
    variants: &'static [Variant],
    /// The value that shows every variant.
    all: &'static str,
    /// The default where no dictionary-specific one applies: everything, as the dictionary wrote it.
    default: &'static str,
}

impl Opt {
    /// The values a reader chooses from, in order: each variant's, then the one showing all.
    fn values(&self) -> Vec<&'static str> {
        self.variants.iter().map(|v| v.value).chain([self.all]).collect()
    }
}

/// The catalogue.
const CATALOGUE: &[Opt] = &[
    // Apple's pronunciation contract (`d:prn`, kept by the Apple import as `data-d-prn`): a respelling, `US`, and an
    // IPA transcription, `IPA`, each also classed by Apple's markup. NOAD writes them as siblings in one group.
    Opt {
        id: "pronunciation",
        attribute: "data-xdict-opt-pronunciation",
        variants: &[
            Variant { value: "respell", class: "t_respell", marker: "data-d-prn", marker_value: "US" },
            Variant { value: "ipa", class: "t_IPA", marker: "data-d-prn", marker_value: "IPA" },
        ],
        all: "both",
        default: "both",
    },
];

/// A dictionary-specific default, keyed by classes the edition's sheets all style (lower case), as the role tables'
/// signatures are.
struct DictionaryDefault {
    signature: &'static [&'static str],
    option: &'static str,
    value: &'static str,
}

const DICTIONARY_DEFAULTS: &[DictionaryDefault] = &[
    // Apple's New Oxford American Dictionary as XDict's Apple import converts it (ADR-0011): `fbm_NOAD`, its front
    // matter's class, is a rule subject no other sheet of the Apple measurement set nor of the 24 styles (measured
    // 2026-10-18). The owner chose IPA for it (ADR-0013); Apple's own default is the respelling.
    DictionaryDefault { signature: &["fbm_noad"], option: "pronunciation", value: "ipa" },
];

/// An option that applies to an edition: its id, the root attribute, its values and its default for the edition.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Declared {
    pub id: &'static str,
    pub attribute: &'static str,
    pub values: Vec<&'static str>,
    pub default: &'static str,
}

/// Why [`display_css`] wrote nothing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refused {
    /// No option of the catalogue has this id.
    UnknownOption,
    /// The option has no such value.
    UnknownValue,
    /// One option named twice.
    Repeated,
    /// A catalogue constant that is not a plain token (a defect of the catalogue, never of its input).
    Unsafe,
}

impl std::fmt::Display for Refused {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Refused::UnknownOption => "no display option has this id",
            Refused::UnknownValue => "the display option has no such value",
            Refused::Repeated => "a display option is named twice",
            Refused::Unsafe => "a catalogue constant is not a plain token",
        })
    }
}

impl std::error::Error for Refused {}

/// The options that apply to an edition, in catalogue order: those whose contract one of `entries` (a sample of the
/// edition's records) carries, each with the edition's default (`style`'s sheets decide a dictionary-specific one).
pub fn declared<'e>(style: &Style, entries: impl IntoIterator<Item = &'e str>) -> Vec<Declared> {
    let entries: Vec<&str> = entries.into_iter().collect();
    CATALOGUE
        .iter()
        .filter(|option| entries.iter().any(|entry| applies(option, entry)))
        .map(|option| Declared {
            id: option.id,
            attribute: option.attribute,
            values: option.values(),
            default: default_of(option, style),
        })
        .collect()
}

/// The option's default for an edition: the first dictionary-specific one whose signature its sheets style, if its
/// value is the option's, else the contract's.
fn default_of(option: &Opt, style: &Style) -> &'static str {
    DICTIONARY_DEFAULTS
        .iter()
        .filter(|d| d.option == option.id && option.values().contains(&d.value))
        .find(|d| d.signature.iter().all(|c| style.facts.styles_class(c)))
        .map_or(option.default, |d| d.value)
}

/// The CSS for `choices`, each an option's id and its default for the edition, written from the catalogue's own
/// constants only; empty for no choice. Refused when an id or a value is not the catalogue's, or an id repeats.
/// Written in catalogue order, one rule a line, so equal choices give equal bytes.
pub fn display_css(choices: &[(&str, &str)]) -> Result<String, Refused> {
    let mut chosen: Vec<(usize, &'static str)> = Vec::new();
    for (id, value) in choices {
        let (at, option) = CATALOGUE.iter().enumerate().find(|(_, o)| o.id == *id).ok_or(Refused::UnknownOption)?;
        let default = option.values().into_iter().find(|v| v == value).ok_or(Refused::UnknownValue)?;
        if chosen.iter().any(|(a, _)| *a == at) {
            return Err(Refused::Repeated);
        }
        chosen.push((at, default));
    }
    chosen.sort_by_key(|(at, _)| *at);
    let mut css = String::new();
    for (at, default) in chosen {
        let option = CATALOGUE.get(at).ok_or(Refused::UnknownOption)?;
        rules(option, default, &mut css)?;
    }
    Ok(css)
}

/// Whether a catalogue constant may be written into CSS as it is: an ASCII letter, then letters, digits, `-`, `_`.
fn plain(token: &str) -> bool {
    token.chars().next().is_some_and(|c| c.is_ascii_alphabetic())
        && token.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

/// One option's rules, its default `default` (one of its values), appended to `css`.
fn rules(option: &Opt, default: &str, css: &mut String) -> Result<(), Refused> {
    let values = option.values();
    let mut tokens = values
        .iter()
        .copied()
        .chain([option.attribute])
        .chain(option.variants.iter().flat_map(|v| [v.class, v.marker, v.marker_value]));
    if !tokens.all(plain) || SEPARATOR.contains(['"', '\\', '\n']) {
        return Err(Refused::Unsafe);
    }
    let attribute = option.attribute;
    // The root as the reader chose `value`: that value set, or, for the default, none of the others (absent, or a
    // value the catalogue does not list).
    let root = |value: &str| {
        if value == default {
            let mut root = String::from(":root");
            for other in values.iter().filter(|v| **v != value) {
                root.push_str(&format!(r#":not([{attribute}="{other}"])"#));
            }
            root
        } else {
            format!(r#":root[{attribute}="{value}"]"#)
        }
    };
    let selector = |v: &Variant| format!(r#".{}[{}="{}"]"#, v.class, v.marker, v.marker_value);
    const HIDE: &str = "{ display: none !important; }";
    // Each variant alone: every other variant is hidden beside a sibling of it, whichever comes first. `:has()` is a
    // rule of its own, so a browser without it drops that rule alone.
    for shown in option.variants {
        let (root, kept) = (root(shown.value), selector(shown));
        for hidden in option.variants.iter().filter(|v| v.value != shown.value) {
            let hidden = selector(hidden);
            css.push_str(&format!("{root} {kept} ~ {hidden} {HIDE}\n"));
            css.push_str(&format!("{root} {hidden}:has(~ {kept}) {HIDE}\n"));
        }
    }
    // All: a separator before each variant that follows another.
    let root = root(option.all);
    for later in option.variants {
        for earlier in option.variants.iter().filter(|v| v.value != later.value) {
            let (earlier, later) = (selector(earlier), selector(later));
            css.push_str(&format!(
                r#"{root} {earlier} ~ {later}::before {{ content: "{SEPARATOR}"; content: "{SEPARATOR}" / ""; }}"#
            ));
            css.push('\n');
        }
    }
    Ok(())
}

/// The deepest nesting followed: past it the scan stops and answers no (an option not offered, never a wrong one).
const MAX_DEPTH: usize = 512;

/// Whether `html` carries the option's contract: an element holding, among its children, every variant (the only
/// arrangement the CSS acts on). A tag scanner, as the rewriter is: a script's and a style's text are raw text,
/// comments and declarations are skipped, attribute names are compared ignoring case and values after their
/// character references, as a browser reads them.
fn applies(option: &Opt, html: &str) -> bool {
    let every: u32 = (1u32 << option.variants.len().min(31)) - 1;
    // Open elements: the name, and which variants its children so far are.
    let mut open: Vec<(String, u32)> = vec![(String::new(), 0)];
    let mut rest = html;
    while let Some(at) = rest.find('<') {
        rest = rest.get(at..).unwrap_or("");
        if let Some(after) = rest.strip_prefix("<!--") {
            rest = after.find("-->").and_then(|end| after.get(end + 3..)).unwrap_or("");
            continue;
        }
        if rest.starts_with("<!") || rest.starts_with("<?") {
            rest = rest.find('>').and_then(|end| rest.get(end + 1..)).unwrap_or("");
            continue;
        }
        if let Some(after) = rest.strip_prefix("</") {
            let name = tag_name(after);
            if let Some(i) = open.iter().rposition(|(n, _)| !n.is_empty() && *n == name) {
                open.truncate(i);
            }
            rest = after.find('>').and_then(|end| after.get(end + 1..)).unwrap_or("");
            continue;
        }
        let Some(after) = rest.get(1..) else { break };
        if !after.starts_with(|c: char| c.is_ascii_alphabetic()) {
            rest = after;
            continue;
        }
        let end = tag_end(after);
        let tag = rest.get(..end + 1).unwrap_or(rest);
        rest = after.get(end..).unwrap_or("");
        let name = tag_name(after);
        let attributes = crate::roles::attributes(tag);
        let value = |name: &str| attributes.iter().find(|(n, _)| n == name).map(|(_, v)| v.as_str());
        let is = |v: &Variant| {
            value("class").is_some_and(|c| c.split_ascii_whitespace().any(|c| c == v.class))
                && value(v.marker) == Some(v.marker_value)
        };
        if let Some(i) = option.variants.iter().position(is)
            && let Some((_, seen)) = open.last_mut()
        {
            *seen |= 1 << i.min(31);
            if *seen & every == every {
                return true;
            }
        }
        if name == "script" || name == "style" {
            rest = raw_text_end(rest, &name);
        } else if !crate::roles::void(&name) {
            if open.len() >= MAX_DEPTH {
                return false;
            }
            open.push((name, 0));
        }
    }
    false
}

/// A tag's name, lower case: what follows `<` or `</` up to a space, `/` or `>`.
fn tag_name(after: &str) -> String {
    after.split(|c: char| c.is_ascii_whitespace() || c == '/' || c == '>').next().unwrap_or("").to_ascii_lowercase()
}

/// Where a start tag's `>` is in `after` (the tag without its `<`), quoted attribute values passed over; its length
/// when it has none.
fn tag_end(after: &str) -> usize {
    let bytes = after.as_bytes();
    let mut i = 0;
    while let Some(&b) = bytes.get(i) {
        match b {
            b'>' => return i,
            b'=' => {
                i += 1;
                while bytes.get(i).is_some_and(u8::is_ascii_whitespace) {
                    i += 1;
                }
                if let Some(&q @ (b'"' | b'\'')) = bytes.get(i) {
                    i += 1;
                    while bytes.get(i).is_some_and(|&c| c != q) {
                        i += 1;
                    }
                    i += 1;
                }
            }
            _ => i += 1,
        }
    }
    bytes.len()
}

/// What follows a raw text element's text: from its end tag (`</name`, ignoring case) on, or nothing without one.
fn raw_text_end<'h>(rest: &'h str, name: &str) -> &'h str {
    let needle = format!("</{name}");
    let bytes = rest.as_bytes();
    (0..bytes.len())
        .find(|&i| bytes.get(i..i + needle.len()).is_some_and(|w| w.eq_ignore_ascii_case(needle.as_bytes())))
        .and_then(|at| rest.get(at..))
        .unwrap_or("")
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::indexing_slicing)]
mod tests {
    use super::*;

    fn pronunciation() -> &'static Opt {
        CATALOGUE.iter().find(|o| o.id == "pronunciation").unwrap()
    }

    const R: &str = r#"<span class="ph t_respell" data-d-prn="US">ˈap(ə)l</span>"#;
    const I: &str = r#"<span class="ph t_IPA" data-d-prn="IPA">ˈæp(ə)l</span>"#;

    fn group(inner: &str) -> String {
        format!(r#"<div class="entry"><span class="hw">apple</span><span class="prx"> | {inner} | </span></div>"#)
    }

    #[test]
    fn an_entry_with_both_variants_side_by_side_carries_the_contract() {
        assert!(applies(pronunciation(), &group(&format!("{R}{I}"))));
        assert!(applies(pronunciation(), &group(&format!("{I} {R}"))), "either order");
        // As written in the reader's file: attribute names in any case, values through their character references.
        let written =
            r#"<span CLASS="t_respell ph" DATA-D-PRN=US>a</span><span class='t_IPA' data-d-prn="&#73;PA">b</span>"#;
        assert!(applies(pronunciation(), &group(written)));
    }

    #[test]
    fn one_variant_alone_or_neither_is_not_the_contract() {
        assert!(!applies(pronunciation(), &group(R)), "respelling only");
        assert!(!applies(pronunciation(), &group(I)), "IPA only");
        assert!(!applies(pronunciation(), &group("ˈap(ə)l")), "neither");
        assert!(!applies(pronunciation(), ""));
        // Both, but in two groups: nothing the CSS could choose between, so nothing to offer.
        let apart = format!(r#"<span class="a">{R}</span><span class="b">{I}</span>"#);
        assert!(!applies(pronunciation(), &apart));
    }

    /// Another dictionary that happens to use the class names, without Apple's marker, or with the markers swapped.
    #[test]
    fn an_unrelated_dictionary_sharing_class_names_is_not_the_contract() {
        let classes_only = r#"<span class="t_respell">a</span><span class="t_IPA">b</span>"#;
        assert!(!applies(pronunciation(), &group(classes_only)));
        let swapped =
            r#"<span class="t_respell" data-d-prn="IPA">a</span><span class="t_IPA" data-d-prn="US">b</span>"#;
        assert!(!applies(pronunciation(), &group(swapped)));
        let markers_only = r#"<span data-d-prn="US">a</span><span data-d-prn="IPA">b</span>"#;
        assert!(!applies(pronunciation(), &group(markers_only)));
    }

    /// Forged or hostile markup is compared, never read as a selector: near misses are not the contract, and markers
    /// in a comment or a script are not elements.
    #[test]
    fn forged_markers_are_not_the_contract() {
        for forged in [
            r#"<span class="t_respell" data-d-prn="US">a</span><span class="t_IPA" data-d-prn='IPA"] * {display:none} [x="'>b</span>"#,
            r#"<span class="t_respell" data-d-prn="us">a</span><span class="t_IPA" data-d-prn="ipa">b</span>"#,
            r#"<span class="t_respell" data-d-prn="US">a</span><span class="t_ipa" data-d-prn="IPA">b</span>"#,
            r#"<span class="t_respell" data-d-prn="US">a</span><span class="t_IPAx" data-d-prn="IPA">b</span>"#,
            r#"<span class="t_respell" data-d-prn="US">a</span><span class="t_IPA" data-d-prn=" IPA">b</span>"#,
            r#"<span class="t_respell" data-d-prn="US">a</span><!-- <span class="t_IPA" data-d-prn="IPA">b</span> -->"#,
            r#"<span class="t_respell" data-d-prn="US">a</span><script>'<span class="t_IPA" data-d-prn="IPA">'</script>"#,
            r#"<span class="t_respell" data-x-data-d-prn="US">a</span><span class="t_IPA" data-d-prn="IPA">b</span>"#,
        ] {
            assert!(!applies(pronunciation(), &group(forged)), "{forged}");
        }
        // Unclosed or deeply nested markup ends the scan without a panic.
        assert!(!applies(pronunciation(), &"<span>".repeat(100_000)));
        assert!(!applies(pronunciation(), r#"<span class="t_IPA" data-d-prn="IPA"#));
    }

    fn noad_sheet() -> Style {
        Style::of_sheets([".fbm_NOAD { margin: 0 } span.ph { font-weight: normal }"])
    }

    #[test]
    fn an_option_is_declared_with_its_default_where_the_sample_carries_it() {
        let both = group(&format!("{R}{I}"));
        let entries = ["<b>see</b>", both.as_str()];
        let plain = declared(&Style::of_sheets(["span.ph { font-weight: normal }"]), entries);
        assert_eq!(
            plain,
            [Declared {
                id: "pronunciation",
                attribute: "data-xdict-opt-pronunciation",
                values: vec!["respell", "ipa", "both"],
                default: "both",
            }],
            "the contract's default: everything, as written"
        );
        let noad = declared(&noad_sheet(), entries);
        assert_eq!(noad.first().map(|d| d.default), Some("ipa"), "Apple's NOAD: IPA (ADR-0013)");
        // The dictionary's default never makes an option apply: NOAD's sheet with no entry carrying both is nothing.
        assert!(declared(&noad_sheet(), [group(I).as_str(), group(R).as_str()]).is_empty());
        assert!(declared(&noad_sheet(), []).is_empty());
    }

    #[test]
    fn every_dictionary_default_is_a_value_of_its_option() {
        for d in DICTIONARY_DEFAULTS {
            let option = CATALOGUE.iter().find(|o| o.id == d.option);
            assert!(option.is_some_and(|o| o.values().contains(&d.value)), "{} {}", d.option, d.value);
            assert!(
                d.signature.iter().all(|c| c.chars().all(|c| !c.is_ascii_uppercase())),
                "signatures are lower case"
            );
        }
        for o in CATALOGUE {
            assert!(o.values().contains(&o.default), "{}", o.id);
        }
    }

    const BOTH: &str = r#"content: " | "; content: " | " / "";"#;

    #[test]
    fn the_css_shows_each_value_and_the_default_where_the_attribute_is_absent() {
        let r = r#".t_respell[data-d-prn="US"]"#;
        let i = r#".t_IPA[data-d-prn="IPA"]"#;
        let a = "data-xdict-opt-pronunciation";
        let hide = "{ display: none !important; }";
        let ipa_default = format!(r#":root:not([{a}="respell"]):not([{a}="both"])"#);
        let expected = [
            format!(r#":root[{a}="respell"] {r} ~ {i} {hide}"#),
            format!(r#":root[{a}="respell"] {i}:has(~ {r}) {hide}"#),
            format!("{ipa_default} {i} ~ {r} {hide}"),
            format!("{ipa_default} {r}:has(~ {i}) {hide}"),
            format!(r#":root[{a}="both"] {i} ~ {r}::before {{ {BOTH} }}"#),
            format!(r#":root[{a}="both"] {r} ~ {i}::before {{ {BOTH} }}"#),
        ];
        let css = display_css(&[("pronunciation", "ipa")]);
        assert_eq!(css, Ok(expected.iter().map(|l| format!("{l}\n")).collect::<String>()));

        // With "both" the default, nothing is hidden where the attribute is absent, and the separator shows.
        let both_default = format!(r#":root:not([{a}="respell"]):not([{a}="ipa"])"#);
        let css = display_css(&[("pronunciation", "both")]).unwrap_or_default();
        assert!(css.contains(&format!(r#":root[{a}="respell"] {r} ~ {i} {hide}"#)), "{css}");
        assert!(css.contains(&format!(r#":root[{a}="ipa"] {i} ~ {r} {hide}"#)), "{css}");
        assert!(css.contains(&format!("{both_default} {r} ~ {i}::before")), "{css}");
        assert_eq!(css.lines().count(), 6);
        let respell_default = format!(r#":root:not([{a}="ipa"]):not([{a}="both"])"#);
        let css = display_css(&[("pronunciation", "respell")]).unwrap_or_default();
        assert!(css.contains(&format!("{respell_default} {r} ~ {i} {hide}")), "{css}");
        // Hiding is display: none, nothing weaker (d.3: out of Find, selection, copy, print and accessibility).
        assert!(!css.contains("visibility") && !css.contains("opacity"));
        assert_eq!(display_css(&[]), Ok(String::new()));
    }

    #[test]
    fn the_css_is_deterministic() {
        let one = display_css(&[("pronunciation", "ipa")]);
        assert!(one.as_ref().is_ok_and(|c| !c.is_empty()));
        for _ in 0..8 {
            assert_eq!(display_css(&[("pronunciation", "ipa")]), one);
        }
        let both = group(&format!("{R}{I}"));
        assert_eq!(declared(&noad_sheet(), [both.as_str()]), declared(&noad_sheet(), [both.as_str()]));
    }

    /// Ids and values are matched against the catalogue, and the CSS is written from its constants: anything else is
    /// refused, never written.
    #[test]
    fn malicious_ids_and_values_are_refused() {
        for (id, value, why) in [
            ("pronunciation", r#"ipa"]) { } * { display: none } :root:not(["#, Refused::UnknownValue),
            ("pronunciation", "IPA", Refused::UnknownValue),
            ("pronunciation", "ipa ", Refused::UnknownValue),
            ("pronunciation", "", Refused::UnknownValue),
            ("pronunciation", "ipa\u{0}", Refused::UnknownValue),
            ("pronunciation", "ｉｐａ", Refused::UnknownValue),
            ("pronunciation} * {display:none", "ipa", Refused::UnknownOption),
            ("Pronunciation", "ipa", Refused::UnknownOption),
            ("", "ipa", Refused::UnknownOption),
        ] {
            assert_eq!(display_css(&[(id, value)]), Err(why), "{id:?} {value:?}");
        }
        assert_eq!(display_css(&[("pronunciation", "ipa"), ("pronunciation", "both")]), Err(Refused::Repeated));
    }

    /// Every constant the CSS is written from is a plain token, and the separator cannot close its string.
    #[test]
    fn the_catalogue_holds_plain_tokens() {
        let plain = |t: &str| {
            t.chars().next().is_some_and(|c| c.is_ascii_alphabetic())
                && t.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
        };
        for o in CATALOGUE {
            assert!(plain(o.id) && plain(o.attribute) && plain(o.all), "{}", o.id);
            assert_eq!(o.attribute, format!("data-xdict-opt-{}", o.id));
            for v in o.variants {
                assert!([v.value, v.class, v.marker, v.marker_value].iter().all(|t| plain(t)), "{}", v.value);
            }
        }
        assert!(!SEPARATOR.contains(['"', '\\', '\n']));
    }
}
