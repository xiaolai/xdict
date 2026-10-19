#!/bin/bash
# Tests of Tools/clean-dev.sh against scratch git repositories and a scratch build host: no ssh, no real machine. The
# build host's part runs here through XDICT_CLEAN_DEV_TRANSPORT (`env HOME=<scratch>`), as it runs there through ssh.
# Each "kept" case has a "removed" twin that differs in the one property under test, so neither half passes alone.
set -uo pipefail
cd "$(dirname "$0")/../.."
failures=0
ok() { echo "ok    $*"; }
bad() { echo "FAIL  $*"; failures=$((failures + 1)); }
scratch=$(mktemp -d)
scratch=$(cd "$scratch" && pwd -P)
pids=()
cleanup() {
    for p in ${pids[@]+"${pids[@]}"}; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
    rm -rf "$scratch"
}
trap cleanup EXIT
OLD=202601010000 # older than any --min-age-hours the tests use
age_old() { find "$1" -exec touch -h -t "$OLD" {} +; }
script=$PWD/Tools/clean-dev.sh
mkdir -p "$scratch/tmp" "$scratch/bin"
printf 'BUILD_HOST = stub-host\n' >"$scratch/local.mk"
export TMPDIR=$scratch/tmp XDICT_CLEAN_DEV_LOCAL_MK=$scratch/local.mk
unset XDICT_HOST_LOCK_HELD
run() { # args...: runs clean-dev.sh, output in $scratch/out, exit status in $rc
    XDICT_CLEAN_DEV_TRANSPORT="env HOME=$scratch/home" bash "$script" "$@" >"$scratch/out" 2>&1
    rc=$?
}
gone() { [ ! -e "$1" ] && [ ! -L "$1" ]; }

# ---- The Air: a repository whose main checkout is on the integration branch ----
repo=$scratch/repo
git init -q -b capture-port "$repo"
g() { git -C "$repo" -c user.name=t -c user.email=t@t "$@"; }
printf '.build/\n' >"$repo/.gitignore"
echo base >"$repo/a.txt"
g add -A && g commit -qm base
wts=$repo/.claude/worktrees
add_wt() { # name branch: a worktree on a new branch with one commit of its own
    g worktree add -q -b "$2" "$wts/$1" capture-port
    echo "$1" >"$wts/$1/$1.txt"
    git -C "$wts/$1" -c user.name=t -c user.email=t@t add -A
    git -C "$wts/$1" -c user.name=t -c user.email=t@t commit -qm "$1"
}
merge() { g merge -q --ff-only "$1" 2>/dev/null || g merge -q --no-edit "$1"; }
add_wt merged worktree-agent-merged && merge worktree-agent-merged
add_wt named feature-named && merge feature-named
add_wt unmerged worktree-agent-unmerged
add_wt dirty worktree-agent-dirty && merge worktree-agent-dirty
add_wt fresh worktree-agent-fresh && merge worktree-agent-fresh
add_wt busy worktree-agent-busy && merge worktree-agent-busy
g worktree add -q -b worktree-agent-outside "$scratch/outside-wt" capture-port
echo untracked >"$wts/dirty/new-file.txt"
for w in merged named unmerged dirty busy; do age_old "$wts/$w"; done
age_old "$scratch/outside-wt"
# A fresh ignored build product does not make a worktree young: only its own files count.
mkdir -p "$wts/merged/.build" && echo product >"$wts/merged/.build/x" && touch -t "$OLD" "$wts/merged"
ln -s "$scratch/outside-wt" "$wts/link-out"
(cd "$wts/busy" && exec sleep 300) </dev/null >/dev/null 2>&1 &
pids+=($!)
sleep 1

run --air --repo "$repo"
[ "$rc" = 0 ] && ok "air dry run exits 0" || bad "air dry run exit $rc: $(cat "$scratch/out")"
for w in merged named unmerged dirty fresh busy; do
    [ -d "$wts/$w" ] || bad "dry run removed $w"
done
[ -d "$wts/merged" ] && ok "a dry run deletes nothing" || true
grep -qE '^remove +[^ ]+ +merged ' "$scratch/out" && ok "dry run lists merged for removal" \
    || bad "dry run does not list merged: $(cat "$scratch/out")"

run --air --apply --repo "$repo"
[ "$rc" = 0 ] && ok "air apply exits 0" || bad "air apply exit $rc: $(cat "$scratch/out")"
gone "$wts/merged" && ok "merged, clean, old: removed" || bad "merged worktree kept: $(cat "$scratch/out")"
gone "$wts/named" && ok "a merged named-branch worktree: removed" || bad "named worktree kept"
g rev-parse -q --verify refs/heads/worktree-agent-merged >/dev/null && bad "worktree-agent-merged branch kept" \
    || ok "its worktree-agent-* branch: deleted"
