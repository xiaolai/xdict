#!/bin/bash
# The notices check (Tools/notices.py) passes on the committed notices, and fails, naming what is missing, when a linked
# crate's or a bundled font's notice is gone: its two positive controls.
set -uo pipefail
cd "$(dirname "$0")/../.."
fail() { echo "notices-test: FAIL: $*" >&2; exit 1; }
scratch=$(mktemp -d); trap 'rm -rf "$scratch"' EXIT

python3 -I Tools/notices.py check || fail "the committed notices do not pass"

crate=$(grep -m1 '^crate ' Resources/Acknowledgements.txt) || fail "the notices list no crate"
grep -vxF "$crate" Resources/Acknowledgements.txt >"$scratch/lacking.txt"
said=$(python3 -I Tools/notices.py check --notices "$scratch/lacking.txt" 2>&1) && fail "a crate's notice removed, and the check passed"
grep -qF "lacks ${crate% (*}" <<<"$said" || fail "the check failed without naming ${crate% (*}: $said"

cp -R Resources/Fonts "$scratch/Fonts" && cp Resources/Fonts/Charis-Regular.ttf "$scratch/Fonts/Unnoticed-Regular.ttf"
said=$(python3 -I Tools/notices.py check --fonts "$scratch/Fonts" 2>&1) && fail "a font without its OFL, and the check passed"
grep -qF "Unnoticed-Regular.ttf" <<<"$said" || fail "the check failed without naming the font: $said"
echo "notices-test: passed (and failed for a missing crate and a missing font notice)"
