//! Opt-in acceptance through the real core catalog and a separately generated lexical pack.
//! No dictionary bodies are copied. Not measured unless both inputs are explicitly provided.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use std::io::BufReader;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Instant;

use xdict_core::words::{PhoneSystem, WordLexicon, WordMode, WordPage, WordQuery, WordReason, WordStatus};
use xdict_core::{Config, Core, Location, NoProgress, Opened, PROTOCOL, Package};

fn contains(page: &WordPage, word: &str) -> bool {
    page.hits.iter().any(|hit| hit.headword.eq_ignore_ascii_case(word))
}

#[test]
fn six_word_modes_with_real_metadata_and_dictionary_headwords() {
    let (Ok(dirs), Ok(pack)) = (std::env::var("XDICT_MDX_CORPUS"), std::env::var("XDICT_WORD_PACK")) else {
        eprintln!("not measured: XDICT_MDX_CORPUS and XDICT_WORD_PACK are required");
        return;
    };
    let started = Instant::now();
    let lexicon = Arc::new(WordLexicon::from_jsonl(BufReader::new(std::fs::File::open(pack).unwrap())).unwrap());
    eprintln!("word metadata: loaded in {:?}", started.elapsed());
    let cache = std::env::var("XDICT_WORD_CACHE").ok();
    let core = Core::new(Config { client_protocol: PROTOCOL, cache_dir: cache, ..Config::default() }).unwrap();
    let mut folders: Vec<PathBuf> = std::env::split_paths(&dirs)
        .flat_map(|dir| std::fs::read_dir(dir).unwrap().map(|entry| entry.unwrap().path()))
        .filter(|path| path.is_dir())
        .collect();
    folders.sort();
    let mut handles = Vec::new();
    for folder in folders {
        let mut files: Vec<PathBuf> = std::fs::read_dir(&folder).unwrap().map(|entry| entry.unwrap().path()).collect();
        files.sort();
        let Some(path) =
            files.into_iter().find(|path| path.extension().is_some_and(|ext| ext.eq_ignore_ascii_case("mdx")))
        else {
            continue;
        };
        let package = Package {
            mdx: Location::Path { path: path.to_string_lossy().into_owned() },
            mdd: Vec::new(),
            sidecars: Vec::new(),
        };
        core.import(package.clone(), &NoProgress).unwrap();
        let Opened::Ready { dict, .. } = core.open(package).unwrap() else { panic!("dictionary not ready") };
        handles.push(dict);
    }
    assert!(!handles.is_empty(), "the supplied corpus contains no dictionary");
    let catalog_started = Instant::now();
    let explorer = core.word_explorer(handles, &NoProgress).unwrap().with_lexicon(Some(lexicon)).unwrap();
    let stats = explorer.stats();
    eprintln!(
        "word catalog: {} headwords, {} editions, built in {:?}",
        stats.headwords,
        stats.editions.len(),
        catalog_started.elapsed()
    );
    eprintln!(
        "metadata counts: pronunciations={} forms={} derivations={} origins={} etymons={}",
        stats.pronunciations, stats.forms, stats.derivations, stats.origins, stats.etymons
    );
    for source in &stats.sources {
        eprintln!("metadata source: {} {} {} ({})", source.id, source.version, source.sha256, source.licence);
    }
    let search_at = |text: &str, mode: WordMode, offset: u32| {
        let start = Instant::now();
        let page = explorer.search(WordQuery { text: text.into(), mode, limit: 1000, offset }).unwrap();
        eprintln!(
            "word query {text:?} {:?} offset={offset}: {:?}, total={:?}, exhausted={:?}, {:?}; first={:?}",
            page.mode,
            page.status,
            page.total,
            page.exhausted,
            start.elapsed(),
            page.hits.iter().take(12).map(|hit| hit.headword.as_str()).collect::<Vec<_>>()
        );
        assert_eq!(page.status, WordStatus::Answered);
        assert!(page.hits.iter().all(|hit| !hit.sources.is_empty() && !hit.reasons.is_empty()));
        page
    };
    let search = |text: &str, mode: WordMode| search_at(text, mode, 0);
    let mut suffix = search("bility", WordMode::EndsWith);
    let mut offset = 0;
    while !contains(&suffix, "possibility") {
        let next = suffix.next.expect("possibility is absent from the exhaustive suffix result");
        assert!(next > offset, "pagination must advance");
        offset = next;
        suffix = search_at("bility", WordMode::EndsWith, offset);
    }
    assert!(contains(&search("recieve", WordMode::Fuzzy { max_distance: 1 }), "receive"));
    assert!(contains(&search("nation", WordMode::Rhyme), "station"));
    assert!(contains(&search("ran", WordMode::Inflections), "run"));
    let family = search("possible", WordMode::Derivations);
    assert!(contains(&family, "possibility"));
    assert!(contains(&family, "impossible"));
    let record = search("record", WordMode::Derivations);
    let mut tagged_pos = std::collections::BTreeSet::new();
    for hit in &record.hits {
        for reason in &hit.reasons {
            if let WordReason::Derivation { query_pronunciations, hit_pronunciations, .. } = reason {
                for pronunciation in query_pronunciations.iter().chain(hit_pronunciations) {
                    if pronunciation.system == PhoneSystem::Ipa
                        && let Some(pos) = &pronunciation.pos
                    {
                        tagged_pos.insert(pos.clone());
                    }
                }
            }
        }
    }
    assert!(
        tagged_pos.contains("noun") && tagged_pos.contains("verb"),
        "record's sourced POS pronunciation contrast was lost: {tagged_pos:?}"
    );
    let roots = search("heart", WordMode::Roots { max_depth: 12 });
    assert!(contains(&roots, "cordial"));
    assert!(roots.hits.iter().any(|hit| hit.reasons.iter().any(|reason| matches!(reason,
        WordReason::SharedOrigin { ancestor, query_path, hit_path }
            if ancestor.language.is_some() && !query_path.is_empty() && !hit_path.is_empty()
    ))));
    eprintln!("real word-options acceptance complete in {:?}", started.elapsed());
}
