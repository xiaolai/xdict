#!/bin/bash
# Extracts every localizable string from the source and syncs it into the catalog, Strings/Localizable.xcstrings.
# Adapted from XiaolaiDict's `Tools/strings.sh`; the measurements below are theirs.
#
# `swiftc -emit-localized-strings` writes one .stringsdata file per source file, holding the keys passed to APIs that
# localize — `String(localized:)`, `LocalizedStringResource`, and every SwiftUI initialiser that takes a
# `LocalizedStringKey`. `xcstringstool sync` merges those into the catalog, adding what is new and marking stale what the
# source no longer says. New entries arrive untranslated: `StringCatalogTests` fails until each has its English and its
# Simplified Chinese, and a stale one until it is removed. The catalog is the file a translator is given.
#
# Built into a scratch path of its own, so every run compiles every file: against the ordinary build directory an
# up-to-date target emits no .stringsdata, and a sync against none would mark every string stale. The app's product
# only, which is every module the reader sees text from; the service carries none.
set -euo pipefail
cd "$(dirname "$0")/.."
readonly CATALOG=Strings/Localizable.xcstrings
# Absolute: the compiler resolves this per target, from a working directory of its own.
readonly EXTRACTED=$PWD/.build/localized-strings
fail() { echo "strings: $*" >&2; exit 1; }

rm -rf "$EXTRACTED" .build/strings
mkdir -p "$EXTRACTED" "$(dirname "$CATALOG")"
[ -e "$CATALOG" ] || printf '{\n  "sourceLanguage" : "en",\n  "strings" : {\n\n  },\n  "version" : "1.0"\n}\n' >"$CATALOG"

# **A basename collision loses one file's strings, silently**: .stringsdata files are named after the source file, not
# its path, so two sources of one name write one file and the second clobbers the first (measured in XiaolaiDict).
# `main.swift` is exempt: SwiftPM requires the name, and the service's carries no reader text.
collisions=$(find Sources -name '*.swift' -exec basename {} \; | grep -v '^main\.swift$' | sort | uniq -d || true)
[ -z "$collisions" ] || fail "two sources share a basename, so one's .stringsdata overwrites the other's: $collisions"

swift build --scratch-path .build/strings --product XDict \
    -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$EXTRACTED" >/dev/null

count=$(find "$EXTRACTED" -name '*.stringsdata' | wc -l | tr -d ' ')
[ "$count" -gt 0 ] || fail "the build produced no .stringsdata, so nothing was extracted; the catalog is left alone"

# Synced into a copy first: a partial extraction takes strings out wholesale (XiaolaiDict measured 117 → 42), while a
# real deletion removes a few. Losing more than a fifth is refused unless the caller says it is meant.
strings_in() { python3 -c 'import json, sys; print(len(json.load(open(sys.argv[1]))["strings"]))' "$1"; }
before=$(strings_in "$CATALOG")
candidate=$(mktemp -d)/Localizable.xcstrings
cp "$CATALOG" "$candidate"
xcrun xcstringstool sync "$candidate" --stringsdata "$EXTRACTED"/*.stringsdata
after=$(strings_in "$candidate")
if [ "$before" -gt 0 ] && [ $((after * 5)) -lt $((before * 4)) ] && [ "${ALLOW_SHRINK:-}" != 1 ]; then
    fail "the sync would take the catalog from $before strings to $after, which looks like a partial extraction; \
nothing was written. If the strings really are gone: ALLOW_SHRINK=1 make strings"
fi
cp "$candidate" "$CATALOG"
echo "strings: $after in $CATALOG (was $before), from $count source files"
