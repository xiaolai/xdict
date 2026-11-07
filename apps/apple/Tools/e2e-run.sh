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
#                         runs them with Tools/e2e.sh on E2E_HOST (E2E_HOST_MACOS, local.mk), once no other project's
#                         XCTest holds that Mac's front; Tools/e2e.sh files every row, pass and fail, in the ledger
#
# **One E2E Mac** (AGENTS.md, "Where builds and tests run": the macOS E2E runs on one Mac; the second E2E Mac's line was
# dropped on 2026-10-17). The split over two Macs that this script once made was removed on 2026-11-05 (the audit's G8
# and L16): no second host has existed since, and its wait for the first host's setup could spin for ever.
#
# Environment (make sets them): XDICT_E2E_HOST, XDICT_E2E_STAGES, XDICT_E2E_FULL, XDICT_E2E_CORPUS, and those
# Tools/e2e.sh reads; XDICT_HOST_LOCK_WAIT (seconds, 3600 by default), how long a run waits for another XCTest.
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { echo "e2e-run: $*" >&2; exit 1; }
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

# wait_idle <host>: another project's XCTest takes the front (AGENTS.md); wait for it, as long as a run waits for the
# host's lock (XDICT_HOST_LOCK_WAIT, Tools/host-lock.sh), then refuse: a GUI run beside another's XCTest fails on clicks
# that were never the product's (2026-11-05; it went ahead after 10 minutes before).
wait_idle() {
    local host=$1 limit=${XDICT_HOST_LOCK_WAIT:-3600} waited=0 busy
    [[ "$limit" =~ ^[0-9]+$ ]] || fail "XDICT_HOST_LOCK_WAIT is not a number of seconds: $limit"
    while :; do
        busy=$(ssh -o BatchMode=yes -o ConnectTimeout=15 -- "$host" "pgrep -fl xctest || true") || fail "cannot reach $host"
        [ -n "$busy" ] || { echo "e2e-run: $host: no xctest running"; return 0; }
        [ "$waited" -lt "$limit" ] \
            || fail "$host still runs XCTest after $waited s ($busy): nothing was run; wait for it, or raise XDICT_HOST_LOCK_WAIT"
        echo "e2e-run: $host is running XCTest ($busy); waiting ($waited of $limit s)"
        sleep 30
        waited=$((waited + 30))
    done
}

run_stages() {
    [ $# -gt 0 ] || { echo "e2e-run: nothing to run"; return 0; }
    local host=${XDICT_E2E_HOST:-} started status=0 started_s
    [ -n "$host" ] || fail "E2E_HOST_MACOS is not set (local.mk)"
    started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    started_s=$(date +%s)
    wait_idle "$host"
    Tools/e2e.sh "$host" "$@" || status=$?
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
    *) fail "usage: e2e-run.sh select | pending | run <sub-stage...>" ;;
esac
