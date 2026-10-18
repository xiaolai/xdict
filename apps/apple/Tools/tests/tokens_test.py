#!/usr/bin/env python3
"""The design tokens' helper (Tools/tokens.py): its source is refused without provenance, its output is determined
by the source alone, `find` names the token or its neighbours, `add` writes only what validates, and `check` sees
each literal it is meant to see, allows exactly its allow-list, and fails on a planted literal."""
import importlib.util
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

TOOLS = pathlib.Path(__file__).resolve().parents[1]
APPLE = TOOLS.parent
SCRIPT = TOOLS / "tokens.py"
spec = importlib.util.spec_from_file_location("tokens", SCRIPT)
tokens = importlib.util.module_from_spec(spec)
sys.modules["tokens"] = tokens
spec.loader.exec_module(tokens)

SOURCE = """\
[groups]
space = { kind = "length", swift = "Space", doc = "The spacing scale." }
inset = { kind = "length", swift = "Inset", doc = "Insets." }
text = { kind = "font", swift = "TextRole", doc = "Text roles." }
colour = { kind = "colour", swift = "Colour", doc = "Colours." }
css = { kind = "css", doc = "Reading style tokens." }
palette = { kind = "css-palette", doc = "Palette." }
accent = { kind = "css-accent", doc = "Accents." }

[space]
s = { value = 4, why = "The small step of the scale." }
m = { value = 12, why = "The middle step of the scale." }
l = { value = 16, why = "The large step of the scale." }

[inset]
entryLeading = { value = 19, source = "P12" }

[text]
body = { system = "body" }
row = { size = 13, weight = "semibold", source = "P12" }

[colour]
label = { system = "labelColor" }
rule = { light = "#929292", dark = "#5c5c5c", source = "P12" }

[css]
space-1 = { value = "0.25rem", why = "The reading style's first step." }

[palette]
bg = { light = "#ffffff", dark = "#1e1e1e", source = "P12" }

[accent]
teal = { light = "#055959", dark = "#81ecec", why = "The default accent hue." }
"""

PARITY = "id\tarea\nP1\twindow\nP12\tsearch\n"


class Root:
    """A copy of apps/apple's shape in a temporary directory: the source, the parity table, and Sources/."""

    def __init__(self, test, source=SOURCE):
        self.path = pathlib.Path(test.enterContext(tempfile.TemporaryDirectory()))
        (self.path / "Tokens").mkdir()
        (self.path / "Tools/parity").mkdir(parents=True)
        (self.path / "Sources/XDictUI").mkdir(parents=True)
        (self.path / "Sources/XDictEntryView/Style").mkdir(parents=True)
        (self.path / "Tokens/tokens.toml").write_text(source)
        (self.path / "Tools/parity/apple-dictionary.tsv").write_text(PARITY)

    def run(self, *args):
        return subprocess.run([sys.executable, "-I", str(SCRIPT), "--root", str(self.path), *args],
                              capture_output=True, text=True)

    def swift(self, text, name="View.swift"):
        (self.path / "Sources/XDictUI" / name).write_text(text)

    def css(self, text, name="sheet.css"):
        (self.path / "Sources/XDictEntryView/Style" / name).write_text(text)

    def findings(self):
        return tokens.scan(str(self.path))


class Source(unittest.TestCase):
    def refused(self, source):
        with self.assertRaises(tokens.Refused) as caught:
            tokens.load(str(Root(self, source).path))
        return str(caught.exception)

    def test_the_real_source_loads(self):
        _, toks, _ = tokens.load(str(APPLE))
        self.assertGreater(len(toks), 100)

    def test_a_token_without_provenance_is_refused(self):
        message = self.refused(SOURCE.replace('m = { value = 12, why = "The middle step of the scale." }',
                                              "m = { value = 12 }"))
        self.assertIn("space.m: no provenance", message)

    def test_an_unknown_parity_id_is_refused(self):
        self.assertIn("P999 is not in", self.refused(SOURCE.replace('source = "P12" }\n\n[text]',
                                                                    'source = "P999" }\n\n[text]')))

    def test_a_why_that_says_nothing_is_refused(self):
        self.assertIn("must say why", self.refused(SOURCE.replace('"The small step of the scale."', '"x"')))

    def test_an_undeclared_group_and_unknown_key_are_refused(self):
        message = self.refused(SOURCE + '\n[stray]\nx = { value = 1, why = "No group for this one." }\n')
        self.assertIn("[stray] is not a declared group", message)
        self.assertIn("unknown keys ['colour']", self.refused(SOURCE.replace(
            'l = { value = 16,', 'l = { colour = "red", value = 16,')))

    def test_system_only_where_it_means_something(self):
        self.assertIn("`system` is for text styles and colours only",
                      self.refused(SOURCE.replace('l = { value = 16, why = "The large step of the scale." }',
                                                  'l = { value = 16, system = "body" }')))
        self.assertIn("system text style must be one of",
                      self.refused(SOURCE.replace('{ system = "body" }', '{ system = "bodyy" }')))


