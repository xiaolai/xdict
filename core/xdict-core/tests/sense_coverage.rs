//! **The sense coverage report** (plan-explain-sense WI-0, ADR-0029 d.2, d.9): before a sense ordinal may enter the
//! markup or the IPC contract, the containers the renderer writes today are measured against an annotation made by
//! reading the entry. The protocol — sample, annotation rules, matching, thresholds — is predeclared in
//! `dev-docs/measurements/2026-10-22-explain-sense/README.md`; this file is its instrument.
//!
//! `XDICT_MDX_CORPUS=<dirs> cargo test --release -p xdict-core --test sense_coverage -- --nocapture`
//!
//! - `XDICT_SENSE_DUMP=<file>` writes the sampled entries' projection text with byte offsets, for the annotator. The
//!   file holds dictionary text; it is written on the measurement host and never committed.
//! - `XDICT_SENSE_ANNOTATION=<file>` scores the containers against the gold senses and prints the report.
//! - `XDICT_SENSE_OUT=<file>` writes the same numbers as JSON.
//!
//! Says "not measured" when the corpus is unset, and writes the dump or scores only when its own variable is set.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde_json::{Value, json};
use xdict_core::{Config, Core, EntryRef, Location, NoProgress, Opened, PROTOCOL, Package, View};
use xdict_entry::Projection;
use xdict_mdx::File;

const BASE: &str = "xdict://d/";
/// The unit the protocol declares: an entry's text up to this many bytes.
const UNIT: usize = 16_384;
/// The shell's entry budget (`MeaningBudget.entryTextBytes`).
const BUDGET: usize = 256 << 10;
/// The dictionaries the protocol names.
const DICTS: [&str; 8] = ["ahd", "cald", "cobuild", "ldoce", "mwc", "noad", "oald", "ode"];
/// The keys, in order, and the fallbacks: the first two a dictionary holds are sampled (the protocol's amended sample).
const KEYS: [&str; 10] =
    ["apple", "river", "quiet", "brief", "anchor", "crane", "harvest", "lantern", "pocket", "ridge"];

fn view(original: bool) -> View {
    View { base_url: BASE.into(), max_body_bytes: 64 << 20, original_style: original }
}

/// A folder's package: `X.mdd` before `X.1.mdd` before `X.2.mdd`, every other file a sidecar.
fn package(dir: &Path) -> Option<(PathBuf, Package)> {
    let mut files: Vec<PathBuf> =
        std::fs::read_dir(dir).ok()?.map(|e| e.unwrap().path()).filter(|p| p.is_file()).collect();
    files.sort();
    let ext = |p: &Path, e: &str| p.extension().is_some_and(|x| x.eq_ignore_ascii_case(e));
    let mdx = files.iter().find(|p| ext(p, "mdx"))?.clone();
    let mut mdd: Vec<&PathBuf> = files.iter().filter(|p| ext(p, "mdd")).collect();
    let volume = |p: &PathBuf| -> u32 {
        let stem = p.file_stem().unwrap().to_string_lossy().into_owned();
        stem.rsplit_once('.').and_then(|(_, n)| n.parse().ok()).map_or(0, |n: u32| n + 1)
    };
    mdd.sort_by_key(|p| volume(p));
    let location = |p: &Path| Location::Path { path: p.to_string_lossy().into_owned() };
    let hidden = |p: &PathBuf| p.file_name().unwrap().to_string_lossy().starts_with('.');
    let sidecars =
        files.iter().filter(|p| !ext(p, "mdx") && !ext(p, "mdd") && !hidden(p)).map(|p| location(p)).collect();
    let package = Package { mdx: location(&mdx), mdd: mdd.into_iter().map(|p| location(p)).collect(), sidecars };
    Some((mdx, package))
}

/// The first non-redirect record of `key`, and its occurrence among the key's exact records (what an `EntryRef`
/// carries; `Core::render` counts redirects too).
fn resolve(file: &File, key: &str) -> Option<u32> {
    let mut occurrence = 0u32;
    for i in file.find(key).ok()? {
        if file.key(i).ok()? != key {
            continue;
        }
        let record = file.record(i).ok()?;
        let text = String::from_utf8_lossy(&record.data);
        if !text.trim_start().starts_with("@@@LINK=") {
            return Some(occurrence);
        }
        occurrence += 1;
    }
    None
}

