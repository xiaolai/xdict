import Foundation
import FoundationModels
import XDictAI
import XDictCore

/// **The AI prompt harness** (plan-ai-meaning WI-0): what one whole entry turns into, how many bytes and tokens the question
/// carries, where the budget cuts it, and — with `--apple` — how long Apple's on-device model takes to a validated
/// complete answer. It reads the reader's dictionaries locally through the core; the output holds sizes, counts and
/// timings, never a headword nor a word of an entry.
///
///   XDictAIMeasure --self-test
///   XDictAIMeasure --corpus <dir> [--out <json>] [--keys 200] [--apple] [--asks 3]
///
/// The entry budget and the question ceiling are the app's own (`MeaningBudget.entryTextBytes`, `AIComposer.questionCeilingUTF8`).
enum HarnessError: Error { case duplicateAsk(String) }

enum Harness {
    /// The app's entry budget for one ask (`MeaningBudget.entryTextBytes`).
    static let entryBudget: UInt64 = 256 << 10
    /// A body this large is read whole; the text budget is what cuts.
    static let bodyBudget: UInt64 = 8 << 20

    static func value(_ flag: String, _ arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static func question(text: String, complete: Bool, cutAt: UInt64, edition: String, key: String,
                         occurrence: UInt32, mode: AIMode = .grounded, sentence: String? = nil,
                         range: NSRange? = nil) -> AIQuestion {
        let spoken = sentence ?? "They \(key) the old way."
        let termRange = range.map { AITermRange.range(start: $0.location, length: $0.length) }
            ?? .range(start: 5, length: key.utf16.count)
        let entry = AIEntryText(text: text, complete: complete, cutAt: cutAt,
                                ref: AIEntryRef(edition: edition, key: key, occurrence: occurrence))
        return AIQuestion(term: key, termRange: termRange, sentence: spoken,
                          entry: mode == .grounded ? entry : nil, language: "en", mode: mode)
    }

    static func composed(_ question: AIQuestion) throws(AIComposeError) -> String {
        let template = AITemplates.defaultTemplate(language: "en", mode: question.mode) ?? ""
        return try AIComposer.compose(template: template, question: question)
    }

    static func entry(text: String, cutAt: UInt64 = 0, complete: Bool = true) -> EntryText {
        EntryText(entry: EntryRef(edition: "synthetic", key: "hold", occurrence: 0), text: text,
                  spans: [], complete: complete, omittedBytes: 0, cutAt: cutAt, spansDropped: 0)
    }

    // MARK: - Self-test

    static func selfTest() throws {
        let small = String(repeating: "hold. To keep; to have. ", count: 40)
        let probe = question(text: small, complete: true, cutAt: 0, edition: "synthetic", key: "hold",
                             occurrence: 0)
        let whole = try composed(probe)
        precondition(whole.contains(small), "the whole entry's text must be in the question")
        precondition(whole.contains("«hold»"), "the term must be marked in its sentence")
        precondition(whole.hasSuffix(AIComposer.responseContract), "the response contract must close every question")
        precondition(whole.utf8.count <= AIComposer.questionCeilingUTF8, "the small entry must fit")

        let sentenceOnly = try composed(question(text: small, complete: true, cutAt: 0, edition: "synthetic",
                                                 key: "hold", occurrence: 0, mode: .sentenceOnly))
        precondition(!sentenceOnly.contains(small), "a sentence-only question carries no entry")

        // The budget's cut is data: the question says incomplete, and the composer never repairs it.
        let cut = entry(text: String(small.prefix(200)), cutAt: 200, complete: false)
        let cutComposed = try composed(question(text: cut.text, complete: cut.complete, cutAt: cut.cutAt,
                                                edition: "synthetic", key: "hold", occurrence: 0))
        precondition(cutComposed.contains(cut.text), "the part before the cut is sent")

        // An over-long template and an unknown placeholder refuse before anything is sent.
        do {
            _ = try AIComposer.compose(template: "{term} {nope}", question: probe)
            preconditionFailure("an unknown placeholder must refuse")
        } catch {
            precondition(error == .unknownPlaceholder("nope"), "refused as the wrong reason: \(error)")
        }
        let overLong = String(repeating: "{term} ", count: 2_000) + "{sentence} {entry}"
        do {
            _ = try AIComposer.compose(template: overLong, question: probe)
            preconditionFailure("an over-long template must refuse")
        } catch {
            precondition(error == .templateTooLong, "refused as the wrong reason: \(error)")
        }
        print("self-test ok")
    }

    // MARK: - The corpus

    struct Sample {
        let key: String
        let textBytes: Int
        let complete: Bool
        let cutAt: UInt64
        let composedBytes: Int
        let tokens: Int?
        let question: AIQuestion
        let composed: String
        let sentenceSource: String
    }

    struct Ask: Encodable {
        let source: String
        let entryBytes: Int
        let composedBytes: Int
        let tokens: Int?
        let seconds: Double
        let outcome: String
        let validated: Bool
        let error: String?
        let sentence: String
    }

    struct DictionaryReport: Encodable {
        let file: String
        let title: String
        let formatVersion: String
        let keys: UInt64
        let keysSampled: Int
        let textBytesMin: Int
        let textBytesMedian: Int
        let textBytesMax: Int
        let composedBytesMin: Int
        let composedBytesMedian: Int
        let composedBytesMax: Int
        let largestComplete: Bool
        let largestCutAt: UInt64
        let largestTokens: Int?
        let asks: [Ask]
    }

    /// A dictionary's folder as a package: its MDX and its own MDD volumes, in order, and no sidecars — `entry_text`
    /// reads the entry's text only, and in a flat folder a loose stylesheet must not attach to an unrelated dictionary.
    static func package(for file: URL) -> Package {
        let folder = file.deletingLastPathComponent()
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let ext = { (url: URL) in url.pathExtension.lowercased() }
        func volume(_ url: URL) -> Int {
            let stem = url.deletingPathExtension().lastPathComponent
            guard let dot = stem.lastIndex(of: "."), let n = Int(stem[stem.index(after: dot)...]) else { return 0 }
            return n + 1
        }
        // Only this dictionary's own volumes: in a flat folder, an unrelated .mdd must not join the package.
        let stem = file.deletingPathExtension().lastPathComponent
        let mdd = files.filter { url in
            guard ext(url) == "mdd" else { return false }
            let name = url.deletingPathExtension().lastPathComponent
            if name == stem { return true }
            guard name.hasPrefix(stem + ".") else { return false }
            // `X.mdd` or `X.<digits>.mdd`; `X.other.mdd` belongs to another dictionary, and an empty suffix
            // (`X..mdd`, the exact-stem volume of `X..mdx`) belongs to neither this dictionary nor a numbered volume.
            let suffix = name.dropFirst(stem.count + 1)
            return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
        }.sorted { volume($0) < volume($1) }
        // `entry_text` reads the entry's text only: stylesheets and other sidecars cannot affect it, and a loose CSS in
        // a flat folder must not attach to an unrelated dictionary.
        return Package(mdx: .path(path: file.path), mdd: mdd.map { .path(path: $0.path) }, sidecars: [])
    }

    /// **A sentence from the entry itself that uses the headword** — the way a reader would meet the word. Nil when the
    /// entry has none (a headword list, a table), and the caller falls back to a synthetic sentence and says so.
    static func entrySentence(_ text: String, key: String) -> (sentence: String, range: NSRange)? {
        let characters = Array(text)
        var start = 0
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "." || character == "!" || character == "?" || character == "\n" {
                let end = index + 1
                let sentence = String(characters[start..<min(end, characters.count)])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if sentence.count >= 20, sentence.count <= 300,
                   let found = sentence.range(of: key, options: [.caseInsensitive, .diacriticInsensitive]) {
                    let boundary = (found.lowerBound == sentence.startIndex
                                    || !sentence[sentence.index(before: found.lowerBound)].isLetter)
                        && (found.upperBound == sentence.endIndex || !sentence[found.upperBound].isLetter)
                    if boundary {
                        let location = sentence[..<found.lowerBound].utf16.count
                        return (sentence, NSRange(location: location, length: key.utf16.count))
                    }
                }
                start = end
            }
            index += 1
        }
        return nil
    }

