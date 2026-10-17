#!/bin/bash
# Assembles, signs, verifies and publishes XDict.app around the SwiftPM products, under one lock. Adapted from
# XiaolaiDict's `Tools/build-bundle.sh` (its ADR-0026: a signed build is not a shippable one); every guard there was
# learned from a build that looked successful and was not. The Makefile is the menu; this is the transaction.
#
#   build-bundle.sh build            bring .build/XDict.app up to date: build, assemble, sign, verify, publish
#   build-bundle.sh verify <bundle>  verification alone, of any bundle
#   build-bundle.sh identity         the signing identity a build would use
#   build-bundle.sh clean            remove the bundle, the stage and the record (not SwiftPM's or cargo's caches)
#
# **Nothing here launches the bundle.** The build Mac's screen is the owner's (owner, 2026-10-14): the app and its
# service are started only on the E2E Mac, where the `launch` stage asks the handshake (`Tools/e2e.sh`).
#
# Environment:
#   XDICT_SIGN_ID       a Developer ID Application identity. Unset: the login keychain's, which must be exactly one
#   XDICT_REMOTE_PRODUCTS  set by `make` when BUILD_HOST is: the products Tools/remote-build.sh built there, used in
#                       place of a build here (and its warnings gate, run there)
#   XDICT_BUILD_NUMBER  CFBundleVersion of a release, a positive integer from the release counter. Unset: a development
#                       build, numbered from the UTC clock and signed offline
set -euo pipefail
cd "$(dirname "$0")/.."

readonly APP_NAME=XDict
readonly BUNDLE_ID=ai.xdict.app
readonly SERVICE=XDictService
readonly SERVICE_ID=ai.xdict.app.DictionaryService
# The platform floor, as AGENTS.md decides it: both plists and every binary are held to it here, and
# `PlatformFloorTests` holds this line to the manifest and the plists.
readonly MINIMUM_MACOS=27.0
readonly CONFIG=release
# Where `swift build -c release` writes each module's diagnostics (measured 2026-10-14, Swift 6.4).
readonly RELEASE_DIAGNOSTICS=.build/out/Intermediates.noindex/XDict.build/Release
readonly APP=.build/$APP_NAME.app
# Assembled here and published by an atomic swap only when every check has passed: $APP is the previous good bundle or
# this one, never a half-built mixture that looks up to date.
readonly STAGE_ROOT=.build/stage
readonly STAGE=$STAGE_ROOT/$APP_NAME.app
readonly XPC_PATH=Contents/XPCServices/$SERVICE_ID.xpc
# What the published bundle was built from; removed before publication and written after it.
readonly BUNDLE_DIGEST=.build/$APP_NAME.app.inputs-sha256
readonly LOCK=.build/bundle.lock
readonly CATALOG=Strings/Localizable.xcstrings
# The Service's menu title (Info.plist NSServices): macOS reads its translation from ServicesMenu.strings (plan-macos-v1 WI-8).
readonly SERVICES_CATALOG=Strings/ServicesMenu.xcstrings
readonly LANGUAGES="en zh-Hans"
# What the service must answer: the core's versions, read by `Tools/build-core.sh` through the same binding and archive.
readonly CORE_VERSIONS=Generated/core-versions.json
readonly SHIPPED_VERSIONS=Contents/Resources/CoreVersions.json
# XDict's phonetic faces and their SIL OFL notices (EntryFonts), shipped byte for byte as released: never subset.
readonly FONTS=Resources/Fonts
# Every third-party notice (Tools/notices.py, held to the lockfile by `make test`), shown by XDict ▸ Acknowledgements.
readonly NOTICES=Resources/Acknowledgements.txt
readonly LOGIN_KEYCHAIN=$HOME/Library/Keychains/login.keychain-db
# `--timestamp` asks Apple's server and fails the way network calls fail (XiaolaiDict lost a release to it); a
# development build signs offline and succeeds or fails on its first try.
readonly SIGN_TRIES=5
# A symbol of the core, by the names Rust and UniFFI give it: the app must hold none, the service must hold some.
readonly CORE_SYMBOLS='uniffi_xdict_ffi|xdict_core|xdict_mdx|xdict_entry|xdict_lookup|xdict_identity'
# The development lab (plan-macos-v1 WI-4): it links the core and can switch an entry's confinement layer off, so it
# never ships. Its flag is what the app binary must not hold, and what the lab binary must, or the reading saw nothing.
readonly LAB=XDictEntryLab
readonly LAB_FLAG=--disable-layer
# The lab's gallery reads the reading style from a directory (`--style-dir`); the app compiles it in and reads none.
readonly LAB_STYLE_FLAG=--style-dir

