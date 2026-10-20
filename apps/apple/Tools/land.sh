#!/bin/bash
# **One landing command** (`make land`): every gate this tree needs, at once, one build Mac each, and a table at the end.
#
#   Tools/land.sh                 the gates whose inputs changed since their last pass (Tools/gate-cache.py)
#   FULL=1 Tools/land.sh          every gate, the cache ignored
#   ONLY=core,entries Tools/land.sh   those gates only
#
# The gates and what they read are AGENTS.md's "Which gates a change needs": the core gate (fmt, test, clippy),
# `make test`, entries_corpus on the 24, the three binding tests, the two memory scripts, the lookup corpus test and
# the format-3.0 test. **A gate whose key already passed prints `cached pass` and does nothing**, so this is also what
# runs after a change of nothing: every gate cached, in seconds, and no host asked.
#
# **No E2E** (owner, 2026-10-17: E2E runs only on the owner's demand). The last line says what is pending
# (`Tools/e2e-run.sh pending`): `E2E suggested: <sub-stages> — <changed paths>`, or `E2E: nothing pending`; then the
# renders (`Tools/gallery/render_affected.py pending`): `Render needed (not run): …`, or `Render: nothing pending`.
#
# Hosts come from local.mk (BUILD_HOSTS, BUILD_HOSTS_XCODE; one Mac since 2026-10-17), each locked, then probed once: Rust 1.99.0 with rustfmt and clippy,
# SwiftLint 0.65.1 and Xcode for `make test`, the 24 for the corpus tests, `~/bin/run1` for the bindings, and no cargo
# or swift build of anyone else's running. An unfit host is skipped with its reason. Each gate gets its own host where
# one is free; on a host, `make test` and the cargo gates run side by side, each lane in its own copy of the tree,
# `xdict-build/<checkout>-land-swift/` and `-land-cargo/`. Never the Air: it only orchestrates.
#
# **It never re-runs anything.** On a failure it prints the command that runs only that gate (or those sub-stages).
set -uo pipefail
cd "$(dirname "$0")/.."
APPLE=$PWD
REPO=$(cd ../.. && pwd)
fail() { echo "land: $*" >&2; exit 1; }
readonly RUST=1.99.0 SWIFTLINT=0.65.1

