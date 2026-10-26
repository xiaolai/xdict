import Foundation
import NaturalLanguage
import XDictAI

/// **The sentence-set measurement** (plan-context-tools WI-2; ADR-0034 d.6): the same sentences asked as a grammar
/// explanation, as a grammar explanation with the system's tags appended (the experiment that alone could put tags into
/// the prompt), and as a translation into a named language — composed through the production composer, asked of one
/// source, and validated through the production validator. It writes a table for the machine columns and a blind set for
/// the owner's reading: answers with no variant label, keyed separately.
///
///   XDictAIMeasure --sentences <file.jsonl> --out <dir> [--apple | --claude | --codex] [--translate-to zh-Hans]
///
/// The sentences are written for the measurement, never taken from a dictionary; with no source named it composes and
/// sizes only, which is what a machine without a configured source can prove.
enum SentenceHarness {
    struct Case {
        let id: String
        let language: String
        let sentence: String
        let term: String
        let range: NSRange?
    }

    struct Row {
        let id: String
        let language: String
        let variant: String
        let target: String
        let composedBytes: Int
        let seconds: Double?
        let outcome: String
        let validated: Bool?
        let detected: String?
        let error: String?
    }

    /// One sentence file: JSON lines of `{id, language, sentence, term, range?}`. A malformed line is the harness's own
    /// failure, never a skipped row.
    static func load(_ url: URL) throws -> [Case] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { line in
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let id = object["id"] as? String, let language = object["language"] as? String,
                  let sentence = object["sentence"] as? String, let term = object["term"] as? String else {
                throw HarnessError.malformed("a sentence line is not {id, language, sentence, term}: \(line)")
            }
            var range: NSRange?
            if let value = object["range"] as? [String: Any], let start = value["start"] as? Int,
               let length = value["length"] as? Int {
                range = NSRange(location: start, length: length)
            }
            return Case(id: id, language: language, sentence: sentence, term: term, range: range)
        }
    }

    /// The variants a case is asked in: the contract-6 questions, and the tag experiment beside them.
    static let variants: [String] = ["grammar", "grammar+tags", "translate"]

    /// The experiment's extra block: the system's own tokens and tags, appended after the composed question. It is
    /// **not** part of contract 6 — it exists to be measured, and only the measurement can put anything like it into a
    /// question the app sends.
    static func tagsBlock(_ sentence: String) -> String {
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
        tagger.string = sentence
        var lines: [String] = []
        tagger.enumerateTags(in: sentence.startIndex..<sentence.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            let lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0
            var parts: [String] = []
            if let tag { parts.append(tag.rawValue) }
            if let lemma, lemma.rawValue != String(sentence[range]) { parts.append("lemma \(lemma.rawValue)") }
            lines.append("\(sentence[range]): \(parts.isEmpty ? "—" : parts.joined(separator: ", "))")
            return true
        }
        return "A part-of-speech reading of the sentence above, from the reader's system:\n" + lines.joined(separator: "\n")
    }

    /// One case's question for a variant, composed through the production composer.
    static func compose(_ item: Case, variant: String, answerLanguage: String, translateTo: String) throws -> String {
        let range = item.range.map { AITermRange.range(start: $0.location, length: $0.length) } ?? .notFound
        switch variant {
        case "translate":
            let template = AITemplates.defaultTemplate(language: answerLanguage, mode: .translate) ?? ""
            let question = AIQuestion(term: item.term, termRange: range, sentence: item.sentence, entry: nil,
                                      language: translateTo, mode: .translate)
            return try AIComposer.compose(template: template, question: question)
        case "grammar", "grammar+tags":
            let template = AITemplates.defaultTemplate(language: answerLanguage, mode: .explainGrammar) ?? ""
            let question = AIQuestion(term: item.term, termRange: range, sentence: item.sentence, entry: nil,
                                      language: answerLanguage, mode: .explainGrammar)
            let composed = try AIComposer.compose(template: template, question: question)
            return variant == "grammar" ? composed : composed + "\n\n" + tagsBlock(item.sentence)
        default:
            throw HarnessError.malformed("unknown variant \(variant)")
        }
    }

    static func run(sentences url: URL, out directory: URL, source: Harness.Source?, translateTo: String,
                    answerLanguage: String, claudeHome: URL?, codexHome: URL?) async throws {
        let cases = try load(url)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let work = FileManager.default.temporaryDirectory.appending(path: "xdict-ai-sentences-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        // One provider per answer shape: the CLI's schema and the guided type are the mode's (contract 6).
        var providers: [AIMode: any AIProvider] = [:]
        for mode in [AIMode.explainGrammar, .translate] {
            if let built = try Harness.provider(source: source, work: work, claudeHome: claudeHome,
                                                codexHome: codexHome, mode: mode) {
                providers[mode] = built
            }
        }

        var rows: [Row] = []
        var blind: [(file: String, id: String, variant: String)] = []
        let blindDirectory = directory.appending(path: "blind")
        try FileManager.default.createDirectory(at: blindDirectory, withIntermediateDirectories: true)
        var counter = 0
        for item in cases {
            for variant in variants {
                let composed: String
                do {
                    composed = try compose(item, variant: variant, answerLanguage: answerLanguage,
                                           translateTo: translateTo)
                } catch {
                    rows.append(Row(id: item.id, language: item.language, variant: variant, target: translateTo,
                                    composedBytes: 0, seconds: nil, outcome: "compose.invalid", validated: nil,
                                    detected: nil, error: (error as? AIComposeError)?.code
                                        ?? String(describing: error)))
                    continue
                }
                let mode: AIMode = variant == "translate" ? .translate : .explainGrammar
                guard let provider = providers[mode] else {
                    rows.append(Row(id: item.id, language: item.language, variant: variant, target: translateTo,
                                    composedBytes: composed.utf8.count, seconds: nil, outcome: "composed", validated: nil,
                                    detected: nil, error: nil))
                    continue
                }
                let started = Date()
                do {
                    let raw = try await provider.answer(to: composed)
                    let seconds = Date().timeIntervalSince(started)
                    var outcome = "answer.invalid"
                    var validated: Bool? = false
                    var errorCode: String?
                    var answerText = raw
                    do {
                        let answer = try AIAnswerValidator.validate(json: Data(raw.utf8), mode: mode, entry: nil)
                        outcome = answer.outcome.rawValue
                        validated = true
                        answerText = variant == "translate" ? (answer.translation ?? answer.explanation)
                                                            : answer.explanation
                    } catch {
                        errorCode = error.code
                    }
                    let detected = variant == "translate" ? dominantLanguage(answerText) : nil
                    rows.append(Row(id: item.id, language: item.language, variant: variant, target: translateTo,
                                    composedBytes: composed.utf8.count, seconds: seconds, outcome: outcome,
                                    validated: validated, detected: detected, error: errorCode))
                    counter += 1
                    let name = String(format: "answer-%03d.txt", counter)
                    try answerText.write(to: blindDirectory.appending(path: name), atomically: true, encoding: .utf8)
                    blind.append((file: name, id: item.id, variant: variant))
                } catch {
                    let seconds = Date().timeIntervalSince(started)
                    rows.append(Row(id: item.id, language: item.language, variant: variant, target: translateTo,
                                    composedBytes: composed.utf8.count, seconds: seconds, outcome: "provider.failed",
                                    validated: nil, detected: nil, error: String(describing: error)))
                }
            }
        }

        var lines = ["id\tlanguage\tvariant\ttarget\tcomposedBytes\tseconds\toutcome\tvalidated\tdetected\tlanguageMatch\terror"]
        for row in rows {
            let match = row.detected.map { $0 == row.target ? "yes" : "no" } ?? ""
            lines.append([row.id, row.language, row.variant, row.target,
                          row.composedBytes == 0 ? "" : String(row.composedBytes),
                          row.seconds.map { String(format: "%.2f", $0) } ?? "", row.outcome,
                          row.validated.map { $0 ? "yes" : "no" } ?? "", row.detected ?? "", match,
                          row.error ?? ""].joined(separator: "\t"))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: directory.appending(path: "prompts.tsv"), atomically: true,
                                                         encoding: .utf8)
        let key = blind.map { ["file": $0.file, "id": $0.id, "variant": $0.variant] }
        let keyData = try JSONSerialization.data(withJSONObject: key, options: [.prettyPrinted, .sortedKeys])
        try keyData.write(to: blindDirectory.appending(path: "key.json"))
        print("sentences: \(cases.count) cases × \(variants.count) variants, \(rows.count) rows, "
              + "\(blind.count) blind answers; wrote \(directory.path)")
    }

    /// The language a translation came out in, as `NLLanguageRecognizer` names it; nil when it names none.
    static func dominantLanguage(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }
}
