//! `service-fixture <out-dir>`: the dictionary the macOS shell's service checks use where they need the service to be
//! busy for a while (plan-macos-v1 WI-3: a lookup killed while it runs, a bulk call stalled past its deadline, a
//! request spanning the idle timer). `slow.mdx` holds `big`, one record of 60 MiB that a lookup reads whole to see
//! whether it is a redirect, and `small`; `slow.mdd` holds `\big.bin`, 63 MiB that `resource()` reads, inflates and
//! returns whole, and `\small.bin`. Both are runs of one byte, so the files are small and the work is not: a reader
//! inflates every byte. `heavy.mdx` is the opposite: 48 MiB of letters that zlib takes only to 31 MB, so an import
//! hashes eight 4 MiB chunks and a `cancel` sent right behind it finds it running. Never shipped.

use std::process::ExitCode;

use xdict_mdx_writer::{Entry, Spec, write};

const MIB: usize = 1 << 20;
const RECORD_BYTES: usize = 60 * MIB;
const RESOURCE_BYTES: usize = 63 * MIB;
const HEAVY_BYTES: usize = 48 * MIB;

/// Lower-case letters and spaces from xorshift64: deterministic, so the file is the same on every run, and with no
/// repetition for zlib to find.
fn noise(len: usize) -> String {
    let mut state: u64 = 0x9E37_79B9_7F4A_7C15;
    let alphabet = b"abcdefghijklmnopqrstuvwxyz ";
    (0..len)
        .map(|_| {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            alphabet.get((state % alphabet.len() as u64) as usize).copied().map_or('a', char::from)
        })
        .collect()
}

fn main() -> ExitCode {
    let Some(out) = std::env::args_os().nth(1).map(std::path::PathBuf::from) else {
        eprintln!("usage: service-fixture <out-dir>");
        return ExitCode::FAILURE;
    };
    let record = "x".repeat(RECORD_BYTES);
    let resource = vec![b'x'; RESOURCE_BYTES];
    let mdx = Spec { block_size: 64 * MIB, ..Spec::mdx() };
    let mdd = Spec { block_size: 64 * MIB, ..Spec::mdd() };
    let written = std::fs::create_dir_all(&out)
        .map_err(|e| e.to_string())
        .and_then(|()| {
            write(&mdx, &[Entry::text("big", &record), Entry::text("small", "a small entry")])
                .map_err(|e| e.to_string())
        })
        .and_then(|bytes| std::fs::write(out.join("slow.mdx"), bytes).map_err(|e| e.to_string()))
        .and_then(|()| {
            write(&mdd, &[Entry::bytes("\\big.bin", &resource), Entry::bytes("\\small.bin", b"small")])
                .map_err(|e| e.to_string())
        })
        .and_then(|bytes| std::fs::write(out.join("slow.mdd"), bytes).map_err(|e| e.to_string()))
        .and_then(|()| write(&mdx, &[Entry::text("noise", &noise(HEAVY_BYTES))]).map_err(|e| e.to_string()))
        .and_then(|bytes| std::fs::write(out.join("heavy.mdx"), bytes).map_err(|e| e.to_string()));
    match written {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("{e}");
            ExitCode::FAILURE
        }
    }
}
