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
#   XDICT_E2E_SERVICE_CHECKS
#                    a subset of the `service` stage's instrument checks (`XDict --service-report --checks`), comma
#                    separated, for working on one. A run with it records nothing
#   XDICT_E2E_SSH    the program that reaches the host, `ssh` unless set. The host guard's positive control sets it to
#                    `Tools/tests/ssh-to-this-mac`, which runs the remote side here
#   XDICT_E2E_CORPUS the owner's 25 dictionaries (`../dictionary-collection/corpus`), for the `entries` stage: their
#                    folders are copied to the E2E Mac (never into the repository) and `entries_corpus`'s sample of them
#                    is rendered there. Unset, that stage fails as not measured: a green run without it measured nothing
set -euo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
readonly SELF
cd "$(dirname "$SELF")/.."

# **The only list of the stages.** A stage named that is not on it is refused: a typo that ran nothing once printed "all
# stages passed" (XiaolaiDict). The remote script is handed this list, so the two cannot differ.
readonly KNOWN_STAGES="launch service hostile reader entries"
# The stages that need the entry view's kit (`Tools/build-lab.sh`): the development lab, the fixtures, the observers.
readonly KIT_STAGES="hostile reader entries"
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
service_checks=${XDICT_E2E_SERVICE_CHECKS:-}
case $service_checks in *[!A-Za-z,]*) fail "XDICT_E2E_SERVICE_CHECKS is check names and commas; got '$service_checks'" ;; esac

# ---------------------------------------------------------------------------------------------------------------------
section "install"
cat "$scratch/common.sh" - <<'SH' | on_host bash -s -- "$REMOTE_DIR" || fail "could not quit the running E2E copy"
set -euo pipefail
app="$HOME/$1/XDict.app"; exe="$app/Contents/MacOS/XDict"
service="$app/Contents/XPCServices/ai.xdict.app.DictionaryService.xpc/Contents/MacOS/XDictService"
quit_bundle
SH
on_host "mkdir -p '$REMOTE_DIR' && rm -f '$REMOTE_DIR/expected-versions.json' '$REMOTE_DIR/service-checks'"
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
# **The `service` stage's dictionaries are written here, by the core's own MDX writer, and shipped with the bundle**: no
# dictionary content enters the repository or reaches the E2E Mac from anywhere else (Tools/build-fixtures.sh).
case " ${STAGES:-$KNOWN_STAGES} " in
    *" service "*)
        Tools/build-fixtures.sh "$scratch/fixtures" >/dev/null || fail "could not write the service stage's fixtures"
        rsync -a --delete -e "$SSH -o BatchMode=yes -o ConnectTimeout=15" "$scratch/fixtures/" "$host:$REMOTE_DIR/fixtures/" \
            || fail "could not copy the fixtures"
        if [ -n "$service_checks" ]; then
            printf '%s\n' "$service_checks" | on_host "cat > '$REMOTE_DIR/service-checks'" || fail "could not copy the check subset"
        fi
        echo "fixtures written and copied${service_checks:+; service checks: $service_checks}"
        ;;
esac
echo "build $remote_version ($build_mode) installed and verified"

# **The entry view's kit**, for the stages that render entries before the service answers them (plan-macos-v1 WI-4):
# built here, shipped beside the bundle, never inside it.
needs_kit=false
for wanted in ${STAGES:-$KNOWN_STAGES}; do
    case " $KIT_STAGES " in *" $wanted "*) needs_kit=true ;; esac
done
if [ "$needs_kit" = true ]; then
    section "kit"
    Tools/build-lab.sh || fail "the entry view's kit could not be built"
    rsync -a --delete -e "$SSH -o BatchMode=yes -o ConnectTimeout=15" .build/e2e-kit/ "$host:$REMOTE_DIR/kit/" \
        || fail "could not copy the kit"
    on_host "codesign --verify --strict '$REMOTE_DIR/kit/XDictEntryLab.app'" || fail "the shipped lab does not verify there"
fi

