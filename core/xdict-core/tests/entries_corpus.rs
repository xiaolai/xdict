//! Entries of real dictionaries through the core, as a shell meets them (`plan-core-v1.md` WI-6):
//! `XDICT_MDX_CORPUS=<the 25> cargo test --release -p xdict-core --test entries_corpus -- --nocapture`. Says
//! "not measured" when the variable is unset.
//!
//! `XDICT_ENTRIES_SAMPLE_OUT=<file>` also writes the sample it rendered, as JSON `[{dict, key, occurrence}]`, `dict`
//! the dictionary's folder name: the macOS entry view renders the same entries (plan-macos-v1 WI-4, `Tools/e2e.sh`
//! stage `entries`), since the bindings cannot enumerate a file's keys.
//!
//! Each folder is imported as a package (its MDX, its MDD volumes in order, its other files as sidecars). For a
//! sample of entries: every URL written in the record classifies (none an unknown scheme); every URL of the
//! rewritten entry, and of the stylesheets it loads, goes through `link()`; every resource and sound resolves
//! or is reported missing by name, never an error.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use xdict_core::{
    BlockReason, Config, Core, EntryRef, Link, LinkOrigin, Location, NoProgress, Opened, PROTOCOL, Package, Resource,
    View,
};
use xdict_mdx::File;

const BASE: &str = "xdict://d/";
const SAMPLE: usize = 400;

fn view() -> View {
    View { base_url: BASE.into(), max_body_bytes: 64 << 20 }
}

/// A folder's package: `X.mdd` before `X.1.mdd` before `X.2.mdd`, every other file a sidecar.
fn package(dir: &Path) -> Option<(PathBuf, Package)> {
    let mut files: Vec<PathBuf> =
        std::fs::read_dir(dir).ok()?.map(|e| e.unwrap().path()).filter(|p| p.is_file()).collect();
    files.sort();
    let ext = |p: &Path, e: &str| p.extension().is_some_and(|x| x.eq_ignore_ascii_case(e));
    let mdx = files.iter().find(|p| ext(p, "mdx"))?.clone();
    let mut mdd: Vec<&PathBuf> = files.iter().filter(|p| ext(p, "mdd")).collect();
    let volume = |p: &Path| -> u32 {
        let stem = p.file_stem().unwrap().to_string_lossy().into_owned();
        stem.rsplit_once('.').and_then(|(_, n)| n.parse().ok()).map_or(0, |n: u32| n + 1)
    };
    mdd.sort_by_key(|p| volume(p));
    let location = |p: &Path| Location::Path { path: p.to_string_lossy().into_owned() };
    let hidden = |p: &Path| p.file_name().unwrap().to_string_lossy().starts_with('.');
    let sidecars =
        files.iter().filter(|p| !ext(p, "mdx") && !ext(p, "mdd") && !hidden(p)).map(|p| location(p)).collect();
    let package = Package { mdx: location(&mdx), mdd: mdd.into_iter().map(|p| location(p)).collect(), sidecars };
    Some((mdx, package))
}

/// The unknown schemes that are expected: OALECD's actions of Oxford's own app (`help:bre`, `addexample:<id>`,
/// `xid:<id>`), which a reader has nothing to do with. Its lookups (`d:`, `x:`, `xi:`, `xp:`) are classified.
fn oxford_action(dict: &str, unknown: &str) -> bool {
    let scheme = unknown.split(':').next().unwrap_or("");
    dict == "oalecd" && (scheme.starts_with("help") || scheme.starts_with("add") || scheme == "xid")
}

/// The URLs under the base in rewritten text.
fn routes(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut rest = text;
    while let Some(at) = rest.find(BASE) {
        let from = &rest[at..];
        let end = from.find(['"', '\'', ')', ' ', '>', '<', '\n']).unwrap_or(from.len());
        out.push(from[..end].to_owned());
        rest = &from[end..];
    }
    out
}

#[derive(Default)]
struct Tally {
    entries: usize,
    written: BTreeMap<&'static str, usize>,
    unknown: BTreeSet<String>,
    resources: BTreeSet<String>,
    missing: BTreeSet<String>,
    lossy: u64,
}

