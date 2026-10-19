#!/bin/bash
# Tests of Tools/clean-dev.sh against scratch git repositories and a scratch build host: no ssh, no real machine. The
# build host's part runs here through XDICT_CLEAN_DEV_TRANSPORT (`env HOME=<scratch>`), as it runs there through ssh.
# Each "kept" case has a "removed" twin that differs in the one property under test, so neither half passes alone.
# A ctime cannot be set back, so the clock is moved forward instead (XDICT_CLEAN_DEV_NOW): everything made here is old
# to the script, and "fresh" is an mtime set into that future.
set -uo pipefail
cd "$(dirname "$0")/../.."
failures=0
ok() { echo "ok    $*"; }
bad() { echo "FAIL  $*"; failures=$((failures + 1)); }
scratch=$(mktemp -d)
scratch=$(cd "$scratch" && pwd -P)
pids=()
cleanup() {
    for p in ${pids[@]+"${pids[@]}"} $(cat "$scratch/more-pids" 2>/dev/null); do
        pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null
    done
    chmod -R u+w "$scratch" 2>/dev/null
    rm -rf "$scratch"
}
trap cleanup EXIT
real_now=$(date +%s)
export XDICT_CLEAN_DEV_NOW=$((real_now + 100 * 3600))
FRESH=$(date -r $((real_now + 90 * 3600)) '+%Y%m%d%H%M.%S') # within 24 h of the moved clock
fresh() { touch -t "$FRESH" "$@"; }
script=$PWD/Tools/clean-dev.sh
mkdir -p "$scratch/tmp" "$scratch/bin" "$scratch/hostbin"
printf 'BUILD_HOST = stub-host\n' >"$scratch/local.mk"
export TMPDIR=$scratch/tmp XDICT_CLEAN_DEV_LOCAL_MK=$scratch/local.mk
unset XDICT_HOST_LOCK_HELD
TRANSPORT="env HOME=$scratch/home"
run() { # args...: runs clean-dev.sh, output in $scratch/out, exit status in $rc
    XDICT_CLEAN_DEV_TRANSPORT="$TRANSPORT" bash "$script" "$@" >"$scratch/out" 2>&1
    rc=$?
}
gone() { [ ! -e "$1" ] && [ ! -L "$1" ]; }
row_is() { grep -qE "^$1 +[^ ]+ +$2 " "$scratch/out"; } # action, name (an ERE)
# The summary counts only what was removed: never a FAILED or REFUSED row.
counts_honest() { # part label (air|build host)
    local said done
    said=$(sed -n "s/^$1: \([0-9]*\) removed .*/\1/p" "$scratch/out")
    done=$(grep -cE '^removed ' "$scratch/out")
    [ -n "$said" ] && [ "$said" = "$done" ]
}

# ---- The Air: a repository whose main checkout is on the integration branch ----
repo=$scratch/repo
git init -q -b capture-port "$repo"
g() { git -C "$repo" -c user.name=t -c user.email=t@t "$@"; }
printf '.build/\n/dev-docs\n' >"$repo/.gitignore"
echo base >"$repo/a.txt"
g add -A && g commit -qm base
wts=$repo/.claude/worktrees
add_wt() { # name branch: a worktree on a new branch with one commit of its own
    g worktree add -q -b "$2" "$wts/$1" capture-port
    echo "$1" >"$wts/$1/f.txt"
    git -C "$wts/$1" -c user.name=t -c user.email=t@t add -A
    git -C "$wts/$1" -c user.name=t -c user.email=t@t commit -qm "$1"
}
merge() { g merge -q --ff-only "$1" 2>/dev/null || g merge -q --no-edit "$1"; }
for w in merged named unmerged dirty fresh busy precious cmdbusy 'a+b' lockedwt racy; do
    b=worktree-agent-$w
    [ "$w" = named ] && b=feature-named
    [ "$w" = 'a+b' ] && b=worktree-agent-aplusb
    add_wt "$w" "$b"
    [ "$w" = unmerged ] || merge "$b"
