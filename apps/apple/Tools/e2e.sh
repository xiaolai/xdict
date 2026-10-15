#!/bin/bash
# End-to-end tests, on the E2E Mac — never on the machine that builds. They run the published bundle there as a reader
# would: started by LaunchServices in the logged-in GUI session, answering through its sandboxed XPC service.
#
#   e2e.sh <ssh-host> [name...]    ship .build/XDict.app to ~/XDictE2E on the host and run the sub-stages the names ask
#                                  for there: a sub-stage (`hostile.production`), a stage (`hostile`: its default
#                                  sub-stages), `all` (the extra ones too); none named, every default sub-stage
#   e2e.sh --list-stages           the default sub-stages, one per line: what `Tools/e2e-status.sh require-fresh` requires
#
# **The sub-stages and the checks each owns are listed once, in `Tools/e2e-substages.txt`** (read by `Tools/e2e-plan.sh`),
# in the order they run, cheapest first. Each is its own row of evidence, with its time; a check is recorded under the
# sub-stage that owns it, whichever launch reported it, and a sub-stage that never reported one of its checks fails.
#
# Adapted from XiaolaiDict's `Tools/e2e.sh` (its ADR-0024): the host guard, the run lock, the parse of the remote
# scripts before anything ships, the GUI-session launcher (`open -n`, whose own answer is kept), the exact-path process
# helpers, cleanup that runs however a run ends and is itself recorded, and the recorder. Not carried: its stages, its
# reads of the study ledger, its stage-input inventory, its predecessor's flags and the public-DCS fallback
# (plan-macos-v1, the extraction table).
#
# Environment:
#   XDICT_E2E_TREE   the source tree `make e2e` read before it built the bundle (`Tools/source-tree.sh`). The run keeps
#                    it only where the tree is unchanged when the run starts and when it ends; otherwise, and when run
#                    by hand, the rows are filed with no tree and are no release's evidence. With it, a bundle, kit,
#                    sample or editions already made of this tree (and, for the bundle and kit, already on the E2E Mac)
#                    is not made or copied again
#   XDICT_E2E_ONLY   checks, comma separated (names from `Tools/e2e-substages.txt`): only the sub-stages that own them,
#                    and inside them only what reports them where the instrument can be asked for less (the service's
#                    `--checks`, the library's launches, the lookup window's paging). Other checks a launch reports are
#                    shown, not recorded. A run with it records nothing
#   XDICT_E2E_FAILFAST
#                    1: stop at the first sub-stage that failed; the rest are not run, so not recorded
#   XDICT_E2E_EXPECTED_VERSIONS
#                    a positive control: a JSON file of versions the `launch` stage expects instead of the bundle's own
#                    (`Contents/Resources/CoreVersions.json`), to show a wrong expectation failing. A run with it
#                    records nothing
#   XDICT_E2E_SSH    the program that reaches the host, `ssh` unless set. The host guard's positive control sets it to
#                    `Tools/tests/ssh-to-this-mac`, which runs the remote side here
#   XDICT_E2E_CORPUS the owner's 25 dictionaries (`../dictionary-collection/corpus`), for `entries.*`, `library.corpus`,
#                    `library.control`, `lookup.*` and `sound.recordings`: their folders are copied to the E2E Mac (never
#                    into the repository); `entries_corpus`'s sample of them is rendered there, the library registers
#                    them against the editions `index_bench` computes here, the lookup window reads LDOCE's internal
#                    keys, and the sound window clicks recordings of every format in the sample's entries. Unset,
#                    those checks fail as not measured: a green run without it measured nothing
#
# Replaced, and refused if set: XDICT_E2E_SERVICE_CHECKS (now XDICT_E2E_ONLY with check names) and
# XDICT_E2E_LIBRARY_NO_RELINK (now the `library.control` sub-stage, run with the others).
set -euo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
readonly SELF
cd "$(dirname "$SELF")/.."
readonly PLAN=Tools/e2e-plan.sh

if [ "${1:-}" = --list-stages ]; then
    bash "$PLAN" substages
    exit 0
fi

fail() { echo "e2e: FAIL: $*" >&2; exit 1; }
section() { echo; echo "== $*"; }
host=${1:?usage: e2e.sh <ssh-host> [name...] | --list-stages}
shift
# **Validated here, before anything is sent**: `ssh host cmd a b` hands the arguments to a remote shell, which parses
# them again, so a name carrying `;` would run there as a command.
case "$*" in *[!a-z0-9.\ ]*) fail "a stage or sub-stage name is lower-case words and dots; got '$*'" ;; esac
[ -z "${XDICT_E2E_SERVICE_CHECKS:-}" ] || fail "XDICT_E2E_SERVICE_CHECKS is replaced by XDICT_E2E_ONLY=<check>[,<check>]"
[ -z "${XDICT_E2E_LIBRARY_NO_RELINK:-}" ] || fail "XDICT_E2E_LIBRARY_NO_RELINK is replaced by the library.control sub-stage"
only=${XDICT_E2E_ONLY:-}
case $only in *[!A-Za-z0-9.,]*) fail "XDICT_E2E_ONLY is check names and commas; got '$only'" ;; esac
failfast=0
case ${XDICT_E2E_FAILFAST:-} in "" | 0) ;; 1) failfast=1 ;; *) fail "XDICT_E2E_FAILFAST is 1 or unset" ;; esac
# shellcheck disable=SC2068 # names, validated above, split on purpose
SUBSTAGES=$(bash "$PLAN" expand $@) || fail "see above: the names are Tools/e2e-substages.txt's"
if [ -n "$only" ]; then
    owners=$(bash "$PLAN" only "$only") || fail "see above: XDICT_E2E_ONLY names checks of Tools/e2e-substages.txt"
    [ $# -eq 0 ] || owners=$(grep -xF -f <(printf '%s\n' "$SUBSTAGES") <<<"$owners" || true)
    [ -n "$owners" ] || fail "XDICT_E2E_ONLY names no check of the sub-stages asked for"
    SUBSTAGES=$owners
fi
SUBSTAGES=$(tr '\n' ' ' <<<"$SUBSTAGES")
# shellcheck disable=SC2086 # sub-stage names, split on purpose
NEEDS=" $(bash "$PLAN" needs $SUBSTAGES | tr '\n' ' ') "
needs() { case $NEEDS in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
readonly APP=.build/XDict.app
readonly REMOTE_DIR=XDictE2E
readonly SSH=${XDICT_E2E_SSH:-ssh}
[ -d "$APP" ] || fail "$APP does not exist; run make app"
on_host() { "$SSH" -o BatchMode=yes -o ConnectTimeout=15 "$host" "$@"; }
to_host() { rsync -a -e "$SSH -o BatchMode=yes -o ConnectTimeout=15" "$@"; }

# **One run at a time against a host**: two runs share the remote installation and would quit each other's app
# mid-assertion. shlock's pid file, because macOS has no flock(1); a lock left by a killed run is taken over.
RUN_LOCK="${TMPDIR:-/tmp}/xdict-e2e-$(printf '%s' "$host" | tr -c 'A-Za-z0-9' '_').lock"
readonly RUN_LOCK
/usr/bin/shlock -f "$RUN_LOCK" -p $$ || fail "another e2e run is already using $host (lock: $RUN_LOCK)"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"; rm -f "$RUN_LOCK"' EXIT

# ---------------------------------------------------------------------------------------------------------------------
# **The remote scripts are parsed here, before anything is shipped.** They are quoted heredocs, which `bash -n` on this
# file skips, so nothing would read them until the far machine did. Zero found means the marker changed.
awk -v dir="$scratch" '
    /<<'"'"'SH'"'"'/ { inside = 1; n++; file = dir "/remote-" n ".sh"; next }
    inside && /^SH$/ { inside = 0; close(file); next }
    inside { print > file }
' "$SELF"
checked=0
for script in "$scratch"/remote-*.sh; do
    [ -f "$script" ] || continue
    bash -n "$script" 2>"$scratch/why" || fail "the remote script $(basename "$script") does not parse: $(cat "$scratch/why")"
    checked=$((checked + 1))
done
[ "$checked" -gt 0 ] || fail "found no remote scripts to check — the heredoc marker has changed"
rm -f "$scratch"/remote-*.sh "$scratch/why"

# ---------------------------------------------------------------------------------------------------------------------
# **What both remote sessions share, written once**: quitting the installed copy and running the stages are two SSH
# sessions, and two copies of one function had drifted in XiaolaiDict.
cat >"$scratch/common.sh" <<'SH'
# Sets PIDS to the processes started from exactly the executable path $1: by the executable `ps` reports, so arguments
# LaunchServices adds cannot hide one; by string equality, never a pattern or a name. **Not a `$(…)` function**: a `ps`
# that fails must stop the run, and inside a command substitution `exit` would stop only the subshell, leaving an empty
# answer that reads as "nothing is running".
find_pids() {
    local table pid executable
    table=$(ps -axww -o pid=,comm=) || { echo "ps failed, so whether $1 is running cannot be told" >&2; exit 1; }
    PIDS=()
    while read -r pid executable; do
        [ "$executable" != "$1" ] || PIDS+=("$pid")
    done <<<"$table"
}

is_running() { find_pids "$1"; [ "${#PIDS[@]}" -gt 0 ]; }

# Every process of this bundle ended: TERM, five seconds, KILL, two more, then an answer.
quit_bundle() {
    local executable
    for executable in "$exe" "$service"; do
        find_pids "$executable"
        [ "${#PIDS[@]}" -eq 0 ] || kill -TERM "${PIDS[@]}" 2>/dev/null || true
    done
    for executable in "$exe" "$service"; do
        for _ in $(seq 1 50); do is_running "$executable" || continue 2; sleep 0.1; done
        find_pids "$executable"
        [ "${#PIDS[@]}" -eq 0 ] || kill -KILL "${PIDS[@]}" 2>/dev/null || true
        for _ in $(seq 1 20); do is_running "$executable" || continue 2; sleep 0.1; done
        echo "still running after TERM and KILL: $executable" >&2
        return 1
    done
}
SH

# ---------------------------------------------------------------------------------------------------------------------
section "machine"
# **The whole point is a second machine. Refuse this one, whatever the SSH name resolves to** — by hardware UUID, which
# no alias, address or VPN route can make two Macs share.
local_uuid=$(ioreg -rd1 -c IOPlatformExpertDevice | awk -F'"' '/IOPlatformUUID/{print $4}')
[ -n "$local_uuid" ] || fail "this Mac reported no hardware UUID, so it cannot be told from the E2E Mac"
remote=$(on_host bash -s <<'SH'
uuid=$(ioreg -rd1 -c IOPlatformExpertDevice | awk -F'"' '/IOPlatformUUID/{print $4}')
printf '%s|%s|%s|%s\n' "$uuid" "$(sysctl -n hw.model)" "$(sw_vers -productVersion)" "$(sw_vers -buildVersion)"
SH
) || fail "cannot reach $host"
IFS='|' read -r remote_uuid remote_model remote_os remote_build <<<"$remote"
[ -n "$remote_uuid" ] || fail "$host reported no hardware UUID"
[ "$remote_uuid" != "$local_uuid" ] \
    || fail "$host is this Mac: end-to-end tests run on the E2E Mac, never on the one that builds"
e2e_os="$remote_os ($remote_build)"
echo "$remote_model, macOS $e2e_os"

# The source tree, held to what it was when the bundle was built: an edit made since is in no bundle this run tests.
source_tree=${XDICT_E2E_TREE:--}
if [ "$source_tree" != - ] && [ "$source_tree" != "$(Tools/source-tree.sh)" ]; then
    echo "the source tree moved since the bundle was built; this run's rows carry no tree"
    source_tree=-
fi
expected_override=${XDICT_E2E_EXPECTED_VERSIONS:-}
[ -z "$expected_override" ] || [ -s "$expected_override" ] || fail "XDICT_E2E_EXPECTED_VERSIONS names no file: $expected_override"
echo "sub-stages: $SUBSTAGES${only:+(only $only)}"
[ "$NEEDS" = "  " ] || echo "they need:$NEEDS"

# made_of <marker>: whether the thing the marker stands beside was made of this very source tree. Never with no tree.
made_of() { [ "$source_tree" != - ] && [ "$(cat "$1" 2>/dev/null)" = "$source_tree" ]; }

# ---------------------------------------------------------------------------------------------------------------------
section "install"
cat "$scratch/common.sh" - <<'SH' | on_host bash -s -- "$REMOTE_DIR" || fail "could not quit the running E2E copy"
set -euo pipefail
app="$HOME/$1/XDict.app"; exe="$app/Contents/MacOS/XDict"
service="$app/Contents/XPCServices/ai.xdict.app.DictionaryService.xpc/Contents/MacOS/XDictService"
quit_bundle
SH
local_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
# **The bundle is copied only when the E2E Mac does not already have it**: the same build number, and the same source
# tree on both sides (the build Mac's from `make e2e`, beside the bundle; the E2E Mac's written after the last copy).
there=$(on_host "mkdir -p '$REMOTE_DIR' && rm -f '$REMOTE_DIR/expected-versions.json' '$REMOTE_DIR/library-editions.json' \
    '$REMOTE_DIR/only' && { /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' '$REMOTE_DIR/XDict.app/Contents/Info.plist' \
    2>/dev/null || echo -; } && { cat '$REMOTE_DIR/XDict.app.source-tree' 2>/dev/null || echo -; }" | tr '\n' ' ') \
    || fail "could not reach $REMOTE_DIR on $host"
read -r there_version there_tree <<<"$there"
if made_of "$APP.source-tree" && [ "$there_version" = "$local_version" ] && [ "$there_tree" = "$source_tree" ]; then
    echo "the E2E Mac already has build $local_version of this tree; not copied"
else
    on_host "rm -f '$REMOTE_DIR/XDict.app.source-tree'" || fail "could not clear the bundle's tree there"
    to_host --delete "$APP" "$host:$REMOTE_DIR/" || fail "could not copy the bundle"
    if made_of "$APP.source-tree"; then
        printf '%s\n' "$source_tree" | on_host "cat > '$REMOTE_DIR/XDict.app.source-tree'" || fail "could not mark the bundle's tree"
    fi
fi
if [ -n "$expected_override" ]; then
    to_host "$expected_override" "$host:$REMOTE_DIR/expected-versions.json" || fail "could not copy the expected versions"
fi
remote_version=$(on_host "/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' '$REMOTE_DIR/XDict.app/Contents/Info.plist'")
[ "$local_version" = "$remote_version" ] || fail "shipped build $local_version, found $remote_version"
case $remote_version in
    *.*) build_mode=development ;;
    *) build_mode=release ;;
