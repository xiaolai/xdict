#!/usr/bin/env python3
"""The lookup driver's readings of the window (`Tools/lookup/lookup_checks.py`): each check passes on the window the
parity design draws (P6 scope bar, P9-P11 merged results, P15 All page) and fails on the one the 2026-10-18 E2E run
read, so none of them can pass on an empty or a stale window.

    python3 -I Tools/tests/lookup_checks_test.py
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lookup"))
import lookup_checks as checks  # noqa: E402


def node(role, ident="", texts=(), depth=0):
    return {"role": role, "id": ident, "texts": list(texts), "depth": depth}


def window(chosen="All", label=True):
    group = node("AXRadioGroup", "scope", ["Dictionaries"] if label else [], 2)
    options = [node("AXRadioButton", "scope.option", [n, n, "1" if n == chosen else "0"], 3)
               for n in ("All", "Alpha", "Beta")]
    table = [node("AXTable", "results", ["search results"], 2)] + [
        node("AXRow", "", [], 3) if i % 2 == 0 else node("AXStaticText", "", [w], 4)
        for i, w in enumerate(["", "apple", "", "apple polisher", "", "applet"])]
    page = [node("AXDisclosureTriangle", "page.divider.Beta", ["Beta", "1"], 3),
            node("AXDisclosureTriangle", "page.divider.LDOCE", ["LDOCE", "1"], 3)]
    return [node("AXWindow", "main", [], 0), node("AXGroup", "scope.bar", [], 1), group] + options + table + page


SECTIONS = [("Alpha", "results"), ("Beta", "results"), ("Records", "noMatch"), ("LDOCE", "results")]


class Where(unittest.TestCase):
    def test_an_item_with_a_value_needs_the_value(self):
        nodes = window(chosen="Beta")
        self.assertIsNotNone(checks.where("#scope.option=1:Beta", nodes))
        self.assertIsNone(checks.where("#scope.option=1:Alpha", nodes), "shown, not chosen")
        self.assertIsNotNone(checks.where("#scope.option:Alpha", nodes))
        self.assertIsNotNone(checks.where("#scope:Dictionaries", nodes))
        self.assertIsNone(checks.where("#scope:Dictionaries", window(label=False)))

    def test_judge_fails_an_empty_window(self):
        self.assertFalse(checks.judge("x", {"present": []}, [])["pass"])
        self.assertTrue(checks.judge("x", {"present": ["#scope.option=1:All"]}, window())["pass"])


class Scope(unittest.TestCase):
    def test_the_chosen_option_alone_has_value_one(self):
        self.assertTrue(checks.scope_chosen(window(chosen="Beta"), "Beta")[0])
        self.assertFalse(checks.scope_chosen(window(chosen="All"), "Beta")[0])

    def test_the_old_unlabelled_group_fails(self):
        # 2026-10-18: the group read with no text at all and its buttons carried no identifier.
        old = [node("AXRadioGroup", "scope", [], 2), node("AXRadioButton", "", ["Beta"], 3)]
        self.assertFalse(checks.scope_chosen(old, "Beta")[0])


class Results(unittest.TestCase):
    def test_rows_in_order_and_each_later_dictionary_by_its_divider(self):
        ok, detail = checks.results_read(window(), ["apple", "apple polisher", "applet"], SECTIONS)
        self.assertTrue(ok, detail)

    def test_rows_out_of_order_fail(self):
        self.assertFalse(checks.results_read(window(), ["applet", "apple"], SECTIONS)[0])

    def test_a_missing_divider_fails(self):
        nodes = [n for n in window() if n["id"] != "page.divider.LDOCE"]
        self.assertFalse(checks.results_read(nodes, ["apple"], SECTIONS)[0])

    def test_the_first_dictionary_needs_no_divider(self):
        self.assertNotIn("page.divider.Alpha", [n["id"] for n in window()])
        self.assertTrue(checks.results_read(window(), ["apple"], SECTIONS)[0])

    def test_a_divider_without_its_name_fails(self):
        nodes = [dict(n, texts=[]) if n["id"] == "page.divider.Beta" else n for n in window()]
        self.assertFalse(checks.results_read(nodes, ["apple"], SECTIONS)[0])

    def test_the_old_window_fails(self):
        # 2026-10-18: no `results` table rows under that identifier, per-dictionary `result` rows expected.
        self.assertFalse(checks.results_read([], ["apple"], SECTIONS)[0])
        self.assertFalse(checks.results_read(window(), [], SECTIONS)[0], "no rows to read is not a reading")


class Placement(unittest.TestCase):
    BAR = {"x": 0, "y": 277, "width": 800, "height": 36}

    def test_under_the_scope_bar(self):
        ok, detail = checks.entry_placement({"scopeBar": self.BAR, "web": {"x": 0, "y": 313, "width": 800,
                                                                           "height": 300}})
        self.assertTrue(ok, detail)

    def test_under_the_notices_when_shown(self):
        notices = {"x": 0, "y": 313, "width": 800, "height": 57}
        self.assertTrue(checks.entry_placement({"scopeBar": self.BAR, "notices": notices,
                                                "web": {"x": 0, "y": 370, "width": 800, "height": 300}})[0])
        self.assertFalse(checks.entry_placement({"scopeBar": self.BAR, "notices": notices,
                                                 "web": {"x": 0, "y": 313, "width": 800, "height": 300}})[0])

    def test_right_under_the_toolbar_fails(self):
        # The pre-parity placement: the entry at the toolbar's bottom, under where the scope bar now is.
        self.assertFalse(checks.entry_placement({"scopeBar": self.BAR, "web": {"x": 0, "y": 277, "width": 800,
                                                                            "height": 300}})[0])

    def test_nothing_to_measure_is_no_verdict(self):
        ok, detail = checks.entry_placement({"scopeBar": self.BAR, "web": None})
        self.assertIsNone(ok)
        self.assertIn("no scope bar or no entry", detail)


if __name__ == "__main__":
    unittest.main(verbosity=1)
