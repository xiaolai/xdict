#!/bin/bash
# Tools/release-publish.sh publishes the DMG and its sha256 under a tag that is at HEAD, then keeps only the two most
# recent GitHub releases and never a tag's deletion (AGENTS.md, owner 2026-10-30). gh is a fake on XDICT_GH that holds
# the release list in a file and logs every call: no real gh runs here.
set -uo pipefail
cd "$(dirname "$0")/../.."
apple=$PWD
fail=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@localhost GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@localhost
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# The fake gh: `release list` prints the releases file (already in the --jq shape: createdAt, tab, tag); `release
# create` adds its tag as the newest; `release delete` removes its tag. Every call is logged, one line each.
cat >"$scratch/gh" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >>"$FAKE_GH_LOG"
case "$1 $2" in
    "release list") cat "$FAKE_RELEASES" ;;
    "release create") printf '2026-11-05T00:00:00Z\t%s\n' "$3" >>"$FAKE_RELEASES" ;;
    "release delete") grep -v "	$3\$" "$FAKE_RELEASES" >"$FAKE_RELEASES.new"; mv "$FAKE_RELEASES.new" "$FAKE_RELEASES" ;;
    *) echo "fake gh: unexpected $*" >&2; exit 9 ;;
esac
FAKE
chmod +x "$scratch/gh"

r=$scratch/repo
mkdir -p "$r/apps/apple/Tools"
cp "$apple/Tools/release-publish.sh" "$r/apps/apple/Tools/"
git -C "$r" init -q && git -C "$r" add -A && git -C "$r" commit -qm base
git -C "$r" tag -a v0.6.13 -m 'XDict 0.6.13: Lookup is faster' HEAD
mkdir -p "$scratch/out"
dmg=$scratch/out/XDict-0.6.13-42.dmg
echo image >"$dmg"

publish() { # case, releases (one "date tag" per line), args...: runs the script; leaves the gh log in $scratch/<case>.gh
    local name=$1; shift
    export FAKE_GH_LOG=$scratch/$name.gh FAKE_RELEASES=$scratch/$name.releases
    : >"$FAKE_GH_LOG"
    printf '%s' "$1" | tr ' ' '\t' >"$FAKE_RELEASES"; shift
    XDICT_GH=$scratch/gh bash "$r/apps/apple/Tools/release-publish.sh" "$@" 2>&1
}
deletes() { grep '^release delete' "$scratch/$1.gh" | cut -d' ' -f3 | tr '\n' ' ' | sed 's/ $//'; }

# Three releases once this one is made: exactly the oldest goes.
out=$(publish three $'2026-10-01T00:00:00Z v0.6.11\n2026-10-15T00:00:00Z v0.6.12\n' "$dmg"); got=$?
if [ "$got" = 0 ] && [ "$(deletes three)" = v0.6.11 ]; then ok "with three releases exactly the oldest is deleted"
else bad "three releases: exit $got, deleted [$(deletes three)]: $out"; fi
grep -q 'deleted the release v0.6.11' <<<"$out" && ok "the deletion is printed" || bad "the deletion was not printed: $out"
grep -qx 'release delete v0.6.11 --yes' "$scratch/three.gh" && ok "the delete is gh release delete <tag> --yes" \
    || bad "delete call: $(grep delete "$scratch/three.gh")"
create=$(grep '^release create' "$scratch/three.gh")
if [ "$create" = "release create v0.6.13 $dmg $dmg.sha256 --verify-tag --title XDict 0.6.13: Lookup is faster --notes-from-tag" ]
then ok "gh release create gets the DMG, its sha256, the tag's title and notes"; else bad "create call: $create"; fi
(cd "$scratch/out" && shasum -a 256 -c XDict-0.6.13-42.dmg.sha256 >/dev/null 2>&1) && ok "the sha256 file is the DMG's" \
    || bad "the sha256 file is missing or wrong"

# The DMG's tag is never deleted, on GitHub or here, and --cleanup-tag is never passed.
cat "$scratch"/*.gh >"$scratch/all.gh" 2>/dev/null
grep -q -- '--cleanup-tag' "$scratch/all.gh" && bad "--cleanup-tag was passed" || ok "--cleanup-tag is never passed"
grep -v '^[[:space:]]*#' "$r/apps/apple/Tools/release-publish.sh" | grep -q -- '--cleanup-tag' \
    && bad "the script's code names --cleanup-tag" || ok "the script's code never names --cleanup-tag"
git -C "$r" rev-parse -q --verify refs/tags/v0.6.13 >/dev/null && ok "the tag is still there" || bad "the tag was deleted"

# Two releases once this one is made: none goes.
out=$(publish two $'2026-10-15T00:00:00Z v0.6.12\n' "$dmg"); got=$?
if [ "$got" = 0 ] && [ -z "$(deletes two)" ] && grep -q '0 older release(s) deleted' <<<"$out"; then
    ok "with two releases none is deleted"
else bad "two releases: exit $got, deleted [$(deletes two)]: $out"; fi

# A notes file is given to gh as the notes.
printf 'Notes.\n' >"$scratch/notes.md"
out=$(publish notes $'2026-10-15T00:00:00Z v0.6.12\n' "$dmg" "$scratch/notes.md"); got=$?
grep -q -- "--notes-file $scratch/notes.md\$" "$scratch/notes.gh" && ok "a notes file is passed as --notes-file" \
    || bad "notes: exit $got: $(cat "$scratch/notes.gh"): $out"

# --dry-run prints the create and the deletions it would make, and changes nothing on GitHub.
out=$(publish dry $'2026-10-01T00:00:00Z v0.6.11\n2026-10-15T00:00:00Z v0.6.12\n' --dry-run "$dmg"); got=$?
if [ "$got" = 0 ] && grep -q '^dry-run: .*release create v0.6.13' <<<"$out" \
    && grep -q '^dry-run: .*release delete v0.6.11 --yes' <<<"$out" && ! grep -q 'v0.6.12 --yes' <<<"$out"; then
    ok "--dry-run prints the create and exactly the oldest deletion"
else bad "dry run: exit $got: $out"; fi
if [ "$(grep -vc '^release list' "$scratch/dry.gh")" = 0 ]; then ok "--dry-run only lists"
else bad "--dry-run changed GitHub: $(cat "$scratch/dry.gh")"; fi

# Refused before gh runs: a tag that is not at HEAD, no tag at all, a sha256 that does not match, a name with no version.
refused() { # name, sentence, dmg
    out=$(publish refused $'2026-10-15T00:00:00Z v0.6.12\n' "$3"); got=$?
    if [ "$got" != 0 ] && grep -q "$2" <<<"$out" && [ ! -s "$scratch/refused.gh" ]; then ok "$1 is refused"
    else bad "$1: exit $got, gh calls $(wc -l <"$scratch/refused.gh" | tr -d ' '): $out"; fi
}
git -C "$r" commit -q --allow-empty -m later
refused "a tag that is not at HEAD" "not HEAD" "$dmg"
git -C "$r" reset -q --hard v0.6.13
other=$scratch/out/XDict-0.6.14.dmg
echo image >"$other"
refused "a DMG with no tag" "there is no tag v0.6.14" "$other"
echo "0000000000000000000000000000000000000000000000000000000000000000  XDict-0.6.13-42.dmg" >"$dmg.sha256"
refused "a sha256 that does not match" "does not match" "$dmg"
echo image >"$scratch/out/xdict.dmg"
refused "a name with no version" "is not XDict-<version>" "$scratch/out/xdict.dmg"
exit $fail
