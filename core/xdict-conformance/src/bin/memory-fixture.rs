//! `memory-fixture <out-dir>`: the dictionary ADR-0007's refutation 24 is measured with. `big.mdx` holds one
//! entry `big` of about 50 MiB of links (each rewritten by `entry()`) and `small`; `big.mdd` holds `\big.css`,
//! about 44 MiB of `url()`s (each rewritten by `resource()`), which rewrites to 60.8 MiB: near the most the
//! core serves (`MAX_RESOURCE_BYTES`, 64 MiB; at 48 MiB it rewrote to 66.4 and was refused), and `\img\a.png`, the
//! image the body names: a missing one is dropped (S13), which would shrink the body under the refused view.
//! Never shipped.

use std::process::ExitCode;

use xdict_mdx_writer::{Entry, Spec, write};

const MIB: usize = 1 << 20;

/// One link the body repeats, and one rule the stylesheet does.
const LINK: &str = r#"<a href="entry://word">word</a> <img src="img/a.png"> "#;
/// A `mask-image`, not a `background`: backgrounds are dropped (Plain by default), and the sheet must still be
/// rewritten URL by URL.
const RULE: &str = "b { mask-image: url(img/a.png) }\n";

/// The sizes measured with (`dev-docs/measurements/2026-10-14-memory/`), each a whole number of its template.
const BODY_BYTES: usize = 53_292_330;
const CSS_BYTES: usize = 44_780_340;

fn main() -> ExitCode {
    let Some(out) = std::env::args_os().nth(1).map(std::path::PathBuf::from) else {
        eprintln!("usage: memory-fixture <out-dir>");
        return ExitCode::FAILURE;
    };
    if !BODY_BYTES.is_multiple_of(LINK.len()) || !CSS_BYTES.is_multiple_of(RULE.len()) {
        eprintln!("a size is not a whole number of its template");
        return ExitCode::FAILURE;
    }
    let body = LINK.repeat(BODY_BYTES / LINK.len());
    let css = RULE.repeat(CSS_BYTES / RULE.len());
    let spec = Spec { block_size: 64 * MIB, ..Spec::mdx() };
    let mdd = Spec { block_size: 64 * MIB, ..Spec::mdd() };
    let written = std::fs::create_dir_all(&out)
        .map_err(|e| e.to_string())
        .and_then(|()| {
            write(&spec, &[Entry::text("big", &body), Entry::text("small", "a small entry")]).map_err(|e| e.to_string())
        })
        .and_then(|mdx| std::fs::write(out.join("big.mdx"), mdx).map_err(|e| e.to_string()))
        .and_then(|()| {
            write(&mdd, &[Entry::bytes("\\big.css", css.as_bytes()), Entry::bytes("\\img\\a.png", b"png")])
                .map_err(|e| e.to_string())
        })
        .and_then(|bytes| std::fs::write(out.join("big.mdd"), bytes).map_err(|e| e.to_string()));
    match written {
        Ok(()) => {
            println!("body {} bytes, stylesheet {} bytes", body.len(), css.len());
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("{e}");
            ExitCode::FAILURE
        }
    }
}
