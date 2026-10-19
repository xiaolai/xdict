import Foundation
import Testing
import XDictTestSupport

/// **Settings ▸ General's hover rows keep what the UI tour found missing** (2026-10-19), read off the code since a form's
/// look cannot be run under a test: the site row and the Screen Recording row contain their controls, so the field, Add
/// Site and Allow… keep their own identifiers (without it the row's took them over), and the site field is bordered (bare,
/// its example.com prompt read as a listed site). The tour's `repeated-identifier` check reads the first from the
/// running app; the border shows only in its pictures.
struct HoverRowGuardTests {
    static let file = "Sources/XDictUI/HoverSettings.swift"
    static let containedRows = ["hover.excludedSites", "hover.screenRecording"]

    @Test func theHoverRowsContainTheirControlsAndTheSiteFieldIsBordered() throws {
        let code = try String(contentsOf: Manifest.package.appending(path: Self.file), encoding: .utf8)
        #expect(Self.uncontained(code, rows: Self.containedRows) == [])
        #expect(Self.siteFieldBordered(code))
    }

    /// **The controls**: each guard red on the code with its modifier taken out.
    @Test func aRowThatGivesAwayItsIdentifierOrABareFieldIsNamed() {
        let contained = """
            LabeledContent { Button("Allow…") {} } label: { Text("Screen Recording") }
            // a comment between them changes nothing
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("hover.screenRecording")
            """
        #expect(Self.uncontained(contained, rows: ["hover.screenRecording"]) == [])
        let given = """
            LabeledContent { Button("Allow…") {} } label: { Text("Screen Recording") }
            .accessibilityIdentifier("hover.screenRecording")
            """
        #expect(Self.uncontained(given, rows: ["hover.screenRecording"]) == ["hover.screenRecording"])
        #expect(Self.uncontained("", rows: ["hover.screenRecording"]) == ["hover.screenRecording"], "a row gone passed")
        let bordered = """
            TextField(text: $typedSite, prompt: Text(verbatim: "example.com")) { Text("Site") }
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("hover.site.field")
            """
        #expect(Self.siteFieldBordered(bordered))
        #expect(!Self.siteFieldBordered(bordered.replacingOccurrences(of: ".textFieldStyle(.roundedBorder)\n", with: "")))
        #expect(!Self.siteFieldBordered(""), "a field gone passed")
    }

    /// The rows whose identifier is not set right after `.accessibilityElement(children: .contain)`.
    static func uncontained(_ code: String, rows: [String]) -> [String] {
        let flat = Self.withoutLineComments(code)
        return rows.filter { row in
            let pattern = #"\.accessibilityElement\(children:\s*\.contain\)\s*\.accessibilityIdentifier\(""#
                + NSRegularExpression.escapedPattern(for: row) + #""\)"#
            return flat.range(of: pattern, options: .regularExpression) == nil
        }
    }

    /// Whether the site field's modifiers, from `TextField(text: $typedSite` to its identifier, hold the rounded border.
    static func siteFieldBordered(_ code: String) -> Bool {
        let flat = Self.withoutLineComments(code)
        guard let start = flat.range(of: "TextField(text: $typedSite"),
              let end = flat.range(of: #".accessibilityIdentifier("hover.site.field")"#, range: start.upperBound..<flat.endIndex)
        else { return false }
        return flat[start.upperBound..<end.lowerBound].contains(".textFieldStyle(.roundedBorder)")
    }

    static func withoutLineComments(_ code: String) -> String {
        code.replacingOccurrences(of: #"//[^\n]*"#, with: "", options: .regularExpression)
    }
}
