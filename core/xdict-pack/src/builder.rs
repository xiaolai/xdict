//! The pack under construction: one canonical order, by type and then by line, de-duplicated.

use std::collections::{BTreeMap, BTreeSet};

use crate::error::{PackError, PackErrorKind, PackResult};
use crate::json::Value;
use crate::limits::{
    MAX_LINE_BYTES, MAX_LIST_ITEMS, MAX_RECORDS, MAX_TOTAL_BYTES, PACK_LANGUAGE, PACK_SCHEMA, PACK_VERSION,
    RECORD_TYPES,
};
use crate::manifest::Source;
use crate::record::{HeaderSource, RawRecord, header_source, validate_record};

/// Collects records into the pack's one canonical order.
///
/// `strict` raises on every invalid record; otherwise a record past a loader bound (which the schema cannot hold,
/// and which is never truncated) is counted in `rejected` and left out, and any other fault raises.
pub struct PackBuilder {
    sources: Vec<HeaderSource>,
    ids: BTreeSet<String>,
    strict: bool,
    lines: BTreeMap<&'static str, BTreeSet<String>>,
    origins: BTreeMap<String, String>,
    rejected: BTreeMap<String, u64>,
}

impl PackBuilder {
    /// A builder over `sources`, whose header ids must be distinct.
    pub fn new(sources: &[Source], strict: bool) -> PackResult<Self> {
        let mut header: Vec<HeaderSource> = sources.iter().map(header_source).collect::<PackResult<_>>()?;
        header.sort_by(|left, right| left.id().cmp(right.id()));
        if header.is_empty() {
            return Err(PackError::new(PackErrorKind::Licence, "a pack needs at least one source"));
        }
        let ids: BTreeSet<String> = header.iter().map(|source| source.id().to_string()).collect();
        if ids.len() != header.len() {
            return Err(PackError::new(PackErrorKind::Malformed, "duplicate source id in the header"));
        }
        Ok(Self {
            sources: header,
            ids,
            strict,
            lines: RECORD_TYPES.iter().map(|kind| (*kind, BTreeSet::new())).collect(),
            origins: BTreeMap::new(),
            rejected: BTreeMap::new(),
        })
    }

    /// Adds one record, charging any failure to `provider`.
    pub fn add(&mut self, record: &RawRecord, provider: &str) -> PackResult<()> {
        let clean = match validate_record(record) {
            Ok(clean) => clean,
            Err(error) => {
                if self.strict || error.kind() != PackErrorKind::Bound {
                    return Err(error.with_source(provider));
                }
                let kind = record.kind().unwrap_or("record");
                *self.rejected.entry(format!("{provider}: {kind} over a loader bound")).or_insert(0) += 1;
                return Ok(());
            }
        };
        if let Some(source) = clean.text("source")
            && !self.ids.contains(source)
        {
            return Err(PackError::at_source(
                PackErrorKind::Licence,
                provider,
                format!("record names unlisted source '{source}'"),
            ));
        }
        let line = clean.line();
        if line.len() as u64 + 1 > MAX_LINE_BYTES {
            if self.strict {
                return Err(PackError::at_source(
                    PackErrorKind::Bound,
                    provider,
                    format!("a {} line over {MAX_LINE_BYTES} bytes", clean.kind()),
                ));
            }
            *self
                .rejected
                .entry(format!("{provider}: {} line over {MAX_LINE_BYTES} bytes", clean.kind()))
                .or_insert(0) += 1;
            return Ok(());
        }
        if clean.kind() == "origin" {
            let id = clean.text("id").unwrap_or("").to_string();
            match self.origins.get(&id) {
                Some(seen) if *seen != line => {
                    return Err(PackError::at_source(
                        PackErrorKind::Malformed,
                        provider,
                        format!("origin '{id}' declared twice, differently"),
                    ));
                }
                Some(_) => {}
                None => {
                    self.origins.insert(id, line.clone());
                }
            }
        }
        if let Some(bucket) = self.lines.get_mut(clean.kind()) {
            bucket.insert(line);
        }
        Ok(())
    }

    /// The pack's header line.
    pub fn header_line(&self) -> PackResult<String> {
        if self.sources.len() as u64 > MAX_LIST_ITEMS {
            return Err(PackError::new(
                PackErrorKind::Bound,
                format!("{} header sources, over {MAX_LIST_ITEMS}", self.sources.len()),
            ));
        }
        let line = crate::json::canonical(&Value::obj(vec![
            ("type", Value::str("header")),
            ("schema", Value::str(PACK_SCHEMA)),
            ("version", Value::Int(PACK_VERSION)),
            ("language", Value::str(PACK_LANGUAGE)),
            ("sources", Value::Arr(self.sources.iter().map(HeaderSource::value).collect())),
        ]));
        if line.len() as u64 + 1 > MAX_LINE_BYTES {
            return Err(PackError::new(PackErrorKind::Bound, format!("the header is over {MAX_LINE_BYTES} bytes")));
        }
        Ok(line)
    }

