#!/bin/bash
# The app icon, compiled: `Resources/XDict.icon` (Icon Composer's document) into `<dir>/Assets.car` by actool. A build
# Mac's job, never the Air's (AGENTS.md): `Tools/remote-build.sh` runs it on BUILD_HOST and brings the catalogue back,
# and `Tools/build-bundle.sh` runs it only when it builds everything itself.
#
#   compile-icon.sh <dir>
#
# macOS 26 and later draw an app icon themselves (shape, glass, dark, tinted and clear) from layered contents, so the
# catalogue carries the layers, not a picture. Every guard below is a way actool has been seen to fail while exiting 0
# (adapted from XiaolaiDict's `Tools/build-bundle.sh` and `Tools/actool.sh`):
# - it writes no catalogue at all for a bad manifest, so the catalogue must exist;
# - it prints warnings and exits 0, so its report is kept and any warning or error fails;
# - it can hold only flattened bitmaps, which is a picture of the icon, so the catalogue must hold an IconImageStack;
# - it also writes `XDict.icns` with four members only (16 and 128 pt): that is not shipped, and no fallback is needed,
#   since nothing below XDict's floor (macOS 27) runs it;
# - a helper it spawns leaves one icon render per compile in the per-user temporary directory, which `TMPDIR` does not
#   steer: the renders this compile made are found by a marker and removed, and a survivor fails the run.
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { echo "compile-icon: $*" >&2; exit 1; }

readonly NAME=XDict
readonly MINIMUM_MACOS=27.0
out=${1:-}
[ -n "$out" ] || fail "usage: $0 <dir>"
mkdir -p "$out"
out=$(cd "$out" && pwd)
# Absolute paths: actool resolves relative ones against a working directory it cached from an earlier call.
readonly DOCUMENT=$PWD/Resources/$NAME.icon
[ -s "$DOCUMENT/icon.json" ] || fail "there is no $DOCUMENT/icon.json"
rm -f "$out/Assets.car" "$out/$NAME.icns" "$out/partial.plist" "$out/actool.log"

user_tmp=$(getconf DARWIN_USER_TEMP_DIR)
user_tmp=${user_tmp%/}
marker=$(mktemp "$user_tmp/xdict-actool-marker.XXXXXX")
trap 'rm -f "$marker"' EXIT
status=0
xcrun actool "$DOCUMENT" --compile "$out" --app-icon "$NAME" --output-partial-info-plist "$out/partial.plist" \
    --platform macosx --minimum-deployment-target "$MINIMUM_MACOS" --target-device mac \
    --errors --warnings --output-format human-readable-text >"$out/actool.log" 2>&1 || status=$?
renders() { find "$user_tmp" -maxdepth 2 -name "${NAME}1024x1024_*.png" -newer "$marker"; }
while IFS= read -r render; do
    rm -f "$render"
    rmdir "$(dirname "$render")" 2>/dev/null || true   # only a directory this emptied
done < <(renders)
[ -z "$(renders)" ] || fail "actool's icon render was left in $user_tmp and could not be removed"

[ "$status" = 0 ] || { cat "$out/actool.log" >&2; fail "actool exited $status"; }
if grep -qiE ": (warning|error):" "$out/actool.log"; then
    cat "$out/actool.log" >&2
    fail "actool reported problems with $DOCUMENT"
fi
[ -s "$out/Assets.car" ] || { cat "$out/actool.log" >&2; fail "actool wrote no Assets.car"; }
icon_name=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIconName" "$out/partial.plist" 2>/dev/null) || icon_name=""
[ "$icon_name" = "$NAME" ] || fail "actool compiled icon '$icon_name', not $NAME"
catalogue=$(xcrun assetutil --info "$out/Assets.car") || fail "assetutil cannot read $out/Assets.car"
grep -q IconImageStack <<<"$catalogue" || fail "Assets.car has no IconImageStack: no layered icon"
rm -f "$out/$NAME.icns" "$out/partial.plist"
echo "compile-icon: $out/Assets.car ($(wc -c <"$out/Assets.car" | tr -d ' ') bytes)"
