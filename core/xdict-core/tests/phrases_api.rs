//! The phrase API through the core (`dev-docs/plan-phrase-recognition.md` WI-4, WI-5): the inventory built from the
//! edition's own public keys, the answer's states, the UTF-16 span, and the bounds re-validated in the core. The
//! dictionary is written here; no dictionary's content enters the repository.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use xdict_core::*;
use xdict_mdx_writer::{self as writer, Entry as W, Spec};

fn entry(key: &str, gloss: &str) -> W {
    W::text(
        key,
        &format!(
            r#"<div class="e"><b class="hw">{key}</b><div class="s"><b>1.</b> <span class="d">{gloss}</span></div></div>"#
        ),
    )
}

fn entries() -> Vec<W> {
    vec![
        entry("give up", "to stop trying"),
        entry("take something into account", "to consider"),
        entry("purple passage", "a fine piece of prose"),
        entry("resource", "a source of supply"),
        entry("take", "to remove"),
    ]
}

struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let n = NEXT.fetch_add(1, Ordering::SeqCst);
        let dir = std::env::temp_dir().join(format!("xdict-phrases-{name}-{}-{n}", std::process::id()));
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

fn package(dir: &Scratch, name: &str, entries: &[W]) -> Package {
    std::fs::write(dir.0.join(format!("{name}.mdx")), writer::write(&Spec::mdx(), entries).unwrap()).unwrap();
    Package { mdx: dir.at(&format!("{name}.mdx")), mdd: vec![], sidecars: vec![] }
}

fn core() -> Core {
    Core::new(Config { client_protocol: PROTOCOL, ..Config::default() }).unwrap()
}

fn opened(core: &Core, package: Package) -> (String, String) {
    core.import(package.clone(), &NoProgress).unwrap();
    match core.open(package).unwrap() {
        Opened::Ready { dict, edition, .. } => (dict, edition),
        other => panic!("not open: {other:?}"),
    }
}

fn phrase_for(core: &Core, dict: &str, sentence: &str, term: &str) -> PhraseAnswer {
    let location = sentence.get(..sentence.find(term).unwrap()).unwrap().encode_utf16().count() as u64;
    let length = term.encode_utf16().count() as u64;
    core.phrases(sentence.to_string(), location, length, vec![dict.to_string()]).unwrap()
}

#[test]
fn a_sentence_finds_its_phrase_after_the_build_and_says_building_before_it() {
    let dir = Scratch::new("build");
    let core = core();
    let (dict, edition) = opened(&core, package(&dir, "noad", &entries()));

    let before = phrase_for(&core, &dict, "the review was full of purple passage", "purple");
    assert_eq!(before.state, PhraseState::Building);
    assert_eq!(before.coverage, [CoverageEntry { dict: dict.clone(), state: Coverage::Building }]);

    let built = core.phrases_build(dict.clone(), &NoProgress).unwrap();
    assert_eq!(built.edition, edition);
    assert!(!built.cached);
    assert!(built.phrases >= 3, "only {} phrases", built.phrases);

    let sentence = "😀 the review was full of purple passage nobody could follow";
    let found = phrase_for(&core, &dict, sentence, "purple");
    assert_eq!(found.state, PhraseState::Found);
    assert_eq!(found.coverage, [CoverageEntry { dict: dict.clone(), state: Coverage::Ready }]);
    let first = found.matches.first().expect("no match");
    assert_eq!(first.phrase, "purple passage");
    assert_eq!(first.gap, 0);
    let expected = sentence.get(..sentence.find("purple").unwrap()).unwrap().encode_utf16().count() as u64;
    assert_eq!(first.location, expected, "the span is UTF-16, after the emoji");
    assert_eq!(first.length, "purple passage".encode_utf16().count() as u64);

    // A second build finds the store and answers cached.
    let again = core.phrases_build(dict.clone(), &NoProgress).unwrap();
    assert!(again.cached);
}

#[test]
fn a_bad_range_or_a_long_sentence_is_refused() {
    let dir = Scratch::new("bounds");
    let core = core();
    let (dict, _) = opened(&core, package(&dir, "bounds", &entries()));
    core.phrases_build(dict.clone(), &NoProgress).unwrap();

    let outside = core.phrases("short sentence".into(), 50, 3, vec![dict.clone()]).unwrap_err();
    assert!(matches!(outside, CoreError::Malformed { .. }), "{outside:?}");
    let long = "a ".repeat(600);
    let too_long = core.phrases(long, 0, 1, vec![dict.clone()]).unwrap_err();
    assert!(matches!(too_long, CoreError::TooLarge { limit: Limit::Sentence, .. }), "{too_long:?}");
}