/// Follows one URL through `link()` and, for a resource or sound, `resource()`; a stylesheet's own URLs too.
fn follow(core: &Core, dict: &str, url: &str, origin: LinkOrigin, tally: &mut Tally, failures: &mut Vec<String>) {
    let link = match core.link(dict.into(), url.into(), origin, view()) {
        Ok(link) => link,
        Err(e) => return failures.push(format!("link({url}): {e:?}")),
    };
    let path = match &link {
        Link::Resource { path } | Link::Sound { path } => path.clone(),
        Link::Blocked { why: BlockReason::UnknownScheme { scheme } } => {
            tally.unknown.insert(format!("{scheme}: {url}"));
            return;
        }
        _ => return,
    };
    if !tally.resources.insert(path.clone()) {
        return;
    }
    match core.resource(dict.into(), path.clone(), view()) {
        Ok(Resource::Found { mime, bytes, path: found }) => {
            if mime == "text/css" {
                for inner in routes(&String::from_utf8_lossy(&bytes)) {
                    let origin = LinkOrigin::Resource { path: found.clone() };
                    follow(core, dict, &inner, origin, tally, failures);
                }
            }
        }
        Ok(Resource::Missing { path }) => {
            tally.missing.insert(path);
        }
        Err(e) => failures.push(format!("resource({path}): {e:?}")),
    }
}

#[test]
fn entries_of_the_corpus() {
    let Ok(dirs) = std::env::var("XDICT_MDX_CORPUS") else {
        eprintln!("not measured: XDICT_MDX_CORPUS is unset");
        return;
    };
    let cache = std::env::temp_dir().join(format!("xdict-entries-{}", std::process::id()));
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
    let mut failures = Vec::new();
    let mut totals = Tally::default();
    let mut sampled = Vec::new();
    for folder in folders {
        let Some((mdx_path, package)) = package(&folder) else { continue };
        let name = folder.file_name().unwrap().to_string_lossy().into_owned();
        let imported = core.import(package.clone(), &NoProgress).unwrap();
        let Opened::Ready { dict, edition, .. } = core.open(package).unwrap() else { panic!("{name}: not open") };
        let file = File::open(&mdx_path).unwrap();
        let step = (file.len() / SAMPLE).max(1);
        let mut tally = Tally::default();
        let mut seen = BTreeMap::new();
        for i in (0..file.len()).step_by(step) {
            let key = file.key(i).unwrap().into_owned();
            let occurrence = file.find(&key).unwrap().iter().filter(|&&j| file.key(j).unwrap() == key && j < i).count();
            let record = file.record(i).unwrap();
            let text = String::from_utf8_lossy(&record.data);
            if text.trim_start().starts_with("@@@LINK=") {
                continue;
            }
            for written in xdict_entry::html(&text, BASE).links {
                let k = match written.link {
                    xdict_entry::Link::Blocked(xdict_entry::Block::UnknownScheme { scheme }) => {
                        tally.unknown.insert(format!("{scheme}: {}", written.url));
                        "unknown"
                    }
                    xdict_entry::Link::Lookup { .. } => "lookup",
                    xdict_entry::Link::Resource { .. } => "resource",
                    xdict_entry::Link::Sound { .. } => "sound",
                    xdict_entry::Link::Speak { .. } => "speak",
                    xdict_entry::Link::Anchor { .. } => "anchor",
                    xdict_entry::Link::Blocked(xdict_entry::Block::Remote { .. }) => "remote",
                    xdict_entry::Link::Blocked(xdict_entry::Block::Script) => "script",
                };
                *tally.written.entry(k).or_default() += 1;
            }
            let entry = EntryRef { edition: edition.clone(), key: key.clone(), occurrence: occurrence as u32 };
            let shown = match core.entry(dict.clone(), entry.clone(), view()) {
                Ok(shown) => shown,
                Err(e) => {
                    failures.push(format!("{name}: entry {key:?}/{occurrence}: {e:?}"));
                    continue;
                }
            };
            tally.entries += 1;
            tally.lossy += shown.lossy_bytes;
            sampled.push(serde_json::json!({"dict": name, "key": key, "occurrence": occurrence}));
            *seen.entry(key).or_insert(0) += 1;
            for url in routes(&shown.html) {
                follow(&core, &dict, &url, LinkOrigin::Entry { entry: entry.clone() }, &mut tally, &mut failures);
            }
        }
        let missing: Vec<&String> = tally.missing.iter().take(6).collect();
        eprintln!(
            "{name:10} {} entries ({} problems at import); written links {:?}; lossy bytes {}; resources {} named, {} \
             missing {missing:?}",
            tally.entries,
            imported.problems.len(),
            tally.written,
            tally.lossy,
            tally.resources.len(),
            tally.missing.len(),
        );
        for u in &tally.unknown {
            if !oxford_action(&name, u) {
                failures.push(format!("{name}: an unknown scheme: {u}"));
            }
        }
        totals.entries += tally.entries;
        totals.lossy += tally.lossy;
        for (k, n) in tally.written {
            *totals.written.entry(k).or_default() += n;
        }
        totals.resources.extend(tally.resources.into_iter().map(|r| format!("{name}/{r}")));
        totals.missing.extend(tally.missing.into_iter().map(|r| format!("{name}/{r}")));
        core.close(dict).unwrap();
    }
    eprintln!(
        "{} entries; written links {:?}; {} resources named, {} missing; {} lossy bytes",
        totals.entries,
        totals.written,
        totals.resources.len(),
        totals.missing.len(),
        totals.lossy
    );
    let _ = std::fs::remove_dir_all(&cache);
    if let Ok(out) = std::env::var("XDICT_ENTRIES_SAMPLE_OUT") {
        std::fs::write(&out, serde_json::Value::Array(sampled).to_string()).unwrap();
        eprintln!("sample written to {out}");
    }
    assert!(failures.is_empty(), "{} failures:\n{}", failures.len(), failures.join("\n"));
}

