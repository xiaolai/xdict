#!/bin/bash
# The memory budgets live in core/binding-env.sh, by name, beside their reasons (the 2026-11-05 audit, G8): neither
# binding's measure-memory.sh writes a number into its budget, and binding-env.sh answers each step of each binding.
# Reads the scripts; builds and measures nothing. `make test-tools`.
set -uo pipefail
cd "$(dirname "$0")/../../../../core"
failures=0
ok() { echo "ok    $*"; }
bad() { echo "FAIL  $*"; failures=$((failures + 1)); }

for script in xdict-ffi/measure-memory.sh xdict-wasm/measure-memory.sh; do
    [ -f "$script" ] || { bad "$script is missing"; continue; }
    # A budget written in the script: `budget=<n>`, or a number handed to `within`.
    if grep -nE 'budget=[0-9]|within[^#]*[[:space:]][0-9]+([[:space:]]|$)' "$script"; then
        bad "$script writes its own budget number"
    else ok "$script writes no budget number"; fi
    grep -q 'memory_budget ' "$script" && ok "$script asks binding-env.sh for its budgets" \
        || bad "$script does not ask memory_budget"
done
# shellcheck source=/dev/null
core=$PWD; . ./binding-env.sh
for binding in swift worker; do
    for step in import entry refused resource; do
        n=$(memory_budget "$binding" "$step") && [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt 0 ] \
            && ok "$binding $step: $n MiB" || bad "binding-env.sh has no budget for $binding $step"
    done
done
memory_budget swift nothing 2>/dev/null && bad "an unknown step has a budget" || ok "an unknown step is refused"

[ "$failures" -eq 0 ] || { echo "memory-budgets-test: $failures failed" >&2; exit 1; }
echo "memory-budgets-test: all passed"