class Generation(unittest.TestCase):
    def test_gen_is_determined_by_the_source(self):
        root = Root(self)
        first = tokens.generated(str(root.path))
        second = tokens.generated(str(root.path))
        self.assertEqual(first, second)
        self.assertEqual(root.run("gen").returncode, 0)
        self.assertEqual(root.run("gen", "--check").returncode, 0)
        swift = (root.path / tokens.SWIFT_OUT).read_text()
        self.assertIn("public static let m: CGFloat = 12", swift)
        self.assertIn("TokenFont(size: 13, weight: .semibold, design: .default, italic: false)", swift)
        self.assertIn("TokenColour(light: 0x929292, dark: 0x5c5c5c)", swift)
        css = (root.path / tokens.CSS_OUT).read_text()
        self.assertIn(":root{\n--xdict-space-1:0.25rem;\n}", css)
        palette = (root.path / tokens.PALETTE_OUT).read_text()
        self.assertIn(":root[data-xdict-theme=light]{\n--xdict-bg:#ffffff;\n}", palette)
        self.assertIn(":root[data-xdict-theme=dark][data-xdict-hue=teal]{\n--xdict-accent:#81ecec\n}", palette)
        self.assertIn('public static let accentTeal = (light: "#055959", dark: "#81ecec")', swift)

    def test_the_new_kinds_generate(self):
        source = SOURCE.replace(
            'accent = { kind = "css-accent", doc = "Accents." }\n',
            'accent = { kind = "css-accent", doc = "Accents." }\n'
            'density = { kind = "css-density", doc = "Density." }\n'
            'fill = { kind = "css-fill", doc = "Fills." }\n'
            'frames = { kind = "rect", swift = "Frames", doc = "Frames." }\n'
            'words = { kind = "string", swift = "Words", doc = "Words." }\n') + (
            '\n[density]\nspace-sense = { main = "0.75em", panel = "0.5em", why = "Between senses in each density." }\n'
            'space-image = { main = "0.75em", why = "Around a picture, the same in both." }\n'
            '\n[fill]\nbp-narrow = { value = "480px", why = "A media query cannot read var()." }\n'
            '\n[frames]\nlab = { x = 100, y = 120, width = 900, height = 700, why = "The lab window, clear of the menu bar." }\n'
            '\n[words]\ninset = { value = "8px 14px", why = "Every entry\'s reading inset." }\n')
        root = Root(self, source)
        self.assertEqual(root.run("gen").returncode, 0)
        density = (root.path / tokens.DENSITY_OUT).read_text()
        self.assertIn(":root{\n--xdict-space-sense:0.75em;\n--xdict-space-image:0.75em;\n}", density)
        self.assertIn(":root[data-xdict-density=panel]{\n--xdict-space-sense:0.5em;\n}", density)
        swift = (root.path / tokens.SWIFT_OUT).read_text()
        self.assertIn('"fill-bp-narrow": "480px",', swift)
        self.assertIn("public static let lab = CGRect(x: 100, y: 120, width: 900, height: 700)", swift)
        self.assertIn('public static let inset = "8px 14px"', swift)
        data, toks, _ = tokens.load(str(root.path))
        self.assertTrue(tokens.find(data, toks, "480px")[0].startswith("{{fill-bp-narrow}} = 480px"))

    def test_a_css_literal_is_found_as_written(self):
        data, toks, _ = tokens.load(str(Root(self).path))
        self.assertEqual(tokens.find(data, toks, "0.25em")[0][:6], "[space")  # no 0.25em token: neighbours only

    def test_a_stale_or_edited_output_fails_check(self):
        root = Root(self)
        root.run("gen")
        (root.path / "Tokens/tokens.toml").write_text(SOURCE.replace("value = 12", "value = 11"))
        result = root.run("gen", "--check")
        self.assertEqual(result.returncode, 1)
        self.assertIn("stale", result.stderr)
        root.run("gen")
        css = root.path / tokens.CSS_OUT
        css.write_text(css.read_text() + "/* hand edit */\n")
        self.assertEqual(root.run("gen", "--check").returncode, 1)

    def test_the_real_outputs_are_fresh(self):
        self.assertEqual(subprocess.run([sys.executable, "-I", str(SCRIPT), "gen", "--check"],
                                        capture_output=True).returncode, 0)