# command_of <gate> <corpus folder on the host>: run from the copy's root, cargo pinned to $RUST.
command_of() {
    local corpus=\$HOME/$2
    case $1 in
        core) echo "cd core && cargo fmt --check && cargo test && cargo clippy --all-targets && cargo test -p xdict-core --no-run -q" ;;
        # The tool tests read git (the source tree): the copy has none, so it gets a snapshot. No hooks: a host's own
        # global hooks (the build Mac's, 2026-10-17) judge commits meant for a repository, not this throwaway one.
        apple-test) echo "rm -rf .git && git init -q && git add -A && git -c core.hooksPath=/dev/null -c user.name=land -c user.email=land@localhost commit -qm snapshot && cd apps/apple && XDICT_KNOWN_COMMITS=\$PWD/../../.known-commits make test" ;;
        entries) echo "cd core && XDICT_MDX_CORPUS=$corpus cargo test --release -p xdict-core --test entries_corpus -- --nocapture" ;;
        lookup-corpus) echo "cd core && XDICT_MDX_CORPUS=$corpus cargo test --release -p xdict-lookup --test corpus -- --nocapture" ;;
        # Run in the host's copy, which is flat: dev-docs/ sits at the copy's root, whatever the Air's workspace looks
        # like (the fixtures are rsynced there below).
        mdx-v3) echo "cd core && XDICT_MDX_MDXBUILDER_V3=\$PWD/../dev-docs/fixtures/mdxbuilder-4.0-v3/synthetic-v3.mdx cargo test -p xdict-mdx --test mdxbuilder" ;;
        # run1 <log name> <command>: the binding toolchain's PATH and JAVA_HOME; its log is ~/logs/<name>.log there.
        bindings) echo "export TAILN=30; ~/bin/run1 land-swift core/xdict-ffi/test-swift.sh && ~/bin/run1 land-kotlin core/xdict-ffi/test-kotlin.sh && ~/bin/run1 land-worker core/xdict-wasm/test-worker.sh" ;;
        memory) echo "export TAILN=30; ~/bin/run1 land-memory-swift core/xdict-ffi/measure-memory.sh && ~/bin/run1 land-memory-worker core/xdict-wasm/measure-memory.sh" ;;
    esac
}
# The facts a gate's key holds besides its inputs, one `--fact` argument a line; Tools/tests/land-test.sh reads them
# here rather than repeating them. What the gate runs is one: a changed command is a gate never passed.
facts_of() {
    echo "--fact"; echo "rust=$RUST"
    echo "--fact"; echo "command=$(command_of "$1" corpus | shasum -a 256 | cut -c1-16)"
    case $1 in
        apple-test) echo "--fact"; echo "swiftlint=$SWIFTLINT" ;;
        entries | lookup-corpus) echo "--fact"; echo "corpus=$2" ;;
    esac
}
if [ "${1:-}" = --facts-of ]; then facts_of "${2:?gate}" "${3:-}"; exit 0; fi
readonly CORPUS_NAME=the24
# The tests name others (Tools/tests/land-test.sh).
readonly AIR_CORPUS=${XDICT_LAND_CORPUS:-$HOME/xdict-corpus/$CORPUS_NAME}
readonly LOCAL_MK=${XDICT_LAND_LOCAL_MK:-$REPO/local.mk}
MAIN=$(Tools/main-checkout.sh "$REPO") || fail "no main checkout"
NAME=$(basename "$REPO")
[[ "$NAME" =~ ^[A-Za-z0-9._-]+$ ]] || fail "the checkout's folder name is not a plain name: $NAME"
readonly REMOTE=xdict-build/$NAME-land
OUT=$APPLE/.build/land
rm -rf "$OUT"
mkdir -p "$OUT"
started=$(date +%s)

mk() { awk -F'=' -v k="$1" '{ name = $1; gsub(/^[ \t]+|[ \t]+$/, "", name) } name == k { sub(/^[^=]*=[ \t]*/, ""); print; exit }' "$LOCAL_MK"; }
[ -f "$LOCAL_MK" ] || fail "no local.mk at $LOCAL_MK: it names the build Macs"
BUILD_HOSTS=$(mk BUILD_HOSTS); BUILD_HOSTS_XCODE=$(mk BUILD_HOSTS_XCODE); E2E_BUILD_HOST=$(mk BUILD_HOST)
[ -n "$BUILD_HOSTS" ] || fail "local.mk sets no BUILD_HOSTS"

# --- What is needed --------------------------------------------------------------------------------------------------
ALL_GATES="core apple-test entries lookup-corpus mdx-v3 bindings memory"
gates=$ALL_GATES
if [ -n "${ONLY:-}" ]; then
    gates=""
    for g in $(tr ',' ' ' <<<"$ONLY"); do
        case " $ALL_GATES " in *" $g "*) gates="$gates $g" ;; *) fail "no gate called $g ($ALL_GATES)" ;; esac
    done
fi
[ -d "$AIR_CORPUS" ] || fail "no corpus at $AIR_CORPUS (the 24: its identity is part of the corpus gates' keys)"
corpus_id=$(python3 -I Tools/gate-cache.py corpus-id "$AIR_CORPUS") || fail "could not read the corpus's identity"
full=()
[ "${FULL:-}" != 1 ] || full=(--full)
: >"$OUT/todo"
for g in $gates; do
    facts=()
    while IFS= read -r a; do facts+=("$a"); done < <(facts_of "$g" "$corpus_id")
    row=$(python3 -I Tools/gate-cache.py status ${full[@]+"${full[@]}"} "${facts[@]}" "$g") || fail "the gate cache failed for $g"
    IFS=$'\t' read -r action _ key why <<<"$row"
    if [ "$action" = skip ]; then
        echo "land: $g: cached pass ${key:0:12} from $why"
        printf '%s\t-\tcached\t0\tcached pass %s from %s\n' "$g" "${key:0:12}" "$why" >"$OUT/$g.result"
    else
        echo "land: $g: run ($why)"
        printf '%s\t%s\n' "$g" "$key" >>"$OUT/todo"
    fi
