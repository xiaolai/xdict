import Foundation
import Testing
import XDictTestSupport

/// **Sentence privacy is a data-flow rule** (ADR-0014 decision 9; plan-capture WI-3): outside the capture targets, the
/// only thing that may touch a captured term's context is the one ephemeral session that holds it — so the sentence never
/// reaches search, the service, the trail or the observation hooks, which stringify into `events.jsonl`. Read off the
/// code: every file outside `XDictCapture` and `XDictCaptureMac` that imports either is searched for a context access
/// (`.context` on anything, or the context's types) — **in code and inside string interpolations**, which run as code
/// (`SourceScan.codeWithInterpolations`) — and each one found must be the session's own call, `hold(` on the line with
/// it. Positive controls below plant each shape.
struct CaptureContextFlowTests {
    static let captureModules: Set<String> = ["XDictCapture", "XDictCaptureMac"]
    static let captureSources = ["Sources/XDictCapture/", "Sources/XDictCaptureMac/"]
    /// **The one reader of a sentence outside capture, by name: the capture lab** (plan-capture WI-4). `--read-point`
    /// prints the term and its sentence for the E2E harness; it is a development instrument that never ships — no shipped
    /// target reaches it (`ModuleBoundaryTests.noShippedTargetHoldsAnInstrumentFlag`) and `Tools/build-bundle.sh` refuses
    /// an app that carries it (`Tools/tests/development-lab-test.sh`). Exempt as that folder of the package, and nothing
    /// else is: the folders here are matched from the package root, never anywhere in a path.
    static let instrumentSources = ["Sources/XDictCaptureLab/"]
    /// **The one authorized AI consumer, by name** (ADR-0021 d.11): the AI pane's hand-off, alone in one file, so the
    /// sentence may become the meaning ask's input on the reader's tap. It is a file, never a folder: the read is one
    /// initializer, and its neighbours stay under the rule.
    static let meaningSources = ["Sources/XDictUI/MeaningHandoffFromTerm.swift"]
    /// What a context access looks like in code (comments and a string's own text removed first).
    static var access: Regex<Substring> { /\.context\b|\bContextOutcome\b|\bSentenceContext\b|\bWordAtPoint\b/ }

