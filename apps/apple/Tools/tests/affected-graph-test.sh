#!/bin/bash
# The generated graph is the manifests' own: Tools/affected-graph.json is what `cargo metadata` and SwiftPM read from
# core/ and Package.swift now, and a graph made wrong by one edge is refused (the check's positive control). Needs
# cargo and swift, as `make test` does; reads no network (`cargo metadata --offline`).
set -uo pipefail
cd "$(dirname "$0")/.."
failures=0
ok() { echo "ok    $*"; }
bad() { echo "FAIL  $*"; failures=$((failures + 1)); }
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

if out=$(python3 -I affected_graph.py check 2>&1); then ok "$out"; else bad "$out"; fi
python3 -I - affected-graph.json "$scratch/wrong.json" <<'PY'
import json, sys
g = json.load(open(sys.argv[1]))
g["targets"]["XDictEntryLab"]["deps"].append("XDictSearch")
json.dump(g, open(sys.argv[2], "w"), indent=1, sort_keys=True)
PY
if XDICT_AFFECTED_GRAPH=$scratch/wrong.json python3 -I affected_graph.py check >/dev/null 2>&1; then
    bad "control: a graph with an edge SwiftPM does not have passed the check"
else ok "control: a graph with an edge SwiftPM does not have is refused"; fi

[ "$failures" -eq 0 ] && echo "affected-graph: all passed" || { echo "affected-graph: $failures failed"; exit 1; }