done

# --- Hosts -----------------------------------------------------------------------------------------------------------
[ -s "$OUT/todo" ] || { BUILD_HOSTS="" BUILD_HOSTS_XCODE=""; }   # all cached: no host asked
probe='export PATH=$HOME/bin:$HOME/.cargo/bin:/opt/homebrew/bin:$PATH
echo "rust=$(rustc +'$RUST' --version 2>/dev/null | awk "{print \$2}")"
echo "fmt=$(cargo +'$RUST' fmt --version >/dev/null 2>&1 && echo yes)"
echo "clippy=$(cargo +'$RUST' clippy --version >/dev/null 2>&1 && echo yes)"
echo "swiftlint=$(swiftlint version 2>/dev/null)"
echo "xcode=$(xcodebuild -version 2>/dev/null | head -1 | awk "{print \$2}")"
echo "corpus=$(n=$(ls -d xdict-corpus/the24/*/ 2>/dev/null | wc -l | tr -d " "); [ "$n" = 24 ] && echo xdict-corpus/the24 || { n=$(ls -d xdict-corpus/the25/*/ 2>/dev/null | wc -l | tr -d " "); [ "$n" = 24 ] && echo xdict-corpus/the25; })"
echo "run1=$(test -x bin/run1 && echo yes)"
echo "busy=$(pgrep -x "cargo|rustc|swift-build|swift-frontend" 2>/dev/null | wc -l | tr -d " ")"'
hosts=$(printf '%s\n' $BUILD_HOSTS $BUILD_HOSTS_XCODE | awk '!seen[$0]++')
# **The host's run lock first** (Tools/host-lock.sh, the one E2E, the gallery, the lab and the tour take): builds and
# E2E share one Mac, so a gate waits for an E2E run there and an E2E run for the gates. Taken in name order.
. Tools/host-lock.sh
locked=""
trap 'for h in $locked; do host_unlock "$h"; done' EXIT
for h in $(printf '%s\n' $hosts | sort); do
    host_lock "$h" land || fail "$h is busy with another XDict run; nothing was run"
    locked="$locked $h"
done
for h in $hosts; do
    ( ssh -o BatchMode=yes -o ConnectTimeout=10 -- "$h" "$probe" >"$OUT/probe.$h" 2>/dev/null || echo "unreachable=yes" >"$OUT/probe.$h" ) &
done
wait
: >"$OUT/hosts"
for h in $hosts; do
    p() { sed -n "s/^$1=//p" "$OUT/probe.$h"; }
    if grep -q '^unreachable=yes' "$OUT/probe.$h"; then echo "land: $h skipped: unreachable"; continue; fi
    # Every XDict run holds the lock taken above, so a build running there now is another project's: slower, not unfit
    # (one Mac since 2026-10-17; skipping it would leave no host).
    [ "$(p busy)" = 0 ] || echo "land: $h: $(p busy) cargo or swift processes of another project are running there"
    caps=""
    if [ "$(p rust)" = "$RUST" ] && [ "$(p fmt)" = yes ] && [ "$(p clippy)" = yes ]; then caps="rust"
    else echo "land: $h: no Rust $RUST with rustfmt and clippy (rustc $(p rust); fmt $(p fmt); clippy $(p clippy)): no cargo gate there"; fi
    if [ -n "$caps" ] && [[ " $BUILD_HOSTS_XCODE " == *" $h "* ]]; then
        if [ "$(p swiftlint)" = "$SWIFTLINT" ] && [ -n "$(p xcode)" ]; then caps="$caps,xcode"
        else echo "land: $h: no SwiftLint $SWIFTLINT with Xcode (SwiftLint $(p swiftlint); Xcode $(p xcode)): no make test there"; fi
    fi
    [ -z "$caps" ] || [ -z "$(p corpus)" ] || caps="$caps,corpus=$(p corpus)"
    [ -z "$caps" ] || [ "$(p run1)" != yes ] || caps="$caps,run1"
    [ -z "$caps" ] || printf '%s\t%s\n' "$h" "$caps" >>"$OUT/hosts"
