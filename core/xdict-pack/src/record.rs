//! A record checked against the loader's rules: every field typed, bounded and NFC-normalised, then written as the
//! one line a pack holds.

use std::collections::BTreeMap;

use crate::error::{PackError, PackErrorKind, PackResult};
use crate::json::{Value as JsonValue, canonical};
use crate::limits::{
    ARPABET_CONSONANTS, ARPABET_VOWELS, CONTENT_KEYS, ETYMON_RELATIONS, FAMILY_KINDS, MAX_LIST_ITEMS, MAX_STRING_CHARS,
    MAX_U32, PHONE_SYSTEMS, RECORD_TYPES, SENSE_RELATIONS, SOURCE_FIELDS,
};
use crate::manifest::{Source, source_id};
use crate::text::{has_control, https_host, nfc};

/// A field as a parser hands it over.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FieldValue {
    /// A string, normalised and checked.
    Text(String),
    /// A bool: only `uncertain` is one.
    Bool(bool),
    /// A list of strings: only `phonemes` and `tags` are.
    TextList(Vec<String>),
    /// A derivation's stem alignment.
    Stem(Stem),
    /// Python's `None`, which a parser writes for an absent optional field.
    Null,
}

/// A derivation's `stem`: two ARPAbet pronunciations and a half-open range of vowel indices on each.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Stem {
    /// The base word's phonemes.
    pub base_phonemes: Vec<String>,
    /// The first vowel index the base range covers.
    pub base_start: i64,
    /// One past the last vowel index the base range covers.
    pub base_end: i64,
    /// The derived word's phonemes.
    pub derived_phonemes: Vec<String>,
    /// The first vowel index the derived range covers.
    pub derived_start: i64,
    /// One past the last vowel index the derived range covers.
    pub derived_end: i64,
}

/// A record as a parser hands it over: its type, and its fields in the order it wrote them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RawRecord {
    pub(crate) fields: Vec<(String, FieldValue)>,
}

impl RawRecord {
    /// A record of `kind` with `fields`, none of them the type.
    pub fn new(kind: &str, fields: Vec<(&str, FieldValue)>) -> Self {
        let mut all = Vec::with_capacity(fields.len() + 1);
        all.push(("type".to_string(), FieldValue::Text(kind.to_string())));
        all.extend(fields.into_iter().map(|(key, value)| (key.to_string(), value)));
        Self { fields: all }
    }

    /// A string field.
    pub fn text(value: impl Into<String>) -> FieldValue {
        FieldValue::Text(value.into())
    }

    /// A list field.
    pub fn list(values: impl IntoIterator<Item = impl Into<String>>) -> FieldValue {
        FieldValue::TextList(values.into_iter().map(Into::into).collect())
    }

    /// The record's type, as the parser named it.
    pub fn kind(&self) -> Option<&str> {
        self.fields.first().and_then(|(key, value)| match (key.as_str(), value) {
            ("type", FieldValue::Text(kind)) => Some(kind.as_str()),
            _ => None,
        })
    }
}

/// One field of a validated record.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Field {
    /// A string.
    Text(String),
    /// A bool.
    Bool(bool),
    /// A list of strings.
    TextList(Vec<String>),
    /// A stem alignment.
    Stem(Stem),
}

/// A record that passed the loader's rules, ready to be written as a line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Record {
    kind: &'static str,
    fields: BTreeMap<&'static str, Field>,
}

