import Foundation
import Testing
import XDictTestSupport

/// **The boundaries the targets are drawn for, asserted rather than described** (adapted from XiaolaiDict's
/// `ModuleBoundaryTests`, ADR-0052 there). Above all: **the core is reachable from the dictionary service alone**
/// (AGENTS.md: every `.mdx` and `.mdd` is parsed in the XPC service, never in the app), by SwiftPM's graph and by what
/// each file imports. The graph alone is not enough: a module already built is on the search path, so an `import` with
/// no declared edge can compile by accident. `Tools/build-bundle.sh` asks the same of the binaries it ships.
struct ModuleBoundaryTests {
    /// The core, as the shell sees it: the generated binding and the archive under it.
    static let coreModules: Set<String> = ["XDictCore", "xdictFFI"]

    /// Who may reach the core: the binding itself, the service, and the service's tests. Nothing that ships, ever.
    static let mayReachTheCore: Set<String> = ["XDictCore", "XDictService", "XDictServiceTests"]

    /// **The one exception, by name: `XDictEntryLab`, a development host that never ships** (plan-macos-v1 WI-4). It is
    /// the production entry view fed by the core linked in directly, so the E2E stages can render the hostile battery
    /// and real dictionaries on the E2E Mac before the service answers entries. It is an exception only while it stays
    /// a leaf — nothing in this package depends on it (`theDevelopmentHostIsALeaf`) — and `Tools/build-bundle.sh`
    /// refuses an XDict.app that carries it, or an app binary that carries its `--disable-layer` flag. The app and the
    /// entry view are held to the rule above like every other target.
    static let developmentHostsReachingTheCore: Set<String> = ["XDictEntryLab"]

    /// **Who may reach the Apple dictionary converter** (ADR-0011 decision 3): the converter, the dictionary service that
    /// runs it, and their tests. An Apple bundle is untrusted binary input, parsed in the service and never in the app
    /// (ADR-0001), so nothing else that ships may link it, the development lab included.
    static let appleImportModule = "XDictAppleImport"
    static let mayReachTheAppleImport: Set<String> = ["XDictAppleImport", "XDictAppleImportTests", "XDictService",
                                                      "XDictServiceTests"]

