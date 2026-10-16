#!/usr/bin/env python3
"""The anywhere driver's own tests (`Tools/anywhere/hostcondition.py`): a host app that shows no page because of its own
window (Chrome's profile picker, any other non-page window) is named as this Mac's condition, never read as XDict
failing to select. Runs nothing and opens nothing: `make test-tools`.

    python3 -I Tools/tests/anywhere_test.py
"""
import os
import subprocess
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "anywhere"))
import front  # noqa: E402
import hostcondition  # noqa: E402


def no_page(bundle, title):
    return {"error": f'hands: {bundle} shows no text view and no page; its front window is "{title}"'}


class HostCondition(unittest.TestCase):
    def test_chromes_profile_picker_is_named_with_what_to_do(self):
        said = hostcondition.of("chrome", no_page("com.google.Chrome", "Who's using Chrome?"))
        self.assertEqual(said, "Chrome shows its profile picker on this Mac; close it by hand")

    def test_any_other_non_page_window_is_named_by_its_title(self):
        said = hostcondition.of("safari", no_page("com.apple.Safari", "Settings"))
        self.assertEqual(said, "Safari's front window is “Settings”, not a page, on this Mac; close it by hand")

    def test_a_window_with_no_title_is_still_a_host_condition(self):
        said = hostcondition.of("chrome", no_page("com.google.Chrome", ""))
        self.assertEqual(said, "Chrome's front window has no title and is not a page, on this Mac; close it by hand")

    def test_a_page_without_the_phrase_or_any_other_error_stays_the_products(self):
        for raw in [{"error": "hands: the page in com.google.Chrome has no 'abbé'"},
                    {"error": "hands: setting the selection failed: AXError -25200"},
                    {"error": "hands: com.google.Chrome shows no text view and no page"},
                    {"selected": "abbé"}, {}]:
            self.assertIsNone(hostcondition.of("chrome", raw), raw)

    def test_the_failure_line_names_it_as_the_hosts_and_still_fails(self):
        line = hostcondition.detail("chrome", "Chrome shows its profile picker on this Mac; close it by hand")
        self.assertTrue(line.startswith("host condition, not XDict: "))


class FrontHeld(unittest.TestCase):
    """`front.guarded`: a host action that times out, or whose host would not come forward, stops the driver with one
    sentence naming the front app and what it is doing (another project's XCTest run), never as silent non-reports."""

    MOCHI = {"name": "MochiUITests-Runner", "bundle": "com.example.MochiUITests.xctrunner", "pid": 4242}
    XCTEST = ["4240 /usr/bin/xcodebuild test -scheme Mochi", "4242 MochiUITests-Runner.app/Contents/MacOS/xctest"]

    def guarded(self, act):
        return front.guarded("select in Notes", act, front=lambda: self.MOCHI, processes=lambda: self.XCTEST)

    def test_an_action_that_works_is_returned(self):
        self.assertEqual(self.guarded(lambda: {"selected": "abbé"}), {"selected": "abbé"})

    def test_a_timeout_names_the_front_and_its_test_run(self):
        def hung():
            raise subprocess.TimeoutExpired(["hands", "select"], 60)
        with self.assertRaises(front.Stopped) as said:
            self.guarded(hung)
        sentence = str(said.exception)
        self.assertIn("select in Notes timed out after 60 s", sentence)
        self.assertIn("MochiUITests-Runner", sentence)
        self.assertIn("XCTest", sentence)

    def test_a_host_that_would_not_come_forward_names_who_has_the_front(self):
        with self.assertRaises(front.Stopped) as said:
            self.guarded(lambda: {"error": "hands: com.apple.Notes would not come to the front ({...})"})
        self.assertIn("MochiUITests-Runner", str(said.exception))

    def test_any_other_error_is_the_checks_to_judge(self):
        self.assertEqual(self.guarded(lambda: {"error": "hands: the page has no 'abbé'"}),
                         {"error": "hands: the page has no 'abbé'"})


if __name__ == "__main__":
    unittest.main()
