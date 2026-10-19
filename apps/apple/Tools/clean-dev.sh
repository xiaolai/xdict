#!/bin/bash
# Cleans XDict's two development machines of what agents leave behind. **A dry run by default**: it prints a table of
# what it would remove and what it keeps, with sizes and why; `--apply` removes that list, recomputed in the same run,
# judging each item once more immediately before removing it. Anything it cannot read is kept.
#
#   Tools/clean-dev.sh [--apply] [--air] [--build-host] [--into <branch>] [--min-age-hours <n>] [--repo <checkout>]
#
# --air         this Mac: git worktrees under <main checkout>/.claude/worktrees. One is removed when its HEAD is an
#               ancestor of --into (default capture-port) or of main; no commit in its HEAD's reflog (or its
#               worktree-agent-* branch's) is on no branch, tag or remote; `git status --ignored` shows no change, no
#               untracked file and no ignored file other than build products (.build, target, node_modules,
#               __pycache__, .DS_Store: dev-docs/, AGENTS.md, .env or local.mk are ignored but precious); no process has
#               a file or its cwd in it (lsof) or names it in its command line (ps, fixed text); no file outside the
#               build products has an mtime or ctime within --min-age-hours (default 24); it is not locked and not the
#               main checkout. Removed by `git worktree remove` (never --force), then `git branch -d` of its branch only
#               when that is a worktree-agent-* branch (named branches are kept; a branch git refuses stays), then
#               `git worktree prune`.
# --build-host  BUILD_HOST in local.mk: ~/xdict-build, by Tools/clean-dev-remote.sh, sent over one ssh with every
#               commit this repository reaches (a git clone, copy or bundle there holding any other commit is kept).
#               `xdict` and `xdict-land-*` are kept; ~/xdict-corpus, ~/XDictE2E and the toolchains are outside its
#               reach. While the host's run lock (Tools/host-lock.sh) is held, an entry its holder names is kept; with
#               --apply and the lock free, the lock is taken for the run, so no XDict run starts during it.
# Neither flag: both. Exit 0 done, 1 on any error (nothing is removed from a part whose state could not be read).
#
# For Tools/tests/clean-dev-test.sh: XDICT_CLEAN_DEV_TRANSPORT replaces `ssh -- <host>` (the remote half then runs
# here, e.g. `env HOME=<scratch>`), XDICT_CLEAN_DEV_LOCAL_MK names the local.mk to read, XDICT_CLEAN_DEV_NOW the clock
# (epoch seconds; a ctime cannot be set back, so the tests move the clock forward instead).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
say() { echo "clean-dev: $*" >&2; }
usage() { sed -n '2,29s/^# \{0,1\}//p' "$0"; }

apply=0 do_air=0 do_host=0 into=capture-port age=24 repo=""
while [ $# -gt 0 ]; do
    case $1 in
        --apply) apply=1 ;;
        --air) do_air=1 ;;
        --build-host) do_host=1 ;;
        --into) [ $# -ge 2 ] || { say "--into needs a branch"; exit 1; }; into=$2; shift ;;
        --min-age-hours) [ $# -ge 2 ] || { say "--min-age-hours needs a number"; exit 1; }; age=$2; shift ;;
        --repo) [ $# -ge 2 ] || { say "--repo needs a path"; exit 1; }; repo=$2; shift ;;
        -h | --help) usage; exit 0 ;;
        *) say "unknown argument: $1"; usage >&2; exit 1 ;;
    esac
    shift
done
case $age in '' | *[!0-9]*) say "--min-age-hours is not a whole number: $age"; exit 1 ;; esac
now=${XDICT_CLEAN_DEV_NOW:-}
case $now in '' | *[!0-9]*) [ -z "$now" ] || { say "XDICT_CLEAN_DEV_NOW is not a number"; exit 1; } ;; esac
[ $do_air = 0 ] && [ $do_host = 0 ] && do_air=1 do_host=1
mode=plan
[ $apply = 1 ] && mode=apply
errors=0

human() { awk -v k="$1" 'BEGIN { split("K M G T", u); i = 1; while (k >= 1024 && i < 4) { k /= 1024; i++ }
    printf (k < 10 && i > 1) ? "%.1f%s" : "%d%s", k, u[i] }'; }
row() { printf '%-8s %7s  %-44s %s\n' "$1" "$2" "$3" "$4"; }

