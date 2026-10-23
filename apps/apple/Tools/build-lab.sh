#!/bin/bash
# The E2E kit for the entry view's stages (plan-macos-v1 WI-4): the development lab as a signed app, the fixtures the
# core's own MDX writer makes from `conformance/fixtures`, the observers and the analysis, and the pointer helper; the
# drag source (WI-5); the keyboard helper, the lookup stage's driver and the app's hostile run (WI-6); the capture lab,
# `--read-point` (plan-capture WI-4). Built here, run on the E2E Mac only (`Tools/e2e.sh`); **nothing here launches anything**.
#
#   build-lab.sh             writes .build/e2e-kit/ whole, or fails
#   build-lab.sh --app-only  only the signed lab, into .build/lab-kit/ (Tools/gallery/lab.sh: compiles nothing here)
#
# `XDictEntryLab` links the core and can switch a confinement layer off, so it is never in XDict.app
# (`Tools/build-bundle.sh` refuses a bundle that carries it); it is signed with the same Developer ID and the hardened
# runtime, as the app is, so it runs on the E2E Mac as the app would.
set -euo pipefail
cd "$(dirname "$0")/.."
readonly LAB=XDictEntryLab
APP_ONLY=0
[ "${1:-}" = --app-only ] && APP_ONLY=1
if [ "$APP_ONLY" = 1 ]; then readonly KIT=.build/lab-kit; else readonly KIT=.build/e2e-kit; fi
readonly APP=$KIT/$LAB.app
fail() { echo "build-lab: $*" >&2; exit 1; }

identity=$(Tools/build-bundle.sh identity) || fail "no signing identity"
python3 -I Tools/hostile/battery.py --check || fail "conformance/fixtures/hostile is stale: run Tools/hostile/battery.py"

if [ -n "${XDICT_REMOTE_PRODUCTS:-}" ]; then
    # Built on BUILD_HOST (Tools/remote-build.sh), and only of the tree here now.
    [ "$(cat "$XDICT_REMOTE_PRODUCTS/source-tree" 2>/dev/null)" = "$(Tools/source-tree.sh)" ] \
        || fail "$XDICT_REMOTE_PRODUCTS was not built of this source tree: make app"
    products=$XDICT_REMOTE_PRODUCTS
else
    swift build -c release --product "$LAB" >/dev/null || fail "swift build of $LAB failed"
    products=$(swift build -c release --show-bin-path)
fi
[ -x "$products/$LAB" ] || fail "swift build produced no $LAB"

rm -rf "$KIT"
mkdir -p "$APP/Contents/MacOS" "$KIT/fixtures"
cp "$products/$LAB" "$APP/Contents/MacOS/$LAB"
# The phonetic faces, where the entry view reads them in the app (`EntryFonts.bundled`).
mkdir -p "$APP/Contents/Resources" && cp -R Resources/Fonts "$APP/Contents/Resources/"
cat >"$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>ai.xdict.lab.entry</string>
    <key>CFBundleName</key><string>XDictEntryLab</string>
    <key>CFBundleExecutable</key><string>XDictEntryLab</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0</string>
    <key>CFBundleVersion</key><string>0</string>
    <key>LSMinimumSystemVersion</key><string>27.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --options runtime --timestamp=none --sign "$identity" "$APP" >/dev/null
codesign --verify --strict "$APP" || fail "$APP does not verify"
[ "$APP_ONLY" = 1 ] && { echo "build-lab: $APP signed by $identity"; exit 0; }

# **The capture lab** (plan-capture WI-4): `--read-point X Y` through hover's own reader, a deputy for whoever runs it, so
# never in XDict.app (`Tools/build-bundle.sh` refuses it there and checks this binary holds what it searches for). Its own
# identifier and the same Developer ID: its Accessibility and Screen Recording grants are its own, given by hand on the E2E
# Mac, and none of XDict.app's are borrowed. Background only: it shows nothing and prints one line.
readonly CAPTURE_LAB=XDictCaptureLab
readonly CAPTURE_APP=$KIT/$CAPTURE_LAB.app
if [ -z "${XDICT_REMOTE_PRODUCTS:-}" ]; then
    swift build -c release --product "$CAPTURE_LAB" >/dev/null || fail "swift build of $CAPTURE_LAB failed"
