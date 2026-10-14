#!/bin/bash
# The Rust core, built for the macOS shell. `make` runs this before anything Swift is compiled.
#
#   Tools/build-core.sh   bring Generated/ (untracked) up to date:
#     Generated/xdictFFI.xcframework   libxdict_ffi.a for aarch64-apple-darwin and its C header, as SwiftPM's
#                                      binary target `xdictFFI`
#     Generated/XDictCore/xdict.swift  the UniFFI Swift binding generated from that library, as the target `XDictCore`
#     Generated/core-versions.json     `versions()` read through that binding and that library: what the bundle's
#                                      dictionary service must answer (`Tools/build-bundle.sh` ships it, the E2E
#                                      `launch` stage compares the handshake with it)
#
# **A static library, linked into the dictionary service alone** (AGENTS.md: every `.mdx` and `.mdd` is parsed in the
# XPC service). The crate already declares `staticlib`. It goes to SwiftPM as an XCFramework because that is the form a
# binary target takes, and a binary target needs no `unsafeFlags`: SwiftPM links the archive into whatever depends on
# it, and only `XDictCore` does, and only `XDictService` depends on that (`ModuleBoundaryTests`). The binding scripts
# link with `-L <dir> -lxdict_ffi`, where cargo also writes the dylib, and the linker prefers the dylib; an XCFramework
# holding only the archive cannot be linked dynamically by accident (`Tools/build-bundle.sh` asserts it of the binary).
#
# Cargo writes into a target directory of this package's own (`.build/cargo`), so the archive the bundle carries is the
# one this script built, never one another build of the workspace left in `core/target`. Generated/ is replaced only
# where its content changed: an unchanged core leaves every file's time alone, and SwiftPM recompiles nothing.
set -euo pipefail
apple=$(cd "$(dirname "$0")/.." && pwd)
core=$(cd "$apple/../../core" && pwd)
readonly apple core
readonly triple=aarch64-apple-darwin
readonly target=$apple/.build/cargo
readonly stage=$apple/.build/core-stage
readonly generated=$apple/Generated
fail() { echo "build-core: $*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || fail "the macOS shell's core is built on macOS"
command -v cargo >/dev/null || fail "cargo is not on PATH"
command -v xcodebuild >/dev/null || fail "xcodebuild is not on PATH: the XCFramework needs Xcode"

rm -rf "$stage"
mkdir -p "$stage/headers" "$stage/XDictCore" "$stage/binding" "$stage/probe"

# 1. The archive, copied at once: the generator below builds the crate again with its own feature, into the same
#    directory, and what ships must be the plain build.
(cd "$core" && CARGO_TARGET_DIR=$target cargo build --quiet --release --locked -p xdict-ffi --target "$triple")
built=$target/$triple/release/libxdict_ffi.a
[ -s "$built" ] || fail "cargo reported success and wrote no $built"
cp "$built" "$stage/libxdict_ffi.a"

# 2. The binding, generated from that archive (UniFFI reads the metadata the library itself carries).
(cd "$core" && CARGO_TARGET_DIR=$target cargo run --quiet --release --locked -p xdict-ffi --target "$triple" \
    --features bindgen --bin uniffi-bindgen -- \
    generate --no-format --library "$stage/libxdict_ffi.a" --language swift --out-dir "$stage/binding" >/dev/null)
for file in xdict.swift xdictFFI.h xdictFFI.modulemap; do
    [ -s "$stage/binding/$file" ] || fail "uniffi-bindgen wrote no $file"
done
grep -qx 'module xdictFFI {' "$stage/binding/xdictFFI.modulemap" \
    || fail "the generated module map no longer declares module xdictFFI, which Package.swift names"
cp "$stage/binding/xdict.swift" "$stage/XDictCore/xdict.swift"
cp "$stage/binding/xdictFFI.h" "$stage/headers/xdictFFI.h"
# SwiftPM finds a binary target's module map by this name only.
cp "$stage/binding/xdictFFI.modulemap" "$stage/headers/module.modulemap"

# 3. The XCFramework: the archive and its headers, one slice.
xcodebuild -create-xcframework -library "$stage/libxdict_ffi.a" -headers "$stage/headers" \
    -output "$stage/xdictFFI.xcframework" >/dev/null
[ -s "$stage/xdictFFI.xcframework/Info.plist" ] || fail "xcodebuild wrote no XCFramework"

# 4. Unchanged archive and binding: nothing to replace, and the versions read from them before still stand.
if [ -s "$generated/core-versions.json" ] \
    && diff -rq "$stage/xdictFFI.xcframework" "$generated/xdictFFI.xcframework" >/dev/null 2>&1 \
    && diff -rq "$stage/XDictCore" "$generated/XDictCore" >/dev/null 2>&1; then
    rm -rf "$stage"
    echo "build-core: Generated/ is up to date ($(cat "$generated/core-versions.json"))"
    exit 0
fi

# 5. The core's versions, read through this binding and this archive by a program of their own. Linked by the archive's
#    path, so nothing can pick a dylib instead. iconv is what the archive asks of the system
#    (`cargo rustc … --print native-static-libs`: -liconv -lSystem -lc -lm).
swiftc -O -module-name coreversions -I "$stage/headers" -Xcc -fmodule-map-file="$stage/headers/module.modulemap" \
    "$stage/XDictCore/xdict.swift" "$apple/Tools/core-versions/main.swift" \
    "$stage/libxdict_ffi.a" -liconv -o "$stage/probe/core-versions"
"$stage/probe/core-versions" >"$stage/core-versions.json"
[ -s "$stage/core-versions.json" ] || fail "the core's versions could not be read"
rm -rf "$stage/headers" "$stage/binding" "$stage/probe" "$stage/libxdict_ffi.a"

# 6. Into place, whole.
rm -rf "$generated"
mv "$stage" "$generated"
echo "build-core: Generated/ written ($(cat "$generated/core-versions.json"))"
