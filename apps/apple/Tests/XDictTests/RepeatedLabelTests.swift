import Foundation
import Testing
import XDictTestSupport

/// **A row says its label once** (UI tour, 2026-10-19: Settings ▸ General's Background row read "Background … Glass ◯──
/// Solid Background", and "背景" twice in Chinese). A `LabeledContent` whose control carries a label of its own has the
/// form draw both, so no `LabeledContent` in the view layer may hold, in its content, a `Text` it also has as its label.
/// Read off the code, since a form's layout cannot be run under a test; the UI tour's `repeated-label` check
/// (`Tools/ui-tour/axcheck.py`) reads the same thing from the running app's tree.
struct RepeatedLabelTests {
    @Test func noRowOfTheViewLayerSaysItsLabelTwice() throws {
        let files = try SourceScan.files(under: Manifest.package.appending(path: "Sources/XDictUI"))
        #expect(files.count > 10, "the scan read too few files to hold anything: \(files.count)")
        let repeated = files.flatMap { file in Self.repeated(file.text).map { "\(file.file.lastPathComponent): \($0)" } }
        #expect(repeated == [])
    }

    /// **The control**: the Background row as it was is named; the row as it is now, and a row whose control and
    /// label say different things, are not.
    @Test func aRowSayingItsLabelTwiceIsNamed() {
        let before = """
            LabeledContent {
                Slider(value: $solidity, in: 0...1) {
                    Text("Background")
                } minimumValueLabel: {
                    Text("Glass")
                }
            } label: {
                Text("Background")
            }
            """
        #expect(Self.repeated(before) == ["Background"])
        #expect(Self.repeated("Slider(value: $solidity, in: 0...1) { Text(\"Background\") }\n") == [])
        let different = "LabeledContent { Button { add() } label: { Text(\"Add Site\") } } label: { Text(\"Never look up on\") }"
        #expect(Self.repeated(different) == [])
    }

    /// The `Text` literals a `LabeledContent` has both in its content and in its label.
    static func repeated(_ code: String) -> [String] {
        let characters = Array(code)
        var found: [String] = []
        var search = code.startIndex
        while let opening = code.range(of: "LabeledContent {", range: search..<code.endIndex) {
            let start = code.distance(from: code.startIndex, to: opening.upperBound) - 1
            guard let contentEnd = Self.closing(characters, from: start),
                  let labelStart = Self.labelOpening(characters, after: contentEnd),
                  let labelEnd = Self.closing(characters, from: labelStart) else {
                search = opening.upperBound
                continue
            }
            let content = Self.texts(String(characters[start...contentEnd]))
            let label = Self.texts(String(characters[labelStart...labelEnd]))
            found += label.filter(content.contains)
            search = opening.upperBound
        }
        return found
    }

    /// The index of the brace closing the one at `open`.
    static func closing(_ characters: [Character], from open: Int) -> Int? {
        var depth = 0
        for index in open..<characters.count {
            if characters[index] == "{" { depth += 1 }
            if characters[index] == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }

    /// The opening brace of ` label: {` right after a content block, if that is what follows it.
    static func labelOpening(_ characters: [Character], after end: Int) -> Int? {
        guard end + 1 < characters.count else { return nil }
        let rest = String(characters[(end + 1)...].prefix(40))
        guard let range = rest.range(of: #"^\s*label:\s*\{"#, options: .regularExpression) else { return nil }
        return end + 1 + rest.distance(from: rest.startIndex, to: range.upperBound) - 1
    }

    static func texts(_ code: String) -> [String] {
        code.matches(of: /Text\("([^"]+)"\)/).map { String($0.output.1) }
    }
}
