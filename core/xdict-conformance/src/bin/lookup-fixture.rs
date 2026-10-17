//! `lookup-fixture <out-dir>`: the dictionaries the macOS main window's checks look words up in (plan-macos-v1 WI-6),
//! written by the core's own MDX writer, so no dictionary content enters the repository. Each folder is one dictionary:
//!
//! - `alpha/`: `apple` (whose first link names `banana`, and whose own CSS says `body{margin:0}`), `banana`, `abbe`
//!   and `abbé` both (the exact one leads, with its reason), a phrase key `take off` beside `take` and `take on`, 120 internal keys `@take_box_000`… (a shape is
//!   internal only as a pattern of the file: ADR-0007 decision 16), whose folded forms begin as `take` does, and
//!   `hop0`…`hop5`, tall entries each linking to the next: a trail.
//! - `beta/`: `abbé` alone (found typed `abbe`, and by a link to `abbe` through tier 2), `apple`, and `see-abbe`, whose link
//!   names `abbe`.
//! - `records/`: 66,355 records under the one key `EC`, as the sentence library files them (ADR-0007 row 23).
//! - `orange` in `alpha/`, `beta/` and `records/`: a headword three dictionaries have, for the All page (parity P15).
//! - `damaged/`: a wrong header checksum; `locked/`: the registration-code bit: refused, each for its reason.
//! - `gone/`: a good dictionary, deleted after it is imported, so its file is missing.
//! - `slow/`: a good dictionary whose import the check holds, so it is indexing while it is asked.
//!
//! Never shipped.

use std::path::Path;
use std::process::ExitCode;

use xdict_mdx_writer::{Defect, Entry, Spec, write};

/// The records filed under `EC` in the sentence library (`core-api.md` §1, row 9).
const RECORDS: usize = 66_355;
/// Internal keys: enough `@…` keys to be a pattern of the file (at least 100, and 0.5 % of its keys).
const INTERNAL: usize = 120;

fn file(path: &Path, spec: &Spec, entries: &[Entry]) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("{}: {e}", parent.display()))?;
    }
    let bytes = write(spec, entries).map_err(|e| format!("{}: {e}", path.display()))?;
    std::fs::write(path, bytes).map_err(|e| format!("{}: {e}", path.display()))
}

fn titled(title: &str) -> Spec {
    Spec { title: title.into(), ..Spec::mdx() }
}

/// A tall entry: a link to the next hop at its top and at its foot, and enough paragraphs between to scroll.
fn hop(n: usize) -> Entry {
    let next = format!("<p><a id=\"next\" href=\"entry://hop{}\">hop{}</a></p>", n + 1, n + 1);
    let body: String = (0..80).map(|p| format!("<p>Paragraph {p} of hop {n}: words to scroll past.</p>")).collect();
    Entry::text(&format!("hop{n}"), &format!("<h1>hop{n}</h1>{next}{body}{next}"))
}

fn write_all(out: &Path) -> Result<(), String> {
    let mut alpha = vec![
        Entry::text(
            "apple",
            "<style>body{margin:0}</style><b>apple</b> in Alpha. See <a href=\"entry://banana\">banana</a>.",
        ),
        Entry::text("banana", "<b>banana</b> in Alpha, reached from apple."),
        Entry::text("abbe", "<b>abbe</b>, written without its accent."),
        Entry::text("abbé", "<b>abbé</b>, written with its accent."),
        Entry::text("take", "<b>take</b>"),
        Entry::text("take off", "<b>take off</b>: to leave the ground."),
        Entry::text("take on", "<b>take on</b>: to accept."),
        // The All page (Apple parity P15): `orange` is in Alpha, Beta and Records, each frame its own. Alpha's own CSS
        // would reach the others' entries if the frames were not isolated.
        Entry::text(
            "orange",
            &format!(
                "<style>p{{color:#b35900}} b{{letter-spacing:0.3em}}</style><b>orange</b> in Alpha.{}",
                (1..=8).map(|n| format!("<p>Sense {n} of orange: a round citrus fruit.</p>")).collect::<String>()
            ),
        ),
    ];
    let internal =
        (0..INTERNAL).map(|i| Entry::text(&format!("@take_box_{i:03}"), "an internal box, reached by a link"));
    alpha.extend(internal);
    alpha.extend((0..=5).map(hop));
    file(&out.join("alpha/alpha.mdx"), &titled("Alpha"), &alpha)?;

    file(
        &out.join("beta/beta.mdx"),
        &titled("Beta"),
        &[
            Entry::text("abbé", "<b>abbé</b> in Beta, which has no unaccented key."),
            Entry::text("apple", "<b>apple</b> in Beta."),
            Entry::text("orange", "<b>orange</b> in Beta.<p>The fruit, and its colour.</p>"),
            Entry::text("see-abbe", "See <a id=\"abbe\" href=\"entry://abbe\">abbe</a>."),
        ],
    )?;

    let mut records: Vec<Entry> = (0..RECORDS).map(|i| Entry::text("EC", &format!("sentence {i}"))).collect();
    records.push(Entry::text("orange", "<b>orange</b> in Records: a fruit in one sentence."));
    file(&out.join("records/records.mdx"), &titled("Records"), &records)?;

    file(
        &out.join("damaged/damaged.mdx"),
        &Spec { defect: Some(Defect::HeaderChecksum), ..titled("Damaged") },
        &[Entry::text("damaged", "never read")],
    )?;
    file(
        &out.join("locked/locked.mdx"),
        &Spec { defect: Some(Defect::RegistrationCodeBit), ..titled("Locked") },
        &[Entry::text("locked", "never read")],
    )?;
    file(&out.join("gone/gone.mdx"), &titled("Gone"), &[Entry::text("gone", "deleted after its import")])?;
    file(&out.join("slow/slow.mdx"), &titled("Slow"), &[Entry::text("slow", "imported while it is asked")])?;
    Ok(())
}

fn main() -> ExitCode {
    let Some(out) = std::env::args_os().nth(1).map(std::path::PathBuf::from) else {
        eprintln!("usage: lookup-fixture <out-dir>");
        return ExitCode::FAILURE;
    };
    match write_all(&out) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("lookup-fixture: {e}");
            ExitCode::FAILURE
        }
    }
}
