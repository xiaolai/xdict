#!/usr/bin/env python3
"""The lookup driver's readings of the main window (`drive.py`), with no window: what the Accessibility tree and the
frames it read must hold, as pure functions over `keys ax` nodes and `keys geometry` frames, so each is unit-tested
(`Tools/tests/lookup_checks_test.py`) apart from a run.

An expected element is written `#id:text` (an element of that identifier carrying that text) or `#id=value:text` (and
carrying that value too, as `keys` reads AXValue into an element's texts: a chosen radio button reads "1"), or bare
text (any element carrying it).
"""


def where(item, nodes):
    """The index of the first node `item` names, or None."""
    texts = [(n.get("id", ""), n.get("texts", [])) for n in nodes]
    if item.startswith("#") and ":" in item:
        ident, text = item[1:].split(":", 1)
        value = None
        if "=" in ident:
            ident, value = ident.split("=", 1)
        return next((i for i, (nid, ts) in enumerate(texts)
                     if nid == ident and text in ts and (value is None or value in ts)), None)
    return next((i for i, (_, ts) in enumerate(texts) if item in ts), None)


def judge(name, expect, nodes):
    """Holds the window, as read, to what the app said it must show."""
    missing = [p for p in expect.get("present", []) if where(p, nodes) is None]
    found = [a for a in expect.get("absent", []) if where(a, nodes) is not None]
    order = [where(o, nodes) for o in expect.get("ordered", [])]
    in_order = all(i is not None for i in order) and order == sorted(order)
    ok = bool(nodes) and not missing and not found and in_order
    detail = (f"{len(nodes)} elements; missing {missing}; present though absent {found}; order "
              f"{list(zip(expect.get('ordered', []), order))}")
    return {"name": f"ax.{name}", "pass": ok, "detail": detail}


def scope_chosen(nodes, name):
    """The scope bar shows `name` chosen (Q1, P6): the `scope.option` titled `name` has value 1 and no other has."""
    options = [n for n in nodes if n.get("id") == "scope.option"]
    chosen = [n.get("texts", []) for n in options if "1" in n.get("texts", [])]
    ok = len(chosen) == 1 and name in chosen[0]
    return ok, f"the scope bar's options, as read: {[n.get('texts') for n in options]}; chosen {chosen}"


def descendants(nodes, ident):
    """The nodes under the first node of identifier `ident`, by the walk's depth."""
    start = next((i for i, n in enumerate(nodes) if n.get("id") == ident), None)
    if start is None:
        return []
    depth = nodes[start].get("depth", 0)
    out = []
    for node in nodes[start + 1:]:
        if node.get("depth", 0) <= depth:
            break
        out.append(node)
    return out


def results_read(nodes, rows, sections):
    """VoiceOver's reading of the results (R10, R11, P9-P11, P15): the merged `results` table reads `rows` (the app's
    first headwords) in order; and the All page names each dictionary that found the word, after the first, by its
    divider (`page.divider.<name>`, a disclosure triangle labelled with the name). `sections` is the app's
    [(name, status)] in the reader's order."""
    texts = [t for n in descendants(nodes, "results") for t in n.get("texts", [])]
    at = [texts.index(r) if r in texts else None for r in rows]
    in_order = bool(rows) and all(i is not None for i in at) and at == sorted(at)
    found = [name for name, status in sections if status == "results"]
    wanted = found[1:]
    dividers = {n.get("id", "")[len("page.divider."):]: n for n in nodes
                if n.get("id", "").startswith("page.divider.")}
    named = [d for d in wanted if d in dividers and d in dividers[d].get("texts", [])]
    roles = sorted({dividers[d].get("role", "") for d in named})
    ok = in_order and len(found) >= 2 and named == wanted and "AXUnknown" not in roles and "" not in roles
    return ok, (f"rows {rows} read at {at} of the table's texts {texts[:8]}; dictionaries with results {found}, "
                f"dividers expected {wanted}, read {sorted(dividers)} as {roles}")


def entry_placement(geometry):
    """Where the entry starts (P6): right under the scope bar, or under the page's notices while they are shown, within
    1 pt; never under the toolbar alone, since the 36 pt scope bar sits between. None when a frame is missing, with
    the reason."""
    bar, notices, web = geometry.get("scopeBar"), geometry.get("notices"), geometry.get("web")
    if not bar or not web:
        return None, f"no scope bar or no entry to measure: {geometry}"
    above = max([bar["y"] + bar["height"]] + ([notices["y"] + notices["height"]] if notices else []))
    band = web["y"] - above
    under = "the page's notices" if notices and notices["y"] + notices["height"] == above else "the scope bar"
    return abs(band) <= 1, f"the entry starts {band:g} pt below {under}'s bottom"
