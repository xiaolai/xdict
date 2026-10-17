#!/usr/bin/env python3
"""The dependency matrix of the E2E keys, on this checkout: **every harness, kit and fixture input reaches the key of
every sub-stage that executes it** (Tools/gate-cache.py `inputs`, which the E2E ledger keys with). Reads files and the
graph only; changes nothing and runs nothing.

The expectation here is derived independently of Tools/affected_graph.py's own derivation: from what `Tools/e2e.sh`
runs for every sub-stage (itself and the plan), from what each need's builder reads (the kit's `Tools/build-lab.sh`,
the fixtures' `Tools/build-fixtures.sh` and the core's fixture writer over `conformance/fixtures`, the sample's
`entries_corpus`, the editions' `index_bench` and `editions.py`, the corpus's expectations), and from every instrument
function that reads the string catalog in Chinese.
"""
import importlib.util
import os
import re
import subprocess
import sys
import unittest

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APPLE = os.path.dirname(TOOLS)
REPO = os.path.dirname(os.path.dirname(APPLE))


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


CACHE = load("gate_cache", os.path.join(TOOLS, "gate-cache.py"))
LISTING = CACHE.files()
MODULE, GRAPH = CACHE.load_graph(LISTING)
SUBS = list(GRAPH.order)
INPUTS = {s: set(m) for s, m in zip(SUBS, (CACHE.inputs([f"e2e:{s}" for s in SUBS], LISTING, GRAPH, MODULE.GATES)
                                             [f"e2e:{s}"] for s in SUBS))}
TABLE = subprocess.run(["bash", os.path.join(TOOLS, "e2e-plan.sh"), "table"], check=True, capture_output=True,
                       text=True).stdout.splitlines()
OWNER = {row.split("\t")[4]: row.split("\t")[0] for row in TABLE}


def needing(*needs):
    return {s for s in SUBS if set(GRAPH.needs[s]) & set(needs)}


def apple(path):
    return f"apps/apple/{path}"


def under(prefix):
    return {p for p in LISTING if p.startswith(prefix)}


def referenced(script, base):
    """The repository files a script names, as paths from the repository's root (`base` is the script's directory
    relative to the root): `Tools/...`, `Resources/...`, `../../conformance/...`, `Sources/...`."""
    with open(os.path.join(REPO, base, script), encoding="utf-8") as source:
        text = "\n".join(line for line in source.read().splitlines() if not line.lstrip().startswith("#"))
    found = set()
    for word in re.findall(r"(?:\.\./\.\./)?(?:Tools|Resources|Sources|conformance|core)/[A-Za-z0-9_./-]+", text):
        rel = word[6:] if word.startswith("../../") else os.path.join(base, word)
        rel = os.path.normpath(rel).rstrip("/")
        hits = {p for p in LISTING if p == rel or p.startswith(rel + "/")}
        found |= hits
    return found


class Matrix(unittest.TestCase):
    def reaches(self, path, subs, why):
        self.assertIn(path, LISTING, f"{path} is not in the tree")
        missing = sorted(s for s in subs if path not in INPUTS[s])
        self.assertFalse(missing, f"{path} ({why}) does not reach the key of {missing}")

    def test_codex_cases(self):
        """The cases the 2026-10-17 refutation found unkeyed."""
        cases = [
            (apple("Tools/e2e.sh"), {"sound.speech"}),
            (apple("Tools/build-lab.sh"), {"hostile.production"}),
            (apple("Tools/lookup/keys.swift"), {"sound.notices"}),
            (apple("Tools/hostile/analyze.py"), {"entries.quick"}),
            ("core/xdict-core/tests/entries_corpus.rs", {"sound.recordings", "entries.lab"}),
            ("conformance/fixtures/hostile/dictionary.json", {"hostile.faults"}),
            (apple("Strings/Localizable.xcstrings"), {"library.generated"}),
        ]
        for path, subs in cases:
            self.reaches(path, subs, "a refuted case")

    def test_what_every_sub_stage_runs(self):
        for path in ("Tools/e2e.sh", "Tools/e2e-run.sh", "Tools/e2e-plan.sh", "Tools/e2e-substages.txt", "Makefile"):
            self.reaches(apple(path), SUBS, "runs every sub-stage")

    def test_the_kit(self):
        kit = needing("kit")
        inputs = {apple("Tools/build-lab.sh")} | referenced("Tools/build-lab.sh", "apps/apple")
        inputs |= under("conformance/fixtures/")   # the core's fixture writer, which build-lab.sh runs, reads them
        self.assertGreater(len(inputs), 20)
        for path in sorted(inputs):
            self.reaches(path, kit, "the kit is built of it")

    def test_the_fixtures(self):
        fixtures = needing("fixtures")
        inputs = {apple("Tools/build-fixtures.sh")} | under("conformance/fixtures/")
        for path in sorted(inputs):
            self.reaches(path, fixtures, "the fixtures are written of it")

    def test_the_sample_editions_and_corpus(self):
        for path in ("core/xdict-core/tests/entries_corpus.rs", apple("Tools/core-on-host.sh")):
            self.reaches(path, needing("sample"), "the sample is made by it")
        for path in ("core/xdict-core/examples/index_bench.rs", apple("Tools/library/editions.py"),
                     apple("Tools/core-on-host.sh")):
            self.reaches(path, needing("editions"), "the editions are made by it")
        self.reaches(apple("Tools/library/health-expected.json"), needing("corpus"), "shipped with the corpus")

    def test_every_chinese_sentence_check_reads_the_catalog(self):
        """Every instrument function that renders a catalog string in Chinese (`String(localized:` and `zh-Hans`):
        each check it reports belongs to a sub-stage the catalog reaches."""
        owners = {}
        for top in ("Sources/XDict", "Sources/XDictInstruments", "Sources/XDictUI"):
            for root, _, names in os.walk(os.path.join(APPLE, top)):
                for name in names:
                    if name.endswith(".swift"):
                        with open(os.path.join(root, name), encoding="utf-8") as source:
                            text = source.read()
                        for check in chinese_checks(text):
                            owners[check] = os.path.join(top, name)
        self.assertTrue(owners, "the audit found no sentence check at all")
        for check, where in sorted(owners.items()):
            sub = OWNER.get(check)
            self.assertIsNotNone(sub, f"{check} ({where}) belongs to no sub-stage")
            self.reaches(apple("Strings/Localizable.xcstrings"), {sub}, f"{check} in {where} reads it in Chinese")


def chinese_checks(text):
    """`check("…"` names in each Swift function whose body holds both `String(localized` and `zh-Hans`."""
    out = set()
    for match in re.finditer(r"\bfunc\s+\w+[^{]*\{", text):
        depth, i = 1, match.end()
        while depth and i < len(text):
            depth += {"{": 1, "}": -1}.get(text[i], 0)
            i += 1
        body = text[match.end():i]
        if "String(localized" in body and "zh-Hans" in body:
            # Every check name the function spells, as `check("…"` or in a table it checks by (`("sentence.x", …)`).
            out |= {word for word in re.findall(r'"([A-Za-z0-9_.]+)"', body) if word in OWNER}
    return out


if __name__ == "__main__":
    unittest.main(verbosity=1)