    /// How many distinct records of each type the pack holds.
    pub fn counts(&self) -> BTreeMap<&'static str, usize> {
        self.lines.iter().map(|(kind, lines)| (*kind, lines.len())).collect()
    }

    /// The whole pack, or `bound` if it is past the loader's record count or total size.
    pub fn pack_lines(&self) -> PackResult<Vec<String>> {
        let total: usize = self.counts().values().sum();
        if total as u64 > MAX_RECORDS {
            return Err(PackError::new(PackErrorKind::Bound, format!("{total} records, over {MAX_RECORDS}")));
        }
        let mut out = vec![self.header_line()?];
        for kind in RECORD_TYPES {
            if let Some(lines) = self.lines.get(kind) {
                out.extend(lines.iter().cloned());
            }
        }
        let size: u64 = out.iter().map(|line| line.len() as u64 + 1).sum();
        if size > MAX_TOTAL_BYTES {
            return Err(PackError::new(
                PackErrorKind::Bound,
                format!("the pack is {size} bytes, over {MAX_TOTAL_BYTES}"),
            ));
        }
        Ok(out)
    }

    /// The records left out for a loader bound, counted by reason.
    pub fn rejected(&self) -> &BTreeMap<String, u64> {
        &self.rejected
    }

    /// The header sources, in the order the pack lists them.
    pub fn sources(&self) -> &[HeaderSource] {
        &self.sources
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::indexing_slicing)]

    use super::*;
    use crate::record::FieldValue;

    fn source() -> Source {
        Source {
            id: "cmu".into(),
            provider: "cmudict".into(),
            name: "The CMU Pronouncing Dictionary".into(),
            url: "https://example.org/cmudict.dict".into(),
            version: "cmu@1".into(),
            sha256: "81917843c7f44ce2b094ac63873c2c7a4cf802040792c455ba3ca406891c3d22".into(),
            file: "cmudict.dict".into(),
            bytes: 1,
            licence: "BSD-2-Clause".into(),
            attribution: "Carnegie Mellon University".into(),
            notice: Some("Copyright".into()),
            notice_files: Vec::new(),
            coverage: None,
        }
    }

    fn record(word: &str) -> RawRecord {
        RawRecord::new(
            "pronunciation",
            vec![
                ("word", RawRecord::text(word)),
                ("system", RawRecord::text("arpabet")),
                ("phonemes", RawRecord::list(["HH", "EH1", "L", "OW0"])),
                ("source", RawRecord::text("cmu")),
            ],
        )
    }

    #[test]
    fn a_pack_is_its_header_then_its_records_in_type_order() {
        let mut builder = PackBuilder::new(&[source()], true).unwrap();
        builder.add(&record("b"), "cmu").unwrap();
        builder.add(&record("a"), "cmu").unwrap();
        builder.add(&record("a"), "cmu").unwrap();
        let lines = builder.pack_lines().unwrap();
        assert_eq!(lines.len(), 3);
        assert!(lines[0].contains("\"type\":\"header\""));
        assert!(lines[1].contains("\"word\":\"a\""));
        assert!(lines[2].contains("\"word\":\"b\""));
    }

    #[test]
    fn a_record_naming_an_unlisted_source_is_a_licence_failure() {
        let mut builder = PackBuilder::new(&[source()], true).unwrap();
        let raw = RawRecord::new(
            "pronunciation",
            vec![
                ("word", RawRecord::text("a")),
                ("system", RawRecord::text("arpabet")),
                ("phonemes", RawRecord::list(["AH0"])),
                ("source", RawRecord::text("nope")),
            ],
        );
        assert_eq!(builder.add(&raw, "cmu").unwrap_err().kind(), PackErrorKind::Licence);
    }

    #[test]
    fn a_bound_failure_is_counted_when_not_strict() {
        let long = "a".repeat(300);
        let raw = RawRecord::new(
            "origin",
            vec![("id", RawRecord::text("ety:1")), ("language", RawRecord::text(long)), ("form", RawRecord::text("x"))],
        );
        let mut builder = PackBuilder::new(&[source()], false).unwrap();
        builder.add(&raw, "ety").unwrap();
        assert_eq!(builder.rejected().values().sum::<u64>(), 1);
        let mut strict = PackBuilder::new(&[source()], true).unwrap();
        assert_eq!(strict.add(&raw, "ety").unwrap_err().kind(), PackErrorKind::Bound);
    }

    #[test]
    fn an_origin_declared_two_ways_is_refused() {
        let one = RawRecord::new(
            "origin",
            vec![
                ("id", RawRecord::text("ety:1")),
                ("language", RawRecord::text("Latin")),
                ("form", RawRecord::text("a")),
            ],
        );
        let two = RawRecord::new(
            "origin",
            vec![
                ("id", RawRecord::text("ety:1")),
                ("language", RawRecord::text("Latin")),
                ("form", RawRecord::text("b")),
            ],
        );
        let mut builder = PackBuilder::new(&[source()], true).unwrap();
        builder.add(&one, "ety").unwrap();
        assert_eq!(builder.add(&two, "ety").unwrap_err().kind(), PackErrorKind::Malformed);
        let _ = FieldValue::Null;
    }
}
