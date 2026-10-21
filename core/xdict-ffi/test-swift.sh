#!/bin/sh
# The conformance scenario through the Swift binding (macOS): writes the fixtures, builds the core as a
# library, generates the binding, compiles tests/swift/main.swift against it and runs it.
# XDICT_CONFORMANCE_EXPECTED replaces tiny/expected.json and XDICT_CONFORMANCE_MATRIX_EXPECTED matrix/expected.json,
# to show a wrong expectation failing; a relative path is read from where the script is started.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
core=$(cd "$here/.." && pwd)
. "$core/binding-env.sh"
expected=$(absolute "${XDICT_CONFORMANCE_EXPECTED:-$core/../conformance/fixtures/tiny/expected.json}")
matrix=$(absolute "${XDICT_CONFORMANCE_MATRIX_EXPECTED:-$core/../conformance/fixtures/matrix/expected.json}")
ledger=$(absolute "${XDICT_CONFORMANCE_LEDGER:-$core/../conformance/ledger/cases.json}")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cd "$core"
cargo run -q -p xdict-conformance --bin conformance-fixtures -- "$work/fixtures"
native_binding swift "$work/swift"
swift_program "$work/swift" "$here/tests/swift/main.swift" "$work/conformance"
DYLD_LIBRARY_PATH=$release "$work/conformance" "$work/fixtures/tiny" "$expected" "$work/fixtures/matrix" "$matrix" "$ledger"
