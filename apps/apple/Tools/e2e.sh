#!/bin/bash
# End-to-end tests, on the E2E Mac — never on the machine that builds. They run the published bundle there as a reader
# would: started by LaunchServices in the logged-in GUI session, answering through its sandboxed XPC service.
#
#   e2e.sh <ssh-host> [stage...]   ship .build/XDict.app to ~/XDictE2E on the host and run the stages there (all of
#                                  them when none is named)
#   e2e.sh --list-stages           the stage names, one per line: what `Tools/e2e-status.sh require-fresh` requires
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
#                    by hand, the rows are filed with no tree and are no release's evidence
#   XDICT_E2E_EXPECTED_VERSIONS
#                    a positive control: a JSON file of versions the `launch` stage expects instead of the bundle's own
#                    (`Contents/Resources/CoreVersions.json`), to show a wrong expectation failing. A run with it
#                    records nothing
#   XDICT_E2E_SSH    the program that reaches the host, `ssh` unless set. The host guard's positive control sets it to
#                    `Tools/tests/ssh-to-this-mac`, which runs the remote side here
set -euo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
readonly SELF
cd "$(dirname "$SELF")/.."

# **The only list of the stages.** A stage named that is not on it is refused: a typo that ran nothing once printed "all
# stages passed" (XiaolaiDict). The remote script is handed this list, so the two cannot differ.
readonly KNOWN_STAGES="launch"
if [ "${1:-}" = --list-stages ]; then
    printf '%s\n' $KNOWN_STAGES
    exit 0
fi

fail() { echo "e2e: FAIL: $*" >&2; exit 1; }
section() { echo; echo "== $*"; }
host=${1:?usage: e2e.sh <ssh-host> [stage...] | --list-stages}
shift
STAGES="$*"
# **Validated here, before anything is sent**: `ssh host cmd a b` hands the arguments to a remote shell, which parses
# them again, so a stage name carrying `;` would run there as a command.
case $STAGES in *[!a-z\ ]*) fail "a stage name is a lower-case word; got '$STAGES'" ;; esac
for wanted in $STAGES; do
    case " $KNOWN_STAGES " in *" $wanted "*) ;; *) fail "no stage called '$wanted'; the stages are: $KNOWN_STAGES" ;; esac
done
readonly APP=.build/XDict.app
readonly REMOTE_DIR=XDictE2E
readonly SSH=${XDICT_E2E_SSH:-ssh}
[ -d "$APP" ] || fail "$APP does not exist; run make app"
on_host() { "$SSH" -o BatchMode=yes -o ConnectTimeout=15 "$host" "$@"; }

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

# ---------------------------------------------------------------------------------------------------------------------
section "install"
cat "$scratch/common.sh" - <<'SH' | on_host bash -s -- "$REMOTE_DIR" || fail "could not quit the running E2E copy"
set -euo pipefail
app="$HOME/$1/XDict.app"; exe="$app/Contents/MacOS/XDict"
service="$app/Contents/XPCServices/ai.xdict.app.DictionaryService.xpc/Contents/MacOS/XDictService"
quit_bundle
SH
on_host "mkdir -p '$REMOTE_DIR' && rm -f '$REMOTE_DIR/expected-versions.json'"
rsync -a --delete -e "$SSH -o BatchMode=yes -o ConnectTimeout=15" "$APP" "$host:$REMOTE_DIR/" \
    || fail "could not copy the bundle"
if [ -n "$expected_override" ]; then
    rsync -a -e "$SSH -o BatchMode=yes -o ConnectTimeout=15" "$expected_override" "$host:$REMOTE_DIR/expected-versions.json" \
        || fail "could not copy the expected versions"
fi
local_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
remote_version=$(on_host "/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' '$REMOTE_DIR/XDict.app/Contents/Info.plist'")
[ "$local_version" = "$remote_version" ] || fail "shipped build $local_version, found $remote_version"
case $remote_version in
    *.*) build_mode=development ;;
    *) build_mode=release ;;
esac
on_host "codesign --verify --strict --deep '$REMOTE_DIR/XDict.app'" || fail "the shipped bundle does not verify there"
echo "build $remote_version ($build_mode) installed and verified"