esac
on_host "codesign --verify --strict --deep '$REMOTE_DIR/XDict.app'" || fail "the shipped bundle does not verify there"
# The plan the remote side runs by: each check's sub-stage (`Tools/e2e-plan.sh table`), and the checks asked for.
bash "$PLAN" table | on_host "cat > '$REMOTE_DIR/plan.tsv'" || fail "could not copy the plan"
printf '%s\n' "$only" | tr ',' '\n' | on_host "cat > '$REMOTE_DIR/only'" || fail "could not copy the checks asked for"
# **The fixtures are written here, by the core's own MDX writer, and shipped with the bundle**: no dictionary content
# enters the repository or reaches the E2E Mac from anywhere else (Tools/build-fixtures.sh).
if needs fixtures; then
    Tools/build-fixtures.sh "$scratch/fixtures" >/dev/null || fail "could not write the fixtures"
    to_host --delete "$scratch/fixtures/" "$host:$REMOTE_DIR/fixtures/" || fail "could not copy the fixtures"
    echo "fixtures written and copied"
fi
echo "build $remote_version ($build_mode) installed and verified"

# **The entry view's kit**, for the sub-stages that use it (plan-macos-v1 WI-4): built here, shipped beside the bundle,
# never inside it; neither again when this tree's kit is already here and there.
if needs kit; then
    section "kit"
    if made_of .build/e2e-kit.source-tree && [ -d .build/e2e-kit ]; then
        echo "the kit of this tree is built already"
    else
        rm -f .build/e2e-kit.source-tree
        Tools/build-lab.sh || fail "the entry view's kit could not be built"
        [ "$source_tree" = - ] || printf '%s\n' "$source_tree" >.build/e2e-kit.source-tree
    fi
    if made_of .build/e2e-kit.source-tree \
        && [ "$(on_host "cat '$REMOTE_DIR/kit.source-tree' 2>/dev/null || true")" = "$source_tree" ]; then
        echo "the E2E Mac has this tree's kit; not copied"
    else
        on_host "rm -f '$REMOTE_DIR/kit.source-tree'" || fail "could not clear the kit's tree there"
        to_host --delete --exclude entries-sample.json .build/e2e-kit/ "$host:$REMOTE_DIR/kit/" || fail "could not copy the kit"
        on_host "codesign --verify --strict '$REMOTE_DIR/kit/XDictEntryLab.app'" || fail "the shipped lab does not verify there"
        if made_of .build/e2e-kit.source-tree; then
            printf '%s\n' "$source_tree" | on_host "cat > '$REMOTE_DIR/kit.source-tree'" || fail "could not mark the kit's tree"
        fi
    fi
fi

