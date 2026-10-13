#!/bin/sh
# ADR-0007 refutation 24: peak memory of import, entry() and resource() on memory-fixture's dictionary, through
# the Swift binding (macOS). Each step runs in its own process, so each peak is that step's.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
core=$(cd "$here/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cd "$core"
cargo run -q --release -p xdict-conformance --bin memory-fixture -- "$work/fixture"
cargo build -q --release -p xdict-ffi
cargo run -q --release -p xdict-ffi --features bindgen --bin uniffi-bindgen -- \
    generate --library target/release/libxdict_ffi.dylib --language swift --out-dir "$work/swift" >/dev/null
swiftc -O -module-name memory -I "$work/swift" -Xcc -fmodule-map-file="$work/swift/xdictFFI.modulemap" \
    "$work/swift/xdict.swift" "$here/tests/memory/main.swift" -L target/release -lxdict_ffi -o "$work/memory"
for step in import entry refused resource; do
    DYLD_LIBRARY_PATH=target/release "$work/memory" "$work/fixture" "$step"
done
