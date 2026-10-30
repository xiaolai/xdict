import Foundation
import Testing
import XDictTestSupport

/// **Hover asks in its own list; the popup's other triggers ask in the popup's** (owner, 2026-10-30): the presenter sets
/// the list from the request's trigger before the term is submitted, and the panel's model reads it for both its places
/// — the frames and the page. The app target has no test of a real popup; the composition is read off the code, and the
/// rule itself is `PopupPreferencesTests`.
struct PopupOrderWiringTests {
    static let anywhere = "Sources/XDict/LookupAnywhere.swift"
    static let window = "Sources/XDictUI/SearchWindowState.swift"

    @Test func theTriggerChoosesTheList() throws {
        let text = try String(contentsOf: Manifest.package.appending(path: Self.anywhere), encoding: .utf8)
        let body = try #require(DocumentDrawWiringTests.function("accept", in: text), "accept was not found")
        #expect(body.contains("trigger == .pointerGesture ? .hover : .popup"),
                "the popup no longer chooses its list by the request's trigger")
        #expect(body.contains("popupList.list ="), "the list is never set before the term is submitted")
    }

    @Test func thePanelsModelReadsTheChosenList() throws {
        let text = try String(contentsOf: Manifest.package.appending(path: Self.window), encoding: .utf8)
        #expect(text.contains("PopupPreferences.ordered(sources.filter(\\.enabled).map(\\.id), list: popupList.list)"),
                "the model's sources no longer follow the list the trigger chose")
        #expect(text.contains("PopupPreferences.ordered(items.map { $0.id }, list: popupList.list)"),
                "the panel's page no longer follows the list the trigger chose")
    }
}
