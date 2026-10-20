import Foundation
import Testing
import XDictTestSupport

/// **The selection path reads with the reader's own exclusions** (plan-capture follow-ups, 2026-10-19): every selection
/// read hands over the hover policy the reader edits (`hover.policy`, or a local taken from it), never a policy made on
/// the spot — a `.shipped` there would read the sentence on every site the reader excluded. The app reads through one
/// seam (`selectionRead`, the cancellation seam of the capture-contract audit, WI-0), so the rule has two halves: every
/// seam call passes the reader's policy, and the one production read forwards the policy it was handed. Read off the
/// code, since the app target runs no test; positive controls plant each mistake.
struct SelectionExclusionWiringTests {
    static let source = "Sources/XDict/LookupAnywhere.swift"

    @Test func everySelectionReadHandsOverTheReadersPolicy() throws {
        let text = try String(contentsOf: Manifest.package.appending(path: Self.source), encoding: .utf8)
        // The premise: the scan sees the seam and its call sites (the shortcut's read and the Service's two paths).
        #expect(Self.productionReads(text) == 1, "the scan read \(Self.productionReads(text)) production reads")
        #expect(Self.seamCalls(text) >= 2, "the scan read \(Self.seamCalls(text)) seam calls")
        #expect(Self.problems(text) == [])
    }

    @Test func aReadWithoutTheReadersPolicyIsNamed() {
        let good = """
            let exclusions = hover.policy
            let a = await selectionRead(front, nil, exclusions)
            let b = await selectionRead(reader, point, self.hover.policy)
            return await SelectionReader.read(from: reader, clicked: clicked, excluding: excluding, ownHolder: holder)
            """
        #expect(Self.problems(good) == [])
        #expect(Self.problems("let a = await selectionRead(front, nil, .shipped)\n") == ["1"])
        #expect(Self.problems("let p = HoverPolicy.shipped\nlet a = await selectionRead(f, nil, p)\n")
                == ["2"], "a local not taken from the reader's policy")
        #expect(Self.problems("let a = await SelectionReader.read(from: f, excluding: .shipped)\n") == ["1"],
                "the production read forwards a policy of its own")
    }

    static func productionReads(_ text: String) -> Int {
        SourceScan.codeOnly(text).matches(of: /SelectionReader\.read\(/).count
    }

    /// The seam's call sites: not its declaration and not the capture into a local.
    static func seamCalls(_ text: String) -> Int {
        SourceScan.codeOnly(text).split(separator: "\n").filter {
            $0.contains("selectionRead(") && !$0.contains("var selectionRead") && !$0.contains("= selectionRead")
        }.count
    }

    /// The lines whose read hands over anything but the reader's policy: a seam call whose policy argument is not
    /// `hover.policy` (or a local from it), or the production read not forwarding the seam's `excluding`.
    static func problems(_ text: String) -> [String] {
        let code = SourceScan.codeOnly(text)
        let fromPolicy = Set(code.matches(of: /\blet\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:self\.)?hover\.policy\b/)
            .map { String($0.output.1) })
        return code.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, line in
            if line.contains("SelectionReader.read(") {
                return line.contains("excluding: excluding") ? nil : "\(index + 1)"
            }
            guard line.contains("selectionRead("), !line.contains("var selectionRead"), !line.contains("= selectionRead")
            else { return nil }
            if line.contains("hover.policy)") || fromPolicy.contains(where: { line.contains("\($0))") }) { return nil }
            return "\(index + 1)"
        }
    }
}
