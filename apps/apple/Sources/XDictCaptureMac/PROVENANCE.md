# XDictCaptureMac — migration manifest

Capture's macOS target, under XDict ADR-0014 decisions 5 to 7 and 10, plan-capture WI-2. Its files come from two
places: XiaolaiDict's `MacCapture` (`../xiaolaidict`, read at commit 044dac6), and XDict's own `XDictAnywhere`, from
which the selection reader moved down. One row per file: where it came from, the tests that moved with it (by their
names, now in `Tests/XDictCaptureMacTests/`) and the ADR behind it. "ADR-00nn" without a prefix is XiaolaiDict's; XDict's
are written "XDict ADR-00nn".

**Provenance check (2026-10-18, by reading).** Every XiaolaiDict origin file below and its tests were read in full while
porting. `git log` over those source and test paths names one author, the owner: 11 commits; no file carries a licence
header, a copyright line or text from another project, and none of them is, or was translated from, third-party code.
XiaolaiDict has no licence file, so this is a recorded check, not a given (XDict ADR-0014 Context). The files moved from
`XDictAnywhere` are XDict's own, with their history in this repository.

## Files

| XDict file | Origin | Tests moved by name | ADR |
|---|---|---|---|
| `AccessibilityAccess.swift` (`PermissionProbe`, `AccessibilityAccess`) | XiaolaiDict `Sources/MacCapture/AccessibilityAccess.swift` and the `PermissionProbe` of `Sources/MacCapture/Permission.swift`; the asking half (`ensure`, `request`) not moved: asking is `AccessibilityGate`'s, in `XDictAnywhere` | `AccessibilityAccessTests`: `aGrantedPermissionIsNeverAskedFor`, `anUnreadableProbeNeitherPromptsNorPasses`, `theHoverGateNeverPrompts` (now also a scan of this target for any prompting call); not moved: the two asking cases and `theAccessibilityPromptKeyIsTheFrameworksOwn`, whose subject stays in the gate | 0017; XDict ADR-0014 d.7 |
| `AccessibilitySession.swift` (`CaptureError`, `AccessibilityReading`, `AccessibilityRequests`, `AccessibilitySession`, `PageWalk`, `breadthFirst`) | XDict `Sources/XDictAnywhere/Accessibility.swift` (moved down), merged with XiaolaiDict `Sources/MacCapture/AccessibilitySession.swift` (the request seam, the injected clock, `enhance`, the classified walk to the page); new: the hit test as a request of the session | `AccessibilitySessionTests`: `accessibilityStatusesAreClassified`, `anInvalidApplicationElementMeansTheAppIsGone`, `aRefusalByTheAppItselfIsReported` (XiaolaiDict `CaptureTests`); `BreadthFirstTests` (3, XiaolaiDict); new: `aStalledHitTestEndsTheReadAtItsDeadline`, `aHitTestInsideTheBudgetIsAnswered` | 0046; XDict ADR-0014 d.6 |
| `AccessibilityLane.swift` (`LaneWork`, `LaneRefusal`, `LaneState`, `LaneBounds`, `AccessibilityLane`) | XiaolaiDict `Sources/MacCapture/AccessibilitySession.swift` (`AccessibilityLane`), rebuilt from a FIFO into a queue with XDict ADR-0014 decision 6's rules | `AccessibilityLaneTests` (XiaolaiDict, in `AccessibilityBudgetTests.swift`): `readsNeverOverlap`, `eachReadSeesItsOwnTimeout`, `aReadCancelledBeforeItsTurnDoesNoWork`, `aCancelledWaiterIsAnsweredBeforeTheReadAheadEnds`, `aCallerCancelledBeforeAskingDoesNoWork`; new `AccessibilityLaneRuleTests`: `aHoverFloodThenAShortcutReadWaitsOnlyForTheReadInFlight`, `aNewerHoverReplacesTheOneWaiting`, `anExplicitRequestStopsTheHoverInFlight`, `anItemThatWaitsTooLongIsDroppedWithItsOutcome`, `aReadBlockedInTheFrameworkIsReportedStuck`, `boundsThatDropEverythingAreRefused`. `CancellationWatchOrderTests` not moved: the lane no longer uses XiaolaiDict's `value(of:orOnCancel:watching:)` | 0042, 0046; XDict ADR-0014 d.6 |

## Not moved

`HoverWatcher`, `HoverReader`, `PendingContext` (plan-capture WI-3), `ScreenTextRecogniser`, `ScreenRecordingAccess`,
`ScreenMetricsAppKit` and the Screen Recording half of `Permission` (WI-4).