    /// What each target may bind besides this package's own modules. **Exact sets, not floors**: a framework arriving in
    /// a target is a line in a diff and a decision, and one nothing imports any more is a line to drop.
    static let systemModules: [String: Set<String>] = [
        // No UI and no domain: the identities, the core's versions and the launch window's sentences, plain Swift.
        "XDictBase": [],
        // The IPC contract: Foundation alone (`theContractStandsAlone` says why, and refuses more).
        "XDictContract": contractMayBind,
        // `UniformTypeIdentifiers` names what the library's Add Dictionaries… offers; `AppKit` is the main window's
        // search field and the entry view's place in it, `Observation` the window's state (plan-macos-v1 WI-6);
        // `ServiceManagement` launch at login and `os` the log of its refusal (WI-9).
        "XDictUI": ["AppKit", "Foundation", "Observation", "ServiceManagement", "SwiftUI", "UniformTypeIdentifiers", "os"],
        // The main window's model: the search the window observes, plain Swift (WI-6).
        "XDictSearch": ["Foundation", "Observation"],
        "XDictSearchTests": ["Foundation", "Synchronization", "Testing"],
        // Sound and speech (WI-7): the system's voices, its audio player and synthesiser; their log.
        "XDictSpeech": ["AVFAudio", "Foundation", "os"],
        "XDictSpeechTests": ["AVFAudio", "Foundation", "Testing"],
        // Lookup from anywhere (WI-8): Carbon's hot keys, the Accessibility API, the front app and the window list
        // (`AppKit`, `CoreGraphics`), the shortcut's state the Settings field observes, its log.
        "XDictAnywhere": ["AppKit", "ApplicationServices", "Carbon.HIToolbox", "CoreGraphics", "Foundation", "Observation",
                          "os"],
        "XDictAnywhereTests": ["ApplicationServices", "Carbon.HIToolbox", "CoreGraphics", "Foundation", "Testing"],
        // The entry view: the web view, its delegates and the consent prompt; its log.
        "XDictEntryView": ["AppKit", "Foundation", "WebKit", "os"],
        // `AppKit`: the library's drag-and-drop instrument shows its window by hand (`LibraryDropReport`). `WebKit`: the
        // main window's instruments read the entry's page in a content world of their own (`InstrumentPage`, WI-6).
        // `ApplicationServices`: the lookup-anywhere instrument says whether the app may read other apps
        // (`AXIsProcessTrusted`); `Observation`: the panel's state (plan-macos-v1 WI-8).
        "XDict": ["AppKit", "ApplicationServices", "Foundation", "Observation", "SwiftUI", "WebKit", "os"],
        // The development lab: the entry view's windows, and a drop target for the reader-driven drag tests.
        "XDictEntryLab": ["AppKit", "Foundation", "UniformTypeIdentifiers", "WebKit"],
        // `Security` reads the service's own signature for the client requirement (`ClientCheck`); `CryptoKit` hashes an
        // Apple dictionary snapshot for its source revision (`AppleImports`, ADR-0011 decision 7).
        "XDictService": ["CryptoKit", "Foundation", "Security", "Synchronization", "os"],
        // The app's side of the contract: NSXPC, its locks, its log.
        "XDictClient": ["Foundation", "Synchronization", "os"],
        // The E2E instruments, compiled into the app and run by its flags.
        "XDictInstruments": ["Foundation", "Synchronization"],
        // The reader's library: the model the view layer observes, the locks of a file's live location, its log.
        "XDictLibrary": ["Foundation", "Observation", "Synchronization", "os"],
        "XDictLibraryTests": ["Foundation", "Testing"],
        // Generated by UniFFI: Foundation and the archive's C module (`xdictFFI`, a package module).
        "XDictCore": ["Foundation"],
        // The Apple dictionary converter (ADR-0011): Foundation, and the system's libz for the bundles' and the MDX
        // blocks' zlib streams (strict about a stream's end, which the Compression framework does not report).
        "XDictAppleImport": ["Foundation", "zlib"],
        "XDictAppleImportTests": ["Foundation", "Testing"],
        // `zlib`: the synthetic Apple bundles compress their sections as Apple's do (`SyntheticAppleBundle`).
        "XDictTestSupport": ["Foundation", "zlib"],
        "XDictBaseTests": ["Foundation", "Testing"],
        "XDictContractTests": ["Foundation", "Synchronization", "Testing"],
        // AppKit and SwiftUI: the search field's AppKit coordinator and the menu's key equivalents, tested as they are.
        "XDictUITests": ["AppKit", "Carbon.HIToolbox", "Foundation", "SwiftUI", "Testing"],
        // WebKit's preferences and rule-list store, never a web view; JavaScriptCore for the shell's scripts.
        "XDictEntryViewTests": ["AppKit", "Foundation", "JavaScriptCore", "Testing", "WebKit"],
        "XDictServiceTests": ["Foundation", "Synchronization", "Testing"],
        "XDictClientTests": ["Foundation", "Synchronization", "Testing"],
        // `AppKit`: the menu-bar glyph drawn through CoreSVG and measured (`BundleFactsTests`).
        "XDictTests": ["AppKit", "Foundation", "Testing"],
    ]

    /// **The contract binds Foundation and nothing else, and depends on no target of this package.** Both processes
    /// compile it: the app, which must never reach the core, and the service, which has no UI. So it may not import the
    /// core (the app could not link it), AppKit or SwiftUI (the service would carry a UI framework), nor `XDictBase` or
    /// any other target here (a frozen contract that moves with the code beside it is not frozen).
    static let contractMayBind: Set<String> = ["Foundation"]

    /// The settings every compiled target carries, as `dump-package` spells them.
    static let everyTargetIsCompiledWith: Set<String> = [
        "treatAllWarnings error", "enableUpcomingFeature MemberImportVisibility",
    ]

    // MARK: - The core

    @Test func onlyTheServiceReachesTheCoreInTheGraph() throws {
        let targets = try Manifest.dump().targets
        let reaching = Self.coreModules.reduce(into: Set<String>()) { $0.formUnion(Manifest.reaching($1, in: targets)) }
        #expect(Self.graphProblems(reaching: reaching) == [])
        // The premise: the service does link it. A check that holds because nothing links the core holds nothing.
        #expect(reaching.contains("XDictService"), "the service no longer reaches the core: \(reaching.sorted())")
        // The app and the entry view, named, though the rule above covers them: they are what the exception sits beside.
        #expect(!reaching.contains("XDict") && !reaching.contains("XDictEntryView"), "\(reaching.sorted())")
    }

