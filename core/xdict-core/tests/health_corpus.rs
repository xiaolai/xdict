//! WI-12's health check on real dictionaries: `XDICT_MDX_CORPUS=<dirs> [XDICT_HEALTH_OUT=<file.jsonl>] cargo test
//! --release -p xdict-core --test health_corpus -- --nocapture`. Each folder of the corpus is one package, as in
//! `entries_corpus.rs`. Checks every edition through the core, then again, which must be read back without a second
//! pass; writes each edition's classes and findings, one JSON line each, for comparison with the census
//! (`dev-docs/measurements/2026-10-15-mdx-health/`). The examples are dictionary content: the output belongs outside
//! the repository. Unset, it says "not measured".
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;

use xdict_core::{Config, Core, Location, NoProgress, Opened, PROTOCOL, Package, Progress};

fn package(dir: &Path) -> Option<Package> {
    let mut files: Vec<PathBuf> =
        std::fs::read_dir(dir).ok()?.map(|e| e.unwrap().path()).filter(|p| p.is_file()).collect();
    files.sort();
    let ext = |p: &Path, e: &str| p.extension().is_some_and(|x| x.eq_ignore_ascii_case(e));
    let mdx = files.iter().find(|p| ext(p, "mdx"))?.clone();
    let location = |p: &Path| Location::Path { path: p.to_string_lossy().into_owned() };
    let hidden = |p: &Path| p.file_name().unwrap().to_string_lossy().starts_with('.');
    let mdd = files.iter().filter(|p| ext(p, "mdd")).map(|p| location(p)).collect();
    let sidecars =
        files.iter().filter(|p| !ext(p, "mdx") && !ext(p, "mdd") && !hidden(p)).map(|p| location(p)).collect();
    Some(Package { mdx: location(&mdx), mdd, sidecars })
}

struct Counted(AtomicU64);

impl Progress for Counted {
    fn progress(&self, _: u64, _: u64) -> bool {
        self.0.fetch_add(1, Ordering::SeqCst);
        true
    }
}

#[test]
fn every_edition_is_checked_once_and_kept() {
    let Ok(dirs) = std::env::var("XDICT_MDX_CORPUS") else {
        eprintln!("not measured: XDICT_MDX_CORPUS is unset");
        return;
    };
    let mut out = std::env::var("XDICT_HEALTH_OUT").ok().map(|p| std::fs::File::create(p).unwrap());
    let cache = std::env::temp_dir().join(format!("xdict-health-{}", std::process::id()));
    let core = Core::new(Config {
        client_protocol: PROTOCOL,
        cache_dir: Some(cache.to_string_lossy().into()),
        ..Config::default()
    })
    .unwrap();
    let mut folders: Vec<PathBuf> = std::env::split_paths(&dirs)
        .flat_map(|d| std::fs::read_dir(d).unwrap().map(|e| e.unwrap().path()))
        .filter(|p| p.is_dir())
        .collect();
    folders.sort();
    let mut checked = 0;
    for folder in folders {
        let name = folder.file_name().unwrap().to_string_lossy().into_owned();
        let Some(package) = package(&folder) else { continue };
        core.import(package.clone(), &NoProgress).unwrap();
        let Opened::Ready { dict, info, .. } = core.open(package).unwrap() else { panic!("{name}: not open") };
        let started = Instant::now();
        let first = Counted(AtomicU64::new(0));
        let health = core.health(dict.clone(), &first).unwrap();
        let secs = started.elapsed().as_secs_f64();
        assert_eq!(health.entries, info.keys, "{name}: every entry checked");
        assert!(first.0.load(Ordering::SeqCst) > 0, "{name}: checked");
        let started = Instant::now();
        let again = Counted(AtomicU64::new(0));
        assert_eq!(core.health(dict.clone(), &again).unwrap(), health, "{name}: kept");
        assert_eq!(again.0.load(Ordering::SeqCst), 0, "{name}: read back, not checked again");
        let kept = started.elapsed().as_secs_f64();
        let findings: Vec<String> = health
            .findings
            .iter()
            .map(|f| {
                format!("{:?} {}{}", f.kind, f.count, f.name.as_ref().map(|n| format!(" {n}")).unwrap_or_default())
            })
            .collect();
        eprintln!("{name}: {} entries, {secs:.1} s, read back in {kept:.3} s; {}", health.entries, findings.join("; "));
        if let Some(out) = &mut out {
            let classes: serde_json::Map<String, serde_json::Value> =
                health.classes.iter().map(|c| (c.name.clone(), c.count.into())).collect();
            let examples: Vec<serde_json::Value> = health
                .findings
                .iter()
                .map(|f| {
                    serde_json::json!({ "kind": format!("{:?}", f.kind),
                    "examples": f.examples.iter().map(|e| [e.key.clone(), e.text.clone()]).collect::<Vec<_>>() })
                })
                .collect();
            let line = serde_json::json!({ "dict": name, "entries": health.entries, "secs": secs,
                "classes": classes, "findings": findings, "examples": examples });
            writeln!(out, "{line}").unwrap();
        }
        core.close(dict).unwrap();
        checked += 1;
    }
    assert!(checked > 0, "no dictionary found: not measured");
    let _ = std::fs::remove_dir_all(cache);
}
