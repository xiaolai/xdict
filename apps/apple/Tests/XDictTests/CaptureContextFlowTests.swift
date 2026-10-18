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
    /// **The one reader of a sentence outside capture, by name: the capture lab** (plan-capture WI-4). `--read-point`
    /// prints the term and its sentence for the E2E harness; it is a development instrument that never ships — no shipped
    /// target reaches it (`ModuleBoundaryTests.noShippedTargetHoldsAnInstrumentFlag`) and `Tools/build-bundle.sh` refuses
    /// an app that carries it (`Tools/tests/development-lab-test.sh`). Exempt as a folder, and nothing else is.
    static let instrumentSources = ["Sources/XDictCaptureLab/"]
    /// What a context access looks like in code (comments and strings removed first).
    static var access: Regex<Substring> { /\.context\b|\bContextOutcome\b|\bSentenceContext\b|\bWordAtPoint\b/ }

    @Test func onlyTheSessionTouchesACapturedContextOutsideCapture() throws {
        let sources = Manifest.package.appending(path: "Sources")
        let files = try SourceScan.files(under: sources).map { (path: $0.file.path, text: $0.text) }
        let consumers = Self.consumers(files)
        // The premise: the app's consumer is among them. A rule over files that import nothing of capture holds nothing.
        #expect(consumers.contains { $0.path.hasSuffix("/LookupAnywhere.swift") },
                "the scan read no consumer of capture: \(consumers.map(\.path))")
        #expect(Self.problems(consumers.map { (URL(fileURLWithPath: $0.path).lastPathComponent, $0.text) }) == [])
        // And the exemption is the lab's alone: its files do read a sentence, and are left out by folder.
        #expect(files.contains { $0.path.contains("/Sources/XDictCaptureLab/") }, "the scan read nothing of the capture lab")
    }

    /// **The control for the exemption**: the same sentence read in any other target outside capture is named — the view
    /// layer, the app, a folder whose name only starts like the lab's — and in the lab it is not.
    @Test func aSentenceReadOutsideTheLabIsStillNamed() {
        let read = "import XDictCapture\nfunc show(_ term: CapturedTerm) { print(term.context) }\n"
        let files = ["XDictUI/Leak.swift", "XDict/Leak.swift", "XDictCaptureLabKit/Leak.swift", "XDictCaptureLab/Report.swift",
                     "XDictCaptureMac/Reader.swift"].map { (path: "/repo/apps/apple/Sources/" + $0, text: read) }
        let named = Self.problems(Self.consumers(files).map {
            ($0.path.replacingOccurrences(of: "/repo/apps/apple/Sources/", with: ""), $0.text)
        })
        #expect(named == ["XDictUI/Leak.swift:2", "XDict/Leak.swift:2", "XDictCaptureLabKit/Leak.swift:2"])
    }

    /// The files outside capture and the lab that import capture: the ones the rule reads.
    static func consumers(_ files: [(path: String, text: String)]) -> [(path: String, text: String)] {
        files.filter { file in
            !(captureSources + instrumentSources).contains { file.path.contains("/" + $0) }
                && !Set(SourceScan.imports(in: file.text)).isDisjoint(with: captureModules)
        }
    }

    // MARK: - Inside capture: what its log lines interpolate

    /// **No log line inside capture interpolates the text it read** (decision 9: diagnostics are metadata only). Every
    /// `Logger`, `os_log`, `NSLog` and `print` call in the capture targets is read, strings included, and none may
    /// interpolate a sentence, a context, a word or a text. The premise: the scan found the targets' log calls.
    @Test func noCaptureLogInterpolatesTheText() throws {
        var calls: [(name: String, text: String)] = []
        for folder in Self.captureSources {
            calls += try SourceScan.files(under: Manifest.package.appending(path: folder))
                .map { (folder + $0.file.lastPathComponent, $0.text) }
        }
        #expect(Self.logCalls(calls).count >= 10, "the scan found \(Self.logCalls(calls).count) log calls")
        #expect(Self.logProblems(calls) == [])
    }

    /// The control: each spelling of a leak is named; a count, a refusal's description and a comment are not.
    @Test func aLogLineInterpolatingTheTextIsNamed() {
        let planted = """
            log.debug("read \\(hit.word.sentence.text, privacy: .private)")
            Self.log.notice("context \\(String(describing: recognition.context))")
            print("word: \\(read.word)")
            os_log("%@", "\\(term.text)")
            log.notice("capture: \\(lines.count, privacy: .public) observations")
            log.notice("refused (\\(String(describing: error), privacy: .public))")
            // log.debug("\\(hit.word.sentence.text)") is a comment
            """
        #expect(Self.logProblems([("Planted.swift", planted)])
                == ["Planted.swift:1", "Planted.swift:2", "Planted.swift:3", "Planted.swift:4"])
    }

    static var logCall: Regex<Substring> {
        /\b(?:log|logger|Self\.log)\.(?:debug|info|notice|error|fault|warning|trace|critical)\(|\bprint\(|\bos_log\(|\bNSLog\(/
    }
    /// An interpolation naming what was read: `sentence`, `context`, `.text`, `.word`. Spelled with classes, not `\b`:
    /// Swift's word boundary is Unicode's, under which `recognition.context` is one word.
    static var readText: Regex<Substring> {
        /\\\([^)]*(?:[^A-Za-z0-9_](?:sentence|context)|\.(?:text|word))(?![A-Za-z0-9_])/
    }

    static func logCalls(_ files: [(name: String, text: String)]) -> [String] {
        files.flatMap { name, text in
            text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, line in
                let code = line.drop { $0 == " " }
                return !code.hasPrefix("//") && line.contains(logCall) ? "\(name):\(index + 1)" : nil
            }
        }
    }

    static func logProblems(_ files: [(name: String, text: String)]) -> [String] {
        files.flatMap { name, text in
            text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, line in
                let code = line.drop { $0 == " " }
                return !code.hasPrefix("//") && line.contains(logCall) && line.contains(readText) ? "\(name):\(index + 1)" : nil
            }
        }
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
