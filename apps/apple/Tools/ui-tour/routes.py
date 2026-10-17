"""Every user route of XDict's macOS shell the UI tour walks (Tools/ui-tour/tour.py), and those it cannot.

A route is (id, launch, how a user gets there, what should be visible, steps). `launch` is the library the app starts
over: "reader" (a real first launch, `tour.py --reader`), "full" (the lookup fixtures: alpha, beta, records, slow, and the damaged, gone and locked files) or "empty" (no
dictionary). Every route starts from the main window alone, the search field holding the keyboard. Steps:

    ("key", combo)                 one key with modifiers, held to the app (`keys press`)
    ("type", text)                 the search field selected and the text typed (`keys type`)
    ("menu", index, title...)      a menu-bar item by position (0 Apple, 1 XDict, 2 File, ...) and an item path; a title
                                   is translated for the Chinese UI from the bundle's strings; "#n" is the n-th item
    ("menuopen", index)            that menu left open for the capture
    ("press", match...)            AXPress on an element by identifier, title, description or value
    ("click", match...)            a real click at its centre
    ("extra",)                     the menu-bar extra opened
    ("size", width, height)        the main window set to that size, in points (Apple's 400 × 300 pt minimum)
    ("drop", fixture)              a file of fixtures/library dragged from a source window onto the Library window
    ("wait", seconds)

Each route runs over a launch of its own, so nothing a route leaves behind reaches the next.

Routes with `steps=None` are not driven: their `how` says why, and the index lists them as not captured. The main
window's routes are also held to Apple's Dictionary by `parity.py` (the parity ledger's ids), on English variants.
"""

SEARCH = ("key", "cmd+opt+f")
LIBRARY = ("key", "cmd+shift+l")
NARROW = ("size", 400, 300)
SETTINGS = ("key", "cmd+,")


def look_up(word):
    return [SEARCH, ("type", word), ("key", "return"), ("wait", 1.5)]