class Find(unittest.TestCase):
    def setUp(self):
        self.data, self.toks, _ = tokens.load(str(Root(self).path))

    def test_an_exact_value_names_its_token(self):
        self.assertEqual(tokens.find(self.data, self.toks, "12"),
                         ["Tokens.Space.m = 12    [why: The middle step of the scale.]"])

    def test_a_value_between_names_the_nearest_per_group(self):
        lines = tokens.find(self.data, self.toks, "14")
        self.assertIn("[space] no 14; nearest: Tokens.Space.m = 12, Tokens.Space.l = 16", lines)
        self.assertIn("[inset] no 14; nearest: Tokens.Inset.entryLeading = 19", lines)

    def test_a_css_length_is_found_as_written(self):
        self.assertEqual(tokens.find(self.data, self.toks, "0.25rem"),
                         ["var(--xdict-space-1) = 0.25rem    [why: The reading style's first step.]"])

    def test_a_name_finds_by_part(self):
        self.assertEqual(len(tokens.find(self.data, self.toks, "leading")), 1)


class Add(unittest.TestCase):
    def test_add_writes_a_valid_token_and_generates(self):
        root = Root(self)
        result = root.run("add", "space.xl", "24", "--why", "The extra large step of the scale.")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('xl = { value = 24, why = "The extra large step of the scale." }\n\n[inset]',
                      (root.path / "Tokens/tokens.toml").read_text())
        self.assertIn("public static let xl: CGFloat = 24", (root.path / tokens.SWIFT_OUT).read_text())

    def test_add_refuses_without_provenance_or_twice(self):
        root = Root(self)
        before = (root.path / "Tokens/tokens.toml").read_text()
        self.assertEqual(root.run("add", "space.xl", "24").returncode, 2)
        self.assertEqual(root.run("add", "space.m", "12", "--why", "Again, the middle step.").returncode, 2)
        self.assertEqual(root.run("add", "space.xl", "24", "--source", "P404").returncode, 2)
        self.assertEqual((root.path / "Tokens/tokens.toml").read_text(), before)

    def test_add_a_system_role_and_a_colour(self):
        root = Root(self)
        self.assertEqual(root.run("add", "text.caption", "--system", "caption").returncode, 0)
        self.assertEqual(root.run("add", "colour.panel", "#F3F3F5/#2a2a2c", "--source", "P1").returncode, 0)
        swift = (root.path / tokens.SWIFT_OUT).read_text()
        self.assertIn("TokenFont(style: .caption)", swift)
        self.assertIn("0xf3f3f5", swift)


