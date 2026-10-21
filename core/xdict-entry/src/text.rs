//! **An entry as plain text, whole, for a consumer that reads it** (ADR-0021 d.5, plan-ai-meaning WI-1): the
//! roles-marked HTML [`crate::entry_normalized_within`] writes, projected to text with one span per run back to its
//! roles, and a byte budget that reports its own cut. Nothing here decides structure a second time: the attributes the
//! renderer wrote (`data-xdict-role`, `data-xdict-label`, `data-xdict-section`, `hidden`) are read as they are, and
//! text the rules did not classify is kept, marked with no role.

use crate::rewrite::unescape_text;
use crate::roles::{attributes, void};

/// One run of the entry's text and where it came from: offsets in UTF-8 bytes of [`Projection::text`], and the
/// nearest role, label kind and section kind written around it — none for text the rules did not classify.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TextRun {
    pub start: usize,
    pub len: usize,
    pub role: Option<String>,
    pub label: Option<String>,
    pub section: Option<String>,
}

/// An entry's text under its budget, and what the budget left out.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Projection {
    pub text: String,
    pub runs: Vec<TextRun>,
    /// False whenever any part of the entry is missing from `text` — after a cut, never false otherwise.
    pub complete: bool,
    /// UTF-8 bytes of the whole entry's text that the budget left out.
    pub omitted_bytes: u64,
    /// Where the cut fell: the byte offset in the whole entry's text, and the length of `text`.
    pub cut_at: u64,
    /// Runs (and so their roles) that the budget left out.
    pub runs_dropped: u64,
}

/// Elements whose text is not part of the reading: never shown, or instructions rather than prose.
const SKIPPED: [&str; 3] = ["script", "style", "head"];

/// Elements that begin a line of their own.
const BLOCKS: [&str; 36] = [
    "address",
    "article",
    "aside",
    "blockquote",
    "caption",
    "dd",
    "detail",
    "div",
    "dl",
    "dt",
    "fieldset",
    "figcaption",
    "figure",
    "footer",
    "form",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
    "header",
    "hr",
    "li",
    "main",
    "nav",
    "ol",
    "p",
    "pre",
    "section",
    "summary",
    "table",
    "tbody",
    "td",
    "th",
    "tr",
];

struct Frame {
    name: String,
    /// The nearest value from this element up: cached at push, so a text node never walks the stack. A 60,000-deep
    /// document otherwise costs billions of checks (audit finding, 2026-10-20).
    role: Option<String>,
    label: Option<String>,
    section: Option<String>,
    hidden: bool,
    pre: bool,
    block: bool,
}

/// The most spans one projection carries: 16,384 runs of JSON stay far inside the 4 MB IPC envelope, while a text of
/// 200,000 one-character spans would not. Spans past this are dropped and counted. (Audit finding, 2026-10-20.)
pub const MAX_SPANS: usize = 4_096;

