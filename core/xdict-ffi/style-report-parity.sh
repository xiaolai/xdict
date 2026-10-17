#!/bin/sh
# **On demand only** (owner, 2026-10-17): the reading style's report (`Core::reading_style`, ADR-0010) through the
# Swift and Kotlin bindings, compared field by field with the core's own on one case the test suite's MDX writer makes
# (examples/style-report-case.rs). Not part of `conformance/`, CI, `make test`, `make land` or test-swift.sh /
# test-kotlin.sh; run it before shipping any shell other than macOS, or when the owner asks.
#
# Usage: style-report-parity.sh [swift] [kotlin] [web]   (default: swift kotlin)
# The Web binding does not export the report: it is said so, never counted as a pass, and naming `web` fails.
# XDICT_STYLE_REPORT_PLANT=<swift|kotlin> alters that binding's output before comparing: the check's positive control.
# Kotlin needs kotlinc, a JDK and JNA (JNA_JAR; defaults to the Maven cache's 5.12.1).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
core=$(cd "$here/.." && pwd)
. "$core/binding-env.sh"
plant=${XDICT_STYLE_REPORT_PLANT:-}
shells=${*:-swift kotlin}
jna=$(absolute "${JNA_JAR:-$HOME/.m2/repository/net/java/dev/jna/jna/5.12.1/jna-5.12.1.jar}")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cd "$core"
cargo run -q -p xdict-ffi --example style-report-case -- "$work/case"
[ -s "$work/case/expected.json" ] || { echo "the core wrote no report" >&2; exit 1; }
status=0
compared=0
for shell in $shells; do
    mark=
    [ "$shell" = "$plant" ] && mark=plant
    case $shell in
    swift)
        native_binding swift "$work/swift"
        swift_program "$work/swift" "$here/tests/style-report/main.swift" "$work/stylereport"
        DYLD_LIBRARY_PATH=$release "$work/stylereport" "$work/case" >"$work/swift.json"
        python3 -I "$here/tests/style-report/compare.py" swift "$work/case/expected.json" "$work/swift.json" $mark ||
            status=1
        compared=$((compared + 1)) ;;
    kotlin)
        [ -f "$jna" ] || { echo "JNA not found at $jna: set JNA_JAR" >&2; exit 2; }
        native_binding kotlin "$work/kotlin"
        kstatus=0
        kotlinc -nowarn -include-runtime -cp "$jna" -d "$work/style-report.jar" \
            "$work/kotlin/uniffi/xdict/xdict.kt" "$here/tests/style-report/StyleReport.kt" >"$work/kotlinc.log" 2>&1 ||
            kstatus=$?
        grep -v '^warning:' "$work/kotlinc.log" >&2 || true
        [ "$kstatus" -eq 0 ] || { echo "kotlinc failed (exit $kstatus)" >&2; exit 1; }
        java --enable-native-access=ALL-UNNAMED -Djna.library.path="$release" \
            -cp "$work/style-report.jar:$jna" StyleReportKt "$work/case" >"$work/kotlin.json"
        python3 -I "$here/tests/style-report/compare.py" kotlin "$work/case/expected.json" "$work/kotlin.json" $mark ||
            status=1
        compared=$((compared + 1)) ;;
    web)
        echo "web: not exported (xdict-wasm has no reading style; owner, 2026-10-17)"
        status=1 ;;
    *)
        echo "unknown shell: $shell (swift, kotlin, web)" >&2
        exit 2 ;;
    esac
done
case " $shells " in *" web "*) ;; *) echo "web: not exported (not compared, not counted)" ;; esac
[ "$compared" -gt 0 ] || status=1
exit "$status"
