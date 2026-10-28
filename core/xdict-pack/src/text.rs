//! Text as the pack holds it: NFC, no control characters, and the small string rules the sources need.

use unicode_normalization::UnicodeNormalization;

/// NFC, the one form every string in a pack is in.
pub fn nfc(text: &str) -> String {
    text.nfc().collect()
}

/// Whether `ch` is a Cc character, the category the pack refuses. That is U+0000–U+001F and U+007F–U+009F, and
/// nothing else.
pub fn is_control(ch: char) -> bool {
    let n = ch as u32;
    n <= 0x1F || (0x7F..=0x9F).contains(&n)
}

/// Whether any character of `text` is a control character.
pub fn has_control(text: &str) -> bool {
    text.chars().any(is_control)
}

/// The host of `url` when it is an https address the loader accepts: a nonempty DNS name or a bracketed IPv6
/// literal, an optional numeric port, no whitespace or control character anywhere, and nothing but userinfo before
/// the host. `https://:443`, `https://@`, `https://[broken` and `https://example.org:not-a-port` are refused.
pub fn https_host(url: &str) -> Option<&str> {
    let rest = url.strip_prefix("https://")?;
    if rest.chars().any(|ch| ch.is_whitespace() || is_control(ch)) {
        return None;
    }
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    let host_port = authority.rsplit('@').next().unwrap_or("");
    let (host, port): (&str, Option<&str>) = if let Some(after) = host_port.strip_prefix('[') {
        let (inside, tail) = after.split_once(']')?;
        if !tail.is_empty() && !tail.starts_with(':') {
            return None;
        }
        if inside.is_empty() || inside.chars().any(|ch| !(ch.is_ascii_hexdigit() || ch == ':' || ch == '.')) {
            return None;
        }
        let port = Some(tail).filter(|tail| !tail.is_empty()).and_then(|tail| tail.strip_prefix(':'));
        (inside, port)
    } else {
        let (host, port_text) = host_port.split_once(':').unwrap_or((host_port, ""));
        if host.is_empty() || host.chars().any(|ch| !(ch.is_alphanumeric() || matches!(ch, '-' | '.' | '_'))) {
            return None;
        }
        let port = if port_text.is_empty() { None } else { Some(port_text) };
        (host, port)
    };
    if let Some(port) = port
        && !port.chars().all(|ch| ch.is_numeric())
    {
        return None;
    }
    Some(host)
}

/// `*per- (fare)` becomes `*per-`: etymology-db appends a gloss in parentheses to some forms; the form is kept
/// whole, a trailing hyphen included.
///
/// The reference is the regular expression `^(.*\S)\s+\([^()]*\)$`. Because `[^()]*` admits no parenthesis, the
/// gloss is the last parenthesised group, which must end the string; because `.*` is greedy and `(.*\S)` must end
/// on a non-space, the whitespace run before that group is consumed whole; and because `.` does not cross a line
/// break, neither may the form.
pub fn strip_gloss(form: &str) -> &str {
    // `$` matches at the end, or just before one newline at the end; `.` never crosses a line break.
    let subject = form.strip_suffix('\n').unwrap_or(form);
    let Some(open) = subject.rfind('(') else { return form };
    let Some((before, group)) = subject.split_at_checked(open) else { return form };
    if group.len() < 2 || !group.ends_with(')') {
        return form;
    }
    let Some(inner) = group.get(1..group.len() - 1) else { return form };
    if inner.contains('(') || inner.contains(')') {
        return form;
    }
    let trimmed = before.trim_end();
    if trimmed.len() == before.len() || trimmed.is_empty() || trimmed.contains('\n') {
        return form;
    }
    trimmed
}