done
g worktree add -q -b worktree-agent-outside "$scratch/outside-wt" capture-port
nl=$'nl\nname'
g worktree add -q -b worktree-agent-nl "$wts/$nl" capture-port 2>/dev/null || bad "could not make a worktree with a line break"
echo untracked >"$wts/dirty/new-file.txt"
# A commit reset away lives only in the worktree's reflog: removing the worktree would leave it dangling.
add_wt reset worktree-agent-reset && merge worktree-agent-reset
git -C "$wts/reset" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "unique work"
git -C "$wts/reset" reset -q --hard capture-port
# A build product, ignored, does not keep a worktree; an ignored file of any other kind does (item 1).
mkdir -p "$wts/merged/.build" && echo product >"$wts/merged/.build/x"
mkdir -p "$wts/precious/dev-docs" && echo "an ADR draft, nowhere else" >"$wts/precious/dev-docs/adr.md"
fresh "$wts/fresh/f.txt"
ln -s "$scratch/outside-wt" "$wts/link-out"
g worktree lock "$wts/lockedwt"
(cd "$wts/busy" && exec sleep 300) </dev/null >/dev/null 2>&1 &
pids+=($!)
# Named only by command lines, cwd elsewhere: one plain, one whose name is a regular expression's syntax (item 2).
bash -c 'sleep 300; :' "$wts/cmdbusy" </dev/null >/dev/null 2>&1 &
pids+=($!)
bash -c 'sleep 300; :' "$wts/a+b" </dev/null >/dev/null 2>&1 &
pids+=($!)
# The race (item 3): each worktree is sized (du), judged, and, when removable, judged again from a fresh lsof just before
# its removal. The lsof that follows sizing `racy` writes a precious file into it: in the window, after its judgement.
cat >"$scratch/bin/du" <<EOF
#!/bin/bash
echo "\$*" >"$scratch/last-du"
exec /usr/bin/du "\$@"
EOF
cat >"$scratch/bin/lsof" <<EOF
#!/bin/bash
case \$(cat "$scratch/last-du" 2>/dev/null) in
    *"/racy") mkdir -p "$wts/racy/dev-docs" && echo "written in the window" >"$wts/racy/dev-docs/new.md" ;;
esac
exec /usr/sbin/lsof "\$@"
EOF
chmod +x "$scratch/bin/du" "$scratch/bin/lsof"
sleep 1

run --air --repo "$repo"
[ "$rc" = 0 ] && ok "air dry run exits 0" || bad "air dry run exit $rc: $(cat "$scratch/out")"
[ -d "$wts/merged" ] && [ -d "$wts/named" ] && ok "a dry run deletes nothing" || bad "dry run removed something"
row_is remove merged && ok "dry run lists merged for removal" || bad "dry run does not list merged: $(cat "$scratch/out")"
grep -q 'nl\\nname' "$scratch/out" && row_is keep "\\\$'nl\\\\nname'" && ok "a line break in a name: kept, shown quoted (item 7)" \
    || bad "line-break name: $(grep -n 'nl' "$scratch/out")"

PATH=$scratch/bin:$PATH run --air --apply --repo "$repo"
[ "$rc" = 0 ] && ok "air apply exits 0" || bad "air apply exit $rc: $(cat "$scratch/out")"
gone "$wts/merged" && ok "merged, clean, old, only build products ignored: removed" || bad "merged kept: $(cat "$scratch/out")"
gone "$wts/named" && ok "a merged named-branch worktree: removed" || bad "named worktree kept"
g rev-parse -q --verify refs/heads/worktree-agent-merged >/dev/null && bad "worktree-agent-merged branch kept" \
    || ok "its worktree-agent-* branch: deleted"
