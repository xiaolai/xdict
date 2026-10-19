#!/bin/bash
# The build host's half of Tools/clean-dev.sh, sent there on ssh's stdin (`bash -s -- <args>`) and never kept there:
# it lists ~/xdict-build, says what is removable and why, and with `apply` removes that list, recomputed in this same
# run, judging each item once more immediately before removing it. Every argument is from a safe alphabet (a word,
# digits, base64), so the remote shell's quoting is moot.
#
#   bash -s -- <plan|apply> <min-age-hours> <none|unreadable|b64:<holder text>> <now: epoch seconds, or ->
#
# This file defines `main` and runs nothing. The Air sends it followed by `known_commits` (a here-document of every
# commit its repository reaches, refs and reflogs) and, as the very last line, the call `main "$@"`. A stream cut short
# therefore runs nothing; main's last output line is the end marker the Air requires (a run cut short mid-way lacks it).
#
# The third argument is the Air's run lock (Tools/host-lock.sh) for this host: free, unreadable (keep everything), or
# the command lines and cwd of the run holding it (an entry they name is kept). The fourth is the clock, for the tests.
#
# An entry (a folder of ~/xdict-build) is removable when it is not `xdict` (the main copy) nor `xdict-land-*` (the
# landing lanes); no file in it outside .build/, target/ and node_modules/ has an mtime or ctime within the age (rsync
# -a keeps the source's mtimes; the ctime says when the copy was made); no process has a file or its cwd in it or names
# it in its command line (fixed text, not a pattern); the lock's holder does not name it; and every git repository in
# it (a .git folder, or the folder itself when bare) holds only commits the Air knows and no uncommitted change. Its
# artifacts (`<entry>.bundle`, `<entry>.out`, `<entry>-git/`, `<entry>-*.sh|py|swift`) go with it, each judged by the
# same rules (a bundle's heads must be known to the Air); loose `*.sh|py|swift|bundle` files likewise. A symlink, an
# unusual name or an unknown kind of file is kept. Unreadable state keeps: an unreadable process table is an error
# (exit 1) with nothing removed, and an unreadable age, process use or git state keeps that item.
set -uo pipefail
say() { echo "clean-dev (build host): $*" >&2; }

