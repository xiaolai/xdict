# The Windows wire contract — contract 4

**2026-11-05** · Status: **current, contract 4** — every fixture in `fixtures.jsonl` is decoded, checked against this
schema and re-encoded by `tests/rust` and `tests/cs`; the app's client and the service implement it. Contract 2 added
the learning set (history, notes, review, export/erase, the entry gloss) and raised the JSON envelope to 4 MiB.
Contract 3 added `ledgerSync`, the one writable destination and the service-owned staging inbox/outbox; contract 4 adds `entryText`, the bounded plain text with spans, senses and the cut. Normative for
`apps/windows/`; decisions in ADR-0022, ADR-0023/0037 and ADR-0004.

## 1. Transport

The app creates a **private duplex pipe pair** at each service spawn and passes the service's ends through
`PROC_THREAD_ATTRIBUTE_HANDLE_LIST`; the service inherits them and nothing else. There is no name to connect to, no
DACL to negotiate and no listener. A reconnect is a new service process and a new pair. The app writes requests on
one end and reads replies on the other; the service does the reverse on its inherited ends.

**Framing.** Every frame is `u32 length` (little-endian, the payload's bytes) followed by `u8 kind` and the payload:

| kind | payload |
|---|---|
| 1 | a JSON envelope, UTF-8 |
| 2 | `u64 transfer id` then raw bytes (a bulk reply) |

A frame is bounded before it is read: JSON ≤ 4 MiB, bulk ≤ 64 MiB. A frame of an unknown kind, a length that
exceeds its bound, or a truncated frame ends the connection; the service answers nothing further on it. A **reply**
JSON over 4 MiB is refused as `envelopeTooLarge`, with its bulk payload withheld, so a maximum history is a typed,
product-visible bound rather than a connection the client must drop.

## 2. The envelope

```json
{"contract": 4, "id": 17, "op": "lookup", "files": [], "operation": { ... }}
```

- `contract` and `id` come first and are read before anything else. A `contract` other than the service's is
  answered `contractMismatch` with both numbers, and the rest of the envelope is never decoded.
- `id` is the app's request number, unique per connection; it is echoed on the reply and on every progress event.
- `files` carries the handles an operation may read, each
  `{"id":"<uuid>","name":"...","handle":<u64>,"identity":{"device":..,"inode":..,"size":..,"mtimeNs":..,"ctimeNs":..},"observedAt":<u64>,"write":<bool>}`
  where `handle` is a **handle valid in the service process** (the app duplicated it there with
  `DUPLICATE_SAME_ACCESS`), `identity` is the app's observation of the path the file came from, `observedAt` is a
  monotonic observation number, and `write` is contract 3's one writable destination (absent or false on every
  other file). A request that may read must carry an observation for every file it names; a missing one is
  `admission`.
- The service admits a file only if the handle is a regular file, opened read-only unless it is `ledgerSync`'s
  single `write` file, and only if the handle's own identity matches either the observation or the identity the
  service last saw; an observation older than the newest for that file never replaces it. A writable handle on any
  other operation, or a second one on `ledgerSync`, is `admission`.

A reply is `{"contract":4,"id":17,"ok":{...}}` or `{"contract":4,"id":17,"error":{"type":"...",...}}`. A reply that
carries bytes announces them in the JSON: `"bulk":{"transfer":<u64>,"length":<u64>,"mime":"..."}`, and the kind-2
frame with that transfer id follows before any other reply on the connection. At most two bulk replies are in
flight; a third request is `busy` until one completes.

## 3. Operations

The operation vocabulary is the core's, camel-cased, with no Apple conversion (`convertApple`, `cancelConversion`
are macOS-only, ADR-0011).

