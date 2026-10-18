#!/bin/bash
# expand-entitlements.sh <signing identity> <entitlements in> <entitlements out>
#
# The app group both binaries share (ADR-0011 decision 4) is team-prefixed. The tracked entitlements write the prefix
# as Xcode's `$(TeamIdentifierPrefix)`, so no team identifier is in the repository; this substitutes the team named by
# the signing identity ("Developer ID Application: Name (TEAMID)"), the same identity `codesign` is given. Fails, and
# writes nothing, for an identity without a ten-character team, or for any `$(` placeholder it does not expand.
set -euo pipefail
[ $# -eq 3 ] || { echo "usage: expand-entitlements.sh <identity> <in> <out>" >&2; exit 2; }
identity=$1 in=$2 out=$3
team=$(sed -n 's/^.*(\([A-Z0-9]\{10\}\))$/\1/p' <<<"$identity")
[ -n "$team" ] || { echo "expand-entitlements: the identity names no team: '$identity'" >&2; exit 1; }
expanded=$(sed "s/\$(TeamIdentifierPrefix)/$team./g" "$in")
! grep -qF '$(' <<<"$expanded" || { echo "expand-entitlements: an unexpanded placeholder in $in" >&2; exit 1; }
tmp=$(mktemp "$out.XXXXXX")
printf '%s\n' "$expanded" >"$tmp"
plutil -lint -s "$tmp" || { rm -f "$tmp"; echo "expand-entitlements: $in did not expand to a property list" >&2; exit 1; }
mv "$tmp" "$out"
