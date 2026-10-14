# apple

macOS and iOS, in Swift and SwiftUI, sharing one Swift package. macOS adds AppKit and runs the core in an
XPC service, so dictionary files are parsed outside the app. It also holds the Safari web extension's
wrapper, built from `apps/extension/`, and the native-messaging host the other browsers' extension calls
(ADR-0008). The reference platform: built first.

## Status

**macOS skeleton and harness** (plan-macos-v1 WI-2). XDict.app opens one window that says what its dictionary service
answered; the service is sandboxed, links the core and answers one call, `versions()`, over NSXPC. WI-3 replaces that
handshake with the frozen contract. Every gate below runs; iOS is not started.

| Target | What it is |
|---|---|
| `XDictBase` | The bundle identities and the handshake: its `@objc` protocol, its wire value, its client |
| `XDictUI` | The view layer: the launch window and its sentences |
| `XDict` | The app: not sandboxed, Developer ID, hardened runtime; never links the core |
| `xdictFFI`, `XDictCore` | The core: `libxdict_ffi.a` as an XCFramework, and its UniFFI binding, both generated into `Generated/` |
| `XDictService` | The dictionary service, `ai.xdict.app.DictionaryService`: sandboxed, no file or network entitlement, the only target that reaches the core |
| `XDictTestSupport` and four test targets | `XDictTests` holds the harness's own rules: module boundaries, test floors, the string catalog, the platform floor, the bundle's facts |

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
The one stage today, **`launch`**: LaunchServices starts the app (its parent is launchd and `lsappinfo` knows it), its
service runs from the bundle, the `--handshake-report` instrument (also started by LaunchServices) gets the core's
versions through the real XPC path, they equal those of the core the bundle was built from
(`Contents/Resources/CoreVersions.json`), and the app quits on TERM.

Positive controls: `XDICT_E2E_EXPECTED_VERSIONS=<json> Tools/e2e.sh <host> launch` expects other versions and must fail
(it records nothing); `XDICT_E2E_SSH=Tools/tests/ssh-to-this-mac Tools/e2e.sh any launch` reaches this Mac and must stop
at the host guard.

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
