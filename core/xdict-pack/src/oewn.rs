//! Open English Wordnet: POS-tagged IPA, sense-level derivation links, synonyms and antonyms — and nothing of its
//! definitions, examples or untagged form lists.

use std::collections::BTreeMap;

use serde_json::Value as Json;

use crate::Emit;
use crate::error::{PackError, PackErrorKind, PackResult};
use crate::limits::{MAX_ZIP_MEMBER_BYTES, OEWN_POS, lookup};
use crate::record::RawRecord;
use crate::text::nfc;
use crate::zip::Zip;

/// One document of the archive: the file's base name, and its parsed JSON.
pub type Document = (String, Json);

/// The zip's `entries-*.json` and synset documents, by name.
///
/// Nothing else is opened — `frames.json`, every synset's definitions and examples and every other file in the zip
/// stay unread.
pub fn read_oewn_zip(file: std::fs::File, source: &str) -> PackResult<Vec<Document>> {
    let zip = Zip::from_file(file, source)?;
    let mut listed: Vec<(String, String, String)> = Vec::new();
    for entry in zip.entries() {
        if entry.name.ends_with('/') {
            continue;
        }
        let name = base_name(&entry.name).to_string();
        if !(is_entries(&name) || is_synsets(&name)) {
            continue;
        }
        if entry.uncompressed > MAX_ZIP_MEMBER_BYTES {
            return Err(PackError::at_source(
                PackErrorKind::Bound,
                source,
                format!("{name} is over {MAX_ZIP_MEMBER_BYTES} bytes"),
            ));
        }
        let data = zip.read(entry, source)?;
        if data.len() as u64 > MAX_ZIP_MEMBER_BYTES {
            return Err(PackError::at_source(
                PackErrorKind::Bound,
                source,
                format!("{name} is over {MAX_ZIP_MEMBER_BYTES} bytes"),
            ));
        }
        let text = String::from_utf8(data)
            .map_err(|error| PackError::at_source(PackErrorKind::Malformed, source, format!("{name}: {error}")))?;
        listed.push((entry.name.clone(), name, text));
    }
    listed.sort_by(|left, right| left.0.cmp(&right.0));
    let mut names: Vec<String> = Vec::new();
    let mut docs = Vec::with_capacity(listed.len());
    for (_, name, text) in listed {
        if names.contains(&name) {
            return Err(PackError::at_source(PackErrorKind::Malformed, source, format!("{name} appears twice")));
        }
        names.push(name.clone());
        let parsed: Json = serde_json::from_str(&text)
            .map_err(|error| PackError::at_source(PackErrorKind::Malformed, source, format!("{name}: {error}")))?;
        docs.push((name, parsed));
    }
    if !docs.iter().any(|(name, _)| is_entries(name)) {
        return Err(PackError::at_source(PackErrorKind::Version, source, "no entries-*.json in the zip"));
    }
    Ok(docs)
}

fn base_name(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}

fn is_entries(name: &str) -> bool {
    let Some(rest) = name.strip_prefix("entries-") else { return false };
    let Some(stem) = rest.strip_suffix(".json") else { return false };
    !stem.is_empty() && !stem.contains('/')
}

fn is_synsets(name: &str) -> bool {
    let Some((prefix, rest)) = name.split_once('.') else { return false };
    if !matches!(prefix, "adj" | "adv" | "noun" | "verb") {
        return false;
    }
    let Some(stem) = rest.strip_suffix(".json") else { return false };
    !stem.is_empty() && stem.chars().all(|ch| ch.is_ascii_alphabetic() || ch == '_')
}

/// An entry key: a POS code, optionally numbered (`n-1`) for a further lexeme of the same POS.
fn entry_code(code: &str) -> Option<&str> {
    let (head, rest) = match code.split_once('-') {
        Some((head, rest)) => (head, Some(rest)),
        None => (code, None),
    };
    if !matches!(head, "n" | "v" | "a" | "r" | "s") {
        return None;
    }
    if let Some(number) = rest {
        let mut digits = number.chars();
        let first = digits.next()?;
        if !matches!(first, '1'..='9') || !digits.all(|ch| ch.is_ascii_digit()) {
            return None;
        }
    }
    Some(head)
}

fn with_place(source: &str, name: &str) -> String {
    format!("{source}/{name}")
}

