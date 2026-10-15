#!/bin/bash
# The E2E kit for the entry view's stages (plan-macos-v1 WI-4): the development lab as a signed app, the fixtures the
# core's own MDX writer makes from `conformance/fixtures`, the observers and the analysis, and the pointer helper; the
# drag source (WI-5); the keyboard helper, the lookup stage's driver and the app's hostile run (WI-6).
# Built here, run on the E2E Mac only (`Tools/e2e.sh`); **nothing here launches anything**.
#
#   build-lab.sh      writes .build/e2e-kit/ whole, or fails
#
# `XDictEntryLab` links the core and can switch a confinement layer off, so it is never in XDict.app
# (`Tools/build-bundle.sh` refuses a bundle that carries it); it is signed with the same Developer ID and the hardened
# runtime, as the app is, so it runs on the E2E Mac as the app would.
set -euo pipefail
cd "$(dirname "$0")/.."
readonly LAB=XDictEntryLab
readonly KIT=.build/e2e-kit
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
cp Tools/lookup/drive.py Tools/lookup/run-app-hostile.sh Tools/lookup/verdicts.py "$KIT/lookup/"
# Lookup from anywhere's hands in other apps and its driver (plan-macos-v1 WI-8).
mkdir -p "$KIT/anywhere"
swiftc -O -warnings-as-errors -o "$KIT/anywhere/hands" Tools/anywhere/hands.swift || fail "the hands helper did not build"
cp Tools/anywhere/drive.py "$KIT/anywhere/"
echo "build-lab: $KIT ($(du -sh "$KIT" | cut -f1)): $LAB.app signed by $identity, $(ls "$KIT/fixtures" | wc -l | tr -d ' ') fixtures"
