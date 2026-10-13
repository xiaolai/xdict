//! Import and open against real files (ADR-0002; `plan-core-v1.md` WI-4; Codex objections 5, 6, 7 and 9).
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::time::Duration;

use xdict_core::*;
use xdict_mdx_writer::{self as writer, Entry as W, Spec};

struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let n = NEXT.fetch_add(1, Ordering::SeqCst);
        let dir = std::env::temp_dir().join(format!("xdict-identity-{name}-{}-{n}", std::process::id()));
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

fn core(data: &Scratch, cache: &str) -> Core {
    let config = Config {
        client_protocol: PROTOCOL,
        data_dir: Some(data.join("data").to_string_lossy().into()),
        cache_dir: Some(data.join(cache).to_string_lossy().into()),
        entropy: vec![],
    };
    Core::new(config).unwrap()
}

fn path(p: &Path) -> Location {
    Location::Path { path: p.to_string_lossy().into() }
}

fn alone(p: &Path) -> Package {
    Package { mdx: path(p), mdd: vec![], sidecars: vec![] }
}

fn mdx(text: &str) -> Vec<u8> {
    writer::write(&Spec::mdx(), &[W::text("run", text), W::text("walk", "on foot")]).unwrap()
}

fn ready(opened: Opened) -> (String, String) {
    match opened {
        Opened::Ready { dict, edition, .. } => (dict, edition),
        other => panic!("not open: {other:?}"),
    }
}

fn reason(opened: Opened) -> ImportReason {
    match opened {
        Opened::NeedsImport { reason } => reason,
        other => panic!("opened: {other:?}"),
    }
}

#[test]
fn a_moved_file_keeps_its_edition_and_lineage() {
    let dir = Scratch::new("moved");
    std::fs::create_dir_all(dir.join("a")).unwrap();
    std::fs::create_dir_all(dir.join("b")).unwrap();
    let (from, to) = (dir.join("a/x.mdx"), dir.join("b/renamed.mdx"));
    std::fs::write(&from, mdx("to move fast")).unwrap();
    let core = core(&dir, "cache");
    let first = core.import(alone(&from), &NoProgress).unwrap();
    std::fs::rename(&from, &to).unwrap();
    // A path is never an identity: the new place is new to the registry, its file is not.
    assert_eq!(reason(core.open(alone(&to)).unwrap()), ImportReason::New);
    let again = core.import(alone(&to), &NoProgress).unwrap();
    assert_eq!((again.edition, again.lineage), (first.edition, first.lineage));
    ready(core.open(alone(&to)).unwrap());
}

/// ADR-0002's measurement, as a test: equal size, mtime restored, and the change is still seen, by ctime.
#[test]
fn an_in_place_rewrite_at_equal_size_and_mtime_is_caught() {
    let dir = Scratch::new("rewrite");
    let file = dir.join("x.mdx");
    let (before, after) = (mdx("AAAA meaning"), mdx("BBBB meaning"));
    assert_eq!(before.len(), after.len());
    std::fs::write(&file, &before).unwrap();
    let core = core(&dir, "cache");
    let first = core.import(alone(&file), &NoProgress).unwrap();
    ready(core.open(alone(&file)).unwrap());

    let mtime = std::fs::metadata(&file).unwrap().modified().unwrap();
    std::thread::sleep(Duration::from_millis(20));
    {
        use std::io::{Seek, Write};
        let mut f = std::fs::OpenOptions::new().write(true).open(&file).unwrap();
        f.seek(std::io::SeekFrom::Start(0)).unwrap();
        f.write_all(&after).unwrap();
        f.set_modified(mtime).unwrap();
    }
    let now = std::fs::metadata(&file).unwrap();
    assert_eq!((now.len(), now.modified().unwrap()), (before.len() as u64, mtime), "size and mtime look unchanged");
    assert_eq!(reason(core.open(alone(&file)).unwrap()), ImportReason::Changed);
    let second = core.import(alone(&file), &NoProgress).unwrap();
    assert_ne!(second.edition, first.edition, "the rewrite is another edition");
}

