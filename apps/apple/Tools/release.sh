#!/bin/bash
# Notarises a release of XDict and packages it as a disk image. Publishes nothing anywhere: the DMG is left in
# .build/release. Adapted from XiaolaiDict's `Tools/release.sh` (its ADR-0026: a signed build is not a shippable one).
#
#   make release BUILD_NUMBER=<n>            the ordinary release
#   make release-bootstrap BUILD_NUMBER=<n>  the skeleton's (plan-macos-v1 WI-2)
#
# **No upload without end-to-end evidence of this very content** (XiaolaiDict ADR-0024, addendum of 2026-10-11; by key
# since 2026-10-17): the ordinary release needs, for **every default sub-stage** and RELEASE_EXTRAS, a pass in the E2E
# ledger under the key that sub-stage has for this tree, the build host's toolchain, the E2E Mac's macOS build and the
# corpus, not failed since and within E2E_EVIDENCE_MAX_DAYS (`Tools/e2e-status.sh require-fresh`), and the tree
# committed, so what ships names a commit. **The bootstrap release needs that of the `launch` stage alone**: the
# skeleton has no other stage that means anything yet. It may be cut from a tree not yet committed; it names that tree
# (`Tools/source-tree.sh`), whose objects are in the repository's store. **Whatever the ledger carries, RELEASE_SMOKE
# runs on the stapled release bundle** (step 2a): no key sees a signature, an entitlement or a ticket.
#
#   1. build, signed with a secure timestamp        (the notary refuses a signature without one)
#   2. notarise the app, staple its ticket          (so a first launch works offline)
#  2a. the release smoke on the E2E Mac            (`Tools/e2e-status.sh smoke`, on this very stapled bundle)
#   3. build the disk image from the stapled app
#   4. sign the disk image                          (a ticket alone is not enough for a .dmg)
#   5. notarise the disk image, staple its ticket
#  5a. ask for the evidence once more                (a failure filed during notarisation revokes)
#   6. ask Gatekeeper, here and on the E2E Mac, and fail unless it says "Notarized Developer ID"
#
# The order is load-bearing: each step consumes the one before it, and an image built before its app was stapled
# ships the unstapled app.
#
# Environment (the Makefile sets each):
#   XDICT_BUILD_NUMBER    the release counter's value: required, and what makes this a release
#   XDICT_NOTARY_PROFILE  a notarytool keychain profile (`chase-notary`): a name, never a credential
#   XDICT_E2E_HOST        the E2E Mac's SSH name, where Gatekeeper is asked last
#   XDICT_SIGN_ID         optional; `Tools/build-bundle.sh identity` otherwise
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "release: $*" >&2; exit 1; }
note() { echo "$*"; }

mode=full
case "${1:-}" in
    "") ;;
    --bootstrap) mode=bootstrap ;;
    *) fail "usage: $0 [--bootstrap]" ;;
esac
readonly mode
evidence() { if [ "$mode" = bootstrap ]; then Tools/e2e-status.sh require-fresh --bootstrap; else Tools/e2e-status.sh require-fresh; fi; }

readonly BUILT=.build/XDict.app
readonly OUT=.build/release
# Released from a copy, so stapling never touches the bundle development builds are published to.
readonly APP=$OUT/XDict.app
# Apple's notary service drops connections and notarytool has no retry of its own: five, as XiaolaiDict measured.
readonly TRIES=5
readonly REMOTE_DIR=XDictE2E/release

[ -n "${XDICT_BUILD_NUMBER:-}" ] || fail "a release needs a number from the release counter: BUILD_NUMBER=<n>"
[ -n "${XDICT_NOTARY_PROFILE:-}" ] || fail "XDICT_NOTARY_PROFILE is not set"
[ -n "${XDICT_E2E_HOST:-}" ] || fail "XDICT_E2E_HOST is not set: Gatekeeper is asked on the E2E Mac last (E2E_HOST_MACOS in local.mk)"
XDICT_SIGN_ID=$(Tools/build-bundle.sh identity) || fail "no signing identity"
export XDICT_SIGN_ID

# Before anything is built or uploaded: the profile exists and Apple accepts it (the cheapest authenticated call).
xcrun notarytool history --keychain-profile "$XDICT_NOTARY_PROFILE" >/dev/null 2>&1 \
    || fail "notarytool cannot use the keychain profile '$XDICT_NOTARY_PROFILE' (made once per Mac with xcrun notarytool store-credentials)"
if [ "$mode" = full ]; then
    Tools/source-tree.sh --clean >/dev/null || fail "an ordinary release is cut from a committed tree: commit, run make e2e, then release"
fi
evidence || fail "no fresh end-to-end evidence of this source tree for the $mode release"

