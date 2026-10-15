#!/bin/bash
# The end-to-end record: one row per sub-stage (`Tools/e2e-substages.txt`), against the build, the E2E Mac and the source tree it ran on. Adapted from
# XiaolaiDict's `Tools/e2e-status.sh` (its ADR-0024 and the addenda of 2026-10-11); its carrying of unchanged stages is
# not carried over, so every row is a run.
#
#   e2e-status.sh record <build> <host> <os> <tree> <mode>
#                            file the `RESULT<TAB>sub-stage<TAB>pass|fail[<TAB>check]` lines on stdin, with each
#                            sub-stage's seconds from its `TIME<TAB>sub-stage<TAB>seconds` line
#   e2e-status.sh show       what each stage last did, and whether it is evidence of the tree here now
#   e2e-status.sh require-fresh [--bootstrap]
#                            exit 1 unless every default sub-stage (`Tools/e2e.sh --list-stages`) — with --bootstrap,
#                            the skeleton's `launch` alone — last passed on a development bundle of this very source tree,
#                            all on one E2E Mac and one macOS build. What a release asks before it builds and again before
#                            it uploads anything
#
# A row is `sub-stage, result, build, when, host, os, tree, mode, seconds`, tab-separated (rows of before the split have
# no seconds and name whole stages, which nothing requires now). `host` is the E2E Mac's hardware UUID,
# `os` its macOS version and build, `tree` the source tree the bundle was built from (`Tools/source-tree.sh`) or `-`
# where it moved during the run or was not given, and `mode` is `development` or `release`, read from the build number.
set -euo pipefail
cd "$(dirname "$0")/.."
readonly STATUS=.build/e2e-status.tsv
# The stage the skeleton's bootstrap release rests on (plan-macos-v1 WI-2).
readonly BOOTSTRAP_STAGES="launch"

# A stage passes only if every assertion in it passed: the last result per stage once marked a stage green whose
# earlier check had failed (XiaolaiDict). A run that emitted no RESULT line leaves the record untouched; its own exit
# status says it went wrong.
record() {
    local ran=$1 host=$2 os=$3 tree=$4 mode=$5 now name result seconds
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    mkdir -p "$(dirname "$STATUS")"
    { grep "^RESULT	\|^TIME	" || true; } | awk -F'\t' '
        $1 == "TIME" { took[$2] = $3; next }
        { if ($3 == "fail") seen[$2] = "fail"; else if (!($2 in seen)) seen[$2] = "pass" }
        END { for (n in seen) print n "\t" seen[n] "\t" (n in took ? took[n] : "-") }' \
    | while IFS=$'\t' read -r name result seconds; do
        [ -n "${name:-}" ] || continue
        if [ -f "$STATUS" ]; then grep -v "^$name	" "$STATUS" >"$STATUS.new" || true; else : >"$STATUS.new"; fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$result" "$ran" "$now" "$host" "$os" "$tree" "$mode" "$seconds" \
            >>"$STATUS.new"
        mv "$STATUS.new" "$STATUS"
    done
}

show() {
    local tree
    tree=$(Tools/source-tree.sh)
    [ -s "$STATUS" ] || { echo "no end-to-end run is recorded"; return 0; }
    printf '%-20s %-6s %6s %-22s %-21s %-8s %-18s %s\n' SUB-STAGE RESULT SECS BUILD WHEN HOST MACOS "OF THIS TREE"
    while IFS=$'\t' read -r name result ran when host os stage_tree mode seconds; do
        local of=no
        [ "$stage_tree" != "$tree" ] || of=yes
        printf '%-20s %-6s %6s %-22s %-21s %-8s %-18s %s (%s)\n' "$name" "$result" "${seconds:--}" "$ran" "$when" "${host:0:8}" "$os" "$of" "$mode"
    done <"$STATUS"
}

# Every reason a release may not go out on this record, one per line; nothing where it may.
refusals() {
    local tree=$1; shift
    local stage row result tree_of mode host os first=""
    for stage in "$@"; do
        row=$( [ -f "$STATUS" ] && awk -F'\t' -v s="$stage" '$1 == s' "$STATUS" || true)
        if [ -z "$row" ]; then echo "$stage: never recorded"; continue; fi
        IFS=$'\t' read -r _ result _ _ host os tree_of mode _ <<<"$row"
        if [ "$result" != pass ]; then echo "$stage: last result $result"
        elif [ "$tree_of" = - ] || [ -z "$tree_of" ]; then
            echo "$stage: its last pass recorded no source tree (run by hand, or the tree moved during the run)"
        elif [ "$tree_of" != "$tree" ]; then
            echo "$stage: stale — its last pass was of source tree ${tree_of:0:12}, not this one, ${tree:0:12}"
        elif [ "$mode" != development ]; then
            echo "$stage: its last pass ran a $mode bundle; the evidence is a development bundle of this tree"
        elif [ -z "$host" ] || [ "$host" = - ] || [ -z "$os" ] || [ "$os" = - ]; then
            echo "$stage: its last pass recorded no E2E Mac or macOS build"
        elif [ -z "$first" ]; then first="$stage|$host|$os"
        elif [ "${first#*|}" != "$host|$os" ]; then
            echo "$stage: passed on another E2E Mac or macOS build than ${first%%|*}; the evidence is one Mac's, on one build"
        fi
    done
}

require_fresh() {
    local mode=full stages tree problems
    [ "${1:-}" != --bootstrap ] || mode=bootstrap
    if [ "$mode" = bootstrap ]; then
        stages=$BOOTSTRAP_STAGES
    else
        stages=$(Tools/e2e.sh --list-stages | paste -sd' ' -)
        [ -n "$stages" ] || { echo "e2e-status: Tools/e2e.sh listed no stages" >&2; return 1; }
    fi
    tree=$(Tools/source-tree.sh)
    # shellcheck disable=SC2086 # the stage names are words, split on purpose
    problems=$(refusals "$tree" $stages)
    if [ -n "$problems" ]; then
        echo "no fresh end-to-end pass of this source tree (${tree:0:12}) for the $mode release:" >&2
        sed 's/^/  /' <<<"$problems" >&2
        echo "run make e2e on this tree, then release" >&2
        return 1
    fi
    echo "end-to-end evidence for the $mode release: $stages — each passed on a development bundle of this tree (${tree:0:12})"
}

case ${1:-} in
    record)
        [ $# -eq 6 ] || { echo "usage: e2e-status.sh record <build> <host> <os> <tree> <mode>" >&2; exit 64; }
        shift; record "$@" ;;
    show) show ;;
    require-fresh) require_fresh "${2:-}" ;;
    *) echo "usage: e2e-status.sh record|show|require-fresh [--bootstrap]" >&2; exit 64 ;;
esac