g rev-parse -q --verify refs/heads/feature-named >/dev/null && ok "a named branch: kept" || bad "feature-named deleted"
[ -d "$wts/unmerged" ] && ok "unmerged: kept" || bad "unmerged removed"
[ -f "$wts/dirty/new-file.txt" ] && ok "dirty (untracked file): kept" || bad "dirty removed"
[ -d "$wts/fresh" ] && ok "too new: kept" || bad "fresh removed"
[ -d "$wts/busy" ] && row_is keep busy && ok "in use (a process's cwd): kept" || bad "busy removed"
[ -f "$wts/precious/dev-docs/adr.md" ] && row_is keep precious && grep -q 'precious .*ignored files other than build' "$scratch/out" \
    && ok "an ignored file that is not a build product: kept, and said (item 1)" || bad "precious: $(grep precious "$scratch/out")"
[ -d "$wts/reset" ] && grep -qE '^keep .* reset .*reflog holds 1 commits on no branch' "$scratch/out" \
    && ok "a commit only in its reflog: kept" || bad "reset: $(grep reset "$scratch/out")"
[ -d "$wts/cmdbusy" ] && ok "named by a process's command line: kept" || bad "cmdbusy removed"
[ -d "$wts/a+b" ] && ok "a+b named by a process: kept (fixed text, not a pattern; item 2)" || bad "a+b removed"
[ -d "$wts/lockedwt" ] && row_is keep lockedwt && ok "a locked worktree: kept" || bad "lockedwt removed"
[ -f "$wts/racy/dev-docs/new.md" ] && grep -q 'racy .*re-checked before removal' "$scratch/out" \
    && ok "changed between the judgement and the removal: re-checked and kept (item 3)" || bad "racy: $(grep racy "$scratch/out")"
[ -d "$scratch/outside-wt" ] && ok "a worktree outside .claude/worktrees: kept" || bad "outside worktree removed"
[ -L "$wts/link-out" ] && [ -d "$scratch/outside-wt" ] && ok "a symlink out of the root: untouched" || bad "symlink followed"
[ -d "$wts/$nl" ] && ok "a line-break name: kept on apply" || bad "line-break worktree removed"
[ -f "$repo/a.txt" ] && ok "the main checkout: kept" || bad "main checkout touched"
counts_honest air && ok "air summary counts what was removed" || bad "air summary: $(grep '^air:' "$scratch/out")"

run --air --apply --repo "$repo"
[ "$rc" = 0 ] && ! grep -q '^removed' "$scratch/out" && ok "a second apply is idempotent" \
    || bad "second apply: exit $rc: $(cat "$scratch/out")"

# The integration branch is an argument: unmerged into capture-port, merged into another. Its branch is not merged into
# the main checkout's HEAD, so `git branch -d` refuses it, and it stays.
g branch -q other worktree-agent-unmerged
run --air --apply --repo "$repo" --into other
gone "$wts/unmerged" && ok "--into other: a branch merged there is removed" || bad "--into ignored: $(cat "$scratch/out")"
g rev-parse -q --verify refs/heads/worktree-agent-unmerged >/dev/null && grep -q 'branch kept (git branch -d refused)' "$scratch/out" \
    && ok "a branch git branch -d refuses: kept" || bad "an unmerged branch was deleted"
run --air --repo "$repo" --into no-such-branch
[ "$rc" = 1 ] && ok "a missing integration branch is an error" || bad "missing --into: exit $rc"

# A removal that fails is FAILED, exit 1, and not counted as removed (item 7).
add_wt stuck worktree-agent-stuck && merge worktree-agent-stuck
mkdir -p "$wts/stuck/ro" && echo x >"$wts/stuck/ro/t.txt" && git -C "$wts/stuck" -c user.name=t -c user.email=t@t add -A \
    && git -C "$wts/stuck" -c user.name=t -c user.email=t@t commit -qm ro && merge worktree-agent-stuck && chmod 555 "$wts/stuck/ro"
run --air --apply --repo "$repo"
[ "$rc" = 1 ] && grep -qE '^FAILED .* stuck ' "$scratch/out" && counts_honest air \
    && ok "a failed removal: FAILED, exit 1, not counted" || bad "stuck: exit $rc: $(grep -E 'stuck|^air:' "$scratch/out")"
