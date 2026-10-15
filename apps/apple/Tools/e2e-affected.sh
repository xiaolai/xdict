#!/bin/bash
# The end-to-end sub-stages a change needs, by `Tools/e2e-affected.map`: printed one a line, in the order they run, and
# nothing at all when the change needs none (notes, other platforms, tests that run only here).
#
#   e2e-affected.sh <base-ref>          the change since <base-ref>'s merge base with HEAD: committed, staged, unstaged
#                                       and untracked (not ignored), as the source tree the bundle is built from is
#   e2e-affected.sh --paths <path...>   the same for paths given from the repository's root, for the tests
#   -v (first)                          also say on stderr which rule took each path
#
# **A path no rule matches selects every sub-stage**, and so does a rule naming `all`. A rule marked `check:` names a
# check's own code, and each sub-stage it names brings its positive control (`control` lines).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
map=${XDICT_E2E_AFFECTED_MAP:-$here/e2e-affected.map}
fail() { echo "e2e-affected: $*" >&2; exit 1; }
verbose=false
[ "${1:-}" != -v ] || { verbose=true; shift; }
[ $# -gt 0 ] || fail "usage: e2e-affected.sh [-v] <base-ref> | --paths <path...>"
[ -s "$map" ] || fail "no map at $map"

if [ "$1" = --paths ]; then
    shift
    paths=$(printf '%s\n' "$@")
else
    repo=$(git -C "$here" rev-parse --show-toplevel)
    git -C "$repo" rev-parse --verify --quiet "$1^{commit}" >/dev/null || fail "no commit called '$1'"
    base=$(git -C "$repo" merge-base "$1" HEAD) || fail "'$1' and HEAD share no history"
    paths=$( { git -C "$repo" diff --name-only "$base" --; git -C "$repo" ls-files --others --exclude-standard; } | sort -u)
fi

# The rules, in order: pattern, kind (plain|check), names.
rules=$(awk '/^[[:space:]]*(#|$)/ || $1 == "control" { next } { print }' "$map")
controls=$(awk '$1 == "control" { print $2 " " $3 }' "$map")
[ -n "$rules" ] || fail "the map has no rule"

selected="" everything=false
add() { selected="$selected $*"; }
while IFS= read -r path; do
    [ -n "$path" ] || continue
    matched=false
    while read -r pattern first rest; do
        # shellcheck disable=SC2254 # the pattern is the rule's, matched as a pattern on purpose
        case $path in $pattern) ;; *) continue ;; esac
        matched=true
        names="${first#check:} $rest"
        [ "$verbose" = false ] || echo "$path: $pattern -> $first $rest" >&2
        case " $names " in
            *" none "*) ;;
            *" all "*) everything=true ;;
            *)
                # shellcheck disable=SC2086 # names, split on purpose
                add $names
                if [ "${first#check:}" != "$first" ]; then
                    for name in $(bash "$here/e2e-plan.sh" expand $names); do
                        # shellcheck disable=SC2046 # names, split on purpose
                        add $(awk -v s="$name" '$1 == s { print $2 }' <<<"$controls")
                    done
                fi ;;
        esac
        break
    done <<<"$rules"
    if [ "$matched" = false ]; then
        [ "$verbose" = false ] || echo "$path: no rule, so everything" >&2
        everything=true
    fi
done <<<"$paths"

# Everything is what `make e2e` runs with no STAGES: every default sub-stage, the controls among them.
if [ "$everything" = true ]; then
    bash "$here/e2e-plan.sh" substages
elif [ -n "${selected// /}" ]; then
    # shellcheck disable=SC2086 # names, split on purpose
    bash "$here/e2e-plan.sh" expand $selected
fi
