//! [`STYLE`] says which version of the rules wrote an entry. It went unraised through many changes to what they write,
//! because nothing tied it to the output. This test does: it renders a fixed set of inputs (every entry of the
//! conformance fixtures, plus inputs shaped for normalization, roles, links and transcription marks) and pins a digest
//! of what they become together with `STYLE`. A change to the output without a new `STYLE`, or the reverse, fails.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing, clippy::string_slice)]

use std::path::Path;

use xdict_entry::{Entry, STYLE, Style, entry_normalized_within, html_normalized_within};

/// `(STYLE, digest of the output)`, as last raised. Change both together, never one.
const PINNED: (u32, u64) = (7, 0x934b_0f14_cede_c765);

const BASE: &str = "xdict://d/";

/// Inputs shaped to reach each part of the rules, keyed where the roles need a key.
const SHAPED: [(&str, &str); 12] = [
    ("", r#"<p style="font-size:18px;color:#f00;font-family:Arial">plain <b>bold</b> <font size="+1">big</font></p>"#),
    ("", r#"<table><tr><td>a</td><td>b</td></tr></table><img src="x.png"><a href="entry://hue#s1">hue</a>"#),
    ("", r#"<span class="phon">/ˈæp(ə)l/</span> <b>[<i>ˈ</i>&#230;pl]</b> <em>\ˈa-pəl\</em>"#),
    ("", "<font>—<b>vision</b> <a>uk</a> /ˈvɪʒ.<sup>ə</sup>n/</font>"),
    ("", r#"<div>Brit.<a>sound</a>/<span class="phonetics">ˈdʌɪnə</span>/</div>"#),
    ("county council", r#"<b class="hw">ˌcounty ˈcouncil</b> <span class="d">a council</span>"#),
    (
        "pet",
        r#"<b class="hw">pet</b> <span class="ph">ˈpɛt</span> <span class="pos">noun</span> <span class="d">an animal</span>"#,
    ),
    ("run", r#"<b>run</b> <a href="sound://run.mp3">play</a> <i class="pos">verb</i> <span class="ex">I run.</span>"#),
    ("x", "<<run>> <script>alert(1)</script><a href=\"https://example.com/\">out</a>"),
    // A box of speakers before its transcription (STYLE 3: `data-xdict-speakers`).
    (
        "x",
        r#"<span class="h"><span class="s"><a href="sound://x.mp3"><img src="s.png"></a></span><span>ˈeks</span></span>"#,
    ),
    // A word list written in a drawn box (STYLE 4: OPAL's pills are labels).
    ("x", r#"<span class="pill">OPAL W</span> <span class="pill">B2</span>"#),
    // The roles a markup's table makes sure beyond the part of speech (STYLE 7).
    (
        "run",
        r#"<b class="hw">run</b> <span class="sensenum">1</span> <span class="d">to move fast</span> <b>2.</b> <span class="d">to flow</span>"#,
    ),
];

/// FNV-1a, 64 bits: stable across platforms and releases, which `DefaultHasher` does not promise.
fn fnv(digest: &mut u64, bytes: &[u8]) {
    for b in bytes {
        *digest ^= u64::from(*b);
        *digest = digest.wrapping_mul(0x0000_0100_0000_01b3);
    }
}

/// Every `mdx.entries` `[key, body]` of the conformance fixtures, in path order.
fn fixture_entries() -> Vec<(String, String)> {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../conformance/fixtures");
    let mut files: Vec<_> = std::fs::read_dir(&root)
        .unwrap()
        .map(|e| e.unwrap().path().join("dictionary.json"))
        .filter(|p| p.is_file())
        .collect();
    files.sort();
    let mut out = Vec::new();
    for file in files {
        let text = std::fs::read_to_string(&file).unwrap();
        out.extend(mdx_entries(&text).unwrap_or_else(|| panic!("{}: no mdx.entries read", file.display())));
    }
    assert!(out.len() > 20, "the conformance fixtures' entries were not found under {}", root.display());
    out
}

/// The `[key, body]` pairs of the first `"entries"` array after `"mdx"`, read without a JSON crate (this crate has
/// none): the fixtures write each pair as two JSON strings.
fn mdx_entries(text: &str) -> Option<Vec<(String, String)>> {
    let from = text.find("\"mdx\"")?;
    let at = from + text[from..].find("\"entries\"")? + "\"entries\"".len();
    let mut chars = text[at..].chars().peekable();
    while chars.next_if(|c| *c != '[').is_some() {}
    chars.next()?; // the array's `[`
    let mut out = Vec::new();
    loop {
        while chars.next_if(|c| c.is_whitespace() || *c == ',').is_some() {}
        match chars.next()? {
            ']' => return Some(out),
            '[' => {
                let mut pair = Vec::new();
                loop {
                    while chars.next_if(|c| c.is_whitespace() || *c == ',').is_some() {}
                    match chars.next()? {
                        ']' => break,
                        '"' => pair.push(json_string(&mut chars)?),
                        _ => return None,
                    }
                }
                let [key, body]: [String; 2] = pair.try_into().ok()?;
                out.push((key, body));
            }
            _ => return None,
        }
    }
}

/// A JSON string's body after its opening quote, unescaped, up to and past its closing quote.
fn json_string(chars: &mut std::iter::Peekable<std::str::Chars<'_>>) -> Option<String> {
    let mut s = String::new();
    loop {
        match chars.next()? {
            '"' => return Some(s),
            '\\' => match chars.next()? {
                'n' => s.push('\n'),
                't' => s.push('\t'),
                'r' => s.push('\r'),
                'b' => s.push('\u{8}'),
                'f' => s.push('\u{c}'),
                'u' => {
                    let hi = u32::from_str_radix(&chars.by_ref().take(4).collect::<String>(), 16).ok()?;
                    let code = if (0xD800..0xDC00).contains(&hi) {
                        let (Some('\\'), Some('u')) = (chars.next(), chars.next()) else { return None };
                        let lo = u32::from_str_radix(&chars.by_ref().take(4).collect::<String>(), 16).ok()?;
                        0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00)
                    } else {
                        hi
                    };
                    s.push(char::from_u32(code)?);
                }
                c => s.push(c),
            },
            c => s.push(c),
        }
    }
}

#[test]
fn style_is_raised_with_any_change_to_the_output() {
    let style = Style::of_sheets([
        // `chwd` and `collobox` name Longman's markup (STYLE 6: per-markup tables, `data-xdict-sure`).
        ".pos{font-style:italic} .hw{font-weight:bold} .pill{background:#666} .chwd{font-weight:bold} .collobox{border:0}",
    ]);
    let mut digest = 0xcbf2_9ce4_8422_2325;
    let inputs = fixture_entries().into_iter().chain(SHAPED.iter().map(|(k, b)| ((*k).to_owned(), (*b).to_owned())));
    for (key, body) in inputs {
        let html = if key.is_empty() {
            html_normalized_within(&body, BASE, "", &style, usize::MAX).unwrap().0
        } else {
            let is_key = |k: &str| k == "pet" || k == "county council";
            let entry =
                Entry { key: &key, resource: None, is_key: Some(&is_key), strip_off_for_tests: false, original: false };
            entry_normalized_within(&body, BASE, "", &style, &entry, usize::MAX).unwrap().0
        };
        fnv(&mut digest, html.as_bytes());
        fnv(&mut digest, &[0]);
    }
    let (pinned_style, pinned_digest) = PINNED;
    assert!(
        digest != pinned_digest || STYLE == pinned_style,
        "STYLE is {STYLE} but the output is what PINNED records for {pinned_style}: a raise with no change to what \
         the rules write. Set PINNED to ({STYLE}, {digest:#018x}) only if the raise is meant."
    );
    assert!(
        digest == pinned_digest || STYLE != pinned_style,
        "What normalization writes changed (digest {digest:#018x}, pinned {pinned_digest:#018x}) but STYLE is still \
         {STYLE}. Raise STYLE in xdict-entry/src/normalize.rs and set PINNED here to (the new STYLE, {digest:#018x}). \
         Expected whenever a branch changes normalization (two branches doing so in parallel each raise it, and the \
         second rebases onto the first's raise): that is this test doing its job."
    );
    assert_eq!((STYLE, digest), PINNED, "PINNED is ({STYLE}, {digest:#018x}) once STYLE is raised for this output");
}
