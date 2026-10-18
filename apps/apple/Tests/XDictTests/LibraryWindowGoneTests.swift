import Foundation
import Testing
import XDictTestSupport

/// **The Library window is gone** (ADR-0012 d.5): no scene, no window id and no ⇧⌘L anywhere in the app's sources.
/// Every way in opens Settings ▸ Dictionaries instead (`SettingsRouteTests`).
struct LibraryWindowGoneTests {
    static func sources() throws -> [(name: String, text: String)] {
        let root = Manifest.package.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        return try files.map { ($0.path, try String(contentsOf: $0, encoding: .utf8)) }
    }

    /// The scan sees the sources at all: a scan of nothing would pass every check below.
    @Test func theScanReadsTheApp() throws {
        let all = try Self.sources()
        #expect(all.contains { $0.name.hasSuffix("XDict/XDictApp.swift") && $0.text.contains("Settings {") })
    }

    @Test func noLibraryWindowIdIsLeft() throws {
        for file in try Self.sources() {
            #expect(!file.text.contains("libraryWindow"), "\(file.name) still names the library window")
            #expect(!file.text.contains("Window(\"Library\""), "\(file.name) still declares the Library window")
            #expect(!file.text.contains("LibraryView("), "\(file.name) still shows the Library window's view")
        }
    }

    @Test func shiftCommandLIsUnbound() throws {
        let bound = #/keyboardShortcut\(\s*"l"\s*,\s*modifiers:\s*\[[^\]]*\.shift[^\]]*\]/#
        for file in try Self.sources() {
            #expect(file.text.firstMatch(of: bound) == nil, "\(file.name) binds ⇧⌘L")
        }
    }

    /// Positive control: the pattern does see a ⇧⌘L binding.
    @Test func theShortcutPatternSeesABinding() {
        let bound = #/keyboardShortcut\(\s*"l"\s*,\s*modifiers:\s*\[[^\]]*\.shift[^\]]*\]/#
        #expect(#".keyboardShortcut("l", modifiers: [.command, .shift])"#.firstMatch(of: bound) != nil)
    }
}
