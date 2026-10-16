#!/bin/bash
# The end-to-end plan's own tests: the sub-stages' checks against the full run's (`e2e-plan.sh coverage`), what names
# select (`expand`, `only`), what a change selects (`Tools/e2e-affected.sh`), and that `Tools/e2e.sh` lists what the plan
# says. Each gate is also shown failing on input made to fail it. Runs nothing remote and opens nothing: `make test`.
set -euo pipefail
cd "$(dirname "$0")/.."
plan=./e2e-plan.sh
affected=./e2e-affected.sh
failures=0
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
ok() { echo "ok    $*"; }
bad() { echo "FAIL  $*"; failures=$((failures + 1)); }
# same <what> <expected> <got>
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$(tr '\n' ' ' <<<"$2")], got [$(tr '\n' ' ' <<<"$3")]"; fi; }
# refuses <what> <command...>: the command must fail.
refuses() { local what=$1; shift; if "$@" >"$scratch/out" 2>&1; then bad "$what: passed ($(head -c 200 "$scratch/out"))"; else ok "$what"; fi; }
lines() { printf '%s\n' "$@"; }

# --- coverage --------------------------------------------------------------------------------------------------------
if out=$(bash $plan coverage tests/e2e-checks-baseline.txt 2>&1); then ok "coverage: $out"; else bad "coverage: $out"; fi
# The control: one check dropped from every sub-stage must go red, and name it.
sed 's/ kill\.typedError / /' e2e-substages.txt >"$scratch/dropped.txt"
! grep -q 'kill\.typedError' "$scratch/dropped.txt" || bad "the coverage control's edit did not apply"
if out=$(XDICT_E2E_SUBSTAGES=$scratch/dropped.txt bash $plan coverage tests/e2e-checks-baseline.txt 2>&1); then
    bad "coverage with kill.typedError dropped passed"
else
    case $out in *"in no sub-stage: kill.typedError "*) ok "coverage control: a dropped check goes red ($out)" ;;
        *) bad "coverage control failed without naming the check: $out" ;; esac
fi
# A check in two sub-stages is red too.
awk '{ print } /^@ launch / { getline; print $0 " conformance.tiny" }' e2e-substages.txt >"$scratch/twice.txt"
refuses "coverage control: a check in two sub-stages goes red" \
    env XDICT_E2E_SUBSTAGES="$scratch/twice.txt" bash $plan coverage tests/e2e-checks-baseline.txt

# --- names -----------------------------------------------------------------------------------------------------------
same "a bare stage means its default sub-stages" \
    "$(lines hostile.binding hostile.faults hostile.production hostile.app hostile.controls)" "$(bash $plan expand hostile)"
same "entries' default leaves out the quick sample and the lab" "$(lines entries.persistence entries.full)" \
    "$(bash $plan expand entries)"
same "a stage with no parts is its own sub-stage" "launch" "$(bash $plan expand launch)"
same "names run in the catalog's order, each once" "$(lines launch service.conformance lookup.paging)" \
    "$(bash $plan expand lookup.paging launch service.conformance launch)"
same "no name means every default sub-stage" "$(bash $plan substages)" "$(bash $plan expand)"
same "all adds the extra ones" "$(bash $plan substages --all)" "$(bash $plan expand all)"
refuses "an unknown stage is refused" bash $plan expand hostil
refuses "an unknown sub-stage is refused" bash $plan expand hostile.prod
same "E2E_ONLY's checks select their owners" "$(lines service.recovery lookup.paging)" \
    "$(bash $plan only paging.everyRecord,kill.typedError)"
refuses "an unknown check is refused" bash $plan only paging.everything
same "what sub-stages need" "$(lines corpus editions)" "$(bash $plan needs library.corpus library.control)"

