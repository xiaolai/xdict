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
# A stage whose sub-stages are all extra is refused as such, naming them, not as a stage that does not exist.
for stage in hover measure; do
    if out=$(bash $plan expand $stage 2>&1); then bad "a stage with only extra sub-stages expanded: $out"
    else case $out in *"no stage called"*) bad "$stage: refused as unknown: $out" ;;
        *"no default sub-stage"*"$stage."*) ok "$stage: refused as a stage with only extra sub-stages, naming them" ;;
        *) bad "$stage: refused without naming its sub-stages: $out" ;; esac; fi
done
out=$(bash $plan expand hostil 2>&1 || true)
case $out in *"no stage called 'hostil'"*) ok "an unknown stage is still called unknown" ;; *) bad "an unknown stage: $out" ;; esac
same "E2E_ONLY's checks select their owners" "$(lines service.recovery lookup.paging)" \
    "$(bash $plan only ax.paging,kill.typedError)"
refuses "an unknown check is refused" bash $plan only paging.everything
same "what sub-stages need" "$(lines corpus editions)" "$(bash $plan needs library.corpus library.control)"

# --- the affected map ------------------------------------------------------------------------------------------------
got=$(bash $affected --paths apps/apple/Sources/XDictEntryView/EntryWebView.swift)
case " $(tr '\n' ' ' <<<"$got") " in *" hostile.production "*) ok "an XDictEntryView change selects hostile.production" ;;
    *) bad "an XDictEntryView change did not select hostile.production: $got" ;; esac
same "a health change selects only its own sub-stage" "library.health" \
    "$(bash $affected --paths core/xdict-health/src/lib.rs)"
got=$(bash $affected --paths core/xdict-entry/src/roles.rs)
case " $(tr '\n' ' ' <<<"$got") " in
    *" launch."*|*" library."*|*" panel."*) bad "a rendering change selects stages that never render: $got" ;;
    *" hostile.production "*" entries.full "*) ok "a rendering change selects the entry's stages, not the app's" ;;
    *) bad "a rendering change missed hostile.production or entries.full: $got" ;; esac
got=$(bash $affected --paths apps/apple/Sources/XDictEntryView/EntryMarks.swift)
case " $(tr '\n' ' ' <<<"$got") " in *" hostile.faults "*|*" hostile.binding "*) bad "a stylesheet change selects the fault and binding twins: $got" ;;
    *" reader "*) ok "a stylesheet change selects what draws the entry" ;; *) bad "a stylesheet change missed reader: $got" ;; esac
same "the reader is everything" "$(bash $plan substages)" "$(bash $affected --paths core/xdict-mdx/src/lib.rs)"
same "an unmapped path selects every default sub-stage" "$(bash $plan substages)" \
    "$(bash $affected --paths apps/apple/no-rule-names-this.file)"
same "notes and unit tests select nothing" "" \
    "$(bash $affected --paths README.md dev-docs/plan.md apps/apple/Tests/XDictTests/X.swift core/xdict-mdx/tests/t.rs)"
got=$(bash $affected --paths apps/apple/Tools/hostile/analyze.py)
case " $(tr '\n' ' ' <<<"$got") " in *" hostile.controls "*) ok "the analyzer's change brings the hostile controls" ;;
    *) bad "the analyzer's change did not bring hostile.controls: $got" ;; esac
same "a library instrument brings the relinking control" "$(lines library.generated library.corpus library.control)" \
    "$(bash $affected --paths apps/apple/Sources/XDictInstruments/LibraryCorpus.swift)"
# (Not a confinement layer's file: those name hostile.controls themselves, as product code, not as a check's.)
same "product code brings no control" "$(lines hostile.binding hostile.faults reader hostile.production lookup.core lookup.a11y hostile.app entries.quick entries.persistence sound.speech sound.notices sound.recordings)" \
    "$(bash $affected --paths apps/apple/Sources/XDictEntryView/EntryEvents.swift)"
# The gallery is a style tool no sub-stage runs (2026-10-16: it selected hostile.controls, 23 min).
same "the gallery's code selects nothing" "" \
    "$(bash $affected --paths apps/apple/Sources/XDictEntryLab/Gallery.swift apps/apple/Sources/XDictEntryLab/GalleryInvariants.swift \
        apps/apple/Sources/XDictEntryLab/GalleryPhon.swift apps/apple/Tools/gallery/run.sh apps/apple/Tools/gallery/page.py)"
# **What the harness executes is derived, and widens** (2026-10-17, replacing the smoke sets of 2026-10-16): Tools/e2e.sh
# runs every sub-stage, so an edit to it selects them all. **A file a sub-stage's own function runs reaches that
# sub-stage** (2026-10-23): the kit builder copies Tools/lookup/drive.py into the kit and only `substage_lookup` runs
# it, so it selects the lookup group and nothing else. A file a helper or the top level runs still reaches every
# sub-stage that needs the kit: the builder itself, and analyze.py, which `hostile_runs` runs for its callers.
got=$(bash $affected --paths apps/apple/Tools/e2e.sh | sort)
same "a harness edit selects every sub-stage, the extra ones too" "$(bash $plan substages --all | sort)" "$got"
same "a driver one sub-stage function runs reaches that sub-stage only" \
    "$(lines lookup.core lookup.a11y lookup.paging)" "$(bash $affected --paths apps/apple/Tools/lookup/drive.py)"
