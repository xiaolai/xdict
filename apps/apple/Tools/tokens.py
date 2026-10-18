#!/usr/bin/env python3
"""XDict's design tokens for the macOS shell: generate them, find them, add them, and find what bypasses them.

    python3 -I Tools/tokens.py gen [--check]       write (or, --check: compare) the generated files
    python3 -I Tools/tokens.py list [group]        every token, or one group's, with its provenance
    python3 -I Tools/tokens.py find <value|name>   the token with this value (or the nearest in each group), or by name
    python3 -I Tools/tokens.py add <group.name> [value] (--source P.. | --why "..." | --system ...)
    python3 -I Tools/tokens.py check [--report]    find literals that should be tokens; exit 1 on any (0 with --report)

`--root <dir>` (before the command) runs against another copy of apps/apple; the tests use it.

**The source** is `Tokens/tokens.toml` (its header says the format). Every token carries `source` (a parity id of
`Tools/parity/apple-dictionary.tsv`: Apple measured it), `system` (the platform's text style or semantic colour) or
`why` (a sentence); one without is refused, as is an unknown key, group or parity id.

**What is generated**, byte for byte from the source and its SHA-256:
  Sources/XDictTokens/Tokens.swift            `public enum Tokens { enum Space { static let m: CGFloat = 12 } ... }`
  Sources/XDictEntryView/Style/tokens.css     the reading style's `--xdict-*` on :root (injected by EntryReadingFrame)
  Sources/XDictEntryView/Style/palette.css    the palette per theme and the accent per hue
  Sources/XDictEntryView/Style/density.css    R7a's space by role, main window and lookup panel
A `css-fill` token is written into a stylesheet's `{{fill-<name>}}` when the sheet is installed (`EntryStyle.css`), for
the places `var()` cannot reach: a media query. `gen --check` and `check` both run in `make test-tools`: a stale or
hand-edited output, or a literal anywhere `check` looks, fails it. `TokensFreshnessTests` holds the digest too.

**What `check` looks for** (Swift under Sources/, CSS under Style/), and what it allows:
  Swift: numeric literals in `.padding(`, `spacing:`, `Spacer(minLength:`, `.frame(`, `.offset(`, `cornerRadius`,
  `.lineSpacing(`, `.opacity(`, `NSEdgeInsets(`/`EdgeInsets(`, `NSSize(`/`CGSize(`/`NSRect(`/`CGRect(`; font sizes
  (`.system(size:`, `systemFont(ofSize:` and its kin, `NSFont(name:size:`); every colour built from components
  (`Color(red:/white:/hue:`, `NSColor(red:/white:/calibrated…/srgb…/device…/displayP3…`), one finding per call; and
  `let`/`var` of a `CGFloat` type given a literal; and a tolerance compared bare with a distance (`hypot(`, `distance`,
  `dx`/`dy`, `.minX`... `.width`, `.x`/`.y` on the other side of `<`, `<=`, `>`, `>=`), written as a literal or as a
  constant whose type is inferred (`static let horizontal = 3`, reported at its declaration): capture's shape
  (ADR-0014 decision 11). A ratio (the other side divides) is not a distance.
  CSS: lengths (px pt rem em lh vw vh ch ex) and colours (#hex, rgb(), hsl()) outside tokens.css and outside the
  fallback of a `var(`.
  ALLOWED, and nothing else:
    - 0 in a length position (any of the Swift positions above, or a CSS length): it means none.
    - 1 as an opacity (`.opacity(1)`): it means unchanged. Every other 1 (a hairline, a 1 pt rect) is a length.
    - a literal right after `*` or `/`: a factor or ratio (`/ 2`, `/ 255`), not a length.
    - anything in Sources/XDictTokens (the tokens themselves) and in generated files (EntryStyleFiles.swift).
    - a line ending in `// token-exempt: <reason>` (CSS: `/* token-exempt: <reason> */`): counted and listed by
      `check`; an exemption with no reason is itself a finding.
  Not seen: CSS and numbers inside Swift string literals (the reading style's own Swift-side CSS), and JavaScript.
"""
import argparse
import hashlib
import json
import math
import os
import re
import subprocess
import sys
import tomllib

HERE = os.path.dirname(os.path.abspath(__file__))
APPLE = os.path.normpath(os.path.join(HERE, ".."))

TOML = "Tokens/tokens.toml"
PARITY = "Tools/parity/apple-dictionary.tsv"
SWIFT_OUT = "Sources/XDictTokens/Tokens.swift"
CSS_OUT = "Sources/XDictEntryView/Style/tokens.css"
STYLE_DIR = "Sources/XDictEntryView/Style"
SKIP_DIRS = ("Sources/XDictTokens",)
SKIP_FILES = ("Sources/XDictEntryView/EntryStyleFiles.swift",)

KINDS = {"length", "size", "rect", "string", "font", "colour", "css", "css-palette", "css-accent", "css-density",
         "css-fill"}
# Kinds that become a Swift enum of the group's own name. The CSS kinds become `Tokens.ReadingStyle` (their data, for
# the shell's checks and the palette it writes) and CSS files; `css-fill` becomes `Tokens.ReadingStyle.fills`, the
# values of the `{{fill-<name>}}` placeholders a stylesheet uses where `var()` cannot go (a media query).
SWIFT_KINDS = {"length", "size", "rect", "string", "font", "colour"}
PALETTE_OUT = "Sources/XDictEntryView/Style/palette.css"
DENSITY_OUT = "Sources/XDictEntryView/Style/density.css"
TEXT_STYLES = ["largeTitle", "title", "title2", "title3", "headline", "subheadline", "body", "callout", "footnote",
               "caption", "caption2"]
