//! The lexical pack: versioned JSONL, one header line and then one typed record per line, linguistic metadata only
//! (words, forms, parts of speech, phonemes, relations, origins, ids; never definitions, examples or dictionary
//! files). Each line is the serde form of [`LexiconHeader`] or [`LexiconRecord`], camel-case, `type`-tagged, so a pack
//! and the plain records of [`WordLexicon::from_records`] are one schema. The loader reads it under explicit bounds
//! ([`LexiconLimits`]) and answers damage with [`WordError::Corrupt`] and the line, never a partial lexicon.
//!
//! The loader parses lines as plain JSON values and reads every field itself, so it needs no `serde` feature, and
//! a field this schema does not name (a `definition`, a `gloss`) is damage, not something passed over.

use std::collections::{HashMap, HashSet};
use std::io::{BufRead, ErrorKind};
use std::panic::{AssertUnwindSafe, catch_unwind};

use serde_json::{Map, Value};

use super::phones;
use super::types::{EtymonRelation, FamilyKind, LexiconSource, PhoneSystem, WordError, WordLimit, record};

/// The `schema` a pack's header names.
pub const WORD_PACK_SCHEMA: &str = "xdict-word-pack";
/// The pack version this loader reads; another is [`WordError::UnsupportedVersion`]. **2 adds `sense`** — the
/// word net's synset relations the synonym and antonym modes read — and a 1 pack is refused naming both versions
/// rather than read without them.
pub const WORD_PACK_VERSION: u32 = 2;

/// A pack's first line, with `"type": "header"`.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(rename_all = "camelCase"))]
pub struct LexiconHeader {
    /// [`WORD_PACK_SCHEMA`].
    pub schema: String,
    /// [`WORD_PACK_VERSION`].
    pub version: u32,
    /// BCP 47 language of the modern words (`en`).
    pub language: String,
    /// Every source a record may name; at least one, ids unique, `url` `https://` only.
    pub sources: Vec<LexiconSource>,
}

/// **The header serializes with the tag the loader requires** (`"type": "header"`); the derive cannot add a constant
/// field to a struct, and without it a serialized header could not be loaded back (audit, 2026-10-24).
#[cfg(feature = "serde")]
impl serde::Serialize for LexiconHeader {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeStruct;
        let mut state = serializer.serialize_struct("LexiconHeader", 5)?;
        state.serialize_field("type", "header")?;
        state.serialize_field("schema", &self.schema)?;
        state.serialize_field("version", &self.version)?;
        state.serialize_field("language", &self.language)?;
        state.serialize_field("sources", &self.sources)?;
        state.end()
    }
}

record! {

    /// A pronunciation of `word`, as the source gives it.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct PronunciationRecord {
        pub word: String,
        /// Only where the source ties this pronunciation to a part of speech.
        pub pos: Option<String>,
        pub system: PhoneSystem,
        /// ARPAbet: one token per item, CMUdict's 39 phonemes, every vowel with a stress digit 0, 1 or 2, no space.
        /// IPA: as the source writes it, often one item holding the whole transcription, spaces between a phrase's
        /// words kept (`ˈaɪs ˌkɹiːm`); never split or guessed.
        pub phonemes: Vec<String>,
        pub dialect: Option<String>,
        pub source: String,
    }

    /// `form` is an inflection of `lemma` as `pos`. The lemma itself needs no record: it is in every paradigm a form
    /// record names it in.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct FormRecord {
        pub form: String,
        pub lemma: String,
        pub pos: String,
        /// The source's grammatical tags (`past`, `plural`); at least one.
        pub tags: Vec<String>,
        pub source: String,
    }

    /// An edge of the modern derivational family, never an etymology. Where the kind carries a direction (an affix
    /// or compound) or the source states one, `derived` is productively derived from `base`. For
    /// [`FamilyKind::Other`], and for a [`FamilyKind::Conversion`] from an unoriented source, the source states only
    /// that the two are related, with no direction (OEWN's links are undirected; the builder stores `Other` pairs
    /// sorted and conversions in an arbitrary part-of-speech order, `adj` < `adv` < `noun` < `verb`): `base` and
    /// `derived` are then the two stored endpoints, and neither is claimed to come from the other, historically or
    /// productively.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct DerivationRecord {
        /// The source's base; for an unoriented edge, merely the first stored endpoint.
        pub base: String,
        pub base_pos: Option<String>,
        /// The source's derived word; for an unoriented edge, merely the second stored endpoint.
        pub derived: String,
        pub derived_pos: Option<String>,
        pub kind: FamilyKind,
        pub affix: Option<String>,
        /// Only where an external stem alignment is supplied: what stem stress is classified from. The current pack
        /// builder writes none, so its edges classify as unknown stress until a source supplies one.
        pub stem: Option<StemAlignment>,
        pub source: String,
    }

    /// Which vowels of each pronunciation belong to the shared stem: half-open ranges of vowel indices (0-based, in
    /// vowel order), the same length on both sides. The pronunciations are named in full so the alignment never
    /// depends on which of a word's variants is meant.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct StemAlignment {
        pub base_phonemes: Vec<String>,
        pub base_start: u32,
        pub base_end: u32,
        pub derived_phonemes: Vec<String>,
        pub derived_start: u32,
        pub derived_end: u32,
    }

    /// A node of the etymology graph. `word` is set when the node is a modern word's own etymology: one node per
    /// etymology, so homographs (`bank` the shore, `bank` the money) are two nodes with one `word`.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct OriginRecord {
        pub id: String,
        pub language: String,
        pub form: String,
        pub word: Option<String>,
    }

    /// `child` comes from `parent` (node ids; an id no origin record declares is an unknown node, not damage).
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct EtymonRecord {
        pub child: String,
        pub parent: String,
        pub relation: EtymonRelation,
        #[cfg_attr(feature = "serde", serde(default))]
        pub uncertain: bool,
        pub source: String,
    }

    /// **Two words a word net ties through one synset** (schema 2): the relation the synonym and antonym modes read.
    /// Both words are spelled as the pack spells them; the synset is the source's own id, kept so two relations can be
    /// told apart when a word has several senses.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct SenseRecord {
        pub word: String,
        pub other: String,
        pub relation: SenseRelation,
        /// The source's synset id.
        pub synset: String,
        /// The part of speech the source ties the synset to, when it says.
        pub pos: Option<String>,
        pub source: String,
    }

    /// **How two words are related in a synset**: OEWN's own four, and no others.
    #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
    pub enum SenseRelation {
        Synonym,
        Antonym,
        Hypernym,
        Hyponym,
    }

    /// The loader's bounds. Past any of them the load fails with [`WordError::TooLarge`], never truncates. Build one
    /// with `..LexiconLimits::default()` so a bound added later keeps its default.
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub struct LexiconLimits {
        /// Per line, its `\n` not counted; enforced while reading, before the line is held.
        pub max_line_bytes: u64,
        /// Records after the header.
        pub max_records: u64,
        /// Per string field, header and records alike, in Unicode scalar values.
        pub max_string_chars: u64,
        /// Per list field (the header's sources included).
        pub max_list_items: u64,
        /// The whole pack: its bytes, newlines included, when read from JSONL; the bytes of its strings when given as
        /// plain records.
        pub max_total_bytes: u64,
    }
}