# ---------------------------------------------------------------------------------------------------------------------
section "run${STAGES:+: $STAGES}"
cat "$scratch/common.sh" - >"$scratch/run.sh" <<'SH'
set -euo pipefail
home="$HOME/$1"; shift
known=$1; shift
app="$home/XDict.app"; exe="$app/Contents/MacOS/XDict"
service="$app/Contents/XPCServices/ai.xdict.app.DictionaryService.xpc/Contents/MacOS/XDictService"
expected="$app/Contents/Resources/CoreVersions.json"
[ ! -s "$home/expected-versions.json" ] || expected="$home/expected-versions.json"
WANTED=("$@")
[ ${#WANTED[@]} -gt 0 ] || read -r -a WANTED <<<"$known"
failures=0

# **Until a stage claims it, what runs is setup**, and setup is a name the record can hold.
STAGE=setup
want() {  # want <name>: is this stage wanted? Also names it, for the result lines.
    STAGE=$1
    local w
    for w in "${WANTED[@]}"; do [ "$w" = "$1" ] && return 0; done
    return 1
}
# RESULT lines are for the recorder; PASS and FAIL lines for a person.
pass() { echo "PASS  $*"; printf 'RESULT\t%s\tpass\n' "$STAGE"; }
flunk() { echo "FAIL  $*"; failures=$((failures + 1)); printf 'RESULT\t%s\tfail\n' "$STAGE"; }

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

# report <flag> <seconds>: an instrument started by LaunchServices like the app (`open -n --args`), its JSON on stdout
# once it has written and exited; nothing, and status 1, if it wrote nothing in time.
report() {
    local flag=$1 budget=$2 name=${1#--} waited=0
    local out="$reports/$name.json" err="$reports/$name.err"
    rm -f "$out" "$err"
    open -n --stdout "$out" --stderr "$err" "$app" --args "$flag" || return 1
    while [ ! -s "$out" ] && [ "$waited" -lt $((budget * 10)) ]; do sleep 0.1; waited=$((waited + 1)); done
    [ -s "$out" ] || return 1
    cat "$out"
}

# ---------------------------------------------------------------------------------------------------------------------
if want launch; then
# **launch**: LaunchServices starts the app, its dictionary service answers the handshake through the real XPC path,
# and the versions it answers with are those of the core the bundle was built from.
launch_stage() {
    local why pid parent service_pid answered wanted key json known_as mismatched=""
    if ! why=$(launch_app 2>&1); then
        flunk "launch: XDict could not be started — $why. The rest of this stage did not run"
        return 0
    fi
    # Read again here: `launch_app` ran in a command substitution, whose PIDS died with it.
    find_pids "$exe"
    pid=${PIDS[0]:-}
    [ -n "$pid" ] || { flunk "launch: XDict started and was gone before it could be looked at"; return 0; }
    parent=$(parent_of "$pid")
    if [ "$parent" = 1 ]; then pass "launch: started by LaunchServices (pid $pid, its parent launchd)"
    else flunk "launch: pid $pid's parent is ${parent:-unknown}, not launchd: it was not started by LaunchServices"; fi
    # Captured, then matched: `producer | grep -q` fails under pipefail when grep stops reading early.
    known_as=$(lsappinfo info -only bundleid "$pid" 2>&1 || true)
    if grep -q 'bundleID="ai.xdict.app"' <<<"$known_as"; then
        pass "launch: LaunchServices knows pid $pid as ai.xdict.app"
    else
        flunk "launch: LaunchServices does not know pid $pid as ai.xdict.app ($(tr -s ' \n' ' ' <<<"$known_as"))"
    fi
    sleep 1
    if is_running "$exe"; then pass "launch: still running 1 s after it started"; else flunk "launch: not running 1 s after it started"; fi

    # The app asks its service at launch, so its own service is running now, from this bundle, started by launchd.
    if wait_for_process "$service" 100; then
        service_pid=${PIDS[0]:-}
        parent=$(parent_of "$service_pid")
        if [ "$parent" = 1 ]; then pass "launch: the app's dictionary service runs from the bundle (pid $service_pid, started by launchd)"
        else flunk "launch: the dictionary service (pid $service_pid) was started by ${parent:-unknown}, not launchd"; fi
    else
        flunk "launch: the app started and no dictionary service from this bundle ran within 10 s"
    fi

    # The handshake, asked by the instrument exactly as the app asks it.
    if ! json=$(report --handshake-report 30); then
        flunk "launch: --handshake-report wrote nothing within 30 s ($(head -c 300 "$reports/handshake-report.err" 2>/dev/null))"
        return 0
    fi
    echo "      handshake: $json"
    if plutil -extract failure raw -o - "$reports/handshake-report.json" >/dev/null 2>&1; then
        flunk "launch: the handshake failed: $(plutil -extract failure raw -o - "$reports/handshake-report.json")"
        return 0
    fi
    for key in protocol core indexFormat normalization; do
        answered=$(plutil -extract "service.$key" raw -o - "$reports/handshake-report.json" 2>/dev/null || echo "(none)")
        wanted=$(plutil -extract "$key" raw -o - "$expected" 2>/dev/null || echo "(none)")
        [ "$answered" = "$wanted" ] || mismatched="$mismatched $key=$answered (the core's: $wanted)"
    done
    if [ -z "$mismatched" ]; then pass "launch: the service answered the handshake with the core's versions ($(tr -d '\n' <"$expected"))"
    else flunk "launch: the service's versions are not the core's:$mismatched"; fi
    parent=$(plutil -extract parentPid raw -o - "$reports/handshake-report.json" 2>/dev/null || echo "?")
    if [ "$parent" = 1 ]; then pass "launch: the handshake was asked by an XDict started by LaunchServices"
    else flunk "launch: the instrument's parent was $parent, not launchd"; fi

    # And it quits when asked, the service with it.
    kill -TERM "$pid" 2>/dev/null || true
    local gone=no
    for _ in $(seq 1 50); do is_running "$exe" || { gone=yes; break; }; sleep 0.1; done
    if [ "$gone" = yes ]; then pass "launch: quits on TERM within 5 s"; else flunk "launch: still running 5 s after TERM"; fi
}
launch_stage
fi

finished=true
echo
[ "$failures" -eq 0 ] && echo "all stages passed" || { echo "$failures assertion(s) failed"; exit 1; }
SH

RUN_LOG=$scratch/run.log
set +e
# shellcheck disable=SC2086 # the stage names are words, validated above
on_host bash -s -- "$REMOTE_DIR" "'$KNOWN_STAGES'" $STAGES <"$scratch/run.sh" | tee "$RUN_LOG" | grep -v "^RESULT	"
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

if [ -n "$expected_override" ]; then
    echo
    echo "positive control (XDICT_E2E_EXPECTED_VERSIONS): nothing is recorded"
    exit "$remote_status"
fi
# The tree likewise: one that moved while the stages ran is no tree this run tested.
[ "$source_tree" = - ] || [ "$source_tree" = "$(Tools/source-tree.sh)" ] || source_tree=-
Tools/e2e-status.sh record "$remote_version" "$remote_uuid" "$e2e_os" "$source_tree" "$build_mode" <"$RUN_LOG"
echo
Tools/e2e-status.sh show
exit "$remote_status"
