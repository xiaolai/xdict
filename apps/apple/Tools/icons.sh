#!/bin/bash
# Every platform's icon set, generated from one source: Resources/XDict.icon and Resources/MenuBarIcon.svg
# (Tools/icons/README.md).
#
#   icons.sh generate   write the sets into apps/{android,windows,linux,web,extension}/icons/, each replaced whole,
#                       after they pass `verify`
#   icons.sh check      fail if a committed set is missing, stale, holds a file the generator does not write, or
#                       fails `verify`'s measurements: the generator is run into a scratch folder and compared byte for
#                       byte (part of `make test-tools`, Tools/tests/icons-test.sh)
#   icons.sh remote <host>
#                       `generate` on <host>, and the sets brought back here (`make icons` with BUILD_HOST set)
#
# A build Mac's job (AGENTS.md: the Air never builds): it compiles a Swift script and rasterises through CoreSVG.
#
# Environment, for the test: XDICT_ICONS_APPS, the `apps/` folder to compare or write (default: this checkout's).
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { echo "icons: $*" >&2; exit 1; }

readonly PLATFORMS="android windows linux web extension"
readonly APPS=${XDICT_ICONS_APPS:-$(cd .. && pwd)}
readonly SCRIPT=Tools/icons/make-icons.swift

if [ "${1:-}" = remote ]; then
    # `make icons` with BUILD_HOST: the source and this tool to the host, `generate` there, the five sets back whole.
    host=${2:-}
    [ -n "$host" ] || fail "usage: $0 remote <host>"
    remote=xdict-build/icons-$(basename "$(cd ../.. && pwd)")
    ssh "$host" "rm -rf $remote && mkdir -p $remote/apps/apple" || fail "could not prepare $host:$remote"
    rsync -a Resources Tools "$host:$remote/apps/apple/" || fail "could not copy the source to $host"
    ssh "$host" "cd $remote/apps/apple && Tools/icons.sh generate" || fail "the generator failed on $host"
    for platform in $PLATFORMS; do
        rsync -a --delete "$host:$remote/apps/$platform/icons/" "$APPS/$platform/icons/" \
            || fail "could not bring $platform/icons back from $host"
    done
    echo "icons: generated on $host into $APPS/{${PLATFORMS// /,}}/icons"
    exit 0
fi

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
# The script is compiled, not interpreted: `swift <file>` would JIT it on every call, twice per run.
swiftc -O -o "$scratch/make-icons" "$SCRIPT" || fail "make-icons.swift did not compile"
"$scratch/make-icons" generate "$PWD" "$scratch/apps" || fail "the generator failed"
for platform in $PLATFORMS; do
    [ -d "$scratch/apps/$platform/icons" ] || fail "the generator wrote nothing for $platform"
done
"$scratch/make-icons" verify "$PWD" "$scratch/apps" >"$scratch/verify.md" \
    || { cat "$scratch/verify.md"; fail "the generated sets fail their measurements"; }

case "${1:-}" in
    generate)
        for platform in $PLATFORMS; do
            rm -rf "$APPS/$platform/icons"
            mkdir -p "$APPS/$platform"
            cp -R "$scratch/apps/$platform/icons" "$APPS/$platform/icons"
        done
        cat "$scratch/verify.md"
        echo "icons: wrote $(cd "$scratch/apps" && find . -type f | wc -l | tr -d ' ') files into $APPS/{${PLATFORMS// /,}}/icons"
        ;;
    check)
        stale=0
        for platform in $PLATFORMS; do
            [ -d "$APPS/$platform/icons" ] || { echo "icons: $platform/icons is missing" >&2; stale=1; continue; }
            # `diff -rq` names a changed file, one only on either side, and exits 1 for any of them.
            diff -rq "$scratch/apps/$platform/icons" "$APPS/$platform/icons" >&2 || stale=1
        done
        [ "$stale" = 0 ] || fail "the committed icon sets are not what the source generates: run \`make icons\`"
        "$scratch/make-icons" verify "$PWD" "$APPS" >"$scratch/committed.md" \
            || { cat "$scratch/committed.md"; fail "the committed icon sets fail their measurements"; }
        echo "icons: the committed sets match their source and pass $(grep -c '| yes |' "$scratch/committed.md") measurements"
        ;;
    *) fail "usage: $0 generate|check" ;;
esac
