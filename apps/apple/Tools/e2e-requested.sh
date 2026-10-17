#!/bin/bash
# **E2E is off by default** (owner, 2026-10-17: "from now on, all e2e testing by default off, unless explicitly
# requested"). An agent's shell carries CLAUDECODE=1; there an E2E run needs E2E_REQUESTED=1, set only when the owner
# asked for that run. The owner's own terminal has no CLAUDECODE and is never stopped. Sourced by Tools/e2e.sh, run
# alone by Tools/tests/e2e-requested-test.sh.
if [ "${CLAUDECODE:-}" = 1 ] && [ "${E2E_REQUESTED:-}" != 1 ]; then
    echo "e2e: E2E is off by default; an agent runs it only when the owner asked for this run (E2E_REQUESTED=1)." >&2
    echo "e2e: say instead: E2E suggested: <sub-stages> — <why> (make e2e-pending prints it, running nothing)" >&2
    exit 2
fi
