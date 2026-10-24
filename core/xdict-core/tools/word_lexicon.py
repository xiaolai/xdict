#!/usr/bin/env python3
"""Build XDict's word pack: redistributable English linguistic metadata for `xdict_core::words`.

The pack is the `xdict-word-pack` v1 JSONL the Rust loader reads (`src/words/lexicon.rs`): a header line naming
every source (URL, pinned version, SHA-256 of the raw download, licence, short attribution, coverage), then one
typed record per line (`pronunciation`, `form`, `derivation`, `origin`, `etymon`). Records hold linguistic
metadata only; a definition, gloss, example or prose etymology is never read into one, and the writer refuses
any record carrying such a key. The complete licence notices go to a sidecar (`<pack>.notices.md`) that travels
with the pack; the header keeps only the short credits.

Providers (`WORD_LEXICON.md` has the mapping rules and each source's obligations):

- CMUdict `cmudict.dict`: stressed ARPAbet, every variant, no part of speech.
- Open English Wordnet JSON zip, `entries-*.json` only: POS-tagged IPA and sense-level derivation links, which
  OEWN gives undirected: such a pair, kind `other` or (same spelling) `conversion`, has unoriented endpoints
  (written in alphabetical order, which claims nothing about which word comes from which).
- etymology-db CSV.gz: explicit ancestry only. A `group_derived_root` is a chain walked in `parent_position`
  order; `has_root` links the term to its root and is never a chain step; affixes, cognates, doublets and
  "related" rows are not ancestry. English `*_with_root` rows give modern derivations.
- MorphyNet English TSVs: tagged inflections and typed prefix/suffix derivations, each kept only when its
  morpheme attaches to its base.
- Kaikki per-word JSONL (optional, `--kaikki-input` receipts): POS-tagged IPA, tagged forms, `form_of` forms
  confirmed by the sense's own link, and `af`/`prefix`/`suffix`/`compound`/`confix` derivations.

No provider supplies a stem alignment, so the builder never writes a derivation's optional `stem`; it validates one
exactly as the loader does when a record carries it.

Every raw file is checked against its pinned SHA-256 and size before it is parsed. Raw downloads and built
packs live outside Git. Standard library only; no network.
"""

from __future__ import annotations

import argparse
import csv
import gzip
import hashlib
import json
import os
import re
import sys
import tempfile
import unicodedata
import zipfile
from collections import Counter
from collections.abc import Iterable, Iterator
from pathlib import Path, PurePosixPath

PACK_SCHEMA = "xdict-word-pack"
PACK_VERSION = 1
PACK_LANGUAGE = "en"
MANIFEST_FORMAT = "xdict-word-lexicon-sources"
MANIFEST_VERSION = 2
PACK_NAME = "xdict-words-en.jsonl"

# The Rust loader's bounds (`LexiconLimits::default` in `src/words/lexicon.rs`). The writer holds every record and
# the whole pack to them, so a pack it writes always loads; a pack past a whole-pack bound is never written.
MAX_LINE_BYTES = 64 * 1024
MAX_RECORDS = 4_000_000
MAX_TOTAL_BYTES = 512 * 1024 * 1024
MAX_STRING_CHARS = 256
MAX_LIST_ITEMS = 64
MAX_DEPTH = 12

# Source-side bounds: a line or field past these is a `bound` error naming the source and line.
MAX_SOURCE_LINE_BYTES = 16 << 20
MAX_CSV_FIELD_BYTES = 1 << 16
MAX_ZIP_MEMBER_BYTES = 256 << 20
MAX_NOTICE_BYTES = 1 << 20
# The report keeps at most this many metadata samples of skipped rows per reason, the first in source order; the
# count covers every row.
MAX_SKIPPED_SAMPLES = 50

ARPABET_VOWELS = frozenset(
    {"AA", "AE", "AH", "AO", "AW", "AY", "EH", "ER", "EY", "IH", "IY", "OW", "OY", "UH", "UW"}
)
ARPABET_CONSONANTS = frozenset(
    {
        "B", "CH", "D", "DH", "F", "G", "HH", "JH", "K", "L", "M", "N", "NG", "P", "R", "S", "SH", "T", "TH",
        "V", "W", "Y", "Z", "ZH",
    }
)

RECORD_TYPES = ("pronunciation", "form", "derivation", "origin", "etymon")
# type -> (required fields, optional fields). `phonemes` and `tags` are lists, `uncertain` a bool, the rest strings.
RECORD_FIELDS = {
    "pronunciation": ({"word", "system", "phonemes", "source"}, {"pos", "dialect"}),
    "form": ({"form", "lemma", "pos", "tags", "source"}, set()),
    "derivation": ({"base", "derived", "kind", "source"}, {"basePos", "derivedPos", "affix", "stem"}),
    "origin": ({"id", "language", "form"}, {"word"}),
    "etymon": ({"child", "parent", "relation", "uncertain", "source"}, set()),
}
LIST_FIELDS = frozenset({"phonemes", "tags"})
# A derivation's optional `stem` (`StemAlignment` in src/words/lexicon.rs): exactly these fields, two ARPAbet
# pronunciations and a half-open range of vowel indices on each, the two ranges one length.
STEM_FIELDS = ("basePhonemes", "baseStart", "baseEnd", "derivedPhonemes", "derivedStart", "derivedEnd")
MAX_U32 = (1 << 32) - 1
PHONE_SYSTEMS = frozenset({"arpabet", "ipa"})
FAMILY_KINDS = frozenset({"prefix", "suffix", "conversion", "compound", "other"})
ETYMON_RELATIONS = frozenset(
    {"inherited", "borrowed", "learned", "derived", "calque", "compound", "affix", "root", "unknown"}
)
SOURCE_FIELDS = ("id", "name", "url", "version", "sha256", "licence", "attribution")

# Keys that carry dictionary content rather than metadata. A record holding one is refused.
CONTENT_KEYS = frozenset(
    {
        "definition", "definitions", "gloss", "glosses", "raw_glosses", "example", "examples", "senses",
        "etymology_text", "quote", "quotes", "text", "usage", "note", "notes", "expansion",
    }
)

OEWN_POS = {"n": "noun", "v": "verb", "a": "adj", "s": "adj", "r": "adv"}
# An entry key is a POS code, optionally numbered (`n-1`, `n-2`) for a further lexeme of the same POS (a homograph).
OEWN_ENTRY_KEY = re.compile(r"([nvars])(?:-[1-9][0-9]*)?")
OEWN_ENTRIES = re.compile(r"entries-[^/]+\.json")

# etymology-db relation types (README of 2023-12, plus `has_root`, which the README omits and the data uses),
# each in exactly one class. A type in none fails the build after the whole file is read, listing every one.
ETY_ANCESTRY = {
    "inherited_from": "inherited",
    "borrowed_from": "borrowed",
    "orthographic_borrowing_from": "borrowed",
    "unadapted_borrowing_from": "borrowed",
    "learned_borrowing_from": "learned",
    "semi_learned_borrowing_from": "learned",
    "derived_from": "derived",
    "calque_of": "calque",
    "partial_calque_of": "calque",
    "semantic_loan_of": "calque",
    "phono-semantic_matching_of": "unknown",
}
# A root names the term's root, not a step of its chain: an edge with relation `root`.
ETY_ROOT = frozenset({"has_root", "root"})
# English-to-English rows that name the base of a modern derivation explicitly.
ETY_WITH_ROOT = frozenset({"has_prefix_with_root", "has_suffix_with_root"})
ETY_GROUP = frozenset({"group_affix_root", "group_related_root", "group_derived_root"})
# Not ancestry: affixes (shared affixes must never join words as a root), compounds, clippings, cognates.
ETY_DROPPED = frozenset(
    {
        "has_prefix", "has_suffix", "has_confix", "has_affix", "compound_of", "back-formation_from",
        "doublet_with", "is_onomatopoeic", "named_after", "etymologically_related_to", "blend_of",
        "clipping_of", "abbreviation_of", "initialism_of", "cognate_of",
    }
)
ETY_COLUMNS = (
    "term_id", "lang", "term", "reltype", "related_term_id", "related_lang", "related_term", "position",
    "group_tag", "parent_tag", "parent_position",
)
ETY_ENGLISH = "English"
ETY_GLOSS = re.compile(r"^(.*\S)\s+\([^()]*\)$")

MORPHYNET_INFL_POS = {"N": "noun", "V": "verb", "ADJ": "adj", "ADV": "adv"}
# The pinned `eng.inflectional.v1.tsv` holds exactly two rows broken by stray quotes (a quoted `"softly\tsoftly"`
# split across the tab), whose feature column is no POS code. These exact rows are skipped and counted; any other
# row with an unknown code still fails the build.
MORPHYNET_INFL_KNOWN_MALFORMED = frozenset(
    {
        ('"softly', ' softly"', '"|', '"softly|"'),
        ('"softly', ' softly"', "comparable", "-"),
    }
)
MORPHYNET_DERI_POS = {"N": "noun", "V": "verb", "J": "adj", "R": "adv"}
MORPHYNET_KINDS = frozenset({"prefix", "suffix"})
# MorphyNet's English derivational file uses `U` in about 2,000 rows; its README documents only N, V, J and R, so
# such rows are skipped and counted rather than given an invented part of speech.
MORPHYNET_UNDOCUMENTED_POS = frozenset({"U"})
MORPHYNET_VOWELS = frozenset("aeiou")

