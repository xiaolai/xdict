#!/bin/bash
# The end-to-end evidence, read from and written to the one E2E ledger (Tools/e2e-ledger.py): a row per sub-stage
# (`Tools/e2e-substages.txt`) per run, pass and fail, under the sub-stage's content key.
#
#   e2e-status.sh record <build> <host> <os> <tree> <mode> <bundle>
#                            file the `RESULT<TAB>sub-stage<TAB>pass|fail[<TAB>check]` lines on stdin, with each
#                            sub-stage's seconds from its `TIME<TAB>sub-stage<TAB>seconds` line (Tools/e2e.sh). Keyed with
#                            the facts the tested bundle names itself (its Provenance.txt: its tree and the toolchain
#                            its build used), the E2E Mac's macOS build (from <os>, `version (build)`) and the corpus. A
#                            bundle of another tree than <tree> is refused; with no tree, the rows are filed unkeyed
#   e2e-status.sh show       the ledger's last rows (Tools/e2e-ledger.py show; E2E_LEDGER_LAST, E2E_LEDGER_STAGE)
#   e2e-status.sh required [--bootstrap]
#                            the sub-stages an on-demand release plan counts: every default one and RELEASE_EXTRAS;
#                            with --bootstrap, BOOTSTRAP_STAGES
#   e2e-status.sh smoke      RELEASE_SMOKE: what a release runs on its own signed bundle whatever the ledger says
#   e2e-status.sh plan [--bootstrap]
#                            per required sub-stage, `carried <date> <host> <key>` or `run — <why>`, and the minutes the
#                            runs take by their recorded seconds (`make release-plan`)
#   e2e-status.sh run-set [--bootstrap]
#                            the plan's `run` sub-stages, one a line (`make e2e RELEASE_NEEDED=1`)
#   e2e-status.sh require-fresh [--bootstrap]
#                            exit 1 unless the plan carries every required sub-stage. **On demand only** (`make
#                            e2e-evidence`): no step of a release or of a landing asks it (owner, 2026-10-24)
#
# **Release evidence is by key, not by tree** (owner, 2026-10-17): a sub-stage whose inputs and facts are what they were
# when it last passed is not run again for a release. The key holds the files that reach it, the build host's Xcode,
# Swift and Rust, the E2E Mac's macOS build, the corpus and the graph; a carried pass must be younger than
# E2E_EVIDENCE_MAX_DAYS (default 14). **The ledger is a record, never a gate** (owner, 2026-10-24: "e2e，不应该成为任何
# 一步的 gate，它就应该是 on demand 的"): a release is cut from a committed tree and always runs RELEASE_SMOKE on its
# release-signed bundle and Gatekeeper on the disk image, whatever the ledger carries.
set -euo pipefail
cd "$(dirname "$0")/.."
# The stage the skeleton's bootstrap release rests on (plan-macos-v1 WI-2).
readonly BOOTSTRAP_STAGES="launch"
# Extra sub-stages the ordinary release plan counts too: the WI-10 measurement (warm p95 within 1 s is part of done).
readonly RELEASE_EXTRAS="measure.protocol"
# Run on the release-signed, notarised bundle by every release, carried or not: keys cannot see signing.
readonly RELEASE_SMOKE="launch"
fail() { echo "e2e-status: $*" >&2; exit 1; }

# **A sub-stage the owner waives for one release** (2026-10-23): XDICT_E2E_WAIVE names them on the release command and
# nowhere else, so the waiver cannot silently carry into another release. It is for a judgement the keys cannot make —
# that a change reaching a sub-stage's inputs cannot reach its behaviour — and every check says what it waived.
waived_stages() { printf '%s\n' ${XDICT_E2E_WAIVE:-} | tr ',' ' ' | tr ' ' '\n' | sed '/^$/d'; }
waived_note() {
    local w
    w=$(waived_stages | paste -sd' ' -)
    [ -z "$w" ] || echo "e2e-status: WAIVED by the owner for this release: $w (XDICT_E2E_WAIVE)" >&2
}

# args_of <output of e2e-facts.sh>: its lines into the array `facts` (bash 3.2 has no mapfile).
facts=()
args_of() { local line; facts=(); while IFS= read -r line; do [ -z "$line" ] || facts+=("$line"); done <<<"$1"; }

