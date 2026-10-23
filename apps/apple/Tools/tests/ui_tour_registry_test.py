#!/usr/bin/env python3
"""The UI tour preserves the service's real registry while exercising synthetic history and notes."""
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "ui-tour"))
from ledger_sandbox import RegistrySandbox, classify_services  # noqa: E402


class RegistryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        self.registry = self.root / "service" / "registry"
        self.registry.mkdir(parents=True)
        (self.registry / "owner.log").write_bytes(b"original data\x00unchanged")
        self.backup = self.root / "tour-state"
        self.stops = 0

    def tearDown(self):
        self.temp.cleanup()

    def stop(self):
        self.stops += 1

    def test_restores_original_after_synthetic_use_and_reset(self):
        with RegistrySandbox(self.registry, self.backup, self.stop) as sandbox:
            self.assertEqual(list(self.registry.iterdir()), [])
            (self.registry / "demo.log").write_text("synthetic")
            sandbox.reset()
            self.assertEqual(list(self.registry.iterdir()), [])
            self.assertTrue((self.backup / "registry" / "owner.log").is_file())
        self.assertEqual((self.registry / "owner.log").read_bytes(), b"original data\x00unchanged")
        self.assertFalse((self.registry / "demo.log").exists())
        self.assertFalse(self.backup.exists())
        self.assertGreaterEqual(self.stops, 3)

    def test_restores_on_capture_exception(self):
        with self.assertRaisesRegex(RuntimeError, "capture failed"):
            with RegistrySandbox(self.registry, self.backup, self.stop):
                (self.registry / "demo.log").write_text("synthetic")
                raise RuntimeError("capture failed")
        self.assertEqual((self.registry / "owner.log").read_bytes(), b"original data\x00unchanged")
        self.assertFalse(self.backup.exists())

    def test_absence_is_restored_too(self):
        (self.registry / "owner.log").unlink()
        self.registry.rmdir()
        with RegistrySandbox(self.registry, self.backup, self.stop):
            self.assertTrue(self.registry.is_dir())
        self.assertFalse(self.registry.exists())

    def test_an_existing_backup_is_never_overwritten(self):
        self.backup.mkdir()
        (self.backup / "receipt.json").write_text("keep")
        with self.assertRaises(RuntimeError):
            with RegistrySandbox(self.registry, self.backup, self.stop):
                self.fail("should have refused")
        self.assertEqual((self.backup / "receipt.json").read_text(), "keep")
        self.assertTrue((self.registry / "owner.log").is_file())

    def test_symlink_registry_is_refused(self):
        target = self.root / "linked"
        target.symlink_to(self.registry, target_is_directory=True)
        with self.assertRaises(RuntimeError):
            with RegistrySandbox(target, self.backup, self.stop):
                self.fail("should have refused")
        self.assertFalse(self.backup.exists())

    def test_failed_stop_keeps_original_backup(self):
        allowed = [True]
        def stop():
            if not allowed[0]:
                raise RuntimeError("service still running")
        with self.assertRaisesRegex(RuntimeError, "still running"):
            with RegistrySandbox(self.registry, self.backup, stop):
                allowed[0] = False
        self.assertEqual((self.backup / "registry" / "owner.log").read_bytes(), b"original data\x00unchanged")
        self.assertTrue((self.backup / "receipt.json").exists())

    def test_only_exact_test_bundle_service_is_owned(self):
        app = pathlib.Path("/Users/test/XDictE2E/XDict.app")
        table = "41 /Users/test/XDictE2E/XDict.app/Contents/XPCServices/ai.xdict.app.DictionaryService.xpc/Contents/MacOS/XDictService\n42 /Applications/XDict.app/Contents/XPCServices/ai.xdict.app.DictionaryService.xpc/Contents/MacOS/XDictService\n43 /usr/bin/other\n"
        owned, foreign = classify_services(table, app)
        self.assertEqual(owned, [41])
        self.assertEqual(foreign, [42])


if __name__ == "__main__":
    unittest.main()
