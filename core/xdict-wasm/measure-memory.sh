#!/bin/sh
# ADR-0007 refutation 24: peak memory of import, entry() and resource() on memory-fixture's dictionary, through
# the Web binding (Node 24, wasm-bindgen 0.2.129). Each step runs in its own process, so each peak is that step's.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
core=$(cd "$here/.." && pwd)
. "$core/binding-env.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cd "$core"
cargo run -q --release -p xdict-conformance --bin memory-fixture -- "$work/fixture"
web_binding "$work/pkg"
for step in import entry refused resource; do
    node "$here/tests/memory/memory.ts" "$work/pkg" "$work/fixture" "$step"
done
