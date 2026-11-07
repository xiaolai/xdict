//! The element sweep's strip list (`dev-docs/element-sweep.md` §2.4) where a rule reads one tag, one attribute or one
//! script: which scripts run (S1 and the owner's Q6), `javascript:` links (S6), audio hidden in attributes (S5) and
//! `<<word>>` references (S12). What needs the element tree (S5's link, S10, S11) is `crate::roles`'s.

/// Script text read for its purpose, at most: a library's purpose shows early, and a 64 MiB script is not read
/// whole to decide it.
const PURPOSE_BYTES: usize = 1 << 20;
/// The longest `<<word>>` read as a reference.
const ARROW_BYTES: usize = 64;
/// The most inline scripts read from one entry.
const INLINE_SCRIPTS: usize = 64;

/// Calls that only an ad or a tracker makes.
const TRACKERS: [&str; 12] = [
    "googletag",
    "gtag(",
    "google-analytics",
    "googlesyndication",
    "adsbygoogle",
    "doubleclick",
    "hm.baidu",
    "cnzz",
    "_hmt",
    "_gaq",
    "fbq(",
    "analytics.js",
];
/// What a script does that makes the entry work: folds, tabs, toggles, reveals.
const WORKS: [&str; 13] = [
    "toggle",
    "display",
    "classlist",
    "classname",
    "addclass",
    "removeclass",
    "collapse",
    "expand",
    "show(",
    "hide(",
    "slidedown",
    "slideup",
    "hidden",
];
/// What only audio needs.
const AUDIO: [&str; 6] = ["audio", ".play(", ".mp3", ".wav", ".ogg", "sound"];
/// Recording file extensions.
const RECORDINGS: [&str; 6] = [".mp3", ".wav", ".ogg", ".spx", ".m4a", ".aac"];

/// Why a script is kept (`Ok`: it makes something work) or dropped (`Err`: `tracker`, `audio` or `other`): the
/// owner's Q6. A tracker is dropped whatever else it does; a script that toggles, folds or reveals is kept even when
/// it also plays audio; one that only plays audio, and one that does neither, go.
pub fn script_purpose(text: &str) -> Result<&'static str, &'static str> {
    let end = (0..=text.len().min(PURPOSE_BYTES)).rev().find(|&i| text.is_char_boundary(i)).unwrap_or(0);
    let lower = text.get(..end).unwrap_or("").to_ascii_lowercase();
    if TRACKERS.iter().any(|t| lower.contains(t)) {
        return Err("tracker");
    }
    if WORKS.iter().any(|w| lower.contains(w)) {
        return Ok("fold");
    }
    if AUDIO.iter().any(|a| lower.contains(a)) {
        return Err("audio");
    }
    Err("other")
}

/// The bodies of an entry's inline `<script>`s (those without a `src`), at most [`INLINE_SCRIPTS`] of them; each
/// `<script` is looked for once, so the cost is the entry's length. Its tag is read as HTML reads it ([`crate::tag::end`]): a
/// `>` in a quoted value does not end it, and one that never ends is the rest of the entry, no script.
pub(crate) fn inline_scripts(entry: &str) -> impl Iterator<Item = &str> {
    let mut rest = entry;
    std::iter::from_fn(move || {
        loop {
            let lower_at = find_ignoring_case(rest, "<script")?;
            let after_name = rest.get(lower_at + "<script".len()..)?;
            // `<scripting>` is another element.
            if after_name.bytes().next().is_some_and(|b| !(b.is_ascii_whitespace() || matches!(b, b'/' | b'>'))) {
                rest = after_name;
                continue;
            }
            let Some(gt) = crate::tag::end(after_name) else {
                rest = "";
                return None;
            };
            let tag = after_name.get(..gt)?;
            let body_from = after_name.get(gt + 1..)?;
            let end = find_ignoring_case(body_from, "</script").unwrap_or(body_from.len());
            rest = body_from.get(end..)?;
            if !crate::roles::attributes(&format!("<script{tag}>")).iter().any(|(name, _)| name == "src") {
                return body_from.get(..end);
            }
        }
    })
    .take(INLINE_SCRIPTS)
}

fn find_ignoring_case(haystack: &str, needle: &str) -> Option<usize> {
    let n = needle.len();
    haystack.as_bytes().windows(n).position(|w| w.eq_ignore_ascii_case(needle.as_bytes()))
}

/// Whether a URL is `javascript:` as a browser reads it: leading spaces and control characters, and tabs and line
/// breaks anywhere, ignored.
pub(crate) fn javascript_url(value: &str) -> bool {
    let decoded = crate::rewrite::unescaped_html(value);
    let squeezed: String =
        decoded.trim_start_matches(|c: char| c <= ' ').chars().filter(|c| !matches!(c, '\t' | '\n' | '\r')).collect();
    squeezed.get(..11).is_some_and(|p| p.eq_ignore_ascii_case("javascript:"))
}