#[test]
fn two_copies_register_one_edition() {
    let dir = Scratch::new("copies");
    let (a, b) = (dir.join("a.mdx"), dir.join("b.mdx"));
    std::fs::write(&a, mdx("same")).unwrap();
    std::fs::copy(&a, &b).unwrap();
    let core = core(&dir, "cache");
    let first = core.import(alone(&a), &NoProgress).unwrap();
    let second = core.import(alone(&b), &NoProgress).unwrap();
    assert_eq!((&first.edition, &first.lineage), (&second.edition, &second.lineage));
    let (one, e1) = ready(core.open(alone(&a)).unwrap());
    let (two, e2) = ready(core.open(alone(&b)).unwrap());
    assert_ne!(one, two, "two locations open as two handles");
    assert_eq!(e1, e2);
}

/// Codex objection 7: the registry is the reader's data and the cache is disposable. A new core with the
/// registry and an empty cache asks for an import, and the import finds the lineage it had.
#[test]
fn an_empty_cache_with_the_registry_keeps_the_lineage() {
    let dir = Scratch::new("restore");
    let file = dir.join("x.mdx");
    std::fs::write(&file, mdx("kept")).unwrap();
    let first = core(&dir, "cache-1").import(alone(&file), &NoProgress).unwrap();
    let restored = core(&dir, "cache-2");
    assert_eq!(reason(restored.open(alone(&file)).unwrap()), ImportReason::IndexMissing);
    let again = restored.import(alone(&file), &NoProgress).unwrap();
    assert_eq!(again.lineage, first.lineage);
    ready(restored.open(alone(&file)).unwrap());
}

fn volume(dir: &Scratch, name: &str, css: &str, extra: &str) -> PathBuf {
    let path = dir.join(name);
    let entries = [W::bytes("\\a.css", css.as_bytes()), W::bytes(&format!("\\{extra}"), b"only here")];
    std::fs::write(&path, writer::write(&Spec::mdd(), &entries).unwrap()).unwrap();
    path
}

fn resource_text(core: &Core, dict: &str, path: &str) -> String {
    let view = View { base_url: "xdict://d/".into(), max_body_bytes: 1 << 20 };
    match core.resource(dict.into(), path.into(), view).unwrap() {
        Resource::Found { bytes, .. } => String::from_utf8(bytes).unwrap(),
        Resource::Missing { .. } => "missing".into(),
    }
}

fn index_files(dir: &Path) -> Vec<(PathBuf, std::time::SystemTime)> {
    let mut files: Vec<_> = std::fs::read_dir(dir)
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| p.extension().is_some_and(|e| e == "xdidx"))
        .map(|p| (p.clone(), std::fs::metadata(&p).unwrap().modified().unwrap()))
        .collect();
    files.sort();
    files
}

/// Codex objection 5: each volume has its own index; replacing one re-indexes that one alone, and the order
/// the package gives is the order resources are found in.
#[test]
fn volumes_are_indexed_and_searched_one_by_one() {
    let dir = Scratch::new("volumes");
    let file = dir.join("x.mdx");
    std::fs::write(&file, mdx("with volumes")).unwrap();
    let (one, two) = (volume(&dir, "x.mdd", "from one", "one.mp3"), volume(&dir, "x.1.mdd", "from two", "two.mp3"));
    let package = |volumes: &[&Path]| Package {
        mdx: path(&file),
        mdd: volumes.iter().map(|v| path(v)).collect(),
        sidecars: vec![],
    };
    let core = core(&dir, "cache");
    core.import(package(&[&one, &two]), &NoProgress).unwrap();
    let (dict, _) = ready(core.open(package(&[&one, &two])).unwrap());
    assert_eq!(resource_text(&core, &dict, "a.css"), "from one");
    assert_eq!(resource_text(&core, &dict, "two.mp3"), "only here");
    let before = index_files(&dir.join("cache"));
    assert_eq!(before.len(), 3, "an index for the MDX and one per volume");

    std::thread::sleep(Duration::from_millis(20));
    volume(&dir, "x.1.mdd", "from two, replaced", "two.mp3");
    assert_eq!(reason(core.open(package(&[&one, &two])).unwrap()), ImportReason::Changed);
    core.import(package(&[&one, &two]), &NoProgress).unwrap();
    let after = index_files(&dir.join("cache"));
    // Nothing indexed before was written again (each file has its old time); the replaced volume got one more.
    assert!(before.iter().all(|f| after.contains(f)), "an index was rebuilt: {before:?} then {after:?}");
    assert_eq!(after.len(), before.len() + 1, "the replaced volume has an index of its own: {after:?}");

    assert_eq!(reason(core.open(package(&[&two, &one])).unwrap()), ImportReason::Changed, "another order");
    core.import(package(&[&two, &one]), &NoProgress).unwrap();
    let (dict, _) = ready(core.open(package(&[&two, &one])).unwrap());
    assert_eq!(resource_text(&core, &dict, "a.css"), "from two, replaced");
}

