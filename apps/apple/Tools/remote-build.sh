#!/bin/bash
# Builds on another Mac what `Tools/build-bundle.sh` assembles, so that this Mac only assembles and signs: the
# Developer ID key never leaves its keychain, and the compiling load goes elsewhere (owner's decision, 2026-10-15).
#
#   XDICT_REMOTE_GATES="lint test-swift"|test remote-build.sh <host>
#                             `make` sets both up when BUILD_HOST is set (the repository's untracked local.mk)
#
# 1. The source tree is read here first (`Tools/source-tree.sh`).
# 2. The repository is copied to <host>:xdict-build/<this checkout's folder name>/, without build products, dictionary
#    files, local.mk, .git (a worktree's points at this Mac) or a `.known-commits` of the checkout's own (only a
#    release's gates send one, below).
# 3. There: the gates the Makefile names in XDICT_REMOTE_GATES, the same the build would run on this Mac, so the remote
#    path mirrors the local one (2026-11-05): `lint test-swift` for `make app`, and `test` (SwiftLint, the tool tests,
#    the core, swift test and its warnings gate) for `make release` and `release-bootstrap`. Any other value is
#    refused. `test` runs in a throwaway git snapshot of the copy, as `make land`'s apple-test gate runs it: the tool
#    tests read git (the source tree), and the ledger's commits are checked against this Mac's `git rev-list --all`,
#    sent as `.known-commits` and read through XDICT_KNOWN_COMMITS. Until 2026-11-05 every remote build ran `make lint
#    test-swift`, so a release built there skipped `test-tools`, which a release built here runs (the 2026-11-05
#    audit, M11); the notices check (`Tools/notices.py check`, needs cargo) is one of those tool tests.
#    Then `swift build -c release` and the compiler-warnings gate on that release build, exactly as `build-bundle.sh`
#    runs it here; and the app icon compiled by actool (`Tools/compile-icon.sh`), which needs Xcode and so a build Mac.
# 4. Back here, only: the app, the service and the entry lab into .build/remote-products/, the icon's Assets.car beside
#    them, and Generated/ (the core's versions and binding, which the bundle's checks and its input digest read).
#    The products are deleted on the host before its release build, so an unchanged tree relinks them (seconds) and
#    whatever comes back was made by this run, never left over from an earlier one.
#    And the toolchain the build compiled with, named by its own shell right after `swift build` (Tools/toolchain-facts.sh,
#    as `fact:` lines), into .build/remote-products/toolchain: the E2E ledger keys the bundle's runs with it.
# 5. Refused, loudly, if a product is missing, the toolchain unnamed, older than the run's marker on the host (both times are the host's
#    clock), or the source tree changed while the host built. Only then is .build/remote-products/source-tree
#    written, which `build-bundle.sh` and `build-lab.sh` require to equal the tree they assemble.
#
# Environment, for the tests (Tools/tests/remote-build-test.sh): XDICT_REMOTE_SSH, XDICT_REMOTE_RSYNC (the commands),
# XDICT_REMOTE_NAME (the folder on the host), XDICT_REMOTE_LOCAL (where products land; this apps/apple),
# XDICT_SOURCE_TREE_CMD (how the tree is read).
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { echo "remote-build: $*" >&2; exit 1; }

host=${1:-}
[ -n "$host" ] || fail "usage: $0 <host>"
readonly SSH=${XDICT_REMOTE_SSH:-ssh}
readonly RSYNC=${XDICT_REMOTE_RSYNC:-rsync}
repo=$(cd ../.. && pwd)
readonly NAME=${XDICT_REMOTE_NAME:-$(basename "$repo")}
readonly LOCAL=${XDICT_REMOTE_LOCAL:-$PWD}
readonly TREE_CMD=${XDICT_SOURCE_TREE_CMD:-Tools/source-tree.sh}
readonly GATES=${XDICT_REMOTE_GATES:-}
case $GATES in
    "lint test-swift") gates_command="make lint test-swift >&2"; snapshot="" ;;
    test)
        gates_command="XDICT_KNOWN_COMMITS=\$PWD/../../.known-commits make test >&2"
        snapshot="rm -rf .git && git init -q && git add -A
