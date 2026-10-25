# The capture contract

**capture-contract: 1** · 2026-10-20 · Normative. A shell MAY NOT claim capture conformance without running the
fixtures in this folder through its own native implementation (`README.md` here says how). Decisions live in ADR-0014
(capture), ADR-0003 d.2/d.5 (shell vs core) and ADR-0007; this file states **what must be identical everywhere**, not
why, and not how any platform reads a word.

## 1. Scope and authority

- **Capture is shell-only.** The core never sees a `CapturedTerm`; only the term string goes on to lookup (ADR-0014
  d.1, d.9). Nothing here may be implemented by importing the core.
- **What is shared are boundary guarantees**, not mechanisms: the value's meaning and validation, the request
  lifecycle, the privacy obligation. How a word and its sentence are read — Accessibility, OCR, pixels, scripts,
  permissions, tiling — is the platform's, and a shell may differ freely there (ADR-0003 d.2).
- The fixtures in this folder are the executable form of this text. Where they disagree, this text is corrected first
  and the fixtures follow; a fixture that cannot be decoded is a harness failure, never a refused capture.

## 2. The value

A **capture** is one immutable `CapturedTerm` with these fields, all mandatory:

| Field | Meaning |
|---|---|
| `term` | the word or phrase as captured, exactly; never trimmed, never truncated, never cleaned |
| `trigger` | what asked: `selection` (shortcut), `service`, `menu`, `pointerGesture` (hover) |
| `acquisition` | how the text was got: `textRange`, `textMarkers`, `boundsScan`, `recognition`, `serviceText`, `ownView`, `elementTitle`, … — **an extensible namespace** |
| `confidence` | finite, in `0…1`; its scope is the platform's and is stated in the mapping (§9) |
| `source` | the app it came from (may be unknown) |
| `pointer` | where and when, or absent |
| `box` | `absent`, `measured` (exact or containing), or `clickPlacement` — a placement valid only at capture time |
| `context` | a context outcome (§4) |

`trigger` and `acquisition` are two fields, never one `method`. A shell MAY add acquisition names; it MUST NOT reuse a
shared name for another meaning, and shared fixtures use no name this table does not list.

## 3. Validation and transformation

A constructor MUST accept or refuse a value by these rules, in this order where order is observable:

1. `term` is not empty and holds no Unicode control character (`Cc`, the C0 and C1 sets). A term with one is
   **refused**, never cleaned: a cleaned key is a key nobody captured. `Cf` (joiners, direction marks) and combining
   marks are meaningful and kept.
2. `confidence` is finite and within `0…1`.
3. Every coordinate is finite.
4. An **available context's** sentence over **`contextCeilingUTF16` = 1,000 UTF-16 units is refused before cleaning**
   (the order is normative: a sentence that would shrink under the ceiling after cleaning is still refused). The
   ceiling is XiaolaiDict's measured sentence bound; a shell's own limit may tighten it and never loosen it.
5. An available context's `term` range is zero-based UTF-16, lies inside the sentence, starts and ends on whole
   characters (no split surrogate), **has the term's own length in UTF-16 units**, and its text equals `term` under
   Unicode canonical equivalence (reordered combining marks of equal length are the same word; a spelling of the same
   word in a different UTF-16 length — NFC against NFD — is not the term). **The range holds the term's own units**, so
   a consumer may take `sentence[range]` as the term without normalizing.
6. In an accepted sentence, `tab`, LF, CR, VT, FF and NEL (U+0085) become a space; every other control character is
   removed; **the range moves with the text**, and its length is unchanged. Combining marks and `Cf` are kept.

**Comparison in conformance is ordinal UTF-16 of the complete output**, never locale-, normalization- or
canonical-insensitive. The semantic rules above are canonical; the *comparison of answers* is byte-exact on the UTF-16
units, so two shells that answer with different admissible spellings disagree and one of them is wrong.

## 4. The context outcome

- `available(sentence, term, cut, gap)` — the sentence around the word, the word's range in it per §3, which outer ends
  were cut (`start`, `end`, or neither) and an internal-gap reason where the sentence spans a boundary the reader could
  not cross.
- `pending(handle)` — the sentence is still being read. A pending handle settles **exactly once**: to an outcome, or to
  the first reading on overdue, or cancelled. Whatever it settles to MUST pass §3 against the term it was held for;
  a settlement that cannot (over the ceiling, outside the sentence, holding another term, or itself `pending`) is held
  as `unavailable(notCaptured)` — fail-closed, never installed as read.
- `unavailable(reason)`: `appExposedNone`, `disagreesWithServiceText`, `notCaptured`, `excluded`.

A **Service's text is always the query**; Accessibility text that disagrees with it supplies neither context nor
geometry.

## 5. Requests and acknowledgements

1. A request is **numbered synchronously, at the gesture**, before any asynchronous work starts. Numbering is separate
   from claiming presentation.
2. Every request reaches **exactly one terminal acknowledgement**, carrying its request number and the result's
   generation. A second, or a stale generation's, changes nothing.