# **The real dictionaries, for `entries`**: `entries_corpus`'s own sample of them (the bindings cannot enumerate a file's
# keys), and their folders copied beside the bundle. An unset corpus ships nothing, and the stage says not measured.
wants_entries=false
for wanted in ${STAGES:-$KNOWN_STAGES}; do [ "$wanted" != entries ] || wants_entries=true; done
if [ "$wants_entries" = true ] && [ -n "${XDICT_E2E_CORPUS:-}" ]; then
    section "corpus"
    [ -d "$XDICT_E2E_CORPUS" ] || fail "XDICT_E2E_CORPUS is not a folder: $XDICT_E2E_CORPUS"
    corpus=$(cd "$XDICT_E2E_CORPUS" && pwd)
    sample=$(pwd)/.build/entries-sample.json
    (cd ../../core && XDICT_MDX_CORPUS="$corpus" XDICT_ENTRIES_SAMPLE_OUT="$sample" \
        cargo test -q --release -p xdict-core --test entries_corpus -- --nocapture >"$scratch/entries-corpus.log" 2>&1) \
        || fail "entries_corpus failed, so its sample is not one: $(tail -3 "$scratch/entries-corpus.log")"
    [ -s "$sample" ] || fail "entries_corpus wrote no sample"
    rsync -a -e "$SSH -o BatchMode=yes -o ConnectTimeout=15" "$sample" "$host:$REMOTE_DIR/kit/entries-sample.json" \
        || fail "could not copy the sample"
    folders=()
    for folder in "$corpus"/*/; do
        name=$(basename "$folder")
        case $name in _*) continue ;; esac
        folders+=("${folder%/}")   # no trailing slash: rsync copies the folder, not its contents
    done
    [ "${#folders[@]}" -gt 0 ] || fail "no dictionary folder in $corpus"
    echo "${#folders[@]} dictionaries, $(python3 -I -c 'import json, sys; print(len(json.load(open(sys.argv[1]))))' "$sample") sampled entries"
    rsync -a --delete -e "$SSH -o BatchMode=yes -o ConnectTimeout=15" "${folders[@]}" "$host:$REMOTE_DIR/corpus/" \
        || fail "could not copy the corpus"
fi

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
# verdicts <prefix> <file>: each PASS or FAIL line of an analysis, as this stage's assertions; none at all is a FAIL.
verdicts() {
    local prefix=$1 file=$2 line seen=0
    while IFS= read -r line; do
        case $line in
            "PASS  "*) pass "$prefix: ${line#PASS  }"; seen=$((seen + 1)) ;;
            "FAIL  "*) flunk "$prefix: ${line#FAIL  }"; seen=$((seen + 1)) ;;
        esac
    done <"$file"
    [ "$seen" -gt 0 ] || flunk "$prefix: the analysis gave no verdict ($(head -c 300 "$file"))"
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
    # The shipped app's own launch check of the entry view (ADR-0009 decision 7): both WebKit switches turned off and
    # read back off on this Mac's WebKit, with no web view made. Either missing or still on, no entry would render.
    local ready preconnect peer
    ready=$(plutil -extract entryView.ready raw -o - "$reports/handshake-report.json" 2>/dev/null || echo "(none)")
    preconnect=$(plutil -extract entryView.switches.LinkPreconnect raw -o - "$reports/handshake-report.json" 2>/dev/null || echo "(none)")
    peer=$(plutil -extract entryView.switches.PeerConnectionEnabled raw -o - "$reports/handshake-report.json" 2>/dev/null || echo "(none)")
    if [ "$ready" = true ] && [ "$preconnect" = false ] && [ "$peer" = false ]; then
        pass "launch: the app reads LinkPreconnect and PeerConnectionEnabled back off: entries can be shown confined"
    else
        flunk "launch: the app's entry view would refuse (ready $ready, LinkPreconnect $preconnect, PeerConnectionEnabled $peer, $(plutil -extract entryView.refusal raw -o - "$reports/handshake-report.json" 2>/dev/null))"
    fi
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

# ---------------------------------------------------------------------------------------------------------------------
if want service; then
# **service**: this bundle's own signed dictionary service, asked through the app's `ServiceClient` by an instrument
# LaunchServices started (`XDict --service-report`, plan-macos-v1 WI-3): `conformance/`'s `tiny` and `matrix`, the
# refusals, supersession, a stalled bulk call, `kill -9` mid-lookup and the idle exit raced. **Every check is required by
# name**: an instrument that stopped early leaves one missing, and a missing one fails. Then who reaches the service by
# name, and the client requirement the service holds every connection to.
readonly SERVICE_CHECKS="conformance.tiny conformance.matrix refusal.noHandle refusal.pipe refusal.writable
    refusal.otherFile refusal.control refusal.missingToken supersede.lateReply supersede.queuedNeverSent stall.timedOut
    stall.newConnection stall.answeredWhileTheStalledRun kill.typedError kill.nextLookupSucceeds idle.exitsWhenQuiet
    idle.workSpanningTheTimer idle.racingRequestsAnsweredOnce"

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

service_stage() {
    local since subset="" file="$reports/service-report.json" count i name passed detail seen=" " wanted
    since=$(date '+%Y-%m-%d %H:%M:%S')
    [ ! -s "$home/service-checks" ] || subset=$(cat "$home/service-checks")
    if ! report --service-report 600 "$home/fixtures" ${subset:+--checks "$subset"} >/dev/null; then
        flunk "service: --service-report wrote nothing within 600 s ($(head -c 300 "$reports/service-report.err" 2>/dev/null))"
    else
        count=$(plutil -extract checks raw -o - "$file" 2>/dev/null || echo 0)
        [ "$count" -gt 0 ] || flunk "service: the instrument reported no check: $(head -c 300 "$file")"
        for (( i = 0; i < count; i++ )); do
            name=$(plutil -extract "checks.$i.name" raw -o - "$file")
            passed=$(plutil -extract "checks.$i.pass" raw -o - "$file")
            detail=$(plutil -extract "checks.$i.detail" raw -o - "$file")
            seen="$seen$name "
            if [ "$passed" = true ]; then pass "service: $name — ${detail:0:240}"; else flunk "service: $name — ${detail:0:900}"; fi
        done
        if [ -z "$subset" ]; then
            for wanted in $SERVICE_CHECKS; do
                case $seen in *" $wanted "*) ;; *) flunk "service: $wanted was never reported: the instrument stopped before it" ;; esac
            done
        fi
        echo "      facts: $(plutil -extract facts json -o - "$file" 2>/dev/null | head -c 1500)"
    fi

    # **Who reaches the service by name.** The executable in the bundle, run from this shell, does: the control. The same
    # executable copied out of the bundle does not, and starts no service: an embedded XPC service is found in the asking
    # program's own bundle, and the copy has none. The copy is signed ad hoc, because with the bundle's signature outside
    # the bundle AMFI kills it at launch (measured 2026-10-14), which would say nothing about the name.
    local said status before=" " after="" pid outside="$reports/outside/XDict"
    status=0; said=$(bounded 30 "$exe" --connect-report 2>&1) || status=$?
    if [ "$status" -eq 0 ] && grep -q '"connected":true' <<<"$said"; then
        pass "service: the bundle's executable reaches its service by name"
    else
        flunk "service: the bundle's executable did not reach its service by name (exit $status): ${said:0:300}"
    fi
    mkdir -p "$reports/outside"
    cp "$exe" "$outside"
    codesign -s - -f "$outside" >/dev/null 2>&1 || flunk "service: the copy outside the bundle could not be signed ad hoc"
    find_pids "$service"
    [ "${#PIDS[@]}" -eq 0 ] || before=" ${PIDS[*]} "
    status=0; said=$(bounded 30 "$outside" --connect-report 2>&1) || status=$?
    find_pids "$service"
    if [ "${#PIDS[@]}" -gt 0 ]; then
        for pid in "${PIDS[@]}"; do case $before in *" $pid "*) ;; *) after="$after $pid" ;; esac; done
    fi
    if [ "$status" -eq 1 ] && grep -q '"connected":false' <<<"$said" && [ -z "$after" ]; then
        pass "service: a copy of the app outside the bundle cannot reach the service by name ($(grep -o '"failure":"[^"]*"' <<<"$said"))"
    else
        flunk "service: a copy of the app outside the bundle: exit $status, new service processes:${after:- none}; ${said:0:300}"
    fi

    # **The client requirement.** Each start of the service logs the requirement it holds every connection to, or that it
    # could build none and refuses everyone; this stage started it several times (the kill, the idle exit). It must name
    # the app and the team that signed this bundle (read from the bundle's signature, and not printed).
    local team logged required refused
    team=$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')
    logged=$(/usr/bin/log show --start "$since" --style compact \
        --predicate 'subsystem == "ai.xdict.app.DictionaryService" AND category == "service"' 2>&1 || true)
    required=$(grep -cF "client requirement: anchor apple generic and identifier \"ai.xdict.app\" and certificate leaf[subject.OU] = \"$team\"" <<<"$logged" || true)
    refused=$(grep -c "no client requirement could be built" <<<"$logged" || true)
    if [ -n "$team" ] && [ "$required" -gt 0 ] && [ "$refused" -eq 0 ]; then
        pass "service: the service set its client requirement, the app's identifier and this bundle's own team, at each of $required starts; none failed to build one"
    else
        flunk "service: the client requirement: ${team:+with this bundle's team }logged at $required starts, $refused could not build one${team:- (the bundle's signature names no team)}"
    fi
}
service_stage
fi

# ---------------------------------------------------------------------------------------------------------------------
if want hostile; then
# **hostile**: the hostile-input suite through the production entry view (plan-macos-v1 WI-4; ADR-0007 decision 14).
# One observed run per configuration in `cases.json` (no layer, each layer alone, the navigation table with and
# without the link-preconnect switch, production), then the suite's rules (`analyze.py suite`): every observer shown
# its deliberate attempt, every case loaded, each layer's probes leaving with it off and refused with it on, and
# production at zero on every observer. Then fail-closed: each WebKit-switch fault refuses with its own sentence and
# makes no web view, beside a control that renders. Then one web view per dictionary: twins with the same paths keep
# their own answers across a held request and a switch. Results stay on the E2E Mac under results/hostile.
hostile_stage() {
    local results="$home/results/hostile" label off fault
    rm -rf "$results"
    mkdir -p "$results"
    cp "$kit/cases.json" "$results/cases.json"
    for label in $(python3 -I "$kit/analyze.py" runs "$kit/cases.json"); do
        off=$(python3 -I "$kit/analyze.py" off "$kit/cases.json" "$label")
        if "$kit/run-hostile.sh" "$kit" "$results" "$label" hostile ${off:+--disable-layer "$off"} \
            >"$results/$label.log" 2>&1; then
            echo "      $label: $(tail -1 "$results/$label.log")"
        else
            flunk "hostile: the $label run did not happen as described — $(tail -2 "$results/$label.log" | tr '\n' ' ')"
        fi
    done
    python3 -I "$kit/analyze.py" suite "$results" >"$results/suite.txt" 2>&1 || true
    verdicts hostile "$results/suite.txt"

    for fault in none missing-list missing-feature missing-setter missing-getter ineffective-setter; do
        lab_report "$results/fault-$fault.json" 60 --fault-switch "$fault" --fixture "$kit/fixtures/hostile" \
            || echo "      fault $fault: no report ($(head -c 300 "$results/fault-$fault.json.err" 2>/dev/null))"
    done
    python3 -I "$kit/analyze.py" faults "$results" >"$results/faults.txt" 2>&1 || true
    verdicts hostile "$results/faults.txt"

    lab_report "$results/binding.json" 90 --binding "$kit/fixtures/twin-a" "$kit/fixtures/twin-b" \
        || echo "      binding: no report ($(head -c 300 "$results/binding.json.err" 2>/dev/null))"
    python3 -I "$kit/analyze.py" binding "$results" >"$results/binding.txt" 2>&1 || true
    verdicts hostile "$results/binding.txt"
}
hostile_stage
fi

# ---------------------------------------------------------------------------------------------------------------------
if want reader; then
# **reader**: a person's hands on the production entry view (ADR-0009 refutation, item 8). Real pointer events from
# `pointer` (hover; plain, command-, option- and shift-clicks; downloads; the context menu; drags out of the view), the
# observers watching the reader entry's own ports and names: nothing leaves, every remote question is a native prompt
# answered by a real click, and only the one "Open in Browser" reaches the opener.
reader_stage() {
    local results="$home/results/reader" access
    rm -rf "$results"
    mkdir -p "$results"
    access=$("$kit/pointer" access 2>&1 || true)
    if ! grep -q '"postEvents":true' <<<"$access"; then
        flunk "reader: this SSH session may not post events ($access): grant Accessibility (Privacy & Security, Device Control and Data Access) to sshd-keygen-wrapper on the E2E Mac; nothing was driven"
        return 0
    fi
    pass "reader: this session may post events ($access)"
    if ! "$kit/run-hostile.sh" "$kit" "$results" reader reader >"$results/run.log" 2>&1; then
        flunk "reader: the run did not happen as described — $(tail -2 "$results/run.log" | tr '\n' ' ')"
        return 0
    fi
    python3 -I "$kit/analyze.py" verdicts "$results/reader" >"$results/verdicts.txt" 2>&1 || true
    verdicts reader "$results/verdicts.txt"
    grep '^NOTE' "$results/verdicts.txt" | sed 's/^NOTE /      /' || true
}
reader_stage
fi

# ---------------------------------------------------------------------------------------------------------------------
if want entries; then
# **entries**: the owner's dictionaries through the production entry view (plan-macos-v1 WI-4, done-when):
# `entries_corpus`'s sample renders with every image and stylesheet the core resolves loaded and nothing outside
# `xdict:`; OALD's and LDOCE's folding scripts open a section (R5); LDOCE's *hold* finishes, find's count equals a count
# over the entry's text, and a narrow window stays usable; zoom and appearance survive a relaunch per dictionary.
entries_stage() {
    local results="$home/results/entries"
    rm -rf "$results"
    mkdir -p "$results"
    if [ ! -s "$kit/entries-sample.json" ] || [ ! -d "$home/corpus" ]; then
        flunk "entries: not measured — no corpus on the E2E Mac (set XDICT_E2E_CORPUS on the build Mac)"
        return 0
    fi
    lab_report "$results/corpus.json" 5400 --corpus "$home/corpus" --sample "$kit/entries-sample.json" \
        || echo "      corpus: no report ($(head -c 300 "$results/corpus.json.err" 2>/dev/null))"
    defaults delete ai.xdict.lab.persistence >/dev/null 2>&1 || true
    lab_report "$results/persistence-set.json" 120 --corpus "$home/corpus" --persistence set \
        || echo "      persistence set: no report ($(head -c 300 "$results/persistence-set.json.err" 2>/dev/null))"
    lab_report "$results/persistence-check.json" 120 --corpus "$home/corpus" --persistence check \
        || echo "      persistence check: no report ($(head -c 300 "$results/persistence-check.json.err" 2>/dev/null))"
    python3 -I "$kit/analyze.py" entries "$results" >"$results/verdicts.txt" 2>&1 || true
    verdicts entries "$results/verdicts.txt"
    grep '^NOTE' "$results/verdicts.txt" | sed 's/^NOTE /      /' || true
}
entries_stage
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
# What the entry view's stages measured (each run's observations, summaries, the suite's matrix), kept here for reading;
# the verdicts are the log's. A copy that fails costs the detail, not the run.
if on_host "test -d '$REMOTE_DIR/results'"; then
    mkdir -p .build/e2e-results
    rsync -a -e "$SSH -o BatchMode=yes -o ConnectTimeout=15" "$host:$REMOTE_DIR/results/" .build/e2e-results/ \
        || echo "the stages' results could not be copied back from the E2E Mac"
fi

if [ -n "$expected_override" ] || [ -n "$service_checks" ]; then
    echo
    echo "a positive control or a subset (XDICT_E2E_EXPECTED_VERSIONS, XDICT_E2E_SERVICE_CHECKS): nothing is recorded"
    exit "$remote_status"
fi
# The tree likewise: one that moved while the stages ran is no tree this run tested.
[ "$source_tree" = - ] || [ "$source_tree" = "$(Tools/source-tree.sh)" ] || source_tree=-
Tools/e2e-status.sh record "$remote_version" "$remote_uuid" "$e2e_os" "$source_tree" "$build_mode" <"$RUN_LOG"
echo
Tools/e2e-status.sh show
exit "$remote_status"