# find_main: the main checkout of --repo, or of this script's repository.
find_main() {
    local common
    common=$(git -C "${repo:-$here}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
    [ -n "$common" ] || { say "cannot find the repository"; return 1; }
    (cd "$common/.." && pwd -P)
}

# ---- The Air ----

# snapshot: every open file and cwd (lsof) and every command line (ps), read now; our own cwd and pid must be among
# them, or the table was not read.
snapshot() {
    opened=$(lsof -nP -Fn 2>/dev/null | sed -n 's/^n//p')
    # Here-strings, not pipes: under pipefail `grep -q` closing early made the writer's SIGPIPE read as "not found".
    grep -qxF "$PWD" <<<"$opened" || { say "cannot read open files (lsof): nothing removed on this Mac"; return 1; }
    procs=$(ps -axww -o pid=,command= 2>/dev/null)
    awk -v me="$$" '$1 == me { f = 1 } END { exit !f }' <<<"$procs" \
        || { say "cannot read the process list (ps): nothing removed on this Mac"; return 1; }
}

# build_product <ignored path>: 0 when it is a build product, which a worktree may hold and still be removed.
build_product() {
    local p=${1%/}
    case "/$p/" in */.build/* | */target/* | */node_modules/* | */__pycache__/*) return 0 ;; esac
    [ "${p##*/}" = .DS_Store ]
}

# tree_state <worktree>: prints a reason to keep it for what `git status --ignored` shows (nothing: clean).
tree_state() {
    local wt=$1 out e code changes=0 precious=""
    out=$(mktemp) || { echo "cannot read git status"; return; }
    if ! git -C "$wt" status --porcelain=v1 -z --ignored >"$out" 2>/dev/null; then
        rm -f "$out"; echo "cannot read git status"; return
    fi
    while IFS= read -r -d '' e; do
        code=${e:0:2}
        case $code in
            '!!') build_product "${e:3}" || { [ -n "$precious" ] || precious=${e:3}; } ;;
            R* | C*) changes=$((changes + 1)); IFS= read -r -d '' e ;; # a rename carries its old path next
            *) changes=$((changes + 1)) ;;
        esac
    done <"$out"
    rm -f "$out"
    if [ $changes -gt 0 ]; then echo "uncommitted or untracked changes ($changes)"
    elif [ -n "$precious" ]; then echo "ignored files other than build products ($(printf '%q' "$precious"))"
    fi
}

# reflog_state <worktree> <branch>: prints a reason to keep it when a commit its HEAD's reflog (removed with the
# worktree) or its worktree-agent-* branch's reflog (removed with the branch) names is on no branch, tag or remote: a
# commit reset away would otherwise be left dangling, for gc to take.
reflog_state() {
    local wt=$1 b=$2 hs more
    hs=$(git -C "$wt" reflog show --format=%H HEAD 2>/dev/null) || { echo "cannot read its reflog"; return; }
    case $b in
        worktree-agent-*)
            more=$(git -C "$main" reflog show --format=%H "refs/heads/$b" 2>/dev/null) || { echo "cannot read its branch's reflog"; return; }
            hs="$hs"$'\n'"$more" ;;
    esac
    hs=$(grep -xE '[0-9a-f]{40}' <<<"$hs" | sort -u)
    [ -n "$hs" ] || return 0
    # shellcheck disable=SC2086 # one hash per word
    more=$(git -C "$main" rev-list $hs --not --branches --tags --remotes 2>/dev/null) || { echo "cannot read its reflog's commits"; return; }
    [ -z "$more" ] || echo "its reflog holds $(grep -c . <<<"$more") commits on no branch"
}

# air_judge <index>: prints "remove|<why>" or "keep|<why>" for worktree <index>, reading the snapshot.
air_judge() {
    local i=$1 real=${reals[$1]} merged="" b rc why hit
    if [ "${flags[$i]}" = locked ]; then echo "keep|locked"; return; fi
    for b in $bases; do
        git -C "$main" merge-base --is-ancestor "${heads[$i]}" "$b" 2>/dev/null; rc=$?
        [ $rc = 0 ] && { merged=$b; break; }
        [ $rc = 1 ] || { echo "keep|cannot read its ancestry"; return; }
    done
    [ -n "$merged" ] || { echo "keep|not merged into $bases (${branches[$i]:-detached})"; return; }
    why=$(reflog_state "$real" "${branches[$i]}")
    [ -z "$why" ] || { echo "keep|$why"; return; }
    why=$(tree_state "$real")
    [ -z "$why" ] || { echo "keep|$why"; return; }
    hit=$(find "$real" \( -path "$real/*" \( -name .build -o -name target -o -name node_modules \) \) -prune \
        -o \( -newermt "$cutoff" -o -newerct "$cutoff" \) -print -quit 2>/dev/null) || { echo "keep|cannot read its age"; return; }
    [ -z "$hit" ] || { echo "keep|modified in the last $age h"; return; }
    if P=$real awk 'BEGIN { p = ENVIRON["P"] } $0 == p || index($0, p "/") == 1 { f = 1 } END { exit !f }' <<<"$opened"; then
        echo "keep|a process has its cwd or a file in it"; return
    fi
    grep -qF -- "$real" <<<"$procs" && { echo "keep|named by a running process"; return; }
    echo "remove|merged into $merged, clean, unused for $age h (${branches[$i]:-detached})"
}

