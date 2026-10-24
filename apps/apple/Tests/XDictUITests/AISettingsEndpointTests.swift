import AppKit
import Foundation
import SwiftUI
import Testing
import XDictAI
@testable import XDictUI

/// **An address the reader pastes survives the Test button's redraw** (2026-10-25): the Address field was bound to an
/// optional URL, and a paste with a leading space is not a URL, so the field wrote nil over the reader's address; the
/// next redraw — the key test's — then showed the field's placeholder, `http://127.0.0.1:11434/v1`, as if the server
/// address had been reset. The field's text is the reader's; only a parsed address may replace the stored one.
@MainActor
struct AISettingsEndpointTests {
    static func preferences() -> MeaningPreferences {
        let suite = "ai.xdict.tests.ai-endpoint." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return MeaningPreferences(defaults: defaults, keys: MemoryKeyStore())
    }

    @Test func aPastedAddressWithAStraySpaceSurvivesTheTestButtonsRedraw() async throws {
        let preferences = Self.preferences()
        preferences.choose(.http, cloud: true)
        preferences.update { $0.endpoint = URL(string: "https://api.example.com/v1") }
        let model = AISettingsModel(preferences: preferences)
        model.keyState = .stored  // the Test button is up

        let host = NSHostingController(rootView: AISettings(model: model, route: SettingsRoute()))
        host.sizingOptions = []
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 800, height: 760))
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        defer { window.close() }
        try await ToolbarTestSupport.settle(window)

        let address = try #require(Self.addressField(in: window.contentView), "the Address field is not shown")
        window.makeFirstResponder(address)
        try await ToolbarTestSupport.settle(window)
        let editor = try #require(address.currentEditor(), "the Address field did not take the edit")
        editor.selectAll(nil)
        editor.insertText("  https://pasted.example.com/v1\n")
        try await ToolbarTestSupport.settle(window)

        // What Test does to the view: its key row changes from the buttons to the spinner.
        model.keyState = .testing
        try await ToolbarTestSupport.settle(window)

        #expect(preferences.settings.endpoint?.absoluteString == "https://pasted.example.com/v1",
                "the pasted address was not stored")
        #expect(Self.addressField(in: window.contentView)?.stringValue == "https://pasted.example.com/v1",
                "the field fell back to its placeholder instead of the reader's address")
    }

    /// The Address row's field, where AppKit draws it: its placeholder is the example address.
    static func addressField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        var all: [NSTextField] = []
        func walk(_ view: NSView) {
            if let field = view as? NSTextField { all.append(field) }
            for sub in view.subviews { walk(sub) }
        }
        walk(view)
        return all.first { $0.placeholderString?.contains("11434") == true }
            ?? all.first { $0.accessibilityIdentifier() == "ai.endpoint" }
    }
}