/// Counts the bytes read through it.
struct Counting {
    bytes: Vec<u8>,
    read: Arc<AtomicU64>,
}

impl ByteSource for Counting {
    fn size(&self) -> u64 {
        self.bytes.len() as u64
    }
    fn read_at(&self, offset: u64, len: u32) -> Result<Vec<u8>, CoreError> {
        self.read.fetch_add(u64::from(len), Ordering::SeqCst);
        Ok(self.bytes[offset as usize..offset as usize + len as usize].to_vec())
    }
    fn identity(&self) -> Option<FileIdentity> {
        Some(FileIdentity {
            device: 9,
            inode: self.bytes.len() as u64,
            size: self.bytes.len() as u64,
            mtime_ns: 1,
            ctime_ns: 1,
        })
    }
}

/// Codex objection 6: opening reads the files' headers and nothing more.
#[test]
fn open_reads_headers_only() {
    let dir = Scratch::new("headers");
    let entries: Vec<W> = (0..20_000).map(|i| W::text(&format!("key{i:05}"), &format!("record number {i}"))).collect();
    let big = writer::write(&Spec { block_size: 4096, ..Spec::mdx() }, &entries).unwrap();
    let resources: Vec<W> = (0..5_000).map(|i| W::bytes(&format!("\\r{i}.mp3"), &[7u8; 64])).collect();
    let mdd = writer::write(&Spec { block_size: 4096, ..Spec::mdd() }, &resources).unwrap();
    let (size, mdd_size) = (big.len() as u64, mdd.len() as u64);
    let read = Arc::new(AtomicU64::new(0));
    let package = Package {
        mdx: Location::Source { name: "big.mdx".into(), source: Arc::new(Counting { bytes: big, read: read.clone() }) },
        mdd: vec![Location::Source {
            name: "big.mdd".into(),
            source: Arc::new(Counting { bytes: mdd, read: read.clone() }),
        }],
        sidecars: vec![],
    };
    let core = core(&dir, "cache");
    core.import(package.clone(), &NoProgress).unwrap();
    read.store(0, Ordering::SeqCst);
    ready(core.open(package).unwrap());
    let opened = read.load(Ordering::SeqCst);
    assert!(opened < 8 * 1024, "open read {opened} bytes of {} (two headers are about 2 KB)", size + mdd_size);
}

/// Codex objection 9: a progress callback cancels the import by its answer, and may call back into the core
/// without deadlocking it.
#[test]
fn progress_cancels_and_may_reenter_the_core() {
    let dir = Scratch::new("progress");
    let file = dir.join("x.mdx");
    std::fs::write(&file, mdx("progress")).unwrap();
    let other = dir.join("y.mdx");
    std::fs::write(&other, mdx("another")).unwrap();
    let core = Arc::new(core(&dir, "cache"));
    core.import(alone(&other), &NoProgress).unwrap();

    struct Stop;
    impl Progress for Stop {
        fn progress(&self, _: u64, _: u64) -> bool {
            false
        }
    }
    let cancelled = core.import(alone(&file), &Stop);
    assert!(matches!(cancelled, Err(CoreError::Cancelled { .. })), "{cancelled:?}");
    assert_eq!(reason(core.open(alone(&file)).unwrap()), ImportReason::New, "a cancelled import registers nothing");

    struct Reenter(Arc<Core>, PathBuf, Arc<AtomicUsize>);
    impl Progress for Reenter {
        fn progress(&self, _: u64, _: u64) -> bool {
            let (dict, _) = ready(self.0.open(alone(&self.1)).unwrap());
            self.0.close(dict).unwrap();
            self.2.fetch_add(1, Ordering::SeqCst);
            true
        }
    }
    let calls = Arc::new(AtomicUsize::new(0));
    let (done, finished) = std::sync::mpsc::channel();
    let (c, f, o, n) = (core.clone(), file.clone(), other.clone(), calls.clone());
    std::thread::spawn(move || {
        let result = c.import(alone(&f), &Reenter(c.clone(), o, n));
        let _ = done.send(result.map(|i| i.edition));
    });
    let result = finished.recv_timeout(Duration::from_secs(10)).expect("the import deadlocked");
    assert!(result.is_ok(), "{result:?}");
    assert!(calls.load(Ordering::SeqCst) > 0);
}
