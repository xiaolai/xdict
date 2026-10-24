#!/bin/bash
# Owner-requested local Xcode iteration (2026-10-24). Builds the actual Swift app only, not tests or Rust.
set -euo pipefail
cd "$(dirname "$0")/.."
apple=$PWD
out=$apple/.build/local-preview
mkdir -p "$out"

case ${1:-} in
    project)
        python3 Tools/live-ui-project.py
        exit
        ;;
    build) ;;
    *) echo "usage: Tools/live-ui.sh project|build" >&2; exit 2 ;;
esac

swift build --product XDict --jobs 4
bin=$(swift build --show-bin-path)
# The existing signed dictionary service supplies the real dictionaries. A core change needs a full app build.
cmp /Applications/XDict.app/Contents/Resources/CoreVersions.json Generated/core-versions.json
stage=$(mktemp -d "$out/stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT
ditto /Applications/XDict.app "$stage/XDict.app"
cp "$bin/XDict" "$stage/XDict.app/Contents/MacOS/XDict"
resources=$stage/XDict.app/Contents/Resources
if [ -f "$resources/Provenance.txt" ]; then
    mv "$resources/Provenance.txt" "$resources/InstalledResourcesProvenance.txt"
fi
cat > "$resources/DevelopmentPreview.txt" <<'TXT'
Local UI development bundle: actual XDict Swift sources, built locally in Debug.
Resources and the unchanged DictionaryService are from the installed app; their core versions match.
This is not a release artifact. Xcode Run uses this copy rather than replacing /Applications/XDict.app.
TXT
identity=$(Tools/build-bundle.sh identity)
Tools/expand-entitlements.sh "$identity" Resources/XDict.entitlements "$out/XDict.entitlements"
codesign --force --options runtime --timestamp=none --entitlements "$out/XDict.entitlements" \
    --sign "$identity" "$stage/XDict.app"
codesign --verify --strict --deep "$stage/XDict.app"
if pgrep -f "$out/XDict.app/Contents/MacOS/XDict" >/dev/null; then
    osascript -e 'tell application id "ai.xdict.app" to quit'
fi
if [ -d "$out/XDict.app" ]; then mv "$out/XDict.app" "$stage/previous.app"; fi
mv "$stage/XDict.app" "$out/XDict.app"
echo "Actual XDict ready: $out/XDict.app"