done

# Each gate to a fit host, the most constrained first; a host taken once, unless no fit host is free (then queued
# behind another gate there). The E2E bundle's build Mac is the last choice for `make test`.
plan=$(python3 -I - "$OUT/todo" "$OUT/hosts" "$E2E_BUILD_HOST" <<'PY'
import sys
todo = [l.split("\t")[0] for l in open(sys.argv[1]).read().splitlines() if l]
hosts = {}
for line in open(sys.argv[2]).read().splitlines():
    h, caps = line.split("\t")
    hosts[h] = set(c.split("=")[0] for c in caps.split(","))
e2e_build = sys.argv[3]
need = {"core": {"rust"}, "apple-test": {"rust", "xcode"}, "entries": {"rust", "corpus"},
        "lookup-corpus": {"rust", "corpus"}, "mdx-v3": {"rust"}, "bindings": {"rust", "run1"},
        "memory": {"rust", "run1"}}
fit = {g: [h for h in hosts if need[g] <= hosts[h]] for g in todo}
jobs = {}
for g in sorted(todo, key=lambda g: len(fit[g])):
    if not fit[g]:
        print(f"{g}\t-")
        continue
    # Prefer a free host with the fewest capabilities, so the rare ones stay free; the E2E build Mac last.
    free = sorted(fit[g], key=lambda h: (len(jobs.get(h, [])), h == e2e_build, len(hosts[h])))
    h = free[0]
    jobs.setdefault(h, []).append(g)
# Two lanes a host, each in a copy of its own: `make test` beside the cargo gates, which run in turn (they share one
# target folder, whose cargo lock would only queue them). One Mac runs every gate since 2026-10-17.
for h, gs in jobs.items():
    for lane, part in (("swift", [g for g in gs if g == "apple-test"]), ("cargo", [g for g in gs if g != "apple-test"])):
        if part:
            print(f"{' '.join(part)}\t{h}\t{lane}")
PY
) || fail "could not place the gates"

# --- The gates -------------------------------------------------------------------------------------------------------
# A green run that measured nothing is not a pass: each corpus test must print the line only a measured run prints
# (the files' "not measured" lines belong to other variables of the same test files, so their absence proves nothing).
measured() {
    case $1 in
        entries) grep -q 'entries; written links' "$2" && grep -q 'entries_of_the_corpus \.\.\. ok' "$2" ;;
        lookup-corpus) grep -qE '^24 files: ' "$2" ;;
        *) return 0 ;;
    esac
}