/// **Every code point where Unicode's full case folding differs from its lowercase mapping** — 297 of them — generated
/// from the reference implementation's own `str.casefold` (Python 3.15, Unicode 17) rather than trusted to memory:
///
/// ```sh
/// python3 -c 'print(sum(chr(c).casefold() != chr(c).lower() for c in range(0x110000)))'
/// ```
///
/// A code point not listed folds to its lowercase mapping, which is what `str.casefold` does to it too; a fixture in
/// `morphynet::tests` holds the cases where a plain lowercase would disagree.
fn fold_exception(ch: char) -> Option<&'static str> {
    match ch {
        '\u{B5}' => Some("μ"),
        '\u{DF}' => Some("ss"),
        '\u{149}' => Some("ʼn"),
        '\u{17F}' => Some("s"),
        '\u{1F0}' => Some("ǰ"),
        '\u{345}' => Some("ι"),
        '\u{390}' => Some("ΐ"),
        '\u{3B0}' => Some("ΰ"),
        '\u{3C2}' => Some("σ"),
        '\u{3D0}' => Some("β"),
        '\u{3D1}' => Some("θ"),
        '\u{3D5}' => Some("φ"),
        '\u{3D6}' => Some("π"),
        '\u{3F0}' => Some("κ"),
        '\u{3F1}' => Some("ρ"),
        '\u{3F5}' => Some("ε"),
        '\u{587}' => Some("եւ"),
        '\u{13A0}' => Some("Ꭰ"),
        '\u{13A1}' => Some("Ꭱ"),
        '\u{13A2}' => Some("Ꭲ"),
        '\u{13A3}' => Some("Ꭳ"),
        '\u{13A4}' => Some("Ꭴ"),
        '\u{13A5}' => Some("Ꭵ"),
        '\u{13A6}' => Some("Ꭶ"),
        '\u{13A7}' => Some("Ꭷ"),
        '\u{13A8}' => Some("Ꭸ"),
        '\u{13A9}' => Some("Ꭹ"),
        '\u{13AA}' => Some("Ꭺ"),
        '\u{13AB}' => Some("Ꭻ"),
        '\u{13AC}' => Some("Ꭼ"),
        '\u{13AD}' => Some("Ꭽ"),
        '\u{13AE}' => Some("Ꭾ"),
        '\u{13AF}' => Some("Ꭿ"),
        '\u{13B0}' => Some("Ꮀ"),
        '\u{13B1}' => Some("Ꮁ"),
        '\u{13B2}' => Some("Ꮂ"),
        '\u{13B3}' => Some("Ꮃ"),
        '\u{13B4}' => Some("Ꮄ"),
        '\u{13B5}' => Some("Ꮅ"),
        '\u{13B6}' => Some("Ꮆ"),
        '\u{13B7}' => Some("Ꮇ"),
        '\u{13B8}' => Some("Ꮈ"),
        '\u{13B9}' => Some("Ꮉ"),
        '\u{13BA}' => Some("Ꮊ"),
        '\u{13BB}' => Some("Ꮋ"),
        '\u{13BC}' => Some("Ꮌ"),
        '\u{13BD}' => Some("Ꮍ"),
        '\u{13BE}' => Some("Ꮎ"),
        '\u{13BF}' => Some("Ꮏ"),
        '\u{13C0}' => Some("Ꮐ"),
        '\u{13C1}' => Some("Ꮑ"),
        '\u{13C2}' => Some("Ꮒ"),
        '\u{13C3}' => Some("Ꮓ"),
        '\u{13C4}' => Some("Ꮔ"),
        '\u{13C5}' => Some("Ꮕ"),
        '\u{13C6}' => Some("Ꮖ"),
        '\u{13C7}' => Some("Ꮗ"),
        '\u{13C8}' => Some("Ꮘ"),
        '\u{13C9}' => Some("Ꮙ"),
        '\u{13CA}' => Some("Ꮚ"),
        '\u{13CB}' => Some("Ꮛ"),
        '\u{13CC}' => Some("Ꮜ"),
        '\u{13CD}' => Some("Ꮝ"),
        '\u{13CE}' => Some("Ꮞ"),
        '\u{13CF}' => Some("Ꮟ"),
        '\u{13D0}' => Some("Ꮠ"),
        '\u{13D1}' => Some("Ꮡ"),
        '\u{13D2}' => Some("Ꮢ"),
        '\u{13D3}' => Some("Ꮣ"),
        '\u{13D4}' => Some("Ꮤ"),
        '\u{13D5}' => Some("Ꮥ"),
        '\u{13D6}' => Some("Ꮦ"),
        '\u{13D7}' => Some("Ꮧ"),
        '\u{13D8}' => Some("Ꮨ"),
        '\u{13D9}' => Some("Ꮩ"),
        '\u{13DA}' => Some("Ꮪ"),
        '\u{13DB}' => Some("Ꮫ"),
        '\u{13DC}' => Some("Ꮬ"),
        '\u{13DD}' => Some("Ꮭ"),
        '\u{13DE}' => Some("Ꮮ"),
        '\u{13DF}' => Some("Ꮯ"),
        '\u{13E0}' => Some("Ꮰ"),
        '\u{13E1}' => Some("Ꮱ"),
        '\u{13E2}' => Some("Ꮲ"),
        '\u{13E3}' => Some("Ꮳ"),
        '\u{13E4}' => Some("Ꮴ"),
        '\u{13E5}' => Some("Ꮵ"),
        '\u{13E6}' => Some("Ꮶ"),
        '\u{13E7}' => Some("Ꮷ"),
        '\u{13E8}' => Some("Ꮸ"),
        '\u{13E9}' => Some("Ꮹ"),
        '\u{13EA}' => Some("Ꮺ"),
        '\u{13EB}' => Some("Ꮻ"),
        '\u{13EC}' => Some("Ꮼ"),
        '\u{13ED}' => Some("Ꮽ"),
        '\u{13EE}' => Some("Ꮾ"),
        '\u{13EF}' => Some("Ꮿ"),
        '\u{13F0}' => Some("Ᏸ"),
        '\u{13F1}' => Some("Ᏹ"),
        '\u{13F2}' => Some("Ᏺ"),
        '\u{13F3}' => Some("Ᏻ"),
        '\u{13F4}' => Some("Ᏼ"),
        '\u{13F5}' => Some("Ᏽ"),
        '\u{13F8}' => Some("Ᏸ"),
        '\u{13F9}' => Some("Ᏹ"),
        '\u{13FA}' => Some("Ᏺ"),
        '\u{13FB}' => Some("Ᏻ"),
        '\u{13FC}' => Some("Ᏼ"),
        '\u{13FD}' => Some("Ᏽ"),
        '\u{1C80}' => Some("в"),
        '\u{1C81}' => Some("д"),
        '\u{1C82}' => Some("о"),
        '\u{1C83}' => Some("с"),
        '\u{1C84}' => Some("т"),
        '\u{1C85}' => Some("т"),
        '\u{1C86}' => Some("ъ"),
        '\u{1C87}' => Some("ѣ"),
        '\u{1C88}' => Some("ꙋ"),
        '\u{1E96}' => Some("ẖ"),
        '\u{1E97}' => Some("ẗ"),
        '\u{1E98}' => Some("ẘ"),
        '\u{1E99}' => Some("ẙ"),
        '\u{1E9A}' => Some("aʾ"),
        '\u{1E9B}' => Some("ṡ"),
        '\u{1E9E}' => Some("ss"),
        '\u{1F50}' => Some("ὐ"),
        '\u{1F52}' => Some("ὒ"),
        '\u{1F54}' => Some("ὔ"),
        '\u{1F56}' => Some("ὖ"),
        '\u{1F80}' => Some("ἀι"),
        '\u{1F81}' => Some("ἁι"),
        '\u{1F82}' => Some("ἂι"),
        '\u{1F83}' => Some("ἃι"),
        '\u{1F84}' => Some("ἄι"),
        '\u{1F85}' => Some("ἅι"),
        '\u{1F86}' => Some("ἆι"),
        '\u{1F87}' => Some("ἇι"),
        '\u{1F88}' => Some("ἀι"),
        '\u{1F89}' => Some("ἁι"),
        '\u{1F8A}' => Some("ἂι"),
        '\u{1F8B}' => Some("ἃι"),
        '\u{1F8C}' => Some("ἄι"),
        '\u{1F8D}' => Some("ἅι"),
        '\u{1F8E}' => Some("ἆι"),
        '\u{1F8F}' => Some("ἇι"),
        '\u{1F90}' => Some("ἠι"),
        '\u{1F91}' => Some("ἡι"),
        '\u{1F92}' => Some("ἢι"),
        '\u{1F93}' => Some("ἣι"),
        '\u{1F94}' => Some("ἤι"),
        '\u{1F95}' => Some("ἥι"),
        '\u{1F96}' => Some("ἦι"),
        '\u{1F97}' => Some("ἧι"),
        '\u{1F98}' => Some("ἠι"),
        '\u{1F99}' => Some("ἡι"),
        '\u{1F9A}' => Some("ἢι"),
        '\u{1F9B}' => Some("ἣι"),
        '\u{1F9C}' => Some("ἤι"),
        '\u{1F9D}' => Some("ἥι"),
        '\u{1F9E}' => Some("ἦι"),
        '\u{1F9F}' => Some("ἧι"),
        '\u{1FA0}' => Some("ὠι"),
        '\u{1FA1}' => Some("ὡι"),
        '\u{1FA2}' => Some("ὢι"),
        '\u{1FA3}' => Some("ὣι"),
        '\u{1FA4}' => Some("ὤι"),
        '\u{1FA5}' => Some("ὥι"),
        '\u{1FA6}' => Some("ὦι"),
        '\u{1FA7}' => Some("ὧι"),
        '\u{1FA8}' => Some("ὠι"),
        '\u{1FA9}' => Some("ὡι"),
        '\u{1FAA}' => Some("ὢι"),
        '\u{1FAB}' => Some("ὣι"),
        '\u{1FAC}' => Some("ὤι"),
        '\u{1FAD}' => Some("ὥι"),
        '\u{1FAE}' => Some("ὦι"),
        '\u{1FAF}' => Some("ὧι"),
        '\u{1FB2}' => Some("ὰι"),
        '\u{1FB3}' => Some("αι"),
        '\u{1FB4}' => Some("άι"),
        '\u{1FB6}' => Some("ᾶ"),
        '\u{1FB7}' => Some("ᾶι"),
        '\u{1FBC}' => Some("αι"),
        '\u{1FBE}' => Some("ι"),
        '\u{1FC2}' => Some("ὴι"),
        '\u{1FC3}' => Some("ηι"),
        '\u{1FC4}' => Some("ήι"),
        '\u{1FC6}' => Some("ῆ"),
        '\u{1FC7}' => Some("ῆι"),
        '\u{1FCC}' => Some("ηι"),
        '\u{1FD2}' => Some("ῒ"),
        '\u{1FD3}' => Some("ΐ"),
        '\u{1FD6}' => Some("ῖ"),
        '\u{1FD7}' => Some("ῗ"),
        '\u{1FE2}' => Some("ῢ"),
        '\u{1FE3}' => Some("ΰ"),
        '\u{1FE4}' => Some("ῤ"),
        '\u{1FE6}' => Some("ῦ"),
        '\u{1FE7}' => Some("ῧ"),
        '\u{1FF2}' => Some("ὼι"),
        '\u{1FF3}' => Some("ωι"),
        '\u{1FF4}' => Some("ώι"),
        '\u{1FF6}' => Some("ῶ"),
        '\u{1FF7}' => Some("ῶι"),
        '\u{1FFC}' => Some("ωι"),
        '\u{AB70}' => Some("Ꭰ"),
        '\u{AB71}' => Some("Ꭱ"),
        '\u{AB72}' => Some("Ꭲ"),
        '\u{AB73}' => Some("Ꭳ"),
        '\u{AB74}' => Some("Ꭴ"),
        '\u{AB75}' => Some("Ꭵ"),
        '\u{AB76}' => Some("Ꭶ"),
        '\u{AB77}' => Some("Ꭷ"),
        '\u{AB78}' => Some("Ꭸ"),
        '\u{AB79}' => Some("Ꭹ"),
        '\u{AB7A}' => Some("Ꭺ"),
        '\u{AB7B}' => Some("Ꭻ"),
        '\u{AB7C}' => Some("Ꭼ"),
        '\u{AB7D}' => Some("Ꭽ"),
        '\u{AB7E}' => Some("Ꭾ"),
        '\u{AB7F}' => Some("Ꭿ"),
        '\u{AB80}' => Some("Ꮀ"),
        '\u{AB81}' => Some("Ꮁ"),
        '\u{AB82}' => Some("Ꮂ"),
        '\u{AB83}' => Some("Ꮃ"),
        '\u{AB84}' => Some("Ꮄ"),
        '\u{AB85}' => Some("Ꮅ"),
        '\u{AB86}' => Some("Ꮆ"),
        '\u{AB87}' => Some("Ꮇ"),
        '\u{AB88}' => Some("Ꮈ"),
        '\u{AB89}' => Some("Ꮉ"),
        '\u{AB8A}' => Some("Ꮊ"),
        '\u{AB8B}' => Some("Ꮋ"),
        '\u{AB8C}' => Some("Ꮌ"),
        '\u{AB8D}' => Some("Ꮍ"),
        '\u{AB8E}' => Some("Ꮎ"),
        '\u{AB8F}' => Some("Ꮏ"),
        '\u{AB90}' => Some("Ꮐ"),
        '\u{AB91}' => Some("Ꮑ"),
        '\u{AB92}' => Some("Ꮒ"),
        '\u{AB93}' => Some("Ꮓ"),
        '\u{AB94}' => Some("Ꮔ"),
        '\u{AB95}' => Some("Ꮕ"),
        '\u{AB96}' => Some("Ꮖ"),
        '\u{AB97}' => Some("Ꮗ"),
        '\u{AB98}' => Some("Ꮘ"),
        '\u{AB99}' => Some("Ꮙ"),
        '\u{AB9A}' => Some("Ꮚ"),
        '\u{AB9B}' => Some("Ꮛ"),
        '\u{AB9C}' => Some("Ꮜ"),
        '\u{AB9D}' => Some("Ꮝ"),
        '\u{AB9E}' => Some("Ꮞ"),
        '\u{AB9F}' => Some("Ꮟ"),
        '\u{ABA0}' => Some("Ꮠ"),
        '\u{ABA1}' => Some("Ꮡ"),
        '\u{ABA2}' => Some("Ꮢ"),
        '\u{ABA3}' => Some("Ꮣ"),
        '\u{ABA4}' => Some("Ꮤ"),
        '\u{ABA5}' => Some("Ꮥ"),
        '\u{ABA6}' => Some("Ꮦ"),
        '\u{ABA7}' => Some("Ꮧ"),
        '\u{ABA8}' => Some("Ꮨ"),
        '\u{ABA9}' => Some("Ꮩ"),
        '\u{ABAA}' => Some("Ꮪ"),
        '\u{ABAB}' => Some("Ꮫ"),
        '\u{ABAC}' => Some("Ꮬ"),
        '\u{ABAD}' => Some("Ꮭ"),
        '\u{ABAE}' => Some("Ꮮ"),
        '\u{ABAF}' => Some("Ꮯ"),
        '\u{ABB0}' => Some("Ꮰ"),
        '\u{ABB1}' => Some("Ꮱ"),
        '\u{ABB2}' => Some("Ꮲ"),
        '\u{ABB3}' => Some("Ꮳ"),
        '\u{ABB4}' => Some("Ꮴ"),
        '\u{ABB5}' => Some("Ꮵ"),
        '\u{ABB6}' => Some("Ꮶ"),
        '\u{ABB7}' => Some("Ꮷ"),
        '\u{ABB8}' => Some("Ꮸ"),
        '\u{ABB9}' => Some("Ꮹ"),
        '\u{ABBA}' => Some("Ꮺ"),
        '\u{ABBB}' => Some("Ꮻ"),
        '\u{ABBC}' => Some("Ꮼ"),
        '\u{ABBD}' => Some("Ꮽ"),
        '\u{ABBE}' => Some("Ꮾ"),
        '\u{ABBF}' => Some("Ꮿ"),
        '\u{FB00}' => Some("ff"),
        '\u{FB01}' => Some("fi"),
        '\u{FB02}' => Some("fl"),
        '\u{FB03}' => Some("ffi"),
        '\u{FB04}' => Some("ffl"),
        '\u{FB05}' => Some("st"),
        '\u{FB06}' => Some("st"),
        '\u{FB13}' => Some("մն"),
        '\u{FB14}' => Some("մե"),
        '\u{FB15}' => Some("մի"),
        '\u{FB16}' => Some("վն"),
        '\u{FB17}' => Some("մխ"),
        _ => None,
    }
}

