#!/bin/bash
# E2E is off by default (owner, 2026-10-17): from an agent's shell (CLAUDECODE=1) Tools/e2e.sh refuses unless the run
# was asked for (E2E_REQUESTED=1). The owner's own terminal has no CLAUDECODE and is never stopped.
set -uo pipefail
cd "$(dirname "$0")/../.."
fail=0
check() { # name, want-exit, env...
    local name=$1 want=$2; shift 2
    out=$(env -i PATH="$PATH" HOME="$HOME" "$@" bash Tools/e2e-requested.sh 2>&1); got=$?
    if [ "$got" = "$want" ]; then echo "ok: $name"; else echo "FAIL: $name: exit $got, want $want: $out"; fail=1; fi
}
check "an agent without a request is refused" 2 CLAUDECODE=1
check "an agent with a request runs" 0 CLAUDECODE=1 E2E_REQUESTED=1
check "the owner's terminal runs" 0
check "a request other than 1 is no request" 2 CLAUDECODE=1 E2E_REQUESTED=yes
# Tools/e2e.sh itself must hold the guard, before it touches a host.
out=$(env -i PATH="$PATH" HOME="$HOME" CLAUDECODE=1 bash Tools/e2e.sh nohost launch 2>&1); got=$?
if [ "$got" = 2 ] && grep -q "E2E is off by default" <<<"$out"; then echo "ok: e2e.sh refuses an unrequested agent run"
else echo "FAIL: e2e.sh ran for an unrequested agent (exit $got): $(head -c 300 <<<"$out")"; fail=1; fi
exit $fail