WEIGHTS = ["ultraLight", "thin", "light", "regular", "medium", "semibold", "bold", "heavy", "black"]
DESIGNS = ["default", "serif", "rounded", "monospaced"]
# The semantic colours of NSColor a token may name (AppKit's own, which follow appearance, contrast and accent).
SYSTEM_COLOURS = ["labelColor", "secondaryLabelColor", "tertiaryLabelColor", "quaternaryLabelColor", "linkColor",
                  "placeholderTextColor", "separatorColor", "selectedContentBackgroundColor",
                  "unemphasizedSelectedContentBackgroundColor", "controlAccentColor", "controlColor",
                  "controlBackgroundColor", "controlTextColor", "disabledControlTextColor", "textColor",
                  "textBackgroundColor", "selectedTextColor", "selectedTextBackgroundColor", "windowBackgroundColor",
                  "underPageBackgroundColor", "gridColor", "headerTextColor", "findHighlightColor", "systemRed",
                  "systemOrange", "systemYellow", "systemGreen", "systemMint", "systemTeal", "systemCyan",
                  "systemBlue", "systemIndigo", "systemPurple", "systemPink", "systemBrown", "systemGray"]
SWIFT_KEYWORDS = {"default", "class", "struct", "enum", "func", "let", "var", "if", "else", "for", "in", "return",
                  "self", "Self", "Type", "init", "case", "switch", "where", "while", "repeat", "import", "protocol",
                  "extension", "static", "public", "private", "internal", "operator", "is", "as", "nil", "true",
                  "false", "super", "throw", "throws", "try", "catch", "do", "guard", "defer", "break", "continue"}
HEX6 = re.compile(r"^#[0-9a-f]{6}$")
CSS_HEX = re.compile(r"^#[0-9a-f]{6}$|^transparent$")
PARITY_ID = re.compile(r"^P[0-9]+$")
SWIFT_NAME = re.compile(r"^[a-z][A-Za-z0-9]*$")
CSS_NAME = re.compile(r"^[a-z][a-z0-9-]*$")
CSS_BASE_PX = 16  # rem and em are compared with px at the reading style's `--xdict-base` (find only).


class Refused(Exception):
    pass


# MARK: - The source

class Token:
    def __init__(self, group, name, kind, fields, line):
        self.group, self.name, self.kind, self.fields, self.line = group, name, kind, fields, line

    @property
    def provenance(self):
        f = self.fields
        if "source" in f:
            return "source " + f["source"] + " (Apple-measured, fixed)"
        if "system" in f:
            return "system " + f["system"]
        return "why: " + f.get("why", "")

    def display(self):
        f, k = self.fields, self.kind
        if k == "length":
            return num(f["value"])
        if k == "size":
            return num(f["width"]) + "x" + num(f["height"])
        if k == "rect":
            return f"{num(f['x'])},{num(f['y'])} {num(f['width'])}x{num(f['height'])}"
        if k in ("string", "css-fill"):
            return f["value"]
        if k == "css-density":
            return f["main"] + (" / panel " + f["panel"] if "panel" in f else "")
        if k == "font":
            if "system" in f:
                return "." + f["system"]
            parts = [num(f["size"]) + " pt", f.get("weight", "regular")]
            if f.get("design", "default") != "default":
                parts.append(f["design"])
            if f.get("italic"):
                parts.append("italic")
            return " ".join(parts)
        if k == "colour":
            return f["system"] if "system" in f else f["light"] + " / " + f["dark"]
        if k == "css":
            return f["value"]
        return f["light"] + " / " + f["dark"]

    def numbers(self):
        """The numeric values `find` compares, as points (CSS lengths at the base size)."""
        f, k = self.fields, self.kind
        if k == "length":
            return [f["value"]]
        if k == "size":
            return [f["width"], f["height"]]
        if k == "rect":
            return [f["x"], f["y"], f["width"], f["height"]]
        if k == "font" and "size" in f:
            return [f["size"]]
        if k in ("css", "css-fill"):
            px = css_px(f["value"])
            return [px] if px is not None else []
        if k == "css-density":
            return [p for p in (css_px(f["main"]), css_px(f.get("panel", ""))) if p is not None]
        return []

    @property
    def css_text(self):
        """The literal as written in CSS, which `find` also matches exactly (`0.25em` is not `0.25rem`)."""
        f = self.fields
        return [v for v in (f.get("value"), f.get("main"), f.get("panel"), f.get("light"), f.get("dark"))
                if isinstance(v, str)]


def num(v):
    return str(int(v)) if float(v).is_integer() else repr(float(v))


def css_px(text):
    m = re.fullmatch(r"(-?\d*\.?\d+)(px|rem|em)", text.strip())
    if not m:
        return None
    v = float(m.group(1))
    return v if m.group(2) == "px" else v * CSS_BASE_PX


def parity_ids(root):
    path = os.path.join(root, PARITY)
    with open(path, encoding="utf-8") as f:
        return {line.split("\t", 1)[0] for line in f if PARITY_ID.match(line.split("\t", 1)[0])}


