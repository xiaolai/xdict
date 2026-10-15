# apple

macOS and iOS, in Swift and SwiftUI, sharing one Swift package. macOS adds AppKit and runs the core in an
XPC service, so dictionary files are parsed outside the app. It also holds the Safari web extension's
wrapper, built from `apps/extension/`, and the native-messaging host the other browsers' extension calls
(ADR-0008). The reference platform: built first.

## Status

**macOS, plan-macos-v1 WI-2 to WI-7** (corrected 2026-10-15: this said the skeleton's one window). XDict.app has its
library (WI-5), its main window — search, the dictionary's own entry, links and the trail (WI-6) — and the entry's sounds
and the system voice (WI-7); the sandboxed service answers the IPC contract frozen on 2026-10-14 (WI-1, ADR-0009,
`XDictContract`). Every gate below runs; lookup from anywhere, setup and the release are WI-8 to WI-10; iOS is not
started.

| Target | What it is |
|---|---|
| `XDictBase` | The bundle identities and the handshake: its `@objc` protocol, its wire value, its client |
| `XDictContract` | The frozen IPC contract: the NSXPC protocols and interfaces, versioned envelopes, the records and error kinds both sides exchange, files by handle, the identity rule, limits and deadlines. Foundation only; the service converts the core's types into it (`CoreMapping.swift`) |
| `XDictUI` | The view layer: the main window, the library window, Settings' speech pane and their sentences |
| `XDictClient` | The app's side of the contract: `ServiceClient` (request ids, deadlines, credits, generations, reconnection, tokens) |
| `XDictLibrary` | The reader's library (WI-5): packages found in what the reader chose, bookmarks and file ids, imports with cancel and retry, order, names, languages, changed editions and lineage joins; kinds, never sentences |
| `XDictSearch` | The main window's model (WI-6): a search over every enabled dictionary or one, painted as each answers, paged, the trail; and its pronunciation (WI-7): a `sound://` link's recording fetched and played, or spoken instead with the reason; kinds, never sentences |
| `XDictSpeech` | Sound and speech (WI-7): the system's voices and the one that speaks a dictionary's declared language in the reader's accent, the accent kept, and the output (`AVAudioFile` and `AVAudioEngine`, `AVSpeechSynthesizer`) behind a seam tests use without a sound |
| `XDictEntryView` | The entry view and its confinement (WI-4) |
| `XDictInstruments` | The E2E instruments' scenarios, compiled into the app and run by its development flags |
| `XDictEntryLab` | A development host of the entry view that links the core; never in XDict.app |
| `XDict` | The app: not sandboxed, Developer ID, hardened runtime; never links the core |
| `xdictFFI`, `XDictCore` | The core: `libxdict_ffi.a` as an XCFramework, and its UniFFI binding, both generated into `Generated/` |
| `XDictService` | The dictionary service, `ai.xdict.app.DictionaryService`: sandboxed, no file or network entitlement, the only target that reaches the core |
| `XDictTestSupport` and the test targets | `XDictTests` holds the harness's own rules: module boundaries, test floors, the string catalog, the platform floor, the bundle's facts |

## Build and test

Needs Xcode 27 (Swift 6.4), Rust 1.99 with `aarch64-apple-darwin`, SwiftLint 0.65.1 (`brew install swiftlint`), and a
Developer ID Application identity in the login keychain (exactly one, or name it with `SIGN_ID=`). macOS 27 runs only on
Apple silicon, so everything is arm64 alone.

```sh
cd apps/apple
make            # = make app: the core, lint, swift test, the warnings gate, then .build/XDict.app signed and verified
make test       # the core, lint, swift test and the warnings gate
make strings    # re-extract the strings into Strings/Localizable.xcstrings (then translate: en and zh-Hans)
make clean
```

**Nothing launches XDict on the Mac that builds** (the owner's rule, 2026-10-14: its screen is in use). The app, its
service and the handshake run on the E2E Mac only, through `make e2e`.

`make` builds the core first (`Tools/build-core.sh`): cargo builds `libxdict_ffi.a` into `.build/cargo`, UniFFI generates
the Swift binding from that archive, and both go into `Generated/` (untracked) as SwiftPM's binary target and a Swift
target. The archive is linked statically into the service alone.

### The gates, and what each refuses

| Gate | Where | Refuses |
|---|---|---|
| The core reaches the service alone | `ModuleBoundaryTests`; `Tools/build-bundle.sh` | any other target that depends on or imports `XDictCore`/`xdictFFI`; an app binary holding a core symbol or linking a core dylib |
| The contract stands alone | `ModuleBoundaryTests` | `XDictContract` importing anything but Foundation (the core, AppKit, a target of this package) or depending on a target here |
| Warnings are errors | `Package.swift` (every target); `Tools/compiler-warnings.py` (each source's diagnostics file, debug and release) | any warning the compiler wrote down |
| `MemberImportVisibility`, warnings as errors on every target | `ModuleBoundaryTests`, from SwiftPM's own reading of the manifest | a target added after the loop that sets them |
| SwiftLint `--strict`, pinned 0.65.1 | `make lint` | its correctness rules (`.swiftlint.yml`), or another SwiftLint version |
| Test floors | `TestInventoryTests` | a test target that lost tests, or has no floor |
| The string catalog | `StringCatalogTests` | a reader-facing string not in the catalog, an entry without a translated English and Simplified Chinese, a stale entry, display text below the view layer |
| The platform floor, 27.0 | `PlatformFloorTests`; `Tools/build-bundle.sh` | the manifest, either Info.plist, the bundle script or a binary's `minos` saying anything else |
| The bundle | `Tools/build-bundle.sh` | wrong identities or executables, versions that differ, an ad-hoc or other identity, no hardened runtime, entitlements other than each file's exactly, a non-arm64 binary |

## End to end

Never on the Mac that builds: the stages run on the E2E Mac named by `E2E_HOST_MACOS` in the repository's untracked
`local.mk`, in `~/XDictE2E` there.

```sh
make e2e                 # make app, then every stage on the E2E Mac; STAGES="launch" for some
make e2e-status          # what each stage last did, on which build, and whether it is evidence of this tree
```

`Tools/e2e.sh` refuses the build Mac by hardware UUID, ships the bundle, starts it with `open -n` in the GUI session and
records each stage's result against the build, the E2E Mac, its macOS and the source tree (`Tools/source-tree.sh`).
The stages:
- **`launch`**: LaunchServices starts the app (its parent is launchd and `lsappinfo` knows it), its service runs from
  the bundle, the `--handshake-report` instrument (also started by LaunchServices) gets the core's versions through the
  real XPC path, they equal those of the core the bundle was built from (`Contents/Resources/CoreVersions.json`), and
  the app quits on TERM.
- **`service`** (plan-macos-v1 WI-3): the `--service-report` instrument, started by LaunchServices, drives the signed
  service through the app's `ServiceClient` over fixtures `Tools/build-fixtures.sh` writes here and ships:
  `conformance/`'s `tiny` and `matrix`, the refusals, supersession, a stalled bulk call, `kill -9` mid-lookup and the
  idle exit raced, every check required by name. Then the bundle's executable reaches the service by name and a copy of
  it outside the bundle does not, and every start of the service logged the client requirement with the bundle's team.
- **`hostile`**, **`reader`** and **`entries`** (plan-macos-v1 WI-4) run the entry view in `Tools/build-lab.sh`'s kit,
  shipped beside the bundle: the hostile-input suite, a person's hands on it, and the owner's dictionaries (`E2E_CORPUS`
  in `local.mk`).
- **`library`** (plan-macos-v1 WI-5): `--library-report` imports `Tools/build-fixtures.sh`'s `library/` packages through
  the app's library and the signed service (file, folder, ordered volumes and a sidecar, a missing volume, cancel then
  retry while another dictionary answers, languages, three refusals and their sentences in both languages, a link out of
  the folder, sounds, a rewritten file joined and undone, a moved folder relinked); `--library-drop` shows the
  production library window and `dragsource` plus `pointer` drag a dictionary onto it; `--library-corpus` registers the
  owner's 25 against the editions `index_bench` computes here, moves their folder, relaunches, and rewrites one.
- **`lookup`** (plan-macos-v1 WI-6): `--lookup-window` runs the real app over a library of its own; `drive.py` works its
  main window by key events alone and reads it through the Accessibility API, and the window's scenario runs through it.
- **`sound`** (plan-macos-v1 WI-7; `sound.speech`, `sound.notices` and `sound.recordings`, one launch):
  `--sound-report` shows a production main window whose sounds play at volume 0
  (decoded, started and run to their end, unheard on the shared E2E Mac) and clicks links in its entries as a reader's
  clicks are routed: a `.tts` link and the speak button speak, the accent changes the voice, a dictionary declared Chinese
  speaks with a Chinese voice (every utterance also rendered into a buffer, so a voice that says nothing fails); the
  library's `sounds` fixture gives a missing, a Speex and an undecodable recording their own notices, in both languages,
  read off the window by `keys ax`; then recordings of every format the 25 hold, from `entries_corpus`'s sample: mp3,
  WAV and Ogg Vorbis play to their end, Speex is spoken instead with its notice.

Positive controls: `XDICT_E2E_EXPECTED_VERSIONS=<json> Tools/e2e.sh <host> launch` expects other versions and must fail
(it records nothing); `XDICT_E2E_SSH=Tools/tests/ssh-to-this-mac Tools/e2e.sh any launch` reaches this Mac and must stop
at the host guard; `XDICT_E2E_SERVICE_CHECKS=supersede,drop Tools/e2e.sh <host> service` runs a subset of the service's
checks, for a bundle built with one switched off (it records nothing); `XDICT_E2E_LIBRARY_NO_RELINK=1 make e2e
STAGES=library` relaunches the moved 25 with relinking off and must fail (it records nothing).

## Release

Publishes nothing: a notarised, stapled DMG is left in `.build/release`, accepted by Gatekeeper here and on the E2E Mac
(`spctl -a -vv`) as "Notarized Developer ID". Notarisation uses the keychain profile `chase-notary`.

```sh
make release BUILD_NUMBER=<n>             # needs a fresh pass of every implemented stage on a development bundle of
                                          # this tree, and the tree committed
make release-bootstrap BUILD_NUMBER=<n>   # the skeleton's: a fresh pass of `launch` alone; the tree may be uncommitted
```

"Of this tree" is `Tools/source-tree.sh`: the git tree the working copy would commit as, so an edit made after the E2E
run, committed or not, needs the run again.

## CI

`.github/workflows/macos.yml`, on changes to `apps/apple/**` or `core/**`: the core built as the shell links it, the app
and the service built unsigned, `swift test` and the warnings gate.
