#!/usr/bin/env python3
"""The warnings gate (Tools/compiler-warnings.py) attributes a warning to the source it is about, not to the `.dia`
that holds it. Swift compiles sources in batches and may write a warning located in another source of the batch (a
macro expansion buffer of `#expect`, measured 2026-10-18) into the wrong source's `.dia`; once that other source is
fixed and recompiled, the holder, not recompiled, keeps the warning forever. Such a warning counts only when its
holder is at least as new as the attributed source's own `.dia`."""
import importlib.util
import os
import pathlib
import sys
import tempfile
import unittest

TOOLS = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("compiler_warnings", TOOLS / "compiler-warnings.py")
gate = importlib.util.module_from_spec(spec)
sys.modules["compiler_warnings"] = gate
spec.loader.exec_module(gate)

BUFFER = ("/var/folders/x/T/swift-generated-sources/@__swiftmacro_12XDictUITests0035DictionaryTableDropTestsswift_"
          "IgGGkfMX13_8_6expectfMf_.swift")
MACRO_WARNING = f"{BUFFER}:1:48: warning: call to main actor-isolated static method in a nonisolated context"


class Module:
    """A module directory with a `.SwiftFileList` and a `.dia` per source, each with its warnings and its age."""

    def __init__(self, test, sources):
        self.directory = pathlib.Path(test.enterContext(tempfile.TemporaryDirectory())) / "XDictUITests.build"
        self.directory.mkdir()
        (self.directory / "XDictUITests.SwiftFileList").write_text(
            "".join(f"/src/Tests/XDictUITests/{name}.swift\n" for name in sources))
        self.contents = {}
        self.write("XDictUITests-primary-emit-module", [], age=100)
        for name in sources:
            self.write(name, [], age=100)
        original = gate.warnings_in
        gate.warnings_in = lambda _library, path: list(self.contents[path.name])
        test.addCleanup(setattr, gate, "warnings_in", original)

    def write(self, stem, warnings, age):
        """`age` seconds ago."""
        path = self.directory / f"{stem}.dia"
        path.write_bytes(b"")
        self.contents[path.name] = warnings
        stamp = 2_000_000_000 - age
        os.utime(path, (stamp, stamp))

    def read(self):
        reading = gate.Reading()
        gate.read_module(None, self.directory, False, reading)
        return reading


class CrossFileMacroWarnings(unittest.TestCase):
    def test_older_holder_than_the_sources_own_dia_is_stale(self):
        # The observed case: DictionaryTableDropTests fixed and recompiled at 09:04, its own .dia clean; the
        # warnings sit in AnywhereSentencesTests.dia of 09:02, which was not recompiled.
        module = Module(self, ["AnywhereSentencesTests", "DictionaryTableDropTests"])
        module.write("AnywhereSentencesTests", [MACRO_WARNING], age=120)
        module.write("DictionaryTableDropTests", [], age=0)
        reading = module.read()
        self.assertEqual(list(reading.warnings), [])
        self.assertEqual(reading.stale_warnings, 1)

    def test_holder_newer_than_the_sources_own_dia_counts(self):
        module = Module(self, ["AnywhereSentencesTests", "DictionaryTableDropTests"])
        module.write("AnywhereSentencesTests", [MACRO_WARNING], age=0)
        module.write("DictionaryTableDropTests", [], age=120)
        self.assertEqual(list(module.read().warnings), [MACRO_WARNING])

    def test_holder_as_new_as_the_sources_own_dia_counts(self):
        module = Module(self, ["AnywhereSentencesTests", "DictionaryTableDropTests"])
        module.write("AnywhereSentencesTests", [MACRO_WARNING], age=5)
        module.write("DictionaryTableDropTests", [], age=5)
        self.assertEqual(list(module.read().warnings), [MACRO_WARNING])

    def test_source_with_no_own_dia_keeps_the_warning(self):
        module = Module(self, ["AnywhereSentencesTests"])
        module.write("AnywhereSentencesTests", [MACRO_WARNING], age=120)
        self.assertEqual(list(module.read().warnings), [MACRO_WARNING])

    def test_unparseable_buffer_name_keeps_the_warning(self):
        module = Module(self, ["AnywhereSentencesTests", "DictionaryTableDropTests"])
        odd = MACRO_WARNING.replace("0035DictionaryTableDropTestsswift_IgGGk", "zzz")
        module.write("AnywhereSentencesTests", [odd], age=120)
        module.write("DictionaryTableDropTests", [], age=0)
        self.assertEqual(list(module.read().warnings), [odd])

    def test_warning_in_its_own_dia_counts_however_old(self):
        module = Module(self, ["DictionaryTableDropTests"])
        module.write("DictionaryTableDropTests", [MACRO_WARNING], age=1000)
        self.assertEqual(list(module.read().warnings), [MACRO_WARNING])


class OtherModules(unittest.TestCase):
    def test_macro_buffer_of_another_module_keeps_the_warning(self):
        module = Module(self, ["AnywhereSentencesTests", "DictionaryTableDropTests"])
        other = MACRO_WARNING.replace("12XDictUITests", "11XDictSearch")
        module.write("AnywhereSentencesTests", [other], age=120)
        module.write("DictionaryTableDropTests", [], age=0)
        self.assertEqual(list(module.read().warnings), [other])

    def test_same_named_file_outside_the_list_keeps_the_warning(self):
        module = Module(self, ["A", "B"])
        warning = "/elsewhere/B.swift:3:5: warning: unused"
        module.write("A", [warning], age=120)
        module.write("B", [], age=0)
        self.assertEqual(list(module.read().warnings), [warning])


class CrossFileSourceWarnings(unittest.TestCase):
    def test_older_holder_of_another_real_sources_warning_is_stale(self):
        module = Module(self, ["A", "B"])
        warning = "/src/Tests/XDictUITests/B.swift:3:5: warning: unused"
        module.write("A", [warning], age=120)
        module.write("B", [], age=0)
        self.assertEqual(list(module.read().warnings), [])

    def test_newer_holder_of_another_real_sources_warning_counts(self):
        module = Module(self, ["A", "B"])
        warning = "/src/Tests/XDictUITests/B.swift:3:5: warning: unused"
        module.write("A", [warning], age=0)
        module.write("B", [], age=120)
        self.assertEqual(list(module.read().warnings), [warning])

    def test_warning_with_no_location_counts(self):
        module = Module(self, ["A", "B"])
        module.write("A", ["warning: something"], age=120)
        module.write("B", [], age=0)
        self.assertEqual(list(module.read().warnings), ["warning: something"])


class BufferNames(unittest.TestCase):
    def test_swift_punycode_file_name(self):
        self.assertEqual(gate.macro_source(BUFFER), ("XDictUITests", "DictionaryTableDropTests.swift"))

    def test_unparseable(self):
        for name in ["@__swiftmacro_zz.swift", "@__swiftmacro_12XDictUITests0099Short_a.swift",
                     "@__swiftmacro_99XDict.swift", "@__swiftmacro_.swift"]:
            self.assertIsNone(gate.macro_source(f"/T/{name}"), name)


if __name__ == "__main__":
    unittest.main()
