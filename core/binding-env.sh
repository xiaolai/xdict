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
    case $(uname) in Darwin) native_lib=libxdict_ffi.dylib ;; *) native_lib=libxdict_ffi.so ;; esac
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