class Check(unittest.TestCase):
    def kinds(self, swift=None, css=None):
        root = Root(self)
        if swift is not None:
            root.swift(swift)
        if css is not None:
            root.css(css)
        findings, exemptions = root.findings()
        return [(f[2], f[3]) for f in findings], exemptions

    def test_each_swift_pattern_is_seen(self):
        cases = {
            "x.padding(8)": ("padding", "8"),
            "x.padding(.horizontal, 20)": ("padding", "20"),
            "VStack(spacing: 6) {}": ("spacing", "6"),
            "Spacer(minLength: 4)": ("spacing", "4"),
            "x.frame(width: 360)": ("frame", "360"),
            "x.frame(minWidth: 140, maxHeight: .infinity)": ("frame", "140"),
            "x.frame(\n  idealHeight: 560)": ("frame", "560"),
            "x.offset(y: -3)": ("offset", "-3"),
            "RoundedRectangle(cornerRadius: 8)": ("radius", "8"),
            "x.cornerRadius(5)": ("radius", "5"),
            "layer.cornerRadius = 6": ("radius", "6"),
            "x.font(.system(size: 15).italic())": ("font-size", "15"),
            "let f = Font.system(size: 11, weight: .bold)": ("font-size", "11"),
            "label.font = .systemFont(ofSize: 13, weight: .regular)": ("font-size", "13"),
            "NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)": ("font-size", "10"),
            "x.opacity(0.5)": ("opacity", "0.5"),
            "x.lineSpacing(3)": ("line-spacing", "3"),
            "NSEdgeInsets(top: 2, left: 0, bottom: 0, right: 0)": ("insets", "2"),
            "t.intercellSpacing = NSSize(width: 4, height: 0)": ("geometry", "4"),
            "CGRect(x: 0, y: 0, width: 1, height: 0)": ("geometry", "1"),
            "static let rowHeight: CGFloat = 28": ("constant", "28"),
            "let minimum: (width: CGFloat, height: CGFloat) = (400, 0)": ("constant", "400"),
        }
        for code, expected in cases.items():
            with self.subTest(code=code):
                self.assertEqual(self.kinds(swift=code + "\n")[0], [expected])

    def test_capture_shaped_distance_comparisons_are_seen(self):
        cases = {
            "static let horizontal = 3\nfunc near(dx: CGFloat) -> Bool { dx <= horizontal }": ("distance", "3"),
            "func moved(a: CGPoint, b: CGPoint) -> Bool { hypot(b.x - a.x, b.y - a.y) > 2 }": ("distance", "2"),
            "let slack = 4.0\nguard box.width < slack else { return }": ("distance", "4.0"),
            "guard abs(a.minX - b.minX) <= 3 else { return }": ("distance", "3"),
            "if 2 < distance(from: p, to: box) { }": ("distance", "2"),
        }
        for code, expected in cases.items():
            with self.subTest(code=code):
                self.assertEqual(self.kinds(swift=code + "\n")[0], [expected])

    def test_distances_that_are_not_capture_tolerances_are_not_seen(self):
        found, _ = self.kinds(swift="\n".join([
            "guard dx <= tolerance.horizontal else { return }", "if count > 3 { }", "guard box.width > 0 else { return }",
            "return overlap / shorter >= 0.5", "let limit = 3\nif items.count > limit { }",
            "guard dx <= metrics.hit.horizontal * 2 else { return }", "let s: Set<Int> = []",
        ]) + "\n")
        self.assertEqual(found, [])

    def test_a_planted_capture_tolerance_fails_check(self):
        root = Root(self)
        root.swift("func near(dx: CGFloat, t: HitTolerance) -> Bool { dx <= t.horizontal }\n")
        self.assertEqual(root.run("check").returncode, 0)
        root.swift("static let horizontal = 3\nfunc near(dx: CGFloat) -> Bool { dx <= horizontal }\n")
        result = root.run("check")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Sources/XDictUI/View.swift:1: distance 3", result.stdout)

    def test_the_other_capture_spellings_are_seen(self):
        cases = {
            "static let gap: Double = 3\nguard dx <= gap else { return }": [("distance", "3")],
            "guard dx <= CGFloat(3) else { return }": [("distance", "3")],
            "func near(_ p: CGPoint, tolerance: CGFloat = 3) -> Bool { true }": [("default", "3")],
            "guard dx<=3 else { return }": [("distance", "3")],
            "let r = box.insetBy(dx: -3, dy: -2)": [("geometry", "-3"), ("geometry", "-2")],
        }
        for code, expected in cases.items():
            with self.subTest(code=code):
                self.assertEqual(self.kinds(swift=code + "\n")[0], expected)

    def capture_kinds(self, swift):
        root = Root(self)
        (root.path / "Sources/XDictCapture").mkdir()
        (root.path / "Sources/XDictCapture/Rule.swift").write_text(swift)
        return [(f[2], f[3]) for f in root.findings()[0]]

    def test_a_capture_float_constant_is_injected_or_named_a_fraction(self):
        cases = {
            "static let pitch: Double = 1.5": [("capture-unitless-name", "1.5")],
            "let jitter = 0.25": [("capture-unitless-name", "0.25")],
            "func clips(edge: CGFloat = 0.004) -> Bool { true }": [("capture-unitless-name", "0.004")],
            "static let pitchRatio: Double = 1.5": [],
            "static let cutFraction = 0.25": [],
            "func f(minimumOverlap: CGFloat = 0.2) -> Bool { true }": [],
            "init(confidence: Double = 1) {}": [],
            "static let count = 3": [],
        }
        for code, expected in cases.items():
            with self.subTest(code=code):
                self.assertEqual(self.capture_kinds(code + "\n"), expected)

    def test_the_fraction_rule_holds_only_inside_capture(self):
        self.assertEqual(self.kinds(swift="let jitter = 0.25\n")[0], [])

    def test_a_colour_from_components_is_one_finding(self):
        found, _ = self.kinds(swift="let c = NSColor(white: 0x5c / 255, alpha: 1)\nlet d = Color(red: 1, green: 0, blue: 0)\n")
        self.assertEqual([k for k, _ in found], ["colour", "colour"])

    def test_what_is_allowed_is_not_seen(self):
        found, _ = self.kinds(swift="\n".join([
            "x.padding(0)", "VStack(spacing: 0) {}", "x.opacity(1)", "x.frame(width: Tokens.Window.settingsWidth)",
            "x.frame(minWidth: ToolbarLayout.minimumWindow.width / 2)", "let a = items[3]", "let count = 12",
            "x.padding(Tokens.Space.m)", "// x.padding(8) in a comment", 'let s = "x.padding(8)"',
            "let t = Color(nsColor: .labelColor)", "let frame = CGRect(origin: .zero, size: size)",
        ]) + "\n")
        self.assertEqual(found, [])

    def test_a_1_that_is_a_length_is_seen(self):
        self.assertEqual(self.kinds(swift="x.frame(height: 1)\n")[0], [("frame", "1")])

    def test_css_lengths_and_colours_are_seen_outside_fallbacks(self):
        found, _ = self.kinds(css="\n".join([
            "a{margin:0.25em 0 0 4px}",
            "b{color:#1d1d1f;background:rgba(0,0,0,.1)}",
            "c{padding:var(--xdict-space-1, 4px);margin:0}",
            "/* 12px in a comment */",
            "d{width:calc(var(--xdict-hit) - 1em)}",
        ]) + "\n")
        self.assertEqual(found, [("css-length", "0.25em"), ("css-length", "4px"), ("css-colour", "#1d1d1f"),
                                 ("css-colour", "rgba"), ("css-length", "1em")])

    def test_tokens_css_and_the_tokens_target_are_not_scanned(self):
        root = Root(self)
        root.css(":root{--xdict-base:16px}\n", name="tokens.css")
        (root.path / "Sources/XDictTokens").mkdir()
        (root.path / "Sources/XDictTokens/Tokens.swift").write_text("public static let m: CGFloat = 12\n")
        self.assertEqual(root.findings(), ([], []))

    def test_an_exemption_needs_a_reason(self):
        found, exemptions = self.kinds(swift="x.padding(8) // token-exempt: the lab's own window\n"
                                             "x.padding(9) // token-exempt:\n",
                                       css="a{margin:3px} /* token-exempt: a dictionary quirk */\n")
        self.assertEqual(found, [("exempt-no-reason", "9")])
        self.assertEqual([e[2] for e in exemptions], ["a dictionary quirk", "the lab's own window"])

    def test_a_planted_literal_fails_check_and_report_does_not(self):
        root = Root(self)
        root.swift("x.padding(Tokens.Space.m)\n")
        self.assertEqual(root.run("check").returncode, 0)
        root.swift("x.padding(Tokens.Space.m)\nx.padding(14)\n")
        result = root.run("check")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Sources/XDictUI/View.swift:2: padding 14    -> [space] no 14; nearest: Tokens.Space.m = 12, "
                      "Tokens.Space.l = 16", result.stdout)
        self.assertEqual(root.run("check", "--report").returncode, 0)


if __name__ == "__main__":
    unittest.main()