impl Default for LexiconLimits {
    /// 64 KiB a line, 4 M records, 256 scalars a string, 64 items a list, 512 MiB in all.
    fn default() -> Self {
        Self {
            max_line_bytes: 64 * 1024,
            max_records: 4_000_000,
            max_string_chars: 256,
            max_list_items: 64,
            max_total_bytes: 512 * 1024 * 1024,
        }
    }
}

/// One line after the header: the record's fields beside its `type` (`pronunciation`, `form`, `derivation`, `origin`,
/// `etymon`).
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(rename_all = "camelCase", tag = "type"))]
pub enum LexiconRecord {
    Pronunciation(PronunciationRecord),
    Form(FormRecord),
    Derivation(DerivationRecord),
    Origin(OriginRecord),
    Etymon(EtymonRecord),
    Sense(SenseRecord),
}

/// A loaded, validated, immutable lexical pack.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WordLexicon {
    header: LexiconHeader,
    records: Vec<LexiconRecord>,
}

impl WordLexicon {
    /// Reads a JSONL pack under the default [`LexiconLimits`].
    pub fn from_jsonl(reader: impl BufRead) -> Result<Self, WordError> {
        Self::from_jsonl_with_limits(reader, LexiconLimits::default())
    }

    /// Reads a JSONL pack under `limits`. Every line is `\n`-terminated, the last included: a pack cut off mid-line
    /// is refused as truncated.
    pub fn from_jsonl_with_limits(reader: impl BufRead, limits: LexiconLimits) -> Result<Self, WordError> {
        let mut reader = reader;
        guarded(move || load_jsonl(&mut reader, limits))
    }

    /// Takes plain records, validated exactly as a pack's lines are (a record's line is its index plus 2), under the
    /// default [`LexiconLimits`].
    pub fn from_records(header: LexiconHeader, records: Vec<LexiconRecord>) -> Result<Self, WordError> {
        Self::from_records_with_limits(header, records, LexiconLimits::default())
    }

    /// Takes plain records under `limits`. They are already in memory, so `max_line_bytes` has nothing to bound;
    /// `max_total_bytes` bounds the bytes of their strings.
    pub fn from_records_with_limits(
        header: LexiconHeader,
        records: Vec<LexiconRecord>,
        limits: LexiconLimits,
    ) -> Result<Self, WordError> {
        guarded(move || load_records(header, records, limits))
    }

    pub fn header(&self) -> &LexiconHeader {
        &self.header
    }

    pub fn records(&self) -> &[LexiconRecord] {
        &self.records
    }
}

// ---- loading ----------------------------------------------------------------------------------------------------

/// Runs `work`, a panic in it answered as [`WordError::Internal`]: nothing half-built escapes, since the unwound
/// state is dropped with the closure.
fn guarded<T>(work: impl FnOnce() -> Result<T, WordError>) -> Result<T, WordError> {
    catch_unwind(AssertUnwindSafe(work))
        .unwrap_or_else(|_| Err(WordError::Internal { detail: "the lexicon loader panicked".into() }))
}

fn load_jsonl(reader: &mut impl BufRead, limits: LexiconLimits) -> Result<WordLexicon, WordError> {
    let mut lines = Lines { buf: Vec::new(), total: 0, limits };
    if !lines.read(reader, 1)? {
        return Err(corrupt("the pack is empty: no header line").at(1));
    }
    let mut checker = Checker::new(&limits);
    let header = parse(&lines.buf).and_then(header_from).map_err(|f| f.at(1))?;
    checker.header(&header).map_err(|f| f.at(1))?;

    let mut records = Vec::new();
    let mut line: u64 = 1;
    loop {
        line = line.saturating_add(1);
        if !lines.read(reader, line)? {
            break;
        }
        if len64(records.len()) >= limits.max_records {
            let detail = format!("more than {} records", limits.max_records);
            return Err(Fault::TooLarge(WordLimit::Records, detail).at(line));
        }
        let record = parse(&lines.buf).and_then(record_from).map_err(|f| f.at(line))?;
        checker.record(&record).map_err(|f| f.at(line))?;
        records.push(record);
    }
    check_origin_ids(&records)?;
    Ok(WordLexicon { header, records })
}

fn load_records(
    header: LexiconHeader,
    records: Vec<LexiconRecord>,
    limits: LexiconLimits,
) -> Result<WordLexicon, WordError> {
    if len64(records.len()) > limits.max_records {
        let detail = format!("{} records, more than {}", records.len(), limits.max_records);
        return Err(Fault::TooLarge(WordLimit::Records, detail).at(0));
    }
    let mut checker = Checker::new(&limits);
    checker.header(&header).map_err(|f| f.at(1))?;
    // **The header counts too**, so a pack of zero records still answers to the string budget (audit, 2026-10-24).
    if checker.bytes > limits.max_total_bytes {
        let detail = format!("more than {} bytes of strings", limits.max_total_bytes);
        return Err(Fault::TooLarge(WordLimit::TotalBytes, detail).at(1));
    }
    for (index, record) in records.iter().enumerate() {
        let line = record_line(index);
        checker.record(record).map_err(|f| f.at(line))?;
        if checker.bytes > limits.max_total_bytes {
            let detail = format!("more than {} bytes of strings", limits.max_total_bytes);
            return Err(Fault::TooLarge(WordLimit::TotalBytes, detail).at(line));
        }
    }
    check_origin_ids(&records)?;
    Ok(WordLexicon { header, records })
}

