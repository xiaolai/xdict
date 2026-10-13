//! Where an import's time goes, per phase, over every file under a folder. Never shipped. With
//! `XDICT_PROFILE_PLAIN=1`, dictionaries are indexed without the lookup policy, to measure what it costs.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]
use std::time::Instant;
use xdict_mdx::{DiskFile, File, Kind};

fn main() {
    let root = std::env::args().nth(1).unwrap();
    let mut files = Vec::new();
    let mut stack = vec![(std::path::PathBuf::from(root), 0)];
    while let Some((dir, depth)) = stack.pop() {
        for e in std::fs::read_dir(&dir).unwrap().flatten() {
            let p = e.path();
            if p.is_dir() && depth < 2 {
                stack.push((p, depth + 1));
            } else if p.extension().is_some_and(|x| x.eq_ignore_ascii_case("mdx") || x.eq_ignore_ascii_case("mdd")) {
                files.push(p);
            }
        }
    }
    let (mut hash, mut build_mdx, mut build_mdd, mut bytes) = (0f64, 0f64, 0f64, 0u64);
    for p in &files {
        let mdd = p.extension().is_some_and(|x| x.eq_ignore_ascii_case("mdd"));
        let source = DiskFile::open(p).unwrap();
        if !mdd {
            let t = Instant::now();
            let h = xdict_identity::hash::<std::io::Error>(&source, |_| Ok(())).unwrap();
            hash += t.elapsed().as_secs_f64();
            bytes += xdict_mdx::Source::len(&source);
            let t = Instant::now();
            if std::env::var_os("XDICT_PROFILE_PLAIN").is_some() {
                File::build_index(&source, Some(Kind::Mdx), h.digest, &xdict_mdx::index::Plain).unwrap();
            } else {
                File::build_index(&source, Some(Kind::Mdx), h.digest, &xdict_lookup::Policy).unwrap();
            }
            build_mdx += t.elapsed().as_secs_f64();
        } else {
            let t = Instant::now();
            File::build_index(&source, Some(Kind::Mdd), [0; 32], &xdict_mdx::index::Plain).unwrap();
            build_mdd += t.elapsed().as_secs_f64();
        }
    }
    println!(
        "hash {:.2} s over {:.2} GB ({:.2} GB/s); build mdx {:.2} s; build mdd {:.2} s",
        hash,
        bytes as f64 / 1e9,
        bytes as f64 / 1e9 / hash,
        build_mdx,
        build_mdd
    );
}
