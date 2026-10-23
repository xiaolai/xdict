"""A native search target must be inside its window and every scrolling viewport."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("visibility", Path(__file__).resolve().parents[1] / "ui-tour" / "visibility.py")
visibility = importlib.util.module_from_spec(spec)
spec.loader.exec_module(visibility)


class VisibilityTests(unittest.TestCase):
    def tree(self, target):
        return {"windows": [{"role": "AXWindow", "frame": [100, 100, 800, 592], "children": [
            {"role": "AXScrollArea", "frame": [300, 132, 600, 560], "children": [target]}]}]}

    def target(self, frame, role="AXTextArea"):
        return {"identifier": "ai.prompt.advanced", "role": role, "frame": frame}

    def test_offscreen_expanded_prompt_is_not_revealed(self):
        self.assertFalse(visibility.visible(self.tree(self.target([330, 925, 540, 176])), "ai.prompt.advanced", "AXTextArea"))

    def test_visible_editor_is_revealed(self):
        self.assertTrue(visibility.visible(self.tree(self.target([330, 240, 540, 176])), "ai.prompt.advanced", "AXTextArea"))

    def test_partially_clipped_target_is_not_reachable(self):
        self.assertFalse(visibility.visible(self.tree(self.target([330, 650, 540, 176])), "ai.prompt.advanced", "AXTextArea"))

    def test_role_disambiguates_inherited_identifier(self):
        self.assertFalse(visibility.visible(self.tree(self.target([330, 240, 540, 16], "AXDisclosureTriangle")), "ai.prompt.advanced", "AXTextArea"))

    def test_sheet_has_its_own_viewport_beyond_parent(self):
        tree={"windows": [{"role": "AXWindow", "frame": [100, 100, 400, 300], "children": [
            {"role": "AXSheet", "frame": [130, 152, 340, 480], "children": [self.target([160, 420, 200, 176])]}]}]}
        self.assertTrue(visibility.visible(tree, "ai.prompt.advanced", "AXTextArea"))

    def test_pane_must_fill_its_native_column(self):
        narrow={"windows": [{"role": "AXWindow", "frame": [460, 160, 1180, 760], "children": [
            {"role": "AXGroup", "frame": [1300, 160, 340, 760], "children": [
                {"role": "AXScrollArea", "identifier": "meaning.pane", "frame": [1340, 212, 260, 708]}]}]}]}
        self.assertFalse(visibility.fills_container(narrow, "meaning.pane"))
        narrow["windows"][0]["children"][0]["children"][0]["frame"]=[1300, 212, 340, 708]
        self.assertTrue(visibility.fills_container(narrow, "meaning.pane"))

    def test_missing_frame_or_target_is_not_accepted(self):
        self.assertFalse(visibility.visible(self.tree({"identifier": "ai.prompt.advanced", "role": "AXTextArea"}), "ai.prompt.advanced", "AXTextArea"))
        self.assertFalse(visibility.visible(self.tree(self.target([330, 240, 540, 176])), "missing", "AXTextArea"))

    def test_ancestor_scroll_clip_is_checked(self):
        tree=self.tree({"role": "AXScrollArea", "frame": [320, 240, 550, 80], "children": [self.target([330, 260, 540, 176])]})
        self.assertFalse(visibility.visible(tree, "ai.prompt.advanced", "AXTextArea"))


if __name__ == "__main__":
    unittest.main()
