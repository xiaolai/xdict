# The reading history's conformance vectors

`cases.json` is the history every binding must agree on (ADR-0023, ADR-0024): the outcomes of recording seven
readings in order against a fresh core, and the days the core answers for them. It is run through each binding's own
production API — the UniFFI Swift binding, the UniFFI Kotlin binding, and `xdict-wasm` with its TypeScript wrapper —
never by calling the core directly. The core's own test reads the same file, so a binding and the core cannot drift
apart without one of them failing.

The rules the vectors exercise, and which no shell may reimplement:

- **Retry identity is the operation id**, not the reading's content: `op-1` twice is one event; the same reading under
  `op-2` is a second event, and the day collapses it into one card with `times`.
- **The language filter runs before anything is written.** A reading outside the target languages (and an unknown
  language with a non-empty set) writes nothing — not even its sentence. An empty set keeps every language.
- **A day is a calendar day in the reader's zone**, not a 24-hour window: 00:10 the next day is the next day, and the
  label (`today`, `yesterday`, `weekday`, `date`) is the core's.
- **The history's cards are newest first** within a day, and its days are newest first.

Comparing is by subset, as everywhere in `conformance/fixtures/`: every field `expect` names must be present and equal,
and lists must have equal lengths and order — extra fields the binding carries are ignored.

A binding runs this after its fixture scenario: a fresh core (no data directory, so the log is in memory), the
readings in file order, each outcome compared as its own word, then `history` at `history.now` with its UTC offset,
compared with `history.expect`.