# `control hostile.app hostile.controls`: what reaches the app check reaches its control.
same "a driver another sub-stage's function runs reaches that sub-stage, and its control" \
    "$(lines hostile.app hostile.controls)" "$(bash $affected --paths apps/apple/Tools/lookup/verdicts.py)"
# The sound group's function runs the typing helper for `sound.notices` alone (under `asked sound.notices`), and only
# sound.notices needs the kit: the other two could not run the file in any run that builds it.
same "a file several functions run reaches every one of them, and no other" \
    "$(lines setup lookup.core lookup.a11y lookup.paging sound.notices)" \
    "$(bash $affected --paths apps/apple/Tools/lookup/keys.swift)"
got=$(bash $affected --paths apps/apple/Tools/hostile/analyze.py)
for sub in hostile.controls hostile.production entries.persistence sound.notices; do
    case " $(tr '\n' ' ' <<<"$got") " in *" $sub "*) ;; *) bad "a helper's tool change missed $sub: $got" ;; esac
done
got=$(bash $affected --paths apps/apple/Sources/XDictEntryView/EntryRuleList.swift)
case " $(tr '\n' ' ' <<<"$got") " in *" hostile.controls "*) ok "a confinement layer's change brings the hostile controls" ;;
    *) bad "a confinement layer's change did not bring hostile.controls: $got" ;; esac
got=$(bash $affected --paths apps/apple/Sources/XDictEntryView/EntryReadingFrame.swift apps/apple/Sources/XDictEntryLab/Reader.swift)
case " $(tr '\n' ' ' <<<"$got") " in *" hostile.controls "*) bad "a style or reader-lab change brings the hostile controls: $got" ;;
    *) ok "a style or reader-lab change leaves out the hostile controls" ;; esac
# Every name the map uses is a sub-stage or a stage.
names=$(awk '/^[[:space:]]*(#|$)/ { next } $1 == "control" { print $2; print $3; next }
    { for (i = 2; i <= NF; i++) { n = $i; sub(/^check:/, "", n); if (n != "none" && n != "all") print n } }' e2e-affected.map | sort -u)
# shellcheck disable=SC2086 # names, split on purpose
if bash $plan expand $names >/dev/null 2>"$scratch/why"; then ok "every name in the map is a sub-stage or a stage"
else bad "the map names what is no sub-stage: $(cat "$scratch/why")"; fi
# The control of the map's fail-safe: a map whose last rule takes every path selects only what it says.
{ cat e2e-affected.map; echo "*  launch"; } >"$scratch/catch-all.map"
same "map control: a catch-all rule overrides the fail-safe (so the fail-safe is what selected everything)" "launch" \
    "$(XDICT_E2E_AFFECTED_MAP=$scratch/catch-all.map bash $affected --paths apps/apple/no-rule-names-this.file)"

# --- hover (plan-capture WI-5): defined, extra, and selected by what it reads ----------------------------------------
hover_all="hover.accessibility hover.ocr hover.exclusions hover.permission hover.popover"
hover_lab="hover.accessibility hover.ocr hover.exclusions"
got=$(bash $plan substages)
case " $(tr '\n' ' ' <<<"$got") " in *" hover."*) bad "a hover sub-stage is default, so a release would require it: $got" ;;
    *) ok "no hover sub-stage is default: a bare run and a release leave them out" ;; esac
got=$(bash $plan expand all)
got=" $(tr '\n' ' ' <<<"$got") "
missing=""; for s in $hover_all; do case $got in *" $s "*) ;; *) missing="$missing $s" ;; esac; done
[ -z "$missing" ] && ok "all names every hover sub-stage" || bad "all leaves out$missing"
# hover_selects <what> <wanted sub-stages> <path...>: each wanted sub-stage in the path's selection.
hover_selects() {
    local what=$1 wanted=$2 got missing="" s
    shift 2
    got=" $(bash $affected --paths "$@" | tr '\n' ' ') "
    for s in $wanted; do case $got in *" $s "*) ;; *) missing="$missing $s" ;; esac; done
    [ -z "$missing" ] && ok "$what" || bad "$what: missed$missing (got$got)"
}
# shellcheck disable=SC2086 # the names are words
same "the capture lab's code selects the sub-stages it runs in, and no other" "$(lines $hover_lab)" \
    "$(bash $affected --paths apps/apple/Sources/XDictCaptureLab/ReadPoint.swift)"