/// Whether a handler plays audio and nothing else the entry needs.
pub(crate) fn audio_handler(value: &str) -> bool {
    let lower = value.to_ascii_lowercase();
    let plays = lower.contains("new audio")
        || lower.contains(".play(")
        || RECORDINGS.iter().any(|r| lower.contains(r))
        || ["playsound", "play_sound", "playaudio", "play_audio", "sound(", "speak("].iter().any(|p| lower.contains(p));
    plays && !WORKS.iter().any(|w| lower.contains(w))
}

/// A recording a handler names literally: `new Audio('a.mp3')`.
pub(crate) fn handler_recording(value: &str) -> Option<&str> {
    let lower = value.to_ascii_lowercase();
    let at = lower.find("new audio(")? + "new audio(".len();
    let rest = value.get(at..)?.trim_start();
    let quote = rest.chars().next().filter(|c| matches!(c, '\'' | '"'))?;
    let body = rest.get(1..)?;
    let literal = body.get(..body.find(quote)?)?;
    recording(literal).then_some(literal)
}

/// Whether a value names a recording by its extension.
pub(crate) fn recording(value: &str) -> bool {
    let v = value.trim().split(['?', '#']).next().unwrap_or("").to_ascii_lowercase();
    RECORDINGS.iter().any(|r| v.ends_with(r))
}

/// Whether a recording's URL is remote: it cannot play (the CSP), so its word is spoken instead.
pub(crate) fn remote(value: &str) -> bool {
    let v = value.trim().to_ascii_lowercase();
    v.starts_with("http:") || v.starts_with("https:") || v.starts_with("//")
}

/// `<<word>>` at the start of `from`, a reference a browser would read as a tag and lose: the word and the length.
pub(crate) fn arrow(from: &str) -> Option<(&str, usize)> {
    let body = from.strip_prefix("<<")?;
    let limit = (0..=body.len().min(ARROW_BYTES + 2)).rev().find(|&i| body.is_char_boundary(i)).unwrap_or(0);
    let end = body.get(..limit)?.find(">>")?;
    let word = body.get(..end)?;
    let plain = !word.is_empty()
        && word.len() <= ARROW_BYTES
        && word.chars().any(char::is_alphabetic)
        && !word.contains(['<', '>', '=', '"', '/', '&'])
        && !word.starts_with(char::is_whitespace);
    plain.then_some((word, 2 + end + 2))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn javascript_is_read_as_a_browser_reads_it() {
        assert!(javascript_url("javascript:void(0)"));
        assert!(javascript_url("  JAVA\tSCRIPT:x"));
        assert!(javascript_url("&#106;avascript:x"));
        assert!(!javascript_url("entry://javascript"));
    }

    #[test]
    fn a_recording_is_named_by_its_extension() {
        assert_eq!(handler_recording("new Audio('a/b.mp3').play()"), Some("a/b.mp3"));
        assert_eq!(handler_recording("new Audio(this.getAttribute('data-mp3')).play()"), None);
        assert!(audio_handler("new Audio(x).play()"));
        assert!(!audio_handler("toggle(this)"));
        assert!(remote("https://x.example/a.mp3"));
    }

    #[test]
    fn an_arrow_reference_is_a_word() {
        assert_eq!(arrow("<<an>> x"), Some(("an", 6)));
        assert_eq!(arrow("<<b>x</b>"), None);
        assert_eq!(arrow("<<>>"), None);
        assert_eq!(arrow(&format!("<<{}>>", "a".repeat(200))), None);
    }

    /// **Every inline script is read, its tag as HTML reads it** (audit 2026-11-05, L12): a `>` inside a quoted value
    /// once ended the tag before its `src`, a `<scripting>` was taken for a script, and a fold script after them went
    /// unread, so S10 could unwrap what it needs.
    #[test]
    fn inline_scripts_are_read_tag_by_tag() {
        fn scripts(html: &str) -> Vec<&str> {
            inline_scripts(html).collect()
        }
        assert_eq!(
            scripts(r#"<script data-x="a>b" src="t.js"></script><p>x</p><script>toggle('y')</script>"#),
            ["toggle('y')"]
        );
        assert_eq!(scripts(r#"<script title='>' >fold()</script>"#), ["fold()"]);
        assert_eq!(scripts("<scripting>x</scripting><script>toggle()</script>"), ["toggle()"]);
        assert_eq!(scripts("<SCRIPT type=text/javascript>show(1)</Script >"), ["show(1)"]);
        // A `<script` whose tag never ends is the rest of the entry; what came before is still read.
        assert_eq!(scripts(r#"<script>toggle()</script><p>a</p><script data-x="b>"#), ["toggle()"]);
        assert_eq!(scripts(r#"<script>toggle()</script><script src="x.js"#), ["toggle()"]);
        // An unclosed script runs to the end, as a browser runs it.
        assert_eq!(scripts("<script>hide(1)"), ["hide(1)"]);
    }
}
