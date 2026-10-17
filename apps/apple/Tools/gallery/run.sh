#!/bin/sh
# The lab gallery on an E2E Mac, under XDict's run lock for that host, failing loudly when it ends early.
#
#   Tools/gallery/run.sh <ssh-host> <out-dir> <lab gallery args...>
#
# Runs `.build/e2e-kit/XDictEntryLab.app --gallery …` there with the given arguments (paths on the host, `$HOME/…`),
# copies `report.json` and `images/` back, and exits non-zero, naming why, unless the report exists and holds every row
# the run meant to write (`expected`). The lab's stdout and stderr are kept beside the report. A `--keys` argument
# naming a local file is copied to the host first.
set -u
. "$(dirname "$0")/../render-requested.sh"
host=${1:?usage: run.sh <ssh-host> <out-dir> <lab gallery args...>}
out=${2:?usage: run.sh <ssh-host> <out-dir> <lab gallery args...>}
shift 2
here=$(cd "$(dirname "$0")/../.." && pwd)
lab="$here/.build/e2e-kit/XDictEntryLab.app"
[ -d "$lab" ] || { echo "gallery: $lab does not exist; build the lab kit first" >&2; exit 2; }
remote=XDictE2E/gallery-run

# The same lock Tools/e2e.sh takes for this host: one run against a host at a time.
. "$here/Tools/host-lock.sh"
host_lock "$host" gallery || exit 3
trap 'host_unlock "$host"' EXIT

args=""
while [ $# -gt 0 ]; do
    if [ "$1" = "--keys" ] && [ -f "${2:-}" ]; then
        rsync -a "$2" "$host:$remote-keys.json" || { echo "gallery: could not copy $2" >&2; exit 4; }
        args="$args --keys \$HOME/$remote-keys.json"
        shift 2
        continue
    fi
    args="$args $1"
    shift
done

rsync -a --delete "$lab" "$host:$remote-lab/" || { echo "gallery: could not copy the lab" >&2; exit 4; }
# The lab's render id beside it, for hot.sh and for the passes below: known only when the kit is of this tree.
render_lab_id=unknown
if [ "$(cat "$here/.build/e2e-kit.source-tree" 2>/dev/null)" = "$("$here/Tools/source-tree.sh")" ]; then
    render_lab_id=$(/usr/bin/python3 -I "$here/Tools/gallery/render_affected.py" lab-id) || render_lab_id=unknown
fi
printf '%s\n' "$render_lab_id" | ssh "$host" "cat > $remote-lab/render-lab-id" \
    || { echo "gallery: could not stamp the lab's render id" >&2; exit 4; }
case " $args " in *" --style-dir "* | *" --original-style "*) render_lab_id=unknown ;; esac
[ -z "${XDICT_LAB_CONTROL:-}${XDICT_LAB_DENSITY:-}${XDICT_LAB_OPEN_PICTURES:-}${XDICT_LAB_WIDTH:-}" ] || render_lab_id=unknown
ssh "$host" "rm -rf $remote; mkdir -p $remote; open -n -W --stdout \$HOME/$remote/stdout.txt --stderr \$HOME/$remote/stderr.txt \
    $remote-lab/XDictEntryLab.app --args --gallery $args --out \$HOME/$remote/report.json"
opened=$?
rm -rf "$out"; mkdir -p "$out"
rsync -a "$host:$remote/" "$out/" || { echo "gallery: could not copy the results back" >&2; exit 4; }

/usr/bin/python3 - "$out" "$opened" <<'PY'
import json, os, sys
out, opened = sys.argv[1], int(sys.argv[2])
images = len(os.listdir(os.path.join(out, "images"))) if os.path.isdir(os.path.join(out, "images")) else 0
def tail(name):
    try:
        with open(os.path.join(out, name), errors="replace") as f:
            return "".join(f.readlines()[-15:]).strip() or "(empty)"
    except OSError:
        return "(none)"
path = os.path.join(out, "report.json")
if opened != 0 or not os.path.isfile(path):
    print(f"gallery: FAIL: the lab ended without a report (open exit {opened}, {images} images written)\n"
          f"stderr:\n{tail('stderr.txt')}\nstdout:\n{tail('stdout.txt')}", file=sys.stderr)
    sys.exit(1)
report = json.load(open(path))
rows, expected = len(report.get("rows", [])), report.get("expected")
if expected is None or rows != expected:
    print(f"gallery: FAIL: {rows} rows written of {expected} expected ({images} images)", file=sys.stderr)
    sys.exit(1)
failures = report.get("failures", [])
print(f"gallery: {rows} rows of {expected}, {len(failures)} failures")
for f in failures:
    print("  " + f[:300])
sys.exit(1 if failures else 0)
PY
status=$?
# A render pass for every picture whose checks passed (Tools/gallery/render_affected.py), when the lab is of this tree.
if [ "$render_lab_id" != unknown ] && [ -f "$out/report.json" ]; then
    /usr/bin/python3 -I "$here/Tools/gallery/render_affected.py" record --lab-id "$render_lab_id" --report "$out/report.json" \
        || echo "gallery: the render passes were not recorded"
fi
# Each failure against the style ledger: a known row, or `NEW:` for one to file before it is fixed.
[ -f "$out/report.json" ] && /usr/bin/python3 -I "$here/Tools/gallery/ledger.py" triage "$out/report.json"
exit $status
