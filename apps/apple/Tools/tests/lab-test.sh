#!/bin/bash
# `Tools/gallery/lab.sh`'s own tests, with stand-ins for ssh and rsync as in remote-build-test.sh: nothing is compiled
# and nothing leaves this Mac. Each refusal is shown (a product missing, one older than the run, the tree edited while
# the host built), and the bundle's build is held never to read the lab's products. `make test-tools`.
set -euo pipefail
cd "$(dirname "$0")/../.."
failures=0
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
ok() { echo "ok    $*"; }
bad() { echo "FAIL  $*"; failures=$((failures + 1)); }

# A lab is no bundle's input: build-bundle.sh and the Makefile that hands it XDICT_REMOTE_PRODUCTS never name it.
if grep -n "lab-products" Tools/build-bundle.sh Makefile >"$scratch/named"; then
    bad "the bundle's build names the lab's products: $(head -3 "$scratch/named")"
else ok "the bundle's build never reads .build/lab-products"; fi

host=$scratch/host
mkdir -p "$host" "$scratch/bin"
cat >"$scratch/bin/rsync" <<'EOF'
#!/bin/bash
args=()
for a in "$@"; do
    case $a in fake-host:/*) args+=("${a#fake-host:}") ;; fake-host:*) args+=("$FAKE_HOST/${a#fake-host:}") ;;
        *) args+=("$a") ;; esac
done
exec /usr/bin/rsync "${args[@]}"
EOF
cat >"$scratch/bin/ssh" <<'EOF'
#!/bin/bash
set -euo pipefail
apple=$(ls -d "$FAKE_HOST"/xdict-build/lab-*/apps/apple)
bin=$apple/.build/release
rm -rf "$bin"; mkdir -p "$bin"
if [ "$FAKE_MODE" = stale ]; then echo x >"$bin/XDictEntryLab"; chmod +x "$bin/XDictEntryLab"; touch -t 202001010000 "$bin/XDictEntryLab"; fi
mkdir -p "$apple/.build"; touch "$apple/.build/lab-build.marker"; sleep 1
[ "$FAKE_MODE" = edit ] && echo changed >"$FAKE_TREE"
if [ "$FAKE_MODE" = good ] || [ "$FAKE_MODE" = edit ]; then echo x >"$bin/XDictEntryLab"; chmod +x "$bin/XDictEntryLab"; fi
echo "products=$bin"
EOF
chmod +x "$scratch/bin/"*

run() {  # run <mode>: the script's exit, its output in $scratch/out
    rm -rf "$scratch/local" "$host"; mkdir -p "$scratch/local" "$host"
    echo one >"$scratch/tree"
    FAKE_HOST=$host FAKE_MODE=$1 FAKE_TREE=$scratch/tree XDICT_LAB_HOST=fake-host \
    XDICT_REMOTE_SSH=$scratch/bin/ssh XDICT_REMOTE_RSYNC=$scratch/bin/rsync XDICT_LAB_LOCAL=$scratch/local \
    XDICT_SOURCE_TREE_CMD="cat $scratch/tree" XDICT_LAB_STOP_AFTER_FETCH=1 \
        Tools/gallery/lab.sh >"$scratch/out" 2>&1
}

if run good; then
    if [ -x "$scratch/local/.build/lab-products/XDictEntryLab" ] \
        && [ "$(cat "$scratch/local/.build/lab-products/source-tree")" = one ] \
        && [ ! -e "$scratch/local/.build/remote-products" ]; then
        ok "good: the lab and the tree it was built of are here, and nothing in remote-products"
    else bad "good: passed without the lab: $(ls -R "$scratch/local" | head -20)"; fi
else bad "good: $(tail -3 "$scratch/out")"; fi

for mode in missing stale edit; do
    if run $mode; then bad "$mode: passed"
    elif [ -e "$scratch/local/.build/lab-products/source-tree" ]; then bad "$mode: failed but left a stamp"
    else ok "$mode refused: $(tail -1 "$scratch/out")"; fi
done

[ "$failures" -eq 0 ] || { echo "lab-test: $failures failed" >&2; exit 1; }
echo "lab-test: all passed"
