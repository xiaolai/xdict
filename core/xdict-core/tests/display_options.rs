//! Display options through the core (ADR-0013 decisions 2, 3, 6 and 7): which apply to an open edition, with its
//! default, and the CSS a shell applies; the dictionary's markers kept by the render in either style.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

use xdict_core::*;
use xdict_mdx_writer::{self as writer, Entry as W, Spec};

const R: &str = r#"<span class="ph t_respell" data-d-prn="US">ˈap(ə)l</span>"#;
const I: &str = r#"<span class="ph t_IPA" data-d-prn="IPA">ˈæp(ə)l</span>"#;
/// Apple's NOAD as the Apple import converts it names itself by its front matter's class (ADR-0013 d.2).
const NOAD_SHEET: &str = ".fbm_NOAD { margin: 0 }\nspan.ph { font-weight: normal }";

struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let n = NEXT.fetch_add(1, Ordering::SeqCst);
        let dir = std::env::temp_dir().join(format!("xdict-options-{name}-{}-{n}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        Self(dir)
    }
    fn at(&self, name: &str) -> Location {
        Location::Path { path: self.0.join(name).to_string_lossy().into() }
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn pronounced(group: &str) -> String {
    format!(r#"<div class="entry"><span class="hw">apple</span><span class="prx"> | {group} | </span> a fruit</div>"#)
}

/// Writes `name` with an entry `apple` holding `group`, a plain entry and a redirect; `sheet`, if any, as its sidecar.
/// Answers the core, the open handle and the edition.
fn opened(dir: &Scratch, name: &str, group: &str, sheet: Option<&str>) -> (Core, String, String) {
    let entries = [
        W::text("apple", &pronounced(group)),
        W::text("pear", "<b>pear</b> a fruit"),
        W::text("apples", "@@@LINK=apple"),
    ];
    std::fs::write(dir.0.join(name), writer::write(&Spec::mdx(), &entries).unwrap()).unwrap();
    let mut sidecars = Vec::new();
    if let Some(sheet) = sheet {
        let css = format!("{name}.css");
        std::fs::write(dir.0.join(&css), sheet).unwrap();
        sidecars.push(dir.at(&css));
    }
    let package = Package { mdx: dir.at(name), mdd: vec![], sidecars };
    let core = Core::new(Config { client_protocol: PROTOCOL, ..Config::default() }).unwrap();
    let imported = core.import(package.clone(), &NoProgress).unwrap();
    match core.open(package).unwrap() {
        Opened::Ready { dict, .. } => (core, dict, imported.edition),
        other => panic!("not open: {other:?}"),
    }
}

fn pronunciation(default: &str) -> DisplayOption {
    DisplayOption {
        id: "pronunciation".into(),
        attribute: "data-xdict-opt-pronunciation".into(),
        values: vec!["respell".into(), "ipa".into(), "both".into()],
        default_value: default.into(),
    }
}

#[test]
fn an_edition_carrying_both_variants_declares_pronunciation_with_its_default() {
    let dir = Scratch::new("declared");
    let (core, noad, _) = opened(&dir, "noad.mdx", &format!("{R}{I}"), Some(NOAD_SHEET));
    let got = core.display_options(noad.clone()).unwrap();
    assert_eq!(got.version, DISPLAY_OPTIONS);
    assert_eq!(got.options, [pronunciation("ipa")], "Apple's NOAD: IPA by default");
    assert_eq!(got.css, xdict_entry::display_css(&[("pronunciation", "ipa")]).unwrap());
    assert_eq!(core.display_options(noad).unwrap(), got, "the same answer again");

    // The same contract in a dictionary that is not NOAD: the contract's default, everything as written.
    let (core, plain, _) = opened(&dir, "plain.mdx", &format!("{I}{R}"), Some("span.ph { font-weight: normal }"));
    let got = core.display_options(plain).unwrap();
    assert_eq!(got.options, [pronunciation("both")]);
    assert_eq!(got.css, xdict_entry::display_css(&[("pronunciation", "both")]).unwrap());
}

#[test]
fn an_edition_without_both_variants_declares_nothing() {
    let dir = Scratch::new("none");
    for (name, group) in [("ipa.mdx", I), ("respell.mdx", R), ("neither.mdx", "ˈap(ə)l")] {
        let (core, dict, _) = opened(&dir, name, group, Some(NOAD_SHEET));
        let got = core.display_options(dict).unwrap();
        assert_eq!((got.options.len(), got.css.as_str()), (0, ""), "{name}");
    }
    // Another dictionary's classes without Apple's marker.
    let (core, dict, _) =
        opened(&dir, "classes.mdx", r#"<span class="t_respell">a</span><span class="t_IPA">b</span>"#, None);
    assert!(core.display_options(dict).unwrap().options.is_empty());
}

/// d.7: an option holds under Original style. The CSS reads only the dictionary's markers, so the render must keep
/// them, side by side, in either style.
#[test]
fn the_render_keeps_the_markers_in_either_style() {
    let dir = Scratch::new("render");
    let (core, dict, edition) = opened(&dir, "noad.mdx", &format!("{R}{I}"), Some(NOAD_SHEET));
    let neutral = xdict_entry::Style::of_sheets([""]);
    for original_style in [false, true] {
        let view = View { base_url: "xdict://d/".into(), max_body_bytes: 1 << 20, original_style };
        let entry = EntryRef { edition: edition.clone(), key: "apple".into(), occurrence: 0 };
        let html = core.entry(dict.clone(), entry, view).unwrap().html;
        let kept = xdict_entry::declared(&neutral, [html.as_str()]);
        assert_eq!(kept.len(), 1, "original style {original_style}: {html}");
    }
}

#[test]
fn a_stale_handle_is_refused() {
    let dir = Scratch::new("stale");
    let (core, dict, _) = opened(&dir, "noad.mdx", &format!("{R}{I}"), None);
    core.close(dict.clone()).unwrap();
    assert!(matches!(core.display_options(dict), Err(CoreError::StaleHandle { .. })));
}
