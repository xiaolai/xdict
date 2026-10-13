//! The [`Core`]: one per process, thread-safe, every call guarded so that no panic crosses the boundary.
//!
//! **No lock is held while the shell's code runs**: a `ByteSource`, a `Progress` callback, or a read through
//! either, so a callback may call back into the core without deadlocking (Codex objection 9).

use std::collections::HashMap;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::{Arc, Mutex, MutexGuard};

use sha2::{Digest, Sha256};
use xdict_mdx::{File, Kind};

use crate::error::{CoreError, Limit, Missing};
use crate::source::{Opened as OpenedSource, read_all};
use crate::types::*;

/// The protocol between shell and core (ADR-0007 decision 11). Raised by any change a shell must be rebuilt for.
pub const PROTOCOL: u32 = 1;
/// The per-edition index's format; 0 until there is one.
pub const INDEX_FORMAT: u32 = 0;
/// The tier-2 normalisation's version; 0 until there is one.
pub const NORMALIZATION: u32 = 0;
/// The most hits one page holds.
pub const MAX_PAGE: u32 = 1_000;
/// The scheme version an edition is written with (ADR-0002 decision 1).
pub const EDITION_SCHEME: &str = "mdx-sha256-v1:";

/// How much of a file one read takes during import.
const IMPORT_CHUNK: u64 = 4 << 20;

pub struct Core {
    nonce: u32,
    state: Mutex<State>,
}

struct State {
    random: SplitMix,
    next_handle: u32,
    generation: u32,
    editions: HashMap<String, Edition>,
    locations: HashMap<String, Row>,
    open: HashMap<u32, Arc<Dict>>,
}

struct Edition {
    lineage: String,
}

/// What the registry knows of one location.
struct Row {
    edition: String,
    identity: Option<FileIdentity>,
    package: Package,
}

/// One opened package.
struct Dict {
    edition: String,
    mdx_source: OpenedSource,
    mdx: File,
    mdd: Vec<(OpenedSource, File)>,
    sidecars: Vec<(String, OpenedSource)>,
}

impl Core {
    /// A core for one process. Fails with `Incompatible` when the shell was built for another protocol.
    pub fn new(config: Config) -> Result<Self, CoreError> {
        guard(|| {
            if config.client_protocol != PROTOCOL {
                return Err(CoreError::Incompatible {
                    core: PROTOCOL,
                    client: config.client_protocol,
                    detail: format!("the core speaks protocol {PROTOCOL}, the shell {}", config.client_protocol),
                });
            }
            let mut random = SplitMix::seeded(&config.entropy)?;
            let nonce = (random.next() >> 32) as u32;
            let state = State {
                random,
                next_handle: 1,
                generation: 1,
                editions: HashMap::new(),
                locations: HashMap::new(),
                open: HashMap::new(),
            };
            Ok(Self { nonce, state: Mutex::new(state) })
        })
    }

    pub fn versions() -> Versions {
        Versions {
            protocol: PROTOCOL,
            core: env!("CARGO_PKG_VERSION").into(),
            index_format: INDEX_FORMAT,
            normalization: NORMALIZATION,
        }
    }

