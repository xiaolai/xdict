"""The Apple Dictionary parity checks (Tools/parity/apple-dictionary.tsv, groups A, B and E): what each tour route's
accessibility tree and the menu bar must show for XDict's main window to be Apple's, by ledger id.

    checks(route, tree, menubar) -> [{"id": "P3", "ok": bool, "why": str}, ...]

`tree` is the tour's `ax tree` ({"windows": [...]}); `menubar` its `ax menubar` ({"menubar": [...]}) or None. The rules
read English titles, so the tour runs them on `-en` variants only. Each rule was measured against Apple's own captures
(dev-docs/artifacts/apple-dictionary/apple/*.ax.json, menubar.json): `Tools/tests/ui_tour_test.py` holds every rule
green on a tree shaped as Apple's and red on one shaped as XDict's before the parity work.
"""
import re

# The tour's fixture library, in the reader's order (Tools/build-fixtures.sh): what the scope bar lists after "All".
FIXTURE_DICTIONARIES = ["Alpha", "Beta"]
# The same, as the Search menu names them (Apple's menu gives full names, its bar short ones; XDict has one name).
MENU_DICTIONARIES = FIXTURE_DICTIONARIES
FOUND = re.compile(r"^\d+ found$")
# The menu bar's modifier mask, as `ax menubar` reports it (kAXMenuItemCmdModifiers): 0 is ⌘ alone.
CMD, SHIFT_CMD, OPT_CMD = 0, 1, 2


def nodes(tree):
    """Every element of every window, depth first, with its window."""
    out = []

    def walk(node, window):
        out.append((node, window))
        for kid in node.get("children", []):
            walk(kid, window)

    for window in tree.get("windows", []):
        walk(window, window)
    return out


def main_window(tree):
    for window in tree.get("windows", []):
        if window.get("role") == "AXWindow" and window.get("subrole") == "AXStandardWindow":
            return window
    return (tree.get("windows") or [{}])[0]


def label(node):
    return node.get("title") or node.get("description") or node.get("value") or ""


def find(tree, role=None, text=None, ident=None, visible=True):
    """Elements by role, label (exact, or a compiled pattern) and identifier; with `visible`, only those drawn."""
    found = []
    for node, _ in nodes(tree):
        if role and node.get("role") != role:
            continue
        if ident and node.get("identifier") != ident:
            continue
        if text is not None:
            value = label(node)
            if hasattr(text, "match"):
                if not text.match(str(value)):
                    continue
            elif value != text:
                continue
        frame = node.get("frame") or [0, 0, 0, 0]
        if visible and (frame[2] < 1 or frame[3] < 1):
            continue
        found.append(node)
    return found


def texts(tree):
    return [str(label(n)) for n, _ in nodes(tree) if n.get("role") == "AXStaticText"]


def results_table(tree):
    tables = [n for n in find(tree, "AXTable") if n.get("description") == "search results"]
    return tables[0] if tables else None


def rows(table):
    return [n for n in table.get("children", []) if n.get("role") == "AXRow"] if table else []


def row_texts(table):
    out = []
    for row in rows(table):
        for node, _ in nodes({"windows": [row]}):
            if node.get("role") in ("AXStaticText", "AXTextField") and label(node):
                out.append(str(label(node)))
                break
    return out


# ---- the rules, each returning None when Apple's, else why not ----

def title_dictionary(tree):
    window = main_window(tree)
    titles = [str(label(n)) for n in find(tree, "AXStaticText", "Dictionary")]
    if not str(window.get("title", "")).startswith("Dictionary") and not titles:
        return f"the window's title is {window.get('title')!r}, not 'Dictionary'"
    return None


def title_found(tree):
    window = main_window(tree)
    if FOUND.match(str(window.get("title", "")).split(" – ")[-1]) or find(tree, "AXStaticText", FOUND):
        return None
    return f"no 'N found' under the title (window title {window.get('title')!r})"


def title_no_count(tree):
    if find(tree, "AXStaticText", FOUND) or "found" in str(main_window(tree).get("title", "")):
        return "a count shows before anything was found"
    return None