g rev-parse -q --verify refs/heads/feature-named >/dev/null && ok "a named branch: kept" || bad "feature-named deleted"
[ -d "$wts/unmerged" ] && ok "unmerged: kept" || bad "unmerged removed"
g rev-parse -q --verify refs/heads/worktree-agent-unmerged >/dev/null && ok "unmerged branch: kept" || bad "unmerged branch deleted"
[ -f "$wts/dirty/new-file.txt" ] && ok "dirty (untracked file): kept" || bad "dirty removed"
[ -d "$wts/fresh" ] && ok "too new: kept" || bad "fresh removed"
[ -d "$wts/busy" ] && ok "in use (a process's cwd): kept" || bad "busy removed"
[ -d "$scratch/outside-wt" ] && ok "a worktree outside .claude/worktrees: kept" || bad "outside worktree removed"
[ -L "$wts/link-out" ] && [ -d "$scratch/outside-wt" ] && ok "a symlink out of the root: untouched" || bad "symlink followed"
[ -f "$repo/a.txt" ] && ok "the main checkout: kept" || bad "main checkout touched"
grep -qE '^keep +[^ ]+ +busy ' "$scratch/out" && ok "the table says busy is kept" \
    || bad "the table does not show busy kept"

run --air --apply --repo "$repo"
[ "$rc" = 0 ] && ! grep -q '^removed' "$scratch/out" && ok "a second apply is idempotent" \
    || bad "second apply: exit $rc: $(cat "$scratch/out")"

# The integration branch is an argument: unmerged into capture-port, merged into another.
g branch -q other worktree-agent-unmerged
age_old "$wts/unmerged"
run --air --apply --repo "$repo" --into other
gone "$wts/unmerged" && ok "--into other: a branch merged there is removed" || bad "--into ignored: $(cat "$scratch/out")"
run --air --repo "$repo" --into no-such-branch
[ "$rc" = 1 ] && ok "a missing integration branch is an error" || bad "missing --into: exit $rc"

# Process use that cannot be read keeps everything, loudly.
add_wt merged2 worktree-agent-merged2 && merge worktree-agent-merged2 && age_old "$wts/merged2"
printf '#!/bin/sh\nexit 1\n' >"$scratch/bin/lsof" && chmod +x "$scratch/bin/lsof"
PATH=$scratch/bin:$PATH run --air --apply --repo "$repo"
[ "$rc" = 1 ] && [ -d "$wts/merged2" ] && ok "air: an unreadable process table keeps all, exit 1" \
    || bad "air with lsof failing: exit $rc, merged2 $([ -d "$wts/merged2" ] && echo kept || echo removed)"

# ---- The build host ----
home=$scratch/home
root=$home/xdict-build
mkdir -p "$root" "$home/xdict-corpus" "$home/XDictE2E" "$home/.cargo" "$home/.cache" "$scratch/outside"
echo keep >"$home/xdict-corpus/c" && echo keep >"$scratch/outside/precious"
mk() { mkdir -p "$root/$1/apps" && echo x >"$root/$1/apps/f"; }
for d in old xdict xdict-land-cargo xdict-land-swift fresh stalebuild cwdbusy argbusy lockref apple-thing inner "we ird"; do
    mk "$d"
done
mkdir -p "$root/old-git/objects" "$root/xdict.out"
echo b >"$root/old.bundle"; echo s >"$root/old-probe.sh"; echo p >"$root/old-mutants.py"; echo s >"$root/old-ZZ.swift"
echo b >"$root/fresh.bundle"; echo p >"$root/loose.py"; echo t >"$root/notes.txt"; echo b >"$root/orphan.bundle"
ln -s "$scratch/outside" "$root/evil"
ln -s "$scratch/outside" "$root/inner/out"
age_old "$root"
mkdir -p "$root/stalebuild/.build" "$root/stalebuild/core/target" && echo n >"$root/stalebuild/.build/new"
echo n >"$root/stalebuild/core/target/new"
echo n >"$root/fresh/apps/new"
echo n >"$root/newloose.sh"
touch -t "$OLD" "$root" "$root/stalebuild" "$root/stalebuild/core" "$root/fresh/apps" "$root/fresh"
(cd "$root/cwdbusy/apps" && exec sleep 300) </dev/null >/dev/null 2>&1 &
pids+=($!)
bash -c 'sleep 300; :' "$root/argbusy" </dev/null >/dev/null 2>&1 &
pids+=($!)
bash -c 'sleep 300; :' "/elsewhere/.claude/worktrees/lockref/apps/apple" </dev/null >/dev/null 2>&1 &
lockpid=$!
pids+=($lockpid)
. Tools/host-lock.sh
echo "$lockpid" >"$(host_lock_file stub-host)"
sleep 1

run --mbp16
[ "$rc" = 0 ] && ok "build host dry run exits 0" || bad "build host dry run exit $rc: $(cat "$scratch/out")"
[ -d "$root/old" ] && [ -f "$root/old.bundle" ] && ok "build host dry run deletes nothing" || bad "dry run deleted"
grep -qE '^remove .* old( |$)' "$scratch/out" && ok "dry run lists old" || bad "dry run does not list old: $(cat "$scratch/out")"