/// OEWN `entries-*.json` and synset documents to pronunciation, derivation and sense records.
///
/// Each pronunciation keeps its entry's part of speech and its `variety` as the dialect. A sense's `derivation`
/// targets become derivation records, their endpoints unoriented and in alphabetical order. A synset's `members`
/// are its synonyms, written one pair each way; an antonym is written each way too, each record naming the synset
/// its own word's sense declares.
pub fn parse_oewn_entries(docs: &[Document], source: &str, emit: Emit<'_>) -> PackResult<()> {
    let mut senses: BTreeMap<String, (String, String)> = BTreeMap::new();
    let mut sense_synset: BTreeMap<String, String> = BTreeMap::new();
    let mut links: Vec<(String, String, String)> = Vec::new();
    let mut antonyms: Vec<(String, String, String)> = Vec::new();
    let mut synsets: BTreeMap<String, (String, Vec<String>)> = BTreeMap::new();
    for (name, doc) in docs {
        if is_synsets(name) {
            read_synsets(doc, source, name, &mut synsets)?;
            continue;
        }
        if !is_entries(name) {
            continue;
        }
        let where_ = with_place(source, name);
        let Some(lemmas) = doc.as_object() else {
            return Err(PackError::at_source(PackErrorKind::Malformed, where_, "not an object"));
        };
        for (lemma, by_pos) in lemmas {
            let Some(positions) = by_pos.as_object() else {
                return Err(PackError::at_source(
                    PackErrorKind::Malformed,
                    where_,
                    format!("entry '{lemma}' is not an object"),
                ));
            };
            if lemma.is_empty() {
                return Err(PackError::at_source(
                    PackErrorKind::Malformed,
                    where_,
                    format!("entry '{lemma}' is not an object"),
                ));
            }
            for (code, entry) in positions {
                let Some(head) = entry_code(code) else {
                    return Err(PackError::at_source(
                        PackErrorKind::Malformed,
                        where_,
                        format!("'{lemma}': unknown part of speech '{code}'"),
                    ));
                };
                if entry.as_object().is_none() {
                    return Err(PackError::at_source(
                        PackErrorKind::Malformed,
                        where_,
                        format!("'{lemma}'/{code}: not an object"),
                    ));
                }
                let pos = lookup(&OEWN_POS, head).unwrap_or("noun");
                emit_pronunciations(entry, lemma, pos, source, &where_, emit)?;
                for sense in list_field(entry, "sense", lemma, code, &where_)? {
                    let sid = sense.get("id").and_then(Json::as_str).unwrap_or("");
                    if sid.is_empty() {
                        return Err(PackError::at_source(
                            PackErrorKind::Malformed,
                            where_,
                            format!("'{lemma}': a sense without an id"),
                        ));
                    }
                    let declared = (lemma.clone(), pos.to_string());
                    let seen = senses.entry(sid.to_string()).or_insert_with(|| declared.clone());
                    if *seen != declared {
                        return Err(PackError::at_source(
                            PackErrorKind::Malformed,
                            where_,
                            format!("sense '{sid}' declared twice"),
                        ));
                    }
                    let synset = sense.get("synset").and_then(Json::as_str).unwrap_or("");
                    if synset.is_empty() {
                        return Err(PackError::at_source(
                            PackErrorKind::Malformed,
                            where_,
                            format!("'{sid}': a sense without a synset"),
                        ));
                    }
                    sense_synset.insert(sid.to_string(), synset.to_string());
                    for target in targets_of(sense, "derivation", sid, &where_)? {
                        links.push((sid.to_string(), target, where_.clone()));
                    }
                    for target in targets_of(sense, "antonym", sid, &where_)? {
                        antonyms.push((sid.to_string(), target, where_.clone()));
                    }
                }
            }
        }
    }
    for (sid, synset) in &sense_synset {
        if !synsets.contains_key(synset) {
            return Err(PackError::at_source(
                PackErrorKind::Malformed,
                source,
                format!("sense '{sid}' names undeclared synset '{synset}'"),
            ));
        }
    }
    for (sid, (pos, members)) in &synsets {
        for word in members {
            for other in members {
                if word != other {
                    emit(RawRecord::new(
                        "sense",
                        vec![
                            ("word", RawRecord::text(word.clone())),
                            ("other", RawRecord::text(other.clone())),
                            ("relation", RawRecord::text("synonym")),
                            ("synset", RawRecord::text(sid.clone())),
                            ("pos", RawRecord::text(pos.clone())),
                            ("source", RawRecord::text(source)),
                        ],
                    ))?;
                }
            }
        }
    }
    for (sid, target, where_) in &antonyms {
        let Some(there) = senses.get(target) else {
            return Err(PackError::at_source(
                PackErrorKind::Malformed,
                where_.clone(),
                format!("antonym to undeclared sense '{target}'"),
            ));
        };
        let Some(here) = senses.get(sid) else {
            return Err(PackError::at_source(
                PackErrorKind::Malformed,
                where_.clone(),
                format!("antonym to undeclared sense '{target}'"),
            ));
        };
        if here == there {
            continue;
        }
        for mine in [sid, target] {
            let theirs = if mine == sid { target } else { sid };
            let (Some(own), Some(other)) = (senses.get(mine), senses.get(theirs)) else { continue };
            let own_synset = sense_synset.get(mine).cloned().unwrap_or_default();
            emit(RawRecord::new(
                "sense",
                vec![
                    ("word", RawRecord::text(own.0.clone())),
                    ("other", RawRecord::text(other.0.clone())),
                    ("relation", RawRecord::text("antonym")),
                    ("synset", RawRecord::text(own_synset)),
                    ("pos", RawRecord::text(own.1.clone())),
                    ("source", RawRecord::text(source)),
                ],
            ))?;
        }
    }
    for (sid, target, where_) in &links {
        let Some(here) = senses.get(sid) else { continue };
        let Some(there) = senses.get(target) else {
            return Err(PackError::at_source(
                PackErrorKind::Malformed,
                where_.clone(),
                format!("derivation to undeclared sense '{target}'"),
            ));
        };
        if here == there {
            continue;
        }
        let (low, high) =
            if (nfc(&here.0), &here.1) <= (nfc(&there.0), &there.1) { (here, there) } else { (there, here) };
        let kind = if nfc(&low.0) == nfc(&high.0) { "conversion" } else { "other" };
        emit(RawRecord::new(
            "derivation",
            vec![
                ("base", RawRecord::text(low.0.clone())),
                ("basePos", RawRecord::text(low.1.clone())),
                ("derived", RawRecord::text(high.0.clone())),
                ("derivedPos", RawRecord::text(high.1.clone())),
                ("kind", RawRecord::text(kind)),
                ("source", RawRecord::text(source)),
            ],
        ))?;
    }
    Ok(())
}

