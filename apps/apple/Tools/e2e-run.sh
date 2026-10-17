#!/bin/bash
# **Which E2E sub-stages run, and where** (`make e2e`, `make e2e-affected`, `make e2e-quick`, `Tools/land.sh`).
#
#   e2e-run.sh select     the sub-stages to run, one a line on stdout; on stderr, per sub-stage, `skipped: carried
#                         <date> <host> <key>` or `run: <why>`. By default **only what has no pass for its current key in
#                         the E2E ledger** (Tools/e2e-ledger.py: a sub-stage's key is the content of every file that
#                         reaches it by the generated graph, the hand list and the map, plus the build host's toolchain,
#                         the E2E Mac's macOS build, the corpus and the graph). STAGES=<names> runs those, forced; FULL=1
#                         every default sub-stage; RELEASE_NEEDED=1 exactly what a release could not carry
#                         (`Tools/e2e-status.sh run-set`; the release's smoke runs in Tools/release.sh, on its own bundle)
#   e2e-run.sh pending    one line, running nothing: `E2E suggested: <sub-stages> — <changed paths>` or
#                         `E2E: nothing pending` (`make e2e-pending`, and the end of `make land`)
#   e2e-run.sh run <sub-stage...>
#                         runs them with Tools/e2e.sh: split over E2E_HOST_MACOS and E2E_HOST_MACOS_2 in parallel when
#                         both are set and E2E_SPLIT is not 0, else on E2E_HOST alone. Tools/e2e.sh files every row,
#                         pass and fail, in the ledger
#
# **The split.** Sub-stages that post keys or pointer events, or read another app's window, need Accessibility and the
# front: on the first host only (the second has no Accessibility for XDict.app; AGENTS.md). The rest are balanced by
# the seconds each last took (the ledger; 60 where none is recorded), a group's one launch kept together.
# The second host starts once the first has finished its setup (the kit, the sample, the editions are made on this Mac
# once, and two setups at once would write them twice). Each host has its own run lock (Tools/e2e.sh).
#
# **Split evidence is release evidence too** where both Macs run one macOS build: the key holds the build, so a row of
# the other build is simply not this key's.
#
# Environment (make sets them): XDICT_E2E_HOST, XDICT_E2E_HOST_2, XDICT_E2E_SPLIT, XDICT_E2E_STAGES, XDICT_E2E_FULL,
# XDICT_E2E_CORPUS, and those Tools/e2e.sh reads.
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { echo "e2e-run: $*" >&2; exit 1; }
# Post keys or pointer events, or read a window by Accessibility: the first host only.
readonly FRONT_GROUPS=" lookup sound anywhere "
readonly FRONT_SUBSTAGES=" reader library.generated "

# read_facts: the key's facts for a run of the bundle `make e2e` would test on XDICT_E2E_HOST, into the array `facts`.
facts=()
read_facts() {
    local out build line
    build=$(Tools/e2e-facts.sh bundle) || build=$(Tools/e2e-facts.sh build) || fail "the build host's toolchain could not be read"
    out=$(Tools/e2e-facts.sh macos "${XDICT_E2E_HOST:-}") || fail "the E2E Mac's macOS build could not be read"
    line=$(Tools/e2e-facts.sh corpus) || fail "the corpus could not be read"
    out=$build$'\n'$out$'\n'$line
    facts=()
    while IFS= read -r line; do [ -z "$line" ] || facts+=("$line"); done <<<"$out"
}

select_stages() {
    local stages=${XDICT_E2E_STAGES:-} rows list
    if [ -n "$stages" ]; then
        # shellcheck disable=SC2086 # names, split on purpose
        list=$(bash Tools/e2e-plan.sh expand $stages) || fail "see above"
        while read -r sub; do echo "e2e: $sub run: forced (STAGES)" >&2; echo "$sub"; done <<<"$list"
        return 0
    fi
    if [ "${XDICT_E2E_RELEASE_NEEDED:-}" = 1 ]; then
        Tools/e2e-status.sh plan >&2 || fail "the release plan failed"
        Tools/e2e-status.sh run-set || fail "the release plan failed"
        return 0
    fi
    local full=()
    [ "${XDICT_E2E_FULL:-}" != 1 ] || full=(--full)
    read_facts
    # shellcheck disable=SC2046 # names, split on purpose
    rows=$(python3 -I Tools/e2e-ledger.py plan ${full[@]+"${full[@]}"} "${facts[@]}" $(bash Tools/e2e-plan.sh substages)) \
        || fail "the ledger failed"
    while IFS=$'\t' read -r action sub _ why _; do
        if [ "$action" = carried ]; then
            echo "e2e: $sub skipped: carried $why" >&2
        else
            echo "e2e: $sub run: $why" >&2
            echo "$sub"
        fi
    done <<<"$rows"
}

# The seconds each sub-stage last took, `sub<TAB>seconds`.
weights() { python3 -I Tools/e2e-ledger.py seconds 2>/dev/null || true; }

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
    if [ "$status" != 0 ]; then
        local failed
        failed=$(python3 -I Tools/e2e-ledger.py failed-since "$started" 2>/dev/null || true)
        echo "e2e-run: failed: ${failed:-see above}" >&2
        [ -z "$failed" ] || echo "re-run only those: make e2e-quick STAGES=\"${failed% }\" E2E_CORPUS=\"\$HOME/xdict-corpus/the24\"" >&2
    fi
    return "$status"
}

# **E2E runs only on the owner's demand** (owner, 2026-10-17): agents and `make land` only say what is pending. One
# line: the default sub-stages with no pass for their current key, and the changed paths that reach them.
pending() {
    local rows
    read_facts
    # shellcheck disable=SC2046 # names, split on purpose
    rows=$(python3 -I Tools/e2e-ledger.py plan "${facts[@]}" $(bash Tools/e2e-plan.sh substages)) || fail "the ledger failed"
    awk -F'\t' '
        $1 == "run" { subs = subs " " $2; n++
                      if ($4 ~ /^changed: /) { p = substr($4, 10); if (!(p in seen)) { seen[p] = 1; paths = paths (paths ? ", " : "") p } }
                      else other++ }
        END {
            if (!n) { print "E2E: nothing pending"; exit }
            why = paths
            if (other) why = why (why ? "; " : "") other " with no pass for their key"
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
