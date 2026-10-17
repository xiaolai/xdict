#!/usr/bin/env python3
"""The UI tour's tree checks (Tools/ui-tour/axcheck.py) and its route table (routes.py): each check red on a tree that
has the fault and quiet on one that has not; every route id unique, every undriven route saying why."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ui-tour"))
import axcheck  # noqa: E402
from routes import NOT_DRIVEN_WHY, ROUTES  # noqa: E402


def window(*children):
    return {"windows": [{"role": "AXWindow", "frame": [0, 0, 400, 300], "children": list(children)}]}


def kinds(tree):
    return sorted(f["kind"] for f in axcheck.checks(tree))


good = window({"role": "AXButton", "title": "Add", "frame": [10, 10, 60, 20]},
              {"role": "AXStaticText", "value": "Name", "frame": [80, 10, 60, 20]})
assert kinds(good) == [], kinds(good)
assert kinds(window({"role": "AXButton", "frame": [10, 10, 20, 20]})) == ["unlabelled"]
assert kinds(window({"role": "AXStaticText", "value": "x", "frame": [380, 10, 60, 20]})) == ["outside-window"]
# Content scrolled out of view is not clipping.
assert kinds(window({"role": "AXScrollArea", "frame": [0, 0, 400, 300],
                     "children": [{"role": "AXStaticText", "value": "x", "frame": [0, 900, 60, 20]}]})) == []
assert kinds(window({"role": "AXStaticText", "value": "a", "frame": [10, 10, 60, 20]},
                    {"role": "AXStaticText", "value": "b", "frame": [20, 12, 60, 20]})) == ["overlap"]
# The window's own buttons carry no title by design.
assert kinds(window({"role": "AXButton", "subrole": "AXCloseButton", "frame": [4, 4, 12, 12]})) == []

ids = [r[0] for r in ROUTES]
assert len(ids) == len(set(ids)), "route ids repeat"
assert all(r[1] in ("full", "empty", "reader") for r in ROUTES)
undriven = {r[0] for r in ROUTES if r[4] is None}
assert undriven == set(NOT_DRIVEN_WHY), undriven ^ set(NOT_DRIVEN_WHY)
print(f"ui_tour_test: ok ({len(ROUTES)} routes, {len(undriven)} not driven)")
