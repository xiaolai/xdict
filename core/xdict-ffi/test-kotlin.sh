#!/bin/sh
# The conformance scenario through the Kotlin binding on the JVM: writes the fixtures, builds the core as a
# library, generates the binding, compiles tests/kotlin/Conformance.kt against it and runs it.
# Needs kotlinc, a JDK, and JNA (JNA_JAR; defaults to the Maven cache's 5.12.1).
# XDICT_CONFORMANCE_EXPECTED replaces tiny/expected.json and XDICT_CONFORMANCE_MATRIX_EXPECTED matrix/expected.json,
# to show a wrong expectation failing; a relative path, JNA_JAR's too, is read from where the script is started.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
core=$(cd "$here/.." && pwd)
. "$core/binding-env.sh"
expected=$(absolute "${XDICT_CONFORMANCE_EXPECTED:-$core/../conformance/fixtures/tiny/expected.json}")
matrix=$(absolute "${XDICT_CONFORMANCE_MATRIX_EXPECTED:-$core/../conformance/fixtures/matrix/expected.json}")
ledger=$(absolute "${XDICT_CONFORMANCE_LEDGER:-$core/../conformance/ledger/cases.json}")
jna=$(absolute "${JNA_JAR:-$HOME/.m2/repository/net/java/dev/jna/jna/5.12.1/jna-5.12.1.jar}")
[ -f "$jna" ] || { echo "JNA not found at $jna: set JNA_JAR" >&2; exit 2; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cd "$core"
cargo run -q -p xdict-conformance --bin conformance-fixtures -- "$work/fixtures"
native_binding kotlin "$work/kotlin"
# kotlinc's own status decides; only its warnings are dropped from what is shown.
status=0
kotlinc -nowarn -include-runtime -cp "$jna" -d "$work/conformance.jar" \
    "$work/kotlin/uniffi/xdict/xdict.kt" "$here/tests/kotlin/Conformance.kt" >"$work/kotlinc.log" 2>&1 || status=$?
grep -v '^warning:' "$work/kotlinc.log" >&2 || true
[ "$status" -eq 0 ] || { echo "kotlinc failed (exit $status)" >&2; exit 1; }
java --enable-native-access=ALL-UNNAMED -Djna.library.path="$release" \
    -cp "$work/conformance.jar:$jna" ConformanceKt "$work/fixtures/tiny" "$expected" "$work/fixtures/matrix" "$matrix" "$ledger"
