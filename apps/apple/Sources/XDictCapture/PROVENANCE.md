# XDictCapture — migration manifest

Capture's pure target, ported from XiaolaiDict (`../xiaolaidict`, read at commit 044dac6) under XDict ADR-0014
decision 10, plan-capture WI-1. One row per file: where it came from, the tests that moved with it (by their
XiaolaiDict names, now in `Tests/XDictCaptureTests/`) and the ADR behind it. "ADR-00nn" without a prefix is
XiaolaiDict's; XDict's are written "XDict ADR-00nn".

**Provenance check (2026-10-18, by reading).** Every origin file below and its tests were read in full while porting.
`git log` over them names one author, the owner (24 commits); no file carries a licence header, a copyright line or
text from another project, and none of them is, or was translated from, third-party code. XiaolaiDict has no licence
file, so this is a recorded check, not a given (XDict ADR-0014 Context).

## Ported files

| XDict file | XiaolaiDict origin | Tests moved by name | ADR |
|---|---|---|---|
| `BandTiling.swift` | `Sources/Capture/BandTiling.swift` | `BandTilingTests` | 0016 (tiling addendum) |
| `ContextStrip.swift` (`ContextStrip`, `ColumnLayout`, `ParagraphFinder`, `ListMarker`) | `Sources/Capture/ContextStrip.swift` | `ContextStripTests` | 0016 |
| `RecognisedText.swift` (`RecognisedTextPicker`, `LineJoiner`, `TextBlock`, `CaptureEdge`) | `Sources/Capture/RecognisedText.swift` | `LineJoinerSplitLineTests`, `DegenerateRegionTests`, the recogniser cases of `ScreenReadingTests` | 0016, 0042 |
| `HoverPolicy.swift` (`HoverGesture`, `TapCounter`, `GestureRecogniser`, `HoverModifier`, `HoverRefusal`, `HoverPolicy`, `HoverPause`) | `Sources/Capture/HoverPolicy.swift` | `HoverPolicyTests` | 0015 |
| `HoverSession.swift` | `Sources/Capture/HoverSession.swift` | `HoverSessionTests` (with `RequestSequence`'s cases) | 0045 |
| `RequestSequence.swift` | `Sources/Capture/RequestSequence.swift` | the `RequestSequence` cases of `HoverSessionTests` | 0045 |
| `PointerWindow.swift` (`ListedWindow`, `PointerWindow`, `PointerTarget`, `CaptureAuthorization`) | `Sources/Capture/PointerWindow.swift` | `PointerWindowTests`, `PointerTargetTests` | 0016, 0042 |
| `ScreenGeometry.swift` (`HitTolerance`, `CaptureGeometry`) | `Sources/Capture/ScreenGeometry.swift` | `HitToleranceTests` and the geometry cases of `ScreenReadingTests` | 0016 |
| `ScreenSpace.swift` (`UpPoint`, `DownPoint`, `UpRect`) | `Sources/Capture/ScreenSpace.swift` | `ScreenSpaceTests` | 0016 |
| `WordBounds.swift` (`DownRect`, `WordBounds`, `ReadBounds`) | `Sources/Capture/WordBounds.swift` | `WordBoundsTests` | 0016 |
| `TextSegmenter.swift` (`SentenceContext`, `WordAtPoint`, `TextSegmenter`) | `Sources/DictionaryModel/TextSegmenter.swift` | `SelectionContextTests`, the segmenter cases of `ScreenReadingTests` | 0016 |
| `CaptureScript.swift` | `ProbeScript.dominant(in:)` and `letterScript(of:)` of `Sources/DictionaryModel/DictionaryLanguage.swift` | `CaptureScriptTests` (from `DictionaryLanguageTests`: `punctuationDigitsAndSpacesDoNotVote`, `anyKanaMakesItJapaneseHoweverManyHanThereAre`, `latinReachesPastAscii`, `punctuationInsideAScriptsBlockDoesNotVote`, `theScriptsAreRecognisedWhereverUnicodePutsThem`, `composedAndDecomposedTextAgree`, `aBlockNamedForOneScriptCanHoldAnother`, `presentationFormsFoldToTheLettersTheyAre`, `kanaBeyondTheOriginalBlocksIsStillKana`, `amongLettersTheMajorityScriptWins`) | 0015 |
| `CaptureExclusions.swift` | the password-manager list of `Sources/Capture/PlacePolicy.swift` (the list only) | `HoverPolicyTests` (`itShipsExcludingPasswordManagers`) | 0015 |

## What changed on the way (re-checked against XDict, ADR-0014)

- **No literal tolerance or capture dimension.** `HitTolerance` (3 pt, 2 pt), `HoverSession.restTolerance` (2 pt),
  `ContextStrip`'s 300/150/600 pt and `BandTiling`'s 4/16 px slacks arrive through `CaptureMetrics` (decision 11);
  the tests hand in XiaolaiDict's measured values (`MeasuredMetrics.swift`). Dimensionless ratios are `Double`.
- **No lookup bound.** `ContextStrip.maximumCharacters` was `LookupRequest.maximumSentenceLength`; the context limit is
  now capture's own acquisition limit (`CaptureLimits.contextUTF16`, UTF-16 units), applied before assembly (decision 3).
- **No sentences below the consumer.** `HoverRefusal.reason` and `HoverPause.name(of:)` were display text; the
  consumer words them (decision 4). Their two tests now assert the kinds and the lengths.
- **Capture's own lists.** The excluded apps are `CaptureExclusions`, not the study ledger's `PlacePolicy`; the script
  filter is `CaptureScript`, not the dictionary probe (decision 10).
- `XiaolaiDictBase` (`Duration.seconds`, the log subsystem) is replaced inline; the log carries metadata only.

## Not moved (decision 10, and the WI-1 brief)

`ReadingPlace` (document URLs, titles, ledger fields), `CaptureQuality` and `MisreadSigns` (study-ledger quality),
`PlacePolicy`'s place stripping, `HoverPolicyStore` (settings storage: WI-3), `DrawerGeometry`, `SentenceExcerpt`,
`RevealSequence` (panel and developer code), `ProcessResolver` and `SystemOverlaySurface` (the Mac adapter's and the E2E
panel stage's), and every `MacCapture` file (WI-2).
