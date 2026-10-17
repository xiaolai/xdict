#!/bin/bash
# **The style-report parity check stays on demand** (owner, 2026-10-17): core/xdict-ffi/style-report-parity.sh runs
# only when asked. No default path may name it, its case or its programs: `conformance/`, the CI workflows, this
# Makefile (`make test`, `make land`), the tools `make land` and E2E run, and the default binding scripts.
# Its positive control: the same scan, over a copy of a default file that names it, must find it.
set -uo pipefail
cd "$(dirname "$0")/../../../.."
failures=0
ok() { echo "ok    $*"; }
bad() { echo "FAIL  $*"; failures=$((failures + 1)); }
names='style-report-parity|style-report-case|tests/style-report'

defaults=(.github/workflows conformance core/xdict-conformance apps/apple/Makefile apps/apple/Tools
          core/binding-env.sh core/xdict-ffi/test-swift.sh core/xdict-ffi/test-kotlin.sh core/xdict-ffi/measure-memory.sh
          core/xdict-wasm)
for path in "${defaults[@]}"; do
    [ -e "$path" ] || bad "default path missing, so the scan would say nothing about it: $path"
done
# This test names them itself, to look for them.
found=$(grep -rlE "$names" "${defaults[@]}" 2>/dev/null | grep -v '^apps/apple/Tools/tests/on-demand-test.sh$')
if [ -z "$found" ]; then ok "no default path names the style-report parity check"
else bad "a default path names the on-demand style-report check: $found"; fi

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
{ cat core/xdict-ffi/test-swift.sh; echo 'sh "$here/style-report-parity.sh"'; } >"$scratch/test-swift.sh"
if grep -qE "$names" "$scratch/test-swift.sh"; then ok "the scan finds the check where a default script names it"
else bad "the scan missed a planted name: it cannot fail"; fi

[ -x core/xdict-ffi/style-report-parity.sh ] && ok "the on-demand check exists" ||
    bad "core/xdict-ffi/style-report-parity.sh is missing or not executable"
[ "$failures" -eq 0 ] || exit 1
