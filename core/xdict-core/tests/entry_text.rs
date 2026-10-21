//! The whole-entry text projection through the core (ADR-0021 d.5, plan-ai-meaning WI-1): the same render `entry` gives,
//! as plain text with spans, completeness and the budget's cut; the guards the entry view has.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

use xdict_core::*;
use xdict_mdx_writer::{self as writer, Entry as W, Spec};

/// Enough of a sheet that the roles have markers to classify; the text is what this test reads.
const SHEET: &str = ".fbm_NOAD { margin: 0 }\nspan.ph { font-weight: normal }\nspan.sense { display: block }";

const BODY: &str = r#"<div class="entry"><span class="hw">run</span><span class="sense"><span class="se">move fast</span><span class="ex">she ran home</span></span><p>a paragraph the rules do not know</p></div>"#;

struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let n = NEXT.fetch_add(1, Ordering::SeqCst);
        let dir = std::env::temp_dir().join(format!("xdict-entry-text-{name}-{}-{n}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        Self(dir)
    }

    fn at(&self, name: &str) -> Location {
        Location::Path { path: self.0.join(name).to_string_lossy().into() }
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn opened(dir: &Scratch) -> (Core, String, String) {
    let entries = [W::text("run", BODY), W::text("walk", "<b>walk</b> on foot")];
    std::fs::write(dir.0.join("noad.mdx"), writer::write(&Spec::mdx(), &entries).unwrap()).unwrap();
    std::fs::write(dir.0.join("noad.css"), SHEET).unwrap();
    let package = Package { mdx: dir.at("noad.mdx"), mdd: vec![], sidecars: vec![dir.at("noad.css")] };
    let core = Core::new(Config { client_protocol: PROTOCOL, ..Config::default() }).unwrap();
    let imported = core.import(package.clone(), &NoProgress).unwrap();
    match core.open(package).unwrap() {
        Opened::Ready { dict, .. } => (core, dict, imported.edition),
        other => panic!("not open: {other:?}"),
    }
}

fn view(max_text_bytes: u64) -> TextView {
    TextView { base_url: "xdict://d/".into(), max_body_bytes: 1 << 20, max_text_bytes, original_style: false }
}

fn reference(edition: &str, key: &str) -> EntryRef {
    EntryRef { edition: edition.into(), key: key.into(), occurrence: 0 }
}

#[test]
fn the_whole_entry_comes_back_as_text_with_its_spans() {
    let dir = Scratch::new("whole");
    let (core, dict, edition) = opened(&dir);
    let got = core.entry_text(dict, reference(&edition, "run"), view(u64::MAX)).unwrap();
    assert_eq!(got.entry, reference(&edition, "run"), "the edition, key and occurrence are echoed");
    assert!(got.complete);
    assert_eq!(got.omitted_bytes, 0);
    assert_eq!(got.spans_dropped, 0);
    assert!(got.text.contains("run"), "{}", got.text);
    assert!(got.text.contains("move fast"), "{}", got.text);
    assert!(got.text.contains("she ran home"), "{}", got.text);
    assert!(got.text.contains("a paragraph the rules do not know"), "{}", got.text);
    assert!(!got.spans.is_empty(), "an entry with text has spans");
    for span in &got.spans {
        let start = usize::try_from(span.start).unwrap();
        let len = usize::try_from(span.len).unwrap();
        assert!(start + len <= got.text.len(), "a span past the text: {span:?}");
        assert!(got.text.is_char_boundary(start) && got.text.is_char_boundary(start + len), "a span split a character");
    }
}

#[test]
fn a_budget_cut_is_data_and_reports_what_it_left_out() {
    let dir = Scratch::new("cut");
    let (core, dict, edition) = opened(&dir);
    let whole = core.entry_text(dict.clone(), reference(&edition, "run"), view(u64::MAX)).unwrap();
    let budget = (whole.text.len() / 2) as u64;
    let cut = core.entry_text(dict.clone(), reference(&edition, "run"), view(budget)).unwrap();
    assert!(!cut.complete);
    assert_eq!(cut.text.len() as u64, cut.cut_at);
    assert_eq!(cut.omitted_bytes, whole.text.len() as u64 - cut.text.len() as u64);
    assert!(cut.spans_dropped > 0, "a cut leaves runs out: {} of {}", cut.spans_dropped, whole.spans.len());
    assert!(whole.text.starts_with(&cut.text));
    assert!(cut.spans.len() <= whole.spans.len());

    let zero = core.entry_text(dict, reference(&edition, "run"), view(0)).unwrap();
    assert!(zero.text.is_empty());
    assert!(!zero.complete);
    assert_eq!(zero.omitted_bytes, whole.text.len() as u64);
    assert_eq!(zero.cut_at, 0);
    assert_eq!(zero.spans_dropped, whole.spans.len() as u64);
}

#[test]
fn a_budget_at_the_end_is_complete() {
    let dir = Scratch::new("exact");
    let (core, dict, edition) = opened(&dir);
    let whole = core.entry_text(dict.clone(), reference(&edition, "run"), view(u64::MAX)).unwrap();
    let exact = core.entry_text(dict, reference(&edition, "run"), view(whole.text.len() as u64)).unwrap();
    assert!(exact.complete);
    assert_eq!(exact.text, whole.text);
    assert_eq!(exact.omitted_bytes, 0);
    assert_eq!(exact.spans, whole.spans);
}

#[test]
fn the_guards_are_the_entry_views() {
    let dir = Scratch::new("guards");
    let (core, dict, edition) = opened(&dir);
    let wrong = reference("mdx-sha256-v1:not-this-edition", "run");
    assert!(matches!(core.entry_text(dict.clone(), wrong, view(u64::MAX)), Err(CoreError::EditionMismatch { .. })));
    let missing = EntryRef { edition: edition.clone(), key: "run".into(), occurrence: 7 };
    assert!(matches!(core.entry_text(dict.clone(), missing, view(u64::MAX)), Err(CoreError::NotFound { .. })));
    let small =
        TextView { base_url: "xdict://d/".into(), max_body_bytes: 16, max_text_bytes: u64::MAX, original_style: false };
    assert!(matches!(
        core.entry_text(dict.clone(), reference(&edition, "run"), small),
        Err(CoreError::TooLarge { limit: Limit::Body, .. })
    ));
    // The entry view itself still answers as before the render was shared.
    let entry = core.entry(
        dict,
        reference(&edition, "run"),
        View { base_url: "xdict://d/".into(), max_body_bytes: 1 << 20, original_style: false },
    );
    assert!(!entry.unwrap().html.is_empty());
}
