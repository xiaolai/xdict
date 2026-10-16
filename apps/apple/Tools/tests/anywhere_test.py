#!/usr/bin/env python3
"""The anywhere driver's own tests (`Tools/anywhere/hostcondition.py`): a host app that shows no page because of its own
window (Chrome's profile picker, any other non-page window) is named as this Mac's condition, never read as XDict
failing to select. Runs nothing and opens nothing: `make test-tools`.

    python3 -I Tools/tests/anywhere_test.py
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "anywhere"))
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


if __name__ == "__main__":
    unittest.main()
