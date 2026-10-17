#!/bin/bash
# Builds on another Mac what `Tools/build-bundle.sh` assembles, so that this Mac only assembles and signs: the
# Developer ID key never leaves its keychain, and the compiling load goes elsewhere (owner's decision, 2026-10-15).
#
#   remote-build.sh <host>    `make` sets it up when BUILD_HOST is set (the repository's untracked local.mk)
#
# 1. The source tree is read here first (`Tools/source-tree.sh`).
# 2. The repository is copied to <host>:xdict-build/<this checkout's folder name>/, without build products, dictionary
#    files or local.mk.
# 3. There: `make lint test-swift` (the core, SwiftLint, swift test and its warnings gate), the third-party notices
#    held to the crates the service links (`Tools/notices.py check`: needs cargo, so there and not here), `swift build
#    -c release` and the compiler-warnings gate on that release build, exactly as `build-bundle.sh` runs it here.
# 4. Back here, only: the app, the service and the entry lab into .build/remote-products/, and Generated/ (the core's
#    versions and binding, which the bundle's checks and its input digest read).
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
readonly PRODUCTS=$LOCAL/.build/remote-products
readonly NAMES="XDict XDictService XDictEntryLab"
[[ "$NAME" =~ ^[A-Za-z0-9._-]+$ ]] || fail "the checkout's folder name is not a plain name: $NAME"
remote=xdict-build/$NAME

started=$(date +%s)
tree=$($TREE_CMD) || fail "could not read the source tree"
rm -rf "$PRODUCTS"
mkdir -p "$PRODUCTS"

"$RSYNC" -a --delete --exclude target --exclude .build --exclude node_modules --exclude '*.mdx' --exclude '*.mdd' \
    --exclude /local.mk "$repo/" "$host:$remote/" || fail "could not copy the tree to $host"

# The host's PATH: user-level tools first (~/bin holds the pinned SwiftLint, ~/.cargo/bin the Rust toolchain).
out=$("$SSH" "$host" "set -euo pipefail; export PATH=\$HOME/bin:\$HOME/.cargo/bin:/opt/homebrew/bin:\$PATH
cd $remote/apps/apple
mkdir -p .build && touch .build/remote-build.marker
make lint test-swift >&2
python3 -I Tools/notices.py check >&2
bin=\$(swift build -c release --show-bin-path)
rm -f$(for p in $NAMES; do printf ' "$bin/%s"' "$p"; done)
swift build -c release >&2
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
for f in "${files[@]}"; do
    "$RSYNC" -a "$host:$f" "$PRODUCTS/" || fail "$host has no $(basename "$f") after its build"
done
"$RSYNC" -a --delete "$host:$remote/apps/apple/Generated/" "$LOCAL/Generated/" || fail "could not fetch Generated/"

for p in $NAMES; do
    [ -x "$PRODUCTS/$p" ] || fail "$p came back missing or not executable"
    [ "$PRODUCTS/$p" -nt "$PRODUCTS/remote-build.marker" ] || fail "$p is older than this run's build on $host"
done
[ "$($TREE_CMD)" = "$tree" ] || fail "the source tree changed while $host built: build again"
printf '%s\n' "$toolchain" >"$PRODUCTS/toolchain"
printf '%s\n' "$tree" >"$PRODUCTS/source-tree"
echo "remote-build: built on $host in $(($(date +%s) - started)) s; products in $PRODUCTS"