git -c core.hooksPath=/dev/null -c user.name=remote-build -c user.email=remote-build@localhost commit -qm snapshot" ;;
    *) fail "XDICT_REMOTE_GATES is '$GATES': the Makefile names \"lint test-swift\" (make app) or \"test\" (make release)" ;;
esac
readonly PRODUCTS=$LOCAL/.build/remote-products
readonly NAMES="XDict XDictService XDictEntryLab XDictCaptureLab"
[[ "$NAME" =~ ^[A-Za-z0-9._-]+$ ]] || fail "the checkout's folder name is not a plain name: $NAME"
remote=xdict-build/$NAME

started=$(date +%s)
tree=$($TREE_CMD) || fail "could not read the source tree"
rm -rf "$PRODUCTS"
mkdir -p "$PRODUCTS"

"$RSYNC" -a --delete --exclude target --exclude .build --exclude node_modules --exclude '*.mdx' --exclude '*.mdd' \
    --exclude /local.mk --exclude .git --exclude /.known-commits "$repo/" "$host:$remote/" || fail "could not copy the tree to $host"
if [ "$GATES" = test ]; then
    git -C "$repo" rev-list --all >"$PRODUCTS/known-commits" || fail "could not list this checkout's commits"
    "$RSYNC" -a "$PRODUCTS/known-commits" "$host:$remote/.known-commits" || fail "could not copy the commit list to $host"
fi

# The host's PATH: user-level tools first (~/bin holds the pinned SwiftLint, ~/.cargo/bin the Rust toolchain).
out=$("$SSH" "$host" "set -euo pipefail; export PATH=\$HOME/bin:\$HOME/.cargo/bin:/opt/homebrew/bin:\$PATH
cd $remote
$snapshot
cd apps/apple
mkdir -p .build && touch .build/remote-build.marker
$gates_command
bin=\$(swift build -c release --show-bin-path)
rm -f$(for p in $NAMES; do printf ' "$bin/%s"' "$p"; done)
swift build -c release >&2
bash Tools/compile-icon.sh .build/icon >&2
bash Tools/toolchain-facts.sh | sed 's/^/fact:/'
python3 Tools/compiler-warnings.py .build/out/Intermediates.noindex/XDict.build/Release --whole-module --no-test-targets >&2
echo products=\$bin") || fail "the build on $host failed"
bin=$(printf '%s\n' "$out" | sed -n 's/^products=//p' | tail -1)
[ -n "$bin" ] || fail "the build on $host named no products"
toolchain=$(printf '%s\n' "$out" | sed -n 's/^fact://p')
for name in xcode swift rust; do
    grep -q "^$name=." <<<"$toolchain" || fail "the build on $host named no $name version (Tools/toolchain-facts.sh)"
done

files=("$remote/apps/apple/.build/remote-build.marker")
for p in $NAMES; do files+=("$bin/$p"); done
files+=("$remote/apps/apple/.build/icon/Assets.car")
for f in "${files[@]}"; do
    "$RSYNC" -a "$host:$f" "$PRODUCTS/" || fail "$host has no $(basename "$f") after its build"
done
"$RSYNC" -a --delete "$host:$remote/apps/apple/Generated/" "$LOCAL/Generated/" || fail "could not fetch Generated/"

for p in $NAMES; do
    [ -x "$PRODUCTS/$p" ] || fail "$p came back missing or not executable"
    [ "$PRODUCTS/$p" -nt "$PRODUCTS/remote-build.marker" ] || fail "$p is older than this run's build on $host"
done
[ -s "$PRODUCTS/Assets.car" ] || fail "the app icon's Assets.car came back missing or empty"
[ "$PRODUCTS/Assets.car" -nt "$PRODUCTS/remote-build.marker" ] || fail "Assets.car is older than this run's build on $host"
[ "$($TREE_CMD)" = "$tree" ] || fail "the source tree changed while $host built: build again"
printf '%s\n' "$toolchain" >"$PRODUCTS/toolchain"
printf '%s\n' "$tree" >"$PRODUCTS/source-tree"
echo "remote-build: built on $host in $(($(date +%s) - started)) s; products in $PRODUCTS"