# Uploads, then waits — as two calls, because they fail differently: a single `submit --wait` that times out while
# polling reports failure for an upload that went through, and running it again uploads twice. A verdict ends the wait
# whatever notarytool exits with; only a dropped connection is worth asking again.
notarize() {  # $1: the file to submit, a .zip of the app or the .dmg
    local file=$1 attempt out id="" status=""
    for (( attempt = 1; attempt <= TRIES; attempt++ )); do
        if out=$(xcrun notarytool submit "$file" --keychain-profile "$XDICT_NOTARY_PROFILE" --output-format plist) \
           && id=$(plutil -extract id raw -o - - <<<"$out" 2>/dev/null); then
            break
        fi
        id=""
        (( attempt < TRIES )) || break
        note "upload attempt $attempt of $TRIES returned no submission id; retrying"
        sleep $(( attempt * 10 ))
    done
    [ -n "$id" ] || fail "could not upload $file for notarisation after $TRIES attempts"
    note "submitted $(basename "$file") as $id; waiting for Apple"
    for (( attempt = 1; attempt <= TRIES; attempt++ )); do
        out=$(xcrun notarytool wait "$id" --keychain-profile "$XDICT_NOTARY_PROFILE" --output-format plist) || true
        status=$(plutil -extract status raw -o - - <<<"$out" 2>/dev/null) || status=""
        case $status in Accepted | Invalid | Rejected) break ;; esac
        (( attempt < TRIES )) || break
        note "no verdict for $id yet (attempt $attempt of $TRIES); asking again — the upload stands"
        sleep $(( attempt * 15 ))
    done
    if [ "$status" != Accepted ]; then
        # Apple's log names each rejected file and why; without it a rejection is a guess.
        xcrun notarytool log "$id" --keychain-profile "$XDICT_NOTARY_PROFILE" >&2 || true
        fail "notarisation of $(basename "$file") ended as '${status:-no verdict}' (submission $id)"
    fi
    note "notarised $(basename "$file") ($id)"
}

# Stapling fetches the ticket from Apple and drops as an upload does; a ticket not yet propagated reads the same.
staple() {
    local attempt
    for (( attempt = 1; attempt <= TRIES; attempt++ )); do
        xcrun stapler staple "$1" >/dev/null 2>&1 && break
        (( attempt < TRIES )) || fail "could not staple a ticket to $1 after $TRIES attempts"
        note "stapling $(basename "$1") failed (attempt $attempt of $TRIES); retrying"
        sleep 10
    done
    xcrun stapler validate "$1" >/dev/null || fail "$1 has no valid ticket after stapling"
}

# A secure timestamp is a network call too (XiaolaiDict lost a release to it on the disk image, after the app had been
# notarised). The last attempt keeps its words, so a bad identity fails loudly at once.
sign_with_timestamp() {
    local artifact=$1 attempt
    for (( attempt = 1; attempt <= TRIES; attempt++ )); do
        if (( attempt == TRIES )); then
            codesign --force --timestamp --sign "$XDICT_SIGN_ID" "$artifact" || fail "could not sign $artifact"
            return
        fi
        codesign --force --timestamp --sign "$XDICT_SIGN_ID" "$artifact" >/dev/null 2>&1 && return
        note "signing $(basename "$artifact") failed on attempt $attempt of $TRIES; retrying"
        sleep $(( attempt * 2 ))
    done
}

# The only verdict that counts: what Gatekeeper tells a reader who downloaded this. Captured rather than piped, so the
# status is spctl's, and never `|| true`.
gatekeeper() {  # $1: artifact; the rest: spctl's assessment options
    local artifact=$1 verdict
    shift
    verdict=$(spctl -a -vv "$@" "$artifact" 2>&1) || fail "Gatekeeper rejected $artifact: $verdict"
    grep -q 'source=Notarized Developer ID' <<<"$verdict" || fail "Gatekeeper accepted $artifact, but not as notarised: $verdict"
    note "Gatekeeper here: $(basename "$artifact") accepted, source=Notarized Developer ID"
}

# 1. Build. A release number makes build-bundle.sh sign with a secure timestamp and refuse any bundle without one.
Tools/build-bundle.sh build
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$BUILT/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$BUILT/Contents/Info.plist")
[ "$build" = "$XDICT_BUILD_NUMBER" ] || fail "the built bundle is numbered $build, not $XDICT_BUILD_NUMBER"
# `get-task-allow` lets a debugger attach and the notary refuses it; asked before the upload, so the refusal takes a
# second rather than minutes. (`verify_bundle` already holds each binary to its entitlements file exactly.)
for part in "$BUILT" "$BUILT/Contents/XPCServices/ai.xdict.app.DictionaryService.xpc"; do
    entitlements=$(codesign -d --entitlements - --xml "$part" 2>/dev/null || true)
    ! grep -q "get-task-allow" <<<"$entitlements" || fail "get-task-allow is set on $part; the notary would refuse it"
done
# **Asked again after the build and before any upload**, because the tree is read again now: an edit made during the
# build would otherwise be released without the evidence.
tree=$(Tools/source-tree.sh)
evidence || fail "the source tree moved during the build; no evidence covers what was built"

rm -rf "$OUT"
mkdir -p "$OUT"
ditto "$BUILT" "$APP"

# 2. The app, as the archive notarytool takes (`ditto -c -k --keepParent`, the form Apple documents).
ditto -c -k --keepParent "$APP" "$OUT/XDict.zip"
notarize "$OUT/XDict.zip"
rm -f "$OUT/XDict.zip"
staple "$APP"
codesign --verify --strict --deep "$APP" || fail "stapling broke the app's signature"

