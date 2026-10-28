//! The bounds, the vocabulary and the schema constants the pack is built and checked to.
//!
//! The numbers are the Rust loader's (`LexiconLimits::default` in `xdict-core/src/words/lexicon.rs`), mirrored so
//! that a pack this crate writes always loads; a pack past a whole-pack bound is never written. `WORD_LEXICON.md`
//! is the written spec, and `core/xdict-pack/reference/word_lexicon.py` is the reference implementation this crate is
//! held to, byte for byte.

/// The pack's schema name.
pub const PACK_SCHEMA: &str = "xdict-word-pack";
/// The pack's schema version.
pub const PACK_VERSION: u64 = 2;
/// The language a pack is built for.
pub const PACK_LANGUAGE: &str = "en";
/// The manifest's format name.
pub const MANIFEST_FORMAT: &str = "xdict-word-lexicon-sources";
/// The manifest's format version.
pub const MANIFEST_VERSION: u64 = 2;
/// The file name a pack is written as.
pub const PACK_NAME: &str = "xdict-words-en.jsonl";

/// Per line, its `\n` not counted.
pub const MAX_LINE_BYTES: u64 = 64 * 1024;
/// Records after the header.
pub const MAX_RECORDS: u64 = 4_000_000;
/// The whole pack, its newlines included.
pub const MAX_TOTAL_BYTES: u64 = 512 * 1024 * 1024;
/// Per string field, in Unicode scalar values.
pub const MAX_STRING_CHARS: u64 = 256;
/// Per list field.
pub const MAX_LIST_ITEMS: u64 = 64;
/// How deep `etymology_records` follows ancestry from an English head.
pub const MAX_DEPTH: u32 = 12;

/// **The etymology graph's own bound** (plan-local-word-pack decision 4): ancestry nodes held at once, and distinct
/// edges. The pack's own bounds bound its output, not the graph the parse builds first, and the graph is what a Mac
/// with 8 GB must carry before a single record is written. Measured on mbp16 over the pinned 2023-12 file
/// (2026-10-28): **1,963,781 nodes and 835,244 edges**, the build peaking at 2.13 GiB of resident memory — about
/// 1.2 KiB a node. Twice the pinned file's nodes is where the memory stops fitting a reader's Mac, so that is the
/// bound: a corrupt or hostile file — a decompression bomb, or nothing but fresh term ids — fails loudly there
/// instead of thrashing. `the_ancestry_graph_is_within_its_bound` prints the pinned file's own size.
pub const MAX_GRAPH_NODES: u64 = 4_000_000;
/// The most distinct ancestry edges the graph holds; see [`MAX_GRAPH_NODES`]. The pinned file has 835,244.
pub const MAX_GRAPH_EDGES: u64 = 3_000_000;
/// The most rows one term's block may hold (etymology-db writes a handful): a file whose blocks never end is refused
/// rather than accumulated waiting for the graph's own bound, which is only checked once a block completes.
pub const MAX_ETYMOLOGY_BLOCK_ROWS: usize = 1_000_000;

/// A source line, its terminator included.
pub const MAX_SOURCE_LINE_BYTES: u64 = 16 << 20;
/// One etymology-db CSV field.
pub const MAX_CSV_FIELD_BYTES: u64 = 1 << 16;
/// One zip member, read whole.
pub const MAX_ZIP_MEMBER_BYTES: u64 = 256 << 20;
/// One notice file.
pub const MAX_NOTICE_BYTES: u64 = 1 << 20;
/// The sources manifest, which is a few KiB: a file larger than this is not one.
pub const MAX_MANIFEST_BYTES: u64 = 4 << 20;
/// How many metadata samples of skipped rows the report keeps per reason; the counts cover every row.
pub const MAX_SKIPPED_SAMPLES: usize = 50;

/// The record types, in the order a pack writes them.
pub const RECORD_TYPES: [&str; 6] = ["pronunciation", "form", "derivation", "origin", "etymon", "sense"];

/// CMUdict's vowels, as stressed ARPAbet keeps them before the stress digit.
pub const ARPABET_VOWELS: [&str; 15] =
    ["AA", "AE", "AH", "AO", "AW", "AY", "EH", "ER", "EY", "IH", "IY", "OW", "OY", "UH", "UW"];
/// CMUdict's consonants, which carry no stress digit.
pub const ARPABET_CONSONANTS: [&str; 24] = [
    "B", "CH", "D", "DH", "F", "G", "HH", "JH", "K", "L", "M", "N", "NG", "P", "R", "S", "SH", "T", "TH", "V", "W",
    "Y", "Z", "ZH",
];

/// The pronunciation systems a record may name.
pub const PHONE_SYSTEMS: [&str; 2] = ["arpabet", "ipa"];
/// A derivation's kinds.
pub const FAMILY_KINDS: [&str; 5] = ["prefix", "suffix", "conversion", "compound", "other"];
/// An etymon edge's relations.
pub const ETYMON_RELATIONS: [&str; 9] =
    ["inherited", "borrowed", "learned", "derived", "calque", "compound", "affix", "root", "unknown"];
/// A sense record's relations: the loader's four. The writer emits synonym and antonym, the two a mode reads.
pub const SENSE_RELATIONS: [&str; 4] = ["synonym", "antonym", "hypernym", "hyponym"];
/// A derivation's stem alignment: exactly these fields.
pub const STEM_FIELDS: [&str; 6] =
    ["basePhonemes", "baseStart", "baseEnd", "derivedPhonemes", "derivedStart", "derivedEnd"];
