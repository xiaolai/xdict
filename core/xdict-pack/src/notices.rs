//! The notices sidecar: what the pack is, its licence as a whole, and every source's complete notices verbatim.

use crate::manifest::Notice;
use crate::record::HeaderSource;

/// The longest run of backticks in `text`, one longer than it, and never fewer than three.
fn fence(text: &str) -> String {
    let mut longest = 0usize;
    let mut run = 0usize;
    for ch in text.chars() {
        if ch == '`' {
            run += 1;
            longest = longest.max(run);
        } else {
            run = 0;
        }
    }
    "`".repeat(longest.saturating_add(1).max(3))
}

/// The sidecar: what the pack is, its licence as a whole, and every source's complete notices verbatim.
pub fn notices_text(pack_name: &str, pack_sha256: &str, entries: &[(HeaderSource, Vec<Notice>)]) -> String {
    let mut out: Vec<String> = vec![
        format!("# Notices for {pack_name}"),
        String::new(),
        format!("Pack SHA-256: `{pack_sha256}`"),
        String::new(),
        "This pack holds linguistic metadata only (pronunciations, inflected forms, derivational links and \
         etymological ancestry), built by XDict's own word pack builder — `xdict-pack`, whose reference \
         implementation is `word_lexicon.py` — from the sources below. It adapts ShareAlike \
         sources, so the pack as a whole is distributed under the Creative Commons Attribution-ShareAlike 4.0 \
         International licence, https://creativecommons.org/licenses/by-sa/4.0/ (CC BY-SA 3.0 material is \
         adapted under the later version its section 4(b) permits). Each source keeps its own terms, reproduced \
         in full below; this file must travel with the pack. The XDict code is licensed separately and does not \
         cover this pack."
            .to_string(),
        String::new(),
    ];
    for (source, notices) in entries {
        out.push(format!("## {}: {}", source.id(), source.name()));
        out.push(String::new());
        for (key, value) in [
            ("url", Some(source.url())),
            ("version", Some(source.version())),
            ("sha256", Some(source.sha256())),
            ("licence", Some(source.licence())),
            ("attribution", Some(source.attribution())),
            ("coverage", source.coverage()),
        ] {
            if let Some(value) = value.filter(|text| !text.is_empty()) {
                out.push(format!("- {key}: {value}"));
            }
        }
        out.push(String::new());
        for notice in notices {
            let title = match (&notice.file, &notice.sha256) {
                (None, _) => "Notice".to_string(),
                (Some(file), Some(sha)) => format!("{file} (SHA-256 {sha})"),
                (Some(file), None) => file.clone(),
            };
            let fence = fence(&notice.text);
            let body = if notice.text.ends_with('\n') { notice.text.clone() } else { format!("{}\n", notice.text) };
            out.push(format!("### {title}"));
            out.push(String::new());
            out.push(format!("{fence}text"));
            out.push(body + &fence);
            out.push(String::new());
        }
    }
    out.join("\n")
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::indexing_slicing)]

    use super::*;

    #[test]
    fn a_fence_is_longer_than_the_longest_run() {
        assert_eq!(fence("nothing"), "```");
        assert_eq!(fence("a ``` b"), "````");
        assert_eq!(fence("a ````` b"), "``````");
    }

    #[test]
    fn a_notice_is_written_with_its_title_and_fence() {
        let source = crate::manifest::Source {
            id: "cmu".into(),
            provider: "cmudict".into(),
            name: "CMU".into(),
            url: "https://example.org/x".into(),
            version: "v1".into(),
            sha256: "a".repeat(64),
            file: "x".into(),
            bytes: 1,
            licence: "BSD-2-Clause".into(),
            attribution: "CMU".into(),
            notice: None,
            notice_files: Vec::new(),
            coverage: None,
        };
        let header = crate::record::header_source(&source).unwrap();
        let text = notices_text(
            "xdict-words-en.jsonl",
            &"f".repeat(64),
            &[(header, vec![Notice { file: None, text: "Copyright".into(), sha256: None }])],
        );
        assert!(text.starts_with("# Notices for xdict-words-en.jsonl\n\nPack SHA-256: `"));
        assert!(text.contains("### Notice\n\n```text\nCopyright\n```\n"));
        assert!(text.contains("- licence: BSD-2-Clause"));
    }
}