/// One entry as the shell would get it: the rendered markup (whose sense runs the renderer now writes), projected.
fn project(core: &Core, dict: &str, entry: EntryRef, original: bool, budget: usize) -> Option<Projection> {
    let shown = core.entry(dict.to_string(), entry, view(original)).ok()?;
    Some(xdict_entry::entry_text_from_html(&shown.html, budget))
}

/// The sampled entries for one dictionary: the first two keys it holds.
fn sample(file: &File) -> Vec<(String, u32)> {
    let mut out = Vec::new();
    for key in KEYS {
        if out.len() == 2 {
            break;
        }
        if let Some(occurrence) = resolve(file, key) {
            out.push((key.to_string(), occurrence));
        }
    }
    out
}

/// The corpus folders the protocol names, sorted, by name.
fn corpus(dirs: &str) -> BTreeMap<String, PathBuf> {
    let mut folders: Vec<PathBuf> = std::env::split_paths(dirs)
        .flat_map(|d| std::fs::read_dir(d).unwrap().map(|e| e.unwrap().path()))
        .filter(|p| p.is_dir())
        .collect();
    folders.sort();
    folders.iter().filter_map(|p| Some((p.file_name()?.to_string_lossy().into_owned(), p.clone()))).collect()
}

fn path_of(dirs: &str, name: &str) -> Option<PathBuf> {
    corpus(dirs).get(name).cloned()
}

#[test]
fn dump_the_sample_for_annotation() {
    let Ok(out_path) = std::env::var("XDICT_SENSE_DUMP") else {
        eprintln!("not measured: XDICT_SENSE_DUMP is unset");
        return;
    };
    let Ok(dirs) = std::env::var("XDICT_MDX_CORPUS") else {
        eprintln!("not measured: XDICT_MDX_CORPUS is unset");
        return;
    };
    let cache = std::env::temp_dir().join(format!("xdict-senses-{}", std::process::id()));
    let core = Core::new(Config {
        client_protocol: PROTOCOL,
        cache_dir: Some(cache.to_string_lossy().into()),
        ..Config::default()
    })
    .unwrap();
    let mut out = String::new();
    for name in DICTS {
        let Some(folder) = path_of(&dirs, name) else {
            eprintln!("{name}: skipped, not in the corpus");
            continue;
        };
        let Some((mdx_path, package)) = package(&folder) else {
            eprintln!("{name}: skipped, no MDX package");
            continue;
        };
        let Ok(file) = File::open(&mdx_path) else {
            eprintln!("{name}: skipped, the file did not open");
            continue;
        };
        if core.import(package.clone(), &NoProgress).is_err() {
            eprintln!("{name}: skipped, the import failed");
            continue;
        }
        let Ok(Opened::Ready { dict, edition, .. }) = core.open(package) else {
            eprintln!("{name}: skipped, the package did not open");
            continue;
        };
        for (key, occurrence) in sample(&file) {
            let entry = EntryRef { edition: edition.clone(), key: key.clone(), occurrence };
            // **The markup itself**, for the classifier work: written only when asked, on the measurement host.
            if let Ok(html_dir) = std::env::var("XDICT_SENSE_HTML")
                && let Some(shown) = core.entry(dict.clone(), entry.clone(), view(false)).ok()
            {
                let _ = std::fs::create_dir_all(&html_dir);
                let _ = std::fs::write(format!("{html_dir}/{name}-{key}.html"), shown.html);
            }
            if let Some(p) = project(&core, &dict, entry, false, usize::MAX) {
                out.push_str(&format!("=== {name}|{key}|{occurrence}|{}\n", p.text.len()));
                for sense in &p.senses {
                    out.push_str(&format!(
                        "--- sense {} start={} len={} label={:?} parent={:?} whole={}\n",
                        sense.id, sense.start, sense.len, sense.label, sense.parent, sense.whole
                    ));
                }
                let mut at = 0usize;
                for line in p.text.split('\n') {
                    out.push_str(&format!("[{at}] {line}\n"));
                    at += line.len() + 1;
                }
            } else {
                eprintln!("{name}/{key}/{occurrence}: skipped, the entry did not render");
            }
        }
        core.close(dict).ok();
    }
    std::fs::write(&out_path, out).unwrap();
    eprintln!("dump written to {out_path}");
    let _ = std::fs::remove_dir_all(&cache);
}