impl Record {
    /// The record's type.
    pub fn kind(&self) -> &'static str {
        self.kind
    }

    /// The record as the one line a pack holds, no newline.
    pub fn line(&self) -> String {
        let mut pairs: Vec<(&str, JsonValue)> = Vec::with_capacity(self.fields.len() + 1);
        pairs.push(("type", JsonValue::str(self.kind)));
        for (key, field) in &self.fields {
            let value = match field {
                Field::Text(text) => JsonValue::str(text.clone()),
                Field::Bool(flag) => JsonValue::Bool(*flag),
                Field::TextList(items) => {
                    JsonValue::Arr(items.iter().map(|item| JsonValue::str(item.clone())).collect())
                }
                Field::Stem(stem) => stem_value(stem),
            };
            pairs.push((key, value));
        }
        canonical(&JsonValue::obj(pairs))
    }

    /// The text of a string field, when a caller needs to look inside a validated record.
    pub fn text(&self, key: &str) -> Option<&str> {
        match self.fields.get(key) {
            Some(Field::Text(text)) => Some(text.as_str()),
            _ => None,
        }
    }
}

fn stem_value(stem: &Stem) -> JsonValue {
    JsonValue::obj(vec![
        ("basePhonemes", JsonValue::Arr(stem.base_phonemes.iter().map(|p| JsonValue::str(p.clone())).collect())),
        ("baseStart", JsonValue::Int(stem.base_start.max(0) as u64)),
        ("baseEnd", JsonValue::Int(stem.base_end.max(0) as u64)),
        ("derivedPhonemes", JsonValue::Arr(stem.derived_phonemes.iter().map(|p| JsonValue::str(p.clone())).collect())),
        ("derivedStart", JsonValue::Int(stem.derived_start.max(0) as u64)),
        ("derivedEnd", JsonValue::Int(stem.derived_end.max(0) as u64)),
    ])
}

fn required(kind: &str) -> &'static [&'static str] {
    match kind {
        "pronunciation" => &["word", "system", "phonemes", "source"],
        "form" => &["form", "lemma", "pos", "tags", "source"],
        "derivation" => &["base", "derived", "kind", "source"],
        "origin" => &["id", "language", "form"],
        "etymon" => &["child", "parent", "relation", "uncertain", "source"],
        "sense" => &["word", "other", "relation", "synset", "source"],
        _ => &[],
    }
}

fn optional(kind: &str) -> &'static [&'static str] {
    match kind {
        "pronunciation" => &["pos", "dialect"],
        "derivation" => &["basePos", "derivedPos", "affix", "stem"],
        "origin" => &["word"],
        "sense" => &["pos"],
        _ => &[],
    }
}

fn malformed(message: impl Into<String>) -> PackError {
    PackError::new(PackErrorKind::Malformed, message)
}

fn bound(message: impl Into<String>) -> PackError {
    PackError::new(PackErrorKind::Bound, message)
}

