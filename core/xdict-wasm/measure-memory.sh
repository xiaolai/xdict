#!/bin/sh
# ADR-0007 refutation 24: peak memory of import, entry() and resource() on memory-fixture's dictionary, through
# the Web binding inside a Node Worker, as the Web shell runs the core (Node 24, wasm-bindgen 0.2.129). Each step
# runs in its own process, so each peak is that step's, and each is held to a budget (`within`, binding-env.sh).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
core=$(cd "$here/.." && pwd)
. "$core/binding-env.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cd "$core"
cargo run -q --release -p xdict-conformance --bin memory-fixture -- "$work/fixture"
web_binding "$work/pkg"
over=0
for step in import entry refused resource; do
    line=$(node "$here/tests/memory/memory.ts" "$work/pkg" "$work/fixture" "$step")
    printf '%s\n' "$line"
    # entry and refused re-set on the single build host (2026-10-17): the same core grows wasm memory 2 -> 269 MiB
    # on both hosts, but Node's own resident memory there sits 3-4 MiB above the Mac mini these were first measured on
    # (refused 362-363, entry 507-514 on the tree before and after entry-defects alike); ~1% above the highest, as before.
    case $step in import) budget=125 ;; entry) budget=520 ;; refused) budget=367 ;; resource) budget=333 ;; esac
    within "$line" "$budget" || over=1
done
[ "$over" -eq 0 ] || { echo "a step passed its memory budget" >&2; exit 1; }
