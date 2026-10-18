# XDictCaptureLab — provenance

A development instrument, never in XDict.app (plan-capture WI-4; XDict ADR-0014 decision 8, after XiaolaiDict ADR-0016).
XiaolaiDict compiled its capture instruments into a development bundle and out of a release with
`XIAOLAIDICT_CAPTURE_INSTRUMENTS`, so the bundle its end-to-end tests ran was not the one a reader got. Here the
instrument is a target of its own that neither shipped executable reaches: the bundle that is tested is the bundle that
ships, and the lab travels in the E2E kit beside it, built of the same tree, signed, with its own identity and grants.

Re-checked against MDX-first: nothing here reads a dictionary; it reads the screen through capture's own targets.

| File | Source | Tests | ADRs |
|---|---|---|---|
| `LabCommand.swift` | XiaolaiDict `Sources/XiaolaiDict/LaunchArguments.swift` (`readPoint`). Changed: the lab's only command; anything else, nothing included, is a usage error | `ReadPointArgumentTests` (`aPointIsParsed`, `anythingElseIsRefused`, from XiaolaiDict's `LaunchArgumentsTests`; two refused cases added) | XiaolaiDict 0016 |
| `PointReport.swift` | XiaolaiDict `Sources/XiaolaiDict/LookupCommand.swift` (`PointReport`). Changed: built from the `CapturedTerm` capture hands to search (ADR-0014 d.2) — the acquisition, the source app, the measured box, the context's outcome — and never from a pending context; the first reading kept with how its context ended | `PointReportBoundsTests` (`theReportCarriesTheBoxYDownWithItsQuality`, `noBoxIsReportedAsNone`, from XiaolaiDict); new `PointReportTests` | XDict ADR-0014 d.2 |
| `ReadPoint.swift` | XiaolaiDict `LookupCommand.readPoint`. Changed: XDict's `HoverReader` with the shipped policy and the app's own distances (`CaptureTolerances.metrics`), a capture deadline of the instrument's own (30 s); a recognised word waits for its context's end; Screen Recording is never asked for, only reported | new `ReadPointRunTests` | XDict ADR-0014 d.6, d.7, d.8 |
| `LabMain.swift`, `main.swift` | new: the report on standard output, one line; anything else on standard error; 0, 1, or 64 for a usage error | new `LabMainTests` | — |