chmod -R u+w "$wts" 2>/dev/null

# Process use that cannot be read keeps everything, loudly.
add_wt merged2 worktree-agent-merged2 && merge worktree-agent-merged2
mkdir -p "$scratch/badbin" && printf '#!/bin/sh\nexit 1\n' >"$scratch/badbin/lsof" && chmod +x "$scratch/badbin/lsof"
PATH=$scratch/badbin:$PATH run --air --apply --repo "$repo"
[ "$rc" = 1 ] && [ -d "$wts/merged2" ] && ok "air: an unreadable process table keeps all, exit 1" \
    || bad "air with lsof failing: exit $rc, merged2 $([ -d "$wts/merged2" ] && echo kept || echo removed)"

# ---- The build host ----
home=$scratch/home
root=$home/xdict-build
mkdir -p "$root" "$home/xdict-corpus" "$home/XDictE2E" "$home/.cargo" "$home/.cache" "$scratch/outside"
echo keep >"$home/xdict-corpus/c" && echo keep >"$scratch/outside/precious"
mk() { mkdir -p "$root/$1/apps" && echo x >"$root/$1/apps/f"; }
for d in old xdict xdict-land-cargo xdict-land-swift fresh stalebuild cwdbusy argbusy lockref apple-thing inner "we ird" \
    heldopen nested dirtyclone aaa zzz; do
    mk "$d"
done
mkdir -p "$root/xdict.out"
echo s >"$root/old-probe.sh"; echo p >"$root/old-mutants.py"; echo s >"$root/old-ZZ.swift"; echo r >"$root/old.out"
echo b >"$root/fresh.bundle"; echo r >"$root/fresh.out"; echo p >"$root/loose.py"; echo t >"$root/notes.txt"
echo garbage >"$root/junk.bundle"
# Git data (item 4): a clone of the Air's repository is known; a repository with its own commit is not.
git clone -q "$repo" "$root/old-git"
git -C "$repo" bundle create -q "$root/old.bundle" capture-port 2>/dev/null
unknown=$scratch/unknown-repo
git init -q -b main "$unknown" && echo u >"$unknown/u" && git -C "$unknown" add -A \
    && git -C "$unknown" -c user.name=t -c user.email=t@t commit -qm "exists only on the build host"
git clone -q "$unknown" "$root/lonely-git"
git clone -q "$unknown" "$root/nested/repo"
git -C "$unknown" bundle create -q "$root/orphan.bundle" main 2>/dev/null
git clone -q "$repo" "$root/dirtyclone/repo" && echo change >>"$root/dirtyclone/repo/a.txt"
ln -s "$scratch/outside" "$root/evil"
ln -s "$scratch/outside" "$root/inner/out"
mkdir -p "$root/stalebuild/.build" "$root/stalebuild/core/target"
echo n >"$root/stalebuild/.build/new" && echo n >"$root/stalebuild/core/target/new"
fresh "$root/stalebuild/.build/new" "$root/stalebuild/core/target/new" "$root/fresh/apps/new" 2>/dev/null \
    || { echo n >"$root/fresh/apps/new"; fresh "$root/fresh/apps/new"; }
echo n >"$root/newloose.sh" && fresh "$root/newloose.sh"
(cd "$root/cwdbusy/apps" && exec sleep 300) </dev/null >/dev/null 2>&1 &
pids+=($!)
bash -c 'sleep 300; :' "$root/argbusy" </dev/null >/dev/null 2>&1 &
pids+=($!)
# A file held open, cwd elsewhere, no path in the command line (item 3: lsof for open files).
(exec 3<"$root/heldopen/apps/f"; cd /; exec sleep 300) </dev/null >/dev/null 2>&1 &
pids+=($!)
bash -c 'sleep 300; :' "/elsewhere/.claude/worktrees/lockref/apps/apple" </dev/null >/dev/null 2>&1 &
lockpid=$!
pids+=($lockpid)
. Tools/host-lock.sh
echo "$lockpid" >"$(host_lock_file stub-host)"
# The race on the host (item 3): sizing `aaa` puts a process into `zzz`, after zzz was judged and before its removal.
cat >"$scratch/hostbin/du" <<EOF
#!/bin/bash
case "\$*" in *"/aaa") (cd "$root/zzz/apps" && exec sleep 300) </dev/null >/dev/null 2>&1 & echo \$! >>"$scratch/more-pids" ;; esac
exec /usr/bin/du "\$@"
EOF
chmod +x "$scratch/hostbin/du"
sleep 1

