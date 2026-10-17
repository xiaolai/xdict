#!/bin/bash
# Nothing compiles or tests on the Air (owner, 2026-10-15): every target that would is refused there, loudly, even
# when local.mk is missing (a worktree once fell back to building and testing on the Air, 2026-10-18).
set -uo pipefail
cd "$(dirname "$0")/../.."
fail=0
check() { # name, want-exit, model
    out=$(XDICT_HW_MODEL="$3" bash Tools/not-on-air.sh 2>&1); got=$?
    if [ "$got" = "$2" ]; then echo "ok: $1"; else echo "FAIL: $1: exit $got, want $2: $out"; fail=1; fi
}
check "an Air is refused" 2 "MacBook Air"
check "a MacBook Pro builds" 0 "MacBook Pro"
check "a Mac mini builds" 0 "Mac mini"
# Every local compile or test target runs the guard first.
for t in lint core test-swift test-tools strings; do
    if make -n "$t" BUILD_HOST= 2>/dev/null | head -1 | grep -q 'Tools/not-on-air.sh'; then echo "ok: $t is guarded"
    else echo "FAIL: $t does not run Tools/not-on-air.sh first"; fail=1; fi
done
exit $fail