    /// Hashes, reads and registers a package: the slow call, run in the background, once per edition.
    pub fn import(&self, package: Package, progress: &dyn Progress) -> Result<Imported, CoreError> {
        guard(|| {
            // One pass over the bytes feeds the edition hash and the parse, so both describe one file.
            let opened = OpenedSource::open(&package.mdx)?;
            let mut hasher = Sha256::new();
            let mut bytes = Vec::new();
            read_all(&*opened.source, IMPORT_CHUNK, |chunk, done, total| {
                hasher.update(chunk);
                bytes.try_reserve(chunk.len()).map_err(|_| CoreError::internal("out of memory"))?;
                bytes.extend_from_slice(chunk);
                if progress.progress(done, total) {
                    Ok(())
                } else {
                    Err(CoreError::Cancelled { detail: "the import was cancelled".into() })
                }
            })?;
            let edition = format!("{EDITION_SCHEME}{}", hex(&hasher.finalize()));
            let mdx = File::from_source(Box::new(bytes), Some(Kind::Mdx))?;
            let info = info(&mdx);
            let mut problems = Vec::new();
            for volume in &package.mdd {
                if let Err(error) =
                    OpenedSource::open(volume).and_then(|o| Ok(File::from_source(o.source, Some(Kind::Mdd))?))
                {
                    problems.push(Problem::VolumeUnreadable { name: volume.name().into(), error });
                }
            }
            let mut state = self.lock()?;
            let lineage = match state.editions.get(&edition) {
                Some(known) => known.lineage.clone(),
                None => {
                    let lineage = state.random.uuid();
                    state.editions.insert(edition.clone(), Edition { lineage: lineage.clone() });
                    lineage
                }
            };
            let row = Row { edition: edition.clone(), identity: opened.identity, package: package.clone() };
            state.locations.insert(location_key(&package.mdx), row);
            Ok(Imported { edition, lineage, info, problems })
        })
    }

    /// Opens a location already imported. Never hashes or indexes: anything that would need to is
    /// `NeedsImport` (ADR-0007 decision 3).
    pub fn open(&self, location: Location) -> Result<Opened, CoreError> {
        guard(|| {
            let (edition, recorded, package) = {
                let state = self.lock()?;
                match state.locations.get(&location_key(&location)) {
                    None => return Ok(Opened::NeedsImport { reason: ImportReason::New }),
                    Some(row) => (row.edition.clone(), row.identity, row.package.clone()),
                }
            };
            let mdx_source = OpenedSource::open(&location)?;
            match (recorded, mdx_source.identity) {
                (Some(then), Some(now)) if then == now => {}
                (Some(_), Some(_)) => return Ok(Opened::NeedsImport { reason: ImportReason::Changed }),
                _ => return Ok(Opened::NeedsImport { reason: ImportReason::NoIdentity }),
            }
            let reader = OpenedSource::open(&location)?;
            let mdx = File::from_source(reader.source, Some(Kind::Mdx))?;
            let mut mdd = Vec::new();
            for volume in &package.mdd {
                // A volume that cannot be read was reported at import; its resources are missing.
                let Ok(check) = OpenedSource::open(volume) else { continue };
                let Ok(reader) = OpenedSource::open(volume) else { continue };
                if let Ok(file) = File::from_source(reader.source, Some(Kind::Mdd)) {
                    mdd.push((check, file));
                }
            }
            let mut sidecars = Vec::new();
            for sidecar in &package.sidecars {
                if let Ok(opened) = OpenedSource::open(sidecar) {
                    sidecars.push((sidecar.name().to_owned(), opened));
                }
            }
            let info = info(&mdx);
            let dict = Dict { edition: edition.clone(), mdx_source, mdx, mdd, sidecars };
            let mut state = self.lock()?;
            let handle = state.next_handle;
            state.next_handle = handle.checked_add(1).ok_or_else(|| CoreError::internal("handles exhausted"))?;
            state.open.insert(handle, Arc::new(dict));
            Ok(Opened::Ready { dict: self.handle(handle), edition, info })
        })
    }

    /// Closes a handle. Closing one already closed is not an error; one from another core is.
    pub fn close(&self, dict: String) -> Result<(), CoreError> {
        guard(|| {
            let handle = self.parse_handle(&dict)?;
            self.lock()?.open.remove(&handle);
            Ok(())
        })
    }