run --build-host --repo "$repo"
[ "$rc" = 0 ] && ok "build host dry run exits 0" || bad "build host dry run exit $rc: $(cat "$scratch/out")"
[ -d "$root/old" ] && [ -f "$root/old.bundle" ] && ok "build host dry run deletes nothing" || bad "dry run deleted"
row_is remove old && ok "dry run lists old" || bad "dry run does not list old: $(cat "$scratch/out")"
row_is remove old.out && ok "an entry's .out is listed, with it (item 4)" || bad "old.out not listed"
grep -q 'clean-dev-remote: end' "$scratch/out" && bad "the end marker leaked into the table" || ok "the end marker is not shown"

TRANSPORT="env HOME=$home PATH=$scratch/hostbin:$PATH" run --build-host --apply --repo "$repo"
[ "$rc" = 0 ] && ok "build host apply exits 0" || bad "build host apply exit $rc: $(cat "$scratch/out")"
gone "$root/old" && ok "an old unused copy: removed" || bad "old kept: $(cat "$scratch/out")"
for a in old.bundle old-git old-probe.sh old-mutants.py old-ZZ.swift old.out; do
    gone "$root/$a" && ok "its artifact $a: removed" || bad "artifact $a kept: $(grep -F "$a" "$scratch/out")"
done
[ -d "$root/xdict" ] && [ -d "$root/xdict.out" ] && ok "the main copy and its output: kept" || bad "main copy removed"
[ -d "$root/xdict-land-cargo" ] && [ -d "$root/xdict-land-swift" ] && ok "the landing lanes: kept" || bad "a lane removed"
[ -d "$root/fresh" ] && [ -f "$root/fresh.bundle" ] && [ -f "$root/fresh.out" ] && ok "too new, with its artifacts: kept" \
    || bad "fresh removed"
gone "$root/stalebuild" && ok "new files only under .build/ and target/: removed" || bad "stalebuild kept"
[ -d "$root/cwdbusy" ] && ok "a process's cwd inside: kept" || bad "cwdbusy removed"
[ -d "$root/argbusy" ] && ok "a process naming it: kept" || bad "argbusy removed"
[ -d "$root/heldopen" ] && row_is keep heldopen && ok "a file held open inside: kept" || bad "heldopen removed"
[ -d "$root/lockref" ] && grep -qE '^keep .* lockref .*lock' "$scratch/out" && ok "named by the run lock's holder: kept" \
    || bad "lockref: $(grep lockref "$scratch/out")"
gone "$root/apple-thing" && ok "a folder name inside every checkout (apple, of apps/apple) names no entry" \
    || bad "apple-thing kept by the holder's apps/apple"
[ -d "$root/lonely-git" ] && grep -qE '^keep .* lonely-git .*commits the Air does not know' "$scratch/out" \
    && ok "a clone with a commit the Air lacks: kept (item 4)" || bad "lonely-git: $(grep lonely "$scratch/out")"
[ -d "$root/nested" ] && grep -qE '^keep .* nested .*commits the Air does not know' "$scratch/out" \
    && ok "a copy holding such a repository: kept" || bad "nested: $(grep nested "$scratch/out")"
[ -d "$root/dirtyclone" ] && grep -qE '^keep .* dirtyclone .*uncommitted' "$scratch/out" \
    && ok "a copy holding a repository with uncommitted changes: kept" || bad "dirtyclone: $(grep dirtyclone "$scratch/out")"
