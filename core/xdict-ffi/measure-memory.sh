#!/bin/sh
# ADR-0007 refutation 24: peak memory of import, entry() and resource() on memory-fixture's dictionary, through
# the Swift binding (macOS). Each step runs in its own process, so each peak is that step's.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
core=$(cd "$here/.." && pwd)
. "$core/binding-env.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cd "$core"
cargo run -q --release -p xdict-conformance --bin memory-fixture -- "$work/fixture"
native_binding swift "$work/swift"
swift_program "$work/swift" "$here/tests/memory/main.swift" "$work/memory"
for step in import entry refused resource; do
    DYLD_LIBRARY_PATH=$release "$work/memory" "$work/fixture" "$step"
done
