//! **One entry's brief gloss through the core** (ADR-0037, contract 21): the first sense's definition or translation,
//! resolved by the recorded edition, with the core fixing the view. No text is data; a missing edition or entry is the
//! same typed answer the entry view gives.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

use xdict_core::*;
use xdict_mdx_writer::{self as writer, Entry as W, Spec};

/// Enough of a sheet that the roles have markers to classify; the text is what this test reads.
const SHEET: &str = ".fbm_NOAD { margin: 0 }\nspan.ph { font-weight: normal }\nspan.sense { display: block }";

struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let n = NEXT.fetch_add(1, Ordering::SeqCst);
        let dir = std::env::temp_dir().join(format!("xdict-entry-gloss-{name}-{}-{n}", std::process::id()));
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

fn package(dir: &Scratch, name: &str, body: &str) -> Package {
    std::fs::write(dir.0.join(name), writer::write(&Spec::mdx(), &[W::text("run", body)]).unwrap()).unwrap();
    std::fs::write(dir.0.join("noad.css"), SHEET).unwrap();
    Package { mdx: dir.at(name), mdd: vec![], sidecars: vec![dir.at("noad.css")] }
}

fn opened(dir: &Scratch, name: &str, body: &str) -> (Core, String, String) {
    let package = package(dir, name, body);
    let core = Core::new(Config { client_protocol: PROTOCOL, ..Config::default() }).unwrap();
    let imported = core.import(package.clone(), &NoProgress).unwrap();
    match core.open(package).unwrap() {
        Opened::Ready { dict, .. } => (core, dict, imported.edition),
        other => panic!("not open: {other:?}"),
    }
}

fn reference(edition: &str, key: &str) -> EntryRef {
    EntryRef { edition: edition.into(), key: key.into(), occurrence: 0 }
}

#[test]
fn the_first_definition_comes_back_as_the_gloss() {
    let dir = Scratch::new("first");
    let (core, _dict, edition) = opened(&dir, "noad.mdx", "<b>run</b> to move fast");
    let gloss = core.entry_gloss(reference(&edition, "run")).unwrap();
    assert_eq!(gloss.entry, reference(&edition, "run"), "the edition, key and occurrence are echoed");
    assert_eq!(gloss.text.as_deref(), Some("to move fast"));
    assert_eq!(gloss.source, Some(GlossSource::Definition));
    assert!(!gloss.truncated);
}

#[test]
fn an_entry_with_no_definition_answers_no_text_rather_than_an_error() {
    let dir = Scratch::new("none");
    let (core, _dict, edition) = opened(&dir, "noad.mdx", "<b>run</b>");
    let gloss = core.entry_gloss(reference(&edition, "run")).unwrap();
    assert_eq!(gloss.text, None);
    assert_eq!(gloss.source, None);
    assert!(!gloss.truncated);
}

#[test]
fn an_edition_that_is_not_open_is_a_not_found() {
    let dir = Scratch::new("edition");
    let (core, _dict, _edition) = opened(&dir, "noad.mdx", "<b>run</b> to move fast");
    let missing = reference("mdx-sha256-v1:not-this-edition", "run");
    assert!(matches!(core.entry_gloss(missing), Err(CoreError::NotFound { what: Missing::Edition, .. })));
}

#[test]
fn a_missing_entry_is_a_not_found() {
    let dir = Scratch::new("entry");
    let (core, _dict, edition) = opened(&dir, "noad.mdx", "<b>run</b> to move fast");
    assert!(matches!(
        core.entry_gloss(reference(&edition, "nope")),
        Err(CoreError::NotFound { what: Missing::Entry, .. })
    ));
}

#[test]
fn two_editions_of_the_same_key_never_share_a_gloss() {
    let dir = Scratch::new("editions");
    let one_package = package(&dir, "one.mdx", "<b>run</b> to move fast");
    let two_package = package(&dir, "two.mdx", "<b>run</b> to go quickly");
    let core = Core::new(Config { client_protocol: PROTOCOL, ..Config::default() }).unwrap();
    let one = core.import(one_package.clone(), &NoProgress).unwrap();
    let two = core.import(two_package.clone(), &NoProgress).unwrap();
    assert!(matches!(core.open(one_package).unwrap(), Opened::Ready { .. }));
    assert!(matches!(core.open(two_package).unwrap(), Opened::Ready { .. }));
    assert_ne!(one.edition, two.edition, "the two files are two editions");

    let first = core.entry_gloss(reference(&one.edition, "run")).unwrap();
    let second = core.entry_gloss(reference(&two.edition, "run")).unwrap();
    assert_eq!(first.text.as_deref(), Some("to move fast"));
    assert_eq!(second.text.as_deref(), Some("to go quickly"));
}