    /// Looks `query` up in `dicts`, in that order, and returns one page of references.
    pub fn lookup(&self, query: String, dicts: Vec<String>, options: LookupOptions) -> Result<Page, CoreError> {
        guard(|| {
            if options.limit > MAX_PAGE {
                return Err(CoreError::TooLarge {
                    limit: Limit::Page,
                    detail: format!("a page holds at most {MAX_PAGE} hits, {} were asked", options.limit),
                });
            }
            let generation = self.lock()?.generation;
            if options.generation.is_some_and(|g| g != generation) {
                return Err(CoreError::stale("the page belongs to another generation"));
            }
            let mut hits = Vec::new();
            let mut problems = Vec::new();
            for id in &dicts {
                let dict = self.dict(id)?;
                let mut seen: HashMap<String, u32> = HashMap::new();
                for record in dict.mdx.lookup(&query)? {
                    let occurrence = next_occurrence(&mut seen, &record.key);
                    let text = String::from_utf8_lossy(&record.data);
                    let Some(target) = redirect_target(&text) else {
                        let how = if record.key == query { How::Exact } else { How::Folded };
                        let entry = EntryRef { edition: dict.edition.clone(), key: record.key.clone(), occurrence };
                        hits.push(Hit { dict: id.clone(), entry, headword: record.key, how, problems: vec![] });
                        continue;
                    };
                    let mut found = false;
                    let mut seen_target: HashMap<String, u32> = HashMap::new();
                    for landed in dict.mdx.lookup(target)? {
                        let occurrence = next_occurrence(&mut seen_target, &landed.key);
                        if redirect_target(&String::from_utf8_lossy(&landed.data)).is_some() {
                            continue;
                        }
                        found = true;
                        let entry = EntryRef { edition: dict.edition.clone(), key: landed.key.clone(), occurrence };
                        let how = How::Redirect { chain: vec![record.key.clone(), landed.key.clone()] };
                        hits.push(Hit { dict: id.clone(), entry, headword: landed.key, how, problems: vec![] });
                    }
                    if !found {
                        problems.push(HitProblem::DanglingRedirect { from: record.key.clone(), target: target.into() });
                    }
                }
            }
            let total = hits.len() as u64;
            let hits = hits.into_iter().skip(options.offset as usize).take(options.limit as usize).collect();
            Ok(Page { hits, total, generation, problems })
        })
    }

    /// Keys beginning with `prefix`, for a search field.
    pub fn suggest(&self, prefix: String, dicts: Vec<String>, limit: u32) -> Result<Vec<String>, CoreError> {
        guard(|| {
            let wanted = prefix.to_lowercase();
            let mut out: Vec<String> = Vec::new();
            for id in &dicts {
                let dict = self.dict(id)?;
                for key in dict.mdx.keys() {
                    if out.len() >= limit as usize {
                        return Ok(out);
                    }
                    if key.to_lowercase().starts_with(&wanted) && !out.iter().any(|k| k == key) {
                        out.push(key.to_owned());
                    }
                }
            }
            Ok(out)
        })
    }

    /// One entry's HTML for the entry view.
    pub fn entry(&self, dict: String, entry: EntryRef, view: View) -> Result<Entry, CoreError> {
        guard(|| {
            let opened = self.dict(&dict)?;
            if opened.edition != entry.edition {
                return Err(CoreError::EditionMismatch {
                    detail: format!("{} is not the edition open as {dict}", entry.edition),
                });
            }
            opened.mdx_source.unchanged()?;
            let record = opened
                .mdx
                .lookup(&entry.key)?
                .into_iter()
                .filter(|r| r.key == entry.key)
                .nth(entry.occurrence as usize)
                .ok_or_else(|| CoreError::NotFound {
                    what: Missing::Entry,
                    detail: format!("{:?} has no record {}", entry.key, entry.occurrence),
                })?;
            if record.data.len() as u64 > view.max_body_bytes {
                return Err(CoreError::TooLarge {
                    limit: Limit::Body,
                    detail: format!("the entry is {} bytes, the view takes {}", record.data.len(), view.max_body_bytes),
                });
            }
            let html = String::from_utf8_lossy(&record.data).into_owned();
            Ok(Entry { entry, html, csp: csp(&view.base_url), lossy_bytes: 0 })
        })
    }