# host_job <host> <lane> <gate...>: copy once, to the lane's own folder, then each gate there in turn.
host_job() {
    local host=$1 lane=$2 remote=$REMOTE-$2 g corpus t0 status key line
    shift 2
    local rlog=$OUT/rsync.$host.$lane
    corpus=$(awk -F'\t' -v h="$host" '$1 == h' "$OUT/hosts" | tr ',' '\n' | sed -n 's/^corpus=//p')
    if ! rsync -a --delete --exclude target --exclude .build --exclude node_modules --exclude '*.mdx' --exclude '*.mdd' \
        --exclude /local.mk --exclude .git "$REPO/" "$host:$remote/" >"$rlog" 2>&1; then
        for g in "$@"; do printf '%s\t%s\tran\t0\tcould not copy the tree: %s\n' "$g" "$host" "$(tail -1 "$rlog")" >"$OUT/$g.result"; done
        return
    fi
    for g in "$@"; do
        # The format-3.0 test's file is an .mdx, which the copy leaves out: sent alone (it is MDXBuilder's, not content).
        # dev-docs/ is a sibling of the main checkout (the workspace root), so a worktree has none of its own.
        # The snapshot has no history: the ledger's commits are checked against the Air's list (ledger.py check).
        if [ "$g" = apple-test ]; then
            git -C "$REPO" rev-list --all >"$OUT/known-commits.$lane" &&
                rsync -a "$OUT/known-commits.$lane" "$host:$remote/.known-commits" >>"$rlog" 2>&1
        fi
        if [ "$g" = mdx-v3 ]; then
            rsync -a "$(dirname "$MAIN")/dev-docs/fixtures/mdxbuilder-4.0-v3/" "$host:$remote/dev-docs/fixtures/mdxbuilder-4.0-v3/" >>"$rlog" 2>&1
        fi
        t0=$(date +%s)
        # The toolchain pinned only where the default is another: a pinned name can be a second install without the
        # default's targets (wasm32 on the bindings' host, 2026-10-17).
        ssh -o BatchMode=yes -- "$host" "set -o pipefail; export PATH=\$HOME/bin:\$HOME/.cargo/bin:/opt/homebrew/bin:\$PATH
[ \"\$(rustc --version 2>/dev/null | awk '{print \$2}')\" = $RUST ] || export RUSTUP_TOOLCHAIN=$RUST
cd $remote && $(command_of "$g" "$corpus")" >"$OUT/$g.log" 2>&1
        status=$?
        [ "$status" != 0 ] || measured "$g" "$OUT/$g.log" || status=97
        line=$(grep -v '^[[:space:]]*$' "$OUT/$g.log" | tail -1 | cut -c1-90)
        [ "$status" != 97 ] || line="green, but the corpus was not measured"
        if [ "$status" = 0 ]; then
            key=$(awk -F'\t' -v g="$g" '$1 == g { print $2 }' "$OUT/todo")
            python3 -I Tools/gate-cache.py record "$g" "$key" "$(( $(date +%s) - t0 ))" "$host" || line="passed; NOT cached: $line"
        fi
        printf '%s\t%s\tran\t%s\t%s %s\n' "$g" "$host" "$(( $(date +%s) - t0 ))" "$([ "$status" = 0 ] && echo PASS || echo "FAIL($status)")" "$line" >"$OUT/$g.result"
    done
}

pids=()
while IFS=$'\t' read -r gs host lane; do
    [ -n "$gs" ] || continue
    if [ "$host" = - ]; then
        printf '%s\t-\tnot run\t0\tFAIL no fit host (see the probe lines above)\n' "$gs" >"$OUT/$gs.result"
        continue
    fi
    echo "land: $host ($lane): $gs"
    # shellcheck disable=SC2086 # gate names, split on purpose
    host_job "$host" "$lane" $gs &
    pids+=($!)
done <<<"$plan"
for p in ${pids[@]+"${pids[@]}"}; do wait "$p"; done

# --- The table -------------------------------------------------------------------------------------------------------
echo
printf '%-14s %-12s %-8s %6s  %s\n' GATE HOST RAN SECS RESULT
failed=""
for g in $ALL_GATES; do
    [ -f "$OUT/$g.result" ] || continue
    IFS=$'\t' read -r _ host ran secs result <"$OUT/$g.result"
    printf '%-14s %-12s %-8s %6s  %s\n' "$g" "$host" "$ran" "$secs" "$result"
    case $result in FAIL*) failed="$failed $g" ;; esac
done
echo "land: wall-clock $(( $(date +%s) - started )) s; logs in $OUT"
for g in $failed; do echo "re-run only $g: make -C apps/apple land ONLY=$g   (log: $OUT/$g.log)"; done
echo
XDICT_E2E_CORPUS=$AIR_CORPUS Tools/e2e-run.sh pending || echo "E2E: could not say what is pending (see above)"
# What renders the change needs, never rendered here (owner, 2026-10-18: renders only as permitted). Computed here, in
# the checkout with its history, not in a gate's copy (which has none); always one line, `cannot compute` included.
render_line=$(python3 -I Tools/gallery/render_affected.py pending 2>"$OUT/render.log")
echo "${render_line:-Render: cannot compute: the selection printed nothing (see $OUT/render.log)}"
[ -z "$failed" ]
