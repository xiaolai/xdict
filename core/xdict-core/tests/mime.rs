//! Media resources carry the type a WebView needs to play them.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};

use xdict_core::*;
use xdict_mdx_writer::{self as writer, Entry as W, Spec};

struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let n = NEXT.fetch_add(1, Ordering::SeqCst);
        let dir = std::env::temp_dir().join(format!("xdict-mime-{name}-{}-{n}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        Self(dir)
    }
    fn join(&self, name: &str) -> PathBuf {
        self.0.join(name)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn path(p: &Path) -> Location {
    Location::Path { path: p.to_string_lossy().into() }
}

fn mime_of(resource: Resource) -> String {
    match resource {
        Resource::Found { mime, .. } => mime,
        Resource::Missing { path } => panic!("missing: {path}"),
    }
}

#[test]
fn video_and_audio_resources_have_playable_types() {
    let dir = Scratch::new("types");
    let mdx = dir.join("book.mdx");
    let mdd = dir.join("book.mdd");
    std::fs::write(&mdx, writer::write(&Spec::mdx(), &[W::text("book", "<p>media</p>")]).unwrap()).unwrap();
    let resources = [
        W::bytes("\\clip.mp4", b"mp4"),
        W::bytes("\\clip.m4v", b"m4v"),
        W::bytes("\\clip.webm", b"webm"),
        W::bytes("\\word.mp3", b"mp3"),
        W::bytes("\\letter.woff2", b"woff"),
    ];
    std::fs::write(&mdd, writer::write(&Spec::mdd(), &resources).unwrap()).unwrap();

    let package = Package { mdx: path(&mdx), mdd: vec![path(&mdd)], sidecars: vec![] };
    let core = Core::new(Config { client_protocol: PROTOCOL, entropy: vec![1; 16], ..Config::default() }).unwrap();
    let imported = core.import(package.clone(), &NoProgress).unwrap();
    let Opened::Ready { dict, .. } = core.open(package).unwrap() else { panic!("not open") };
    let view = View { base_url: "xdict://d/".into(), max_body_bytes: 1 << 20, original_style: false };

    for (name, want) in [
        ("clip.mp4", "video/mp4"),
        ("clip.m4v", "video/mp4"),
        ("clip.webm", "video/webm"),
        ("word.mp3", "audio/mpeg"),
        ("letter.woff2", "font/woff2"),
    ] {
        let resource = core.resource(dict.clone(), name.into(), view.clone()).unwrap();
        assert_eq!(mime_of(resource), want, "{name}");
    }
    let _ = imported;
}
