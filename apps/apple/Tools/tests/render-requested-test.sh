#!/bin/bash
# Renders are off by default for agents (owner, 2026-10-18: "改点什么，这就跑一遍，太耽误时间了"): from an agent's shell
# (CLAUDECODE=1) the scripts that open windows on the E2E Mac refuse unless XDICT_RENDER_REQUESTED=1, which only the
# orchestrator sets, once per landing batch. The owner's own terminal is never stopped.
set -uo pipefail
cd "$(dirname "$0")/../.."
fail=0
check() { # name, want-exit, env...
    local name=$1 want=$2; shift 2
    out=$(env -i PATH="$PATH" HOME="$HOME" "$@" bash Tools/render-requested.sh 2>&1); got=$?
    if [ "$got" = "$want" ]; then echo "ok: $name"; else echo "FAIL: $name: exit $got, want $want: $out"; fail=1; fi
}
check "an agent without a request is refused" 2 CLAUDECODE=1
check "a requested batch runs" 0 CLAUDECODE=1 XDICT_RENDER_REQUESTED=1
check "the owner's terminal runs" 0
check "a request other than 1 is no request" 2 CLAUDECODE=1 XDICT_RENDER_REQUESTED=yes
# Each window-opening script refuses before it touches a host.
for s in Tools/gallery/hot.sh Tools/gallery/run.sh Tools/ui-tour/run.sh Tools/gallery/render-affected.sh; do
    out=$(env -i PATH="$PATH" HOME="$HOME" CLAUDECODE=1 E2E_HOST=nohost.invalid bash "$s" oald:apple 2>&1); got=$?
    if [ "$got" = 2 ] && grep -q "renders are off by default" <<<"$out"; then echo "ok: $s refuses an unrequested agent run"
    else echo "FAIL: $s ran for an unrequested agent (exit $got): $(head -c 200 <<<"$out")"; fail=1; fi
done
exit $fail