run --mbp16 --apply
[ "$rc" = 0 ] && ok "build host apply exits 0" || bad "build host apply exit $rc: $(cat "$scratch/out")"
gone "$root/old" && ok "an old unused copy: removed" || bad "old kept: $(cat "$scratch/out")"
for a in old.bundle old-git old-probe.sh old-mutants.py old-ZZ.swift; do
    gone "$root/$a" && ok "its artifact $a: removed" || bad "artifact $a kept"
done
[ -d "$root/xdict" ] && [ -d "$root/xdict.out" ] && ok "the main copy and its output: kept" || bad "main copy removed"
[ -d "$root/xdict-land-cargo" ] && [ -d "$root/xdict-land-swift" ] && ok "the landing lanes: kept" || bad "a lane removed"
[ -d "$root/fresh" ] && [ -f "$root/fresh.bundle" ] && ok "too new, with its artifact: kept" || bad "fresh removed"
gone "$root/stalebuild" && ok "new files only under .build/ and target/: removed" || bad "stalebuild kept"
[ -d "$root/cwdbusy" ] && ok "a process's cwd inside: kept" || bad "cwdbusy removed"
[ -d "$root/argbusy" ] && ok "a process naming it: kept" || bad "argbusy removed"
[ -d "$root/lockref" ] && ok "named by the run lock's holder: kept" || bad "lockref removed"
grep -qE '^keep +[^ ]+ +lockref .*lock' "$scratch/out" && ok "the table says the lock keeps lockref" || bad "no lock reason"
gone "$root/apple-thing" && ok "a folder name inside every checkout (apple, of apps/apple) names no entry" \
    || bad "apple-thing kept by the holder's apps/apple"
gone "$root/loose.py" && gone "$root/orphan.bundle" && ok "old loose scripts and bundles: removed" || bad "loose kept"
[ -f "$root/newloose.sh" ] && ok "a new loose script: kept" || bad "newloose removed"
[ -f "$root/notes.txt" ] && ok "an unknown kind of file: kept" || bad "notes.txt removed"
[ -L "$root/evil" ] && [ -f "$scratch/outside/precious" ] && ok "a symlink out of the root: kept, target intact" \
    || bad "symlink evil followed or removed"
gone "$root/inner" && [ -f "$scratch/outside/precious" ] && ok "a copy holding a symlink out: removed, target intact" \
    || bad "inner: $(ls "$root" | tr '\n' ' ') / $(ls "$scratch/outside")"
[ -d "$root/we ird" ] && ok "an unusual name: kept" || bad "unusual name removed"
[ -f "$home/xdict-corpus/c" ] && [ -d "$home/XDictE2E" ] && [ -d "$home/.cargo" ] && ok "outside the root: untouched" \
    || bad "a protected folder touched"

run --mbp16 --apply
[ "$rc" = 0 ] && ! grep -q '^removed' "$scratch/out" && ok "a second build-host apply is idempotent" \
    || bad "second apply: exit $rc: $(cat "$scratch/out")"

# Unreadable process use on the host: nothing removed, exit 1.
mk old2 && age_old "$root/old2" && touch -t "$OLD" "$root"
PATH=$scratch/bin:$PATH run --mbp16 --apply
[ "$rc" = 1 ] && [ -d "$root/old2" ] && ok "host: an unreadable process table keeps all, exit 1" \
    || bad "host with lsof failing: exit $rc"

# The root itself a symlink (to anywhere): refused before anything is listed.
mkdir -p "$scratch/home2/elsewhere/victim" && age_old "$scratch/home2/elsewhere"
ln -s "$scratch/home2/elsewhere" "$scratch/home2/xdict-build"
XDICT_CLEAN_DEV_TRANSPORT="env HOME=$scratch/home2" bash "$script" --mbp16 --apply >"$scratch/out" 2>&1
rc=$?
[ "$rc" = 1 ] && [ -d "$scratch/home2/elsewhere/victim" ] && ok "a symlinked root: refused, exit 1" \
    || bad "symlinked root: exit $rc: $(cat "$scratch/out")"

# Arguments are checked before anything runs.
run --min-age-hours abc
[ "$rc" = 1 ] && ok "a non-numeric age is refused" || bad "age abc: exit $rc"

# The Makefile wires the target and the test.
# Captured, not piped into grep -q: under pipefail make's SIGPIPE would read as "missing".
dry=$(make -n clean-dev 2>/dev/null)
grep -q 'Tools/clean-dev.sh' <<<"$dry" && ok "make clean-dev runs the script" \
    || bad "make clean-dev missing"
dry=$(make -n test-tools BUILD_HOST= 2>/dev/null)
grep -q 'Tools/tests/clean-dev-test.sh' <<<"$dry" && ok "test-tools runs this test" \
    || bad "test-tools does not run clean-dev-test.sh"

[ "$failures" = 0 ] && echo "clean-dev: all passed" || echo "clean-dev: $failures failed"
[ "$failures" = 0 ]