def is_number(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def validate(data, ids, lines):
    """Every problem with the source, as sentences; the tokens if there are none."""
    problems, tokens = [], []
    groups = data.get("groups")
    if not isinstance(groups, dict) or not groups:
        return ["tokens.toml has no [groups] table"], []
    for g, spec in groups.items():
        if not isinstance(spec, dict) or spec.get("kind") not in KINDS:
            problems.append(f"group {g}: kind must be one of {sorted(KINDS)}")
            continue
        unknown = set(spec) - {"kind", "swift", "doc"}
        if unknown:
            problems.append(f"group {g}: unknown keys {sorted(unknown)}")
        if spec["kind"] in SWIFT_KINDS and not re.fullmatch(r"[A-Z][A-Za-z0-9]*", str(spec.get("swift", ""))):
            problems.append(f"group {g}: a Swift group needs `swift`, the enum's name")
        if not str(spec.get("doc", "")).strip():
            problems.append(f"group {g}: needs `doc`, a line on what it is for")
    for table in data:
        if table != "groups" and table not in groups:
            problems.append(f"[{table}] is not a declared group (add it to [groups])")
    for g, spec in groups.items():
        if not isinstance(spec, dict) or spec.get("kind") not in KINDS:
            continue
        kind = spec["kind"]
        for name, f in (data.get(g) or {}).items():
            where = f"{g}.{name}"
            line = lines.get((g, name), 0)
            if not isinstance(f, dict):
                problems.append(f"{where}: must be an inline table {{ ... }}")
                continue
            namere = CSS_NAME if kind.startswith("css") else SWIFT_NAME
            if not namere.match(name) or name in SWIFT_KEYWORDS:
                problems.append(f"{where}: the name must match {namere.pattern} and not be a Swift keyword")
            problems += [where + ": " + p for p in check_fields(kind, f, ids)]
            tokens.append(Token(g, name, kind, f, line))
    return problems, tokens


def check_fields(kind, f, ids):
    out = []
    prov = [k for k in ("source", "why", "system") if k in f]
    if not prov:
        out.append("no provenance: give `source` (a parity id), `why` (a sentence) or `system`")
    if "source" in f:
        if not PARITY_ID.match(str(f["source"])):
            out.append(f"source {f['source']!r} is not a parity id (P<n>)")
        elif f["source"] not in ids:
            out.append(f"source {f['source']} is not in {PARITY}")
    if "why" in f and len(str(f["why"]).strip()) < 10:
        out.append("`why` must say why in a sentence")
    allowed = {"source", "why"}
    if kind == "length":
        allowed |= {"value"}
        if not is_number(f.get("value")) or f.get("value") < 0:
            out.append("`value` must be a number of points, 0 or more")
    elif kind == "size":
        allowed |= {"width", "height"}
        if not all(is_number(f.get(k)) and f.get(k) >= 0 for k in ("width", "height")):
            out.append("`width` and `height` must be numbers of points")
    elif kind == "rect":
        allowed |= {"x", "y", "width", "height"}
        if not all(is_number(f.get(k)) for k in ("x", "y", "width", "height")):
            out.append("`x`, `y`, `width` and `height` must be numbers of points")
    elif kind in ("string", "css-fill"):
        allowed |= {"value"}
        if not isinstance(f.get("value"), str) or not f["value"].strip() or re.search(r'[\\"\n]', f["value"]):
            out.append("`value` must be a string with no backslash, double quote or newline")
    elif kind == "css-density":
        allowed |= {"main", "panel"}
        if not all(isinstance(f.get(k, "x"), str) and re.fullmatch(r"-?\d*\.?\d+(em|rem|px)", f.get(k, "0em"))
                   for k in ("main", "panel")) or "main" not in f:
            out.append("`main` (and `panel`, if the lookup panel's differs) must be CSS lengths")
    elif kind == "font":
        allowed |= {"system", "size", "weight", "design", "italic"}
        if "system" in f:
            if f["system"] not in TEXT_STYLES:
                out.append(f"system text style must be one of {TEXT_STYLES}")
            if set(f) & {"size", "design"}:
                out.append("a system text style takes no `size` or `design`")
        elif not is_number(f.get("size")) or f["size"] <= 0:
            out.append("`size` must be a number of points (or give `system`, a text style)")
        if f.get("weight", "regular") not in WEIGHTS:
            out.append(f"weight must be one of {WEIGHTS}")
        if f.get("design", "default") not in DESIGNS:
            out.append(f"design must be one of {DESIGNS}")
        if not isinstance(f.get("italic", False), bool):
            out.append("italic must be true or false")
    elif kind == "colour":
        allowed |= {"system", "light", "dark"}
        if "system" in f:
            if f["system"] not in SYSTEM_COLOURS:
                out.append(f"system colour {f['system']!r} is not one of NSColor's semantic colours")
            if set(f) & {"light", "dark"}:
                out.append("a system colour takes no `light` or `dark`")
        elif not all(HEX6.match(str(f.get(k, ""))) for k in ("light", "dark")):
            out.append("`light` and `dark` must be #rrggbb (lowercase), or give `system`")
    elif kind == "css":
        allowed |= {"value"}
        if not isinstance(f.get("value"), str) or not f["value"].strip() or re.search(r"[;{}\n]", f["value"]):
            out.append("`value` must be a CSS value: a string, with no ; { } or newline")
    else:
        allowed |= {"light", "dark"}
        if not all(CSS_HEX.match(str(f.get(k, ""))) for k in ("light", "dark")):
            out.append("`light` and `dark` must be #rrggbb (lowercase) or transparent")
    if kind not in ("font", "colour") and "system" in f:
        out.append("`system` is for text styles and colours only")
    unknown = set(f) - allowed
    if unknown:
        out.append(f"unknown keys {sorted(unknown)}")
    return out


def token_lines(text):
    """(group, name) -> line number in tokens.toml, for messages."""
    out, group = {}, None
    for i, line in enumerate(text.split("\n"), 1):
        m = re.match(r"^\[([A-Za-z0-9_-]+)\]\s*$", line)
        if m:
            group = m.group(1)
            continue
        m = re.match(r"^([A-Za-z0-9_-]+)\s*=", line)
        if m and group:
            out[(group, m.group(1))] = i
    return out


def load(root, text=None):
    if text is None:
        with open(os.path.join(root, TOML), encoding="utf-8") as f:
            text = f.read()
    try:
        data = tomllib.loads(text)
    except tomllib.TOMLDecodeError as e:
        raise Refused(f"tokens.toml does not parse: {e}")
    problems, tokens = validate(data, parity_ids(root), token_lines(text))
    if problems:
        raise Refused("tokens.toml refused:\n  " + "\n  ".join(problems))
    return data, tokens, text


# MARK: - gen

def swift_doc(t):
    f = t.fields
    if "source" in f:
        return f"Apple-measured ({f['source']}, `Tools/parity/apple-dictionary.tsv`): fixed."
    if "system" in f:
        return f"The system's own: `{f['system']}`."
    return f["why"]


def render_swift(data, tokens, digest):
    out = [
        "// Generated by Tools/tokens.py from Tokens/tokens.toml. Do not edit: edit tokens.toml (or run",
        "// `Tools/tokens.py add`), then `Tools/tokens.py gen`.",
        "import AppKit",
        "import SwiftUI",
        "",
        "/// **XDict's design tokens for the macOS shell**: every length, size, text role and colour the shell draws with,",
        "/// each with its provenance (Apple-measured, the system's, or a reason). `Tools/tokens.py find <value>` says which",
        "/// token a value is; `Tools/tokens.py check` finds what bypasses them.",
        "public enum Tokens {",
        "    /// SHA-256 of the tokens.toml this file was made from: `TokensFreshnessTests` holds it to the file.",
        f'    public static let sourceDigest = "{digest}"',
    ]
    for g, spec in data["groups"].items():
        if spec["kind"] not in SWIFT_KINDS:
            continue
        out += ["", f"    /// {spec['doc']}", f"    public enum {spec['swift']} {{"]
        for t in [t for t in tokens if t.group == g]:
            f = t.fields
            out.append(f"        /// {swift_doc(t)}")
            if t.kind == "length":
                out.append(f"        public static let {t.name}: CGFloat = {num(f['value'])}")
            elif t.kind == "size":
                out.append(f"        public static let {t.name} = CGSize(width: {num(f['width'])}, "
                           f"height: {num(f['height'])})")
            elif t.kind == "rect":
                out.append(f"        public static let {t.name} = CGRect(x: {num(f['x'])}, y: {num(f['y'])}, "
                           f"width: {num(f['width'])}, height: {num(f['height'])})")
            elif t.kind == "string":
                out.append(f'        public static let {t.name} = "{f["value"]}"')
            elif t.kind == "font":
                if "system" in f:
                    weight = f", weight: .{f['weight']}" if "weight" in f else ""
                    out.append(f"        public static let {t.name} = TokenFont(style: .{f['system']}{weight})")
                else:
                    out.append(f"        public static let {t.name} = TokenFont(size: {num(f['size'])}, "
                               f"weight: .{f.get('weight', 'regular')}, design: .{f.get('design', 'default')}, "
                               f"italic: {'true' if f.get('italic') else 'false'})")
            else:
                if "system" in f:
                    out.append(f"        public static var {t.name}: TokenColour {{ TokenColour(.{f['system']}) }}")
                else:
                    out.append(f"        public static var {t.name}: TokenColour {{ TokenColour(light: "
                               f"0x{f['light'][1:]}, dark: 0x{f['dark'][1:]}) }}")
        out.append("    }")
    out += render_reading_style(tokens)
    out += ["}", ""]
    return "\n".join(out)


def camel(css_name):
    head, *rest = css_name.split("-")
    return head + "".join(p[:1].upper() + p[1:] for p in rest)


def swift_string(s):
    return json.dumps(s, ensure_ascii=False)


def render_reading_style(tokens):
    """The reading style's tokens as Swift data: what the shell checks colours against and writes into a sheet."""
    def by(kind):
        return [t for t in tokens if t.kind == kind]
    out = ["", "    /// The reading style's tokens as data (the CSS is `tokens.css`, `palette.css` and `density.css`).",
           "    public enum ReadingStyle {",
           "        /// Every `--xdict-<name>` on `:root`, in order.",
           "        public static let root: [(String, String)] = ["]
    out += [f"            ({swift_string(t.name)}, {swift_string(t.fields['value'])})," for t in by("css")]
    out += ["        ]", "        /// The palette: name, light, dark.",
            "        public static let palette: [(String, String, String)] = ["]
    out += [f"            ({swift_string(t.name)}, {swift_string(t.fields['light'])}, {swift_string(t.fields['dark'])}),"
            for t in by("css-palette")]
    out += ["        ]", "        /// The accent hues, light and dark."]
    out += [f"        public static let accent{camel(t.name)[:1].upper() + camel(t.name)[1:]} = "
            f"(light: {swift_string(t.fields['light'])}, dark: {swift_string(t.fields['dark'])})" for t in by("css-accent")]
    out += ["        /// The values of the `{{fill-<name>}}` placeholders, for what `var()` cannot reach (a media query).",
            "        public static let fills: [String: String] = ["]
    out += [f"            {swift_string('fill-' + t.name)}: {swift_string(t.fields['value'])}," for t in by("css-fill")]
    if not by("css-fill"):
        out[-1] = "        public static let fills: [String: String] = [:"
    out += ["        ]", "    }"]
    return out


def css_header(digest):
    return f"/* Generated by Tools/tokens.py from Tokens/tokens.toml (sha256 {digest}). Do not edit. */"


def render_css(tokens, digest):
    """`:root`'s tokens: one declaration a line, which `EntryStyle.css` joins into `:root{--xdict-a:b;...}`."""
    out = [css_header(digest), ":root{"]
    out += [f"--xdict-{t.name}:{t.fields['value']};" for t in tokens if t.kind == "css"]
    out += ["}", ""]
    return "\n".join(out)


def render_palette(tokens, digest):
    """The palette per theme, then each accent hue per theme (no `;` after the one declaration: as written before)."""
    out = [css_header(digest)]
    for theme in ("light", "dark"):
        out.append(f":root[data-xdict-theme={theme}]{{")
        out += [f"--xdict-{t.name}:{t.fields[theme]};" for t in tokens if t.kind == "css-palette"]
        out.append("}")
    for t in [t for t in tokens if t.kind == "css-accent"]:
        for theme in ("light", "dark"):
            out += [f":root[data-xdict-theme={theme}][data-xdict-hue={t.name}]{{", f"--xdict-accent:{t.fields[theme]}",
                    "}"]
    out.append("")
    return "\n".join(out)


def render_density(tokens, digest):
    """R7a's space by role: the main window's on `:root`, the lookup panel's where it differs."""
    dens = [t for t in tokens if t.kind == "css-density"]
    out = [css_header(digest), ":root{"]
    out += [f"--xdict-{t.name}:{t.fields['main']};" for t in dens]
    out += ["}", ":root[data-xdict-density=panel]{"]
    out += [f"--xdict-{t.name}:{t.fields['panel']};" for t in dens if "panel" in t.fields]
    out += ["}", ""]
    return "\n".join(out)


def generated(root):
    data, tokens, text = load(root)
    digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
    return {SWIFT_OUT: render_swift(data, tokens, digest), CSS_OUT: render_css(tokens, digest),
            PALETTE_OUT: render_palette(tokens, digest), DENSITY_OUT: render_density(tokens, digest)}


def cmd_gen(root, check=False):
    stale = []
    for rel, text in generated(root).items():
        path = os.path.join(root, rel)
        current = open(path, encoding="utf-8").read() if os.path.exists(path) else None
        if current == text:
            continue
        if check:
            stale.append(rel)
            continue
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        print("tokens: wrote " + rel)
    if stale:
        print("tokens: stale versus tokens.toml: " + ", ".join(stale) + "; run Tools/tokens.py gen", file=sys.stderr)
        return 1
    if check:
        print("tokens: generated files are fresh")
        return 0
    # A new or changed CSS file reaches the binary only through the reading style's generator.
    gen_style = os.path.join(root, "Tools", "reading-style-gen.py")
    if os.path.exists(gen_style):
        subprocess.run([sys.executable, "-I", gen_style], check=True)
    return 0


# MARK: - list and find

def swift_path(t, data):
    spec = data["groups"][t.group]
    if t.kind in SWIFT_KINDS:
        return f"Tokens.{spec['swift']}.{t.name}"
    if t.kind == "css-accent":
        return f"--xdict-accent (hue {t.name})"
    if t.kind == "css-fill":
        return "{{fill-" + t.name + "}}"
    return f"var(--xdict-{t.name})"


def line_of(t, data):
    return f"{swift_path(t, data)} = {t.display()}    [{t.provenance}]"


def cmd_list(root, group=None):
    data, tokens, _ = load(root)
    if group and group not in data["groups"]:
        raise Refused(f"no group {group}; groups: {', '.join(data['groups'])}")
    for g in data["groups"]:
        if group and g != group:
            continue
        print(f"[{g}] {data['groups'][g]['doc']}")
        for t in [t for t in tokens if t.group == g]:
            print("  " + line_of(t, data))


def parse_query_number(q):
    q = q.strip()
    try:
        return float(q.replace("_", ""))
    except ValueError:
        return css_px(q)


def find(data, tokens, query, groups=None):
    """Lines answering `query`: exact matches, else the nearest token below and above in each group; or by name."""
    value = parse_query_number(query)
    pool = [t for t in tokens if groups is None or t.group in groups]
    if value is None:
        q = query.lower().lstrip("-").removeprefix("xdict-")
        q = q.removeprefix("--xdict-")
        hits = [t for t in pool if q in f"{t.group}.{t.name}".lower() or q in swift_path(t, data).lower()]
        if not hits and query.startswith("#"):
            hits = [t for t in pool if query.lower() in t.display().lower()]
        return [line_of(t, data) for t in hits]
    if re.fullmatch(r"-?\d*\.?\d+[a-z%]+", query.strip()):
        # A CSS literal: the token written so, since 0.25em and 0.25rem are not the same length.
        exact = [t for t in pool if query.strip() in t.css_text]
    else:
        exact = [t for t in pool if any(abs(n - value) < 1e-9 for n in t.numbers())]
    if exact:
        return [line_of(t, data) for t in exact]
    out = []
    for g in data["groups"]:
        nums = [(n, t) for t in pool if t.group == g for n in t.numbers()]
        if not nums:
            continue
        below = max((p for p in nums if p[0] < value), default=None, key=lambda p: p[0])
        above = min((p for p in nums if p[0] > value), default=None, key=lambda p: p[0])
        near = [p for p in (below, above) if p]
        out.append(f"[{g}] no {num(value)}; nearest: " + ", ".join(
            f"{swift_path(t, data)} = {num(n)}" for n, t in near))
    return out


def cmd_find(root, query):
    data, tokens, _ = load(root)
    lines = find(data, tokens, query)
    if not lines:
        print(f"tokens: nothing matches {query!r}")
        return 1
    print("\n".join(lines))
    return 0


# MARK: - add

def toml_string(s):
    return json.dumps(s, ensure_ascii=False)


def parse_add_value(kind, raw):
    """The fields a value on the command line stands for, by the group's kind."""
    if raw is None:
        return {}
    if kind == "length":
        return {"value": number(raw)}
    if kind == "size":
        w, _, h = raw.partition("x")
        return {"width": number(w), "height": number(h)}
    if kind == "font":
        parts = raw.split(":")
        f = {"size": number(parts[0])}
        for p in parts[1:]:
            if p == "italic":
                f["italic"] = True
            elif p in WEIGHTS:
                f["weight"] = p
            elif p in DESIGNS:
                f["design"] = p
            else:
                raise Refused(f"font value part {p!r}: a weight, a design or italic (e.g. 13:semibold:serif)")
        return f
    if kind == "css":
        return {"value": raw}
    light, sep, dark = raw.partition("/")
    if not sep:
        raise Refused("a colour value is light/dark, e.g. #929292/#5c5c5c (or give --system)")
    return {"light": light.strip().lower(), "dark": dark.strip().lower()}


def number(raw):
    try:
        v = float(raw)
    except ValueError:
        raise Refused(f"{raw!r} is not a number")
    return int(v) if v.is_integer() else v


def inline_table(fields):
    parts = []
    for k, v in fields.items():
        if isinstance(v, bool):
            parts.append(f"{k} = {'true' if v else 'false'}")
        elif isinstance(v, (int, float)):
            parts.append(f"{k} = {num(v)}")
        else:
            parts.append(f"{k} = {toml_string(v)}")
    return "{ " + ", ".join(parts) + " }"


def cmd_add(root, dotted, raw, source=None, why=None, system=None):
    data, tokens, text = load(root)
    group, _, name = dotted.partition(".")
    if group not in data["groups"] or not name:
        raise Refused(f"{dotted!r}: give <group>.<name> with a group of {', '.join(data['groups'])}")
    if any(t.group == group and t.name == name for t in tokens):
        raise Refused(f"{dotted} exists already: {line_of(next(t for t in tokens if t.group == group and t.name == name), data)}")
    if not (source or why or system):
        raise Refused("a token needs --source P.., --why \"...\" or --system ...")
    kind = data["groups"][group]["kind"]
    if raw is None and not system:
        raise Refused("give a value (only a --system token may go without)")
    fields = parse_add_value(kind, raw)
    for k, v in (("system", system), ("source", source), ("why", why)):
        if v:
            fields[k] = v
    line = f"{name} = {inline_table(fields)}"
    lines = text.split("\n")
    header = next((i for i, l in enumerate(lines) if l.strip() == f"[{group}]"), None)
    if header is None:
        lines = lines[:-1] + ["", f"[{group}]", line, ""] if lines and lines[-1] == "" else lines + ["", f"[{group}]", line]
    else:
        end = next((i for i in range(header + 1, len(lines)) if lines[i].startswith("[")), len(lines))
        while end > header + 1 and not lines[end - 1].strip():
            end -= 1
        lines.insert(end, line)
    new = "\n".join(lines)
    load(root, new)  # refuses before anything is written
    with open(os.path.join(root, TOML), "w", encoding="utf-8") as f:
        f.write(new)
    print(f"tokens: added {group}.{name}: {line}")
    cmd_gen(root)


# MARK: - check

NUMBER = re.compile(r"(?<![\w.])(-?(?:0x[0-9a-fA-F_]+|\d[\d_]*(?:\.\d+)?))(?![\w])")
EXEMPT_SWIFT = re.compile(r"//\s*token-exempt:(.*)$")
EXEMPT_CSS = re.compile(r"/\*\s*token-exempt:(.*?)\*/")

# Calls whose numeric arguments are design values: (regex of the opening, kind).
SWIFT_CALLS = [
    (r"\.padding\(", "padding"),
    (r"\.frame\(", "frame"),
    (r"\.offset\(", "offset"),
    (r"\bNSEdgeInsets\(|\bEdgeInsets\(", "insets"),
    (r"\b(?:NSSize|CGSize|NSRect|CGRect)\(", "geometry"),
    (r"\.cornerRadius\(|\bcornerRadius:\s*", "radius"),
    (r"\.lineSpacing\(", "line-spacing"),
    (r"\.opacity\(", "opacity"),
    (r"\.system\(\s*size:|[sS]ystemFont\(ofSize:|\bNSFont\(name:", "font-size"),
]
# One finding per call, whatever its numbers: a colour built from components.
SWIFT_COLOUR = re.compile(r"\b(?:Color|NSColor)\(\s*(?:\.sRGB\s*,\s*)?(?:red|white|hue|calibratedRed|calibratedWhite|"
                          r"calibratedHue|srgbRed|deviceRed|deviceWhite|deviceHue|displayP3Red|genericGamma22White):")
# Labels whose literal value is a design value.
SWIFT_LABELS = [
    (re.compile(r"\bspacing:\s*(-?[\d.]+)"), "spacing"),
    (re.compile(r"\bSpacer\(minLength:\s*(-?[\d.]+)"), "spacing"),
    (re.compile(r"\b(?:cornerRadius|lineSpacing)\s*=\s*(-?[\d.]+)"), "radius"),
]
SWIFT_CONSTANT = re.compile(r"\b(?:let|var)\s+\w+\s*:\s*(?:CGFloat|\([^)=]*CGFloat[^)=]*\))\s*=\s*([^\n]*)")

CSS_LENGTH = re.compile(r"(?<![\w#.-])(-?\d*\.?\d+)(px|pt|rem|em|lh|vw|vh|ch|ex)\b")
CSS_COLOUR = re.compile(r"#[0-9a-fA-F]{3,8}\b|\b(?:rgba?|hsla?)\(")

KIND_GROUPS = {
    "padding": ["space", "inset"], "spacing": ["space"], "offset": ["space", "inset"], "insets": ["space", "inset"],
    "frame": ["window", "control", "row", "size", "space", "inset"],
    "geometry": ["window", "control", "row", "size", "space", "inset"],
    "constant": ["window", "control", "row", "inset", "space", "radius", "line", "size"],
    "radius": ["radius"], "line-spacing": ["space"], "font-size": ["text"], "opacity": [],
    "colour": ["colour"], "css-length": ["css", "density", "fill"], "css-colour": ["css", "palette"],
    "distance": ["space", "inset", "size"],
}


def skip_interpolation(text, j):
    """The index after the `)` closing an interpolation whose code starts at `j`, past strings nested in it."""
    depth, n = 1, len(text)
    while j < n and depth:
        c = text[j]
        if c == '"':
            j += 1
            while j < n and text[j] not in '"\n':
                j += 2 if text[j] == "\\" else 1
        depth += c == "("
        depth -= c == ")"
        j += 1
    return j


def blank_swift(text):
    """`text` with comments and string literals replaced by spaces, newlines kept, so positions still map to lines."""
    out, i, n = list(text), 0, len(text)

    def blank(a, b):
        for k in range(a, b):
            if out[k] != "\n":
                out[k] = " "
    while i < n:
        c = text[i]
        if text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            blank(i, j)
            i = j
        elif text.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if text.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif text.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            blank(i, j)
            i = j
        elif c == '"' or (c == "#" and re.match(r'#+"', text[i:])):
            hashes = len(re.match(r'#*', text[i:]).group(0))
            start = i + hashes
            triple = text.startswith('"""', start)
            close = ('"""' if triple else '"') + "#" * hashes
            j = start + (3 if triple else 1)
            while j < n:
                if text.startswith("\\" + "#" * hashes + "(", j):
                    j = skip_interpolation(text, j + hashes + 2)
                    continue
                if hashes == 0 and text[j] == "\\":
                    j += 2
                    continue
                if text.startswith(close, j):
                    j += len(close)
                    break
                if not triple and text[j] == "\n":
                    break
                j += 1
            blank(i, j)
            i = j
        else:
            i += 1
    return "".join(out)


def span(text, open_end):
    """The end of the parenthesised arguments that start just before `open_end` (after its `(`)."""
    depth, j = 1, open_end
    while j < len(text) and depth:
        if text[j] == "(":
            depth += 1
        elif text[j] == ")":
            depth -= 1
        j += 1
    return j


def numeric_value(raw):
    raw = raw.replace("_", "")
    neg = raw.startswith("-")
    body = raw[1:] if neg else raw
    v = int(body, 16) if body.lower().startswith("0x") else float(body)
    return -v if neg else v


def allowed(kind, value, text, pos):
    before = text[:pos].rstrip()
    if before.endswith(("*", "/")):
        return True  # a factor or ratio
    if value == 0 and kind not in ("font-size", "colour"):
        return True  # none
    if value == 1 and kind == "opacity":
        return True  # unchanged
    return False


# Capture-shaped distances (ADR-0014 decision 11): a tolerance compared with a distance, written as a bare literal or as
# a constant whose type is inferred (`static let horizontal = 3`), which the `CGFloat` constant rule cannot see.
COMPARISON = re.compile(r"\s(<=|>=|<|>)\s")
DISTANCE_TERM = re.compile(r"\bhypot\(|\bdistance\b|\b(?:dx|dy)\b|\.(?:minX|maxX|minY|maxY|midX|midY|width|height|x|y)\b")
OPERAND = r"(-?(?:\d[\d_]*(?:\.\d+)?)|(?:Self\.|self\.)?[A-Za-z_]\w*)"
RIGHT_OPERAND = re.compile(r"\s*" + OPERAND + r"(?=\s*(?:$|[,{})?:&|;]|else\b))")
LEFT_OPERAND = re.compile(r"(?:^|[\s(!,{])" + OPERAND + r"\s*$")
INFERRED = r"\b(?:let|var)\s+{name}\s*=\s*(-?\d[\d_]*(?:\.\d+)?)\s*(?:$|//|\n)"


def distance_comparisons(clean):
    """(kind, position, value) for each tolerance compared bare with a distance: the literal itself, or the inferred
    numeric constant's declaration. 0 means none and is allowed; a ratio (the other side divides) is not a distance."""
    out = []
    offset = 0
    for line in clean.split("\n"):
        for m in COMPARISON.finditer(line):
            left, right = line[:m.start()], line[m.end():]
            for operand_match, other, base in ((RIGHT_OPERAND.match(right), left, m.end()),
                                               (LEFT_OPERAND.search(left), right, None)):
                if operand_match is None or not DISTANCE_TERM.search(other) or " / " in other:
                    continue
                operand = operand_match.group(1)
                if base is None:
                    start = operand_match.start(1)
                else:
                    start = base + operand_match.start(1)
                if re.fullmatch(r"-?\d[\d_]*(?:\.\d+)?", operand):
                    if numeric_value(operand) != 0:
                        out.append(("distance", offset + start, operand))
                    continue
                name = operand.split(".")[-1]
                decl = re.search(INFERRED.format(name=re.escape(name)), clean)
                if decl and numeric_value(decl.group(1)) != 0:
                    out.append(("distance", decl.start(1), decl.group(1)))
        offset += len(line) + 1
    return out


def scan_swift(rel, text):
    clean = blank_swift(text)
    lines = text.split("\n")
    found = {}

    def add(kind, pos, value):
        found.setdefault(pos, (kind, clean.count("\n", 0, pos) + 1, value))
    for pattern, kind in SWIFT_CALLS:
        for m in re.finditer(pattern, clean):
            end = span(clean, m.end()) if m.group(0).endswith("(") else m.end() + 12
            if kind == "font-size" and not m.group(0).endswith("("):
                end = span(clean, m.end())
            if kind == "radius" and not m.group(0).endswith("("):
                end = m.end() + len(re.match(r"[^,)\n]*", clean[m.end():]).group(0))
            for nm in NUMBER.finditer(clean, m.end(), end):
                value = numeric_value(nm.group(1))
                if kind == "font-size":
                    # Only the size argument: after `size:` or `ofSize:`.
                    if not re.search(r"(?:size|ofSize):\s*$", clean[max(0, nm.start() - 16):nm.start()]):
                        continue
                if not allowed(kind, value, clean, nm.start()):
                    add(kind, nm.start(), nm.group(1))
    for m in SWIFT_COLOUR.finditer(clean):
        end = span(clean, clean.index("(", m.start()) + 1)
        add("colour", m.start(), " ".join(clean[m.start():end].split()))
    for rx, kind in SWIFT_LABELS:
        for m in rx.finditer(clean):
            value = numeric_value(m.group(1)) if re.fullmatch(r"-?\d[\d.]*", m.group(1)) else None
            if value is not None and not allowed(kind, value, clean, m.start(1)):
                add(kind, m.start(1), m.group(1))
    for m in SWIFT_CONSTANT.finditer(clean):
        for nm in NUMBER.finditer(clean, m.start(1), m.end(1)):
            value = numeric_value(nm.group(1))
            if not allowed("constant", value, clean, nm.start()):
                add("constant", nm.start(), nm.group(1))
    for kind, pos, value in distance_comparisons(clean):
        add(kind, pos, value)
    return [(rel, line, kind, value, lines[line - 1]) for kind, line, value in
            sorted(found.values(), key=lambda f: f[1])], EXEMPT_SWIFT


def blank_css(text):
    """Comments and `var(--x, fallback)` fallbacks blanked, newlines kept."""
    out = list(text)

    def blank(a, b):
        for k in range(a, b):
            if out[k] != "\n":
                out[k] = " "
    for m in re.finditer(r"/\*.*?\*/", text, re.S):
        blank(m.start(), m.end())
    clean = "".join(out)
    for m in re.finditer(r"\bvar\(", clean):
        end = span(clean, m.end())
        depth, j = 0, m.end()
        while j < end - 1:
            ch = clean[j]
            depth += ch == "("
            depth -= ch == ")"
            if ch == "," and depth == 0:
                blank(j, end - 1)
                break
            j += 1
    return "".join(out)


def scan_css(rel, text):
    clean = blank_css(text)
    lines = text.split("\n")
    out = []
    for m in CSS_LENGTH.finditer(clean):
        if float(m.group(1)) == 0:
            continue
        line = clean.count("\n", 0, m.start()) + 1
        out.append((rel, line, "css-length", m.group(0), lines[line - 1]))
    for m in CSS_COLOUR.finditer(clean):
        line = clean.count("\n", 0, m.start()) + 1
        out.append((rel, line, "css-colour", m.group(0).rstrip("("), lines[line - 1]))
    out.sort(key=lambda f: f[1])
    return out, EXEMPT_CSS


def scan(root):
    """(findings, exemptions): each finding (file, line, kind, value, source line)."""
    findings, exemptions = [], []
    sources = os.path.join(root, "Sources")
    for dirpath, dirnames, filenames in os.walk(sources):
        dirnames.sort()
        for fn in sorted(filenames):
            path = os.path.join(dirpath, fn)
            rel = os.path.relpath(path, root)
            if rel.startswith(SKIP_DIRS) or rel in SKIP_FILES or rel in (CSS_OUT, PALETTE_OUT, DENSITY_OUT):
                continue
            if fn.endswith(".swift"):
                scanner = scan_swift
            elif fn.endswith(".css") and rel.startswith(STYLE_DIR):
                scanner = scan_css
            else:
                continue
            with open(path, encoding="utf-8") as f:
                text = f.read()
            hits, exempt_rx = scanner(rel, text)
            seen_lines = set()
            for hit in hits:
                m = exempt_rx.search(hit[4])
                if m is None:
                    findings.append(hit)
                    continue
                reason = m.group(1).strip()
                if not reason:
                    findings.append((hit[0], hit[1], "exempt-no-reason", hit[3], hit[4]))
                elif (rel, hit[1]) not in seen_lines:
                    seen_lines.add((rel, hit[1]))
                    exemptions.append((rel, hit[1], reason))
    return findings, exemptions


def suggestion(data, tokens, kind, value):
    groups = KIND_GROUPS.get(kind)
    if not groups or kind in ("colour", "exempt-no-reason"):
        return ""
    lines = find(data, tokens, value, groups)
    return "; ".join(lines[:3])


def cmd_check(root, report=False):
    data, tokens, _ = load(root)
    findings, exemptions = scan(root)
    by_kind = {}
    for f in findings:
        by_kind.setdefault(f[2], []).append(f)
    for f in findings:
        hint = suggestion(data, tokens, f[2], f[3])
        print(f"{f[0]}:{f[1]}: {f[2]} {f[3]}" + (f"    -> {hint}" if hint else ""))
    for rel, line, reason in exemptions:
        print(f"{rel}:{line}: exempt: {reason}")
    summary = ", ".join(f"{k} {len(v)}" for k, v in sorted(by_kind.items()))
    print(f"tokens check: {len(findings)} finding(s)" + (f" ({summary})" if summary else "")
          + f", {len(exemptions)} exemption(s)")
    return 0 if report or not findings else 1


# MARK: - main

def main(argv):
    p = argparse.ArgumentParser(prog="tokens.py", description=__doc__.split("\n\n")[0])
    p.add_argument("--root", default=APPLE)
    sub = p.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("gen")
    g.add_argument("--check", action="store_true")
    li = sub.add_parser("list")
    li.add_argument("group", nargs="?")
    fi = sub.add_parser("find")
    fi.add_argument("query")
    ad = sub.add_parser("add")
    ad.add_argument("token")
    ad.add_argument("value", nargs="?")
    ad.add_argument("--source")
    ad.add_argument("--why")
    ad.add_argument("--system")
    ch = sub.add_parser("check")
    ch.add_argument("--report", action="store_true")
    a = p.parse_args(argv)
    root = os.path.abspath(a.root)
    try:
        if a.cmd == "gen":
            return cmd_gen(root, a.check)
        elif a.cmd == "list":
            cmd_list(root, a.group)
        elif a.cmd == "find":
            return cmd_find(root, a.query)
        elif a.cmd == "add":
            cmd_add(root, a.token, a.value, a.source, a.why, a.system)
        else:
            return cmd_check(root, a.report)
    except Refused as e:
        print(e, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
