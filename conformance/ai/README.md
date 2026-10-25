# The AI contract's fixtures

**Owned by the shells, not the core.** The contract (`CONTRACT.md`) binds every shell's "meaning here" ask; the core only
supplies `entry_text` (`conformance/capture/` owns the sentence). Each shell runs these fixtures through its own
implementation — never through a core binding.

## Files

| File | What it is |
|---|---|
| `CONTRACT.md` | the normative text, `ai-contract: 4` |
| `vectors.jsonl` | `mark`, `compose` and `validate` cases, grammar `format: 1` |
| `defaults/<language>.<mode>.txt` | the shipped default templates, one per language and mode |
| a shell's runner | not here: macOS keeps its runner in its own test tree (`apps/apple/Tests/XDictAITests/AIContractTests.swift`) |

## How a shell runs the vectors

1. **`mark`** — the marking rule (CONTRACT.md §3): feed `sentence` and `range`, compare the complete `«…»`-marked text,
   ordinal UTF-16. A range that cannot be applied marks nothing.
2. **`compose`** — the template rules (§4): feed the template, mode and values; compare the **complete composed question**,
   including the answer-language line (§4b) and the fixed response contract appended after one blank line (§6), byte for
   byte. An invalid case compares the
   stable code (`template.unknownPlaceholder`, `template.missingPlaceholder`, `template.entryInSentenceOnly`,
   `template.tooLong`).
3. **`validate`** — the answer rules (§5): feed the answer object, the entry (`text`, `complete`) and the mode; compare
   the validated outcome, or the stable code (`answer.shape`, `answer.outcome`, `answer.quote.notFound`,
   `answer.quote.count`, `answer.quote.tooLong`, `answer.explanation`, `answer.noMatchingSenseOnPartial`,
   `answer.ungrounded`).

A case that cannot be decoded is a **harness failure**, never an expected refusal. The runner prints the executed case
ids, the count and the suite revision (`shasum -a 256 vectors.jsonl`).

## What the fixtures do not cover

Provider behaviour — an endpoint that ignores the schema, a CLI that remembers a previous turn, a guardrail refusal from
Apple's model — is native acceptance, per shell (CONTRACT.md §8.3). The lifecycle and privacy checks are native tests too:
one operation per ask, cancellation, no history, consent at send, preview equals sent bytes.

## Adding a case

A case states one behaviour this contract already requires. Add it, show the shell's runner red against a mutation of the
implementation if it guards one, and bump nothing: the suite revision changes, the grammar and the major do not.

## Non-negotiables

- No dictionary content in a fixture: every entry text here is written for the test.
- No real API key, endpoint or reader text in a fixture.
- The fixed response contract's bytes are copied from `CONTRACT.md` §6 exactly; a runner that builds a different suffix
  fails the `compose` cases, which is the point.
