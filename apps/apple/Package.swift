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
        // What the app and the service share, and no domain vocabulary beyond it: the bundle identities, and the values
        // the launch window shows (the core's versions, and how asking for them failed). No framework at all.
        .target(name: "XDictBase"),

        // **The IPC contract between the app and the service, frozen at WI-1** (ADR-0009): the NSXPC protocols and
        // their interfaces, the versioned envelopes, the records both sides exchange, the error kinds, the limits and
        // the deadlines. Foundation only, and no other target of this package: the app compiles it without the core,
        // and the service converts the core's types into it (`ModuleBoundaryTests` holds both).
        .target(name: "XDictContract"),

        // The view layer, apart from the app so Xcode can preview it. Reader-facing text lives here and in the app,
        // and nowhere below (`StringCatalogTests`).
        .target(name: "XDictUI", dependencies: ["XDictBase", "XDictContract", "XDictLibrary"]),

        // **The entry view and its confinement** (plan-macos-v1 WI-4; ADR-0009 decision 7; ADR-0007 decision 14): a
        // `WKWebView` per open dictionary, its `xdict:` scheme handler, the core's policy as a header on every response,
        // the rule list, the navigation and UI delegates, the two WebKit switches read back before anything renders, the
        // reader's consent before a remote link leaves, find, zoom and appearance. Its own target because it binds
        // WebKit and AppKit, which nothing else in the view layer does. It gets bytes through `EntryContent`, never the
        // contract's types, so the service's client plugs in without the view knowing the wire (WI-3, WI-6).
        .target(name: "XDictEntryView", dependencies: ["XDictBase"]),

        // **The app's side of the contract** (plan-macos-v1 WI-3): `ServiceClient` — request ids, deadlines, credits,
        // generations per caller, reconnection, handles reopened after a restart, payload ceilings — over a transport
        // seam (NSXPC, or a test's fake), and the tokens it sends. No core: it asks the service.
        .target(name: "XDictClient", dependencies: ["XDictBase", "XDictContract"]),

        // The development instruments' scenarios (the E2E `service` stage): the conformance fixtures answered through the
        // contract, and the service's checks that need a real service — a kill, a stall, a racing idle timer. They ship
        // in the app, as the handshake report does: they read only the fixtures they are pointed at.
        .target(name: "XDictInstruments", dependencies: ["XDictClient", "XDictContract", "XDictLibrary"]),

        // **The reader's library** (plan-macos-v1 WI-5; ADR-0009 decision 2: the app's own, in its Application Support):
        // which files make each dictionary and where they are now (a security-scoped bookmark and a file id per file),
        // packages found in what the reader chose and kept inside it, imports with progress, cancel and retry, the
        // order, names, languages and enablement, a changed edition recognised, and lineage joins made only by the
        // reader and undone exactly. Kinds, never sentences: the view layer words them. No core: it asks the service.
        .target(name: "XDictLibrary", dependencies: ["XDictClient", "XDictContract"]),

        // The app: not sandboxed, Developer ID, hardened runtime. **It never links the core** — it asks the service.
        .executableTarget(name: "XDict", dependencies: ["XDictBase", "XDictClient", "XDictContract", "XDictEntryView",
                                                        "XDictInstruments", "XDictLibrary", "XDictUI"]),

        // **A development instrument, never in XDict.app** (`Tools/build-lab.sh`, `Tools/build-bundle.sh` holds the app
        // to its two executables): the production entry view, fed by the core linked in directly, so the E2E stages can
        // render the hostile battery and real dictionaries before the service answers entries (WI-3). It is the only
        // place a confinement layer can be switched off (`--disable-layer`), for the isolated per-layer controls.
        .executableTarget(name: "XDictEntryLab", dependencies: ["XDictCore", "XDictEntryView"]),

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
        // the core (ADR-0001 decision 5), answering the frozen contract.
        .executableTarget(name: "XDictService", dependencies: ["XDictBase", "XDictContract", "XDictCore"]),

        // What the test targets share, and nothing ships: a source walk that cannot skip silently, a directory that
        // removes itself, and the manifest as SwiftPM reads it.
        .target(name: "XDictTestSupport", path: "Tests/Support"),
        .testTarget(name: "XDictBaseTests", dependencies: ["XDictBase"]),
        // The client against services of the tests' own: fakes of the transport, and NSXPC listeners in this process.
        .testTarget(name: "XDictClientTests", dependencies: ["XDictBase", "XDictClient", "XDictContract"]),
        // The contract as the app sees it, with no core: envelopes, files, identity, admission, the NSXPC interfaces.
        .testTarget(name: "XDictContractTests", dependencies: ["XDictContract"]),
        .testTarget(name: "XDictUITests", dependencies: ["XDictBase", "XDictLibrary", "XDictUI"]),
        // The library without a service: packages found on disk, bookmarks across a move, languages, names, the
        // document, refusals and sounds; the model against a fake of the service.
        .testTarget(name: "XDictLibraryTests", dependencies: ["XDictClient", "XDictContract", "XDictLibrary"]),
        // The entry view's decisions, without a window or a web view (the build Mac opens neither): routing and refusal,
        // the policy on every response, the rule list, the navigation table, the switches' read-back, link routing, the
        // consent gate, find's counting and the readability rule (their JavaScript in JavaScriptCore), preferences.
        .testTarget(name: "XDictEntryViewTests", dependencies: ["XDictEntryView"]),
        // The one test target besides the service that reaches the core: the service's own listener, over a real NSXPC
        // connection in this process, asked through the real client and the instruments' scenarios; and the core's
        // types mapped into the contract's.
        .testTarget(name: "XDictServiceTests", dependencies: ["XDictClient", "XDictContract", "XDictCore",
                                                              "XDictInstruments", "XDictService"]),
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
