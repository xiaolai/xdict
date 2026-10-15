//! `library-fixture <out-dir>`: the packages the macOS library's checks import (plan-macos-v1 WI-5), written by the
//! core's own MDX writer, so no dictionary content enters the repository. Each folder is one situation a reader meets:
//!
//! - `file/single.mdx`: one dictionary chosen as a file.
//! - `folder/vol/`: `vol.mdx` with three volumes and a stylesheet beside it. `shared.bin` is in volumes 0 and 1 with
//!   different bytes, so the bytes a lookup gets say which volume was searched first.
//! - `gap/`: `gap.mdx`, `gap.mdd` and `gap.2.mdd`: `gap.1.mdd` is missing.
//! - `drop/dropped.mdx`: the dictionary the drag-and-drop check drops.
//! - `refused/`: `v3/` (a format 3.0 resource library beside a good MDX), `regcode/` (the registration-code bit) and
//!   `damaged/` (a wrong header checksum): each refused with its own reason.
//! - `lang/`: a file whose name states its languages (and whose title is the editor's placeholder), and one whose name
//!   does not.
//! - `escape/esc/`: `esc.css` is a symbolic link to `outside/secret.css`, outside the folder a reader would choose.
//! - `sounds/`: an entry naming a playable recording, one in a format macOS does not play, and one the package lacks.
//! - `rewrite/`: two editions of one dictionary, for a file rewritten under the library.
//! - `big/big.mdx`: 128 MiB stored uncompressed (so it costs no time to write), which an import hashes in 32 reports
//!   of 4 MiB: long enough for a cancel to reach it running, and for lookups to be answered while it runs.
//!
//! Never shipped.

use std::path::Path;
use std::process::ExitCode;

use xdict_mdx_writer::{Compression, Defect, Entry, Spec, Version, write};

const MIB: usize = 1 << 20;

/// Writes one dictionary file.
fn file(path: &Path, spec: &Spec, entries: &[Entry]) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("{}: {e}", parent.display()))?;
    }
    let bytes = write(spec, entries).map_err(|e| format!("{}: {e}", path.display()))?;
    std::fs::write(path, bytes).map_err(|e| format!("{}: {e}", path.display()))
}

/// Writes a plain file beside the dictionaries.
fn plain(path: &Path, bytes: &[u8]) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("{}: {e}", parent.display()))?;
    }
    std::fs::write(path, bytes).map_err(|e| format!("{}: {e}", path.display()))
}

fn titled(title: &str) -> Spec {
    Spec { title: title.into(), ..Spec::mdx() }
}

