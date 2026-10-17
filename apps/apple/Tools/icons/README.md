# XDict's icons

One source, every platform.

| Source | What it is |
|---|---|
| `apps/apple/Resources/XDict.icon` | The app icon, an Icon Composer document ported from XiaolaiDict: a D with a sparkle in it, flat (no glass, specular or shadow), the ground and the mark coloured per appearance in `icon.json`. The mark is the default reading accent, teal `#055959` and dark `#81ECEC` (`EntryReadingFrame.Accent.teal`; `BundleFactsTests` holds the two together) |
| `apps/apple/Resources/MenuBarIcon.svg` | The designer's small-size glyph: the D solid with the sparkle cut out, one even-odd path. At 22 pt an 8-unit stroke is under 2 px and the sparkle's waist under 1, so mass survives where lines don't |

The D's contour is a filled outline: the stroke-8 path, offset 4 units each way. As a stroke, Icon Composer's
generation-26 renderer filled the whole D solid. This was measured with `ictool --design-generation 26`, and it
mattered for an iOS 26 or a back-deployed build. The outline differs from the stroke by under half a pixel at 1024
(3,075 of 1,048,576 pixels move by more than 8 levels, all on the edge).

## What uses which

| Platform | Where | Built from |
|---|---|---|
| macOS | `Resources/XDict.icon` compiled by `Tools/compile-icon.sh` (actool, on the build Mac) into `Contents/Resources/Assets.car`, `CFBundleIconName` = `XDict`; the menu bar reads `MenuBarIcon.svg` as a template | the source itself |
| iOS | the same `Resources/XDict.icon` (`"squares": "shared"`); no iOS target exists yet: compile it with `actool --platform iphoneos --app-icon XDict` | the source itself |
| Android | `apps/android/icons/` | generated |
| Windows | `apps/windows/icons/` | generated |
| Linux | `apps/linux/icons/` | generated |
| Web | `apps/web/icons/` | generated |
| Extension | `apps/extension/icons/` | generated |

The generated sets are committed. Never edit them by hand. Run `cd apps/apple && make icons`, which runs on
`BUILD_HOST`, and `make test-tools` fails while any set is stale, missing a file, holds a file the generator does
not write, or fails a measurement (`Tools/tests/icons-test.sh`).

## Why the generator lives here

`make-icons.swift` rasterises through CoreSVG (AppKit's `NSImage`) and reads the `.icon`, so the only renderer it needs
ships with macOS: no dependency is added. Its source is in `apps/apple/Resources`, and `apps/apple`'s `make test-tools`
is the suite that runs on the build Macs. The other shells only consume committed files, so none of them needs a
macOS tool to build. There is no repository-wide `tools/` folder (ADR-0006), and one generator is not a reason to start
one.

## The rules it applies

Every number is in `Rules` in `make-icons.swift`, and `verify` measures every output against them: sizes,
transparency, the ink's bounding box, safe zones and contrast.

| Rule | Value | Source |
|---|---|---|
| Plate shape (platforms that do not mask) | superellipse, n = 4.4 | fitted to the masks of Notes, Calendar and Terminal on macOS 27.0.1 |
| Grid margin (Linux, PWA `any`) | 100/1024 a side | Apple's tile, 824 of 1024. GNOME asks for margin and gives no number |
| Tight margin (Windows, favicons, extension 16–48, Android legacy) | 2/48 a side | Windows' 48-px icon grid |
| Extension 128 | 96 px artwork, 16 px margin | Chrome's extension icon guidance |
| Glyph instead of mark | at 32 px and below | the designer's reason for the glyph (above) |
| Android adaptive | 108 dp canvas, 72 dp shown, 66 dp safe circle; mark ink to 32 dp from the centre | Android adaptive icons |
| PWA maskable | mark inside 0.40 of the width from the centre (drawn to 0.37) | W3C manifest, "maskable" |
| Tray, toolbar | glyph fills 14/16, both axes | chosen; ink never touches the edge |
| Android notification | white glyph on alpha, 20 dp live area in 24 dp | Android status-bar icons |
| Windows unplated (taskbar) | dark theme: the `.icon`'s dark mark; light theme: its light mark | Windows asks for both, or it plates the icon itself |
| Windows 10 tiles | the dark mark at 0.5 of the tile height (Small 0.66) on `#1B2A4A` | chosen; Windows 11 does not show tiles, and the Store needs MedTile at 100% |
| Surfaces for contrast rows | light `#F3F3F3`, dark `#202020` | approximations of Windows 11's taskbars; not read from a system |

ICO members are PNG at every size. Windows reads PNG members from Vista on. The legacy BMP encoding is not written.
