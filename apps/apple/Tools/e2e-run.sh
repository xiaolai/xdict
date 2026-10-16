#!/bin/bash
# **Which E2E sub-stages run, and where** (`make e2e`, `make e2e-affected`, `make e2e-quick`, `Tools/land.sh`).
#
#   e2e-run.sh select     the sub-stages to run, one a line on stdout; on stderr, per sub-stage, `skipped: unchanged
#                         since pass <date>` or `run: <why>`. By default **only what changed since its last pass**
#                         (`Tools/gate-cache.py`: a sub-stage's key is the content of every file the affected map gives
#                         it, plus the corpus). STAGES=<names> runs those, forced; FULL=1 every default sub-stage,
#                         ignoring the cache. Writes the keys to .build/e2e-selection.tsv for `run`
#   e2e-run.sh pending    one line, running nothing: `E2E suggested: <sub-stages> — <changed paths>` or
#                         `E2E: nothing pending` (`make e2e-pending`, and the end of `make land`)
#   e2e-run.sh run <sub-stage...>
#                         runs them with Tools/e2e.sh: split over E2E_HOST_MACOS and E2E_HOST_MACOS_2 in parallel when
#                         both are set and E2E_SPLIT is not 0, else on E2E_HOST alone. Then files each pass of this tree
#                         in the gate cache under the key `select` computed
#
# **The split.** Sub-stages that post keys or pointer events, or read another app's window, need Accessibility and the
# front: on the first host only (the second has no Accessibility for XDict.app; AGENTS.md). The rest are balanced by
# the seconds each last took (.build/e2e-status.tsv; 60 where none is recorded), a group's one launch kept together.
# The second host starts once the first has finished its setup (the kit, the sample, the editions are made on this Mac
# once, and two setups at once would write them twice). Each host has its own run lock (Tools/e2e.sh).
#
# **Split evidence is development evidence only**: `Tools/e2e-status.sh require-fresh` still demands one Mac and one
# macOS build, so a release needs `make e2e FULL=1 E2E_SPLIT=0`.
#
# Environment (make sets them): XDICT_E2E_HOST, XDICT_E2E_HOST_2, XDICT_E2E_SPLIT, XDICT_E2E_STAGES, XDICT_E2E_FULL,
# XDICT_E2E_CORPUS, and those Tools/e2e.sh reads.
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { echo "e2e-run: $*" >&2; exit 1; }
readonly SELECTION=.build/e2e-selection.tsv
readonly STATUS=.build/e2e-status.tsv
# Post keys or pointer events, or read a window by Accessibility: the first host only.
readonly FRONT_GROUPS=" lookup sound anywhere "
readonly FRONT_SUBSTAGES=" reader library.generated "

corpus_fact() {
    if [ -n "${XDICT_E2E_CORPUS:-}" ]; then
        python3 -I Tools/gate-cache.py corpus-id "$XDICT_E2E_CORPUS" || fail "could not read the corpus at $XDICT_E2E_CORPUS"
    else echo none; fi
}

