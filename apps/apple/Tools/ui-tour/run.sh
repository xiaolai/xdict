#!/bin/bash
# The UI tour (owner's request, 2026-10-17), started from the Air: every route of routes.py walked on the E2E Mac's
# installed XDict (`~/XDictE2E/XDict.app`) and captured, in light and dark and in English and Simplified Chinese.
# Not an E2E stage: nothing is recorded in the E2E ledger, and nothing is built or opened on this Mac.
#
#   Tools/ui-tour/run.sh [--only id,id] [--variants light-en,dark-en,light-zh,dark-zh]
#
# The host is E2E_HOST_MACOS in the repository's local.mk. The tour refuses to start while XDict runs there (a reader's
# copy is never quit) or an xctest run holds that Mac. Output: dev-docs/artifacts/ui-tour/<variant>/<route>.png and
# .ax.json, results.json and index.html, beside routes.md.
set -euo pipefail
cd "$(dirname "$0")/../.."
common=$(cd "$(git rev-parse --git-common-dir)/.." && pwd)
host=$(sed -n 's/^E2E_HOST_MACOS *= *//p' "$common/local.mk" 2>/dev/null | head -1)
[ -n "$host" ] || { echo "run.sh: E2E_HOST_MACOS is not set in $common/local.mk" >&2; exit 1; }
out="$common/dev-docs/artifacts/ui-tour"
mkdir -p "$out"

tree=$(Tools/source-tree.sh)
installed=$(ssh "$host" 'sed -n "s/^tree=//p" XDictE2E/XDict.app/Contents/Resources/Provenance.txt' 2>/dev/null || true)
if [ "$installed" != "$tree" ]; then
    echo "run.sh: note: the installed bundle is of tree ${installed:-unknown}, this working copy is $tree" >&2
fi

rsync -a --delete Tools/ui-tour/ "$host:XDictE2E/ui-tour-kit/"
ssh "$host" 'rm -rf XDictE2E/ui-tour-out && mkdir -p XDictE2E/ui-tour-out'
status=0
ssh "$host" /usr/bin/python3 -I XDictE2E/ui-tour-kit/tour.py '"$HOME/XDictE2E"' '"$HOME/XDictE2E/ui-tour-out"' "$@" \
    || status=$?
rsync -a --exclude .bin --exclude '.prefs-backup.plist' "$host:XDictE2E/ui-tour-out/" "$out/"
[ "$status" -eq 0 ] || { echo "run.sh: the tour stopped (exit $status); what it captured is in $out" >&2; exit "$status"; }
[ -s "$out/results.json" ] || { echo "run.sh: the tour wrote no results.json" >&2; exit 1; }
python3 -I Tools/ui-tour/index.py "$out"
echo "$out/index.html"
