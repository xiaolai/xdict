"""Tests for `word_lexicon.py`: provider parsing, the `xdict-word-pack` schema, bounds, notices and the build.

Every fixture is authored here in its provider's published shape; none is copied from a source. Content-looking
fields carry `PLACEHOLDER` text that must never reach a pack.
Run: `python3 -I -m unittest discover -s core/xdict-core/tools -p 'test_word_lexicon.py' -v`.
"""

from __future__ import annotations

import contextlib
import csv
import gzip
import hashlib
import io
import json
import re
import tempfile
import unicodedata
import unittest
import zipfile
from collections import Counter
from pathlib import Path
from unittest import mock

import word_lexicon as wl

TOOLS = Path(__file__).resolve().parent
PLACEHOLDER = "PLACEHOLDER-CONTENT"
SRC = {
    "id": "t", "name": "Test source", "url": "https://example.org/t", "version": "1", "sha256": "0" * 64,
    "licence": "MIT", "attribution": "Test attribution",
}
# The Rust loader's source-id charset (`Checker::source_entry` in src/words/lexicon.rs).
LOADER_SOURCE_ID = re.compile(r"[A-Za-z0-9_.:-]+")
SAMPLE_FIELDS = frozenset({"line", "word", "base", "derived", "basePos", "derivedPos", "affix", "kind"})


def of_type(records, kind: str) -> list[dict]:
    return [r for r in records if r["type"] == kind]


def strip(records) -> set[str]:
    """Records as canonical JSON without their source, for set comparison."""
    return {wl.dumps({k: v for k, v in r.items() if k != "source"}) for r in records}


class Raises:
    def assertLexicon(self, kind: str, fn, *args, **kwargs) -> wl.LexiconError:
        with self.assertRaises(wl.LexiconError) as caught:
            result = fn(*args, **kwargs)
            if hasattr(result, "__next__"):
                list(result)
        self.assertEqual(caught.exception.kind, kind, str(caught.exception))
        return caught.exception


# --- CMUdict -------------------------------------------------------------------------------------------------


