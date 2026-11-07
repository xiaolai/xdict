#!/bin/bash
# Publishes a release on GitHub: the notarized disk image and its sha256, under the tag `Tools/release-tag.sh` wrote; then
# deletes every release beyond the two most recent.
#
#   Tools/release-publish.sh [--dry-run] <dmg> [notes file]
#
# The DMG is `make release`'s (`XDict-<macOS version>[-<build>].dmg`); its version names the tag, `v<version>`, which
# must exist here and point at HEAD (`gh release create --verify-tag` then also refuses one GitHub does not have: **a tag
# is pushed only when the branch is**, AGENTS.md, and this pushes nothing). `<dmg>.sha256` (shasum's own format) is
# written beside it when absent and checked when present, so the published hash is the file's. The title is the tag's
# first line; the notes are the file given, or else the tag's message.
#
# **Only the two most recent GitHub releases are kept** (AGENTS.md, owner 2026-10-30: "from now on, we only keep 2 most
# recent releases on github"; no local archive either): once this one is published, every release beyond the two most
# recent by creation date is deleted with `gh release delete --yes`, its assets with it, and named on the way. **Tags
# are never deleted** (same rule): never `--cleanup-tag`, so every release note stays reachable by its tag.
#
# --dry-run prints each `gh` command that would change something instead of running it (the list of releases is still
# read, so the deletions it prints are the real ones). XDICT_GH names the gh command (Tools/tests/release-publish-test.sh).
set -euo pipefail
fail() { echo "release-publish: $*" >&2; exit 1; }
readonly GH=${XDICT_GH:-gh}
readonly KEEP=2
repo=$(cd "$(dirname "$0")/../../.." && pwd)

dry=0
[ "${1:-}" != --dry-run ] || { dry=1; shift; }
[ $# -ge 1 ] && [ $# -le 2 ] || fail "usage: $0 [--dry-run] <dmg> [notes file]"
dmg=$1 notes=${2:-}
[ -s "$dmg" ] || fail "no disk image at $dmg"
name=$(basename "$dmg")
[[ "$name" =~ ^XDict-([0-9]+\.[0-9]+\.[0-9]+)(-[0-9]+)?\.dmg$ ]] || fail "$name is not XDict-<version>[-<build>].dmg"
version=${BASH_REMATCH[1]}
tag=v$version
[ -z "$notes" ] || [ -s "$notes" ] || fail "the notes file $notes is missing or empty"

git -C "$repo" rev-parse -q --verify "refs/tags/$tag" >/dev/null || fail "there is no tag $tag: run Tools/release-tag.sh first"
[ "$(git -C "$repo" cat-file -t "$tag")" = tag ] || fail "$tag is not an annotated tag (Tools/release-tag.sh writes one)"
[ "$(git -C "$repo" rev-parse "$tag^{commit}")" = "$(git -C "$repo" rev-parse HEAD)" ] \
    || fail "$tag is $(git -C "$repo" rev-parse --short "$tag^{commit}"), not HEAD ($(git -C "$repo" rev-parse --short HEAD)): publish from the tagged commit"

sum=$dmg.sha256
if [ -e "$sum" ]; then
    (cd "$(dirname "$dmg")" && shasum -a 256 -c "$(basename "$sum")" >/dev/null) \
        || fail "$(basename "$sum") does not match $name: the image changed since its hash was taken"
else
    (cd "$(dirname "$dmg")" && shasum -a 256 "$name" >"$(basename "$sum")") || fail "could not write $(basename "$sum")"
fi

title=$(git -C "$repo" tag -l --format='%(contents:subject)' "$tag")
[ -n "$title" ] || fail "$tag has no message to title the release with"
create=("$GH" release create "$tag" "$dmg" "$sum" --verify-tag --title "$title")
if [ -n "$notes" ]; then create+=(--notes-file "$notes"); else create+=(--notes-from-tag); fi

change() {  # change <command...>: run it, or print it under --dry-run
    if [ "$dry" = 1 ]; then printf 'dry-run:'; printf ' %q' "$@"; printf '\n'; else "$@"; fi
}
change "${create[@]}" || fail "gh could not publish $tag; nothing was deleted"

# Newest first; under --dry-run the release just "made" is not on GitHub yet, so it is counted as the newest.
releases=$("$GH" release list --limit 1000 --json tagName,createdAt --jq '.[] | [.createdAt, .tagName] | @tsv') \
    || fail "gh could not list the releases; $tag is published, nothing was deleted"
ordered=$( { [ "$dry" = 0 ] || printf '9999-12-31T00:00:00Z\t%s\n' "$tag"; printf '%s\n' "$releases"; } \
    | awk -F'\t' 'NF == 2 && !seen[$2]++' | sort -r | cut -f2)
grep -qx "$tag" <<<"$ordered" || fail "$tag is not among GitHub's releases after publishing it; nothing was deleted"
deleted=0
while IFS= read -r old; do
    [ -n "$old" ] && [ "$old" != "$tag" ] || continue
    change "$GH" release delete "$old" --yes || fail "gh could not delete the release $old"
    echo "release-publish: deleted the release $old (its tag stays)"
    deleted=$((deleted + 1))
done < <(tail -n +$((KEEP + 1)) <<<"$ordered")
echo "release-publish: $tag published$([ "$dry" = 0 ] || echo ' (dry run)'); $deleted older release(s) deleted, $KEEP kept"
