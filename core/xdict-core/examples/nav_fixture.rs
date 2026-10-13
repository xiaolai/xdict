//! The Web harness's entry, rewritten by the core (`plan-core-v1.md` WI-6; `core-api.md` §5.3). Never shipped.
//!
//! - `nav_fixture write <dir>`: writes a dictionary whose entry uses every link form, imports it, and writes
//!   `<dir>/entry.html` (XDict's shim, then the entry as `entry()` rewrites it under `/x/`) and every resource
//!   the entry names, as `resource()` serves it, under `<dir>/x/r/`.
//! - `nav_fixture classify <dir>`: reads `<dir>/caught.json` (`[{"engine", "case", "url"}]`, each URL a path the
//!   shim caught), classifies each through `link()`, and fails unless every engine caught every case and each
//!   means what it should.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use std::path::{Path, PathBuf};
use std::sync::Arc;

use xdict_core::{
    BlockReason, ByteSource, Config, Core, CoreError, EntryRef, FileIdentity, Link, LinkOrigin, Location, NoProgress,
    Opened, PROTOCOL, Package, Resource, View,
};
use xdict_mdx_writer::{Entry, Spec, write};

const BASE: &str = "/x/";

/// A 1×1 PNG, so that the harness can see an image load.
const DOT: &[u8] = b"\x89\x50\x4E\x47\x0D\x0A\x1A\x0A\x00\x00\x00\x0D\x49\x48\x44\x52\x00\x00\x00\x01\x00\x00\x00\x01\x08\x04\x00\x00\x00\xB5\x1C\x0C\x02\x00\x00\x00\x0B\x49\x44\x41\x54\x78\xDA\x63\x64\x60\x00\x00\x00\x06\x00\x02\x30\x81\xD0\x2F\x00\x00\x00\x00\x49\x45\x4E\x44\xAE\x42\x60\x82";

/// What each case of the harness does to the entry, and what it must mean.
const CASES: [(&str, &str); 10] = [
    ("click-entry", "lookup run"),
    ("click-bword", "lookup café"),
    ("click-sound", "sound run.mp3"),
    ("click-tts", "speak hello"),
    ("click-oxford", "lookup very"),
    ("click-remote", "remote https://example.com/x"),
    ("click-anchor-entry", "lookup hue#sense1"),
    ("script-entry", "lookup run"),
    ("script-tts", "speak hello world"),
    ("handler-bword", "lookup hue"),
];

const ENTRY: &str = concat!(
    r#"<link rel="stylesheet" href="nav.css">"#,
    r#"<a id="click-entry" href="entry://run">run</a> "#,
    r#"<a id="click-bword" href="bword://caf&#233;">café</a> "#,
    r#"<a id="click-sound" href="sound://run.mp3">play</a> "#,
    r#"<a id="click-tts" href="sound://hello.tts">say</a> "#,
    r#"<a id="click-oxford" href="d:very">very</a> "#,
    r#"<a id="click-remote" href="https://example.com/x">out</a> "#,
    r#"<a id="click-anchor-entry" href="entry://hue#sense1">hue</a> "#,
    r#"<span id="handler-bword" onclick="location.href='bword://hue'">hue</span> "#,
    r#"<img src="img/dot.png">"#,
    r#"<script>"#,
    r#"const mode = new URLSearchParams(location.search).get('case');"#,
    r#"if (mode === 'script-entry') setTimeout(() => { location.href = 'entry://' + 'run'; }, 50);"#,
    r#"if (mode === 'script-tts') setTimeout(() => { location.href = 'sound://' + 'hello world.tts'; }, 50);"#,
    r#"</script>"#,
);

/// The shim XDict injects before a dictionary's scripts: a Navigation API listener that cancels the view's own
/// routes and reports them, and a capture-phase click listener (WebKit fires no `navigate` for some clicks).
const SHIM: &str = r#"<!doctype html><meta charset="utf-8"><script>
const report = (m) => parent.postMessage(m, '*');
if (window.navigation) {
  navigation.addEventListener('navigate', (e) => {
    const u = new URL(e.destination.url);
    if (u.origin === location.origin && u.pathname.startsWith('/x/')) {
      e.preventDefault();
      report({ kind: 'caught', url: u.pathname + u.hash });
    } else if (u.origin !== location.origin) {
      e.preventDefault();
      report({ kind: 'left', url: u.href });
    }
  });
} else { report({ kind: 'no-navigation-api' }); }
window.addEventListener('error', (e) => report({ kind: 'error', message: String(e.message) }));
</script>"#;

/// The dictionary's bytes through a source, with an identity, so the core can import it.
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

fn view() -> View {
    View { base_url: BASE.into(), max_body_bytes: 1 << 20 }
}

