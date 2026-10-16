#!/bin/bash
# Tests of Tools/e2e-run.sh: what `make e2e` selects (only what changed since its last pass, FULL=1, STAGES=) and how a
# run is split over the two E2E Macs. Reaches no host: `select` reads this checkout and a scratch gate cache, `split`
# is pure.
set -uo pipefail
cd "$(dirname "$0")/../.."
run=Tools/e2e-run.sh
failures=0
ok() { echo "ok    $*"; }
bad() { echo "FAIL  $*"; failures=$((failures + 1)); }
scratch=$(mktemp -d)
saved=""
[ ! -f .build/e2e-selection.tsv ] || { saved=$scratch/selection; cp .build/e2e-selection.tsv "$saved"; }
trap 'if [ -n "$saved" ]; then cp "$saved" .build/e2e-selection.tsv; else rm -f .build/e2e-selection.tsv; fi; rm -rf "$scratch"' EXIT
export XDICT_GATE_CACHE=$scratch/cache XDICT_E2E_CORPUS= XDICT_E2E_STAGES= XDICT_E2E_FULL=
defaults=$(bash Tools/e2e-plan.sh substages | sort | tr '\n' ' ')

bash $run pending 2>/dev/null | grep -q '^E2E suggested: .* — .*no pass recorded' && ok "pending names what has no pass" \
    || bad "pending with no record: $(bash $run pending 2>&1 | tail -1)"
got=$(bash $run select 2>"$scratch/err" | sort | tr '\n' ' ')
[ "$got" = "$defaults" ] && ok "no record: every default sub-stage" || bad "no record: [$got]"
grep -q 'run: no pass recorded' "$scratch/err" && ok "each says why it runs" || bad "no reason: $(head -3 "$scratch/err")"

# Every one passes: the next selection is empty.
while IFS=$'\t' read -r sub key; do
    [ "$sub" = tree ] || python3 -I Tools/gate-cache.py record "e2e:$sub" "$key" 1 test || bad "record $sub"
done <.build/e2e-selection.tsv
if got=$(bash $run select 2>"$scratch/err"); then
    [ -z "$got" ] && ok "an unchanged tree selects nothing" || bad "unchanged tree selected [$got]"
else bad "select failed: $(tail -2 "$scratch/err")"; fi
grep -q 'skipped: unchanged since pass 20' "$scratch/err" && ok "a skip names its pass's date" || bad "skip line: $(head -2 "$scratch/err")"
[ "$(bash $run pending 2>/dev/null)" = "E2E: nothing pending" ] && ok "pending: nothing, after every pass" \
    || bad "pending after passes: $(bash $run pending 2>&1)"

got=$(XDICT_E2E_FULL=1 bash $run select 2>/dev/null | sort | tr '\n' ' ')
[ "$got" = "$defaults" ] && ok "FULL=1 selects every default sub-stage" || bad "FULL=1: [$got]"
got=$(XDICT_E2E_STAGES="hostile.faults lookup" bash $run select 2>"$scratch/err" | tr '\n' ' ')
[ "$got" = "hostile.faults lookup.core lookup.a11y lookup.paging " ] && grep -q 'forced' "$scratch/err" \
    && ok "STAGES= is forced, whatever passed" || bad "STAGES: [$got]"

echo 'not a record line' >>"$scratch/cache/passes.tsv"
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