/// The record checked against the loader's rules and NFC-normalised.
///
/// An unknown type or field, a missing field, a wrong value type, an empty string, a control character, an invalid
/// phoneme, kind or relation, or an invalid `stem` is `malformed`; a content key is `content`; a string over 256
/// scalars or a list over 64 items is `bound` (never truncated).
pub fn validate_record(raw: &RawRecord) -> PackResult<Record> {
    let kind = raw.kind().ok_or_else(|| malformed("a record is not an object"))?;
    let Some(kind) = RECORD_TYPES.iter().find(|name| **name == kind).copied() else {
        return Err(malformed(format!("unknown record type '{}'", raw.kind().unwrap_or(""))));
    };
    let wants = required(kind);
    let may = optional(kind);
    let mut out: BTreeMap<&'static str, Field> = BTreeMap::new();
    for (key, value) in &raw.fields {
        let name = key.as_str();
        if name == "type" {
            continue;
        }
        if CONTENT_KEYS.contains(&name) {
            return Err(PackError::new(PackErrorKind::Content, format!("{kind} carries '{name}'")));
        }
        let Some(static_key) = wants.iter().chain(may.iter()).copied().find(|candidate| *candidate == name) else {
            return Err(malformed(format!("{kind} has unknown field '{name}'")));
        };
        if matches!(value, FieldValue::Null) {
            if wants.contains(&name) {
                return Err(malformed(format!("{kind}.{name} is null")));
            }
            continue;
        }
        let field = match name {
            "uncertain" => match value {
                FieldValue::Bool(flag) => Field::Bool(*flag),
                _ => return Err(malformed(format!("{kind}.{name} is not a bool"))),
            },
            "stem" => match value {
                FieldValue::Stem(stem) => Field::Stem(stem_validated(stem)?),
                _ => return Err(malformed(format!("{kind}.{name} is not an object"))),
            },
            "phonemes" | "tags" => match value {
                FieldValue::TextList(items) => {
                    if items.is_empty() {
                        return Err(malformed(format!("{kind}.{name} is not a non-empty list")));
                    }
                    if items.len() as u64 > MAX_LIST_ITEMS {
                        return Err(bound(format!("{kind}.{name} has {} items, over {MAX_LIST_ITEMS}", items.len())));
                    }
                    let mut clean = Vec::with_capacity(items.len());
                    for item in items {
                        clean.push(string(kind, name, item)?);
                    }
                    Field::TextList(clean)
                }
                _ => return Err(malformed(format!("{kind}.{name} is not a non-empty list"))),
            },
            _ => match value {
                FieldValue::Text(text) => Field::Text(string(kind, name, text)?),
                _ => return Err(malformed(format!("{kind}.{name} is not a string"))),
            },
        };
        out.insert(static_key, field);
    }
    let mut missing: Vec<&str> = wants.iter().copied().filter(|key| !out.contains_key(key)).collect();
    if !missing.is_empty() {
        missing.sort_unstable();
        let listed = missing.iter().map(|key| format!("'{key}'")).collect::<Vec<_>>().join(", ");
        return Err(malformed(format!("{kind} lacks [{listed}]")));
    }
    match kind {
        "pronunciation" => {
            let system = text_of(&out, "system").unwrap_or("");
            if !PHONE_SYSTEMS.contains(&system) {
                return Err(malformed(format!("unknown phone system '{system}'")));
            }
            if system == "arpabet"
                && let Some(problem) = check_arpabet(texts_of(&out, "phonemes"))
            {
                return Err(malformed(problem));
            }
        }
        "derivation" => {
            let family = text_of(&out, "kind").unwrap_or("");
            if !FAMILY_KINDS.contains(&family) {
                return Err(malformed(format!("unknown derivation kind '{family}'")));
            }
        }
        "etymon" => {
            let relation = text_of(&out, "relation").unwrap_or("");
            if !ETYMON_RELATIONS.contains(&relation) {
                return Err(malformed(format!("unknown relation '{relation}'")));
            }
        }
        "sense" => {
            let relation = text_of(&out, "relation").unwrap_or("");
            if !SENSE_RELATIONS.contains(&relation) {
                return Err(malformed(format!("unknown sense relation '{relation}'")));
            }
        }
        _ => {}
    }
    Ok(Record { kind, fields: out })
}

fn text_of<'a>(fields: &'a BTreeMap<&'static str, Field>, key: &str) -> Option<&'a str> {
    match fields.get(key) {
        Some(Field::Text(text)) => Some(text.as_str()),
        _ => None,
    }
}

fn texts_of<'a>(fields: &'a BTreeMap<&'static str, Field>, key: &str) -> &'a [String] {
    match fields.get(key) {
        Some(Field::TextList(items)) => items.as_slice(),
        _ => &[],
    }
}

fn string(kind: &str, key: &str, value: &str) -> PackResult<String> {
    let text = nfc(value);
    if text.trim().is_empty() {
        return Err(malformed(format!("{kind}.{key} is empty")));
    }
    if has_control(&text) {
        return Err(malformed(format!("{kind}.{key} has a control character")));
    }
    let scalars = text.chars().count() as u64;
    if scalars > MAX_STRING_CHARS {
        return Err(bound(format!("{kind}.{key} has {scalars} scalars, over {MAX_STRING_CHARS}")));
    }
    Ok(text)
}

