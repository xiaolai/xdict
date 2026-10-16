#!/usr/bin/env python3
"""The lookup driver's typing (`Tools/lookup/typing.py`): a key the E2E Mac drops while typing is read back from the
search field and typed again once, holding the front first; a second miss stops the run with one sentence naming what
the field held and who had the front, never as the scenario's checks going unreported.

    python3 -I Tools/tests/lookup_typing_test.py
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lookup"))
import typing_check  # noqa: E402


class Mac:
    """A search field fed by key events, dropping the keys at the positions in `drops` (one list per attempt)."""

    def __init__(self, drops, front="XDict"):
        self.field, self.drops, self.attempt, self.front_name = "", list(drops), 0, front
        self.held, self.selected = 0, False

    def hold(self):
        self.held += 1

    def select_all(self):
        self.selected = True

    def type_keys(self, text):
        lost = self.drops[self.attempt] if self.attempt < len(self.drops) else []
        self.attempt += 1
        typed = "".join(c for i, c in enumerate(text) if i not in lost)
        self.field = typed if self.selected else self.field + typed
        self.selected = False

    def read_field(self):
        return self.field

    def front(self):
        return self.front_name


def run(mac, text="take o"):
    return typing_check.type_and_confirm(text, hold=mac.hold, select_all=mac.select_all, type_keys=mac.type_keys,
                                         read_field=mac.read_field, front=mac.front)


class Typing(unittest.TestCase):
    def test_every_key_arriving_types_once(self):
        mac = Mac([[]])
        self.assertEqual(run(mac), ("take o", 1))
        self.assertEqual(mac.held, 1)

    def test_a_lost_key_is_typed_again_over_a_selected_field(self):
        mac = Mac([[1], []])
        self.assertEqual(run(mac), ("take o", 2))
        self.assertEqual(mac.held, 2, "the front is held again before the second try")

    def test_a_second_loss_names_the_field_and_the_front(self):
        mac = Mac([[1], [3]], front="Safari")
        with self.assertRaises(typing_check.Lost) as said:
            run(mac)
        sentence = str(said.exception)
        self.assertIn("'tke o'", sentence)
        self.assertIn("'tak o'", sentence)
        self.assertIn("Safari", sentence)

    def test_the_field_is_what_counts_not_the_key_count(self):
        mac = Mac([[]])
        mac.type_keys = lambda text: setattr(mac, "field", text + "x")
        with self.assertRaises(typing_check.Lost):
            run(mac)


if __name__ == "__main__":
    unittest.main(verbosity=1)