/// **`html` as plain text, held to `max_bytes`.** A budget that cuts reports the cut (`complete: false`, the bytes
/// left out, where it fell, the runs dropped); it is data, never an error. A zero budget is an empty text that says
/// what it left out.
pub fn entry_text_from_html(html: &str, max_bytes: usize) -> Projection {
    let mut state = State::default();
    let mut frames: Vec<Frame> = Vec::new();
    let mut at = 0usize;
    while at < html.len() {
        let Some(rest) = html.get(at..) else { break };
        match rest.find('<') {
            Some(0) => {
                // A `<` starts markup only when a name, `/`, `!` or `?` follows; `1 < 2` is text.
                let next = rest.as_bytes().get(1).copied();
                if next.is_some_and(|b| b.is_ascii_alphabetic() || matches!(b, b'/' | b'!' | b'?')) {
                    at = at_tag(html, at, &mut frames, &mut state);
                } else {
                    state.text("<", &frames);
                    at += 1;
                }
            }
            Some(lt) => {
                state.text(rest.get(..lt).unwrap_or(""), &frames);
                at += lt;
            }
            None => {
                state.text(rest, &frames);
                break;
            }
        }
    }
    while state.text.ends_with('\n') {
        state.text.pop();
    }
    // **A span never reaches past the text**: trimming trailing newlines shortened the text, and the last run may have
    // covered them. (Audit finding, 2026-10-20.)
    let trimmed = state.text.len();
    state.runs.retain_mut(|run| {
        if run.start >= trimmed {
            return false;
        }
        run.len = run.len.min(trimmed - run.start);
        true
    });
    let full_len = state.text.len();
    let all_runs = state.runs.len();
    let mut kept = all_runs;
    let mut cut = full_len;
    if full_len > max_bytes {
        kept = state.runs.iter().take_while(|r| r.start.saturating_add(r.len) <= max_bytes).count();
        cut = if kept == 0 { 0 } else { state.runs.get(kept - 1).map_or(0, |r| r.start + r.len) };
    }
    let kept_by_cap = kept.min(MAX_SPANS);
    let complete = cut == full_len && kept == all_runs;
    state.text.truncate(cut);
    state.runs.truncate(kept_by_cap);
    Projection {
        text: state.text,
        runs: state.runs,
        complete,
        omitted_bytes: (full_len - cut) as u64,
        cut_at: cut as u64,
        // Every run the projection does not carry: those past the budget's cut, and those past the span cap.
        runs_dropped: (all_runs - kept_by_cap) as u64,
    }
}

#[derive(Default)]
struct State {
    text: String,
    runs: Vec<TextRun>,
    /// A whitespace-only node between two inline elements: the space belongs before the next run, not to none.
    pending_space: bool,
}

impl State {
    /// A line boundary, unless everything from here is hidden.
    fn boundary(&mut self, frames: &[Frame]) {
        if frames.last().is_some_and(|f| f.hidden) {
            return;
        }
        if !self.text.is_empty() && !self.text.ends_with('\n') {
            self.text.push('\n');
        }
        self.pending_space = false;
    }

    /// One text node: entities decoded, whitespace collapsed outside `pre`, and one run recorded.
    fn text(&mut self, raw: &str, frames: &[Frame]) {
        let context = frames.last();
        if raw.is_empty() || context.is_some_and(|f| f.hidden) {
            return;
        }
        let decoded = unescape_text(raw);
        let pre = context.is_some_and(|f| f.pre);
        let mut run = String::with_capacity(decoded.len());
        let mut trailing_space = false;
        if pre {
            // **Preformatted text is kept as written**, including a leading or trailing space and indentation. A control
            // character is not text anyone sees: dropped here, it cannot multiply six-fold in the reply's JSON and push a
            // valid projection past its envelope (verification finding, 2026-10-20).
            run.extend(decoded.chars().filter(|c| !c.is_control() || matches!(c, '\n' | '\t')));
        } else {
            let mut space = false;
            for c in decoded.chars() {
                if c.is_control() && !c.is_ascii_whitespace() {
                    continue;
                }
                if c.is_ascii_whitespace() {
                    space = true;
                    continue;
                }
                if space {
                    space = false;
                    let at_line_start = run.is_empty() && (self.text.is_empty() || self.text.ends_with('\n'));
                    if !at_line_start {
                        run.push(' ');
                    }
                }
                run.push(c);
            }
            trailing_space = space;
        }
        if run.is_empty() {
            if trailing_space {
                let at_line_start = self.text.is_empty() || self.text.ends_with('\n');
                self.pending_space = !at_line_start;
            }
            return;
        }
        // **A space between runs is a separator, never part of either run's span**: the leading space of this run, or
        // the one a whitespace-only node left waiting, goes into the text outside the spans. A *trailing* space is kept
        // as a pending separator for the next run, so `<span>one </span><span>two</span>` reads "one two".
        if !pre {
            if let Some(stripped) = run.strip_prefix(' ') {
                if !self.text.is_empty() && !self.text.ends_with('\n') && !self.text.ends_with(' ') {
                    self.text.push(' ');
                }
                run = stripped.to_owned();
                self.pending_space = false;
            } else if self.pending_space {
                self.pending_space = false;
                if !self.text.is_empty() && !self.text.ends_with('\n') && !self.text.ends_with(' ') {
                    self.text.push(' ');
                }
            }
        }
        let start = self.text.len();
        self.text.push_str(&run);
        self.runs.push(TextRun {
            start,
            len: run.len(),
            role: context.and_then(|f| f.role.clone()),
            label: context.and_then(|f| f.label.clone()),
            section: context.and_then(|f| f.section.clone()),
        });
        if trailing_space {
            self.pending_space = true;
        }
    }
}

