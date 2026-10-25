import CryptoKit
import Foundation
import Testing
@testable import XDictAI

/// **The AI contract's fixtures** (`conformance/ai/CONTRACT.md` §8; plan-ai-meaning WI-3): every case in
/// `conformance/ai/vectors.jsonl` through the **production** marking, composer and validator, the complete output compared
/// ordinal UTF-16. The harness decodes the fixture grammar and nothing else; a case it cannot use is a harness failure,
/// never an expected refusal.
struct AIContractTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let vectors = root.appending(path: "conformance/ai/vectors.jsonl")

    /// A fixture the harness could not use — never an expected refusal.
    struct Harness: Error, CustomStringConvertible { let description: String }

    @Test func theVectors() throws {
        let data = try Data(contentsOf: Self.vectors)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        var ids = Set<String>()
        var failures: [String] = []
        for (index, line) in lines.enumerated() {
            let where_ = "line \(index + 1)"
            let parsed: Any
            do { parsed = try JSONSerialization.jsonObject(with: Data(line.utf8)) }
            catch { throw Harness(description: "\(where_): not JSON (\(error.localizedDescription))") }
            guard let object = parsed as? [String: Any] else { throw Harness(description: "\(where_): not an object") }
            guard object["format"] as? Int == 1 else {
                throw Harness(description: "\(where_): unsupported grammar \(String(describing: object["format"]))")
            }
            guard object["contract"] as? Int == 3 else {
                throw Harness(description: "\(where_): unsupported major \(String(describing: object["contract"]))")
            }
            guard let id = object["id"] as? String, ids.insert(id).inserted else {
                throw Harness(description: "\(where_): a missing or duplicate id")
            }
            guard let input = object["input"] as? [String: Any], let expect = object["expect"] as? [String: Any] else {
                throw Harness(description: "\(where_): a case needs input and expect")
            }
            guard let op = object["op"] as? String else { throw Harness(description: "\(where_): no operation") }
            let problem: String?
            switch op {
            case "mark": problem = evaluateMark(id: id, input: input, expect: expect)
            case "compose": problem = evaluateCompose(id: id, input: input, expect: expect)
            case "validate": problem = evaluateValidate(id: id, input: input, expect: expect)
            default: throw Harness(description: "\(where_): unknown operation \(op)")
            }
            if let problem { failures.append(problem) }
        }
        print("ai-contract cases: \(ids.sorted().joined(separator: " "))")
        print("ai-contract: \(ids.count) cases, suite sha256:\(digest)")
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    private func evaluateMark(id: String, input: [String: Any], expect: [String: Any]) -> String? {
        guard let sentence = input["sentence"] as? String, let range = input["range"] as? [String: Any] else {
            return "\(id): harness: mark needs a sentence and a range"
        }
        let start = range["start"] as? String, length = range["length"] as? String
        let parsedRange: AITermRange
        if start == "not-found" {
            parsedRange = .notFound
        } else if let start, let length, let s = Int(start), let l = Int(length) {
            parsedRange = .range(start: s, length: l)
        } else {
            return "\(id): harness: an integer string or not-found was expected"
        }
        guard let wanted = expect["text"] as? String, expect["status"] as? String == "ok" else {
            return "\(id): a mark case expects ok and text"
        }
        let got = AIMarking.marked(sentence: sentence, range: parsedRange)
        return same(got, wanted) ? nil : "\(id): marked text differs\n  got: \(got)\n want: \(wanted)"
    }

    private func evaluateCompose(id: String, input: [String: Any], expect: [String: Any]) -> String? {
        guard let template = input["template"] as? String, let term = input["term"] as? String,
              let sentence = input["sentence"] as? String, let language = input["language"] as? String,
              let modeText = input["mode"] as? String, let mode = AIMode(rawValue: modeText) else {
            return "\(id): harness: compose needs template, term, sentence, language and mode"
        }
        let entry: AIEntryText?
        if let text = input["entry"] as? String {
            entry = AIEntryText(text: text, complete: true, cutAt: 0,
                                ref: AIEntryRef(edition: "e", key: "k", occurrence: 0))
        } else if let object = input["entry"] as? [String: Any], let text = object["text"] as? String {
            // An entry object carries the cut report: a cut and a whole entry may have identical text.
            entry = AIEntryText(text: text, complete: object["complete"] as? Bool ?? true,
                                cutAt: (object["cutAt"] as? NSNumber)?.uint64Value ?? 0,
                                ref: AIEntryRef(edition: "e", key: "k", occurrence: 0))
        } else {
            entry = nil
        }
        let question = AIQuestion(term: term, termRange: .notFound, sentence: sentence, entry: entry,
                                  sense: Self.sense(input), language: language, mode: mode)
        do {
            let composed = try AIComposer.compose(template: template, question: question)
            guard expect["status"] as? String == "ok", let wanted = expect["text"] as? String else {
                return "\(id): expected \(expect["code"] ?? "invalid"), got a question"
            }
            return same(composed, wanted) ? nil : "\(id): composed question differs\n  got: \(composed)\n want: \(wanted)"
        } catch {
            guard expect["status"] as? String == "invalid" else {
                return "\(id): refused (\(error.code)), expected a question"
            }
            let wanted = expect["code"] as? String ?? ""
            return error.code == wanted ? nil : "\(id): refused as \(error.code), wanted \(wanted)"
        }
    }

    private func evaluateValidate(id: String, input: [String: Any], expect: [String: Any]) -> String? {
        guard let answer = input["answer"] as? [String: Any], let modeText = input["mode"] as? String,
              let mode = AIMode(rawValue: modeText) else {
            return "\(id): harness: validate needs an answer and a mode"
        }
        let entry: AIEntryText?
        if let object = input["entry"] as? [String: Any], let text = object["text"] as? String,
           let complete = object["complete"] as? Bool {
            entry = AIEntryText(text: text, complete: complete, cutAt: 0,
                                ref: AIEntryRef(edition: "e", key: "k", occurrence: 0))
        } else {
            entry = nil
        }
        guard let data = try? JSONSerialization.data(withJSONObject: answer, options: []) else {
            return "\(id): harness: the answer cannot be encoded"
        }
        do {
            let validated = try AIAnswerValidator.validate(json: data, mode: mode, entry: entry,
                                                          sense: Self.sense(input))
            guard expect["status"] as? String == "ok" else {
                return "\(id): expected \(expect["code"] ?? "invalid"), got \(validated.outcome.rawValue)"
            }
            let wanted = expect["outcome"] as? String ?? ""
            return validated.outcome.rawValue == wanted ? nil : "\(id): outcome \(validated.outcome.rawValue), wanted \(wanted)"
        } catch {
            guard expect["status"] as? String == "invalid" else {
                return "\(id): refused (\(error.code)), expected \(expect["outcome"] ?? "a value")"
            }
            let wanted = expect["code"] as? String ?? ""
            return error.code == wanted ? nil : "\(id): refused as \(error.code), wanted \(wanted)"
        }
    }

    /// **The quote is a byte substring** (§5.3): Swift compares strings canonically, so an NFD quote would pass against
    /// an NFC entry and prove nothing about provenance. (Audit finding, 2026-10-20.)
    @Test func aCanonicallyEquivalentQuoteIsNotFound() {
        let entry = AIEntryText(text: "café", complete: true, cutAt: 0,
                                ref: AIEntryRef(edition: "e", key: "k", occurrence: 0))
        let answer = #"{"outcome":"matched","quotes":["cafe\u0301"],"explanation":"It is a drink."}"#
        do {
            _ = try AIAnswerValidator.validate(json: Data(answer.utf8), mode: .grounded, entry: entry)
            Issue.record("an NFD quote passed against an NFC entry")
        } catch {
            #expect(error == .quoteNotFound)
        }
    }

    /// **Unicode line separators are line breaks** (§5.6): U+2028 and U+2029 would draw a second line in the pane.
    @Test func aUnicodeLineSeparatorInTheExplanationIsRefused() {
        let entry = AIEntryText(text: "hold. To keep.", complete: true, cutAt: 0,
                                ref: AIEntryRef(edition: "e", key: "k", occurrence: 0))
        let answer = #"{"outcome":"matched","quotes":["hold"],"explanation":"First\u2028second"}"#
        do {
            _ = try AIAnswerValidator.validate(json: Data(answer.utf8), mode: .grounded, entry: entry)
            Issue.record("a U+2028 explanation passed")
        } catch {
            #expect(error == .explanation)
        }
    }

    /// **The entry's completeness reaches the model** (§4a): whole and cut entries say which they are, and the cut one
    /// names its cut point. (Audit finding, 2026-10-20.)
    @Test func theComposedQuestionCarriesTheEntryState() throws {
        let whole = AIQuestion(term: "hold", termRange: .notFound, sentence: "Please hold",
                               entry: AIEntryText(text: "1. to keep", complete: true, cutAt: 0,
                                                  ref: AIEntryRef(edition: "e", key: "k", occurrence: 0)),
                               language: "en", mode: .grounded)
        let cut = AIQuestion(term: "hold", termRange: .notFound, sentence: "Please hold",
                             entry: AIEntryText(text: "1. to keep", complete: false, cutAt: 200,
                                                ref: AIEntryRef(edition: "e", key: "k", occurrence: 0)),
                             language: "en", mode: .grounded)
        let template = "{term}: {sentence} Entry: {entry}"
        let wholeText = try AIComposer.compose(template: template, question: whole)
        let cutText = try AIComposer.compose(template: template, question: cut)
        #expect(wholeText.contains("The entry above is complete: every part of it was sent."))
        #expect(cutText.contains("The entry above is incomplete: it was cut at byte 200"))
        // A sentence-only question has no entry, so no state.
        let sentenceOnly = try AIComposer.compose(template: "Word {term}: {sentence}",
                                                  question: AIQuestion(term: "hold", termRange: .notFound,
                                                                       sentence: "Please hold", entry: nil,
                                                                       language: "en", mode: .sentenceOnly))
        #expect(!sentenceOnly.contains("The entry above is"))
    }

    /// **The chosen sense's completeness reaches the model** (§4a, contract 3): a span-dropped sense is partial even
    /// when the entry is whole, and the model gets fixed bytes saying so. (Audit finding, 2026-10-23.)
    @Test func theComposedQuestionCarriesTheChosenSensesCompleteness() throws {
        let whole = try Self.explainQuestion(whole: true)
        let partial = try Self.explainQuestion(whole: false)
        #expect(whole.contains("The chosen sense above is complete: every part of it was sent."))
        #expect(partial.contains("The chosen sense above is incomplete: part of it was not sent."))
        #expect(!whole.contains("The chosen sense above is incomplete"))
        #expect(!partial.contains("The chosen sense above is complete"))
    }

    /// **A range that splits a character names no text** (§2): an empty target at a continuation byte is refused as
    /// surely as a mismatched one. (Verification finding, 2026-10-23.)
    @Test func aSenseRangeThatSplitsACharacterIsRefused() {
        let entry = AIEntryText(text: "café", complete: true, cutAt: 0,
                                ref: AIEntryRef(edition: "e", key: "k", occurrence: 0))
        // "café" is five UTF-8 bytes; byte 4 is the second half of "é".
        let sense = AISense(id: 1, start: 4, len: 0, text: "", label: nil, section: nil, whole: true)
        let question = AIQuestion(term: "cafe", termRange: .notFound, sentence: "A cafe", entry: entry,
                                  sense: sense, language: "en", mode: .explainSense)
        do {
            _ = try AIComposer.compose(template: "{term} {sentence} {entry} {sense}", question: question)
            Issue.record("a sense range inside a character was composed")
        } catch {
            #expect(error == .senseTextMismatch)
        }
    }

    private static func explainQuestion(whole: Bool) throws -> String {
        let entry = AIEntryText(text: "1. to keep", complete: true, cutAt: 0,
                                ref: AIEntryRef(edition: "e", key: "k", occurrence: 0))
        let sense = AISense(id: 1, start: 0, len: 10, text: "1. to keep", label: "1", section: nil, whole: whole)
        let question = AIQuestion(term: "hold", termRange: .notFound, sentence: "Please hold", entry: entry,
                                  sense: sense, language: "en", mode: .explainSense)
        return try AIComposer.compose(template: "{term}: {sentence} Entry: {entry} Sense: {sense}", question: question)
    }

    /// **The cap is enforced while rendering** (§4.5): many `{entry}` placeholders must not materialise a huge string
    /// before being refused. (Audit finding, 2026-10-20.)
    @Test func anEntryPlaceholderFloodIsRefusedWhileRendering() {
        let entry = AIEntryText(text: String(repeating: "a", count: 64 << 10), complete: true, cutAt: 0,
                                ref: AIEntryRef(edition: "e", key: "k", occurrence: 0))
        let question = AIQuestion(term: "hold", termRange: .notFound, sentence: "Please hold", entry: entry,
                                  language: "en", mode: .grounded)
        let template = String(repeating: "{entry} ", count: 1_000) + "{term} {sentence}"
        do {
            _ = try AIComposer.compose(template: template, question: question)
            Issue.record("a 64 MB question was composed")
        } catch {
            #expect(error == .questionTooLong)
        }
    }

    /// **Exactly at the ceiling is allowed; one byte over is not** (§4.5). Off-by-one here would refuse a question the
    /// contract permits. (Verification finding, 2026-10-20.)
    @Test func aQuestionExactlyAtTheCeilingIsAllowed() throws {
        let suffix = AIComposer.responseContract.utf8.count
        let room = AIComposer.questionCeilingUTF8 - 2 - suffix - 2   // sentenceOnly: "a " and the term
        let question = AIQuestion(term: "a", termRange: .notFound, sentence: String(repeating: "b", count: room),
                                  entry: nil, language: "en", mode: .sentenceOnly)
        let exact = try AIComposer.compose(template: "{term} {sentence}", question: question)
        #expect(exact.utf8.count == AIComposer.questionCeilingUTF8)
        let over = AIQuestion(term: "a", termRange: .notFound, sentence: String(repeating: "b", count: room + 1),
                              entry: nil, language: "en", mode: .sentenceOnly)
        do {
            _ = try AIComposer.compose(template: "{term} {sentence}", question: over)
            Issue.record("a question one byte over the ceiling was composed")
        } catch {
            #expect(error == .questionTooLong)
        }
    }

    /// **A fixture the harness cannot use is a harness failure** (§8): malformed JSON, an unknown operation, a duplicate
    /// id, an unsupported grammar or major.
    @Test func aFixtureTheHarnessCannotUseIsAHarnessFailure() {
        let good = #"{"format":1,"contract":2,"id":"a","op":"mark","input":{"sentence":"hold","range":{"start":"not-found","length":"4"}},"expect":{"status":"ok","text":"hold"}}"#
        func run(_ text: String) throws {
            let data = Data(text.utf8)
            var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            if lines.last?.isEmpty == true { lines.removeLast() }
            var ids = Set<String>()
            for line in lines {
                let parsed: Any
                do { parsed = try JSONSerialization.jsonObject(with: Data(line.utf8)) }
                catch { throw Harness(description: "not JSON (\(error.localizedDescription))") }
                guard let object = parsed as? [String: Any] else {
                    throw Harness(description: "not an object")
                }
                guard object["format"] as? Int == 1, object["contract"] as? Int == 2 else {
                    throw Harness(description: "unsupported version")
                }
                guard let id = object["id"] as? String, ids.insert(id).inserted else {
                    throw Harness(description: "duplicate id")
                }
                guard let op = object["op"] as? String, ["mark", "compose", "validate"].contains(op) else {
                    throw Harness(description: "unknown operation")
                }
            }
        }
        #expect(throws: Harness.self) { try run(good + "\n" + good + "\n") }
        #expect(throws: Harness.self) { try run(good.replacingOccurrences(of: #""format":1"#, with: #""format":2"#)) }
        #expect(throws: Harness.self) { try run(good.replacingOccurrences(of: #""contract":2"#, with: #""contract":3"#)) }
        #expect(throws: Harness.self) { try run(good.replacingOccurrences(of: #""op":"mark""#, with: #""op":"frob""#)) }
        #expect(throws: Harness.self) { try run(#"{"#) }
        #expect(throws: Never.self) { try run(good) }
    }

    /// **The response contract is the contract's own bytes** (`CONTRACT.md` §6): the fenced block after `## 6.`, joined by
    /// newlines with no trailing one. A reworded suffix fails here before it fails every compose case.
    @Test func theResponseContractIsTheContractsBytes() throws {
        let text = try String(contentsOf: Self.root.appending(path: "conformance/ai/CONTRACT.md"), encoding: .utf8)
        let section = try #require(text.range(of: "## 6."), "CONTRACT.md has no section 6")
        let after = text[section.upperBound...]
        let opening = try #require(after.range(of: "```text\n"), "section 6 has no text block")
        let rest = after[opening.upperBound...]
        let closing = try #require(rest.range(of: "\n```"), "the text block is not closed")
        let block = String(rest[..<closing.lowerBound])
        #expect(AIComposer.responseContract == block, "the suffix differs from CONTRACT.md §6")
    }

    /// **The chosen-sense suffix is §6a's block**, byte for byte (contract 3).
    @Test func theChosenSenseSuffixIsTheContracts() throws {
        let text = try String(contentsOf: Self.root.appending(path: "conformance/ai/CONTRACT.md"), encoding: .utf8)
        let section = try #require(text.range(of: "## 6a."), "CONTRACT.md has no section 6a")
        let after = text[section.upperBound...]
        let opening = try #require(after.range(of: "```text\n"), "section 6a has no text block")
        let rest = after[opening.upperBound...]
        let closing = try #require(rest.range(of: "\n```"), "the text block is not closed")
        let block = String(rest[..<closing.lowerBound])
        #expect(AIComposer.explainResponseContract == block, "the suffix differs from CONTRACT.md §6a")
    }

    /// **The providers can generate every outcome the contract names** (contract 3; plan-explain-sense WI-4): the CLI's
    /// schema and Apple's guided enum carry the two chosen-sense verdicts, and the validator (the vectors above) keeps
    /// them out of the old modes.
    @Test func theProvidersCanGenerateEveryOutcomeTheContractNames() {
        let outcomes = Set(AIOutcome.allCases.map(\.rawValue))
        for outcome in outcomes {
            #expect(AIAnswerSchema.claude.contains("\"\(outcome)\""),
                    "the Claude schema omits \(outcome)")
        }
        #if canImport(FoundationModels)
        #expect(Set(AppleAnswerOutcome.allCases.map(\.rawValue)) == outcomes,
                "the guided enum and the contract disagree")
        #endif
    }

    /// A chosen-sense record from a fixture's `sense` object.
    static func sense(_ input: [String: Any]) -> AISense? {
        guard let object = input["sense"] as? [String: Any], let text = object["text"] as? String else { return nil }
        return AISense(id: (object["id"] as? NSNumber)?.uint32Value ?? 0,
                       start: (object["start"] as? NSNumber)?.uint64Value ?? 0,
                       len: (object["len"] as? NSNumber)?.uint64Value ?? 0,
                       text: text, label: object["label"] as? String, section: object["section"] as? String,
                       whole: object["whole"] as? Bool ?? true)
    }

    /// **The shipped defaults are the files** (`CONTRACT.md` §4.7), byte for byte.
    @Test func theDefaultTemplatesAreTheFiles() throws {
        for language in AITemplates.languages {
            for mode in AIMode.allCases {
                let file = Self.root.appending(path: "conformance/ai/defaults/\(language).\(mode.rawValue).txt")
                let wanted = try String(contentsOf: file, encoding: .utf8)
                let got = try #require(AITemplates.defaultTemplate(language: language, mode: mode),
                                       "no default for \(language)/\(mode.rawValue)")
                #expect(got == wanted, "\(language)/\(mode.rawValue) differs from its file")
            }
        }
    }

    // MARK: - Comparison: ordinal UTF-16, complete

    private func same(_ a: String, _ b: String) -> Bool { Array(a.utf16) == Array(b.utf16) }
}
