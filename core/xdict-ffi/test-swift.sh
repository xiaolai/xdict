#!/bin/sh
# The conformance scenario through the Swift binding (macOS): writes the fixtures, builds the core as a
# library, generates the binding, compiles tests/swift/main.swift against it and runs it.
# XDICT_CONFORMANCE_EXPECTED replaces expected.json, to show a wrong expectation failing.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
core=$(cd "$here/.." && pwd)
expected=${XDICT_CONFORMANCE_EXPECTED:-$core/../conformance/fixtures/tiny/expected.json}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cd "$core"
cargo run -q -p xdict-conformance --bin conformance-fixtures -- "$work/fixtures"
cargo build -q --release -p xdict-ffi
cargo run -q --release -p xdict-ffi --features bindgen --bin uniffi-bindgen -- \
    generate --library target/release/libxdict_ffi.dylib --language swift --out-dir "$work/swift" >/dev/null
swiftc -O -module-name conformance -I "$work/swift" -Xcc -fmodule-map-file="$work/swift/xdictFFI.modulemap" \
    "$work/swift/xdict.swift" "$here/tests/swift/main.swift" \
    -L target/release -lxdict_ffi -o "$work/conformance"
DYLD_LIBRARY_PATH=target/release "$work/conformance" "$work/fixtures/tiny" "$expected"
