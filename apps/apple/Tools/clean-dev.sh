#!/bin/bash
# Cleans XDict's two development machines of what agents leave behind. **A dry run by default**: it prints a table of
# what it would remove and what it keeps, with sizes and why; `--apply` removes exactly that list, recomputed in the
# same run. Anything it cannot read is kept.
#
#   Tools/clean-dev.sh [--apply] [--air] [--mbp16] [--into <branch>] [--min-age-hours <n>] [--repo <checkout>]
#
# --air    this Mac: git worktrees under <main checkout>/.claude/worktrees. One is removed when its HEAD is an
#          ancestor of --into (default capture-port) or of main, `git status` is clean (untracked files count, ignored
#          ones do not), no process has its cwd or a file in it (lsof) or names it (pgrep -f), no file outside .build/,
#          target/ and node_modules/ changed within --min-age-hours (default 24), it is not locked and not the main
#          checkout. Removed by `git worktree remove` (never --force), then `git branch -d` of its branch only when that
#          is a worktree-agent-* branch (named branches are kept), then `git worktree prune`.
# --mbp16  the build host (BUILD_HOST in local.mk): ~/xdict-build, by Tools/clean-dev-remote.sh, sent over one ssh.
#          `xdict` and `xdict-land-*` are kept; ~/xdict-corpus, ~/XDictE2E and the toolchains are outside its reach.
#          While the build host's run lock (Tools/host-lock.sh) is held, an entry its holder names is kept; with
#          --apply and the lock free, the lock is taken for the run, so no XDict run starts during it.
# Neither flag: both. Exit 0 done, 1 on any error (nothing is removed from a part whose state could not be read).
#
# For Tools/tests/clean-dev-test.sh: XDICT_CLEAN_DEV_TRANSPORT replaces `ssh <host>` (the remote half then runs here,
# e.g. `env HOME=<scratch>`), XDICT_CLEAN_DEV_LOCAL_MK names the local.mk to read.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
say() { echo "clean-dev: $*" >&2; }
usage() { sed -n '2,21s/^# \{0,1\}//p' "$0"; }

apply=0 do_air=0 do_host=0 into=capture-port age=24 repo=""
while [ $# -gt 0 ]; do
    case $1 in
        --apply) apply=1 ;;
        --air) do_air=1 ;;
        --mbp16) do_host=1 ;;
        --into) [ $# -ge 2 ] || { say "--into needs a branch"; exit 1; }; into=$2; shift ;;
        --min-age-hours) [ $# -ge 2 ] || { say "--min-age-hours needs a number"; exit 1; }; age=$2; shift ;;
        --repo) [ $# -ge 2 ] || { say "--repo needs a path"; exit 1; }; repo=$2; shift ;;
        -h | --help) usage; exit 0 ;;
        *) say "unknown argument: $1"; usage >&2; exit 1 ;;
    esac
    shift
done
case $age in '' | *[!0-9]*) say "--min-age-hours is not a whole number: $age"; exit 1 ;; esac
[ $do_air = 0 ] && [ $do_host = 0 ] && do_air=1 do_host=1
mode=plan
[ $apply = 1 ] && mode=apply
errors=0

human() { awk -v k="$1" 'BEGIN { split("K M G T", u); i = 1; while (k >= 1024 && i < 4) { k /= 1024; i++ }
    printf (k < 10 && i > 1) ? "%.1f%s" : "%d%s", k, u[i] }'; }
row() { printf '%-8s %7s  %-44s %s\n' "$1" "$2" "$3" "$4"; }