# --- what a change selects (Tools/affected_graph.py: the generated graph and the hand list) -------------------------
# Sub-stages by what they launch (Tools/e2e.sh): the lab's, and the app's (the app and its service).
lab_subs=$(lines hostile.binding hostile.faults reader hostile.production hostile.controls entries.lab)
has() { case " $(tr '\n' ' ' <<<"$2") " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
none_of() { local s; for s in $1; do has "$s" "$2" && return 1; done; return 0; }
everything=$(bash $plan substages --all)

got=$(bash $affected --paths apps/apple/Sources/XDictEntryView/EntryWebView.swift)
has hostile.production "$got" && ok "an XDictEntryView change selects hostile.production" \
    || bad "an XDictEntryView change did not select hostile.production: $got"
same "a crate the service links is every sub-stage" "$everything" "$(bash $affected --paths core/xdict-mdx/src/lib.rs)"
same "an unmapped path selects every default sub-stage" "$(bash $plan substages)" \
    "$(bash $affected --paths apps/apple/no-rule-names-this.file)"
# The service is in the app's bundle, not in the lab (which links the core itself).
got=$(bash $affected --paths apps/apple/Sources/XDictService/Service.swift)
if none_of "$lab_subs" "$got" && has launch "$got" && has service.conformance "$got"; then
    ok "the service's code selects the app's sub-stages, not the lab's"
else bad "the service's code: $got"; fi
same "notes and unit tests select nothing" "" \
    "$(bash $affected --paths README.md dev-docs/plan.md apps/apple/Tests/XDictTests/X.swift core/xdict-mdx/tests/t.rs)"
got=$(bash $affected --paths apps/apple/Tools/hostile/analyze.py)
has hostile.controls "$got" && ok "the analyzer's change brings the hostile controls" \
    || bad "the analyzer's change did not bring hostile.controls: $got"
# The gallery's Swift is compiled into the lab, so it reaches the lab's sub-stages (the hand map said none: 2026-10-16,
# it had selected hostile.controls); its scripts reach nothing.
same "the gallery's code selects the lab's sub-stages, its scripts nothing" "$lab_subs" \
    "$(bash $affected --paths apps/apple/Sources/XDictEntryLab/Gallery.swift apps/apple/Tools/gallery/run.sh \
        apps/apple/Tools/gallery/page.py)"
# A lookup driver change with small harness edits (ba6e081) ran every sub-stage.
got=$(bash $affected --paths apps/apple/Makefile apps/apple/Tools/build-lab.sh apps/apple/Tools/e2e.sh \
    apps/apple/Tools/lookup/drive.py apps/apple/Tools/lookup/typing_check.py apps/apple/Tools/tests/lookup_typing_test.py)
if none_of "sound.speech library.generated hostile.controls" "$got" && has launch "$got" && has lookup.core "$got"; then
    ok "a driver change with harness edits selects a smoke set and its own stage"
else bad "a driver change with harness edits: $got"; fi
same "a lookup driver change selects only lookup" "$(lines lookup.core lookup.a11y lookup.paging)" \
    "$(bash $affected --paths apps/apple/Tools/lookup/drive.py)"
got=$(bash $affected --paths apps/apple/Sources/XDictEntryView/EntryRuleList.swift)
has hostile.controls "$got" && ok "a confinement layer's change brings the hostile controls" \
    || bad "a confinement layer's change did not bring hostile.controls: $got"

# The graph's own cases (2026-10-17), each shown red once against the control below it.
# 1. A core crate nothing on the Apple side links, and one only the fixtures build, select no Swift-only sub-stage.
same "an xdict-wasm change selects no sub-stage" "" "$(bash $affected --paths core/xdict-wasm/src/lib.rs)"
got=$(bash $affected --paths core/xdict-mdx-writer/src/lib.rs)
if ! has launch "$got" && has service.conformance "$got"; then
    ok "a fixtures-only crate selects what reads fixtures, not launch (which links only the app and the service)"
else bad "a fixtures-only crate: $got"; fi
# 2. XDictSearch is the app's: none of the lab's hostile sub-stages (hostile.app types into its window, so it stays).
got=$(bash $affected --paths apps/apple/Sources/XDictSearch/SearchModel.swift)
if none_of "$lab_subs" "$got" && has hostile.app "$got"; then ok "an XDictSearch change selects no lab hostile sub-stage"
else bad "an XDictSearch change: $got"; fi
# 3. The package manifest is the Swift graph itself.
same "a Package.swift change selects everything" "$(bash $plan substages)" \
    "$(bash $affected --paths apps/apple/Package.swift)"
# Their controls: a graph or hand list made wrong must turn each red.
python3 -I - affected-graph.json "$scratch/wrong.json" <<'PY'
import json, sys
g = json.load(open(sys.argv[1]))
g["targets"]["XDictEntryLab"]["deps"].append("XDictSearch")
g["crates"]["xdict-ffi"]["deps"].append("xdict-wasm")
json.dump(g, open(sys.argv[2], "w"))
PY
got=$(XDICT_AFFECTED_GRAPH=$scratch/wrong.json bash $affected --paths core/xdict-wasm/src/lib.rs 2>/dev/null)
[ -n "$got" ] && ok "control: an xdict-wasm the core linked would select sub-stages" || bad "control 1 stayed green"
got=$(XDICT_AFFECTED_GRAPH=$scratch/wrong.json bash $affected --paths apps/apple/Sources/XDictSearch/SearchModel.swift 2>/dev/null)
has hostile.production "$got" && ok "control: an XDictSearch the lab linked would select hostile.production" \
    || bad "control 2 stayed green: $got"
sed 's|^apps/apple/Package.swift .*|apps/apple/Package.swift none|' affected-hand.map >"$scratch/wrong.map"
got=$(XDICT_AFFECTED_HAND=$scratch/wrong.map bash $affected --paths apps/apple/Package.swift)
[ -z "$got" ] && ok "control: a hand list saying none for Package.swift selects nothing" || bad "control 3 stayed green: $got"

# Every name the hand list uses is a sub-stage, a stage or a node the graph has (the module refuses one that is not).
names=$(awk '/^[[:space:]]*(#|$)/ { next } $1 == "control" { print $2; print $3; next } $1 ~ /^(launches|builds|binary)$/ { next }
    { for (i = 2; i <= NF; i++) { n = $i; sub(/^check:/, "", n); if (n != "none" && n != "all" && n !~ /:/) print n } }' \
    affected-hand.map | sort -u)
# shellcheck disable=SC2086 # names, split on purpose
if bash $plan expand $names >/dev/null 2>"$scratch/why"; then ok "every name in the hand list is a sub-stage or a stage"
else bad "the hand list names what is no sub-stage: $(cat "$scratch/why")"; fi
# The control of the fail-safe: a hand list whose last rule takes every path selects only what it says.
{ cat affected-hand.map; echo "*  launch"; } >"$scratch/catch-all.map"
same "hand list control: a catch-all rule overrides the fail-safe (so the fail-safe is what selected everything)" "launch" \
    "$(XDICT_AFFECTED_HAND=$scratch/catch-all.map bash $affected --paths apps/apple/no-rule-names-this.file)"

# --- the harness lists what the plan says ----------------------------------------------------------------------------
same "e2e.sh --list-stages is the plan's default sub-stages (what a release requires)" "$(bash $plan substages)" \
    "$(./e2e.sh --list-stages)"

echo
[ "$failures" -eq 0 ] && echo "e2e-plan-test: all passed" || { echo "e2e-plan-test: $failures failed"; exit 1; }
