#!/bin/bash
# **A picture of a core change, with no gate**: the entry lab rebuilt of this tree and installed where
# `Tools/gallery/hot.sh` renders with it ("pictures before gates", AGENTS.md).
#
#   Tools/gallery/lab.sh
#
# 1. The tree goes to the first BUILD_HOSTS_XCODE host (local.mk), which builds the core (`Tools/build-core.sh`) and
#    `swift build -c release --product XDictEntryLab`, nothing else: no lint, no tests, no warnings gate. A picture is
#    not evidence a gate passed.
# 2. The lab comes back to .build/lab-products/ with a `source-tree` stamp, under remote-build.sh's refusals: a
#    product missing, one older than this run's build there, the tree changed while it built.
# 3. `Tools/build-lab.sh --app-only` signs it here into .build/lab-kit/ (the E2E kit is not touched; nothing
#    compiles here).
# 4. It is installed on the E2E Mac (E2E_HOST, else E2E_HOST_MACOS) as hot.sh's lab, under the gallery's run lock.
#
# .build/lab-products is a lab's alone: `Tools/build-bundle.sh` never reads it (Tools/tests/lab-test.sh).
# Each step prints its time. Environment, for the tests: XDICT_REMOTE_SSH, XDICT_REMOTE_RSYNC, XDICT_LAB_HOST,
# XDICT_LAB_LOCAL (this apps/apple), XDICT_SOURCE_TREE_CMD, XDICT_LAB_SIGN (the signing step's command),
# XDICT_LAB_STOP_AFTER_FETCH (1: stop once the products are here).
set -euo pipefail
cd "$(dirname "$0")/../.."
fail() { echo "lab: $*" >&2; exit 1; }
readonly SSH=${XDICT_REMOTE_SSH:-ssh}
readonly RSYNC=${XDICT_REMOTE_RSYNC:-rsync}
readonly LOCAL=${XDICT_LAB_LOCAL:-$PWD}
readonly TREE_CMD=${XDICT_SOURCE_TREE_CMD:-Tools/source-tree.sh}
readonly PRODUCTS=$LOCAL/.build/lab-products
readonly LAB=XDictEntryLab
repo=$(cd ../.. && pwd)
# The main checkout, where local.mk lives (Tools/main-checkout.sh).
main=$(Tools/main-checkout.sh "$repo") || exit 2
setting() { awk -v k="$1" -F'=' '{ n = $1; gsub(/[ \t]/, "", n) } n == k { sub(/^[^=]*=[ \t]*/, ""); print; exit }' \
    "$main/local.mk" 2>/dev/null; }
host=${XDICT_LAB_HOST:-$(setting BUILD_HOSTS_XCODE | awk '{print $1}')}
[ -n "$host" ] || fail "no BUILD_HOSTS_XCODE in local.mk"
remote=xdict-build/lab-$(basename "$repo")
[[ "$remote" =~ ^xdict-build/[A-Za-z0-9._-]+$ ]] || fail "the checkout's folder name is not a plain name"

step=$(date +%s)
took() { local now; now=$(date +%s); echo "lab: $1: $((now - step)) s"; step=$now; }

# The build host's run lock (Tools/host-lock.sh): since 2026-10-17 it is also the E2E Mac, so the build waits for an
# E2E run, a gate or a gallery there, and they for it.
. Tools/host-lock.sh
trap 'host_unlock "$host"; [ -z "${e2e:-}" ] || host_unlock "$e2e"' EXIT
host_lock "$host" lab || exit 3

tree=$($TREE_CMD) || fail "could not read the source tree"
# The lab's render id (Tools/gallery/render_affected.py), stamped beside the installed lab: hot.sh keys its pictures
# with it. Taken now, for the tree this build is of (a tree changed while it builds is refused below).
render_lab_id=$(python3 -I Tools/gallery/render_affected.py lab-id 2>/dev/null) || render_lab_id=unknown
rm -rf "$PRODUCTS"
mkdir -p "$PRODUCTS"
"$RSYNC" -a --delete --exclude target --exclude .build --exclude node_modules --exclude '*.mdx' --exclude '*.mdd' \
    --exclude /local.mk "$repo/" "$host:$remote/" || fail "could not copy the tree to $host"
took "copied to the build host"

out=$("$SSH" "$host" "set -euo pipefail; export PATH=\$HOME/bin:\$HOME/.cargo/bin:/opt/homebrew/bin:\$PATH
cd $remote/apps/apple
mkdir -p .build && touch .build/lab-build.marker
Tools/build-core.sh >&2
bin=\$(swift build -c release --product $LAB --show-bin-path)
rm -f \"\$bin/$LAB\"
swift build -c release --product $LAB >&2
echo products=\$bin") || fail "the build on $host failed"
bin=$(printf '%s\n' "$out" | sed -n 's/^products=//p' | tail -1)
[ -n "$bin" ] || fail "the build on $host named no products"
took "built on the build host"

for f in "$remote/apps/apple/.build/lab-build.marker" "$bin/$LAB"; do
    "$RSYNC" -a "$host:$f" "$PRODUCTS/" || fail "$host has no $(basename "$f") after its build"
done
[ -x "$PRODUCTS/$LAB" ] || fail "$LAB came back missing or not executable"
[ "$PRODUCTS/$LAB" -nt "$PRODUCTS/lab-build.marker" ] || fail "$LAB is older than this run's build on $host"
[ "$($TREE_CMD)" = "$tree" ] || fail "the source tree changed while $host built: build again"
printf '%s\n' "$tree" >"$PRODUCTS/source-tree"
took "fetched"
[ "${XDICT_LAB_STOP_AFTER_FETCH:-0}" = 1 ] && exit 0

XDICT_REMOTE_PRODUCTS=$PRODUCTS ${XDICT_LAB_SIGN:-Tools/build-lab.sh --app-only} || fail "the lab could not be signed"
took "signed here"

e2e=${E2E_HOST:-$(setting E2E_HOST_MACOS)}
[ -n "$e2e" ] || fail "no E2E_HOST and no E2E_HOST_MACOS in local.mk"
host_lock "$e2e" lab || exit 3
"$RSYNC" -a --delete "$LOCAL/.build/lab-kit/$LAB.app" "$e2e:XDictE2E/gallery-run-lab/" \
    || fail "could not install the lab on $e2e"
printf '%s\n' "$render_lab_id" | "$SSH" "$e2e" "cat > XDictE2E/gallery-run-lab/render-lab-id" \
    || fail "could not stamp the lab's render id on $e2e"
took "installed for hot.sh"