/// None if every phone is one of CMUdict's 39 with a well-placed stress digit, else the reason.
pub fn check_arpabet(phones: &[String]) -> Option<String> {
    for phone in phones {
        let base = phone.trim_end_matches(['0', '1', '2']);
        let stress = phone.get(base.len()..).unwrap_or("");
        if ARPABET_VOWELS.contains(&base) {
            if stress.chars().count() != 1 {
                return Some(format!("vowel '{phone}' needs exactly one stress digit"));
            }
        } else if ARPABET_CONSONANTS.contains(&base) {
            if !stress.is_empty() {
                return Some(format!("consonant '{phone}' carries stress"));
            }
        } else {
            return Some(format!("unknown phone '{phone}'"));
        }
    }
    None
}

fn vowel_count(phones: &[String]) -> i64 {
    phones.iter().filter(|phone| ARPABET_VOWELS.contains(&phone.trim_end_matches(['0', '1', '2']))).count() as i64
}

fn stem_validated(stem: &Stem) -> PackResult<Stem> {
    let mut clean = Stem::default();
    for (side, phonemes) in [("base", &stem.base_phonemes), ("derived", &stem.derived_phonemes)] {
        let key = format!("{side}Phonemes");
        if phonemes.is_empty() {
            return Err(malformed(format!("derivation.stem.{key} is not a non-empty list")));
        }
        if phonemes.len() as u64 > MAX_LIST_ITEMS {
            return Err(bound(format!("derivation.stem.{key} has {} items, over {MAX_LIST_ITEMS}", phonemes.len())));
        }
        let mut items = Vec::with_capacity(phonemes.len());
        for phone in phonemes {
            items.push(string("derivation", &format!("stem.{key}"), phone)?);
        }
        if let Some(problem) = check_arpabet(&items) {
            return Err(malformed(format!("derivation.stem.{key}: {problem}")));
        }
        if side == "base" {
            clean.base_phonemes = items;
        } else {
            clean.derived_phonemes = items;
        }
    }
    let mut spans: Vec<i64> = Vec::new();
    for side in ["base", "derived"] {
        let (start, end) =
            if side == "base" { (stem.base_start, stem.base_end) } else { (stem.derived_start, stem.derived_end) };
        for (edge, number) in [("Start", start), ("End", end)] {
            if number < 0 || number as u64 > MAX_U32 {
                return Err(malformed(format!(
                    "derivation.stem.{side}{edge} is not a whole number from 0 to {MAX_U32}"
                )));
            }
        }
        let phonemes = if side == "base" { &clean.base_phonemes } else { &clean.derived_phonemes };
        let vowels = vowel_count(phonemes);
        if !(start < end && end <= vowels) {
            return Err(malformed(format!(
                "derivation.stem: the {side} range {start}..{end} is not within its {vowels} vowels"
            )));
        }
        spans.push(end - start);
        if side == "base" {
            clean.base_start = start;
            clean.base_end = end;
        } else {
            clean.derived_start = start;
            clean.derived_end = end;
        }
    }
    if spans.first() != spans.get(1) {
        return Err(malformed(format!(
            "derivation.stem spans {} vowels of the base but {} of the derived word",
            spans.first().copied().unwrap_or(0),
            spans.get(1).copied().unwrap_or(0)
        )));
    }
    Ok(clean)
}

/// A source as the pack header lists it: every field non-empty and within the loader's string bound, the id a
/// source id (so within the loader's charset), sha256 64 lowercase hex.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HeaderSource {
    id: String,
    name: String,
    url: String,
    version: String,
    sha256: String,
    licence: String,
    attribution: String,
    coverage: Option<String>,
}

impl HeaderSource {
    /// The source's id.
    pub fn id(&self) -> &str {
        &self.id
    }

    /// The source's name.
    pub fn name(&self) -> &str {
        &self.name
    }

    /// The source's https URL.
    pub fn url(&self) -> &str {
        &self.url
    }

    /// The pinned version.
    pub fn version(&self) -> &str {
        &self.version
    }

    /// The pinned SHA-256.
    pub fn sha256(&self) -> &str {
        &self.sha256
    }