/// Origin ids name graph nodes, so each is declared once; edges may still name undeclared ones.
fn check_origin_ids(records: &[LexiconRecord]) -> Result<(), WordError> {
    // **One id, one declaration**: two identical origin records are one declaration, kept once by the explorer; the
    // same id with different content is damage (audit, 2026-10-24).
    let mut seen: HashMap<&str, &OriginRecord> = HashMap::new();
    for (index, record) in records.iter().enumerate() {
        let LexiconRecord::Origin(origin) = record else { continue };
        match seen.get(origin.id.as_str()) {
            Some(previous) if *previous != origin => {
                return Err(
                    corrupt(format!("origin id {:?} is declared differently twice", origin.id)).at(record_line(index))
                );
            }
            Some(_) => {}
            None => {
                seen.insert(origin.id.as_str(), origin);
            }
        }
    }
    Ok(())
}

fn record_line(index: usize) -> u64 {
    len64(index).saturating_add(2)
}

fn len64(n: usize) -> u64 {
    u64::try_from(n).unwrap_or(u64::MAX)
}

/// The line reader: one reused buffer that never holds more than `max_line_bytes`, and the running total.
struct Lines {
    buf: Vec<u8>,
    total: u64,
    limits: LexiconLimits,
}

impl Lines {
    /// Reads line `line` into `buf`, its `\n` dropped; false at a clean end. Each chunk of the reader's own buffer is
    /// measured before it is copied, so an overlong line fails without being held.
    fn read(&mut self, reader: &mut impl BufRead, line: u64) -> Result<bool, WordError> {
        self.buf.clear();
        loop {
            let available = match reader.fill_buf() {
                Ok(available) => available,
                Err(e) if e.kind() == ErrorKind::Interrupted => continue,
                Err(e) => return Err(WordError::Io { detail: format!("line {line}: {e}") }),
            };
            if available.is_empty() {
                if self.buf.is_empty() {
                    return Ok(false);
                }
                return Err(corrupt("the last line has no newline: the pack is truncated").at(line));
            }
            let newline = available.iter().position(|&b| b == b'\n');
            let take = newline.unwrap_or(available.len());
            let consumed = take.saturating_add(usize::from(newline.is_some()));
            if len64(self.buf.len()).saturating_add(len64(take)) > self.limits.max_line_bytes {
                let detail = format!("a line longer than {} bytes", self.limits.max_line_bytes);
                return Err(Fault::TooLarge(WordLimit::LineBytes, detail).at(line));
            }
            self.total = self.total.saturating_add(len64(consumed));
            if self.total > self.limits.max_total_bytes {
                let detail = format!("a pack larger than {} bytes", self.limits.max_total_bytes);
                return Err(Fault::TooLarge(WordLimit::TotalBytes, detail).at(line));
            }
            self.buf.extend_from_slice(available.get(..take).unwrap_or(&[]));
            reader.consume(consumed);
            if newline.is_some() {
                return Ok(true);
            }
        }
    }
}

// ---- faults -----------------------------------------------------------------------------------------------------

/// What is wrong with one line, before the line is known.
enum Fault {
    Corrupt(String),
    TooLarge(WordLimit, String),
    Version(u32),
}

impl Fault {
    fn at(self, line: u64) -> WordError {
        match self {
            Fault::Corrupt(detail) => WordError::Corrupt { line, detail },
            Fault::TooLarge(limit, detail) => WordError::TooLarge { limit, detail: format!("line {line}: {detail}") },
            Fault::Version(found) => WordError::UnsupportedVersion {
                found,
                supported: WORD_PACK_VERSION,
                detail: format!("line {line}: pack version {found}; this loader reads {WORD_PACK_VERSION}"),
            },
        }
    }
}

fn corrupt(detail: impl Into<String>) -> Fault {
    Fault::Corrupt(detail.into())
}

/// A pack's own text, cut short and escaped for a log line.
fn clip(text: &str) -> String {
    let short: String = text.chars().take(64).collect();
    format!("{short:?}")
}

// ---- JSON to records --------------------------------------------------------------------------------------------

type Object = Map<String, Value>;

const HEADER_KEYS: &[&str] = &["type", "schema", "version", "language", "sources"];
const SOURCE_KEYS: &[&str] = &["id", "name", "url", "version", "sha256", "licence", "attribution", "coverage"];
const PRONUNCIATION_KEYS: &[&str] = &["type", "word", "pos", "system", "phonemes", "dialect", "source"];
const FORM_KEYS: &[&str] = &["type", "form", "lemma", "pos", "tags", "source"];
const DERIVATION_KEYS: &[&str] =
    &["type", "base", "basePos", "derived", "derivedPos", "kind", "affix", "stem", "source"];
const STEM_KEYS: &[&str] = &["basePhonemes", "baseStart", "baseEnd", "derivedPhonemes", "derivedStart", "derivedEnd"];
const ORIGIN_KEYS: &[&str] = &["type", "id", "language", "form", "word"];
const ETYMON_KEYS: &[&str] = &["type", "child", "parent", "relation", "uncertain", "source"];
const SENSE_KEYS: &[&str] = &["type", "word", "other", "relation", "synset", "pos", "source"];

