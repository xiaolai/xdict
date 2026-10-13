//! `memory-fixture <out-dir>`: the dictionary ADR-0007's refutation 24 is measured with. `big.mdx` holds one
//! entry `big` of about 50 MiB of links (each rewritten by `entry()`) and `small`; `big.mdd` holds `\big.css`,
//! about 44 MiB of `url()`s (each rewritten by `resource()`), which rewrites to 60.8 MiB: near the most the
//! core serves (`MAX_RESOURCE_BYTES`, 64 MiB; at 48 MiB it rewrote to 66.4 and was refused). Never shipped.

use std::process::ExitCode;

use xdict_mdx_writer::{Entry, Spec, write};

const MIB: usize = 1 << 20;

fn main() -> ExitCode {
    let Some(out) = std::env::args_os().nth(1).map(std::path::PathBuf::from) else {
        eprintln!("usage: memory-fixture <out-dir>");
        return ExitCode::FAILURE;
    };
    let body = r#"<a href="entry://word">word</a> <img src="img/a.png"> "#.repeat(48 * MIB / 51);
    let css = "b { background: url(img/a.png) }\n".repeat(44 * MIB / 34);
    let spec = Spec { block_size: 64 * MIB, ..Spec::mdx() };
    let mdd = Spec { block_size: 64 * MIB, ..Spec::mdd() };
    let written = std::fs::create_dir_all(&out)
        .map_err(|e| e.to_string())
        .and_then(|()| {
            write(&spec, &[Entry::text("big", &body), Entry::text("small", "a small entry")]).map_err(|e| e.to_string())
        })
        .and_then(|mdx| std::fs::write(out.join("big.mdx"), mdx).map_err(|e| e.to_string()))
        .and_then(|()| write(&mdd, &[Entry::bytes("\\big.css", css.as_bytes())]).map_err(|e| e.to_string()))
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
