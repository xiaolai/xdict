//! The reader against files written by `xdict-mdx-writer`, an independent implementation of the format.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

mod support;

use support::Scratch;
use xdict_mdx::{Error, File, FormatVersion, Kind, Unsupported};
use xdict_mdx_writer::{self as writer, Compression, Defect, Entry, Spec, TextEncoding, Version};

fn open(spec: &Spec, entries: &[Entry]) -> (Scratch, Result<File, Error>) {
    let extension = if matches!(spec.kind, writer::Kind::Mdd) { "mdd" } else { "mdx" };
    let scratch = Scratch::with(&writer::write(spec, entries).unwrap(), extension);
    let file = File::open(scratch.path());
    (scratch, file)
}

fn words() -> Vec<Entry> {
    vec![
        Entry::text("apple", "<b>apple</b> a fruit"),
        Entry::text("bank", "the side of a river"),
        Entry::text("bank", "a place for money"),
        Entry::text("café", "a small restaurant — 咖啡馆"),
        Entry::text("ice-cream", "a frozen dessert"),
        Entry::text("Run", "to move fast"),
        Entry::text("zebra", "an animal with stripes"),
        Entry::text("长", "long"),
    ]
}

fn text(record: &xdict_mdx::Record) -> &str {
    std::str::from_utf8(&record.data).expect("an MDX record is returned as UTF-8")
}

#[test]
fn every_version_compression_and_encoding_reads_back_every_entry() {
    let entries = words();
    for version in [Version::V1_2, Version::V2_0, Version::V3_0] {
        for compression in [Compression::None, Compression::Zlib] {
            for encoding in [TextEncoding::Utf8, TextEncoding::Utf16] {
                for obfuscate in [false, true] {
                    if obfuscate && version == Version::V1_2 {
                        continue; // the format has no key-index obfuscation before 2.0
                    }
                    if version == Version::V3_0 && (encoding == TextEncoding::Utf16 || obfuscate) {
                        continue; // 3.0 is UTF-8 and encrypts every block, whatever the spec says
                    }
                    let spec = Spec {
                        version,
                        compression,
                        kind: writer::Kind::Mdx(encoding),
                        obfuscate_key_index: obfuscate,
                        ..Spec::mdx()
                    };
                    let label = format!("{version:?} {compression:?} {encoding:?} obfuscated={obfuscate}");
                    let (_scratch, file) = open(&spec, &entries);
                    let file = file.unwrap_or_else(|e| panic!("{label}: {e}"));
                    assert_eq!(file.len(), entries.len(), "{label}");
                    assert_eq!(file.header().kind, Kind::Mdx, "{label}");
                    let expected_version = match version {
                        Version::V1_2 => FormatVersion::V1_2,
                        Version::V2_0 => FormatVersion::V2_0,
                        Version::V3_0 => FormatVersion::V3_0,
                    };
                    assert_eq!(file.header().version, expected_version, "{label}");
                    assert_eq!(file.header().title, "Test Dictionary", "{label}");
                    for entry in &entries {
                        let found = file.lookup(&entry.key).unwrap_or_else(|e| panic!("{label}: {e}"));
                        let wanted = std::str::from_utf8(&entry.record).unwrap();
                        assert!(
                            found.iter().any(|r| text(r) == wanted),
                            "{label}: {:?} did not return {wanted:?}, got {found:?}",
                            entry.key
                        );
                    }
                }
            }
        }
    }
}

#[test]
fn a_repeated_key_returns_every_record_in_file_order() {
    let (_scratch, file) = open(&Spec::mdx(), &words());
    let file = file.unwrap();
    let found = file.lookup("bank").unwrap();
    let texts: Vec<&str> = found.iter().map(text).collect();
    assert_eq!(texts, ["the side of a river", "a place for money"]);
}

#[test]
fn a_missing_key_is_an_empty_answer_not_an_error() {
    let (_scratch, file) = open(&Spec::mdx(), &words());
    assert!(file.unwrap().lookup("nonexistent").unwrap().is_empty());
}

#[test]
fn case_is_folded_only_where_the_header_allows_it() {
    let (_s1, insensitive) = open(&Spec::mdx(), &words());
    let insensitive = insensitive.unwrap();
    assert_eq!(text(&insensitive.lookup("run").unwrap()[0]), "to move fast");
    assert_eq!(text(&insensitive.lookup("APPLE").unwrap()[0]), "<b>apple</b> a fruit");

    let sensitive_spec = Spec { key_case_sensitive: true, ..Spec::mdx() };
    let (_s2, sensitive) = open(&sensitive_spec, &words());
    let sensitive = sensitive.unwrap();
    assert!(sensitive.lookup("run").unwrap().is_empty());
    assert_eq!(text(&sensitive.lookup("Run").unwrap()[0]), "to move fast");
}

