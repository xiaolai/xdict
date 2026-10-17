#!/usr/bin/env python3
"""Pseudo-localization for the UI tour's `pseudo` variant (owner's i18n round, 2026-10-17): every English value of the
string catalog made longer and accented, format directives kept, so a label that clips or wraps in a longer language
shows in a capture before a translator meets it. **A tour instrument, never shipped**: the tour compiles it into a copy
of the installed app on the E2E Mac (tour.py, `pseudo_app`), never into XDict.app.

    python3 -I pseudo.py <Localizable.xcstrings> <out.xcstrings>

"Look Up" becomes "⟦Ļôôķ Ûþ··⟧": about 40% longer (German and Finnish run 30-40% past English), every letter still
readable, the brackets showing where a string was cut.
"""
import json
import re
import sys

ACCENTED = dict(zip(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ",
    "åƀçđéƒĝĥîĵķļɱñöþǫŕšţûṽŵẋýžÅƁÇĐÉƑĜĤÎĴĶĻṀÑÖÞǪŔŠŢÛṼŴẊÝŽ"))
# A format directive (`%@`, `%lld`, `%1$@`, `%2$#@n@`, `%%`) or a stringsdict argument (`%arg`): kept as written.
DIRECTIVE = re.compile(r"%(?:arg|%|\d+\$)?(?:#@\w+@|ll[du]|l?[du]|@|f|u)?")
EXPANSION = 0.4


def pseudo(text):
    """`text` accented and padded, its directives untouched."""
    out, visible, at = [], 0, 0
    for match in DIRECTIVE.finditer(text):
        plain = text[at:match.start()]
        out.append("".join(ACCENTED.get(c, c) for c in plain))
        visible += len(plain)
        out.append(match.group(0))
        at = match.end()
    plain = text[at:]
    out.append("".join(ACCENTED.get(c, c) for c in plain))
    visible += len(plain)
    return "⟦" + "".join(out) + "·" * max(1, round(visible * EXPANSION)) + "⟧"


def localize(localization):
    """An English localization with every value made pseudo: its unit, its plural forms, its substitutions'."""
    def walk(node):
        if isinstance(node, dict):
            if "stringUnit" in node:
                unit = dict(node["stringUnit"], value=pseudo(node["stringUnit"]["value"]))
                node = dict(node, stringUnit=unit)
            return {k: (walk(v) if k != "stringUnit" else v) for k, v in node.items()}
        return node
    return walk(localization)


def build(catalog):
    """The catalog with only an English that is pseudo: what the tour compiles in place of the app's English."""
    strings = {}
    for key, entry in catalog["strings"].items():
        english = entry.get("localizations", {}).get("en") or {"stringUnit": {"state": "translated", "value": key}}
        strings[key] = {"localizations": {"en": localize(english)}}
    return {"sourceLanguage": "en", "strings": strings, "version": catalog.get("version", "1.0")}


def main():
    source, target = sys.argv[1:3]
    with open(source, encoding="utf-8") as f:
        catalog = json.load(f)
    with open(target, "w", encoding="utf-8") as f:
        json.dump(build(catalog), f, ensure_ascii=False, indent=2)


if __name__ == "__main__":
    main()
