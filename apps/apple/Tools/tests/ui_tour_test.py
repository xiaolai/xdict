#!/usr/bin/env python3
"""The UI tour's tree checks (Tools/ui-tour/axcheck.py) and its route table (routes.py): each check red on a tree that
has the fault and quiet on one that has not; every route id unique, every undriven route saying why."""
import html
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
# A row that says its label twice (Settings ▸ General's Background row, 2026-10-19: the slider's own label drawn after
# 'Glass ◯── Solid' as well as the row's). Its nodes as the tour captured them (light-en settings.general.ax.json), the
# repeat nested once more under itself, as AX gave it; red on it, quiet with the slider's label hidden.
background = [{"role": "AXStaticText", "value": "Background", "frame": [30, 1008.25, 72.5, 16]},
              {"role": "AXButton", "title": "Glass", "frame": [273, 1011.375, 26.5, 13]},
              {"role": "AXSlider", "identifier": "panel-solidity", "value": "0", "frame": [303.5, 1009.875, 160.5, 16]},
              {"role": "AXButton", "title": "Solid", "frame": [468, 1011.375, 24.5, 13]}]
again = {"role": "AXStaticText", "value": "Background", "frame": [497.5, 1009.306884765625, 72.5, 16],
         "children": [{"role": "AXStaticText", "value": "Background", "frame": [497.5, 1009.306884765625, 72.5, 16]}]}
row_window = {"windows": [{"role": "AXWindow", "frame": [0, 0, 600, 1106], "children": [
    {"role": "AXGroup", "frame": [20, 990, 560, 50], "children": background + [again]}]}]}
assert kinds(row_window) == ["repeated-label"], kinds(row_window)
row_window["windows"][0]["children"][0]["children"] = background
assert kinds(row_window) == [], kinds(row_window)
# The same words in two rows, one under the other (a list of names), are not a repeat.
assert kinds(window({"role": "AXStaticText", "value": "Alpha", "frame": [10, 10, 60, 20]},
                    {"role": "AXStaticText", "value": "Alpha", "frame": [10, 40, 60, 20]})) == []
# An identifier on a row's container is taken by every control in it (Settings ▸ General's site field and Add Site,
# both `hover.excludedSites`, 2026-10-19): the tour then cannot find the field by its own. Repeated menu items are the
# menu's own (`menuAction:`), not XDict's.
assert kinds(window({"role": "AXTextField", "identifier": "hover.excludedSites", "description": "Site",
                     "frame": [100, 10, 150, 16]},
                    {"role": "AXButton", "identifier": "hover.excludedSites", "title": "Add Site",
                     "frame": [260, 6, 75, 24]})) == ["repeated-identifier"]
assert kinds(window({"role": "AXGroup", "identifier": "hover.excludedSites", "frame": [20, 0, 360, 40], "children": [
    {"role": "AXTextField", "identifier": "hover.site.field", "description": "Site", "frame": [100, 10, 150, 16]},
    {"role": "AXButton", "identifier": "hover.addSite", "title": "Add Site", "frame": [260, 6, 75, 24]}]})) == []
assert kinds(window({"role": "AXMenuItem", "identifier": "menuAction:", "title": "Open", "frame": [0, 0, 90, 20]},
                    {"role": "AXMenuItem", "identifier": "menuAction:", "title": "Quit", "frame": [0, 20, 90, 20]})) == []

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
# Hover's routes (plan-capture WI-5): the Lookup pane's rows and the Screen Recording row as this Mac's grant leaves
# them, driven; the row's other states and the hover popover, which need a grant changed or another app's text, not. The
# hover rows moved from General to Lookup in the owner's Settings audit of 2026-10-30.
hover_driven = {"settings.lookup", "settings.lookup.hover", "menubar.hoverPause", "menubar.hoverPaused",
                "menubar.hoverOff"}
hover_undriven = {"settings.lookup.screenRecordingNotSetUp", "settings.lookup.screenRecordingNotAllowed",
                  "settings.lookup.screenRecordingAllowed", "settings.lookup.screenRecordingCouldNotTell",
                  "hover.popover"}