clean_air() {
    main=$(find_main) || return 1
    git -C "$main" rev-parse -q --verify "refs/heads/$into" >/dev/null \
        || { say "no branch $into to measure merged against"; return 1; }
    bases=$into
    [ "$into" != main ] && git -C "$main" rev-parse -q --verify refs/heads/main >/dev/null && bases="$into main"
    echo "worktrees under .claude/worktrees on this Mac ($mode; merged into: $bases; age $age h)"
    row ACTION SIZE WORKTREE WHY
    if [ ! -d "$main/.claude/worktrees" ]; then echo "air: no .claude/worktrees"; return 0; fi
    [ -L "$main/.claude/worktrees" ] && { say ".claude/worktrees is a symlink: refused"; return 1; }
    local wroot
    wroot=$(cd "$main/.claude/worktrees" && pwd -P) || return 1
    cutoff=$(date -r $((${now:-$(date +%s)} - age * 3600)) '+%Y-%m-%d %H:%M:%S') || return 1
    cd "$wroot" || return 1
    snapshot || return 1

    paths=() heads=() branches=() flags=() reals=()
    local path="" head="" branch="" flag="" line
    while IFS= read -r -d '' line; do
        case $line in
            "worktree "*) path=${line#worktree } head="" branch="" flag="" ;;
            "HEAD "*) head=${line#HEAD } ;;
            "branch refs/heads/"*) branch=${line#branch refs/heads/} ;;
            locked*) flag=locked ;;
            prunable*) flag=prunable ;;
            bare) flag=bare ;;
            "") [ -n "$path" ] && { paths+=("$path"); heads+=("$head"); branches+=("$branch"); flags+=("$flag"); }; path="" ;;
        esac
    done < <(git -C "$main" worktree list --porcelain -z 2>/dev/null; printf '\0')
    [ ${#paths[@]} -gt 0 ] || { say "git worktree list read nothing"; return 1; }

    local i p real name d action why kb rem_kb=0 keep_kb=0 rem_n=0 err=0 b
    for i in "${!paths[@]}"; do
        p=${paths[$i]} name=${p##*/}
        reals[$i]=""
        case $p in *$'\n'* | *$'\r'*)
            row keep - "$(printf '%q' "$name")" "a line break in its name: not handled"; continue ;;
        esac
        real=$(cd "$p" 2>/dev/null && pwd -P) || real=""
        [ "$real" = "$main" ] && continue
        if [ "${flags[$i]}" = prunable ] || [ -z "$real" ]; then
            row prune - "$name" "its folder is gone: git worktree prune drops the record"; continue
        fi
        if [ -L "$p" ] || [ "$(dirname "$real")" != "$wroot" ]; then
            row keep - "$p" "outside .claude/worktrees: not handled"; continue
        fi
        reals[$i]=$real
        kb=$(du -sk "$real" 2>/dev/null | cut -f1); kb=${kb:-0}
        d=$(air_judge "$i")
        action=${d%%|*} why=${d#*|}
        if [ "$action" = remove ] && [ $apply = 1 ]; then
            # Judged again now, from a fresh process table: a worktree may have changed since the table began.
            if ! snapshot; then
                action=FAILED why="the process table could not be read again" err=$((err + 1))
            else
                d=$(air_judge "$i")
                if [ "${d%%|*}" != remove ]; then
                    action=keep why="re-checked before removal: ${d#*|}"
                elif git -C "$main" worktree remove "$real" 2>/dev/null; then
                    action=removed
                    b=${branches[$i]}
                    case $b in
                        worktree-agent-*)
                            git -C "$main" branch -q -d -- "$b" 2>/dev/null && why="$why; branch deleted" \
                                || why="$why; branch kept (git branch -d refused)" ;;
                        "") ;;
                        *) why="$why; branch kept (named)" ;;
                    esac
                else
                    action=FAILED why="git worktree remove refused" err=$((err + 1))
                fi
            fi
        fi
        case $action in
            remove | removed) rem_kb=$((rem_kb + kb)) rem_n=$((rem_n + 1)) ;;
            keep) keep_kb=$((keep_kb + kb)) ;;
        esac
        row "$action" "$(human "$kb")" "$name" "$why"
    done
    if [ $apply = 1 ]; then
        git -C "$main" worktree prune || { say "git worktree prune failed"; err=$((err + 1)); }
    fi
    local verb=removable
    [ $apply = 1 ] && verb=removed
    echo "air: $rem_n $verb ($(human "$rem_kb")); kept $(human "$keep_kb"); $err failed"
    [ $err = 0 ]
}

