#!/bin/bash
# Peak memory of one Apple dictionary conversion through the service's own code (ADR-0011 decision 5; plan WI-4), in the
# style of core/xdict-ffi/measure-memory.sh: the synthetic bundle is written in one process and converted in another,
# so the peak is the conversion's, and held to a budget it fails over. A synthetic bundle only (AppleImportMemoryProbe):
# never an Apple one. On the build host; the Air refuses.
#
# **The budget is BUDGET_MIB below**, from the measurement written beside it. The bundle inflates to 256 MiB, which the
# converter holds whole while it builds the records (the inflated sections, the transformed entries and the records),
# so the peak is a few times that; the budget is the measured peak and about 15% for allocator noise. A change that
# needs more says why here, beside the number.
#
# Not measured here: the signed service with dictionaries open, and a real bundle (Hungarian, 123 MB), which the owner
# measures by hand (ADR-0011 decision 5); this is the synthetic worst case the tests can carry.
set -euo pipefail
cd "$(dirname "$0")/.."
Tools/not-on-air.sh
# 2026-10-18, the build host, debug build: 1024 and 1023 MiB peak (36 before) converting 65,536 entries, 256 MiB
# inflated. Shown red once with a budget of 0.
readonly BUDGET_MIB=1180
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swift build --build-tests >/dev/null
XDICT_APPLE_MEMORY_MAKE=$work swift test --skip-build --filter AppleImportMemoryProbe >"$work/make.log" 2>&1 \
    || { cat "$work/make.log" >&2; echo "the synthetic bundle was not written" >&2; exit 1; }
XDICT_APPLE_MEMORY_CONVERT=$work swift test --skip-build --filter AppleImportMemoryProbe >"$work/convert.log" 2>&1 \
    || { cat "$work/convert.log" >&2; echo "the conversion failed" >&2; exit 1; }
line=$(grep -a 'apple-import memory: peak' "$work/convert.log" | head -1)
[ -n "$line" ] || { cat "$work/convert.log" >&2; echo "no peak was printed: nothing was measured" >&2; exit 1; }
printf '%s\n' "$line"
after=$(sed -n 's/.* \([0-9][0-9]*\) MiB after.*/\1/p' <<<"$line")
[ -n "$after" ] || { echo "no peak in: $line" >&2; exit 1; }
[ "$after" -le "$BUDGET_MIB" ] || { echo "over budget: $after MiB, the most is $BUDGET_MIB MiB" >&2; exit 1; }
echo "within budget: $after MiB of $BUDGET_MIB MiB"
