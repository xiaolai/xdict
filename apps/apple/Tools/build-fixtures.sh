#!/bin/bash
# The dictionaries the service's checks read, written by the core's own MDX writer (AGENTS.md: no dictionary content
# enters this repository; fixtures are written by the test suite's writer). One script for the three places that need
# them: `make test` (the in-process service tests), CI, and the E2E `service` stage, which ships them to the E2E Mac.
#
#   Tools/build-fixtures.sh <dir>   writes, replacing what was there:
#     <dir>/tiny/     tiny.mdx, tiny.mdd, tiny.css and the defective files, with conformance/fixtures/tiny/expected.json
#     <dir>/matrix/   the 32 variants and variants.json, with conformance/fixtures/matrix/expected.json
#     <dir>/slow/     slow.mdx, slow.mdd and heavy.mdx (`service-fixture`): a lookup, a resource and an import that keep
#                     the service busy
#     <dir>/library/  the packages the library's checks import (`library-fixture`): a file, a folder with ordered
#                     volumes and a sidecar, a missing volume, three refusals, language names, a symbolic link out of
#                     its folder, sounds, a file rewritten, and a 128 MiB one to cancel (plan-macos-v1 WI-5)
#     <dir>/lookup/   the dictionaries the main window's checks search (`lookup-fixture`): an exact and an accented key,
#                     phrase keys, internal keys, a trail of six entries, 66,355 records under one key, and four that
#                     cannot answer, each for its own reason (plan-macos-v1 WI-6)
#
# Written into a scratch directory first and moved into place whole, so a failed run never leaves a mixture that
# looks complete.
set -euo pipefail
apple=$(cd "$(dirname "$0")/.." && pwd)
core=$(cd "$apple/../../core" && pwd)
conformance=$(cd "$apple/../../conformance/fixtures" && pwd)
readonly apple core conformance
fail() { echo "build-fixtures: $*" >&2; exit 1; }

out=${1:?usage: build-fixtures.sh <dir>}
mkdir -p "$(dirname "$out")"
# Absolute: cargo runs from core/, and a relative path would be written there.
out=$(cd "$(dirname "$out")" && pwd)/$(basename "$out")
scratch=$(mktemp -d "$(dirname "$out")/.fixtures.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

(cd "$core" && CARGO_TARGET_DIR=$apple/.build/cargo cargo run --quiet --release --locked -p xdict-conformance \
    --bin conformance-fixtures -- "$scratch")
(cd "$core" && CARGO_TARGET_DIR=$apple/.build/cargo cargo run --quiet --release --locked -p xdict-conformance \
    --bin service-fixture -- "$scratch/slow")
(cd "$core" && CARGO_TARGET_DIR=$apple/.build/cargo cargo run --quiet --release --locked -p xdict-conformance \
    --bin library-fixture -- "$scratch/library")
(cd "$core" && CARGO_TARGET_DIR=$apple/.build/cargo cargo run --quiet --release --locked -p xdict-conformance \
    --bin lookup-fixture -- "$scratch/lookup")
for fixture in tiny matrix; do
    cp "$conformance/$fixture/expected.json" "$scratch/$fixture/expected.json"
done
# What the checks open, asserted here: a writer that wrote nothing would otherwise show up as a test that found nothing.
for file in tiny/tiny.mdx tiny/tiny.mdd tiny/tiny.css tiny/tiny-rebuilt.mdx tiny/expected.json matrix/variants.json matrix/expected.json \
    slow/slow.mdx slow/slow.mdd slow/heavy.mdx library/file/single.mdx library/folder/vol/vol.2.mdd \
    library/folder/vol/vol.css library/gap/gap.2.mdd library/drop/dropped.mdx library/refused/v3/v3.mdd \
    library/refused/regcode/regcode.mdx library/refused/damaged/damaged.mdx library/lang/Plain\ Glossary.mdx \
    library/escape/esc/esc.css library/sounds/sounds.mdd library/rewrite/second.mdx library/big/big.mdx \
    lookup/alpha/alpha.mdx lookup/beta/beta.mdx lookup/records/records.mdx lookup/damaged/damaged.mdx \
    lookup/locked/locked.mdx lookup/gone/gone.mdx lookup/slow/slow.mdx; do
    [ -s "$scratch/$file" ] || fail "the writer left no $file"
done
# The escape is a symbolic link, or it tests nothing.
[ -L "$scratch/library/escape/esc/esc.css" ] || fail "library/escape/esc/esc.css is not a symbolic link"

rm -rf "$out"
mv "$scratch" "$out"
trap - EXIT
echo "build-fixtures: $out written ($(find "$out" -type f | wc -l | tr -d ' ') files)"
