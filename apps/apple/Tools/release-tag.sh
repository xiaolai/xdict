#!/bin/bash
# Tags a release: the annotated tag `v<macOS version>` on HEAD, whose message names all three versions. Pushes nothing.
#
#   Tools/release-tag.sh "<one line>"     writes `v<macOS>` and prints its name
#
# **Three version numbers, each its own, and every release is tagged** (AGENTS.md, owner 2026-10-23: "we actually need 3
# version numbers, core, macos, windows"; tagged since 2026-10-21: "when release, we always tag"). Read here, never typed:
#   core     the workspace version in core/Cargo.toml (`[workspace.package] version`)
#   macOS    CFBundleShortVersionString in Resources/Info.plist and Resources/DictionaryService-Info.plist, which agree
#   Windows  <Version> in apps/windows/Directory.Build.props
# The message is `XDict <macOS>: <one line>`, then a blank line and `Core <core> · macOS <macOS> · Windows <Windows>`, as
# v0.0.1…v0.6.12 are. Written to a file and given to `git tag -a -F`, so no shell ever parses it.
#
# Refused, with a sentence and no tag: a dirty tree (a tag names a commit, and what is uncommitted is in none), a tag of
# that name already there (tags are never moved or deleted: AGENTS.md, 2026-10-30), plists that disagree, a version that
# is not three numbers, a line that is empty or more than one. **A tag is pushed only when the branch is** (AGENTS.md):
# this never pushes; `Tools/release-publish.sh` publishes once it is.
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { echo "release-tag: $*" >&2; exit 1; }
repo=$(cd ../.. && pwd)

line=${1:-}
[ $# -eq 1 ] || fail "usage: $0 \"<one line>\""
[ -n "$line" ] || fail "the tag's one line is empty: say what this release does"
case $line in *$'\n'* | *$'\r'*) fail "the tag's line is more than one line" ;; esac

is_version() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
# The `version = "…"` line of the [workspace.package] table, as Cargo writes it; anything else fails is_version below.
core=$(awk '/^\[/ { in_table = ($0 == "[workspace.package]") } in_table && /^version[ \t]*=/ {
    sub(/^version[ \t]*=[ \t]*"/, ""); sub(/".*/, ""); print; exit }' "$repo/core/Cargo.toml")
[ -n "$core" ] || fail "core/Cargo.toml names no [workspace.package] version"
mac=$(plutil -extract CFBundleShortVersionString raw -o - Resources/Info.plist) \
    || fail "Resources/Info.plist has no CFBundleShortVersionString"
service=$(plutil -extract CFBundleShortVersionString raw -o - Resources/DictionaryService-Info.plist) \
    || fail "Resources/DictionaryService-Info.plist has no CFBundleShortVersionString"
[ "$mac" = "$service" ] || fail "the app says macOS $mac and the service $service: one version, in both plists"
windows=$(sed -n 's:.*<Version>\(.*\)</Version>.*:\1:p' "$repo/apps/windows/Directory.Build.props" | head -1)
[ -n "$windows" ] || fail "apps/windows/Directory.Build.props has no <Version>"
for pair in "core:$core" "macOS:$mac" "Windows:$windows"; do
    is_version "${pair#*:}" || fail "the ${pair%%:*} version is not three numbers: ${pair#*:}"
done

[ -z "$(git -C "$repo" status --porcelain)" ] || fail "the tree has uncommitted changes: commit first, a tag names a commit"
tag=v$mac
! git -C "$repo" rev-parse -q --verify "refs/tags/$tag" >/dev/null \
    || fail "$tag already exists (on $(git -C "$repo" rev-parse --short "$tag^{commit}")): tags are never moved; bump the macOS version"

message=$(mktemp)
trap 'rm -f "$message"' EXIT
printf 'XDict %s: %s\n\nCore %s · macOS %s · Windows %s\n' "$mac" "$line" "$core" "$mac" "$windows" >"$message"
git -C "$repo" tag -a "$tag" -F "$message" HEAD || fail "git could not write $tag"
echo "$tag"