/// One tag at `at` (which holds `<`): the offset the scan continues from.
fn at_tag(html: &str, at: usize, frames: &mut Vec<Frame>, state: &mut State) -> usize {
    let rest = html.get(at..).unwrap_or("");
    if rest.starts_with("<!--") {
        return rest.get(4..).and_then(|s| s.find("-->")).map_or(html.len(), |e| at + 4 + e + 3);
    }
    if rest.starts_with("<!") || rest.starts_with("<?") {
        return rest.find('>').map_or(html.len(), |e| at + e + 1);
    }
    let Some(end) = tag_end(rest) else {
        // No `>`: what is left is text, not markup.
        state.text(rest, frames);
        return html.len();
    };
    let tag = rest.get(..end).unwrap_or("");
    let after = at + end;
    let inner = tag.get(1..end.saturating_sub(1)).unwrap_or("");
    if let Some(close) = inner.strip_prefix('/') {
        let name = name_of(close);
        if let Some(pos) = frames.iter().rposition(|f| f.name.eq_ignore_ascii_case(name)) {
            let block = frames.get(pos).is_some_and(|f| f.block);
            frames.truncate(pos);
            if block {
                state.boundary(frames);
            }
        }
        return after;
    }
    let name = name_of(inner);
    let lower = name.to_ascii_lowercase();
    if lower == "br" {
        state.boundary(frames);
        return after;
    }
    let attrs = attributes(tag);
    let own_hidden = attrs.iter().any(|(k, _)| k.eq_ignore_ascii_case("hidden"));
    let block = BLOCKS.contains(&lower.as_str());
    let hidden = frames.last().is_some_and(|f| f.hidden) || own_hidden;
    if block && !hidden {
        state.boundary(frames);
    }
    let closed = void(&lower) || tag.get(..end.saturating_sub(1)).is_some_and(|s| s.trim_end().ends_with('/'));
    if SKIPPED.contains(&lower.as_str()) {
        return skip_element(html, after, &lower);
    }
    if closed {
        return after;
    }
    let parent = frames.last();
    let is_pre = lower == "pre";
    frames.push(Frame {
        name: lower,
        // The nearest ancestor's value unless this element writes its own: cached here, never walked again.
        role: attribute(&attrs, "data-xdict-role").or_else(|| parent.and_then(|f| f.role.clone())),
        label: attribute(&attrs, "data-xdict-label").or_else(|| parent.and_then(|f| f.label.clone())),
        section: attribute(&attrs, "data-xdict-section").or_else(|| parent.and_then(|f| f.section.clone())),
        hidden,
        pre: parent.is_some_and(|f| f.pre) || is_pre,
        block,
    });
    after
}

/// The content of a `script`, `style` or `head` starts at `after`: the scan resumes at its end tag, or never.
fn skip_element(html: &str, after: usize, name: &str) -> usize {
    let rest = html.get(after..).unwrap_or("");
    let needle = format!("</{name}");
    find_ascii_case_insensitive(rest, &needle).map_or(html.len(), |e| after + e)
}