fn list_field<'a>(entry: &'a Json, key: &str, lemma: &str, code: &str, where_: &str) -> PackResult<Vec<&'a Json>> {
    match entry.get(key) {
        None | Some(Json::Null) => Ok(Vec::new()),
        Some(Json::Array(items)) => Ok(items.iter().collect()),
        Some(_) => Err(PackError::at_source(
            PackErrorKind::Malformed,
            where_.to_string(),
            format!("'{lemma}'/{code}: {key} is not a list"),
        )),
    }
}

fn targets_of(sense: &Json, key: &str, sid: &str, where_: &str) -> PackResult<Vec<String>> {
    match sense.get(key) {
        None | Some(Json::Null) => Ok(Vec::new()),
        Some(Json::Array(items)) => {
            let mut out = Vec::with_capacity(items.len());
            for item in items {
                let Some(text) = item.as_str() else {
                    return Err(PackError::at_source(
                        PackErrorKind::Malformed,
                        where_.to_string(),
                        format!("'{sid}': a {key} target is not a string"),
                    ));
                };
                out.push(text.to_string());
            }
            Ok(out)
        }
        Some(_) => Err(PackError::at_source(
            PackErrorKind::Malformed,
            where_.to_string(),
            format!("'{sid}': {key} is not a list"),
        )),
    }
}

fn emit_pronunciations(
    entry: &Json,
    lemma: &str,
    pos: &str,
    source: &str,
    where_: &str,
    emit: Emit<'_>,
) -> PackResult<()> {
    let prons = list_field(entry, "pronunciation", lemma, "", where_)?;
    for pron in prons {
        let value = pron.get("value").and_then(Json::as_str).unwrap_or("");
        if value.trim().is_empty() {
            return Err(PackError::at_source(
                PackErrorKind::Malformed,
                where_.to_string(),
                format!("'{lemma}': pronunciation without a value"),
            ));
        }
        let mut fields = vec![
            ("word", RawRecord::text(lemma)),
            ("pos", RawRecord::text(pos)),
            ("system", RawRecord::text("ipa")),
            ("phonemes", RawRecord::list([value.trim()])),
            ("source", RawRecord::text(source)),
        ];
        if let Some(variety) = pron.get("variety").and_then(Json::as_str).filter(|text| !text.trim().is_empty()) {
            fields.push(("dialect", RawRecord::text(variety.trim())));
        }
        emit(RawRecord::new("pronunciation", fields))?;
    }
    Ok(())
}