[ -f "$root/orphan.bundle" ] && grep -qE '^keep .* orphan.bundle .*does not know' "$scratch/out" \
    && ok "a bundle of commits the Air lacks: kept" || bad "orphan.bundle: $(grep orphan "$scratch/out")"
[ -f "$root/junk.bundle" ] && ok "an unreadable bundle: kept" || bad "junk.bundle removed"
[ -d "$root/zzz" ] && grep -qE '^keep .* zzz .*re-checked before removal' "$scratch/out" \
    && ok "in use by the time of its removal: re-checked and kept (item 3)" || bad "zzz: $(grep zzz "$scratch/out")"
gone "$root/aaa" && ok "its twin, unchanged: removed" || bad "aaa kept"
gone "$root/loose.py" && ok "an old loose script: removed" || bad "loose kept"
[ -f "$root/newloose.sh" ] && ok "a new loose script: kept" || bad "newloose removed"
[ -f "$root/notes.txt" ] && ok "an unknown kind of file: kept" || bad "notes.txt removed"
[ -L "$root/evil" ] && [ -f "$scratch/outside/precious" ] && ok "a symlink out of the root: kept, target intact" \
    || bad "symlink evil followed or removed"
gone "$root/inner" && [ -f "$scratch/outside/precious" ] && ok "a copy holding a symlink out: removed, target intact" \
    || bad "inner: $(ls "$root" | tr '\n' ' ') / $(ls "$scratch/outside")"
[ -d "$root/we ird" ] && ok "an unusual name: kept" || bad "unusual name removed"
[ -f "$home/xdict-corpus/c" ] && [ -d "$home/XDictE2E" ] && [ -d "$home/.cargo" ] && ok "outside the root: untouched" \
    || bad "a protected folder touched"
counts_honest "build host" && ok "build host summary counts what was removed" || bad "host summary: $(grep '^build host:' "$scratch/out")"

run --build-host --apply --repo "$repo"
[ "$rc" = 0 ] && ! grep -q '^removed' "$scratch/out" && ok "a second build-host apply is idempotent" \
    || bad "second apply: exit $rc: $(cat "$scratch/out")"

# A removal that fails: FAILED, exit 1, not counted (item 7).
mk stuck && chmod 555 "$root/stuck/apps"
run --build-host --apply --repo "$repo"
[ "$rc" = 1 ] && grep -qE '^FAILED .* stuck ' "$scratch/out" && counts_honest "build host" \
    && ok "host: a failed removal is FAILED, exit 1, not counted" || bad "host stuck: exit $rc: $(grep -E 'stuck|^build host:' "$scratch/out")"
chmod -R u+w "$root/stuck" && rm -rf "$root/stuck"

# A lock whose holder cannot be read keeps everything it would judge.
mk old3
echo garbage >"$(host_lock_file stub-host)"
run --build-host --apply --repo "$repo"
[ -d "$root/old3" ] && grep -qE "^keep .* old3 .*lock's holder cannot be read" "$scratch/out" \
    && ok "an unreadable lock holder: kept" || bad "old3 with an unreadable lock: $(grep old3 "$scratch/out")"
rm -f "$(host_lock_file stub-host)"

# The script cut short (item 5): nothing runs, no end marker, exit 1. Two cuts: mid-script, and only the last line.
size=$(wc -c <Tools/clean-dev-remote.sh)
printf '#!/bin/bash\nhead -c %s | env HOME=%s "$@"\n' $((size / 2)) "$home" >"$scratch/bin/cut-half"
printf '#!/bin/bash\nsed '"'"'$d'"'"' | env HOME=%s "$@"\n' "$home" >"$scratch/bin/cut-last"
printf '#!/bin/bash\ncat | env HOME=%s "$@"\n' "$home" >"$scratch/bin/whole"
chmod +x "$scratch/bin/cut-half" "$scratch/bin/cut-last" "$scratch/bin/whole"
for cut in cut-half cut-last; do
    TRANSPORT=$scratch/bin/$cut run --build-host --apply --repo "$repo"
    [ "$rc" = 1 ] && [ -d "$root/old3" ] && ok "a stream cut short ($cut): exit 1, nothing removed" \
        || bad "$cut: exit $rc, old3 $([ -d "$root/old3" ] && echo kept || echo removed)"
