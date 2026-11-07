#!/bin/bash
# Tests of Tools/land.sh that reach no host: ssh and rsync are stubs that refuse and log. Every gate already passed
# prints `cached pass`, asks no host and exits 0; a corrupt cache runs everything, and with no host fit for it, fails
# red with the command that re-runs each gate alone. A pass is recorded only for the tree that was keyed: an edit between
# the keys and the copy leaves it unrecorded (the 2026-11-05 audit, M12). Runs no E2E: its last line only says what is
# pending.
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
# The hosts the Makefile exports from a real local.mk (run under `make test`, they are set): Tools/e2e-facts.sh asks
# XDICT_BUILD_HOST for its toolchain, which reached a real host from "all cached asks no host" (2026-10-18).
unset XDICT_BUILD_HOST XDICT_BUILD_CORPUS XDICT_E2E_HOST XDICT_E2E_CORPUS
# The gallery's keys and the render record, scratch ones (Tools/gallery/render_affected.py pending ends land's output).
python3 -I -c 'import json, sys
dicts = [l.split()[1:] for l in open("Tools/gallery/render-affected.map") if l.startswith("dicts ")][0]
json.dump({"rows": [{"dict": d, "kind": "long", "key": d} for d in dicts]}, open(sys.argv[1], "w"))' "$scratch/keys.json"
export XDICT_GALLERY_KEYS=$scratch/keys.json XDICT_RENDER_CACHE=$scratch/renders XDICT_RENDER_CORPUS=$scratch/no-corpus
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
tail -2 "$scratch/out" | head -1 | grep -q '^E2E' && ok "the line before last says what E2E is pending" \
    || bad "line before last: $(tail -2 "$scratch/out" | head -1)"
tail -1 "$scratch/out" | grep -q '^Render' && ok "the last line says what renders are pending" || bad "last line: $(tail -1 "$scratch/out")"
grep -q 'make e2e\b' "$scratch/out" && bad "land ran or offered an E2E run" || ok "land runs no E2E"

# A corrupt record: everything runs. While another XDict run (an E2E run, the gallery, a tour) holds a host's lock,
# land waits for it, says who holds it, and asks no host; given no time to wait, it fails red.
echo garbage >>"$scratch/cache/passes.tsv"
mkdir -p "$scratch/tmp"
sleep 300 &
holder=$!
. Tools/host-lock.sh
TMPDIR=$scratch/tmp /usr/bin/shlock -f "$(TMPDIR=$scratch/tmp host_lock_file stub-x)" -p "$holder"
: >"$scratch/called"
if TMPDIR=$scratch/tmp XDICT_HOST_LOCK_WAIT=0 land; then bad "land ran while another run held the host"
else ok "land fails while another run holds the host"; fi
grep -q "stub-x is held by another XDict run (pid $holder" "$scratch/out" && ok "it names who holds the host" \
    || bad "holder not named: $(tail -3 "$scratch/out")"
[ ! -s "$scratch/called" ] && ok "a held host is not asked" || bad "called while held: $(cat "$scratch/called")"
kill "$holder"; wait "$holder" 2>/dev/null
TMPDIR=$scratch/tmp XDICT_HOST_LOCK_WAIT=0 land
grep -q 'held by another' "$scratch/out" && bad "the lock outlived its holder" || ok "a released host is taken"
grep -q 'ssh' "$scratch/called" && ok "a released host is asked" || bad "no host asked once released"
ls "$scratch/tmp"/xdict-e2e-* >/dev/null 2>&1 && bad "land left its lock behind" || ok "land removes its lock"

if land; then bad "a corrupt cache with no reachable host exited 0"; else ok "a corrupt cache runs every gate, and red here"; fi
grep -q 'corrupt' "$scratch/out" && ok "the corruption is said" || bad "corruption not said"
grep -q 'stub-a skipped: unreachable' "$scratch/out" && ok "an unfit host is skipped with its reason" || bad "no skip reason"
grep -q 're-run only core: make -C apps/apple land ONLY=core' "$scratch/out" && ok "a failure prints its re-run command" \
    || bad "no re-run line: $(tail -5 "$scratch/out")"

