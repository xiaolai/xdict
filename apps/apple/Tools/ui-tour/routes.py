"""Every user route of XDict's macOS shell the UI tour walks (Tools/ui-tour/tour.py), and those it cannot.

A route is (id, launch, how a user gets there, what should be visible, steps). `launch` is the library the app starts
over: "reader" (a real first launch, `tour.py --reader`), "full" (the lookup fixtures: alpha, beta, records, slow, and the damaged, gone and locked files) or "empty" (no
dictionary). Every route starts from the main window alone, the search field holding the keyboard. Steps:

    ("key", combo)                 one key with modifiers, held to the app (`keys press`)
    ("type", text)                 the text field holding the keyboard (the search field, unless a click moved it)
                                   selected and the text typed (`keys type`)
    ("menu", index, title...)      a menu-bar item by position (0 Apple, 1 XDict, 2 File, ...) and an item path; a title
                                   is translated for the Chinese UI from the bundle's strings; "#n" is the n-th item
    ("menuopen", index)            that menu left open for the capture
    ("press", match...)            AXPress on an element by identifier, title, description or value
    ("click", match...)            a real click at its centre
    ("extra",)                     the menu-bar extra opened
    ("size", width, height)        the main window set to that size, in points (Apple's 400 × 300 pt minimum)
    ("drop", fixture)              a file of fixtures/library dragged from a source window onto the window in front (Settings ▸ Dictionaries)
    ("wait", seconds)
    ("after", step...)            a step run after the capture (the print panel cancelled before the app quits)
    ("pref", key, value)           one of XDict's preferences (`PREFS`) stored before the launch, after the tour deleted
                                   them: a state the route needs, never reached by clicking a switch whose state it
                                   cannot know (menubar.hoverOff, 2026-10-19)

Each route runs over a launch of its own, so nothing a route leaves behind reaches the next. No two driven routes walk the
same way (waits aside): one that only waits longer captures the same picture (ui_tour_test).

Routes with `steps=None` are not driven: their `how` says why, and the index lists them as not captured. The main
window's routes are also held to Apple's Dictionary by `parity.py` (the parity ledger's ids), on English variants.
"""

SEARCH = ("key", "cmd+opt+f")
NARROW = ("size", 400, 300)
SETTINGS = ("key", "cmd+,")
# Settings ▸ Dictionaries, the only dictionary list (ADR-0012 d.2).
DICTIONARIES = [SETTINGS, ("wait", 1), ("click", "Dictionaries"), ("wait", 1)]


def look_up(word):
    return [SEARCH, ("type", word), ("key", "return"), ("wait", 1.5)]


# The preferences a route may store before its launch, with their type: the keys the app reads (HoverControl.enabledKey).
PREFS = {"hoverLookupEnabled": bool}


def prefs(steps):
    """A route's `("pref", key, value)` steps as (key, value), each checked against `PREFS`; ValueError otherwise."""
    found = []
    for step in steps:
        if step[0] != "pref":
            continue
        if len(step) != 3 or step[1] not in PREFS or type(step[2]) is not PREFS[step[1]]:
            raise ValueError(f"no such preference step {step}: one of {sorted(PREFS)}, typed as PREFS says")
        found.append((step[1], step[2]))
    return found


def defaults_commands(domain, preferences):
    """The `defaults write` commands storing `preferences` ((key, value) as `prefs` gives them) in `domain`, a defaults
    domain or a plist's path: what tour.py's Session runs before a launch, and ui_tour_test runs against a scratch
    plist."""
    return [["defaults", "write", domain, key, "-bool", "YES" if value else "NO"] for key, value in preferences]


