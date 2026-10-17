#!/bin/bash
# The icon sets' staleness check (Tools/icons.sh check) passes on the committed sets, and fails, naming the file, when
# one is changed, missing or extra: its three positive controls. `make test-tools`; a build Mac's (it compiles Swift).
set -uo pipefail
cd "$(dirname "$0")/../.."
fail() { echo "icons-test: FAIL: $*" >&2; exit 1; }
scratch=$(mktemp -d); trap 'rm -rf "$scratch"' EXIT
apps=$(cd .. && pwd)

Tools/icons.sh check || fail "the committed icon sets are not what their source generates"

copy() {  # a fresh copy of the five committed sets, in $scratch/apps
    rm -rf "$scratch/apps"
    for platform in android windows linux web extension; do
        mkdir -p "$scratch/apps/$platform" && cp -R "$apps/$platform/icons" "$scratch/apps/$platform/icons"
    done
}
refused() {  # refused <what> <name the refusal must carry>
    local said
    said=$(XDICT_ICONS_APPS=$scratch/apps Tools/icons.sh check 2>&1) && fail "$1, and the check passed"
    grep -qF "$2" <<<"$said" || fail "$1, and the check failed without naming $2: $said"
}

copy; printf 'x' >>"$scratch/apps/web/icons/icon-512.png"
refused "a generated file changed" "icon-512.png"
copy; rm "$scratch/apps/android/icons/res/mipmap-xxxhdpi/ic_launcher_monochrome.png"
refused "a generated file missing" "ic_launcher_monochrome.png"
copy; echo stray >"$scratch/apps/linux/icons/hicolor/stray.png"
refused "a file the generator does not write" "stray.png"
echo "icons-test: passed (and failed for a changed, a missing and an extra file)"
