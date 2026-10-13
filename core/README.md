# core

The Rust core every XDict platform shares: one Cargo workspace. Nothing that makes a platform feel native
lives here (UI, capture, permissions, speech output, file pickers, the entry view); everything that must
behave identically everywhere does. No panic crosses its boundary; every exported function returns a
typed error.

| Crate | What it holds | Status |
|---|---|---|
| `xdict-mdx` | Clean-room reader for MDict `.mdx`/`.mdd`, formats 1.2, 2.0 and 3.0 | working |
| `xdict-mdx-writer` | Writes test files, damaged ones included; never shipped | working |
| `xdict-entry` | Entry processing: `@@@LINK=`, `entry://`, `sound://`, stylesheet substitution, link rewriting | empty |
| `xdict-identity` | Edition identity (SHA-256 of the whole file) and dictionary lineage | empty |
| `xdict-lookup` | Key folding and lemma fallback from the dictionary's own inflections | empty |
| `xdict-study` | Spaced-repetition scheduler, ledger, append-only event log, sync merge | empty |
| `xdict-core` | The one API the platforms call, composed from the crates above | empty |
| `xdict-ffi` | UniFFI bindings of `xdict-core` for Swift and Kotlin (and C#, if the spike chooses UniFFI) | empty |
| `xdict-wasm` | `wasm-bindgen` bindings of `xdict-core` for the Web | empty |

`cd core && cargo test && cargo clippy --all-targets` is the gate.
