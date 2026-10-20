# The capture contract's fixtures

**Owned by the shells, not the core.** The contract (`CONTRACT.md`) binds every platform shell's capture; the fixtures
here are language-neutral, and each shell runs them through its own capture runner — never through a core binding (the
core never sees a `CapturedTerm`: ADR-0014 d.1, d.9). The core-binding fixtures live in `../fixtures/`.

## Files

| File | What it is |
|---|---|
| `CONTRACT.md` | the normative text, `capture-contract: 1` |
| `vectors.jsonl` | value cases, grammar `format: 1`: one case a line, complete input and complete expected output |
| `lifecycle.md` | the request-lifecycle scenarios a shell runs with its own native tests |
| a shell's runner | not here: each shell keeps its runner in its own test tree (macOS: `apps/apple/Tests/XDictCaptureTests/CaptureContractTests.swift`) |

## How a shell runs the value fixtures

1. Decode a case into the shell's **native** type and call the **production** constructor. The adapter maps the
   fixture grammar to native values; it must not re-implement validation, round numbers, or substitute an unknown
   variant. A case that cannot be decoded is a **harness failure**, not an expected refusal.
2. Compare the **complete output**, ordinal UTF-16 (`CONTRACT.md` §3). A valid case compares every field; an invalid
   case compares the stable semantic code.
3. Run every case, then print the executed case ids and count and the **suite revision** (a digest of
   `vectors.jsonl`). Never skip a case silently.
4. Fail loudly on an unsupported contract major, an unsupported grammar version, an unknown operation, a duplicate
   id, a malformed record, or a missing file.

To produce the suite revision: `shasum -a 256 vectors.jsonl` (any digest both sides agree on is acceptable; it is
recorded in the evidence line).

## Adding a case

A case states one behaviour this contract already requires. Add it, show the shell's runner red against a mutation of
the implementation if the case is a guard, and bump nothing: the suite revision changes, the grammar and the major do
not. A case that requires a *new* behaviour is a contract change first (`CONTRACT.md`, a major bump, then the case).

## Non-negotiables

- No dictionary content and no captured reader text in a fixture: every sentence here is written for the test.
- The fixtures express **values** only. Ordering, eventual acknowledgement, cancellation, permission behaviour and OCR
  quality are `lifecycle.md` scenarios and native acceptance checks — not vectors.
