# xdict-wasm

`wasm-bindgen` bindings of `xdict-core` for the Web, run in a Worker, and `ts/xdict.ts`, the typed wrapper a
shell calls. Requests and answers are JSON in the core's serde shape; dictionary files are read through
`ByteSource`s the shell implements (`FileReaderSync`, `FileSystemSyncAccessHandle`) and never uploaded. A
panic is a trap here, reported as `internal`; the instance is then replaced (ADR-0007 decision 12).

`test-worker.sh` runs `conformance/` through it in a Node Worker.
