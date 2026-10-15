//! The matrix scenario (`conformance/README.md`) against the core directly: one dictionary in every version,
//! compression and encoding the reader reads, each imported, opened and asked the same questions.
//!
//! `XDICT_CONFORMANCE_MATRIX_EXPECTED` replaces `matrix/expected.json`, so a deliberately wrong expectation can
//! be shown to fail.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use std::path::PathBuf;

use serde_json::Value;
use xdict_core::*;

mod common;
use common::{outcome, subset};

#[test]
fn every_variant_of_the_matrix_conforms() {
    let template = std::fs::read_to_string(
        std::env::var_os("XDICT_CONFORMANCE_MATRIX_EXPECTED")
            .map(PathBuf::from)
            .unwrap_or_else(|| xdict_conformance::fixtures().join("matrix/expected.json")),
    )
    .unwrap();
    let dir = std::env::temp_dir().join(format!("xdict-conformance-matrix-{}", std::process::id()));
    xdict_conformance::write_fixture(&xdict_conformance::fixtures().join("matrix"), &dir).unwrap();
    let variants: Value = serde_json::from_str(&std::fs::read_to_string(dir.join("variants.json")).unwrap()).unwrap();
    let variants = variants.as_array().unwrap();
    assert_eq!(variants.len(), 32, "the matrix's variants");
    let view = View { base_url: "xdict://d/".into(), max_body_bytes: 1 << 20, original_style: false };
    let mut failures = Vec::new();

    for variant in variants {
        let name = variant["name"].as_str().unwrap();
        let x: Value = serde_json::from_str(
            &template
                .replace("$word", variant["word"].as_str().unwrap())
                .replace("$gloss", variant["gloss"].as_str().unwrap())
                .replace("$version", variant["version"].as_str().unwrap()),
        )
        .unwrap();
        let mut check = |at: &str, expected: &Value, actual: Value| {
            if let Err(e) = subset(expected, &actual, &format!("{name}.{at}")) {
                failures.push(e);
            }
        };
        let core = Core::new(Config { client_protocol: PROTOCOL, ..Config::default() }).unwrap();
        let mdx = Location::Path { path: dir.join(format!("{name}.mdx")).to_string_lossy().into_owned() };
        let package = Package { mdx, mdd: vec![], sidecars: vec![] };
        let imported = match core.import(package.clone(), &NoProgress) {
            Ok(imported) => imported,
            Err(e) => {
                check("import", &x["import"], outcome::<Imported>(Err(e)));
                continue;
            }
        };
        check("import", &x["import"], outcome::<Imported>(Ok(imported.clone())));
        let opened = core.open(package).unwrap();
        check("open", &x["open"], outcome::<Opened>(Ok(opened.clone())));
        let Opened::Ready { dict, .. } = opened else { continue };
        for (i, case) in x["lookups"].as_array().unwrap().iter().enumerate() {
            let options = LookupOptions {
                limit: case["limit"].as_u64().unwrap() as u32,
                offset: case["offset"].as_u64().unwrap() as u32,
                mode: MatchMode::Reader,
                generation: None,
            };
            let got = outcome(core.lookup(case["query"].as_str().unwrap().into(), vec![dict.clone()], options));
            check(&format!("lookups[{i}]"), &case["page"], got);
        }
        for (i, case) in x["entries"].as_array().unwrap().iter().enumerate() {
            let entry = EntryRef {
                edition: imported.edition.clone(),
                key: case["entry"]["key"].as_str().unwrap().into(),
                occurrence: case["entry"]["occurrence"].as_u64().unwrap() as u32,
            };
            check(&format!("entries[{i}]"), &case["result"], outcome(core.entry(dict.clone(), entry, view.clone())));
        }
    }
    assert!(failures.is_empty(), "{} failures:\n{}", failures.len(), failures.join("\n"));
}
