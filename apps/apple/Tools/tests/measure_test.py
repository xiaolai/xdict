#!/usr/bin/env python3
"""The WI-10 measurement's arithmetic (Tools/measure/stats.py): nearest-rank percentiles, overhead subtraction,
invalid samples, the verdict and the report."""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "measure"))
import stats  # noqa: E402


def sample(serial, key, paint, overhead=0.0, **extra):
    return {"serial": serial, "query": f"w{serial}", "keyAt": key, "paintAt": paint, "overheadSeconds": overhead, **extra}


class Percentiles(unittest.TestCase):
    def test_nearest_rank(self):
        values = list(range(1, 201))  # 1..200
        self.assertEqual(stats.percentile(values, 95), 190)
        self.assertEqual(stats.percentile(values, 50), 100)
        self.assertEqual(stats.percentile(list(range(1, 21)), 95), 19)
        self.assertEqual(stats.percentile([7], 95), 7)

    def test_order_does_not_matter(self):
        self.assertEqual(stats.percentile([5, 1, 4, 2, 3], 50), 3)

    def test_empty_and_out_of_range_refused(self):
        with self.assertRaises(ValueError):
            stats.percentile([], 50)
        with self.assertRaises(ValueError):
            stats.percentile([1], 0)


class Overhead(unittest.TestCase):
    def test_subtracted_per_sample(self):
        latencies, raw, invalid = stats.corrected([sample(1, 100.0, 100.250, 0.010)])
        self.assertAlmostEqual(latencies[0], 0.240)
        self.assertAlmostEqual(raw[0], 0.250)
        self.assertEqual(invalid, [])

    def test_invalid_named_not_timed(self):
        samples = [sample(1, 10.0, None, error="WebKit reported no first-contentful-paint"),
                   sample(2, 10.0, 10.5, stale=True), sample(3, 10.0, 10.001, 0.01), sample(4, 10.0, 10.2)]
        latencies, _, invalid = stats.corrected(samples)
        self.assertEqual(len(latencies), 1)
        self.assertEqual(len(invalid), 3)
        self.assertIn("#2", invalid[1])
        self.assertIn("negative", invalid[2])


class Verdict(unittest.TestCase):
    def test_pass_and_each_failure(self):
        warm = stats.summary([0.2] * 200)
        cold = stats.summary([1.5] * 20)
        self.assertTrue(stats.lookup_verdict(warm, cold)[0])
        slow = stats.summary([0.2] * 189 + [1.2] * 11)  # the 190th is 1.2
        passed, why = stats.lookup_verdict(slow, cold)
        self.assertFalse(passed)
        self.assertIn("over 1.0 s", why)
        self.assertFalse(stats.lookup_verdict(stats.summary([0.2] * 199), cold)[0])
        self.assertFalse(stats.lookup_verdict(warm, stats.summary([1.0] * 19))[0])

    def test_boundary_is_within(self):
        self.assertTrue(stats.lookup_verdict(stats.summary([1.0] * 200), stats.summary([1.0] * 20))[0])


class Report(unittest.TestCase):
    def test_table(self):
        text = stats.report([("typed lookup, warm", stats.summary([0.1, 0.2]), 0.0004),
                             ("panel", stats.summary([]), None)])
        lines = text.splitlines()
        self.assertEqual(len(lines), 3)
        self.assertIn("200.0 ms", lines[1])
        self.assertIn("0.4 ms", lines[1])
        self.assertIn("—", lines[2])


if __name__ == "__main__":
    unittest.main(verbosity=0)
