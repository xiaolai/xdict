#!/usr/bin/env python3
"""Tests of Tools/gallery/render_affected.py: which pictures a change needs, and which of them already passed.

Each rule of render-affected.map selects what it should; an unmapped path selects the representative set, never nothing
and never the full gallery; a role-table hunk selects that row's dictionaries; a carried key is skipped; an edited style
file invalidates exactly the pictures that read it; a pass is recorded only for a picture whose checks passed. Positive
controls: a map with a role-table row missing, or a route pattern that matches no route, is refused. Opens nothing,
reaches no host; the gallery's keys, the corpus and the cache are scratch ones.
"""
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "..", "gallery", "render_affected.py")
spec = importlib.util.spec_from_file_location("render_affected", TOOL)
ra = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ra)

failures = 0


def check(name, condition, detail=""):
    global failures
    if condition:
        print(f"ok    {name}")
    else:
        failures += 1
        print(f"FAIL  {name}{': ' + str(detail) if detail else ''}")


STYLE = "apps/apple/Sources/XDictEntryView/Style/"
PROFILES = "core/xdict-entry/src/roles/profiles.rs"
m = ra.read_map(ra.MAP)
route_ids = ra.route_ids()
ra.check_map(m, route_ids, open(os.path.join(ra.REPO, PROFILES), encoding="utf-8").read())
# The gallery's keys, of the real shape: three kinds a dictionary (short, long, media), 24 dictionaries.
keys = {d: [("short", f"{d}-s"), ("long", f"{d}-l"), ("media", f"{d}-m")] for d in m.dicts}
ledger = ra.ledger_repros(os.path.join(HERE, "..", "gallery", "style-ledger.tsv"))
profiles_text = open(os.path.join(ra.REPO, PROFILES), encoding="utf-8").read()


def sel(paths, hunks=None, full=False):
    return ra.select(paths, m, keys, ledger, route_ids, hunks or {}, profiles_text, full=full,
                     ledger_text=open(os.path.join(HERE, "..", "gallery", "style-ledger.tsv"), encoding="utf-8").read())


def views_of(s):
    return {p[2] for p in s.pictures}


def dicts_of(s):
    return {p[0] for p in s.pictures}


check("the test set is 24 dictionaries", len(m.dicts) == 24, len(m.dicts))
full = sel([], full=True)
check("FULL=1 selects every picture: 72 x 4 = 288", len(full.pictures) == 288, len(full.pictures))
check("FULL=1 selects every route", set(full.routes) == set(route_ids))

unknown = sel(["apps/apple/SomethingNew.txt"])
check("(d) an unmapped path selects nothing", not unknown.pictures and not unknown.routes)
check("(d) ... and says so", unknown.unmatched == ["apps/apple/SomethingNew.txt"], unknown.unmatched)
for path in ("apps/apple/Sources/XDictLibrary/Library.swift", "core/xdict-mdx/src/lib.rs",
             "apps/apple/Sources/XDictEntryLab/Gallery.swift"):
    s = sel([path])
    check(f"(d) {path} selects no entry", not s.pictures)

none = sel(["dev-docs/plan.md", "apps/apple/Tests/XDictTests/A.swift"])
check("notes and tests select nothing, by an explicit rule", not none.pictures and not none.routes and not none.unmatched)

SHARED = "shared file: reaches every dictionary"
for name in ("type.css", "colour-core.js", "frame.js", "frame-core.js", "column.css"):
    s = sel([STYLE + name])
    check(f"(b) {name}: one entry a dictionary, light core only (24)",
          len(s.pictures) == 24 and views_of(s) == {"core-light"} and dicts_of(s) == set(m.dicts),
          (views_of(s), len(s.pictures)))
    check(f"(b) {name}: the reason names the shared file", all(SHARED in r for p in s.pictures for r in s.pictures[p]))
    check(f"(b) {name}: the hint to scope it to a profile row", bool(s.hint) and "profile" in s.hint, s.hint)
check("(b) the representative entry is the `represent` kind",
      {p[1] for p in sel([STYLE + "type.css"]).pictures} == {f"{d}-l" for d in m.dicts})
s = sel(["core/xdict-entry/src/normalize.rs"])
check("(b) the core's shared entry processing: 24", len(s.pictures) == 24 and views_of(s) == {"core-light"})
minimal = sel([STYLE + "minimal.css"])
check("Original style's sheet: its route, no picture of the four views",
      not minimal.pictures and set(minimal.routes) == {"settings.dictionaries.originalStyle"})

