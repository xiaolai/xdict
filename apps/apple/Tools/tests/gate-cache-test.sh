#!/bin/bash
# Tests of Tools/gate-cache.py: a gate or an E2E sub-stage runs only when its input key has no recorded pass. Built in a
# scratch repository with a map and a catalog of its own; reaches nothing and opens nothing.
set -uo pipefail
cd "$(dirname "$0")/.."
tool=$PWD/gate-cache.py
failures=0
ok() { echo "ok    $*"; }
bad() { echo "FAIL  $*"; failures=$((failures + 1)); }
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

repo=$scratch/repo
mkdir -p "$repo/core" "$repo/apps/apple/Sources/XDictSpeech" "$repo/apps/apple/Tools/lookup" "$repo/docs"
echo 'fn a() {}' >"$repo/core/a.rs"
echo 'let s = 1' >"$repo/apps/apple/Sources/XDictSpeech/s.swift"
echo 'x = 1' >"$repo/apps/apple/Tools/lookup/x.py"
echo 'notes' >"$repo/docs/n.md"
git -C "$repo" init -q && git -C "$repo" add -A && git -C "$repo" -c user.name=t -c user.email=t@t commit -qm init
cat >"$scratch/map" <<'MAP'
control hostile.production hostile.controls
*.md                                none
apps/apple/Sources/XDictSpeech/*    sound
apps/apple/Tools/lookup/*           check:lookup
apps/apple/Tools/hostile/*          check:hostile.production
core/*                              all
MAP
cat >"$scratch/catalog" <<'CAT'
@ launch default -
launch.ok
@ lookup.core default kit group=lookup
lookup.core.ok
@ hostile.production default kit
hostile.production.ok
@ hostile.controls default kit
hostile.controls.ok
@ sound.speech default fixtures group=sound
sound.speech.ok
@ sound.notices default fixtures group=sound
sound.notices.ok
@ entries.quick extra kit
entries.quick.ok
CAT
export XDICT_GATE_REPO=$repo XDICT_E2E_AFFECTED_MAP=$scratch/map XDICT_E2E_SUBSTAGES=$scratch/catalog
export XDICT_GATE_CACHE=$scratch/cache
gates="core apple-test e2e"
status() { python3 -I "$tool" status "$@" $gates; }
runs() { awk -F'\t' '$1 == "run" { print $2 }' | sort | tr '\n' ' '; }
record_all() { status | awk -F'\t' '$1 == "run" { print $2 "\t" $3 }' | while IFS=$'\t' read -r g k; do
    python3 -I "$tool" record "$g" "$k" 1 testhost || bad "record $g"; done; }

# Nothing recorded: everything runs, and says why.
out=$(status 2>&1)
[ "$(runs <<<"$out")" = "apple-test core e2e:hostile.controls e2e:hostile.production e2e:launch e2e:lookup.core e2e:sound.notices e2e:sound.speech " ] \
    && ok "no record: every gate and default sub-stage runs" || bad "no record: $out"
grep -q 'no pass recorded' <<<"$out" && ok "a miss says no pass is recorded" || bad "a miss gave no reason: $out"

record_all
out=$(status 2>&1)
[ -z "$(runs <<<"$out")" ] && ok "an unchanged tree selects nothing" || bad "unchanged tree ran: $(runs <<<"$out")"
grep -q '^skip	core	.*	20' <<<"$out" && ok "a skip names the date of its pass" || bad "skip without a date: $out"

# One byte of one product file: only the sub-stages the map gives it, and the apps gate.
printf 'let s = 2\n' >"$repo/apps/apple/Sources/XDictSpeech/s.swift"
out=$(status 2>&1)
[ "$(runs <<<"$out")" = "apple-test e2e:sound.notices e2e:sound.speech " ] \
    && ok "a one-file change selects only the sub-stages whose keys include it" || bad "one-file change: $(runs <<<"$out")"
grep -q 'e2e:sound.speech	.*apps/apple/Sources/XDictSpeech/s.swift' <<<"$out" \
    && ok "a run names the changed path" || bad "a run did not name the path: $out"
record_all

# A check's own code brings its positive control.
printf 'x = 2\n' >"$repo/apps/apple/Tools/lookup/x.py"
out=$(status 2>&1)
[ "$(runs <<<"$out")" = "apple-test e2e:lookup.core " ] && ok "a driver change selects its sub-stage" \
    || bad "driver change: $(runs <<<"$out")"
record_all
mkdir -p "$repo/apps/apple/Tools/hostile" && echo y >"$repo/apps/apple/Tools/hostile/a.py"
out=$(status 2>&1)
[ "$(runs <<<"$out")" = "apple-test e2e:hostile.controls e2e:hostile.production " ] \
    && ok "a check's code brings its control" || bad "check: rule: $(runs <<<"$out")"
record_all

# Notes select nothing; a path no rule names selects every sub-stage.
echo more >>"$repo/docs/n.md"
out=$(status 2>&1)
[ -z "$(runs <<<"$out")" ] && ok "a note selects nothing" || bad "a note ran: $(runs <<<"$out")"
echo z >"$repo/unmapped.txt"
out=$(status 2>&1)
[ "$(runs <<<"$out")" = "e2e:hostile.controls e2e:hostile.production e2e:launch e2e:lookup.core e2e:sound.notices e2e:sound.speech " ] \
    && ok "an unmapped path selects every sub-stage" || bad "unmapped: $(runs <<<"$out")"
record_all

# The core: its gate and every sub-stage.
echo '// x' >>"$repo/core/a.rs"
out=$(status 2>&1)
[ "$(runs <<<"$out")" = "apple-test core e2e:hostile.controls e2e:hostile.production e2e:launch e2e:lookup.core e2e:sound.notices e2e:sound.speech " ] \
    && ok "a core change runs the core gate and every sub-stage" || bad "core change: $(runs <<<"$out")"
record_all

# A host fact is part of the key.
out=$(python3 -I "$tool" status --fact rustc=1.99.1 core 2>&1)
[ "$(runs <<<"$out")" = "core " ] && ok "a changed toolchain fact runs the gate" || bad "fact: $out"

# FULL: everything, whatever is recorded.
out=$(status --full 2>&1)
[ "$(runs <<<"$out" | wc -w | tr -d ' ')" = 8 ] && ok "--full selects all" || bad "--full: $(runs <<<"$out")"

# Fail loud: a corrupt record selects everything, and says so.
cp "$scratch/cache/passes.tsv" "$scratch/good.tsv"
echo 'garbage line' >>"$scratch/cache/passes.tsv"
out=$(status 2>"$scratch/err")
[ "$(runs <<<"$out" | wc -w | tr -d ' ')" = 8 ] && grep -q corrupt "$scratch/err" \
    && ok "a corrupt record selects all, loudly" || bad "corrupt: $(runs <<<"$out") / $(cat "$scratch/err")"
cp "$scratch/good.tsv" "$scratch/cache/passes.tsv"
rm -rf "$scratch/cache/manifests"
out=$(status 2>"$scratch/err")
[ "$(runs <<<"$out" | wc -w | tr -d ' ')" = 8 ] && ok "a record whose manifests are gone selects all" \
    || bad "missing manifests: $(runs <<<"$out")"
rm -rf "$scratch/cache"
out=$(status 2>&1)
[ "$(runs <<<"$out" | wc -w | tr -d ' ')" = 8 ] && ok "a missing record selects all" || bad "missing: $(runs <<<"$out")"

# The selection agrees with Tools/e2e-affected.sh path by path, where that script decides (`all` aside).
for path in apps/apple/Sources/XDictSpeech/s.swift apps/apple/Tools/lookup/x.py apps/apple/Tools/hostile/a.py; do
    want=$(bash ./e2e-affected.sh --paths "$path" | sort | tr '\n' ' ')
    got=$(python3 -I "$tool" select-paths "$path" | sort | tr '\n' ' ')
    [ "$want" = "$got" ] && ok "same as e2e-affected for $path" || bad "$path: e2e-affected [$want], gate-cache [$got]"
done

# A release never reads the cache: its evidence stays fresh.
if grep -l 'gate-cache' release.sh e2e-status.sh >/dev/null 2>&1; then bad "release.sh or e2e-status.sh reads the gate cache"
else ok "the release path does not read the gate cache"; fi

[ "$failures" -eq 0 ] && echo "gate-cache: all passed" || { echo "gate-cache: $failures failed"; exit 1; }