main() {
    [ $# = 4 ] || { say "usage: <plan|apply> <min-age-hours> <lock> <now>"; return 1; }
    local mode=$1 age=$2 lockarg=$3 now=$4
    case $mode in plan | apply) ;; *) say "unknown mode"; return 1 ;; esac
    case $age in '' | *[!0-9]*) say "the age is not a whole number of hours"; return 1 ;; esac
    [ "$now" = - ] && now=$(date +%s)
    case $now in '' | *[!0-9]*) say "the clock is not a number"; return 1 ;; esac
    declare -F known_commits >/dev/null || { say "the Air's commits were not sent"; return 1; }

    root=$HOME/xdict-build
    [ -d "$root" ] && [ ! -L "$root" ] || { say "~/xdict-build is missing or a symlink: refused"; return 1; }
    home_real=$(cd "$HOME" && pwd -P) && real=$(cd "$root" && pwd -P) || { say "cannot resolve ~/xdict-build"; return 1; }
    [ "$real" = "$home_real/xdict-build" ] || { say "~/xdict-build resolves outside the home folder: refused"; return 1; }
    cd "$real" || return 1

    case $lockarg in
        none) lock_state=free lock_text="" ;;
        unreadable) lock_state=unreadable lock_text="" ;;
        b64:*)
            lock_state=held
            lock_text=$(printf '%s' "${lockarg#b64:}" | base64 -d 2>/dev/null) || lock_state=unreadable ;;
        *) say "unknown lock argument"; return 1 ;;
    esac
    cutoff=$(date -r $((now - age * 3600)) '+%Y-%m-%d %H:%M:%S') || return 1
    known=$(known_commits | grep -xE '[0-9a-f]{40}' | sort -u)
    [ -n "$known" ] || { say "the Air's commit list is empty"; return 1; }
    snapshot || return 1

    names=()
    local p n
    for p in "$real"/* "$real"/.[!.]* "$real"/..?*; do
        [ -e "$p" ] || [ -L "$p" ] || continue
        names+=("${p##*/}")
    done
    dirs=" "
    for n in ${names[@]+"${names[@]}"}; do
        valid_name "$n" && [ -d "$n" ] && [ ! -L "$n" ] && dirs="$dirs$n "
    done

    local rows=() d o
    for n in ${names[@]+"${names[@]}"}; do
        valid_name "$n" && is_dir "$n" && [ -z "$(owner "$n")" ] || continue
        d=$(entry_judgement "$n")
        rows+=("$d")
        entry_actions="$entry_actions$n=${d%%|*} "
    done
    for n in ${names[@]+"${names[@]}"}; do
        if ! valid_name "$n"; then rows+=("keep|$(printf '%q' "$n")|an unusual name, not handled"); continue; fi
        if [ -L "$n" ]; then rows+=("keep|$n|a symlink: never followed or removed"); continue; fi
        is_dir "$n" && [ -z "$(owner "$n")" ] && continue
        rows+=("$(item_judgement "$n")")
    done

    local errors=0 rem_kb=0 keep_kb=0 rem_n=0 r action rest why kb removed=" "
    echo "~/xdict-build on the build host ($mode; age $age h)"
    printf '%-8s %7s  %-44s %s\n' ACTION SIZE NAME WHY
    for r in ${rows[@]+"${rows[@]}"}; do
        action=${r%%|*} rest=${r#*|}
        n=${rest%%|*} why=${rest#*|}
        kb=0
        if valid_name "$n"; then kb=$(du -sk "$real/$n" 2>/dev/null | cut -f1); kb=${kb:-0}; fi
        if [ "$action" = remove ] && [ "$mode" = apply ]; then
            # An artifact goes only once its entry is gone (the entry may have been kept on its own re-check).
            o=$(owner "$n")
            if [ -n "$o" ]; then
                case $removed in *" $o "*) ;; *) action=keep why="its entry $o was kept" ;; esac
            fi
            if [ "$action" = remove ]; then
                # Judged again now, from a fresh process table: an item may have changed since the table began.
                if ! snapshot; then
                    action=FAILED why="the process table could not be read again" errors=$((errors + 1))
                else
                    if [ -n "$o" ]; then d=$(judge "$n" "an artifact of $o")
                    elif is_dir "$n"; then d=$(entry_judgement "$n"); d=${d%%|*}"|"${d#*|*|}
                    else d=$(item_judgement "$n"); d=${d%%|*}"|"${d#*|*|}; fi
                    if [ "${d%%|*}" != remove ]; then
                        action=keep why="re-checked before removal: ${d#*|}"
                    elif valid_name "$n" && [ ! -L "$real/$n" ] && [ "$(cd "$real" && pwd -P)" = "$home_real/xdict-build" ]; then
                        # Exactly this child of the root: a plain name, not a symlink, its parent the resolved root.
                        rm -rf -- "${real:?}/$n"
                        if [ -e "$real/$n" ] || [ -L "$real/$n" ]; then
                            action=FAILED errors=$((errors + 1))
                        else
                            action=removed removed="$removed$n "
                        fi
                    else
                        action=REFUSED errors=$((errors + 1))
                    fi
                fi
            fi
        fi
        case $action in
            remove | removed) rem_kb=$((rem_kb + kb)) rem_n=$((rem_n + 1)) ;;
            keep) keep_kb=$((keep_kb + kb)) ;;
        esac
        printf '%-8s %7s  %-44s %s\n' "$action" "$(human "$kb")" "$n" "$why"
    done
    local verb=removable
    [ "$mode" = apply ] && verb=removed
    echo "build host: $rem_n $verb ($(human "$rem_kb")); kept $(human "$keep_kb"); $errors failed"
    [ "$errors" = 0 ] || { say "$errors removals failed"; return 1; }
    echo "clean-dev-remote: end $mode"
}