ROUTES = [
    ("reader.firstLaunch", "reader", "Launch XDict for the first time (a real launch, no instrument; `--reader`)",
     "The setup board opening by itself over the first main window; English, the Mac's own appearance", []),
    # The main window
    ("main.start", "full", "Launch XDict", "As Apple's Dictionary (P2–P6, P14): the title 'XDict' (XDict's own); Back / "
     "Forward, Smaller / Bigger Text and the search field ('Search', its magnifier the scope menu) in the toolbar; "
     "the entry right under the toolbar, no scope bar; no sidebar; 'Type a word to look up in…' and the dictionaries' "
     "names, centred", []),
    ("window.min", "full", "Ask for a 100 × 100 pt main window (P1)", "It takes Apple's minimum, 400 × 300 pt",
     [("size", 100, 100)]),
    ("main.w640", "full", "Look up 'apple' at 640 pt (P8)", "Search field (with its scope menu), the pairs and the "
     "title in the toolbar", [("size", 640, 500), ("key", "cmd+opt+f"), ("type", "apple"),
                                           ("key", "return"), ("wait", 1.5)]),
    ("main.narrow", "full", "Look up 'apple' at the 400 pt minimum (P8)", "The search field and its scope menu still "
     "there; Back / Forward and the text size in the toolbar's overflow",
     [NARROW] + [("key", "cmd+opt+f"), ("type", "apple"), ("key", "return"), ("wait", 1.5)]),
    ("main.noDictionaries", "empty", "Launch XDict with an empty library", "'No Dictionaries' with its sentence and an "
     "'Open Dictionary Settings' button", []),
    ("search.result", "full", "Type 'apple', Return", "As Apple's (P2, P9, P43): 'N found' under the title; the "
     "sidebar one flat list of headwords (28 pt rows, 13 pt, the selected one semibold); the damaged and gone "
     "dictionaries said in the page, above the entry", look_up("apple")),
    ("search.next", "full", "Type 'apple', Return, then Down (P11)", "The next headword chosen and shown, the list "
     "holding the keyboard", look_up("apple") + [("key", "down"), ("wait", 1)]),
    ("search.live", "full", "Type 'take o' without Return (P10)", "'take off' shown at once, the list of 'take o…' "
     "headwords in the sidebar", [SEARCH, ("type", "take o"), ("wait", 1.5)]),
    ("search.didyoumean", "full", "Type 'bananna', Return (P13)", "'Did you mean?' over 'banana', its "
     "entry shown", look_up("bananna")),
    ("search.phrase", "full", "Type 'take o', Down, Return", "The phrase 'take off' looked up and shown",
     [SEARCH, ("type", "take o"), ("wait", 1.2), ("key", "down"), ("key", "return"), ("wait", 1.5)]),
    ("search.many", "full", "Type 'a', Return", "Many results; the sidebar's 'more' row where a section is cut",
     look_up("a")),
    ("search.none", "full", "Type 'zzqxjv', Return (P12)", "Apple's grey 'No entries found.' at the pane's top left; "
     "no count", look_up("zzqxjv")),
    ("search.noneEmpty", "empty", "Type 'apple', Return over an empty library", "'No Dictionaries', not a blank page",
     look_up("apple")),
    ("trail.followed", "full", "Look up 'apple', Tab into the entry, Tab to its first link, Return", "The linked "
     "entry shown; Back enabled", look_up("apple") + [("key", "tab"), ("key", "tab"), ("key", "return"),
                                                     ("wait", 1.5)]),
    ("trail.back", "full", "... then Back (⌘[)", "The first entry again; Forward enabled",
     look_up("apple") + [("key", "tab"), ("key", "tab"), ("key", "return"), ("wait", 1.2), ("key", "cmd+["),
                         ("wait", 1)]),
    ("trail.origin", "full", "... then Return to Original Word (⌥⌘[)", "The typed word's entry",
     look_up("apple") + [("key", "tab"), ("key", "tab"), ("key", "return"), ("wait", 1.2), ("key", "cmd+opt+["),
                         ("wait", 1)]),
    ("scope.one", "full", "Look up 'apple', then ⌘2 (P7)", "Beta chosen: the field reads 'Search in Beta', its "
     "magnifier in the accent colour; the list and entry Beta's", look_up("apple") + [("key", "cmd+2"), ("wait", 1.2)]),
    ("scope.menu", "full", "Look up 'apple', click the search field's magnifier (P6)", "The 'Search In' menu: All "
     "Dictionaries checked (⌘0), then Alpha (⌘1), Beta (⌘2) and the rest in the reader's order, one that cannot "
     "answer greyed", look_up("apple") + [("click", "scope.menu"), ("wait", 0.8)]),
    ("scope.click", "full", "Look up 'apple', choose Beta in the magnifier's menu (P6)", "Beta chosen: the field "
     "reads 'Search in Beta', its magnifier in the accent colour; the list and entry Beta's",
     look_up("apple") + [("click", "scope.menu"), ("wait", 0.8), ("key", "down"), ("key", "down"), ("key", "down"),
                         ("key", "return"), ("wait", 1.2)]),
    ("entry.find", "full", "Look up 'apple', ⌘F, type 'a' (P30)", "The find bar under the toolbar with a match "
     "count; the page dimmed, the matches white, the current one yellow",
     look_up("apple") + [("key", "cmd+f"), ("wait", 0.6), ("key", "a"), ("wait", 0.8)]),
    ("entry.zoomIn", "full", "Look up 'apple', ⌘= twice (P29)", "The entry larger, nothing clipped",
     look_up("apple") + [("key", "cmd+="), ("key", "cmd+="), ("wait", 0.8)]),
    ("entry.collapse", "full", "Look up 'apple', View ▸ Collapse All", "The entry's sections collapsed",
     look_up("apple") + [("menu", 4, "Collapse All"), ("wait", 0.8)]),
    # The All page (P15, P16): `orange` is in Alpha, Beta and Records
    ("page.all", "full", "Type 'orange', Return (P15)", "Alpha's, Beta's and Records' entries on one page in the "
     "reader's order, each in its own frame sized to it; Alpha's with no divider, then Apple's divider (triangle, grey "
     "rule, the name centred) before Beta and Records; one scroller, the page's", look_up("orange")),
    ("page.collapse", "full", "... then click Beta's divider (P15)", "Beta collapsed to its divider, the triangle "
     "pointing right; Records moved up under it", look_up("orange") + [("press", "page.divider.Beta"), ("wait", 0.8)]),
    ("page.one", "full", "... then ⌘2, Beta alone (P15)", "Only Beta's entry, no divider", look_up("orange")
     + [("key", "cmd+2"), ("wait", 1.2)]),
    ("page.find", "full", "... then ⌘F, type 'fruit' (P15, P30)", "Matches in every frame counted together; the "
     "first one current, yellow", look_up("orange") + [("key", "cmd+f"), ("wait", 0.6), ("type", "fruit"),
                                                       ("key", "return"), ("wait", 1)]),
    ("page.zoomIn", "full", "Type 'orange', Return, then ⌘= twice (P15, P29)", "Every frame larger, and the dividers' "
     "names, bands and triangles with them", look_up("orange") + [("key", "cmd+="), ("key", "cmd+="), ("wait", 1)]),
    ("page.print", "full", "Type 'orange', Return, then File ▸ Print… (P44)", "The system's print panel over the window; "
     "its preview the whole page: Alpha's, Beta's and Records' entries, each under its name, no triangles or rules",
     look_up("orange") + [("menu", 2, "Print…"), ("wait", 6), ("after", "key", "escape")]),
    ("speech.pronounce", "full", "Look up 'apple', ⌥⌘P", "Spoken (volume 0 here); a notice if no voice or recording",
     look_up("apple") + [("key", "cmd+opt+p"), ("wait", 1.5)]),
    # Menus
    ("menu.app", "full", "Click the XDict menu", "About XDict, Acknowledgments, Settings…, Set Up XDict…, "
     "Services, Hide, Quit", [("menuopen", 1)]),
    ("menu.file", "full", "Click File (P32)", "New Window, New Tab ⌘T, Add Dictionaries… ⌘O, Close, Print… ⌘P",
     [("menuopen", 2)]),
    ("menu.edit", "full", "Click Edit (P33)", "Find ▸ (Search For a New Word… ⌥⌘F, Find… ⌘F, Find Next ⌘G, Find "
     "Previous ⇧⌘G, Use Selection for Find ⌘E, Jump to Selection ⌘J), Pronounce ⌥⌘P", [("menuopen", 3)]),
    ("menu.editFind", "full", "Click Edit ▸ Find (P33)", "Apple's Find submenu", [("menu", 3, "Find"), ("wait", 0.4)]),
    ("menu.view", "full", "Click View", "Bigger Text ⌘+, Smaller Text ⌘-, Actual Size ⌥⌘0, Expand All, Collapse "
     "All", [("menuopen", 4)]),
    ("menu.go", "full", "Click Go", "Back ⌘[, Forward ⌘], Return to Original Word ⌥⌘[", [("menuopen", 5)]),
    ("menu.search", "full", "Click Search (P7, P36)", "All Dictionaries ⌘0, each dictionary ⌘1…, Select Next "
     "Dictionary ⌘}, Select Previous Dictionary ⌘{", [("menuopen", 6)]),
    ("menu.window", "full", "Click Window (P37)", "The tab items and the window list (no Library: ADR-0012 d.5)",
     [("menuopen", 7)]),
    ("menu.help", "full", "Click Help (P38)", "The help search field and XDict Help", [("menuopen", 8)]),
    ("menu.services", "full", "Select the search field's word, XDict ▸ Services", "The Services submenu, XDict's "
     "own lookup among them", look_up("apple") + [SEARCH, ("menu", 1, "Services|服务")]),
    ("menubar.extra", "full", "Click XDict's menu-bar item", "Look Up Selection (⌃⌥D), Open XDict, Dictionaries…, "
     "Settings…, Quit XDict", [("extra",)]),
    ("about", "full", "XDict ▸ About XDict", "The About panel: icon, version, copyright", [("menu", 1, "#0")]),
    ("acknowledgments", "full", "XDict ▸ Acknowledgments", "Every third-party notice, readable",
     [("menu", 1, "Acknowledgments")]),
    ("setup.board", "full", "XDict ▸ Set Up XDict…", "Each setup row with its live state and action",
     [("menu", 1, "Set Up XDict…")]),
    ("setup.boardEmpty", "empty", "XDict ▸ Set Up XDict… over an empty library", "The Dictionaries row not done, "
     "'Add Dictionaries…'", [("menu", 1, "Set Up XDict…")]),
    # The panel
    ("panel.selection", "full", "Select 'apple' in the search field, ⌃⌥D", "The lookup panel: the query, the "
     "dictionary picker, the entry, 'Open in XDict'", look_up("apple") + [SEARCH, ("key", "ctrl+opt+d"),
                                                                        ("wait", 2)]),
    ("panel.expand", "full", "The panel's Open in XDict", "The main window with the panel's word, dictionary and "
     "entry, the search field focused", look_up("apple") + [SEARCH, ("key", "ctrl+opt+d"), ("wait", 2),
                                                           ("press", "panel.expand"), ("wait", 1.5)]),
    ("panel.expandNarrow", "full", "Open in XDict into a 400 pt main window", "As panel.expand, at the minimum width",
     [NARROW] + look_up("apple") + [SEARCH, ("key", "ctrl+opt+d"), ("wait", 2), ("press", "panel.expand"),
                                    ("wait", 1.5)]),
    ("panel.noDictionaries", "empty", "⌃⌥D over an empty library, a word selected", "The panel's 'No Dictionaries'",
     [("type", "apple"), ("key", "cmd+a"), ("key", "ctrl+opt+d"), ("wait", 2)]),
    # Settings. Three panes (ADR-0012 d.1): Dictionaries, Reading & Speech, General. The Dictionaries pane is the only
    # dictionary list (d.2); its routes are the Library window's, moved by what they drive (d.7,
    # dev-docs/settings-library-inventory.md).
    ("settings.dictionaries.empty", "empty", "⌘, ▸ Dictionaries over an empty library", "'No Dictionaries Yet' with "
     "'Add MDX Files…' over the empty table", DICTIONARIES),
    ("settings.dictionaries.details", "full", "⌘, ▸ Dictionaries, click 'alpha', Details…", "The sheet: Name, Files, "
     "Reading style (fonts, sheets), Health, Languages, Reading (Original style), About (title, format, entries, "
     "edition), Remove from Library, Done", DICTIONARIES + [("click", "alpha", "Alpha"), ("wait", 0.8),
                                            ("click", "settings.details"), ("wait", 1.5)]),
    ("settings.dictionaries.originalStyle", "full", "⌘, ▸ Dictionaries, click 'alpha', switch Original style on",
     "The switch on, in the options box", DICTIONARIES + [("click", "alpha", "Alpha"), ("wait", 0.8),
                                           ("click", "original-style"), ("wait", 0.8)]),
    ("settings.dictionaries.damaged", "full", "⌘, ▸ Dictionaries, click 'damaged'", "Beneath the table, a sentence "
     "naming why it cannot be read (bad checksum), with Show in Finder",
     DICTIONARIES + [("click", "damaged", "Damaged"), ("wait", 1.2)]),
    ("settings.dictionaries.gone", "full", "⌘, ▸ Dictionaries, click 'gone'", "Beneath the table, the file is "
     "missing, said in a sentence, with Locate…", DICTIONARIES + [("click", "gone", "Gone"), ("wait", 1.2)]),
    ("settings.dictionaries.records", "full", "⌘, ▸ Dictionaries, click 'records', Details…", "A large dictionary's "
     "details and health", DICTIONARIES + [("click", "records", "Records"), ("wait", 0.8),
                            ("click", "settings.details"), ("wait", 1.5)]),
    ("settings.dictionaries.addPanel", "full", "⌘, ▸ Dictionaries, ⌘O (+ ▸ Add MDX Files…)", "The open panel for "
     ".mdx/.mdd and folders", DICTIONARIES + [("key", "cmd+o"), ("wait", 2)]),
    ("settings.dictionaries.addMenu", "full", "⌘, ▸ Dictionaries, click +", "The + menu: Add MDX Files… ⌘O, then "
     "Add Apple Dictionaries… (P39; ADR-0011 decision 1)", DICTIONARIES + [("click", "settings.add"), ("wait", 0.8)]),
    # ADR-0011 (plan WI-5): the Apple dictionaries installed on the Mac the tour runs on; nothing is converted.
    ("settings.dictionaries.appleImport", "full", "⌘, ▸ Dictionaries, + ▸ Add Apple Dictionaries…", "The sheet: a "
     "checkbox per Apple dictionary installed on this Mac with its languages and size, 'Apple Dictionary' greyed with "
     "its sentence, how to download more (Dictionary.app ▸ Settings), Cancel and Import (dimmed until one is ticked)",
     DICTIONARIES + [("click", "settings.add"), ("wait", 0.8), ("click", "Add Apple Dictionaries…"), ("wait", 3)]),
    ("settings.dictionaries.dropV3", "full", "Drag a format 3.0 .mdx onto the table", "Imported and Ready: XDict "
     "reads format 3.0 dictionaries (ADR-0005)", DICTIONARIES + [("drop", "refused/v3/v3.mdx"), ("wait", 3)]),
    ("settings.dictionaries.dropV3Mdd", "full", "Drag a folder holding a format 3.0 .mdx and its .mdd onto the table",
     "The dictionary imported and selected, its .mdd refused with the sentence naming format 3.0 resources "
     "(Details…)", DICTIONARIES + [("drop", "refused/v3"), ("wait", 3), ("click", "settings.details"),
                    ("wait", 1.2)]),
    ("settings.dictionaries.dropEncrypted", "full", "Drag a registration-code file onto the table", "Refused, with a "
     "notice in the strip", DICTIONARIES + [("drop", "refused/regcode/regcode.mdx"), ("wait", 3)]),
    ("settings.dictionaries.dropImported", "empty", "Drag a good .mdx onto the empty table", "The new dictionary "
     "imported, listed and selected", DICTIONARIES + [("drop", "file/single.mdx"), ("wait", 4)]),
    # Settings ▸ General holds every row on screen at once (the window is as tall as its form), so a route scrolled to
    # a section would capture the same picture: one route shows the pane, and only a route that changes a row's state
    # is another (2026-10-19: settings.general.screenRecording and settings.lookup were dropped, both the same walk as
    # this one; the Screen Recording row shows here, in the state macOS holds for XDict.app on the touring Mac).
    ("settings.general", "full", "⌘, ▸ General", "Open XDict when you log in, Keep XDict in the menu bar, Language; "
     "Look up the selection: the shortcut recorder, its sentence; hover's rows: 'Look up the word under the pointer' "
     "on (the tour's launch deletes XDict's preferences), Hover key (Option ⌥), Gesture (Hold | Press Twice), Rest "
     "time, Looks up (the writing systems of the enabled dictionaries, shown and not chosen), Password managers: "
     "Always, Never look up in with Add an App…, Never look up on with its bordered field (example.com) and Add Site, "
     "its sentence two lines at most (P53), then Screen Recording in the state macOS holds for XDict.app on this Mac: "
     "not set up with Allow…, allowed, not allowed with where System Settings keeps the switch and Check Again, or "
     "could not tell with Check Again; showing it asks for nothing, so no system prompt (P50, P52; ADR-0014 decision "
     "7); Lookup popup; Background with Glass and Solid, said once; Show Setup…",
     [SETTINGS, ("wait", 1), ("click", "General")]),
    ("settings.dictionaries", "full", "⌘, ▸ Dictionaries", "Apple's table with every dictionary in order, + and − "
     "under it, the options box below (P39, P40); the strip above it holds the fixtures' notice: no 'locked' row, as "
     "the fixtures' registration-code file is refused at import, the notice naming why (ADR-0005 decision 4, "
     "5b19fbd; this was settings.dictionaries.locked, the same walk, dropped 2026-10-19)", DICTIONARIES),
    ("settings.readingSpeech", "full", "⌘, ▸ Reading & Speech", "Accent colour with its sentence; English accent, "
     "Voice, Open Read & Speak Settings, Use the dictionary's recordings",
     [SETTINGS, ("wait", 1), ("click", "Reading & Speech")]),
    ("settings.recording", "full", "⌘, ▸ General, click the recorder", "'Type the new shortcut'",
     [SETTINGS, ("wait", 1), ("click", "General"), ("wait", 0.6), ("click", "shortcut.recorder"), ("wait", 0.6)]),
    # Hover (plan-capture WI-3, WI-4; defined by WI-5): its rows in Settings ▸ General (settings.general) and the
    # menu-bar pause group. The tour's launch deletes XDict's preferences, so hover is on, with the Option key and Hold.
    # The menu shows the reader's setting, not whether the driven run watches (it never does: HoverControl.isOn).
    ("settings.general.hover", "full", "⌘, ▸ General, click Never look up on's field, type a site", "The field in use: "
     "its border and focus ring, 'example.org' in it, Add Site enabled; the sentence beside it two lines at most (P53)",
     [SETTINGS, ("wait", 1), ("click", "General"), ("wait", 0.8), ("click", "hover.site.field"), ("wait", 0.4),
      ("type", "example.org")]),
    ("menubar.hoverPause", "full", "Click XDict's menu-bar item, then Pause Hover", "Pause Hover's lengths: For 15 "
     "minutes, For 1 hour, For 8 hours, between Dictionaries… and Settings… (P51)",
     [("extra",), ("press", "Pause Hover"), ("wait", 0.6)]),
    # A pause length's title is the system's words for its length ("For %@" in English, the length alone in Chinese).
    ("menubar.hoverPaused", "full", "Pause Hover ▸ For 15 minutes, then XDict's menu-bar item again", "'Hover resumes "
     "in 15 minutes' or 14 (disabled) and Resume Hover where Pause Hover was (P51)",
     [("extra",), ("press", "Pause Hover"), ("wait", 0.6), ("press", "For 15 minutes", "15分钟"), ("wait", 0.6),
      ("extra",)]),
    ("menubar.hoverOff", "full", "Hover turned off in Settings (stored before the launch), then XDict's menu-bar item",
     "'Hover Is Off in Settings', disabled, where Pause Hover was (P51)",
     [("pref", "hoverLookupEnabled", False), ("extra",)]),
    # Not driven
    ("settings.dictionaries.appleUpdated", "full", "An imported Apple dictionary whose bundle Apple updated", "Beneath "
     "the table, 'Apple updated <name>.' with Convert Again; after it, 'Kept as the same dictionary…' with Undo "
     "(ADR-0011 decisions 7 and 8)", None),
    ("settings.dictionaries.appleRemoved", "full", "An imported Apple dictionary whose bundle Apple removed",
     "Beneath the table, 'Apple removed this dictionary’s files; this copy still reads.' (ADR-0011 decision 9)", None),
    ("settings.dictionaries.loading", "full", "An import in progress", "Progress and Cancel in the strip above the "
     "table", None),
    ("lookup.held", "full", "A dictionary slow to answer", "Its section waiting, the others shown", None),
    ("settings.dictionaries.changed", "full", "A dictionary's file replaced", "Beneath the table, 'Is it still the "
     "same dictionary?' with Same / A Different Dictionary, then Undo", None),
    ("services.otherApp", "full", "Services ▸ Look Up in XDict from another app", "The panel over that app", None),
    ("anywhere.noAccess", "full", "⌃⌥D with Accessibility not granted", "'Nothing to Look Up' and 'Open "
     "Accessibility Settings'", None),
    ("sound.recording", "full", "A sound:// link in an entry", "The recording plays, or a notice says why not", None),
    ("settings.general.screenRecordingNotSetUp", "full", "The Screen Recording row before XDict ever asked",
     "'Lets hover read words in apps that do not share their text, such as terminals and images. macOS asks once.' "
     "and Allow… (P52)", None),
    ("settings.general.screenRecordingAllowed", "full", "The Screen Recording row with the grant given", "'Hover reads "
     "words from the screen where an app does not share its text.' and 'Allowed', no button (P52)", None),
    ("settings.general.screenRecordingNotAllowed", "full", "The Screen Recording row with the grant refused", "'Not "
     "allowed. Turn XDict on in System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording, then check "
     "again.' and Check Again (P52)", None),
    ("settings.general.screenRecordingCouldNotTell", "full", "The Screen Recording row when macOS gave no answer",
     "'Could not tell whether Screen Recording is allowed. Check again in a moment.' and Check Again (P52)", None),
    ("hover.popover", "full", "Hold Option with the pointer resting on a word in another app (TextEdit)", "XDict's "
     "lookup popover beside the word (P41, P50); released and moved away, it stays until dismissed", None),
]