/// The first byte offset of `needle` in `haystack`, ignoring ASCII case, without copying the haystack.
fn find_ascii_case_insensitive(haystack: &str, needle: &str) -> Option<usize> {
    haystack
        .char_indices()
        .find(|(i, _)| {
            haystack.get(*i..).and_then(|rest| rest.get(..needle.len())).is_some_and(|s| s.eq_ignore_ascii_case(needle))
        })
        .map(|(i, _)| i)
}

/// The end of the tag starting at the `<` of `s`: after its `>`, respecting quoted attribute values.
fn tag_end(s: &str) -> Option<usize> {
    let mut quote: Option<char> = None;
    for (i, c) in s.char_indices() {
        match quote {
            Some(q) if c == q => quote = None,
            Some(_) => {}
            None if c == '"' || c == '\'' => quote = Some(c),
            None if c == '>' => return Some(i + 1),
            None => {}
        }
    }
    None
}

/// The tag's name, without its closing slash or attributes.
fn name_of(inner: &str) -> &str {
    let s = inner.trim_start_matches('/');
    let n = s.find(|c: char| c.is_ascii_whitespace() || c == '/').unwrap_or(s.len());
    s.get(..n).unwrap_or("")
}

fn attribute(attrs: &[(String, String)], name: &str) -> Option<String> {
    // **A metadata value is a kind, not prose**: the renderer writes short names, and an oversized one is hostile
    // input that would otherwise multiply across spans and the IPC envelope. (Audit finding, 2026-10-20.)
    attrs
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case(name))
        .map(|(_, v)| v.clone())
        .filter(|v| !v.is_empty() && v.len() <= 32)
        // Attributes decode numeric entities, so a value can hold a control character: six bytes each in the reply's
        // JSON, across every span. A kind has no controls in it; the value is refused whole, never trimmed into one.
        .filter(|v| !v.chars().any(char::is_control))
}

#[cfg(test)]
mod tests {
    use super::*;