def toolbar_order(tree):
    names = ["Back", "Forward", "Smaller Text", "Bigger Text"]
    xs = []
    for name in names:
        buttons = [n for n in find(tree, "AXButton") if n.get("description") == name or n.get("title") == name]
        if not buttons:
            return f"no {name!r} button in the toolbar"
        xs.append(buttons[0]["frame"][0])
    field = search_field(tree)
    if field is None:
        return "no search field"
    xs.append(field["frame"][0])
    if xs != sorted(xs):
        return f"toolbar order is not Back, Forward, Smaller Text, Bigger Text, search: x {xs}"
    return None


def toolbar_help(tree):
    wanted = {"Back": "Show the previous result", "Forward": "Show the next result",
              "Smaller Text": "Decrease font size", "Bigger Text": "Increase font size"}
    for name, help_text in wanted.items():
        buttons = [n for n in find(tree, "AXButton") if n.get("description") == name or n.get("title") == name]
        if not buttons or buttons[0].get("help") != help_text:
            return f"{name}: help {buttons[0].get('help') if buttons else None!r}, Apple's is {help_text!r}"
    return None


def search_field(tree):
    fields = [n for n in find(tree, "AXTextField") if n.get("subrole") == "AXSearchField"]
    return fields[0] if fields else None


def search_placeholder(tree):
    field = search_field(tree)
    if field is None:
        return "no search field"
    if field.get("placeholder") not in ("Search", None) or (field.get("placeholder") is None
                                                             and field.get("description") != "Search"):
        return f"the search field's placeholder is {field.get('placeholder')!r}, not 'Search'"
    return None


def scope_bar(tree):
    groups = [g for g in find(tree, "AXRadioGroup")
              if [label(b) for b in g.get("children", []) if b.get("role") == "AXRadioButton"][:1] == ["All"]]
    if not groups:
        return "no scope bar: a radio group whose first button is 'All'"
    names = [label(b) for b in groups[0]["children"] if b.get("role") == "AXRadioButton"]
    if names[1:1 + len(FIXTURE_DICTIONARIES)] != FIXTURE_DICTIONARIES:
        return f"the scope bar lists {names}, not All then {FIXTURE_DICTIONARIES}"
    toolbar = find(tree, "AXToolbar")
    if toolbar and groups[0]["frame"][1] < toolbar[0]["frame"][1] + toolbar[0]["frame"][3] - 1:
        return "the scope bar is not under the toolbar"
    return None


def scope_selected(index):
    def rule(tree):
        name = FIXTURE_DICTIONARIES[index]
        for group in find(tree, "AXRadioGroup"):
            for button in group.get("children", []):
                if button.get("role") == "AXRadioButton" and label(button) == name:
                    return None if str(button.get("value")) == "1" else f"{name} is not the chosen scope"
        return f"no scope button {name!r}"
    return rule


def no_sidebar(tree):
    if results_table(tree):
        return "the sidebar shows before a search"
    return None


def sidebar_table(tree):
    table = results_table(tree)
    if table is None:
        return "no 'search results' table in the sidebar"
    # The first screenful: Apple's own table gives rows far below the fold 24 pt (measured, search.result).
    heights = {round(r["frame"][3]) for r in rows(table)[:10] if r.get("frame")}
    if not heights or heights - {28}:
        return f"result rows are {sorted(heights)} pt high, Apple's 28"
    return None


def sidebar_fonts(tree):
    table = results_table(tree)
    sizes, names = set(), set()
    for row in rows(table):
        for node, _ in nodes({"windows": [row]}):
            for run in node.get("font") or []:
                if isinstance(run, dict):
                    sizes.add(run.get("size"))
                    names.add(run.get("name"))
    if sizes != {13}:
        return f"result rows' text is {sorted(map(str, sizes))} pt, Apple's 13"
    if not any("Demi" in n or "Semibold" in n for n in names if n):
        return f"no row is semibold (fonts {sorted(n for n in names if n)})"
    return None


def sidebar_flat(tree):
    if any(t in ("Not Searched", "Suggestions", "Recent Lookups") for t in texts(tree)):
        return "the sidebar still has sections"
    return None