#[test]
fn an_empty_or_whitespace_sentence_is_not_asked() {
    let dir = Scratch::new("empty");
    let core = core();
    let (dict, _) = opened(&core, package(&dir, "empty", &entries()));
    core.phrases_build(dict.clone(), &NoProgress).unwrap();
    let answer = core.phrases(String::new(), 0, 0, vec![dict.clone()]).unwrap();
    assert_eq!(answer.state, PhraseState::NotAsked);
    assert!(answer.matches.is_empty());
}

#[test]
fn a_cancelled_build_is_not_a_failure_and_the_edition_stays_buildable() {
    struct Cancel;
    impl Progress for Cancel {
        fn progress(&self, _done: u64, _total: u64) -> bool {
            false
        }
    }
    let dir = Scratch::new("cancel");
    let core = core();
    let (dict, _) = opened(&core, package(&dir, "cancel", &entries()));
    let cancelled = core.phrases_build(dict.clone(), &Cancel);
    assert!(matches!(cancelled, Err(CoreError::Cancelled { .. })), "{cancelled:?}");
    let answer = phrase_for(&core, &dict, "the review was full of purple passage", "purple");
    assert_eq!(answer.state, PhraseState::Building, "a cancelled build was reported as a failure");
    core.phrases_build(dict.clone(), &NoProgress).unwrap();
    assert_eq!(phrase_for(&core, &dict, "the review was full of purple passage", "purple").state, PhraseState::Found);
}

#[test]
fn a_store_that_does_not_decode_says_building_and_the_build_repairs_it() {
    struct ScratchStore(PathBuf);
    #[derive(Default)]
    struct Recording {
        written: Mutex<HashMap<String, Vec<u8>>>,
    }
    struct Bytes(Vec<u8>);
    impl ByteSource for Bytes {
        fn size(&self) -> u64 {
            self.0.len() as u64
        }
        fn read_at(&self, offset: u64, len: u32) -> Result<Vec<u8>, CoreError> {
            let start = usize::try_from(offset).unwrap();
            let end = start.checked_add(len as usize).unwrap();
            self.0.get(start..end).map(<[u8]>::to_vec).ok_or_else(|| CoreError::Io {
                kind: IoKind::ShortRead,
                detail: "a short read from the recording store".into(),
            })
        }
        fn identity(&self) -> Option<FileIdentity> {
            None
        }
    }
    impl IndexStorage for Recording {
        fn get(&self, name: &str) -> Result<Option<Arc<dyn ByteSource>>, CoreError> {
            let bytes = self.written.lock().unwrap().get(name).cloned();
            Ok(bytes.map(|bytes| Arc::new(Bytes(bytes)) as Arc<dyn ByteSource>))
        }
        fn put(&self, name: &str, bytes: Vec<u8>) -> Result<(), CoreError> {
            self.written.lock().unwrap().insert(name.to_owned(), bytes.to_vec());
            Ok(())
        }
    }
    let storage = Arc::new(Recording::default());
    let core =
        Core::with_index_storage(Config { client_protocol: PROTOCOL, ..Config::default() }, storage.clone()).unwrap();
    let dir = ScratchStore(std::env::temp_dir().join(format!("xdict-phrases-store-{}", std::process::id())));
    let _ = std::fs::remove_dir_all(&dir.0);
    std::fs::create_dir_all(&dir.0).unwrap();
    let scratch = Scratch(dir.0.clone());
    let (dict, edition) = opened(&core, package(&scratch, "store", &entries()));
    // A store under the right name that is not one: the answer says building, and the build replaces it.
    let name = xdict_core::phrases::store_name(&edition);
    storage.written.lock().unwrap().insert(name, b"not a store".to_vec());
    let answer = phrase_for(&core, &dict, "the review was full of purple passage", "purple");
    assert_eq!(answer.state, PhraseState::Building, "a corrupt store was not reported as building");
    let built = core.phrases_build(dict.clone(), &NoProgress).unwrap();
    assert!(!built.cached);
    assert_eq!(phrase_for(&core, &dict, "the review was full of purple passage", "purple").state, PhraseState::Found);
}