class CmudictTests(Raises, unittest.TestCase):
    def test_variants_comments_and_phones(self):
        lines = [
            ";;; a header comment\n",
            "record R EH1 K ER0 D\n",
            "record(2) R IH0 K AO1 R D # verb\n",
            "\n",
        ]
        records = list(wl.parse_cmudict(lines, "cmu"))
        self.assertEqual(
            records,
            [
                {"type": "pronunciation", "word": "record", "system": "arpabet",
                 "phonemes": ["R", "EH1", "K", "ER0", "D"], "source": "cmu"},
                {"type": "pronunciation", "word": "record", "system": "arpabet",
                 "phonemes": ["R", "IH0", "K", "AO1", "R", "D"], "source": "cmu"},
            ],
        )
        self.assertTrue(all("pos" not in r and "dialect" not in r for r in records))

    def test_bad_phones_are_malformed(self):
        for line in ("run R AH N\n", "run R AH1 N1\n", "run R AH12 N\n", "run XX1\n", "run\n", "run(1) R AH1 N\n"):
            with self.subTest(line=line):
                error = self.assertLexicon("malformed", wl.parse_cmudict, [line], "cmu")
                self.assertEqual(error.line, 1)

    def test_overlong_source_line_is_bound(self):
        self.assertLexicon("bound", wl.parse_cmudict, ["a " + "B " * (wl.MAX_SOURCE_LINE_BYTES // 2)], "cmu")


# --- Open English Wordnet ------------------------------------------------------------------------------------


def oewn_docs():
    entries = {
        "possible": {
            "a": {
                "pronunciation": [{"value": "ˈpɒsɪbl̩", "variety": "GB"}, {"value": "ˈpɑsəbl̩", "variety": "US"}],
                "sense": [
                    {"id": "possible%3:00:00::", "synset": "1-a", "antonym": ["impossible%3:00:00::"],
                     "derivation": ["possibility%1:26:00::"]},
                ],
            },
        },
        "possibility": {
            "n": {
                "pronunciation": [{"value": "ˌpɒsɪˈbɪliti", "variety": "GB"}],
                "sense": [{"id": "possibility%1:26:00::", "synset": "2-n", "derivation": ["possible%3:00:00::"]}],
            },
        },
        "impossible": {"a": {"sense": [{"id": "impossible%3:00:00::", "synset": "3-a"}]}},
        "record": {
            "n": {"pronunciation": [{"value": "ˈɹɛkɔːd"}],
                  "sense": [{"id": "record%1:10:03::", "derivation": ["record%2:32:00::"]}]},
            "v": {"form": ["recorded"], "pronunciation": [{"value": "ɹɪˈkɔɹd", "variety": "US"}],
                  "sense": [{"id": "record%2:32:00::", "derivation": ["record%1:10:03::"]},
                            {"id": "record%2:32:01::", "derivation": ["record%2:32:00::"]}]},
        },
    }
    synsets = {"1-a": {"definition": [PLACEHOLDER], "example": [PLACEHOLDER], "members": ["possible"]}}
    return [("entries-p.json", entries), ("adj.all.json", synsets)]


class OewnTests(Raises, unittest.TestCase):
    def test_pronunciations_keep_pos_and_variety_whole(self):
        prons = of_type(wl.parse_oewn_entries(oewn_docs(), "oewn"), "pronunciation")
        self.assertIn(
            {"type": "pronunciation", "word": "possible", "pos": "adj", "system": "ipa", "phonemes": ["ˈpɒsɪbl̩"],
             "dialect": "GB", "source": "oewn"},
            prons,
        )
        record = [p for p in prons if p["word"] == "record"]
        self.assertEqual(
            {(p["pos"], p.get("dialect"), p["phonemes"][0]) for p in record},
            {("noun", None, "ˈɹɛkɔːd"), ("verb", "US", "ɹɪˈkɔɹd")},
        )

    def test_derivations_are_unoriented_pairs_and_conversions(self):
        # OEWN links carry no direction: the pair is written in alphabetical order, so `base` here is only an
        # endpoint. possibility is not claimed as the base of possible.
        derivations = of_type(wl.parse_oewn_entries(oewn_docs(), "oewn"), "derivation")
        self.assertEqual(
            strip(derivations),
            {
                wl.dumps({"type": "derivation", "base": "possibility", "basePos": "noun", "derived": "possible",
                          "derivedPos": "adj", "kind": "other"}),
                wl.dumps({"type": "derivation", "base": "record", "basePos": "noun", "derived": "record",
                          "derivedPos": "verb", "kind": "conversion"}),
            },
        )

    def test_synset_files_and_content_are_never_read(self):
        records = wl.parse_oewn_entries(oewn_docs(), "oewn")
        self.assertNotIn(PLACEHOLDER, json.dumps(records, ensure_ascii=False))
        self.assertEqual(of_type(records, "form"), [])

    def test_dangling_derivation_and_unknown_pos_are_malformed(self):
        dangling = [("entries-x.json", {"x": {"n": {"sense": [{"id": "x%1", "derivation": ["y%1"]}]}}})]
        self.assertLexicon("malformed", wl.parse_oewn_entries, dangling, "oewn")
        unknown = [("entries-x.json", {"x": {"q": {"sense": []}}})]
        self.assertLexicon("malformed", wl.parse_oewn_entries, unknown, "oewn")
        twice = [("entries-x.json", {"x": {"n": {"sense": [{"id": "s"}]}, "v": {"sense": [{"id": "s"}]}}})]
        self.assertLexicon("malformed", wl.parse_oewn_entries, twice, "oewn")

    def test_numbered_homograph_entries_are_all_read(self):
        # OEWN numbers further lexemes of one POS `n-1`, `n-2`: each keeps its own pronunciation and senses.
        docs = [("entries-b.json", {
            "bass": {
                "n": {"pronunciation": [{"value": "beɪs"}], "sense": [{"id": "bass%1:10:00::"}]},
                "n-1": {"pronunciation": [{"value": "bæs", "variety": "GB"}], "sense": [{"id": "bass%1:13:00::"}]},
                "n-2": {"sense": [{"id": "bass%1:05:00::", "derivation": ["basso%1:18:00::"]}]},
            },
            "bassist": {"n": {"sense": [{"id": "bassist%1:18:00::",
                                         "derivation": ["bass%1:10:00::", "bass%1:13:00::"]}]}},
            "basso": {"n": {"sense": [{"id": "basso%1:18:00::", "derivation": ["bass%1:05:00::"]}]}},
        })]
        records = wl.parse_oewn_entries(docs, "oewn")
        self.assertEqual(
            {(p["word"], p["pos"], p.get("dialect"), p["phonemes"][0]) for p in of_type(records, "pronunciation")},
            {("bass", "noun", None, "beɪs"), ("bass", "noun", "GB", "bæs")},
        )
        self.assertEqual(
            strip(of_type(records, "derivation")),
            {
                wl.dumps({"type": "derivation", "base": "bass", "basePos": "noun", "derived": "bassist",
                          "derivedPos": "noun", "kind": "other"}),
                wl.dumps({"type": "derivation", "base": "bass", "basePos": "noun", "derived": "basso",
                          "derivedPos": "noun", "kind": "other"}),
            },
        )
        self.assertEqual(sum(1 for d in of_type(records, "derivation") if d["derived"] == "bassist"), 2)

    def test_malformed_entry_keys_are_refused(self):
        for code in ("n-x", "n-0", "n-", "n1", "n-1-2", "q-1", "N", "nn", "-1"):
            with self.subTest(code=code):
                docs = [("entries-x.json", {"x": {code: {"sense": []}}})]
                self.assertLexicon("malformed", wl.parse_oewn_entries, docs, "oewn")

    def test_zip_reader_opens_only_entries(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "oewn.zip"
            with zipfile.ZipFile(path, "w") as archive:
                for name, doc in oewn_docs():
                    archive.writestr(name, json.dumps(doc))
                archive.writestr("frames.json", "not json at all")
            docs = wl.read_oewn_zip(path, "oewn")
            self.assertEqual([name for name, _ in docs], ["entries-p.json"])
            (Path(tmp) / "bad.zip").write_bytes(b"not a zip")
            self.assertLexicon("malformed", wl.read_oewn_zip, Path(tmp) / "bad.zip", "oewn")


# --- etymology-db ---------------------------------------------------------------------------------------------


def ety(*rows) -> list[str]:
    """CSV lines: the header, then each row `(term_id, lang, term, reltype, rid, rlang, rterm, tag, parent, ppos)`."""
    out = io.StringIO()
    writer = csv.writer(out, lineterminator="\n")
    writer.writerow(wl.ETY_COLUMNS)
    for row in rows:
        tid, lang, term, rel, rid, rlang, rterm, *rest = list(row) + [""] * (10 - len(row))
        tag, parent, ppos = rest[:3]
        writer.writerow([tid, lang, term, rel, rid, rlang, rterm, "0", tag, parent, ppos])
    return out.getvalue().splitlines(keepends=True)


def edges(records) -> set[tuple[str, str, str]]:
    return {(r["child"], r["parent"], r["relation"]) for r in of_type(records, "etymon")}


def origins(records) -> dict[str, dict]:
    return {r["id"]: r for r in of_type(records, "origin")}


class EtymologyTests(Raises, unittest.TestCase):
    def build(self, *rows, **kwargs):
        graph = wl.parse_etymology_csv(ety(*rows), "ety")
        return graph, wl.etymology_records(graph, "ety", **kwargs)

    def test_cow_chain_across_blocks_and_pie_root(self):
        _, records = self.build(
            ("cow", "English", "cow", "inherited_from", "oe", "Old English", "cū"),
            ("cow", "English", "cow", "has_root", "pie", "Proto-Indo-European", "*gʷṓws (cow)"),
            ("oe", "Old English", "cū", "inherited_from", "pwg", "Proto-West Germanic", "*kū"),
            ("pwg", "Proto-West Germanic", "*kū", "inherited_from", "pg", "Proto-Germanic", "*kōz"),
        )
        self.assertEqual(
            edges(records),
            {("ety:cow", "ety:oe", "inherited"), ("ety:cow", "ety:pie", "root"),
             ("ety:oe", "ety:pwg", "inherited"), ("ety:pwg", "ety:pg", "inherited")},
        )
        found = origins(records)
        self.assertEqual(found["ety:cow"], {"type": "origin", "id": "ety:cow", "language": "English", "form": "cow",
                                            "word": "cow"})
        self.assertEqual(found["ety:pie"]["form"], "*gʷṓws")
        self.assertNotIn("word", found["ety:oe"])
        self.assertTrue(all(r["uncertain"] is False for r in of_type(records, "etymon")))

    def test_derived_group_is_a_chain_in_parent_position_order(self):
        _, records = self.build(
            ("beef", "English", "beef", "group_derived_root", "", "", "", "G"),
            ("beef", "English", "beef", "inherited_from", "lat", "Latin", "bōs", "", "G", "2"),
            ("beef", "English", "beef", "inherited_from", "me", "Middle English", "beef", "", "G", "0"),
            ("beef", "English", "beef", "borrowed_from", "of", "Old French", "buef", "", "G", "1"),
            ("beef", "English", "beef", "etymologically_related_to", "x", "Latin", "bovīnus", "", "G", "3"),
        )
        self.assertEqual(
            edges(records),
            {("ety:beef", "ety:me", "inherited"), ("ety:me", "ety:of", "borrowed"), ("ety:of", "ety:lat", "inherited")},
        )
        self.assertNotIn("ety:x", origins(records))

    def test_related_group_in_a_chain_is_one_step_of_alternatives(self):
        _, records = self.build(
            ("w", "English", "w", "group_derived_root", "", "", "", "G"),
            ("w", "English", "w", "borrowed_from", "a", "Latin", "a", "", "G", "0"),
            ("w", "English", "w", "group_related_root", "", "", "", "R", "G", "1"),
            ("w", "English", "w", "inherited_from", "b", "Ancient Greek", "b", "", "R", "0"),
            ("w", "English", "w", "inherited_from", "c", "Ancient Greek", "c", "", "R", "1"),
            ("w", "English", "w", "derived_from", "d", "Proto-Indo-European", "*d-", "", "G", "2"),
        )
        self.assertEqual(
            edges(records),
            {("ety:w", "ety:a", "borrowed"), ("ety:a", "ety:b", "inherited"), ("ety:a", "ety:c", "inherited"),
             ("ety:b", "ety:d", "derived"), ("ety:c", "ety:d", "derived")},
        )

    def test_shared_affixes_are_never_roots_and_hyphen_roots_survive(self):
        _, records = self.build(
            ("impossible", "English", "impossible", "has_prefix", "in", "English", "in-"),
            ("impossible", "English", "impossible", "group_affix_root", "", "", "", "A"),
            ("impossible", "English", "impossible", "has_affix", "able", "English", "-able", "", "A", "0"),
            ("impossible", "English", "impossible", "borrowed_from", "lat", "Latin", "impossibilis"),
            ("unlikely", "English", "unlikely", "has_prefix", "in", "English", "in-"),
            ("record", "English", "record", "has_root", "kerd", "Proto-Indo-European", "*ḱerd- (heart)"),
            ("heart", "English", "heart", "has_root", "kerd", "Proto-Indo-European", "*ḱerd-"),
            ("cordial", "English", "cordial", "has_root", "kerd", "Proto-Indo-European", "*ḱerd-"),
        )
        found = origins(records)
        self.assertNotIn("ety:in", found)
        self.assertNotIn("ety:able", found)
        self.assertEqual(found["ety:kerd"]["form"], "*ḱerd-")
        self.assertEqual(
            {e for e in edges(records) if e[1] == "ety:kerd"},
            {("ety:record", "ety:kerd", "root"), ("ety:heart", "ety:kerd", "root"),
             ("ety:cordial", "ety:kerd", "root")},
        )
        self.assertNotIn("ety:unlikely", found)

    def test_with_root_rows_give_english_derivations_only(self):
        _, records = self.build(
            ("unhappy", "English", "unhappy", "has_prefix_with_root", "happy", "English", "happy"),
            ("cow", "English", "cow", "has_suffix_with_root", "kye", "Old English", "cȳ"),
        )
        self.assertEqual(
            of_type(records, "derivation"),
            [{"type": "derivation", "base": "happy", "derived": "unhappy", "kind": "other", "source": "ety"}],
        )
        self.assertEqual(edges(records), set())

    def test_nested_derived_group_and_empty_targets_are_skipped_and_counted(self):
        graph, records = self.build(
            ("w", "English", "w", "group_derived_root", "", "", "", "G"),
            ("w", "English", "w", "group_derived_root", "", "", "", "H", "G", "0"),
            ("w", "English", "w", "inherited_from", "a", "Latin", "a", "", "H", "0"),
            ("w", "English", "w", "inherited_from", "", "", "", "", "G", "1"),
            ("v", "English", "v", "inherited_from", "v", "English", "v"),
        )
        self.assertEqual(edges(records), set())
        self.assertEqual(graph.skipped["group_derived_root inside group_derived_root"], 1)
        self.assertEqual(graph.skipped["ancestry row without related id, language or form"], 1)
        self.assertEqual(graph.skipped["self-edge"], 1)
        # The unread nested group and the empty row are both steps that gave nothing: each breaks the chain.
        self.assertEqual(graph.skipped["ancestry chain broken at a skipped step"], 2)

    def test_depth_is_bounded(self):
        rows = [(f"n{i}", "English" if i == 0 else "Latin", f"n{i}", "inherited_from", f"n{i + 1}", "Latin",
                 f"n{i + 1}") for i in range(5)]
        _, records = self.build(*rows, max_depth=2)
        self.assertEqual(edges(records), {("ety:n0", "ety:n1", "inherited"), ("ety:n1", "ety:n2", "inherited")})
        self.assertEqual(set(origins(records)), {"ety:n0", "ety:n1", "ety:n2"})

    def test_unknown_types_are_collected_then_refused(self):
        error = self.assertLexicon(
            "version", wl.parse_etymology_csv,
            ety(("a", "English", "a", "mystery", "b", "Latin", "b"), ("c", "English", "c", "riddle", "d", "Latin", "d"),
                ("e", "English", "e", "mystery", "f", "Latin", "f")),
            "ety",
        )
        self.assertIn("mystery (2)", str(error))
        self.assertIn("riddle (1)", str(error))

    def test_shape_errors(self):
        self.assertLexicon("version", wl.parse_etymology_csv, ["a,b,c\n"], "ety")
        self.assertLexicon("malformed", wl.parse_etymology_csv,
                           ety(("a", "English", "a", "inherited_from", "b", "Latin", "b", "", "NOPE", "0")), "ety")
        short = ety()[:1] + ["a,English,a\n"]
        self.assertLexicon("malformed", wl.parse_etymology_csv, short, "ety")

    def test_fable_has_root_is_written_as_root(self):
        # A stated root is a known relation, not an unknown one; it is still never a chain step.
        self.assertIn("root", wl.ETYMON_RELATIONS)
        _, records = self.build(
            ("cow", "English", "cow", "has_root", "pie", "Proto-Indo-European", "*gʷṓws (cow)"),
            ("w", "English", "w", "group_derived_root", "", "", "", "G"),
            ("w", "English", "w", "borrowed_from", "a", "Latin", "a", "", "G", "0"),
            ("w", "English", "w", "has_root", "r", "Proto-Indo-European", "*r-", "", "G", "1"),
            ("w", "English", "w", "inherited_from", "c", "Ancient Greek", "c", "", "G", "2"),
            ("psm", "English", "psm", "phono-semantic_matching_of", "z", "Latin", "z"),
        )
        self.assertEqual(
            edges(records),
            {("ety:cow", "ety:pie", "root"), ("ety:w", "ety:a", "borrowed"), ("ety:w", "ety:r", "root"),
             ("ety:a", "ety:c", "inherited"), ("ety:psm", "ety:z", "unknown")},
        )
        record = {"type": "etymon", "child": "ety:cow", "parent": "ety:pie", "relation": "root", "uncertain": False,
                  "source": "t"}
        self.assertEqual(wl.validate_record(record), record)
        self.assertEqual(wl.pack_lines([SRC], [record])[1], wl.dumps(record))

    def test_fable_a_failed_chain_step_breaks_the_chain(self):
        # a, then b with no related id, then c, d: nothing may join a to c across the gap.
        graph, records = self.build(
            ("w", "English", "w", "group_derived_root", "", "", "", "G"),
            ("w", "English", "w", "borrowed_from", "a", "Latin", "a", "", "G", "0"),
            ("w", "English", "w", "inherited_from", "", "", "", "", "G", "1"),
            ("w", "English", "w", "inherited_from", "c", "Ancient Greek", "c", "", "G", "2"),
            ("w", "English", "w", "derived_from", "d", "Proto-Indo-European", "*d-", "", "G", "3"),
        )
        self.assertEqual(edges(records), {("ety:w", "ety:a", "borrowed")})
        self.assertEqual(graph.parents.get("ety:w"), {("ety:a", "borrowed")})
        self.assertNotIn("ety:a", graph.parents)
        self.assertEqual(graph.skipped["ancestry row without related id, language or form"], 1)
        self.assertEqual(graph.skipped["ancestry chain broken at a skipped step"], 1)

    def test_fable_a_related_step_with_no_usable_member_breaks_the_chain(self):
        graph, records = self.build(
            ("w", "English", "w", "group_derived_root", "", "", "", "G"),
            ("w", "English", "w", "borrowed_from", "a", "Latin", "a", "", "G", "0"),
            ("w", "English", "w", "group_related_root", "", "", "", "R", "G", "1"),
            ("w", "English", "w", "inherited_from", "", "Ancient Greek", "b", "", "R", "0"),
            ("w", "English", "w", "derived_from", "c", "Proto-Indo-European", "*c-", "", "G", "2"),
        )
        self.assertEqual(edges(records), {("ety:w", "ety:a", "borrowed")})
        self.assertEqual(graph.skipped["ancestry chain broken at a skipped step"], 1)

    def test_fable_non_ancestry_rows_inside_a_chain_are_not_gaps(self):
        # Control: a related row between two steps is not a step, so the chain stays whole and nothing is counted.
        graph, records = self.build(
            ("w", "English", "w", "group_derived_root", "", "", "", "G"),
            ("w", "English", "w", "borrowed_from", "a", "Latin", "a", "", "G", "0"),
            ("w", "English", "w", "etymologically_related_to", "x", "Latin", "x", "", "G", "1"),
            ("w", "English", "w", "inherited_from", "c", "Ancient Greek", "c", "", "G", "2"),
        )
        self.assertEqual(edges(records), {("ety:w", "ety:a", "borrowed"), ("ety:a", "ety:c", "inherited")})
        self.assertEqual(graph.skipped["ancestry chain broken at a skipped step"], 0)

    def test_strip_gloss(self):
        self.assertEqual(wl.strip_gloss("*per- (fare)"), "*per-")
        self.assertEqual(wl.strip_gloss("*ḱerd-"), "*ḱerd-")
        self.assertEqual(wl.strip_gloss("(a)"), "(a)")


# --- MorphyNet ------------------------------------------------------------------------------------------------


class MorphyNetTests(Raises, unittest.TestCase):
    def test_inflections(self):
        lines = [
            "record\trecords\tV|PRS;3;SG\trecord|s\n",
            "record\trecords\tN|PL\trecord|s\n",
            "record\trecording\tV|V.PTCP;PRS\trecord|ing\n",
            "possible\tpossible\tN;SG\t-\n",
            "run\trun\tADJ\t-\n",
        ]
        self.assertEqual(
            list(wl.parse_morphynet_inflection(lines, "mi")),
            [
                {"type": "form", "form": "records", "lemma": "record", "pos": "verb", "tags": ["PRS", "3", "SG"],
                 "source": "mi"},
                {"type": "form", "form": "records", "lemma": "record", "pos": "noun", "tags": ["PL"], "source": "mi"},
                {"type": "form", "form": "recording", "lemma": "record", "pos": "verb", "tags": ["V.PTCP", "PRS"],
                 "source": "mi"},
            ],
        )

    def derive(self, lines: list[str]) -> tuple[list[dict], Counter[str]]:
        skipped: Counter[str] = Counter()
        return list(wl.parse_morphynet_derivation(lines, "md", skipped=skipped)), skipped

    def test_derivations(self):
        records, skipped = self.derive([
            "possibility\timpossibility\tN\tN\tim\tprefix\n",
            "possible\tpossibly\tJ\tR\tly\tsuffix\n",
            "run\trunner\tV\tN\ter\tsuffix\n",
        ])
        self.assertEqual(
            records,
            [
                {"type": "derivation", "base": "possibility", "basePos": "noun", "derived": "impossibility",
                 "derivedPos": "noun", "kind": "prefix", "affix": "im-", "source": "md"},
                {"type": "derivation", "base": "possible", "basePos": "adj", "derived": "possibly",
                 "derivedPos": "adv", "kind": "suffix", "affix": "-ly", "source": "md"},
                {"type": "derivation", "base": "run", "basePos": "verb", "derived": "runner",
                 "derivedPos": "noun", "kind": "suffix", "affix": "-er", "source": "md"},
            ],
        )
        self.assertEqual(skipped, Counter())

    def test_attached_affixes_are_kept(self):
        # Real MorphyNet shapes: literal attachment, a hyphen prefix, and the three spelling rules.
        rows = [
            ("record", "re-record", "re", "prefix"),
            ("run", "outrun", "out", "prefix"),
            ("sense", "nonsense", "non", "prefix"),
            ("possible", "unpossible", "un", "prefix"),
            ("photograph", "photographer", "er", "suffix"),
            ("multicultural", "multiculturalism", "ism", "suffix"),
            ("alphabetic", "alphabetical", "al", "suffix"),
            ("record", "recordable", "able", "suffix"),
            ("possible", "possibly", "ly", "suffix"),
            ("connote", "connotation", "ation", "suffix"),
            ("happy", "happiness", "ness", "suffix"),
            ("run", "runner", "er", "suffix"),
            ("run", "runny", "y", "suffix"),
            ("run", "runnable", "able", "suffix"),
            ("run", "runneth", "eth", "suffix"),
            ("Record", "re-record", "RE", "prefix"),
        ]
        for base, derived, affix, kind in rows:
            with self.subTest(base=base, derived=derived):
                self.assertTrue(wl.morphynet_attaches(base, derived, affix, kind))
        records, skipped = self.derive([f"{b}\t{d}\tV\tV\t{a}\t{k}\n" for b, d, a, k in rows])
        self.assertEqual(len(records), len(rows))
        self.assertEqual(skipped, Counter())

    def test_affixes_that_do_not_attach_are_skipped_and_counted(self):
        rows = [
            ("run", "ember", "umb", "prefix"),
            ("moon", "month", "th", "suffix"),
            ("record", "recorder", "re", "prefix"),
            ("possible", "possibility", "ly", "suffix"),
            ("happy", "happness", "ness", "suffix"),
            ("rain", "rainner", "er", "suffix"),
            ("box", "boxxer", "er", "suffix"),
        ]
        for base, derived, affix, kind in rows:
            with self.subTest(base=base, derived=derived):
                self.assertFalse(wl.morphynet_attaches(base, derived, affix, kind))
        records, skipped = self.derive([
            "run\tember\tV\tJ\tumb\tprefix\n",
            "moon\tmonth\tN\tN\tth\tsuffix\n",
            "run\trunner\tV\tN\t\tsuffix\n",
            "run\trun\tV\tN\ter\tsuffix\n",
        ])
        self.assertEqual(records, [])
        self.assertEqual(
            skipped,
            Counter({"prefix spelling change not modelled": 1, "suffix spelling change not modelled": 1,
                     "empty morpheme": 1, "derived word equals its base": 1}),
        )

    def test_fable_known_allomorphs_are_unmodelled_not_defects(self):
        # Ordinary English derivations the conservative rules do not model. They stay out (no guessed allomorphy
        # rule), but the reason says the spelling change is not modelled, not that the row is broken.
        for base, derived, affix in (("possible", "possibility", "ity"), ("conclude", "conclusion", "sion")):
            with self.subTest(derived=derived):
                self.assertFalse(wl.morphynet_attaches(base, derived, affix, "suffix"))
        self.assertFalse(wl.morphynet_attaches("legal", "illegal", "in", "prefix"))
        records, skipped = self.derive([
            "possible\tpossibility\tJ\tN\tity\tsuffix\n",
            "conclude\tconclusion\tV\tN\tsion\tsuffix\n",
            "legal\tillegal\tJ\tJ\tin\tprefix\n",
            "a\tare\tU\tN\tre\tsuffix\n",
        ])
        self.assertEqual(records, [])
        self.assertEqual(
            skipped,
            Counter({"suffix spelling change not modelled": 2, "prefix spelling change not modelled": 1,
                     "undocumented POS U": 1}),
        )
        self.assertFalse(any("does not attach" in reason for reason in skipped))

    def test_fable_skipped_samples_are_bounded_metadata_in_source_order(self):
        self.assertEqual(wl.MAX_SKIPPED_SAMPLES, 50)
        lines = [f"moon{i:03d}\tmonth{i:03d}\tN\tN\tth\tsuffix\n" for i in range(120)]
        lines.append("a\tare\tU\tN\tre\tsuffix\n")

        def run() -> tuple[Counter[str], dict[str, list[dict]]]:
            skipped: Counter[str] = Counter()
            samples: dict[str, list[dict]] = {}
            self.assertEqual(list(wl.parse_morphynet_derivation(lines, "md", skipped=skipped, samples=samples)), [])
            return skipped, samples

        skipped, samples = run()
        self.assertEqual(skipped, Counter({"suffix spelling change not modelled": 120, "undocumented POS U": 1}))
        unmodelled = samples["suffix spelling change not modelled"]
        self.assertEqual(len(unmodelled), 50)
        self.assertEqual(
            unmodelled[0],
            {"line": 1, "base": "moon000", "derived": "month000", "basePos": "N", "derivedPos": "N", "affix": "th",
             "kind": "suffix"},
        )
        self.assertEqual([s["line"] for s in unmodelled], list(range(1, 51)))
        self.assertEqual(
            samples["undocumented POS U"],
            [{"line": 121, "base": "a", "derived": "are", "basePos": "U", "derivedPos": "N", "affix": "re",
              "kind": "suffix"}],
        )
        for reason, items in samples.items():
            for item in items:
                with self.subTest(reason=reason, line=item.get("line")):
                    self.assertLessEqual(item.keys(), SAMPLE_FIELDS)
        self.assertEqual(run(), (skipped, samples))
        # Without a samples dict the parser still only counts.
        self.assertEqual(self.derive(lines)[1], skipped)

    def test_undocumented_pos_u_is_skipped_and_counted(self):
        unknown: Counter[str] = Counter()
        skipped: Counter[str] = Counter()
        lines = ["a\tare\tU\tN\tre\tsuffix\n", "a\tare\tN\tU\tre\tsuffix\n", "record\trecordable\tV\tJ\table\tsuffix\n"]
        records = list(wl.parse_morphynet_derivation(lines, "md", unknown, skipped=skipped))
        self.assertEqual([r["derived"] for r in records], ["recordable"])
        self.assertEqual(skipped, Counter({"undocumented POS U": 2}))
        self.assertEqual(unknown, Counter())
        self.assertNotIn("U", wl.MORPHYNET_DERI_POS)

    def test_unknown_codes_are_collected(self):
        unknown: Counter[str] = Counter()
        skipped: Counter[str] = Counter()
        lines = ["a\tb\tX\tN\tre\tprefix\n", "a\tc\tN\tN\tre\tinfix\n", "a\td\tX\tU\tre\tprefix\n"]
        self.assertEqual(list(wl.parse_morphynet_derivation(lines, "md", unknown, skipped=skipped)), [])
        self.assertEqual(unknown, Counter({"derivation POS X": 2, "derivation type infix": 1}))
        self.assertEqual(skipped, Counter())
        self.assertLexicon("version", wl.parse_morphynet_derivation, ["a\tb\tX\tN\tre\tprefix\n"], "md",
                           skipped=Counter())
        self.assertLexicon("version", wl.parse_morphynet_inflection, ["a\tas\tQ|PL\ta|s\n"], "mi")

    def test_known_malformed_quoted_rows_are_skipped_and_counted(self):
        quoted = ["\t".join(row) + "\n" for row in sorted(wl.MORPHYNET_INFL_KNOWN_MALFORMED)]
        self.assertEqual(len(quoted), 2)
        lines = ["record\trecords\tN|PL\trecord|s\n", *quoted]
        unknown: Counter[str] = Counter()
        skipped: Counter[str] = Counter()
        records = list(wl.parse_morphynet_inflection(lines, "mi", unknown, skipped=skipped))
        self.assertEqual([r["form"] for r in records], ["records"])
        self.assertEqual(skipped, Counter({"known malformed quoted row": 2}))
        self.assertEqual(unknown, Counter())
        for line in quoted:
            with self.subTest(line=line):
                self.assertLexicon("malformed", wl.parse_morphynet_inflection, [line], "mi", Counter())

    def test_other_unknown_codes_are_still_refused(self):
        # Only the exact pinned rows are skipped: a near-miss quoted row and an ordinary unknown code still fail.
        lines = ['"softly\t softly"\t"|\t"other|"\n', "a\tas\tQ|PL\ta|s\n", "a\tb\tcomparable\t-\n"]
        unknown: Counter[str] = Counter()
        skipped: Counter[str] = Counter()
        self.assertEqual(list(wl.parse_morphynet_inflection(lines, "mi", unknown, skipped=skipped)), [])
        self.assertEqual(unknown, Counter({'inflection POS "': 1, "inflection POS Q": 1, "inflection POS comparable": 1}))
        self.assertEqual(skipped, Counter())

    def test_dispatcher_reports_skipped_inflection_rows(self):
        entry = {"id": "morphynet-infl", "provider": "morphynet-inflection"}
        quoted = ["\t".join(row) + "\n" for row in sorted(wl.MORPHYNET_INFL_KNOWN_MALFORMED)]
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "infl.tsv"
            path.write_text("record\trecords\tN|PL\trecord|s\n" + "".join(quoted), encoding="utf-8")
            report = {"skipped": Counter()}
            records = list(wl._parse_provider(entry, path, report))
            self.assertEqual([r["form"] for r in records], ["records"])
            self.assertEqual(report["skipped"], Counter({"morphynet-infl: known malformed quoted row": 2}))
            path.write_text("".join(quoted) + "a\tas\tQ|PL\ta|s\n", encoding="utf-8")
            self.assertLexicon("version", lambda: list(wl._parse_provider(entry, path, {"skipped": Counter()})))

    def test_column_counts(self):
        self.assertLexicon("malformed", wl.parse_morphynet_inflection, ["a\tb\tN|PL\n"], "mi")
        self.assertLexicon("malformed", wl.parse_morphynet_derivation, ["a\tb\tN\tN\tre\n"], "md", skipped=Counter())


# --- Kaikki ---------------------------------------------------------------------------------------------------


def kaikki_lines() -> list[str]:
    entries = [
        {
            "word": "impossible", "pos": "adj", "lang": "English", "lang_code": "en",
            "etymology_text": PLACEHOLDER,
            "etymology_templates": [
                {"name": "inh", "args": {"1": "en", "2": "enm", "3": "impossible"}, "expansion": PLACEHOLDER},
                {"name": "af", "args": {"1": "en", "2": "im-", "3": "possible<t:" + PLACEHOLDER + ">"},
                 "expansion": PLACEHOLDER},
            ],
            "forms": [
                {"form": "more impossible", "tags": ["comparative"]},
                {"form": "inpossible", "tags": ["alternative", "obsolete"]},
                {"form": "impossible", "tags": ["canonical"]},
                {"form": "no-table-tags", "tags": ["table-tags"]},
            ],
            "sounds": [{"ipa": "/ɪmˈpɒs.ɪ.bəl/", "tags": ["UK"]}, {"enpr": PLACEHOLDER}],
            "senses": [{"glosses": [PLACEHOLDER], "examples": [{"text": PLACEHOLDER}]}],
        },
        {
            "word": "record", "pos": "noun", "lang": "English", "lang_code": "en",
            "sounds": [
                {"ipa": "/ˈɹɛk.ɔːd/", "tags": ["UK", "noun"]},
                {"ipa": "/ɹɪˈkɔːd/", "tags": ["UK", "verb"]},
                {"ipa": "/x/", "tags": ["noun", "verb"]},
            ],
        },
        {
            "word": "axes", "pos": "noun", "lang": "English", "lang_code": "en",
            "senses": [
                {"links": [["ax", "ax#English"], ["axe", "axe#English"]], "glosses": [PLACEHOLDER],
                 "tags": ["form-of", "plural"], "form_of": [{"word": "ax and axe"}]},
                {"links": [["axis", "axis#English"]], "glosses": [PLACEHOLDER], "tags": ["form-of", "plural"],
                 "form_of": [{"word": "axis"}]},
            ],
            "etymology_templates": [
                {"name": "ety", "args": {"1": "en", "2": ":bor", "3": "la:axēs"}, "expansion": PLACEHOLDER},
            ],
        },
        {
            "word": "blackbird", "pos": "noun", "lang_code": "en",
            "etymology_templates": [
                {"name": "compound", "args": {"1": "en", "2": "black", "3": "bird"}},
                {"name": "af", "args": {"1": "en", "2": "la:niger", "3": "bird"}},
            ],
        },
        {"word": "possible", "pos": "adj", "lang": "Middle English", "lang_code": "enm",
         "sounds": [{"ipa": "/enm/"}]},
    ]
    return [json.dumps(e, ensure_ascii=False) + "\n" for e in entries]


class KaikkiTests(Raises, unittest.TestCase):
    def setUp(self):
        self.records = list(wl.parse_kaikki_jsonl(kaikki_lines(), "kaikki:x"))

    def test_no_content_and_only_english(self):
        self.assertNotIn(PLACEHOLDER, json.dumps(self.records, ensure_ascii=False))
        self.assertNotIn("/enm/", json.dumps(self.records, ensure_ascii=False))

    def test_affix_template_gives_the_impossible_family(self):
        derivations = of_type(self.records, "derivation")
        self.assertIn(
            {"type": "derivation", "base": "possible", "derived": "impossible", "derivedPos": "adj", "kind": "prefix",
             "affix": "im-", "source": "kaikki:x"},
            derivations,
        )
        self.assertEqual(
            {(d["base"], d["derived"], d["kind"]) for d in derivations},
            {("possible", "impossible", "prefix"), ("black", "blackbird", "compound"),
             ("bird", "blackbird", "compound")},
        )

    def test_sounds_take_pos_from_tags_and_stay_whole(self):
        prons = {(p["word"], p["phonemes"][0], p.get("pos"), p.get("dialect")) for p in
                 of_type(self.records, "pronunciation")}
        self.assertEqual(
            prons,
            {("impossible", "/ɪmˈpɒs.ɪ.bəl/", "adj", "UK"), ("record", "/ˈɹɛk.ɔːd/", "noun", "UK"),
             ("record", "/ɹɪˈkɔːd/", "verb", "UK"), ("record", "/x/", None, None)},
        )

    def test_forms_skip_alternatives_and_check_form_of_links(self):
        forms = {(f["form"], f["lemma"], f["pos"], tuple(f["tags"])) for f in of_type(self.records, "form")}
        self.assertEqual(
            forms,
            {("more impossible", "impossible", "adj", ("comparative",)), ("axes", "axis", "noun", ("plural",))},
        )

    def test_bad_lines(self):
        self.assertLexicon("malformed", wl.parse_kaikki_jsonl, ["{not json\n"], "k")
        self.assertLexicon("malformed", wl.parse_kaikki_jsonl, ['{"lang_code":"en","word":"a"}\n'], "k")

    def test_receipt_verifies_each_file(self):
        template = {"id": "kaikki", "name": "Kaikki", "url_prefix": "https://kaikki.org/dictionary/English/",
                    "licence": "CC-BY-SA-4.0", "attribution": "Kaikki", "notice": "notice"}
        with tempfile.TemporaryDirectory() as tmp:
            data = "".join(kaikki_lines()).encode("utf-8")
            (Path(tmp) / "impossible.jsonl").write_bytes(data)
            item = {"word": "impossible", "url": "https://kaikki.org/dictionary/English/meaning/i/im/impossible.jsonl",
                    "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(), "snapshot": "2026-10-21"}
            receipt = Path(tmp) / "receipt.json"
            receipt.write_text(json.dumps([item]))
            [(src, path)] = wl.load_kaikki_receipt(receipt, template)
            self.assertEqual((src["id"], src["sha256"], src["version"], src["url"]),
                             ("kaikki:impossible", item["sha256"], "2026-10-21", item["url"]))
            self.assertEqual(path.name, "impossible.jsonl")
            receipt.write_text(json.dumps([item | {"sha256": "1" * 64}]))
            self.assertLexicon("hash", wl.load_kaikki_receipt, receipt, template)
            receipt.write_text(json.dumps([item | {"word": "../impossible"}]))
            self.assertLexicon("malformed", wl.load_kaikki_receipt, receipt, template)
            receipt.write_text(json.dumps([item | {"url": "https://elsewhere.example/impossible.jsonl"}]))
            self.assertLexicon("malformed", wl.load_kaikki_receipt, receipt, template)
            receipt.write_text(json.dumps([item | {"word": "absent"}]))
            self.assertLexicon("missing", wl.load_kaikki_receipt, receipt, template)

    TEMPLATE = {"id": "kaikki", "name": "Kaikki", "url_prefix": "https://kaikki.org/dictionary/English/",
                "licence": "CC-BY-SA-4.0", "attribution": "Kaikki", "notice": "notice"}

    def write_receipt(self, folder: Path, words: list[str]) -> Path:
        data = kaikki_lines()[0].encode("utf-8")
        items = []
        for index, word in enumerate(words):
            (folder / f"{word}.jsonl").write_bytes(data)
            items.append({"word": word, "url": f"https://kaikki.org/dictionary/English/meaning/{index}.jsonl",
                          "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(), "snapshot": "2026-10-21"})
        receipt = folder / "receipt.json"
        receipt.write_text(json.dumps(items), encoding="utf-8")
        return receipt

    def test_fable_receipt_words_give_loader_safe_unique_ids(self):
        # A word the loader's id charset holds keeps its readable id; any other (space, apostrophe, non-ASCII, or the
        # reserved `sha256:` prefix) is named by the SHA-256 of its NFC UTF-8 spelling. Name and file keep the word.
        readable = {"impossible": "kaikki:impossible", "Rome": "kaikki:Rome", "re-record": "kaikki:re-record"}
        hashed = ["ice cream", "don't", "café", "sha256:abc"]
        with tempfile.TemporaryDirectory() as tmp:
            receipt = self.write_receipt(Path(tmp), [*readable, *hashed])
            loaded = wl.load_kaikki_receipt(receipt, self.TEMPLATE)
            self.assertEqual(wl.load_kaikki_receipt(receipt, self.TEMPLATE), loaded)
        by_word = {src["name"].removeprefix("Kaikki: "): (src, path) for src, path in loaded}
        self.assertEqual(set(by_word), {*readable, *hashed})
        expected = readable | {
            word: "kaikki:sha256:" + hashlib.sha256(unicodedata.normalize("NFC", word).encode("utf-8")).hexdigest()
            for word in hashed
        }
        for word, (src, path) in by_word.items():
            with self.subTest(word=word):
                self.assertEqual(src["id"], expected[word])
                self.assertTrue(LOADER_SOURCE_ID.fullmatch(src["id"]), src["id"])
                self.assertEqual(path.name, f"{word}.jsonl")
        ids = [src["id"] for src, _ in loaded]
        self.assertEqual(len(set(ids)), len(ids))
        header = json.loads(wl.PackBuilder([src for src, _ in loaded]).header_line())
        self.assertEqual(sorted(s["id"] for s in header["sources"]), sorted(ids))

    def test_fable_receipt_words_equal_under_nfc_are_refused(self):
        # One canonical word listed twice (NFC and NFD spellings) is a duplicate, never merged or given two ids.
        with tempfile.TemporaryDirectory() as tmp:
            receipt = self.write_receipt(Path(tmp), ["café"])
            items = json.loads(receipt.read_text(encoding="utf-8"))
            items.append(items[0] | {"word": "café", "url": items[0]["url"] + "?nfd"})
            receipt.write_text(json.dumps(items), encoding="utf-8")
            self.assertLexicon("malformed", wl.load_kaikki_receipt, receipt, self.TEMPLATE)


# --- records, the header and the pack -------------------------------------------------------------------------


def pron(**overrides) -> dict:
    return {"type": "pronunciation", "word": "run", "system": "arpabet", "phonemes": ["R", "AH1", "N"],
            "source": "t"} | overrides


class RecordTests(Raises, unittest.TestCase):
    def test_every_record_type_validates(self):
        for record in (
            pron(),
            pron(system="ipa", phonemes=["/ɹʌn/"], pos="verb", dialect="US"),
            {"type": "form", "form": "ran", "lemma": "run", "pos": "verb", "tags": ["PST"], "source": "t"},
            {"type": "derivation", "base": "run", "derived": "runner", "kind": "suffix", "affix": "-er",
             "source": "t"},
            {"type": "origin", "id": "ety:1", "language": "English", "form": "run", "word": "run"},
            {"type": "etymon", "child": "ety:1", "parent": "ety:2", "relation": "inherited", "uncertain": False,
             "source": "t"},
        ):
            with self.subTest(type=record["type"]):
                self.assertEqual(wl.validate_record(record), record)

    def test_absent_optionals_are_omitted_and_text_is_nfc(self):
        record = wl.validate_record(pron(pos=None, word="café"))
        self.assertNotIn("pos", record)
        self.assertEqual(record["word"], "café")

    def test_rejections(self):
        cases = [
            ("content", pron(gloss=PLACEHOLDER)),
            ("content", {"type": "origin", "id": "o", "language": "en", "form": "f", "etymology_text": "x"}),
            ("malformed", pron(extra="x")),
            ("malformed", {"type": "lemma", "word": "run"}),
            ("malformed", pron(phonemes=["R", "AH", "N"])),
            ("malformed", pron(phonemes=[])),
            ("malformed", pron(system="sampa")),
            ("malformed", pron(word="a\tb")),
            ("malformed", pron(word=" ")),
            ("malformed", {"type": "form", "form": "ran", "lemma": "run", "pos": "verb", "tags": [], "source": "t"}),
            ("malformed", {"type": "derivation", "base": "a", "derived": "b", "kind": "infix", "source": "t"}),
            ("malformed", {"type": "etymon", "child": "a", "parent": "b", "relation": "cognate", "uncertain": False,
                           "source": "t"}),
            ("malformed", {"type": "etymon", "child": "a", "parent": "b", "relation": "inherited", "uncertain": 0,
                           "source": "t"}),
            ("bound", pron(word="a" * (wl.MAX_STRING_CHARS + 1))),
            ("bound", pron(system="ipa", phonemes=["a"] * (wl.MAX_LIST_ITEMS + 1))),
        ]
        for kind, record in cases:
            with self.subTest(record=record):
                self.assertLexicon(kind, wl.validate_record, record)
        self.assertEqual(wl.validate_record(pron(word="é" * wl.MAX_STRING_CHARS))["word"], "é" * wl.MAX_STRING_CHARS)

    def test_header_shape(self):
        header = json.loads(wl.pack_lines([SRC | {"coverage": "all", "notice": "long", "provider": "x"}], [])[0])
        self.assertEqual(
            header,
            {"type": "header", "schema": "xdict-word-pack", "version": 1, "language": "en",
             "sources": [SRC | {"coverage": "all"}]},
        )
        for bad, kind in ((SRC | {"sha256": "A" * 64}, "malformed"), (SRC | {"licence": ""}, "licence"),
                          (SRC | {"url": "http://x"}, "malformed"), (SRC | {"version": "pending"}, "pending"),
                          (SRC | {"coverage": "c" * (wl.MAX_STRING_CHARS + 1)}, "bound")):
            with self.subTest(bad=bad):
                self.assertLexicon(kind, wl.pack_lines, [bad], [])
        self.assertLexicon("malformed", wl.pack_lines, [SRC, SRC], [])

    def test_pack_order_dedupe_and_determinism(self):
        records = [
            {"type": "etymon", "child": "ety:1", "parent": "ety:2", "relation": "inherited", "uncertain": False,
             "source": "t"},
            {"type": "origin", "id": "ety:2", "language": "Latin", "form": "b"},
            {"type": "origin", "id": "ety:1", "language": "English", "form": "a", "word": "a"},
            {"type": "form", "form": "ran", "lemma": "run", "pos": "verb", "tags": ["PST"], "source": "t"},
            pron(), pron(),
        ]
        lines = wl.pack_lines([SRC], records)
        self.assertEqual(wl.pack_lines([SRC], list(reversed(records))), lines)
        self.assertEqual([json.loads(line)["type"] for line in lines],
                         ["header", "pronunciation", "form", "origin", "origin", "etymon"])
        self.assertEqual(lines[1], '{"phonemes":["R","AH1","N"],"source":"t","system":"arpabet","type":"pronunciation",'
                                   '"word":"run"}')

    def test_sources_and_origins_must_be_consistent(self):
        self.assertLexicon("licence", wl.pack_lines, [SRC], [pron(source="other")])
        self.assertLexicon("malformed", wl.pack_lines, [SRC], [
            {"type": "origin", "id": "o", "language": "Latin", "form": "a"},
            {"type": "origin", "id": "o", "language": "Latin", "form": "b"},
        ])

    def test_bounds_are_counted_in_a_build_and_raised_when_strict(self):
        long = pron(word="a" * (wl.MAX_STRING_CHARS + 1))
        self.assertLexicon("bound", wl.pack_lines, [SRC], [long])
        builder = wl.PackBuilder([SRC], strict=False)
        builder.add(long, "t")
        builder.add(pron(), "t")
        self.assertEqual(builder.counts()["pronunciation"], 1)
        self.assertEqual(sum(builder.rejected.values()), 1)
        with self.assertRaises(wl.LexiconError):
            builder.add(pron(gloss="x"), "t")

    def test_limits_match_the_rust_loader(self):
        # `LexiconLimits::default()` in src/words/lexicon.rs.
        self.assertEqual(
            (wl.MAX_LINE_BYTES, wl.MAX_RECORDS, wl.MAX_STRING_CHARS, wl.MAX_LIST_ITEMS, wl.MAX_TOTAL_BYTES),
            (64 * 1024, 4_000_000, 256, 64, 512 * 1024 * 1024),
        )

    def test_whole_pack_bounds_fail_the_pack_never_cut_it(self):
        records = [pron(), pron(word="ran"), pron(word="runs")]
        for strict in (True, False):
            builder = wl.PackBuilder([SRC], strict=strict)
            for record in records:
                builder.add(record, "t")
            exact = builder.pack_lines()
            size = sum(len(line.encode("utf-8")) + 1 for line in exact)
            with self.subTest(strict=strict, bound="records"):
                with mock.patch.object(wl, "MAX_RECORDS", 3):
                    self.assertEqual(builder.pack_lines(), exact)
                with mock.patch.object(wl, "MAX_RECORDS", 2):
                    self.assertLexicon("bound", builder.pack_lines)
            with self.subTest(strict=strict, bound="bytes"):
                with mock.patch.object(wl, "MAX_TOTAL_BYTES", size):
                    self.assertEqual(builder.pack_lines(), exact)
                with mock.patch.object(wl, "MAX_TOTAL_BYTES", size - 1):
                    self.assertLexicon("bound", builder.pack_lines)
            self.assertEqual(builder.rejected, Counter())

    def test_fable_header_source_ids_use_the_loader_charset(self):
        for bad in ("kaikki:ice cream", "kaikki:don't", "kaikki:café", "kaikki:a/b", "kaikki:"):
            with self.subTest(id=bad):
                self.assertLexicon("malformed", wl.header_source, SRC | {"id": bad})
                self.assertLexicon("malformed", wl.PackBuilder, [SRC | {"id": bad}])
        for good in ("t", "morphynet-deri", "kaikki:impossible", "kaikki:Rome", "kaikki:re-record",
                     "kaikki:sha256:" + "a" * 64):
            with self.subTest(id=good):
                self.assertEqual(wl.header_source(SRC | {"id": good})["id"], good)
                header = json.loads(wl.PackBuilder([SRC | {"id": good}]).header_line())
                self.assertEqual(header["sources"][0]["id"], good)

    # possible P AA1 S AH0 B AH0 L has 3 vowels; possibility P AA2 S AH0 B IH1 L AH0 T IY0 has 5.
    STEM = {
        "basePhonemes": ["P", "AA1", "S", "AH0", "B", "AH0", "L"], "baseStart": 0, "baseEnd": 2,
        "derivedPhonemes": ["P", "AA2", "S", "AH0", "B", "IH1", "L", "AH0", "T", "IY0"], "derivedStart": 0,
        "derivedEnd": 2,
    }

    def derivation(self, **overrides) -> dict:
        return {"type": "derivation", "base": "possible", "basePos": "adj", "derived": "possibility",
                "derivedPos": "noun", "kind": "suffix", "affix": "-ity", "source": "t"} | overrides

    def test_fable_optional_stem_alignment_matches_the_loader(self):
        for stem in (self.STEM, self.STEM | {"baseStart": 1, "baseEnd": 3, "derivedStart": 3, "derivedEnd": 5}):
            with self.subTest(stem=stem):
                record = self.derivation(stem=stem)
                self.assertEqual(wl.validate_record(record), record)
                lines = wl.pack_lines([SRC], [record])
                self.assertEqual(lines[1], wl.dumps(record))
                self.assertEqual(json.loads(lines[1])["stem"], stem)
        self.assertNotIn("stem", wl.validate_record(self.derivation(stem=None)))
        self.assertNotIn("stem", wl.validate_record(self.derivation()))

    def test_fable_malformed_stem_alignments_are_refused(self):
        def without(key: str) -> dict:
            return {k: v for k, v in self.STEM.items() if k != key}

        malformed = [
            "x", [], {}, self.STEM | {"extra": 1}, self.STEM | {"basephonemes": ["P"]},
            *(without(key) for key in self.STEM),
            self.STEM | {"baseStart": True}, self.STEM | {"derivedEnd": False}, self.STEM | {"baseEnd": 2.0},
            self.STEM | {"baseStart": "0"}, self.STEM | {"baseStart": -1}, self.STEM | {"baseEnd": None},
            self.STEM | {"baseEnd": 2**32},
            self.STEM | {"baseStart": 1, "baseEnd": 1, "derivedStart": 1, "derivedEnd": 1},
            self.STEM | {"baseStart": 2, "baseEnd": 1, "derivedStart": 2, "derivedEnd": 1},
            self.STEM | {"baseStart": 0, "baseEnd": 4, "derivedStart": 0, "derivedEnd": 4},
            self.STEM | {"derivedEnd": 3},
            self.STEM | {"basePhonemes": []}, self.STEM | {"basePhonemes": ["P", "AA", "S"]},
            self.STEM | {"basePhonemes": ["XX1", "AA1"]}, self.STEM | {"derivedPhonemes": ["SH1", "AA1", "AH0"]},
            self.STEM | {"derivedPhonemes": [1, "AA1", "AH0"]}, self.STEM | {"basePhonemes": "P AA1 S"},
        ]
        for stem in malformed:
            with self.subTest(stem=stem):
                self.assertLexicon("malformed", wl.validate_record, self.derivation(stem=stem))
                self.assertLexicon("malformed", wl.pack_lines, [SRC], [self.derivation(stem=stem)])
        too_many = self.STEM | {"basePhonemes": ["AA1"] * (wl.MAX_LIST_ITEMS + 1)}
        self.assertLexicon("bound", wl.validate_record, self.derivation(stem=too_many))
        at_bound = self.STEM | {"basePhonemes": ["AA1"] * wl.MAX_LIST_ITEMS}
        self.assertEqual(wl.validate_record(self.derivation(stem=at_bound))["stem"], at_bound)

    def test_header_sources_are_bounded(self):
        sources = [SRC | {"id": f"t{i}"} for i in range(wl.MAX_LIST_ITEMS + 1)]
        self.assertLexicon("bound", wl.pack_lines, sources, [])
        self.assertEqual(len(json.loads(wl.pack_lines(sources[:-1], [])[0])["sources"]), wl.MAX_LIST_ITEMS)


# --- manifest and notices -------------------------------------------------------------------------------------


class ManifestTests(Raises, unittest.TestCase):
    def shipped(self) -> dict:
        return json.loads((TOOLS / "word_lexicon_sources.json").read_text(encoding="utf-8"))

    def test_shipped_manifest_is_complete(self):
        entries = wl.load_manifest(self.shipped())
        self.assertEqual([e["id"] for e in entries], ["cmu", "ety", "kaikki", "morphynet-deri", "morphynet-infl", "oewn"])
        for entry in entries:
            if entry["provider"] != "kaikki":
                self.assertTrue(wl.SHA256_HEX.fullmatch(entry["sha256"]), entry["id"])
                wl.header_source(entry)
        self.assertNotIn("pending", json.dumps(self.shipped()).lower())

    def test_refusals(self):
        base = self.shipped()

        def changed(index: int, **fields) -> dict:
            copy = json.loads(json.dumps(base))
            copy["sources"][index].update(fields)
            return copy

        self.assertLexicon("version", wl.load_manifest, base | {"version": 1})
        self.assertLexicon("pending", wl.load_manifest, changed(0, sha256="pending"))
        self.assertLexicon("malformed", wl.load_manifest, changed(0, sha256="abc"))
        self.assertLexicon("malformed", wl.load_manifest, changed(0, file="../cmudict.dict"))
        self.assertLexicon("malformed", wl.load_manifest, changed(0, url="http://example.org"))
        self.assertLexicon("malformed", wl.load_manifest, changed(0, provider="nope"))
        self.assertLexicon("licence", wl.load_manifest, changed(0, licence=""))
        self.assertLexicon("licence", wl.load_manifest, changed(0, notice=""))
        self.assertLexicon("malformed", wl.load_manifest, changed(1, id="cmu"))

    def test_notice_files_are_read_whole_and_checked(self):
        text = "  1 Princeton notice line with trailing spaces  \n  2 ```inner fence```  \n"
        pin = hashlib.sha256(text.encode("utf-8")).hexdigest()
        entry = {"id": "oewn", "notice_files": [{"file": "N.txt", "marker": "Princeton", "sha256": pin}]}
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "N.txt").write_text(text, encoding="utf-8")
            [notice] = wl.read_notices(entry, Path(tmp))
            self.assertEqual(notice["text"], text)
            self.assertEqual(notice["sha256"], pin)
            sidecar = wl.notices_text("p.jsonl", "f" * 64, [(SRC, [notice])])
            self.assertIn(text, sidecar)
            self.assertIn("````text\n", sidecar)
            (Path(tmp) / "N.txt").write_text(text + "changed\n", encoding="utf-8")
            self.assertLexicon("hash", wl.read_notices, entry, Path(tmp))
            wrong = "wrong file"
            (Path(tmp) / "N.txt").write_text(wrong, encoding="utf-8")
            pinned_wrong = {"id": "oewn", "notice_files": [
                {"file": "N.txt", "marker": "Princeton", "sha256": hashlib.sha256(wrong.encode()).hexdigest()}]}
            self.assertLexicon("licence", wl.read_notices, pinned_wrong, Path(tmp))
            self.assertLexicon("missing", wl.read_notices,
                               entry | {"notice_files": [{"file": "M", "marker": "x", "sha256": pin}]}, Path(tmp))

    def test_notice_files_must_be_pinned(self):
        base = self.shipped()
        oewn = next(i for i, s in enumerate(base["sources"]) if s["id"] == "oewn")
        for pin, kind in ((None, "malformed"), ("pending", "pending"), ("ABC", "malformed")):
            with self.subTest(pin=pin):
                copy = json.loads(json.dumps(base))
                item = copy["sources"][oewn]["notice_files"][0]
                if pin is None:
                    del item["sha256"]
                else:
                    item["sha256"] = pin
                self.assertLexicon(kind, wl.load_manifest, copy)
        for entry in base["sources"]:
            for item in entry.get("notice_files") or []:
                self.assertTrue(wl.SHA256_HEX.fullmatch(item.get("sha256", "")), item["file"])


# --- the build ------------------------------------------------------------------------------------------------

WNDB = "  1 This software and database is being provided  \n  2 WordNet 3.1 Copyright 2011 by Princeton University.  \n"
OEWN_LICENSE = "This resource is derived from Princeton WordNet under the WordNet License.\n"


class BuildTests(Raises, unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.raw = root / "raw"
        self.raw.mkdir()
        (self.raw / "cmudict.dict").write_text(";;; comment\npossible P AA1 S AH0 B AH0 L\n", encoding="utf-8")
        with zipfile.ZipFile(self.raw / "oewn-2025-json.zip", "w") as archive:
            for name, doc in oewn_docs():
                archive.writestr(name, json.dumps(doc, ensure_ascii=False))
        with gzip.open(self.raw / "etymology-2023-12.csv.gz", "wt", encoding="utf-8", newline="") as handle:
            handle.writelines(ety(
                ("p", "English", "possible", "borrowed_from", "lat", "Latin", "possibilis"),
                ("p", "English", "possible", "has_prefix", "x", "English", "pre-"),
            ))
        (self.raw / "eng.inflectional.v1.tsv").write_text("possible\tpossibles\tN|PL\tpossible|s\n", encoding="utf-8")
        (self.raw / "eng.derivational.v1.tsv").write_text(
            "possible\tpossibly\tJ\tR\tly\tsuffix\n"
            "run\tember\tV\tJ\tumb\tprefix\n"
            "moon\tmonth\tN\tN\tth\tsuffix\n"
            "a\tare\tU\tN\tre\tsuffix\n",
            encoding="utf-8",
        )
        (self.raw / "oewn-WNDB_License.txt").write_text(WNDB, encoding="utf-8")
        (self.raw / "globalwordnet-english-wordnet-LICENSE.md").write_text(OEWN_LICENSE, encoding="utf-8")
        self.manifest = root / "manifest.json"
        self.write_manifest()
        kaikki = root / "kaikki"
        kaikki.mkdir()
        data = kaikki_lines()[0].encode("utf-8")
        (kaikki / "impossible.jsonl").write_bytes(data)
        self.receipt = kaikki / "receipt.json"
        self.receipt.write_text(json.dumps([{
            "word": "impossible", "url": "https://kaikki.org/dictionary/English/meaning/i/im/impossible.jsonl",
            "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(), "snapshot": "2026-10-21 snapshot",
        }]), encoding="utf-8")
        self.root = root

    def tearDown(self):
        self.tmp.cleanup()

    def write_manifest(self) -> None:
        """The shipped manifest with every raw file and notice file pinned to the fixtures in `self.raw`."""
        manifest = json.loads((TOOLS / "word_lexicon_sources.json").read_text(encoding="utf-8"))
        for entry in manifest["sources"]:
            if "file" in entry:
                entry["sha256"], entry["bytes"] = wl.sha256_file(self.raw / entry["file"])
            for item in entry.get("notice_files") or []:
                item["sha256"] = wl.sha256_file(self.raw / item["file"])[0]
        self.manifest.write_text(json.dumps(manifest), encoding="utf-8")

    def run_build(self, name: str) -> dict:
        return wl.build(self.raw, self.root / name / "words.jsonl", self.manifest, kaikki_receipts=[self.receipt])

    def test_end_to_end(self):
        result = self.run_build("a")
        pack = (self.root / "a" / "words.jsonl").read_text(encoding="utf-8")
        lines = pack.splitlines()
        header = json.loads(lines[0])
        self.assertEqual(header["schema"], "xdict-word-pack")
        self.assertEqual([s["id"] for s in header["sources"]],
                         ["cmu", "ety", "kaikki:impossible", "morphynet-deri", "morphynet-infl", "oewn"])
        records = [json.loads(line) for line in lines[1:]]
        self.assertNotIn(PLACEHOLDER, pack)
        self.assertIn({"type": "origin", "id": "ety:p", "language": "English", "form": "possible", "word": "possible"},
                      records)
        self.assertNotIn("ety:x", pack)
        self.assertIn({"type": "derivation", "base": "possible", "derived": "impossible", "derivedPos": "adj",
                       "kind": "prefix", "affix": "im-", "source": "kaikki:impossible"}, records)
        self.assertEqual(result["records"], {k: sum(1 for r in records if r["type"] == k) for k in wl.RECORD_TYPES})
        notices = (self.root / "a" / "words.notices.md").read_text(encoding="utf-8")
        self.assertIn(result["packSha256"], notices)
        self.assertIn(WNDB, notices)
        self.assertIn(OEWN_LICENSE, notices)
        self.assertIn("NOR ITS EMPLOYEES BE LIABLE", notices)
        self.assertIn("Attribution-ShareAlike 4.0", notices)
        self.assertTrue((self.root / "a" / "words.report.json").is_file())
        self.assertNotIn('"derived":"ember"', pack)
        self.assertNotIn('"derived":"month"', pack)
        self.assertIn('"derived":"possibly"', pack)
        self.assertEqual(
            {k: v for k, v in result["skipped"].items() if k.startswith("morphynet-deri: ")},
            {"morphynet-deri: prefix spelling change not modelled": 1,
             "morphynet-deri: suffix spelling change not modelled": 1,
             "morphynet-deri: undocumented POS U": 1},
        )
        report = json.loads((self.root / "a" / "words.report.json").read_text(encoding="utf-8"))
        self.assertEqual(report["skipped"], result["skipped"])

    def test_fable_report_carries_bounded_metadata_samples(self):
        result = self.run_build("a")
        report = json.loads((self.root / "a" / "words.report.json").read_text(encoding="utf-8"))
        self.assertEqual(report["skippedSamples"], result["skippedSamples"])
        self.assertEqual(
            {k: v for k, v in result["skipped"].items() if k.startswith("morphynet-deri: ")},
            {"morphynet-deri: prefix spelling change not modelled": 1,
             "morphynet-deri: suffix spelling change not modelled": 1,
             "morphynet-deri: undocumented POS U": 1},
        )
        samples = result["skippedSamples"]
        self.assertEqual(
            samples["morphynet-deri: prefix spelling change not modelled"],
            [{"line": 2, "base": "run", "derived": "ember", "basePos": "V", "derivedPos": "J", "affix": "umb",
              "kind": "prefix"}],
        )
        self.assertEqual(
            samples["morphynet-deri: undocumented POS U"],
            [{"line": 4, "base": "a", "derived": "are", "basePos": "U", "derivedPos": "N", "affix": "re",
              "kind": "suffix"}],
        )
        for reason, items in samples.items():
            with self.subTest(reason=reason):
                self.assertIn(reason, result["skipped"])
                self.assertLessEqual(len(items), min(wl.MAX_SKIPPED_SAMPLES, result["skipped"][reason]))
                self.assertTrue(all(item.keys() <= SAMPLE_FIELDS for item in items), items)
        self.assertNotIn(PLACEHOLDER, json.dumps(report, ensure_ascii=False))
        # No current provider supplies a stem alignment, and none is inferred.
        pack = (self.root / "a" / "words.jsonl").read_text(encoding="utf-8").splitlines()
        self.assertFalse(any("stem" in json.loads(line) for line in pack[1:]))

    def test_two_builds_are_byte_identical(self):
        self.run_build("a")
        self.run_build("b")
        for name in ("words.jsonl", "words.notices.md"):
            self.assertEqual((self.root / "a" / name).read_bytes(), (self.root / "b" / name).read_bytes(), name)

    def test_cli(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = wl.main(["build", "--raw-dir", str(self.raw), "--output", str(self.root / "c" / "w.jsonl"),
                            "--manifest", str(self.manifest), "--kaikki-input", str(self.receipt)])
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out.getvalue())["sources"][0], "cmu")
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(wl.main(["verify", "--raw-dir", str(self.raw), "--manifest", str(self.manifest)]), 0)

    def test_refusals(self):
        (self.raw / "cmudict.dict").write_text("tampered P AA1\n", encoding="utf-8")
        self.assertLexicon("hash", self.run_build, "a")
        (self.raw / "cmudict.dict").unlink()
        self.assertLexicon("missing", self.run_build, "a")

    def test_output_inside_the_repository_is_refused(self):
        # A repository of its own (a `.git` marker), so this runs with or without a real checkout around it.
        repo = self.root / "checkout"
        tools = repo / "core" / "tools"
        tools.mkdir(parents=True)
        (repo / ".git").mkdir()
        self.assertEqual(wl.repository_root(tools.resolve()), repo.resolve())
        self.assertIsNone(wl.repository_root((self.root / "raw").resolve()))
        inside = repo / "pack" / "never-written.jsonl"
        self.assertLexicon("malformed", wl.refuse_inside_repository, inside, tools)
        self.assertLexicon("malformed", wl.refuse_inside_repository, tools / "w.jsonl", tools)
        wl.refuse_inside_repository(self.root / "outside" / "w.jsonl", tools)
        wl.refuse_inside_repository(inside, self.root / "raw")
        with mock.patch.object(wl, "TOOLS_DIR", tools):
            self.assertLexicon("malformed", wl.build, self.raw, inside, self.manifest)
            self.assertFalse(inside.exists())
            self.assertFalse(inside.parent.exists())
            outside = self.root / "outside" / "words.jsonl"
            wl.build(self.raw, outside, self.manifest, kaikki_receipts=[self.receipt])
            self.assertTrue(outside.is_file())

    def test_notice_with_wrong_file_fails(self):
        (self.raw / "oewn-WNDB_License.txt").write_text("unrelated text\n", encoding="utf-8")
        self.assertLexicon("hash", self.run_build, "a")
        self.write_manifest()
        self.assertLexicon("licence", self.run_build, "a")


if __name__ == "__main__":
    unittest.main()
