"""The WI-10 measurement's arithmetic (plan-macos-v1 WI-10, "Measurement protocol"), kept apart from the driver so it
is tested off the E2E Mac (`Tools/tests/measure_test.py`).

- A typed-lookup sample is `paintAt - keyAt - overheadSeconds` (wall-clock seconds, from `XDict --measure`'s
  `samples.jsonl`). A sample that is `stale` (its document began before the key), has no paint, or comes out negative
  is invalid: counted and named, never timed.
- Percentiles are nearest-rank: the value at rank ceil(p/100 * n) of the sorted samples, so p95 of 200 is the 190th
  and p95 of 20 the 19th; no interpolation, so every quoted value is a real sample.
"""
import math

WARMUP = 10
WARM = 200
COLD = 20
PANEL = 20
WARM_P95_GATE = 1.0  # seconds; XiaolaiDict ux B3


def percentile(values, p):
    """Nearest-rank percentile of `values` (0 < p <= 100); raises on an empty list rather than inventing a number."""
    if not values:
        raise ValueError("no samples")
    if not 0 < p <= 100:
        raise ValueError(f"percentile {p} out of (0, 100]")
    ordered = sorted(values)
    return ordered[max(1, math.ceil(p / 100 * len(ordered))) - 1]


def corrected(samples):
    """(latencies, raw latencies, invalid reasons) of typed-lookup samples, overhead subtracted."""
    latencies, raw, invalid = [], [], []
    for s in samples:
        name = f"#{s.get('serial', '?')} {s.get('query', '?')!r}"
        if s.get("error") or s.get("paintAt") is None:
            invalid.append(f"{name}: {s.get('error') or 'no paint'}")
            continue
        if s.get("stale"):
            invalid.append(f"{name}: the painted document began before the key")
            continue
        whole = s["paintAt"] - s["keyAt"]
        latency = whole - s.get("overheadSeconds", 0.0)
        if latency < 0:
            invalid.append(f"{name}: negative latency {latency:.4f} s")
            continue
        raw.append(whole)
        latencies.append(latency)
    return latencies, raw, invalid


def summary(values):
    """n, p50, p95 and max of a list of seconds; n 0 and None otherwise."""
    if not values:
        return {"n": 0, "p50": None, "p95": None, "max": None}
    return {"n": len(values), "p50": percentile(values, 50), "p95": percentile(values, 95), "max": max(values)}


def lookup_verdict(warm, cold):
    """(passed, sentence): warm needs all 200 valid and p95 within the gate; cold needs all 20 valid (reported)."""
    problems = []
    if warm["n"] != WARM:
        problems.append(f"warm has {warm['n']} valid samples, not {WARM}")
    elif warm["p95"] > WARM_P95_GATE:
        problems.append(f"warm p95 {warm['p95']:.3f} s is over {WARM_P95_GATE} s")
    if cold["n"] != COLD:
        problems.append(f"cold has {cold['n']} valid samples, not {COLD}")
    return not problems, "; ".join(problems) or "within the protocol"


def ms(value):
    return "—" if value is None else f"{value * 1000:.1f} ms"


def report(rows):
    """A fixed-width table of (label, summary, overhead p50 or None) rows, one line each."""
    lines = [f"{'measure':<22} {'n':>4} {'p50':>10} {'p95':>10} {'max':>10} {'overhead p50':>13}"]
    for label, s, overhead in rows:
        lines.append(f"{label:<22} {s['n']:>4} {ms(s['p50']):>10} {ms(s['p95']):>10} {ms(s['max']):>10} "
                     f"{ms(overhead):>13}")
    return "\n".join(lines)
