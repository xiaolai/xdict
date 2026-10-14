# apps

One native shell per platform, each written in that platform's own language and UI toolkit, each calling
the Rust core in `core/` through its binding. No shared UI framework. macOS is the reference platform.

| Folder | Platform | Language · UI | Entry view | Core binding |
|---|---|---|---|---|
| `apple/` | macOS and iOS | Swift · SwiftUI (+ AppKit on macOS) | WKWebView | UniFFI (Swift) |
| `android/` | Android | Kotlin · Jetpack Compose | Android System WebView | UniFFI (Kotlin) |
| `windows/` | Windows | C# · WinUI 3 (Windows App SDK) | WebView2 | UniFFI C# or C ABI |
| `linux/` | Linux | Rust · GTK4 + libadwaita | WebKitGTK | the core as a Rust crate |
| `web/` | Web | TypeScript | sandboxed iframe | `wasm-bindgen` |
| `extension/` | Chrome, Edge and Firefox extension (Safari's wrapper in `apple/`) | TypeScript | confined frame, no extension API | none: asks the installed app through native messaging |

The browser extension is a capture surface of the native app, not a shell with a core of its own (ADR-0008).

Each shell's inner layout is made by its own toolchain (Xcode, Gradle, `dotnet new`, Cargo, the web
bundler) when the shell starts, and every shell runs `conformance/` through its own binding in CI.
