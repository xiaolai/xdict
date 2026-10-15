#!/usr/bin/env python3
"""The hostile battery's own tests (`Tools/hostile/battery.py`, `analyze.py`): what the cases and runs say, and how a
case's outcome is told: it left, the core stripped its script, the core dropped it as a comment (S2), or the view
blocked it. Runs nothing remote and opens nothing: `make test-tools`.

    python3 -I Tools/tests/hostile_test.py
"""
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "hostile"))
import analyze  # noqa: E402
import battery  # noqa: E402


class Battery(unittest.TestCase):
    def setUp(self):
        self.cases = {c["id"]: c for c in battery.cases()}

    def test_strip_is_a_layer_on_only_in_its_own_run_and_production(self):
        self.assertIn("strip", battery.LAYERS)
        self.assertEqual(battery.RUNS["strip"], ["strip"])
        self.assertEqual(battery.RUNS["production"], battery.LAYERS)
        self.assertEqual(battery.RUNS["shell"], [layer for layer in battery.LAYERS if layer != "strip"])
        on = [label for label, layers in battery.RUNS.items() if "strip" in layers]
        self.assertEqual(sorted(on), ["production", "strip"])
        self.assertEqual(battery.PRODUCTION_PART, ["shell", "production"])
        probe = battery.PROBES["strip"]
        self.assertEqual((probe["run"], probe["against"]), ("strip", "baseline"))

    def test_scripts_are_counted_as_written_and_as_the_core_sees_them(self):
        # At byte zero the core sees the script; behind the textarea comment it reads a comment (S2).
        self.assertEqual((self.cases["fetch"]["scripts"], self.cases["fetch"]["scriptsVisible"]), (1, 1))
        t = self.cases["script~textarea"]
        self.assertEqual((t["scripts"], t["scriptsVisible"]), (1, 0))

    def test_a_script_holding_script_markup_in_a_string_is_one_element(self):
        # The core writes a kept script's `<script` as `\x3Cscript`, the same JavaScript string: counted as substrings,
        # the strip-off run would see one fewer served and call the case stripped (`nav-blob-url`, 2026-10-16).
        page = '<script>var s="<script>R(1)</" + "script>";</script>'
        self.assertEqual((battery.script_elements(page), battery.visible_scripts(page)), (1, 1))
        served = '<script>var s="\\x3Cscript>R(1)</" + "script>";</script>'
        self.assertEqual(analyze.outcome(False, battery.script_elements(page), battery.visible_scripts(page),
                                         battery.script_elements(served)), "blocked")
        blob = self.cases["nav-blob-url"]
        self.assertEqual((blob["scripts"], blob["scriptsVisible"]), (1, 1))

    def test_no_case_reports_through_a_script_of_the_harness(self):
        # The lab's own world says a page loaded; no record carries the old `R('loaded')`.
        for c in self.cases.values():
            self.assertNotIn("R('loaded'", c["record"], c["id"])
        self.assertTrue(self.cases["ok-xdict"]["probe"])
        self.assertTrue(self.cases["ok-link-nav"]["probe"])


class Outcomes(unittest.TestCase):
    def test_each_outcome_by_its_cause(self):
        self.assertEqual(analyze.outcome(left=True, written=1, visible=1, served=0), "left")
        self.assertEqual(analyze.outcome(left=False, written=1, visible=1, served=0), "stripped")
        self.assertEqual(analyze.outcome(left=False, written=1, visible=0, served=0), "commented")
        self.assertEqual(analyze.outcome(left=False, written=1, visible=1, served=1), "blocked")
        self.assertEqual(analyze.outcome(left=False, written=None, visible=None, served=None), "blocked")

    def test_ok_xdict_expects_its_scripts_stripped_only_when_they_were(self):
        drawn = {"img", "data-img", "css", "audio"}
        self.assertEqual(analyze.ok_xdict_broken(drawn, stripped=True), [])
        self.assertEqual(analyze.ok_xdict_broken(drawn, stripped=False), ["eval", "function", "inline", "script"])
        self.assertEqual(analyze.ok_xdict_broken(drawn - {"css"}, stripped=True), ["css"])


class Runs(unittest.TestCase):
    """`summarize` over a run directory made here: three cases, one per outcome the view's run can give."""

    def run_dir(self, served):
        d = tempfile.mkdtemp()
        cases = [{"id": cid, "payload": cid, "context": "byte-zero", "group": "g", "tcp": 47100 + i, "udp": 47400 + i,
                  "names": [], "scripts": 1, "scriptsVisible": visible}
                 for i, (cid, visible) in enumerate([("a", 1), ("b", 0), ("ok-xdict", 1)])]
        listed = {"token": "h1", "control": {"http": 47090, "tcp": 47091, "udp": 47390}, "selftestName": "s.invalid",
                  "reader": {"tcp": 1, "udp": 2}, "cases": cases}
        # Served is what the lab counted in the loaded document (`document.scripts`), the first time it read one.
        lab = {"cases": {c["id"]: {"loaded": True, "scriptsWritten": 1,
                                   "page": [["ok", k] for k in ("img", "data-img", "css", "audio")]
                                   + [["scripts", str(served[c["id"]])], ["scripts", "9"]]}
                         for c in cases}}
        files = {"cases.json": json.dumps(listed), "report.json": json.dumps(lab), "observed.jsonl": "",
                 "oracle.json": json.dumps({"asked": [], "pid": 0}), "lab.started": "0", "lab.ended": "1",
                 "dns.ndjson": ""}
        for name, text in files.items():
            with open(os.path.join(d, name), "w") as f:
                f.write(text)
        return d

    def test_a_run_counts_stripped_commented_and_blocked_apart(self):
        s = analyze.summarize(self.run_dir({"a": 0, "b": 0, "ok-xdict": 0}))
        self.assertEqual(s["outcomes"], {"left": 0, "stripped": 2, "commented": 1, "blocked": 0})
        self.assertEqual(s["cases"]["ok-xdict"]["broken"], [])
        s = analyze.summarize(self.run_dir({"a": 1, "b": 1, "ok-xdict": 1}))
        self.assertEqual(s["outcomes"], {"left": 0, "stripped": 0, "commented": 0, "blocked": 3})
        self.assertEqual(s["cases"]["ok-xdict"]["broken"], ["eval", "function", "inline", "script"])

    def test_the_parts_split_the_runs(self):
        with open(os.path.join(battery.FIXTURE, "cases.json")) as f:
            listed = json.load(f)
        out = lambda *a: analyze.runs_of(listed, *a)
        self.assertEqual(out("production"), ["shell", "production"])
        self.assertNotIn("production", out("controls"))
        self.assertIn("strip", out("controls"))
        self.assertEqual(len(out(None)), len(out("production")) + len(out("controls")))


if __name__ == "__main__":
    unittest.main(verbosity=1)
