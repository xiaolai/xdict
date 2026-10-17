#!/bin/bash
# Tests of Tools/e2e-run.sh: what `make e2e` selects (only what has no pass for its key in the E2E ledger, FULL=1,
# STAGES=) and how a run is split over the two E2E Macs. Reaches no host: `select` reads this checkout, a scratch ledger
# and facts given by the environment; `split` is pure.
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
printf -- '--fact\nxcode=27.1\n--fact\nswift=6.3\n--fact\nrust=1.99.0\n' >"$scratch/bundle.facts"
defaults=$(bash Tools/e2e-plan.sh substages | sort | tr '\n' ' ')

bash $run pending 2>/dev/null | grep -q '^E2E suggested: .* — .*no pass for their key' && ok "pending names what has no pass" \
    || bad "pending with no record: $(bash $run pending 2>&1 | tail -1)"
got=$(bash $run select 2>"$scratch/err" | sort | tr '\n' ' ')
[ "$got" = "$defaults" ] && ok "no record: every default sub-stage" || bad "no record: [$got]"
grep -q 'run: no row for it' "$scratch/err" && ok "each says why it runs" || bad "no reason: $(head -3 "$scratch/err")"

# Every one passes, as Tools/e2e.sh files it: the next selection is empty.
for sub in $defaults; do printf 'RESULT\t%s\tpass\nTIME\t%s\t5\n' "$sub" "$sub"; done >"$scratch/run.log"
XDICT_E2E_BUNDLE_FACTS=$scratch/bundle.facts bash Tools/e2e-status.sh record 1.2 HOSTUUID "27.0 (25A1)" \
    "$(Tools/source-tree.sh)" development <"$scratch/run.log" >/dev/null || bad "record failed"
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

# The split: what needs the front stays on the first host; a group stays whole; the rest is balanced.
plan=$(bash $run split launch reader lookup.core lookup.a11y lookup.paging hostile.controls hostile.production \
    entries.full service.idle selection.hosts services.menu library.generated hostile.app)
one=" $(sed -n 1p <<<"$plan" | cut -f1) "; two=" $(sed -n 2p <<<"$plan" | cut -f1) "
front=true
for sub in reader lookup.core lookup.a11y lookup.paging selection.hosts services.menu library.generated; do
    case $one in *" $sub "*) ;; *) front=false ;; esac
done
$front && ok "front and Accessibility sub-stages go to the first host" || bad "front on the second: [$two]"
case $two in *" hostile.controls "*) ok "the longest free sub-stage goes to the lighter host" ;;
    *) bad "hostile.controls not on the second: [$one] [$two]" ;; esac
n=$(( $(wc -w <<<"$one") + $(wc -w <<<"$two") ))
[ "$n" = 13 ] && ok "every sub-stage is placed once" || bad "placed $n of 13"
plan=$(bash $run split reader lookup.core)
[ -z "$(sed -n 2p <<<"$plan" | cut -f1)" ] && ok "front-only work leaves the second host idle" || bad "split [$plan]"

[ "$failures" -eq 0 ] && echo "e2e-run: all passed" || { echo "e2e-run: $failures failed"; exit 1; }
