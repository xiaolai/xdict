#!/bin/bash
# Tools/expand-entitlements.sh: the team prefix of the app group is taken from the signing identity at signing time,
# never from a tracked file; anything it cannot expand exactly fails, never signs with a placeholder left in.
set -uo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

for file in Resources/XDict.entitlements Resources/DictionaryService.entitlements; do
    if Tools/expand-entitlements.sh "Developer ID Application: Some Name (ABCDE12345)" "$file" "$work/out.plist"; then
        # `plutil -extract` splits a key path at its dots; PlistBuddy does not.
        groups=$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.application-groups" "$work/out.plist" | tr -d ' \n')
        [ "$groups" = 'Array{ABCDE12345.ai.xdict.app}' ] && ok "$file: the group takes the identity's team" \
            || bad "$file: groups $groups"
        grep -q 'TeamIdentifierPrefix' "$work/out.plist" && bad "$file: a placeholder survived" || ok "$file: none left"
        rm -f "$work/out.plist"
    else
        bad "$file: did not expand"
    fi
done

# An identity naming no team, or a malformed one, is refused, and nothing is written.
for identity in "Developer ID Application: Some Name" "Developer ID Application: X (abcde12345)" "X (ABCDE1234)" ""; do
    if Tools/expand-entitlements.sh "$identity" Resources/XDict.entitlements "$work/out.plist" 2>/dev/null; then
        bad "identity '$identity' was accepted"
    else
        [ -e "$work/out.plist" ] && bad "identity '$identity' left a file" || ok "identity '$identity' refused"
    fi
done

# A placeholder other than the team prefix cannot be expanded here, so it is refused.
printf '<plist version="1.0"><dict><key>k</key><string>$(PRODUCT_NAME)</string></dict></plist>\n' >"$work/other.plist"
Tools/expand-entitlements.sh "X (ABCDE12345)" "$work/other.plist" "$work/out.plist" 2>/dev/null \
    && bad "another placeholder was accepted" || ok "another placeholder refused"
exit $fail
