# linux

Linux, in Rust with GTK4 and libadwaita, and WebKitGTK for entries. Its own Cargo workspace, depending on
the core by path, so GTK never enters the core's build on other platforms. It owns the browser extension's
native-messaging host (ADR-0008). Not started.

## Icons

`icons/` is generated from `apps/apple/Resources/XDict.icon` (`apps/apple/Tools/icons/README.md`). Never edit it by
hand: run `cd apps/apple && make icons`. Where it plugs in, once the shell exists:

- `icons/hicolor/` installs into `$prefix/share/icons/hicolor/`: PNGs from 16 to 512,
  `scalable/apps/ai.xdict.app.svg` and `symbolic/apps/ai.xdict.app-symbolic.svg`. The icon name is the app id,
  `ai.xdict.app`
- `icons/ai.xdict.app.desktop` installs into `$prefix/share/applications/` and says `Icon=ai.xdict.app`. Its
  `Exec=xdict` is a placeholder until the shell names its binary
- the tray (StatusNotifierItem): `ai.xdict.app-symbolic` where the host recolours symbolic icons. Otherwise,
  `ai.xdict.app-tray-on-dark` or `-tray-on-light` (in `hicolor/<size>/status/`), whichever matches the panel's colour
