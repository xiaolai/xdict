"""A host app's own window in the way, told apart from XDict failing (AGENTS.md: a GUI stage names whoever took the
front, never reads a lost action as the product's failure). `hands select` names the front window when it finds no
text view and no page; that is this Mac's condition, said in a sentence with what to do. The check still fails: a host
condition never passes silently.
"""
import re

NAMES = {"textedit": "TextEdit", "notes": "Notes", "safari": "Safari", "chrome": "Chrome"}
NO_PAGE = re.compile(r'shows no text view and no page; its front window is "(.*)"$', re.S)
PICKER = "Who's using Chrome?"


def of(host, raw):
    """The sentence naming the host's condition, or None when the failure is not the host's window."""
    match = NO_PAGE.search(str(raw.get("error", "")))
    if not match:
        return None
    name, title = NAMES.get(host, host), match.group(1)
    if host == "chrome" and title == PICKER:
        return "Chrome shows its profile picker on this Mac; close it by hand"
    if not title:
        return f"{name}'s front window has no title and is not a page, on this Mac; close it by hand"
    return f"{name}'s front window is “{title}”, not a page, on this Mac; close it by hand"


def detail(host, sentence):
    """The failed check's detail: the host's condition, not XDict's."""
    return f"host condition, not XDict: {sentence}"
