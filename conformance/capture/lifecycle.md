# The capture lifecycle

**capture-contract: 1** · 2026-10-20 · Normative alongside `CONTRACT.md` §5. The value fixtures (`vectors.jsonl`) say what a
capture is; this file says **when things happen and which request an answer belongs to**. Each shell runs these scenarios
with its **own native tests** — nothing here is a harness, and no shell imports another's code (`CONTRACT.md` §8.2).

## Rule 1 — The number exists before the read

**Scenario.** The reader asks (a shortcut, a Service, a menu item, a hover gesture). The read that follows is slow and is
suspended. Assert that the request's number was handed out **before** the read started — in the gesture's own turn, not
when its result came back — that a second ask in the same turn got the next number, and that numbering is **separate from
claiming presentation**: a hover holds its number while the shortcut that asked later claims presentation.

**Observable assertions**

- `begin` returns before any asynchronous work of the request starts.
- Numbers strictly increase in the order asked, across every trigger.
- A number alone presents nothing; claiming is a second act on the same number.

**macOS instance:** `CaptureSinkTests.requestsAreNumberedSynchronouslyInOrder`,
`RequestNumberingTests.everyTriggerIsNumberedInOneOrderAndEndsOnce`,
`RequestNumberingTests.aHoverNumberedBeforeAShortcutLosesAndOneNumberedAfterWins`.

## Rule 2 — Every request ends, exactly once

**Scenarios and the ending each owes**

| The request… | Ends as |
|---|---|
| was delivered and its content drawn | `shown` |
| was delivered but the presentation did not come up | `notShown` |
| was refused before delivery | `cancelled`, with generation `0` |
| was superseded by a newer request that claimed presentation | `cancelled` |
| was open when the presentation closed | `cancelled` |
| was delivered and its consumer went away | `cancelled` |

**Observable assertions**

- Each number reaches exactly one terminal event, carrying the number and the generation it was given for.
- A second answer, a duplicate, or a late answer for an older generation changes nothing and is told as such.
- A request that was accepted and never acknowledged still ends when its consumer goes or its presentation closes — the
  consumer owns this, and no request may be left open.
- The book is bounded: ended numbers are remembered only far enough to recognise late answers, and a number forgotten
  that way is ended, never open.

**macOS instance:** `CaptureSinkTests.aDuplicateAcknowledgementIsIgnored`, `aRefusalCancelsTheRequest`,
`escapeBeforeDeliveryCancelsAndTheResultIsNotDelivered`, `aConsumerThatDisappearsCancelsWhatIsOpen`,
`anAcceptedRequestEndsWhenTheConsumerGoes`, `aLongRunOfRequestsDoesNotGrowTheBook`; `RequestNumberingTests.everyEndingIsToldOnce`.

## Rule 3 — A stale answer changes nothing

**Scenario A — a stale answer at the book.** Deliver A, then B. A's late acknowledgement, for any generation, ends
nothing; B's own acknowledgement ends B under B's generation.

**Scenario B — a stale document at the consumer.** Deliver A for term *X*; before the presentation asks its view for a
document, deliver B for term *Y*. The document that finishes is A's, while the presented term is already B's. The finish
must acknowledge **nothing**: the term *Y*'s entry has not been drawn. Only a finish of the document the presentation
asked to show for the lookup shown now may acknowledge.

**Scenario C — identical terms.** Deliver A (*tide*, generation 1), then B (*tide*, generation 2). An acknowledgement
caused by A's document, in the window before B's lookup has been handed to the view, must not be credited to B; when B's
document finishes, it acknowledges B under B's generation, never under A's.

**Observable assertions**

- No acknowledgement names a request or generation other than the **latest delivery's**.
- A finished document is the presented term's only where it belongs to the lookup the view was asked to show **now**.
- A stale document's finish changes no request and acknowledges nothing.

**macOS instance:** `PresentationAcksTests.aNewerDeliveryReplacesTheOlder`;
`CaptureSinkTests.aStaleGenerationLeavesTheRequestOpen`, `CaptureSinkTests.sameWordRequestsAcknowledgedInReverseSettleApart`;
`PresentedEntryTests` (the identity's rule, both nils included); `DocumentDrawWiringTests` (the real adapter
consults it; the window records the lookup it handed the view).

## Rule 4 — A Service in flight is cancelled by the shortcut or Escape

**Scenario.** A Service read is suspended mid-flight. The reader presses the lookup shortcut, or Escape; or a newer
Service asks. The suspended read is cancelled, and whatever it answers afterwards presents nothing and changes nothing.
The rule holds for a Service over another app and over XDict's own window alike.

**Observable assertions**

- The in-flight Service task is cancelled by the shortcut, by Escape, and by a newer Service.
- Work that answers after the cancellation produces no presentation and no observation.
- The request it belonged to still reaches its one terminal event.

**macOS instance:** `ServiceCancellationTests.anInFlightServiceIsCancelledAndPresentsNothing` — the reader's app and XDict's
own window, each with the shortcut and Escape (4 cases).

## What each shell owes

- One named native test per rule, each shown **failing once** against a mutation of the rule it covers.
- The triggers and outcomes its platform cannot produce, recorded in its mapping (`CONTRACT.md` §9) — a shell without
  Services says so instead of skipping this file's rule 4 silently.
- Its own runner report naming the scenario tests, beside the value suite's case count and revision.
