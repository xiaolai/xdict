#!/usr/bin/env python3
"""The UI tour's tree checks (Tools/ui-tour/axcheck.py) and its route table (routes.py): each check red on a tree that
has the fault and quiet on one that has not; every route id unique, every undriven route saying why."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ui-tour"))
import json  # noqa: E402

import axcheck  # noqa: E402
import parity  # noqa: E402
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
# Hover's routes (plan-capture WI-5): the General rows and the Screen Recording row as this Mac's grant leaves them,
# driven; the row's other states and the hover popover, which need a grant changed or another app's text, not.
hover_driven = {"settings.general.hover", "settings.general.screenRecording", "menubar.hoverPause",
                "menubar.hoverPaused", "menubar.hoverOff"}
hover_undriven = {"settings.general.screenRecordingNotSetUp", "settings.general.screenRecordingNotAllowed",
                  "settings.general.screenRecordingAllowed", "settings.general.screenRecordingCouldNotTell",
                  "hover.popover"}
assert hover_driven <= set(ids) - undriven, hover_driven - (set(ids) - undriven)
assert hover_undriven <= undriven, hover_undriven - undriven
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

# The Apple Dictionary parity checks (parity.py): every rule green on trees shaped as Apple's Dictionary measured
# (dev-docs/artifacts/apple-dictionary/apple/*.ax.json, menubar.json) and red on trees shaped as XDict's main window was
# before the parity work (the UI tour's captures of 2026-10-17). Every route a rule names is a driven route.
def node(role, frame=(0, 0, 10, 10), children=(), **attrs):
    return dict(role=role, frame=list(frame), children=list(children), **attrs)


def button(name, x, help_text):
    return node("AXButton", (x, 8, 36, 36), description=name, help=help_text)


def rowed(*words, semibold=0):
    return node("AXTable", (0, 52, 183, 600), [
        node("AXRow", (0, 52 + 28 * i, 183, 28), [node("AXCell", (16, 52 + 28 * i, 151, 28), [
            node("AXStaticText", (19, 57 + 28 * i, 149, 18), value=w,
                 font=[{"name": ".AppleSystemUIFontDemi" if i == semibold else ".AppleSystemUIFont", "size": 13}])])])
        for i, w in enumerate(words)], description="search results")


def scope_menu(chosen):
    """The search field's magnifier, the scope menu's button (P6, XDict's own since 2026-10-18; P42)."""
    return node("AXButton", (523, 14, 28, 24), description="Search In", identifier="scope.menu", value=chosen)


def apple_window(title, *extra, chosen="All Dictionaries"):
    placeholder = "Search" if chosen == "All Dictionaries" else f"Search in {chosen}"
    return {"windows": [node("AXWindow", (0, 0, 859, 837), [
        node("AXToolbar", (0, 0, 859, 52), [
            button("Back", 100, "Show the previous result"), button("Forward", 136, "Show the next result"),
            button("Smaller Text", 440, "Decrease font size"), button("Bigger Text", 476, "Increase font size"),
            node("AXTextField", (520, 7, 327, 38), [scope_menu(chosen)], subrole="AXSearchField",
                 placeholder=placeholder),
            node("AXStaticText", (180, 0, 200, 52), value="XDict")]),
        *extra], subrole="AXStandardWindow", title=title)]}


# The scope bar XDict had before 2026-10-18, a radio group under the toolbar: P6 is red on it now.
scope_bar = node("AXRadioGroup", (183, 52, 676, 36), [node("AXRadioButton", (190 + 60 * i, 59, 60, 22), title=t,
                                                           value="1" if i == 0 else "0")
                                                      for i, t in enumerate(["All", "Alpha", "Beta"])])


def old_window(title, *extra):
    return {"windows": [node("AXWindow", (0, 0, 1000, 700), [
        node("AXToolbar", (0, 0, 1000, 52), [
            button("Back", 330, "Back"), button("Forward", 360, "Forward"),
            node("AXPopUpButton", (600, 8, 150, 30), description="Dictionaries", identifier="scope"),
            node("AXTextField", (760, 7, 240, 38), subrole="AXSearchField", placeholder="Look Up")]),
        *extra], subrole="AXStandardWindow", title=title)]}


def keys(*items):
    return [dict(title=t, key=k, mods=m) for t, k, m in items]


apple_menus = {"menubar": [
    {"title": "XDict", "items": [{"title": "Services", "items": []}]},
    {"title": "File", "items": keys(("New Window", "N", 0), ("New Tab", "T", 0), ("Print…", "P", 0))},
    {"title": "Edit", "items": [{"title": "Find", "items": keys(
        ("Search For a New Word…", "F", 2), ("Find…", "F", 0), ("Find Next", "G", 0), ("Find Previous", "G", 1),
        ("Use Selection for Find", "E", 0), ("Jump to Selection", "J", 0))}]},
    {"title": "View", "items": keys(("Bigger Text", "+", 0), ("Actual Size", "0", 2))},
    {"title": "Go", "items": keys(("Back", "[", 0), ("Forward", "]", 0))},
    {"title": "Search", "items": keys(("All Dictionaries", "0", 0), ("Alpha", "1", 0), ("Beta", "2", 0),
                                      ("Select Next Dictionary", "}", 0), ("Select Previous Dictionary", "{", 0))},
    {"title": "Window", "items": keys(("Show Tab Bar", None, 0))},
    {"title": "Help", "items": keys(("XDict Help", None, 0))}]}
old_menus = {"menubar": [
    {"title": "File", "items": keys(("New Window", "N", 0), ("Add Dictionaries…", "O", 0))},
    {"title": "Edit", "items": keys(("Find in Entry…", "F", 0), ("Find Next", "G", 0), ("Pronounce", "P", 2))},
    {"title": "View", "items": keys(("Zoom In", "+", 0), ("Actual Size", "0", 0))},
    {"title": "Go", "items": keys(("Back", "[", 0), ("Forward", "]", 0), ("Search", "F", 2))},
    {"title": "Dictionaries", "items": keys(("All Dictionaries", "0", 2), ("Alpha", "1", 2), ("Beta", "2", 2))},
    {"title": "Window", "items": keys(("Library", "L", 1))},
    {"title": "Help", "items": []}]}

start_text = [node("AXStaticText", value="Type a word to look up in…"), node("AXStaticText", value="Alpha"),
              node("AXStaticText", value="Beta")]
page = [node("AXDisclosureTriangle", (183, 300, 676, 32), identifier="page.divider.Beta", description="Beta",
              value="1"),
        node("AXDisclosureTriangle", (183, 500, 676, 32), identifier="page.divider.Records", description="Records",
              value="1")]
cases = {
    "main.start": (apple_window("XDict", *start_text), old_window("Look Up")),
    "search.result": (apple_window("XDict", rowed("apple", "Apple", "apple pie"),
                                   node("AXGroup", (200, 90, 400, 20), identifier="status"),
                                   node("AXStaticText", value="2 found")),
                      old_window("apple", node("AXOutline", (0, 52, 220, 600), [node("AXStaticText", value="Alpha")]),
                                 node("AXStaticText", value="Not Searched"))),
    "search.live": (apple_window("XDict", rowed("take off", "take on"), node("AXStaticText", value="2 found")),
                    old_window("Look Up", node("AXStaticText", value="Suggestions"))),
    "search.didyoumean": (apple_window("XDict", node("AXStaticText", value="Did you mean?"),
                                       rowed("banana")), old_window("Look Up")),
    "search.none": (apple_window("XDict", rowed(), node("AXStaticText", (200, 98, 220, 30),
                                                             value="No entries found.")),
                    old_window("zzqxjv", node("AXStaticText", (500, 300, 200, 30), value="No Results for “zzqxjv”"))),
    "window.min": ({"windows": [node("AXWindow", (0, 0, 400, 300), subrole="AXStandardWindow")]},
                   {"windows": [node("AXWindow", (0, 0, 640, 420), subrole="AXStandardWindow")]}),
    "main.narrow": (apple_window("XDict"), old_window("apple")),
    "scope.one": (apple_window("XDict", chosen="Beta"), apple_window("XDict")),
    "scope.click": (apple_window("XDict", chosen="Beta"), apple_window("XDict", scope_bar)),
    "entry.find": (apple_window("XDict", node("AXTextField", (200, 95, 500, 22), subrole="AXSearchField")),
                   old_window("apple")),
    # Apple's page: dividers named by the dictionaries after the first; XDict's old window had one entry, no divider.
    "page.all": (apple_window("XDict", *page), old_window("orange")),
    "page.collapse": (apple_window("XDict", dict(page[0], value="0"), page[1]), old_window("orange")),
    "page.one": (apple_window("XDict"), apple_window("XDict", *page)),
    "page.find": (apple_window("XDict", *page, node("AXTextField", (200, 95, 500, 22), subrole="AXSearchField")),
                  old_window("orange")),
    # Apple's print panel (print.ax.json): a sheet with Print and Cancel; before P44 XDict printed one frame, no panel
    # read here.
    "page.print": (apple_window("XDict", node("AXSheet", (80, 337, 1560, 1000), [
        node("AXButton", (1296, 1248, 140, 48), title="Cancel"),
        node("AXButton", (1460, 1248, 140, 48), title="Print")])), old_window("orange")),
}
cases["search.next"] = cases["search.result"]
cases["window.min"][0]["windows"][0]["frame"] = [0, 0, 400, 300]
cases["main.narrow"][0]["windows"][0]["frame"] = [0, 0, 859, 837]
driven = {r[0] for r in ROUTES if r[4] is not None}
for route in parity.TREE_RULES:
    assert route in driven, f"parity names {route}, which the tour does not drive"
    good, bad = cases[route]
    for check in parity.checks(route, good, apple_menus):
        assert check["ok"], (route, check)
    red = [c for c in parity.checks(route, bad, old_menus) if not c["ok"]]
    assert red, f"{route}: no parity rule is red on XDict's old window"
for route in parity.MENU_RULES:
    assert all(c["ok"] for c in parity.checks(route, cases[route][0], apple_menus)), route
    assert all(not c["ok"] for c in parity.checks(route, cases[route][1], old_menus)
               if c["id"] in ("P7", "P32", "P33", "P36", "P37", "P38")), route
    assert not any(c["ok"] for c in parity.checks(route, cases[route][0], None) if c["id"] == "P32"), "no menu bar read"
# P45: a Share item anywhere in the menus is not Apple's, nor an app menu without Services.
shared = {"menubar": apple_menus["menubar"] + [{"title": "Edit", "items": [{"title": "Share…", "items": []}]}]}
assert parity.menus_share(apple_menus) is None and parity.menus_share(shared), "P45 never red"
assert parity.menus_share({"menubar": apple_menus["menubar"][1:]}), "P45 without Services"
# P6: the scope is the search field's menu. The bar alone, the bar beside the menu, a menu button not named "Search In",
# and a placeholder that does not name the chosen dictionary are each red.
assert parity.scope_menu(apple_window("XDict")) is None
assert parity.scope_menu(apple_window("XDict", scope_bar)), "the old scope bar beside the menu"
bar_only = apple_window("XDict", scope_bar)
bar_only["windows"][0]["children"][0]["children"][4]["children"] = []
assert parity.scope_menu(bar_only), "the scope bar without the menu"
unnamed = apple_window("XDict")
unnamed["windows"][0]["children"][0]["children"][4]["children"][0]["description"] = "search"
assert parity.scope_menu(unnamed), "a magnifier not named 'Search In'"
mislabelled = apple_window("XDict", chosen="Beta")
mislabelled["windows"][0]["children"][0]["children"][4]["placeholder"] = "Search"
assert parity.scope_selected(1)(mislabelled), "Beta chosen but the placeholder says Search"
print(f"ui_tour_test: parity ok ({sum(len(v) for v in parity.TREE_RULES.values())} tree rules, "
      f"{sum(len(v) for v in parity.MENU_RULES.values())} menu rules)")
# A drop aims at the dictionary table's own frame, never the window's centre (dark-en dropV3Mdd, 2026-10-18), and a
# table missing from the tree fails naming what it looked for.
import aim  # noqa: E402
table = node("AXTable", (100, 300, 560, 200), identifier="settings.dictionaries", description="Dictionaries")
tree = {"windows": [node("AXWindow", (80, 80, 600, 700), [node("AXGroup", (90, 120, 580, 40)), table])]}
assert aim.drop_target(tree) == (380, 400), aim.drop_target(tree)
# A long table runs past what shows: its scroll area's frame is the one aimed at.
long_table = node("AXTable", (100, 300, 560, 2000), identifier="settings.dictionaries")
scrolled = {"windows": [node("AXWindow", (80, 80, 600, 700),
                             [node("AXScrollArea", (100, 300, 560, 200), [long_table])])]}
assert aim.drop_target(scrolled) == (380, 400), aim.drop_target(scrolled)
try:
    aim.drop_target({"windows": [node("AXWindow", (80, 80, 600, 700))]})
    raise AssertionError("a tree without the table gave an aim")
except aim.NoTarget as missing:
    assert "settings.dictionaries" in str(missing), missing
print("ui_tour_test: drop aim ok")
print(f"ui_tour_test: ok ({len(ROUTES)} routes, {len(undriven)} not driven)")
