#!/bin/bash
# What an end-to-end run is made of, read from `Tools/e2e-substages.txt` (the only list): the sub-stages, the checks each
# owns, and which a set of names asks for. Used by `Tools/e2e.sh`, `Tools/e2e-status.sh` and `Tools/e2e-affected.sh`;
# runs nothing and reaches nothing. Bash 3.2, as /bin/bash is on both Macs.
#
#   e2e-plan.sh substages [--all]       the default sub-stages (with --all every one), in the order they run
#   e2e-plan.sh expand [name...]        the sub-stages the names ask for, in run order. A sub-stage names itself; a bare
#                                       stage (`hostile`) its default sub-stages; `all` every one; none at all, the
#                                       default ones. An unknown name fails: a typo once ran nothing and passed
#   e2e-plan.sh only <check,check...>   the sub-stages that own those checks (E2E_ONLY); an unknown check fails
#   e2e-plan.sh table                   `sub-stage<TAB>default|extra<TAB>needs<TAB>group<TAB>check`, one row per check
#   e2e-plan.sh needs <sub-stage...>    the union of what they need (kit, fixtures, sample, editions, corpus), a line each
#   e2e-plan.sh coverage <baseline>     exit 1 unless every check is in exactly one sub-stage and the checks are exactly
#                                       the baseline's (`Tools/tests/e2e-checks-baseline.txt`); says which differ
#
# `XDICT_E2E_SUBSTAGES` names another catalog, for the tests' controls.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
catalog=${XDICT_E2E_SUBSTAGES:-$here/e2e-substages.txt}
[ -s "$catalog" ] || { echo "e2e-plan: no catalog at $catalog" >&2; exit 1; }
fail() { echo "e2e-plan: $*" >&2; exit 1; }

# The catalog as rows; a sub-stage with no check, or a check before any sub-stage, is refused here, once.
table() {
    awk '
        /^[[:space:]]*(#|$)/ { next }
        /^@/ {
            if (sub_ != "" && !checks) { print "e2e-plan: " sub_ " owns no check" > "/dev/stderr"; bad = 1 }
            sub_ = $2; kind = $3; needs = $4; group = "-"; checks = 0
            if (kind != "default" && kind != "extra") { print "e2e-plan: " sub_ ": default or extra, not " kind > "/dev/stderr"; bad = 1 }
            if (sub_ !~ /^[a-z]+(\.[a-z0-9]+)?$/) { print "e2e-plan: a sub-stage is stage or stage.part: " sub_ > "/dev/stderr"; bad = 1 }
            for (i = 5; i <= NF; i++) if ($i ~ /^group=/) group = substr($i, 7)
            next
        }
        {
            if (sub_ == "") { print "e2e-plan: a check before any sub-stage: " $0 > "/dev/stderr"; bad = 1; next }
            for (i = 1; i <= NF; i++) { print sub_ "\t" kind "\t" needs "\t" group "\t" $i; checks++ }
        }
        END {
            if (sub_ != "" && !checks) { print "e2e-plan: " sub_ " owns no check" > "/dev/stderr"; bad = 1 }
            exit bad
        }' "$catalog"
}

rows=$(table) || fail "the catalog $catalog does not parse"

substages() {
    if [ "${1:-}" = --all ]; then awk -F'\t' '!seen[$1]++ { print $1 }' <<<"$rows"
    else awk -F'\t' '$2 == "default" && !seen[$1]++ { print $1 }' <<<"$rows"; fi
}

expand() {
    local all wanted="" word stage
    all=$(substages --all)
    [ $# -gt 0 ] || { substages; return 0; }
    for word in "$@"; do
        case $word in
            all) wanted="$wanted $all" ;;
            *.*)
                grep -qxF "$word" <<<"$all" || fail "no sub-stage called '$word'; they are: $(tr '\n' ' ' <<<"$all")"
                wanted="$wanted $word" ;;
            *)
                stage=$(awk -F'\t' -v s="$word" '$2 == "default" && ($1 == s || index($1, s ".") == 1) && !seen[$1]++ { print $1 }' <<<"$rows")
                [ -n "$stage" ] || fail "no stage called '$word'; the stages are: $(sed 's/\..*//' <<<"$all" | awk '!seen[$0]++' | tr '\n' ' ')"
                wanted="$wanted $stage" ;;
        esac
    done
    # In run order, each once.
    awk -v w=" $(tr '\n' ' ' <<<"$wanted") " '{ if (index(w, " " $0 " ")) print }' <<<"$all"
}

only() {
    local check owner owners=""
    [ -n "${1:-}" ] || fail "only: no check named"
    for check in $(tr ',' ' ' <<<"$1"); do
        owner=$(awk -F'\t' -v c="$check" '$5 == c { print $1 }' <<<"$rows")
        [ -n "$owner" ] || fail "no check called '$check' (Tools/e2e-substages.txt lists them)"
        owners="$owners $owner"
    done
    expand $owners
}

needs() {
    local sub
    for sub in "$@"; do awk -F'\t' -v s="$sub" '$1 == s { print $3; exit }' <<<"$rows"; done \
        | tr ',' '\n' | grep -v '^-$' | sort -u || true
}

coverage() {
    local baseline=$1 twice missing extra
    [ -s "$baseline" ] || fail "coverage: no baseline at $baseline"
    twice=$(cut -f5 <<<"$rows" | sort | uniq -d)
    missing=$(comm -23 <(grep -v '^#' "$baseline" | grep . | sort -u) <(cut -f5 <<<"$rows" | sort -u))
    extra=$(comm -13 <(grep -v '^#' "$baseline" | grep . | sort -u) <(cut -f5 <<<"$rows" | sort -u))
    [ -z "$twice" ] || echo "in more than one sub-stage: $(tr '\n' ' ' <<<"$twice")" >&2
    [ -z "$missing" ] || echo "in no sub-stage: $(tr '\n' ' ' <<<"$missing")" >&2
    [ -z "$extra" ] || echo "not in the baseline: $(tr '\n' ' ' <<<"$extra")" >&2
    [ -z "$twice$missing$extra" ] || return 1
    echo "$(wc -l <<<"$rows" | tr -d ' ') checks in $(substages --all | wc -l | tr -d ' ') sub-stages, each in one: the baseline's, exactly"
}

command=${1:-}
[ $# -eq 0 ] || shift
case $command in
    substages) substages "$@" ;;
    expand) expand "$@" ;;
    only) only "$@" ;;
    table) printf '%s\n' "$rows" ;;
    needs) needs "$@" ;;
    coverage) [ $# -eq 1 ] || fail "usage: coverage <baseline>"; coverage "$1" ;;
    *) echo "usage: e2e-plan.sh substages [--all] | expand [name...] | only <checks> | table | needs <sub...> | coverage <baseline>" >&2; exit 64 ;;
esac
