# shellcheck shell=sh
# What the binding scripts share (xdict-ffi/{test-swift,test-kotlin,measure-memory}.sh,
# xdict-wasm/{test-worker,measure-memory}.sh): sourced, never run. POSIX sh; the caller sets `set -eu` and `$core`,
# and works from `$core` once it has made its paths absolute.
: "${core:?binding-env.sh is sourced after the caller sets core}"

# $1 as an absolute path, read against the directory the script was started in: call it before any `cd`.
absolute() {
    case $1 in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$PWD" "$1" ;;
    esac
}

# The workspace's target directory as Cargo resolves it (CARGO_TARGET_DIR, a config's build.target-dir, or
# core/target), so that a build and the step reading its output agree. Read from Cargo's JSON without a JSON
# parser: a path JSON had to escape (a quote, a backslash, a control character) holds a backslash as written
# there, and is refused rather than misread.
target_dir() {
    dir=$(cd "$core" && cargo metadata --format-version 1 --no-deps |
        sed -n 's/.*"target_directory":"\([^"]*\)".*/\1/p')
    [ -n "$dir" ] || { echo "cargo metadata named no target directory" >&2; return 1; }
    case $dir in
    *\\*) echo "the target directory's name needs escaping in JSON, which this script does not read: $dir" >&2
        return 1 ;;
    esac
    printf '%s\n' "$dir"
}

# The triple of the machine running this, which the native library is built for.
host_triple() {
    host=$(rustc -vV | sed -n 's/^host: //p')
    [ -n "$host" ] || { echo "rustc named no host triple" >&2; return 1; }
    printf '%s\n' "$host"
}

# The core built as a native library (release), and its UniFFI binding for $1 (swift, kotlin) generated into $2.
# Sets $release, the directory that holds the library. Built for the host by name, so its artifacts are under
# target/<host>/release whatever build target a Cargo configuration sets.
native_binding() {
    case $(uname) in
        Darwin) native_lib=libxdict_ffi.dylib ;;
        MINGW*|MSYS*|CYGWIN*) native_lib=xdict_ffi.dll ;;
        *) native_lib=libxdict_ffi.so ;;
    esac
    host=$(host_triple)
    release=$(target_dir)/$host/release
    cargo build -q --release -p xdict-ffi --target "$host"
    cargo run -q --release -p xdict-ffi --target "$host" --features bindgen --bin uniffi-bindgen -- \
        generate --no-format --library "$release/$native_lib" --language "$1" --out-dir "$2" >/dev/null
}

# A Swift program: the Swift binding in $1 (from native_binding) and the main file $2, compiled into $3, whose
# file name is also the module's name.
swift_program() {
    swiftc -O -module-name "$(basename "$3")" -I "$1" -Xcc -fmodule-map-file="$1/xdictFFI.modulemap" \
        "$1/xdict.swift" "$2" -L "$release" -lxdict_ffi -o "$3"
}

# The core built for wasm32 (release), and its wasm-bindgen package (--target web) written into $1.
web_binding() {
    target=$(target_dir)
    cargo build -q --release -p xdict-wasm --target wasm32-unknown-unknown
    wasm-bindgen --target web --out-dir "$1" "$target/wasm32-unknown-unknown/release/xdict_wasm.wasm"
}

# **Every budget lives here, by name** (the 2026-11-05 audit, G8): `measure-memory.sh` of each binding asks
# `memory_budget <swift|worker> <step>` and writes no number of its own, so a change that needs a higher budget changes
# it here, beside its reason (AGENTS.md: "says why in `binding-env.sh`, beside the number");
# apps/apple/Tools/tests/memory-budgets-test.sh holds the scripts to it. In MiB, the peak of one step in its own process.
# Swift (macOS): measured on an Apple-silicon Mac on 2026-10-16, plus about 2% (see `within`).
MEMORY_BUDGET_SWIFT_IMPORT=16
MEMORY_BUDGET_SWIFT_ENTRY=410
MEMORY_BUDGET_SWIFT_REFUSED=242
MEMORY_BUDGET_SWIFT_RESOURCE=240
# Worker (Node 24 and wasm-bindgen 0.2.129): entry and refused re-set on the single build host (2026-10-17): the same
# core grows wasm memory 2 -> 269 MiB on both hosts, but Node's own resident memory there sits 3-4 MiB above the Mac mini
# these were first measured on (refused 362-363, entry 507-514 on the tree before and after entry-defects alike); ~1%
# above the highest, as before.
MEMORY_BUDGET_WORKER_IMPORT=125
MEMORY_BUDGET_WORKER_ENTRY=520
MEMORY_BUDGET_WORKER_REFUSED=367
MEMORY_BUDGET_WORKER_RESOURCE=333

# memory_budget <swift|worker> <import|entry|refused|resource>: that step's budget in MiB; an unknown one fails loud.
memory_budget() {
    case $1:$2 in
        swift:import) echo "$MEMORY_BUDGET_SWIFT_IMPORT" ;;
        swift:entry) echo "$MEMORY_BUDGET_SWIFT_ENTRY" ;;
        swift:refused) echo "$MEMORY_BUDGET_SWIFT_REFUSED" ;;
        swift:resource) echo "$MEMORY_BUDGET_SWIFT_RESOURCE" ;;
        worker:import) echo "$MEMORY_BUDGET_WORKER_IMPORT" ;;
        worker:entry) echo "$MEMORY_BUDGET_WORKER_ENTRY" ;;
        worker:refused) echo "$MEMORY_BUDGET_WORKER_REFUSED" ;;
        worker:resource) echo "$MEMORY_BUDGET_WORKER_RESOURCE" ;;
        *) echo "no memory budget for $1 $2" >&2; return 1 ;;
    esac
}

# A memory step's line ("…, N MiB after; …") held to $2 MiB: its peak past that is reported and returns 1. The
# budgets are what was measured on an Apple-silicon Mac on 2026-10-16, plus about 2%. They sit above the
# 2026-10-14 baseline (aa67039: Swift entry 369, refused 224; Worker entry 481, refused 333) by what the roles' tree
# holds per element followed (a 160-byte node, its name, its children, and the icon rules' detail where an element
# has any), about 18 MiB for the fixture's 65,536 elements.
within() {
    after=$(printf '%s\n' "$1" | sed -n 's/.* \([0-9][0-9]*\) MiB after.*/\1/p')
    [ -n "$after" ] || { echo "no peak in: $1" >&2; return 1; }
    [ "$after" -le "$2" ] || { echo "over budget: $after MiB, the most is $2 MiB" >&2; return 1; }
}