const SYSTEMS: &[(&str, PhoneSystem)] = &[("arpabet", PhoneSystem::Arpabet), ("ipa", PhoneSystem::Ipa)];
const KINDS: &[(&str, FamilyKind)] = &[
    ("prefix", FamilyKind::Prefix),
    ("suffix", FamilyKind::Suffix),
    ("conversion", FamilyKind::Conversion),
    ("compound", FamilyKind::Compound),
    ("other", FamilyKind::Other),
];
const SENSE_RELATIONS: &[(&str, SenseRelation)] = &[
    ("synonym", SenseRelation::Synonym),
    ("antonym", SenseRelation::Antonym),
    ("hypernym", SenseRelation::Hypernym),
    ("hyponym", SenseRelation::Hyponym),
];
const RELATIONS: &[(&str, EtymonRelation)] = &[
    ("inherited", EtymonRelation::Inherited),
    ("borrowed", EtymonRelation::Borrowed),
    ("learned", EtymonRelation::Learned),
    ("derived", EtymonRelation::Derived),
    ("calque", EtymonRelation::Calque),
    ("compound", EtymonRelation::Compound),
    ("affix", EtymonRelation::Affix),
    ("root", EtymonRelation::Root),
    ("unknown", EtymonRelation::Unknown),
];

fn parse(bytes: &[u8]) -> Result<Value, Fault> {
    serde_json::from_slice(bytes).map_err(|e| corrupt(format!("not one JSON value in UTF-8: {e}")))
}

/// `value` as an object naming no key outside `allowed`.
fn object(value: Value, what: &str, allowed: &[&str]) -> Result<Object, Fault> {
    let Value::Object(map) = value else {
        return Err(corrupt(format!("{what} is not a JSON object")));
    };
    match map.keys().find(|key| !allowed.contains(&key.as_str())) {
        Some(key) => Err(corrupt(format!("{what}: no field {} in this schema", clip(key)))),
        None => Ok(map),
    }
}

/// The field, `null` and absent alike.
fn take(map: &mut Object, key: &str) -> Option<Value> {
    map.remove(key).filter(|value| !value.is_null())
}

fn optional_string(map: &mut Object, key: &str) -> Result<Option<String>, Fault> {
    match take(map, key) {
        None => Ok(None),
        Some(Value::String(text)) => Ok(Some(text)),
        Some(_) => Err(corrupt(format!("`{key}` is not a string"))),
    }
}

fn string(map: &mut Object, key: &str) -> Result<String, Fault> {
    optional_string(map, key)?.ok_or_else(|| corrupt(format!("`{key}` is missing")))
}

fn strings(map: &mut Object, key: &str) -> Result<Vec<String>, Fault> {
    let Some(Value::Array(items)) = take(map, key) else {
        return Err(corrupt(format!("`{key}` is not a list")));
    };
    items
        .into_iter()
        .map(|item| match item {
            Value::String(text) => Ok(text),
            _ => Err(corrupt(format!("`{key}` holds something not a string"))),
        })
        .collect()
}

fn number(map: &mut Object, key: &str) -> Result<u32, Fault> {
    take(map, key)
        .as_ref()
        .and_then(Value::as_u64)
        .and_then(|n| u32::try_from(n).ok())
        .ok_or_else(|| corrupt(format!("`{key}` is not a whole number from 0 to {}", u32::MAX)))
}

fn flag(map: &mut Object, key: &str) -> Result<bool, Fault> {
    match take(map, key) {
        None => Ok(false),
        Some(Value::Bool(flag)) => Ok(flag),
        Some(_) => Err(corrupt(format!("`{key}` is not true or false"))),
    }
}

fn choice<T: Copy>(map: &mut Object, key: &str, options: &[(&str, T)]) -> Result<T, Fault> {
    let text = string(map, key)?;
    options.iter().find(|(name, _)| *name == text).map(|&(_, value)| value).ok_or_else(|| {
        let names: Vec<&str> = options.iter().map(|(name, _)| *name).collect();
        corrupt(format!("`{key}` {} is not one of {}", clip(&text), names.join(", ")))
    })
}

/// The header's shape. Schema and version are read first, so a later version's header is
/// [`WordError::UnsupportedVersion`] whatever fields it adds.
fn header_from(value: Value) -> Result<LexiconHeader, Fault> {
    let Value::Object(mut map) = value else {
        return Err(corrupt("the first line is not the pack's header"));
    };
    match take(&mut map, "type") {
        Some(Value::String(kind)) if kind == "header" => {}
        _ => return Err(corrupt("the first line is not the pack's header")),
    }
    let schema = string(&mut map, "schema")?;
    if schema != WORD_PACK_SCHEMA {
        return Err(corrupt(format!("schema {}, not {WORD_PACK_SCHEMA:?}", clip(&schema))));
    }
    let version = number(&mut map, "version")?;
    if version != WORD_PACK_VERSION {
        return Err(Fault::Version(version));
    }
    let mut map = object(Value::Object(map), "the header", HEADER_KEYS)?;
    let language = string(&mut map, "language")?;
    let Some(Value::Array(items)) = take(&mut map, "sources") else {
        return Err(corrupt("`sources` is not a list"));
    };
    let sources = items.into_iter().map(source_from).collect::<Result<_, _>>()?;
    Ok(LexiconHeader { schema, version, language, sources })
}

fn source_from(value: Value) -> Result<LexiconSource, Fault> {
    let mut map = object(value, "a source", SOURCE_KEYS)?;
    Ok(LexiconSource {
        id: string(&mut map, "id")?,
        name: string(&mut map, "name")?,
        url: string(&mut map, "url")?,
        version: string(&mut map, "version")?,
        sha256: string(&mut map, "sha256")?,
        licence: string(&mut map, "licence")?,
        attribution: string(&mut map, "attribution")?,
        coverage: optional_string(&mut map, "coverage")?,
    })
}