ROUTES = [
    ("reader.firstLaunch", "reader", "Launch XDict for the first time (a real launch, no instrument; `--reader`)",
     "The setup board opening by itself over the first main window; English, the Mac's own appearance", []),
    # The main window
    ("main.start", "full", "Launch XDict", "As Apple's Dictionary (P2–P6, P14): the title 'Dictionary'; Back / "
     "Forward, Smaller / Bigger Text and the search field ('Search') in the toolbar; the scope bar (All, Alpha, Beta, "
     "...) under it; no sidebar; 'Type a word to look up in…' and the dictionaries' names, centred", []),
    ("window.min", "full", "Ask for a 100 × 100 pt main window (P1)", "It takes Apple's minimum, 400 × 300 pt",
     [("size", 100, 100)]),
    ("main.narrow", "full", "Look up 'apple' at the 400 pt minimum (P8)", "The search field and the scope bar (All "
     "and what fits, the rest under ») still there; Back / Forward and the text size in the toolbar's overflow",
     [NARROW] + [("key", "cmd+opt+f"), ("type", "apple"), ("key", "return"), ("wait", 1.5)]),
    ("main.noDictionaries", "empty", "Launch XDict with an empty library", "'No Dictionaries' with its sentence and an "
     "'Open Library' button", []),
    ("search.result", "full", "Type 'apple', Return", "As Apple's (P2, P9, P43): 'N found' under the title; the "
     "sidebar one flat list of headwords (28 pt rows, 13 pt, the selected one semibold); the damaged and gone "
     "dictionaries said in the page, above the entry", look_up("apple")),
    ("search.next", "full", "Type 'apple', Return, then Down (P11)", "The next headword chosen and shown, the list "
     "holding the keyboard", look_up("apple") + [("key", "down"), ("wait", 1)]),
    ("search.live", "full", "Type 'take o' without Return (P10)", "'take off' shown at once, the list of 'take o…' "
     "headwords in the sidebar", [SEARCH, ("type", "take o"), ("wait", 1.5)]),
    ("search.didyoumean", "full", "Type 'acomplished', Return (P13)", "'Did you mean?' over 'accomplished', its "
     "entry shown", look_up("acomplished")),
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
    ("scope.one", "full", "Look up 'apple', then ⌘2 (P7)", "The scope bar's Beta chosen; the list and entry Beta's",
     look_up("apple") + [("key", "cmd+2"), ("wait", 1.2)]),
    ("scope.click", "full", "Look up 'apple', click Beta in the scope bar (P6)", "Beta chosen on its grey capsule",
     look_up("apple") + [("click", "Beta"), ("wait", 1.2)]),
    ("entry.find", "full", "Look up 'apple', ⌘F, type 'a' (P30)", "The find bar under the scope bar with a match "
     "count; the page dimmed, the matches white, the current one yellow",
     look_up("apple") + [("key", "cmd+f"), ("wait", 0.6), ("key", "a"), ("wait", 0.8)]),
    ("entry.zoomIn", "full", "Look up 'apple', ⌘= twice (P29)", "The entry larger, nothing clipped",
     look_up("apple") + [("key", "cmd+="), ("key", "cmd+="), ("wait", 0.8)]),
    ("entry.collapse", "full", "Look up 'apple', View ▸ Collapse All", "The entry's sections collapsed",
     look_up("apple") + [("menu", 4, "Collapse All"), ("wait", 0.8)]),
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
    ("menu.window", "full", "Click Window (P37)", "Library ⇧⌘L, the tab items and the window list", [("menuopen", 7)]),
    ("menu.help", "full", "Click Help (P38)", "The help search field and XDict Help", [("menuopen", 8)]),
    ("menu.services", "full", "Select the search field's word, XDict ▸ Services", "The Services submenu, XDict's "
     "own lookup among them", look_up("apple") + [SEARCH, ("menu", 1, "Services|服务")]),
    ("menubar.extra", "full", "Click XDict's menu-bar item", "Look Up Selection (⌃⌥D), Open XDict, Library…, "
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
    # The library
    ("library.window", "full", "⇧⌘L", "The library: every dictionary in order, each with 'Use in lookups', "
     "problem badges on damaged / gone / locked; 'Select a dictionary to see its details.'", [LIBRARY, ("wait", 1)]),
    ("library.empty", "empty", "⇧⌘L over an empty library", "'No Dictionaries Yet' with 'Add Dictionaries…'",
     [LIBRARY, ("wait", 1)]),
    ("library.detail", "full", "⇧⌘L, click 'alpha'", "Name, Files, Reading style (fonts, sheets), Health, "
     "Languages, Reading (Original style), About (title, format, entries, edition), Remove from Library",
     [LIBRARY, ("wait", 1), ("click", "alpha", "Alpha"), ("wait", 1.5)]),
    ("library.originalStyle", "full", "... switch Original style on", "The switch on",
     [LIBRARY, ("wait", 1.5), ("click", "alpha", "Alpha"), ("wait", 1.5), ("click", "original-style"),
      ("wait", 0.8)]),
    ("library.damaged", "full", "⇧⌘L, click 'damaged'", "A sentence naming why it cannot be read (bad checksum)",
     [LIBRARY, ("wait", 1), ("click", "damaged", "Damaged"), ("wait", 1.2)]),
    ("library.gone", "full", "⇧⌘L, click 'gone'", "The file is missing, said in a sentence, with what to do",
     [LIBRARY, ("wait", 1), ("click", "gone", "Gone"), ("wait", 1.2)]),
    ("library.locked", "full", "⇧⌘L over the fixtures, which hold a registration-code file", "No 'locked' row: "
     "such a file is refused at import (ADR-0005 decision 4, 5b19fbd), with a notice naming why",
     [LIBRARY, ("wait", 1.5)]),
    ("library.records", "full", "⇧⌘L, click 'records'", "A large dictionary's details and health",
     [LIBRARY, ("wait", 1), ("click", "records", "Records"), ("wait", 1.5)]),
    ("library.addPanel", "full", "⇧⌘L, Add Dictionaries… (⌘O)", "The open panel for .mdx/.mdd and folders",
     [LIBRARY, ("wait", 1), ("key", "cmd+o"), ("wait", 2)]),
    ("library.dropV3", "full", "Drag a format 3.0 .mdx onto the library", "Imported and Ready: XDict reads format "
     "3.0 dictionaries (ADR-0005)", [LIBRARY, ("wait", 1), ("drop", "refused/v3/v3.mdx"), ("wait", 3)]),
    ("library.dropV3Mdd", "full", "Drag a folder holding a format 3.0 .mdx and its .mdd onto the library",
     "The dictionary imported, and its .mdd refused on it with the sentence naming format 3.0 resources",
     [LIBRARY, ("wait", 1), ("drop", "refused/v3"), ("wait", 3), ("click", "v3", "V3", "Format Three Resources"),
      ("wait", 1.2)]),
    ("library.dropEncrypted", "full", "Drag a registration-code file onto the library", "Refused, or asking for the "
     "reader's own code, with a sentence", [LIBRARY, ("wait", 1), ("drop", "refused/regcode/regcode.mdx"),
                                            ("wait", 3)]),
    ("library.dropImported", "empty", "Drag a good .mdx onto an empty library", "The new dictionary imported and "
     "listed", [LIBRARY, ("wait", 1), ("drop", "file/single.mdx"), ("wait", 4)]),
    # Settings
    ("settings.general", "full", "⌘, ▸ General", "Open XDict when you log in, Language, Show Setup…",
     [SETTINGS, ("wait", 1), ("click", "General")]),
    ("settings.dictionaries", "full", "⌘, ▸ Dictionaries", "Apple's table, options box below (P39, P40)",
     [SETTINGS, ("wait", 1), ("click", "Dictionaries"), ("wait", 1)]),
    ("settings.reading", "full", "⌘, ▸ Reading", "Accent colour with its sentence",
     [SETTINGS, ("wait", 1), ("click", "Reading")]),
    ("settings.speech", "full", "⌘, ▸ Speech", "English accent, Voice, Open Read & Speak Settings, Use the "
     "dictionary's recordings", [SETTINGS, ("wait", 1), ("click", "Speech")]),
    ("settings.lookup", "full", "⌘, ▸ Lookup", "Look up the selection: the shortcut recorder, its sentence",
     [SETTINGS, ("wait", 1), ("click", "Lookup")]),
    ("settings.recording", "full", "⌘, ▸ Lookup, click the recorder", "'Type the new shortcut'",
     [SETTINGS, ("wait", 1), ("click", "Lookup"), ("wait", 0.6), ("click", "shortcut.recorder"), ("wait", 0.6)]),
    # Not driven
    ("library.loading", "full", "An import in progress", "Progress and Cancel on the row", None),
    ("lookup.held", "full", "A dictionary slow to answer", "Its section waiting, the others shown", None),
    ("library.changed", "full", "A dictionary's file replaced", "'Is it still the same dictionary?' with Same / "
     "A Different Dictionary, then Undo", None),
    ("services.otherApp", "full", "Services ▸ Look Up in XDict from another app", "The panel over that app", None),
    ("anywhere.noAccess", "full", "⌃⌥D with Accessibility not granted", "'Nothing to Look Up' and 'Open "
     "Accessibility Settings'", None),
    ("sound.recording", "full", "A sound:// link in an entry", "The recording plays, or a notice says why not", None),
]

NOT_DRIVEN_WHY = {
    "library.loading": "an import lasts milliseconds over the fixtures; only the E2E lookup scenario's TransportHold "
                       "holds one open, and it runs only with that scenario",
    "lookup.held": "the TransportHold is the E2E scenario's to set; the tour does not run the scenario",
    "library.changed": "needs a dictionary's file replaced under a running app; the E2E library stage does that",
    "services.otherApp": "needs a selection in another app (TextEdit, Notes); the tour drives XDict alone",
    "anywhere.noAccess": "Accessibility grants are never changed by script, and XDict holds it on this Mac",
    "sound.recording": "the lookup fixtures hold no recording; the E2E sound stage plays them at volume 0",
}
