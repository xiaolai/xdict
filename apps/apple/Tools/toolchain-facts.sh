#!/bin/bash
# The toolchain that builds the bundle, as the E2E ledger keys it: three `name=value` lines, run **by the build itself**,
# in its own shell and PATH, right after it compiled (Tools/remote-build.sh on the build Mac, Tools/build-bundle.sh
# here), so the facts are the compiler's that made the products, never a later probe's (2026-10-17).
#
#   xcode=<version>/<build version>    `xcodebuild -version`, both lines: one marketing version spans several builds
#   swift=<swift --version's first line>
#   rust=<rustc --version>, asked in core/, where cargo resolves the toolchain it builds with
#
# Exit 1, naming what, when any of them answers nothing.
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { echo "toolchain-facts: $*" >&2; exit 1; }
one_line() { tr '\t' ' ' | head -1; }
xcode=$(xcodebuild -version 2>/dev/null) || fail "xcodebuild -version failed"
version=$(awk '/^Xcode /{print $2}' <<<"$xcode")
build=$(awk '/^Build version /{print $3}' <<<"$xcode")
[ -n "$version" ] && [ -n "$build" ] || fail "xcodebuild -version named no version or build: $xcode"
swift=$(swift --version 2>/dev/null | one_line) || true
[ -n "$swift" ] || fail "swift --version answered nothing"
rust=$(cd ../../core && rustc --version 2>/dev/null | one_line) || true
[ -n "$rust" ] || fail "rustc --version answered nothing in core/"
printf 'xcode=%s/%s\nswift=%s\nrust=%s\n' "$version" "$build" "$swift" "$rust"