done
TRANSPORT=$scratch/bin/whole run --build-host --apply --repo "$repo"
[ "$rc" = 0 ] && gone "$root/old3" && ok "the whole stream through the same pipe: runs" || bad "whole: exit $rc: $(cat "$scratch/out")"

# Unreadable process use on the host: nothing removed, exit 1.
mk old2
TRANSPORT="env HOME=$home PATH=$scratch/badbin:$PATH" run --build-host --apply --repo "$repo"
[ "$rc" = 1 ] && [ -d "$root/old2" ] && ok "host: an unreadable process table keeps all, exit 1" \
    || bad "host with lsof failing: exit $rc"

# The root itself a symlink (to anywhere): refused before anything is listed.
mkdir -p "$scratch/home2/elsewhere/victim"
ln -s "$scratch/home2/elsewhere" "$scratch/home2/xdict-build"
TRANSPORT="env HOME=$scratch/home2" run --build-host --apply --repo "$repo"
[ "$rc" = 1 ] && [ -d "$scratch/home2/elsewhere/victim" ] && ok "a symlinked root: refused, exit 1" \
    || bad "symlinked root: exit $rc: $(cat "$scratch/out")"

# rsync -a keeps the source's mtimes: a copy made just now of old files is young by its ctime (item 3). The real clock.
mkdir -p "$scratch/home3/xdict-build" "$scratch/src/apps" && echo y >"$scratch/src/apps/f"
find "$scratch/src" -exec touch -h -t 202601010000 {} +
rsync -a "$scratch/src/" "$scratch/home3/xdict-build/rsynced/"
XDICT_CLEAN_DEV_NOW=$(($(date +%s) + 60)) TRANSPORT="env HOME=$scratch/home3" run --build-host --apply --repo "$repo"
[ -d "$scratch/home3/xdict-build/rsynced" ] && grep -qE '^keep .* rsynced .*modified' "$scratch/out" \
    && ok "an rsync copy of old files made just now: kept by its ctime" || bad "rsynced: $(cat "$scratch/out")"

# The host name (item 6): one starting with '-' is refused before ssh could read it as an option.
printf 'BUILD_HOST = -oBatchMode.yes\n' >"$scratch/local-dash.mk" # plain characters but for the leading '-'
XDICT_CLEAN_DEV_LOCAL_MK=$scratch/local-dash.mk run --build-host --repo "$repo"
[ "$rc" = 1 ] && grep -q 'not a plain host name' "$scratch/out" && ok "a host starting with '-': refused" \
    || bad "dash host: exit $rc: $(cat "$scratch/out")"
help=$(bash "$script" --help)
grep -q -- '--build-host' <<<"$help" && ok "the flag is --build-host, named for its role" || bad "--help has no --build-host"

# Arguments are checked before anything runs.
run --min-age-hours abc
[ "$rc" = 1 ] && ok "a non-numeric age is refused" || bad "age abc: exit $rc"

# The Makefile wires the target and the test. Captured, not piped into grep -q: under pipefail make's SIGPIPE would
# read as "missing".
dry=$(make -n clean-dev 2>/dev/null)
grep -q 'Tools/clean-dev.sh' <<<"$dry" && ok "make clean-dev runs the script" || bad "make clean-dev missing"
dry=$(make -n test-tools BUILD_HOST= 2>/dev/null)
grep -q 'Tools/tests/clean-dev-test.sh' <<<"$dry" && ok "test-tools runs this test" || bad "test-tools does not run clean-dev-test.sh"

[ "$failures" = 0 ] && echo "clean-dev: all passed" || echo "clean-dev: $failures failed"
[ "$failures" = 0 ]