/// `text` folded for a case-insensitive comparison, exactly as Python's `str.casefold` folds it: **full case folding**
/// (Unicode `CaseFolding.txt`, statuses C and F), so a final sigma folds to sigma, `ß` to `ss`, `ſ` to `s` and the `ﬀ`
/// ligatures expand. `char::to_lowercase` is the *lowercase* mapping, and differs at exactly [`fold_exception`]'s
/// code points.
pub fn casefold(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for ch in text.chars() {
        match fold_exception(ch) {
            Some(fold) => out.push_str(fold),
            None => out.extend(ch.to_lowercase()),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::indexing_slicing)]

    use super::*;

    #[test]
    fn nfc_composes_what_the_sources_decompose() {
        assert_eq!(nfc("cafe\u{301}"), "caf\u{e9}");
        assert_eq!(nfc("caf\u{e9}"), "caf\u{e9}");
    }

    #[test]
    fn control_is_exactly_the_cc_category() {
        assert!(has_control("a\u{0}b"));
        assert!(has_control("a\u{7f}"));
        assert!(has_control("\u{9b}"));
        assert!(!has_control("caf\u{e9}"));
        assert!(!has_control("\u{2028}"));
    }

    #[test]
    fn an_https_host_is_what_the_loader_reads() {
        assert_eq!(https_host("https://example.org/a/b"), Some("example.org"));
        assert_eq!(https_host("https://user:pw@example.org:8080/x"), Some("example.org"));
        assert_eq!(https_host("https://[2001:db8::1]:443/x"), Some("2001:db8::1"));
        assert_eq!(https_host("https://[2001:db8::1]/x"), Some("2001:db8::1"));
        assert_eq!(https_host("http://example.org"), None);
        assert_eq!(https_host("https://:443"), None);
        assert_eq!(https_host("https://@"), None);
        assert_eq!(https_host("https://[broken"), None);
        assert_eq!(https_host("https://example.org:not-a-port"), None);
        assert_eq!(https_host("https://exa mple.org"), None);
        assert_eq!(https_host("https://example.org:8080"), Some("example.org"));
    }

    #[test]
    fn a_gloss_at_the_end_is_dropped_and_nothing_else_is() {
        assert_eq!(strip_gloss("*per- (fare)"), "*per-");
        assert_eq!(strip_gloss("word (a gloss)"), "word");
        assert_eq!(strip_gloss("word"), "word");
        assert_eq!(strip_gloss("word (a) (b)"), "word (a)");
        assert_eq!(strip_gloss("(alone)"), "(alone)");
        assert_eq!(strip_gloss("word(a)"), "word(a)");
        assert_eq!(strip_gloss("word (a (b))"), "word (a (b))");
    }

    #[test]
    fn casefold_folds_the_full_way_python_does() {
        assert_eq!(casefold("Straße"), "strasse");
        assert_eq!(casefold("ΣΟΦΟΣ"), "σοφοσ");
        assert_eq!(casefold("Æ"), "æ");
        assert_eq!(casefold("Run"), "run");
    }
}