    /// The licence expression.
    pub fn licence(&self) -> &str {
        &self.licence
    }

    /// The short attribution.
    pub fn attribution(&self) -> &str {
        &self.attribution
    }

    /// What the source covers, when it says.
    pub fn coverage(&self) -> Option<&str> {
        self.coverage.as_deref()
    }

    /// The source as a pack header lists it.
    pub fn value(&self) -> JsonValue {
        let mut pairs = vec![
            ("id", JsonValue::str(self.id.clone())),
            ("name", JsonValue::str(self.name.clone())),
            ("url", JsonValue::str(self.url.clone())),
            ("version", JsonValue::str(self.version.clone())),
            ("sha256", JsonValue::str(self.sha256.clone())),
            ("licence", JsonValue::str(self.licence.clone())),
            ("attribution", JsonValue::str(self.attribution.clone())),
        ];
        if let Some(coverage) = &self.coverage {
            pairs.push(("coverage", JsonValue::str(coverage.clone())));
        }
        JsonValue::obj(pairs)
    }
}

/// A manifest source as the pack header lists it.
pub fn header_source(entry: &Source) -> PackResult<HeaderSource> {
    let mut out: Vec<(&'static str, String)> = Vec::with_capacity(SOURCE_FIELDS.len());
    for key in SOURCE_FIELDS {
        let value = match key {
            "id" => &entry.id,
            "name" => &entry.name,
            "url" => &entry.url,
            "version" => &entry.version,
            "sha256" => &entry.sha256,
            "licence" => &entry.licence,
            _ => &entry.attribution,
        };
        if value.trim().is_empty() {
            return Err(PackError::new(PackErrorKind::Licence, format!("source '{}' lacks {key}", entry.id)));
        }
        if value.trim().to_lowercase() == "pending" {
            return Err(PackError::new(PackErrorKind::Pending, format!("source '{}': {key} is pending", entry.id)));
        }
        let text = nfc(value);
        if has_control(&text) {
            return Err(malformed(format!("source '{}': {key} has a control character", entry.id)));
        }
        out.push((key, text));
    }
    let pick =
        |name: &str| out.iter().find(|(key, _)| *key == name).map(|(_, value)| value.clone()).unwrap_or_default();
    let id = pick("id");
    if !source_id(&id) {
        return Err(malformed(format!(
            "source id '{id}' is not a source id the loader reads (letters, digits and - _ . :)"
        )));
    }
    let sha256 = pick("sha256");
    if !(sha256.len() == 64 && sha256.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))) {
        return Err(malformed(format!("source '{id}': sha256 is not 64 lowercase hex digits")));
    }
    let url = pick("url");
    if https_host(&url).is_none() {
        return Err(malformed(format!("source '{id}': url is not an https address with a host")));
    }
    let coverage = entry.coverage.as_ref().filter(|text| !text.trim().is_empty()).map(|text| nfc(text));
    if let Some(coverage) = &coverage
        && has_control(coverage)
    {
        return Err(malformed(format!("source '{id}': coverage has a control character")));
    }
    let header = HeaderSource {
        name: pick("name"),
        version: pick("version"),
        licence: pick("licence"),
        attribution: pick("attribution"),
        sha256,
        url,
        id,
        coverage,
    };
    for (key, value) in [
        ("id", Some(&header.id)),
        ("name", Some(&header.name)),
        ("url", Some(&header.url)),
        ("version", Some(&header.version)),
        ("sha256", Some(&header.sha256)),
        ("licence", Some(&header.licence)),
        ("attribution", Some(&header.attribution)),
        ("coverage", header.coverage.as_ref()),
    ] {
        if let Some(value) = value
            && value.chars().count() as u64 > MAX_STRING_CHARS
        {
            return Err(bound(format!(
                "source '{}': {key} has {} scalars, over {MAX_STRING_CHARS}",
                header.id,
                value.chars().count()
            )));
        }
    }
    Ok(header)
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::indexing_slicing)]

    use super::*;

    fn pronunciation(word: &str) -> RawRecord {
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
    fn a_record_becomes_one_canonical_line() {
        let record = validate_record(&pronunciation("hello")).unwrap();
        assert_eq!(
            record.line(),
            r#"{"phonemes":["HH","EH1","L","OW0"],"source":"cmu","system":"arpabet","type":"pronunciation","word":"hello"}"#
        );
    }

    #[test]
    fn a_content_key_is_refused() {
        let mut raw = pronunciation("hello");
        raw.fields.push(("gloss".to_string(), RawRecord::text("a greeting")));
        assert_eq!(validate_record(&raw).unwrap_err().kind(), PackErrorKind::Content);
    }

    #[test]
    fn an_unknown_field_is_malformed() {
        let mut raw = pronunciation("hello");
        raw.fields.push(("nonsense".to_string(), RawRecord::text("x")));
        assert_eq!(validate_record(&raw).unwrap_err().kind(), PackErrorKind::Malformed);
    }

    #[test]
    fn a_missing_field_is_named() {
        let mut raw = pronunciation("hello");
        raw.fields.retain(|(key, _)| key != "word");
        let error = validate_record(&raw).unwrap_err();
        assert!(error.to_string().contains("lacks ['word']"), "{error}");
    }

    #[test]
    fn a_bad_phone_is_refused() {
        let mut raw = pronunciation("hello");
        raw.fields.retain(|(key, _)| key != "phonemes");
        raw.fields.push(("phonemes".to_string(), RawRecord::list(["HH", "XX"])));
        assert!(validate_record(&raw).unwrap_err().to_string().contains("unknown phone"));
    }

    #[test]
    fn a_consonant_carrying_stress_is_refused() {
        assert!(check_arpabet(&["B1".to_string()]).is_some());
        assert!(check_arpabet(&["B".to_string()]).is_none());
        assert!(check_arpabet(&["AH0".to_string()]).is_none());
        assert!(check_arpabet(&["AH".to_string()]).is_some());
    }

    #[test]
    fn a_string_past_its_bound_is_a_bound_failure() {
        let long = "a".repeat(MAX_STRING_CHARS as usize + 1);
        let record = RawRecord::new(
            "origin",
            vec![("id", RawRecord::text("ety:1")), ("language", RawRecord::text(long)), ("form", RawRecord::text("x"))],
        );
        assert_eq!(validate_record(&record).unwrap_err().kind(), PackErrorKind::Bound);
    }

    #[test]
    fn a_good_stem_is_kept_and_a_bad_one_refused() {
        let good = Stem {
            base_phonemes: vec!["B".into(), "AH1".into(), "T".into()],
            base_start: 0,
            base_end: 1,
            derived_phonemes: vec!["B".into(), "AH1".into(), "T".into(), "IH0".into(), "NG".into()],
            derived_start: 0,
            derived_end: 1,
        };
        let record = RawRecord::new(
            "derivation",
            vec![
                ("base", RawRecord::text("bat")),
                ("derived", RawRecord::text("bating")),
                ("kind", RawRecord::text("suffix")),
                ("stem", FieldValue::Stem(good)),
                ("source", RawRecord::text("cmu")),
            ],
        );
        let clean = validate_record(&record).unwrap();
        assert!(clean.line().contains("\"baseEnd\":1"));
        let bad = Stem { base_phonemes: vec!["B".into()], base_start: 0, base_end: 3, ..Default::default() };
        let record = RawRecord::new(
            "derivation",
            vec![
                ("base", RawRecord::text("bat")),
                ("derived", RawRecord::text("bating")),
                ("kind", RawRecord::text("suffix")),
                ("stem", FieldValue::Stem(bad)),
                ("source", RawRecord::text("cmu")),
            ],
        );
        assert_eq!(validate_record(&record).unwrap_err().kind(), PackErrorKind::Malformed);
    }
}
