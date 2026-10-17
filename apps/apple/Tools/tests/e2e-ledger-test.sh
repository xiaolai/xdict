#!/bin/bash
# Tests of Tools/e2e-ledger.py, the one record of E2E runs, and of the release's contract with it: a sub-stage is
# carried only by a pass under its current key (content and facts), not revoked by a later failure, recorded with a
# graph that was not stale, and, for a release, young enough; a ledger that cannot be trusted carries nothing; the
# release smoke runs whatever the ledger says. Built in a scratch repository with a graph, a hand list and a catalog
# of its own; reaches no host and launches nothing.
set -uo pipefail
cd "$(dirname "$0")/.."
tool=$PWD/e2e-ledger.py
tools=$PWD
failures=0
ok() { echo "ok    $*"; }
bad() { echo "FAIL  $*"; failures=$((failures + 1)); }
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

repo=$scratch/repo
mkdir -p "$repo/apps/apple/Sources/XDictSpeech" "$repo/apps/apple/Sources/XDict" "$repo/core/xdict-core/src"
echo 'let s = 1' >"$repo/apps/apple/Sources/XDictSpeech/s.swift"
echo 'let a = 1' >"$repo/apps/apple/Sources/XDict/a.swift"
echo 'fn a() {}' >"$repo/core/xdict-core/src/lib.rs"
echo '// package' >"$repo/apps/apple/Package.swift"
git -C "$repo" init -q && git -C "$repo" add -A && git -C "$repo" -c user.name=t -c user.email=t@t commit -qm init
python3 -I - "$scratch/graph.json" "$(git -C "$repo" hash-object apps/apple/Package.swift)" <<'PY'
import json, sys
json.dump({"version": 1, "manifests": {"apps/apple/Package.swift": sys.argv[2]},
           "crates": {"xdict-core": {"dir": "core/xdict-core/", "deps": [], "dev": []}},
           "targets": {"XDict": {"type": "executable", "dir": "apps/apple/Sources/XDict/", "deps": ["XDictSpeech"]},
                       "XDictSpeech": {"type": "regular", "dir": "apps/apple/Sources/XDictSpeech/", "deps": []}}},
          open(sys.argv[1], "w"))