# Kaikki form tags that mark a table artefact, the headword itself or another spelling, not an inflection.
KAIKKI_FORM_SKIP = frozenset(
    {"table-tags", "inflection-template", "canonical", "romanization", "class", "alternative", "alt-of"}
)
KAIKKI_SOUND_POS = {"noun": "noun", "verb": "verb", "adjective": "adj", "adverb": "adv"}
KAIKKI_AFFIX_TEMPLATES = frozenset({"af", "affix", "prefix", "pre", "suffix", "suf", "compound", "com", "confix", "con"})
KAIKKI_FOREIGN_PART = re.compile(r"^[a-z]{2,3}(?:-[a-z]{2,3})*:")
KAIKKI_WORD_FILE = re.compile(r"[^/\\\x00-\x1f.][^/\\\x00-\x1f]*")

SHA256_HEX = re.compile(r"[0-9a-f]{64}")
# A manifest id; a header id is one, optionally with `:` and a per-file part (`kaikki:impossible`). Every id is within
# the loader's charset (letters, digits and `- _ . :`). `<prefix>:sha256:<hex>` is reserved for a Kaikki word the
# plain form cannot hold (`kaikki_source_id`).
SOURCE_PREFIX = re.compile(r"[a-z][a-z0-9-]*")
SOURCE_ID = re.compile(r"[a-z][a-z0-9-]*(?::(?:sha256:[0-9a-f]{64}|[A-Za-z0-9._-]+))?")
RESERVED_ID_PART = "sha256:"
PLAIN_FILE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")


class LexiconError(ValueError):
    """A typed failure: `kind` is one of malformed, bound, version, content, licence, pending, hash, missing."""

    KINDS = frozenset({"malformed", "bound", "version", "content", "licence", "pending", "hash", "missing"})

    def __init__(self, kind: str, message: str, *, source: str | None = None, line: int | None = None):
        if kind not in self.KINDS:
            raise ValueError(f"unknown LexiconError kind {kind!r}")
        where = (source or "") + (f":{line}" if line is not None else "")
        super().__init__(f"{kind}: {where}: {message}" if where else f"{kind}: {message}")
        self.kind = kind
        self.source = source
        self.line = line


# --- text helpers ---------------------------------------------------------------------------------------------


def nfc(text: str) -> str:
    return unicodedata.normalize("NFC", text)


def has_control(text: str) -> bool:
    return any(unicodedata.category(ch) == "Cc" for ch in text)


def https_host(url: str) -> str | None:
    """`url`'s host when it is an https address the Rust loader accepts: a nonempty DNS name or a bracketed IPv6
    literal, an optional numeric port, no whitespace or control character anywhere, and nothing but userinfo before
    the host. `https://:443`, `https://@`, `https://[broken` and `https://example.org:not-a-port` are refused (audit,
    2026-10-24)."""
    if not url.startswith("https://"):
        return None
    rest = url[len("https://"):]
    if any(ch.isspace() or has_control(ch) for ch in rest):
        return None
    authority = rest.split("/", 1)[0].split("?", 1)[0].split("#", 1)[0]
    host_port = authority.rsplit("@", 1)[-1]
    if host_port.startswith("["):
        inside, separator, tail = host_port[1:].partition("]")
        if not separator or (tail and not tail.startswith(":")):
            return None
        if not inside or any(ch not in "0123456789abcdefABCDEF:." for ch in inside):
            return None
        port = tail[1:] if tail else None
        host = inside
    else:
        host, _, port_text = host_port.partition(":")
        if not host or any(not (ch.isalnum() or ch in "-._") for ch in host):
            return None
        port = port_text or None
    if port is not None and not port.isdigit():
        return None
    return host

def check_line(raw: str, source: str, line: int) -> str:
    if len(raw) > MAX_SOURCE_LINE_BYTES or len(raw.encode("utf-8")) > MAX_SOURCE_LINE_BYTES:
        raise LexiconError("bound", f"line longer than {MAX_SOURCE_LINE_BYTES} bytes", source=source, line=line)
    return raw.rstrip("\n").rstrip("\r")


def strip_gloss(form: str) -> str:
    """`*per- (fare)` -> `*per-`: etymology-db appends a gloss in parentheses to some forms; the form is kept whole,
    a trailing hyphen included."""
    match = ETY_GLOSS.match(form)
    return match.group(1) if match else form