fn record_from(value: Value) -> Result<LexiconRecord, Fault> {
    let Value::Object(mut map) = value else {
        return Err(corrupt("a record is not a JSON object"));
    };
    let kind = string(&mut map, "type")?;
    let map = Value::Object(map);
    Ok(match kind.as_str() {
        "pronunciation" => {
            let mut map = object(map, "a pronunciation", PRONUNCIATION_KEYS)?;
            LexiconRecord::Pronunciation(PronunciationRecord {
                word: string(&mut map, "word")?,
                pos: optional_string(&mut map, "pos")?,
                system: choice(&mut map, "system", SYSTEMS)?,
                phonemes: strings(&mut map, "phonemes")?,
                dialect: optional_string(&mut map, "dialect")?,
                source: string(&mut map, "source")?,
            })
        }
        "form" => {
            let mut map = object(map, "a form", FORM_KEYS)?;
            LexiconRecord::Form(FormRecord {
                form: string(&mut map, "form")?,
                lemma: string(&mut map, "lemma")?,
                pos: string(&mut map, "pos")?,
                tags: strings(&mut map, "tags")?,
                source: string(&mut map, "source")?,
            })
        }
        "derivation" => {
            let mut map = object(map, "a derivation", DERIVATION_KEYS)?;
            LexiconRecord::Derivation(DerivationRecord {
                base: string(&mut map, "base")?,
                base_pos: optional_string(&mut map, "basePos")?,
                derived: string(&mut map, "derived")?,
                derived_pos: optional_string(&mut map, "derivedPos")?,
                kind: choice(&mut map, "kind", KINDS)?,
                affix: optional_string(&mut map, "affix")?,
                stem: take(&mut map, "stem").map(stem_from).transpose()?,
                source: string(&mut map, "source")?,
            })
        }
        "origin" => {
            let mut map = object(map, "an origin", ORIGIN_KEYS)?;
            LexiconRecord::Origin(OriginRecord {
                id: string(&mut map, "id")?,
                language: string(&mut map, "language")?,
                form: string(&mut map, "form")?,
                word: optional_string(&mut map, "word")?,
            })
        }
        "etymon" => {
            let mut map = object(map, "an etymon", ETYMON_KEYS)?;
            LexiconRecord::Etymon(EtymonRecord {
                child: string(&mut map, "child")?,
                parent: string(&mut map, "parent")?,
                relation: choice(&mut map, "relation", RELATIONS)?,
                uncertain: flag(&mut map, "uncertain")?,
                source: string(&mut map, "source")?,
            })
        }
        "sense" => {
            let mut map = object(map, "a sense relation", SENSE_KEYS)?;
            LexiconRecord::Sense(SenseRecord {
                word: string(&mut map, "word")?,
                other: string(&mut map, "other")?,
                relation: choice(&mut map, "relation", SENSE_RELATIONS)?,
                synset: string(&mut map, "synset")?,
                pos: optional_string(&mut map, "pos")?,
                source: string(&mut map, "source")?,
            })
        }
        "header" => return Err(corrupt("a second header")),
        other => return Err(corrupt(format!("no record type {} in this schema", clip(other)))),
    })
}

fn stem_from(value: Value) -> Result<StemAlignment, Fault> {
    let mut map = object(value, "a stem alignment", STEM_KEYS)?;
    Ok(StemAlignment {
        base_phonemes: strings(&mut map, "basePhonemes")?,
        base_start: number(&mut map, "baseStart")?,
        base_end: number(&mut map, "baseEnd")?,
        derived_phonemes: strings(&mut map, "derivedPhonemes")?,
        derived_start: number(&mut map, "derivedStart")?,
        derived_end: number(&mut map, "derivedEnd")?,
    })
}

// ---- validation -------------------------------------------------------------------------------------------------

/// What every header and record must hold, the same for a pack's lines and for plain records. Counts the bytes of
/// the strings it passes, for [`LexiconLimits::max_total_bytes`] over plain records.
struct Checker<'l> {
    limits: &'l LexiconLimits,
    sources: HashSet<String>,
    bytes: u64,
}

impl<'l> Checker<'l> {
    fn new(limits: &'l LexiconLimits) -> Self {
        Self { limits, sources: HashSet::new(), bytes: 0 }
    }

    fn header(&mut self, header: &LexiconHeader) -> Result<(), Fault> {
        if header.schema != WORD_PACK_SCHEMA {
            return Err(corrupt(format!("schema {}, not {WORD_PACK_SCHEMA:?}", clip(&header.schema))));
        }
        if header.version != WORD_PACK_VERSION {
            return Err(Fault::Version(header.version));
        }
        self.text("schema", &header.schema)?;
        self.text("language", &header.language)?;
        if !bcp47(&header.language) {
            return Err(corrupt(format!("language {} is not a BCP 47 tag", clip(&header.language))));
        }
        self.list("sources", header.sources.len())?;
        for source in &header.sources {
            self.source_entry(source)?;
            if !self.sources.insert(source.id.clone()) {
                return Err(corrupt(format!("source id {} is named twice", clip(&source.id))));
            }
        }
        Ok(())
    }

