#!/bin/bash
# The git tree this working copy is: the tree a commit of every tracked and untracked, non-ignored file would have,
# committed or not. Printed as one hash.
#
#   Tools/source-tree.sh          the working copy's tree
#   Tools/source-tree.sh --clean  the same, and exit 1 unless it is HEAD's (nothing uncommitted, nothing untracked)
#
# **Why not HEAD's tree** (XiaolaiDict's receipt was `HEAD^{tree}` of a clean copy): evidence is a fact about bytes,
# and naming the bytes needs no commit. A tree taken this way equals `HEAD^{tree}` exactly when the copy is clean, so
# evidence recorded before a commit stays the evidence of that commit when it is made of the same content, and an edit
# made since, committed or not, is a different tree. Whether a release must also be committed is the release's
# question (`Tools/release.sh`), asked with `--clean`.
#
# Built in an index of its own (`GIT_INDEX_FILE`), so the repository's index, refs and working copy are untouched;
# `git add` writes the untracked files' blobs into the object store, which is all it leaves behind.
set -euo pipefail
repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export GIT_INDEX_FILE=$scratch/index
git -C "$repo" read-tree HEAD
git -C "$repo" add --all :/
tree=$(git -C "$repo" write-tree)
[[ "$tree" =~ ^[0-9a-f]{40,64}$ ]] || { echo "source-tree: git wrote no tree" >&2; exit 1; }
printf '%s\n' "$tree"
if [ "${1:-}" = --clean ]; then
    head=$(git -C "$repo" rev-parse 'HEAD^{tree}')
    [ "$tree" = "$head" ] || { echo "source-tree: the working copy is not HEAD's tree: commit first" >&2; exit 1; }
fi