# 2a. The release smoke: the stapled, release-signed bundle on the E2E Mac, whatever the ledger carries. Tools/e2e.sh
# ships .build/XDict.app, so the stapled copy takes its place (the same bundle plus its ticket); its rows are filed as
# `release` mode, keyed by the bundle's own provenance.
rm -rf "$BUILT"
ditto "$APP" "$BUILT"
# **The smoke is the release's own gate, so it is permitted here** (2026-10-23: an agent's `make release` notarised the
# app and then stopped, because `Tools/e2e.sh` refuses an agent's run without `E2E_REQUESTED=1` — and the release's
# required smoke is not an agent's spare run: `make release` is the owner's request by construction, and this line is
# the only place the permission is given).
# shellcheck disable=SC2046 # the smoke's names, split on purpose
E2E_REQUESTED=1 XDICT_E2E_TREE="$tree" Tools/e2e.sh "$XDICT_E2E_HOST" $(Tools/e2e-status.sh smoke) \
    || fail "the release smoke ($(Tools/e2e-status.sh smoke)) failed on the release-signed bundle"

# 3. The disk image, from the stapled app, with the usual Applications link to drag it onto.
dmg=$OUT/XDict-$version-$build.dmg
staging=$(mktemp -d)
mount=""
cleanup() {
    if [ -n "$mount" ]; then hdiutil detach -quiet "$mount" 2>/dev/null || true; rmdir "$mount" 2>/dev/null || true; fi
    rm -rf "$staging"
}
trap cleanup EXIT
ditto "$APP" "$staging/XDict.app"
ln -s /Applications "$staging/Applications"
hdiutil create -quiet -volname "XDict $version" -srcfolder "$staging" -ov -format UDZO "$dmg" || fail "hdiutil could not build $dmg"

# 4–5. Signed, then notarised and stapled in its own right: a .dmg is assessed on its own signature first.
sign_with_timestamp "$dmg"
notarize "$dmg"
staple "$dmg"
# **Asked once more, after the notarisations and before the image is accepted**: a run filed meanwhile may have revoked
# a carried pass (a failure under the same key), and that must stop the release here.
[ "$(Tools/source-tree.sh)" = "$tree" ] || fail "the source tree moved during the release"
evidence || fail "the evidence changed during notarisation; nothing is released"

# 6. As a reader meets them: the disk image, and the app inside it — not the copy the image was built from.
gatekeeper "$dmg" -t open --context context:primary-signature
mount=$(mktemp -d)
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mount" "$dmg" || fail "could not mount $dmg to check it"
codesign --verify --strict --deep "$mount/XDict.app" || fail "the app inside $(basename "$dmg") does not verify"
xcrun stapler validate "$mount/XDict.app" >/dev/null || fail "the app inside $(basename "$dmg") carries no ticket"
gatekeeper "$mount/XDict.app" -t exec
hdiutil detach -quiet "$mount" || fail "could not detach $mount"
rmdir "$mount" 2>/dev/null || true
mount=""

# And on the E2E Mac, which never built it: the image copied there, mounted read-only, both assessed.
ssh_e2e() { ssh -o BatchMode=yes -o ConnectTimeout=15 "$XDICT_E2E_HOST" "$@"; }
ssh_e2e "mkdir -p '$REMOTE_DIR'" || fail "cannot reach the E2E Mac"
rsync -a "$dmg" "$XDICT_E2E_HOST:$REMOTE_DIR/" || fail "could not copy $(basename "$dmg") to the E2E Mac"
ssh_e2e bash -s -- "$REMOTE_DIR/$(basename "$dmg")" <<'SH' || fail "Gatekeeper on the E2E Mac did not accept the release"
set -euo pipefail
dmg="$HOME/$1"
mount=$(mktemp -d)
trap 'hdiutil detach -quiet "$mount" 2>/dev/null || true; rmdir "$mount" 2>/dev/null || true' EXIT
assess() {  # assess <label> <spctl options…> <path>
    local label=$1 verdict
    shift
    verdict=$(spctl -a -vv "$@" 2>&1) || { echo "E2E Mac: Gatekeeper rejected $label: $verdict" >&2; return 1; }
    grep -q 'source=Notarized Developer ID' <<<"$verdict" || { echo "E2E Mac: $label accepted, not as notarised: $verdict" >&2; return 1; }
    echo "Gatekeeper on the E2E Mac ($(sw_vers -productVersion)): $label — $(tr '\n' ' ' <<<"$verdict")"
}
assess "the disk image" -t open --context context:primary-signature "$dmg"
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mount" "$dmg"
codesign --verify --strict --deep "$mount/XDict.app"
assess "the app inside it" "$mount/XDict.app"
SH

note ""
note "released XDict $version ($build), $mode release, source tree $tree — not published"
note "  $dmg"
note "  size   $(du -h "$dmg" | cut -f1)"
note "  sha256 $(shasum -a 256 "$dmg" | cut -d' ' -f1)"
