#!/usr/bin/env python3
"""The lookup driver's readings of the window (`Tools/lookup/lookup_checks.py`): each check passes on the window the
parity design draws (P6 scope menu, P9-P11 merged results, P15 All page) and fails on the one the 2026-10-18 E2E run
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


def window(chosen="All Dictionaries", label=True):
    # The search field and its magnifier, the scope menu's button: "Search in", the chosen scope as its value (P6, P42).
    prompt = "Search" if chosen == "All Dictionaries" else f"Search in {chosen}"
    field = node("AXTextField", "search-field", [prompt], 2)
    menu = node("AXButton", "scope.menu", (["Search in"] if label else []) + [chosen], 3)
    table = [node("AXTable", "results", ["search results"], 2)] + [
        node("AXRow", "", [], 3) if i % 2 == 0 else node("AXStaticText", "", [w], 4)
        for i, w in enumerate(["", "apple", "", "apple polisher", "", "applet"])]
    page = [node("AXDisclosureTriangle", "page.divider.Beta", ["Beta", "1"], 3),
            node("AXDisclosureTriangle", "page.divider.LDOCE", ["LDOCE", "1"], 3)]
    return [node("AXWindow", "main", [], 0), field, menu] + table + page


SECTIONS = [("Alpha", "results"), ("Beta", "results"), ("Records", "noMatch"), ("LDOCE", "results")]


class Where(unittest.TestCase):
    def test_an_item_with_a_value_needs_the_value(self):
        # What the lookup instrument expects (LookupWindow.swift): the menu button's name, then the chosen scope.
        nodes = window(chosen="Beta")
        self.assertIsNotNone(checks.where("#scope.menu=Search in:Beta", nodes))
        self.assertIsNone(checks.where("#scope.menu=Search in:Alpha", nodes), "offered, not chosen")
        self.assertIsNone(checks.where("#scope.menu=Search in:Beta", window(chosen="Beta", label=False)))
        self.assertIsNotNone(checks.where("#scope.menu=Search in:Dict: Two", window(chosen="Dict: Two")),
                             "a name holding a colon")

    def test_judge_fails_an_empty_window(self):
        self.assertFalse(checks.judge("x", {"present": []}, [])["pass"])
        self.assertTrue(checks.judge("x", {"present": ["#scope.menu=Search in:All Dictionaries"]}, window())["pass"])


class Scope(unittest.TestCase):
    def test_the_menu_button_and_the_placeholder_name_the_chosen_scope(self):
        self.assertTrue(checks.scope_chosen(window(chosen="Beta"), "Beta")[0])
        self.assertFalse(checks.scope_chosen(window(chosen="All Dictionaries"), "Beta")[0])

    def test_the_placeholder_alone_or_the_button_alone_fails(self):
        nodes = [n if n["id"] != "search-field" else dict(n, texts=["Search"]) for n in window(chosen="Beta")]
        self.assertFalse(checks.scope_chosen(nodes, "Beta")[0], "the field still says Search")
        nodes = [n if n["id"] != "scope.menu" else dict(n, texts=["Search in", "All Dictionaries"])
                 for n in window(chosen="Beta")]
        self.assertFalse(checks.scope_chosen(nodes, "Beta")[0], "the button still says All Dictionaries")

    def test_the_old_scope_bar_fails(self):
        # Before 2026-10-18: a radio group of scope.option buttons, no menu button in the field.
        old = [node("AXRadioGroup", "scope", ["Dictionaries"], 2),
               node("AXRadioButton", "scope.option", ["Beta", "Beta", "1"], 3)]
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
    TOOLBAR = {"x": 0, "y": 225, "width": 800, "height": 52}

    def test_right_under_the_toolbar(self):
        ok, detail = checks.entry_placement({"toolbar": self.TOOLBAR, "web": {"x": 0, "y": 277, "width": 800,
                                                                             "height": 300}})
        self.assertTrue(ok, detail)

    def test_under_the_notices_when_shown(self):
        notices = {"x": 0, "y": 277, "width": 800, "height": 57}
        self.assertTrue(checks.entry_placement({"toolbar": self.TOOLBAR, "notices": notices,
                                                "web": {"x": 0, "y": 334, "width": 800, "height": 300}})[0])
        self.assertFalse(checks.entry_placement({"toolbar": self.TOOLBAR, "notices": notices,
                                                 "web": {"x": 0, "y": 277, "width": 800, "height": 300}})[0])

    def test_a_band_where_the_scope_bar_was_fails(self):
        # The scope bar's 36 pt row, gone since 2026-10-18: an entry still starting under it leaves a band.
        self.assertFalse(checks.entry_placement({"toolbar": self.TOOLBAR, "web": {"x": 0, "y": 313, "width": 800,
                                                                              "height": 300}})[0])

    def test_nothing_to_measure_is_no_verdict(self):
        ok, detail = checks.entry_placement({"toolbar": self.TOOLBAR, "web": None})
        self.assertIsNone(ok)
        self.assertIn("no toolbar or no entry", detail)


if __name__ == "__main__":
    unittest.main(verbosity=1)