# ---- The build host ----
local_mk() {
    if [ -n "${XDICT_CLEAN_DEV_LOCAL_MK:-}" ]; then printf '%s' "$XDICT_CLEAN_DEV_LOCAL_MK"; return; fi
    local common
    common=$(git -C "$here" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
    printf '%s/local.mk' "$(cd "$common/.." && pwd -P)"
}

# lock_arg <host>: none, unreadable, or b64:<the holder's and its children's command lines and cwd>.
lock_arg() {
    local file pid text kids k cwd next
    file=$(host_lock_file "$1")
    [ -e "$file" ] || { echo none; return; }
    pid=$(cat "$file" 2>/dev/null) || { echo unreadable; return; }
    case $pid in '' | *[!0-9]*) echo unreadable; return ;; esac
    ps -p "$pid" >/dev/null 2>&1 || { echo none; return; } # a dead holder's lock is taken over by shlock
    text=$(ps -o command= -p "$pid" 2>/dev/null) || { echo unreadable; return; }
    [ -n "$text" ] || { echo unreadable; return; }
    cwd=$(lsof -nP -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')
    kids=$(pgrep -P "$pid" 2>/dev/null)
    while [ -n "$kids" ]; do
        next=""
        for k in $kids; do
            text="$text"$'\n'"$(ps -o command= -p "$k" 2>/dev/null)"
            next="$next $(pgrep -P "$k" 2>/dev/null)"
        done
        kids=$(echo $next)
    done
    printf 'b64:%s' "$(printf '%s\n%s\n' "$text" "$cwd" | base64 | tr -d '\n')"
}

clean_host() {
    local mk host lockarg main known out rc
    mk=$(local_mk) || { say "cannot find local.mk"; return 1; }
    host=$(awk -F'=' '{ n = $1; gsub(/[ \t]/, "", n) } n == "BUILD_HOST" { sub(/^[^=]*=[ \t]*/, ""); sub(/[ \t]+$/, ""); print; exit }' \
        "$mk" 2>/dev/null)
    [ -n "$host" ] || { say "no BUILD_HOST in local.mk"; return 1; }
    case $host in -* | *[!A-Za-z0-9._@-]*) say "BUILD_HOST is not a plain host name"; return 1 ;; esac
    main=$(find_main) || return 1
    known=$(git -C "$main" rev-list --all --reflog 2>/dev/null) && [ -n "$known" ] \
        || { say "cannot list this repository's commits"; return 1; }
    . "$here/host-lock.sh"
    # Read first, taken only when free: shlock may take over a lock file it cannot read as stale, which would turn an
    # unreadable holder (keep everything) into a free lock.
    lockarg=$(lock_arg "$host")
    if [ $apply = 1 ] && [ "$lockarg" = none ]; then
        if XDICT_HOST_LOCK_WAIT=0 host_lock "$host" clean-dev 2>/dev/null; then
            # Expanded now: $host is this function's local, gone when the EXIT trap runs (a plain name, checked above).
            trap "host_unlock '$host'" EXIT
        else
            lockarg=$(lock_arg "$host") # taken in between by another run
        fi
    fi
    local transport
    if [ -n "${XDICT_CLEAN_DEV_TRANSPORT:-}" ]; then
        read -r -a transport <<<"$XDICT_CLEAN_DEV_TRANSPORT"
    else
        transport=(ssh -o BatchMode=yes -- "$host")
    fi
    # The script, then the commits as a here-document (hex lines only), then the call as the very last line.
    out=$({
        cat "$here/clean-dev-remote.sh"
        printf "known_commits() {\ncat <<'XDICT_KNOWN_COMMITS'\n"
        printf '%s\n' "$known"
        printf 'XDICT_KNOWN_COMMITS\n}\nmain "$@"\n'
    } | "${transport[@]}" bash -s -- "$mode" "$age" "$lockarg" "${now:--}")
    rc=$?
    printf '%s\n' "$out" | grep -v '^clean-dev-remote: end '
    [ $rc = 0 ] || { say "the build host's part failed (exit $rc)"; return 1; }
    [ "$(printf '%s\n' "$out" | tail -1)" = "clean-dev-remote: end $mode" ] \
        || { say "the build host's part did not finish (no end marker): its output is incomplete"; return 1; }
}

if [ $do_air = 1 ]; then
    (clean_air) || errors=$((errors + 1))
    [ $do_host = 1 ] && echo
fi
if [ $do_host = 1 ]; then
    clean_host || errors=$((errors + 1))
fi
[ $errors = 0 ] || { say "finished with errors"; exit 1; }
