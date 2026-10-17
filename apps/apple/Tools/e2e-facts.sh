#!/bin/bash
# The facts an E2E sub-stage's key holds besides its files (Tools/e2e-ledger.py), as `--fact` and `name=value`
# on lines of their own, read into an argument list:
#
#   e2e-facts.sh build     xcode, swift, rust a build made now would have: Tools/toolchain-facts.sh, as the build runs
#                          it (on XDICT_BUILD_HOST in its build folder and PATH, Tools/remote-build.sh's; else here).
#                          A prediction, for a plan: what a run is filed under is its bundle's own provenance
#   e2e-facts.sh bundle    the facts .build/XDict.app names itself (Contents/Resources/Provenance.txt), when it was
#                          built of this very tree; nothing, and exit 1, otherwise
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
readonly PROVENANCE=.build/XDict.app/Contents/Resources/Provenance.txt
emit() { printf -- '--fact\n%s\n' "$@"; }

build() {
    local xcode=${XDICT_FACT_XCODE:-} swift=${XDICT_FACT_SWIFT:-} rust=${XDICT_FACT_RUST:-} out name
    if [ -z "$xcode" ] || [ -z "$swift" ] || [ -z "$rust" ]; then
        if [ -n "${XDICT_BUILD_HOST:-}" ]; then
            name=$(basename "$(cd ../.. && pwd)")
            # Tools/remote-build.sh's folder and PATH, so the answer is the build's.
            out=$(${XDICT_REMOTE_SSH:-ssh} -o BatchMode=yes -o ConnectTimeout=15 -- "$XDICT_BUILD_HOST" \
                "export PATH=\$HOME/bin:\$HOME/.cargo/bin:/opt/homebrew/bin:\$PATH; cd xdict-build/$name/apps/apple && bash Tools/toolchain-facts.sh") \
                || fail "cannot ask $XDICT_BUILD_HOST for its toolchain (it needs one build there first: make app)"
        else out=$(Tools/toolchain-facts.sh) || fail "this Mac's toolchain could not be named"; fi
        [ -n "$xcode" ] || xcode=$(sed -n 's/^xcode=//p' <<<"$out")
        [ -n "$swift" ] || swift=$(sed -n 's/^swift=//p' <<<"$out")
        [ -n "$rust" ] || rust=$(sed -n 's/^rust=//p' <<<"$out")
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
        [ -s "$PROVENANCE" ] && [ "$(sed -n 's/^tree=//p' "$PROVENANCE")" = "$(Tools/source-tree.sh)" ] || exit 1
        for name in xcode swift rust; do
            line=$(grep "^$name=." "$PROVENANCE") || exit 1
            emit "$line"
        done ;;
    macos) macos "${2:-}" ;;
    corpus) corpus ;;
    plan) build; macos "${2:-}"; corpus ;;
    *) fail "usage: e2e-facts.sh build|bundle|macos <host>|corpus|plan <host>" ;;
esac