# A host that answers: ssh plays the probe and passes every gate, rsync copies nothing. With FAKE_EDIT set, the copy is
# the moment the working copy is edited (the source tree is read from a file here), between the keys and the gate.
mkdir -p "$scratch/fit"
cat >"$scratch/fit/ssh" <<'EOF'
#!/bin/bash
[ -z "${FAKE_SSH_LOG:-}" ] || printf '%s\n' "$*" >>"$FAKE_SSH_LOG"
case "$*" in
    *'rust=$(rustc'*) printf 'rust=1.99.0\nfmt=yes\nclippy=yes\nswiftlint=0.65.1\nxcode=27.0\ncorpus=%s\nrun1=yes\nbusy=0\n' "${FAKE_CORPUS:-}" ;;
    *) echo "gate ran" ;;
esac
EOF
cat >"$scratch/fit/rsync" <<'EOF'
#!/bin/bash
[ -z "${FAKE_EDIT:-}" ] || echo edited >"$FAKE_TREE"
EOF
chmod +x "$scratch/fit/"*
printf 'BUILD_HOSTS = fit-a\nBUILD_HOSTS_XCODE = fit-a\nBUILD_HOST = fit-a\n' >"$scratch/fit.mk"
core_status() {
    facts=()
    while IFS= read -r a; do facts+=("$a"); done < <(bash Tools/land.sh --facts-of core "$corpus")
    XDICT_GATE_CACHE=$1 python3 -I Tools/gate-cache.py status "${facts[@]}" core | cut -f1
}
fit_land() {  # fit_land <cache> [edit]: land ONLY=core against the answering host
    echo keyed >"$scratch/tree"
    FAKE_EDIT=${2:-} FAKE_TREE=$scratch/tree PATH=$scratch/fit:$PATH TMPDIR=$scratch/tmp XDICT_HOST_LOCK_WAIT=0 \
        XDICT_GATE_CACHE=$1 XDICT_LAND_LOCAL_MK=$scratch/fit.mk XDICT_SOURCE_TREE_CMD="cat $scratch/tree" ONLY=core \
        bash Tools/land.sh >"$scratch/out" 2>&1
}
if fit_land "$scratch/cache-same" && grep -qE '^core .* PASS gate ran' "$scratch/out" \
    && [ "$(core_status "$scratch/cache-same")" = skip ]; then
    ok "an unchanged tree: the pass is recorded (positive control)"
else bad "unchanged tree: not recorded: $(grep -E '^core ' "$scratch/out"; tail -3 "$scratch/out")"; fi
if fit_land "$scratch/cache-edit" edit; then ok "a tree edited during the run still prints its pass, exit 0"
else bad "edited tree exited non-zero: $(tail -3 "$scratch/out")"; fi
grep -qE '^core .* PASS passed; NOT cached: the tree changed during the run' "$scratch/out" \
    && ok "an edited tree: passed; NOT cached: the tree changed during the run" \
    || bad "edited tree's line: $(grep -E '^core ' "$scratch/out")"
[ "$(core_status "$scratch/cache-edit")" = run ] && [ ! -s "$scratch/cache-edit/passes.tsv" ] \
    && ok "an edited tree records nothing" || bad "an edit between key and gate was recorded as a pass"

# The corpus gates demand their corpus: XDICT_CORPUS_REQUIRED=1 makes an unset or empty XDICT_MDX_CORPUS fail the test
# with a sentence rather than pass as "not measured" (2026-11-05). Seen in what the host is asked to run.
: >"$scratch/ssh.log"
FAKE_SSH_LOG=$scratch/ssh.log FAKE_CORPUS=xdict-corpus/the24 PATH=$scratch/fit:$PATH TMPDIR=$scratch/tmp \
    XDICT_HOST_LOCK_WAIT=0 XDICT_GATE_CACHE=$scratch/cache-corpus XDICT_LAND_LOCAL_MK=$scratch/fit.mk \
    ONLY=entries,lookup-corpus bash Tools/land.sh >"$scratch/out" 2>&1
for g in 'xdict-core --test entries_corpus' 'xdict-lookup --test corpus'; do
    if grep -F -- "$g" "$scratch/ssh.log" | grep -qF 'XDICT_CORPUS_REQUIRED=1 XDICT_MDX_CORPUS=$HOME/xdict-corpus/the24 '; then
        ok "the corpus is required where land runs: $g"
    else bad "no XDICT_CORPUS_REQUIRED=1 on $g: $(grep -F -- "$g" "$scratch/ssh.log" | head -1)"; fi
done

[ "$failures" -eq 0 ] && echo "land: all passed" || { echo "land: $failures failed"; exit 1; }
