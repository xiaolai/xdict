"""Writes core/xdict-entry/src/entities.rs from WHATWG's entities.json (argv[1]) to argv[2].

    curl -fsSo /tmp/entities/entities.json https://html.spec.whatwg.org/entities.json
    python3 -I core/xdict-entry/gen_entities.py /tmp/entities/entities.json core/xdict-entry/src/entities.rs
"""
import json
import sys

table = json.load(open(sys.argv[1], encoding="utf-8"))
rows = []
for key, value in table.items():
    assert key.startswith("&")
    name = key[1:]
    assert name.rstrip(";").isascii() and name.rstrip(";").isalnum(), key
    text = "".join(chr(c) for c in value["codepoints"])
    assert text == value["characters"], key
    rows.append((name, value["codepoints"]))
rows.sort(key=lambda r: r[0].encode())
longest = max(len(n.rstrip(";")) for n, _ in rows)
legacy = max(len(n) for n, _ in rows if not n.endswith(";"))

# HTML's numeric character reference end state replaces C1 code points by their windows-1252 characters; the
# five windows-1252 leaves undefined (0x81, 0x8D, 0x8F, 0x90, 0x9D) stay as they are.
c1 = []
for b in range(0x80, 0xA0):
    try:
        c1.append((b, ord(bytes([b]).decode("cp1252"))))
    except UnicodeDecodeError:
        pass
assert len(c1) == 27, len(c1)


def lit(codepoints):
    return '"' + "".join(f"\\u{{{c:x}}}" for c in codepoints) + '"'


out = [
    "//! HTML's named character references, every one of the standard's table (WHATWG HTML, \"Named character",
    "//! references\", <https://html.spec.whatwg.org/entities.json>, CC BY 4.0), sorted by name for a binary search, and",
    "//! the windows-1252 characters its numeric references stand for in place of C1 controls. Written by a script",
    "//! from that file by `gen_entities.py`; a name keeps its `;`, and the 106 read without one appear twice.",
    "",
    f"/// The longest name, without its `;`: no reference is searched for past it.",
    f"pub(crate) const LONGEST: usize = {longest};",
    "",
    f"/// The longest name a browser reads without a `;`.",
    f"pub(crate) const LONGEST_LEGACY: usize = {legacy};",
    "",
    f"static NAMED: [(&str, &str); {len(rows)}] = [",
]
for name, cps in rows:
    out.append(f'    ("{name}", {lit(cps)}),')
out += [
    "];",
    "",
    f"static C1: [(u32, char); {len(c1)}] = [",
]
for b, c in c1:
    out.append(f"    (0x{b:x}, '\\u{{{c:x}}}'),")
out += [
    "];",
    "",
    "/// The text of the reference named `name` (with its `;`, if it has one).",
    "pub(crate) fn named(name: &str) -> Option<&'static str> {",
    "    NAMED.binary_search_by(|(n, _)| n.cmp(&name)).ok().and_then(|i| NAMED.get(i)).map(|&(_, text)| text)",
    "}",
    "",
    "/// The character a numeric reference to the C1 control `code` stands for, where HTML gives one.",
    "pub(crate) fn c1(code: u32) -> Option<char> {",
    "    C1.iter().find(|&&(c, _)| c == code).map(|&(_, to)| to)",
    "}",
    "",
    "#[cfg(test)]",
    "mod tests {",
    "    use super::*;",
    "",
    "    /// A binary search misses quietly in a table out of order; and a name read without `;` is one with it.",
    "    #[test]",
    "    fn the_table_is_sorted_and_every_legacy_name_has_its_semicolon_form() {",
    "        assert!(NAMED.windows(2).all(|w| matches!(w, [a, b] if a.0 < b.0)));",
    "        for (name, text) in NAMED.iter().filter(|(n, _)| !n.ends_with(';')) {",
    "            assert_eq!(named(&format!(\"{name};\")), Some(*text), \"{name}\");",
    "            assert!(name.len() <= LONGEST_LEGACY);",
    "        }",
    "        assert!(NAMED.iter().all(|(n, _)| n.trim_end_matches(';').len() <= LONGEST));",
    "    }",
    "}",
    "",
]
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(out))
print(len(rows), "names; longest", longest, "; legacy longest", legacy)