    /// What a URL an entry or its script produced means. Takes the URL raw, `.tts` and all.
    pub fn link(&self, dict: String, url: String, origin: LinkOrigin, view: View) -> Result<Link, CoreError> {
        guard(|| {
            self.dict(&dict)?;
            let _ = (&origin, &view);
            Ok(classify(&url))
        })
    }

    /// A resource's bytes: the sidecars first, then the volumes in order. Missing is a value.
    pub fn resource(&self, dict: String, path: String, view: View) -> Result<Resource, CoreError> {
        guard(|| {
            let _ = &view;
            let opened = self.dict(&dict)?;
            let path = normalize_path(&path);
            for (name, sidecar) in &opened.sidecars {
                if name.eq_ignore_ascii_case(&path) {
                    sidecar.unchanged()?;
                    let mut bytes = Vec::new();
                    read_all(&*sidecar.source, IMPORT_CHUNK, |chunk, _, _| {
                        bytes.extend_from_slice(chunk);
                        Ok(())
                    })?;
                    return Ok(Resource::Found { mime: mime(&path).into(), path, bytes });
                }
            }
            let key = format!("\\{}", path.replace('/', "\\"));
            for (check, volume) in &opened.mdd {
                check.unchanged()?;
                if let Some(record) = volume.lookup(&key)?.into_iter().next() {
                    return Ok(Resource::Found { mime: mime(&path).into(), path, bytes: record.data });
                }
            }
            Ok(Resource::Missing { path })
        })
    }

    /// Panics on purpose, so that each binding can prove a panic reaches it as `Internal`.
    pub fn self_test_panic(&self) -> Result<(), CoreError> {
        guard(|| -> Result<(), CoreError> {
            #[allow(clippy::panic)]
            {
                panic!("the deliberate panic of self_test_panic")
            }
        })
    }

    fn lock(&self) -> Result<MutexGuard<'_, State>, CoreError> {
        self.state.lock().map_err(|_| CoreError::internal("the core's state was left inconsistent by an earlier fault"))
    }

    fn handle(&self, handle: u32) -> String {
        format!("{:08x}{handle:08x}", self.nonce)
    }

    fn parse_handle(&self, dict: &str) -> Result<u32, CoreError> {
        let raw = u64::from_str_radix(dict, 16).map_err(|_| CoreError::stale(format!("{dict:?} is not a handle")))?;
        if dict.len() != 16 || (raw >> 32) as u32 != self.nonce {
            return Err(CoreError::stale(format!("{dict} belongs to another core")));
        }
        Ok(raw as u32)
    }

    fn dict(&self, dict: &str) -> Result<Arc<Dict>, CoreError> {
        let handle = self.parse_handle(dict)?;
        self.lock()?.open.get(&handle).cloned().ok_or_else(|| CoreError::stale(format!("{dict} is closed")))
    }
}

/// Runs a call so that a panic inside it comes back as `Internal` (ADR-0003 decision 4).
fn guard<T>(call: impl FnOnce() -> Result<T, CoreError>) -> Result<T, CoreError> {
    catch_unwind(AssertUnwindSafe(call)).unwrap_or_else(|payload| {
        let message = payload
            .downcast_ref::<&str>()
            .map(|s| (*s).to_owned())
            .or_else(|| payload.downcast_ref::<String>().cloned())
            .unwrap_or_else(|| "a panic with no message".into());
        Err(CoreError::internal(message))
    })
}

fn info(file: &File) -> DictInfo {
    let header = file.header();
    let format_version = match header.version {
        xdict_mdx::FormatVersion::V1_2 => "1.2",
        xdict_mdx::FormatVersion::V2_0 => "2.0",
        xdict_mdx::FormatVersion::V3_0 => "3.0",
    };
    DictInfo {
        title: header.title.clone(),
        description: header.description.clone(),
        format_version: format_version.into(),
        keys: file.len() as u64,
    }
}

fn location_key(location: &Location) -> String {
    match location {
        Location::Path { path } => format!("path:{path}"),
        Location::Source { name, .. } => format!("source:{name}"),
    }
}

