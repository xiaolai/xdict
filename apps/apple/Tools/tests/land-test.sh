#!/bin/bash
# Tests of Tools/land.sh that reach no host: ssh and rsync are stubs that refuse and log. Every gate already passed
# prints `cached pass`, asks no host and exits 0; a corrupt cache runs everything, and with no host fit for it, fails
# red with the command that re-runs each gate alone. Runs no E2E: its last line only says what is pending.
set -uo pipefail
cd "$(dirname "$0")/../.."
failures=0
ok() { echo "ok    $*"; }
bad() { echo "FAIL  $*"; failures=$((failures + 1)); }
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/corpus/one"
echo x >"$scratch/corpus/one/a.txt"
for tool in ssh rsync; do
    printf '#!/bin/bash\necho "%s $*" >>"%s/called"\nexit 255\n' "$tool" "$scratch" >"$scratch/bin/$tool"
    chmod +x "$scratch/bin/$tool"
done
printf 'BUILD_HOSTS = stub-a stub-b\nBUILD_HOSTS_XCODE = stub-x\nBUILD_HOST = stub-x\n' >"$scratch/local.mk"
export XDICT_GATE_CACHE=$scratch/cache XDICT_LAND_CORPUS=$scratch/corpus XDICT_LAND_LOCAL_MK=$scratch/local.mk
land() { PATH=$scratch/bin:$PATH bash Tools/land.sh >"$scratch/out" 2>&1; }

# A gate's command is part of its key: the same land.sh with one gate's command edited gives that gate other facts.
cp Tools/land.sh "$scratch/land-edited.sh"
sed -i.bak 's/cargo test -p xdict-core --no-run -q/cargo test -p xdict-core --no-run/' "$scratch/land-edited.sh"
mkdir -p "$scratch/Tools" && cp "$scratch/land-edited.sh" "$scratch/Tools/land.sh"
if [ "$(bash Tools/land.sh --facts-of core x)" != "$(bash "$scratch/Tools/land.sh" --facts-of core x)" ] \
    && [ "$(bash Tools/land.sh --facts-of mdx-v3 x)" = "$(bash "$scratch/Tools/land.sh" --facts-of mdx-v3 x)" ]; then
    ok "an edited gate command changes that gate's facts, and no other's"
else bad "a gate's command is not in its facts"; fi

# Every gate recorded as passed, under the facts land.sh names.
corpus=$(python3 -I Tools/gate-cache.py corpus-id "$scratch/corpus")
for g in core apple-test entries lookup-corpus mdx-v3 bindings memory; do
    facts=()
    while IFS= read -r a; do facts+=("$a"); done < <(bash Tools/land.sh --facts-of "$g" "$corpus")
    key=$(python3 -I Tools/gate-cache.py status "${facts[@]}" "$g" 2>/dev/null | cut -f3)
    python3 -I Tools/gate-cache.py record "$g" "$key" 1 test || bad "record $g"
done

if land; then ok "every gate cached: exit 0"; else bad "all cached exited non-zero: $(tail -5 "$scratch/out")"; fi
[ "$(grep -c 'cached pass' "$scratch/out")" -ge 7 ] && ok "each gate says cached pass" || bad "cached lines: $(grep -c 'cached pass' "$scratch/out")"
[ ! -s "$scratch/called" ] && ok "all cached asks no host" || bad "called: $(cat "$scratch/called")"
tail -1 "$scratch/out" | grep -q '^E2E' && ok "the last line says what E2E is pending" || bad "last line: $(tail -1 "$scratch/out")"
grep -q 'make e2e\b' "$scratch/out" && bad "land ran or offered an E2E run" || ok "land runs no E2E"

# A corrupt record: everything runs; no host answers, so every gate fails, red, with its re-run command.
echo garbage >>"$scratch/cache/passes.tsv"
if land; then bad "a corrupt cache with no reachable host exited 0"; else ok "a corrupt cache runs every gate, and red here"; fi
grep -q 'corrupt' "$scratch/out" && ok "the corruption is said" || bad "corruption not said"
grep -q 'stub-a skipped: unreachable' "$scratch/out" && ok "an unfit host is skipped with its reason" || bad "no skip reason"
grep -q 're-run only core: make -C apps/apple land ONLY=core' "$scratch/out" && ok "a failure prints its re-run command" \
    || bad "no re-run line: $(tail -5 "$scratch/out")"

[ "$failures" -eq 0 ] && echo "land: all passed" || { echo "land: $failures failed"; exit 1; }
