//! What a URL in an entry means (ADR-0007 decisions 7, 8 and 14), and the paths resources travel under.
//!
//! Two readings. A URL **written in a dictionary** (an attribute, a stylesheet) is literal text: MDict paths
//! hold `%`, `?` and `#` as file-name characters (`core-api.md` finding 4), so nothing in it is decoded. A URL
//! **a web view hands back** (a navigation, a fetch) has been through the view's URL parser, so it is decoded
//! exactly once. Either way it is first read as the view reads it (the WHATWG URL Standard), or the core could
//! call "local" what the view fetches from the network (`/\host/x`, `ht<TAB>tp://host`).

/// What a link means.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Link {
    /// Look this up, in link mode.
    Lookup {
        query: String,
        anchor: Option<String>,
    },
    /// A resource, by its path as it travels: canonical, each segment percent-encoded ([`Path`]).
    Resource {
        path: String,
    },
    /// Play this recording, by its path as it travels.
    Sound {
        path: String,
    },
    /// Speak this text (`sound://….tts`, MDict's own convention).
    Speak {
        text: String,
    },
    /// Scroll to this anchor of the same entry.
    Anchor {
        name: String,
    },
    Blocked(Block),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Block {
    /// Entries never reach the network.
    Remote {
        url: String,
    },
    /// `javascript:` and the like.
    Script,
    UnknownScheme {
        scheme: String,
    },
}

/// The routes the core writes under a view's base.
pub(crate) const ENTRY: &str = "entry/";
pub(crate) const SOUND: &str = "sound/";
pub(crate) const RESOURCE: &str = "r/";
pub(crate) const BLOCKED: &str = "blocked/";

/// A URL as a browser's parser takes it in: leading and trailing C0 controls and spaces trimmed, and every tab
/// and newline removed, wherever it is.
pub(crate) fn preprocess(url: &str) -> String {
    url.trim_matches(|c: char| c <= ' ').chars().filter(|c| !matches!(c, '\t' | '\n' | '\r')).collect()
}

/// The URL's scheme, lower-cased, and what follows its colon: an ASCII letter, then letters, digits, `+`, `-` or
/// `.`, then `:`.
pub(crate) fn scheme(url: &str) -> Option<(String, &str)> {
    let (head, rest) = url.split_once(':')?;
    let mut chars = head.chars();
    let first = chars.next()?;
    let valid = first.is_ascii_alphabetic() && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'));
    valid.then(|| (head.to_ascii_lowercase(), rest))
}

/// The URL Standard's special schemes other than `file`: each reaches the network, with or without slashes.
pub(crate) fn is_remote_scheme(scheme: &str) -> bool {
    matches!(scheme, "http" | "https" | "ws" | "wss" | "ftp")
}

/// The schemes Oxford's own data uses for "look this word up" (OALECD 9: `d:very`, `x:The`, `xi:Bourke`,
/// `xp:accustom`, 1,455 of a 400-entry sample's links). Its other schemes (`help:`, `addexample:`, `xid:`…) are
/// actions of Oxford's app, with nothing for a reader to do: unknown schemes.
pub(crate) fn is_oxford_lookup(scheme: &str) -> bool {
    matches!(scheme, "d" | "x" | "xi" | "xp")
}

/// Without a scheme, two leading slashes in either direction name another host.
pub(crate) fn names_a_host(url: &str) -> bool {
    url.replace('\\', "/").starts_with("//")
}

/// `sound://x.tts`: MDict's "speak this", the text before the suffix.
pub(crate) fn tts(text: &str) -> Option<&str> {
    let n = text.len().checked_sub(4)?;
    text.get(n..).filter(|t| t.eq_ignore_ascii_case(".tts")).and_then(|_| text.get(..n))
}

/// What a URL a web view handed back means: decoded once. `base` is the view's base; `dir` the directory of
/// the resource the URL appeared in (empty for an entry), against which a relative path resolves.
pub fn classify(url: &str, base: &str, dir: &str) -> Link {
    let url = preprocess(url);
    if let Some(route) = strip_prefix_ignore_case(&url, base) {
        return route_link(route);
    }
    if let Some((scheme, rest)) = scheme(&url) {
        let body = rest.strip_prefix("//").unwrap_or(rest);
        return match scheme.as_str() {
            "entry" | "bword" => lookup(body),
            s if is_oxford_lookup(s) => Link::Lookup { query: decode(rest), anchor: None },
            "sound" | "gdau" => sound(&decode(body)),
            "javascript" => Link::Blocked(Block::Script),
            "file" | "mdd" => Link::Resource { path: Path::resolve("", &decode(body)).travel() },
            s if is_remote_scheme(s) => Link::Blocked(Block::Remote { url }),
            _ => Link::Blocked(Block::UnknownScheme { scheme }),
        };
    }
    if let Some(name) = url.strip_prefix('#') {
        return Link::Anchor { name: decode(name) };
    }
    if names_a_host(&url) {
        return Link::Blocked(Block::Remote { url });
    }
    Link::Resource { path: Path::resolve(dir, &decode(&url)).travel() }
}

