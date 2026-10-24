//! **An entry as plain text, whole, for a consumer that reads it** (ADR-0021 d.5, plan-ai-meaning WI-1): the
//! roles-marked HTML [`crate::entry_normalized_within`] writes, projected to text with one span per run back to its
//! roles, and a byte budget that reports its own cut. Nothing here decides structure a second time: the attributes the
//! renderer wrote (`data-xdict-role`, `data-xdict-label`, `data-xdict-section`, `hidden`) are read as they are, and
//! text the rules did not classify is kept, marked with no role.

use std::collections::BTreeMap;

use crate::rewrite::unescape_text;
use crate::roles::{attributes, void};

/// One run of the entry's text and where it came from: offsets in UTF-8 bytes of [`Projection::text`], the
/// nearest role, label kind and section kind written around it — none for text the rules did not classify — and
/// the innermost sense containing it, when the markup names one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TextRun {
    pub start: usize,
    pub len: usize,
    pub role: Option<String>,
    pub label: Option<String>,
    pub section: Option<String>,
    /// The id of the innermost sense container this run lies in (ADR-0029 d.2).
    pub sense: Option<u32>,
}

/// One sense the entry's markup names (`data-xdict-sense`): its ordinal, its canonical byte range in
/// [`Projection::text`], the label as printed, its section, its parent and whether the projection carries it whole
/// (ADR-0029 d.2, d.3). The range includes the printed label, definitions, examples, translations, nested children
/// and the separators between them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Sense {
    pub id: u32,
    pub start: usize,
    pub len: usize,
    /// The printed sense label (the sense-number text), or none when it is not text (CSS counters) or was cut.
    pub label: Option<String>,
    pub section: Option<String>,
    /// The id of the nearest ancestor sense, or none for a top-level sense.
    pub parent: Option<u32>,
    /// True only when the whole range is in `text` and none of its runs was dropped by the span cap.
    pub whole: bool,
}

/// An entry's text under its budget, and what the budget left out.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Projection {
    pub text: String,
    pub runs: Vec<TextRun>,
    /// The senses the markup names, in document order (ADR-0029 d.2). Empty for markup that names none.
    pub senses: Vec<Sense>,
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

/// A sense while it is being followed: its range begins at its first element and ends where the next sense at its
/// level, an end marker or its scope element ends it (ADR-0029 d.2). Its runs carry the innermost open sense, so text
/// between two elements of a run is covered as the reader sees it.
struct Draft {
    id: u32,
    start: usize,
    end: usize,
    parent: Option<u32>,
    label: Option<String>,
    section: Option<String>,
    /// The element depth the run started at: its parent's close ends it.
    scope_depth: usize,
    /// A run head reaches into its following siblings, so an explicit end marker ends it; a container holds its own
    /// element and only that element's close ends it (verification finding, 2026-10-23).
    run: bool,
    closed: bool,
}

/// The most spans one projection carries: 16,384 runs of JSON stay far inside the 4 MB IPC envelope, while a text of
/// 200,000 one-character spans would not. Spans past this are dropped and counted. (Audit finding, 2026-10-20.)
pub const MAX_SPANS: usize = 4_096;

