//! Measures the per-edition index on real files (`plan-core-v1.md` WI-3). Never shipped.
//!
//! - `index_bench build <cache> <dir>...`: writes every `.mdx`/`.mdd` file's index (two levels deep) into
//!   `<cache>`, and the list of files beside them.
//! - `index_bench open <cache>`: in a fresh process, opens every listed file through its mapped index, looks
//!   up each file's first key, and prints the time; run it under `/usr/bin/time -l` for the resident memory.
//! - `index_bench core <cache> <mdx> <query>`: imports one dictionary through the core and pages a lookup.
//! - `index_bench import-all <scratch> <dir>`: imports every dictionary under `<dir>` (each MDX with its stem's
//!   MDD volumes and its folder's other files as sidecars) into a fresh registry and cache, timed.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use std::path::{Path, PathBuf};
use std::time::Instant;

use std::sync::Arc;

use xdict_mdx::index::{Derive, Plain, Slice};
use xdict_mdx::{DiskFile, File, Kind};

fn files(roots: &[String]) -> Vec<PathBuf> {
    let mut out = Vec::new();
    for root in roots {
        let mut stack = vec![(PathBuf::from(root), 0)];
        while let Some((dir, depth)) = stack.pop() {
            let Ok(entries) = std::fs::read_dir(&dir) else { continue };
            for entry in entries.flatten() {
                let path = entry.path();
                let ext = path.extension().and_then(|e| e.to_str()).map(str::to_ascii_lowercase);
                if path.is_dir() && depth < 2 {
                    stack.push((path, depth + 1));
                } else if matches!(ext.as_deref(), Some("mdx" | "mdd")) {
                    out.push(path);
                }
            }
        }
    }
    out.sort();
    out
}

/// Each MDX with the MDD volumes of its stem (`x.mdd`, `x.1.mdd`, …, in that order) and its folder's other
/// files as sidecars.
fn packages(roots: &[String]) -> Vec<(PathBuf, Vec<PathBuf>, Vec<PathBuf>)> {
    let all = files(roots);
    let stem = |p: &Path| p.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    let mut out = Vec::new();
    for mdx in all.iter().filter(|p| kind(p) == Kind::Mdx) {
        let base = stem(mdx);
        let mut volumes: Vec<(usize, PathBuf)> = all
            .iter()
            .filter(|p| kind(p) == Kind::Mdd && p.parent() == mdx.parent())
            .filter_map(|p| {
                let s = stem(p);
                if s == base {
                    Some((0, p.clone()))
                } else {
                    let n = s.strip_prefix(&format!("{base}."))?.parse::<usize>().ok()?;
                    Some((n, p.clone()))
                }
            })
            .collect();
        volumes.sort();
        let sidecars: Vec<PathBuf> = std::fs::read_dir(mdx.parent().unwrap())
            .unwrap()
            .flatten()
            .map(|e| e.path())
            .filter(|p| {
                p.is_file()
                    && !matches!(
                        p.extension().and_then(|e| e.to_str()).map(str::to_ascii_lowercase).as_deref(),
                        Some("mdx" | "mdd")
                    )
            })
            .collect();
        out.push((mdx.clone(), volumes.into_iter().map(|v| v.1).collect(), sidecars));
    }
    out
}

fn kind(path: &Path) -> Kind {
    if path.extension().is_some_and(|e| e.eq_ignore_ascii_case("mdd")) { Kind::Mdd } else { Kind::Mdx }
}

