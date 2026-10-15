//! The health check's report as the boundary carries it (plan-macos-v1 WI-12): the checker's classes grouped into
//! what a reader is told, and the form it is kept in beside the edition's index.

use crate::types::{FindingKind, Health, HealthClass, HealthExample, HealthFinding};

/// The checker's version, which a kept report must match.
pub const HEALTH: u32 = xdict_health::VERSION;

/// Missing stylesheets and scripts named one by one; the rest are not named.
const NAMED_FILES: usize = 8;

/// Each kind a reader is told of and the classes it gathers, in the order findings are given. Classes not here are
/// counted and kept, never told: the browser's own recovery mends them (stray and misnested tags, entities), the
/// confinement blocks them (scripts), they are the format's design (homographs), or nothing is to be done (a site
/// path copied from the web, an app's pseudo-scheme).
const KINDS: &[(FindingKind, &[&str])] = &[
    (FindingKind::MissingSounds, &["link.sound_missing"]),
    (FindingKind::MissingImages, &["link.img_missing_resource", "link.media_missing_resource"]),
    (FindingKind::MissingWords, &["link.entry_missing_key", "link.bword_missing_key"]),
    (FindingKind::CodeAsText, &["markup.escaped_tag_as_text"]),
    (
        FindingKind::CommentMarks,
        &[
            "comment.stray_close",
            "comment.malformed_open_lt_dashes",
            "comment.malformed_open_bang_dash",
            "comment.malformed_close_bang",
            "comment.nested",
            "comment.unclosed_swallows",
            "comment.unclosed_short",
        ],
    ),
    (FindingKind::StyleAsText, &["style.css_as_visible_text", "style.unclosed"]),
    (
        FindingKind::BrokenRedirects,
        &[
            "redirect.missing_target",
            "redirect.to_itself",
            "redirect.loop",
            "redirect.chain_too_deep",
            "redirect.chain_ends_missing",
            "redirect.empty_target",
        ],
    ),
    (FindingKind::DoubleEncoded, &["text.mojibake_double_utf8"]),
    (FindingKind::Undecodable, &["text.undecodable_bytes", "text.replacement_char_stored"]),
    (FindingKind::EmptyEntries, &["record.empty", "record.whitespace_only"]),
    (FindingKind::HugeEntries, &["record.huge_over_1mib"]),
    (FindingKind::RepeatedEntries, &["key.duplicate_identical_records"]),
    (
        FindingKind::OddHeadwords,
        &[
            "key.edge_whitespace",
            "key.invisible_or_control",
            "key.html_in_key",
            "key.entity_in_key",
            "key.replacement_char",
        ],
    ),
    (FindingKind::Repaired, &["text.repaired"]),
];

/// The checker's report as the boundary carries it.
pub(crate) fn of(report: &xdict_health::Report) -> Health {
    let mut findings = Vec::new();
    let mut files: Vec<(&String, &u64)> = report.missing_files.iter().filter(|(name, _)| !name.is_empty()).collect();
    files.sort_by(|a, b| b.1.cmp(a.1).then_with(|| a.0.cmp(b.0)));
    for (name, count) in files.into_iter().take(NAMED_FILES) {
        let class =
            if name.ends_with(".js") { "link.script_missing_resource" } else { "link.stylesheet_missing_resource" };
        let examples = report.classes.get(class).map(examples).unwrap_or_default();
        findings.push(HealthFinding {
            kind: FindingKind::MissingFile,
            count: *count,
            name: Some(name.clone()),
            examples,
        });
    }
    for (kind, classes) in KINDS {
        let count: u64 = classes.iter().map(|c| report.count(c)).sum();
        if count == 0 {
            continue;
        }
        let mut found = Vec::new();
        for class in *classes {
            for example in report.classes.get(*class).map(examples).unwrap_or_default() {
                if found.len() < xdict_health::EXAMPLES {
                    found.push(example);
                }
            }
        }
        findings.push(HealthFinding { kind: *kind, count, name: None, examples: found });
    }
    let classes =
        report.classes.iter().map(|(name, class)| HealthClass { name: name.clone(), count: class.count }).collect();
    Health { version: HEALTH, entries: report.records, findings, classes }
}

fn examples(class: &xdict_health::Class) -> Vec<HealthExample> {
    class.examples.iter().map(|(key, text)| HealthExample { key: key.clone(), text: text.clone() }).collect()
}

// MARK: - Kept beside the index

/// The first line of a kept report.
const MAGIC: &str = "xdict-health";
/// A kept report larger than this is not read: it is checked again.
pub(crate) const MAX_KEPT: u64 = 4 << 20;

fn kind_name(kind: FindingKind) -> &'static str {
    match kind {
        FindingKind::MissingFile => "missing-file",
        FindingKind::MissingSounds => "missing-sounds",
        FindingKind::MissingImages => "missing-images",
        FindingKind::MissingWords => "missing-words",
        FindingKind::CodeAsText => "code-as-text",
        FindingKind::CommentMarks => "comment-marks",
        FindingKind::StyleAsText => "style-as-text",
        FindingKind::BrokenRedirects => "broken-redirects",
        FindingKind::DoubleEncoded => "double-encoded",
        FindingKind::Undecodable => "undecodable",
        FindingKind::EmptyEntries => "empty-entries",
        FindingKind::HugeEntries => "huge-entries",
        FindingKind::RepeatedEntries => "repeated-entries",
        FindingKind::OddHeadwords => "odd-headwords",
        FindingKind::Repaired => "repaired",
    }
}