def dumps(obj: object) -> str:
    return json.dumps(obj, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def record_skip(
    skipped: Counter[str], samples: dict[str, list[dict]] | None, reason: str, sample: dict | None = None
) -> None:
    """Count a skipped source row under `reason` and, while that reason holds fewer than `MAX_SKIPPED_SAMPLES`,
    keep its metadata sample (source line, words, POS codes, affix, kind; never a definition or a raw row), its
    empty fields dropped."""
    skipped[reason] += 1
    if samples is None or sample is None:
        return
    bucket = samples.setdefault(reason, [])
    if len(bucket) < MAX_SKIPPED_SAMPLES:
        bucket.append({key: value for key, value in sample.items() if value not in ("", None)})


# --- the sources manifest and raw files -----------------------------------------------------------------------


def validate_notice_files(entry: dict, where: str) -> None:
    """A source's notice files: a non-empty list of plain names, each with a marker and a pinned lowercase hash."""
    files = entry.get("notice_files")
    if files is None:
        return
    if not isinstance(files, list) or not files:
        raise LexiconError("malformed", "notice_files is not a non-empty list", source=where)
    for item in files:
        if (
            not isinstance(item, dict)
            or not isinstance(item.get("file"), str)
            or not PLAIN_FILE.fullmatch(item["file"])
            or not isinstance(item.get("marker"), str)
            or not item["marker"].strip()
        ):
            raise LexiconError("malformed", "a notice_files item needs a plain file and a marker", source=where)
        sha = item.get("sha256")
        if isinstance(sha, str) and sha.strip().lower() == "pending":
            raise LexiconError("pending", f"notice file {item['file']}: sha256 is still pending", source=where)
        if not isinstance(sha, str) or not SHA256_HEX.fullmatch(sha):
            raise LexiconError(
                "malformed", f"notice file {item['file']}: sha256 is not 64 lowercase hex digits", source=where
            )


def validate_provider_entry(entry: dict, provider: str, where: str) -> None:
    """A source's provider-specific fields: Kaikki's prefix, or a pinned download (URL, version, hash, file, size)."""
    if provider == "kaikki":
        prefix = entry.get("url_prefix")
        if not isinstance(prefix, str) or https_host(prefix) is None:
            raise LexiconError("malformed", "kaikki needs an https url_prefix", source=where)
        return
    url = entry.get("url")
    if not isinstance(url, str) or https_host(url) is None:
        raise LexiconError("malformed", "url is not an https address with a host", source=where)
    if not isinstance(entry.get("version"), str) or not entry["version"].strip():
        raise LexiconError("malformed", "missing version", source=where)
    if not isinstance(entry.get("sha256"), str) or not SHA256_HEX.fullmatch(entry["sha256"]):
        raise LexiconError("malformed", "sha256 is not 64 lowercase hex digits", source=where)
    if not isinstance(entry.get("file"), str) or not PLAIN_FILE.fullmatch(entry["file"]):
        raise LexiconError("malformed", "file must be a plain file name", source=where)
    size = entry.get("bytes")
    if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
        raise LexiconError("malformed", "bytes must be a positive integer", source=where)


def read_manifest(path: Path) -> list[dict]:
    """A sources manifest read and validated; a filesystem, UTF-8 or JSON fault is `malformed`, as `build` reports
    it (the audit found `verify` raising a bare `FileNotFoundError`, 2026-10-24)."""
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise LexiconError("malformed", f"unreadable manifest: {error}", source="manifest") from error
    return load_manifest(manifest)


def load_manifest(manifest: object) -> list[dict]:
    """Validate a parsed sources manifest and return its sources, sorted by id.

    A wrong format or version is `version`; a `pending` value anywhere is `pending`; a missing licence,
    attribution or notice is `licence`; anything else out of shape (a URL not https, a SHA-256 not 64 lowercase
    hex digits, a file name with a path in it, a duplicate id, an unknown provider) is `malformed`.
    """
    if not isinstance(manifest, dict):
        raise LexiconError("malformed", "manifest is not an object", source="manifest")
    if manifest.get("format") != MANIFEST_FORMAT or manifest.get("version") != MANIFEST_VERSION:
        raise LexiconError(
            "version",
            f"expected format {MANIFEST_FORMAT!r} version {MANIFEST_VERSION}, found "
            f"{manifest.get('format')!r} version {manifest.get('version')!r}",
            source="manifest",
        )
    sources = manifest.get("sources")
    if not isinstance(sources, list) or not sources:
        raise LexiconError("malformed", "no sources", source="manifest")
    seen: set[str] = set()
    out = []
    for entry in sources:
        if not isinstance(entry, dict):
            raise LexiconError("malformed", "a source is not an object", source="manifest")
        sid = entry.get("id")
        where = f"manifest:{sid}"
        if not isinstance(sid, str) or not SOURCE_PREFIX.fullmatch(sid):
            raise LexiconError("malformed", f"bad source id {sid!r}", source="manifest")
        if sid in seen:
            raise LexiconError("malformed", "duplicate source id", source=where)
        seen.add(sid)
        for key, value in entry.items():
            if isinstance(value, str) and value.strip().lower() == "pending":
                raise LexiconError("pending", f"{key} is still pending", source=where)
        provider = entry.get("provider")
        if provider not in PROVIDERS:
            raise LexiconError("malformed", f"unknown provider {provider!r}", source=where)
        for key in ("name", "licence", "attribution"):
            if not isinstance(entry.get(key), str) or not entry[key].strip():
                raise LexiconError("licence" if key != "name" else "malformed", f"missing {key}", source=where)
        notice, files = entry.get("notice"), entry.get("notice_files")
        if not (isinstance(notice, str) and notice.strip()) and not files:
            raise LexiconError("licence", "no notice and no notice_files", source=where)
        validate_notice_files(entry, where)
        if "coverage" in entry and not isinstance(entry["coverage"], str):
            raise LexiconError("malformed", "coverage is not a string", source=where)
        validate_provider_entry(entry, provider, where)
        out.append(dict(entry))
    return sorted(out, key=lambda s: s["id"])


def sha256_file(path: Path) -> tuple[str, int]:
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
            size += len(chunk)
    return digest.hexdigest(), size


def verify_file(path: Path, sha256: str, size: int | None, source: str) -> str:
    """Hash `path` and return its SHA-256 if it and the size match; `missing` or `hash` otherwise."""
    if not path.is_file():
        raise LexiconError("missing", f"{path} is not a file", source=source)
    actual, actual_size = sha256_file(path)
    if size is not None and actual_size != size:
        raise LexiconError("hash", f"{path}: {actual_size} bytes, expected {size}", source=source)
    if actual != sha256:
        raise LexiconError("hash", f"{path}: sha256 {actual}, expected {sha256}", source=source)
    return actual


def kaikki_source_id(prefix: str, word: str) -> str:
    """`<prefix>:<word>` when that is a `SOURCE_ID`, so a plain word keeps a readable id; otherwise (a space, an
    apostrophe, a non-ASCII letter, or a word starting with the reserved `sha256:`) `<prefix>:sha256:` and the
    SHA-256 of the word's NFC UTF-8 bytes. The reserved part keeps the two forms from ever colliding."""
    canonical = nfc(word)
    plain = f"{prefix}:{canonical}"
    if not canonical.startswith(RESERVED_ID_PART) and SOURCE_ID.fullmatch(plain):
        return plain
    return f"{prefix}:{RESERVED_ID_PART}{hashlib.sha256(canonical.encode('utf-8')).hexdigest()}"


def load_kaikki_receipt(path: Path, template: dict) -> list[tuple[dict, Path]]:
    """A Kaikki receipt (`[{word, url, bytes, sha256, snapshot}]`) to one header source per verified file.

    Each file is `<word>.jsonl` beside the receipt and must match the receipt's size and hash; its source keeps
    its own URL, snapshot and hash, so no file stands in for a corpus it is not. The source id is
    `kaikki_source_id`; its name keeps the word as written. A word listed twice, NFC-equal spellings included, is
    `malformed`, checked before its file is read.
    """
    where = f"kaikki-receipt:{path}"
    try:
        items = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise LexiconError("malformed", f"unreadable receipt: {error}", source=where) from error
    if not isinstance(items, list) or not items:
        raise LexiconError("malformed", "receipt is not a non-empty list", source=where)
    seen: set[str] = set()
    out = []
    for item in items:
        if not isinstance(item, dict):
            raise LexiconError("malformed", "a receipt item is not an object", source=where)
        word, url, sha, size, snapshot = (item.get(k) for k in ("word", "url", "sha256", "bytes", "snapshot"))
        if not isinstance(word, str) or not KAIKKI_WORD_FILE.fullmatch(word):
            raise LexiconError("malformed", f"bad word {word!r}", source=where)
        sid = kaikki_source_id(template["id"], word)
        if sid in seen:
            raise LexiconError("malformed", f"{word!r} listed twice (as {sid})", source=where)
        seen.add(sid)
        if not isinstance(url, str) or not url.startswith(template["url_prefix"]):
            raise LexiconError("malformed", f"{word}: url outside {template['url_prefix']}", source=where)
        if not isinstance(sha, str) or not SHA256_HEX.fullmatch(sha):
            raise LexiconError("malformed", f"{word}: sha256 is not 64 lowercase hex digits", source=where)
        if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
            raise LexiconError("malformed", f"{word}: bytes must be a positive integer", source=where)
        if not isinstance(snapshot, str) or not snapshot.strip():
            raise LexiconError("malformed", f"{word}: no snapshot", source=where)
        file = path.parent / f"{word}.jsonl"
        verify_file(file, sha, size, sid)
        src = {
            "id": sid,
            "name": f"{template['name']}: {word}",
            "url": url,
            "version": snapshot.strip(),
            "sha256": sha,
            "licence": template["licence"],
            "attribution": template["attribution"],
            "notice": template.get("notice"),
            "notice_files": template.get("notice_files"),
            "provider": "kaikki",
        }
        if template.get("coverage"):
            src["coverage"] = template["coverage"]
        out.append((src, file))
    return sorted(out, key=lambda pair: pair[0]["id"])


def read_notices(entry: dict, notice_dir: Path) -> list[dict]:
    """The source's complete notices: the inline `notice`, then each `notice_files` file verbatim, which must match
    its pinned `sha256` and contain its `marker` (so a changed or wrong file fails here, not in a reader's hands)."""
    out = []
    if isinstance(entry.get("notice"), str) and entry["notice"].strip():
        out.append({"title": "Notice", "text": entry["notice"], "file": None, "sha256": None})
    for item in entry.get("notice_files") or []:
        path = notice_dir / item["file"]
        if not path.is_file():
            raise LexiconError("missing", f"notice file {path} not found", source=entry["id"])
        with path.open("rb") as handle:
            data = handle.read(MAX_NOTICE_BYTES + 1)
        if len(data) > MAX_NOTICE_BYTES:
            raise LexiconError("bound", f"notice file {path} is over {MAX_NOTICE_BYTES} bytes", source=entry["id"])
        actual = hashlib.sha256(data).hexdigest()
        if actual != item.get("sha256"):
            raise LexiconError("hash", f"notice file {path}: sha256 {actual}, expected {item.get('sha256')}",
                               source=entry["id"])
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError as error:
            raise LexiconError("malformed", f"notice file {path} is not UTF-8", source=entry["id"]) from error
        if item["marker"] not in text:
            raise LexiconError("licence", f"notice file {path} lacks {item['marker']!r}", source=entry["id"])
        out.append({"title": item["file"], "text": text, "file": item["file"], "sha256": actual})
    return out


# --- CMUdict --------------------------------------------------------------------------------------------------


def check_arpabet(phones: list[str]) -> str | None:
    """None if every phone is one of CMUdict's 39 with a well-placed stress digit, else the reason."""
    for phone in phones:
        base = phone.rstrip("012")
        stress = phone[len(base):]
        if base in ARPABET_VOWELS:
            if len(stress) != 1:
                return f"vowel {phone!r} needs exactly one stress digit"
        elif base in ARPABET_CONSONANTS:
            if stress:
                return f"consonant {phone!r} carries stress"
        else:
            return f"unknown phone {phone!r}"
    return None


def parse_cmudict(lines: Iterable[str], source: str) -> Iterator[dict]:
    """CMUdict lines to ARPAbet pronunciation records, one per variant, with no part of speech.

    `word(2)` names a variant of `word`; `;;;` lines and `#` comments are dropped. An unknown phone, a misplaced
    stress digit, a variant index under 2, a control character or a line with no phones is `malformed`.
    """
    for number, raw in enumerate(lines, 1):
        line = check_line(raw, source, number)
        if line.startswith(";;;"):
            continue
        text = line.split("#", 1)[0].strip()
        if not text:
            continue
        parts = text.split()
        if len(parts) < 2:
            raise LexiconError("malformed", "a word with no phones", source=source, line=number)
        word = parts[0]
        variant = re.fullmatch(r"(.+)\((\d+)\)", word)
        if variant:
            if int(variant.group(2)) < 2:
                raise LexiconError("malformed", f"variant index under 2 in {word!r}", source=source, line=number)
            word = variant.group(1)
        if has_control(word):
            raise LexiconError("malformed", "control character in a word", source=source, line=number)
        phones = parts[1:]
        problem = check_arpabet(phones)
        if problem:
            raise LexiconError("malformed", problem, source=source, line=number)
        yield {"type": "pronunciation", "word": word, "system": "arpabet", "phonemes": phones, "source": source}


# --- Open English Wordnet -------------------------------------------------------------------------------------


def read_oewn_zip(path: Path, source: str) -> list[tuple[str, object]]:
    """The zip's `entries-*.json` documents, by name. Synset files (definitions, examples) are never opened."""
    docs = []
    names: set[str] = set()
    try:
        with zipfile.ZipFile(path) as archive:
            for info in sorted(archive.infolist(), key=lambda i: i.filename):
                name = PurePosixPath(info.filename).name
                if info.is_dir() or not OEWN_ENTRIES.fullmatch(name):
                    continue
                if name in names:
                    raise LexiconError("malformed", f"{name} appears twice", source=source)
                names.add(name)
                if info.file_size > MAX_ZIP_MEMBER_BYTES:
                    raise LexiconError("bound", f"{name} is over {MAX_ZIP_MEMBER_BYTES} bytes", source=source)
                with archive.open(info) as member:
                    data = member.read(MAX_ZIP_MEMBER_BYTES + 1)
                if len(data) > MAX_ZIP_MEMBER_BYTES:
                    raise LexiconError("bound", f"{name} is over {MAX_ZIP_MEMBER_BYTES} bytes", source=source)
                try:
                    docs.append((name, json.loads(data.decode("utf-8"))))
                except (UnicodeDecodeError, json.JSONDecodeError) as error:
                    raise LexiconError("malformed", f"{name}: {error}", source=source) from error
    except zipfile.BadZipFile as error:
        raise LexiconError("malformed", f"not a zip: {error}", source=source) from error
    if not docs:
        raise LexiconError("version", "no entries-*.json in the zip", source=source)
    return docs


def parse_oewn_entries(docs: Iterable[tuple[str, object]], source: str) -> list[dict]:
    """OEWN `entries-*.json` documents `(file name, parsed JSON)` to IPA pronunciation and derivation records.

    Documents with other names are skipped unread. Each pronunciation keeps its entry's part of speech and its
    `variety` as the dialect, as one whole transcription. A sense's `derivation` targets become derivation
    records: OEWN gives no direction, so the pair is written in alphabetical order and its `base` and `derived`
    are unoriented endpoints, not a claim of which word is the base; the kind is `conversion` when the spelling
    is the same and `other` otherwise, and a conversion's endpoints are just as unoriented (record noun -> verb
    is only the alphabetical order of the parts of speech). Antonyms, the untagged `form` lists and every other relation are not read.
    A numbered entry key (`n-1`) is a further lexeme of its base POS; every one is read in full. An unknown entry
    key, a sense id declared under two words or parts of speech, or a derivation to a sense no entry declares
    is `malformed`.
    """
    senses: dict[str, tuple[str, str]] = {}
    links: list[tuple[tuple[str, str], str, str]] = []
    out: list[dict] = []
    for name, doc in docs:
        if not OEWN_ENTRIES.fullmatch(name):
            continue
        where = f"{source}/{name}"
        if not isinstance(doc, dict):
            raise LexiconError("malformed", "not an object", source=where)
        for lemma, by_pos in doc.items():
            if not isinstance(by_pos, dict) or not lemma:
                raise LexiconError("malformed", f"entry {lemma!r} is not an object", source=where)
            for code, entry in by_pos.items():
                key = OEWN_ENTRY_KEY.fullmatch(code) if isinstance(code, str) else None
                if key is None:
                    raise LexiconError("malformed", f"{lemma!r}: unknown part of speech {code!r}", source=where)
                if not isinstance(entry, dict):
                    raise LexiconError("malformed", f"{lemma!r}/{code}: not an object", source=where)
                pos = OEWN_POS[key.group(1)]
                for pron in entry.get("pronunciation") or []:
                    value = pron.get("value") if isinstance(pron, dict) else None
                    if not isinstance(value, str) or not value.strip():
                        raise LexiconError("malformed", f"{lemma!r}: pronunciation without a value", source=where)
                    record = {
                        "type": "pronunciation", "word": lemma, "pos": pos, "system": "ipa",
                        "phonemes": [value.strip()], "source": source,
                    }
                    variety = pron.get("variety")
                    if isinstance(variety, str) and variety.strip():
                        record["dialect"] = variety.strip()
                    out.append(record)
                sense_list = entry.get("sense") or []
                if not isinstance(sense_list, list):
                    raise LexiconError("malformed", f"{lemma!r}/{code}: sense is not a list", source=where)
                for sense in sense_list:
                    sid = sense.get("id") if isinstance(sense, dict) else None
                    if not isinstance(sid, str) or not sid:
                        raise LexiconError("malformed", f"{lemma!r}: a sense without an id", source=where)
                    if senses.setdefault(sid, (lemma, pos)) != (lemma, pos):
                        raise LexiconError("malformed", f"sense {sid!r} declared twice", source=where)
                    targets = sense.get("derivation") or []
                    if not isinstance(targets, list):
                        raise LexiconError("malformed", f"{sid!r}: derivation is not a list", source=where)
                    for target in targets:
                        if not isinstance(target, str):
                            raise LexiconError("malformed", f"{sid!r}: a derivation target is not a string", source=where)
                        links.append(((lemma, pos), target, where))
    for here, target, where in links:
        there = senses.get(target)
        if there is None:
            raise LexiconError("malformed", f"derivation to undeclared sense {target!r}", source=where)
        if here == there:
            continue
        (base, base_pos), (derived, derived_pos) = sorted([here, there], key=lambda p: (nfc(p[0]), p[1]))
        out.append(
            {
                "type": "derivation", "base": base, "basePos": base_pos, "derived": derived,
                "derivedPos": derived_pos, "kind": "conversion" if nfc(base) == nfc(derived) else "other",
                "source": source,
            }
        )
    return out


# --- etymology-db ---------------------------------------------------------------------------------------------


class EtymologyGraph:
    """The ancestry graph parsed from etymology-db: node ids are `ety:<term_id>`."""

    def __init__(self) -> None:
        self.nodes: dict[str, tuple[str, str]] = {}
        self.heads: dict[str, str] = {}
        self.parents: dict[str, set[tuple[str, str]]] = {}
        self.derivations: list[dict] = []
        self.skipped: Counter[str] = Counter()
        self.samples: dict[str, list[dict]] = {}

    def skip(self, reason: str, row: _Row | None = None) -> None:
        record_skip(self.skipped, self.samples, reason, None if row is None else {"line": row.line, "word": row.term})

    def node(self, node_id: str, language: str, form: str) -> None:
        value = (sys.intern(language), form)
        current = self.nodes.get(node_id)
        if current is None or value < current:
            self.nodes[node_id] = value

    def edge(self, child: str, parent: str, relation: str) -> None:
        if child == parent:
            self.skip("self-edge")
            return
        self.parents.setdefault(child, set()).add((parent, relation))


class _Row:
    __slots__ = ("line", "term_id", "lang", "term", "reltype", "rid", "rlang", "rterm", "tag", "parent", "ppos", "children")

    def __init__(self, line: int, values: list[str]):
        self.line = line
        (self.term_id, self.lang, self.term, self.reltype, self.rid, self.rlang, self.rterm, _position, self.tag,
         self.parent, self.ppos) = values
        self.children: list[tuple[int, int, _Row]] = []


def _ety_rows(lines: Iterable[str], source: str) -> Iterator[_Row]:
    """The rows of an etymology-db CSV, with the field limit raised for this read only: the limit is the process's,
    so it is restored however the generator ends (found by the audit, 2026-10-24)."""
    previous_limit = csv.field_size_limit()
    csv.field_size_limit(MAX_CSV_FIELD_BYTES)
    try:
        reader = csv.reader(lines)
        try:
            header = next(reader)
        except StopIteration:
            raise LexiconError("malformed", "empty file", source=source, line=1) from None
        except csv.Error as error:
            raise LexiconError("malformed", str(error), source=source, line=1) from error
        if sorted(header) != sorted(ETY_COLUMNS) or len(header) != len(ETY_COLUMNS):
            raise LexiconError("version", f"unexpected columns {header}", source=source, line=1)
        order = [header.index(name) for name in ETY_COLUMNS]
        while True:
            try:
                values = next(reader)
            except StopIteration:
                return
            except csv.Error as error:
                kind = "bound" if "field larger" in str(error) else "malformed"
                raise LexiconError(kind, str(error), source=source, line=reader.line_num) from error
            if len(values) != len(ETY_COLUMNS):
                raise LexiconError(
                    "malformed", f"{len(values)} fields, expected {len(ETY_COLUMNS)}", source=source,
                    line=reader.line_num,
                )
            yield _Row(reader.line_num, [values[i] for i in order])
    finally:
        csv.field_size_limit(previous_limit)


def parse_etymology_csv(lines: Iterable[str], source: str, *, english: str = ETY_ENGLISH) -> EtymologyGraph:
    """etymology-db CSV lines to an `EtymologyGraph` of explicit ancestry.

    Rows come in contiguous blocks per `term_id`; a row's `parent_tag` must name a group of its own block
    (`malformed` otherwise: the file is not in the order this reader relies on). Within a block:

    - a top-level ancestry row is an edge from the term to the related term;
    - a `group_derived_root` is a chain: its ancestry children, in `parent_position` order, are successive
      steps, each edge from the previous step's node(s); a nested `group_related_root` is one step of
      alternatives; other children (related, affix groups) are not steps. A step that gives no node (an ancestry
      row without id, language or form, a related group none of whose ancestry rows does, or a nested derived
      group, which is not read) breaks the chain: nothing joins the steps either side of it, and the break is
      counted. The steps after it still link to one another, but no English head reaches them through this chain;
    - a top-level `group_related_root` gives alternatives directly under the term;
    - `has_root` anywhere is an edge from the term to its root, relation `root`, never a step;
    - English `*_with_root` rows to an English base are modern derivations (`kind: other`);
    - affix, cognate, doublet and "related" rows give nothing.

    An unknown `reltype` fails after the whole file is read, with every unknown type and its count.
    """
    graph = EtymologyGraph()
    unknown: Counter[str] = Counter()
    block: list[_Row] = []
    for row in _ety_rows(lines, source):
        if block and row.term_id != block[0].term_id:
            _ety_block(block, graph, source, english, unknown)
            block = []
        block.append(row)
    if block:
        _ety_block(block, graph, source, english, unknown)
    if unknown:
        listed = ", ".join(f"{name} ({count})" for name, count in sorted(unknown.items()))
        raise LexiconError("version", f"unknown relation types: {listed}", source=source)
    return graph


def _ety_block(rows: list[_Row], graph: EtymologyGraph, source: str, english: str, unknown: Counter[str]) -> None:
    head = "ety:" + rows[0].term_id
    groups: dict[str, _Row] = {}
    for row in rows:
        known = row.reltype in ETY_ANCESTRY or row.reltype in ETY_ROOT or row.reltype in ETY_WITH_ROOT
        if not (known or row.reltype in ETY_GROUP or row.reltype in ETY_DROPPED):
            unknown[row.reltype] += 1
        if row.reltype in ETY_GROUP:
            if not row.tag:
                raise LexiconError("malformed", "a group row without group_tag", source=source, line=row.line)
            if row.tag in groups:
                raise LexiconError("malformed", f"group {row.tag} declared twice", source=source, line=row.line)
            groups[row.tag] = row
    top: list[_Row] = []
    for row in rows:
        if not row.parent:
            top.append(row)
            continue
        group = groups.get(row.parent)
        if group is None:
            raise LexiconError(
                "malformed", f"parent_tag {row.parent} names no group of term {row.term_id}", source=source, line=row.line
            )
        try:
            position = int(row.ppos)
        except ValueError:
            raise LexiconError("malformed", f"parent_position {row.ppos!r}", source=source, line=row.line) from None
        group.children.append((position, row.line, row))
    for group in groups.values():
        group.children.sort(key=lambda item: (item[0], item[1]))
    if not rows[0].lang or not rows[0].term.strip():
        graph.skip("term without language or form", rows[0])
        return
    if rows[0].lang == english:
        graph.heads[head] = rows[0].term
    graph.node(head, rows[0].lang, rows[0].term)
    _ety_items(top, head, graph, source, english, chain=False)


def _ety_target(row: _Row, graph: EtymologyGraph) -> str | None:
    form = strip_gloss(row.rterm.strip())
    if not row.rid or not form or not row.rlang:
        graph.skip("ancestry row without related id, language or form", row)
        return None
    node = "ety:" + row.rid
    graph.node(node, row.rlang, form)
    return node


def _ety_side(row: _Row, head: str, graph: EtymologyGraph, source: str, english: str) -> bool:
    """Handle a row that is never a chain step; True if it was one of those."""
    if row.reltype in ETY_ROOT:
        target = _ety_target(row, graph)
        if target:
            graph.edge(head, target, "root")
        return True
    if row.reltype in ETY_WITH_ROOT:
        base = strip_gloss(row.rterm.strip())
        if row.lang == english and row.rlang == english and base and base != row.term:
            graph.derivations.append(
                {"type": "derivation", "base": base, "derived": row.term, "kind": "other", "source": source}
            )
        return True
    return False


def _ety_members(
    group: _Row, head: str, graph: EtymologyGraph, source: str, english: str
) -> tuple[list[tuple[str, str]], bool]:
    """A related group's alternatives: (node, relation) for each ancestry child, and whether it had any ancestry
    child at all; roots and families handled."""
    members = []
    ancestry = False
    for _, _, child in group.children:
        if _ety_side(child, head, graph, source, english):
            continue
        if child.reltype in ETY_ANCESTRY:
            ancestry = True
            target = _ety_target(child, graph)
            if target:
                members.append((target, ETY_ANCESTRY[child.reltype]))
        elif child.reltype in ETY_GROUP:
            graph.skip(f"{child.reltype} inside group_related_root", child)
    return members, ancestry


def _ety_items(items: list[_Row], head: str, graph: EtymologyGraph, source: str, english: str, *, chain: bool) -> None:
    previous = [head]
    for row in items:
        if _ety_side(row, head, graph, source, english):
            continue
        step: list[tuple[str, str]] = []
        # A row that is a step of the chain, whether or not it gives a node.
        is_step = False
        if row.reltype in ETY_ANCESTRY:
            is_step = True
            target = _ety_target(row, graph)
            if target:
                step = [(target, ETY_ANCESTRY[row.reltype])]
        elif row.reltype == "group_related_root":
            step, is_step = _ety_members(row, head, graph, source, english)
        elif row.reltype == "group_derived_root":
            if not chain:
                _ety_items([child for _, _, child in row.children], head, graph, source, english, chain=True)
                continue
            graph.skip("group_derived_root inside group_derived_root", row)
            is_step = True
        elif row.reltype == "group_affix_root":
            _ety_items_sides(row, head, graph, source, english)
            continue
        if not step:
            if chain and is_step:
                # Never join the steps either side of one that gave nothing: that edge would be invented.
                graph.skip("ancestry chain broken at a skipped step", row)
                previous = []
            continue
        for parent in previous:
            for node, relation in step:
                graph.edge(parent, node, relation)
        if chain:
            previous = [node for node, _ in step]


def _ety_items_sides(group: _Row, head: str, graph: EtymologyGraph, source: str, english: str) -> None:
    """An affix group gives no ancestry; only its roots and explicit English derivations are kept."""
    for _, _, child in group.children:
        _ety_side(child, head, graph, source, english)


def etymology_records(graph: EtymologyGraph, source: str, *, max_depth: int = MAX_DEPTH) -> list[dict]:
    """The graph as origin and etymon records, kept to what English heads reach within `max_depth` edges, plus the
    graph's derivation records. `uncertain` is false: etymology-db carries no uncertainty."""
    depth: dict[str, int] = {}
    frontier = sorted(head for head in graph.heads if head in graph.parents)
    for head in frontier:
        depth[head] = 0
    out: list[dict] = []
    level = 0
    while frontier and level < max_depth:
        following = []
        for child in frontier:
            for parent, relation in sorted(graph.parents.get(child, ())):
                out.append(
                    {"type": "etymon", "child": child, "parent": parent, "relation": relation, "uncertain": False,
                     "source": source}
                )
                if parent not in depth:
                    depth[parent] = level + 1
                    following.append(parent)
        frontier = sorted(following)
        level += 1
    for node in sorted(depth):
        language, form = graph.nodes[node]
        record = {"type": "origin", "id": node, "language": language, "form": form}
        if node in graph.heads:
            record["word"] = graph.heads[node]
        out.append(record)
    out.extend(graph.derivations)
    return out


# --- MorphyNet ------------------------------------------------------------------------------------------------


def _tsv(lines: Iterable[str], source: str, columns: int) -> Iterator[tuple[int, list[str]]]:
    for number, raw in enumerate(lines, 1):
        line = check_line(raw, source, number)
        if not line.strip():
            continue
        fields = line.split("\t")
        if len(fields) != columns:
            raise LexiconError("malformed", f"{len(fields)} fields, expected {columns}", source=source, line=number)
        yield number, fields


def parse_morphynet_inflection(
    lines: Iterable[str],
    source: str,
    unknown: Counter[str] | None = None,
    *,
    skipped: Counter[str] | None = None,
    samples: dict[str, list[dict]] | None = None,
) -> Iterator[dict]:
    """MorphyNet `lemma, form, features, segmentation` lines to form records.

    The features' first item is the part of speech (`N`, `V`, `ADJ`, `ADV`); the rest, across `|`-separated
    morphemes and `;`-joined features, are the tags, verbatim and in order. A form equal to its lemma (the
    `-` segmentation rows) needs no record. A row in `MORPHYNET_INFL_KNOWN_MALFORMED` is counted in `skipped`,
    its source line kept in `samples` (and raised as `malformed` at once when no counter is given). An unknown
    part of speech is counted in `unknown` (and raised as `version` at once when no counter is given).
    """
    for number, fields in _tsv(lines, source, 4):
        if tuple(fields) in MORPHYNET_INFL_KNOWN_MALFORMED:
            if skipped is None:
                raise LexiconError("malformed", "a known malformed quoted row", source=source, line=number)
            record_skip(skipped, samples, "known malformed quoted row", {"line": number})
            continue
        lemma, form, features, _segmentation = fields
        if not lemma or not form or not features:
            raise LexiconError("malformed", "an empty field", source=source, line=number)
        items = [item for part in features.split("|") for item in part.split(";")]
        code, tags = items[0], []
        for tag in items[1:]:
            if tag and tag not in tags:
                tags.append(tag)
        if code not in MORPHYNET_INFL_POS:
            if unknown is None:
                raise LexiconError("version", f"unknown part of speech {code!r}", source=source, line=number)
            unknown[f"inflection POS {code}"] += 1
            continue
        if form == lemma or not tags:
            continue
        yield {"type": "form", "form": form, "lemma": lemma, "pos": MORPHYNET_INFL_POS[code], "tags": tags,
               "source": source}


def morphynet_attaches(base: str, derived: str, affix: str, kind: str) -> bool:
    """Whether `derived` is `base` with `affix` attached, compared case-folded.

    The rules are deliberately conservative: a False is not a verdict that the row is wrong. Ordinary
    allomorphy (possible + ity -> possibility, conclude + sion -> conclusion, in + legal -> illegal) is not
    modelled and gives False, as does a nonsense row (run -> ember). No rule is guessed to admit either.

    A prefix attaches as `affix + base` or `affix + "-" + base` (re-record). A suffix attaches literally
    (`record + able`) or through one of three spelling rules, and no other:

    - silent-e drop: `possible + ly` -> possibly (a final `le` meets the `l` of `ly`), `connote + ation`;
    - y to i after a consonant, unless the suffix starts with `i`: `happy + ness` -> happiness;
    - doubling of a final single consonant (not w, x or y) after a single vowel, before a suffix starting with a
      vowel or `y`: `run + er` -> runner, `run + y` -> runny.
    """
    base, derived, affix = base.casefold(), derived.casefold(), affix.casefold()
    if not base or not affix:
        return False
    if kind == "prefix":
        return derived in (affix + base, f"{affix}-{base}")
    if derived == base + affix:
        return True
    if base.endswith("e") and derived == base[:-1] + affix:
        return True
    if base.endswith("le") and affix.startswith("l") and derived == base[:-2] + affix:
        return True
    if (
        len(base) >= 2 and base.endswith("y") and base[-2] not in MORPHYNET_VOWELS and not affix.startswith("i")
        and derived == base[:-1] + "i" + affix
    ):
        return True
    last = base[-1]
    return (
        len(base) >= 2 and last.isalpha() and last not in MORPHYNET_VOWELS and last not in "wxy"
        and base[-2] in MORPHYNET_VOWELS and (len(base) == 2 or base[-3] not in MORPHYNET_VOWELS)
        and (affix[0] in MORPHYNET_VOWELS or affix[0] == "y")
        and derived == base + last + affix
    )


def parse_morphynet_derivation(
    lines: Iterable[str],
    source: str,
    unknown: Counter[str] | None = None,
    *,
    skipped: Counter[str],
    samples: dict[str, list[dict]] | None = None,
) -> Iterator[dict]:
    """MorphyNet `source, target, source POS, target POS, morpheme, type` lines to derivation records.

    POS codes `N V J R` become noun, verb, adj, adv; `type` is prefix or suffix, and the morpheme is written as an
    affix of that type (`im` prefix -> `im-`, `ly` suffix -> `-ly`). A row is kept only when its morpheme
    attaches to its base (`morphynet_attaches`), so a row such as run -> ember (`umb`, prefix) never joins two
    words. Rows left out are counted in `skipped` by reason: the undocumented POS `U`, an empty morpheme, a
    spelling change the attachment rules do not model (which covers real allomorphs and nonsense rows alike), a
    word derived from itself. `samples`, when given, keeps the first `MAX_SKIPPED_SAMPLES` rows of each reason
    as metadata: line, both words, both POS codes and the morpheme verbatim, and the type. Any other unknown code
    is counted in `unknown` (or raised as `version` at once when no counter is given).
    """
    for number, (base, derived, base_code, derived_code, morpheme, kind) in _tsv(lines, source, 6):
        if not base or not derived:
            raise LexiconError("malformed", "an empty word", source=source, line=number)
        sample = {"line": number, "base": base, "derived": derived, "basePos": base_code, "derivedPos": derived_code,
                  "affix": morpheme, "kind": kind}
        codes = (base_code, derived_code)
        problems = [
            f"derivation POS {c}" for c in codes if c not in MORPHYNET_DERI_POS and c not in MORPHYNET_UNDOCUMENTED_POS
        ]
        if kind not in MORPHYNET_KINDS:
            problems.append(f"derivation type {kind}")
        if problems:
            if unknown is None:
                raise LexiconError("version", "; ".join(problems), source=source, line=number)
            unknown.update(problems)
            continue
        if any(c in MORPHYNET_UNDOCUMENTED_POS for c in codes):
            record_skip(skipped, samples, "undocumented POS U", sample)
            continue
        if base == derived:
            record_skip(skipped, samples, "derived word equals its base", sample)
            continue
        affix = morpheme.strip().strip("-")
        if not affix:
            record_skip(skipped, samples, "empty morpheme", sample)
            continue
        if not morphynet_attaches(base, derived, affix, kind):
            record_skip(skipped, samples, f"{kind} spelling change not modelled", sample)
            continue
        yield {
            "type": "derivation", "base": base, "basePos": MORPHYNET_DERI_POS[base_code], "derived": derived,
            "derivedPos": MORPHYNET_DERI_POS[derived_code], "kind": kind, "source": source,
            "affix": f"{affix}-" if kind == "prefix" else f"-{affix}",
        }


# --- Kaikki ---------------------------------------------------------------------------------------------------


def _strings(value: object) -> list[str]:
    return [item for item in value if isinstance(item, str)] if isinstance(value, list) else []


def _affix_parts(template: dict) -> list[str] | None:
    """The parts of an English morphology template, affixes hyphenated; None when not one."""
    name, args = template.get("name"), template.get("args")
    if name not in KAIKKI_AFFIX_TEMPLATES or not isinstance(args, dict) or args.get("1") != "en":
        return None
    numbered = []
    index = 2
    while isinstance(args.get(str(index)), str):
        numbered.append(args[str(index)].split("<", 1)[0].strip())
        index += 1
    if name in ("prefix", "pre") and len(numbered) >= 2:
        return [numbered[0].rstrip("-") + "-"] + numbered[1:]
    if name in ("suffix", "suf") and len(numbered) >= 2:
        return numbered[:1] + ["-" + part.lstrip("-") for part in numbered[1:]]
    if name in ("confix", "con") and len(numbered) >= 2:
        first, last = numbered[0].rstrip("-") + "-", "-" + numbered[-1].lstrip("-")
        return [first] + numbered[1:-1] + [last]
    return numbered


def _kaikki_derivations(word: str, pos: str, templates: object, source: str) -> Iterator[dict]:
    for template in templates if isinstance(templates, list) else []:
        if not isinstance(template, dict):
            continue
        parts = [part for part in (_affix_parts(template) or []) if part]
        if not parts or any(KAIKKI_FOREIGN_PART.match(part) for part in parts):
            continue
        affixes = [p for p in parts if p.startswith("-") or p.endswith("-")]
        bases = [p for p in parts if p not in affixes]
        if not bases:
            continue
        if len(bases) == 1 and len(affixes) == 1 and not (affixes[0].startswith("-") and affixes[0].endswith("-")):
            kind, affix = ("prefix" if affixes[0].endswith("-") else "suffix"), affixes[0]
        elif not affixes:
            kind, affix = "compound", None
        else:
            kind, affix = "other", None
        for base in bases:
            if base == word:
                continue
            record = {"type": "derivation", "base": base, "derived": word, "derivedPos": pos, "kind": kind,
                      "source": source}
            if affix:
                record["affix"] = affix
            yield record


def parse_kaikki_jsonl(lines: Iterable[str], source: str, *, lang_code: str = "en") -> Iterator[dict]:
    """Kaikki / Wiktextract JSONL lines to pronunciation, form and derivation records for `lang_code` entries.

    Reads `word`, `pos`, `sounds[].ipa` (whole, with its tags; a `noun`/`verb`/... tag sets the part of speech,
    the other tags are the dialect), `forms[]` less `KAIKKI_FORM_SKIP`, `senses[].form_of` only where the sense
    links that very lemma (with the sense's grammatical tags), and the English morphology templates. Glosses,
    examples, `etymology_text`, expansions and the ancestry templates are never read: etymology-db supplies
    ancestry with its chains. A line that is not a JSON object, or an entry without `word` or `pos`, is
    `malformed`.
    """
    for number, raw in enumerate(lines, 1):
        line = check_line(raw, source, number)
        if not line.strip():
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError as error:
            raise LexiconError("malformed", f"not JSON: {error.msg}", source=source, line=number) from None
        if not isinstance(entry, dict):
            raise LexiconError("malformed", "not an object", source=source, line=number)
        if entry.get("lang_code") != lang_code:
            continue
        word, pos = entry.get("word"), entry.get("pos")
        if not isinstance(word, str) or not word or not isinstance(pos, str) or not pos:
            raise LexiconError("malformed", "an entry without word or pos", source=source, line=number)
        for sound in entry.get("sounds") or []:
            ipa = sound.get("ipa") if isinstance(sound, dict) else None
            if not isinstance(ipa, str) or not ipa.strip():
                continue
            tags = _strings(sound.get("tags"))
            named = sorted({KAIKKI_SOUND_POS[t] for t in tags if t in KAIKKI_SOUND_POS})
            record = {"type": "pronunciation", "word": word, "system": "ipa", "phonemes": [ipa.strip()],
                      "source": source}
            if len(named) == 1:
                record["pos"] = named[0]
            elif not named:
                record["pos"] = pos
            dialect = [t for t in tags if t not in KAIKKI_SOUND_POS]
            if dialect:
                record["dialect"] = ", ".join(dialect)
            yield record
        for form in entry.get("forms") or []:
            if not isinstance(form, dict):
                continue
            text, tags = form.get("form"), _strings(form.get("tags"))
            if not isinstance(text, str) or not text.strip() or text == word or not tags:
                continue
            if any(tag in KAIKKI_FORM_SKIP for tag in tags):
                continue
            yield {"type": "form", "form": text, "lemma": word, "pos": pos, "tags": tags, "source": source}
        for sense in entry.get("senses") or []:
            if not isinstance(sense, dict) or not isinstance(sense.get("form_of"), list):
                continue
            tags = [t for t in _strings(sense.get("tags")) if t != "form-of"]
            if not tags or any(tag in KAIKKI_FORM_SKIP for tag in tags):
                continue
            linked = {link[0] for link in sense.get("links") or [] if isinstance(link, list) and link
                      and isinstance(link[0], str)}
            for target in sense["form_of"]:
                lemma = target.get("word") if isinstance(target, dict) else None
                if isinstance(lemma, str) and lemma in linked and lemma != word:
                    yield {"type": "form", "form": word, "lemma": lemma, "pos": pos, "tags": tags, "source": source}
        yield from _kaikki_derivations(word, pos, entry.get("etymology_templates"), source)


# --- records and the pack -------------------------------------------------------------------------------------


def validate_record(record: object) -> dict:
    """The record checked against the Rust loader's rules and NFC-normalised.

    An unknown type or field, a missing field, a wrong value type, an empty string, a control character, an
    invalid phoneme, kind or relation, or an invalid `stem` (`_stem`) is `malformed`; a content key is `content`;
    a string over 256 scalars or a list over 64 items is `bound` (never truncated).
    """
    if not isinstance(record, dict):
        raise LexiconError("malformed", "a record is not an object")
    kind = record.get("type")
    if kind not in RECORD_FIELDS:
        raise LexiconError("malformed", f"unknown record type {kind!r}")
    required, optional = RECORD_FIELDS[kind]
    out: dict = {"type": kind}
    for key, value in record.items():
        if key == "type":
            continue
        if key in CONTENT_KEYS:
            raise LexiconError("content", f"{kind} carries {key!r}")
        if key not in required and key not in optional:
            raise LexiconError("malformed", f"{kind} has unknown field {key!r}")
        if value is None:
            if key in required:
                raise LexiconError("malformed", f"{kind}.{key} is null")
            continue
        if key == "uncertain":
            if not isinstance(value, bool):
                raise LexiconError("malformed", "uncertain is not a bool")
            out[key] = value
        elif key == "stem":
            out[key] = _stem(value)
        elif key in LIST_FIELDS:
            if not isinstance(value, list) or not value:
                raise LexiconError("malformed", f"{kind}.{key} is not a non-empty list")
            if len(value) > MAX_LIST_ITEMS:
                raise LexiconError("bound", f"{kind}.{key} has {len(value)} items, over {MAX_LIST_ITEMS}")
            out[key] = [_string(kind, key, item) for item in value]
        else:
            out[key] = _string(kind, key, value)
    missing = required - out.keys()
    if missing:
        raise LexiconError("malformed", f"{kind} lacks {sorted(missing)}")
    if kind == "pronunciation":
        if out["system"] not in PHONE_SYSTEMS:
            raise LexiconError("malformed", f"unknown phone system {out['system']!r}")
        if out["system"] == "arpabet":
            problem = check_arpabet(out["phonemes"])
            if problem:
                raise LexiconError("malformed", problem)
    elif kind == "derivation" and out["kind"] not in FAMILY_KINDS:
        raise LexiconError("malformed", f"unknown derivation kind {out['kind']!r}")
    elif kind == "etymon" and out["relation"] not in ETYMON_RELATIONS:
        raise LexiconError("malformed", f"unknown relation {out['relation']!r}")
    return out


def _string(kind: str, key: str, value: object) -> str:
    if not isinstance(value, str):
        raise LexiconError("malformed", f"{kind}.{key} is not a string")
    text = nfc(value)
    if not text.strip():
        raise LexiconError("malformed", f"{kind}.{key} is empty")
    if has_control(text):
        raise LexiconError("malformed", f"{kind}.{key} has a control character")
    if len(text) > MAX_STRING_CHARS:
        raise LexiconError("bound", f"{kind}.{key} has {len(text)} scalars, over {MAX_STRING_CHARS}")
    return text


def _stem(value: object) -> dict:
    """A derivation's stem alignment, checked as the loader's `stem_from` and `Checker::stem` check it: exactly
    `STEM_FIELDS`; each pronunciation a non-empty list of ARPAbet phonemes (over 64 is `bound`); each start and
    end an integer (never a bool) from 0 to 2^32-1 with start < end <= the pronunciation's vowel count; both
    ranges one length. Anything else is `malformed`."""
    if not isinstance(value, dict):
        raise LexiconError("malformed", "derivation.stem is not an object")
    unknown = sorted(set(value) - set(STEM_FIELDS))
    if unknown:
        raise LexiconError("malformed", f"derivation.stem has unknown field {unknown[0]!r}")
    out: dict = {}
    spans = []
    for side in ("base", "derived"):
        key = f"{side}Phonemes"
        phonemes = value.get(key)
        if not isinstance(phonemes, list) or not phonemes:
            raise LexiconError("malformed", f"derivation.stem.{key} is not a non-empty list")
        if len(phonemes) > MAX_LIST_ITEMS:
            raise LexiconError("bound", f"derivation.stem.{key} has {len(phonemes)} items, over {MAX_LIST_ITEMS}")
        clean = [_string("derivation", f"stem.{key}", phone) for phone in phonemes]
        problem = check_arpabet(clean)
        if problem:
            raise LexiconError("malformed", f"derivation.stem.{key}: {problem}")
        out[key] = clean
    for side in ("base", "derived"):
        bounds = []
        for edge in ("Start", "End"):
            key = f"{side}{edge}"
            number = value.get(key)
            if not isinstance(number, int) or isinstance(number, bool) or not 0 <= number <= MAX_U32:
                raise LexiconError("malformed", f"derivation.stem.{key} is not a whole number from 0 to {MAX_U32}")
            out[key] = number
            bounds.append(number)
        start, end = bounds
        vowels = sum(1 for phone in out[f"{side}Phonemes"] if phone.rstrip("012") in ARPABET_VOWELS)
        if not start < end <= vowels:
            raise LexiconError("malformed", f"derivation.stem: the {side} range {start}..{end} is not within its "
                                            f"{vowels} vowels")
        spans.append(end - start)
    if spans[0] != spans[1]:
        raise LexiconError("malformed", f"derivation.stem spans {spans[0]} vowels of the base but {spans[1]} of the "
                                        "derived word")
    return out


def header_source(entry: dict) -> dict:
    """A source as the pack header lists it: every field non-empty and within the loader's string bound, the id
    a `SOURCE_ID` (so within the loader's charset), sha256 64 lowercase hex."""
    out = {}
    for key in SOURCE_FIELDS:
        value = entry.get(key)
        if not isinstance(value, str) or not value.strip():
            raise LexiconError("licence", f"source {entry.get('id')!r} lacks {key}")
        if value.strip().lower() == "pending":
            raise LexiconError("pending", f"source {entry['id']!r}: {key} is pending")
        text = nfc(value)
        if has_control(text):
            raise LexiconError("malformed", f"source {entry['id']!r}: {key} has a control character")
        out[key] = text
    if not SOURCE_ID.fullmatch(out["id"]):
        raise LexiconError("malformed", f"source id {out['id']!r} is not a source id the loader reads "
                                        "(letters, digits and - _ . :)")
    if not SHA256_HEX.fullmatch(out["sha256"]):
        raise LexiconError("malformed", f"source {out['id']!r}: sha256 is not 64 lowercase hex digits")
    if https_host(out["url"]) is None:
        raise LexiconError("malformed", f"source {out['id']!r}: url is not an https address with a host")
    if isinstance(entry.get("coverage"), str) and entry["coverage"].strip():
        coverage = nfc(entry["coverage"])
        if has_control(coverage):
            raise LexiconError("malformed", f"source {out['id']!r}: coverage has a control character")
        out["coverage"] = coverage
    for key, value in out.items():
        if len(value) > MAX_STRING_CHARS:
            raise LexiconError("bound", f"source {out['id']!r}: {key} has {len(value)} scalars, over {MAX_STRING_CHARS}")
    return out


class PackBuilder:
    """Collects records into the pack's one canonical order: by type, then by canonical JSON, de-duplicated.

    `strict` raises on every invalid record; otherwise a record past a loader bound (which the schema cannot
    hold, and which is never truncated) is counted in `rejected` and left out, and any other fault raises.
    """

    def __init__(self, sources: Iterable[dict], *, strict: bool = True):
        self.sources = sorted((header_source(s) for s in sources), key=lambda s: s["id"])
        ids = [s["id"] for s in self.sources]
        if not ids:
            raise LexiconError("licence", "a pack needs at least one source")
        if len(set(ids)) != len(ids):
            raise LexiconError("malformed", "duplicate source id in the header")
        self.ids = frozenset(ids)
        self.strict = strict
        self.lines: dict[str, set[str]] = {kind: set() for kind in RECORD_TYPES}
        self.origins: dict[str, str] = {}
        self.rejected: Counter[str] = Counter()

    def add(self, record: dict, provider: str) -> None:
        try:
            clean = validate_record(record)
        except LexiconError as error:
            if self.strict or error.kind != "bound":
                raise LexiconError(error.kind, str(error), source=provider) from None
            self.rejected[f"{provider}: {record.get('type')} over a loader bound"] += 1
            return
        if "source" in clean and clean["source"] not in self.ids:
            raise LexiconError("licence", f"record names unlisted source {clean['source']!r}", source=provider)
        line = dumps(clean)
        if len(line.encode("utf-8")) + 1 > MAX_LINE_BYTES:
            if self.strict:
                raise LexiconError("bound", f"a {clean['type']} line over {MAX_LINE_BYTES} bytes", source=provider)
            self.rejected[f"{provider}: {clean['type']} line over {MAX_LINE_BYTES} bytes"] += 1
            return
        if clean["type"] == "origin":
            if self.origins.setdefault(clean["id"], line) != line:
                raise LexiconError("malformed", f"origin {clean['id']!r} declared twice, differently", source=provider)
        self.lines[clean["type"]].add(line)

    def header_line(self) -> str:
        if len(self.sources) > MAX_LIST_ITEMS:
            raise LexiconError("bound", f"{len(self.sources)} header sources, over {MAX_LIST_ITEMS}")
        line = dumps(
            {"type": "header", "schema": PACK_SCHEMA, "version": PACK_VERSION, "language": PACK_LANGUAGE,
             "sources": self.sources}
        )
        if len(line.encode("utf-8")) + 1 > MAX_LINE_BYTES:
            raise LexiconError("bound", f"the header is over {MAX_LINE_BYTES} bytes")
        return line

    def counts(self) -> dict[str, int]:
        return {kind: len(self.lines[kind]) for kind in RECORD_TYPES}

    def pack_lines(self) -> list[str]:
        """The whole pack, or `bound` if it is past the loader's record count or total size: a pack the loader
        would refuse is never cut down to fit."""
        total = sum(self.counts().values())
        if total > MAX_RECORDS:
            raise LexiconError("bound", f"{total} records, over {MAX_RECORDS}")
        out = [self.header_line()]
        for kind in RECORD_TYPES:
            out.extend(sorted(self.lines[kind]))
        size = sum(len(line.encode("utf-8")) + 1 for line in out)
        if size > MAX_TOTAL_BYTES:
            raise LexiconError("bound", f"the pack is {size} bytes, over {MAX_TOTAL_BYTES}")
        return out


def pack_lines(sources: Iterable[dict], records: Iterable[dict]) -> list[str]:
    """The pack as JSON lines (no newlines): the header, then the canonical records. Strict: any invalid record
    raises. Byte-identical for the same sources and records in any order."""
    builder = PackBuilder(sources)
    for record in records:
        builder.add(record, "records")
    return builder.pack_lines()


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temp = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(handle, "wb") as out:
            out.write(data)
            out.flush()
            os.fsync(out.fileno())
        os.replace(temp, path)
    except BaseException:
        Path(temp).unlink(missing_ok=True)
        raise


def write_pack(path: Path, lines: list[str]) -> str:
    """Write `lines` newline-terminated as UTF-8 through a temporary file and a rename; return the SHA-256."""
    data = "".join(line + "\n" for line in lines).encode("utf-8")
    atomic_write(path, data)
    return hashlib.sha256(data).hexdigest()


def _fence(text: str) -> str:
    longest = max((len(run) for run in re.findall(r"`+", text)), default=0)
    return "`" * max(3, longest + 1)


def notices_text(pack_name: str, pack_sha256: str, entries: list[tuple[dict, list[dict]]]) -> str:
    """The sidecar: what the pack is, its licence as a whole, and every source's complete notices verbatim."""
    out = [
        f"# Notices for {pack_name}",
        "",
        f"Pack SHA-256: `{pack_sha256}`",
        "",
        "This pack holds linguistic metadata only (pronunciations, inflected forms, derivational links and "
        "etymological ancestry), built by `word_lexicon.py` from the sources below. It adapts ShareAlike "
        "sources, so the pack as a whole is distributed under the Creative Commons Attribution-ShareAlike 4.0 "
        "International licence, https://creativecommons.org/licenses/by-sa/4.0/ (CC BY-SA 3.0 material is "
        "adapted under the later version its section 4(b) permits). Each source keeps its own terms, reproduced "
        "in full below; this file must travel with the pack. The XDict code is licensed separately and does not "
        "cover this pack.",
        "",
    ]
    for source, notices in entries:
        out += [f"## {source['id']}: {source['name']}", ""]
        for key in ("url", "version", "sha256", "licence", "attribution", "coverage"):
            if source.get(key):
                out.append(f"- {key}: {source[key]}")
        out.append("")
        for notice in notices:
            title = notice["title"] if notice["file"] is None else f"{notice['file']} (SHA-256 {notice['sha256']})"
            fence = _fence(notice["text"])
            body = notice["text"] if notice["text"].endswith("\n") else notice["text"] + "\n"
            out += [f"### {title}", "", fence + "text", body + fence, ""]
    return "\n".join(out)


# --- the build ------------------------------------------------------------------------------------------------


def _text_lines(path: Path, source: str) -> Iterator[str]:
    with path.open("r", encoding="utf-8", newline="") as handle:
        try:
            yield from handle
        except UnicodeDecodeError as error:
            raise LexiconError("malformed", f"not UTF-8: {error}", source=source) from error


def _gzip_lines(path: Path, source: str) -> Iterator[str]:
    try:
        with gzip.open(path, "rt", encoding="utf-8", newline="") as handle:
            yield from handle
    except (OSError, EOFError, UnicodeDecodeError) as error:
        raise LexiconError("malformed", f"bad gzip text: {error}", source=source) from error


def _report_skips(report: dict, sid: str, skipped: Counter[str], samples: dict[str, list[dict]]) -> None:
    report["skipped"].update({f"{sid}: {k}": v for k, v in skipped.items()})
    report.setdefault("samples", {}).update({f"{sid}: {k}": v for k, v in samples.items()})


def _parse_provider(entry: dict, path: Path, report: dict) -> Iterator[dict]:
    sid, provider = entry["id"], entry["provider"]
    if provider == "cmudict":
        yield from parse_cmudict(_text_lines(path, sid), sid)
    elif provider == "oewn":
        yield from parse_oewn_entries(read_oewn_zip(path, sid), sid)
    elif provider == "etymology-db":
        graph = parse_etymology_csv(_gzip_lines(path, sid), sid)
        _report_skips(report, sid, graph.skipped, graph.samples)
        yield from etymology_records(graph, sid)
    elif provider in ("morphynet-inflection", "morphynet-derivation"):
        unknown: Counter[str] = Counter()
        skipped: Counter[str] = Counter()
        samples: dict[str, list[dict]] = {}
        if provider == "morphynet-inflection":
            yield from parse_morphynet_inflection(_text_lines(path, sid), sid, unknown, skipped=skipped,
                                                  samples=samples)
        else:
            yield from parse_morphynet_derivation(_text_lines(path, sid), sid, unknown, skipped=skipped,
                                                  samples=samples)
        _report_skips(report, sid, skipped, samples)
        if unknown:
            listed = ", ".join(f"{name} ({count})" for name, count in sorted(unknown.items()))
            raise LexiconError("version", f"unknown codes: {listed}", source=sid)
    elif provider == "kaikki":
        yield from parse_kaikki_jsonl(_text_lines(path, sid), sid)
    else:  # load_manifest admits only PROVIDERS
        raise LexiconError("malformed", f"unknown provider {provider!r}", source=sid)


PROVIDERS = frozenset({"cmudict", "oewn", "etymology-db", "morphynet-inflection", "morphynet-derivation", "kaikki"})


TOOLS_DIR = Path(__file__).resolve().parent


def repository_root(start: Path) -> Path | None:
    for directory in [start, *start.parents]:
        if (directory / ".git").exists():
            return directory
    return None


def refuse_inside_repository(output: Path, start: Path) -> None:
    """`malformed` if `output` lies inside the Git checkout holding `start`; packs stay outside Git."""
    repo = repository_root(start.resolve())
    if repo is not None and output.resolve().is_relative_to(repo.resolve()):
        raise LexiconError("malformed", f"output {output} is inside the repository {repo}; packs stay outside Git")


def build(
    raw_dir: Path,
    output: Path,
    manifest_path: Path,
    *,
    kaikki_receipts: Iterable[Path] = (),
    notice_dir: Path | None = None,
) -> dict:
    """Verify every raw file, parse every provider, write the pack, its notices sidecar and a build report.

    Returns the report: record counts by type and source, records left out for a loader bound, the source rows
    skipped by reason, the first `MAX_SKIPPED_SAMPLES` of each reason as metadata samples, and the SHA-256 of
    each written file.
    """
    notice_dir = notice_dir or raw_dir
    refuse_inside_repository(output, TOOLS_DIR)
    entries = read_manifest(manifest_path)
    jobs: list[tuple[dict, Path]] = []
    kaikki = [e for e in entries if e["provider"] == "kaikki"]
    for entry in entries:
        if entry["provider"] == "kaikki":
            continue
        path = raw_dir / entry["file"]
        verify_file(path, entry["sha256"], entry["bytes"], entry["id"])
        jobs.append((entry, path))
    receipts = list(kaikki_receipts)
    if receipts and not kaikki:
        raise LexiconError("malformed", "--kaikki-input given but the manifest has no kaikki source")
    for receipt in receipts:
        jobs.extend(load_kaikki_receipt(receipt, kaikki[0]))
    sources = [entry for entry, _ in jobs]
    if len({s["id"] for s in sources}) != len(sources):
        raise LexiconError("malformed", "two Kaikki receipts list the same word")
    notices = [(header_source(entry), read_notices(entry, notice_dir)) for entry in sources]
    builder = PackBuilder(sources, strict=False)
    report: dict = {"skipped": Counter(), "samples": {}}
    by_source: dict[str, Counter[str]] = {}
    for entry, path in jobs:
        tally = by_source.setdefault(entry["id"], Counter())
        for record in _parse_provider(entry, path, report):
            builder.add(record, entry["id"])
            tally[record["type"]] += 1
    lines = builder.pack_lines()
    pack_sha = write_pack(output, lines)
    sidecar = output.with_name(output.stem + ".notices.md")
    notice_bytes = notices_text(output.name, pack_sha, notices).encode("utf-8")
    atomic_write(sidecar, notice_bytes)
    result = {
        "pack": str(output),
        "packSha256": pack_sha,
        "notices": str(sidecar),
        "noticesSha256": hashlib.sha256(notice_bytes).hexdigest(),
        "records": builder.counts(),
        "parsedBySource": {sid: dict(sorted(t.items())) for sid, t in sorted(by_source.items())},
        "rejected": dict(sorted(builder.rejected.items())),
        "skipped": dict(sorted(report["skipped"].items())),
        "skippedSamples": dict(sorted(report["samples"].items())),
        "sources": [s["id"] for s in builder.sources],
    }
    atomic_write(output.with_name(output.stem + ".report.json"), (json.dumps(result, indent=2, sort_keys=True) + "\n").encode())
    return result


def main(argv: list[str] | None = None) -> int:
    tools = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    commands = parser.add_subparsers(dest="command", required=True)
    verify = commands.add_parser("verify", help="check the raw files against the manifest's size and SHA-256")
    verify.add_argument("--raw-dir", type=Path, required=True)
    verify.add_argument("--manifest", type=Path, default=tools / "word_lexicon_sources.json")
    make = commands.add_parser("build", help="build the pack, its notices sidecar and a report")
    make.add_argument("--raw-dir", type=Path, required=True, help="directory holding the raw downloads")
    make.add_argument("--output", type=Path, help=f"pack path outside the repository (default <raw-dir>/../pack/{PACK_NAME})")
    make.add_argument("--manifest", type=Path, default=tools / "word_lexicon_sources.json")
    make.add_argument("--kaikki-input", type=Path, action="append", default=[], metavar="RECEIPT",
                      help="a Kaikki receipt JSON; its <word>.jsonl files sit beside it (repeatable)")
    make.add_argument("--notice-dir", type=Path, help="directory holding the notice files (default: --raw-dir)")
    args = parser.parse_args(argv)
    try:
        if args.command == "verify":
            entries = read_manifest(args.manifest)
            for entry in entries:
                if entry["provider"] != "kaikki":
                    verify_file(args.raw_dir / entry["file"], entry["sha256"], entry["bytes"], entry["id"])
                    print(f"ok {entry['id']} {entry['sha256']}")
            return 0
        output = args.output or args.raw_dir.resolve().parent / "pack" / PACK_NAME
        result = build(args.raw_dir, output, args.manifest, kaikki_receipts=args.kaikki_input,
                       notice_dir=args.notice_dir)
    except LexiconError as error:
        print(f"word_lexicon: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