pane = sel(["apps/apple/Sources/XDictEntryView/EntryPane.swift"])
check("(c) EntryPane.swift: the panel and page routes, no entry",
      not pane.pictures and {r for r in pane.routes if r.startswith("panel.")} == {r for r in route_ids if r.startswith("panel.")}
      and any(r.startswith("page.") for r in pane.routes), sorted(pane.routes))
popover = sel(["apps/apple/Sources/XDictUI/LookupPopover.swift"])
check("(c) the popover: the panel routes only", popover.routes and not popover.pictures
      and all(r.startswith(("panel.", "entry.")) for r in popover.routes), sorted(popover.routes))
search = sel(["apps/apple/Sources/XDictUI/SearchWindow.swift"])
check("(c) the search window: its routes", "search.result" in search.routes and "main.start" in search.routes
      and not search.pictures and not any(r.startswith("library.") for r in search.routes), sorted(search.routes))
menus = sel(["apps/apple/Sources/XDict/XDictApp.swift"])
# XDictApp.swift also composes Settings' panes (ADR-0012 d.1, d.4), so its routes are the menus' and Settings'.
check("(c) the menus and Settings: their routes", menus.routes and not menus.pictures
      and all(r.startswith(("menu", "about", "ackn", "settings.")) for r in menus.routes)
      and any(r.startswith("settings.") for r in menus.routes), sorted(menus.routes))

# (a) A role-table hunk: the line of LDOCE's `signature` selects LDOCE and LDOCE-EC alone.
lines = profiles_text.split("\n")
chwd = next(i + 1 for i, l in enumerate(lines) if '"chwd"' in l)
row = sel([PROFILES], hunks={PROFILES: {chwd}})
check("(a) a hunk in a role-table row selects that row's dictionaries only", dicts_of(row) == {"ldoce", "ldoce-ec"},
      dicts_of(row))
check("(a) ... every gallery entry of theirs, light core",
      {(p[0], p[1]) for p in row.pictures} >= {(d, k) for d in ("ldoce", "ldoce-ec") for _, k in keys[d]}
      and views_of(row) == {"core-light"}, views_of(row))
check("(a) ... and their style-ledger repro entries", ("ldoce", "hyphenation", "core-light") in row.pictures)
check("(a) ... no hint", not row.hint, row.hint)
matcher = next(i + 1 for i, l in enumerate(lines) if l.startswith("fn matches("))
outside = sel([PROFILES], hunks={PROFILES: {matcher}})
check("(b) a hunk outside every row is a shared change: 24", len(outside.pictures) == 24, len(outside.pictures))
whole = sel([PROFILES])
check("(a) profiles.rs with no hunks: every row's dictionaries",
      dicts_of(whole) == {d for ds in m.profiles.values() for d in ds})
# (a) A style-ledger row: its dictionaries; dark too when the row is about colour.
LEDGER = "apps/apple/Tools/gallery/style-ledger.tsv"
ledger_lines = open(os.path.join(ra.REPO, LEDGER), encoding="utf-8").read().split("\n")
d4 = next(i + 1 for i, l in enumerate(ledger_lines) if l.startswith("D4\t"))
d44 = next(i + 1 for i, l in enumerate(ledger_lines) if l.startswith("D44\t"))
s = sel([LEDGER], hunks={LEDGER: {d4}})
check("(a) a ledger row selects its dictionary, light core", dicts_of(s) == {"noad"} and views_of(s) == {"core-light"},
      (dicts_of(s), views_of(s)))
s = sel([LEDGER], hunks={LEDGER: {d44}})
check("(a) a colour row adds dark", dicts_of(s) == {"med"} and views_of(s) == {"core-light", "core-dark"}, views_of(s))
s = sel([LEDGER], hunks={LEDGER: {1}})
check("(d) the ledger's header selects nothing", not s.pictures)