def rows_include(*words):
    def rule(tree):
        got = row_texts(results_table(tree))
        missing = [w for w in words if w not in got]
        return f"rows {got[:8]} lack {missing}" if missing else None
    return rule


def notices_in_page(tree):
    table = results_table(tree)
    inside = {id(n) for n, _ in nodes({"windows": [table]})} if table else set()
    notices = [n for n in find(tree, ident="status") if id(n) not in inside]
    return None if notices else "no notice in the page for the dictionaries that could not search"


def start_page(tree):
    if "Type a word to look up in…" not in texts(tree):
        return "no 'Type a word to look up in…' start page"
    missing = [d for d in FIXTURE_DICTIONARIES if d not in texts(tree)]
    return f"the start page does not name {missing}" if missing else None


def no_entries_line(tree):
    lines = find(tree, "AXStaticText", "No entries found.")
    if not lines:
        return "no 'No entries found.' line"
    bars = find(tree, "AXRadioGroup")
    if bars:
        bar = bars[0]["frame"]
        x, y = lines[0]["frame"][:2]
        if not (0 <= x - bar[0] <= 40 and 0 <= y - (bar[1] + bar[3]) <= 80):
            return f"'No entries found.' is at {lines[0]['frame']}, not at the pane's top left (bar {bar})"
    return None


def minimum_size(tree):
    frame = main_window(tree).get("frame") or [0, 0, 0, 0]
    if [round(frame[2]), round(frame[3])] != [400, 300]:
        return f"asked for 100 × 100, the window took {frame[2]:g} × {frame[3]:g}, not 400 × 300"
    return None


def narrow(tree):
    field, window = search_field(tree), main_window(tree).get("frame")
    if field is None:
        return "no search field at 400 pt"
    f = field["frame"]
    if window and f[0] + f[2] > window[0] + window[2] + 2:
        return "the search field runs out of the window at 400 pt"
    return scope_bar(tree)


def find_bar(tree):
    fields = [n for n in find(tree, "AXTextField") if n.get("subrole") == "AXSearchField"]
    return None if len(fields) >= 2 else "no find bar's field beside the search field"


def dividers(tree):
    """The All page's dividers (P15), top to bottom: (name, expanded)."""
    found = [n for n in find(tree, "AXDisclosureTriangle", visible=False)
             if str(n.get("identifier", "")).startswith("page.divider.")]
    found.sort(key=lambda n: (n.get("frame") or [0, 0])[1])
    return [(label(n), str(n.get("value")) not in ("0", "False", "false")) for n in found]


def page_dividers(*names):
    def rule(tree):
        got = [name for name, _ in dividers(tree)]
        return None if got == list(names) else f"dividers {got}, not {list(names)}"
    return rule


def page_collapsed(name):
    def rule(tree):
        state = dict(dividers(tree)).get(name)
        return None if state is False else f"{name}'s divider is {'missing' if state is None else 'expanded'}"
    return rule


# ---- the menu bar ----

def menu(menubar, title):
    for item in (menubar or {}).get("menubar", []):
        if item.get("title") == title:
            return item.get("items", [])
    return None


def item(items, title):
    for entry in items or []:
        if entry.get("title") == title:
            return entry
    return None


def keyed(menubar, path, key, mods):
    items = menu(menubar, path[0])
    if items is None:
        return f"no {path[0]} menu"
    for step in path[1:-1]:
        items = (item(items, step) or {}).get("items")
    entry = item(items, path[-1])
    if entry is None:
        return f"no {' ▸ '.join(path)}"
    if str(entry.get("key", "")).upper() != key.upper() or entry.get("mods", 0) != mods:
        return f"{' ▸ '.join(path)} is key {entry.get('key')!r} mods {entry.get('mods')}, Apple's {key!r} mods {mods}"
    return None