select_stages() {
    local stages=${XDICT_E2E_STAGES:-} rows
    mkdir -p .build
    : >"$SELECTION.new"
    if [ -n "$stages" ]; then
        # shellcheck disable=SC2086 # names, split on purpose
        bash Tools/e2e-plan.sh expand $stages >"$SELECTION.list" || fail "see above"
        while read -r sub; do echo "e2e: $sub run: forced (STAGES)" >&2; echo "$sub"; done <"$SELECTION.list"
        rm -f "$SELECTION.list" "$SELECTION.new" "$SELECTION"
        return 0
    fi
    local full=()
    [ "${XDICT_E2E_FULL:-}" != 1 ] || full=(--full)
    rows=$(python3 -I Tools/gate-cache.py status ${full[@]+"${full[@]}"} --fact "corpus=$(corpus_fact)" e2e) || fail "the gate cache failed"
    while IFS=$'\t' read -r action gate key why; do
        sub=${gate#e2e:}
        if [ "$action" = skip ]; then
            echo "e2e: $sub skipped: unchanged since pass $why" >&2
        else
            echo "e2e: $sub run: $why" >&2
            printf '%s\t%s\n' "$sub" "$key" >>"$SELECTION.new"
            echo "$sub"
        fi
    done <<<"$rows"
    printf 'tree\t%s\n' "$(Tools/source-tree.sh)" >>"$SELECTION.new"
    mv "$SELECTION.new" "$SELECTION"
}

# The seconds each sub-stage last took, `sub<TAB>seconds`.
weights() { [ -s "$STATUS" ] && awk -F'\t' '$9 ~ /^[0-9]+$/ { print $1 "\t" $9 }' "$STATUS" || true; }

# split <sub...>: two lines, the first host's sub-stages and the second's.
split() {
    local table
    table=$(bash Tools/e2e-plan.sh table)
    python3 -I - "$FRONT_GROUPS" "$FRONT_SUBSTAGES" "$(weights)" "$table" "$@" <<'PY'
import sys
front_groups, front_subs, weights, table = sys.argv[1].split(), sys.argv[2].split(), sys.argv[3], sys.argv[4]
subs = sys.argv[5:]
seconds = {}
for line in weights.splitlines():
    name, s = line.split("\t")
    seconds[name] = int(s)
group = {}
for row in table.splitlines():
    sub, _, _, g, _ = row.split("\t")
    group[sub] = g
units = {}
for sub in subs:
    g = group.get(sub, "-")
    units.setdefault(sub if g == "-" else "group:" + g, []).append(sub)
def weight(members):
    # A group runs one launch: its members each record the launch's time, so it counts once.
    if len(members) > 1:
        return max(seconds.get(m, 60) for m in members)
    return seconds.get(members[0], 60)
hosts, load = [[], []], [0, 0]
rest = []
for unit, members in units.items():
    if (unit.startswith("group:") and unit[6:] in front_groups) or any(m in front_subs for m in members):
        hosts[0] += members
        load[0] += weight(members)
    else:
        rest.append((weight(members), members))
for w, members in sorted(rest, key=lambda r: -r[0]):
    i = 0 if load[0] <= load[1] else 1
    hosts[i] += members
    load[i] += w
order = {s: i for i, s in enumerate(subs)}
for i in (0, 1):
    print(" ".join(sorted(hosts[i], key=order.get)) + f"\t{load[i]}")
PY
}

# wait_idle <host>: another project's XCTest takes the front (AGENTS.md); wait for it, up to 10 minutes.
wait_idle() {
    local host=$1 i busy
    for i in $(seq 1 20); do
        busy=$(ssh -o BatchMode=yes -o ConnectTimeout=15 -- "$host" "pgrep -fl xctest || true") || fail "cannot reach $host"
        [ -n "$busy" ] || { echo "e2e-run: $host: no xctest running"; return 0; }
        echo "e2e-run: $host is running XCTest ($busy); waiting ($i/20)"
        sleep 30
    done
    echo "e2e-run: $host still runs XCTest after 10 min; going ahead, a GUI failure there may be the host's" >&2
}

# record_passes <started>: each selected sub-stage that passed in this run, of the tree selected, into the gate cache.
record_passes() {
    local started=$1 tree now_tree sub key
    [ -s "$SELECTION" ] || return 0
    tree=$(awk -F'\t' '$1 == "tree" { print $2 }' "$SELECTION")
    now_tree=$(Tools/source-tree.sh)
    [ "$tree" = "$now_tree" ] || { echo "e2e-run: the tree changed since the selection; no pass cached" >&2; return 0; }
    while IFS=$'\t' read -r sub key; do
        [ "$sub" != tree ] || continue
        awk -F'\t' -v s="$sub" -v t="$tree" -v w="$started" '$1 == s && $2 == "pass" && $7 == t && $4 >= w { ok = 1 }
            END { exit !ok }' "$STATUS" 2>/dev/null || continue
        python3 -I Tools/gate-cache.py record "e2e:$sub" "$key" \
            "$(awk -F'\t' -v s="$sub" '$1 == s { print ($9 ~ /^[0-9]+$/ ? $9 : 0) }' "$STATUS")" e2e || true
    done <"$SELECTION"
    rm -f "$SELECTION"
}

run_stages() {
    [ $# -gt 0 ] || { echo "e2e-run: nothing to run"; return 0; }
    local host=${XDICT_E2E_HOST:-} host2=${XDICT_E2E_HOST_2:-} started status=0 started_s
    [ -n "$host" ] || fail "E2E_HOST_MACOS is not set (local.mk)"
    started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    started_s=$(date +%s)
    if [ -z "$host2" ] || [ "$host2" = "$host" ] || [ "${XDICT_E2E_SPLIT:-1}" = 0 ]; then
        wait_idle "$host"
        Tools/e2e.sh "$host" "$@" || status=$?
    else
        local plan one two logs
        plan=$(split "$@")
        one=$(sed -n 1p <<<"$plan" | cut -f1); two=$(sed -n 2p <<<"$plan" | cut -f1)
        echo "e2e-run: split: $host [$(sed -n 1p <<<"$plan" | cut -f2) s]: $one"
        echo "e2e-run: split: $host2 [$(sed -n 2p <<<"$plan" | cut -f2) s]: ${two:-nothing}"
        wait_idle "$host"
        [ -z "$two" ] || wait_idle "$host2"
        logs=$(mktemp -d)
        local s1=0 s2=0 p1 p2=""
        # shellcheck disable=SC2086 # names, split on purpose
        { Tools/e2e.sh "$host" $one >"$logs/1" 2>&1; echo $? >"$logs/1.status"; } &
        p1=$!
        if [ -n "$two" ]; then
            # The second starts once the first has done this Mac's setup.
            until grep -q '^== run:' "$logs/1" 2>/dev/null || [ -s "$logs/1.status" ]; do sleep 2; done
            # shellcheck disable=SC2086
            { Tools/e2e.sh "$host2" $two >"$logs/2" 2>&1; echo $? >"$logs/2.status"; } &
            p2=$!
        fi
        tail -n +1 -f "$logs/1" 2>/dev/null | sed -u "s/^/[1] /" &
        local t1=$!
        if [ -n "$p2" ]; then { sleep 1; tail -n +1 -f "$logs/2" 2>/dev/null | sed -u "s/^/[2] /"; } & fi
        local t2=$!
        wait "$p1" || true
        [ -z "$p2" ] || wait "$p2" || true
        sleep 1
        kill "$t1" "$t2" 2>/dev/null || true
        s1=$(cat "$logs/1.status" 2>/dev/null || echo 1)
        [ -z "$p2" ] || s2=$(cat "$logs/2.status" 2>/dev/null || echo 1)
        echo
        echo "e2e-run: $host exited $s1; ${two:+$host2 exited $s2}"
        [ "$s1" = 0 ] && [ "$s2" = 0 ] || status=1
        rm -rf "$logs"
    fi
    echo "e2e-run: wall-clock $(( $(date +%s) - started_s )) s"
    record_passes "$started"
    if [ "$status" != 0 ]; then
        local failed
        failed=$(awk -F'\t' -v w="$started" '$2 == "fail" && $4 >= w && $1 != "cleanup" { print $1 }' "$STATUS" | tr '\n' ' ')
        echo "e2e-run: failed: ${failed:-see above}" >&2
        [ -z "$failed" ] || echo "re-run only those: make e2e-quick STAGES=\"${failed% }\" E2E_CORPUS=\"\$HOME/xdict-corpus/the24\"" >&2
    fi
    return "$status"
}

# **E2E runs only on the owner's demand** (owner, 2026-10-17): agents and `make land` only say what is pending. One
# line: the default sub-stages with no pass for their current key, and the changed paths that reach them.
pending() {
    local rows
    rows=$(python3 -I Tools/gate-cache.py status --fact "corpus=$(corpus_fact)" e2e) || fail "the gate cache failed"
    awk -F'\t' '
        $1 == "run" { subs = subs " " substr($2, 5); n++
                      if ($4 ~ /^changed: /) { p = substr($4, 10); if (!(p in seen)) { seen[p] = 1; paths = paths (paths ? ", " : "") p } }
                      else other++ }
        END {
            if (!n) { print "E2E: nothing pending"; exit }
            why = paths
            if (other) why = why (why ? "; " : "") other " with no pass recorded"
            print "E2E suggested:" subs " — " why
        }' <<<"$rows"
}

case ${1:-} in
    select) select_stages ;;
    pending) pending ;;
    run) shift; run_stages "$@" ;;
    split) shift; split "$@" ;;
    *) fail "usage: e2e-run.sh select | pending | run <sub-stage...> | split <sub-stage...>" ;;
esac