# Positive controls: a map that has lost a row's line, or names a route that does not exist, is refused.
with tempfile.TemporaryDirectory() as scratch:
    text = open(ra.MAP, encoding="utf-8").read()
    bad_map = os.path.join(scratch, "a.map")
    open(bad_map, "w", encoding="utf-8").write("\n".join(l for l in text.split("\n") if not l.startswith("profile chwd")))
    try:
        ra.check_map(ra.read_map(bad_map), route_ids, profiles_text)
        check("a role-table row with no `profile` line is refused", False)
    except ra.MapError as error:
        check("a role-table row with no `profile` line is refused", "chwd" in str(error), error)
    open(bad_map, "w", encoding="utf-8").write(text + "\napps/apple/X.swift  route:no.such.route\n")
    try:
        ra.check_map(ra.read_map(bad_map), route_ids, profiles_text)
        check("a route pattern matching no route is refused", False)
    except ra.MapError as error:
        check("a route pattern matching no route is refused", "no.such.route" in str(error), error)
    open(bad_map, "w", encoding="utf-8").write("apps/apple/X.swift  rep\n" + text)
    try:
        ra.read_map(bad_map)
        check("entries with no views are refused", False)
    except ra.MapError as error:
        check("entries with no views are refused", "views" in str(error), error)

# Render keys: the style files a view reads, the lab, the dictionary's file, the entry, the view.
listing = {STYLE + n: f"100644:{n}-1" for n in ("type.css", "colour-core.js", "minimal.css", "frame.js")}
listing["apps/apple/Sources/XDict/x.swift"] = "100644:x-1"
dict_ids = {d: f"id-{d}" for d in m.dicts}


def keyed(listing, dict_ids, lab="lab-1"):
    return {p: ra.picture_key(p, ra.style_manifest(listing, m, p[2]), lab, dict_ids[p[0]]) for p in full.pictures}


base = keyed(listing, dict_ids)
check("every picture has its own key", len(set(base.values())) == 288)
edited = keyed(dict(listing, **{STYLE + "type.css": "100644:type.css-2"}), dict_ids)
check("an edit to type.css invalidates every picture that reads it (all four views do)",
      all(base[p] != edited[p] for p in base))
edited = keyed(dict(listing, **{STYLE + "minimal.css": "100644:minimal.css-2"}), dict_ids)
check("an edit to minimal.css invalidates none of the four views' pictures", all(base[p] == edited[p] for p in base))
edited = keyed(dict(listing, **{"apps/apple/Sources/XDict/x.swift": "100644:x-2"}), dict_ids)
check("a file no view reads changes no key", base == edited)
edited = keyed(listing, dict(dict_ids, oald="id-oald-2"))
check("a dictionary's new file invalidates exactly its own pictures",
      {p for p in base if base[p] != edited[p]} == {p for p in base if p[0] == "oald"})
edited = keyed(listing, dict_ids, lab="lab-2")
check("another lab invalidates every picture", all(base[p] != edited[p] for p in base))
check("an unknown dictionary file has no key", ra.picture_key(next(iter(full.pictures)), {}, "lab", None) is None)

# The record: a carried key is skipped; a corrupt record carries nothing.
with tempfile.TemporaryDirectory() as scratch:
    passes = os.path.join(scratch, "passes.tsv")
    some = sorted(full.pictures)[:5]
    ra.append_passes(passes, [(base[p], p) for p in some])
    carried = ra.read_passes(passes)
    check("a recorded key is carried", all(base[p] in carried for p in some) and len(carried) == 5)
    check("another key is not", sorted(full.pictures)[6] not in carried and base[sorted(full.pictures)[6]] not in carried)
    with open(passes, "a", encoding="utf-8") as out:
        out.write("garbage\n")
    check("a corrupt record carries nothing", ra.read_passes(passes) == {})
    check("no record carries nothing", ra.read_passes(os.path.join(scratch, "none.tsv")) == {})

# Recording from a gallery report: only the rows whose checks passed; an unattributed failure records nothing.
rows = [{"dict": "oald", "key": "apple", "kind": "long", "mode": "core-light"},
        {"dict": "oald", "key": "apple", "kind": "long", "mode": "core-dark"},
        {"dict": "oald", "key": "take off", "kind": "short", "mode": "core-light"},
        {"dict": "med", "key": "chat", "kind": "long", "mode": "core-light"}]
passed = ra.passed_rows({"rows": rows, "failures": ["oald core-dark apple: text colours outside the palette x"]})
check("a failed row is not recorded, the rest are",
      passed == [("oald", "apple", "core-light"), ("oald", "take off", "core-light"), ("med", "chat", "core-light")], passed)
passed = ra.passed_rows({"rows": rows, "failures": ["oald light: G2 the dominant size is 9px"]})
check("a dictionary's light failure fails its light rows", ("oald", "apple", "core-light") not in passed
      and ("oald", "apple", "core-dark") in passed and ("med", "chat", "core-light") in passed, passed)