/// The largest half-open vowel index a stem range may name.
pub const MAX_U32: u64 = (1 << 32) - 1;

/// A header source's fields, in the order the notices list them.
pub const SOURCE_FIELDS: [&str; 7] = ["id", "name", "url", "version", "sha256", "licence", "attribution"];

/// Keys that carry dictionary content rather than metadata. A record holding one is refused.
pub const CONTENT_KEYS: [&str; 16] = [
    "definition",
    "definitions",
    "gloss",
    "glosses",
    "raw_glosses",
    "example",
    "examples",
    "senses",
    "etymology_text",
    "quote",
    "quotes",
    "text",
    "usage",
    "note",
    "notes",
    "expansion",
];

/// OEWN's part-of-speech codes, as the pack names them.
pub const OEWN_POS: [(&str, &str); 5] = [("n", "noun"), ("v", "verb"), ("a", "adj"), ("s", "adj"), ("r", "adv")];

/// etymology-db relation types that are ancestry, and the relation each is written as.
pub const ETY_ANCESTRY: [(&str, &str); 11] = [
    ("inherited_from", "inherited"),
    ("borrowed_from", "borrowed"),
    ("orthographic_borrowing_from", "borrowed"),
    ("unadapted_borrowing_from", "borrowed"),
    ("learned_borrowing_from", "learned"),
    ("semi_learned_borrowing_from", "learned"),
    ("derived_from", "derived"),
    ("calque_of", "calque"),
    ("partial_calque_of", "calque"),
    ("semantic_loan_of", "calque"),
    ("phono-semantic_matching_of", "unknown"),
];
/// A root names the term's root, not a step of its chain.
pub const ETY_ROOT: [&str; 2] = ["has_root", "root"];
/// English-to-English rows that name the base of a modern derivation explicitly.
pub const ETY_WITH_ROOT: [&str; 2] = ["has_prefix_with_root", "has_suffix_with_root"];
/// A block's group rows.
pub const ETY_GROUP: [&str; 3] = ["group_affix_root", "group_related_root", "group_derived_root"];
/// Not ancestry: affixes (shared affixes must never join words as a root), compounds, clippings, cognates.
pub const ETY_DROPPED: [&str; 15] = [
    "has_prefix",
    "has_suffix",
    "has_confix",
    "has_affix",
    "compound_of",
    "back-formation_from",
    "doublet_with",
    "is_onomatopoeic",
    "named_after",
    "etymologically_related_to",
    "blend_of",
    "clipping_of",
    "abbreviation_of",
    "initialism_of",
    "cognate_of",
];
/// The etymology-db columns, in the order the builder wants them.
pub const ETY_COLUMNS: [&str; 11] = [
    "term_id",
    "lang",
    "term",
    "reltype",
    "related_term_id",
    "related_lang",
    "related_term",
    "position",
    "group_tag",
    "parent_tag",
    "parent_position",
];
/// The language an etymology-db row must be in to become an English head.
pub const ETY_ENGLISH: &str = "English";

/// MorphyNet's inflectional part-of-speech codes.
pub const MORPHYNET_INFL_POS: [(&str, &str); 4] = [("N", "noun"), ("V", "verb"), ("ADJ", "adj"), ("ADV", "adv")];
/// The pinned `eng.inflectional.v1.tsv` holds exactly two rows broken by stray quotes, whose feature column is no
/// POS code. These exact rows are skipped and counted; any other row with an unknown code still fails the build.
pub const MORPHYNET_INFL_KNOWN_MALFORMED: [[&str; 4]; 2] =
    [["\"softly", " softly\"", "\"|", "\"softly|\""], ["\"softly", " softly\"", "comparable", "-"]];
/// MorphyNet's derivational part-of-speech codes.
pub const MORPHYNET_DERI_POS: [(&str, &str); 4] = [("N", "noun"), ("V", "verb"), ("J", "adj"), ("R", "adv")];
/// The derivation types MorphyNet's English file declares.
pub const MORPHYNET_KINDS: [&str; 2] = ["prefix", "suffix"];
/// MorphyNet's English derivational file uses `U` in about 2,000 rows; its README documents only N, V, J and R, so
/// such rows are skipped and counted rather than given an invented part of speech.
pub const MORPHYNET_UNDOCUMENTED_POS: [&str; 1] = ["U"];
/// The vowels the attachment rules treat as vowels.
pub const MORPHYNET_VOWELS: [char; 5] = ['a', 'e', 'i', 'o', 'u'];

/// The providers a manifest may name.
pub const PROVIDERS: [&str; 6] =
    ["cmudict", "oewn", "etymology-db", "morphynet-inflection", "morphynet-derivation", "kaikki"];

// ---- predicates over the tables above ---------------------------------------------------------------

/// Whether `value` is one of `table`.
pub fn in_table(table: &[&str], value: &str) -> bool {
    table.contains(&value)
}

/// The value `code` maps to in a `(code, value)` table.
pub fn lookup<'a>(table: &[(&'a str, &'a str)], code: &str) -> Option<&'a str> {
    table.iter().find(|(name, _)| *name == code).map(|(_, value)| *value)
}
