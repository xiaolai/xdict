#!/usr/bin/env python3
"""The UI tour's tree checks (Tools/ui-tour/axcheck.py) and its route table (routes.py): each check red on a tree that
has the fault and quiet on one that has not; every route id unique, every undriven route saying why."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ui-tour"))
import json  # noqa: E402

import axcheck  # noqa: E402
import pseudo  # noqa: E402
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

# Parity P39: Settings ▸ Dictionaries is Apple's table: described "Dictionaries", a checkbox in every row, 20 pt rows.
def row(height=20, box=True):
    kids = [{"role": "AXCheckBox", "title": "Use in lookups", "value": 1, "frame": [4, 0, 19, 17]}] if box else []
    return {"role": "AXRow", "frame": [0, 0, 560, height], "children": kids}


def table(*rows, description="Dictionaries"):
    return window({"role": "AXScrollArea", "frame": [0, 0, 400, 200],
                   "children": [{"role": "AXTable", "description": description, "frame": [0, 0, 400, 200],
                                 "children": list(rows)}]})


def p39(tree):
    return sorted(f["kind"] for f in axcheck.dictionaries_table(tree))


assert p39(table(row(), row())) == [], p39(table(row(), row()))
assert p39(table(row(), description="search results")) == ["no-dictionaries-table"]
assert p39(table(row(), row(box=False))) == ["row-without-checkbox"]
assert p39(table(row(height=28))) == ["row-height"]
assert p39(table()) == ["no-rows"]
# In Chinese the description is 词典: XDict's table is found by its identifier.
zh = table(row(), description="词典")
zh["windows"][0]["children"][0]["children"][0]["identifier"] = "settings.dictionaries"
assert p39(zh) == [], p39(zh)

ids = [r[0] for r in ROUTES]
assert len(ids) == len(set(ids)), "route ids repeat"
assert all(r[1] in ("full", "empty", "reader") for r in ROUTES)
undriven = {r[0] for r in ROUTES if r[4] is None}
assert undriven == set(NOT_DRIVEN_WHY), undriven ^ set(NOT_DRIVEN_WHY)
# The pseudo language: longer, accented, every format directive kept exactly; on the real catalog, every value of every
# form (plural forms and substitutions included) keeps its source's directives, so the copy formats as the app does.
assert pseudo.pseudo("Look Up").startswith("⟦Ļööķ Ûþ"), pseudo.pseudo("Look Up")
for text in ["%lld files could not be added.", "%1$@ has %2$#@n@.", "%arg entries are", "Checking… %@", "100%%"]:
    made = pseudo.pseudo(text)
    assert pseudo.DIRECTIVE.findall(made) == pseudo.DIRECTIVE.findall(text), (text, made)
    visible = len(pseudo.DIRECTIVE.sub("", text))
    assert made.count("·") >= round(visible * 0.4), (text, made)
assert len(pseudo.pseudo("Remove from Library")) >= len("Remove from Library") * 1.4
with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "Strings", "Localizable.xcstrings"),
          encoding="utf-8") as f:
    catalog = json.load(f)


def values(node):
    if isinstance(node, dict):
        if "stringUnit" in node:
            yield node["stringUnit"]["value"]
        for key, kid in node.items():
            if key != "stringUnit":
                yield from values(kid)


built = pseudo.build(catalog)
assert set(built["strings"]) == set(catalog["strings"])
for key, entry in catalog["strings"].items():
    source = list(values(entry.get("localizations", {}).get("en") or {"stringUnit": {"value": key}}))
    made = list(values(built["strings"][key]["localizations"]["en"]))
    assert len(source) == len(made) and all(
        pseudo.DIRECTIVE.findall(a) == pseudo.DIRECTIVE.findall(b) for a, b in zip(source, made)), (key, made)
    assert all(m.startswith("⟦") and m != s for s, m in zip(source, made)), (key, made)
print(f"ui_tour_test: pseudo ok ({len(built['strings'])} keys)")
print(f"ui_tour_test: ok ({len(ROUTES)} routes, {len(undriven)} not driven)")