/// A stand-in identity for measuring: the file's number. The edition hash is import's cost, not open's.
fn identity(n: usize) -> [u8; 32] {
    let mut id = [0u8; 32];
    id[..8].copy_from_slice(&(n as u64).to_le_bytes());
    id
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("build") => {
            let cache = PathBuf::from(&args[1]);
            std::fs::create_dir_all(&cache).unwrap();
            let list = files(&args[2..]);
            let (started, mut bytes) = (Instant::now(), 0u64);
            let mut kept = Vec::new();
            for (n, path) in list.iter().enumerate() {
                let source = DiskFile::open(path).unwrap();
                match File::build_index(&source, Some(kind(path)), identity(n), &*derive(kind(path))) {
                    Ok(index) => {
                        bytes += index.len() as u64;
                        xdict_mmap::OwnDirectory::new(&cache).replace(&format!("{n}.xdidx"), &index).unwrap();
                        kept.push(format!("{n}\t{}", path.display()));
                    }
                    Err(e) => eprintln!("skipped {}: {e}", path.display()),
                }
            }
            std::fs::write(cache.join("files.tsv"), kept.join("\n")).unwrap();
            println!(
                "{} indexes, {:.0} MB, built in {:.1} s",
                kept.len(),
                bytes as f64 / 1e6,
                started.elapsed().as_secs_f64()
            );
        }
        Some("open") => {
            let cache = PathBuf::from(&args[1]);
            let list = std::fs::read_to_string(cache.join("files.tsv")).unwrap();
            let started = Instant::now();
            let mut open = Vec::new();
            for line in list.lines() {
                let (n, path) = line.split_once('\t').unwrap();
                let path = PathBuf::from(path);
                let region = Box::new(Slice(xdict_mmap::OwnDirectory::new(&cache).map(&format!("{n}.xdidx")).unwrap()));
                let source = Box::new(DiskFile::open(&path).unwrap());
                let file = File::with_index(
                    source,
                    Some(kind(&path)),
                    region,
                    identity(n.parse().unwrap()),
                    derive(kind(&path)),
                )
                .unwrap()
                .unwrap_or_else(|stale| panic!("{}: {stale:?}", path.display()));
                open.push(file);
            }
            let opened = started.elapsed();
            let mut found = 0;
            for file in &open {
                if let Some(Ok(key)) = file.keys().next() {
                    found += usize::from(!file.find(&key).unwrap().is_empty());
                }
            }
            println!(
                "{} files open in {:.1} ms; first keys found in {found} ({:.1} ms with the lookups)",
                open.len(),
                opened.as_secs_f64() * 1e3,
                started.elapsed().as_secs_f64() * 1e3
            );
        }
        Some("core") => {
            let config = xdict_core::Config {
                client_protocol: xdict_core::PROTOCOL,
                cache_dir: Some(args[1].clone()),
                ..Default::default()
            };
            let core = xdict_core::Core::new(config).unwrap();
            let mdx = xdict_core::Location::Path { path: args[2].clone() };
            let started = Instant::now();
            let package = xdict_core::Package { mdx, mdd: vec![], sidecars: vec![] };
            let imported = core.import(package.clone(), &xdict_core::NoProgress).unwrap();
            let imported_in = started.elapsed();
            let started = Instant::now();
            let xdict_core::Opened::Ready { dict, .. } = core.open(package).unwrap() else { panic!("not open") };
            let opened_in = started.elapsed();
            let started = Instant::now();
            let options = xdict_core::LookupOptions {
                limit: 10,
                offset: 0,
                mode: xdict_core::MatchMode::Reader,
                generation: None,
            };
            let page = core.lookup(args[3].clone(), vec![dict], options).unwrap();
            println!(
                "{} keys; import {:.2} s, open {:.1} ms; {:?}: {} hits on the page of {} ({:.1} ms)",
                imported.info.keys,
                imported_in.as_secs_f64(),
                opened_in.as_secs_f64() * 1e3,
                args[3],
                page.hits.len(),
                page.total,
                started.elapsed().as_secs_f64() * 1e3
            );
        }
        Some("import-all") => {
            let scratch = PathBuf::from(&args[1]);
            let _ = std::fs::remove_dir_all(&scratch);
            let config = xdict_core::Config {
                client_protocol: xdict_core::PROTOCOL,
                data_dir: Some(scratch.join("data").to_string_lossy().into()),
                cache_dir: Some(scratch.join("cache").to_string_lossy().into()),
                entropy: vec![],
            };
            let core = xdict_core::Core::new(config).unwrap();
            let packages = packages(&args[2..]);
            let at = |p: &Path| xdict_core::Location::Path { path: p.to_string_lossy().into() };
            let started = Instant::now();
            let mut problems = 0;
            for (mdx, volumes, sidecars) in &packages {
                let package = xdict_core::Package {
                    mdx: at(mdx),
                    mdd: volumes.iter().map(|v| at(v)).collect(),
                    sidecars: sidecars.iter().map(|s| at(s)).collect(),
                };
                let imported =
                    core.import(package, &xdict_core::NoProgress).unwrap_or_else(|e| panic!("{}: {e}", mdx.display()));
                problems += imported.problems.len();
            }
            let editions =
                std::fs::read_to_string(scratch.join("data/registry.json")).unwrap().matches("mdx-sha256-v1:").count();
            println!(
                "{} packages ({} volumes) imported in {:.2} s; {problems} problems; registry mentions {editions} edition strings",
                packages.len(),
                packages.iter().map(|p| p.1.len()).sum::<usize>(),
                started.elapsed().as_secs_f64()
            );
        }
        _ => eprintln!(
            "usage: index_bench build <cache> <dir>... | open <cache> | core <cache> <mdx> <query> | import-all <scratch> <dir>"
        ),
    }
}

/// What the core indexes each kind under: dictionaries under the lookup policy, resource libraries plainly.
fn derive(kind: Kind) -> Arc<dyn Derive> {
    match kind {
        Kind::Mdx => Arc::new(xdict_lookup::Policy),
        Kind::Mdd => Arc::new(Plain),
    }
}