fn next_occurrence(seen: &mut HashMap<String, u32>, key: &str) -> u32 {
    let n = seen.entry(key.to_owned()).or_insert(0);
    let occurrence = *n;
    *n += 1;
    occurrence
}

/// The target of an `@@@LINK=` record.
fn redirect_target(text: &str) -> Option<&str> {
    let rest = text.trim_start().strip_prefix("@@@LINK=")?;
    let target = rest.lines().next().unwrap_or("").trim();
    (!target.is_empty()).then_some(target)
}

/// What a URL means, read the way the entry's web view reads it (the WHATWG URL Standard): otherwise the
/// core could call "local" a URL the view fetches from the network (`/\\host/x`, `ht<TAB>tp://host`).
fn classify(url: &str) -> Link {
    let url = preprocess(url);
    if let Some((scheme, rest)) = scheme(&url) {
        let body = rest.strip_prefix("//").unwrap_or(rest);
        return match scheme.as_str() {
            "entry" | "bword" => {
                let (query, anchor) = match body.split_once('#') {
                    Some((q, a)) => (q.to_owned(), Some(a.to_owned())),
                    None => (body.to_owned(), None),
                };
                Link::Lookup { query, anchor }
            }
            "sound" => match body
                .len()
                .checked_sub(4)
                .filter(|&n| body.get(n..).is_some_and(|t| t.eq_ignore_ascii_case(".tts")))
            {
                Some(n) => Link::Speak { text: body.get(..n).unwrap_or("").to_owned() },
                None => Link::Sound { path: body.to_owned() },
            },
            "javascript" => Link::Blocked { why: BlockReason::Script },
            // The URL Standard's special schemes other than `file`: each reaches the network, with or
            // without slashes after the colon.
            "http" | "https" | "ws" | "wss" | "ftp" => Link::Blocked { why: BlockReason::Remote { url } },
            "file" | "mdd" => Link::Resource { path: normalize_path(body) },
            _ => Link::Blocked { why: BlockReason::UnknownScheme { scheme } },
        };
    }
    if let Some(name) = url.strip_prefix('#') {
        return Link::Anchor { name: name.into() };
    }
    // Without a scheme, two leading slashes in either direction name another host.
    if url.replace('\\', "/").starts_with("//") {
        return Link::Blocked { why: BlockReason::Remote { url } };
    }
    Link::Resource { path: normalize_path(&url) }
}

/// A URL as a browser's parser takes it in: leading and trailing C0 controls and spaces trimmed, and every
/// tab and newline removed, wherever it is.
fn preprocess(url: &str) -> String {
    url.trim_matches(|c: char| c <= ' ').chars().filter(|c| !matches!(c, '\t' | '\n' | '\r')).collect()
}

/// The URL's scheme, lower-cased, and what follows its colon: an ASCII letter, then letters, digits, `+`,
/// `-` or `.`, then `:`.
fn scheme(url: &str) -> Option<(String, &str)> {
    let (head, rest) = url.split_once(':')?;
    let mut chars = head.chars();
    let first = chars.next()?;
    let valid = first.is_ascii_alphabetic() && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'));
    valid.then(|| (head.to_ascii_lowercase(), rest))
}

/// A resource path as the core compares it: forward slashes, no leading separator.
fn normalize_path(path: &str) -> String {
    path.replace('\\', "/").trim_start_matches('/').to_owned()
}

fn mime(path: &str) -> &'static str {
    let ext = path.rsplit('.').next().unwrap_or("").to_ascii_lowercase();
    match ext.as_str() {
        "css" => "text/css",
        "js" => "text/javascript",
        "html" | "htm" => "text/html",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "svg" => "image/svg+xml",
        "webp" => "image/webp",
        "mp3" => "audio/mpeg",
        "ogg" => "audio/ogg",
        "wav" => "audio/wav",
        "ttf" => "font/ttf",
        "otf" => "font/otf",
        "woff" => "font/woff",
        "woff2" => "font/woff2",
        _ => "application/octet-stream",
    }
}

