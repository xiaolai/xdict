#!/bin/bash
# Tests of Tools/e2e-ledger.py, the one record of E2E runs: a sub-stage is carried only by a pass under its current key
# (content, modes and facts), filed of the very bundle that was tested, not revoked by a later failure, in order, not
# from the future, recorded with a graph that was not stale; a ledger that cannot be trusted (corrupt, cut short,
# rolled back) carries nothing. **The release reads none of it** (owner, 2026-10-24: E2E is on demand, never a gate of
# any step): release.sh's contract, held below, is the smoke on the stapled bundle and the source tree asked again
# after the disk image's notarisation. Built in a scratch repository with a graph, a hand list and a catalog of its
# own; reaches no host and launches nothing.
set -uo pipefail
cd "$(dirname "$0")/.."
tool=$PWD/e2e-ledger.py
tools=$PWD
failures=0
ok() { echo "ok    $*"; }
bad() { echo "FAIL  $*"; failures=$((failures + 1)); }
scratch=$(mktemp -d)
trap 'chmod -R u+rw "$scratch" 2>/dev/null; rm -rf "$scratch"' EXIT

repo=$scratch/repo
mkdir -p "$repo/apps/apple/Sources/XDictSpeech" "$repo/apps/apple/Sources/XDict" "$repo/core/xdict-core/src"
echo 'let s = 1' >"$repo/apps/apple/Sources/XDictSpeech/s.swift"
echo 'let a = 1' >"$repo/apps/apple/Sources/XDict/a.swift"
echo 'fn a() {}' >"$repo/core/xdict-core/src/lib.rs"
echo '// package' >"$repo/apps/apple/Package.swift"
git -C "$repo" init -q && git -C "$repo" add -A && git -C "$repo" -c user.name=t -c user.email=t@t commit -qm init
graph() {  # graph <out> [stale]
    python3 -I - "$1" "$(git -C "$repo" hash-object apps/apple/Package.swift)" "${2:-}" <<'PY'
import json, sys
json.dump({"version": 1, "manifests": {"apps/apple/Package.swift": "0" * 40 if sys.argv[3] else sys.argv[2]},
           "crates": {"xdict-core": {"dir": "core/xdict-core/", "deps": [], "dev": []}},
           "targets": {"XDict": {"type": "executable", "dir": "apps/apple/Sources/XDict/", "deps": ["XDictSpeech"]},
                       "XDictSpeech": {"type": "regular", "dir": "apps/apple/Sources/XDictSpeech/", "deps": []}}},
          open(sys.argv[1], "w"))
PY
}
graph "$scratch/graph.json"
graph "$scratch/stale.json" stale
cat >"$scratch/map" <<'MAP'
apps/apple/Sources/XDictSpeech/*    sound.speech
MAP
cat >"$scratch/hand" <<'MAP'
launches *          XDict
apps/apple/Package.swift            all
MAP
cat >"$scratch/catalog" <<'CAT'
@ launch default -
launch.ok launch.two
@ sound.speech default fixtures group=sound
sound.speech.ok
@ measure.protocol extra -
measure.protocol.ok
CAT
export XDICT_GATE_REPO=$repo XDICT_AFFECTED_GRAPH=$scratch/graph.json XDICT_AFFECTED_HAND=$scratch/hand \
    XDICT_E2E_AFFECTED_MAP=$scratch/map XDICT_E2E_SUBSTAGES=$scratch/catalog XDICT_GATE_CACHE=$scratch/cache \
    XDICT_E2E_LEDGER=$scratch/share/e2e-ledger.tsv
ledger=$XDICT_E2E_LEDGER
subs="launch sound.speech measure.protocol"
facts() { echo --fact xcode=27.1/27B55 --fact "swift=${SWIFT:-6.3}" --fact rust=1.99.0 --fact "macos=${MACOS:-25A1}" --fact corpus=none; }
tree() {
    local index=$scratch/index.$$.$RANDOM
    GIT_INDEX_FILE=$index git -C "$repo" read-tree HEAD && GIT_INDEX_FILE=$index git -C "$repo" add --all :/ \
        && GIT_INDEX_FILE=$index git -C "$repo" write-tree
    rm -f "$index"
}
# bundle <dir> <tree>: a bundle whose build wrote its provenance (Tools/build-bundle.sh does, inside the signature).
bundle() {
    mkdir -p "$1/Contents/Resources"
    printf 'tree=%s\nxcode=27.1/27B55\nswift=%s\nrust=1.99.0\n' "$2" "${SWIFT:-6.3}" >"$1/Contents/Resources/Provenance.txt"
}
# lines <sub=pass|fail ...>: a run log as Tools/e2e.sh writes it, every check of each sub-stage reported.
lines() {
    local pair sub
    for pair in "$@"; do
        sub=${pair%%=*}
        for check in $(awk -v s="$sub" '$1 == "@" { on = ($2 == s); next } on { print }' "$scratch/catalog"); do
            printf 'RESULT\t%s\t%s\t%s\n' "$sub" "${pair#*=}" "$check"
        done
        printf 'TIME\t%s\t%s\n' "$sub" "${SECS:-90}"
    done
}
# record_log <log> [extra options]: file it, of a bundle of this tree unless BUNDLE names another.
record_log() {
    local log=$1 t
    shift
    t=${TREE:-$(tree)}
    [ -n "${BUNDLE:-}" ] || { bundle "$scratch/app.$$" "$t"; }
    python3 -I "$tool" record --fact "macos=${MACOS:-25A1}" --fact corpus=none --bundle "${BUNDLE:-$scratch/app.$$}" \
        --build 1.2 --host "${HOST:-HOSTUUID-1}" --os "27.0 (${MACOS:-25A1})" --tree "$t" --mode development "$@" <"$log"
}
record() { lines "$@" >"$scratch/log.$$"; record_log "$scratch/log.$$" >/dev/null || bad "record $*"; }
# plan_of [options]: `action sub why` lines of a release plan.
plan_of() { python3 -I "$tool" plan --release $(facts) "$@" $subs 2>"$scratch/err" | awk -F'\t' '{ print $1 " " $2 " " $4 }'; }
action() { awk -v s="$2" '$2 == s { print $1 }' <<<"$1"; }
runs() { awk '$1 == "run"' <<<"$1" | wc -l | tr -d ' '; }

# Nothing recorded: everything runs, and says so.
out=$(plan_of)
[ "$(runs "$out")" = 3 ] && grep -q 'no row for it' <<<"$out" && ok "an empty ledger carries nothing" || bad "empty: $out"

# Carried when unchanged: a pass under the same key.
record launch=pass sound.speech=pass measure.protocol=pass
out=$(plan_of)
[ "$(runs "$out")" = 0 ] && ok "an unchanged tree is carried, every sub-stage" || bad "unchanged: $out"
grep -q '^carried launch 20[0-9-]*T[0-9:]*Z HOSTUUID ' <<<"$out" && ok "a carried row names its date, host and key" \
    || bad "carried line: $out"
[ "$(wc -l <"$ledger" | tr -d ' ')" = 3 ] && grep -q "	$(git -C "$repo" rev-parse HEAD)	ok	1.2	" "$ledger" \
    && ok "a row a sub-stage, with the commit of a committed tree" || bad "rows: $(cat "$ledger")"

# **The evidence is the tested bundle's.** A bundle of tree A, recorded while the checkout is tree B and B is given as
# the run's tree, files nothing; nor does a supplied fact stand in for the bundle's own.
treeA=$(tree)
echo 'let a = 9' >"$repo/apps/apple/Sources/XDict/a.swift"
bundle "$scratch/appA" "$treeA"
lines launch=pass >"$scratch/logA"
before=$(wc -l <"$ledger" | tr -d ' ')
if BUNDLE=$scratch/appA record_log "$scratch/logA" >/dev/null 2>"$scratch/err"; then bad "a bundle of another tree was recorded"
else
    [ "$(wc -l <"$ledger" | tr -d ' ')" = "$before" ] && grep -q 'bundle was built of' "$scratch/err" \
        && ok "a bundle of tree A is refused for tree B, and files nothing" || bad "A/B: $(cat "$scratch/err")"
fi
rm -rf "$scratch/nobundle"; mkdir -p "$scratch/nobundle"
BUNDLE=$scratch/nobundle record_log "$scratch/logA" >/dev/null 2>&1 && bad "a bundle with no provenance was recorded" \
    || ok "a bundle with no provenance is refused"
echo 'let a = 1' >"$repo/apps/apple/Sources/XDict/a.swift"
# A bundle of this very tree, with a build fact supplied beside it: refused, not silently replaced.
lines launch=pass >"$scratch/logB"
before=$(wc -l <"$ledger" | tr -d ' ')
record_log "$scratch/logB" --fact xcode=99.0/99A1 >/dev/null 2>&1 && bad "a supplied build fact was accepted" \
    || { [ "$(wc -l <"$ledger" | tr -d ' ')" = "$before" ] && ok "build facts cannot be supplied to record; they are the bundle's" \
         || bad "a supplied build fact filed rows"; }
# A bundle built with another Swift is keyed as such: its pass carries nothing for this Swift.
SWIFT=6.4 record launch=pass
[ "$(action "$(SWIFT=6.4 plan_of)" launch)" = carried ] && [ "$(action "$(plan_of)" launch)" = carried ] \
    && ok "a pass is keyed with the Swift that built its bundle" || bad "provenance facts"

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

# **The recorder's boundary**: a verdict other than pass or fail is refused; a pass missing one of its checks is a fail.
printf 'RESULT\tlaunch\terror\tlaunch.ok\n' >"$scratch/log"
record_log "$scratch/log" >/dev/null 2>&1 && bad "a verdict 'error' was recorded" || ok "a verdict other than pass or fail is refused"
printf 'RESULT\tlaunch\tpass\tlaunch.ok\n' >"$scratch/log"
record_log "$scratch/log" >/dev/null 2>&1 || bad "a short run log could not be filed"
out=$(plan_of)
grep -q '^run launch failed last, .*launch.two' <<<"$out" && ok "a pass missing a check of its sub-stage is filed as a fail" \
    || bad "incomplete: $out / $(tail -1 "$ledger")"
record launch=pass

# **Order and time.** A pass filed after a newer failure (a recorder that stalled) does not resurrect the key; a row
# from the future carries nothing; a pass too old runs for a release, not for development.
XDICT_E2E_LEDGER_CLOCK=2030-01-02T00:00:00Z record launch=fail 2>/dev/null
out=$(plan_of)
[ "$(action "$out" launch)" = run ] && grep -q 'future' <<<"$out" && ok "a row from the future carries nothing" \
    || bad "future: $out"
record launch=pass
[ "$(action "$(plan_of)" launch)" = run ] && ok "a pass filed after a newer failure is not carried" || bad "out of order: $(plan_of)"
cp "$ledger" "$scratch/future.tsv"
rm -rf "$scratch/share"
XDICT_E2E_LEDGER_CLOCK=2020-01-01T00:00:00Z record launch=pass sound.speech=pass measure.protocol=pass
out=$(plan_of)
[ "$(runs "$out")" = 3 ] && grep -q 'too old: passed 2020-01-01' <<<"$out" && ok "a pass older than the max age runs for a release" \
    || bad "too old: $out"
out=$(python3 -I "$tool" plan $(facts) $subs 2>/dev/null | cut -f1 | sort -u)
[ "$out" = carried ] && ok "development skips ignore the age" || bad "dev age: $out"
[ "$(runs "$(plan_of --max-days 100000)")" = 0 ] && ok "--max-days moves the bound" || bad "max-days"
for days in nan inf 0 -1 x; do
    python3 -I "$tool" plan --release --max-days "$days" $(facts) $subs >/dev/null 2>&1 \
        && bad "--max-days $days was accepted" || ok "--max-days $days is refused"
done
XDICT_E2E_LEDGER_CLOCK=2020-01-01T00:00:01Z record launch=fail
XDICT_E2E_LEDGER_CLOCK=2020-01-01T00:00:00Z record launch=pass
[ "$(action "$(plan_of --max-days 100000)" launch)" = run ] && ok "an older pass appended after a newer failure is rejected" \
    || bad "older pass"
rm -rf "$scratch/share"
record launch=pass sound.speech=pass measure.protocol=pass
cp "$ledger" "$scratch/good.tsv"; cp "$ledger.head" "$scratch/good.head"
restore() { rm -f "$ledger" "$ledger.head"; cp "$scratch/good.tsv" "$ledger"; cp "$scratch/good.head" "$ledger.head"; }

# Another macOS build on the E2E Mac runs everything, and names the fact; another Mac of the same build carries.
out=$(MACOS=25A2 plan_of)
[ "$(runs "$out")" = 3 ] && grep -q 'fact macos=25A1 -> macos=25A2' <<<"$out" && ok "a different macOS build runs, and says so" \
    || bad "macos: $out"
rm -rf "$scratch/share"
HOST=HOSTUUID-2 record launch=pass sound.speech=pass measure.protocol=pass
[ "$(runs "$(plan_of)")" = 0 ] && ok "another E2E Mac of the same build carries" || bad "two Macs"

# A pass recorded with a stale graph carries nothing.
rm -rf "$scratch/share"
XDICT_AFFECTED_GRAPH=$scratch/stale.json record launch=pass sound.speech=pass measure.protocol=pass 2>/dev/null
out=$(plan_of)
[ "$(runs "$out")" = 3 ] && ok "a pass recorded with a stale graph is not carried" || bad "stale row: $out"
restore

# **Integrity.** Corrupt, unreadable, an unfinished last line, a row edited, the ledger cut short or rolled back: nothing
# is carried, and stderr says why.
integrity() {  # integrity <what> <grep for the reason>
    local out
    out=$(plan_of)
    [ "$(runs "$out")" = 3 ] && grep -q "$2" "$scratch/err" && ok "$1 carries nothing, and says so" \
        || bad "$1: $out / $(cat "$scratch/err")"
    restore
}
echo 'garbage' >>"$ledger"; integrity "a corrupt ledger" 'corrupt at line'
printf 'v2\tpartial' >>"$ledger"; integrity "an unfinished last line" 'unfinished'
sed -i.bak '2s/	pass	/	fail	/' "$ledger"; integrity "an edited row" 'chain'
sed -i.bak '$d' "$ledger"; integrity "a ledger cut short of its last row" 'head'
lines launch=fail >"$scratch/log"; record_log "$scratch/log" >/dev/null 2>&1
cp "$scratch/good.tsv" "$ledger"; out=$(plan_of)
[ "$(runs "$out")" = 3 ] && grep -q 'head' "$scratch/err" && ok "a ledger rolled back before its last failure is detected" \
    || bad "rollback: $out / $(cat "$scratch/err")"
restore
chmod 000 "$ledger"
if [ -r "$ledger" ]; then ok "an unreadable ledger (skipped: this user reads a mode-000 file)"
else integrity "an unreadable ledger" unreadable; fi
chmod 644 "$ledger" 2>/dev/null || true

# A key without its facts is refused, not computed.
python3 -I "$tool" plan --fact xcode=27.1 launch >/dev/null 2>"$scratch/err" && bad "a plan without facts ran" \
    || { grep -q 'no fact for swift, rust, macos, corpus' "$scratch/err" && ok "a plan without its facts is refused" \
         || bad "facts refusal: $(cat "$scratch/err")"; }

# A path neither the map nor the graph knows changes every key; so does a file's mode alone.
echo z >"$repo/unknown.txt"
[ "$(runs "$(plan_of)")" = 3 ] && ok "an unknown path runs every sub-stage" || bad "unknown"
rm "$repo/unknown.txt"
chmod +x "$repo/apps/apple/Sources/XDict/a.swift"
[ "$(runs "$(plan_of)")" = 3 ] && ok "a mode change alone runs what the file reaches" || bad "mode: $(plan_of)"
chmod -x "$repo/apps/apple/Sources/XDict/a.swift"

# The evaluator's own code is part of every key: a copy of the tools with one evaluator edited carries nothing.
mkdir -p "$scratch/tools"
cp "$tools/e2e-ledger.py" "$tools/gate-cache.py" "$tools/affected_graph.py" "$tools/e2e-plan.sh" "$scratch/tools/"
[ "$(python3 -I "$scratch/tools/e2e-ledger.py" plan $(facts) $subs 2>/dev/null | cut -f1 | sort -u)" = carried ] \
    || bad "an unedited copy of the tools does not carry"
for file in gate-cache.py affected_graph.py e2e-ledger.py; do
    cp "$tools/$file" "$scratch/tools/$file"; echo '# edited' >>"$scratch/tools/$file"
    out=$(python3 -I "$scratch/tools/e2e-ledger.py" plan $(facts) $subs 2>/dev/null | cut -f1 | sort -u)
    [ "$out" = run ] && ok "an edit to $file changes every key" || bad "$file edited: $out"
    cp "$tools/$file" "$scratch/tools/$file"
done

# release-plan's numbers: the minutes of what runs, from recorded seconds (90 s each; 60 where none).
echo 'let a = 2' >"$repo/apps/apple/Sources/XDict/a.swift"
out=$(python3 -I "$tool" plan --release --human $(facts) $subs 2>/dev/null)
grep -q '^to run: 3 of 3, about 5 min' <<<"$out" && ok "release-plan totals 3 x 90 s as 5 min" || bad "numbers: $out"
SECS=600 record launch=pass
out=$(python3 -I "$tool" plan --release --human $(facts) $subs 2>/dev/null)
grep -q '^to run: 2 of 3, about 3 min' <<<"$out" && grep -q '^launch .* carried ' <<<"$out" \
    && ok "release-plan counts only what runs (2 x 90 s)" || bad "numbers after a pass: $out"

# Concurrent writers, each with a key whose manifest is new: every record completes and every row is filed and keyed.
echo 'let a = 3' >"$repo/apps/apple/Sources/XDict/a.swift"
before=$(wc -l <"$ledger" | tr -d ' ')
TREE=$(tree); export TREE
for i in 1 2 3 4 5 6; do record launch=pass sound.speech=pass & done; wait
unset TREE
[ "$(wc -l <"$ledger" | tr -d ' ')" = $((before + 12)) ] && [ -z "$(tail -12 "$ledger" | awk -F'\t' '$5 == "-"')" ] \
    && [ "$(runs "$(plan_of)")" = 1 ] && ok "six concurrent records of a new key file every row, keyed, chained" \
    || bad "concurrent: $(wc -l <"$ledger") rows, wanted $((before + 12)); $(cat "$scratch/err")"

# show: the last rows, by sub-stage.
out=$(python3 -I "$tool" show --last 2 --stage sound)
[ "$(grep -c '^20.* sound.speech ' <<<"$out")" = 2 ] && ok "show filters by stage and counts rows" || bad "show: $out"

# **The corpus by content**: the same length and time, other bytes, is another corpus.
mkdir -p "$scratch/corpus/d"
printf 'AAAAAAAA' >"$scratch/corpus/d/a.mdx"; touch -t 202001010000 "$scratch/corpus/d/a.mdx"
one=$(python3 -I "$tools/gate-cache.py" corpus-id "$scratch/corpus")
printf 'BBBBBBBB' >"$scratch/corpus/d/a.mdx"; touch -t 202001010000 "$scratch/corpus/d/a.mdx"
two=$(python3 -I "$tools/gate-cache.py" corpus-id "$scratch/corpus")
[ -n "$one" ] && [ "$one" != "$two" ] && ok "a corpus file replaced at equal size and time changes the corpus id" \
    || bad "corpus id: $one $two"

# **Static contracts of the release and the run**, each held to a copy without it (the positive control).
# The smoke runs on the stapled release bundle, unconditionally.
smoke_runs() {
    # An environment prefix before XDICT_E2E_TREE is allowed: the release's smoke carries `E2E_REQUESTED=1`, the run's
    # own permission (2026-10-23). What is held is the order, on the stapled bundle.
    awk '/XDICT_E2E_TREE=.*Tools\/e2e\.sh "\$XDICT_E2E_HOST" \$\(Tools\/e2e-status\.sh smoke\)/ { found = NR }
         /^staple "\$APP"$/ { stapled = NR }
         END { exit !(found && stapled && found > stapled) }' "$1"
}
# **The release asks the tree again after the disk image is notarised** (owner, 2026-10-24: E2E is never a gate of any
# step; a release names its source tree): an edit during notarisation still stops it, before anything is announced.
tree_last() {
    awk '/^staple "\$dmg"$/ { dmg = NR } /Tools\/source-tree\.sh\)" = "\$tree"/ { last = NR }
         /^note "released XDict/ { done = NR }
         END { exit !(dmg && last > dmg && done > last) }' "$1"
}
contract() {  # contract <what> <check> <file> <line pattern to drop for the control>
    "$2" "$3" && ok "$1" || bad "$1"
    grep -v "$4" "$3" >"$scratch/control"
    "$2" "$scratch/control" && bad "the check of '$1' passes without it" || ok "the check of '$1' fails without it"
}
contract "release.sh runs the smoke after stapling" smoke_runs "$tools/release.sh" 'e2e-status.sh smoke) \\$'
contract "release.sh checks the source tree after the disk image's notarisation" tree_last "$tools/release.sh" \
    'Tools/source-tree.sh)" = "\$tree"'
# The sample and the editions are reused only for the same corpus content (its id), not its path.
corpus_keyed() { [ "$(grep -c 'cat "\$sample.corpus".*= "\$corpus_id"\|cat "\$editions.corpus".*= "\$corpus_id"' "$1")" = 2 ]; }
contract "e2e.sh reuses the sample and editions only for the same corpus id" corpus_keyed "$tools/e2e.sh" 'cat "\$sample.corpus"'
[ "$(bash "$tools/e2e-status.sh" smoke)" = launch ] && ok "the smoke is named once: launch" || bad "smoke: $(bash "$tools/e2e-status.sh" smoke)"

[ "$failures" -eq 0 ] && echo "e2e-ledger: all passed" || { echo "e2e-ledger: $failures failed"; exit 1; }