/// A gold sense from the annotation: its range and parent, as the annotator marked them.
struct Gold {
    start: usize,
    len: usize,
    parent: Option<usize>,
}

fn iou(a: (usize, usize), b: (usize, usize)) -> f64 {
    let start = a.0.max(b.0);
    let end = a.1.min(b.1);
    let overlap = end.saturating_sub(start) as f64;
    let union = (a.1.max(b.1) - a.0.min(b.0)) as f64;
    if union <= 0.0 { 0.0 } else { overlap / union }
}

#[derive(Default)]
struct Row {
    records: usize,
    skipped: usize,
    gold: usize,
    containers: usize,
    correct: usize,
    found: usize,
    merged: usize,
    gold_bytes: usize,
    uncovered: usize,
    budget_misses: usize,
    revision_moves: usize,
    entries: usize,
    parent_checked: usize,
    parent_correct: usize,
}

#[test]
fn sense_coverage_of_the_corpus() {
    let Ok(annotation_path) = std::env::var("XDICT_SENSE_ANNOTATION") else {
        eprintln!("not measured: XDICT_SENSE_ANNOTATION is unset");
        return;
    };
    let Ok(dirs) = std::env::var("XDICT_MDX_CORPUS") else {
        eprintln!("not measured: XDICT_MDX_CORPUS is unset");
        return;
    };
    let annotation: Value = serde_json::from_str(&std::fs::read_to_string(&annotation_path).unwrap()).unwrap();
    let entries = annotation["entries"].as_array().unwrap();
    let cache = std::env::temp_dir().join(format!("xdict-senses-{}", std::process::id()));
    let core = Core::new(Config {
        client_protocol: PROTOCOL,
        cache_dir: Some(cache.to_string_lossy().into()),
        ..Config::default()
    })
    .unwrap();
    let mut by_dict: BTreeMap<String, Row> = BTreeMap::new();
    // The annotation's entries, grouped so each dictionary is imported and opened once.
    let mut grouped: BTreeMap<String, Vec<&Value>> = BTreeMap::new();
    for item in entries {
        grouped.entry(item["dict"].as_str().unwrap_or("").to_string()).or_default().push(item);
    }
    for (name, items) in grouped {
        let row = by_dict.entry(name.clone()).or_default();
        let Some(folder) = path_of(&dirs, &name) else {
            row.records += items.len();
            row.skipped += items.len();
            eprintln!("{name}: skipped, not in the corpus at {dirs}");
            continue;
        };
        let Some((mdx_path, package)) = package(&folder) else {
            row.records += items.len();
            row.skipped += items.len();
            eprintln!("{name}: skipped, no MDX package");
            continue;
        };
        let Ok(_file) = File::open(&mdx_path) else {
            row.records += items.len();
            row.skipped += items.len();
            eprintln!("{name}: skipped, the file did not open");
            continue;
        };
        if core.import(package.clone(), &NoProgress).is_err() {
            row.records += items.len();
            row.skipped += items.len();
            eprintln!("{name}: skipped, the import failed");
            continue;
        }
        let Ok(Opened::Ready { dict, edition, .. }) = core.open(package) else {
            row.records += items.len();
            row.skipped += items.len();
            eprintln!("{name}: skipped, the package did not open");
            continue;
        };
        for item in items {
            row.records += 1;
            let key = item["key"].as_str().unwrap_or("");
            let occurrence = item["occurrence"].as_u64().unwrap_or(0) as u32;
            let gold: Vec<Gold> = item["senses"]
                .as_array()
                .map(|a| {
                    a.iter()
                        .map(|s| Gold {
                            start: s["start"].as_u64().unwrap_or(0) as usize,
                            len: s["len"].as_u64().unwrap_or(0) as usize,
                            parent: s["parent"].as_u64().map(|p| p as usize),
                        })
                        .collect()
                })
                .unwrap_or_default();
            let entry = EntryRef { edition: edition.clone(), key: key.to_string(), occurrence };
            match project(&core, &dict, entry.clone(), false, usize::MAX) {
                Some(full) => {
                    row.entries += 1;
                    eprintln!("{name}/{key}:");
                    score(row, &full, &gold);
                    // **The revision check** (ADR-0029 d.3): the same entry under the dictionary's own original style.
                    if project(&core, &dict, entry.clone(), true, usize::MAX).is_some_and(|other| {
                        let a: Vec<(usize, usize)> = full.senses.iter().map(|s| (s.start, s.start + s.len)).collect();
                        let b: Vec<(usize, usize)> = other.senses.iter().map(|s| (s.start, s.start + s.len)).collect();
                        a != b
                    }) {
                        row.revision_moves += 1;
                    }
                    // **After the budget**: the same containers at the shell's 256 KiB, and whether they are whole.
                    if full.text.len() <= BUDGET
                        && let Some(cut) = project(&core, &dict, entry, false, BUDGET)
                    {
                        for (index, gold) in gold.iter().enumerate() {
                            let target = (gold.start, gold.start + gold.len);
                            let position =
                                full.senses.iter().position(|s| iou((s.start, s.start + s.len), target) >= 0.9);
                            if let Some(position) = position
                                && !cut.senses.get(position).is_some_and(|s| s.whole)
                            {
                                row.budget_misses += 1;
                                eprintln!("{name}/{key}: gold sense {index} is not whole at the budget");
                            }
                        }
                    }
                }
                None => {
                    row.skipped += 1;
                    eprintln!("{name}/{key}/{occurrence}: skipped, the entry did not render");
                }
            }
        }
        core.close(dict).ok();
    }
    let mut total = Row::default();
    for (name, row) in &by_dict {
        eprintln!(
            "{name:10} {:3} records, {} skipped; gold {:3}; containers {:3}; precision {:.3}; recall {:.3}; merged {}; \
             uncovered {:.3}; budget misses {}; revision moves {}/{}",
            row.records,
            row.skipped,
            row.gold,
            row.containers,
            ratio(row.correct, row.containers),
            ratio(row.found, row.gold),
            row.merged,
            ratio(row.uncovered, row.gold_bytes),
            row.budget_misses,
            row.revision_moves,
            row.entries
        );
        eprintln!(
            "{name:10} hierarchy: {}/{} matched senses with the annotated parent",
            row.parent_correct, row.parent_checked
        );
        total.records += row.records;
        total.skipped += row.skipped;
        total.gold += row.gold;
        total.containers += row.containers;
        total.correct += row.correct;
        total.found += row.found;
        total.merged += row.merged;
        total.gold_bytes += row.gold_bytes;
        total.uncovered += row.uncovered;
        total.budget_misses += row.budget_misses;
        total.revision_moves += row.revision_moves;
        total.entries += row.entries;
        total.parent_checked += row.parent_checked;
        total.parent_correct += row.parent_correct;
    }
    let precision = ratio(total.correct, total.containers);
    let recall = ratio(total.found, total.gold);
    let merged = ratio(total.merged, total.containers);
    let uncovered = ratio(total.uncovered, total.gold_bytes);
    eprintln!(
        "TOTAL: {} records, {} skipped, {} entries; gold {}; containers {}; precision {precision:.3}; recall \
         {recall:.3}; merged {merged:.3}; uncovered {uncovered:.3}; budget misses {}; revision moves {}/{}",
        total.records,
        total.skipped,
        total.entries,
        total.gold,
        total.containers,
        total.budget_misses,
        total.revision_moves,
        total.entries
    );
    eprintln!("hierarchy: {}/{} matched senses with the annotated parent", total.parent_correct, total.parent_checked);
    let pass = precision >= 0.95 && recall >= 0.90 && merged <= 0.02 && uncovered <= 0.05 && total.budget_misses == 0;
    eprintln!("thresholds: {}", if pass { "PASS" } else { "MISS" });
    if let Ok(out) = std::env::var("XDICT_SENSE_OUT") {
        let json = json!({
            "records": total.records, "skipped": total.skipped, "entries": total.entries,
            "gold": total.gold, "containers": total.containers, "precision": precision, "recall": recall,
            "merged": merged, "uncovered": uncovered, "budget_misses": total.budget_misses,
            "revision_moves": total.revision_moves, "parent_checked": total.parent_checked,
            "parent_correct": total.parent_correct, "pass": pass
        });
        std::fs::write(out, json.to_string()).unwrap();
    }
    let _ = std::fs::remove_dir_all(&cache);
}

