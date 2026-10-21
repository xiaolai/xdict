#!/usr/bin/env python3
"""The E2E harness's own two failures of 2026-10-21, held so they cannot come back silently.

1. A stage that died part-way filed its `RESULT <stage> fail` row from the EXIT trap but never counted it, and a
   trap's last command is the shell's exit status — so a red run exited 0. The release gate reads the ledger, but a
   green exit on a red run is how a reader stops believing the colour.
2. The setup stage expanded an array that is legitimately empty (`language` in the `first` phase) as `"${language[@]}"`
   under `set -u`. bash 3.2 — /bin/bash on the Air and on the E2E Mac — calls that an unbound variable and kills the
   script at that line.

Both are read off `Tools/e2e.sh`, the one source of the remote run script; each check has a control that plants the old
shape and must see it named. Run by `make test-tools`.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HARNESS = ROOT / "Tools/e2e.sh"
failures = 0


def ok(message):
    print(f"ok    {message}")


def bad(message):
    global failures
    print(f"FAIL  {message}")
    failures += 1


def problems(text):
    """What is wrong with this harness text, named; empty is the only good answer."""
    found = []
    stopped = re.search(r'if \[ "\$finished" != true \]; then(?P<body>.*?)\n    fi', text, re.S)
    if not stopped:
        found.append("the EXIT trap has no stopped-stage branch")
    elif "failures=$((failures + 1))" not in stopped.group("body"):
        found.append("a stage that died part-way is written but not counted, so the run can exit 0")
    if re.search(r'(?<!\+)"\$\{language\[@\]\}"', text):
        found.append("an empty array expanded under set -u kills bash 3.2 (the setup stage's language array)")
    return found


def main():
    text = HARNESS.read_text(encoding="utf-8")
    # The premise: the trap and the setup call are read. A scan over a file without them holds nothing.
    if "on_exit()" not in text or "--setup-report" not in text:
        bad("Tools/e2e.sh was not read whole: no on_exit or no setup call in it")
    got = problems(text)
    if got:
        for problem in got:
            bad(problem)
    else:
        ok("a stage that dies part-way is counted, so a red run exits non-zero")
        ok("the setup stage never expands an empty array under set -u")

    # The controls: the shapes this guards against are named, and a correct one passes.
    old = """
    if [ "$finished" != true ]; then
        echo "FAIL  $STAGE"
        printf 'RESULT\\t%s\\tfail\\n' "$STAGE"
    fi
    open --args "${language[@]}"
    """
    want = ["a stage that died part-way is written but not counted, so the run can exit 0",
            "an empty array expanded under set -u kills bash 3.2 (the setup stage's language array)"]
    got = problems(old)
    if got == want:
        ok("the control's two old shapes are both named")
    else:
        bad(f"the control named {got}, not {want}")
    good = """
    if [ "$finished" != true ]; then
        printf 'RESULT\\t%s\\tfail\\n' "$STAGE"
        failures=$((failures + 1))
    fi
    open --args ${language[@]+"${language[@]}"}
    """
    if problems(good) == []:
        ok("the corrected shapes pass")
    else:
        bad(f"a corrected shape was refused: {problems(good)}")

    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
