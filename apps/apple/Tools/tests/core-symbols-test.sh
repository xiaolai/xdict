#!/bin/bash
# `Tools/build-bundle.sh`'s check that the core is in the service and not in the app, read off the products before
# `strip -x` (`verify_core_unstripped`; the 2026-11-05 audit, L16). Driven on binaries of the test's own, compiled from a
# few lines of C: a local (static) symbol named like the core's stands for the core's hidden Rust symbols. Shown here:
# `strip -x` erases such a symbol, so a check after it saw nothing; the check refuses an app that holds one, and a
# service that holds none (nm read nothing); a clean pair passes; and assemble() runs it before its strip. `make test-tools`.
set -euo pipefail
cd "$(dirname "$0")/../.."
failures=0
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
ok() { echo "ok    $*"; }
bad() { echo "FAIL  $*"; failures=$((failures + 1)); }

definitions=$(grep -E "^readonly CORE_SYMBOLS=" Tools/build-bundle.sh || true)
function_text=$(sed -n '/^verify_core_unstripped() {$/,/^}$/p' Tools/build-bundle.sh)
[ -n "$definitions" ] || { echo "FAIL  build-bundle.sh defines no CORE_SYMBOLS"; exit 1; }
[ -n "$function_text" ] || { echo "FAIL  build-bundle.sh has no verify_core_unstripped"; exit 1; }
eval "$definitions"
eval "$function_text"

binary() {  # binary <name> <C source>: a linked executable
    printf '%s\n' "$2" >"$scratch/$1.c"
    cc -O0 -o "$scratch/$1" "$scratch/$1.c" || { echo "FAIL  cc could not build $1"; exit 1; }
    printf '%s\n' "$scratch/$1"
}
core='static int xdict_core_lookup(int x) { return x + 1; }
int main(int argc, char **argv) { (void)argv; return xdict_core_lookup(argc) == 0; }'
plain='int main(void) { return 0; }'
app_with_core=$(binary app-with-core "$core")
service=$(binary service "$core")
app=$(binary app "$plain")

# The mechanism: a local core symbol is there as linked and gone after strip -x, which build-bundle.sh runs.
cp "$app_with_core" "$scratch/stripped"
strip -S -x "$scratch/stripped"
if nm "$app_with_core" | grep -qE "$CORE_SYMBOLS" && ! nm "$scratch/stripped" | grep -qE "$CORE_SYMBOLS"; then
    ok "strip -x erases a local core symbol: a check after the strip cannot see it"
else bad "a local core symbol survives strip -x, or was never there: the premise does not hold"; fi

if out=$(verify_core_unstripped "$app" "$service"); then ok "a clean app beside a service with the core passes"
else bad "a clean pair refused: $out"; fi
if out=$(verify_core_unstripped "$app_with_core" "$service"); then bad "an unstripped app holding the core passed"
else ok "an app holding a core symbol is refused: $out"; fi
if out=$(verify_core_unstripped "$app" "$app"); then bad "a service with no core symbol passed"
else ok "a service with no core symbol is refused (nm read nothing): $out"; fi

# assemble() checks the products before it strips its copies.
body=$(sed -n '/^assemble() {$/,/^}$/p' Tools/build-bundle.sh)
check_line=$(grep -n 'verify_core_unstripped "\$products' <<<"$body" | head -1 | cut -d: -f1)
strip_line=$(grep -n 'strip -S -x' <<<"$body" | head -1 | cut -d: -f1)
if [ -n "$check_line" ] && [ -n "$strip_line" ] && [ "$check_line" -lt "$strip_line" ]; then
    ok "assemble() checks the unstripped products (line $check_line) before strip -x (line $strip_line)"
else bad "assemble() does not check the products before its strip (check ${check_line:-none}, strip ${strip_line:-none})"; fi

[ "$failures" -eq 0 ] || { echo "core-symbols-test: $failures failed" >&2; exit 1; }
echo "core-symbols-test: all passed"
