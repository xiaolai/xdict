import Foundation
import Testing
import XDictTestSupport

/// **The app's half of XiaolaiDict's `ScriptFilterWiringTests`** (moved by name from its `HoverAuditTests.swift` at
/// `044dac6`; capture-migration manifest §7.2), re-checked against XDict's layout: the selection path is
/// `Sources/XDict/LookupAnywhere.swift` and `Sources/XDictCaptureMac/SelectionReader.swift`, and hover's settings live
/// in `XDictAnywhere`. Read off the code, comments and a string's own text removed.
struct ScriptFilterWiringTests {
    private func code(_ path: String) throws -> String {
        SourceScan.codeWithInterpolations(try String(contentsOf: Manifest.package.appending(path: path), encoding: .utf8))
    }

    /// **The shortcut path is not filtered by script.** The reader selected that text and pressed the key; refusing it
    /// would be refusing something explicitly asked for. If this ever needs to change it should be a second, separate
    /// switch — not hover's leaking across. The premise: hover's reader does ask, by the spelling searched for.
    @Test func theSelectionShortcutIsNotFilteredByScript() throws {
        #expect(try code("Sources/XDictCaptureMac/HoverReader.swift").contains(".allows("),
                "hover's reader no longer asks the script filter by this spelling: the search sees nothing")
        for path in ["Sources/XDict/LookupAnywhere.swift", "Sources/XDictCaptureMac/SelectionReader.swift"] {
            let text = try code(path)
            #expect(!text.contains(".allows(") && !text.contains("allowedScripts"),
                    "\(path) consults the hover script filter, which refuses what the reader asked for")
        }
    }

    /// **Hover's settings read the suite they were given and no other.** `init(defaults:)` exists so a test never touches
    /// the reader's own preferences; a store reaching `UserDefaults.standard` would switch hover off for the person using
    /// the Mac whenever a test toggled it. Mechanical, because the next setting added is the one that would slip. The
    /// premise: the target's stores do take an injected suite.
    @Test func theAppReadsOnlyTheDefaultsSuiteItWasGiven() throws {
        let files = try SourceScan.files(under: Manifest.package.appending(path: "Sources/XDictAnywhere"))
        #expect(files.contains { $0.text.contains("defaults: UserDefaults") }, "no store in XDictAnywhere takes a suite")
        let reaching = files.filter {
            let text = SourceScan.codeWithInterpolations($0.text)
            return text.contains("UserDefaults.standard") || text.contains("?? .standard")
        }
        #expect(reaching.isEmpty, "reaching past the injected suite: \(reaching.map(\.file.lastPathComponent))")
    }
}