fn write_all(out: &Path) -> Result<(), String> {
    let mdd = Spec::mdd();
    file(
        &out.join("file/single.mdx"),
        &titled("Single File"),
        &[Entry::text("apple", "<b>apple</b> a fruit"), Entry::text("banana", "<b>banana</b> another fruit")],
    )?;

    let vol = out.join("folder/vol");
    file(
        &vol.join("vol.mdx"),
        &titled("Volumes"),
        &[Entry::text(
            "volumes",
            "<link rel=\"stylesheet\" href=\"vol.css\"><img src=\"a.bin\"><img src=\"b.bin\"><img src=\"c.bin\">",
        )],
    )?;
    file(
        &vol.join("vol.mdd"),
        &mdd,
        &[Entry::bytes("\\a.bin", b"volume 0"), Entry::bytes("\\shared.bin", b"shared from volume 0")],
    )?;
    file(
        &vol.join("vol.1.mdd"),
        &mdd,
        &[Entry::bytes("\\b.bin", b"volume 1"), Entry::bytes("\\shared.bin", b"shared from volume 1")],
    )?;
    file(&vol.join("vol.2.mdd"), &mdd, &[Entry::bytes("\\c.bin", b"volume 2")])?;
    plain(&vol.join("vol.css"), b".vol { float: left }\n")?;

    let gap = out.join("gap");
    file(&gap.join("gap.mdx"), &titled("Gap"), &[Entry::text("gap", "a dictionary missing its second volume")])?;
    file(&gap.join("gap.mdd"), &mdd, &[Entry::bytes("\\first.bin", b"volume 0")])?;
    file(&gap.join("gap.2.mdd"), &mdd, &[Entry::bytes("\\third.bin", b"volume 2")])?;

    file(&out.join("drop/dropped.mdx"), &titled("Dropped"), &[Entry::text("dropped", "arrived by drag and drop")])?;

    let refused = out.join("refused");
    file(&refused.join("v3/v3.mdx"), &titled("Format Three Resources"), &[Entry::text("three", "an entry")])?;
    file(
        &refused.join("v3/v3.mdd"),
        &Spec { version: Version::V3_0, ..Spec::mdd() },
        &[Entry::bytes("\\x.bin", b"x")],
    )?;
    file(
        &refused.join("regcode/regcode.mdx"),
        &Spec { defect: Some(Defect::RegistrationCodeBit), ..titled("Locked") },
        &[Entry::text("locked", "never read")],
    )?;
    file(
        &refused.join("damaged/damaged.mdx"),
        &Spec { defect: Some(Defect::HeaderChecksum), ..titled("Damaged") },
        &[Entry::text("damaged", "never read")],
    )?;

    // The title is the placeholder MdxBuilder leaves, so the name the reader sees comes from the file.
    file(
        &out.join("lang/牛津高阶英汉双解词典.mdx"),
        &titled("Title (No HTML code allowed)"),
        &[Entry::text("ox", "牛")],
    )?;
    file(&out.join("lang/Plain Glossary.mdx"), &titled("Plain Glossary"), &[Entry::text("term", "a term")])?;

    let esc = out.join("escape/esc");
    file(&esc.join("esc.mdx"), &titled("Escape"), &[Entry::text("esc", "<link rel=\"stylesheet\" href=\"esc.css\">")])?;
    plain(&out.join("outside/secret.css"), b"/* outside the folder the reader chose */\n")?;
    let link = esc.join("esc.css");
    let _ = std::fs::remove_file(&link);
    std::os::unix::fs::symlink("../../outside/secret.css", &link).map_err(|e| format!("{}: {e}", link.display()))?;

    let sounds = out.join("sounds");
    file(
        &sounds.join("sounds.mdx"),
        &titled("Sounds"),
        &[Entry::text(
            "sounds",
            "<a href=\"sound://here.mp3\">here</a> <a href=\"sound://present.spx\">speex</a> \
         <a href=\"sound://gone.mp3\">gone</a>",
        )],
    )?;
    file(
        &sounds.join("sounds.mdd"),
        &mdd,
        &[
            Entry::bytes("\\here.mp3", b"ID3 not really a recording"),
            Entry::bytes("\\present.spx", b"Speex not really a recording"),
        ],
    )?;

    let rewrite = out.join("rewrite");
    file(&rewrite.join("first.mdx"), &titled("Rewrite"), &[Entry::text("word", "the first edition")])?;
    file(&rewrite.join("second.mdx"), &titled("Rewrite"), &[Entry::text("word", "the second edition, rewritten")])?;

    let record = "x".repeat(4 * MIB);
    let big: Vec<Entry> = (0..32).map(|n| Entry::text(&format!("big{n:02}"), &record)).collect();
    let stored = Spec { compression: Compression::None, block_size: 4 * MIB, ..titled("Big") };
    file(&out.join("big/big.mdx"), &stored, &big)?;
    Ok(())
}

fn main() -> ExitCode {
    let Some(out) = std::env::args_os().nth(1).map(std::path::PathBuf::from) else {
        eprintln!("usage: library-fixture <out-dir>");
        return ExitCode::FAILURE;
    };
    match write_all(&out) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("library-fixture: {e}");
            ExitCode::FAILURE
        }
    }
}