NOT_DRIVEN_WHY = {
    "settings.dictionaries.loading": "an import lasts milliseconds over the fixtures; only the E2E lookup scenario's "
                                     "TransportHold holds one open, and it runs only with that scenario",
    "lookup.held": "the TransportHold is the E2E scenario's to set; the tour does not run the scenario",
    "settings.dictionaries.changed": "needs a dictionary's file replaced under a running app; the E2E library stage "
                                     "does that",
    "services.otherApp": "needs a selection in another app (TextEdit, Notes); the tour drives XDict alone",
    "anywhere.noAccess": "Accessibility grants are never changed by script, and XDict holds it on this Mac",
    "sound.recording": "the lookup fixtures hold no recording; the E2E sound stage plays them at volume 0",
    "settings.dictionaries.appleUpdated": "needs an imported Apple dictionary whose installed bundle then changes; the "
                                          "E2E library.apple stage converts a synthetic one and changes it",
    "settings.dictionaries.appleRemoved": "needs an imported Apple dictionary whose installed bundle then goes; the "
                                          "E2E library.apple stage removes its synthetic one",
    "settings.general.screenRecordingNotSetUp": "only the state macOS holds for XDict.app on this Mac is shown "
                                                "(settings.general), and grants are never changed by "
                                                "script",
    "settings.general.screenRecordingAllowed": "as settings.general.screenRecordingNotSetUp",
    "settings.general.screenRecordingNotAllowed": "as settings.general.screenRecordingNotSetUp",
    "settings.general.screenRecordingCouldNotTell": "macOS answers on this Mac; there is no way to make it not answer",
    "hover.popover": "needs the hover key held over another app's text; the tour drives XDict alone, whose own windows "
                     "hover never reads (ADR-0014 decision 6); the E2E hover.popover sub-stage does it",
}
