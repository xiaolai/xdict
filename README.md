# XDict

A macOS dictionary for the MDict (`.mdx`/`.mdd`) files you already have.

XDict ships no dictionary content. It reads the dictionaries on your own Mac, where they stay.

Status: early development. Product site: [xdict.ai](https://xdict.ai).

## Licence

ISC — see [LICENSE](LICENSE).

## Layout

| Folder | What it holds |
|---|---|
| `core/` | The Rust core every platform shares: dictionary reading, entry processing, identity, lookup, study |
| `apps/` | One native app per platform: macOS and iOS (Swift), Android (Kotlin), Windows (C#), Linux (Rust, GTK4), Web (TypeScript) |
| `conformance/` | Fixtures every platform runs to prove it behaves like the others |
