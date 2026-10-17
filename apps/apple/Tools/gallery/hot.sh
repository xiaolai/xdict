#!/bin/sh
# **A reading-style change, from edit to picture, with no rebuild** (plan-verification §4.6).
#
#   Tools/gallery/hot.sh <dict>:<key>[:<kind>] ...
#
# Copies only Sources/XDictEntryView/Style/ to the E2E Mac, renders the named entries there with the lab already
# installed by Tools/gallery/run.sh (`--style-dir`: the lab reads the style from that copy, not its own binary), and
# copies the pictures and the report back to dev-docs/artifacts/reading-frame/hot/. `kind` names the pictures
# (`<dict>-<kind>-<mode>.jpg`, as the gallery's); it defaults to the key. Nothing is built, signed or copied but text.
#
# The host is E2E_HOST, else local.mk's E2E_HOST_MACOS; corpus and sample are the gallery's on that host. It refuses
# to start while an xctest run holds the host's screen, and takes the gallery's run lock. Exits non-zero, naming why,
# unless the report holds every row; the gallery's failures are printed, and fail it too. XDICT_LAB_CONTROL=1|G
# renders a positive control (GalleryInvariants, GalleryChecks, GallerySpace): that run must fail. XDICT_LAB_DENSITY=panel
# renders the lookup panel's density; XDICT_LAB_OPEN_PICTURES=1 opens the fold of hidden pictures;
# XDICT_LAB_WIDTH=<px> pictures another pane width; XDICT_LAB_MODES=core-light,core-dark only those views.
set -u
. "$(dirname "$0")/../render-requested.sh"
[ $# -gt 0 ] || { echo "usage: hot.sh <dict>:<key>[:<kind>] ..." >&2; exit 2; }
started=$(date +%s)
apple=$(cd "$(dirname "$0")/../.." && pwd)
repo=$(cd "$apple/../.." && pwd)
# The main checkout, where local.mk and dev-docs/ live: this one, or the first folder above it holding local.mk (a
# worktree is kept inside its main checkout, under .claude/worktrees/).
main=$repo
while [ ! -f "$main/local.mk" ] && [ "$main" != / ]; do main=$(dirname "$main"); done
mk=$main/local.mk
host=${E2E_HOST:-$(awk -F'=' '{ n = $1; gsub(/[ \t]/, "", n) } n == "E2E_HOST_MACOS" { sub(/^[^=]*=[ \t]*/, ""); print; exit }' "$mk" 2>/dev/null)}
[ -n "$host" ] || { echo "hot: no E2E_HOST and no E2E_HOST_MACOS in local.mk" >&2; exit 2; }
out=${HOT_OUT:-$main/dev-docs/artifacts/reading-frame/hot}
remote=XDictE2E/hot
lab=XDictE2E/gallery-run-lab/XDictEntryLab.app

# The keys file the gallery takes (`--keys`): the entries, and the dictionaries they are in (`--only`).
keys=$(mktemp -t xdict-hot) || exit 4
trap 'rm -f "$keys"' EXIT
only=$(/usr/bin/python3 -I - "$keys" "$@" <<'PY'
import json, re, sys
rows, dicts = [], []
for arg in sys.argv[2:]:
    part = arg.split(":")
    if len(part) not in (2, 3) or not all(part):
        sys.exit(f"hot: {arg!r} is not <dict>:<key>[:<kind>]")
    kind = part[2] if len(part) == 3 else re.sub(r"[^A-Za-z0-9]+", "_", part[1])
    rows.append({"dict": part[0], "kind": kind, "key": part[1]})
    dicts.append(part[0])
json.dump({"rows": rows}, open(sys.argv[1], "w"))
print(",".join(sorted(set(dicts))))
PY
) || exit 2

busy=$(ssh "$host" 'pgrep -fl xctest') && { echo "hot: $host is running xctest, which takes the front: $busy" >&2; exit 3; }
ssh "$host" "[ -x $lab/Contents/MacOS/XDictEntryLab ]" \
    || { echo "hot: no lab at $host:$lab; install one with Tools/gallery/run.sh" >&2; exit 2; }

. "$apple/Tools/host-lock.sh"
host_lock "$host" hot || exit 3
trap 'rm -f "$keys"; host_unlock "$host"' EXIT

rsync -a --delete --include '*.css' --include '*.js' --exclude '*' "$apple/Sources/XDictEntryView/Style/" \
    "$host:$remote/style/" || { echo "hot: could not copy the style" >&2; exit 4; }
rsync -a "$keys" "$host:$remote/keys.json" || { echo "hot: could not copy the keys" >&2; exit 4; }
# A positive control (`XDICT_LAB_CONTROL=1` spacing, `G` the checks G1–G15) goes to the lab's environment.
control=${XDICT_LAB_CONTROL:-}
case $control in ''|1|G) ;; *) echo "hot: XDICT_LAB_CONTROL is 1 or G" >&2; exit 2 ;; esac
# The density (WI-11 R7a): the main window's, or `XDICT_LAB_DENSITY=panel` for the lookup panel's.
density=${XDICT_LAB_DENSITY:-}
case $density in ''|main|panel) ;; *) echo "hot: XDICT_LAB_DENSITY is main or panel" >&2; exit 2 ;; esac
[ "$density" = main ] && density=
# The render key of each picture (Tools/gallery/render_affected.py), taken before the style is copied: the installed
# lab's id (stamped by lab.sh or run.sh) with this working copy's style. Only the standard views are keyed: a control,
# the panel's density, opened pictures or another width are other pictures.
render_keys=""
lab_id=$(ssh "$host" "cat $(dirname "$lab")/render-lab-id 2>/dev/null")
if [ -n "$control$density${XDICT_LAB_OPEN_PICTURES:-}${XDICT_LAB_WIDTH:-}" ]; then
    echo "hot: a variant view: no render pass will be recorded"