passed = ra.passed_rows({"rows": rows, "failures": ["oald: no entry with text among 9"]})
check("a dictionary's failure fails all its rows", all(p[0] != "oald" for p in passed) and passed, passed)
check("an unattributed failure records nothing", ra.passed_rows({"rows": rows, "failures": ["something broke"]}) == [])

# The command, end to end, in this repository: pending, keys, record, pending again.
with tempfile.TemporaryDirectory() as scratch:
    corpus = os.path.join(scratch, "corpus")
    for d in m.dicts:
        os.makedirs(os.path.join(corpus, d))
        open(os.path.join(corpus, d, "a.mdx"), "w").write(d)
    report = {"rows": [{"dict": d, "kind": k, "key": key, "mode": "core-light"} for d in m.dicts for k, key in keys[d]]}
    keys_file = os.path.join(scratch, "keys.json")
    json.dump(report, open(keys_file, "w"))
    env = dict(os.environ, XDICT_GALLERY_KEYS=keys_file, XDICT_RENDER_CORPUS=corpus,
               XDICT_RENDER_CACHE=os.path.join(scratch, "cache"), XDICT_RENDER_LAB_ID="lab-test",
               XDICT_GATE_CACHE=os.path.join(scratch, "gates"))
    env.pop("CLAUDECODE", None)

    def run(*args):
        return subprocess.run([sys.executable, "-I", TOOL, *args], capture_output=True, text=True, env=env)

    out = run("pending", "--paths", STYLE + "type.css")
    check("pending: one line, the count, why and the hint", "profile row" in out.stdout and out.returncode == 0 and out.stdout.strip().startswith(
        "Render needed (not run): 24 pictures") and STYLE + "type.css" in out.stdout, out.stdout + out.stderr)
    out = run("pending", "--paths", "dev-docs/x.md")
    check("pending with nothing selected", out.stdout.strip() == "Render: nothing pending", out.stdout + out.stderr)
    out = run("pending", "--full", "--paths", "dev-docs/x.md")
    check("pending FULL=1: 288 pictures", out.stdout.startswith("Render needed (not run): 288 pictures"), out.stdout + out.stderr)
    plan = run("plan", "--paths", STYLE + "type.css")
    groups = [l.split("\t") for l in plan.stdout.splitlines() if l.startswith("views\t")]
    check("plan: an entry a line, with its views", plan.returncode == 0 and len(groups) == 24
          and all(g[1] == "core-light" for g in groups), plan.stdout + plan.stderr)
    entries = [g[2] for g in groups]
    keyed_out = run("keys", "--lab-id", "lab-test", "--views", "core-light", *entries)
    check("keys: one a picture", keyed_out.returncode == 0 and len(keyed_out.stdout.splitlines()) == 24,
          keyed_out.stdout[-300:] + keyed_out.stderr)
    keys_tsv = os.path.join(scratch, "keys.tsv")
    open(keys_tsv, "w").write(keyed_out.stdout)
    rendered = {"rows": [{"dict": e.split(":")[0], "key": e.split(":")[1], "kind": e.split(":")[2], "mode": v}
                         for e in entries for v in ("core-light",)],
                "failures": [f"{entries[0].split(':')[0]} core-light {entries[0].split(':')[1]}: a failure"]}
    report_file = os.path.join(scratch, "report.json")
    json.dump(rendered, open(report_file, "w"))
    out = run("record", "--keys", keys_tsv, "--report", report_file)
    check("record: every passed picture, not the failed one", out.returncode == 0 and "recorded 23" in out.stdout,
          out.stdout + out.stderr)
    out = run("pending", "--paths", STYLE + "type.css")
    check("pending again: only the failed picture is needed, 23 carried",
          out.stdout.startswith("Render needed (not run): 1 picture") and "23 carried" in out.stdout, out.stdout + out.stderr)
    out = run("select", "--paths", STYLE + "type.css")
    check("select names a carried picture with its date", "carried 20" in out.stdout, out.stdout[:400])
    out = run("pending", "--full", "--paths", STYLE + "type.css")
    check("FULL=1 forces carried pictures", out.stdout.startswith("Render needed (not run): 288 pictures"), out.stdout)
    env["XDICT_RENDER_LAB_ID"] = "lab-other"
    out = run("pending", "--paths", STYLE + "type.css")
    check("another lab carries nothing", out.stdout.startswith("Render needed (not run): 24 pictures"), out.stdout)
    env["XDICT_RENDER_LAB_ID"] = "lab-test"
    shutil.rmtree(corpus)
    out = run("pending", "--paths", STYLE + "type.css")
    check("no corpus: nothing carried, and said", out.stdout.startswith("Render needed (not run): 24 pictures")
          and "corpus" in out.stderr, out.stdout + out.stderr)