hover_selects "the pure capture target selects every hover sub-stage" "$hover_all" apps/apple/Sources/XDictCapture/HoverPolicy.swift
hover_selects "the readers and the lane select every hover sub-stage" "$hover_all selection.hosts" \
    apps/apple/Sources/XDictCaptureMac/HoverReader.swift
hover_selects "the hover control (linked by the app and the lab) selects every hover sub-stage" "$hover_all" \
    apps/apple/Sources/XDictAnywhere/HoverControl.swift
hover_selects "the app's hover wiring selects the popover" "hover.popover" apps/apple/Sources/XDict/LookupAnywhere.swift
hover_selects "Settings' hover rows select the permission sub-stage" "hover.permission setup" \
    apps/apple/Sources/XDictUI/HoverSettings.swift apps/apple/Sources/XDictUI/HoverSentences.swift
hover_selects "the menu-bar pause group selects the popover" "hover.popover menubar.item" \
    apps/apple/Sources/XDictUI/MenuBarMenu.swift
hover_selects "the popover's view selects the popover" "hover.popover panel.expand" apps/apple/Sources/XDictUI/LookupPopover.swift
# Its control: without the hand list's `launches` lines for them, no sub-stage starts the lab, and the selection above is
# no longer exact (the lab's code is named by no map rule: the graph decides).
grep -v '^launches hover\.' affected-hand.map >"$scratch/no-lab.hand"
got=$(XDICT_AFFECTED_HAND=$scratch/no-lab.hand bash $affected --paths apps/apple/Sources/XDictCaptureLab/ReadPoint.swift)
# shellcheck disable=SC2086 # the names are words
[ "$got" != "$(lines $hover_lab)" ] && ok "control: the hand list's launches are what select exactly the lab's sub-stages" \
    || bad "control: the hand list without hover's launches selected the same: $got"


# --- paths the map does not name: the generated graph (Tools/affected_graph.py) -------------------------------------
lab_subs="hostile.binding hostile.faults reader hostile.production hostile.controls entries.lab"
has() { case " $(tr '\n' ' ' <<<"$2") " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
# The service's code is named by no rule: the graph gives it the app's sub-stages (it is in the app's bundle), and not
# the lab's, which links the core itself. (It was everything, by the fail-safe, before the graph.)
got=$(bash $affected --paths apps/apple/Sources/XDictService/Service.swift)
lab_hit=""; for s in $lab_subs; do has "$s" "$got" && lab_hit="$lab_hit $s"; done
if [ -z "$lab_hit" ] && has launch "$got" && has service.conformance "$got"; then
    ok "the service's code (no rule) selects the app's sub-stages by the graph, not the lab's"
else bad "the service's code: lab [$lab_hit], got $(tr '\n' ' ' <<<"$got")"; fi
# A manifest edit is build-level: the build gate compiles it and launch is the smoke that the app still starts. It must
# not select the whole plan — an unrelated dependency line once re-ran every sub-stage (owner, 2026-10-23: only what a
# change could affect).
same "a Package.swift change is the launch smoke" "launch" "$(bash $affected --paths apps/apple/Package.swift)"
got=$(bash $affected --paths apps/apple/Sources/XDictSearch/SearchModel.swift)
lab_hit=""; for s in $lab_subs; do has "$s" "$got" && lab_hit="$lab_hit $s"; done
[ -z "$lab_hit" ] && ok "an XDictSearch change selects no lab hostile sub-stage" || bad "an XDictSearch change selects$lab_hit"
# Its controls: a graph made wrong turns the service's case red; a map made wrong the XDictSearch one.
python3 -I - affected-graph.json "$scratch/wrong.json" <<'PY'
import json, sys
g = json.load(open(sys.argv[1]))
g["targets"]["XDictEntryLab"]["deps"].append("XDictService")
json.dump(g, open(sys.argv[2], "w"))
PY
got=$(XDICT_AFFECTED_GRAPH=$scratch/wrong.json bash $affected --paths apps/apple/Sources/XDictService/Service.swift 2>/dev/null)
has hostile.production "$got" && ok "control: a service the lab linked would select hostile.production" \
    || bad "control: the wrong graph changed nothing: $got"
sed 's|^apps/apple/Sources/XDictSearch/\*.*|apps/apple/Sources/XDictSearch/* hostile.production|' e2e-affected.map >"$scratch/wrong.map"
got=$(XDICT_E2E_AFFECTED_MAP=$scratch/wrong.map bash $affected --paths apps/apple/Sources/XDictSearch/SearchModel.swift)
has hostile.production "$got" && ok "control: the map's answer is the one taken for a path it names" \
    || bad "control: the map's rule was not taken: $got"

# --- the harness lists what the plan says ----------------------------------------------------------------------------
same "e2e.sh --list-stages is the plan's default sub-stages (what a release requires)" "$(bash $plan substages)" \
    "$(./e2e.sh --list-stages)"

echo
[ "$failures" -eq 0 ] && echo "e2e-plan-test: all passed" || { echo "e2e-plan-test: $failures failed"; exit 1; }
