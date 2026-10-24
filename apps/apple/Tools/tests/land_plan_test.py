#!/usr/bin/env python3
"""Tests `Tools/land_plan.py`: the gate placement and the lane split.

The lane rule is a correctness rule, not a preference: `lookup-corpus` reads OED's 706,524 keys, and beside
`make test` on one Mac it had macOS kill the WebKit lab's processes mid-suite (2026-10-24, 75 failures that all
pass alone). A host that runs both puts the corpus in the Swift lane after `make test`; a host that runs only
the corpus keeps it in its cargo lane.
"""

import subprocess
import sys
import tempfile
from pathlib import Path

PLAN = Path(__file__).resolve().parent.parent / "land_plan.py"
ALL = ["core", "apple-test", "entries", "lookup-corpus", "mdx-v3", "bindings", "memory"]
failures = []


def plan(todo, hosts, e2e=""):
    with tempfile.TemporaryDirectory() as scratch:
        d = Path(scratch)
        (d / "todo").write_text("\n".join(todo) + "\n", encoding="utf-8")
        (d / "hosts").write_text("".join(f"{h}\t{c}\n" for h, c in hosts.items()), encoding="utf-8")
        return subprocess.run([sys.executable, "-I", str(PLAN), str(d / "todo"), str(d / "hosts"), e2e],
                              capture_output=True, text=True)


def ok(condition, what):
    print(f"ok    {what}" if condition else f"FAIL  {what}")
    if not condition:
        failures.append(what)


def lanes(output):
    table = {}
    for line in output.splitlines():
        if "\t" not in line:
            continue
        gates, host, lane = line.split("\t")
        table.setdefault(host, {}).setdefault(lane, []).extend(gates.split())
    return table


full = plan(ALL, {"mac": "rust,xcode,corpus,run1"})
table = lanes(full.stdout)["mac"]
ok(full.returncode == 0, "a full host plans every gate")
ok(table["swift"] == ["apple-test", "lookup-corpus"],
   "the corpus follows `make test` in the Swift lane, never beside it")
ok("lookup-corpus" not in table["cargo"], "the cargo lane holds no corpus gate when the host runs `make test`")
ok(set(table["cargo"]) == {"core", "entries", "mdx-v3", "bindings", "memory"},
   "the other gates stay in the cargo lane")

split = plan(ALL, {"swift-host": "rust,xcode,run1", "corpus-host": "rust,corpus"})
table = lanes(split.stdout)
ok("lookup-corpus" in table["corpus-host"]["cargo"],
   "a host that runs only the corpus keeps it in its cargo lane")

unfit = plan(["entries"], {"mac": "rust"})
ok(unfit.stdout.strip() == "entries\t-", "a gate no host fits is marked, not placed")

unknown = plan(["new-gate"], {"mac": "rust"})
ok(unknown.returncode == 1 and "no rule for new-gate" in unknown.stderr,
   "a new gate without capabilities is refused, so the planner cannot silently starve it")

if failures:
    print(f"land-plan: {len(failures)} failed")
    sys.exit(1)
print("land-plan: all passed")
