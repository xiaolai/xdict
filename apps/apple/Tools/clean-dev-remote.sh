#!/bin/bash
# The build host's half of Tools/clean-dev.sh, sent there on ssh's stdin (`bash -s -- <args>`) and never kept there:
# it lists ~/xdict-build, says what is removable and why, and with `apply` removes exactly that list, recomputed in
# this same run. Every argument is from a safe alphabet (a word, digits, base64), so the remote shell's quoting is moot.
#
#   bash -s -- <plan|apply> <min-age-hours> <none|unreadable|b64:<holder text>>
#
# The third argument is the Air's run lock (Tools/host-lock.sh) for this host: free, unreadable (keep everything), or
# the command lines and cwd of the run holding it (an entry they name is kept).
#
# An entry (a folder of ~/xdict-build) is removable when it is not `xdict` (the main copy) nor `xdict-land-*` (the
# landing lanes), holds no file newer than the age outside .build/, target/ and node_modules/, no process's command
# line names it nor has its cwd inside it, and the lock's holder does not name it. Its artifacts (`<entry>.bundle`,
# `<entry>.out`, `<entry>-git/`, `<entry>-*.sh|py|swift`) go with it; loose `*.sh|py|swift|bundle` files by the same
# rules. A symlink, an unusual name or an unknown kind of file is kept. Unreadable state keeps everything: a process
# table that cannot be read is an error (exit 1) with nothing removed.
set -uo pipefail
say() { echo "clean-dev (build host): $*" >&2; }
[ $# = 3 ] || { say "usage: <plan|apply> <min-age-hours> <lock>"; exit 1; }
mode=$1 age=$2 lockarg=$3
case $mode in plan | apply) ;; *) say "unknown mode"; exit 1 ;; esac
case $age in '' | *[!0-9]*) say "the age is not a whole number of hours"; exit 1 ;; esac

root=$HOME/xdict-build
[ -d "$root" ] && [ ! -L "$root" ] || { say "~/xdict-build is missing or a symlink: refused"; exit 1; }
home_real=$(cd "$HOME" && pwd -P) && real=$(cd "$root" && pwd -P) || { say "cannot resolve ~/xdict-build"; exit 1; }
[ "$real" = "$home_real/xdict-build" ] || { say "~/xdict-build resolves outside the home folder: refused"; exit 1; }
cd "$real" || exit 1

case $lockarg in
    none) lock_state=free lock_text="" ;;
    unreadable) lock_state=unreadable lock_text="" ;;
    b64:*)
        lock_state=held
        lock_text=$(printf '%s' "${lockarg#b64:}" | base64 -d 2>/dev/null) || lock_state=unreadable ;;
    *) say "unknown lock argument"; exit 1 ;;
esac

cutoff=$(date -r $(($(date +%s) - age * 3600)) '+%Y-%m-%d %H:%M:%S') || exit 1

# Every process's cwd, once. Our own (this folder) must be among them, or the table was not read.
cwds=$(lsof -nP -a -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')
# A here-string, not a pipe: under pipefail `grep -q` closing early makes the writer's SIGPIPE read as "not found".
grep -qxF "$real" <<<"$cwds" || { say "cannot read the processes' working folders (lsof): nothing removed"; exit 1; }

valid_name() { case $1 in '' | . | .. | .* | *[!A-Za-z0-9._-]*) return 1 ;; esac; }

# in_use <name>: 0 in use, 1 not, 2 unknown.
in_use() {
    local p=$real/$1 rc
    printf '%s\n' "$cwds" | awk -v p="$p" '$0 == p || index($0, p "/") == 1 { f = 1 } END { exit !f }' && return 0
    pgrep -f "xdict-build/$1" >/dev/null
    rc=$?
    case $rc in 0) return 0 ;; 1) return 1 ;; *) return 2 ;; esac
}

# young <name>: 0 a file newer than the cutoff (build products aside), 1 none, 2 unknown.
young() {
    local p=$real/$1 hit
    hit=$(find "$p" \( -path "$p/*" \( -name .build -o -name target -o -name node_modules \) \) -prune \
        -o -newermt "$cutoff" -print -quit 2>/dev/null) || return 2
    [ -n "$hit" ]
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

# judge <name> <what>: prints "remove|<why>" or "keep|<why>" from age, use and the lock.
judge() {
    local n=$1 what=$2 r
    young "$n"; r=$?
    [ $r = 2 ] && { echo "keep|cannot read its age"; return; }
    [ $r = 0 ] && { echo "keep|modified in the last $age h"; return; }
    in_use "$n"; r=$?
    [ $r = 2 ] && { echo "keep|cannot read its process use"; return; }
    [ $r = 0 ] && { echo "keep|in use by a process"; return; }
    [ "$lock_state" = unreadable ] && { echo "keep|the run lock's holder cannot be read"; return; }
    lock_names "$n" && { echo "keep|named by the run holding the lock"; return; }
    echo "remove|$what"
}

names=()
for p in "$real"/* "$real"/.[!.]* "$real"/..?*; do
    [ -e "$p" ] || [ -L "$p" ] || continue
    names+=("${p##*/}")
