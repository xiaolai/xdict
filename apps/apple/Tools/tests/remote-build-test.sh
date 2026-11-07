#!/bin/bash
# `Tools/remote-build.sh`'s own tests, with stand-ins for ssh and rsync: the "build host" is a folder here, and its
# build is faked by writing the products, so nothing is compiled and nothing leaves this Mac. Each refusal is shown:
# a product missing, a product older than the run, the tree edited while the host built, no icon catalogue. And what the
# host is asked to run mirrors the local path (2026-11-05): for a release (XDICT_REMOTE_GATES=test) `make test`, tool
# tests included, in a git snapshot with this checkout's commits (the 2026-11-05 audit, M11: every remote build ran
# `make lint test-swift`, so a release built there skipped `test-tools`); for `make app` (`lint test-swift`) only those,
# with no snapshot and no commit list; anything else refused. And the Makefile sets each. `make test-tools`.
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
# ssh: keeps the command it was given (ssh-command, beside the host folder) and plays the build as FAKE_MODE says.
cat >"$scratch/bin/ssh" <<'EOF'
#!/bin/bash
set -euo pipefail
shift; printf '%s\n' "$*" >"$FAKE_HOST.ssh-command"
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

run() {  # run <mode> [gates]: the script's exit, its output in $scratch/out; gates `test` (a release's) unless given
    rm -rf "$scratch/local"; mkdir -p "$scratch/local"
    echo one >"$scratch/tree"
    XDICT_REMOTE_GATES=${2-test} FAKE_HOST=$host FAKE_NAME=test FAKE_MODE=$1 FAKE_TREE=$scratch/tree \
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

# The command the host runs, read as the host's shell would get it.
cmd=$scratch/host.ssh-command
grep -qE '(^|[;&[:space:]])make test( |>|$)' "$cmd" && ok "the host runs make test, tool tests included" \
    || bad "no make test in the host's command: $(grep -n make "$cmd")"
grep -q 'make lint test-swift' "$cmd" && bad "the host still runs make lint test-swift" || ok "not the narrower make lint test-swift"
grep -q 'rm -rf .git && git init -q && git add -A' "$cmd" && grep -q 'commit -qm snapshot' "$cmd" \
    && ok "the host makes a throwaway git snapshot first" || bad "no git snapshot in the host's command"
grep -q 'XDICT_KNOWN_COMMITS=\$PWD/../../.known-commits make test' "$cmd" \
    && ok "make test reads this checkout's commits from .known-commits" || bad "make test without XDICT_KNOWN_COMMITS"
if [ -s "$host/xdict-build/test/.known-commits" ] \
    && [ "$(cat "$host/xdict-build/test/.known-commits")" = "$(git rev-list --all)" ]; then
    ok "the host's .known-commits is this checkout's git rev-list --all"
else bad "no .known-commits on the host, or not this checkout's commits"; fi

# make app: the gates it runs here, `lint test-swift`, and none of the release's snapshot or commit list.
rm -f "$host/xdict-build/test/.known-commits" "$cmd"
if run good "lint test-swift"; then
    grep -qE '(^|[;&[:space:]])make lint test-swift( |>|$)' "$cmd" && ok "app: the host runs make lint test-swift" \
        || bad "app: no make lint test-swift: $(grep -n make "$cmd")"
    grep -qE '(^|[;&[:space:]])make test( |>|$)' "$cmd" && bad "app: the host runs make test" || ok "app: no make test"
    grep -qE 'git init|commit -qm snapshot|XDICT_KNOWN_COMMITS' "$cmd" && bad "app: a snapshot or the commit list" \
        || ok "app: no git snapshot, no XDICT_KNOWN_COMMITS"
    [ -e "$host/xdict-build/test/.known-commits" ] && bad "app: .known-commits was sent" || ok "app: no .known-commits sent"
else bad "app: $(tail -3 "$scratch/out")"; fi
for gates in "" "lint" "test-tools"; do
    if run good "$gates"; then bad "gates '$gates': ran"
    elif grep -q "XDICT_REMOTE_GATES is '$gates'" "$scratch/out"; then
        ok "gates '$gates' refused: $(tail -1 "$scratch/out")"
    else bad "gates '$gates': $(tail -2 "$scratch/out")"; fi
done
# The Makefile names them: app the narrow pair, release and release-bootstrap the whole `make test`. Run for real on a
# copy of the Makefile whose remote-build.sh, build-bundle.sh and release.sh are stubs that print what they were given.
mk=$scratch/mk
mkdir -p "$mk/Tools"
cp Makefile "$mk/"
printf '#!/bin/bash\necho "gates=$XDICT_REMOTE_GATES"\n' >"$mk/Tools/remote-build.sh"
printf '#!/bin/bash\ntrue\n' >"$mk/Tools/build-bundle.sh"
cp "$mk/Tools/build-bundle.sh" "$mk/Tools/release.sh"
chmod +x "$mk/Tools/"*
for t in "app:lint test-swift" "release:test" "release-bootstrap:test"; do
    got=$(env -u XDICT_REMOTE_GATES make -s -C "$mk" "${t%%:*}" BUILD_HOST=fake-host BUILD_NUMBER=1 2>&1 | sed -n 's/^gates=//p')
    [ "$got" = "${t#*:}" ] && ok "make ${t%%:*} has remote-build.sh run: ${t#*:}" \
        || bad "make ${t%%:*} gave remote-build.sh '$got', want '${t#*:}': $(make -s -C "$mk" "${t%%:*}" BUILD_HOST=fake-host BUILD_NUMBER=1 2>&1 | tail -2)"
done

for mode in missing stale edit nofacts noicon; do
    if run $mode; then bad "$mode: passed"
    elif [ -e "$scratch/local/.build/remote-products/source-tree" ]; then bad "$mode: failed but left a stamp"
    else ok "$mode refused: $(tail -1 "$scratch/out")"; fi
done

[ "$failures" -eq 0 ] || { echo "remote-build-test: $failures failed" >&2; exit 1; }
echo "remote-build-test: all passed"