#[test]
fn punctuation_and_spaces_are_ignored_unless_strip_key_says_no() {
    for strip in [Some(true), None] {
        let (_s, file) = open(&Spec { strip_key: strip, ..Spec::mdx() }, &words());
        let file = file.unwrap();
        for query in ["ice cream", "icecream", "ice-cream"] {
            let found = file.lookup(query).unwrap();
            assert_eq!(found.len(), 1, "strip={strip:?} query={query:?}");
            assert_eq!(text(&found[0]), "a frozen dessert");
        }
    }
    let (_s, file) = open(&Spec { strip_key: Some(false), ..Spec::mdx() }, &words());
    assert!(file.unwrap().lookup("icecream").unwrap().is_empty());
}

#[test]
fn an_exact_match_comes_before_a_folded_one() {
    let entries = vec![Entry::text("US", "United States"), Entry::text("us", "we, as an object")];
    let (_s, file) = open(&Spec::mdx(), &entries);
    let file = file.unwrap();
    let lower = file.lookup("us").unwrap();
    assert_eq!(lower.iter().map(text).collect::<Vec<_>>(), ["we, as an object", "United States"]);
    let upper = file.lookup("US").unwrap();
    assert_eq!(upper.iter().map(text).collect::<Vec<_>>(), ["United States", "we, as an object"]);
}

#[test]
fn mdd_resources_come_back_byte_for_byte() {
    let png = [0x89u8, b'P', b'N', b'G', 0, 0, 1, 2, 0xFF];
    let mp3 = vec![0xABu8; 300];
    let entries =
        vec![Entry::bytes("\\image.png", &png), Entry::bytes("\\sound\\a.mp3", &mp3), Entry::bytes("\\x.css", b"")];
    for version in [Version::V1_2, Version::V2_0] {
        let spec = Spec { version, obfuscate_key_index: version == Version::V2_0, ..Spec::mdd() };
        let (_s, file) = open(&spec, &entries);
        let file = file.unwrap();
        assert_eq!(file.header().kind, Kind::Mdd);
        assert_eq!(file.lookup("\\image.png").unwrap()[0].data, png);
        assert_eq!(file.lookup("\\sound\\a.mp3").unwrap()[0].data, mp3);
        assert_eq!(file.lookup("\\x.css").unwrap()[0].data, Vec::<u8>::new());
    }
}

#[test]
fn keys_are_listed_in_file_order() {
    let (_s, file) = open(&Spec::mdx(), &words());
    let keys: Vec<String> = file.unwrap().keys().map(str::to_owned).collect();
    let mut expected: Vec<String> = words().into_iter().map(|e| e.key).collect();
    expected.sort();
    assert_eq!(keys, expected);
}

fn refusal(defect: Defect) -> Error {
    refusal_in(Version::V2_0, defect)
}

fn refusal_in(version: Version, defect: Defect) -> Error {
    let obfuscate_key_index = version == Version::V2_0;
    let (_s, file) = open(&Spec { version, obfuscate_key_index, defect: Some(defect), ..Spec::mdx() }, &words());
    match file {
        Err(e) => e,
        Ok(file) => file.lookup("apple").expect_err("a defective file must be refused somewhere"),
    }
}

#[test]
fn an_unknown_format_version_is_refused_by_name() {
    for version in [Version::V2_0, Version::V3_0] {
        let refused = refusal_in(version, Defect::UnknownFormatVersion);
        assert!(matches!(&refused, Error::Unsupported(Unsupported::FormatVersion(v)) if v == "4.0"), "{version:?}: {refused}");
    }
}

#[test]
fn a_format_3_resource_library_is_refused_by_name() {
    // No real 3.0 `.mdd` has been seen (dev-docs/format-v3-facts.md), so one is refused rather than guessed at.
    let scratch = Scratch::with(&writer::write(&Spec { version: Version::V3_0, ..Spec::mdx() }, &words()).unwrap(), "mdd");
    let refused = File::open(scratch.path()).err().expect("a 3.0 .mdd must be refused");
    assert!(matches!(refused, Error::Unsupported(Unsupported::ResourceLibraryV3)), "{refused}");
}

