# xdict-core

The single API every platform calls (ADR-0007): `Core::new`, `import`, `open`, `close`, `lookup`, `suggest`,
`entry`, `link`, `resource`. Message-shaped: plain records and enums, handles for what is open, typed errors,
no panic across the boundary. It composes `xdict-mdx` today; `xdict-entry`, `xdict-identity`, `xdict-lookup`
and `xdict-study` join it as they are built. `xdict-ffi` and `xdict-wasm` expose it; the Linux shell calls it
directly. The `serde` feature gives the JSON shape the Web binding speaks.