    enum Source: String { case apple, claude, codex }

    struct AskRecord: Decodable {
        let id: String
        let dictionary: String
        let entryBytes: Int
        let composedBytes: Int
        let sentence: String
        let composed: String
        let entry: String?
        let complete: Bool?
        let cutAt: UInt64?
        let edition: String?
        let key: String?
        let occurrence: UInt32?
    }

    struct AskFile: Decodable { let asks: [AskRecord] }

    struct AnswerRecord: Decodable {
        let id: String
        let raw: String
        let seconds: Double
    }

    struct AnswerFile: Decodable { let answers: [AnswerRecord] }

    /// **Check answers a CLI produced elsewhere** (the Air may be the only Mac signed in to a source): the ask file says
    /// what was sent; each answer is validated against that exact entry, as the app would.
    static func validate(asks askPath: URL, answers answerPath: URL, out: URL, source: String) throws {
        let asks = try JSONDecoder().decode(AskFile.self, from: Data(contentsOf: askPath))
        let answers = try JSONDecoder().decode(AnswerFile.self, from: Data(contentsOf: answerPath))
        var byID: [String: AskRecord] = [:]
        for ask in asks.asks {
            guard byID.updateValue(ask, forKey: ask.id) == nil else {
                throw HarnessError.duplicateAsk(ask.id)
            }
        }
        var rows: [[String: Any]] = []
        for answer in answers.answers {
            guard let ask = byID[answer.id] else { continue }
            let entry = ask.entry.map {
                AIEntryText(text: $0, complete: ask.complete ?? true, cutAt: ask.cutAt ?? 0,
                            ref: AIEntryRef(edition: ask.edition ?? "", key: ask.key ?? "", occurrence: ask.occurrence ?? 0))
            }
            var row: [String: Any] = ["source": source, "id": answer.id, "dictionary": ask.dictionary,
                                      "entryBytes": ask.entryBytes, "composedBytes": ask.composedBytes,
                                      "sentence": ask.sentence, "seconds": answer.seconds]
            do {
                let validated = try AIAnswerValidator.validate(json: Data(answer.raw.utf8), mode: .grounded, entry: entry)
                row["outcome"] = validated.outcome.rawValue
                row["validated"] = true
            } catch {
                row["outcome"] = "answer.invalid"
                row["validated"] = false
                row["error"] = error.code
            }
            rows.append(row)
        }
        let data = try JSONSerialization.data(withJSONObject: ["source": source, "asks": rows],
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: out)
        let passed = rows.filter { $0["validated"] as? Bool == true }.count
        print("validated \(passed) of \(rows.count); wrote \(out.path)")
    }

