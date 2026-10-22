# windows

Windows, in C# and WinUI 3, with WebView2 for entries. The core runs in a separate low-privilege process, the Rust
service, over a private pipe pair (ADR-0022). The app never links the core. It owns the browser extension's
native-messaging host in a later milestone (ADR-0008).

**State: WI-1 to WI-11 built (2026-10-22).** The app starts a capability-free AppContainer service; the full
operation set runs through the production client and pipe, with bounded credits, generations, deadlines and
reopen. Search, the entry view, the library, one Settings window (Dictionaries / Reading & Speech / General),
look up from anywhere (shortcut, tray, non-activating panel) and sound all run, and the 15-stage E2E runner,
measurement and unsigned bundle/MSI are in `Tools/`. Open owner items: the signing certificate (so releases are
unsigned), a fresh Windows 11 VM install/uninstall and SmartScreen check, the Chinese read of the reader's
sentences, and Word/Office activation plus a UIA-text PDF reader for those two capture cases. The Windows E2E
host is named in the workspace's untracked `local.mk` (`E2E_HOST_WINDOWS`, `XDICT_LAUNCH_HOST`); state and next actions live in
`dev-docs/continuation.md` and `dev-docs/plan-windows-v1.md`.

## Layout

| Path | What |
|---|---|
| `XDict.App/` | WinUI 3, unpackaged, self-contained Windows App SDK. The window; the launch probe. |
| `XDict.Client/` | AppContainer spawn, private pipes, handle observations, credits, generation cancellation, deadlines and reopen. |
| `XDict.Contract/` | The wire types and validators. No UI, no core. |
| `XDict.Models/` | Models testable without a window: the string catalogue, the launch probe. |
| `XDict.Conformance/` | The IPC conformance gate: the real service through the production client and pipe. |
| `XDict.Tests/` | xUnit: handshake, typed refusals, lifecycle, sandbox, endpoint admission, strings, launch and output boundary. |
| `service/` | The Rust service, its own Cargo workspace, linking `../../../core/xdict-core` directly. |
| `contract/` | The frozen wire contract (`CONTRACT.md`, `contract.json`) and its fixtures, read by a Rust test and a C# test. |
| `Tools/` | The PowerShell gates: build, test, contract, conformance, capture, launch, bundle. |

## Gates

Run on Windows only; the Rust toolchain and .NET 10 are in `local.mk`'s host notes. Most gates cache their pass under
`%LOCALAPPDATA%\XDict\gates`, keyed by the contents they read (a lab's key includes the app, the core, the embedded
apple resources and `conformance/`); `-Full` ignores the cache, and the corpus gates (`library-corpus`) never cache.
A gate that passed on an unchanged tree is not run again (AGENTS.md).

```powershell
cd apps\windows
.\Tools\build.ps1        # the service (cargo), the solution, XDictService.exe copied beside XDict.exe
.\Tools\test.ps1         # service fmt/test/clippy and dotnet tests over the real service
.\Tools\contract.ps1     # the fixtures through Rust and C#
.\Tools\conformance.ps1  # the IPC conformance runner
.\Tools\capture.ps1      # the capture suite's integrity (the production run is WI-9)
.\Tools\all.ps1          # all five, in order
```

`Tools\service-control-batch.ps1` runs the WI-4 mutation controls sequentially, restores exact source bytes and
rebuilds. Run it only on an exclusively owned host copy. Test-only contract-2 and confinement-probe service binaries
are built separately under `service/target/acceptance`; the product service excludes those features.

`Tools\proxy-probe.ps1` is the WI-5 falsification harness, with `-Mode control`, `production`, `production-empty`
or `production-preconnect`. Run one at a time in the Windows interactive session. Production currently exits 1,
as required when any target TCP, UDP or **proxy TCP** observer sees traffic. This is not the full hostile suite.

`Tools\launch.ps1` is the launch stage: it starts the built app in the E2E host's interactive session through a
scheduled task, reads the versions the app wrote to `%LOCALAPPDATA%\XDict\launch\<id>.json`, and quits the app.
It refuses to run anywhere but the host named by `-ExpectedHost` / `XDICT_LAUNCH_HOST` (set in `local.mk`), and refuses with a sentence when Smart App
Control is on (`VerifiedAndReputablePolicyState = 1`), because that host refuses locally built binaries at load.

`Tools\bundle.ps1` stages the release bundle under `out\release`; `-CertificateThumbprint` signs it with `signtool`
(the certificate is the owner's purchase, and nothing signs without one).

## CI

`.github/workflows/windows.yml` builds the service and the solution, and runs the unit, contract and IPC-conformance
tests on `windows-latest`. UI and E2E never run there: a hosted runner has no desktop session (ADR-0004).

## Icons

`icons/` is generated from `apps/apple/Resources/XDict.icon` (`apps/apple/Tools/icons/README.md`). Never edit it by
hand: run `cd apps/apple && make icons`. Where it plugs in:

- the executable: `<ApplicationIcon>..\icons\XDict.ico</ApplicationIcon>` (16, 24, 32, 48, 64, 256)
- `Package.appxmanifest`, with `icons\Images` copied in as `Images`, when MSIX returns with the extension:
  - `<Logo>Images\StoreLogo.png</Logo>`
  - `<uap:VisualElements Square44x44Logo="Images\AppList.png" Square150x150Logo="Images\MedTile.png" BackgroundColor="#1B2A4A">`
  - inside it, `<uap:DefaultTile Wide310x150Logo="Images\WideTile.png" Square71x71Logo="Images\SmallTile.png" Square310x310Logo="Images\LargeTile.png"/>`

  The `AppList.targetsize-*` files come plated, as `_altform-unplated` (dark theme) and as `_altform-lightunplated`.
  With all three, Windows does not plate the icon itself on the taskbar and in Start
- the tray: `icons\tray-on-light.ico` or `icons\tray-on-dark.ico`, chosen by the taskbar's theme
  (`HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize\SystemUsesLightTheme`)

Entry surface (WI-5, built 2026-10-21): `XDict.App/EntryPane.cs` uses a registered `xdict://d/` custom scheme, core
CSP response headers, request and navigation refusal, a dictionary-bound source and a live protection self-test. It
uses no browser arguments. The reading frame, the corpus check and the isolated-layer controls are in place; the
15-stage E2E run includes `hostile`, `reader` and `entries` through the app's own window. See
`measurements/2026-10-20-windows-entry/README.md` and `measurements/2026-10-21-windows-capture/`.