assert hover_driven <= set(ids) - undriven, hover_driven - (set(ids) - undriven)
assert hover_undriven <= undriven, hover_undriven - undriven
# **No two driven routes walk the same way** (2026-10-19: settings.general, .hover, .screenRecording and settings.lookup
# differed only by a wait, and captured the same picture byte for byte). Waits are not a difference.
import routes  # noqa: E402


def walked(route):
    return (route[1], tuple(s for s in route[4] if s[0] != "wait"))


seen = {}
for route in ROUTES:
    if route[4] is not None:
        assert walked(route) not in seen, f"{route[0]} walks as {seen.get(walked(route))} does"
        seen[walked(route)] = route[0]
same = [("a", "full", "", "", [("key", "cmd+,"), ("wait", 1)]), ("b", "full", "", "", [("key", "cmd+,"), ("wait", 2)])]
assert walked(same[0]) == walked(same[1]), "control: two routes differing by a wait read as different"
# **A setting a route needs is stored before its launch** (`("pref", key, value)`, applied by tour.py's Session after the
# preferences are deleted), never reached by clicking a switch whose state the route cannot know: menubar.hoverOff
# clicked hover's switch and turned hover on in three variants of four (2026-10-19).
by_id = {r[0]: r for r in ROUTES}
assert routes.prefs(by_id["menubar.hoverOff"][4]) == [("hoverLookupEnabled", False)], by_id["menubar.hoverOff"][4]
assert not any(s[0] == "click" for s in by_id["menubar.hoverOff"][4]), "menubar.hoverOff clicks to set its state"
for route in ROUTES:
    routes.prefs(route[4] or [])
for bad in ([("pref", "hoverLookupEnabled", "NO")], [("pref", "somethingElse", False)]):
    try:
        routes.prefs(bad)
        raise AssertionError(f"routes.prefs took {bad}")
    except ValueError:
        pass
# Each key is the one the app reads: HoverControl's `enabledKey`.
with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "Sources", "XDictAnywhere",
                       "HoverControl.swift"), encoding="utf-8") as f:
    control_source = f.read()
for key in routes.PREFS:
    assert f'"{key}"' in control_source, f"no preference {key} in HoverControl.swift"
# The commands the tour's Session runs to store them (routes.defaults_commands), run here against a scratch plist in
# place of XDict's domain and read back: the route's value is what is stored, as a boolean.
import plistlib  # noqa: E402
import subprocess  # noqa: E402
import tempfile  # noqa: E402

with tempfile.TemporaryDirectory() as scratch:
    target = os.path.join(scratch, "prefs")
    for argv in routes.defaults_commands(target, routes.prefs(by_id["menubar.hoverOff"][4])):
        subprocess.run(argv, check=True, capture_output=True)
    with open(target + ".plist", "rb") as f:
        stored = plistlib.load(f)
    assert stored == {"hoverLookupEnabled": False}, stored
    for argv in routes.defaults_commands(target, [("hoverLookupEnabled", True)]):
        subprocess.run(argv, check=True, capture_output=True)
    with open(target + ".plist", "rb") as f:
        assert plistlib.load(f) == {"hoverLookupEnabled": True}, "control: a true preference was not stored true"
assert routes.defaults_commands("d", []) == [], "a route with no preference wrote one"
with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ui-tour", "tour.py"), encoding="utf-8") as f:
    tour_source = f.read()
assert "defaults_commands(DOMAIN, preferences)" in tour_source and "prefs(steps)" in tour_source, \
    "tour.py does not store a route's preferences through routes.defaults_commands"
# The site field is the hover route's own state (P53): reached by its identifier, which the row no longer takes over.
assert ("click", "hover.site.field") in by_id["settings.lookup.hover"][4], by_id["settings.lookup.hover"][4]
# The menu-bar item's menu is not one of the app's windows: a press on Pause Hover finds it only if press and click
# also look in the open menu-bar extra (`ax.swift`'s `roots`).
with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ui-tour", "ax.swift"), encoding="utf-8") as f:
    ax_source = f.read()
