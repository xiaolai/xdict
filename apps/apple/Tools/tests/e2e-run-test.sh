#!/bin/bash
# Tests of Tools/e2e-run.sh: what `make e2e` selects (only what has no pass for its key in the E2E ledger, FULL=1,
# STAGES=), and that a run refuses, running nothing, when another project's XCTest holds the E2E Mac past the wait
# (XDICT_HOST_LOCK_WAIT; 2026-11-05). Reaches no host: `select` reads this checkout, a scratch ledger and facts given by
# the environment; `run`'s ssh and sleep are stand-ins, and E2E stays refused (CLAUDECODE=1, no E2E_REQUESTED).
set -uo pipefail
cd "$(dirname "$0")/../.."
run=Tools/e2e-run.sh
failures=0
ok() { echo "ok    $*"; }
bad() { echo "FAIL  $*"; failures=$((failures + 1)); }
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export XDICT_E2E_LEDGER=$scratch/ledger/e2e-ledger.tsv XDICT_E2E_CORPUS= XDICT_E2E_STAGES= XDICT_E2E_FULL= \
    XDICT_E2E_RELEASE_NEEDED= XDICT_FACT_XCODE=27.1 XDICT_FACT_SWIFT=6.3 XDICT_FACT_RUST=1.99.0 XDICT_FACT_MACOS=25A1
# A bundle as its build names itself (Tools/build-bundle.sh's Provenance.txt), of this very tree.
mkdir -p "$scratch/XDict.app/Contents/Resources"
printf 'tree=%s\nxcode=27.1\nswift=6.3\nrust=1.99.0\n' "$(Tools/source-tree.sh)" >"$scratch/XDict.app/Contents/Resources/Provenance.txt"
defaults=$(bash Tools/e2e-plan.sh substages | sort | tr '\n' ' ')

bash $run pending 2>/dev/null | grep -q '^E2E suggested: .* — .*no pass for their key' && ok "pending names what has no pass" \
    || bad "pending with no record: $(bash $run pending 2>&1 | tail -1)"
got=$(bash $run select 2>"$scratch/err" | sort | tr '\n' ' ')
[ "$got" = "$defaults" ] && ok "no record: every default sub-stage" || bad "no record: [$got]"
grep -q 'run: no row for it' "$scratch/err" && ok "each says why it runs" || bad "no reason: $(head -3 "$scratch/err")"

# Every one passes, as Tools/e2e.sh files it: the next selection is empty.
bash Tools/e2e-plan.sh table | awk -F'\t' -v d=" $defaults" 'index(d, " " $1 " ") { print "RESULT\t" $1 "\tpass\t" $5; t[$1] = 1 }
    END { for (s in t) print "TIME\t" s "\t5" }' >"$scratch/run.log"
bash Tools/e2e-status.sh record 1.2 HOSTUUID "27.0 (25A1)" "$(Tools/source-tree.sh)" development "$scratch/XDict.app" \
    <"$scratch/run.log" >/dev/null || bad "record failed"
if got=$(bash $run select 2>"$scratch/err"); then
    [ -z "$got" ] && ok "an unchanged tree selects nothing" || bad "unchanged tree selected [$got]"
else bad "select failed: $(tail -2 "$scratch/err")"; fi
grep -q 'skipped: carried 20' "$scratch/err" && ok "a skip names its pass's date" || bad "skip line: $(head -2 "$scratch/err")"
got=$(XDICT_FACT_MACOS=25A2 bash $run select 2>/dev/null | sort | tr '\n' ' ')
[ "$got" = "$defaults" ] && ok "another macOS build on the E2E Mac selects all" || bad "macOS build: [$got]"
[ "$(bash $run pending 2>/dev/null)" = "E2E: nothing pending" ] && ok "pending: nothing, after every pass" \
    || bad "pending after passes: $(bash $run pending 2>&1)"

got=$(XDICT_E2E_FULL=1 bash $run select 2>/dev/null | sort | tr '\n' ' ')
[ "$got" = "$defaults" ] && ok "FULL=1 selects every default sub-stage" || bad "FULL=1: [$got]"
got=$(XDICT_E2E_STAGES="hostile.faults lookup" bash $run select 2>"$scratch/err" | tr '\n' ' ')
[ "$got" = "hostile.faults lookup.core lookup.a11y lookup.paging " ] && grep -q 'forced' "$scratch/err" \
    && ok "STAGES= is forced, whatever passed" || bad "STAGES: [$got]"

echo 'not a record line' >>"$XDICT_E2E_LEDGER"
got=$(bash $run select 2>"$scratch/err" | sort | tr '\n' ' ')
[ "$got" = "$defaults" ] && grep -q corrupt "$scratch/err" && ok "a corrupt cache selects all, loudly" \
    || bad "corrupt: [$got] $(head -2 "$scratch/err")"

# A busy E2E Mac: ssh always answers with another project's XCTest, sleep returns at once. Given no time to wait, the
# run refuses after one look and never reaches Tools/e2e.sh (whose own refusal under CLAUDECODE=1 would say so).
mkdir -p "$scratch/busy"
printf '#!/bin/bash\necho "ssh $*" >>"%s/busy/called"\necho "4242 xctest"\n' "$scratch" >"$scratch/busy/ssh"
printf '#!/bin/bash\nexit 0\n' >"$scratch/busy/sleep"
chmod +x "$scratch/busy/ssh" "$scratch/busy/sleep"
out=$(unset E2E_REQUESTED; PATH=$scratch/busy:$PATH CLAUDECODE=1 XDICT_HOST_LOCK_WAIT=0 XDICT_E2E_HOST=busy-host \
    bash $run run launch 2>&1); status=$?
if [ "$status" != 0 ] && grep -q 'still runs XCTest after 0 s .*nothing was run' <<<"$out"; then
    ok "a Mac busy past the wait is refused, loudly"
else bad "busy Mac: exit $status: $(tail -2 <<<"$out")"; fi
grep -q 'E2E is off by default' <<<"$out" && bad "it went ahead to Tools/e2e.sh" || ok "nothing was run after the wait"
[ "$(grep -c . "$scratch/busy/called" 2>/dev/null)" = 1 ] && ok "no time to wait: one look, no loop" \
    || bad "ssh called $(grep -c . "$scratch/busy/called" 2>/dev/null) times"
out=$(XDICT_HOST_LOCK_WAIT=soon XDICT_E2E_HOST=busy-host PATH=$scratch/busy:$PATH bash $run run launch 2>&1) \
    && bad "a wait that is not a number was taken" || { grep -q 'not a number' <<<"$out" && ok "a wait that is not a number is refused" \
    || bad "bad wait: $out"; }
grep -nE 'XDICT_E2E_SPLIT|XDICT_E2E_HOST_2|E2E_HOST_MACOS_2|^split\(\)|split\) shift' "$run" Makefile \
    && bad "split mode is still there" || ok "no split mode is left"

[ "$failures" -eq 0 ] && echo "e2e-run: all passed" || { echo "e2e-run: $failures failed"; exit 1; }
