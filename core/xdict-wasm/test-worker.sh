#!/bin/sh
# The conformance scenario through the Web binding: writes the fixtures, builds xdict-wasm for
# wasm32-unknown-unknown, runs wasm-bindgen (--target web), then runs tests/worker/ in a Node Worker.
# Needs wasm-bindgen-cli 0.2.129, tsc (the wrapper is type-checked strictly), and Node 24 (which runs
# TypeScript by stripping types, unchecked: the suite itself imports node: modules without typings).
# XDICT_CONFORMANCE_EXPECTED replaces tiny/expected.json, XDICT_CONFORMANCE_MATRIX_EXPECTED matrix/expected.json and
# XDICT_CONFORMANCE_PHRASE phrase/vectors.jsonl, to show a wrong expectation failing; a relative path is read from
# where the script is started.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
core=$(cd "$here/.." && pwd)
. "$core/binding-env.sh"
expected=$(absolute "${XDICT_CONFORMANCE_EXPECTED:-$core/../conformance/fixtures/tiny/expected.json}")
matrix=$(absolute "${XDICT_CONFORMANCE_MATRIX_EXPECTED:-$core/../conformance/fixtures/matrix/expected.json}")
ledger=$(absolute "${XDICT_CONFORMANCE_LEDGER:-$core/../conformance/ledger/cases.json}")
phrase=$(absolute "${XDICT_CONFORMANCE_PHRASE:-$core/../conformance/phrase/vectors.jsonl}")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

tsc --noEmit --strict --target es2022 --module esnext --moduleResolution bundler --lib es2022,dom "$here/ts/xdict.ts"
cd "$core"
cargo run -q -p xdict-conformance --bin conformance-fixtures -- "$work/fixtures"
web_binding "$work/pkg"
node "$here/tests/worker/run.ts" "$work/pkg" "$work/fixtures/tiny" "$expected" "$work/fixtures/matrix" "$matrix" "$ledger" "$phrase"