PY
cat >"$scratch/map" <<'MAP'
apps/apple/Sources/XDictSpeech/*    sound.speech
MAP
cat >"$scratch/hand" <<'MAP'
launches *          XDict
apps/apple/Package.swift            all
MAP
cat >"$scratch/catalog" <<'CAT'
@ launch default -
launch.ok
@ sound.speech default fixtures group=sound
sound.speech.ok
@ measure.protocol extra -
measure.ok
CAT
export XDICT_GATE_REPO=$repo XDICT_AFFECTED_GRAPH=$scratch/graph.json XDICT_AFFECTED_HAND=$scratch/hand \
    XDICT_E2E_AFFECTED_MAP=$scratch/map XDICT_E2E_SUBSTAGES=$scratch/catalog XDICT_GATE_CACHE=$scratch/cache \
    XDICT_E2E_LEDGER=$scratch/share/e2e-ledger.tsv
ledger=$XDICT_E2E_LEDGER
subs="launch sound.speech measure.protocol"
facts() { echo --fact xcode=27.1 --fact swift=6.3 --fact rust=1.99.0 --fact "macos=${MACOS:-25A1}" --fact corpus=none; }
tree() {
    local index=$scratch/index
    rm -f "$index"
    GIT_INDEX_FILE=$index git -C "$repo" read-tree HEAD && GIT_INDEX_FILE=$index git -C "$repo" add --all :/ \
        && GIT_INDEX_FILE=$index git -C "$repo" write-tree
}
# record <result per sub, as sub=pass|fail ...>: one run, as Tools/e2e.sh files it.
record() {
    local pair
    for pair in "$@"; do
        printf 'RESULT\t%s\t%s\t%s\n' "${pair%%=*}" "${pair#*=}" "${pair%%=*}.ok"
        printf 'TIME\t%s\t%s\n' "${pair%%=*}" "${SECS:-90}"
    done | python3 -I "$tool" record $(facts) --build 1.2 --host HOSTUUID-1 --os "27.0 (${MACOS:-25A1})" \
        --tree "${TREE:-$(tree)}" --mode development >/dev/null || bad "record $*"
}
# plan_of [options]: `action sub why` lines of a release plan.
plan_of() { python3 -I "$tool" plan --release $(facts) "$@" $subs 2>"$scratch/err" | awk -F'\t' '{ print $1 " " $2 " " $4 }'; }
action() { awk -v s="$2" '$2 == s { print $1 }' <<<"$1"; }

# Nothing recorded: everything runs, and says so.
out=$(plan_of)
[ "$(awk '$1 == "run"' <<<"$out" | wc -l | tr -d ' ')" = 3 ] && grep -q 'no row for it' <<<"$out" \
    && ok "an empty ledger carries nothing" || bad "empty: $out"

# Carried when unchanged: a pass under the same key.
record launch=pass sound.speech=pass measure.protocol=pass
out=$(plan_of)
[ -z "$(awk '$1 == "run"' <<<"$out")" ] && ok "an unchanged tree is carried, every sub-stage" || bad "unchanged: $out"
grep -q '^carried launch 20[0-9-]*T[0-9:]*Z HOSTUUID ' <<<"$out" && ok "a carried row names its date, host and key" \
    || bad "carried line: $out"
[ "$(wc -l <"$ledger" | tr -d ' ')" = 3 ] && grep -q "	$(git -C "$repo" rev-parse HEAD)	ok	1.2$" "$ledger" \
    && ok "a row a sub-stage, with the commit of a committed tree" || bad "rows: $(cat "$ledger")"

# Run when an input changed, naming it; only what it reaches.
echo 'let s = 2' >"$repo/apps/apple/Sources/XDictSpeech/s.swift"
out=$(plan_of)
[ "$(action "$out" sound.speech)" = run ] && [ "$(action "$out" launch)" = carried ] \
    && ok "a changed input runs what it reaches, and only that" || bad "changed input: $out"
grep -q '^run sound.speech changed: apps/apple/Sources/XDictSpeech/s.swift$' <<<"$out" \
    && ok "the reason names the first changed input" || bad "reason: $out"
record sound.speech=pass

# A later failure on the same key revokes the pass.
record launch=fail
out=$(plan_of)
grep -q '^run launch failed last, .* (launch.ok)$' <<<"$out" && ok "a later failure revokes a pass" || bad "revoke: $out"
record launch=pass
[ "$(action "$(plan_of)" launch)" = carried ] && ok "a pass after the failure carries again" || bad "re-pass"

# Too old runs, for a release only.
cp "$ledger" "$scratch/good.tsv"
sed -i.bak 's/	20[0-9][0-9]-[0-9-]*T/	2020-01-01T/' "$ledger"
out=$(plan_of)
[ "$(awk '$1 == "run"' <<<"$out" | wc -l | tr -d ' ')" = 3 ] && grep -q 'too old: passed 2020-01-01' <<<"$out" \
    && ok "a pass older than the max age runs for a release" || bad "too old: $out"
out=$(python3 -I "$tool" plan $(facts) $subs 2>/dev/null | cut -f1 | sort -u)
[ "$out" = carried ] && ok "development skips ignore the age" || bad "dev age: $out"
out=$(plan_of --max-days 100000)
[ -z "$(awk '$1 == "run"' <<<"$out")" ] && ok "--max-days moves the bound" || bad "max-days: $out"
cp "$scratch/good.tsv" "$ledger"

# Another macOS build on the E2E Mac runs everything, and names the fact.
out=$(MACOS=25A2 plan_of)
[ "$(awk '$1 == "run"' <<<"$out" | wc -l | tr -d ' ')" = 3 ] && grep -q 'fact macos=25A1 -> macos=25A2' <<<"$out" \
    && ok "a different macOS build runs, and says so" || bad "macos: $out"
# Two Macs of one build are one evidence: a row from another host under the same key carries.
sed 's/HOSTUUID-1/HOSTUUID-2/' "$ledger" >"$scratch/two.tsv" && cp "$scratch/two.tsv" "$ledger"
[ -z "$(plan_of | awk '$1 == "run"')" ] && ok "another E2E Mac of the same build carries" || bad "two Macs"
cp "$scratch/good.tsv" "$ledger"

# A pass recorded with a stale graph carries nothing.
sed 's/	ok	1\.2$/	stale	1.2/' "$ledger" >"$scratch/stale.tsv" && cp "$scratch/stale.tsv" "$ledger"
out=$(plan_of)
[ "$(awk '$1 == "run"' <<<"$out" | wc -l | tr -d ' ')" = 3 ] && grep -q 'stale graph' <<<"$out" \
    && ok "a pass recorded with a stale graph is not carried" || bad "stale row: $out"
cp "$scratch/good.tsv" "$ledger"

# Corrupt or unreadable: nothing carried, loudly.
echo 'garbage' >>"$ledger"
out=$(plan_of)
[ "$(awk '$1 == "run"' <<<"$out" | wc -l | tr -d ' ')" = 3 ] && grep -q 'corrupt at line' "$scratch/err" \
    && ok "a corrupt ledger carries nothing, and says so" || bad "corrupt: $out / $(cat "$scratch/err")"
cp "$scratch/good.tsv" "$ledger"
chmod 000 "$ledger"
if [ -r "$ledger" ]; then ok "an unreadable ledger (skipped: this user reads a mode-000 file)"
else
    out=$(plan_of)
    [ "$(awk '$1 == "run"' <<<"$out" | wc -l | tr -d ' ')" = 3 ] && grep -q unreadable "$scratch/err" \
        && ok "an unreadable ledger carries nothing" || bad "unreadable: $out"
fi
chmod 644 "$ledger"

# A key without its facts is refused, not computed.
python3 -I "$tool" plan --fact xcode=27.1 launch >/dev/null 2>"$scratch/err" && bad "a plan without facts ran" \
    || { grep -q 'no fact for swift, rust, macos, corpus' "$scratch/err" && ok "a plan without its facts is refused" \
         || bad "facts refusal: $(cat "$scratch/err")"; }

# A path neither the map nor the graph knows changes every key.
echo z >"$repo/unknown.txt"
out=$(plan_of)
[ "$(awk '$1 == "run"' <<<"$out" | wc -l | tr -d ' ')" = 3 ] && ok "an unknown path runs every sub-stage" || bad "unknown: $out"
rm "$repo/unknown.txt"

# release-plan's numbers: the minutes of what runs, from recorded seconds (90 s each; 60 where none).
echo 'let a = 2' >"$repo/apps/apple/Sources/XDict/a.swift"
out=$(python3 -I "$tool" plan --release --human $(facts) $subs 2>/dev/null)
grep -q '^to run: 3 of 3, about 5 min' <<<"$out" && ok "release-plan totals 3 x 90 s as 5 min" || bad "numbers: $out"
SECS=600 record launch=pass
out=$(python3 -I "$tool" plan --release --human $(facts) $subs 2>/dev/null)
grep -q '^to run: 2 of 3, about 3 min' <<<"$out" && grep -q '^launch .* carried ' <<<"$out" \
    && ok "release-plan counts only what runs (2 x 90 s)" || bad "numbers after a pass: $out"

# Two writers at once lose no row and key every row. No positive control: with the lock removed this still passes,
# because one short O_APPEND write is already whole on APFS; the lock (flock) is for the guarantee POSIX does not give.
before=$(wc -l <"$ledger" | tr -d ' ')
TREE=$(tree); export TREE
for i in 1 2 3 4; do record launch=pass sound.speech=pass & done; wait
unset TREE
[ "$(wc -l <"$ledger" | tr -d ' ')" = $((before + 8)) ] && [ -z "$(tail -8 "$ledger" | awk -F'\t' '$5 == "-"')" ] && ok "four concurrent records file every row" \
    || bad "concurrent: $(wc -l <"$ledger") rows, wanted $((before + 8))"

# show: the last rows, by sub-stage.
out=$(python3 -I "$tool" show --last 2 --stage sound)
[ "$(grep -c '^20.* sound.speech ' <<<"$out")" = 2 ] && ok "show filters by stage and counts rows" || bad "show: $out"

# **The release smoke always runs.** Tools/release.sh runs RELEASE_SMOKE on the release-signed bundle unconditionally,
# after the evidence and the stapling; the check is held to a copy without it (the positive control).
smoke_runs() {
    awk '/^XDICT_E2E_TREE=.*Tools\/e2e\.sh "\$XDICT_E2E_HOST" \$\(Tools\/e2e-status\.sh smoke\)/ { found = NR }
         /^staple "\$APP"$/ { stapled = NR }
         END { exit !(found && stapled && found > stapled) }' "$1"
}
smoke_runs "$tools/release.sh" && ok "release.sh runs the smoke after stapling, unconditionally" || bad "release.sh: no smoke"
grep -v 'e2e-status.sh smoke) \\$' "$tools/release.sh" >"$scratch/release-nosmoke.sh"
smoke_runs "$scratch/release-nosmoke.sh" && bad "the smoke check passes a release.sh without it" \
    || ok "the smoke check fails a release.sh without the smoke"
[ "$(bash "$tools/e2e-status.sh" smoke)" = launch ] && ok "the smoke is named once: launch" || bad "smoke: $(bash "$tools/e2e-status.sh" smoke)"

[ "$failures" -eq 0 ] && echo "e2e-ledger: all passed" || { echo "e2e-ledger: $failures failed"; exit 1; }
