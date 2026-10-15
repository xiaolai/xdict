#!/bin/sh
# ADR-0007 refutation 24: peak memory of import, entry() and resource() on memory-fixture's dictionary, through
# the Swift binding (macOS). Each step runs in its own process, so each peak is that step's, and each is held to a
# budget (`within`, binding-env.sh).
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
over=0
for step in import entry refused resource; do
    line=$(DYLD_LIBRARY_PATH=$release "$work/memory" "$work/fixture" "$step")
    printf '%s\n' "$line"
    case $step in import) budget=16 ;; entry) budget=410 ;; refused) budget=242 ;; resource) budget=240 ;; esac
    within "$line" "$budget" || over=1
done
[ "$over" -eq 0 ] || { echo "a step passed its memory budget" >&2; exit 1; }
