#!/bin/bash
# `Tools/build-bundle.sh`'s refusal of the development labs in what ships (`verify_no_development_lab`), driven on bundles
# of the test's own: Mach-O files copied from the system, never built, never signed, never launched. The function and its
# constants are read out of the script, not copied, so this tests what a bundle's build runs. Each refusal is shown once,
# and the clean bundle passes. `make test-tools`.
set -euo pipefail
cd "$(dirname "$0")/../.."
failures=0
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
ok() { echo "ok    $*"; }
bad() { echo "FAIL  $*"; failures=$((failures + 1)); }

names='APP_NAME|SERVICE|SERVICE_ID|XPC_PATH|LAB|LAB_FLAG|LAB_STYLE_FLAG|CAPTURE_LAB|CAPTURE_LAB_FLAG'
definitions=$(grep -E "^readonly ($names)=" Tools/build-bundle.sh || true)
function_text=$(sed -n '/^verify_no_development_lab() {$/,/^}$/p' Tools/build-bundle.sh)
# A reading that found nothing would make every case below vacuous: refuse it first.
[ "$(grep -c . <<<"$definitions")" -eq 9 ] \
    || { echo "FAIL  build-bundle.sh does not define all of $names: $(tr '\n' ' ' <<<"$definitions")"; exit 1; }
grep -q 'CAPTURE_LAB' <<<"$function_text" \
    || { echo "FAIL  verify_no_development_lab does not look for the capture lab"; exit 1; }
eval "$definitions"
eval "$function_text"

bundle() {  # bundle <name>: an app and its service, both real Mach-O files, nothing else
    local root=$scratch/$1.app
    mkdir -p "$root/Contents/MacOS" "$root/$XPC_PATH/Contents/MacOS"
    cp /usr/bin/true "$root/Contents/MacOS/$APP_NAME"
    cp /usr/bin/true "$root/$XPC_PATH/Contents/MacOS/$SERVICE"
    printf '%s\n' "$root"
}

refused() {  # refused <case> <bundle> <words the refusal must hold>
    local said
    if said=$(verify_no_development_lab "$2"); then
        bad "$1: the bundle passed"
    elif grep -qF -- "$3" <<<"$said"; then
        ok "$1: refused ($said)"
    else
        bad "$1: refused for another reason: $said"
    fi
}

clean=$(bundle clean)
if said=$(verify_no_development_lab "$clean"); then ok "a bundle of the app and its service alone passes"
else bad "the clean bundle was refused: $said"; fi

app=$(bundle app-flag)
printf -- '--read-point' >>"$app/Contents/MacOS/$APP_NAME"
refused "the capture lab's flag in the app binary" "$app" "Contents/MacOS/$APP_NAME holds $CAPTURE_LAB_FLAG"

service=$(bundle service-flag)
printf -- '--read-point' >>"$service/$XPC_PATH/Contents/MacOS/$SERVICE"
refused "the capture lab's flag in the service binary" "$service" "holds $CAPTURE_LAB_FLAG"

module=$(bundle app-module)
printf 'XDictCaptureLab' >>"$module/Contents/MacOS/$APP_NAME"
refused "the capture lab's module in the app binary" "$module" "holds $CAPTURE_LAB"

carried=$(bundle carried)
mkdir -p "$carried/Contents/Resources/$CAPTURE_LAB.app"
echo not-a-binary >"$carried/Contents/Resources/$CAPTURE_LAB.app/README"
refused "the capture lab carried in the bundle" "$carried" "carries something named $CAPTURE_LAB"

entry=$(bundle entry-flag)
printf -- '--disable-layer' >>"$entry/Contents/MacOS/$APP_NAME"
refused "the entry lab's flag, as before" "$entry" "holds $LAB_FLAG"

if [ "$failures" -gt 0 ]; then echo "development-lab-test: $failures failure(s)"; exit 1; fi
echo "development-lab-test: passed (and refused the capture lab's flag, its module and the lab itself in what ships)"