    /// One source's credits: short, complete, its download pinned by hash and reached over HTTPS.
    fn source_entry(&mut self, source: &LexiconSource) -> Result<(), Fault> {
        self.text("id", &source.id)?;
        if !source.id.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | ':')) {
            return Err(corrupt(format!("source id {} is not letters, digits and - _ . :", clip(&source.id))));
        }
        self.text("name", &source.name)?;
        self.text("url", &source.url)?;
        if https_host(&source.url).is_none() {
            return Err(corrupt(format!("source url {} is not an https:// address with a host", clip(&source.url))));
        }
        self.text("version", &source.version)?;
        self.text("sha256", &source.sha256)?;
        if source.sha256.len() != 64 || !source.sha256.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f')) {
            return Err(corrupt(format!("sha256 {} is not 64 lowercase hex digits", clip(&source.sha256))));
        }
        self.text("licence", &source.licence)?;
        self.text("attribution", &source.attribution)?;
        self.optional_text("coverage", source.coverage.as_deref())
    }

    fn record(&mut self, record: &LexiconRecord) -> Result<(), Fault> {
        match record {
            LexiconRecord::Pronunciation(p) => {
                self.text("word", &p.word)?;
                self.optional_text("pos", p.pos.as_deref())?;
                self.phonemes("phonemes", p.system, &p.phonemes)?;
                self.optional_text("dialect", p.dialect.as_deref())?;
                self.source(&p.source)
            }
            LexiconRecord::Form(f) => {
                self.text("form", &f.form)?;
                self.text("lemma", &f.lemma)?;
                self.text("pos", &f.pos)?;
                self.list("tags", f.tags.len())?;
                for tag in &f.tags {
                    self.text("tags", tag)?;
                }
                self.source(&f.source)
            }
            LexiconRecord::Derivation(d) => {
                self.text("base", &d.base)?;
                self.optional_text("basePos", d.base_pos.as_deref())?;
                self.text("derived", &d.derived)?;
                self.optional_text("derivedPos", d.derived_pos.as_deref())?;
                self.optional_text("affix", d.affix.as_deref())?;
                if let Some(stem) = &d.stem {
                    self.stem(stem)?;
                }
                self.source(&d.source)
            }
            LexiconRecord::Origin(o) => {
                self.text("id", &o.id)?;
                self.text("language", &o.language)?;
                self.text("form", &o.form)?;
                self.optional_text("word", o.word.as_deref())
            }
            LexiconRecord::Etymon(e) => {
                self.text("child", &e.child)?;
                self.text("parent", &e.parent)?;
                self.source(&e.source)
            }
            LexiconRecord::Sense(s) => {
                self.text("word", &s.word)?;
                self.text("other", &s.other)?;
                self.text("synset", &s.synset)?;
                self.optional_text("pos", s.pos.as_deref())?;
                self.source(&s.source)
            }
        }
    }

    /// Both pronunciations valid ARPAbet; each range non-empty and within its vowels; the two ranges one length.
    fn stem(&mut self, stem: &StemAlignment) -> Result<(), Fault> {
        self.phonemes("basePhonemes", PhoneSystem::Arpabet, &stem.base_phonemes)?;
        self.phonemes("derivedPhonemes", PhoneSystem::Arpabet, &stem.derived_phonemes)?;
        let base = vowel_range("base", stem.base_start, stem.base_end, &stem.base_phonemes)?;
        let derived = vowel_range("derived", stem.derived_start, stem.derived_end, &stem.derived_phonemes)?;
        if base != derived {
            return Err(corrupt(format!("the stem spans {base} vowels of the base but {derived} of the derived word")));
        }
        Ok(())
    }

    fn phonemes(&mut self, field: &str, system: PhoneSystem, phonemes: &[String]) -> Result<(), Fault> {
        self.list(field, phonemes.len())?;
        for phoneme in phonemes {
            self.text(field, phoneme)?;
            // IPA is kept as the source writes it, spaces between a phrase's words included: `text` has already
            // refused the empty and the control characters, and nothing is segmented or guessed here.
            let valid = match system {
                PhoneSystem::Arpabet => phones::phone(phoneme).is_some(),
                PhoneSystem::Ipa => true,
            };
            if !valid {
                return Err(corrupt(format!("`{field}`: {} is not a {system:?} phoneme", clip(phoneme))));
            }
        }
        Ok(())
    }

    fn source(&mut self, id: &str) -> Result<(), Fault> {
        self.text("source", id)?;
        if !self.sources.contains(id) {
            return Err(corrupt(format!("source {} is not one the header names", clip(id))));
        }
        Ok(())
    }

    /// A list field: at least one item, at most `max_list_items`.
    fn list(&self, field: &str, len: usize) -> Result<(), Fault> {
        if len == 0 {
            return Err(corrupt(format!("`{field}` is empty")));
        }
        if len64(len) > self.limits.max_list_items {
            let detail = format!("`{field}` holds {len} items, more than {}", self.limits.max_list_items);
            return Err(Fault::TooLarge(WordLimit::ListItems, detail));
        }
        Ok(())
    }

    /// An optional string: absent, or as a required one (an empty string is not how a pack says "none").
    fn optional_text(&mut self, field: &str, text: Option<&str>) -> Result<(), Fault> {
        match text {
            Some(text) => self.text(field, text),
            None => Ok(()),
        }
    }

    /// A string field: not empty, at most `max_string_chars` scalars, no control character.
    fn text(&mut self, field: &str, text: &str) -> Result<(), Fault> {
        if text.is_empty() {
            return Err(corrupt(format!("`{field}` is empty")));
        }
        let max = usize::try_from(self.limits.max_string_chars).unwrap_or(usize::MAX);
        if text.chars().nth(max).is_some() {
            let detail = format!("`{field}` is longer than {} characters", self.limits.max_string_chars);
            return Err(Fault::TooLarge(WordLimit::StringChars, detail));
        }
        if text.chars().any(char::is_control) {
            return Err(corrupt(format!("`{field}` {} holds a control character", clip(text))));
        }
        self.bytes = self.bytes.saturating_add(len64(text.len()));
        Ok(())
    }
}

/// **A BCP 47 tag's shape**: a 2–8 letter primary subtag, or private use (`x`) with at least one subtag, then 1–8
/// alphanumeric subtags, none empty, and a one-letter singleton (an extension's or private use's marker) followed by
/// at least one subtag. `-`, `123`, `en--US`, bare `x` and `en-a` were accepted by the check this replaces (audit,
/// 2026-10-24).
fn bcp47(tag: &str) -> bool {
    let mut parts = tag.split('-');
    let Some(primary) = parts.next() else { return false };
    let rest: Vec<&str> = parts.collect();
    let private = primary == "x";
    let primary_ok = (private && !rest.is_empty())
        || ((2..=8).contains(&primary.len()) && primary.bytes().all(|b| b.is_ascii_alphabetic()));
    if !primary_ok {
        return false;
    }
    if private {
        return rest
            .iter()
            .all(|part| (1..=8).contains(&part.len()) && part.bytes().all(|byte| byte.is_ascii_alphanumeric()));
    }
    let mut index = 0;
    while index < rest.len() {
        let Some(part) = rest.get(index) else { return false };
        if !((1..=8).contains(&part.len()) && part.bytes().all(|byte| byte.is_ascii_alphanumeric())) {
            return false;
        }
        if part.bytes().all(|byte| byte.is_ascii_digit()) && part.len() != 3 {
            return false;
        }
        if part.len() == 1 {
            let Some(next) = rest.get(index + 1) else { return false };
            if next.len() < 2 {
                return false;
            }
        }
        index += 1;
    }
    true
}