fn ratio(part: usize, whole: usize) -> f64 {
    if whole == 0 { 1.0 } else { part as f64 / whole as f64 }
}

/// Scores one entry's containers against its gold senses, in the protocol's unit.
fn score(row: &mut Row, full: &Projection, gold: &[Gold]) {
    let unit = full.text.len().min(UNIT);
    let golds: Vec<(usize, usize)> =
        gold.iter().filter(|g| g.start < unit).map(|g| (g.start, (g.start + g.len).min(unit))).collect();
    let containers: Vec<(u32, (usize, usize))> =
        full.senses.iter().filter(|s| s.start < unit).map(|s| (s.id, (s.start, (s.start + s.len).min(unit)))).collect();
    row.gold += golds.len();
    row.containers += containers.len();
    let mut gold_mask = vec![false; unit];
    for (start, end) in &golds {
        for slot in gold_mask.iter_mut().take(*end).skip(*start) {
            *slot = true;
        }
        row.gold_bytes += end.saturating_sub(*start);
    }
    // **A parent covering its own subsenses is not a merge** (ADR-0029 d.2 makes hierarchy real): a merged container
    // covers two gold senses where neither is an ancestor of the other. The annotation's parent indices are the
    // hierarchy; a container over a parent and its children is a correct parent container, not two senses fused.
    let ancestor = |mut index: usize, of: usize| -> bool {
        while let Some(parent) = gold.get(index).and_then(|g| g.parent) {
            if parent == of {
                return true;
            }
            index = parent;
        }
        false
    };
    for (id, c) in &containers {
        let matches: Vec<f64> = golds.iter().map(|g| iou(*c, *g)).collect();
        if matches.iter().filter(|iou| **iou >= 0.9).count() == 1 {
            row.correct += 1;
        } else {
            let best = matches.iter().copied().fold(0.0_f64, f64::max);
            let at = matches.iter().position(|m| *m == best).unwrap_or(0);
            eprintln!(
                "  not matched: container {id} {}..{} ({} B) best IoU {best:.3} with gold {at} {:?}",
                c.0,
                c.1,
                c.1.saturating_sub(c.0),
                golds.get(at)
            );
        }
        let covered: Vec<usize> = gold
            .iter()
            .enumerate()
            .filter(|(_, g)| g.start < unit && iou(*c, (g.start, (g.start + g.len).min(unit))) >= 0.5)
            .map(|(index, _)| index)
            .collect();
        let siblings = covered
            .iter()
            .enumerate()
            .any(|(a, i)| covered.iter().skip(a + 1).any(|j| !ancestor(*i, *j) && !ancestor(*j, *i)));
        if siblings {
            row.merged += 1;
        }
        for slot in gold_mask.iter_mut().take(c.1).skip(c.0) {
            *slot = false;
        }
    }
    row.uncovered += gold_mask.iter().filter(|covered| **covered).count();
    for (index, g) in golds.iter().enumerate() {
        if containers.iter().any(|(_, c)| iou(*c, *g) >= 0.9) {
            row.found += 1;
        } else {
            let best = containers.iter().map(|(_, c)| iou(*c, *g)).fold(0.0_f64, f64::max);
            eprintln!("  not found: gold {index} {:?} ({} B), best IoU {best:.3}", g, g.1.saturating_sub(g.0));
        }
    }
    // **Hierarchy** (ADR-0029 d.2): a nested gold sense's container must be nested in its parent's container, and a
    // top-level one must not be nested. Only pairs whose both ends matched are counted.
    let mut gold_container: BTreeMap<usize, u32> = BTreeMap::new();
    for (index, g) in gold.iter().enumerate() {
        if g.start >= unit {
            continue;
        }
        let interval = (g.start, (g.start + g.len).min(unit));
        if let Some((id, _)) = containers.iter().find(|(_, c)| iou(*c, interval) >= 0.9) {
            gold_container.insert(index, *id);
        }
    }
    for (index, g) in gold.iter().enumerate() {
        if g.start >= unit {
            continue;
        }
        let Some(container) = gold_container.get(&index) else { continue };
        let container_parent = full.senses.iter().find(|s| s.id == *container).and_then(|s| s.parent);
        match g.parent {
            Some(parent) => {
                if let Some(parent_container) = gold_container.get(&parent) {
                    row.parent_checked += 1;
                    if container_parent == Some(*parent_container) {
                        row.parent_correct += 1;
                    }
                }
            }
            None => {
                row.parent_checked += 1;
                if container_parent.is_none() {
                    row.parent_correct += 1;
                }
            }
        }
    }
}