# Every entry's judgement, as " <name>=<action> " words, for its artifacts to follow (set by main).
entry_actions=" "

valid_name() { case $1 in '' | . | .. | .* | *[!A-Za-z0-9._-]*) return 1 ;; esac; }
is_dir() { case $dirs in *" $1 "*) return 0 ;; esac; return 1; }

# snapshot: every open file and cwd (lsof) and every command line (ps), read now. Our own cwd and pid must be among
# them, or the table was not read.
snapshot() {
    opened=$(lsof -nP -Fn 2>/dev/null | sed -n 's/^n//p')
    # Here-strings, not pipes: under pipefail `grep -q` closing early makes the writer's SIGPIPE read as "not found".
    grep -qxF "$real" <<<"$opened" || { say "cannot read the processes' open files (lsof): nothing removed"; return 1; }
    procs=$(ps -axww -o pid=,command= 2>/dev/null)
    awk -v me=$$ '$1 == me { f = 1 } END { exit !f }' <<<"$procs" \
        || { say "cannot read the process list (ps): nothing removed"; return 1; }
}

# owner <name>: the entry (longest) this name is an artifact of, or nothing.
owner() {
    local n=$1 e best=""
    for e in $dirs; do
        [ "$e" = "$n" ] && continue
        case $n in
            "$e.bundle" | "$e.out" | "$e-git" | "$e"-*.sh | "$e"-*.py | "$e"-*.swift) [ ${#e} -gt ${#best} ] && best=$e ;;
        esac
    done
    # Only a `-git`, `.out` or `.bundle` folder is an artifact folder; any other folder is an entry of its own.
    if [ -n "$best" ] && is_dir "$n" && [ "$n" != "$best-git" ] && [ "$n" != "$best.out" ] && [ "$n" != "$best.bundle" ]; then
        best=""
    fi
    printf '%s' "$best"
}

# in_use <name>: 0 when a process has a file or its cwd in it, or names it in its command line (fixed text).
in_use() {
    P=$real/$1 awk 'BEGIN { p = ENVIRON["P"] } $0 == p || index($0, p "/") == 1 { f = 1 } END { exit !f }' <<<"$opened" \
        && return 0
    grep -qF -- "xdict-build/$1" <<<"$procs"
}

# young <name>: 0 a file (build products aside) with an mtime or ctime newer than the cutoff, 1 none, 2 unknown.
young() {
    local p=$real/$1 hit
    hit=$(find "$p" \( -path "$p/*" \( -name .build -o -name target -o -name node_modules \) \) -prune \
        -o \( -newermt "$cutoff" -o -newerct "$cutoff" \) -print -quit 2>/dev/null) || return 2
    [ -n "$hit" ]
}

# unknown_to_air <commit...> on stdin: prints how many are not among the Air's commits.
unknown_to_air() { sort -u | comm -23 - <(printf '%s\n' "$known") | grep -c .; }

# git_state <name>: prints a reason to keep it for its git data (nothing: no unique data), status 2 when unreadable.
git_state() {
    local p=$real/$1 g c dirty list
    if [ -f "$p" ]; then
        case $1 in *.bundle) ;; *) return 0 ;; esac
        list=$(git bundle list-heads "$p" 2>/dev/null | awk '{ print $1 }') || { echo "cannot read the bundle"; return 2; }
        [ -n "$list" ] || { echo "cannot read the bundle"; return 2; }
        c=$(unknown_to_air <<<"$list")
        [ "$c" = 0 ] || echo "a bundle with $c heads the Air does not know"
        return 0
    fi
    list=$(find "$p" \( -path "$p/*" \( -name .build -o -name target -o -name node_modules \) \) -prune \
        -o -name .git -type d -print 2>/dev/null) || { echo "cannot search it for git repositories"; return 2; }
    [ -f "$p/HEAD" ] && [ -d "$p/objects" ] && list="$list"$'\n'"$p"
    while IFS= read -r g; do
        [ -n "$g" ] || continue
        c=$(git --git-dir="$g" rev-list --all --reflog 2>/dev/null) || { echo "cannot read the git repository ${g#"$real"/}"; return 2; }
        c=$(unknown_to_air <<<"$c")
        [ "$c" = 0 ] || { echo "${g#"$real"/} holds $c commits the Air does not know"; return 0; }
        if [ "${g##*/}" = .git ]; then
            dirty=$(git --git-dir="$g" --work-tree="${g%/.git}" status --porcelain 2>/dev/null) \
                || { echo "cannot read git status of ${g#"$real"/}"; return 2; }
            [ -z "$dirty" ] || { echo "${g#"$real"/} has uncommitted changes"; return 0; }
        fi
    done <<<"$list"
    return 0
}