    @Test func onlyTheSessionTouchesACapturedContextOutsideCapture() throws {
        let sources = Manifest.package.appending(path: "Sources")
        let files = try SourceScan.files(under: sources).map { (path: $0.file.path, text: $0.text) }
        let consumers = Self.consumers(files, root: Manifest.package.path)
        // The premise: the app's consumer is among them. A rule over files that import nothing of capture holds nothing.
        #expect(consumers.contains { $0.path.hasSuffix("/LookupAnywhere.swift") },
                "the scan read no consumer of capture: \(consumers.map(\.path))")
        #expect(Self.problems(consumers.map { (URL(fileURLWithPath: $0.path).lastPathComponent, $0.text) }) == [])
        // And the exemption is the lab's alone: its files do read a sentence, and are left out by folder.
        #expect(files.contains { $0.path.contains("/Sources/XDictCaptureLab/") }, "the scan read nothing of the capture lab")
    }

    /// **The control for the exemption**: the same sentence read in any other target outside capture is named — the view
    /// layer, the app, a folder whose name only starts like the lab's, and a lab folder nested anywhere but at the package
    /// root — and in the lab and the capture targets it is not.
    @Test func aSentenceReadOutsideTheLabIsStillNamed() {
        let read = "import XDictCapture\nfunc show(_ term: CapturedTerm) { print(term.context) }\n"
        let root = "/repo/apps/apple"
        let files = ["XDictUI/Leak.swift", "XDict/Leak.swift", "XDictCaptureLabKit/Leak.swift",
                     "XDictUI/Sources/XDictCaptureLab/Leak.swift", "XDictCaptureLab/Report.swift", "XDictCaptureMac/Reader.swift"]
            .map { (path: root + "/Sources/" + $0, text: read) }
        let named = Self.problems(Self.consumers(files, root: root).map {
            ($0.path.replacingOccurrences(of: root + "/Sources/", with: ""), $0.text)
        })
        #expect(named == ["XDictUI/Leak.swift:2", "XDict/Leak.swift:2", "XDictCaptureLabKit/Leak.swift:2",
                          "XDictUI/Sources/XDictCaptureLab/Leak.swift:2"])
    }

    /// **A context read inside a string interpolation is a read**: a log line in the app or the view layer that
    /// interpolates it is named; a string that only says the word is not. Red while string contents are stripped whole.
    @Test func aContextReadInsideAnInterpolationIsNamed() {
        let planted = """
            import XDictCapture
            import os
            func show(_ term: CapturedTerm) {
                Logger().debug("\\(String(describing: term.context))")
                Logger().debug("the context is gone, and term.context is only text here")
                let nested = "\\("inner \\(term.context)")"
            }
            """
        let root = "/repo/apps/apple"
        let files = ["XDict/Leak.swift", "XDictUI/Leak.swift"].map { (path: root + "/Sources/" + $0, text: planted) }
        let named = Self.problems(Self.consumers(files, root: root).map {
            ($0.path.replacingOccurrences(of: root + "/Sources/", with: ""), $0.text)
        })
        #expect(named == ["XDict/Leak.swift:4", "XDict/Leak.swift:6", "XDictUI/Leak.swift:4", "XDictUI/Leak.swift:6"])
    }

    /// The files outside capture and the lab that import capture: the ones the rule reads. The excluded folders are
    /// matched from `root`, the package, so the same names nested deeper are read like any other.
    static func consumers(_ files: [(path: String, text: String)], root: String) -> [(path: String, text: String)] {
        let base = root.hasSuffix("/") ? root : root + "/"
        return files.filter { file in
            !(captureSources + instrumentSources + meaningSources).contains { file.path.hasPrefix(base + $0) }
                && !Set(SourceScan.imports(in: file.text)).isDisjoint(with: captureModules)
        }
    }

    /// **The AI exemption is one file and one read** (ADR-0021 d.11): it exists, it imports capture, and it holds exactly
    /// one context access — so admitting it admits nothing else. A second read added there fails this guard.
    @Test func theAIConsumerIsOneFileAndOneRead() throws {
        let file = Manifest.package.appending(path: Self.meaningSources[0])
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(SourceScan.imports(in: text).contains("XDictCapture"), "the hand-off does not import capture")
        let reads = SourceScan.codeWithInterpolations(text).split(separator: "\n").filter { $0.contains(Self.access) }
        #expect(reads.count == 1, "the authorized file holds \(reads.count) context reads, wanted exactly one")
        #expect(reads.first?.contains("case .available") == true, "the one read is not the hand-off's")
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
            SourceScan.codeWithInterpolations(text).split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                .compactMap { index, line -> String? in
                    guard line.contains(access), !line.lowercased().contains("session.hold(")
                    else { return nil }
                    return "\(name):\(index + 1)"
                }
        }
    }

    // MARK: - Inside capture: what its log calls are handed

    /// **No log call inside capture is handed the text it read** (decision 9: diagnostics are metadata only). Every
    /// `Logger`, `os_log`, `NSLog` and `print` call in the capture targets is read whole — across lines, its interpolations
    /// as code — and none may name a sentence, a context, a `.text` or a `.word`, nor a local of the same function assigned
    /// from one (followed through further locals).
    ///
    /// **A static approximation, and its limit**: a "function" is the text from one `func` to the next, so a closure or
    /// a computed property shares its enclosing function's locals; only `let`/`var` assignments on one line are followed;
    /// a value passed through a parameter, a property, a collection or another function is not. It catches the direct and
    /// the one-step-removed leak, which is what a log line written in passing looks like; it is not a taint analysis.
    @Test func noCaptureLogIsHandedTheText() throws {
        var files: [(name: String, text: String)] = []
        for folder in Self.captureSources {
            files += try SourceScan.files(under: Manifest.package.appending(path: folder))
                .map { (folder + $0.file.lastPathComponent, $0.text) }
        }
        let found = Self.logFindings(files)
        #expect(found.calls >= 10, "the scan found \(found.calls) log calls")
        #expect(found.problems == [])
    }

    /// The control: each single-line spelling of a leak is named; a count, a refusal's description, a string that only
    /// says the words, and a comment are not.
    @Test func aLogLineInterpolatingTheTextIsNamed() {
        let planted = """
            log.debug("read \\(hit.word.sentence.text, privacy: .private)")
            Self.log.notice("context \\(String(describing: recognition.context))")
            print("word: \\(read.word)")
            os_log("%@", "\\(term.text)")
            log.notice("capture: \\(lines.count, privacy: .public) observations")
            log.notice("refused (\\(String(describing: error), privacy: .public))")
            log.notice("the sentence and its context were not read")
            // log.debug("\\(hit.word.sentence.text)") is a comment
            """
        let found = Self.logFindings([("Planted.swift", planted)]).problems
        #expect(found == ["Planted.swift:1", "Planted.swift:2", "Planted.swift:3", "Planted.swift:4"], "\(found)")
    }

    /// The control for the rest: a call across lines, and a context handed over through locals of the same function, are
    /// named at the call's first line; the same name in another function is not. Red while only single lines that name
    /// the text directly are read.
    @Test func aLogCallAcrossLinesOrThroughALocalIsNamed() {
        let planted = """
            func a(_ hit: Hit) {
                log.notice(
                    "read \\(hit.word.sentence.text, privacy: .private)"
                )
            }
            func b(_ term: CapturedTerm) {
                let shown = term.context
                let again = shown
                log.debug("held \\(String(describing: again), privacy: .public)")
            }
            func c(again: Int) {
                log.debug("count \\(again, privacy: .public)")
            }
            """
        #expect(Self.logFindings([("Planted.swift", planted)]).problems == ["Planted.swift:2", "Planted.swift:9"])
    }

    /// **A tuple binding is followed too** (verifier, 2026-10-19, M01 and M01c): the selection's sentence arrives as
    /// `guard let (text, range, cut) = cutToLimit(sentence, …)`, so `text` is the sentence, and so is a local taken from
    /// it. Red while only `let name =` is read.
    @Test func aLogOfATupleBoundSentenceIsNamed() {
        let planted = """
            func a(_ sentence: SentenceContext) -> ContextOutcome {
                guard let (text, range, cut) = cutToLimit(sentence, term: term) else { return .none }
                print(text)
                return .available(sentence: text, term: range, cut: cut, gap: nil)
            }
            func b(_ sentence: SentenceContext) -> ContextOutcome {
                if let (text, range, _) = cutToLimit(sentence, term: term) {
                    let shown = text
                    Self.log.notice("\\(shown, privacy: .private)")
                }
            }
            func c() {
                let (count, total) = (1, 2)
                print(count, total)
            }
            """
        #expect(Self.logFindings([("Planted.swift", planted)]).problems == ["Planted.swift:3", "Planted.swift:9"])
    }

    /// **Any logger, by any name, made inline or held** (verifier round 2, P1 and P2): a `Logger(subsystem:category:)`
    /// used where it is made, and a logger held in any property or local, are read like `log`; a count is not.
    @Test func aLogOnAnyLoggerIsNamed() {
        let planted = """
            func a(_ sentence: String, _ hit: Hit) {
                Logger(subsystem: "ai.xdict.app", category: "capture").notice("\\(sentence, privacy: .private)")
                diagnostics.debug("read \\(hit.word.sentence.text)")
                self.trail.info("\\(hit.word)")
                Self.channel.error("\\(String(describing: hit.context))")
                recorder.log(level: .debug, "\\(sentence)")
                diagnostics.debug("count \\(lines.count, privacy: .public)")
                Logger(subsystem: "ai.xdict.app", category: "capture").error("refused: \\(reason, privacy: .public)")
            }
            """
        #expect(Self.logFindings([("Planted.swift", planted)]).problems
                == ["Planted.swift:2", "Planted.swift:3", "Planted.swift:4", "Planted.swift:5", "Planted.swift:6"])
    }

    // MARK: - Inside capture: nothing it read is persisted

    /// **No capture code writes what it read anywhere that outlives the process** (decision 9: "no persistence written
    /// by the application"): every `UserDefaults`, `FileManager`, `FileHandle`, `write(`, `NSPasteboard`, `SecItem…` and Keychain
    /// call in the capture targets is read like a log call, and none may be handed a sentence, a context, a `.text` or a
    /// `.word`, or a local taken from one. The premise: the scan reads the targets' files.
    @Test func noCaptureCodePersistsTheText() throws {
        var files: [(name: String, text: String)] = []
        for folder in Self.captureSources {
            files += try SourceScan.files(under: Manifest.package.appending(path: folder))
                .map { (folder + $0.file.lastPathComponent, $0.text) }
        }
        #expect(files.count >= 20, "the scan read \(files.count) files")
        #expect(Self.findings(files, calls: Self.persistCall).problems == [])
    }

    /// The control (M02): each way of keeping it is named; a count kept, or a sentence only said in a string, is not.
    @Test func persistingTheTextIsNamed() {
        let planted = """
            func a(_ term: CapturedTerm) {
                UserDefaults.standard.set(term.context, forKey: "last")
                try? hit.word.sentence.text.write(to: url, atomically: true, encoding: .utf8)
                let kept = term.context
                FileManager.default.createFile(atPath: path, contents: Data("\\(kept)".utf8))
                NSPasteboard.general.setString(read.word, forType: .string)
                SecItemAdd([kSecValueData: Data(sentence.utf8)] as CFDictionary, nil)
                UserDefaults.standard.set(lines.count, forKey: "observations")
                print("the sentence is never written")
            }
            """
        #expect(Self.findings([("Planted.swift", planted)], calls: Self.persistCall).problems
                == ["Planted.swift:2", "Planted.swift:3", "Planted.swift:5", "Planted.swift:6", "Planted.swift:7"])
    }

    /// **A suite made inline, a file handle, a bare `write(`** (verifier round 2, P6 and P7): each kept sentence is named
    /// wherever the chain puts it; a count written is not.
    @Test func persistingThroughAChainIsNamed() {
        let planted = """
            func a(_ term: CapturedTerm, _ hit: Hit, _ sentence: String) {
                UserDefaults(suiteName: "ai.xdict.capture")?.set(term.context, forKey: "last")
                FileHandle(forWritingAtPath: path)?.write(Data(sentence.utf8))
                handle.write(Data("\\(hit.word.sentence.text)".utf8))
                stream.write(term.context)
                UserDefaults(suiteName: "ai.xdict.capture")?.set(lines.count, forKey: "observations")
                FileHandle(forWritingAtPath: path)?.write(Data("\\(lines.count)".utf8))
            }
            """
        #expect(Self.findings([("Planted.swift", planted)], calls: Self.persistCall).problems
                == ["Planted.swift:2", "Planted.swift:3", "Planted.swift:4", "Planted.swift:5"])
    }

    /// A store that outlives the process, by its type (a suite or a handle made inline included), and any `.write(`.
    /// Spelled with classes, not `\b`: Swift's word boundary is Unicode's, under which `UserDefaults.standard` is one word.
    static var persistCall: Regex<Substring> {
        /(?:^|[^A-Za-z0-9_])(?:UserDefaults|FileManager|FileHandle|NSPasteboard|SecItem|Keychain)[A-Za-z0-9_.]*\(|\.write\(/
    }

    /// A log call on any receiver — a logger under any name, made inline or held — and the free logging functions.
    static var logCall: Regex<Substring> {
        /\.(?:debug|info|notice|error|fault|warning|trace|critical|log)\(|(?:^|[^A-Za-z0-9_.])(?:print|os_log|NSLog)\(/
    }
    /// What was read, named in code: `sentence`, `context`, `.text`, `.word`. Spelled with classes, not `\b`: Swift's word
    /// boundary is Unicode's, under which `recognition.context` is one word.
    static var readName: Regex<Substring> {
        /(?:^|[^A-Za-z0-9_])(?:sentence|context)(?![A-Za-z0-9_])|\.(?:text|word)(?![A-Za-z0-9_])/
    }
    /// A one-line `let` or `var` assignment: the name — or a tuple of names, `let (text, range, cut) =` — and what it is
    /// assigned.
    static var assignment: Regex<(Substring, Substring, Substring)> {
        /(?:^|[^A-Za-z0-9_])(?:let|var)\s+(\([^)=\n]*\)|[A-Za-z_][A-Za-z0-9_]*)[^=\n]*=([^\n]*)/
    }

    /// Every log call in `files`, counted, and those handed what was read, by file and the call's first line.
    static func logFindings(_ files: [(name: String, text: String)]) -> (calls: Int, problems: [String]) {
        findings(files, calls: logCall, readsReceiver: false)
    }

    /// Every call matching `callPattern` in `files`, counted, and those handed what was read — in their arguments, or, for
    /// a store, anywhere on the statement's line: made on what was read (`text.write(to:`) or chained after the store
    /// (`UserDefaults(suiteName:)?.set(context`) — by file and the call's first line, once a line.
    static func findings(_ files: [(name: String, text: String)], calls callPattern: Regex<Substring>,
                         readsReceiver: Bool = true) -> (calls: Int, problems: [String]) {
        var calls = 0
        var problems: [String] = []
        for (name, text) in files {
            let code = SourceScan.codeWithInterpolations(text)
            let starts = code.matches(of: /\bfunc\b/).map(\.range.lowerBound)
            let bounds = [code.startIndex] + starts + [code.endIndex]
            for (from, to) in zip(bounds, bounds.dropFirst()) {
                let function = code[from..<to]
                let tainted = taintedLocals(in: function)
                for call in function.matches(of: callPattern) {
                    calls += 1
                    // The call starts after the boundary its pattern consumed (a space, or the newline of a call at the
                    // line's start), so it is counted on its own line.
                    let callStart = code[call.range].first.map { $0.isLetter || $0 == "." } == false
                        ? code.index(after: call.range.lowerBound) : call.range.lowerBound
                    let lineStart = code[..<callStart].lastIndex(of: "\n").map { code.index(after: $0) } ?? code.startIndex
                    let lineEnd = code[call.range.upperBound...].firstIndex(of: "\n") ?? code.endIndex
                    let statement = readsReceiver ? String(code[lineStart..<lineEnd]) + "\n" : ""
                    let arguments = statement + balanced(code, from: call.range.upperBound)
                    let names = Set(arguments.matches(of: /[A-Za-z_][A-Za-z0-9_]*/).map { String($0.output) })
                    guard arguments.contains(readName) || !names.isDisjoint(with: tainted) else { continue }
                    let line = code[code.startIndex..<callStart].filter { $0 == "\n" }.count + 1
                    if problems.last != "\(name):\(line)" { problems.append("\(name):\(line)") }
                }
            }
        }
        return (calls, problems)
    }

    /// The locals of `function` assigned from what was read, or from such a local, to a fixed point.
    static func taintedLocals(in function: Substring) -> Set<String> {
        let assigned = function.matches(of: assignment).map { match in
            (names: Set(match.output.1.matches(of: /[A-Za-z_][A-Za-z0-9_]*/).map { String($0.output) }), value: match.output.2)
        }
        var tainted: Set<String> = []
        var grew = true
        while grew {
            grew = false
            for (bound, value) in assigned where !bound.isSubset(of: tainted) {
                let names = Set(value.matches(of: /[A-Za-z_][A-Za-z0-9_]*/).map { String($0.output) })
                if value.contains(readName) || !names.isDisjoint(with: tainted) {
                    tainted.formUnion(bound)
                    grew = true
                }
            }
        }
        tainted.remove("_")
        return tainted
    }

    /// The text of a call's arguments: from just after its `(` to the `)` that closes it, across lines.
    static func balanced(_ code: String, from start: String.Index) -> Substring {
        var depth = 1
        var index = start
        while index < code.endIndex {
            if code[index] == "(" { depth += 1 }
            if code[index] == ")" {
                depth -= 1
                if depth == 0 { break }
            }
            index = code.index(after: index)
        }
        return code[start..<index]
    }
}