# ---- The Air ----
clean_air() {
    local main wroot cutoff opened common
    if [ -n "$repo" ]; then
        common=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
    else
        common=$(git -C "$here" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
    fi
    [ -n "$common" ] || { say "cannot find the repository"; return 1; }
    main=$(cd "$common/.." && pwd -P) || return 1
    git -C "$main" rev-parse -q --verify "refs/heads/$into" >/dev/null \
        || { say "no branch $into to measure merged against"; return 1; }
    local bases=$into
    [ "$into" != main ] && git -C "$main" rev-parse -q --verify refs/heads/main >/dev/null && bases="$into main"
    echo "worktrees under .claude/worktrees on this Mac ($mode; merged into: $bases; age $age h)"
    row ACTION SIZE WORKTREE WHY
    if [ ! -d "$main/.claude/worktrees" ]; then echo "air: no .claude/worktrees"; return 0; fi
    [ -L "$main/.claude/worktrees" ] && { say ".claude/worktrees is a symlink: refused"; return 1; }
    wroot=$(cd "$main/.claude/worktrees" && pwd -P) || return 1
    cutoff=$(date -r $(($(date +%s) - age * 3600)) '+%Y-%m-%d %H:%M:%S') || return 1

    # Every open file and cwd of every process, once; this shell's cwd must be among them, or it was not read.
    cd "$wroot" || return 1
    opened=$(lsof -nP -Fn 2>/dev/null | sed -n 's/^n//p')
    # A here-string, not a pipe: under pipefail `grep -q` closing early made the writer's SIGPIPE read as "not found".
    grep -qxF "$wroot" <<<"$opened" || { say "cannot read open files (lsof): nothing removed on this Mac"; return 1; }

    local paths=() heads=() branches=() flags=() path="" head="" branch="" flag="" line
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

    local i p real name why action kb rem_kb=0 keep_kb=0 rem_n=0 err=0 status hit merged b rc
    for i in "${!paths[@]}"; do
        p=${paths[$i]} name=${p##*/}
        real=$(cd "$p" 2>/dev/null && pwd -P) || real=""
        [ "$real" = "$main" ] && continue
        action=keep why="" kb=0
        if [ "${flags[$i]}" = prunable ] || [ -z "$real" ]; then
            row prune - "$name" "its folder is gone: git worktree prune drops the record"; continue
        fi
        if [ -L "$p" ] || [ "$(dirname "$real")" != "$wroot" ]; then
            row keep - "$p" "outside .claude/worktrees: not handled"; continue
        fi
        kb=$(du -sk "$real" 2>/dev/null | cut -f1); kb=${kb:-0}
        merged=""
        for b in $bases; do
            git -C "$main" merge-base --is-ancestor "${heads[$i]}" "$b" 2>/dev/null; rc=$?
            [ $rc = 0 ] && { merged=$b; break; }
            [ $rc = 1 ] || { merged=error; break; }
        done
        if [ "${flags[$i]}" = locked ]; then why="locked"
        elif [ "$merged" = error ]; then why="cannot read its ancestry"
        elif [ -z "$merged" ]; then why="not merged into $bases (${branches[$i]:-detached})"
        elif ! status=$(git -C "$real" status --porcelain 2>/dev/null); then why="cannot read git status"
        elif [ -n "$status" ]; then why="uncommitted or untracked changes ($(printf '%s\n' "$status" | wc -l | tr -d ' '))"
        elif ! hit=$(find "$real" \( -path "$real/*" \( -name .build -o -name target -o -name node_modules \) \) -prune \
            -o -newermt "$cutoff" -print -quit 2>/dev/null); then why="cannot read its age"
        elif [ -n "$hit" ]; then why="modified in the last $age h"
        elif printf '%s\n' "$opened" | awk -v p="$real" '$0 == p || index($0, p "/") == 1 { f = 1 } END { exit !f }'; then
            why="a process has its cwd or a file in it"
        else
            pgrep -f "$real" >/dev/null; rc=$?
            if [ $rc = 0 ]; then why="named by a running process"
            elif [ $rc != 1 ]; then why="cannot read the process list"
            else action=remove why="merged into $merged, clean, unused for $age h (${branches[$i]:-detached})"; fi
        fi
        if [ $action = remove ]; then
            rem_kb=$((rem_kb + kb)) rem_n=$((rem_n + 1))
            if [ $apply = 1 ]; then
                if git -C "$main" worktree remove "$real" 2>/dev/null; then
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
        else
            keep_kb=$((keep_kb + kb))
        fi
        row "$action" "$(human "$kb")" "$name" "$why"
    done
    if [ $apply = 1 ]; then
        git -C "$main" worktree prune || { say "git worktree prune failed"; err=$((err + 1)); }
    fi
    local verb=removable
    [ $apply = 1 ] && verb=removed
    echo "air: $rem_n $verb ($(human "$rem_kb")); kept $(human "$keep_kb")"
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
    local file pid text kids k cwd
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
        local next=""
        for k in $kids; do
            text="$text"$'\n'"$(ps -o command= -p "$k" 2>/dev/null)"
            next="$next $(pgrep -P "$k" 2>/dev/null)"
        done
        kids=$(echo $next)
    done
    printf 'b64:%s' "$(printf '%s\n%s\n' "$text" "$cwd" | base64 | tr -d '\n')"
}

clean_host() {
    local mk host lockarg
    mk=$(local_mk) || { say "cannot find local.mk"; return 1; }
    host=$(awk -F'=' '{ n = $1; gsub(/[ \t]/, "", n) } n == "BUILD_HOST" { sub(/^[^=]*=[ \t]*/, ""); sub(/[ \t]+$/, ""); print; exit }' \
        "$mk" 2>/dev/null)
    [ -n "$host" ] || { say "no BUILD_HOST in local.mk"; return 1; }
    case $host in *[!A-Za-z0-9._@-]*) say "BUILD_HOST is not a plain host name"; return 1 ;; esac
    . "$here/host-lock.sh"
    if [ $apply = 1 ] && XDICT_HOST_LOCK_WAIT=0 host_lock "$host" clean-dev 2>/dev/null; then
        # Expanded now: $host is this function's local, gone by the time the EXIT trap runs (a plain name, checked above).
        trap "host_unlock '$host'" EXIT
        lockarg=none
    else
        lockarg=$(lock_arg "$host")
    fi
    local transport
    if [ -n "${XDICT_CLEAN_DEV_TRANSPORT:-}" ]; then
        read -r -a transport <<<"$XDICT_CLEAN_DEV_TRANSPORT"
    else
        transport=(ssh -o BatchMode=yes "$host")
    fi
    "${transport[@]}" bash -s -- "$mode" "$age" "$lockarg" <"$here/clean-dev-remote.sh"
}

if [ $do_air = 1 ]; then
    (clean_air) || errors=$((errors + 1))
    [ $do_host = 1 ] && echo
fi
if [ $do_host = 1 ]; then
    clean_host || errors=$((errors + 1))
fi
[ $errors = 0 ] || { say "finished with errors"; exit 1; }
