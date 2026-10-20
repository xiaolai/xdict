#!/bin/bash
# `Tools/main-checkout.sh`'s own tests: the main checkout answered from the checkout itself, from a worktree nested
# inside it, from one under the workspace's sibling `worktrees/`, and from a copy with no history; and the refusal
# when there is none. Every script that needs the main checkout asks the helper and carries no resolver of its own —
# the class that broke on 2026-10-20, when the docs directory became the main checkout's sibling and the marker-file
# walk ran past the workspace root. `make test-tools`.
set -uo pipefail
cd "$(dirname "$0")/../.."
failures=0
ok() { echo "ok    $*"; }
bad() { echo "FAIL  $*"; failures=$((failures + 1)); }
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
# Physical, as git's own paths are: macOS keeps /var a symlink to /private/var.
scratch=$(cd "$scratch" && pwd -P)
helper=$PWD/Tools/main-checkout.sh

root=$scratch/workspace
mkdir -p "$root/dev-docs" "$root/worktrees"
git init -q "$root/main" || { echo "main-checkout-test: git init failed" >&2; exit 1; }
mkdir -p "$root/main/apps/apple"
: >"$root/main/local.mk"
git -C "$root/main" -c core.hooksPath=/dev/null -c user.name=test -c user.email=test@localhost \
    commit -q --allow-empty -m start || { echo "main-checkout-test: git commit failed" >&2; exit 1; }

expect() {  # expect <label> <wanted> <path>
    local got status
    got=$("$helper" "$3" 2>"$scratch/err")
    status=$?
    if [ "$status" -ne 0 ]; then bad "$1: exited $status ($(cat "$scratch/err"))"
    elif [ "$got" != "$2" ]; then bad "$1: got $got, wanted $2"
    else ok "$1: $got"; fi
}

expect "the main checkout, from inside it" "$root/main" "$root/main/apps/apple"

git -C "$root/main" worktree add -q "$root/main/.claude/worktrees/wt" -b nested \
    || bad "could not make a worktree inside the checkout"
expect "a worktree nested inside the checkout" "$root/main" "$root/main/.claude/worktrees/wt"

git -C "$root/main" worktree add -q "$root/worktrees/wt" -b beside \
    || bad "could not make a worktree beside the checkout"
expect "a worktree beside the checkout" "$root/main" "$root/worktrees/wt"

# A copy with no history: the walk for local.mk is the only answer left.
mkdir -p "$scratch/copy/apps/apple"
: >"$scratch/copy/local.mk"
expect "a copy with no history" "$scratch/copy" "$scratch/copy/apps/apple"

# A nested copy with no history answers the nearest local.mk, not the outermost.
mkdir -p "$scratch/inner/nested/apps/apple"
: >"$scratch/inner/nested/local.mk"
expect "the nearest local.mk above a copy" "$scratch/inner/nested" "$scratch/inner/nested/apps/apple"

# A checkout git knows, with no local.mk yet (a fresh clone), is still the main checkout.
git init -q "$scratch/fresh" || bad "could not init a fresh clone"
expect "a fresh clone with no local.mk" "$scratch/fresh" "$scratch/fresh"

# Nothing above: no git common dir, no local.mk. Refused with a sentence, and nothing on stdout.
mkdir -p "$scratch/none/apps/apple"
out=$("$helper" "$scratch/none/apps/apple" 2>"$scratch/err")
status=$?
if [ "$status" -eq 2 ] && [ -z "$out" ] && grep -q 'no main checkout' "$scratch/err"; then
    ok "no main checkout refused: $(cat "$scratch/err")"
else bad "no main checkout: exit $status, stdout '$out', stderr '$(cat "$scratch/err")'"; fi

# One resolver, not five: each script that needs the main checkout asks the helper, and none walks for local.mk or
# reads git's common dir itself.
for script in Tools/land.sh Tools/ui-tour/run.sh Tools/gallery/hot.sh Tools/gallery/lab.sh \
    Tools/gallery/render-affected.sh; do
    if grep -q 'main-checkout\.sh' "$script"; then ok "$script asks the helper"
    else bad "$script does not ask the helper"; fi
    if grep -Eq 'git-common-dir|while \[ ! -f [^]]*local\.mk' "$script"; then
        bad "$script carries its own main-checkout resolver"
    else ok "$script carries no resolver of its own"; fi
done

[ "$failures" -eq 0 ] || { echo "main-checkout-test: $failures failed" >&2; exit 1; }
echo "main-checkout-test: all passed"
