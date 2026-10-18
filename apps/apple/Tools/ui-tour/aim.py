"""Where the UI tour drops a file: the centre of Settings ▸ Dictionaries' table, found in the AX tree (`ax tree`), never
the window's centre, which the notice strip or the problem box can push off the table (ADR-0012 d.7; dark-en
settings.dictionaries.dropV3Mdd, 2026-10-18). Pure, so `Tools/tests/ui_tour_test.py` holds it."""

TABLE = "settings.dictionaries"


class NoTarget(Exception):
    """The tree holds no dictionary table to aim at."""


def find(nodes, identifier, parent=None):
    """The node with `identifier` and its parent."""
    for node in nodes:
        if node.get("identifier") == identifier:
            return node, parent
        found = find(node.get("children", []), identifier, node)
        if found[0]:
            return found
    return None, None


def drop_target(tree):
    """The centre of the table's visible part in global top-left points, from `ax tree`'s output: its scroll area's
    frame when it has one (a long table is taller than what shows), else its own. NoTarget names what was looked for."""
    table, parent = find(tree.get("windows", []), TABLE)
    if table and parent and parent.get("role") == "AXScrollArea":
        table = parent
    if not table or len(table.get("frame") or []) != 4:
        raise NoTarget(f"no element with identifier {TABLE!r} and a frame in any window")
    x, y, w, h = table["frame"]
    return int(x + w / 2), int(y + h / 2)
