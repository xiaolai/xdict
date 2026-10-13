# core

The Rust core every XDict platform shares: one Cargo workspace. Nothing that makes a platform feel native
lives here (UI, capture, permissions, speech output, file pickers, the entry view); everything that must
behave identically everywhere does. No panic crosses its boundary; every exported function returns a
typed error.

| Crate | What it holds | Status |
|---|---|---|
| `xdict-mdx` | Clean-room reader for MDict `.mdx`/`.mdd`, formats 1.2, 2.0 and 3.0, and its per-edition index | working |
| `xdict-mmap` | Read-only maps of XDict's own index files; the one crate allowed `unsafe`, its argument written down | working |
| `xdict-mdx-writer` | Writes test files, damaged ones included; never shipped | working |
| `xdict-entry` | Entry processing: every link classified and rewritten under the view's base, resource paths canonical and encoded, `StyleSheet` substitution (redirects are `xdict-lookup`'s) | working |
| `xdict-identity` | Edition identity (SHA-256 of the whole file), volume tokens, lineages and the registry | working |
| `xdict-lookup` | What a query finds: the two tiers, internal keys, redirects followed breadth first, suggestions; lemma fallback later | working |
| `xdict-study` | Spaced-repetition scheduler, ledger, append-only event log, sync merge | empty |
| `xdict-core` | The one API the platforms call, composed from the crates above (ADR-0007) | interface settled; a thin core behind it |
| `xdict-ffi` | UniFFI bindings of `xdict-core` for Swift and Kotlin (and C#, if the spike chooses UniFFI) | working; conformance in Swift and Kotlin |
| `xdict-wasm` | `wasm-bindgen` bindings of `xdict-core` for the Web, and their TypeScript wrapper | working; conformance in a Worker |
| `xdict-conformance` | Writes `conformance/` fixtures and runs them against the core directly; never shipped | working |

`cd core && cargo fmt --check && cargo test && cargo clippy --all-targets` is the gate; the bindings' suites are
listed in `conformance/README.md`.