/// A URL under the view's base: one of the routes the core wrote, or a relative URL the view resolved there.
fn route_link(route: &str) -> Link {
    if let Some(rest) = route.strip_prefix(ENTRY) {
        return lookup(rest);
    }
    if let Some(rest) = route.strip_prefix(SOUND) {
        return sound(&decode(rest));
    }
    if let Some(rest) = route.strip_prefix(BLOCKED) {
        return Link::Blocked(Block::Remote { url: decode(rest) });
    }
    let rest = route.strip_prefix(RESOURCE).unwrap_or(route);
    let rest = rest.split_once('#').map_or(rest, |(path, _)| path);
    Link::Resource { path: Path::resolve("", &decode(rest)).travel() }
}

fn lookup(body: &str) -> Link {
    let (query, anchor) = match body.split_once('#') {
        Some((q, a)) => (q, Some(decode(a))),
        None => (body, None),
    };
    Link::Lookup { query: decode(query), anchor }
}

fn sound(path: &str) -> Link {
    match tts(path) {
        Some(text) => Link::Speak { text: text.to_owned() },
        None => Link::Sound { path: Path::resolve("", path).travel() },
    }
}

fn strip_prefix_ignore_case<'a>(text: &'a str, prefix: &str) -> Option<&'a str> {
    if prefix.is_empty() {
        return None;
    }
    let head = text.get(..prefix.len())?;
    head.eq_ignore_ascii_case(prefix).then(|| text.get(prefix.len()..)).flatten()
}

