//! Renders one entry of an existing MDX/MDD through the real core, for visual checks.
//!
//! `wordnet_fixture <mdx> <mdd> <key> <out-dir>` writes the entry XDict's rewrite and
//! reading style produce, the policy it must run under, and every resource it asks for.
//! Serve `<out-dir>` over HTTP and open `/entry.html`: the rewritten resource URLs are
//! rooted at `/x/`.
//!
//! Never shipped; this is a measuring instrument.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use std::path::{Path, PathBuf};
use std::sync::Arc;

use xdict_core::{
    ByteSource, Config, Core, CoreError, EntryRef, FileIdentity, Location, NoProgress, Opened, PROTOCOL, Package,
    Resource, View,
};

const BASE: &str = "/x/";

struct Bytes(Vec<u8>);

impl ByteSource for Bytes {
    fn size(&self) -> u64 {
        self.0.len() as u64
    }
    fn read_at(&self, offset: u64, len: u32) -> Result<Vec<u8>, CoreError> {
        Ok(self.0[offset as usize..offset as usize + len as usize].to_vec())
    }
    fn identity(&self) -> Option<FileIdentity> {
        Some(FileIdentity { device: 1, inode: 1, size: self.0.len() as u64, mtime_ns: 0, ctime_ns: 0 })
    }
}

fn source(name: &str, bytes: Vec<u8>) -> Location {
    Location::Source { name: name.into(), source: Arc::new(Bytes(bytes)) }
}

fn view() -> View {
    View { base_url: BASE.into(), max_body_bytes: 8 << 20, original_style: false }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 5 {
        eprintln!("usage: wordnet_fixture <mdx> <mdd> <key> <out-dir>");
        std::process::exit(2);
    }
    let mdx_path = Path::new(&args[1]);
    let mdd_path = Path::new(&args[2]);
    let key = &args[3];
    let out = PathBuf::from(&args[4]);

    let package = Package {
        mdx: source(mdx_path.file_name().unwrap().to_str().unwrap(), std::fs::read(mdx_path).unwrap()),
        mdd: vec![source(mdd_path.file_name().unwrap().to_str().unwrap(), std::fs::read(mdd_path).unwrap())],
        sidecars: vec![],
    };
    let core = Core::new(Config { client_protocol: PROTOCOL, entropy: vec![7; 16], ..Config::default() }).unwrap();
    let imported = core.import(package.clone(), &NoProgress).unwrap();
    let Opened::Ready { dict, .. } = core.open(package).unwrap() else { panic!("not open") };
    let entry = EntryRef { edition: imported.edition, key: key.clone(), occurrence: 0 };
    let shown = core.entry(dict.clone(), entry, view()).unwrap();

    std::fs::create_dir_all(&out).unwrap();
    std::fs::write(out.join("raw.html"), &shown.html).unwrap();
    std::fs::write(out.join("csp.txt"), &shown.csp).unwrap();
    let page = format!(
        "<!doctype html><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\
         <meta http-equiv=\"Content-Security-Policy\" content=\"{}\">\
         <style>body{{margin:0;padding:24px;font-family:-apple-system,BlinkMacSystemFont,'SF Pro Text','Helvetica Neue',Arial,sans-serif;line-height:1.45}}\
         .pane{{max-width:460px;margin:0 auto}}</style>\
         <div class=\"pane\">{}</div>",
        shown.csp, shown.html
    );
    std::fs::write(out.join("entry.html"), page).unwrap();

    // Every resource the entry names, at the path the rewriter made.
    for path in ["wordnet.css", "wordnet.js"] {
        match core.resource(dict.clone(), path.into(), view()).unwrap() {
            Resource::Found { bytes, .. } => {
                let to = out.join("x/r").join(path);
                std::fs::create_dir_all(to.parent().unwrap()).unwrap();
                std::fs::write(&to, bytes).unwrap();
                println!("resource {path}: {} bytes", to.metadata().unwrap().len());
            }
            other => println!("resource {path}: {other:?}"),
        }
    }
    println!("entry {key}: {} bytes, occurrence {}", shown.html.len(), shown.entry.occurrence);
    println!("csp {}", shown.csp);
}
