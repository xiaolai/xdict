import Foundation
import Testing
@testable import XDictAppleImport
import XDictTestSupport

/// **A conversion stops where it is asked to** (ADR-0011 decision 5): the converter asks its checkpoint before every
/// section of `Body.data` it inflates and before every output block it builds, and a `false` stops it there as
/// `cancelled`, leaving nothing in the output folder. What it wrote is counted in its summary.
struct CheckpointTests {
    static func big(_ n: Int, from first: Int = 0) -> [SyntheticAppleBundle.Entry] {
        (first..<(first + n)).map { ("e\($0)", "word\($0)", "<p>" + String(repeating: "text\($0) ", count: 8000) + "</p>", []) }
    }

    /// Converts `bundle`, the checkpoint answering `answer` and recording every step it was asked.
    static func run(_ bundle: URL, into out: URL, answer: @escaping (ConversionStep) -> Bool)
        -> (steps: [ConversionStep], result: Result<ConversionSummary, AppleImportError>) {
        var steps: [ConversionStep] = []
        let result: Result<ConversionSummary, AppleImportError>
        do {
            result = .success(try convert(snapshot: bundle, into: out, name: "T", checkpoint: { step in
                steps.append(step)
                return answer(step)
            }))
        } catch {
            result = .failure(error)
        }
        return (steps, result)
    }

    @Test func everyBodySectionAndEveryOutputBlockIsAStep() throws {
        let root = try SyntheticAppleBundle.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try SyntheticAppleBundle.make(in: root, sections: [Self.big(2), Self.big(2, from: 2)])
        let (steps, result) = Self.run(bundle, into: root.appending(path: "out")) { _ in true }
        #expect(throws: Never.self) { try result.get() }
        let reading = steps.filter { $0.phase == .reading }
        #expect(reading.count == 2, "one step before each of the two sections: \(reading)")
        #expect(reading.map(\.done) == reading.map(\.done).sorted() && reading.first?.done == 0)
        #expect(reading.allSatisfy { $0.done < $0.total }, "\(reading)")
        let writing = steps.filter { $0.phase == .writing }
        #expect(writing.count >= 3, "several MDX record blocks and the MDD's: \(writing)")
        #expect(writing.allSatisfy { $0.done <= $0.total && $0.total == 5 }, "4 articles and the stylesheet: \(writing)")
    }

    @Test func cancelledBetweenBodySectionsItStopsAndLeavesNothing() throws {
        let root = try SyntheticAppleBundle.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try SyntheticAppleBundle.make(in: root, sections: [Self.big(1), Self.big(1, from: 1), Self.big(1, from: 2)])
        let out = root.appending(path: "out")
        let (steps, result) = Self.run(bundle, into: out) { !($0.phase == .reading && $0.done > 0) }
        #expect(throws: AppleImportError.cancelled) { try result.get() }
        #expect(steps.count == 2, "asked before the first section and refused before the second: \(steps)")
        #expect((try? FileManager.default.contentsOfDirectory(atPath: out.path))?.isEmpty ?? true)
    }

    @Test func cancelledBetweenOutputBlocksItStopsAndLeavesNothing() throws {
        let root = try SyntheticAppleBundle.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try SyntheticAppleBundle.make(in: root, entries: Self.big(4))
        let out = root.appending(path: "out")
        let (steps, result) = Self.run(bundle, into: out) { !($0.phase == .writing && $0.done > 0) }
        #expect(throws: AppleImportError.cancelled) { try result.get() }
        #expect(steps.last?.phase == .writing && steps.filter { $0.phase == .writing }.count == 2, "\(steps)")
        #expect((try? FileManager.default.contentsOfDirectory(atPath: out.path))?.isEmpty ?? true, "nothing published")
    }

    @Test func theSummaryCountsWhatWasWritten() throws {
        let root = try SyntheticAppleBundle.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try SyntheticAppleBundle.make(in: root)
        let summary = try convert(snapshot: bundle, into: root.appending(path: "out"), name: "T")
        #expect(summary == ConversionSummary(entries: 2, redirects: 1, resources: 1, files: ["T.mdx", "T.mdd"]))
    }
}