press_case = ax_source.split('case "press", "click":', 1)[1].split("case ", 1)[0]
assert "roots(app)" in press_case and "windows(app)" not in press_case, press_case
roots_func = ax_source.split("func roots(", 1)[1].split("\n}\n", 1)[0] if "func roots(" in ax_source else ""
assert "AXExtrasMenuBar" in roots_func, "press and click do not look in the menu-bar extra"
# The pause lengths are said by the system in the reader's language ("For %@" is the catalog's key, not the title), so
# the route names the Chinese title too.
assert any(s[0] == "press" and "For 15 minutes" in s and any("分钟" in n for n in s[1:])
           for s in by_id["menubar.hoverPaused"][4]), by_id["menubar.hoverPaused"][4]
# **Menus opened from the menu bar are captured in light only** (2026-10-19): they draw in the menu bar's appearance, the
# Mac's, which the tour's `--appearance` (NSApp.appearance) does not reach; every dark capture of them was byte for byte
# the light one. Every menu route is light only, with its reason, and no other route is.
menu_routes = [r[0] for r in ROUTES if r[0].startswith(("menu.", "menubar.")) and r[4] is not None]
assert len(menu_routes) >= 10, menu_routes
for route in menu_routes:
    why = routes.not_in_appearance(route, "dark")
    assert why and "menu bar" in why, (route, why)
    assert routes.not_in_appearance(route, "light") is None, route
for route in (r[0] for r in ROUTES if r[4] is not None and r[0] not in menu_routes):
    assert routes.not_in_appearance(route, "dark") is None, route
    assert routes.not_in_appearance(route, "light") is None, route
# The control: a menu route in dark is named, a window route is not, and a route merely named like one ("menus.x",
# "menubarx") is not.
assert routes.not_in_appearance("menu.view", "dark") and not routes.not_in_appearance("main.start", "dark")
assert not routes.not_in_appearance("menus.x", "dark") and not routes.not_in_appearance("menubarx", "dark")
# tour.py walks a route only in the appearances it is captured in, and records why it skipped one.
assert "not_in_appearance(route, appearance)" in tour_source, \
    "tour.py does not ask routes.not_in_appearance before walking a route"


def simulated_tour(variants):
    """tour.py's own `tour()`, its walk stubbed (no app, no window), over `variants`: what it walked and what it recorded
    as not captured, as {(variant, route)} and {(variant, route): reason}."""
    kit = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ui-tour")
    assert tour_source.rstrip().endswith("main()"), "tour.py no longer ends with main(); the simulation cuts it off"
    with tempfile.TemporaryDirectory() as scratch:
        saved = sys.argv
        sys.argv = [os.path.join(kit, "tour.py"), os.path.join(scratch, "home"), os.path.join(scratch, "out"),
                    "--variants", ",".join(variants)]
        try:
            ns = {"__name__": "tour_simulated", "__file__": os.path.join(kit, "tour.py")}
            exec(compile(tour_source.rstrip()[:-len("main()")], "tour.py", "exec"), ns)
            walked = set()
            ns["walk"] = lambda variant, name, library, route, steps, folder: (
                walked.add((name, route)) or {"variant": name, "route": route, "shots": ["x.png"]})
            results = ns["tour"]()
        finally:
            sys.argv = saved
    skipped = {(r["variant"], r["route"]): r["notCaptured"] for r in results if r.get("notCaptured")}
    return walked, skipped


walked, skipped = simulated_tour(["light-en", "dark-en", "light-zh", "dark-zh"])
toured = {r[0] for r in ROUTES if r[4] is not None and r[1] in ("full", "empty")}
assert toured >= set(menu_routes) and len(toured) > len(menu_routes), toured
for variant in ("light-en", "light-zh"):
    assert {r for v, r in walked if v == variant} == toured, variant
    assert not any(v == variant for v, _ in skipped), variant
for variant in ("dark-en", "dark-zh"):
    assert {r for v, r in walked if v == variant} == toured - set(menu_routes), variant
    assert {r for v, r in skipped if v == variant} == set(menu_routes), variant
    assert all(skipped[(variant, r)] == routes.MENU_BAR_APPEARANCE for r in menu_routes), variant