# lock_names <name>: 0 when the lock's holder names it (a word of its command lines or cwd is the name, or the name
# begins with "<word>-" or ends with "-<word>", as land's lanes and the lab's copy are named after a checkout). The
# folder names inside every checkout are not words here: a holder's cwd is usually apps/apple, and `apple` once kept
# every apple-* copy while any run held the lock.
lock_names() {
    local n=$1 w
    [ "$lock_state" = held ] || return 1
    for w in $(printf '%s\n' "$lock_text" | tr -c 'A-Za-z0-9._-' '\n' | awk 'length($0) >= 3' \
        | grep -vxE 'apps|apple|Tools|tests|gallery|ui-tour|hostile|core|worktrees|bash|make|python3'); do
        case $n in "$w" | "$w"-* | *-"$w") return 0 ;; esac
    done
    return 1
}

# judge <name> <what>: prints "remove|<why>" or "keep|<why>" from age, use, the lock and git data.
judge() {
    local n=$1 what=$2 r g
    young "$n"; r=$?
    [ $r = 2 ] && { echo "keep|cannot read its age"; return; }
    [ $r = 0 ] && { echo "keep|modified in the last $age h"; return; }
    in_use "$n" && { echo "keep|in use by a process"; return; }
    [ "$lock_state" = unreadable ] && { echo "keep|the run lock's holder cannot be read"; return; }
    lock_names "$n" && { echo "keep|named by the run holding the lock"; return; }
    g=$(git_state "$n")
    [ -n "$g" ] && { echo "keep|$g"; return; }
    echo "remove|$what"
}

# entry_judgement <name>: "<action>|<name>|<why>" of an entry.
entry_judgement() {
    local n=$1 d
    case $n in
        xdict) d="keep|the main copy" ;;
        xdict-land-*) d="keep|a landing lane" ;;
        *) d=$(judge "$n" "a copy unused for $age h") ;;
    esac
    echo "${d%%|*}|$n|${d#*|}"
}

# item_judgement <name>: "<action>|<name>|<why>" of an artifact (only with a removable entry) or a loose file.
item_judgement() {
    local n=$1 o d
    o=$(owner "$n")
    if [ -n "$o" ]; then
        if [[ $entry_actions == *" $o=remove "* ]]; then d=$(judge "$n" "an artifact of $o"); else d="keep|an artifact of $o, which is kept"; fi
    elif [ -f "$n" ]; then
        case $n in
            *.sh | *.py | *.swift | *.bundle) d=$(judge "$n" "a loose script or bundle") ;;
            *) d="keep|not a known artifact" ;;
        esac
    else
        d="keep|not a known artifact"
    fi
    echo "${d%%|*}|$n|${d#*|}"
}

human() { awk -v k="$1" 'BEGIN { split("K M G T", u); i = 1; while (k >= 1024 && i < 4) { k /= 1024; i++ }
    printf (k < 10 && i > 1) ? "%.1f%s" : "%d%s", k, u[i] }'; }
