# The Windows capture mapping — capture-contract 1

**2026-10-21** · The platform half of `conformance/capture/CONTRACT.md` §9: what each field means on Windows, and what
this platform cannot produce. Evidence, not code sharing; the values themselves are the contract's.

## The value

| Contract field | Windows |
|---|---|
| `CapturedTerm` | `XDict.Models.CapturedTerm`, made only by `CaptureValue.Make` (the value's rules, in order) and `CapturedTerm.From` |
| `trigger` | `selection` — the global hotkey over the foreground window's selection; `menu` — the tray item; `pointerGesture` — the hover watcher (next milestone); `service` — **cannot be produced**: Windows has no Services, and v1 installs no shell extension |
| `acquisition` | `textRange` — UI Automation 2's `TextPattern` selection range; `ownView` — XDict's own entry view reading its own selection (the pane's script); `elementTitle` — a control's accessible name, placed under the pointer (menu and button labels); `recognition` — `Windows.Media.Ocr` (the OCR milestone); `serviceText` — cannot be produced (no Services); `textMarkers`, `boundsScan` — not used on this platform |
| `confidence` | Over what the acquisition measured: `textRange` and `elementTitle` are 1 (the framework reported the exact text and its range); `recognition` will be the OCR engine's per-word confidence; a click-placement box carries no measurement and does not raise it |
| `source` | `{"process": "msedge.exe", "pid": 1234}` — the foreground process's executable file name and process id. Never the window title: a title can hold the document's own text. The field's inner shape is the platform mapping's; the fixtures carry macOS's `bundleID` |
| `pointer` | The gesture point, physical screen pixels with the origin at the primary display's top-left, and the wall-clock instant (`DateTimeOffset.UtcNow`) when the gesture was received — not a monotonic clock, so it orders events across processes only approximately |
| `box` | `measured` — the union of the selection range's `BoundingRectangle`s from UI Automation, physical screen pixels, quality `containing` (a range's rectangles contain the text; no exact per-glyph box is reported); `clickPlacement` — the pointer's point when a gesture starts a capture; `absent` — a read with no geometry (`ownView` before layout) |

## The sentence cut's known limit

Windows has no in-box sentence tokenizer (macOS uses `NLTokenizer`). `XDict.Models.SentenceCut` cuts the paragraph at
`. ! ? … 。 ！ ？` and their closing quotes and brackets, including CJK text without spaces; an abbreviation such as
"Mr." therefore ends a sentence early. The word's range is exact either way, and the contract's comparison is the
value's, not the sentence's; a better cut is a later refinement, not a conformance gap.

## What Windows cannot produce, and how it is told apart

- **Services do not exist.** `trigger: service` and `acquisition: serviceText` are never produced, and the outcome
  `disagreesWithServiceText` never occurs. Rule 4 is still implemented and tested: a reading suspended mid-flight is
  cancelled by the shortcut and by Escape (`Tools\capture-mutations.ps1` proves the test red against a mutation).
- **The UIPI dead zone.** A non-elevated XDict cannot read an elevated window's selection: UI Automation reports the
  window but exposes no text from it. This is recorded as `unavailable(notCaptured)` — never as an empty selection —
  and the panel says so in a sentence that names the prompt's cause ("XDict cannot read a window running as
  administrator"). It is not `appExposedNone`: the app does expose text; the operating system denies the read.
- **No screen-capture permission prompt.** GDI capture and UI Automation reads are unguarded by the OS on Windows. The
  privacy obligation is the contract's §6 (one ephemeral in-memory session, only the term handed on, the canary), not
  an OS grant; nothing here asks the reader for a permission.
- **`excluded`** will be produced by the same exclusion rules as macOS once the hover watcher lands; the selection
  hotkey does not apply them.

## The runner and its evidence

`Tools\capture-conformance.ps1` runs the value vectors through the production constructor, the four lifecycle rules
and the privacy canary, and reports the executed case ids, the count and the suite revision (SHA-256 of
`conformance/capture/vectors.jsonl`). The value test pins that revision
(`CaptureVectorsTests.SuiteRevisionIsRecorded`), so a suite that changes without a deliberate re-pin fails.

## What the trigger path measures (WI-9 acceptance)

The hotkey to panel-on-screen path is measured on the Windows E2E host, with the service running and with it
suspended; the panel is non-activating (`WS_EX_NOACTIVATE`), placed beside the selection's box in physical pixels, and
Escape or a click away returns focus to the host app. The measurement lives in
`dev-docs/measurements/2026-10-21-windows-capture/`.
