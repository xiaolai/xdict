#!/bin/bash
# Tests of a sub-stage with no driver in Tools/e2e.sh (plan-capture WI-5 verification): `--drivers` names every asked
# sub-stage whose `substage_<name|group>` is missing and fails, before anything is built or shipped; and the remote
# run, given a group with no driver, records a failing row for every sub-stage of the group and exits 1. Runs the run
# script locally over a plan of its own (no app, no E2E Mac); opens nothing: `make test-tools`.
set -euo pipefail
cd "$(dirname "$0")/.."
failures=0
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
ok() { echo "ok    $*"; }
bad() { echo "FAIL  $*"; failures=$((failures + 1)); }

# --- the preflight -------------------------------------------------------------------------------------------------
if out=$(./e2e.sh --drivers launch setup lookup 2>&1); then ok "drivers: sub-stages with their functions pass ($out)"
else bad "drivers: launch, setup and lookup failed: $out"; fi
if out=$(./e2e.sh --drivers launch hover.accessibility hover.popover 2>&1); then
    bad "drivers: hover, which has no driver, passed: $out"
else
    case $out in *"hover.accessibility"*"substage_hover"*"hover.popover"*"substage_hover"*) ok "drivers: each hover sub-stage named with the missing substage_hover" ;;
        *) bad "drivers: failed without naming every hover sub-stage: $out" ;; esac
    case $out in *"launch"*substage_launch*) bad "drivers: named launch, which has its driver: $out" ;; *) ;; esac
fi
# Its control: a copy of e2e.sh without substage_setup goes red on setup.
mkdir -p "$scratch/control/Tools"
sed 's/^substage_setup() {/substage_setup_gone() {/' e2e.sh >"$scratch/control/Tools/e2e.sh"
grep -q '^substage_setup_gone() {' "$scratch/control/Tools/e2e.sh" || bad "the control's edit did not apply"
cp e2e-plan.sh e2e-substages.txt "$scratch/control/Tools/"
if out=$(bash "$scratch/control/Tools/e2e.sh" --drivers setup 2>&1); then
    bad "drivers control: a script without substage_setup passed: $out"
else
    case $out in *"setup"*"substage_setup"*) ok "drivers control: a missing substage_setup goes red" ;;
        *) bad "drivers control: failed for another reason: $out" ;; esac
fi
# The preflight runs before anything is locked, built or shipped.
first_call=$(grep -n '^check_drivers ' e2e.sh | head -1 | cut -d: -f1 || true)
app_check=$(grep -n 'does not exist; run make app' e2e.sh | head -1 | cut -d: -f1)
lock=$(grep -n '^host_lock ' e2e.sh | head -1 | cut -d: -f1)
if [ -n "$first_call" ] && [ "$first_call" -lt "$app_check" ] && [ "$first_call" -lt "$lock" ]; then
    ok "the run checks its drivers before the bundle and the host lock (line $first_call)"
else
    bad "the run's driver check is missing or comes after the bundle or the lock (${first_call:-none}, $app_check, $lock)"
fi

# --- the remote loop: a group with no driver fails every one of its sub-stages ------------------------------------
awk -v dir="$scratch" '
    /<<'"'"'SH'"'"'/ { inside = 1; n++; file = dir "/remote-" n ".sh"; next }
    inside && /^SH$/ { inside = 0; close(file); next }
    inside { print > file }
' e2e.sh
run=$(grep -l '^WANTED=("\$@")' "$scratch"/remote-*.sh | head -1)
[ -n "$run" ] || bad "the run script was not found in e2e.sh"
cat "$scratch/remote-1.sh" "$run" >"$scratch/run.sh"
mkdir -p "$scratch/home/e2e"
printf 'hover.a\textra\tkit\thover\thover.a.one\nhover.b\textra\tkit\thover\thover.b.one\n' >"$scratch/home/e2e/plan.tsv"
status=0
HOME=$scratch/home bash "$scratch/run.sh" e2e 0 hover.a hover.b >"$scratch/out" 2>&1 || status=$?
[ "$status" -eq 1 ] && ok "a group with no driver: the run exits 1" || bad "a group with no driver: exit $status ($(tail -3 "$scratch/out"))"
for sub in hover.a hover.b; do
    if grep -q "^RESULT	$sub	fail	" "$scratch/out"; then ok "a group with no driver: $sub has a failing row"
    else bad "a group with no driver: $sub has no failing row ($(grep '^RESULT' "$scratch/out" | tr '\n' ' '))"; fi
done

echo
[ "$failures" -eq 0 ] && echo "e2e-drivers-test: all passed" || { echo "e2e-drivers-test: $failures failed"; exit 1; }
