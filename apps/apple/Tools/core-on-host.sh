#!/bin/bash
# **Where the E2E run's cargo work happens** (the fixtures, entries_corpus's sample, index_bench's editions): never on
# the Air, where the owner works (owner, 2026-10-15). On BUILD_HOST when local.mk sets one, as Tools/remote-build.sh
# builds there; refused, loudly, on an Air without one; here on any other Mac.
#
#   core-on-host.sh where                      prints the build Mac's name, or `here`; fails on an Air without one
#   core-on-host.sh run <dir> <command>        runs <command> (bash, from the repository's root, cargo on PATH, OUT a
#                                              fresh folder) there, then copies OUT back into <dir>
#
# Environment: XDICT_BUILD_HOST (make sets it from BUILD_HOST); for the tests (Tools/tests/core-on-host-test.sh)
# XDICT_HW_MODEL, XDICT_REMOTE_SSH and XDICT_REMOTE_RSYNC.
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { echo "core-on-host: $*" >&2; exit 1; }
readonly SSH=${XDICT_REMOTE_SSH:-ssh}
readonly RSYNC=${XDICT_REMOTE_RSYNC:-rsync}

where() {
    if [ -n "${XDICT_BUILD_HOST:-}" ]; then
        echo "$XDICT_BUILD_HOST"
        return
    fi
    # The model's name, not its identifier: an Air of 2025 is `Mac17,4`, not `MacBookAir…`.
    local model=${XDICT_HW_MODEL:-$(system_profiler SPHardwareDataType 2>/dev/null | sed -n 's/^ *Model Name: //p')}
    case $model in
        *MacBookAir* | *"MacBook Air"*) fail "this is an Air ($model): the E2E run's cargo work runs on a build Mac. Set BUILD_HOST in local.mk" ;;
        *) echo here ;;
    esac
}

case ${1:-} in
    where) where ;;
    run)
        [ $# -eq 3 ] || fail "usage: $0 run <dir> <command>"
        back=$2 command=$3
        host=$(where) || exit 1
        if [ "$host" = here ]; then
            mkdir -p "$back"
            back=$(cd "$back" && pwd)
            (cd ../.. && OUT="$back" bash -c "$command") || fail "the command failed here: $command"
            exit 0
        fi
        repo=$(cd ../.. && pwd)
        name=$(basename "$repo")
        [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || fail "the checkout's folder name is not a plain name: $name"
        remote=xdict-build/$name
        "$RSYNC" -a --delete --exclude target --exclude .build --exclude node_modules --exclude '*.mdx' \
            --exclude '*.mdd' --exclude /local.mk "$repo/" "$host:$remote/" || fail "could not copy the tree to $host"
        out=xdict-build/$name.out
        # shellcheck disable=SC2016 # expanded on the host
        "$SSH" "$host" "set -euo pipefail; export PATH=\$HOME/.cargo/bin:\$PATH; rm -rf $out; mkdir -p $out
cd $remote && OUT=\$HOME/$out bash -c $(printf '%q' "$command")" >&2 || fail "the command failed on $host: $command"
        mkdir -p "$back"
        "$RSYNC" -a --delete "$host:$out/" "$back/" || fail "could not fetch what $host made"
        ;;
    *) fail "usage: $0 where | run <dir> <command>" ;;
esac
