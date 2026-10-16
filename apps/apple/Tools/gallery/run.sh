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
host=${1:?usage: run.sh <ssh-host> <out-dir> <lab gallery args...>}
out=${2:?usage: run.sh <ssh-host> <out-dir> <lab gallery args...>}
shift 2
here=$(cd "$(dirname "$0")/../.." && pwd)
lab="$here/.build/e2e-kit/XDictEntryLab.app"
[ -d "$lab" ] || { echo "gallery: $lab does not exist; build the lab kit first" >&2; exit 2; }
remote=XDictE2E/gallery-run

# The same lock Tools/e2e.sh takes for this host: one run against a host at a time.
lock="${TMPDIR:-/tmp}/xdict-e2e-$(printf '%s' "$host" | tr -c 'A-Za-z0-9' '_').lock"
tries=0
until /usr/bin/shlock -f "$lock" -p $$; do
    tries=$((tries + 1))
    [ "$tries" -gt 180 ] && { echo "gallery: $host is held by another run (lock: $lock)" >&2; exit 3; }
    sleep 20
done
trap 'rm -f "$lock"' EXIT

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
