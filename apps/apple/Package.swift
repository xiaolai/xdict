// swift-tools-version: 6.2
import PackageDescription

// XDict for macOS: the shell around the Rust core (ADR-0003), which runs in a sandboxed XPC service and never in the
// app (AGENTS.md; plan-macos-v1 WI-2). `make` builds the core first (`Tools/build-core.sh` writes `Generated/`, which
// two targets below are made of), then tests, then assembles, signs and verifies XDict.app (`Tools/build-bundle.sh`).
let package = Package(
    name: "XDict",
    // The floor, decided in AGENTS.md: macOS 27. `PlatformFloorTests` holds this, both Info.plists and every binary the
    // bundle carries to the same number, so raising any one of them alone fails.
    platforms: [.macOS("27.0")],
    targets: [
        // What the app and the service share, and no domain vocabulary beyond it: the bundle identities, and the
        // skeleton's handshake (`versions()` only, over NSXPC), its wire value and its client. WI-3 replaces the
        // handshake with the frozen contract. Foundation, Dispatch and Synchronization.
        .target(name: "XDictBase"),

        // The view layer, apart from the app so Xcode can preview it. Reader-facing text lives here and in the app,
        // and nowhere below (`StringCatalogTests`).
        .target(name: "XDictUI", dependencies: ["XDictBase"]),

        // The app: not sandboxed, Developer ID, hardened runtime. **It never links the core** — it asks the service.
        .executableTarget(name: "XDict", dependencies: ["XDictBase", "XDictUI"]),

        // **The core, and who may reach it.** `xdictFFI` is libxdict_ffi.a and its C header as an XCFramework, and
        // `XDictCore` the UniFFI binding generated from that archive; both are written by `Tools/build-core.sh` into
        // `Generated/`, which is untracked. A binary target is how SwiftPM takes a prebuilt archive without
        // `unsafeFlags`, and it links the archive statically into what depends on it. Only `XDictService` does (and
        // its tests): `ModuleBoundaryTests` refuses any other target that reaches either module, by the graph and by
        // its imports, and `Tools/build-bundle.sh` refuses an app binary carrying a core symbol.
        .binaryTarget(name: "xdictFFI", path: "Generated/xdictFFI.xcframework"),
        .target(
            name: "XDictCore",
            dependencies: ["xdictFFI"],
            path: "Generated/XDictCore",
            // What the archive asks of the system besides libSystem (`--print native-static-libs`).
            linkerSettings: [.linkedLibrary("iconv")]),

        // The dictionary service: sandboxed, with no file and no network entitlement, and the only process that runs
        // the core (ADR-0001 decision 5). Today it answers the handshake; WI-3 makes it the contract.
        .executableTarget(name: "XDictService", dependencies: ["XDictBase", "XDictCore"]),

        // What the test targets share, and nothing ships: a source walk that cannot skip silently, a directory that
        // removes itself, and the manifest as SwiftPM reads it.
        .target(name: "XDictTestSupport", path: "Tests/Support"),
        .testTarget(name: "XDictBaseTests", dependencies: ["XDictBase"]),
        .testTarget(name: "XDictUITests", dependencies: ["XDictBase", "XDictUI"]),
        // The one test target besides the service that reaches the core: it asks the service's own handler, over a
        // real NSXPC connection, and compares the answer with the core's.
        .testTarget(name: "XDictServiceTests", dependencies: ["XDictBase", "XDictCore", "XDictService"]),
        // The harness's own rules, read off the tree: module boundaries, test floors, the string catalog, the floor.
        .testTarget(name: "XDictTests", dependencies: ["XDictTestSupport"]),
    ],
    swiftLanguageModes: [.v6]
)

// **A warning is an error in every target this package compiles, and a file imports every module whose members it
// uses** (`MemberImportVisibility`). Set here, after the list, so a target added later is covered without anyone
// remembering to; `ModuleBoundaryTests` asks SwiftPM's own reading of the manifest that every target has both. A binary
// target compiles nothing and takes no settings. `Tools/compiler-warnings.py` catches what `treatAllWarnings` lets
// through (XiaolaiDict ADR-0052).
for target in package.targets where target.type != .binary {
    target.swiftSettings = (target.swiftSettings ?? []) + [
        .treatAllWarnings(as: .error), .enableUpcomingFeature("MemberImportVisibility"),
    ]
}
