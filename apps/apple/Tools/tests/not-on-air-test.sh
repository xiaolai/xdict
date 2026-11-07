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
# No model name (system_profiler printed none, XDICT_HW_MODEL unset): refused, not taken for "not an Air" (2026-11-05).
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
printf '#!/bin/bash\nexit 0\n' >"$scratch/system_profiler"
chmod +x "$scratch/system_profiler"
out=$(unset XDICT_HW_MODEL; PATH=$scratch:$PATH bash Tools/not-on-air.sh 2>&1); got=$?
if [ "$got" = 2 ] && grep -q 'could not read this Mac' <<<"$out"; then echo "ok: no model name is refused"
else echo "FAIL: no model name: exit $got, want 2 with its sentence: $out"; fail=1; fi
# Every local compile or test target runs the guard first.
for t in lint core test-swift test-tools strings; do
    if make -n "$t" BUILD_HOST= 2>/dev/null | head -1 | grep -q 'Tools/not-on-air.sh'; then echo "ok: $t is guarded"
    else echo "FAIL: $t does not run Tools/not-on-air.sh first"; fail=1; fi
done
exit $fail