/// **The authority of an https address with a nonempty host**, or `None`: the loader's own shape, so a pack the
/// builder writes is one it reads. `https://`, `https:///x`, `https://?x`, `https://#x`, `https://:443` and `https://@`
/// have no host, and whitespace or a control character anywhere in the address is refused (audit, 2026-10-24).
fn https_host(url: &str) -> Option<&str> {
    let rest = url.strip_prefix("https://")?;
    if rest.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return None;
    }
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    // Userinfo, if any, then the host, bracketed for IPv6, and a numeric port.
    let host_port = authority.rsplit_once('@').map_or(authority, |(_, host)| host);
    let (host, port) = if let Some(bracketed) = host_port.strip_prefix('[') {
        let (inside, tail) = bracketed.split_once(']')?;
        let port = match tail {
            "" => None,
            _ => Some(tail.strip_prefix(':')?),
        };
        (inside, port)
    } else {
        match host_port.split_once(':') {
            Some((host, port)) => (host, Some(port)),
            None => (host_port, None),
        }
    };
    let host_ok = if host_port.starts_with('[') {
        !host.is_empty() && host.bytes().all(|b| b.is_ascii_hexdigit() || matches!(b, b':' | b'.'))
    } else {
        !host.is_empty() && host.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_'))
    };
    if !host_ok {
        return None;
    }
    if let Some(port) = port
        && (port.is_empty() || !port.bytes().all(|b| b.is_ascii_digit()))
    {
        return None;
    }
    Some(host)
}