| `op` | `operation` | `ok` |
|---|---|---|
| `versions` | — | `{"protocol","core","indexFormat","normalization"}` |
| `import` | `{"package":{"mdx":FileRef,"mdd":[FileRef],"sidecars":[FileRef]},"progress":<bool>}` | `Imported` |
| `cancel` | `{"id":<the import's id>}` | `{"cancelled":true|false}` |
| `open` | `{"package":...}` | `Opened` |
| `close` | `{"dict":"<handle>"}` | `"closed"` |
| `lookup` | `{"query","dicts":[..],"options":{"limit","offset","mode":"reader"|"link","generation"}}` | `Page` |
| `suggest` | `{"prefix","dicts":[..],"limit"}` | `[string]` |
| `entry` | `{"dict","entry":EntryRef,"view":View}` | `Entry`, with `bulk` |
| `entryText` | `{"dict","entry":EntryRef,"view":{"baseUrl","maxBodyBytes","maxTextBytes","originalStyle"}}` | `EntryText` (`text`,`spans`,`senses`,`style`,`complete`,`omittedBytes`,`cutAt`) |
| `link` | `{"dict","url","origin":LinkOrigin,"view":View}` | `Link` |
| `resource` | `{"dict","path","view":View}` | `Resource`, with `bulk` when found |
| `health` | `{"dict"}` | `Health` |
| `displayOptions` | `{"dict"}` | `DisplayOptions` |
| `readingStyle` | `{"dict"}` | `ReadingStyle` |
| `joinLineage` | `{"edition","lineage"}` | `LineageId` |
| `splitLineage` | `{"edition","newLineage"}` | `LineageId` |
| `lineageOf` | `{"edition"}` | `LineageId?` |
| `entryGloss` | `{"entry":EntryRef}` | `EntryGloss` |
| `ledgerRecord` | `{"reading":Reading,"operation","targetLanguages":[string]}` | `RecordOutcome` |
| `ledgerHistory` | `{"now","utcOffsetSeconds"}` | `History` |
| `ledgerRemove` / `ledgerRestore` | `{"removal":Removal,"operation"}` | `RecordOutcome` |
| `exportData` | — | the log's JSON as the reply's **bulk payload** (`application/json`) |
| `eraseData` | `{"stamp":Stamp,"operation"}` | `EraseReport` |
| `studyNote` | `{"dict","entry":EntryRef,"text","name","stamp":Stamp,"operation"}` | `Note` |
| `studyNoteAt` | `{"entry":EntryRef,"text","name","stamp":Stamp,"operation"}` | `Note` |
| `studyNotes` | — | `[Note]` |
| `definitionHash` | `{"dict","entry":EntryRef}` | string |
| `studyReanchor` | `{"oldEdition","newEdition","stamp":Stamp,"operationPrefix"}` | `ReanchorReport` |
| `reviewQueue` | `{"now","limit"}` | `[StudyCard]` |
| `reviewGrade` | `{"target","revision","grade":"again"|"hard"|"good"|"easy","policy":ReviewPolicy,"stamp":Stamp,"operation"}` | `ReviewOutcome` |
| `reviewUndo` | `{"target","gradeEvent","stamp":Stamp,"operation"}` | `ReviewOutcome` |
| `reviewSummary` | `{"now"}` | `ReviewSummary` |
| `studyConflicts` | — | `[CardConflict]` |
| `reviewResolve` | `{"target","keep","stamp":Stamp,"operation"}` | `ReviewOutcome` |
| `ledgerSync` | `{"device":"<safe name>"}` | `SyncReport` (`exported`,`peers`,`added`,`skipped`) |

`FileRef` is `{"file":"<uuid>"}`, naming an entry of `files`. `EntryRef` is `{"edition","key","occurrence"}`.

**Sync (contract 3).** `ledgerSync` takes every peer log as a read-only file and exactly one writable destination in
the same `files` array; `device` names the destination (`xdict-<device>.xdlog`). The service copies the peers into a
service-owned staging inbox (at most 64 files and 256 MiB in aggregate, one over refused by name), calls the core's
`ledger_sync(inbox, staging, device)`, copies the staged output through the one write handle in chunks, and deletes
staging. The reader's folder path never enters the service, and no dictionary content travels in a log. A killed sync
leaves staging to the next service start's sweep; the app's own destination is replaced only by an atomic rename
after the reply.

