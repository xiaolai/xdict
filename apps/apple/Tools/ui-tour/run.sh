#!/bin/bash
# The UI tour (owner's request, 2026-10-17), started from the Air: every route of routes.py walked on the E2E Mac's
# installed XDict (`~/XDictE2E/XDict.app`) and captured, in light and dark (XDict's own, by `--appearance`) and in English and Simplified Chinese.
# Not an E2E stage: nothing is recorded in the E2E ledger, and nothing is built or opened on this Mac.
#
#   Tools/ui-tour/run.sh [--only id,id] [--variants light-en,light-zh]
#   Tools/ui-tour/run.sh --variants light-pseudo   English made ~40% longer and accented (pseudo.py), in a copy of the
#                                       installed app: what clips in a longer language
#   Tools/ui-tour/run.sh --label after --only settings.general,...   captures kept beside the earlier ones as
#                                       <variant>-after (a before/after pair on the index)
#   Tools/ui-tour/run.sh --reader      one real first launch (no instrument) over a fresh state, added to the results
#
# The host is E2E_HOST_MACOS in the repository's local.mk. The tour refuses to start while XDict runs there (a reader's
# copy is never quit) or an xctest run holds that Mac. Output: dev-docs/artifacts/ui-tour/<variant>/<route>.png and
# .ax.json, results.json and index.html, beside routes.md.
set -euo pipefail
. "$(dirname "$0")/../render-requested.sh"
cd "$(dirname "$0")/../.."
common=$(cd "$(git rev-parse --git-common-dir)/.." && pwd)
host=$(sed -n 's/^E2E_HOST_MACOS *= *//p' "$common/local.mk" 2>/dev/null | head -1)
[ -n "$host" ] || { echo "run.sh: E2E_HOST_MACOS is not set in $common/local.mk" >&2; exit 1; }
# The host's run lock (Tools/host-lock.sh): E2E, the gates, the gallery and the lab take it too, and since 2026-10-17
# that Mac also builds, so the tour waits for them, and they for it.
. Tools/host-lock.sh
host_lock "$host" ui-tour || exit 3
trap 'host_unlock "$host"' EXIT
out="$common/dev-docs/artifacts/ui-tour"
mkdir -p "$out"

tree=$(Tools/source-tree.sh)
installed=$(ssh "$host" 'sed -n "s/^tree=//p" XDictE2E/XDict.app/Contents/Resources/Provenance.txt' 2>/dev/null || true)
if [ "$installed" != "$tree" ]; then
    echo "run.sh: note: the installed bundle is of tree ${installed:-unknown}, this working copy is $tree" >&2
fi

# One tour at a time: a second would replace the first's kit and wipe its output and preferences backup.
if ssh "$host" 'pgrep -f ui-tour-kit/tour.py' >/dev/null; then
    echo "run.sh: another UI tour is running on $host; wait for it" >&2
    exit 1
fi
rsync -a --delete Tools/ui-tour/ "$host:XDictE2E/ui-tour-kit/"
# The catalog the `pseudo` variant is made from (tour.py, pseudo_app).
rsync -a Strings/Localizable.xcstrings "$host:XDictE2E/ui-tour-kit/"
# `--reader` adds one capture to the last tour's results; anything else starts them afresh.
case " $* " in
    *" --reader "*) ssh "$host" 'mkdir -p XDictE2E/ui-tour-out' ;;
    *) ssh "$host" 'rm -rf XDictE2E/ui-tour-out && mkdir -p XDictE2E/ui-tour-out' ;;
esac
status=0
ssh "$host" /usr/bin/python3 -I XDictE2E/ui-tour-kit/tour.py '"$HOME/XDictE2E"' '"$HOME/XDictE2E/ui-tour-out"' "$@" \
    || status=$?
# A partial run (`--only`, `--reader`) adds to the results already here rather than replacing them.
previous=$(mktemp)
[ -s "$out/results.json" ] && cp "$out/results.json" "$previous"
rsync -a --exclude .bin --exclude '.prefs-backup.plist' "$host:XDictE2E/ui-tour-out/" "$out/"
case " $* " in
    *" --only "* | *" --reader "*)
        python3 -I -c '
import json, sys
old = json.load(open(sys.argv[1])) if open(sys.argv[1]).read().strip() else []
new = json.load(open(sys.argv[2]))
keys = {(r["variant"], r["route"]) for r in new}
json.dump([r for r in old if (r["variant"], r["route"]) not in keys] + new, open(sys.argv[2], "w"), indent=1)
' "$previous" "$out/results.json" ;;
esac
rm -f "$previous"
[ "$status" -eq 0 ] || { echo "run.sh: the tour stopped (exit $status); what it captured is in $out" >&2; exit "$status"; }
[ -s "$out/results.json" ] || { echo "run.sh: the tour wrote no results.json" >&2; exit 1; }
# A labelled round beside the review's captures (`results-before.json`, kept from that round) gets the before | after
# page; any other run, the plain one.
label=$(printf '%s\n' "$@" | sed -n '/^--label$/{n;p;}' | head -1)
if [ -n "$label" ] && [ -s "$out/results-before.json" ]; then
    python3 -I Tools/ui-tour/index.py "$out" --before "$out/results-before.json" --label "$label"
else
    python3 -I Tools/ui-tour/index.py "$out"
fi
echo "$out/index.html"