# The lab's inputs, in this repository: the lab's sources and the core behind it, not the style it is handed.
lab = ra.lab_paths(ra.listing())
check("the lab's inputs hold its own sources and the core", any(p.startswith("apps/apple/Sources/XDictEntryLab/") for p in lab)
      and "core/xdict-entry/src/normalize.rs" in lab, len(lab))
check("... not the style files nor their generated Swift, which keys hold apart",
      not any(p.startswith(STYLE) for p in lab) and "apps/apple/Sources/XDictEntryView/EntryStyleFiles.swift" not in lab)
check("... not the app's windows", not any(p.startswith("apps/apple/Sources/XDictUI/") for p in lab))

# Hover's routes (plan-capture WI-5 verification). The pause group's file selects every menu-bar route, not only the
# menu itself; a revert to `route:menubar.extra` is red (its control below).
MENUBAR = "apps/apple/Sources/XDictUI/MenuBarMenu.swift"
PAUSE_ROUTES = {"menubar.extra", "menubar.hoverPause", "menubar.hoverPaused", "menubar.hoverOff"}


def menubar_routes(a_map):
    return set(ra.select([MENUBAR], a_map, keys, ledger, route_ids, {}, profiles_text).routes)


check("the menu-bar menu selects the pause group's routes", PAUSE_ROUTES <= menubar_routes(m), sorted(menubar_routes(m)))
with tempfile.TemporaryDirectory() as tmp:
    reverted = os.path.join(tmp, "reverted.map")
    text = open(ra.MAP, encoding="utf-8").read()
    with open(reverted, "w", encoding="utf-8") as f:
        f.write(text.replace(MENUBAR + "                route:menubar.*", MENUBAR + "                route:menubar.extra"))
    check("control: the revert's edit applied", "route:menubar.extra" in open(reverted, encoding="utf-8").read())
    check("control: a menu-bar rule reverted to route:menubar.extra misses the pause routes",
          not PAUSE_ROUTES <= menubar_routes(ra.read_map(reverted)), sorted(menubar_routes(ra.read_map(reverted))))

# A route the tour does not drive (no steps) is never selected: nothing would ever render it, so it would stay pending.
sys.path.insert(0, os.path.join(HERE, "..", "ui-tour"))
from routes import ROUTES  # noqa: E402
sys.path.pop(0)
undriven = {r[0] for r in ROUTES if r[4] is None}
check("route_ids leaves out every undriven route", undriven and not undriven & set(route_ids), sorted(undriven & set(route_ids)))
hover_rows = set(sel(["apps/apple/Sources/XDictUI/HoverSentences.swift"]).routes)
check("hover's sentences select the Lookup pane, which shows the Screen Recording row, and none of the undriven states",
      "settings.lookup" in hover_rows and not hover_rows & undriven, sorted(hover_rows))
# The control's setting and pause decide what the menu-bar pause group and the General pane's switch show (isOn).
control_rows = set(sel(["apps/apple/Sources/XDictAnywhere/HoverControl.swift"]).routes)
check("hover's control selects the pause group's routes and the Lookup pane",
      {"menubar.hoverPause", "menubar.hoverPaused", "menubar.hoverOff", "settings.lookup"} <= control_rows,
      sorted(control_rows))
apple = set(sel(["apps/apple/Sources/XDictUI/AppleImportSheet.swift"]).routes)
check("the Apple import selects its driven route, not the undriven updated and removed ones",
      "settings.dictionaries.appleImport" in apple and not apple & undriven, sorted(apple))
# Its control: every route id, the undriven ones included, selects them.
every = [r[0] for r in ROUTES]
with_undriven = set(ra.select(["apps/apple/Sources/XDictUI/HoverSentences.swift"], m, keys, ledger, every, {},
                              profiles_text).routes)
check("control: with the undriven routes listed, hover's sentences select them", with_undriven & undriven,
      sorted(with_undriven))

print(f"render-affected: {failures} failure(s)")
sys.exit(1 if failures else 0)