    type Runs<'a> = Vec<(usize, usize, Option<&'a str>, Option<&'a str>, Option<&'a str>)>;

    fn runs(p: &Projection) -> Runs<'_> {
        p.runs.iter().map(|r| (r.start, r.len, r.role.as_deref(), r.label.as_deref(), r.section.as_deref())).collect()
    }

    #[test]
    fn roles_travel_with_the_text() {
        let p = entry_text_from_html(
            r#"<p><span data-xdict-role="sensenum">1</span> <span data-xdict-role="sense">a body of water</span></p>"#,
            usize::MAX,
        );
        assert_eq!(p.text, "1 a body of water");
        assert_eq!(runs(&p), vec![(0, 1, Some("sensenum"), None, None), (2, 15, Some("sense"), None, None)]);
        assert!(p.complete);
    }

    #[test]
    fn label_and_section_kinds_are_read() {
        let p = entry_text_from_html(
            r#"<div data-xdict-role="section" data-xdict-section="definitions"><span data-xdict-role="label" data-xdict-label="pos">verb</span> run</div>"#,
            usize::MAX,
        );
        assert_eq!(p.text, "verb run");
        // The outer element's own role reaches the text under it; its section kind does too.
        assert_eq!(
            runs(&p),
            vec![
                (0, 4, Some("label"), Some("pos"), Some("definitions")),
                (5, 3, Some("section"), None, Some("definitions"))
            ]
        );
    }

    #[test]
    fn a_metadata_value_with_a_control_character_is_not_a_kind() {
        // Attribute entities decode to controls; six JSON bytes each across every span, so a kind with one is refused.
        let p =
            entry_text_from_html(r#"<span data-xdict-role="label" data-xdict-label="pos&#1;">run</span>"#, usize::MAX);
        assert_eq!(p.text, "run");
        assert_eq!(runs(&p), vec![(0, 3, Some("label"), None, None)]);
    }

    #[test]
    fn an_oversized_metadata_value_is_not_a_kind() {
        let kept = "x".repeat(32);
        let long = "y".repeat(33);
        let p = entry_text_from_html(
            &format!(
                r#"<span data-xdict-role="label" data-xdict-label="{kept}">a</span><span data-xdict-role="label" data-xdict-label="{long}">b</span>"#
            ),
            usize::MAX,
        );
        assert_eq!(p.text, "ab");
        // A value long enough to multiply across every span is hostile input, not a kind: it is dropped, not truncated.
        assert_eq!(runs(&p), vec![(0, 1, Some("label"), Some(kept.as_str()), None), (1, 1, Some("label"), None, None)]);
    }

    #[test]
    fn unclassified_text_is_kept_with_no_role() {
        let p = entry_text_from_html("<div>untouched words</div>", usize::MAX);
        assert_eq!(p.text, "untouched words");
        assert_eq!(runs(&p), vec![(0, 15, None, None, None)]);
    }

    #[test]
    fn scripts_and_styles_are_not_text() {
        let p = entry_text_from_html(
            "<style>p { color: red }</style><p>shown</p><script>alert('no')</script><p>also</p>",
            usize::MAX,
        );
        assert_eq!(p.text, "shown\nalso");
        assert!(!p.text.contains("color"));
        assert!(!p.text.contains("alert"));
    }

    #[test]
    fn entities_decode_as_a_browser_decodes_them_in_content() {
        let p = entry_text_from_html("<p>salt &amp; pepper &#233; &notit; caf&eacute;</p>", usize::MAX);
        assert_eq!(p.text, "salt & pepper é ¬it; café");
    }

    #[test]
    fn control_characters_are_not_text() {
        // Entities can decode to C0 controls, which no reader sees; six JSON bytes each, they could push a permitted
        // projection past the envelope. Dropped like a browser drops them from the accessible text. (Audit finding, 2026-10-20.)
        let p = entry_text_from_html("<p>a&#1;b&#31;c</p><pre>x&#7;y\rz</pre>", usize::MAX);
        assert_eq!(p.text, "abc\nxyz");
        assert!(!p.text.chars().any(|c| c.is_control() && c != '\n' && c != '\t'));
    }

    #[test]
    fn blocks_begin_lines_and_br_breaks_one() {
        let p = entry_text_from_html("<p>one</p><p>two<br>three</p>", usize::MAX);
        assert_eq!(p.text, "one\ntwo\nthree");
    }

    #[test]
    fn hidden_elements_are_not_read() {
        let p = entry_text_from_html(
            r#"<p>seen</p><p hidden data-xdict-role="headword">hidden</p><p>after</p>"#,
            usize::MAX,
        );
        assert_eq!(p.text, "seen\nafter");
        assert!(!p.runs.iter().any(|r| r.role.as_deref() == Some("headword")));
    }

    #[test]
    fn preformatted_text_keeps_its_whitespace() {
        let p = entry_text_from_html("<pre>a  b\n c</pre>", usize::MAX);
        assert_eq!(p.text, "a  b\n c");
    }

    #[test]
    fn whitespace_collapses_outside_pre() {
        let p = entry_text_from_html("<p>a\n   b\t\tc</p>", usize::MAX);
        assert_eq!(p.text, "a b c");
    }

    #[test]
    fn multibyte_text_counts_bytes_and_cuts_on_a_run_boundary() {
        let html =
            r#"<p><span data-xdict-role="sense">词典</span></p><p><span data-xdict-role="example">例</span></p>"#;
        let full = entry_text_from_html(html, usize::MAX);
        assert_eq!(full.text, "词典\n例");
        assert_eq!(full.runs.first().map(|r| r.len), Some(6));
        // A budget that ends after the first run keeps it whole.
        let p = entry_text_from_html(html, 7);
        assert_eq!(p.text, "词典");
        assert!(!p.complete);
        assert_eq!(p.cut_at, 6);
        assert_eq!(p.omitted_bytes, 4);
        assert_eq!(p.runs_dropped, 1);
    }

    #[test]
    fn a_cut_reports_what_it_left_out() {
        let html =
            r#"<p><span data-xdict-role="sense">first</span></p><p><span data-xdict-role="example">second</span></p>"#;
        let full = entry_text_from_html(html, usize::MAX);
        assert_eq!(full.text, "first\nsecond");
        let p = entry_text_from_html(html, 6);
        assert_eq!(p.text, "first");
        assert!(!p.complete);
        assert_eq!(p.cut_at, 5);
        assert_eq!(p.omitted_bytes, 7);
        assert_eq!(p.runs_dropped, 1);
        assert_eq!(full.runs.len(), 2);
    }

    #[test]
    fn a_zero_budget_is_data_not_an_error() {
        let p = entry_text_from_html("<p>text</p>", 0);
        assert_eq!(p.text, "");
        assert!(!p.complete);
        assert_eq!(p.omitted_bytes, 4);
        assert_eq!(p.cut_at, 0);
        assert_eq!(p.runs_dropped, 1);
    }

    #[test]
    fn a_budget_exactly_at_the_end_is_complete() {
        let html = "<p>alone</p>";
        let full = entry_text_from_html(html, usize::MAX);
        let p = entry_text_from_html(html, full.text.len());
        assert_eq!(p.text, "alone");
        assert!(p.complete);
        assert_eq!(p.omitted_bytes, 0);
        assert_eq!(p.runs_dropped, 0);
    }

    #[test]
    fn uppercase_markup_is_read_alike() {
        let p = entry_text_from_html(r#"<P>One</P><BR><P>Two</P>"#, usize::MAX);
        assert_eq!(p.text, "One\nTwo");
    }

    #[test]
    fn a_space_at_the_end_of_a_run_is_kept() {
        let p = entry_text_from_html("<span>one </span><span>two</span>", usize::MAX);
        assert_eq!(p.text, "one two");
        assert_eq!(runs(&p), vec![(0, 3, None, None, None), (4, 3, None, None, None)]);
    }

    #[test]
    fn a_literal_less_than_is_text() {
        let p = entry_text_from_html("<p>1 < 2</p>", usize::MAX);
        assert_eq!(p.text, "1 < 2");
    }

    #[test]
    fn trimming_leaves_no_span_past_the_text() {
        let p = entry_text_from_html("<pre>a\n</pre>", usize::MAX);
        assert_eq!(p.text, "a");
        assert!(p.runs.iter().all(|r| r.start + r.len <= p.text.len()), "{:?}", p.runs);
    }

    #[test]
    fn pre_keeps_its_spacing_and_starts_a_line() {
        let p = entry_text_from_html("<p>before</p><pre>  indented</pre>", usize::MAX);
        assert_eq!(p.text, "before\n  indented");
    }

    #[test]
    fn table_headers_start_a_line() {
        let p = entry_text_from_html("<tr><th>head</th><td>cell</td></tr>", usize::MAX);
        assert_eq!(p.text, "head\ncell");
    }

    #[test]
    fn deep_nesting_is_read_without_walking_it_per_node() {
        let mut html = String::new();
        for _ in 0..2_000 {
            html.push_str("<div>");
        }
        html.push_str("deep");
        for _ in 0..2_000 {
            html.push_str("</div>");
        }
        let p = entry_text_from_html(&html, usize::MAX);
        assert_eq!(p.text, "deep");
    }

    #[test]
    fn spans_are_capped_and_dropped_are_counted() {
        let mut html = String::new();
        for _ in 0..(MAX_SPANS + 500) {
            html.push_str("<span>a</span> ");
        }
        let p = entry_text_from_html(&html, usize::MAX);
        assert_eq!(p.runs.len(), MAX_SPANS);
        assert_eq!(p.runs_dropped as usize, 500);
    }
}
