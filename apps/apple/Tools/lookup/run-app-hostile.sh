#!/bin/bash
# One observed run of the hostile battery **through the app's own window** (plan-macos-v1 WI-4's stamp, re-measured at
# WI-6), on the E2E Mac: `Tools/hostile/run-hostile.sh`'s observation, with the signed app (`XDict --entry-hostile`)
# in place of the lab. The observers up and each shown one deliberate attempt, the app started by LaunchServices in the
# GUI session, late egress waited for, the DNS oracle asked, everything stopped, the run analysed by the lab's own
# `analyze.py run`, whose report shape the app's instrument writes.
#
#   run-app-hostile.sh <kit> <results-dir> <app>    writes <results-dir>/app/{report,summary}.json and the observations
#
# Exits non-zero when the run did not happen as described (an observer not listening, no report from the app): a run
# that silently did nothing must not read as a run where nothing left.
set -euo pipefail
kit=$(cd "$1" && pwd)
res=$2
app=$(cd "$3" && pwd)
dir="$res/app"
rm -rf "$dir"
mkdir -p "$dir"
dir=$(cd "$dir" && pwd)
exe="$app/Contents/MacOS/XDict"
[ -x "$exe" ] || { echo "run-app-hostile: no app at $app" >&2; exit 1; }
cp "$kit/cases.json" "$dir/cases.json"

# By the executable `ps` reports, compared whole: never a pattern or a name.
app_running() {
    local table pid executable
    table=$(ps -axww -o pid=,comm=) || { echo "run-app-hostile: ps failed" >&2; exit 1; }
    while read -r pid executable; do [ "$executable" != "$exe" ] || return 0; done <<<"$table"
    return 1
}
app_pids() { ps -axww -o pid=,comm= | awk -v exe="$exe" '{ pid = $1; $1 = ""; sub(/^ /, ""); if ($0 == exe) print pid }'; }
app_running && { echo "run-app-hostile: XDict is already running" >&2; exit 1; }

read -r ctl_http ctl_tcp ctl_udp budget selftest < <(python3 -I -c '
import json, sys
b = json.load(open(sys.argv[1]))
print(b["control"]["http"], b["control"]["tcp"], b["control"]["udp"],
      int(sum(c["wait"] for c in b["cases"]) / 1000 / 2) + 300, b["selftestName"])
' "$dir/cases.json")

obs=""
dns=""
cleanup() {
    [ -z "$dns" ] || kill "$dns" 2>/dev/null || true
    [ -z "$obs" ] || kill "$obs" 2>/dev/null || true
    local pid
    for pid in $(app_pids); do kill "$pid" 2>/dev/null || true; done
}
trap cleanup EXIT

python3 -I "$kit/observe.py" --cases "$dir/cases.json" --log "$dir/observed.jsonl" --ready "$dir/ready.flag" \
    2>"$dir/observe.err" &
obs=$!
for _ in $(seq 1 80); do
    [ -f "$dir/ready.flag" ] && break
    kill -0 "$obs" 2>/dev/null || { echo "run-app-hostile: the observer died: $(cat "$dir/observe.err")" >&2; exit 1; }
    sleep 0.25
done
[ -f "$dir/ready.flag" ] || { echo "run-app-hostile: the observer never became ready" >&2; exit 1; }

/usr/bin/log stream --style ndjson --predicate 'process == "mDNSResponder"' >"$dir/dns.ndjson" 2>"$dir/dns.err" &
dns=$!
sleep 3
kill -0 "$dns" 2>/dev/null || { echo "run-app-hostile: log stream died: $(cat "$dir/dns.err")" >&2; exit 1; }

# Each observer's positive control: one deliberate attempt of its own kind, before anything is counted.
curl -s -m 3 -o /dev/null "http://127.0.0.1:$ctl_http/control/selftest" || true
python3 -I -c 'import socket, sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), 3).close()' "$ctl_tcp"
python3 -I -c 'import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.sendto(b"\x00\x01\x00\x00\x21\x12\xa4\x42" + b"\x00" * 12, ("127.0.0.1", int(sys.argv[1])))' "$ctl_udp"
dscacheutil -q host -a name "$selftest" >/dev/null 2>&1 || true
sleep 1

# The battery's dictionary is imported into a library of the run's own: the import is outside the cases' windows.
date +%s >"$dir/lab.started"
open -n --stdout "$dir/lab.out" --stderr "$dir/lab.err" "$app" --args \
    --entry-hostile "$dir/library" --fixture "$kit/fixtures/hostile" --cases "$dir/cases.json" --out "$dir/report.json"
waited=0
gone=0
while [ ! -s "$dir/report.json" ] && [ "$waited" -lt $((budget * 4)) ]; do
    sleep 0.25
    waited=$((waited + 1))
    # An app that exited without a report ends the wait early; three misses in a row, not one (spike 3).
    if [ "$waited" -gt 40 ] && ! app_running; then gone=$((gone + 1)); else gone=0; fi
    [ "$gone" -ge 3 ] && break
done
for _ in $(seq 1 40); do app_running || break; sleep 0.25; done
if app_running; then
    for pid in $(app_pids); do kill "$pid" 2>/dev/null || true; done
    echo "run-app-hostile: the app had to be killed" >>"$dir/lab.err"
fi
date +%s >"$dir/lab.ended"
sleep 4   # late egress: beacons, keepalive fetches, EventSource retries, ICE retransmissions

python3 -I "$kit/dns_oracle.py" --cases "$dir/cases.json" >"$dir/oracle.json"
sleep 3
kill "$dns" 2>/dev/null || true
kill "$obs" 2>/dev/null || true
wait "$obs" 2>/dev/null || true
dns=""
obs=""

[ -s "$dir/report.json" ] || { echo "run-app-hostile: the app wrote no report: $(tail -5 "$dir/lab.err")" >&2; exit 1; }
# Only the lines the analysis reads: WebKit's, the app's and its service's, the oracle's and the self-test's.
python3 -I - "$dir/dns.ndjson" <<'PY'
import json, os, sys
src = sys.argv[1]
keep = ("com.apple.WebKi", "(XDict", "(Python)", "(python3", "(dscacheutil)")
out = []
for line in open(src, encoding="utf-8", errors="replace"):
    try:
        msg = json.loads(line).get("eventMessage", "")
    except ValueError:
        continue
    if any(k in msg for k in keep):
        out.append(line if line.endswith("\n") else line + "\n")
open(src + ".tmp", "w", encoding="utf-8").writelines(out)
os.replace(src + ".tmp", src)
PY
python3 -I "$kit/analyze.py" run "$dir" >"$dir/summary.json"
echo "run-app-hostile: done ($(python3 -I -c 'import json,sys; s=json.load(open(sys.argv[1])); print(sum(1 for v in s.get("cases", {}).values() if v["left"]), "cases left")' "$dir/summary.json"))"
