#!/bin/sh
# The conformance scenario through the Web binding: writes the fixtures, builds xdict-wasm for
# wasm32-unknown-unknown, runs wasm-bindgen (--target web), then runs tests/worker/ in a Node Worker.
# Needs wasm-bindgen-cli 0.2.129, tsc (the wrapper is type-checked strictly), and Node 24 (which runs
# TypeScript by stripping types, unchecked: the suite itself imports node: modules without typings).
# XDICT_CONFORMANCE_EXPECTED replaces tiny/expected.json and XDICT_CONFORMANCE_MATRIX_EXPECTED matrix/expected.json,
# to show a wrong expectation failing.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
core=$(cd "$here/.." && pwd)
expected=${XDICT_CONFORMANCE_EXPECTED:-$core/../conformance/fixtures/tiny/expected.json}
matrix=${XDICT_CONFORMANCE_MATRIX_EXPECTED:-$core/../conformance/fixtures/matrix/expected.json}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

tsc --noEmit --strict --target es2022 --module esnext --moduleResolution bundler --lib es2022,dom "$here/ts/xdict.ts"
cd "$core"
cargo run -q -p xdict-conformance --bin conformance-fixtures -- "$work/fixtures"
cargo build -q --release -p xdict-wasm --target wasm32-unknown-unknown
wasm-bindgen --target web --out-dir "$work/pkg" target/wasm32-unknown-unknown/release/xdict_wasm.wasm
node "$here/tests/worker/run.ts" "$work/pkg" "$work/fixtures/tiny" "$expected" "$work/fixtures/matrix" "$matrix"