/// **The most senses one projection carries.** An untrusted entry can name a sense on every element; without a cap its
/// sense list alone would push the reply past the IPC envelope. Well past any real entry (the corpus's largest has
/// hundreds), and the text budget usually binds first. Past this, later sense ids are ignored — their text stays in the
/// projection with the enclosing sense's membership, as unclassified text does.
pub const MAX_SENSES: usize = 16_384;

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
    // **A sense still open at the end of the document ends with it**: malformed markup closes nothing, and a range
    // must never reach past the text it was opened in. (ADR-0029 d.2.)
    close_all(&mut state);
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
    // **A sense whose run the span cap dropped is not whole**, even though its text is still in `text`: the shell
    // cannot prove membership for it, and a target it cannot bind is not a target. The drop reaches every ancestor.
    // (ADR-0029 d.2.)
    let mut dropped_sense = vec![false; state.senses.len()];
    for run in state.runs.iter().skip(kept_by_cap) {
        let mut at = run.sense.and_then(|id| state.by_id.get(&id).copied());
        while let Some(index) = at {
            let Some(draft) = state.senses.get(index) else { break };
            let already = dropped_sense.get(index).copied().unwrap_or(true);
            if let Some(slot) = dropped_sense.get_mut(index) {
                *slot = true;
            }
            if already {
                // Already marked with its ancestors: nothing above can be unmarked.
                break;
            }
            at = draft.parent.and_then(|id| state.by_id.get(&id).copied());
        }
    }
    let complete = cut == full_len && kept == all_runs;
    // The label is the sense's own printed number: the first `sensenum` run in its own text, before the cut.
    let senses: Vec<Sense> = state
        .senses
        .iter()
        .enumerate()
        .map(|(index, draft)| {
            // **A range never points past the text it describes**: a sense beyond the cut keeps only the part the
            // shell actually has, and `whole` carries the rest of the truth.
            let raw_end = draft.end.min(trimmed);
            let start = draft.start.min(cut);
            let end = raw_end.min(cut);
            // The label the renderer wrote, else the first sense number seen in the run.
            let label = draft.label.clone().or_else(|| state.labels_seen.get(&draft.id).cloned());
            Sense {
                id: draft.id,
                start,
                len: end.saturating_sub(start),
                label,
                section: draft.section.clone(),
                parent: draft.parent,
                whole: raw_end <= cut && !dropped_sense.get(index).copied().unwrap_or(true),
            }
        })
        .collect();
    state.text.truncate(cut);
    state.runs.truncate(kept_by_cap);
    Projection {
        text: state.text,
        runs: state.runs,
        senses,
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
    /// The senses seen so far, in document order, and the ones open now (outermost first): a repeated element of a
    /// run is the same sense, and a closed id that appears again is ignored (ADR-0029 d.2).
    senses: Vec<Draft>,
    /// An id's draft, so a repeat costs a lookup rather than a scan: an entry naming a sense on every element must not
    /// turn the projection quadratic (audit finding, 2026-10-22).
    by_id: BTreeMap<u32, usize>,
    /// The first printed sense number seen per sense, for markup that names a container but not its label.
    labels_seen: BTreeMap<u32, String>,
    open: Vec<usize>,
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
        let role = context.and_then(|f| f.role.clone());
        let sense = self.open.last().and_then(|&i| self.senses.get(i)).map(|d| d.id);
        // **The first sense number of each sense**, kept here so the final pass looks up a label rather than scanning
        // every run per sense (audit finding, 2026-10-22).
        if let Some(id) = sense
            && role.as_deref() == Some("sensenum")
            && run.len() <= 32
            && !self.labels_seen.contains_key(&id)
        {
            self.labels_seen.insert(id, run.trim().to_owned());
        }
        self.runs.push(TextRun {
            start,
            len: run.len(),
            role,
            label: context.and_then(|f| f.label.clone()),
            section: context.and_then(|f| f.section.clone()),
            sense,
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
            // **A run ends with the element that held it**, before the block boundary that follows: that newline
            // belongs to what comes next, not to the sense. (ADR-0029 d.2.)
            close_scoped(state, frames.len(), false);
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
    // The nearest ancestor's value unless this element writes its own: cached here, never walked again. **Inside an
    // example or a translation, a nested role that is part of its text — a link, a label, a subhead — takes the
    // example's or the translation's role** (the audit, 2026-10-24): the renderer's links inside COBUILD's and OALECD's
    // examples carried their own roles, so the example's span began at the first link's end and paired a sentence's
    // tail with its whole translation. A gloss (`keep`) and a translation inside an example stay themselves.
    // The sure mark is the renderer's own (`roles.rs`): `keep` says the element keeps the dictionary's look inside a
    // sure example and is apparatus, not the example's text; `trans` names a Chinese block. It is not a role value
    // and the projection must not read it as one (audit, 2026-10-24): a kept gloss with no role stayed out of the
    // inherited example role instead of joining its English.
    let sure = attribute(&attrs, "data-xdict-sure");
    let kept = sure.as_deref() == Some("keep");
    let own = attribute(&attrs, "data-xdict-role").or_else(|| match sure.as_deref() {
        Some("keep") | None => None,
        Some(mark) => Some(mark.to_owned()),
    });
    let inherited = parent.and_then(|f| f.role.clone());
    let role = if kept {
        own
    } else {
        match own {
            Some(own)
                if matches!(inherited.as_deref(), Some("example" | "example-trans" | "trans"))
                    && !matches!(own.as_str(), "trans" | "example-trans" | "example") =>
            {
                inherited
            }
            Some(own) => Some(own),
            None => inherited,
        }
    };
    let label = attribute(&attrs, "data-xdict-label").or_else(|| parent.and_then(|f| f.label.clone()));
    let section = attribute(&attrs, "data-xdict-section").or_else(|| parent.and_then(|f| f.section.clone()));
    let pre = parent.is_some_and(|f| f.pre) || is_pre;
    // **The end marker**: every run at this level has ended; the element that follows is not part of it.
    if attrs.iter().any(|(k, _)| k.eq_ignore_ascii_case("data-xdict-sense-end")) {
        close_scoped(state, frames.len(), true);
    }
    // **A sense start**: a new id opens a run at this point; an element repeating an open run's id is that run, and a
    // closed id that appears again is ignored (ADR-0029 d.2).
    if let Some(id) = attribute(&attrs, "data-xdict-sense").and_then(|value| parse_sense_id(&value)) {
        open_sense(state, frames.len(), id, &attrs, section.as_deref());
    }
    frames.push(Frame { name: lower, role, label, section, hidden, pre, block });
    after
}

/// A sense id from `data-xdict-sense`: ASCII digits, 1 based, bounded. Anything else names no sense.
fn parse_sense_id(value: &str) -> Option<u32> {
    if value.is_empty() || value.len() > 7 || !value.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    value.parse::<u32>().ok().filter(|id| (1..=1_000_000).contains(id))
}

/// **A sense starts here**: its range begins at the text written so far, after the boundary that opened the block.
/// The runs it is not inside end here; the label and parent are the renderer's own, never guessed.
fn open_sense(state: &mut State, depth: usize, id: u32, attrs: &[(String, String)], section: Option<&str>) {
    // **A repeat is the same sense**; past the cap a new id is not carried at all, and — because the run that was open
    // ends here — its text belongs to no sense, never to the one before it (verification finding, 2026-10-23).
    if state.by_id.contains_key(&id) {
        return;
    }
    if state.senses.len() >= MAX_SENSES {
        let now = current_end(state);
        let open = std::mem::take(&mut state.open);
        for index in open {
            close_draft(state, index, now);
        }
        return;
    }
    // **The renderer's parent is final**: 0 (or no attribute) is a top-level sense, and an id names that sense. The
    // projection never invents a parent from whatever run happens to be open.
    let parent = match attribute(attrs, "data-xdict-sense-parent") {
        Some(raw) if raw == "0" => None,
        Some(raw) => parse_sense_id(&raw).filter(|parent| *parent != id && state.by_id.contains_key(parent)),
        None => None,
    };
    // The runs still open that are this sense's ancestors stay; the rest end where it starts.
    let mut ancestors = Vec::new();
    let mut at = parent;
    while let Some(parent) = at {
        if ancestors.contains(&parent) {
            break;
        }
        ancestors.push(parent);
        at = state.by_id.get(&parent).and_then(|index| state.senses.get(*index)).and_then(|d| d.parent);
    }
    // **A separator between senses is not part of either**: a block boundary emitted just before this start stays
    // outside the sense that ends there, while the new sense begins after it.
    let end_now = current_end(state);
    let start_now = state.text.len();
    let open = std::mem::take(&mut state.open);
    for index in open {
        if state.senses.get(index).is_some_and(|d| ancestors.contains(&d.id)) {
            state.open.push(index);
        } else {
            close_draft(state, index, end_now);
        }
    }
    // **A run head ends with its parent; a container ends with itself** (the renderer says which). The container's
    // own close is one depth deeper than the parent's.
    let run = attrs.iter().any(|(key, _)| key.eq_ignore_ascii_case("data-xdict-sense-run"));
    let index = state.senses.len();
    state.senses.push(Draft {
        id,
        start: start_now,
        end: start_now,
        parent,
        label: attribute(attrs, "data-xdict-sense-label").filter(|v| v.len() <= 32),
        section: section.map(str::to_owned),
        scope_depth: if run { depth } else { depth + 1 },
        run,
        closed: false,
    });
    state.by_id.insert(id, index);
    state.open.push(index);
}

/// Ends one draft at `at`, once.
fn close_draft(state: &mut State, index: usize, at: usize) {
    if let Some(draft) = state.senses.get_mut(index)
        && !draft.closed
    {
        draft.end = at;
        draft.closed = true;
    }
}

/// Ends every run whose scope element is now closed. An end marker ends the runs at its own level; a closing element
/// ends the runs and containers whose scope was inside it. **A container is never ended by a marker**: the renderer
/// writes one where a run reaches no further, and the container's element still holds what follows
/// (verification finding, 2026-10-23).
fn close_scoped(state: &mut State, depth: usize, explicit: bool) {
    let now = current_end(state);
    let open = std::mem::take(&mut state.open);
    for index in open {
        let scoped = state
            .senses
            .get(index)
            .is_some_and(|d| if explicit { d.run && d.scope_depth >= depth } else { d.scope_depth > depth });
        if scoped {
            close_draft(state, index, now);
        } else {
            state.open.push(index);
        }
    }
}

/// Ends every run at the end of the document.
fn close_all(state: &mut State) {
    let now = current_end(state);
    let open = std::mem::take(&mut state.open);
    for index in open {
        close_draft(state, index, now);
    }
}

/// Where a sense ends now: a block boundary's final newline is the separator before what comes next, not part of the
/// sense that ends here.
fn current_end(state: &State) -> usize {
    if state.text.ends_with('\n') { state.text.len() - 1 } else { state.text.len() }
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
    // The workspace forbids these in library code; a test asserts by failing, which is the point.
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

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
    fn a_nested_role_inside_an_example_takes_the_examples_role() {
        let p = entry_text_from_html(
            r#"<span data-xdict-role="example">You <a data-xdict-role="label">can</a> bet that he will come. <span data-xdict-sure="keep">(a gloss)</span><span data-xdict-role="example-trans">他肯定会来。</span></span>"#,
            usize::MAX,
        );
        let roles: Vec<Option<&str>> = p.runs.iter().map(|r| r.role.as_deref()).collect();
        assert_eq!(roles, vec![Some("example"), Some("example"), Some("example"), None, Some("example-trans")]);
        assert_eq!(p.text, "You can bet that he will come. (a gloss)他肯定会来。");
        let p = entry_text_from_html(
            r#"<span data-xdict-role="trans">中文 <a data-xdict-role="headword">链接</a></span>"#,
            usize::MAX,
        );
        let roles: Vec<Option<&str>> = p.runs.iter().map(|r| r.role.as_deref()).collect();
        assert_eq!(roles, vec![Some("trans"), Some("trans")]);
        // The renderer's other sure mark names the Chinese block, which the example must not swallow.
        let p = entry_text_from_html(
            r#"<span data-xdict-role="example">He came. <span data-xdict-sure="trans">他来了。</span></span>"#,
            usize::MAX,
        );
        let roles: Vec<Option<&str>> = p.runs.iter().map(|r| r.role.as_deref()).collect();
        assert_eq!(roles, vec![Some("example"), Some("trans")]);
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

    #[test]
    fn senses_carry_a_range_a_label_and_their_runs() {
        let html = r#"<div data-xdict-role="sense" data-xdict-sense="1"><span data-xdict-role="sensenum">1</span> <span data-xdict-role="def">a body of water</span></div><div data-xdict-role="sense" data-xdict-sense="2"><span data-xdict-role="sensenum">2</span> <span data-xdict-role="def">to move fast</span></div>"#;
        let p = entry_text_from_html(html, usize::MAX);
        assert_eq!(p.text, "1 a body of water\n2 to move fast");
        assert_eq!(p.senses.len(), 2);
        let first = p.senses.first().unwrap();
        assert_eq!((first.id, first.start, first.len), (1, 0, 17));
        assert_eq!(first.label.as_deref(), Some("1"));
        assert_eq!(first.parent, None);
        assert!(first.whole);
        let second = p.senses.get(1).unwrap();
        assert_eq!((second.id, second.start, second.len), (2, 18, 14));
        assert_eq!(second.label.as_deref(), Some("2"));
        assert!(second.whole);
        // Membership is the innermost sense, projected — never guessed from the text.
        let senses: Vec<Option<u32>> = p.runs.iter().map(|r| r.sense).collect();
        assert_eq!(senses, vec![Some(1), Some(1), Some(2), Some(2)]);
    }

    #[test]
    fn a_nested_sense_names_its_parent_and_is_contained_by_it() {
        let p = entry_text_from_html(
            r#"<div data-xdict-sense="1" data-xdict-sense-parent="0"><span data-xdict-sense="2" data-xdict-sense-parent="1">inner</span> outer</div>"#,
            usize::MAX,
        );
        assert_eq!(p.text, "inner outer");
        let outer = p.senses.first().unwrap();
        let inner = p.senses.get(1).unwrap();
        assert_eq!((outer.id, outer.start, outer.len), (1, 0, 11));
        assert_eq!((inner.id, inner.start, inner.len), (2, 0, 5));
        assert_eq!(inner.parent, Some(1));
        assert_eq!(p.runs.first().and_then(|r| r.sense), Some(2));
        assert_eq!(p.runs.last().and_then(|r| r.sense), Some(1));
    }

    #[test]
    fn a_duplicate_sense_id_is_not_a_second_sense() {
        let p =
            entry_text_from_html(r#"<div data-xdict-sense="1">a</div><div data-xdict-sense="1">b</div>"#, usize::MAX);
        assert_eq!(p.text, "a\nb");
        assert_eq!(p.senses.len(), 1);
        assert_eq!(p.senses.first().map(|s| s.len), Some(1));
    }

    #[test]
    fn a_zero_or_forged_sense_id_names_no_sense() {
        for id in ["0", "-1", "1.1", "x", ""] {
            let p = entry_text_from_html(&format!(r#"<div data-xdict-sense="{id}">a</div>"#), usize::MAX);
            assert!(p.senses.is_empty(), "{id:?} named a sense");
        }
    }

    #[test]
    fn a_sense_the_budget_cut_is_not_whole() {
        let html = r#"<div data-xdict-sense="1">first</div><div data-xdict-sense="2">second</div>"#;
        let p = entry_text_from_html(html, 6);
        assert_eq!(p.text, "first");
        assert!(p.senses.first().is_some_and(|s| s.whole));
        assert!(p.senses.get(1).is_some_and(|s| !s.whole));
        // The cut sense has no text of its own in the projection: its range is empty, and it says so.
        assert_eq!(p.senses.get(1).map(|s| s.len), Some(0));
    }

    #[test]
    fn a_sense_past_the_span_cap_is_not_whole() {
        let mut html = String::from(r#"<div data-xdict-sense="1">"#);
        for _ in 0..(MAX_SPANS + 1) {
            html.push_str("<span>a</span> ");
        }
        html.push_str("</div>");
        let p = entry_text_from_html(&html, usize::MAX);
        assert_eq!(p.runs.len(), MAX_SPANS);
        assert!(p.senses.first().is_some_and(|s| !s.whole), "a dropped run makes its sense unbound");
    }

    #[test]
    fn a_sense_without_a_printed_number_has_no_label() {
        let p = entry_text_from_html(r#"<div data-xdict-sense="1">a body</div>"#, usize::MAX);
        assert_eq!(p.senses.first().and_then(|s| s.label.as_deref()), None);
    }

    #[test]
    fn two_dictionaries_may_print_the_same_ordinal_differently() {
        // The label is what the reader's dictionary printed, not the ordinal restated in one house style.
        let a = entry_text_from_html(
            r#"<div data-xdict-sense="1" data-xdict-sense-label="1." data-xdict-sense-parent="0">a</div>"#,
            usize::MAX,
        );
        let b = entry_text_from_html(
            r#"<div data-xdict-sense="1" data-xdict-sense-label="①" data-xdict-sense-parent="0">b</div>"#,
            usize::MAX,
        );
        assert_eq!(a.senses.first().and_then(|s| s.label.as_deref()), Some("1."));
        assert_eq!(b.senses.first().and_then(|s| s.label.as_deref()), Some("①"));
    }

    #[test]
    fn a_sense_covers_the_text_between_its_elements() {
        // `one <em>two</em> three`: the space between the runs and the inner element's text are the same sense.
        let p = entry_text_from_html(
            r#"<div data-xdict-sense="1" data-xdict-sense-parent="0" data-xdict-sense-run>one <em>two</em> three</div>"#,
            usize::MAX,
        );
        assert_eq!(p.text, "one two three");
        let first = p.senses.first().unwrap();
        assert_eq!((first.start, first.len), (0, 13));
        assert!(p.runs.iter().all(|run| run.sense == Some(1)));
    }

    #[test]
    fn an_end_marker_ends_a_run_but_not_its_container() {
        // A heading between a run and the rest of its container ends the run and nothing else: the container's
        // element still holds the heading's text and what follows (verification finding, 2026-10-23).
        let p = entry_text_from_html(
            r#"<div data-xdict-sense="1"><span data-xdict-sense="2" data-xdict-sense-parent="1" data-xdict-sense-run>a</span><h4 data-xdict-sense-end>note</h4>tail</div>"#,
            usize::MAX,
        );
        assert_eq!(p.text, "a\nnote\ntail");
        let outer = p.senses.first().unwrap();
        let inner = p.senses.get(1).unwrap();
        assert_eq!((outer.id, outer.start, outer.len), (1, 0, 11));
        assert_eq!((inner.id, inner.start, inner.len), (2, 0, 1));
        assert_eq!(p.text.get(outer.start..outer.start + outer.len), Some("a\nnote\ntail"));
        assert_eq!(p.text.get(inner.start..inner.start + inner.len), Some("a"));
        assert!(outer.whole && inner.whole);
    }

    #[test]
    fn a_shared_label_before_the_sense_is_not_part_of_it() {
        // A part of speech above the senses is shared, and the sense begins where its own text does.
        let p = entry_text_from_html(
            r#"<span data-xdict-role="pos">verb</span> <span data-xdict-sense="1" data-xdict-sense-parent="0" data-xdict-sense-run>to move</span>"#,
            usize::MAX,
        );
        // The separator between the shared label and the sense is the sense's leading edge, as the ADR says ranges
        // include their separators.
        let first = p.senses.first().unwrap();
        assert_eq!(first.start, 4);
        assert_eq!(first.len, 8);
    }
}
