#!/bin/bash
# One observed run of the entry view's lab, on the E2E Mac (plan-macos-v1 WI-4), adapted from spike 3's `run-one.sh`:
# the observers up and each shown one deliberate attempt, the lab started by LaunchServices in the GUI session, late
# egress waited for, the DNS oracle asked, everything stopped, the run analysed.
#
#   run-hostile.sh <kit> <results-dir> <label> hostile [--disable-layer L,…]   the battery, with those layers off
#   run-hostile.sh <kit> <results-dir> <label> reader                          the reader entry, driven by reader.py
#
# Exits non-zero when the run did not happen as described (an observer not listening, no report from the lab): a run
# that silently did nothing must not read as a run where nothing left.
set -euo pipefail
kit=$(cd "$1" && pwd)
res=$2
label=$3
mode=$4
shift 4
dir="$res/$label"
rm -rf "$dir"
mkdir -p "$dir"
dir=$(cd "$dir" && pwd)
app="$kit/XDictEntryLab.app"
exe="$app/Contents/MacOS/XDictEntryLab"
[ -x "$exe" ] || { echo "run-hostile: no lab at $app" >&2; exit 1; }
cp "$kit/cases.json" "$dir/cases.json"

# By the executable `ps` reports, compared whole: never a pattern or a name.
lab_running() {
    local table pid executable
    table=$(ps -axww -o pid=,comm=) || { echo "run-hostile: ps failed" >&2; exit 1; }
    while read -r pid executable; do [ "$executable" != "$exe" ] || return 0; done <<<"$table"
    return 1
}
lab_pids() { ps -axww -o pid=,comm= | awk -v exe="$exe" '{ pid = $1; $1 = ""; sub(/^ /, ""); if ($0 == exe) print pid }'; }
lab_running && { echo "run-hostile: a lab is already running" >&2; exit 1; }

read -r ctl_http ctl_tcp ctl_udp budget selftest < <(python3 -I -c '
import json, sys
b = json.load(open(sys.argv[1]))
print(b["control"]["http"], b["control"]["tcp"], b["control"]["udp"],
      int(sum(c["wait"] for c in b["cases"]) / 1000 / 2) + 120, b["selftestName"])
' "$dir/cases.json")

obs=""
dns=""
cleanup() {
    [ -z "$dns" ] || kill "$dns" 2>/dev/null || true
    [ -z "$obs" ] || kill "$obs" 2>/dev/null || true
    local pid
    for pid in $(lab_pids); do kill "$pid" 2>/dev/null || true; done
}
trap cleanup EXIT

python3 -I "$kit/observe.py" --cases "$dir/cases.json" --log "$dir/observed.jsonl" --ready "$dir/ready.flag" \
    2>"$dir/observe.err" &
obs=$!
for _ in $(seq 1 80); do
    [ -f "$dir/ready.flag" ] && break
    kill -0 "$obs" 2>/dev/null || { echo "run-hostile: the observer died: $(cat "$dir/observe.err")" >&2; exit 1; }
    sleep 0.25
done
[ -f "$dir/ready.flag" ] || { echo "run-hostile: the observer never became ready" >&2; exit 1; }

/usr/bin/log stream --style ndjson --predicate 'process == "mDNSResponder"' >"$dir/dns.ndjson" 2>"$dir/dns.err" &
dns=$!
sleep 3
kill -0 "$dns" 2>/dev/null || { echo "run-hostile: log stream died: $(cat "$dir/dns.err")" >&2; exit 1; }

# Each observer's positive control: one deliberate attempt of its own kind, before anything is counted.
curl -s -m 3 -o /dev/null "http://127.0.0.1:$ctl_http/control/selftest" || true
python3 -I -c 'import socket, sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), 3).close()' "$ctl_tcp"
python3 -I -c 'import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.sendto(b"\x00\x01\x00\x00\x21\x12\xa4\x42" + b"\x00" * 12, ("127.0.0.1", int(sys.argv[1])))' "$ctl_udp"
dscacheutil -q host -a name "$selftest" >/dev/null 2>&1 || true
sleep 1

date +%s >"$dir/lab.started"
case $mode in
    hostile)
        open -n --stdout "$dir/lab.out" --stderr "$dir/lab.err" "$app" --args \
            --hostile "$kit/fixtures/hostile" --cases "$dir/cases.json" --out "$dir/report.json" "$@"
        ;;
    reader)
        budget=240
        mkdir -p "$dir/commands"
        open -n --stdout "$dir/lab.out" --stderr "$dir/lab.err" "$app" --args \
            --reader "$kit/fixtures/hostile" --commands "$dir/commands" --out "$dir/report.json"
        python3 -I "$kit/reader.py" "$kit" "$dir/commands" "$dir/steps.json" >"$dir/reader.log" 2>&1 \
            || { echo "run-hostile: reader.py failed: $(tail -3 "$dir/reader.log")" >&2; exit 1; }
        ;;
    *) echo "run-hostile: no mode $mode" >&2; exit 2 ;;
esac
waited=0
gone=0
while [ ! -s "$dir/report.json" ] && [ "$waited" -lt $((budget * 4)) ]; do
    sleep 0.25
    waited=$((waited + 1))
    # A lab that exited without a report ends the wait early; three misses in a row, not one (spike 3).
    if [ "$waited" -gt 40 ] && ! lab_running; then gone=$((gone + 1)); else gone=0; fi
    [ "$gone" -ge 3 ] && break
done
for _ in $(seq 1 40); do lab_running || break; sleep 0.25; done
if lab_running; then
    for pid in $(lab_pids); do kill "$pid" 2>/dev/null || true; done
    echo "run-hostile: the lab had to be killed" >>"$dir/lab.err"
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

[ -s "$dir/report.json" ] || { echo "run-hostile: $label: the lab wrote no report: $(tail -5 "$dir/lab.err")" >&2; exit 1; }
# Only the lines the analysis reads: WebKit's, the lab's, the oracle's and the self-test's (spike 3's trim).
python3 -I - "$dir/dns.ndjson" <<'PY'
import json, os, sys
src = sys.argv[1]
keep = ("com.apple.WebKi", "XDictEntryLab", "(Python)", "(python3", "(dscacheutil)")
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
if [ "$mode" = hostile ]; then
    python3 -I "$kit/analyze.py" run "$dir" >"$dir/summary.json"
else
    python3 -I "$kit/analyze.py" reader "$dir" >"$dir/summary.json"
fi
echo "run-hostile: $label done ($(python3 -I -c 'import json,sys; s=json.load(open(sys.argv[1])); print(sum(1 for v in s.get("cases", {}).values() if v["left"]), "cases left")' "$dir/summary.json"))"
