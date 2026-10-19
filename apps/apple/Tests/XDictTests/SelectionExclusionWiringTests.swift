import Foundation
import Testing
import XDictTestSupport

/// **The selection path reads with the reader's own exclusions** (plan-capture follow-ups, 2026-10-19): every
/// `SelectionReader.read(` in the app hands over the hover policy the reader edits (`hover.policy`, or a local taken from
/// it), never a policy made on the spot — a `.shipped` there would read the sentence on every site the reader excluded.
/// Read off the code, since the app target cannot run under a test; positive controls plant each mistake.
struct SelectionExclusionWiringTests {
    @Test func everySelectionReadHandsOverTheReadersPolicy() throws {
        let app = Manifest.package.appending(path: "Sources/XDict/LookupAnywhere.swift")
        let text = try String(contentsOf: app, encoding: .utf8)
        // The premise: both reads of today are seen (the shortcut's and the menu's, and the Service's).
        #expect(Self.reads(text) >= 2, "the scan read \(Self.reads(text)) selection reads")
        #expect(Self.problems(text) == [])
    }

    @Test func aReadWithoutTheReadersPolicyIsNamed() {
        let good = """
            let exclusions = hover.policy
            let a = await SelectionReader.read(from: front, excluding: exclusions)
            let b = await SelectionReader.read(from: reader, clicked: point, excluding: self.hover.policy)
            """
        #expect(Self.problems(good) == [])
        #expect(Self.problems("let a = await SelectionReader.read(from: front, excluding: .shipped)\n") == ["1"])
        #expect(Self.problems("let a = await SelectionReader.read(from: front, excluding: HoverPolicy.shipped)\n") == ["1"])
        #expect(Self.problems("let p = HoverPolicy.shipped\nlet a = await SelectionReader.read(from: f, excluding: p)\n")
                == ["2"], "a local not taken from the reader's policy")
    }

    static func reads(_ text: String) -> Int {
        SourceScan.codeOnly(text).matches(of: /SelectionReader\.read\(/).count
    }

    /// The lines whose selection read hands over anything but `hover.policy` or a local assigned from it.
    static func problems(_ text: String) -> [String] {
        let code = SourceScan.codeOnly(text)
        let fromPolicy = Set(code.matches(of: /\blet\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:self\.)?hover\.policy\b/)
            .map { String($0.output.1) })
        return code.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, line in
            guard line.contains("SelectionReader.read(") else { return nil }
            guard let handed = line.firstMatch(of: /excluding:\s*([A-Za-z_][A-Za-z0-9_.]*)/)?.output.1 else {
                return "\(index + 1)"
            }
            let value = handed.hasPrefix("self.") ? String(handed.dropFirst(5)) : String(handed)
            return value == "hover.policy" || fromPolicy.contains(value) ? nil : "\(index + 1)"
        }
    }
}