def menus_search(menubar):
    for path, key, mods in [(["Search", "All Dictionaries"], "0", CMD),
                            (["Search", MENU_DICTIONARIES[0]], "1", CMD),
                            (["Search", MENU_DICTIONARIES[1]], "2", CMD),
                            (["Search", "Select Next Dictionary"], "}", CMD),
                            (["Search", "Select Previous Dictionary"], "{", CMD)]:
        why = keyed(menubar, path, key, mods)
        if why:
            return why
    if menu(menubar, "Dictionaries") is not None:
        return "the old Dictionaries menu is still there"
    return None


def menus_view(menubar):
    for entry in menu(menubar, "View") or []:
        if str(entry.get("key", "")) == "0" and entry.get("mods") == CMD:
            return f"⌘0 is still {entry.get('title')!r} in View, not All Dictionaries"
    return keyed(menubar, ["View", "Actual Size"], "0", OPT_CMD)


def menus_file(menubar):
    return keyed(menubar, ["File", "New Tab"], "T", CMD) or keyed(menubar, ["File", "Print…"], "P", CMD)


def menus_find(menubar):
    for title, key, mods in [("Search For a New Word…", "F", OPT_CMD), ("Find…", "F", CMD), ("Find Next", "G", CMD),
                             ("Find Previous", "G", SHIFT_CMD), ("Use Selection for Find", "E", CMD),
                             ("Jump to Selection", "J", CMD)]:
        why = keyed(menubar, ["Edit", "Find", title], key, mods)
        if why:
            return why
    return None


def menus_window(menubar):
    titles = [e.get("title") for e in menu(menubar, "Window") or []]
    tabs = {"Show Tab Bar", "Show All Tabs", "Show Previous Tab", "Merge All Windows"}
    return None if tabs & set(titles) else f"no tab items in Window: {titles}"


def menus_help(menubar):
    titles = [e.get("title") for e in menu(menubar, "Help") or []]
    return None if "XDict Help" in titles else f"no XDict Help in Help: {titles}"


def menus_go(menubar):
    return keyed(menubar, ["Go", "Back"], "[", CMD) or keyed(menubar, ["Go", "Forward"], "]", CMD)


TREE_RULES = {
    "main.start": [("P2", title_dictionary), ("P2", title_no_count), ("P3", toolbar_order), ("P4", toolbar_help),
                   ("P5", search_placeholder), ("P6", scope_bar), ("P9", no_sidebar), ("P14", start_page),
                   ("P42", toolbar_order)],
    "search.result": [("P2", title_found), ("P9", sidebar_table), ("P9", sidebar_flat), ("P9", notices_in_page),
                      ("P43", sidebar_fonts), ("P6", scope_bar)],
    "search.live": [("P10", rows_include("take off")), ("P2", title_found)],
    "search.next": [("P11", sidebar_table)],
    "search.didyoumean": [("P13", lambda t: None if "Did you mean?" in texts(t) else "no 'Did you mean?'"),
                          ("P13", rows_include("banana"))],
    "search.none": [("P12", no_entries_line), ("P2", title_no_count)],
    "window.min": [("P1", minimum_size)],
    "main.narrow": [("P8", narrow)],
    "scope.one": [("P7", scope_selected(1))],
    "entry.find": [("P30", find_bar)],
    "page.all": [("P15", page_dividers("Beta", "Records")), ("P16", title_dictionary)],
    "page.collapse": [("P15", page_collapsed("Beta"))],
    "page.one": [("P15", page_dividers())],
    "page.find": [("P30", find_bar), ("P15", page_dividers("Beta", "Records"))],
}

MENU_RULES = {
    "main.start": [("P7", menus_search), ("P36", menus_search), ("P7", menus_view), ("P32", menus_file),
                   ("P33", menus_find), ("P37", menus_window), ("P38", menus_help), ("P42", menus_go)],
}


def checks(route, tree, menubar=None):
    out = []
    for pid, rule in TREE_RULES.get(route, []):
        why = rule(tree)
        out.append({"id": pid, "ok": why is None, "why": why or ""})
    for pid, rule in MENU_RULES.get(route, []):
        why = rule(menubar) if menubar else "the menu bar was not read"
        out.append({"id": pid, "ok": why is None, "why": why or ""})
    return out
