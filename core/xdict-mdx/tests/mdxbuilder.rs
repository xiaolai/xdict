//! The reader against a format 3.0 file built by the official MdxBuilder 4.0 from XDict's own text.
//!
//! The only check of the v3 reader that does not share its author's reading of the format: no v3 file was
//! found in the wild (ADR-0005), and `xdict-mdx-writer`'s v3 output follows the same facts note as the reader.
//! The file stays outside the repository (`*.mdx` is ignored); `XDICT_MDX_MDXBUILDER_V3` names it. **Unset,
//! this test prints "not measured" and passes: a green run without it is not a measurement.**
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use std::path::PathBuf;

use xdict_mdx::{File, FormatVersion, Kind};

fn texts(file: &File, key: &str) -> Vec<String> {
    let found = file.lookup(key).unwrap_or_else(|e| panic!("{key:?}: {e}"));
    found.iter().map(|r| String::from_utf8(r.data.clone()).unwrap().trim_end().to_owned()).collect()
}

#[test]
fn a_file_mdxbuilder_4_built_reads_back_as_written() {
    let Ok(path) = std::env::var("XDICT_MDX_MDXBUILDER_V3") else {
        eprintln!("not measured: XDICT_MDX_MDXBUILDER_V3 is unset");
        return;
    };
    let file = File::open(&PathBuf::from(&path)).unwrap_or_else(|e| panic!("{path}: {e}"));

    assert_eq!(file.header().version, FormatVersion::V3_0);
    assert_eq!(file.header().kind, Kind::Mdx);
    assert_eq!(file.header().title, "XDict synthetic v3");
    assert_eq!(file.len(), 4_010);

    assert_eq!(texts(&file, "bank"), ["the side of a river", "a place for money"]);
    assert_eq!(texts(&file, "Run"), ["to move fast", "a period of running"]);
    assert_eq!(texts(&file, "run"), ["a period of running", "to move fast"]);
    assert_eq!(texts(&file, "runs"), ["@@@LINK=run"]);
    assert_eq!(texts(&file, "café"), ["a small restaurant — 咖啡馆"]);
    assert_eq!(texts(&file, "ice cream"), ["a frozen dessert"]);
    assert_eq!(texts(&file, "长"), ["long; 长度"]);
    assert_eq!(
        texts(&file, "apple"),
        [r#"<b>apple</b> a fruit <img src="/pic/a.png"> <a href="sound://t.mp3">play</a>"#]
    );
    assert_eq!(texts(&file, "zebra"), ["an animal with stripes"]);
    // Every generated entry, which spans all eleven record blocks and all three key blocks.
    for n in 0..4_000 {
        let key = format!("word{n:05}");
        let found = texts(&file, &key);
        assert_eq!(found.len(), 1, "{key}");
        let expected = format!("synthetic entry number {n} {}", "lorem ".repeat(n % 50)).trim_end().to_owned();
        assert_eq!(found[0], expected, "{key}");
    }
}
