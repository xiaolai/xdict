//! **What a phrase key resolves to, over the reader's dictionaries** (`dev-docs/plan-phrase-recognition.md` WI-1): a
//! key is a lookup target, not proof of phrase-owned meaning, so an evenly spaced sample of each edition's multi-word
//! public keys is looked up through the reader's own path and classified — its own entry, a redirect, a dangling one, a
//! loop, a limit, nothing — with how many records the spelling answers. A measurement, not a gate:
//! `XDICT_MDX_CORPUS=<the 24> cargo test --release -p xdict-core --test phrase_destinations -- --nocapture`. Says
//! "not measured" when the variable is unset.
//!
//! `XDICT_PHRASE_DESTINATIONS_SAMPLE` sets the keys sampled per dictionary (50 by default); the sample itself is chosen
//! evenly over the edition's key positions and never leaves the measuring Mac.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use std::path::{Path, PathBuf};

use xdict_core::{
    Config, Core, HitProblem, How, Location, LookupOptions, MatchMode, NoProgress, Opened, PROTOCOL, Package,
};

fn package(dir: &Path) -> Option<Package> {
    let mut files: Vec<PathBuf> =
        std::fs::read_dir(dir).ok()?.map(|entry| entry.unwrap().path()).filter(|path| path.is_file()).collect();
    files.sort();
    let ext = |p: &Path, e: &str| p.extension().is_some_and(|x| x.eq_ignore_ascii_case(e));
    let mdx = files.iter().find(|p| ext(p, "mdx"))?;
    let locations = |keep: &dyn Fn(&PathBuf) -> bool| -> Vec<Location> {
        files.iter().filter(|p| keep(p)).map(|p| Location::Path { path: p.to_string_lossy().into() }).collect()
    };
    Some(Package {
        mdx: Location::Path { path: mdx.to_string_lossy().into() },
        mdd: locations(&|p| ext(p, "mdd")),
        sidecars: locations(&|p| !ext(p, "mdx") && !ext(p, "mdd")),
    })
}

#[derive(Default)]
struct Classes {
    own: u64,
    redirect: u64,
    dangling: u64,
    loop_: u64,
    limit: u64,
    nothing: u64,
    fan_out: u64,
}

impl Classes {
    fn total(&self) -> u64 {
        self.own + self.redirect + self.dangling + self.loop_ + self.limit + self.nothing + self.fan_out
    }
}

/// One key's class: a problem first (it is why the lookup could not resolve), then the redirect, then the record(s).
fn class(page: &xdict_core::Page) -> &'static str {
    if page.problems.iter().any(|problem| matches!(problem, HitProblem::DanglingRedirect { .. })) {
        return "dangling";
    }
    if page.problems.iter().any(|problem| matches!(problem, HitProblem::RedirectLoop { .. })) {
        return "loop";
    }
    if page.problems.iter().any(|problem| matches!(problem, HitProblem::RedirectLimit { .. })) {
        return "limit";
    }
    if page.hits.len() > 1 {
        return "fanOut";
    }
    match page.hits.first() {
        None => "nothing",
        Some(hit) if matches!(hit.how, How::Redirect { .. }) => "redirect",
        Some(_) => "own",
    }
}

#[test]
fn the_destination_class_of_a_sample_of_phrase_keys_is_counted() {
    let Ok(roots) = std::env::var("XDICT_MDX_CORPUS") else {
        eprintln!("not measured: XDICT_MDX_CORPUS is unset");
        return;
    };
    let wanted: u64 =
        std::env::var("XDICT_PHRASE_DESTINATIONS_SAMPLE").ok().and_then(|value| value.parse().ok()).unwrap_or(50);
    let core = Core::new(Config { client_protocol: PROTOCOL, ..Config::default() }).unwrap();
    let mut folders: Vec<PathBuf> = std::env::split_paths(&roots)
        .flat_map(|root| std::fs::read_dir(root).unwrap().map(|entry| entry.unwrap().path()))
        .filter(|path| path.is_dir())
        .collect();
    folders.sort();
    let mut all = Classes::default();
    eprintln!("file\tkeys\tphrases\tsampled\town\tredirect\tdangling\tloop\tlimit\tnothing\tfanOut");
    for folder in folders {
        let Some(spec) = package(&folder) else { continue };
        let name = folder.file_name().unwrap().to_string_lossy().into_owned();
        let imported = match core.import(spec.clone(), &NoProgress) {
            Ok(imported) => imported,
            Err(error) => {
                eprintln!("{name}\timport failed: {error}");
                continue;
            }
        };
        let Opened::Ready { dict, .. } = core.open(spec).unwrap() else { continue };
        let built = core.phrases_build(dict.clone(), &NoProgress).unwrap();
        // **Every `step`th multi-word public key**, the builder's own filter first: the phrase count is that filter's,
        // so the sample is of what an inventory holds rather than of key positions, where multi-word keys are sparse.
        let step = (built.phrases / wanted.max(1)).max(1);
        let mut classes = Classes::default();
        let mut multi = 0u64;
        let mut sampled = 0u64;
        let options = LookupOptions { limit: 10, offset: 0, mode: MatchMode::Reader, generation: None };
        let mut from = 0u64;
        while let Ok(page) = core.words(dict.clone(), from, 1_000) {
            for key in &page.words {
                if key.split_whitespace().count() < 2 {
                    continue;
                }
                if multi.is_multiple_of(step) && sampled < wanted {
                    sampled += 1;
                    let Ok(answer) = core.lookup(key.clone(), vec![dict.clone()], options.clone()) else { continue };
                    match class(&answer) {
                        "own" => classes.own += 1,
                        "redirect" => classes.redirect += 1,
                        "dangling" => classes.dangling += 1,
                        "loop" => classes.loop_ += 1,
                        "limit" => classes.limit += 1,
                        "nothing" => classes.nothing += 1,
                        "fanOut" => classes.fan_out += 1,
                        _ => {}
                    }
                    if sampled == wanted {
                        break;
                    }
                }
                multi += 1;
            }
            if page.words.is_empty() || page.next <= from {
                break;
            }
            from = page.next;
        }
        eprintln!(
            "{name}\t{}\t{}\t{sampled}\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
            imported.info.keys,
            built.phrases,
            classes.own,
            classes.redirect,
            classes.dangling,
            classes.loop_,
            classes.limit,
            classes.nothing,
            classes.fan_out
        );
        all.own += classes.own;
        all.redirect += classes.redirect;
        all.dangling += classes.dangling;
        all.loop_ += classes.loop_;
        all.limit += classes.limit;
        all.nothing += classes.nothing;
        all.fan_out += classes.fan_out;
        core.close(dict).unwrap();
    }
    assert!(all.total() > 0, "no multi-word key was sampled");
    eprintln!(
        "ALL\tsampled {}\town {}\tredirect {}\tdangling {}\tloop {}\tlimit {}\tnothing {}\tfanOut {}",
        all.total(),
        all.own,
        all.redirect,
        all.dangling,
        all.loop_,
        all.limit,
        all.nothing,
        all.fan_out
    );
}
