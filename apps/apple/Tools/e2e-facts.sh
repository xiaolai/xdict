#!/bin/bash
# The facts an E2E sub-stage's key holds besides its files (Tools/e2e-ledger.py), as `--fact` and `name=value`
# on lines of their own, read into an argument list:
#
#   e2e-facts.sh build     xcode, swift, rust of the host that builds the bundle (XDICT_BUILD_HOST over ssh, else here)
#   e2e-facts.sh bundle    the facts .build/XDict.app was built with (.build/XDict.app.facts, written beside its
#                          source-tree marker); nothing, and exit 1, when it has none of this tree
#   e2e-facts.sh macos <host>
#                          the E2E Mac's macOS build
#   e2e-facts.sh corpus    the corpus's identity (XDICT_E2E_CORPUS; `none` unset)
#   e2e-facts.sh plan <host>
#                          what a bundle built now and run on <host> would be keyed with: build, macos and corpus
#
# Overrides, for the tests and for a host that cannot be asked: XDICT_FACT_XCODE, XDICT_FACT_SWIFT, XDICT_FACT_RUST,
# XDICT_FACT_MACOS. A probe that answers nothing fails: a key without its facts would carry a run across toolchains.
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { echo "e2e-facts: $*" >&2; exit 1; }
readonly FACTS=.build/XDict.app.facts
emit() { printf -- '--fact\n%s\n' "$@"; }

build() {
    local xcode=${XDICT_FACT_XCODE:-} swift=${XDICT_FACT_SWIFT:-} rust=${XDICT_FACT_RUST:-} probe out
    if [ -z "$xcode" ] || [ -z "$swift" ] || [ -z "$rust" ]; then
        probe='export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
echo "$(xcodebuild -version 2>/dev/null | awk "NR==1{print \$2}")"
echo "$(swift --version 2>/dev/null | sed -n "s/.*Swift version \([^ ]*\).*/\1/p" | head -1)"
echo "$(rustc --version 2>/dev/null | awk "{print \$2}")"'
        if [ -n "${XDICT_BUILD_HOST:-}" ]; then
            out=$(${XDICT_REMOTE_SSH:-ssh} -o BatchMode=yes -o ConnectTimeout=15 -- "$XDICT_BUILD_HOST" "$probe") \
                || fail "cannot ask $XDICT_BUILD_HOST for its toolchain"
        else out=$(bash -c "$probe"); fi
        [ -n "$xcode" ] || xcode=$(sed -n 1p <<<"$out")
        [ -n "$swift" ] || swift=$(sed -n 2p <<<"$out")
        [ -n "$rust" ] || rust=$(sed -n 3p <<<"$out")
    fi
    [ -n "$xcode" ] && [ -n "$swift" ] && [ -n "$rust" ] \
        || fail "the build host named no Xcode, Swift or Rust version (xcode=$xcode swift=$swift rust=$rust)"
    emit "xcode=$xcode" "swift=$swift" "rust=$rust"
}

macos() {
    local host=${1:-} os=${XDICT_FACT_MACOS:-}
    if [ -z "$os" ]; then
        [ -n "$host" ] || fail "macos: name the E2E Mac"
        os=$(ssh -o BatchMode=yes -o ConnectTimeout=15 -- "$host" "sw_vers -buildVersion") || fail "cannot ask $host its macOS build"
    fi
    [[ "$os" =~ ^[A-Za-z0-9]+$ ]] || fail "not a macOS build: '$os'"
    emit "macos=$os"
}

corpus() {
    if [ -n "${XDICT_E2E_CORPUS:-}" ]; then
        local id
        id=$(python3 -I Tools/gate-cache.py corpus-id "$XDICT_E2E_CORPUS") || fail "could not read the corpus at $XDICT_E2E_CORPUS"
        emit "corpus=$id"
    else emit "corpus=none"; fi
}

case ${1:-} in
    build) build ;;
    bundle)
        [ -s "$FACTS" ] && [ "$(cat .build/XDict.app.source-tree 2>/dev/null)" = "$(Tools/source-tree.sh)" ] || exit 1
        cat "$FACTS" ;;
    macos) macos "${2:-}" ;;
    corpus) corpus ;;
    plan) build; macos "${2:-}"; corpus ;;
    *) fail "usage: e2e-facts.sh build|bundle|macos <host>|corpus|plan <host>" ;;
esac