/// A core with the harness's dictionary open, and the entry.
fn opened() -> (Core, String, EntryRef) {
    let mdx =
        write(&Spec::mdx(), &[Entry::text("hue", "a shade"), Entry::text("nav", ENTRY), Entry::text("run", "to run")])
            .unwrap();
    let mdd = write(&Spec::mdd(), &[Entry::bytes("\\run.mp3", b"ID3"), Entry::bytes("\\img\\dot.png", DOT)]).unwrap();
    let css = b"body { background: url(img/dot.png) }".to_vec();
    let source = |name: &str, bytes: Vec<u8>| Location::Source { name: name.into(), source: Arc::new(Bytes(bytes)) };
    let package = Package {
        mdx: source("nav.mdx", mdx),
        mdd: vec![source("nav.mdd", mdd)],
        sidecars: vec![source("nav.css", css)],
    };
    let core = Core::new(Config { client_protocol: PROTOCOL, entropy: vec![7; 16], ..Config::default() }).unwrap();
    let imported = core.import(package.clone(), &NoProgress).unwrap();
    let Opened::Ready { dict, .. } = core.open(package).unwrap() else { panic!("not open") };
    let entry = EntryRef { edition: imported.edition, key: "nav".into(), occurrence: 0 };
    (core, dict, entry)
}

fn write_fixture(dir: &Path) {
    let (core, dict, entry) = opened();
    let shown = core.entry(dict.clone(), entry, view()).unwrap();
    std::fs::create_dir_all(dir).unwrap();
    std::fs::write(dir.join("entry.html"), format!("{SHIM}\n{}", shown.html)).unwrap();
    std::fs::write(dir.join("csp.txt"), &shown.csp).unwrap();
    for path in ["nav.css", "img/dot.png", "run.mp3"] {
        let Resource::Found { bytes, .. } = core.resource(dict.clone(), path.into(), view()).unwrap() else {
            panic!("{path} is missing")
        };
        let to = dir.join("x/r").join(path);
        std::fs::create_dir_all(to.parent().unwrap()).unwrap();
        std::fs::write(to, bytes).unwrap();
    }
    println!("wrote {}", dir.display());
}

fn meaning(link: &Link) -> String {
    match link {
        Link::Lookup { query, anchor: Some(a) } => format!("lookup {query}#{a}"),
        Link::Lookup { query, anchor: None } => format!("lookup {query}"),
        Link::Sound { path } => format!("sound {path}"),
        Link::Speak { text } => format!("speak {text}"),
        Link::Resource { path } => format!("resource {path}"),
        Link::Anchor { name } => format!("anchor {name}"),
        Link::Blocked { why: BlockReason::Remote { url } } => format!("remote {url}"),
        Link::Blocked { why } => format!("blocked {why:?}"),
    }
}

fn classify(dir: &Path) {
    let (core, dict, entry) = opened();
    let caught: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(dir.join("caught.json")).unwrap()).unwrap();
    let caught = caught.as_array().unwrap();
    let mut engines: Vec<&str> = caught.iter().filter_map(|c| c["engine"].as_str()).collect();
    engines.sort_unstable();
    engines.dedup();
    let mut failures = Vec::new();
    for engine in &engines {
        for (case, expected) in CASES {
            let Some(url) =
                caught.iter().find(|c| c["engine"] == *engine && c["case"] == case).and_then(|c| c["url"].as_str())
            else {
                failures.push(format!("{engine} {case}: nothing caught"));
                continue;
            };
            let link = core.link(dict.clone(), url.into(), LinkOrigin::Entry { entry: entry.clone() }, view()).unwrap();
            let got = meaning(&link);
            println!("{engine:9} {case:20} {url:45} {got}");
            if got != expected {
                failures.push(format!("{engine} {case}: {url} means {got:?}, not {expected:?}"));
            }
        }
    }
    if !failures.is_empty() {
        eprintln!("{} failures:\n{}", failures.len(), failures.join("\n"));
        std::process::exit(1);
    }
    if engines.is_empty() {
        eprintln!("nothing was caught by any engine");
        std::process::exit(1);
    }
    println!("{} engines × {} cases caught and classified as expected", engines.len(), CASES.len());
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match (args.first().map(String::as_str), args.get(1)) {
        (Some("write"), Some(dir)) => write_fixture(&PathBuf::from(dir)),
        (Some("classify"), Some(dir)) => classify(&PathBuf::from(dir)),
        (Some("cases"), _) => println!("{}", CASES.map(|(c, _)| c).join(" ")),
        _ => {
            eprintln!("usage: nav_fixture write <dir> | classify <dir> | cases");
            std::process::exit(2);
        }
    }
}
