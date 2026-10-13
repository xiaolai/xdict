# XDict

A macOS dictionary for the MDict (`.mdx`/`.mdd`) files you already have.

XDict ships no dictionary content. It reads the dictionaries on your own Mac, where they stay.

Status: early development. Product site: [xdict.ai](https://xdict.ai).

## Licence

**Source-available, free for noncommercial use** — the PolyForm Noncommercial License 1.0.0; commercial use needs a separate license. See [LICENSE](LICENSE) and [LICENSING.md](LICENSING.md). Not OSI open source: the license forbids commercial use.

## Layout

| Folder | What it holds |
|---|---|
| `core/` | The Rust core every platform shares: dictionary reading, entry processing, identity, lookup, study |
| `apps/` | One native app per platform: macOS and iOS (Swift), Android (Kotlin), Windows (C#), Linux (Rust, GTK4), Web (TypeScript) |
| `conformance/` | Fixtures every platform runs to prove it behaves like the others |