/// The policy the view must apply: only the view's own base for every fetch, nothing remote.
fn csp(base: &str) -> String {
    format!(
        "default-src {base}; script-src {base} 'unsafe-inline' 'unsafe-eval'; style-src {base} 'unsafe-inline'; \
         img-src {base} data:; font-src {base} data:; media-src {base}; connect-src 'none'; form-action 'none'; \
         frame-src 'none'; object-src 'none'; base-uri 'none'"
    )
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// SplitMix64: unique handles and lineage ids, not secrets. Seeded from the shell's entropy, or natively from
/// the operating system's through the standard library's randomly keyed hasher.
struct SplitMix(u64);

impl SplitMix {
    fn seeded(entropy: &[u8]) -> Result<Self, CoreError> {
        let mut seed = 0u64;
        if entropy.is_empty() {
            if cfg!(target_family = "wasm") {
                return Err(CoreError::internal("this platform needs Config.entropy: the core has no random source"));
            }
            use std::hash::{BuildHasher, Hasher};
            seed = std::collections::hash_map::RandomState::new().build_hasher().finish();
        }
        for (i, byte) in entropy.iter().enumerate() {
            seed ^= u64::from(*byte).rotate_left((i % 8 * 8) as u32);
            seed = seed.wrapping_mul(0x9E37_79B9_7F4A_7C15);
        }
        Ok(Self(seed))
    }

    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// A version 4 UUID.
    fn uuid(&mut self) -> String {
        let (a, b) = (self.next(), self.next());
        let a = (a & !0xF000) | 0x4000;
        let b = (b & !(0b11 << 62)) | (0b10 << 62);
        format!(
            "{:08x}-{:04x}-{:04x}-{:04x}-{:012x}",
            a >> 32,
            (a >> 16) & 0xFFFF,
            a & 0xFFFF,
            b >> 48,
            b & 0xFFFF_FFFF_FFFF
        )
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::indexing_slicing)]
mod tests {
    use super::*;

    fn remote(url: &str) -> bool {
        matches!(classify(url), Link::Blocked { why: BlockReason::Remote { .. } })
    }

    /// A URL is read the way the entry's web view will read it (the WHATWG URL Standard), or the core would
    /// call "local" what the view fetches from the network.
    #[test]
    fn urls_a_browser_reads_as_remote_are_remote() {
        for url in [
            "https://example.com/a.mp3",
            "HTTP://example.com/a.mp3",
            "//example.com/a.mp3",
            "/\\example.com/a.mp3",
            "\\\\example.com/a.mp3",
            "\\/example.com/a.mp3",
            " \u{1}https://example.com/a.mp3",
            "ht\ttps://example.com/a.mp3",
            "https\n://example.com/a.mp3",
            "http:example.com/a.mp3",
            "wss://example.com/socket",
            "ftp://example.com/a",
        ] {
            assert!(remote(url), "{url:?} was classified {:?}", classify(url));
        }
    }

    #[test]
    fn script_urls_are_blocked_however_they_are_spelt() {
        for url in ["javascript:void(0)", "JavaScript:alert(1)", "java\nscript:alert(1)", " \tjavascript:x"] {
            assert_eq!(classify(url), Link::Blocked { why: BlockReason::Script }, "{url:?}");
        }
    }

    #[test]
    fn dictionary_links_survive_the_same_reading() {
        assert_eq!(classify(" entry://run#n1 "), Link::Lookup { query: "run".into(), anchor: Some("n1".into()) });
        assert_eq!(classify("sound://a\tb.mp3"), Link::Sound { path: "ab.mp3".into() });
        assert_eq!(classify("styles/main.css"), Link::Resource { path: "styles/main.css".into() });
        assert_eq!(classify("/x.css"), Link::Resource { path: "x.css".into() });
    }
}
