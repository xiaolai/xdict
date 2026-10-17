# windows

Windows, in C# and WinUI 3, with WebView2 for entries. The core runs in a separate low-privilege
process. It owns the browser extension's native-messaging host (ADR-0008). Not started.

## Icons

`icons/` is generated from `apps/apple/Resources/XDict.icon` (`apps/apple/Tools/icons/README.md`). Never edit it by
hand: run `cd apps/apple && make icons`. Where it plugs in, once the WinUI project exists:

- the executable: `<ApplicationIcon>icons\XDict.ico</ApplicationIcon>` (16, 24, 32, 48, 64, 256)
- `Package.appxmanifest`, with `icons\Images` copied in as `Images`:
  - `<Logo>Images\StoreLogo.png</Logo>`
  - `<uap:VisualElements Square44x44Logo="Images\AppList.png" Square150x150Logo="Images\MedTile.png" BackgroundColor="#1B2A4A">`
  - inside it, `<uap:DefaultTile Wide310x150Logo="Images\WideTile.png" Square71x71Logo="Images\SmallTile.png" Square310x310Logo="Images\LargeTile.png"/>`

  The `AppList.targetsize-*` files come plated, as `_altform-unplated` (dark theme) and as `_altform-lightunplated`.
  With all three, Windows does not plate the icon itself on the taskbar and in Start
- the tray: `icons\tray-on-light.ico` or `icons\tray-on-dark.ico`, chosen by the taskbar's theme
  (`HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize\SystemUsesLightTheme`)
