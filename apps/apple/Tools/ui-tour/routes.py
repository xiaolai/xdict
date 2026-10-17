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
    ("size", width, height)        the main window set to that size, in points (the 640 pt minimum width)
    ("drop", fixture)              a file of fixtures/library dragged from a source window onto the Library window
    ("wait", seconds)

Each route runs over a launch of its own, so nothing a route leaves behind reaches the next.

Routes with `steps=None` are not driven: their `how` says why, and the index lists them as not captured.
"""

SEARCH = ("key", "cmd+opt+f")
LIBRARY = ("key", "cmd+shift+l")
NARROW = ("size", 640, 560)
SETTINGS = ("key", "cmd+,")


def look_up(word):
    return [SEARCH, ("type", word), ("key", "return"), ("wait", 1.5)]


ROUTES = [
    ("reader.firstLaunch", "reader", "Launch XDict for the first time (a real launch, no instrument; `--reader`)",
     "The setup board opening by itself over the first main window; English, the Mac's own appearance", []),
    # The main window
    ("main.start", "full", "Launch XDict", "Main window, the toolbar's search field focused, 'Look Up a Word' and "
     "'Type a word and press Return.'; toolbar Back / Forward / Return to Original Word, Dictionaries picker, "
     "Pronounce, the search field", []),
    ("main.w640", "full", "Look up 'accomplished' at 640 pt (Codex §1)",
     "Search at least 200 pt, Back and Forward and the scope in the toolbar; below 820 pt the scope a book symbol and "
     "Return in the overflow", [("size", 640, 600)]
     + [("key", "cmd+opt+f"), ("type", "accomplished"), ("key", "return"), ("wait", 1.5)]),
    ("main.w640.closed", "full", "Look up 'accomplished' at 640 pt, sidebar hidden (Codex §1)",
     "Search at least 200 pt, Back and Forward and the scope in the toolbar; below 820 pt the scope a book symbol and "
     "Return in the overflow", [("size", 640, 600)] + [("key", "ctrl+cmd+s"), ("wait", 0.6)]
     + [("key", "cmd+opt+f"), ("type", "accomplished"), ("key", "return"), ("wait", 1.5)]),
    ("main.w720", "full", "Look up 'accomplished' at 720 pt (Codex §1)",
     "Search at least 200 pt, Back and Forward and the scope in the toolbar; below 820 pt the scope a book symbol and "
     "Return in the overflow", [("size", 720, 600)]
     + [("key", "cmd+opt+f"), ("type", "accomplished"), ("key", "return"), ("wait", 1.5)]),
    ("main.w720.closed", "full", "Look up 'accomplished' at 720 pt, sidebar hidden (Codex §1)",
     "Search at least 200 pt, Back and Forward and the scope in the toolbar; below 820 pt the scope a book symbol and "
     "Return in the overflow", [("size", 720, 600)] + [("key", "ctrl+cmd+s"), ("wait", 0.6)]
     + [("key", "cmd+opt+f"), ("type", "accomplished"), ("key", "return"), ("wait", 1.5)]),
    ("main.w820", "full", "Look up 'accomplished' at 820 pt (Codex §1)",
     "Search at least 200 pt, Back and Forward and the scope in the toolbar; below 820 pt the scope a book symbol and "
     "Return in the overflow", [("size", 820, 600)]
     + [("key", "cmd+opt+f"), ("type", "accomplished"), ("key", "return"), ("wait", 1.5)]),
    ("main.w820.closed", "full", "Look up 'accomplished' at 820 pt, sidebar hidden (Codex §1)",
     "Search at least 200 pt, Back and Forward and the scope in the toolbar; below 820 pt the scope a book symbol and "
     "Return in the overflow", [("size", 820, 600)] + [("key", "ctrl+cmd+s"), ("wait", 0.6)]
     + [("key", "cmd+opt+f"), ("type", "accomplished"), ("key", "return"), ("wait", 1.5)]),
    ("main.w1000", "full", "Look up 'accomplished' at 1000 pt (Codex §1)",
     "Search at least 200 pt, Back and Forward and the scope in the toolbar; below 820 pt the scope a book symbol and "
     "Return in the overflow", [("size", 1000, 600)]
     + [("key", "cmd+opt+f"), ("type", "accomplished"), ("key", "return"), ("wait", 1.5)]),
    ("main.w1000.closed", "full", "Look up 'accomplished' at 1000 pt, sidebar hidden (Codex §1)",
     "Search at least 200 pt, Back and Forward and the scope in the toolbar; below 820 pt the scope a book symbol and "
     "Return in the overflow", [("size", 1000, 600)] + [("key", "ctrl+cmd+s"), ("wait", 0.6)]
     + [("key", "cmd+opt+f"), ("type", "accomplished"), ("key", "return"), ("wait", 1.5)]),
    ("main.narrow", "full", "Look up 'apple' at the 640 pt minimum width", "The search field and the Dictionaries "
     "picker both still in the toolbar and readable; nothing in an overflow menu that search needs",
     [NARROW] + [("key", "cmd+opt+f"), ("type", "apple"), ("key", "return"), ("wait", 1.5)]),
    ("main.noDictionaries", "empty", "Launch XDict with an empty library", "'No Dictionaries' with its sentence and an "
     "'Open Library' button", []),
    ("search.result", "full", "Type 'apple', Return", "Sidebar sections per dictionary with results and each "
     "unavailable dictionary's status (damaged, gone, locked); the entry rendered in XDict's reading style",
     look_up("apple")),
    ("search.next", "full", "Type 'apple', Return, then Down", "The results list takes the keyboard, the shown "
     "result selected (as Mail does); Down again moves on",
     look_up("apple") + [("key", "down"), ("wait", 1)]),
    ("search.suggestions", "full", "Type 'take o' without Return", "Suggestions list under the field, 'take off' "
     "among them", [SEARCH, ("type", "take o"), ("wait", 1.5)]),
    ("search.phrase", "full", "Type 'take o', Down, Return", "The phrase 'take off' looked up and shown",
     [SEARCH, ("type", "take o"), ("wait", 1.2), ("key", "down"), ("key", "return"), ("wait", 1.5)]),
    ("search.many", "full", "Type 'a', Return", "Many results; the sidebar's 'more' row where a section is cut",
     look_up("a")),
    ("search.none", "full", "Type 'zzqxjv', Return", "'No Results for “zzqxjv”' and the sidebar saying what each "
     "dictionary found", look_up("zzqxjv")),
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
    ("scope.picker", "full", "Click the Dictionaries picker in the toolbar", "A menu: All Dictionaries and each "
     "dictionary by name", [("click", "scope"), ("wait", 0.8)]),
    ("scope.narrow", "full", "At 640 pt, click the Dictionaries picker", "The menu, the picker and the search field "
     "both visible", [NARROW, ("click", "scope"), ("wait", 0.8)]),
    ("scope.one", "full", "Look up 'apple', then ⌥⌘2", "Only the second dictionary's section; the picker says so",
     look_up("apple") + [("key", "cmd+opt+2"), ("wait", 1.2)]),
    ("entry.find", "full", "Look up 'apple', ⌘F, type 'a'", "The entry's find bar with a match count",
     look_up("apple") + [("key", "cmd+f"), ("wait", 0.6), ("key", "a"), ("wait", 0.8)]),
    ("entry.zoomIn", "full", "Look up 'apple', ⌘= twice", "The entry larger, nothing clipped",
     look_up("apple") + [("key", "cmd+="), ("key", "cmd+="), ("wait", 0.8)]),
    ("entry.collapse", "full", "Look up 'apple', View ▸ Collapse All", "The entry's sections collapsed",
     look_up("apple") + [("menu", 4, "Collapse All"), ("wait", 0.8)]),
    ("speech.pronounce", "full", "Look up 'apple', ⌥⌘P", "Spoken (volume 0 here); a notice if no voice or recording",
     look_up("apple") + [("key", "cmd+opt+p"), ("wait", 1.5)]),
    # Menus
    ("menu.app", "full", "Click the XDict menu", "About XDict, Acknowledgments, Settings…, Set Up XDict…, "
     "Services, Hide, Quit", [("menuopen", 1)]),
    ("menu.file", "full", "Click File", "New Window and the app's file items", [("menuopen", 2)]),
    ("menu.edit", "full", "Click Edit", "Find in Entry… ⌘F, Find Next ⌘G, Find Previous ⇧⌘G, Pronounce ⌥⌘P",
     [("menuopen", 3)]),
    ("menu.view", "full", "Click View", "Zoom In, Zoom Out, Actual Size, Expand All, Collapse All", [("menuopen", 4)]),
    ("menu.go", "full", "Click Go", "Back ⌘[, Forward ⌘], Return to Original Word ⌥⌘[, Search ⌥⌘F",
     [("menuopen", 5)]),
    ("menu.dictionaries", "full", "Click Dictionaries", "All Dictionaries ⌥⌘0 and each dictionary ⌥⌘1…",
     [("menuopen", 6)]),
    ("menu.window", "full", "Click Window", "Library ⇧⌘L and the window list", [("menuopen", 7)]),
    ("menu.help", "full", "Click Help", "The help search field and XDict Help", [("menuopen", 8)]),
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
    ("panel.expandNarrow", "full", "Open in XDict into a 640 pt main window", "As panel.expand, at the minimum width",
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
    ("settings.dictionaries", "full", "⌘, ▸ Dictionaries", "The library inside Settings, not clipped",
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