const ALL_KINDS: [FindingKind; 15] = [
    FindingKind::MissingFile,
    FindingKind::MissingSounds,
    FindingKind::MissingImages,
    FindingKind::MissingWords,
    FindingKind::CodeAsText,
    FindingKind::CommentMarks,
    FindingKind::StyleAsText,
    FindingKind::BrokenRedirects,
    FindingKind::DoubleEncoded,
    FindingKind::Undecodable,
    FindingKind::EmptyEntries,
    FindingKind::HugeEntries,
    FindingKind::RepeatedEntries,
    FindingKind::OddHeadwords,
    FindingKind::Repaired,
];

/// A field with its tab, line break and backslash escaped, so a line holds one record.
fn field(text: &str) -> String {
    text.replace('\\', "\\\\").replace('\t', "\\t").replace('\n', "\\n").replace('\r', "\\r")
}

fn unfield(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('t') => out.push('\t'),
            Some('n') => out.push('\n'),
            Some('r') => out.push('\r'),
            Some(other) => out.push(other),
            None => {}
        }
    }
    out
}

/// A report as kept: one line per item, tab-separated, after a line naming the checker's version.
pub(crate) fn encode(health: &Health) -> Vec<u8> {
    let mut out = format!("{MAGIC}\t{}\nentries\t{}\n", health.version, health.entries);
    for f in &health.findings {
        let name = f.name.as_deref().map(field).unwrap_or_default();
        out.push_str(&format!("finding\t{}\t{}\t{}\t{name}\n", kind_name(f.kind), f.count, u8::from(f.name.is_some())));
        for e in &f.examples {
            out.push_str(&format!("example\t{}\t{}\n", field(&e.key), field(&e.text)));
        }
    }
    for c in &health.classes {
        out.push_str(&format!("class\t{}\t{}\n", field(&c.name), c.count));
    }
    out.into_bytes()
}

/// A kept report, or `None` when it is not one this checker wrote: it is then checked again.
pub(crate) fn decode(bytes: &[u8]) -> Option<Health> {
    let text = std::str::from_utf8(bytes).ok()?;
    let mut lines = text.lines();
    let version: u32 = lines.next()?.strip_prefix(MAGIC)?.strip_prefix('\t')?.parse().ok()?;
    if version != HEALTH {
        return None;
    }
    let entries: u64 = lines.next()?.strip_prefix("entries\t")?.parse().ok()?;
    let mut health = Health { version, entries, findings: Vec::new(), classes: Vec::new() };
    for line in lines {
        let mut parts = line.split('\t');
        match parts.next()? {
            "finding" => {
                let kind = parts.next()?;
                let kind = *ALL_KINDS.iter().find(|k| kind_name(**k) == kind)?;
                let count = parts.next()?.parse().ok()?;
                let named = parts.next()? == "1";
                let name = parts.next()?;
                health.findings.push(HealthFinding {
                    kind,
                    count,
                    name: named.then(|| unfield(name)),
                    examples: Vec::new(),
                });
            }
            "example" => {
                let key = unfield(parts.next()?);
                let text = unfield(parts.next()?);
                health.findings.last_mut()?.examples.push(HealthExample { key, text });
            }
            "class" => {
                let name = unfield(parts.next()?);
                let count = parts.next()?.parse().ok()?;
                health.classes.push(HealthClass { name, count });
            }
            _ => return None,
        }
    }
    Some(health)
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::indexing_slicing)]

    use super::*;

    #[test]
    fn a_kept_report_reads_back_as_it_was() {
        let health = Health {
            version: HEALTH,
            entries: 3,
            findings: vec![
                HealthFinding {
                    kind: FindingKind::MissingFile,
                    count: 2,
                    name: Some("oed.css".into()),
                    examples: vec![HealthExample { key: "a\tb".into(), text: "x\\n\ny\r".into() }],
                },
                HealthFinding { kind: FindingKind::Repaired, count: 1, name: None, examples: vec![] },
            ],
            classes: vec![HealthClass { name: "text.repaired".into(), count: 1 }],
        };
        assert_eq!(decode(&encode(&health)), Some(health));
        assert_eq!(decode(b"xdict-health\t0\nentries\t1\n"), None, "another checker's");
        assert_eq!(decode(b"garbage"), None);
    }

    #[test]
    fn findings_gather_classes_and_name_missing_files() {
        let mut report = xdict_health::Report { records: 9, ..Default::default() };
        for (class, n) in [("link.entry_missing_key", 2), ("link.bword_missing_key", 1), ("markup.misnested", 5)] {
            report.classes.insert(class.into(), xdict_health::Class { count: n, examples: vec![] });
        }
        report.missing_files.insert("oed.css".into(), 4);
        report.missing_files.insert("oed.js".into(), 6);
        let health = of(&report);
        let kinds: Vec<(FindingKind, u64, Option<&str>)> =
            health.findings.iter().map(|f| (f.kind, f.count, f.name.as_deref())).collect();
        assert_eq!(
            kinds,
            [
                (FindingKind::MissingFile, 6, Some("oed.js")),
                (FindingKind::MissingFile, 4, Some("oed.css")),
                (FindingKind::MissingWords, 3, None),
            ]
        );
        assert_eq!(health.classes.len(), 3, "every class kept, told or not");
    }
}