fail() { echo "build-bundle: $*" >&2; exit 1; }
note() { echo "$*"; }
is_release() { [ -n "${XDICT_BUILD_NUMBER:-}" ]; }
plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null; }

# One build at a time, across processes: lockf holds a flock(2) lock the kernel releases when the process dies.
if [ "${XDICT_BUNDLE_LOCKED:-}" != 1 ]; then
    mkdir -p .build
    XDICT_BUNDLE_LOCKED=1 exec lockf -k -t 900 "$LOCK" "$0" "$@"
fi

# ---------------------------------------------------------------------------------------------------------------------
# The identity: a Developer ID, never ad hoc — macOS keys permission grants on the signing identity, and an ad-hoc
# signature changes with every byte. Unset, the login keychain's; two there is a choice this script will not guess.
resolve_identity() {
    local found count
    found=$(security find-identity -v -p codesigning "$LOGIN_KEYCHAIN" 2>/dev/null) \
        || fail "the login keychain could not be read for signing identities"
    if [ -n "${XDICT_SIGN_ID:-}" ]; then
        grep -qF "\"$XDICT_SIGN_ID\"" <<<"$found" || fail "signing identity not in the login keychain: $XDICT_SIGN_ID"
        return 0
    fi
    found=$(sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' <<<"$found" | sort -u)
    count=$(grep -c . <<<"$found" || true)
    [ "$count" -eq 1 ] || fail "the login keychain holds $count Developer ID Application identities; name one: SIGN_ID=…"
    XDICT_SIGN_ID=$found
}

# ---------------------------------------------------------------------------------------------------------------------
# Inputs, by content: a timestamp misses a file restored with an older date and a deleted source; a digest of every
# input's name and bytes misses none. Settings are hashed as data, never spliced into shell code.
digest_files() {
    sort -z | while IFS= read -r -d '' file; do
        printf '%s\0' "$file"
        shasum -a 256 <"$file"
    done
}

bundle_inputs_digest() {
    {
        printf '%s\0' "$CONFIG" "$BUNDLE_ID" "$XDICT_SIGN_ID" "${XDICT_BUILD_NUMBER:-}"
        find Sources Strings Resources Generated Package.swift Makefile Tools/build-bundle.sh \
            Tools/compiler-warnings.py -type f -print0 | digest_files
    } | shasum -a 256 | cut -d' ' -f1
}

# ---------------------------------------------------------------------------------------------------------------------
# Build numbers: a release's from the release counter; a development build's year.monthday.time in UTC, which rises
# with every build whatever the branch — and never at or below the published bundle's.
version_newer() {  # whether $1 is newer than $2: dot-separated integers, field by field, a missing field 0
    local newer older field count
    IFS=. read -r -a newer <<<"$1"
    IFS=. read -r -a older <<<"$2"
    count=$(( ${#newer[@]} > ${#older[@]} ? ${#newer[@]} : ${#older[@]} ))
    for (( field = 0; field < count; field++ )); do
        (( 10#${newer[field]:-0} > 10#${older[field]:-0} )) && return 0
        (( 10#${newer[field]:-0} < 10#${older[field]:-0} )) && return 1
    done
    return 1
}

build_number() {
    local previous year monthday time candidate fields
    previous=$(plist_value "$APP/Contents/Info.plist" CFBundleVersion || true)
    [[ "$previous" =~ ^[0-9]+(\.[0-9]+)*$ ]] || previous=""
    if is_release; then
        [[ "$XDICT_BUILD_NUMBER" =~ ^[1-9][0-9]{0,8}$ ]] \
            || fail "XDICT_BUILD_NUMBER must be a positive integer from the release counter, not '$XDICT_BUILD_NUMBER'"
        echo "$XDICT_BUILD_NUMBER"
        return
    fi
    read -r year monthday time <<<"$(date -u '+%Y %m%d %H%M%S')"
    candidate="$year.$((10#$monthday)).$((10#$time))"
    if [ -n "$previous" ] && ! version_newer "$candidate" "$previous"; then
        IFS=. read -r -a fields <<<"$previous"
        while [ "${#fields[@]}" -lt 3 ]; do fields+=(0); done
        candidate="${fields[0]}.${fields[1]}.$((10#${fields[2]} + 1))"
    fi
    echo "$candidate"
}

# ---------------------------------------------------------------------------------------------------------------------
# Verification: of the staged bundle before publication, and of the published one before it is called up to date.
# Each question is its own function and answers in its own words; `verify_bundle` asks them in turn.

verify_required_files() {
    local bundle=$1 executable file language
    # `-x`, not `-s`: a binary that lost its executable bit still has bytes, and launchd cannot run it.
    for executable in "Contents/MacOS/$APP_NAME" "$XPC_PATH/Contents/MacOS/$SERVICE"; do
        [ -x "$bundle/$executable" ] || { echo "not executable: $bundle/$executable"; return 1; }
    done
    for file in Contents/Info.plist "$XPC_PATH/Contents/Info.plist" "$SHIPPED_VERSIONS"; do
        [ -s "$bundle/$file" ] || { echo "missing: $bundle/$file"; return 1; }
    done
    # Exactly the eight faces and two notices, each identical to the tracked file.
    [ "$(find "$FONTS" -type f | wc -l | tr -d ' ')" = 10 ] || { echo "$FONTS is not the eight faces and two notices"; return 1; }
    for file in "$FONTS"/*; do
        cmp -s "$file" "$bundle/Contents/$file" || { echo "missing or changed: Contents/$file"; return 1; }
    done
    cmp -s "$NOTICES" "$bundle/Contents/$NOTICES" || { echo "missing or changed: Contents/$NOTICES"; return 1; }
    # A translation that never reached the bundle is a reader still reading English.
    for language in $LANGUAGES; do
        for table in Localizable ServicesMenu; do
            [ -s "$bundle/Contents/Resources/$language.lproj/$table.strings" ] \
                || { echo "missing: $language.lproj/$table.strings"; return 1; }
        done
    done
}

verify_bundle_metadata() {
    local bundle=$1 app_plist=$1/Contents/Info.plist service_plist=$1/$XPC_PATH/Contents/Info.plist key
    [ "$(plist_value "$app_plist" CFBundleIdentifier)" = "$BUNDLE_ID" ] \
        || { echo "the app's CFBundleIdentifier is not $BUNDLE_ID"; return 1; }
    [ "$(plist_value "$service_plist" CFBundleIdentifier)" = "$SERVICE_ID" ] \
        || { echo "the service's CFBundleIdentifier is not $SERVICE_ID"; return 1; }
    [ "$(plist_value "$app_plist" CFBundleExecutable)" = "$APP_NAME" ] \
        || { echo "the app's CFBundleExecutable is not $APP_NAME"; return 1; }
    # The Service (plan-macos-v1 WI-8): its message is the provider's method, and NSRequiredContext is what lets macOS
    # offer it in a selection's context menu without the reader enabling it.
    [ "$(plist_value "$app_plist" NSServices:0:NSMessage)" = lookUpInXDict ] \
        || { echo "the app declares no NSServices entry for lookUpInXDict"; return 1; }
    /usr/libexec/PlistBuddy -c 'Print :NSServices:0:NSRequiredContext' "$app_plist" >/dev/null 2>&1 \
        || { echo "the Service declares no NSRequiredContext"; return 1; }
    # **The keys a service needs to launch at all**: a wrong executable name or a missing XPCService dictionary builds,
    # signs and ships, and then launchd refuses the service with nothing to say why.
    [ "$(plist_value "$service_plist" CFBundleExecutable)" = "$SERVICE" ] \
        || { echo "the service's CFBundleExecutable is not $SERVICE"; return 1; }
    [ "$(plist_value "$service_plist" CFBundlePackageType)" = 'XPC!' ] \
        || { echo "the service is not declared as an XPC service (CFBundlePackageType)"; return 1; }
    [ "$(plist_value "$service_plist" XPCService:ServiceType)" = Application ] \
        || { echo "the service does not declare XPCService:ServiceType Application"; return 1; }
    for key in CFBundleShortVersionString CFBundleVersion; do
        [ -n "$(plist_value "$app_plist" "$key")" ] \
            && [ "$(plist_value "$app_plist" "$key")" = "$(plist_value "$service_plist" "$key")" ] \
            || { echo "the app and the service declare different $key"; return 1; }
    done
    for key in "$app_plist" "$service_plist"; do
        [ "$(plist_value "$key" LSMinimumSystemVersion)" = "$MINIMUM_MACOS" ] \
            || { echo "$key declares LSMinimumSystemVersion $(plist_value "$key" LSMinimumSystemVersion), not $MINIMUM_MACOS"; return 1; }
    done
}

# **Every binary is built for the floor, and for Apple silicon alone** — `LC_BUILD_VERSION`'s minos, which the plists
# cannot vouch for: a package whose platform moved would still ship under the old plists' number.
verify_binaries() {
    local bundle=$1 binary build minos archs
    for binary in "$bundle/Contents/MacOS/$APP_NAME" "$bundle/$XPC_PATH/Contents/MacOS/$SERVICE"; do
        build=$(vtool -show-build "$binary" 2>&1) || { echo "vtool could not read $binary: $build"; return 1; }
        grep -q '^ *platform MACOS$' <<<"$build" || { echo "$binary is not built for macOS"; return 1; }
        minos=$(awk '$1 == "minos" { print $2 }' <<<"$build")
        [ "$minos" = "$MINIMUM_MACOS" ] || { echo "$binary is built for macOS ${minos:-unknown}, not $MINIMUM_MACOS"; return 1; }
        archs=$(lipo -archs "$binary" 2>&1) || { echo "lipo could not read $binary"; return 1; }
        [ "$archs" = arm64 ] || { echo "$binary is built for '$archs', not arm64 alone"; return 1; }
    done
}

# **What ships is the app and its service, and nothing of the development lab.** The bundle's Mach-O files are exactly
# the two executables (found by their magic, not their names), nothing in it is named after the lab, and the app
# binary does not hold the lab's flag. Before the signatures: a lab copied in before signing would verify.
verify_no_development_lab() {
    local bundle=$1 file magic found="" expected
    while IFS= read -r -d '' file; do
        magic=$(head -c 4 "$file" | xxd -p)
        case $magic in
            cffaedfe | cefaedfe | feedfacf | feedface | cafebabe | bebafeca) found+="${file#"$bundle"/}"$'\n' ;;
        esac
    done < <(find "$bundle" -type f -print0)
    expected=$(printf '%s\n' "Contents/MacOS/$APP_NAME" "$XPC_PATH/Contents/MacOS/$SERVICE" | sort)
    [ "$(sort <<<"${found%$'\n'}")" = "$expected" ] \
        || { echo "the bundle's executables are not exactly the app and its service: $(tr '\n' ' ' <<<"$found")"; return 1; }
    [ -z "$(find "$bundle" -iname "*$LAB*" -print -quit)" ] || { echo "the bundle carries something named $LAB"; return 1; }
    ! LC_ALL=C grep -aqF -- "$LAB_FLAG" "$bundle/Contents/MacOS/$APP_NAME" \
        || { echo "the app binary holds $LAB_FLAG, the development lab's flag"; return 1; }
    ! LC_ALL=C grep -aqF -- "$LAB_STYLE_FLAG" "$bundle/Contents/MacOS/$APP_NAME" \
        || { echo "the app binary holds $LAB_STYLE_FLAG: only the lab may read a style from a directory"; return 1; }
}

# Each binary's signed entitlements, compared whole with its file as JSON (plutil sorts keys and compacts): one more
# key, a `false`, or `get-task-allow` (which the notary refuses) is a different string.
entitlements_json() {  # $1: a signed code object
    local xml
    xml=$(codesign -d --entitlements - --xml "$1" 2>/dev/null || true)
    if [ -z "$xml" ]; then echo '{}'; else plutil -convert json -o - - <<<"$xml"; fi
}

verify_signatures() {
    local bundle=$1 part described team authority expected_team="" entitlements wanted pair file
    codesign --verify --strict --deep "$bundle" || { echo "the signature does not verify"; return 1; }
    # **Equal team identifiers are not enough**: an ad-hoc signature reports `TeamIdentifier=not set`, and another
    # team's verifies too. Each part carries the configured identity, the hardened runtime, and its own entitlements.
    for pair in "$bundle/$XPC_PATH|Resources/DictionaryService.entitlements" "$bundle|Resources/XDict.entitlements"; do
        part=${pair%%|*}; file=${pair#*|}
        described=$(codesign -dvvv "$part" 2>&1 || true)
        team=$(grep '^TeamIdentifier=' <<<"$described" | head -1)
        authority=$(grep '^Authority=' <<<"$described" | head -1)
        case $team in
            TeamIdentifier= | "TeamIdentifier=not set" | "")
                echo "$part carries no team identifier: an ad-hoc signature keeps no permission grant"; return 1 ;;
        esac
        [ -z "$expected_team" ] || [ "$team" = "$expected_team" ] || { echo "$part is signed by $team, not $expected_team"; return 1; }
        expected_team=$team
        [ "$authority" = "Authority=$XDICT_SIGN_ID" ] || { echo "$part is signed by '$authority', not '$XDICT_SIGN_ID'"; return 1; }
        grep -q '^CodeDirectory .*flags=0x10000(runtime)' <<<"$described" \
            || { echo "$part is not signed with the hardened runtime"; return 1; }
        # `Timestamp=` is Apple's server; `Signed Time=` is the local clock and does not count.
        if is_release; then
            grep -q '^Timestamp=' <<<"$described" || { echo "a release is signed without a secure timestamp: $part"; return 1; }
        fi
        entitlements=$(entitlements_json "$part")
        wanted=$(plutil -convert json -o - "$file")
        [ "$entitlements" = "$wanted" ] || { echo "$part is signed with entitlements $entitlements, not $file's $wanted"; return 1; }
    done
}

# **The core is in the service and nowhere else** (AGENTS.md; `ModuleBoundaryTests` holds the sources). Read off the
# binaries, because that is what ships: the app links nothing of the core and holds no core symbol; the service holds
# the core statically and links no dylib of it; and the service binds no UI framework. **A reading that read nothing
# passes**, so each must be seen to answer first: `otool -L` exits 0 on a file that is not an object, so the list must
# name libSystem; `nm` on an unreadable file is silent, so it must list symbols.
verify_service_boundaries() {
    local bundle=$1 app_binary=$1/Contents/MacOS/$APP_NAME service_binary=$1/$XPC_PATH/Contents/MacOS/$SERVICE
    local binary links symbols count
    for binary in "$app_binary" "$service_binary"; do
        links=$(otool -L "$binary" 2>&1) || { echo "otool -L could not read $binary"; return 1; }
        grep -q '/usr/lib/libSystem.B.dylib' <<<"$links" || { echo "otool -L listed no libSystem for $binary: it read nothing"; return 1; }
        ! grep -qi 'xdict' <<<"$(tail -n +2 <<<"$links")" || { echo "$binary links the core dynamically: $(grep -i xdict <<<"$links")"; return 1; }
        symbols=$(nm "$binary" 2>/dev/null) || { echo "nm could not read $binary"; return 1; }
        [ "$(grep -c '' <<<"$symbols")" -ge 100 ] || { echo "nm listed almost nothing of $binary: it read nothing"; return 1; }
    done
    count=$(nm "$app_binary" | grep -cE "$CORE_SYMBOLS" || true)
    [ "$count" -eq 0 ] || { echo "the app carries $count symbols of the core; the core belongs to the service alone"; return 1; }
    count=$(nm "$service_binary" | grep -cE 'uniffi_xdict_ffi_fn_func_versions' || true)
    [ "$count" -ge 1 ] || { echo "the service holds no core: uniffi_xdict_ffi_fn_func_versions is not in it"; return 1; }
    ! grep -qE '/(AppKit|SwiftUI|WebKit)\.framework/' <<<"$(otool -L "$service_binary")" \
        || { echo "the service binds a UI framework"; return 1; }
}

verify_bundle() {
    local bundle=$1
    verify_required_files "$bundle" || return 1
    verify_bundle_metadata "$bundle" || return 1
    verify_binaries "$bundle" || return 1
    verify_no_development_lab "$bundle" || return 1
    verify_signatures "$bundle" || return 1
    verify_service_boundaries "$bundle" || return 1
}

# ---------------------------------------------------------------------------------------------------------------------
# Assembly, in the stage.

sign_part() {  # $1: entitlements file; $2: the code object
    local entitlements=$1 part=$2 stamp=--timestamp=none attempt
    ! is_release || stamp=--timestamp
    for (( attempt = 1; attempt <= SIGN_TRIES; attempt++ )); do
        if (( attempt == SIGN_TRIES )) || ! is_release; then
            codesign --force --options runtime "$stamp" --entitlements "$entitlements" --sign "$XDICT_SIGN_ID" "$part" >/dev/null
            return
        fi
        codesign --force --options runtime "$stamp" --entitlements "$entitlements" --sign "$XDICT_SIGN_ID" "$part" \
            >/dev/null 2>&1 && return
        note "signing $(basename "$part") failed on attempt $attempt of $SIGN_TRIES; retrying"
        sleep $(( attempt * 2 ))
    done
}

# The products Tools/remote-build.sh brought back, printed, only if they were built of the tree here now.
remote_products() {  # $1: the folder
    local tree
    tree=$(Tools/source-tree.sh) || fail "could not read the source tree"
    [ -s "$1/source-tree" ] || fail "$1 holds no finished remote build: run Tools/remote-build.sh (make does)"
    [ "$(cat "$1/source-tree")" = "$tree" ] || fail "$1 was built of another source tree: build again"
    printf '%s\n' "$1"
}

assemble() {
    [ -s "$CORE_VERSIONS" ] && [ -d Generated/xdictFFI.xcframework ] \
        || fail "Generated/ is missing or incomplete: run Tools/build-core.sh (make does)"
    [ -s "$CATALOG" ] || fail "missing string catalog: $CATALOG"
    local products
    if [ -n "${XDICT_REMOTE_PRODUCTS:-}" ]; then
        # Built on BUILD_HOST by Tools/remote-build.sh, which ran this same warnings gate there; held to this very tree.
        products=$(remote_products "$XDICT_REMOTE_PRODUCTS")
    else
        swift build -c "$CONFIG"
        # **A warning the compiler wrote down fails the bundle, as it fails `make`'s tests**: this reads the build the
        # bundle is made of, which compiles each module whole and no test target.
        python3 Tools/compiler-warnings.py "$RELEASE_DIAGNOSTICS" --whole-module --no-test-targets \
            || fail "the bundle's build has a warning the compiler did not fail it on, or its diagnostics could not be read"
        products=$(swift build -c "$CONFIG" --show-bin-path)
    fi
    [ -x "$products/$APP_NAME" ] && [ -x "$products/$SERVICE" ] || fail "swift build produced no $APP_NAME or $SERVICE"
    # The control for `verify_no_development_lab`'s flag search: the lab this build made must hold the flag.
    LC_ALL=C grep -aqF -- "$LAB_FLAG" "$products/$LAB" \
        || fail "$products/$LAB does not hold $LAB_FLAG, so a search of the app binary for it would see nothing"
    LC_ALL=C grep -aqF -- "$LAB_STYLE_FLAG" "$products/$LAB" \
        || fail "$products/$LAB does not hold $LAB_STYLE_FLAG, so a search of the app binary for it would see nothing"

    local contents=$STAGE/Contents xpc=$STAGE/$XPC_PATH number plist
    rm -rf "$STAGE_ROOT"
    mkdir -p "$contents/MacOS" "$contents/Resources" "$xpc/Contents/MacOS"
    cp "$products/$APP_NAME" "$contents/MacOS/$APP_NAME"
    cp "$products/$SERVICE" "$xpc/Contents/MacOS/$SERVICE"
    cp Resources/Info.plist "$contents/Info.plist"
    cp Resources/DictionaryService-Info.plist "$xpc/Contents/Info.plist"
    cp "$CORE_VERSIONS" "$STAGE/$SHIPPED_VERSIONS"
    cp -R "$FONTS" "$contents/Resources/"
    cp "$NOTICES" "$contents/Resources/"

    # The build number is stamped into the copies, never the tracked files, and read back: PlistBuddy reports success
    # for keys it did not write.
    number=$(build_number)
    for plist in "$contents/Info.plist" "$xpc/Contents/Info.plist"; do
        /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $number" "$plist"
        [ "$(plist_value "$plist" CFBundleVersion)" = "$number" ] || fail "CFBundleVersion did not take in $plist"
    done

    # Translations reach the bundle as compiled tables, one directory per language, read through `Bundle.main`.
    xcrun xcstringstool compile "$CATALOG" --output-directory "$contents/Resources" \
        || fail "the string catalog did not compile"
    xcrun xcstringstool compile "$SERVICES_CATALOG" --output-directory "$contents/Resources" \
        || fail "the Services menu's catalog did not compile"

    # Inside out: the service, then the app that seals it.
    sign_part Resources/DictionaryService.entitlements "$xpc"
    sign_part Resources/XDict.entitlements "$STAGE"

    local problem
    problem=$(verify_bundle "$STAGE") || fail "the staged bundle failed verification: $problem"
    note "assembled $STAGE (build $number)"
}

# ---------------------------------------------------------------------------------------------------------------------
# Running copies, found by the exact path of this bundle's executables (never by name, which would match any other
# process called the same). A `ps` that fails stops the build: "could not look" is not "nothing is running".
find_pids() {  # sets PIDS; not a $(…) function, so that `fail` stops the build and not a subshell
    local table pid executable
    table=$(ps -axww -o pid=,comm=) || fail "ps failed, so whether $1 is running cannot be told"
    PIDS=()
    while read -r pid executable; do
        [ "$executable" != "$PWD/$1" ] || PIDS+=("$pid")
    done <<<"$table"
}

stop() {  # $1: an executable path under the bundle; TERM, wait, KILL, insist
    local executable=$1
    find_pids "$executable"
    [ "${#PIDS[@]}" -gt 0 ] || return 0
    note "quitting the running $(basename "$executable")"
    kill -TERM "${PIDS[@]}" 2>/dev/null || true
    for _ in $(seq 1 50); do find_pids "$executable"; [ "${#PIDS[@]}" -gt 0 ] || return 0; sleep 0.1; done
    kill -KILL "${PIDS[@]}" 2>/dev/null || true
    for _ in $(seq 1 20); do find_pids "$executable"; [ "${#PIDS[@]}" -gt 0 ] || return 0; sleep 0.1; done
    fail "$executable is still running; quit it by hand"
}

quit_running() {
    stop "$APP/Contents/MacOS/$APP_NAME"
    # launchd ends an app's XPC service with the app, but not at once; one that outlived it would serve the next app.
    stop "$APP/$XPC_PATH/Contents/MacOS/$SERVICE"
}

# Publication: one atomic exchange of the staged bundle with the published one (renamex_np, RENAME_SWAP), so $APP is
# never missing and never half-replaced.
swap_into_place() {
    python3 - "$STAGE" "$APP" <<'PY'
import ctypes, os, sys
libc = ctypes.CDLL(None, use_errno=True)
if libc.renamex_np(os.fsencode(sys.argv[1]), os.fsencode(sys.argv[2]), 0x2) != 0:
    sys.exit("renamex_np: " + os.strerror(ctypes.get_errno()))
PY
}

publish() {
    local digest=$1
    quit_running
    rm -f "$BUNDLE_DIGEST" "$APP.source-tree"   # the tree `make e2e` built it from (Makefile): no longer this bundle
    if [ -e "$APP" ]; then
        swap_into_place || fail "could not swap the new bundle into place; $APP is unchanged"
        rm -rf "$STAGE"
    else
        mv "$STAGE" "$APP"
    fi
    printf '%s\n' "$digest" >"$BUNDLE_DIGEST"
    note "published $APP ($(du -sh "$APP" | cut -f1), build $(plist_value "$APP/Contents/Info.plist" CFBundleVersion))"
}

build() {
    resolve_identity
    local digest problem
    digest=$(bundle_inputs_digest)
    if [ -d "$APP" ] && [ "$(cat "$BUNDLE_DIGEST" 2>/dev/null)" = "$digest" ]; then
        if problem=$(verify_bundle "$APP" 2>&1); then
            note "$APP is up to date (build $(plist_value "$APP/Contents/Info.plist" CFBundleVersion))"
            return 0
        fi
        note "$APP matches its inputs but fails verification ($problem); rebuilding"
    fi
    assemble
    publish "$digest"
}

case "${1:-}" in
    build) build ;;
    # The identity a build would sign with, for `Tools/release.sh`, which signs the disk image with the same one.
    identity) resolve_identity; printf '%s\n' "$XDICT_SIGN_ID" ;;
    verify)
        [ -n "${2:-}" ] || fail "usage: $0 verify <bundle>"
        resolve_identity
        problem=$(verify_bundle "$2") || fail "$2 failed verification: $problem"
        note "$2 verifies"
        ;;
    clean)
        quit_running
        rm -rf "$STAGE_ROOT" "$APP" "$BUNDLE_DIGEST" "$APP.source-tree"
        ;;
    *) fail "usage: $0 build|verify <bundle>|identity|clean" ;;
esac
