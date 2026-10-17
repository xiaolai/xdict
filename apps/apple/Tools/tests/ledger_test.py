#!/usr/bin/env python3
"""The style ledger's own check (Tools/gallery/ledger.py): each failure mode shown red on a temporary ledger and
repository (positive controls), the real ledger green, and triage's known and NEW lines."""
import json
import os
import subprocess
import sys
import tempfile
import unittest

APPLE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LEDGER = os.path.join(APPLE, "Tools", "gallery", "ledger.py")
HEADER = "id\topened\tsymptom\trepro\tmechanism\trule\tfix_at\tguard\tstatus\tcommit\n"


def git(root, *args):
    return subprocess.run(["git", "-C", root, *args], check=True, capture_output=True, text=True).stdout.strip()


def run(*args):
    return subprocess.run([sys.executable, "-I", LEDGER, *args], capture_output=True, text=True)


class Check(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        root = cls.root = cls.tmp.name
        files = {
            "apps/apple/Sources/XDictEntryLab/GalleryChecks.swift": "note('G14', ok, 1, 'inset');\n",
            "apps/apple/Sources/XDictEntryLab/GalleryInvariants.swift": "var checks = { strayMarker: {} };\n",
            "apps/apple/Tests/T/FrameTests.swift": "struct FrameTests {\n    @Test func holds() {}\n}\n",
            "core/xdict-entry/tests/roles.rs": "#[test]\nfn a_rule_holds() {}\n",
        }
        for path, body in files.items():
            os.makedirs(os.path.join(root, os.path.dirname(path)), exist_ok=True)
            with open(os.path.join(root, path), "w") as f:
                f.write(body)
        git(root, "init", "-q")
        git(root, "-c", "user.name=t", "-c", "user.email=t@t", "add", ".")
        git(root, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "fixture")
        cls.sha = git(root, "rev-parse", "--short", "HEAD")

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def ledger(self, *rows):
        path = os.path.join(self.root, "ledger.tsv")
        with open(path, "w") as f:
            f.write(HEADER + "".join("\t".join(r) + "\n" for r in rows))
        return path

    def row(self, **over):
        r = {"id": "D1", "opened": "2026-10-17", "symptom": "a gap", "repro": "oald:clear@dark,ldoce:*",
             "mechanism": "m", "rule": "R9", "fix_at": "-", "guard": "G14", "status": "fixed", "commit": self.sha}
        r.update(over)
        return [r[k] for k in ("id", "opened", "symptom", "repro", "mechanism", "rule", "fix_at", "guard", "status",
                               "commit")]

    def check(self, *rows):
        return run("--ledger", self.ledger(*rows), "--root", self.root, "check")

    def red(self, needle, *rows):
        r = self.check(*rows)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn(needle, r.stderr)

    def test_a_good_ledger_is_green(self):
        r = self.check(self.row(), self.row(id="D2", guard="FrameTests.holds"),
                       self.row(id="D3", guard="xdict_entry::a_rule_holds"), self.row(id="D4", guard="strayMarker"),
                       self.row(id="D5", status="open", guard="-", commit="-", repro="-"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("5 rows (4 fixed, 1 open, 0 wontfix), 0 problems", r.stdout)

    def test_fixed_without_guard_or_commit(self):
        self.red("fixed without a guard and a commit", self.row(guard="-"))
        self.red("fixed without a guard and a commit", self.row(commit="-"))

    def test_an_undefined_gallery_check(self):
        self.red("guard 'G17' is defined nowhere", self.row(guard="G17"))

    def test_a_test_that_does_not_exist(self):
        self.red("guard 'FrameTests.missing'", self.row(guard="FrameTests.missing"))
        self.red("guard 'OtherTests.holds'", self.row(guard="OtherTests.holds"))
        self.red("guard 'xdict_entry::missing'", self.row(guard="xdict_entry::missing"))
        self.red("guard 'noSuchCheck'", self.row(guard="noSuchCheck"))

    def test_a_commit_that_does_not_exist(self):
        self.red("commit 'deadbee' does not exist", self.row(commit="deadbee"))

    def test_duplicate_ids(self):
        self.red("duplicate id", self.row(), self.row())

    def test_bad_status(self):
        self.red("bad status 'done'", self.row(status="done"))

    def test_malformed_repro(self):
        self.red("malformed repro", self.row(repro="oald clear"))
        self.red("malformed repro", self.row(repro="oald:clear@"))

    def test_private_text(self):
        self.red("an absolute path or an IP address", self.row(fix_at="/Users/x/file"))

    def test_a_short_row(self):
        path = self.ledger(self.row())
        with open(path, "a") as f:
            f.write("D2\tonly three\tfields\n")
        r = run("--ledger", path, "--root", self.root, "check")
        self.assertEqual(r.returncode, 1)
        self.assertIn("3 fields, not 10", r.stderr)

    def test_known_commits_stand_in_for_history(self):
        # A copy without history (make land's snapshot) checks commits against the list the Air sent with it.
        known = os.path.join(self.root, "known")
        with open(known, "w") as f:
            f.write("0123456789abcdef0123456789abcdef01234567\n")
        r = run("--ledger", self.ledger(self.row()), "--root", self.root, "check", "--known-commits", known)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn(f"commit '{self.sha}' does not exist", r.stderr)
        with open(known, "a") as f:
            f.write(git(self.root, "rev-parse", self.sha) + "\n")
        r = run("--ledger", self.ledger(self.row()), "--root", self.root, "check", "--known-commits", known)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_the_real_ledger_is_green(self):
        known = os.environ.get("XDICT_KNOWN_COMMITS")
        r = run("check", *(["--known-commits", known] if known else []))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("0 problems", r.stdout)


class Triage(unittest.TestCase):
    def test_known_and_new(self):
        with tempfile.TemporaryDirectory() as tmp:
            ledger = os.path.join(tmp, "l.tsv")
            with open(ledger, "w") as f:
                f.write(HEADER + "D1\t2026-10-17\tgutter\toald:clear\tm\tR9\t-\tG14\topen\t-\n"
                        + "D2\t2026-10-17\tbullet\tnoad:harm\tm\tR9\t-\tstrayMarker\topen\t-\n")
            report = os.path.join(tmp, "report.json")
            with open(report, "w") as f:
                json.dump({"failures": [
                    "oald core-light clear: G14 off for 1 of 9: inset 14px ×1",
                    "oald core-dark clear: G14 off for 1 of 9: inset 14px ×1",
                    "oald core-light set off: G14 off for 2 of 9: x ×2",
                    "noad core-light harm: R invariant strayMarker off for 1 of 69: x ×1",
                    "cald core-dark cool off: a speaker against the word before it (speakerTight 2.0)",
                    "ode dark: G2 the dominant size is 18.5px (10 of 12 characters)",
                ]}, f)
            r = run("--ledger", ledger, "triage", report)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn("KNOWN: G14 oald:clear — D1 (open, exact)", r.stdout)
            self.assertIn("KNOWN: G14 oald:set off — D1 (open, same dictionary)", r.stdout)
            self.assertIn("KNOWN: strayMarker noad:harm — D2", r.stdout)
            self.assertIn("NEW: speakerTight cald:cool off — not in the ledger", r.stdout)
            self.assertIn("NEW: G2 ode:* — not in the ledger", r.stdout)
            self.assertIn("5 distinct failures, 3 known, 2 new", r.stdout)


class Repro(unittest.TestCase):
    def test_dry_run_names_hot_and_the_entries(self):
        r = run("repro", "D7", "--dry-run", "--theme", "dark")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("hot.sh ldoce:bloody ldoce:cripple", r.stdout)
        self.assertIn("*-dark.jpg", r.stdout)

    def test_a_row_with_no_entry_refuses(self):
        r = run("repro", "D38", "--dry-run")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("no entry to render yet", r.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=1)