/// Percent-decoding, once; a `%` not followed by two hex digits is itself, and bytes that do not make UTF-8 are
/// replaced.
pub fn decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while let Some(&b) = bytes.get(i) {
        let hex = |at: usize| bytes.get(at).and_then(|&h| (h as char).to_digit(16));
        match (b, hex(i + 1), hex(i + 2)) {
            (b'%', Some(hi), Some(lo)) => {
                out.push((hi * 16 + lo) as u8);
                i += 3;
            }
            _ => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Every byte outside RFC 3986's unreserved set, percent-encoded: `/` too, so the result is one segment.
pub fn encode(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for &b in text.as_bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_' | b'~') {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// A resource path, decoded: forward slashes, no leading separator, `.` and `..` resolved, and a `..` at the root
/// staying at the root, as a browser's URL parser does (ADR-0007 decision 8, as corrected: stylesheets written
/// for a `css/` folder ask for `../images/…` from the dictionary's root, and every view MDict runs in reads that
/// as `images/…`). Resolution never leaves the package: a path is a name in it, not a place on disk.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Path {
    resolved: String,
    asked: String,
}

impl Path {
    /// `path` (decoded text) resolved against `dir`, unless it starts at the root.
    pub fn resolve(dir: &str, path: &str) -> Self {
        let path = path.replace('\\', "/");
        let joined = if path.starts_with('/') || dir.is_empty() { path.clone() } else { format!("{dir}/{path}") };
        let mut segments: Vec<&str> = Vec::new();
        for segment in joined.split('/') {
            match segment {
                "" | "." => {}
                ".." => {
                    segments.pop();
                }
                s => segments.push(s),
            }
        }
        Self { resolved: segments.join("/"), asked: path }
    }

    /// The path as it travels in a URL: each segment percent-encoded.
    pub fn travel(&self) -> String {
        self.resolved.split('/').map(encode).collect::<Vec<_>>().join("/")
    }

    /// The path a resource is looked up by.
    pub fn resolved(&self) -> &str {
        &self.resolved
    }

    /// What was asked for, decoded, for a report.
    pub fn asked(&self) -> &str {
        &self.asked
    }

    /// The directory a relative URL in this resource resolves against.
    pub fn dir(&self) -> &str {
        self.resolved.rsplit_once('/').map_or("", |(dir, _)| dir)
    }
}

/// A path as it arrived from the boundary (encoded), decoded once and resolved.
pub fn travelled(path: &str) -> Path {
    Path::resolve("", &decode(path))
}

#[cfg(test)]
mod tests {
    use super::*;

    const BASE: &str = "xdict://d/";

    fn link(url: &str) -> Link {
        classify(url, BASE, "")
    }

    fn remote(url: &str) -> bool {
        matches!(link(url), Link::Blocked(Block::Remote { .. }))
    }

    /// A URL is read the way the entry's web view will read it (the WHATWG URL Standard), or the core would call
    /// "local" what the view fetches from the network.
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
            assert!(remote(url), "{url:?} was classified {:?}", link(url));
        }
    }

    #[test]
    fn script_urls_are_blocked_however_they_are_spelt() {
        for url in ["javascript:void(0)", "JavaScript:alert(1)", "java\nscript:alert(1)", " \tjavascript:x"] {
            assert_eq!(link(url), Link::Blocked(Block::Script), "{url:?}");
        }
    }

    /// Every form `core-api.md` findings 5 and 20 list.
    #[test]
    fn dictionary_links_of_every_form() {
        assert_eq!(link(" entry://run#n1 "), Link::Lookup { query: "run".into(), anchor: Some("n1".into()) });
        assert_eq!(link("bword://caf%C3%A9"), Link::Lookup { query: "café".into(), anchor: None });
        assert_eq!(link("sound://a\tb.mp3"), Link::Sound { path: "ab.mp3".into() });
        assert_eq!(link("sound://hello%20world.tts"), Link::Speak { text: "hello world".into() });
        assert_eq!(link("gdau://x/a%20b.ogg"), Link::Sound { path: "x/a%20b.ogg".into() });
        assert_eq!(link("styles/main.css"), Link::Resource { path: "styles/main.css".into() });
        assert_eq!(link("/x.css"), Link::Resource { path: "x.css".into() });
        assert_eq!(link("\\img\\a.png"), Link::Resource { path: "img/a.png".into() });
        assert_eq!(link("file://img/a.png"), Link::Resource { path: "img/a.png".into() });
        assert_eq!(link("mdd://img/a.png"), Link::Resource { path: "img/a.png".into() });
        assert_eq!(link("#sense2"), Link::Anchor { name: "sense2".into() });
        assert_eq!(link("about:blank"), Link::Blocked(Block::UnknownScheme { scheme: "about".into() }));
        assert_eq!(
            link("d:360-degree%20appraisal"),
            Link::Lookup { query: "360-degree appraisal".into(), anchor: None }
        );
        assert_eq!(link("help:bre"), Link::Blocked(Block::UnknownScheme { scheme: "help".into() }));
    }

    /// The routes the core writes come back as what they were written for.
    #[test]
    fn the_cores_own_routes() {
        assert_eq!(link("xdict://d/entry/run#n1"), Link::Lookup { query: "run".into(), anchor: Some("n1".into()) });
        assert_eq!(link("XDICT://d/entry/caf%C3%A9"), Link::Lookup { query: "café".into(), anchor: None });
        assert_eq!(link("xdict://d/sound/a%20b.mp3"), Link::Sound { path: "a%20b.mp3".into() });
        assert_eq!(link("xdict://d/sound/hi.tts"), Link::Speak { text: "hi".into() });
        assert_eq!(link("xdict://d/r/x/a%3Fb.css"), Link::Resource { path: "x/a%3Fb.css".into() });
        assert_eq!(
            link("xdict://d/blocked/http%3A%2F%2Fexample.com"),
            Link::Blocked(Block::Remote { url: "http://example.com".into() })
        );
        assert_eq!(classify("/w/entry/run", "/w/", ""), Link::Lookup { query: "run".into(), anchor: None });
    }

    /// Decision 7: a relative URL resolves against the resource it appeared in.
    #[test]
    fn relative_urls_resolve_against_their_resource() {
        assert_eq!(classify("../fonts/a.woff2", BASE, "styles"), Link::Resource { path: "fonts/a.woff2".into() });
        assert_eq!(classify("a.png", BASE, "styles/img"), Link::Resource { path: "styles/img/a.png".into() });
    }

    /// Decision 8: segments travel encoded and decode exactly once; `..` at the root stays there.
    #[test]
    fn paths_travel_encoded_and_decode_once() {
        for raw in ["a b/c?d#e%f.css", "中文/音.mp3", "x/%41.css"] {
            let travelling = Path::resolve("", raw).travel();
            assert!(travelling.bytes().all(|b| b.is_ascii_alphanumeric() || b"-._~%/".contains(&b)), "{travelling}");
            assert_eq!(travelled(&travelling).resolved(), raw, "{travelling}");
        }
        assert_eq!(Path::resolve("", "../images/x.png").resolved(), "images/x.png");
        assert_eq!(Path::resolve("a", "../../x.css").resolved(), "x.css");
        assert_eq!(Path::resolve("a/b", "../c/./d.css").resolved(), "a/c/d.css");
        assert_eq!(decode("100%"), "100%");
        assert_eq!(decode("%zz%4"), "%zz%4");
    }
}