# **The real dictionaries**: `entries_corpus`'s own sample of them (the bindings cannot enumerate a file's keys), the
# editions `index_bench import-all` computes for them (what the library must register), and their folders copied beside
# the bundle. The sample and the editions are kept here per source tree. An unset corpus ships nothing, and the
# sub-stages that need it say not measured.
if { needs corpus || needs sample || needs editions; } && [ -n "${XDICT_E2E_CORPUS:-}" ]; then
    section "corpus"
    [ -d "$XDICT_E2E_CORPUS" ] || fail "XDICT_E2E_CORPUS is not a folder: $XDICT_E2E_CORPUS"
    corpus=$(cd "$XDICT_E2E_CORPUS" && pwd)
    if needs sample; then
        sample=$(pwd)/.build/entries-sample.json
        if made_of "$sample.source-tree" && [ "$(cat "$sample.corpus" 2>/dev/null)" = "$corpus" ] && [ -s "$sample" ]; then
            echo "entries_corpus's sample of this tree is made already"
        else
            rm -f "$sample.source-tree"
            (cd ../../core && XDICT_MDX_CORPUS="$corpus" XDICT_ENTRIES_SAMPLE_OUT="$sample" \
                cargo test -q --release -p xdict-core --test entries_corpus -- --nocapture >"$scratch/entries-corpus.log" 2>&1) \
                || fail "entries_corpus failed, so its sample is not one: $(tail -3 "$scratch/entries-corpus.log")"
            [ -s "$sample" ] || fail "entries_corpus wrote no sample"
            printf '%s\n' "$corpus" >"$sample.corpus"
            [ "$source_tree" = - ] || printf '%s\n' "$source_tree" >"$sample.source-tree"
        fi
        on_host "mkdir -p '$REMOTE_DIR/kit'" && to_host "$sample" "$host:$REMOTE_DIR/kit/entries-sample.json" \
            || fail "could not copy the sample"
        echo "$(python3 -I -c 'import json, sys; print(len(json.load(open(sys.argv[1]))))' "$sample") sampled entries"
    fi
    if needs editions; then
        editions=$(pwd)/.build/library-editions.json
        if made_of "$editions.source-tree" && [ "$(cat "$editions.corpus" 2>/dev/null)" = "$corpus" ] && [ -s "$editions" ]; then
            echo "index_bench's editions of this tree are computed already"
        else
            rm -f "$editions.source-tree"
            (cd ../../core && cargo run -q --release -p xdict-core --example index_bench -- import-all "$scratch/bench" "$corpus" \
                >"$scratch/index-bench.log" 2>&1) || fail "index_bench import-all failed: $(tail -3 "$scratch/index-bench.log")"
            python3 -I Tools/library/editions.py "$scratch/bench/data/registry.json" "$corpus" >"$editions" \
                || fail "index_bench's registry gave no edition for every dictionary"
            printf '%s\n' "$corpus" >"$editions.corpus"
            [ "$source_tree" = - ] || printf '%s\n' "$source_tree" >"$editions.source-tree"
            echo "index_bench: $(tail -1 "$scratch/index-bench.log")"
        fi
        to_host "$editions" "$host:$REMOTE_DIR/library-editions.json" || fail "could not copy the editions"
        echo "$(python3 -I -c 'import json, sys; print(len(json.load(open(sys.argv[1]))))' "$editions") editions from index_bench"
    fi
    folders=()
    for folder in "$corpus"/*/; do
        name=$(basename "$folder")
        case $name in _*) continue ;; esac
        folders+=("${folder%/}")   # no trailing slash: rsync copies the folder, not its contents
    done
    [ "${#folders[@]}" -gt 0 ] || fail "no dictionary folder in $corpus"
    echo "${#folders[@]} dictionaries"
    to_host --delete "${folders[@]}" "$host:$REMOTE_DIR/corpus/" || fail "could not copy the corpus"
fi

# ---------------------------------------------------------------------------------------------------------------------
section "run: $SUBSTAGES"
cat "$scratch/common.sh" - >"$scratch/run.sh" <<'SH'
set -euo pipefail
home="$HOME/$1"; failfast=$2; shift 2
app="$home/XDict.app"; exe="$app/Contents/MacOS/XDict"
service="$app/Contents/XPCServices/ai.xdict.app.DictionaryService.xpc/Contents/MacOS/XDictService"
expected="$app/Contents/Resources/CoreVersions.json"
[ ! -s "$home/expected-versions.json" ] || expected="$home/expected-versions.json"
WANTED=("$@")
[ ${#WANTED[@]} -gt 0 ] || { echo "no sub-stage was asked for"; exit 1; }
# Each check's sub-stage, `Tools/e2e-plan.sh table`: sub-stage, default|extra, needs, group, check.
plan="$home/plan.tsv"
[ -s "$plan" ] || { echo "no plan at $plan"; exit 1; }
ONLY=" $(tr '\n' ' ' <"$home/only" 2>/dev/null || true) "
case $ONLY in *[!\ ]*) only_set=true ;; *) only_set=false ;; esac
failures=0

selected() { local w; for w in "${WANTED[@]}"; do [ "$w" = "$1" ] && return 0; done; return 1; }
owner_of() { awk -F'\t' -v c="$1" '$5 == c { print $1; exit }' "$plan"; }
checks_of() { awk -F'\t' -v s="$1" '$1 == s { print $5 }' "$plan"; }
group_of() { awk -F'\t' -v s="$1" '$1 == s { print $4; exit }' "$plan"; }
# check_asked <check>: whether XDICT_E2E_ONLY leaves it in (it does, when unset).
check_asked() { [ "$only_set" = false ] || case $ONLY in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
# asked <sub-stage>: run, and at least one of its checks asked for.
asked() {
    local check
    selected "$1" || return 1
    for check in $(checks_of "$1"); do check_asked "$check" && return 0; done
    return 1
}

# **Until a sub-stage claims it, what runs is setup**, and setup is a name the record can hold.
STAGE=setup
REPORTED=" "
# record pass|fail <check> <text>: one assertion. RESULT lines are for the recorder, PASS and FAIL lines for a person.
# **A check is recorded under the sub-stage that owns it** (the plan), not the one whose launch reported it; one owned by
# a sub-stage not run, or left out by XDICT_E2E_ONLY, is shown and not counted. `-` is an assertion with no check of its
# own (an instrument that wrote nothing), counted against the sub-stage running; so is a name the plan does not list.
record() {
    local verdict=$1 check=$2 owner=$STAGE word=PASS
    shift 2
    [ "$verdict" = pass ] || word=FAIL
    if [ "$check" != - ]; then
        owner=$(owner_of "$check")
        if [ -z "$owner" ]; then
            owner=$STAGE
            check_asked "$check" || { echo "      (not asked) $word  $*"; return 0; }
        elif ! selected "$owner" || ! check_asked "$check"; then
            echo "      (not asked: $owner) $word  $*"
            return 0
        fi
        REPORTED="$REPORTED$owner:$check "
    fi
    echo "$word  $*"
    [ "$verdict" = pass ] || failures=$((failures + 1))
    printf 'RESULT\t%s\t%s\t%s\n' "$owner" "$verdict" "$check"
}
pass() { record pass "$@"; }
flunk() { record fail "$@"; }
# A sub-stage that never reported one of its checks (that were asked for) fails, by name.
require_reported() {
    local sub=$1 check
    STAGE=$sub
    for check in $(checks_of "$sub"); do
        check_asked "$check" || continue
        case $REPORTED in *" $sub:$check "*) ;; *) flunk - "$sub: $check was never reported" ;; esac
    done
}

# **A stage that dies part-way is a failed stage, and says where it died**: `set -e` ends the script silently at the
# first unguarded failure, and a per-stage record would read the checks never reached as no failures.
set -E
finished=false
died_at=""
trap 'died_at=$LINENO' ERR
# Cleanup a stage needs however the run ends, registered and run in reverse order; one that fails is recorded, never
# swallowed, and does not stop the others.
cleanups=()
at_exit() { cleanups+=("$1"); }
on_exit() {
    local i
    for (( i = ${#cleanups[@]} - 1; i >= 0; i-- )); do
        "${cleanups[$i]}" || {
            echo "FAIL  cleanup: ${cleanups[$i]} did not finish, so this Mac may be left changed"
            failures=$((failures + 1))
            printf 'RESULT\tcleanup\tfail\n'
        }
    done
    printf 'RESULT\tcleanup\tpass\n'
    if [ "$finished" != true ]; then
        echo "FAIL  $STAGE: the script stopped at line ${died_at:-?} before the stage finished"
        printf 'RESULT\t%s\tfail\n' "$STAGE"
    fi
    [ "$failures" -eq 0 ] || exit 1
}
trap on_exit EXIT

# This run's reports: a directory of its own, readable by this user alone (a fixed name in /tmp follows a symlink).
reports=$(mktemp -d /tmp/xdict-e2e.XXXXXX)
chmod 700 "$reports"
drop_reports() { rm -rf "$reports"; }
at_exit drop_reports
at_exit quit_bundle

parent_of() { ps -o ppid= -p "$1" 2>/dev/null | tr -d ' '; }

# wait_for_process <executable> <tenths>: sets PIDS once it runs; returns 1 if it never did.
wait_for_process() {
    local _
    for _ in $(seq 1 "$2"); do is_running "$1" && return 0; sleep 0.1; done
    return 1
}

# launch_app: the app started through LaunchServices in the logged-in GUI session, as a reader starts it. `open`'s own
# status and words are kept: a refused launch once read as lost data (XiaolaiDict). Refused for a copy already running,
# where `open` would only bring it forward and a launch could not be told from none.
launch_app() {
    local said status=0
    if is_running "$exe"; then echo "XDict is already running (pid ${PIDS[*]}), so starting it would start nothing"; return 1; fi
    said=$(open -n "$app" 2>&1) || status=$?
    [ "$status" -eq 0 ] || { echo "LaunchServices would not start it: open exited $status${said:+ — $said}"; return 1; }
    wait_for_process "$exe" 100 || { echo "open exited 0 and no XDict process appeared within 10 s${said:+ ($said)}"; return 1; }
}

# report <flag> <seconds> [argument...]: an instrument started by LaunchServices like the app (`open -n --args`), its
# JSON on stdout once it has written and exited; nothing, and status 1, if it wrote nothing in time.
report() {
    local flag=$1 budget=$2 name=${1#--} waited=0
    shift 2
    local out="$reports/$name.json" err="$reports/$name.err"
    rm -f "$out" "$err"
    open -n --stdout "$out" --stderr "$err" "$app" --args "$flag" "$@" || return 1
    while [ ! -s "$out" ] && [ "$waited" -lt $((budget * 10)) ]; do sleep 0.1; waited=$((waited + 1)); done
    [ -s "$out" ] || return 1
    cat "$out"
}

# The entry view's lab (`Tools/build-lab.sh`), started by LaunchServices like the app; never left running.
kit="$home/kit"
lab="$kit/XDictEntryLab.app"; lab_exe="$lab/Contents/MacOS/XDictEntryLab"
quit_lab() {
    find_pids "$lab_exe"
    [ "${#PIDS[@]}" -eq 0 ] || kill -KILL "${PIDS[@]}" 2>/dev/null || true
    return 0
}
at_exit quit_lab
# lab_report <out> <seconds> <arguments…>: the lab's JSON report once it has written it, or status 1.
lab_report() {
    local out=$1 budget=$2 waited=0
    shift 2
    rm -f "$out"
    if is_running "$lab_exe"; then echo "a lab is already running"; return 1; fi
    open -n --stdout "$out.out" --stderr "$out.err" "$lab" --args "$@" --out "$out" || return 1
    while [ ! -s "$out" ] && [ "$waited" -lt $((budget * 10)) ]; do sleep 0.1; waited=$((waited + 1)); done
    for _ in $(seq 1 50); do is_running "$lab_exe" || break; sleep 0.1; done
    quit_lab
    [ -s "$out" ]
}
# verdicts <check> <file>: each PASS or FAIL line of an analysis, as that check's assertions; none at all is a FAIL.
verdicts() {
    local check=$1 file=$2 line seen=0
    while IFS= read -r line; do
        case $line in
            "PASS  "*) pass "$check" "$check: ${line#PASS  }"; seen=$((seen + 1)) ;;
            "FAIL  "*) flunk "$check" "$check: ${line#FAIL  }"; seen=$((seen + 1)) ;;
        esac
    done <"$file"
    [ "$seen" -gt 0 ] || flunk "$check" "$check: the analysis gave no verdict ($(head -c 300 "$file"))"
}
# findings <file>: each check of an instrument's report (`Findings`) as an assertion of the sub-stage that owns it. One
# that never came is caught by `require_reported`, by name.
findings() {
    local file=$1 count i name passed detail
    count=$(plutil -extract checks raw -o - "$file" 2>/dev/null || echo 0)
    [ "$count" -gt 0 ] || flunk - "$STAGE: the instrument reported no check: $(head -c 300 "$file")"
    for (( i = 0; i < count; i++ )); do
        name=$(plutil -extract "checks.$i.name" raw -o - "$file")
        passed=$(plutil -extract "checks.$i.pass" raw -o - "$file")
        detail=$(plutil -extract "checks.$i.detail" raw -o - "$file")
        if [ "$passed" = true ]; then pass "$name" "$name — ${detail:0:240}"; else flunk "$name" "$name — ${detail:0:900}"; fi
    done
}
# finding <file> <name>: that check's `pass` in an instrument's report (true or false), or nothing if it is not there.
finding() {
    local file=$1 count i
    count=$(plutil -extract checks raw -o - "$file" 2>/dev/null || echo 0)
    for (( i = 0; i < count; i++ )); do
        [ "$(plutil -extract "checks.$i.name" raw -o - "$file")" = "$2" ] || continue
        plutil -extract "checks.$i.pass" raw -o - "$file"
        return 0
    done
}

# app_report <out> <seconds> <arguments…>: an instrument of the app that writes its report to `--out`, started by
# LaunchServices like the app; the report once written, or status 1. The app is never left running.
app_report() {
    local out=$1 budget=$2 waited=0
    shift 2
    rm -f "$out"
    if is_running "$exe"; then echo "XDict is already running"; return 1; fi
    open -n --stdout "$out.out" --stderr "$out.err" "$app" --args "$@" --out "$out" || return 1
    while [ ! -s "$out" ] && [ "$waited" -lt $((budget * 10)) ]; do sleep 0.1; waited=$((waited + 1)); done
    for _ in $(seq 1 50); do is_running "$exe" || break; sleep 0.1; done
    quit_bundle >/dev/null 2>&1 || true
    [ -s "$out" ]
}

# ---------------------------------------------------------------------------------------------------------------------
# **The sub-stages**: `substage_<name, dots as underscores>`, or `substage_<group>` for a group's one launch.

# **launch**: LaunchServices starts the app, its dictionary service answers the handshake through the real XPC path,
# and the versions it answers with are those of the core the bundle was built from.
substage_launch() {
    local why pid parent service_pid answered wanted key json known_as mismatched=""
    if ! why=$(launch_app 2>&1); then
        flunk - "launch: XDict could not be started — $why. The rest of this stage did not run"
        return 0
    fi
    # Read again here: `launch_app` ran in a command substitution, whose PIDS died with it.
    find_pids "$exe"
    pid=${PIDS[0]:-}
    [ -n "$pid" ] || { flunk - "launch: XDict started and was gone before it could be looked at"; return 0; }
    parent=$(parent_of "$pid")
    if [ "$parent" = 1 ]; then pass launch.startedByLaunchServices "launch: started by LaunchServices (pid $pid, its parent launchd)"
    else flunk launch.startedByLaunchServices "launch: pid $pid's parent is ${parent:-unknown}, not launchd: it was not started by LaunchServices"; fi
    # Captured, then matched: `producer | grep -q` fails under pipefail when grep stops reading early.
    known_as=$(lsappinfo info -only bundleid "$pid" 2>&1 || true)
    if grep -q 'bundleID="ai.xdict.app"' <<<"$known_as"; then
        pass launch.knownAsBundle "launch: LaunchServices knows pid $pid as ai.xdict.app"
    else
        flunk launch.knownAsBundle "launch: LaunchServices does not know pid $pid as ai.xdict.app ($(tr -s ' \n' ' ' <<<"$known_as"))"
    fi
    sleep 1
    if is_running "$exe"; then pass launch.stillRunning "launch: still running 1 s after it started"
    else flunk launch.stillRunning "launch: not running 1 s after it started"; fi

    # The app asks its service at launch, so its own service is running now, from this bundle, started by launchd.
    if wait_for_process "$service" 100; then
        service_pid=${PIDS[0]:-}
        parent=$(parent_of "$service_pid")
        if [ "$parent" = 1 ]; then pass launch.serviceFromBundle "launch: the app's dictionary service runs from the bundle (pid $service_pid, started by launchd)"
        else flunk launch.serviceFromBundle "launch: the dictionary service (pid $service_pid) was started by ${parent:-unknown}, not launchd"; fi
    else
        flunk launch.serviceFromBundle "launch: the app started and no dictionary service from this bundle ran within 10 s"
    fi

    # The handshake, asked by the instrument exactly as the app asks it.
    if ! json=$(report --handshake-report 30); then
        flunk launch.handshakeVersions "launch: --handshake-report wrote nothing within 30 s ($(head -c 300 "$reports/handshake-report.err" 2>/dev/null))"
        return 0
    fi
    echo "      handshake: $json"
    if plutil -extract failure raw -o - "$reports/handshake-report.json" >/dev/null 2>&1; then
        flunk launch.handshakeVersions "launch: the handshake failed: $(plutil -extract failure raw -o - "$reports/handshake-report.json")"
        return 0
    fi
    for key in protocol core indexFormat normalization; do
        answered=$(plutil -extract "service.$key" raw -o - "$reports/handshake-report.json" 2>/dev/null || echo "(none)")
        wanted=$(plutil -extract "$key" raw -o - "$expected" 2>/dev/null || echo "(none)")
        [ "$answered" = "$wanted" ] || mismatched="$mismatched $key=$answered (the core's: $wanted)"
    done
    if [ -z "$mismatched" ]; then pass launch.handshakeVersions "launch: the service answered the handshake with the core's versions ($(tr -d '\n' <"$expected"))"
    else flunk launch.handshakeVersions "launch: the service's versions are not the core's:$mismatched"; fi
    # The shipped app's own launch check of the entry view (ADR-0009 decision 7): both WebKit switches turned off and
    # read back off on this Mac's WebKit, with no web view made. Either missing or still on, no entry would render.
    local ready preconnect peer
    ready=$(plutil -extract entryView.ready raw -o - "$reports/handshake-report.json" 2>/dev/null || echo "(none)")
    preconnect=$(plutil -extract entryView.switches.LinkPreconnect raw -o - "$reports/handshake-report.json" 2>/dev/null || echo "(none)")
    peer=$(plutil -extract entryView.switches.PeerConnectionEnabled raw -o - "$reports/handshake-report.json" 2>/dev/null || echo "(none)")
    if [ "$ready" = true ] && [ "$preconnect" = false ] && [ "$peer" = false ]; then
        pass launch.entryViewReady "launch: the app reads LinkPreconnect and PeerConnectionEnabled back off: entries can be shown confined"
    else
        flunk launch.entryViewReady "launch: the app's entry view would refuse (ready $ready, LinkPreconnect $preconnect, PeerConnectionEnabled $peer, $(plutil -extract entryView.refusal raw -o - "$reports/handshake-report.json" 2>/dev/null))"
    fi
    parent=$(plutil -extract parentPid raw -o - "$reports/handshake-report.json" 2>/dev/null || echo "?")
    if [ "$parent" = 1 ]; then pass launch.handshakeParent "launch: the handshake was asked by an XDict started by LaunchServices"
    else flunk launch.handshakeParent "launch: the instrument's parent was $parent, not launchd"; fi

    # And it quits when asked, the service with it.
    kill -TERM "$pid" 2>/dev/null || true
    local gone=no
    for _ in $(seq 1 50); do is_running "$exe" || { gone=yes; break; }; sleep 0.1; done
    if [ "$gone" = yes ]; then pass launch.quitsOnTerm "launch: quits on TERM within 5 s"
    else flunk launch.quitsOnTerm "launch: still running 5 s after TERM"; fi
}

# ---------------------------------------------------------------------------------------------------------------------
# **service.***: this bundle's own signed dictionary service, asked through the app's `ServiceClient` by an instrument
# LaunchServices started (`XDict --service-report`, plan-macos-v1 WI-3), its `--checks` groups split three ways:
# `conformance/`'s `tiny` and `matrix`; the refusals, supersession, a stalled bulk call, `kill -9` mid-lookup, then who
# reaches the service by name and the client requirement it holds every connection to; the idle exit raced.

# bounded <seconds> <command...>: the command's status, or 124 once it has run that long (and it is killed).
bounded() {
    local seconds=$1 child waited=0
    shift
    "$@" &
    child=$!
    while kill -0 "$child" 2>/dev/null; do
        if [ "$waited" -ge $((seconds * 10)) ]; then
            kill -KILL "$child" 2>/dev/null || true
            wait "$child" 2>/dev/null || true
            return 124
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
    wait "$child"
}

# service_group <group> <check-prefix...>: the instrument's `--checks` group, if any check under those prefixes is asked.
service_group() {
    local group=$1 prefix check
    shift
    [ "$only_set" = true ] || { echo "$group"; return 0; }
    for prefix in "$@"; do
        for check in $ONLY; do case $check in "$prefix"*) echo "$group"; return 0 ;; esac; done
    done
}

# service_report <group...>: `--service-report` with those `--checks`, each check it reports recorded.
service_report() {
    local groups file="$reports/service-report.json"
    groups=$(printf '%s\n' "$@" | grep . | paste -sd, - || true)
    [ -n "$groups" ] || return 0
    if ! report --service-report 600 "$home/fixtures" --checks "$groups" >/dev/null; then
        flunk - "$STAGE: --service-report wrote nothing within 600 s ($(head -c 300 "$reports/service-report.err" 2>/dev/null))"
        return 0
    fi
    findings "$file"
    echo "      facts: $(plutil -extract facts json -o - "$file" 2>/dev/null | head -c 1500)"
}

substage_service_conformance() { service_report conformance; }

substage_service_idle() { service_report idle; }

substage_service_recovery() {
    local since
    since=$(date '+%Y-%m-%d %H:%M:%S')
    service_report "$(service_group refusals refusal.)" "$(service_group supersede supersede.lateReply)" \
        "$(service_group drop supersede.queuedNeverSent)" "$(service_group stall stall.)" "$(service_group kill kill.)"

    # **Who reaches the service by name.** The executable in the bundle, run from this shell, does: the control. The same
    # executable copied out of the bundle does not, and starts no service: an embedded XPC service is found in the asking
    # program's own bundle, and the copy has none. The copy is signed ad hoc, because with the bundle's signature outside
    # the bundle AMFI kills it at launch (measured 2026-10-14), which would say nothing about the name.
    local said status before=" " after="" pid outside="$reports/outside/XDict"
    if check_asked service.connect.inside || check_asked service.connect.outside || check_asked service.clientRequirement; then
        status=0; said=$(bounded 30 "$exe" --connect-report 2>&1) || status=$?
        if [ "$status" -eq 0 ] && grep -q '"connected":true' <<<"$said"; then
            pass service.connect.inside "service: the bundle's executable reaches its service by name"
        else
            flunk service.connect.inside "service: the bundle's executable did not reach its service by name (exit $status): ${said:0:300}"
        fi
    fi
    if check_asked service.connect.outside; then
        mkdir -p "$reports/outside"
        cp "$exe" "$outside"
        codesign -s - -f "$outside" >/dev/null 2>&1 || flunk - "service: the copy outside the bundle could not be signed ad hoc"
        find_pids "$service"
        [ "${#PIDS[@]}" -eq 0 ] || before=" ${PIDS[*]} "
        status=0; said=$(bounded 30 "$outside" --connect-report 2>&1) || status=$?
        find_pids "$service"
        if [ "${#PIDS[@]}" -gt 0 ]; then
            for pid in "${PIDS[@]}"; do case $before in *" $pid "*) ;; *) after="$after $pid" ;; esac; done
        fi
        if [ "$status" -eq 1 ] && grep -q '"connected":false' <<<"$said" && [ -z "$after" ]; then
            pass service.connect.outside "service: a copy of the app outside the bundle cannot reach the service by name ($(grep -o '"failure":"[^"]*"' <<<"$said"))"
        else
            flunk service.connect.outside "service: a copy of the app outside the bundle: exit $status, new service processes:${after:- none}; ${said:0:300}"
        fi
    fi

    # **The client requirement.** Each start of the service logs the requirement it holds every connection to, or that it
    # could build none and refuses everyone; this sub-stage started it several times (the kill, the connection above).
    # It must name the app and the team that signed this bundle (read from the bundle's signature, and not printed).
    check_asked service.clientRequirement || return 0
    local team logged required refused
    team=$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')
    logged=$(/usr/bin/log show --start "$since" --style compact \
        --predicate 'subsystem == "ai.xdict.app.DictionaryService" AND category == "service"' 2>&1 || true)
    required=$(grep -cF "client requirement: anchor apple generic and identifier \"ai.xdict.app\" and certificate leaf[subject.OU] = \"$team\"" <<<"$logged" || true)
    refused=$(grep -c "no client requirement could be built" <<<"$logged" || true)
    if [ -n "$team" ] && [ "$required" -gt 0 ] && [ "$refused" -eq 0 ]; then
        pass service.clientRequirement "service: the service set its client requirement, the app's identifier and this bundle's own team, at each of $required starts; none failed to build one"
    else
        # Worded without `${team:-…}`, which printed the team itself whenever one was named, and without an apostrophe
        # inside `${…:+…}`, which bash 3.2 (the E2E Mac's /bin/bash) reads as an opening quote: "bad substitution",
        # and the stage died just as this failure was reported (found 2026-10-15).
        local unsigned=""
        [ -n "$team" ] || unsigned=" (the signature of the bundle names no team)"
        flunk service.clientRequirement "service: the client requirement: ${team:+with the team of this bundle }logged at $required starts, $refused could not build one$unsigned"
    fi
}

# ---------------------------------------------------------------------------------------------------------------------
# **hostile.***: the hostile-input suite through the production entry view (plan-macos-v1 WI-4; ADR-0007 decision 14).
# One observed run per configuration in `cases.json` and the suite's rules (`analyze.py suite`): `production` alone at
# zero on every observer (`hostile.production`); the other seven, each layer alone and none, every observer shown its
# deliberate attempt and each layer's probes leaving with it off and refused with it on (`hostile.controls`, production's
# positive control). Then fail-closed: each WebKit-switch fault refuses with its own sentence and makes no web view,
# beside a control that renders (`hostile.faults`). Then one web view per dictionary: twins with the same paths keep
# their own answers across a held request and a switch (`hostile.binding`). Then the battery through the app's own
# window (`hostile.app`). Results stay on the E2E Mac under results/hostile.
hostile_results="$home/results/hostile"
hostile_prepare() {
    mkdir -p "$hostile_results"
    cp "$kit/cases.json" "$hostile_results/cases.json"
}
# hostile_runs <label...>: those configurations' observed runs.
hostile_runs() {
    local label off
    for label in "$@"; do
        rm -rf "${hostile_results:?}/$label" "$hostile_results/$label.log"
        off=$(python3 -I "$kit/analyze.py" off "$kit/cases.json" "$label")
        if "$kit/run-hostile.sh" "$kit" "$hostile_results" "$label" hostile ${off:+--disable-layer "$off"} \
            >"$hostile_results/$label.log" 2>&1; then
            echo "      $label: $(tail -1 "$hostile_results/$label.log")"
        else
            flunk - "hostile: the $label run did not happen as described — $(tail -2 "$hostile_results/$label.log" | tr '\n' ' ')"
        fi
    done
}
# hostile_suite production|controls: that part's runs, then its rules.
hostile_suite() {
    local part=$1 labels
    hostile_prepare
    labels=$(python3 -I "$kit/analyze.py" runs "$kit/cases.json" | tr ' ' '\n' | grep . \
        | if [ "$part" = production ]; then grep -x production; else grep -vx production; fi || true)
    [ -n "$labels" ] || { flunk - "hostile: cases.json lists no $part run"; return 0; }
    # shellcheck disable=SC2086 # labels, split on purpose
    hostile_runs $labels
    python3 -I "$kit/analyze.py" suite "$hostile_results" "$part" >"$hostile_results/suite-$part.txt" 2>&1 || true
    verdicts "hostile.suite.$part" "$hostile_results/suite-$part.txt"
}
substage_hostile_production() { hostile_suite production; }
substage_hostile_controls() { hostile_suite controls; }

substage_hostile_faults() {
    local fault
    hostile_prepare
    for fault in none missing-list missing-feature missing-setter missing-getter ineffective-setter; do
        lab_report "$hostile_results/fault-$fault.json" 60 --fault-switch "$fault" --fixture "$kit/fixtures/hostile" \
            || echo "      fault $fault: no report ($(head -c 300 "$hostile_results/fault-$fault.json.err" 2>/dev/null))"
    done
    python3 -I "$kit/analyze.py" faults "$hostile_results" >"$hostile_results/faults.txt" 2>&1 || true
    verdicts hostile.faults "$hostile_results/faults.txt"
}

substage_hostile_binding() {
    hostile_prepare
    lab_report "$hostile_results/binding.json" 90 --binding "$kit/fixtures/twin-a" "$kit/fixtures/twin-b" \
        || echo "      binding: no report ($(head -c 300 "$hostile_results/binding.json.err" 2>/dev/null))"
    python3 -I "$kit/analyze.py" binding "$hostile_results" >"$hostile_results/binding.txt" 2>&1 || true
    verdicts hostile.binding "$hostile_results/binding.txt"
}

# **Through the app's own window** (WI-4's stamp, re-measured at WI-6): the battery's dictionary in a library of the
# app's, each case typed into a production main window's search and shown by its entry view, observed as above.
substage_hostile_app() {
    hostile_prepare
    rm -rf "${hostile_results:?}/app" "$hostile_results/app.log"
    if "$kit/lookup/run-app-hostile.sh" "$kit" "$hostile_results" "$app" >"$hostile_results/app.log" 2>&1; then
        echo "      app: $(tail -1 "$hostile_results/app.log")"
    else
        flunk - "hostile: the run through the app did not happen as described — $(tail -2 "$hostile_results/app.log" | tr '\n' ' ')"
    fi
    python3 -I "$kit/lookup/verdicts.py" hostile "$hostile_results/app" >"$hostile_results/app.txt" 2>&1 || true
    verdicts hostile.app "$hostile_results/app.txt"
}

# ---------------------------------------------------------------------------------------------------------------------
# **reader**: a person's hands on the production entry view (ADR-0009 refutation, item 8). Real pointer events from
# `pointer` (hover; plain, command-, option- and shift-clicks; downloads; the context menu; drags out of the view), the
# observers watching the reader entry's own ports and names: nothing leaves, every remote question is a native prompt
# answered by a real click, and only the one "Open in Browser" reaches the opener.
substage_reader() {
    local results="$home/results/reader" access
    rm -rf "$results"
    mkdir -p "$results"
    access=$("$kit/pointer" access 2>&1 || true)
    if ! grep -q '"postEvents":true' <<<"$access"; then
        flunk reader.access "reader: this SSH session may not post events ($access): grant Accessibility (Privacy & Security, Device Control and Data Access) to sshd-keygen-wrapper on the E2E Mac; nothing was driven"
        return 0
    fi
    pass reader.access "reader: this session may post events ($access)"
    # The screen before the lab started, kept with the run: the frontmost application, the session, the display.
    "$kit/pointer" screen >"$results/screen-before.json" 2>&1 || true
    echo "      before the lab: $(head -c 400 "$results/screen-before.json")"
    if ! "$kit/run-hostile.sh" "$kit" "$results" reader reader >"$results/run.log" 2>&1; then
        flunk - "reader: the run did not happen as described — $(tail -2 "$results/run.log" | tr '\n' ' ')"
        return 0
    fi
    python3 -I "$kit/analyze.py" verdicts "$results/reader" >"$results/verdicts.txt" 2>&1 || true
    verdicts reader.verdicts "$results/verdicts.txt"
    grep '^NOTE' "$results/verdicts.txt" | sed 's/^NOTE /      /' || true
}

# ---------------------------------------------------------------------------------------------------------------------
# **entries.***: the owner's dictionaries through the production entry view (plan-macos-v1 WI-4, done-when), through the
# app's own window (WI-4's stamp, re-measured at WI-6): each sampled entry reached as a link to it is by a production
# main window's model and shown by its entry view, the dictionaries in a library of the app's (an edition the service
# indexed before is only hashed). `entries_corpus`'s sample renders with every image and stylesheet the core resolves
# loaded and nothing outside `xdict:`; OALD's and LDOCE's folding scripts open a section (R5); LDOCE's *hold* finishes,
# find's count equals a count over the entry's text, and a narrow window stays usable (`entries.full`, or about twenty
# entries a dictionary in `entries.quick`); zoom and appearance survive a relaunch per dictionary
# (`entries.persistence`). `entries.lab` holds the development lab to the same rules (extra: not a release's).
entries_results="$home/results/entries"
entries_corpus_here() {
    [ -d "$home/corpus" ] && { [ "${1:-}" != sample ] || [ -s "$kit/entries-sample.json" ]; } && return 0
    flunk - "$STAGE: not measured — no corpus on the E2E Mac (set XDICT_E2E_CORPUS on the build Mac)"
    return 1
}
# entries_app_corpus <check> <dir> <sample>: the sample through the app's window, held to the corpus rules.
entries_app_corpus() {
    local check=$1 dir=$2 sample=$3
    rm -rf "$dir"
    mkdir -p "$dir"
    app_report "$dir/corpus.json" 5400 --entry-corpus "$home/corpus" --library-dir "$reports/entries-library" \
        --sample "$sample" || echo "      app corpus: no report ($(head -c 300 "$dir/corpus.json.err" 2>/dev/null))"
    python3 -I "$kit/analyze.py" entries "$dir" corpus >"$dir/verdicts.txt" 2>&1 || true
    verdicts "$check" "$dir/verdicts.txt"
    grep '^NOTE' "$dir/verdicts.txt" | sed 's/^NOTE /      /' || true
}
substage_entries_full() {
    entries_corpus_here sample || return 0
    entries_app_corpus entries.app.corpus "$entries_results/app" "$kit/entries-sample.json"
}
# The quick sample: the first twenty of each dictionary's, in the full sample's order.
substage_entries_quick() {
    entries_corpus_here sample || return 0
    python3 -I -c 'import json, sys
taken, kept = {}, []
for e in json.load(open(sys.argv[1])):
    if taken.get(e["dict"], 0) < 20:
        taken[e["dict"]] = taken.get(e["dict"], 0) + 1
        kept.append(e)
json.dump(kept, open(sys.argv[2], "w"))
print(f"      quick sample: {len(kept)} entries of {len(taken)} dictionaries")' "$kit/entries-sample.json" "$reports/entries-quick.json"
    entries_app_corpus entries.app.quick "$entries_results/app-quick" "$reports/entries-quick.json"
}
substage_entries_persistence() {
    local dir="$entries_results/app-persistence"
    entries_corpus_here || return 0
    rm -rf "$dir"
    mkdir -p "$dir"
    defaults delete ai.xdict.app.e2e.persistence >/dev/null 2>&1 || true
    app_report "$dir/persistence-set.json" 600 --entry-corpus "$home/corpus" \
        --library-dir "$reports/entries-library" --persistence set \
        || echo "      app persistence set: no report ($(head -c 300 "$dir/persistence-set.json.err" 2>/dev/null))"
    app_report "$dir/persistence-check.json" 600 --entry-corpus "$home/corpus" \
        --library-dir "$reports/entries-library" --persistence check \
        || echo "      app persistence check: no report ($(head -c 300 "$dir/persistence-check.json.err" 2>/dev/null))"
    defaults delete ai.xdict.app.e2e.persistence >/dev/null 2>&1 || true
    python3 -I "$kit/analyze.py" entries "$dir" persistence >"$dir/verdicts.txt" 2>&1 || true
    verdicts entries.app.persistence "$dir/verdicts.txt"
}
substage_entries_lab() {
    local dir="$entries_results/lab"
    entries_corpus_here sample || return 0
    rm -rf "$dir"
    mkdir -p "$dir"
    lab_report "$dir/corpus.json" 5400 --corpus "$home/corpus" --sample "$kit/entries-sample.json" \
        || echo "      corpus: no report ($(head -c 300 "$dir/corpus.json.err" 2>/dev/null))"
    defaults delete ai.xdict.lab.persistence >/dev/null 2>&1 || true
    lab_report "$dir/persistence-set.json" 120 --corpus "$home/corpus" --persistence set \
        || echo "      persistence set: no report ($(head -c 300 "$dir/persistence-set.json.err" 2>/dev/null))"
    lab_report "$dir/persistence-check.json" 120 --corpus "$home/corpus" --persistence check \
        || echo "      persistence check: no report ($(head -c 300 "$dir/persistence-check.json.err" 2>/dev/null))"
    python3 -I "$kit/analyze.py" entries "$dir" >"$dir/verdicts.txt" 2>&1 || true
    verdicts entries.lab "$dir/verdicts.txt"
    grep '^NOTE' "$dir/verdicts.txt" | sed 's/^NOTE /      /' || true
}

# ---------------------------------------------------------------------------------------------------------------------
# **library.***: the reader's library through the signed app and its service (plan-macos-v1 WI-5, done-when). With the
# core's generated packages (`XDict --library-report`): file and folder import, ordered volumes and a sidecar, a missing
# volume, cancel then retry while another dictionary answers, languages asked and edited, three refusals each with its
# sentence in both languages, a link out of the folder refused, sounds told apart, a rewritten file joined and undone,
# a moved folder relinked (and missing with relinking off); then a real drag of a dictionary into the production library
# window (`dragsource`, `pointer`): `library.generated`. The owner's 25, in three launches: registered with
# `index_bench`'s editions, found again in their order after their folder moved, and one rewritten and joined only when
# asked: `library.corpus`. Then their folder moved again and the app relaunched with relinking off, which must report
# them missing: `library.control`, the positive control of the relaunch's check.

# The drop: the production library window shown by the app (`--library-drop`), a file dragged into it from another app
# by real pointer events.
library_drop() {
    local work="$reports/library-drop" out="$reports/library-drop.json" access waited=0 drop source source_pid
    mkdir -p "$work/from"
    access=$("$kit/pointer" access 2>&1 || true)
    if ! grep -q '"postEvents":true' <<<"$access"; then
        flunk - "library: this SSH session may not post events ($access), so nothing was dropped"
        return 0
    fi
    cp "$home/fixtures/library/drop/dropped.mdx" "$work/from/dropped.mdx"
    rm -f "$out" "$work/ready.json" "$work/source-ready"
    open -n --stdout "$out" --stderr "$out.err" "$app" --args --library-drop "$work/library" --ready "$work/ready.json" \
        --expect dropped.mdx || { flunk - "library: the drop window could not be started"; return 0; }
    while [ ! -s "$work/ready.json" ] && [ "$waited" -lt 300 ]; do sleep 0.1; waited=$((waited + 1)); done
    if [ ! -s "$work/ready.json" ]; then
        flunk - "library: the drop window never said where it was ($(head -c 300 "$out.err" 2>/dev/null))"
        return 0
    fi
    drop=$(python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1]))["drop"]; print(int(d[0]), int(d[1]))' "$work/ready.json")
    "$kit/dragsource" "$work/from/dropped.mdx" 840 120 "$work/source-ready" >"$work/source.log" 2>&1 &
    source_pid=$!
    waited=0
    while [ ! -s "$work/source-ready" ] && [ "$waited" -lt 100 ]; do sleep 0.1; waited=$((waited + 1)); done
    if [ ! -s "$work/source-ready" ]; then
        kill "$source_pid" 2>/dev/null || true
        flunk - "library: the drag source never showed ($(head -c 300 "$work/source.log"))"
        return 0
    fi
    source=$(cat "$work/source-ready")
    # shellcheck disable=SC2086 # two coordinates each, split on purpose
    "$kit/pointer" drag $source $drop || flunk - "library: pointer could not drag"
    waited=0
    while [ ! -s "$out" ] && [ "$waited" -lt 1000 ]; do sleep 0.1; waited=$((waited + 1)); done
    kill "$source_pid" 2>/dev/null || true
    wait "$source_pid" 2>/dev/null || true
    echo "      drag: from $source to $drop; $(tail -1 "$work/source.log" 2>/dev/null)"
    if [ ! -s "$out" ]; then
        flunk - "library: the drop window wrote no report within 100 s ($(head -c 300 "$out.err" 2>/dev/null))"
        return 0
    fi
    findings "$out"
}

library_results="$home/results/library"
library_keep() { mkdir -p "$library_results"; cp "$reports"/library-*.json "$library_results/" 2>/dev/null || true; }

substage_library_generated() {
    if report --library-report 600 "$home/fixtures" >/dev/null; then
        findings "$reports/library-report.json"
        echo "      facts: $(plutil -extract facts json -o - "$reports/library-report.json" 2>/dev/null | head -c 600)"
    else
        flunk - "library: --library-report wrote nothing within 600 s ($(head -c 300 "$reports/library-report.err" 2>/dev/null))"
    fi
    if check_asked drop.registered; then library_drop; fi
    library_keep
}

# The owner's 25, on APFS clones of their folders (instant, and nothing written to the originals), in a library of this
# run's: imported once, then moved and relaunched by `library.corpus` and `library.control`, whichever run.
library_dir="$reports/library-corpus"
library_at=""   # where the clone is now; empty until imported
library_import() {
    [ -z "$library_at" ] || return 0
    if [ ! -d "$home/corpus" ] || [ ! -s "$home/library-editions.json" ]; then
        flunk - "$STAGE: the 25 not measured — no corpus or editions on the E2E Mac (set XDICT_E2E_CORPUS on the build Mac)"
        return 1
    fi
    rm -rf "$reports/corpus-a" "$library_dir"
    cp -cR "$home/corpus" "$reports/corpus-a" || { flunk - "$STAGE: the corpus could not be cloned"; return 1; }
    if ! report --library-corpus 1800 import "$reports/corpus-a" --library-dir "$library_dir" \
        --expected "$home/library-editions.json" >/dev/null; then
        flunk - "$STAGE: the import launch wrote nothing ($(head -c 300 "$reports/library-corpus.err" 2>/dev/null))"
        return 1
    fi
    cp "$reports/library-corpus.json" "$reports/library-corpus-import.json"
    findings "$reports/library-corpus-import.json"
    library_at="$reports/corpus-a"
}
# library_move <to>: the clone's folder moved, as a reader moves a folder.
library_move() { mv "$library_at" "$1" && library_at=$1; }

substage_library_corpus() {
    library_import || return 0
    library_move "$reports/corpus-b" || { flunk - "library: the corpus could not be moved"; return 0; }
    if report --library-corpus 900 relaunch --library-dir "$library_dir" --moved-to "$library_at" >/dev/null; then
        cp "$reports/library-corpus.json" "$reports/library-corpus-relaunch.json"
        findings "$reports/library-corpus-relaunch.json"
    else
        flunk - "library: the relaunch wrote nothing ($(head -c 300 "$reports/library-corpus.err" 2>/dev/null))"
    fi
    if report --library-corpus 900 rewrite --library-dir "$library_dir" >/dev/null; then
        cp "$reports/library-corpus.json" "$reports/library-corpus-rewrite.json"
        findings "$reports/library-corpus-rewrite.json"
    else
        flunk - "library: the rewrite launch wrote nothing ($(head -c 300 "$reports/library-corpus.err" 2>/dev/null))"
    fi
    library_keep
}

# **The control**: relinking off, the moved dictionaries must be reported missing — `relaunch.foundWhereMoved` fails.
# Its report is read for that one check and recorded as nothing else: the relaunch's own checks are `library.corpus`'s.
substage_library_control() {
    local found
    library_import || return 0
    library_move "$reports/corpus-c" || { flunk - "library: the corpus could not be moved"; return 0; }
    if ! report --library-corpus 900 relaunch --library-dir "$library_dir" --moved-to "$library_at" --no-relink >/dev/null; then
        flunk library.control.missingWithoutRelinking "library: the relaunch without relinking wrote nothing ($(head -c 300 "$reports/library-corpus.err" 2>/dev/null))"
        return 0
    fi
    cp "$reports/library-corpus.json" "$reports/library-corpus-control.json"
    found=$(finding "$reports/library-corpus-control.json" relaunch.foundWhereMoved)
    if [ "$found" = false ]; then
        pass library.control.missingWithoutRelinking "library: with relinking off, relaunch.foundWhereMoved fails: the moved dictionaries are reported missing"
    else
        flunk library.control.missingWithoutRelinking "library: with relinking off, relaunch.foundWhereMoved was ${found:-not reported}, so the check cannot see a dictionary lost"
    fi
    library_keep
}

# ---------------------------------------------------------------------------------------------------------------------
# **lookup.***, one launch (plan-macos-v1 WI-6, done-when): the real app started by LaunchServices over a library of its
# own (`XDict --lookup-window`), its service reached through a transport the checks can hold. First a reader's keyboard
# alone (`keys`, `drive.py`): the search field has the keyboard at launch; a word typed and Return; into the results and
# through them; into the entry, to a link, followed; Back, Forward and the original word; Search; the scope by its
# shortcut, read in the toolbar; a suggestion chosen. VoiceOver's reading of the window: every result names its
# dictionary (`lookup.a11y`). Then the scenario through the window's own model and entry view (`LookupScenario`): scope,
# order, folding, phrases, internal keys (LDOCE's with the corpus), five unavailable states each with its own sentence, a
# held dictionary delaying no other, a five-hop trail returned exactly; then entries asked for faster than WebKit
# answers, none of the replaced loads taken for a link (`lookup.core`); each checkpoint read through the Accessibility
# API against what the window must show (`lookup.a11y`). 66,355 records paged (`lookup.paging`), left out when not asked:
# the scenario is the driver's to start, so `lookup.core` and `lookup.a11y` always run together.
substage_lookup() {
    local results="$home/results/lookup" work="$reports/lookup" access paging=--no-paging corpus=()
    rm -rf "$results" "$work"
    mkdir -p "$results" "$work"
    ! asked lookup.paging || paging=""
    access=$("$kit/lookup/keys" access 2>&1 || true)
    if ! grep -q '"accessibility":true' <<<"$access" || ! grep -q '"postEvents":true' <<<"$access"; then
        flunk lookup.access "lookup: this SSH session may not post keys or read the window ($access): grant Accessibility to sshd-keygen-wrapper on the E2E Mac; nothing was driven"
        return 0
    fi
    pass lookup.access "lookup: this session may post keys and read the window ($access)"
    if is_running "$exe"; then
        flunk - "lookup: XDict is already running (pid ${PIDS[*]}), so the window driven would not be this run's"
        return 0
    fi
    # Windows of an earlier session are not restored: the window driven is the one this launch opens.
    if [ -d "$home/corpus/ldoce" ]; then
        corpus=(--corpus "$home/corpus")
    else
        flunk - "lookup: LDOCE's internal keys not measured — no corpus on the E2E Mac (set XDICT_E2E_CORPUS on the build Mac)"
    fi
    echo "      ${paging:-with paging}"
    open -n --stdout "$work/app.out" --stderr "$work/app.err" "$app" --args -ApplePersistenceIgnoreState YES \
        --lookup-window "$work" --fixtures "$home/fixtures/lookup" ${corpus[@]+"${corpus[@]}"} $paging \
        || { flunk - "lookup: the app could not be started"; return 0; }
    if python3 -I "$kit/lookup/drive.py" "$kit" "$work" "$app" "$work/driver.json" >"$results/drive.log" 2>&1; then
        echo "      driven: $(grep -c '^PASS' "$results/drive.log") passed, $(grep -c '^FAIL' "$results/drive.log") failed"
    else
        flunk - "lookup: the driver stopped — $(tail -2 "$results/drive.log" | tr '\n' ' ')"
    fi
    for _ in $(seq 1 100); do is_running "$exe" || break; sleep 0.1; done
    quit_bundle >/dev/null 2>&1 || true
    if [ -s "$work/findings.json" ]; then
        findings "$work/findings.json"
    else
        flunk - "lookup: the window's scenario wrote no findings ($(head -c 300 "$work/app.err" 2>/dev/null))"
    fi
    if [ -s "$work/driver.json" ]; then
        findings "$work/driver.json"
    else
        flunk - "lookup: the driver wrote no findings"
    fi
    cp "$work"/*.json "$results/" 2>/dev/null || true
    cp "$work"/commands/ax-*.json "$results/" 2>/dev/null || true
}

# ---------------------------------------------------------------------------------------------------------------------
# **sound.***, one launch (plan-macos-v1 WI-7, done-when): a production main window of the app (`XDict --sound-report`)
# whose sounds are at volume 0 — decoded, started and run to their end, unheard on this shared Mac — every link clicked in
# the page as a reader's click is. `sound.speech`: a `.tts` link speaks; the speak button speaks the entry's word;
# switching the accent changes the voice; a dictionary declared Chinese speaks with a Chinese voice; each utterance also
# rendered into a buffer (a voice that "spoke" nothing fails). `sound.notices`: a missing, a Speex and an undecodable
# recording each give their own notice, in both languages, shown in the window and read here as VoiceOver reads it
# (`keys ax`, whenever the instrument asks: it holds no Accessibility grant), and are spoken instead. `sound.recordings`:
# the 25's sampled `sound://` links of every format they hold, mp3, WAV and Ogg Vorbis played to their end and labelled
# as the dictionary's, Speex spoken instead with its notice, a recording a dictionary lacks told so; left out when not
# asked.
substage_sound() {
    local results="$home/results/sound" work="$reports/sound" access out waited=0 checkpoint pid corpus=() was
    rm -rf "$results" "$work"
    mkdir -p "$results" "$work"
    # Only `sound.notices.shown` reads the window. Without the grant `sound.access` fails, and everything else still
    # runs: the sounds need no permission, and a host that may not read windows still says whether they play.
    if asked sound.notices; then
        access=$("$kit/lookup/keys" access 2>&1 || true)
        if grep -q '"accessibility":true' <<<"$access"; then
            pass sound.access "sound: this session may read the window ($access)"
        else
            flunk sound.access "sound: this SSH session may not read the window ($access): grant Accessibility to sshd-keygen-wrapper on the E2E Mac; sound.notices.shown cannot pass here, the rest runs"
        fi
    fi
    if is_running "$exe"; then
        flunk - "sound: XDict is already running (pid ${PIDS[*]}), so the window heard would not be this run's"
        return 0
    fi
    if asked sound.recordings; then
        if [ -d "$home/corpus" ] && [ -s "$kit/entries-sample.json" ]; then
            corpus=(--corpus "$home/corpus" --sample "$kit/entries-sample.json")
        else
            was=$STAGE
            STAGE=sound.recordings
            flunk - "sound: the 25 not measured — no corpus or sample on the E2E Mac (set XDICT_E2E_CORPUS on the build Mac)"
            STAGE=$was
        fi
    fi
    out="$work/sound.json"
    open -n --stdout "$work/app.out" --stderr "$work/app.err" "$app" --args --sound-report "$home/fixtures" \
        --library-dir "$reports/sound-library" --work "$work" --out "$out" ${corpus[@]+"${corpus[@]}"} \
        || { flunk - "sound: the app could not be started"; return 0; }
    # Thirty minutes at most; each checkpoint the instrument writes is answered with the window's tree, once (unasked,
    # it waits 15 s for an answer that does not come, and reports nothing read).
    while [ ! -s "$out" ] && [ "$waited" -lt 18000 ]; do
        for checkpoint in "$work"/checkpoint-*.json; do
            case $checkpoint in *.ax.json | *'*'*) continue ;; esac
            [ ! -e "${checkpoint%.json}.ax.json" ] || continue
            asked sound.notices || continue
            pid=$(plutil -extract pid raw -o - "$checkpoint" 2>/dev/null || echo "")
            "$kit/lookup/keys" ax "$pid" 2000 >"${checkpoint%.json}.ax.tmp" 2>&1 || true
            mv "${checkpoint%.json}.ax.tmp" "${checkpoint%.json}.ax.json"
        done
        sleep 0.1
        waited=$((waited + 1))
    done
    for _ in $(seq 1 50); do is_running "$exe" || break; sleep 0.1; done
    quit_bundle >/dev/null 2>&1 || true
    if [ -s "$out" ]; then
        findings "$out"
        echo "      facts: $(plutil -extract facts json -o - "$out" 2>/dev/null | head -c 1500)"
    else
        flunk - "sound: the instrument wrote no findings within 30 minutes ($(head -c 300 "$work/app.err" 2>/dev/null))"
    fi
    cp "$work"/*.json "$results/" 2>/dev/null || true
}

# ---------------------------------------------------------------------------------------------------------------------
# **The run**: each sub-stage asked for, in the plan's order; a group's launch once, for all of its sub-stages asked.
# Each is timed (`TIME` lines, for the recorder), and each fails by name for a check it never reported.
ran_groups=" "
for sub in "${WANTED[@]}"; do
    group=$(group_of "$sub")
    members=("$sub")
    function_name="substage_${sub//./_}"
    if [ -n "$group" ] && [ "$group" != - ]; then
        case $ran_groups in *" $group "*) continue ;; esac
        ran_groups="$ran_groups$group "
        members=()
        for other in "${WANTED[@]}"; do [ "$(group_of "$other")" != "$group" ] || members+=("$other"); done
        function_name="substage_$group"
    fi
    declare -F "$function_name" >/dev/null || { STAGE=$sub; flunk - "$sub: this script has no $function_name"; continue; }
    STAGE=${members[0]}
    echo
    echo "-- ${members[*]}"
    before=$failures
    started=$SECONDS
    "$function_name"
    took=$((SECONDS - started))
    for member in "${members[@]}"; do
        require_reported "$member"
        printf 'TIME\t%s\t%s\t%s\n' "$member" "$took" "${members[*]}"
    done
    echo "      ${members[*]}: $took s"
    if [ "$failfast" = 1 ] && [ "$failures" -gt "$before" ]; then
        echo
        echo "E2E_FAILFAST: stopping after ${members[*]}, which failed; the sub-stages after it did not run"
        break
    fi
done

finished=true
echo
[ "$failures" -eq 0 ] && echo "all sub-stages passed" || { echo "$failures assertion(s) failed"; exit 1; }
SH

RUN_LOG=$scratch/run.log
set +e
# shellcheck disable=SC2086 # the sub-stage names are words, validated above
on_host bash -s -- "$REMOTE_DIR" "$failfast" $SUBSTAGES <"$scratch/run.sh" | tee "$RUN_LOG" | grep -v "^RESULT	\|^TIME	"
pipeline=("${PIPESTATUS[@]}")
set -e
remote_status=${pipeline[0]}
# **`tee`'s status is the log's, and the log is the evidence**: a log that could not be written is a run with no
# verdict, whatever the stages did.
[ "${pipeline[1]}" -eq 0 ] || fail "the run log could not be written (tee exited ${pipeline[1]}); nothing is recorded"
# **A transport failure is not a set of results**: ssh dying part-way leaves a log of every PASS reached and none of the
# failures after it. The remote script exits 0 or 1; 255 is ssh's own.
if [ "$remote_status" -ge 2 ]; then
    echo "the connection to $host failed mid-run (exit $remote_status); nothing is recorded" >&2
    exit "$remote_status"
fi
grep -q "^RESULT	" "$RUN_LOG" || fail "the run reported no result at all; nothing is recorded"
# What the entry view's stages measured (each run's observations, summaries, the suite's matrix), kept here for reading;
# the verdicts are the log's. A copy that fails costs the detail, not the run.
if on_host "test -d '$REMOTE_DIR/results'"; then
    mkdir -p .build/e2e-results
    to_host "$host:$REMOTE_DIR/results/" .build/e2e-results/ \
        || echo "the stages' results could not be copied back from the E2E Mac"
fi
echo
echo "time per sub-stage:"
awk -F'\t' '$1 == "TIME" { printf "  %-22s %6s s%s\n", $2, $3, ($4 != $2 ? "  (one launch: " $4 ")" : "") }' "$RUN_LOG"

if [ -n "$expected_override" ] || [ -n "$only" ]; then
    echo
    echo "a positive control or a subset (XDICT_E2E_EXPECTED_VERSIONS, XDICT_E2E_ONLY): nothing is recorded"
    exit "$remote_status"
fi
# The tree likewise: one that moved while the stages ran is no tree this run tested.
[ "$source_tree" = - ] || [ "$source_tree" = "$(Tools/source-tree.sh)" ] || source_tree=-
Tools/e2e-status.sh record "$remote_version" "$remote_uuid" "$e2e_os" "$source_tree" "$build_mode" <"$RUN_LOG"
echo
Tools/e2e-status.sh show
exit "$remote_status"