/// MDict's compact styles on the real files that declare them (`core-api.md` finding 14: 30 of the 330):
/// `XDICT_MDX_STYLESHEET_CORPUS=<dirs>`. Every file's `StyleSheet` must parse to as many styles as it numbers
/// (a misaligned parse loses or shifts them). A marker naming no style is the dictionary's own (four of the 29
/// files use `` `14` `` or `` `29` ``, which their headers never define): left as text, and counted.
#[test]
fn stylesheets_of_the_wider_set() {
    let Ok(dirs) = std::env::var("XDICT_MDX_STYLESHEET_CORPUS") else {
        eprintln!("not measured: XDICT_MDX_STYLESHEET_CORPUS is unset");
        return;
    };
    let mut files: Vec<PathBuf> = std::env::split_paths(&dirs)
        .flat_map(|d| std::fs::read_dir(d).unwrap().map(|e| e.unwrap().path()))
        .filter(|p| p.extension().is_some_and(|e| e.eq_ignore_ascii_case("mdx")))
        .collect();
    files.sort();
    let (mut with_sheet, mut records, mut marked, mut markers, mut failures) = (0, 0, 0, 0, Vec::new());
    let mut undefined = 0;
    for path in files {
        let Ok(file) = File::open(&path) else { continue };
        let text = file.header().stylesheet.clone();
        if text.trim().is_empty() {
            continue;
        }
        with_sheet += 1;
        let sheet = xdict_entry::StyleSheet::parse(&text);
        let numbered =
            text.lines().map(str::trim).filter(|l| !l.is_empty() && l.bytes().all(|b| b.is_ascii_digit())).count();
        if sheet.len() != numbered {
            failures.push(format!("{}: {} styles parsed of {numbered} numbered", path.display(), sheet.len()));
            continue;
        }
        let step = (file.len() / 200).max(1);
        for i in (0..file.len()).step_by(step) {
            let Ok(record) = file.record(i) else { continue };
            let record = String::from_utf8_lossy(&record.data);
            records += 1;
            let n = record.matches('`').count() / 2;
            if n == 0 {
                continue;
            }
            marked += 1;
            markers += n;
            let applied = sheet.apply(&record);
            let left: Vec<&str> = applied.split('`').skip(1).step_by(2).filter(|m| m.parse::<u32>().is_ok()).collect();
            undefined += left.len();
        }
    }
    eprintln!(
        "{with_sheet} files with a StyleSheet; {records} records sampled, {marked} with {markers} markers, {undefined} \
         naming no style"
    );
    assert!(with_sheet > 0, "no file with a StyleSheet was found: not measured");
    assert!(failures.is_empty(), "{} failures:\n{}", failures.len(), failures.join("\n"));
}