3. A delivery carries a generation greater than zero. A request that is cancelled before any delivery ends with
   generation `0` and outcome `cancelled`.
4. **Every request ends.** A consumer acknowledges (`shown`, `notShown`), or the request is cancelled (refusal,
   supersession, closing the presentation), or the consumer goes; an accepted request that is never acknowledged ends
   when its consumer goes (`consumerGone`) or its presentation closes. The consumer owns this obligation; it MUST end
   every request it accepts.
5. A **Service task is held like a read**: a shortcut, Escape, or a newer Service cancels it, and work that answers
   after the cancellation presents nothing and changes nothing.

## 6. Privacy and untrusted text

- The sentence lives in **one ephemeral session per presentation**, in memory only, with one exception: the reader's
  local reading history (amended 2026-10-21, ADR-0023) may persist it on this device. The next presentation replaces it,
  and its end or the presentation's close drops it from the session. Only the **term** goes to search, the service's
  lookup, the trail, and observation hooks; the service may also read the sentence for phrase matching, under the
  bullet below.
- **The history is the one consumer that may persist the sentence** (amended 2026-10-21, ADR-0023): with the reader's
  history on it writes the sentence to the on-device ledger, never sends it anywhere, and writes nothing while the
  history is off or the reading's language is outside the reader's target set.
- **The one consumer that may send the sentence is the AI pane** (amended 2026-10-20, ADR-0021): on the reader's tap it
  reads the presentation's sentence and the term's range, sends them to the source the reader chose — the entry text only
  under the reader's switch — and keeps nothing when the presentation ends. What it sends is `conformance/ai/`'s
  contract; this one still governs where the sentence lives.
- **The local dictionary service is the second consumer that may read the sentence** (amended 2026-10-26, owner;
  ADR-0033 d.11): on the capture that presents it, the shell may send the sentence and the term's range to the XPC
  dictionary service for **phrase matching only**. It stays on this machine; the service logs nothing of it and stores
  nothing of it; its answer carries the dictionaries' keys and spans, never the sentence. The AI pane remains the only
  consumer that may send it anywhere. macOS's canary for this one is
  `apps/apple/Tests/XDictContractTests/PhrasePrivacyTests.swift` (the request carries it, the answer does not), beside
  `CapturePrivacyCanaryTests`, which still scans what capture itself holds.
- No description, debug description, dump or log written by the application names the sentence. Diagnostics are
  metadata only.
- Captured text is **untrusted data for every consumer**. Prompt handling is the consumer's; preserving the text
  instruction-like is not proof of safety. A shell MUST run a canary showing the sentence reaches no consumer; macOS's
  is `apps/apple/Tests/XDictCaptureTests/CapturePrivacyCanaryTests.swift` (delivery, settlement, cancellation,
  replacement, refusal; every description and mirror inspected). The history adds two cases to that canary (ADR-0023):
  with the history off, a captured sentence reaches no storage and no message; with it on, a reading outside the
  target languages is not stored.
- A **Service's text is the query** and never yields a context or geometry from disagreeing Accessibility text.

## 7. Bounds

Every bound names its unit. Capture applies **acquisition bounds** before segmentation, scanning or formatting
(bytes read, observations, tile size). **Lookup admission** is the consumer's (200 characters; phrases kept) and capture
never silently truncates a key. The context ceiling (§3.4) is capture's.

## 8. Conformance

A shell is compliant when **all three** hold; a passing value suite alone is not compliance:

1. It passes the **value fixtures** in `vectors.jsonl` (grammar version 1) through its production constructor, comparing
   the complete output (§3) and stable semantic refusal codes for single-fault invalid cases.
2. It passes the **lifecycle scenarios** in `lifecycle.md` with its own native tests (§5).
3. It passes its **native acceptance** checks for the platform mechanisms this contract does not constrain
   (permissions, actual event delivery, framework cancellation behaviour, OCR quality).

The runner reports the executed case ids and count and the **suite revision** (a digest of `vectors.jsonl`). A fixture
that cannot be decoded, an unknown operation, or an unsupported version is a harness failure, never a refusal.

## 9. Platform mapping (required)

Each shell records, in its own repository or beside its runner: the native type for `CapturedTerm`; its acquisition
names and meanings; the coordinate space and unit of `box` and `pointer`; what `source` identifies; what a timestamp
means; what `confidence` is measured over; and which triggers and outcomes its platform cannot produce (for example,
Services do not exist on every platform). The mapping is evidence, not code sharing.

## 10. Versioning

Three identities, never conflated:

- **capture-contract major** (this line): changes when validity, output meaning, or a required lifecycle obligation
  changes. A closed enum gaining a required variant is breaking; an acquisition namespace is explicitly extensible, and
  a new acquisition name is not.
- **fixture grammar version** (`vectors.jsonl` `format`): changes when a case's shape changes.
- **suite revision**: a digest of the fixture file, recorded in evidence; it changes with every case.

A runner meeting an unsupported major, an unsupported grammar, or an unknown operation **fails loudly before reporting
conformance**. Behaviour already required by this text may be tested more within the same major; a failure there is an
existing defect, not a compatibility problem.