    static func run(corpus: URL, out: URL, keyLimit: Int, source: Source?, asks: Int, claudeHome: URL?,
                    codexHome: URL?, only: String?, emit: URL?) async throws {
        let model = SystemLanguageModel.default
        var appleAvailable = false
        var contextSize = 0
        if case .available = model.availability {
            appleAvailable = true
            contextSize = model.contextSize
        }
        // A provider for the source this run measures; nil when none was named (sizes only).
        let work = FileManager.default.temporaryDirectory.appending(path: "xdict-ai-measure-work-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        var provider: (any AIProvider)?
        switch source {
        case .apple?:
            provider = AppleOnDeviceProvider()
        case .claude?:
            provider = ClaudeCLIProvider(configuration: .init(
                executable: nil, configDirectory: claudeHome ?? URL(fileURLWithPath: NSHomeDirectory() + "/.claude"),
                workingDirectory: work, model: nil, timeout: .seconds(240),
                searchPath: ProcessInfo.processInfo.environment["PATH"]))
        case .codex?:
            provider = try CodexCLIProvider(configuration: .init(
                executable: nil, codexHome: codexHome ?? URL(fileURLWithPath: NSHomeDirectory() + "/.codex"),
                workingDirectory: work, model: nil, timeout: .seconds(300)))
        case nil:
            provider = nil
        }

        // The corpus is either flat or one folder per dictionary (the 24 are); both layouts are read.
        var files: [URL] = []
        for item in (try? FileManager.default.contentsOfDirectory(at: corpus, includingPropertiesForKeys: [.isDirectoryKey]))
            ?? [] {
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                let inside = (try? FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? []
                files += inside.filter { $0.pathExtension.lowercased() == "mdx" }
            } else if item.pathExtension.lowercased() == "mdx" {
                files.append(item)
            }
        }
        files.sort { $0.lastPathComponent < $1.lastPathComponent }
        var reports: [DictionaryReport] = []
        var emitted: [[String: Any]] = []

        // A cache that outlives the run keeps the second run fast; the registry and indexes are the core's own.
        let cacheRoot = Harness.value("--cache", arguments).map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appending(path: "xdict-ai-measure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let scratch = cacheRoot
        try FileManager.default.createDirectory(at: scratch.appending(path: "data"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch.appending(path: "cache"), withIntermediateDirectories: true)
        let explicitCache = Harness.value("--cache", arguments) != nil
        defer { if !explicitCache { try? FileManager.default.removeItem(at: scratch) } }
        var entropy = SystemRandomNumberGenerator()
        let core = try Core(config: Config(dataDir: scratch.appending(path: "data").path,
                                           cacheDir: scratch.appending(path: "cache").path,
                                           clientProtocol: versions().protocol,
                                           entropy: Data((0..<32).map { _ in UInt8.random(in: .min ... .max,
                                                                                         using: &entropy) })))

        for file in files {
            if let only, !file.lastPathComponent.localizedCaseInsensitiveContains(only) { continue }
            let package = Self.package(for: file)
            var opened = try core.open(package: package)
            if case .needsImport = opened {
                // The reader's first open imports; the measurement does the same, into its own cache.
                _ = try core.import(package: package, progress: nil)
                opened = try core.open(package: package)
            }
            guard case .ready(let dict, let edition, let info) = opened else {
                print("skip \(file.lastPathComponent): did not open (\(opened))")
                continue
            }
            var keys = Set<String>()
            for prefix in (Array("abcdefghijklmnopqrstuvwxyz") + Array("0123456789")).map(String.init) {
                if let found = try? core.suggest(prefix: prefix, dicts: [dict], limit: 20) {
                    keys.formUnion(found)
                }
                if keys.count >= keyLimit { break }
            }
            var samples: [Sample] = []
            for key in keys.sorted().prefix(keyLimit) {
                guard let page = try? core.lookup(query: key, dicts: [dict],
                                                  options: LookupOptions(limit: 1, offset: 0, mode: .reader,
                                                                         generation: nil)),
                      let hit = page.hits.first,
                      let text = try? core.entryText(dict: hit.dict, entry: hit.entry,
                                                     view: TextView(baseUrl: "", maxBodyBytes: bodyBudget,
                                                                    maxTextBytes: entryBudget)) else { continue }
                let fromEntry = entrySentence(text.text, key: key)
                let question = question(text: text.text, complete: text.complete, cutAt: text.cutAt, edition: edition,
                                        key: key, occurrence: hit.entry.occurrence,
                                        sentence: fromEntry?.sentence, range: fromEntry?.range)
                guard let composed = try? composed(question) else { continue }
                var tokens: Int?
                if appleAvailable {
                    tokens = try? await model.tokenCount(for: composed)
                }
                samples.append(Sample(key: key, textBytes: text.text.utf8.count,
                                      complete: text.complete, cutAt: text.cutAt, composedBytes: composed.utf8.count,
                                      tokens: tokens, question: question, composed: composed,
                                      sentenceSource: fromEntry == nil ? "synthetic" : "entry"))
            }
            guard !samples.isEmpty else {
                print("skip \(file.lastPathComponent): no entry text")
                try? core.close(dict: dict)
                continue
            }
            let byText = samples.map(\.textBytes).sorted()
            let byComposed = samples.map(\.composedBytes).sorted()
            let largest = samples.max { $0.textBytes < $1.textBytes } ?? samples[0]

            let chosen = [largest] + samples.sorted { $0.textBytes < $1.textBytes }
                .dropFirst(max(0, samples.count / 2 - 1)).prefix(max(0, asks - 1))
            if emit != nil {
                // **The exact asks, for a CLI run on the Mac where the reader is signed in** (the harness itself runs on
                // the build host, whose CLI may not be). The file holds entry text; it is written outside the repository
                // and removed after the run.
                for (index, sample) in chosen.prefix(asks).enumerated() {
                    emitted.append([
                        "id": "\(file.path)#\(index)",
                        "dictionary": file.lastPathComponent,
                        "entryBytes": sample.textBytes,
                        "composedBytes": sample.composedBytes,
                        "sentence": sample.sentenceSource,
                        "composed": sample.composed,
                        "entry": sample.question.entry?.text as Any,
                        "complete": sample.question.entry?.complete as Any,
                        "cutAt": sample.question.entry?.cutAt as Any,
                        "edition": sample.question.entry?.ref.edition as Any,
                        "key": sample.question.entry?.ref.key as Any,
                        "occurrence": sample.question.entry?.ref.occurrence as Any,
                    ])
                }
            }
            var timings: [Ask] = []
            if let provider, source != nil {
                for sample in chosen.prefix(asks) {
                    let started = ContinuousClock.now
                    do {
                        let raw = try await provider.answer(to: sample.composed)
                        let elapsed = started.duration(to: .now)
                        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                        do {
                            let answer = try AIAnswerValidator.validate(json: Data(raw.utf8), mode: .grounded,
                                                                        entry: sample.question.entry)
                            timings.append(Ask(source: source?.rawValue ?? "none", entryBytes: sample.textBytes,
                                               composedBytes: sample.composedBytes, tokens: sample.tokens,
                                               seconds: seconds, outcome: answer.outcome.rawValue, validated: true,
                                               error: nil, sentence: sample.sentenceSource))
                        } catch {
                            timings.append(Ask(source: source?.rawValue ?? "none", entryBytes: sample.textBytes,
                                               composedBytes: sample.composedBytes, tokens: sample.tokens,
                                               seconds: seconds, outcome: "answer.invalid", validated: false,
                                               error: error.code, sentence: sample.sentenceSource))
                        }
                    } catch {
                        let elapsed = started.duration(to: .now)
                        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                        timings.append(Ask(source: source?.rawValue ?? "none", entryBytes: sample.textBytes,
                                           composedBytes: sample.composedBytes, tokens: sample.tokens,
                                           seconds: seconds, outcome: "unavailable", validated: false,
                                           error: error.code, sentence: sample.sentenceSource))
                    }
                }
            }
            try? core.close(dict: dict)
            reports.append(DictionaryReport(
                file: file.lastPathComponent, title: info.title, formatVersion: info.formatVersion, keys: info.keys,
                keysSampled: samples.count, textBytesMin: byText.first ?? 0, textBytesMedian: byText[byText.count / 2],
                textBytesMax: byText.last ?? 0, composedBytesMin: byComposed.first ?? 0,
                composedBytesMedian: byComposed[byComposed.count / 2], composedBytesMax: byComposed.last ?? 0,
                largestComplete: largest.complete, largestCutAt: largest.cutAt, largestTokens: largest.tokens,
                asks: timings))
            print("\(file.lastPathComponent): \(samples.count) entries, text \(byText.first ?? 0)…\(byText.last ?? 0) B, "
                  + "question \(byComposed.first ?? 0)…\(byComposed.last ?? 0) B, largest \(largest.complete ? "whole" : "cut at \(largest.cutAt)")")
        }

        if let emit {
            let data = try JSONSerialization.data(withJSONObject: ["asks": emitted],
                                                  options: [.prettyPrinted, .sortedKeys])
            try data.write(to: emit)
            print("wrote \(emit.path) (\(emitted.count) asks)")
        }

        let payload: [String: Any] = [
            "date": ISO8601DateFormatter().string(from: Date()),
            "entryBudgetBytes": entryBudget,
            "questionCeilingBytes": AIComposer.questionCeilingUTF8,
            "apple": ["available": appleAvailable, "contextSize": contextSize],
            "source": source?.rawValue ?? "none",
            "dictionaries": reports.map { report -> [String: Any] in
                let object: [String: Any] = [
                    "file": report.file, "title": report.title, "formatVersion": report.formatVersion,
                    "keys": report.keys, "keysSampled": report.keysSampled,
                    "textBytes": ["min": report.textBytesMin, "median": report.textBytesMedian, "max": report.textBytesMax],
                    "composedBytes": ["min": report.composedBytesMin, "median": report.composedBytesMedian,
                                      "max": report.composedBytesMax],
                    "largest": ["complete": report.largestComplete, "cutAt": report.largestCutAt,
                                "tokens": report.largestTokens as Any],
                    "asks": report.asks.map { ask -> [String: Any] in
                        ["source": ask.source, "entryBytes": ask.entryBytes, "composedBytes": ask.composedBytes,
                         "tokens": ask.tokens as Any, "seconds": ask.seconds, "outcome": ask.outcome,
                         "validated": ask.validated, "error": ask.error as Any, "sentence": ask.sentence]
                    },
                ]
                return object
            },
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: out)
        print("wrote \(out.path)")
    }
}

let arguments = CommandLine.arguments
do {
    if arguments.contains("--self-test") {
        try Harness.selfTest()
        exit(0)
    }
    if let answerPath = Harness.value("--validate-answers", arguments), let asksPath = Harness.value("--asks-file", arguments) {
        try Harness.validate(asks: URL(fileURLWithPath: asksPath), answers: URL(fileURLWithPath: answerPath),
                             out: URL(fileURLWithPath: Harness.value("--out", arguments) ?? "ai-measure.json"),
                             source: Harness.value("--source-name", arguments) ?? "cli")
        exit(0)
    }
    guard let corpus = Harness.value("--corpus", arguments) else {
        print("usage: XDictAIMeasure --self-test | --corpus <dir> [--out <json>] [--keys 120] [--asks 1] "
              + "[--apple | --claude [--claude-home <dir>] | --codex [--codex-home <dir>]] [--only <name>]")
        exit(1)
    }
    let named = ["--apple": Harness.Source.apple, "--claude": .claude, "--codex": .codex]
        .filter { arguments.contains($0.key) }
    precondition(named.count <= 1, "name at most one source: --apple, --claude or --codex")
    let source = named.first?.value
    let out = URL(fileURLWithPath: Harness.value("--out", arguments) ?? "ai-measure.json")
    guard let keys = Int(Harness.value("--keys", arguments) ?? "120"), (0...10_000).contains(keys),
          let asks = Int(Harness.value("--asks", arguments) ?? "1"), (0...100).contains(asks) else {
        FileHandle.standardError.write(Data("ai-measure: --keys is 0…10000 and --asks is 0…100\n".utf8))
        exit(1)
    }
    let claudeHome = Harness.value("--claude-home", arguments).map { URL(fileURLWithPath: $0) }
    let codexHome = Harness.value("--codex-home", arguments).map { URL(fileURLWithPath: $0) }
    let emit = Harness.value("--emit-asks", arguments).map { URL(fileURLWithPath: $0) }
    try await Harness.run(corpus: URL(fileURLWithPath: corpus), out: out, keyLimit: keys, source: source,
                          asks: asks, claudeHome: claudeHome, codexHome: codexHome,
                          only: Harness.value("--only", arguments), emit: emit)
} catch {
    FileHandle.standardError.write(Data("ai-measure: \(error)\n".utf8))
    exit(2)
}