/// The length of a half-open range of vowel indices, which must be non-empty and within the pronunciation's vowels.
fn vowel_range(side: &str, start: u32, end: u32, phonemes: &[String]) -> Result<u32, Fault> {
    let vowels = phones::vowels(phonemes);
    let within = usize::try_from(end).is_ok_and(|end| end <= vowels);
    if start >= end || !within {
        return Err(corrupt(format!("the {side} stem range {start}..{end} is not within its {vowels} vowels")));
    }
    Ok(end.saturating_sub(start))
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

    use super::*;

    fn pack(record: &str) -> Result<WordLexicon, WordError> {
        let sha = "0".repeat(64);
        let header = format!(
            r#"{{"type":"header","schema":"xdict-word-pack","version":{WORD_PACK_VERSION},"language":"en","sources":[{{"id":"oewn","name":"Synthetic oewn","url":"https://example.invalid/oewn","version":"test-1","sha256":"{sha}","licence":"CC0-1.0","attribution":"Written by the xdict-core unit tests"}}]}}"#
        );
        WordLexicon::from_jsonl(format!("{header}\n{record}\n").as_bytes())
    }

    /// **Schema 2 carries a synset relation**, and a pack that says version 1 is refused naming both versions — the
    /// loader reads one shape, and reading an older pack as if it had sense records would be guesswork.
    #[test]
    fn a_sense_relation_loads_and_a_version_1_pack_is_refused() {
        let loaded = pack(r#"{"type":"sense","word":"good","other":"fine","relation":"synonym","synset":"oewn-good-n","pos":"noun","source":"oewn"}"#)
            .expect("a schema 2 pack loads");
        let senses: Vec<_> = loaded
            .records()
            .iter()
            .filter_map(|r| if let LexiconRecord::Sense(s) = r { Some(s) } else { None })
            .collect();
        assert_eq!(senses.len(), 1);
        assert_eq!(senses[0].relation, SenseRelation::Synonym);
        assert_eq!((senses[0].word.as_str(), senses[0].other.as_str()), ("good", "fine"));

        let sha = "0".repeat(64);
        let old = format!(
            r#"{{"type":"header","schema":"xdict-word-pack","version":1,"language":"en","sources":[{{"id":"oewn","name":"Synthetic oewn","url":"https://example.invalid/oewn","version":"test-1","sha256":"{sha}","licence":"CC0-1.0","attribution":"x"}}]}}"#
        );
        // A pack's last line carries its newline: without it the pack is refused as truncated before any version is read.
        let old = format!("{old}\n");
        match WordLexicon::from_jsonl(old.as_bytes()) {
            Err(WordError::UnsupportedVersion { found, supported, .. }) => {
                assert_eq!((found, supported), (1, WORD_PACK_VERSION));
            }
            other => panic!("a version 1 pack was not refused: {other:?}"),
        }
    }

    fn source(url: &str) -> LexiconSource {
        LexiconSource {
            id: "oewn".into(),
            name: "Synthetic oewn".into(),
            url: url.into(),
            version: "test-1".into(),
            sha256: "0".repeat(64),
            licence: "CC0-1.0".into(),
            attribution: "Written by the xdict-core unit tests".into(),
            coverage: Some("Does not cover phrases".into()),
        }
    }

    fn header(language: &str, url: &str) -> LexiconHeader {
        LexiconHeader {
            schema: WORD_PACK_SCHEMA.into(),
            version: WORD_PACK_VERSION,
            language: language.into(),
            sources: vec![source(url)],
        }
    }

    #[test]
    fn one_origin_declared_twice_is_kept_once_and_a_conflict_is_refused() {
        // The guard the explorer's first-declaration index relies on: identical records are one declaration, and a
        // conflicting one never reaches it.
        let origin = r#"{"type":"origin","id":"n1","language":"en","form":"bank","word":"bank"}"#;
        let same = pack(&format!("{origin}\n{origin}"));
        assert!(same.is_ok(), "{same:?}");
        let conflict = r#"{"type":"origin","id":"n1","language":"en","form":"shore","word":"bank"}"#;
        let refused = pack(&format!("{origin}\n{conflict}"));
        assert!(matches!(refused, Err(WordError::Corrupt { line: 3, .. })), "{refused:?}");
    }

    #[test]
    fn a_header_alone_answers_to_the_string_budget() {
        let limits = LexiconLimits { max_total_bytes: 0, ..LexiconLimits::default() };
        let result =
            WordLexicon::from_records_with_limits(header("en", "https://example.invalid/oewn"), Vec::new(), limits);
        assert!(matches!(result, Err(WordError::TooLarge { limit: WordLimit::TotalBytes, .. })), "{result:?}");
    }

    #[test]
    fn malformed_languages_and_urls_are_refused_and_well_formed_ones_load() {
        for language in ["en", "en-US", "zh-Hans"] {
            let loaded = WordLexicon::from_records(header(language, "https://example.invalid/oewn"), Vec::new());
            assert!(loaded.is_ok(), "{language}: {loaded:?}");
        }
        for language in ["-", "123", "en--US", "en-", "toolonglanguage", "x", "en-a"] {
            let refused = WordLexicon::from_records(header(language, "https://example.invalid/oewn"), Vec::new());
            assert!(matches!(refused, Err(WordError::Corrupt { .. })), "{language}: {refused:?}");
        }
        for url in [
            "https://",
            "https:///x",
            "https://?x",
            "https://#x",
            "https://exa mple",
            "https://example.org/a b",
            "https://:443",
            "https://@",
            "https://[broken",
            "https://example.org:not-a-port",
            "http://example.invalid",
        ] {
            let refused = WordLexicon::from_records(header("en", url), Vec::new());
            assert!(matches!(refused, Err(WordError::Corrupt { .. })), "{url}: {refused:?}");
        }
        for url in ["https://example.org", "https://user@example.org:443/a?b#c", "https://[2001:db8::1]:443/x"] {
            let loaded = WordLexicon::from_records(header("en", url), Vec::new());
            assert!(loaded.is_ok(), "{url}: {loaded:?}");
        }
    }

    /// **Every variant's serde form is the loader's form**: serialize what the loader parsed, and the line loads back
    /// to the same record. Red where a field name, a tag or an enum spelling is renamed on one side only (audit,
    /// 2026-10-24).
    #[cfg(feature = "serde")]
    #[test]
    fn every_record_variant_round_trips_through_its_serde_form() {
        let lines = [
            r#"{"type":"pronunciation","word":"nation","system":"arpabet","phonemes":["N","EY1","SH","AH0","N"],"source":"oewn"}"#,
            r#"{"type":"form","form":"ran","lemma":"run","pos":"verb","tags":["past"],"source":"oewn"}"#,
            r#"{"type":"derivation","base":"possible","derived":"possibility","kind":"suffix","affix":"ity","source":"oewn"}"#,
            r#"{"type":"origin","id":"n1","language":"en","form":"bank","word":"bank"}"#,
            r#"{"type":"etymon","child":"n1","parent":"n2","relation":"inherited","source":"oewn"}"#,
            r#"{"type":"pronunciation","word":"record","pos":"verb","system":"arpabet","phonemes":["R","IH0","K","AO1","R","D"],"dialect":"US","source":"oewn"}"#,
            r#"{"type":"derivation","base":"record","basePos":"noun","derived":"record","derivedPos":"verb","kind":"conversion","source":"oewn","stem":{"basePhonemes":["R","IH0","K","AO1","R","D"],"baseStart":1,"baseEnd":2,"derivedPhonemes":["R","IY0","K","AO1","R","D"],"derivedStart":1,"derivedEnd":2}}"#,
        ];
        for line in lines {
            let lexicon = pack(line);
            assert!(lexicon.is_ok(), "{line}: {lexicon:?}");
            let Ok(lexicon) = lexicon else { return };
            let records = lexicon.records().to_vec();
            assert_eq!(records.len(), 1, "{line}");
            let Some(record) = records.first() else { return };
            let serialized = serde_json::to_string(record);
            assert!(serialized.is_ok(), "{line}: {serialized:?}");
            let Ok(serialized) = serialized else { return };
            let again = pack(&serialized);
            assert!(again.is_ok(), "{line} -> {serialized}: {again:?}");
            let Ok(again) = again else { return };
            assert_eq!(again.records(), records.as_slice(), "{line} -> {serialized}");
        }
    }

    #[cfg(feature = "serde")]
    #[test]
    fn a_serialized_header_carries_its_type_and_loads_back() {
        let expected = header("en", "https://example.invalid/oewn");
        let serialized = serde_json::to_string(&expected);
        assert!(serialized.is_ok(), "{serialized:?}");
        let Ok(line) = serialized else { return };
        assert!(line.contains(r#""type":"header""#), "{line}");
        assert!(line.contains(r#""coverage":"Does not cover phrases""#), "{line}");
        let loaded = WordLexicon::from_jsonl(format!("{line}\n").as_bytes());
        assert!(loaded.is_ok(), "{loaded:?}");
        let Ok(loaded) = loaded else { return };
        assert_eq!(loaded.header(), &expected, "the header did not survive its serde form");
    }

    #[test]
    fn ipa_is_one_whole_transcription_and_arpabet_stays_tokens() {
        // A phrase's IPA as the source writes it, the space between its words kept, POS and source with it.
        let phrase = r#"{"type":"pronunciation","word":"ice cream","pos":"noun","system":"ipa","phonemes":["ˈaɪs ˌkɹiːm"],"source":"oewn"}"#;
        let expected = LexiconRecord::Pronunciation(PronunciationRecord {
            word: "ice cream".into(),
            pos: Some("noun".into()),
            system: PhoneSystem::Ipa,
            phonemes: vec!["ˈaɪs ˌkɹiːm".into()],
            dialect: None,
            source: "oewn".into(),
        });
        assert_eq!(pack(phrase).map(|lexicon| lexicon.records().to_vec()), Ok(vec![expected]));

        // ARPAbet is one token per item: an embedded space is not a phoneme.
        let spaced = r#"{"type":"pronunciation","word":"nation","system":"arpabet","phonemes":["N EY1","SH","AH0","N"],"source":"oewn"}"#;
        assert!(matches!(pack(spaced), Err(WordError::Corrupt { line: 2, .. })), "{:?}", pack(spaced));
        // Ordinary spaces pass in IPA; control characters still do not.
        let tabbed =
            r#"{"type":"pronunciation","word":"ice cream","system":"ipa","phonemes":["ˈaɪs\tˌkɹiːm"],"source":"oewn"}"#;
        assert!(matches!(pack(tabbed), Err(WordError::Corrupt { line: 2, .. })), "{:?}", pack(tabbed));
    }
}
