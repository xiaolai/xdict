#!/bin/sh
# **The main checkout, from any working copy of the repository** (the workspace layout in the root AGENTS.md,
# 2026-10-20).
#
#   Tools/main-checkout.sh [path]
#
# Prints the absolute path of the main checkout — the folder holding `.git`, `local.mk`, and the sibling `dev-docs/`
# — for a path inside any of its working copies (default: this script's own checkout). A linked worktree, whether
# nested inside it (`.claude/worktrees/`) or beside it in the workspace's `worktrees/`, is answered by git's common
# dir. A copy with no history has none: the nearest folder above holding `local.mk` is answered instead.
#
# Exits 2 with a sentence when neither answers. It writes nothing and reaches no host. Every script that needs the
# main checkout asks this one (land, the gallery's hot and lab, render-affected, the UI tour), and
# Tools/tests/main-checkout-test.sh holds it to the checkout, a worktree inside it, and one beside it.
set -u
here=$(CDPATH= cd "$(dirname "$0")" && pwd) || exit 2
start=$(CDPATH= cd "${1:-$here/..}" 2>/dev/null && pwd) || {
    echo "main-checkout: no such folder: ${1:-$here/..}" >&2
    exit 2
}

# git's common dir is the main checkout for every working copy of it, wherever that copy sits.
common=
gitdir=$(git -C "$start" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || gitdir=
if [ -n "$gitdir" ]; then
    common=$(dirname "$gitdir")
    if [ -f "$common/local.mk" ]; then
        printf '%s\n' "$common"
        exit 0
    fi
fi

# No history (a copy), or a checkout not set up yet: the nearest local.mk above the path.
main=$start
while [ ! -f "$main/local.mk" ] && [ "$main" != / ]; do main=$(dirname "$main"); done
if [ -f "$main/local.mk" ]; then
    printf '%s\n' "$main"
    exit 0
fi

# A checkout git knows, with no local.mk yet (a fresh clone), is still the main checkout: its scripts say what they
# need from local.mk themselves.
if [ -n "$common" ]; then
    printf '%s\n' "$common"
    exit 0
fi
echo "main-checkout: no main checkout above $start: no git common dir, and no local.mk" >&2
exit 2