#[test]
fn a_source_declared_as_a_resource_library_refuses_format_3() {
    let bytes = writer::write(&Spec { version: Version::V3_0, ..Spec::mdx() }, &words()).unwrap();
    let refused = File::from_source(Box::new(bytes.clone()), Some(Kind::Mdd)).err().expect("must be refused");
    assert!(matches!(refused, Error::Unsupported(Unsupported::ResourceLibraryV3)), "{refused}");
    assert!(File::from_source(Box::new(bytes), None).is_ok());
}

/// A key block holding more keys than it declares is refused before the surplus is stored, in every layout.
#[test]
fn a_key_block_holding_more_keys_than_it_declares_is_malformed() {
    for version in [Version::V1_2, Version::V2_0, Version::V3_0] {
        let refused = refusal_in(version, Defect::OverfullKeyBlock);
        assert!(matches!(&refused, Error::Malformed(m) if m.contains("more than")), "{version:?}: {refused}");
    }
}

#[test]
fn format_3_damage_is_refused_like_2_0_damage() {
    assert!(matches!(refusal_in(Version::V3_0, Defect::LzoRecordBlock), Error::Unsupported(Unsupported::Lzo)));
    assert!(matches!(refusal_in(Version::V3_0, Defect::CorruptRecordBlock), Error::Malformed(_)));
    assert!(matches!(refusal_in(Version::V3_0, Defect::HeaderChecksum), Error::Malformed(_)));
}

#[test]
fn registration_code_encryption_is_refused_by_name() {
    assert!(matches!(refusal(Defect::RegistrationCodeBit), Error::Unsupported(Unsupported::RegistrationCode)));
}

#[test]
fn an_lzo_block_is_refused_by_name() {
    assert!(matches!(refusal(Defect::LzoRecordBlock), Error::Unsupported(Unsupported::Lzo)));
}

#[test]
fn a_corrupt_block_is_malformed() {
    assert!(matches!(refusal(Defect::CorruptRecordBlock), Error::Malformed(_)));
}

#[test]
fn a_wrong_header_checksum_is_malformed() {
    assert!(matches!(refusal(Defect::HeaderChecksum), Error::Malformed(_)));
}

#[test]
fn refusals_are_sentences() {
    let message = refusal(Defect::UnknownFormatVersion).to_string();
    assert!(message.contains("4.0"), "{message}");
    assert!(!message.contains("NotImplemented"), "{message}");
}

/// No input may panic the reader: every prefix of a valid file, and deterministic byte flips across it.
#[test]
fn truncated_and_corrupted_files_never_panic() {
    for spec in [
        Spec::mdx(),
        Spec { version: Version::V1_2, obfuscate_key_index: false, ..Spec::mdx() },
        Spec { version: Version::V3_0, ..Spec::mdx() },
        Spec::mdd(),
    ] {
        let entries = if matches!(spec.kind, writer::Kind::Mdd) {
            vec![Entry::bytes("\\a.png", &[1, 2, 3]), Entry::bytes("\\b.mp3", &[4; 40])]
        } else {
            words()
        };
        let good = writer::write(&spec, &entries).unwrap();
        // Counts how many inputs opened and how many were refused, so the sweep is shown to reach both.
        let (opened, refused) = (std::cell::Cell::new(0), std::cell::Cell::new(0));
        let exercise = |bytes: &[u8]| {
            let scratch = Scratch::with(bytes, "mdx");
            match File::open(scratch.path()) {
                Ok(file) => {
                    opened.set(opened.get() + 1);
                    for key in ["apple", "bank", "\\a.png", "zebra", ""] {
                        let _ = file.lookup(key);
                    }
                    let _ = file.keys().count();
                }
                Err(_) => refused.set(refused.get() + 1),
            }
        };
        exercise(&good);
        assert_eq!(opened.get(), 1, "the unaltered file must open");
        for length in 0..good.len() {
            exercise(&good[..length]);
        }
        assert!(refused.get() >= good.len(), "every truncation must be refused");
        let mut state = 0x2545_F491_4F6C_DD1Du64;
        for _ in 0..2_000 {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            let mut bad = good.clone();
            let at = (state as usize) % bad.len();
            bad[at] ^= ((state >> 32) as u8) | 1;
            exercise(&bad);
        }
        assert!(opened.get() > 1, "{:?}: no corrupted variant opened, so lookups on damaged files went untested", spec.kind);
    }
}