fi
[ -x "$products/$CAPTURE_LAB" ] || fail "swift build produced no $CAPTURE_LAB"
mkdir -p "$CAPTURE_APP/Contents/MacOS"
cp "$products/$CAPTURE_LAB" "$CAPTURE_APP/Contents/MacOS/$CAPTURE_LAB"
cat >"$CAPTURE_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>ai.xdict.lab.capture</string>
    <key>CFBundleName</key><string>XDictCaptureLab</string>
    <key>CFBundleExecutable</key><string>XDictCaptureLab</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0</string>
    <key>CFBundleVersion</key><string>0</string>
    <key>LSMinimumSystemVersion</key><string>27.0</string>
    <key>LSBackgroundOnly</key><true/>
</dict>
</plist>
PLIST
codesign --force --options runtime --timestamp=none --sign "$identity" "$CAPTURE_APP" >/dev/null
codesign --verify --strict "$CAPTURE_APP" || fail "$CAPTURE_APP does not verify"

# The fixtures, by the core's writer: every folder of conformance/fixtures, the battery and the twins among them.
kit_abs=$(cd "$KIT" && pwd)
(cd ../../core && cargo run -q -p xdict-conformance --bin conformance-fixtures -- "$kit_abs/fixtures") \
    || fail "the core's fixture writer failed"
for fixture in hostile twin-a twin-b; do
    ls "$KIT/fixtures/$fixture/"*.mdx >/dev/null 2>&1 || fail "the writer wrote no $fixture"
done
cp ../../conformance/fixtures/hostile/cases.json "$KIT/cases.json"
cp Tools/hostile/observe.py Tools/hostile/dns_oracle.py Tools/hostile/analyze.py Tools/hostile/reader.py \
    Tools/hostile/run-hostile.sh "$KIT/"
swiftc -O -warnings-as-errors -o "$KIT/pointer" Tools/hostile/pointer.swift || fail "the pointer helper did not build"
# The library stage's drag source: a file dragged in from another app (plan-macos-v1 WI-5).
swiftc -O -warnings-as-errors -o "$KIT/dragsource" Tools/library/dragsource.swift || fail "the drag source did not build"
# The lookup stage's keyboard and driver, and the app's own runs of the hostile and entries checks (plan-macos-v1 WI-6).
mkdir -p "$KIT/lookup"
swiftc -O -warnings-as-errors -o "$KIT/lookup/keys" Tools/lookup/keys.swift || fail "the keyboard helper did not build"
cp Tools/lookup/drive.py Tools/lookup/lookup_checks.py Tools/lookup/typing_check.py Tools/lookup/run-app-hostile.sh Tools/lookup/verdicts.py "$KIT/lookup/"
# Lookup from anywhere's hands in other apps and its driver (plan-macos-v1 WI-8).
mkdir -p "$KIT/anywhere"
swiftc -O -warnings-as-errors -o "$KIT/anywhere/hands" Tools/anywhere/hands.swift || fail "the hands helper did not build"
cp Tools/anywhere/drive.py Tools/anywhere/front.py Tools/anywhere/hostcondition.py Tools/anywhere/selection.py "$KIT/anywhere/"
# The WI-10 measurement's driver and its arithmetic.
mkdir -p "$KIT/measure"
cp Tools/measure/drive.py Tools/measure/stats.py "$KIT/measure/"

mkdir -p "$KIT/hover"
cp Tools/hover/drive.py "$KIT/hover/"
echo "build-lab: $KIT ($(du -sh "$KIT" | cut -f1)): $LAB.app and $CAPTURE_LAB.app signed by $identity, $(ls "$KIT/fixtures" | wc -l | tr -d ' ') fixtures"