done
dirs=" "
for n in ${names[@]+"${names[@]}"}; do
    valid_name "$n" && [ -d "$n" ] && [ ! -L "$n" ] && dirs="$dirs$n "
done
is_dir() { case $dirs in *" $1 "*) return 0 ;; esac; return 1; }
# owner <name>: the entry (longest) this name is an artifact of, or nothing.
owner() {
    local n=$1 e best=""
    for e in $dirs; do
        [ "$e" = "$n" ] && continue
        case $n in
            "$e.bundle" | "$e.out" | "$e-git" | "$e"-*.sh | "$e"-*.py | "$e"-*.swift) [ ${#e} -gt ${#best} ] && best=$e ;;
        esac
    done
    # Only a `-git` folder is an artifact folder; any other folder is an entry of its own.
    if [ -n "$best" ] && is_dir "$n" && [ "$n" != "$best-git" ] && [ "$n" != "$best.out" ] && [ "$n" != "$best.bundle" ]; then
        best=""
    fi
    printf '%s' "$best"
}

rows=() # action|name|why, entries first
entry_action=" "
for n in ${names[@]+"${names[@]}"}; do
    valid_name "$n" && is_dir "$n" && [ -z "$(owner "$n")" ] || continue
    case $n in
        xdict) d="keep|the main copy" ;;
        xdict-land-*) d="keep|a landing lane" ;;
        *) d=$(judge "$n" "a copy unused for $age h") ;;
    esac
    rows+=("${d%%|*}|$n|${d#*|}")
    entry_action="$entry_action$n=${d%%|*} "
done
for n in ${names[@]+"${names[@]}"}; do
    if ! valid_name "$n"; then rows+=("keep|$n|an unusual name, not handled"); continue; fi
    if [ -L "$n" ]; then rows+=("keep|$n|a symlink: never followed or removed"); continue; fi
    is_dir "$n" && [ -z "$(owner "$n")" ] && continue
    o=$(owner "$n")
    if [ -n "$o" ]; then
        case $entry_action in
            *" $o=remove "*) d=$(judge "$n" "an artifact of $o") ;;
            *) d="keep|an artifact of $o, which is kept" ;;
        esac
    elif [ -f "$n" ]; then
        case $n in
            *.sh | *.py | *.swift | *.bundle) d=$(judge "$n" "a loose script or bundle") ;;
            *) d="keep|not a known artifact" ;;
        esac
    else
        d="keep|not a known artifact"
    fi
    rows+=("${d%%|*}|$n|${d#*|}")
done

human() { awk -v k="$1" 'BEGIN { split("K M G T", u); i = 1; while (k >= 1024 && i < 4) { k /= 1024; i++ }
    printf (k < 10 && i > 1) ? "%.1f%s" : "%d%s", k, u[i] }'; }
size_kb() { local s; s=$(du -sk "$real/$1" 2>/dev/null | cut -f1); echo "${s:-0}"; }

errors=0 rem_kb=0 keep_kb=0 rem_n=0
echo "~/xdict-build on the build host ($mode; age $age h)"
printf '%-8s %7s  %-44s %s\n' ACTION SIZE NAME WHY
for r in ${rows[@]+"${rows[@]}"}; do
    action=${r%%|*} rest=${r#*|}
    n=${rest%%|*} why=${rest#*|}
    if valid_name "$n"; then kb=$(size_kb "$n"); else kb=$(du -sk -- "$real/$n" 2>/dev/null | cut -f1); kb=${kb:-0}; fi
    if [ "$action" = remove ]; then
        rem_kb=$((rem_kb + kb)) rem_n=$((rem_n + 1))
        if [ "$mode" = apply ]; then
            # Exactly this child of the root: a plain name, not a symlink, its parent the resolved root.
            if valid_name "$n" && [ ! -L "$real/$n" ] && [ "$(cd "$real" && pwd -P)" = "$home_real/xdict-build" ]; then
                rm -rf -- "${real:?}/$n"
                if [ -e "$real/$n" ] || [ -L "$real/$n" ]; then action=FAILED errors=$((errors + 1)); else action=removed; fi
            else
                action=REFUSED errors=$((errors + 1))
            fi
        fi
    else
        keep_kb=$((keep_kb + kb))
    fi
    printf '%-8s %7s  %-44s %s\n' "$action" "$(human "$kb")" "$n" "$why"
done
verb=removable
[ "$mode" = apply ] && verb=removed
echo "build host: $rem_n $verb ($(human "$rem_kb")); kept $(human "$keep_kb")"
[ "$errors" = 0 ] || { say "$errors removals failed"; exit 1; }
