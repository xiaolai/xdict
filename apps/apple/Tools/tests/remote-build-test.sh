#!/bin/bash
# `Tools/remote-build.sh`'s own tests, with stand-ins for ssh and rsync: the "build host" is a folder here, and its
# build is faked by writing the products, so nothing is compiled and nothing leaves this Mac. Each refusal is shown:
# a product missing, a product older than the run, the tree edited while the host built, no icon catalogue. `make test-tools`.
set -euo pipefail
cd "$(dirname "$0")/../.."
failures=0
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
ok() { echo "ok    $*"; }
bad() { echo "FAIL  $*"; failures=$((failures + 1)); }

host=$scratch/host
mkdir -p "$host" "$scratch/bin"
# rsync: `name:path` is the host folder's path (an absolute one as it is, as the build names it); others as given.
cat >"$scratch/bin/rsync" <<'EOF'
#!/bin/bash
args=()
for a in "$@"; do
    case $a in fake-host:/*) args+=("${a#fake-host:}") ;; fake-host:*) args+=("$FAKE_HOST/${a#fake-host:}") ;;
        *) args+=("$a") ;; esac
done
exec /usr/bin/rsync "${args[@]}"
EOF
# ssh: ignores the command and plays the build as FAKE_MODE says, in the host folder.
cat >"$scratch/bin/ssh" <<'EOF'
#!/bin/bash
set -euo pipefail
apple=$FAKE_HOST/xdict-build/$FAKE_NAME/apps/apple
bin=$apple/.build/release
rm -rf "$bin"; mkdir -p "$bin" "$apple/Generated"
[ "$FAKE_MODE" = stale ] && { for p in XDict XDictService XDictEntryLab XDictCaptureLab; do echo x >"$bin/$p"; done; chmod +x "$bin"/*; touch -t 202001010000 "$bin"/*; }
touch -t 202001010001 "$apple/.build/remote-build.marker"  # fixed, not a sleep: past a stale product
[ "$FAKE_MODE" = edit ] && echo changed >"$FAKE_TREE"
if [ "$FAKE_MODE" != stale ]; then
    for p in XDict XDictService XDictEntryLab XDictCaptureLab; do
        [ "$FAKE_MODE" = missing ] && [ $p = XDictService ] && continue
        echo x >"$bin/$p"; chmod +x "$bin/$p"
    done
fi
echo '{}' >"$apple/Generated/core-versions.json"
# The app icon's catalogue (Tools/compile-icon.sh), unless this run plays an actool that wrote none.
mkdir -p "$apple/.build/icon"; rm -f "$apple/.build/icon/Assets.car"
[ "$FAKE_MODE" = noicon ] || echo car >"$apple/.build/icon/Assets.car"
# The toolchain, as the build's own shell names it right after compiling (Tools/toolchain-facts.sh).
[ "$FAKE_MODE" = nofacts ] || printf 'fact:xcode=27.1/27B55\nfact:swift=Apple Swift version 6.3\nfact:rust=rustc 1.99.0\n'
echo "products=$bin"
EOF
chmod +x "$scratch/bin/"*
echo one >"$scratch/tree"

run() {  # run <mode>: the script's exit, its output in $scratch/out
    rm -rf "$scratch/local"; mkdir -p "$scratch/local"
    echo one >"$scratch/tree"
    FAKE_HOST=$host FAKE_NAME=test FAKE_MODE=$1 FAKE_TREE=$scratch/tree \
    XDICT_REMOTE_SSH=$scratch/bin/ssh XDICT_REMOTE_RSYNC=$scratch/bin/rsync XDICT_REMOTE_NAME=test \
    XDICT_REMOTE_LOCAL=$scratch/local XDICT_SOURCE_TREE_CMD="cat $scratch/tree" \
        Tools/remote-build.sh fake-host >"$scratch/out" 2>&1
}

if run good; then
    if [ -x "$scratch/local/.build/remote-products/XDictService" ] && [ -s "$scratch/local/Generated/core-versions.json" ] \
        && [ -s "$scratch/local/.build/remote-products/Assets.car" ] \
        && [ "$(cat "$scratch/local/.build/remote-products/source-tree")" = one ] \
        && [ "$(cat "$scratch/local/.build/remote-products/toolchain")" = "$(printf 'xcode=27.1/27B55\nswift=Apple Swift version 6.3\nrust=rustc 1.99.0')" ]; then
        ok "good: the products, the icon catalogue, Generated/, the tree they were built of and the build's own toolchain are here"
    else bad "good: passed without the products: $(ls -R "$scratch/local" | head -20)"; fi
else bad "good: $(tail -3 "$scratch/out")"; fi

for mode in missing stale edit nofacts noicon; do
    if run $mode; then bad "$mode: passed"
    elif [ -e "$scratch/local/.build/remote-products/source-tree" ]; then bad "$mode: failed but left a stamp"
    else ok "$mode refused: $(tail -1 "$scratch/out")"; fi
done

[ "$failures" -eq 0 ] || { echo "remote-build-test: $failures failed" >&2; exit 1; }
echo "remote-build-test: all passed"
