#!/bin/bash
# The end-to-end sub-stages a change needs, by `Tools/affected_graph.py` (the generated crate and target graph, and the
# hand list `Tools/affected-hand.map` for what no compiler sees): printed one a line, in the order they run, and nothing
# at all when the change needs none (notes, other platforms, unit tests).
#
#   e2e-affected.sh <base-ref>          the change since <base-ref>'s merge base with HEAD: committed, staged, unstaged
#                                       and untracked (not ignored), as the source tree the bundle is built from is
#   e2e-affected.sh --paths <path...>   the same for paths given from the repository's root, for the tests
#   -v (first)                          also say on stderr what took each path
#
# **A path neither the hand list nor the graph names selects every default sub-stage**, and so does a stale graph.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
fail() { echo "e2e-affected: $*" >&2; exit 1; }
verbose=()
[ "${1:-}" != -v ] || { verbose=(-v); shift; }
[ $# -gt 0 ] || fail "usage: e2e-affected.sh [-v] <base-ref> | --paths <path...>"

if [ "$1" = --paths ]; then
    shift
    paths=("$@")
else
    repo=$(git -C "$here" rev-parse --show-toplevel)
    git -C "$repo" rev-parse --verify --quiet "$1^{commit}" >/dev/null || fail "no commit called '$1'"
    base=$(git -C "$repo" merge-base "$1" HEAD) || fail "'$1' and HEAD share no history"
    paths=()
    while IFS= read -r path; do [ -z "$path" ] || paths+=("$path"); done < <(
        { git -C "$repo" diff --name-only "$base" --; git -C "$repo" ls-files --others --exclude-standard; } | sort -u)
fi
[ "${#paths[@]}" -gt 0 ] || exit 0
python3 -I "$here/affected_graph.py" select ${verbose[@]+"${verbose[@]}"} "${paths[@]}"