print(f"ui_tour_test: tour walks {len(toured)} routes in light, {len(toured) - len(menu_routes)} in dark")
# The review page says why a route was not captured, and shows no picture for it (index.py's page and its before |
# after page), from a results.json holding one record of each kind.
with tempfile.TemporaryDirectory() as out:
    index = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ui-tour", "index.py")
    results = [{"variant": "light-en", "route": "menu.view", "shots": ["menu.view.png"]},
               {"variant": "dark-en", "route": "menu.view", "notCaptured": routes.MENU_BAR_APPEARANCE},
               {"variant": "light-en-fixed", "route": "menu.go", "shots": ["menu.go.png"]},
               {"variant": "dark-en-fixed", "route": "menu.go", "notCaptured": routes.MENU_BAR_APPEARANCE}]
    with open(os.path.join(out, "results.json"), "w") as f:
        json.dump(results, f)
    reason = f"not captured: {html.escape(routes.MENU_BAR_APPEARANCE)}"
    for argv in ([], ["--before", os.path.join(out, "results.json"), "--label", "fixed"]):
        subprocess.run([sys.executable, "-I", index, out] + argv, check=True, capture_output=True)
        with open(os.path.join(out, "index.html"), encoding="utf-8") as f:
            page_html = f.read()
        assert reason in page_html, (argv, "the page does not say why a route was not captured")
        assert "light-en/menu.view.png" in page_html, (argv, "control: the light capture is not on the page")
        assert "dark-en/" not in page_html and "dark-en-fixed/" not in page_html, (argv, "a skipped route has a picture")
print("ui_tour_test: index says why a route was not captured")
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
    # Stretched to 1400 pt: the field at its most, the speaker beside it; red, the stretched window of 2026-10-19, the
    # speaker over the field's start and the field past the window's edge.
    "window.wide": ({"windows": [node("AXWindow", (0, 0, 1400, 700), [node("AXToolbar", (0, 0, 1400, 52), [
        button("Back", 100, "Show the previous result"), button("Forward", 136, "Show the next result"),
        button("Pronounce", 180, "Read the selection aloud"),
        button("Smaller Text", 860, "Decrease font size"), button("Bigger Text", 896, "Increase font size"),
        node("AXTextField", (972, 7, 420, 38), [scope_menu("All Dictionaries")], subrole="AXSearchField")])],
        subrole="AXStandardWindow", title="XDict")]},
                    {"windows": [node("AXWindow", (0, 0, 1400, 700), [node("AXToolbar", (0, 0, 1400, 52), [
                        button("Smaller Text", 860, "Decrease font size"),
                        button("Bigger Text", 896, "Increase font size"),
                        button("Pronounce", 940, "Read the selection aloud"),
                        node("AXTextField", (944, 7, 470, 38), subrole="AXSearchField")])],
                        subrole="AXStandardWindow", title="XDict")]}),
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
# window.wide's rule, one defect at a time: the speaker over the field with the field inside the window, and the field
# past the window's edge with nothing over it. Each is red alone, so dropping either clause of the rule fails here.
def wide(speaker_x, field_x, field_width):
    return {"windows": [node("AXWindow", (0, 0, 1400, 700), [node("AXToolbar", (0, 0, 1400, 52), [
        button("Pronounce", speaker_x, "Read the selection aloud"),
        node("AXTextField", (field_x, 7, field_width, 38), subrole="AXSearchField")])], subrole="AXStandardWindow")]}


assert parity.toolbar_fits(wide(932, 972, 420)) is None, "window.wide red on a toolbar that fits"
assert "lies over" in (parity.toolbar_fits(wide(950, 960, 420)) or ""), "the speaker over the field is not red"
assert "runs out" in (parity.toolbar_fits(wide(900, 990, 420)) or ""), "the field past the window's edge is not red"
# The speaker's place (P48): after Back/Forward, before the text-size pair; red beside the text-size pair, as it was.
leading = cases["window.wide"][0]
assert parity.speaker_after_navigation(leading) is None, "the speaker after Back/Forward is red"
beside = {"windows": [node("AXWindow", (0, 0, 1400, 700), [node("AXToolbar", (0, 0, 1400, 52), [
    button("Back", 100, "Show the previous result"), button("Forward", 136, "Show the next result"),
    button("Smaller Text", 860, "Decrease font size"), button("Bigger Text", 896, "Increase font size"),
    button("Pronounce", 932, "Read the selection aloud")])], subrole="AXStandardWindow")]}
assert "not between" in (parity.speaker_after_navigation(beside) or ""), "the speaker beside the text-size pair is not red"
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
