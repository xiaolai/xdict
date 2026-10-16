#!/bin/bash
# Tests of Tools/core-on-host.sh: where the E2E run's cargo work happens. Never on the Air (owner, 2026-10-15): on the
# build Mac when one is set, refused loudly on an Air without one, here on any other Mac. ssh and rsync are stubbed:
# nothing leaves this Mac.
set -uo pipefail
cd "$(dirname "$0")/../.."
run=Tools/core-on-host.sh
failures=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; failures=$((failures + 1)); }
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

# An Air with no build Mac: refused, saying why, and nothing run.
if out=$(XDICT_HW_MODEL=MacBookAir10,1 XDICT_BUILD_HOST= bash $run where 2>&1); then
    bad "an Air without a build Mac was not refused: $out"
elif grep -q "BUILD_HOST" <<<"$out"; then ok "an Air without a build Mac is refused, naming BUILD_HOST"
else bad "refused without saying how to fix it: $out"; fi

# Another Mac with none: here.
out=$(XDICT_HW_MODEL=Macmini9,1 XDICT_BUILD_HOST= bash $run where 2>&1) && [ "$out" = "here" ] \
    && ok "a Mac that is not an Air runs it here" || bad "a mini without a build Mac: $out"

# With a build Mac, from the Air too: there.
out=$(XDICT_HW_MODEL=MacBookAir10,1 XDICT_BUILD_HOST=builder bash $run where 2>&1) && [ "$out" = "builder" ] \
    && ok "with a build Mac, it runs there" || bad "with a build Mac: $out"

# A run there: the tree goes over, the command runs in it with OUT set, and OUT comes back to the asked folder.
cat >"$scratch/ssh" <<'SH'
#!/bin/bash
host=$1; shift
echo "$host" >>"$STUB_LOG.hosts"
printf '%s\n' "$*" >>"$STUB_LOG.commands"
mkdir -p "$STUB_REMOTE/out" && echo made >"$STUB_REMOTE/out/result.txt"
SH
cat >"$scratch/rsync" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$STUB_LOG.rsync"
for last; do :; done
src=${*: -2:1}
case $src in *:*out/) mkdir -p "$last" && cp -R "$STUB_REMOTE/out/." "$last" ;; esac
SH
chmod +x "$scratch/ssh" "$scratch/rsync"
export STUB_LOG=$scratch/log STUB_REMOTE=$scratch/remote
if XDICT_HW_MODEL=MacBookAir10,1 XDICT_BUILD_HOST=builder XDICT_REMOTE_SSH=$scratch/ssh XDICT_REMOTE_RSYNC=$scratch/rsync \
    bash $run run "$scratch/back" 'Tools/build-fixtures.sh "$OUT"' >"$scratch/run.out" 2>&1; then
    [ "$(cat "$scratch/back/result.txt" 2>/dev/null)" = made ] && ok "what the host made comes back" \
        || bad "nothing came back: $(cat "$scratch/run.out")"
    grep -q 'build-fixtures.sh' "$STUB_LOG.commands" && grep -q "cargo" "$STUB_LOG.commands" \
        && ok "the command runs on the host, with its cargo on PATH" || bad "the host was asked: $(cat "$STUB_LOG.commands")"
    grep -q "exclude \*.mdx" "$STUB_LOG.rsync" && ok "no dictionary file is copied" || bad "rsync: $(cat "$STUB_LOG.rsync")"
else
    bad "a run on the build Mac failed: $(cat "$scratch/run.out")"
fi

# A run on an Air with no build Mac: refused before anything is copied or run.
rm -f "$STUB_LOG".*
if XDICT_HW_MODEL=MacBookAir10,1 XDICT_BUILD_HOST= XDICT_REMOTE_SSH=$scratch/ssh XDICT_REMOTE_RSYNC=$scratch/rsync \
    bash $run run "$scratch/back2" 'true' >/dev/null 2>&1; then
    bad "an Air ran cargo work with no build Mac"
else
    [ ! -e "$STUB_LOG.commands" ] && [ ! -e "$STUB_LOG.rsync" ] && ok "refused before anything was copied or run" \
        || bad "something ran before the refusal"
fi

[ "$failures" -eq 0 ] && echo "core-on-host: all passed" || { echo "core-on-host: $failures failed"; exit 1; }