record() {
    local ran=$1 host=$2 os=$3 tree=$4 mode=$5 app=$6 build corpus
    build=$(sed -n 's/.*(\([A-Za-z0-9]*\))$/\1/p' <<<"$os")
    if [ -z "$build" ] && [ "$tree" != - ]; then
        echo "e2e-status: the E2E Mac named no macOS build ($os): the rows are filed unkeyed" >&2
        tree=-
    fi
    corpus=$(Tools/e2e-facts.sh corpus) || fail "see above"
    args_of "--fact"$'\n'"macos=${build:-unknown}"$'\n'"$corpus"
    python3 -I Tools/e2e-ledger.py record "${facts[@]}" --bundle "$app" --build "$ran" --host "$host" --os "$os" \
        --tree "$tree" --mode "$mode"
}

required() {
    local all out s w
    if [ "${1:-}" = --bootstrap ]; then
        all=$BOOTSTRAP_STAGES
    else
        all=$(Tools/e2e.sh --list-stages | paste -sd' ' -)
        [ -n "$all" ] || fail "Tools/e2e.sh listed no stages"
        all="$all $RELEASE_EXTRAS"
    fi
    # A waiver is for a required sub-stage only: a typo is refused, never silently ignored.
    for w in $(waived_stages); do
        case " $all " in *" $w "*) ;; *) fail "XDICT_E2E_WAIVE names '$w', which is not a required sub-stage" ;; esac
    done
    out=""
    for s in $all; do
        case " $(waived_stages | paste -sd' ' -) " in *" $s "*) ;; *) out="$out $s" ;; esac
    done
    echo $out
}

# plan_rows [--bootstrap] [--human]: the ledger's plan for a release built now and run on XDICT_E2E_HOST.
plan_rows() {
    local bootstrap="" human="" out stages
    [ "${1:-}" != --bootstrap ] || { bootstrap=--bootstrap; shift; }
    [ "${1:-}" != --human ] || human=--human
    [ -n "${XDICT_E2E_HOST:-}" ] || [ -n "${XDICT_FACT_MACOS:-}" ] || fail "XDICT_E2E_HOST is not set: the plan keys on its macOS build"
    waived_note
    out=$(Tools/e2e-facts.sh plan "${XDICT_E2E_HOST:-}") || fail "the facts could not be read"
    args_of "$out"
    stages=$(required $bootstrap) || exit 1
    # shellcheck disable=SC2086 # the stage names are words, split on purpose
    python3 -I Tools/e2e-ledger.py plan --release --max-days "${E2E_EVIDENCE_MAX_DAYS:-14}" ${human:+"$human"} "${facts[@]}" $stages
}

require_fresh() {
    local what=full rows runs
    [ "${1:-}" != --bootstrap ] || what=bootstrap
    waived_note
    rows=$(plan_rows ${1:+"$1"}) || fail "the plan failed"
    runs=$(awk -F'\t' '$1 == "run" { print "  " $2 ": " $4 }' <<<"$rows")
    if [ -n "$runs" ]; then
        echo "no end-to-end evidence for the $what release of this source tree; these must run:" >&2
        echo "$runs" >&2
        echo "make e2e RELEASE_NEEDED=1 runs exactly those (make release-plan shows the whole plan), then release" >&2
        return 1
    fi
    echo "end-to-end evidence for the $what release: $(awk -F'\t' '{ printf "%s ", $2 }' <<<"$rows")— each carried by its" \
        "key (the release still runs $RELEASE_SMOKE on its signed bundle)"
}

case ${1:-} in
    record)
        [ $# -eq 7 ] || { echo "usage: e2e-status.sh record <build> <host> <os> <tree> <mode> <bundle>" >&2; exit 64; }
        shift; record "$@" ;;
    show) python3 -I Tools/e2e-ledger.py show --last "${E2E_LEDGER_LAST:-30}" ${E2E_LEDGER_STAGE:+--stage "$E2E_LEDGER_STAGE"} ;;
    required) required "${2:-}" ;;
    smoke) echo "$RELEASE_SMOKE" ;;
    plan) shift; plan_rows "$@" --human ;;
    run-set) shift; rows=$(plan_rows "$@") || exit 1; awk -F'\t' '$1 == "run" { print $2 }' <<<"$rows" ;;
    require-fresh) require_fresh "${2:-}" ;;
    *) echo "usage: e2e-status.sh record|show|required|smoke|plan|run-set|require-fresh [--bootstrap]" >&2; exit 64 ;;
esac