    /// **The development host is a leaf, and still a development host**: an executable nothing depends on, which does
    /// reach the core (an exception nothing uses is a line to drop).
    @Test func theDevelopmentHostIsALeaf() throws {
        let targets = try Manifest.dump().targets
        #expect(Self.leafProblems(targets) == [])
        for host in Self.developmentHostsReachingTheCore {
            #expect(targets[host]?.type == "executable", "\(host) is not an executable target")
            #expect(Manifest.reaching("XDictCore", in: targets).contains(host), "\(host) no longer reaches the core")
        }
    }

    /// **The control: a target that depends on the development host, and the entry view reaching the core, are named**;
    /// the host itself, importing the core, is not.
    @Test func aTargetBesideTheDevelopmentHostIsHeldToTheRule() throws {
        let lab = Manifest.Target(name: "XDictEntryLab", type: "executable", dependencies: ["XDictCore"], path: "",
                                  swiftSettings: [])
        let app = Manifest.Target(name: "XDict", type: "executable", dependencies: ["XDictEntryLab"], path: "",
                                  swiftSettings: [])
        #expect(Self.leafProblems(["XDictEntryLab": lab, "XDict": app]) == ["XDict depends on XDictEntryLab"])
        #expect(Self.graphProblems(reaching: ["XDictService", "XDictEntryLab", "XDictEntryView"])
                == ["XDictEntryView reaches the core"])
        let scratch = try TemporaryDirectory(named: "xdict-planted-entry-core-import")
        try "import Foundation\n@preconcurrency import XDictCore\n"
            .write(to: scratch.appending("Planted.swift"), atomically: true, encoding: .utf8)
        let planted = try SourceScan.files(under: scratch.url).map { ($0.file.lastPathComponent, SourceScan.imports(in: $0.text)) }
        #expect(Self.importProblems(["XDictEntryView": planted, "XDictEntryLab": planted])
                == ["XDictEntryView/Planted.swift imports XDictCore"])
    }

    @Test func onlyTheServiceImportsTheCore() throws {
        let files = try Self.importsByTarget()
        #expect(files.values.allSatisfy { !$0.isEmpty }, "a target whose walk read nothing: \(files.filter(\.value.isEmpty).keys.sorted())")
        #expect(Self.importProblems(files) == [])
    }

    /// **The control: a planted import of the core in the app is refused** — on a list no scan made, and through a
    /// real scan of a directory of the test's own, never by writing into `Sources/`.
    @Test func aCoreImportOutsideTheServiceIsRefused() throws {
        let scratch = try TemporaryDirectory(named: "xdict-planted-core-import")
        try "import Foundation\n@preconcurrency import XDictCore\n"
            .write(to: scratch.appending("Planted.swift"), atomically: true, encoding: .utf8)
        let planted = try SourceScan.files(under: scratch.url).map { ($0.file.lastPathComponent, SourceScan.imports(in: $0.text)) }
        #expect(Self.importProblems(["XDict": planted]) == ["XDict/Planted.swift imports XDictCore"])
        #expect(Self.importProblems(["XDictService": planted]) == [])
        #expect(Self.graphProblems(reaching: ["XDictService", "XDictUI"]) == ["XDictUI reaches the core"])
    }

    // MARK: - The Apple dictionary converter

    @Test func onlyTheServiceReachesTheAppleImport() throws {
        let targets = try Manifest.dump().targets
        let reaching = Manifest.reaching(Self.appleImportModule, in: targets)
        #expect(Self.appleImportGraphProblems(reaching: reaching) == [])
        let files = try Self.importsByTarget()
        #expect(Self.appleImportImportProblems(files) == [])
        // The premise: the service does link it. A rule about a module nothing uses holds nothing.
        #expect(reaching.contains("XDictService"), "the service no longer reaches the converter: \(reaching.sorted())")
        #expect(files["XDictService"]?.contains { $0.modules.contains(Self.appleImportModule) } == true)
    }

    /// **The control: the app, the lab or the library reaching the converter is named**, by the graph and by a planted
    /// import scanned from a directory of the test's own; the service and the converter's tests are not.
    @Test func aTargetReachingTheAppleImportIsNamed() throws {
        #expect(Self.appleImportGraphProblems(reaching: ["XDictService", "XDictServiceTests", "XDict", "XDictEntryLab"])
                == ["XDict reaches the Apple import", "XDictEntryLab reaches the Apple import"])
        let scratch = try TemporaryDirectory(named: "xdict-planted-apple-import")
        try "import Foundation\nimport XDictAppleImport\n"
            .write(to: scratch.appending("Planted.swift"), atomically: true, encoding: .utf8)
        let planted = try SourceScan.files(under: scratch.url).map { ($0.file.lastPathComponent, SourceScan.imports(in: $0.text)) }
        #expect(Self.appleImportImportProblems(["XDictLibrary": planted, "XDictService": planted,
                                                "XDictAppleImportTests": planted])
                == ["XDictLibrary/Planted.swift imports XDictAppleImport"])
    }

    static func appleImportGraphProblems(reaching: Set<String>) -> [String] {
        reaching.subtracting(mayReachTheAppleImport).sorted().map { "\($0) reaches the Apple import" }
    }

    static func appleImportImportProblems(_ files: [String: [(file: String, modules: [String])]]) -> [String] {
        files.sorted(by: { $0.key < $1.key }).flatMap { target, files in
            mayReachTheAppleImport.contains(target) ? [] : files.flatMap { file, modules in
                modules.filter { $0 == appleImportModule }.map { "\(target)/\(file) imports \($0)" }
            }
        }
    }

    // MARK: - The entry view's confinement

    /// **Only the development lab builds a confinement other than `.production`** (ADR-0009 decision 7). The
    /// initialiser is `package`, so the compiler lets every target here call it; this holds the app to the one value:
    /// no target but the entry view (which declares `.production`) and the lab writes `EntryConfinement(`.
    @Test func onlyTheLabBuildsAConfinementWithALayerOff() throws {
        var files: [String: [(file: String, text: String)]] = [:]
        for target in try Manifest.dump().targets.values where target.type != "binary" && target.type != "test" {
            files[target.name] = try SourceScan.files(under: Manifest.package.appending(path: target.path))
                .map { ($0.file.lastPathComponent, $0.text) }
        }
        #expect(Self.confinementProblems(files) == [])
        // The premise: the lab does build one, so the search can see the spelling it looks for.
        #expect(files["XDictEntryLab"]?.contains { SourceScan.codeOnly($0.text).contains("EntryConfinement(") } == true)
    }

    /// The control: the app building one is named; a comment or a string naming it is not.
    @Test func aConfinementBuiltOutsideTheLabIsNamed() {
        let planted = "let c = EntryConfinement(policyHeader: false, ruleList: true)\n"
        let innocent = "// EntryConfinement(policyHeader: false)\nlet s = \"EntryConfinement(\"\n"
        #expect(Self.confinementProblems(["XDict": [("Planted.swift", planted), ("Innocent.swift", innocent)],
                                          "XDictEntryLab": [("Lab.swift", planted)]])
                == ["XDict/Planted.swift builds an EntryConfinement"])
    }

    static func confinementProblems(_ files: [String: [(file: String, text: String)]]) -> [String] {
        files.sorted(by: { $0.key < $1.key }).flatMap { target, files in
            ["XDictEntryView", "XDictEntryLab"].contains(target) ? [] : files.filter {
                SourceScan.codeOnly($0.text).contains("EntryConfinement(")
            }.map { "\(target)/\($0.file) builds an EntryConfinement" }
        }
    }

    /// **Only the development lab renders with a reading style other than the compiled one** (plan-verification §4.6).
    /// `EntryStyle(replacing:)` is the one way to make another, and it is `package`, so the compiler lets every target
    /// here call it; this holds the app to `EntryStyle.bundled`, whose text is in the binary and on no path at run time.
    @Test func onlyTheLabReplacesTheReadingStyle() throws {
        var files: [String: [(file: String, text: String)]] = [:]
        for target in try Manifest.dump().targets.values where target.type != "binary" && target.type != "test" {
            files[target.name] = try SourceScan.files(under: Manifest.package.appending(path: target.path))
                .map { ($0.file.lastPathComponent, $0.text) }
        }
        #expect(Self.styleProblems(files) == [])
        // The premise: the lab does replace it, so the search can see the spelling it looks for.
        #expect(files["XDictEntryLab"]?.contains { SourceScan.codeOnly($0.text).contains("EntryStyle(replacing:") } == true)
    }

    /// The control: the app or the entry view replacing it is named; a comment or a string naming it is not.
    @Test func aStyleReplacedOutsideTheLabIsNamed() {
        let planted = "let s = try EntryStyle(replacing: texts)\n"
        let innocent = "// EntryStyle(replacing: texts)\nlet s = \"EntryStyle(replacing:\"\n"
        #expect(Self.styleProblems(["XDict": [("Planted.swift", planted), ("Innocent.swift", innocent)],
                                    "XDictEntryView": [("View.swift", planted)],
                                    "XDictEntryLab": [("Lab.swift", planted)]])
                == ["XDict/Planted.swift replaces the reading style", "XDictEntryView/View.swift replaces the reading style"])
    }

    static func styleProblems(_ files: [String: [(file: String, text: String)]]) -> [String] {
        files.sorted(by: { $0.key < $1.key }).flatMap { target, files in
            target == "XDictEntryLab" ? [] : files.filter {
                SourceScan.codeOnly($0.text).contains("EntryStyle(replacing:")
            }.map { "\(target)/\($0.file) replaces the reading style" }
        }
    }

    // MARK: - The contract

    @Test func theContractStandsAlone() throws {
        let targets = try Manifest.dump().targets
        let contract = try #require(targets["XDictContract"], "no XDictContract target")
        let files = try #require(try Self.importsByTarget()["XDictContract"])
        #expect(!files.isEmpty, "the walk read nothing of XDictContract")
        #expect(Self.contractProblems(dependencies: contract.dependencies, files: files) == [])
        // The premise: both sides compile against it. A rule about a module nothing uses holds nothing.
        #expect(Manifest.reaching("XDictContract", in: targets).contains("XDictService"),
                "the service no longer compiles against the contract")
    }

    /// **The control: a contract that imports the core, AppKit or a target of this package, or depends on one, is
    /// named** — on a scan of a directory of the test's own, never by writing into `Sources/`.
    @Test func aContractThatReachesFurtherIsNamed() throws {
        let scratch = try TemporaryDirectory(named: "xdict-planted-contract-import")
        try "import Foundation\nimport AppKit\n@preconcurrency import XDictCore\nimport XDictBase\n"
            .write(to: scratch.appending("Planted.swift"), atomically: true, encoding: .utf8)
        let planted = try SourceScan.files(under: scratch.url).map { ($0.file.lastPathComponent, SourceScan.imports(in: $0.text)) }
        #expect(Self.contractProblems(dependencies: ["XDictBase"], files: planted) == [
            "XDictContract depends on XDictBase",
            "XDictContract/Planted.swift imports AppKit",
            "XDictContract/Planted.swift imports XDictCore",
            "XDictContract/Planted.swift imports XDictBase",
        ])
        #expect(Self.contractProblems(dependencies: [], files: [("Clean.swift", ["Foundation"])]) == [])
    }

    // MARK: - Every target's edges and frameworks

    /// **An import with no declared edge, and a declared edge nothing imports**, in every target, tests included. The
    /// first compiles only by accident, against a module already on the search path; the second is how a target comes
    /// to link a subject it does not use.
    @Test func declaredDependenciesAndImportsAgree() throws {
        let targets = try Manifest.dump().targets
        let ours = Set(targets.keys)
        var problems: [String] = []
        for (name, files) in try Self.importsByTarget().sorted(by: { $0.key < $1.key }) {
            let imported = files.reduce(into: Set<String>()) { $0.formUnion($1.modules.filter(ours.contains)) }
            let declared = targets[name]?.dependencies ?? []
            for module in imported.subtracting(declared).sorted() { problems.append("\(name) imports \(module) undeclared") }
            for module in declared.subtracting(imported).sorted() { problems.append("\(name) declares \(module) and imports it nowhere") }
        }
        #expect(problems == [])
    }

    @Test func eachTargetBindsOnlyWhatItIsAllowedTo() throws {
        let targets = try Manifest.dump().targets
        let ours = Set(targets.keys)
        let compiled = Set(targets.values.filter { $0.type != "binary" }.map(\.name))
        #expect(Set(Self.systemModules.keys) == compiled, "targets with a row here and targets SwiftPM compiles differ")
        var problems: [String] = []
        for (name, files) in try Self.importsByTarget().sorted(by: { $0.key < $1.key }) {
            let bound = files.reduce(into: Set<String>()) { $0.formUnion($1.modules.filter { !ours.contains($0) }) }
            let permitted = Self.systemModules[name] ?? []
            if !bound.subtracting(permitted).isEmpty { problems.append("\(name) newly binds \(bound.subtracting(permitted).sorted())") }
            if !permitted.subtracting(bound).isEmpty { problems.append("\(name) no longer binds \(permitted.subtracting(bound).sorted())") }
        }
        #expect(problems == [])
    }

    /// Asked of SwiftPM's evaluation of the manifest, not its text: a target appended after the loop that sets both,
    /// or a loop that stopped setting one, is named.
    @Test func everyTargetIsCompiledWithMemberImportVisibilityAndWarningsAsErrors() throws {
        let missing = Self.settingsMissing(try Manifest.dump().targets)
        #expect(missing == [])
    }

    /// **The control**: a target declared after the loop, in a copy of the manifest SwiftPM evaluates.
    @Test func aTargetCompiledWithoutTheSettingsIsNamed() throws {
        let manifest = try String(contentsOf: Manifest.package.appending(path: "Package.swift"), encoding: .utf8)
        let late = try TemporaryDirectory(named: "xdict-planted-late-target")
        try (manifest + "\npackage.targets.append(.target(name: \"Late\"))\n")
            .write(to: late.appending("Package.swift"), atomically: true, encoding: .utf8)
        let missing = Self.settingsMissing(try Manifest.dump(of: late.url).targets)
        #expect(missing == [
            "Late is compiled without enableUpcomingFeature MemberImportVisibility",
            "Late is compiled without treatAllWarnings error",
        ])
    }

    @Test func theImportScanSeesEverySpelling() {
        let code = """
            import Foundation
            @testable import XDictService; import struct XDictCore.Versions
            /* import Hidden */ // import Commented
            let text = "import Quoted"
            internal import `xdictFFI`
            @_spi(Private) public import Carbon.HIToolbox
            """
        #expect(SourceScan.imports(in: code) == ["Foundation", "XDictService", "XDictCore", "xdictFFI", "Carbon.HIToolbox"])
    }

    // MARK: - The verdicts, apart from the reading, so each control exercises the one the real check uses

    static func graphProblems(reaching: Set<String>) -> [String] {
        reaching.subtracting(mayReachTheCore).subtracting(developmentHostsReachingTheCore).sorted()
            .map { "\($0) reaches the core" }
    }

    static func importProblems(_ files: [String: [(file: String, modules: [String])]]) -> [String] {
        files.sorted(by: { $0.key < $1.key }).flatMap { target, files in
            mayReachTheCore.contains(target) || developmentHostsReachingTheCore.contains(target) ? [] : files.flatMap { file, modules in
                modules.filter(coreModules.contains).map { "\(target)/\(file) imports \($0)" }
            }
        }
    }

    /// Every target that depends on a development host, directly or through another.
    static func leafProblems(_ targets: [String: Manifest.Target]) -> [String] {
        developmentHostsReachingTheCore.sorted().flatMap { host in
            Manifest.reaching(host, in: targets).sorted().map { "\($0) depends on \(host)" }
        }
    }

    static func contractProblems(dependencies: Set<String>, files: [(file: String, modules: [String])]) -> [String] {
        dependencies.sorted().map { "XDictContract depends on \($0)" } + files.flatMap { file, modules in
            modules.filter { !contractMayBind.contains($0) }.map { "XDictContract/\(file) imports \($0)" }
        }
    }

    static func settingsMissing(_ targets: [String: Manifest.Target]) -> [String] {
        targets.values.filter { $0.type != "binary" }.sorted { $0.name < $1.name }.flatMap { target in
            everyTargetIsCompiledWith.subtracting(target.swiftSettings).sorted().map { "\(target.name) is compiled without \($0)" }
        }
    }

    /// Every compiled target's files and what each imports, read where SwiftPM reads the target from.
    static func importsByTarget() throws -> [String: [(file: String, modules: [String])]] {
        let targets = try Manifest.dump().targets.values.filter { $0.type != "binary" }
        var byTarget: [String: [(file: String, modules: [String])]] = [:]
        for target in targets {
            byTarget[target.name] = try SourceScan.files(under: Manifest.package.appending(path: target.path))
                .map { ($0.file.lastPathComponent, SourceScan.imports(in: $0.text)) }
        }
        return byTarget
    }
}