elif [ -z "$lab_id" ] || [ "$lab_id" = unknown ]; then
    echo "hot: the installed lab has no render-lab-id (install it with lab.sh): no render pass will be recorded"
else
    render_keys=$(mktemp -t xdict-render-keys) || exit 4
    /usr/bin/python3 -I "$apple/Tools/gallery/render_affected.py" keys --lab-id "$lab_id" \
        ${XDICT_LAB_MODES:+--views "$XDICT_LAB_MODES"} "$@" >"$render_keys" \
        || { echo "hot: could not key the pictures: no render pass will be recorded"; rm -f "$render_keys"; render_keys=""; }
fi
ssh "$host" "rm -rf $remote/run; mkdir -p $remote/run; open -n -W ${control:+--env XDICT_LAB_CONTROL=$control} ${density:+--env XDICT_LAB_DENSITY=$density} ${XDICT_LAB_OPEN_PICTURES:+--env XDICT_LAB_OPEN_PICTURES=1} ${XDICT_LAB_WIDTH:+--env XDICT_LAB_WIDTH=$XDICT_LAB_WIDTH} ${XDICT_LAB_MODES:+--env XDICT_LAB_MODES=$XDICT_LAB_MODES} \
    --stdout \$HOME/$remote/run/stdout.txt --stderr \$HOME/$remote/run/stderr.txt $lab --args --gallery \$HOME/XDictE2E/corpus \
    --sample \$HOME/XDictE2E/kit/entries-sample.json --keys \$HOME/$remote/keys.json --only $only \
    --style-dir \$HOME/$remote/style --out \$HOME/$remote/run/report.json"
opened=$?
mkdir -p "$out"
rm -f "$out/report.json"   # never read an earlier run's report as this one's
rsync -a --include 'images/' --include '*.jpg' --include 'report.json' --include 'stderr.txt' --exclude '*' \
    "$host:$remote/run/" "$out/" || { echo "hot: could not copy the results back" >&2; exit 4; }

/usr/bin/python3 -I - "$out" "$opened" "$started" <<'PY'
import json, os, sys, time
out, opened, started = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
path = os.path.join(out, "report.json")
if opened != 0 or not os.path.isfile(path):
    sys.exit(f"hot: FAIL: the lab ended without a report (open exit {opened}); see {out}/stderr.txt")
report = json.load(open(path))
rows, expected = report.get("rows", []), report.get("expected")
if expected is None or len(rows) != expected or report.get("style", "bundled") == "bundled":
    sys.exit(f"hot: FAIL: {len(rows)} rows of {expected}, style {report.get('style')!r}")
for row in rows:
    print("  " + os.path.join(out, row["image"]))
failures = report.get("failures", [])
for f in failures:
    print("  FAIL " + f[:300])
print(f"hot: {len(rows)} pictures, {len(failures)} failures, {int(time.time()) - started} s from the command")
sys.exit(1 if failures else 0)
PY
status=$?
# A pass for every picture whose checks passed (a failed one, or a run with an unattributed failure, records nothing).
if [ -n "$render_keys" ] && [ -f "$out/report.json" ]; then
    /usr/bin/python3 -I "$apple/Tools/gallery/render_affected.py" record --keys "$render_keys" --report "$out/report.json" \
        || echo "hot: the render passes were not recorded"
fi
[ -z "$render_keys" ] || rm -f "$render_keys"
exit $status