/// One synset file's members and part of speech, by synset id: `noun.act.json` gives `{id: (noun, [lemmas])}`.
fn read_synsets(
    doc: &Json,
    source: &str,
    name: &str,
    into: &mut BTreeMap<String, (String, Vec<String>)>,
) -> PackResult<()> {
    let where_ = with_place(source, name);
    let Some(synsets) = doc.as_object() else {
        return Err(PackError::at_source(PackErrorKind::Malformed, where_, "not an object"));
    };
    for (sid, synset) in synsets {
        if sid.is_empty() {
            return Err(PackError::at_source(PackErrorKind::Malformed, where_, "a synset id that is not a string"));
        }
        if into.contains_key(sid) {
            return Err(PackError::at_source(
                PackErrorKind::Malformed,
                where_,
                format!("synset '{sid}' declared twice"),
            ));
        }
        if synset.as_object().is_none() {
            return Err(PackError::at_source(
                PackErrorKind::Malformed,
                where_,
                format!("synset '{sid}' is not an object"),
            ));
        }
        let code = synset.get("partOfSpeech").and_then(Json::as_str).unwrap_or("");
        let Some(pos) = lookup(&OEWN_POS, code) else {
            return Err(PackError::at_source(
                PackErrorKind::Malformed,
                where_,
                format!("synset '{sid}': unknown part of speech '{code}'"),
            ));
        };
        let members = match synset.get("members") {
            Some(Json::Array(listed)) => listed,
            _ => {
                return Err(PackError::at_source(
                    PackErrorKind::Malformed,
                    where_,
                    format!("synset '{sid}' has no members"),
                ));
            }
        };
        if members.is_empty() {
            return Err(PackError::at_source(
                PackErrorKind::Malformed,
                where_,
                format!("synset '{sid}' has no members"),
            ));
        }
        let mut words = Vec::with_capacity(members.len());
        for member in members {
            let Some(text) = member.as_str().filter(|text| !text.trim().is_empty()) else {
                return Err(PackError::at_source(
                    PackErrorKind::Malformed,
                    where_,
                    format!("synset '{sid}': a member that is not a word"),
                ));
            };
            words.push(text.to_string());
        }
        into.insert(sid.clone(), (pos.to_string(), words));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::indexing_slicing)]

    use super::*;
    use crate::record::validate_record;
    use serde_json::json;

    fn parse(docs: Vec<Document>) -> PackResult<Vec<RawRecord>> {
        let mut out = Vec::new();
        {
            let mut emit = |record: RawRecord| {
                out.push(record);
                Ok(())
            };
            parse_oewn_entries(&docs, "oewn", &mut emit)?;
        }
        Ok(out)
    }

    /// The lines the pack would hold: the parser's records, de-duplicated as `PackBuilder` de-duplicates them.
    fn lines(records: &[RawRecord]) -> Vec<String> {
        let mut out: Vec<String> = records.iter().map(|record| validate_record(record).unwrap().line()).collect();
        out.sort();
        out.dedup();
        out
    }

    fn documents() -> Vec<Document> {
        vec![
            (
                "entries-a.json".to_string(),
                json!({
                    "able": {
                        "a": {
                            "pronunciation": [{"value": "ˈeɪ.bəl"}],
                            "sense": [{"id": "able__a__1", "synset": "able.a.01", "antonym": ["unable__a__1"]}]
                        }
                    },
                    "ably": {"r": {"sense": [{"id": "ably__r__1", "synset": "ably.r.01", "derivation": ["able__a__1"]}]}}
                }),
            ),
            (
                "adj.all.json".to_string(),
                json!({"able.a.01": {"partOfSpeech": "a", "members": ["able"]},
                       "unable.a.01": {"partOfSpeech": "a", "members": ["unable", "not able"]}}),
            ),
            ("adv.all.json".to_string(), json!({"ably.r.01": {"partOfSpeech": "r", "members": ["ably"]}})),
            (
                "entries-u.json".to_string(),
                json!({"unable": {"a": {"sense": [{"id": "unable__a__1", "synset": "unable.a.01", "antonym": ["able__a__1"]}]}}}),
            ),
        ]
    }

    #[test]
    fn a_synset_writes_every_pair_both_ways() {
        let rendered = lines(&parse(documents()).unwrap());
        let synonyms = rendered.iter().filter(|line| line.contains("synonym")).count();
        // "unable" and "not able" are one ordered pair each way; the two singletons add nothing.
        assert_eq!(synonyms, 2);
        let antonyms = rendered.iter().filter(|line| line.contains("antonym")).count();
        assert_eq!(antonyms, 2);
        let derivations = rendered.iter().filter(|line| line.contains("\"type\":\"derivation\"")).count();
        assert_eq!(derivations, 1);
    }

    #[test]
    fn an_antonym_names_each_sides_own_synset() {
        let rendered = lines(&parse(documents()).unwrap());
        let good = rendered.iter().find(|line| line.contains("antonym") && line.contains("\"word\":\"able\"")).unwrap();
        assert!(good.contains("\"synset\":\"able.a.01\""), "{good}");
    }

    #[test]
    fn a_sense_naming_an_undeclared_synset_is_refused() {
        let mut docs = documents();
        docs[1] = ("adj.all.json".to_string(), json!({}));
        assert!(parse(docs).unwrap_err().to_string().contains("names undeclared synset"));
    }

    #[test]
    fn an_unknown_entry_key_is_refused() {
        let mut docs = documents();
        docs[0] = ("entries-a.json".to_string(), json!({"able": {"x": {}}}));
        assert!(parse(docs).unwrap_err().to_string().contains("unknown part of speech"));
    }

    #[test]
    fn an_undeclared_sense_is_refused() {
        let docs = vec![
            (
                "entries-a.json".to_string(),
                json!({"ably": {"r": {"sense": [{"id": "ably__r__1", "synset": "ably.r.01", "derivation": ["gone__a__1"]}]}}}),
            ),
            ("adv.all.json".to_string(), json!({"ably.r.01": {"partOfSpeech": "r", "members": ["ably"]}})),
        ];
        assert!(parse(docs).unwrap_err().to_string().contains("derivation to undeclared sense"));
    }

    #[test]
    fn a_sense_declared_twice_is_refused() {
        let docs = vec![
            (
                "entries-a.json".to_string(),
                json!({"able": {"a": {"sense": [{"id": "s1", "synset": "able.a.01"}]},
                                "v": {"sense": [{"id": "s1", "synset": "able.a.01"}]}}}),
            ),
            ("adj.all.json".to_string(), json!({"able.a.01": {"partOfSpeech": "a", "members": ["able"]}})),
        ];
        assert!(parse(docs).unwrap_err().to_string().contains("declared twice"));
    }

    #[test]
    fn an_antonym_to_an_undeclared_sense_is_refused() {
        let docs = vec![
            (
                "entries-a.json".to_string(),
                json!({"able": {"a": {"sense": [{"id": "s1", "synset": "able.a.01", "antonym": ["gone"]}]}}}),
            ),
            ("adj.all.json".to_string(), json!({"able.a.01": {"partOfSpeech": "a", "members": ["able"]}})),
        ];
        assert!(parse(docs).unwrap_err().to_string().contains("antonym to undeclared sense"));
    }

    #[test]
    fn a_synset_declared_twice_is_refused() {
        let docs = vec![
            ("adj.all.json".to_string(), json!({"able.a.01": {"partOfSpeech": "a", "members": ["able"]}})),
            ("adj.pert.json".to_string(), json!({"able.a.01": {"partOfSpeech": "a", "members": ["able"]}})),
            ("entries-a.json".to_string(), json!({})),
        ];
        assert!(parse(docs).unwrap_err().to_string().contains("declared twice"));
    }

    #[test]
    fn a_numbered_entry_key_is_read_in_full() {
        let docs = vec![
            (
                "entries-a.json".to_string(),
                json!({"able": {"n-1": {"pronunciation": [{"value": "a"}]}, "n-2": {"pronunciation": [{"value": "b"}]}}}),
            ),
            ("adj.all.json".to_string(), json!({"unused.a.01": {"partOfSpeech": "a", "members": ["unused"]}})),
        ];
        assert_eq!(parse(docs).unwrap().len(), 2);
    }
}
