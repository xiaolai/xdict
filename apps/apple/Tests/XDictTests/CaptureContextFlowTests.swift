import Foundation
import Testing
import XDictTestSupport

/// **Sentence privacy is a data-flow rule** (ADR-0014 decision 9; plan-capture WI-3): outside the capture targets, the
/// only thing that may touch a captured term's context is the one ephemeral session that holds it — so the sentence never
/// reaches search, the service, the trail or the observation hooks, which stringify into `events.jsonl`. Read off the
/// code: every file outside `XDictCapture` and `XDictCaptureMac` that imports either is searched for a context access
/// (`.context` on anything, or the context's types), and each one found must be the session's own call, `hold(` on the
/// line with it. A positive control below plants each shape in a scratch file.
struct CaptureContextFlowTests {
    static let captureModules: Set<String> = ["XDictCapture", "XDictCaptureMac"]
    static let captureSources = ["Sources/XDictCapture/", "Sources/XDictCaptureMac/"]
    /// What a context access looks like in code (comments and strings removed first).
    static var access: Regex<Substring> { /\.context\b|\bContextOutcome\b|\bSentenceContext\b|\bWordAtPoint\b/ }

    @Test func onlyTheSessionTouchesACapturedContextOutsideCapture() throws {
        let sources = Manifest.package.appending(path: "Sources")
        let files = try SourceScan.files(under: sources).filter { file, _ in
            !Self.captureSources.contains { file.path.contains("/" + $0) }
        }
        let consumers = files.filter { !Set(SourceScan.imports(in: $0.text)).isDisjoint(with: Self.captureModules) }
        // The premise: the app's consumer is among them. A rule over files that import nothing of capture holds nothing.
        #expect(consumers.contains { $0.file.lastPathComponent == "LookupAnywhere.swift" },
                "the scan read no consumer of capture: \(consumers.map(\.file.lastPathComponent))")
        #expect(Self.problems(consumers.map { ($0.file.lastPathComponent, $0.text) }) == [])
    }

    /// **The control**: each shape of access is named, and the session's own call is not.
    @Test func aContextReadOutsideTheSessionIsNamed() throws {
        let scratch = try TemporaryDirectory(named: "xdict-planted-context")
        let planted = """
            import XDictCapture
            func leak(_ delivery: CaptureDelivery, _ log: (String) -> Void) {
                log(String(describing: delivery.term.context))
                let outcome: ContextOutcome = delivery.term.context
                session.hold(delivery.term.context, request: 1, generation: 1)
                // delivery.term.context in a comment is not code
            }
            """
        try planted.write(to: scratch.appending("Planted.swift"), atomically: true, encoding: .utf8)
        let files = try SourceScan.files(under: scratch.url).map { ($0.file.lastPathComponent, $0.text) }
        #expect(Self.problems(files) == ["Planted.swift:3", "Planted.swift:4"])
    }

    static func problems(_ files: [(name: String, text: String)]) -> [String] {
        files.flatMap { name, text in
            SourceScan.codeOnly(text).split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                .compactMap { index, line -> String? in
                    guard line.contains(access), !line.lowercased().contains("session.hold(")
                    else { return nil }
                    return "\(name):\(index + 1)"
                }
        }
    }
}