**Edition admission.** `entryGloss`, `studyNoteAt` and `studyReanchor` name an edition rather than a handle. The service
keeps an **edition→open-dictionary map** from `open`; the named edition is resolved there and its files must be
observed like any dictionary's, or the request is `admission`. A service that does not hold the edition answers
`notFound` with `what:"edition"`; the client reopens that dictionary once, keeps the operation id, and never substitutes
another edition. `exportData`'s JSON document is the reply's bulk payload, so the 4 MiB envelope never carries it.
`View` is `{"baseUrl","maxBodyBytes","originalStyle":<bool>}`; the service applies the contract's base and the
view's ceiling, never a base from the request. The records, enums and error shapes are the core's serde shapes
(`core/xdict-core/src/types.rs`, camelCase and a `type` tag), which the fixtures below quote.

**Progress and cancellation.** An import with `"progress":true` sends kind-1 events
`{"contract":4,"id":<import id>,"event":"progress","done":..,"total":..}` while it runs; the app answers with a
kind-1 frame `{"contract":4,"id":<import id>,"event":"answer","cancel":<bool>}`. Work that answers after a `cancel`
answers `cancelled` and registers nothing.

## 4. Typed errors

`CoreError` maps one-to-one: `unsupported` (`feature` typed), `malformed`, `tooLarge` (`limit`), `notFound`
(`what`), `io` (`kind`), `staleHandle`, `editionMismatch`, `sourceChanged`, `cancelled`, `incompatible`
(`core`,`client`), `internal`; each carries `detail` for logs only. The wire adds `contractMismatch`
(`contract`,`service`), `admission`, `busy`, `deadline`, `closed` and `envelopeTooLarge` (`bytes`,`ceiling`). **The
shell words every sentence**; a service never sends one.

## 5. Limits, deadlines and lifecycle

- Envelope ≤ 4 MiB; rendered body ≤ 16 MiB; any other resource ≤ 64 MiB; a page ≤ 1,000; suggestions ≤ 1,000.
- Two bulk replies in flight; eight lookup-class calls in flight; one import at a time; a **service-wide** gate
  admits work across connections, and a stalled call past its deadline frees its slot by a new connection.
- Deadlines: lookup-class 10 s, import none (the app cancels), bulk 30 s. Contract 2: `entryGloss`, `studyNote`,
  `entryText`, `entryGloss`, `studyNoteAt` and `definitionHash` 10 s; `studyReanchor` and `ledgerSync` 15 s; `ledgerRecord`, `ledgerHistory`,
  `ledgerRemove`/`Restore`, `exportData`, `eraseData`, `studyNotes`, the review calls and `studyConflicts` 5 s.
  The bulk class adds `entryText` to contract 2's set: `entry`, `resource`, `entryText`, `entryGloss`, `exportData`, `studyNote`,
  `studyNoteAt`, `definitionHash` and `studyReanchor` (not `ledgerSync`; its bytes cross by handles, not a payload).
- A killed service makes every handle stale; the app starts a new service, re-duplicates the handles and re-opens.
  The service exits when idle with no request, import or reply in flight; the app restarts it on demand.

## 6. Versioning

`contract` is this document's number; a change to the envelope, an operation, a record, a limit or an error bumps
it. The transport (the pipe pair, the frame header, the kind byte) is permanent for the service's install name; a
change ships a new service name. The app and the service negotiate at the first request, and an incompatible pair
answers `contractMismatch` before any dictionary call.

## 7. Fixtures

`fixtures.jsonl` holds request/reply pairs: one per line, `{"name":"...","request":{...},"reply":{...}}`. A pair's
values come from the core's serde shapes; the import/open/lookup pair is the spike's real answer for the tiny
fixture. Both sides decode and re-encode every line in their tests; a fixture that cannot be decoded is a harness
failure, never a refused request.
