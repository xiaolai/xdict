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
    /// The contract major this runner implements (`CONTRACT.md` §9). Contract 6 adds the `translate` and
    /// `explainGrammar` modes, their answers and their fixed response contracts (§2, §5b, §5c, §6b, §6c), so the
    /// fixtures' major moved with them.
    static let contractMajor = 6

    /// A fixture the harness could not use — never an expected refusal.
    struct Harness: Error, CustomStringConvertible { let description: String }

    @Test func theVectors() throws {
        let data = try Data(contentsOf: Self.vectors)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let cases = try Self.suite(data)
        var failures: [String] = []
        for (id, op, input, expect) in cases {
            let problem: String?
            switch op {
            case "mark": problem = evaluateMark(id: id, input: input, expect: expect)
            case "compose": problem = evaluateCompose(id: id, input: input, expect: expect)
            case "validate": problem = evaluateValidate(id: id, input: input, expect: expect)
            default: throw Harness(description: "unknown operation \(op)")
            }
            if let problem { failures.append(problem) }
        }
        print("ai-contract cases: \(cases.map(\.id).sorted().joined(separator: " "))")
        print("ai-contract: \(cases.count) cases, suite sha256:\(digest)")
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    /// **A whole suite, read strictly** (audit round 4, 2026-10-25): the bytes must be UTF-8, an empty suite is a harness
    /// failure, and every line goes through the one parser below. The runner and the harness-failure test share it.
    static func suite(_ data: Data)
        throws(Harness) -> [(id: String, op: String, input: [String: Any], expect: [String: Any])] {
        guard let text = String(data: data, encoding: .utf8) else { throw Harness(description: "the suite is not UTF-8") }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        guard !lines.isEmpty else { throw Harness(description: "the suite holds no cases") }
        var ids = Set<String>()
        var cases: [(id: String, op: String, input: [String: Any], expect: [String: Any])] = []
        for (index, line) in lines.enumerated() {
            cases.append(try fixture(line, at: "line \(index + 1)", ids: &ids))
        }
        return cases
    }

    /// **One fixture line, validated** (audit round 2, 2026-10-25): its grammar, version, id and operation. The runner and
    /// the harness-failure test read fixtures through this one parser, so removing a check here fails both.
    static func fixture(_ line: Substring, at where_: String, ids: inout Set<String>)
        throws(Harness) -> (id: String, op: String, input: [String: Any], expect: [String: Any]) {
        func fail(_ reason: String) -> Harness {
            Harness(description: where_.isEmpty ? reason : "\(where_): \(reason)")
        }
        let parsed: Any
        do { parsed = try JSONSerialization.jsonObject(with: Data(line.utf8)) }
        catch { throw fail("not JSON (\(error.localizedDescription))") }
        guard let object = parsed as? [String: Any] else { throw fail("not an object") }
        guard Self.unsigned(object["format"], max: 1) == 1 else {
            throw fail("unsupported grammar \(String(describing: object["format"]))")
        }
        guard Self.unsigned(object["contract"], max: UInt64(Self.contractMajor)) == UInt64(Self.contractMajor) else {
            throw fail("unsupported major \(String(describing: object["contract"]))")
        }
        guard let id = object["id"] as? String, ids.insert(id).inserted else {
            throw fail("a missing or duplicate id")
        }
        guard let input = object["input"] as? [String: Any], let expect = object["expect"] as? [String: Any] else {
            throw fail("a case needs input and expect")
        }
        guard let op = object["op"] as? String, ["mark", "compose", "validate"].contains(op) else {
            throw fail("a missing or unknown operation")
        }
        return (id, op, input, expect)
    }

    /// A range as the fixtures write it: an object of integer strings, or `not-found` (contract 5 lets a compose
    /// case carry one, so a phrase's marked span is composed as the shell composes it).
    private static func termRange(_ value: Any, at id: String) throws(Harness) -> AITermRange {
        guard let range = value as? [String: Any] else { throw Harness(description: "\(id): harness: a range object was expected") }
        let start = range["start"] as? String, length = range["length"] as? String
        if start == "not-found" { return .notFound }
        guard let start, let length, let s = Int(start), let l = Int(length) else {
            throw Harness(description: "\(id): harness: an integer string or not-found was expected")
        }
        return .range(start: s, length: l)
    }

    private func evaluateMark(id: String, input: [String: Any], expect: [String: Any]) -> String? {
        guard let sentence = input["sentence"] as? String, let range = input["range"] as? [String: Any] else {
            return "\(id): harness: mark needs a sentence and a range"
        }
        let parsedRange: AITermRange
        do { parsedRange = try Self.termRange(range, at: id) } catch { return "\(id): harness: \(error)" }
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
        } else if let value = input["entry"], !(value is NSNull) {
            // An entry object carries the cut report: a cut and a whole entry may have identical text. Its fields are
            // required and typed — a malformed one is a harness failure, never a silent default (audit round 2).
            guard let object = value as? [String: Any], let text = object["text"] as? String,
                  let complete = Self.boolean(object["complete"]) else {
                return "\(id): harness: an entry object needs a text and a boolean complete"
            }
            let cutAt: UInt64
            if let value = object["cutAt"] {
                guard let parsed = Self.unsigned(value, max: UInt64.max) else {
                    return "\(id): harness: entry cutAt is not an unsigned integer"
                }
                cutAt = parsed
            } else {
                cutAt = 0
            }
            entry = AIEntryText(text: text, complete: complete, cutAt: cutAt,
                                ref: AIEntryRef(edition: "e", key: "k", occurrence: 0))
        } else {
            entry = nil
        }
        let sense: AISense?
        do { sense = try Self.sense(input) } catch { return "\(id): harness: \(error)" }
        // **A question's term range is part of the contract's input** (§2): compose cases may state one, and a phrase
        // ask always does — its `term` is the marked span's own words.
        let range: AITermRange
        if let value = input["range"] {
            do { range = try Self.termRange(value, at: id) } catch { return "\(id): harness: \(error)" }
        } else {
            range = .notFound
        }
        let question = AIQuestion(term: term, termRange: range, sentence: sentence, entry: entry,
                                  sense: sense, language: language, mode: mode,
                                  phrase: input["phrase"] as? String)
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
        if let value = input["entry"], !(value is NSNull) {
            guard let object = value as? [String: Any], let text = object["text"] as? String,
                  let complete = Self.boolean(object["complete"]) else {
                return "\(id): harness: an entry object needs a text and a boolean complete"
            }
            entry = AIEntryText(text: text, complete: complete, cutAt: 0,
                                ref: AIEntryRef(edition: "e", key: "k", occurrence: 0))
        } else {
            entry = nil
        }
        let sense: AISense?
        do { sense = try Self.sense(input) } catch { return "\(id): harness: \(error)" }
        guard let data = try? JSONSerialization.data(withJSONObject: answer, options: []) else {
            return "\(id): harness: the answer cannot be encoded"
        }
        do {
            let validated = try AIAnswerValidator.validate(json: data, mode: mode, entry: entry, sense: sense)
            guard expect["status"] as? String == "ok" else {
                return "\(id): expected \(expect["code"] ?? "invalid"), got \(validated.outcome.rawValue)"
            }
            let wanted = expect["outcome"] as? String ?? ""
            guard validated.outcome.rawValue == wanted else {
                return "\(id): outcome \(validated.outcome.rawValue), wanted \(wanted)"
            }
            // **The whole record, not only its outcome** (audit round 4, 2026-10-25): a dropped or reordered quote, or an
            // altered explanation, used to pass; §7 compares the complete validated value.
            // **Ordinal UTF-16, as §5.3 compares them** (audit round 4, 2026-10-25): Swift's `==` reads two canonically
            // equivalent strings as equal, so an NFD quote would pass against an NFC one here and prove nothing.
            let wantedQuotes = expect["quotes"] as? [String] ?? (answer["quotes"] as? [String] ?? [])
            guard validated.quotes.count == wantedQuotes.count,
                  zip(validated.quotes, wantedQuotes).allSatisfy({ same($0.0, $0.1) }) else {
                return "\(id): quotes \(validated.quotes), wanted \(wantedQuotes)"
            }
            let wantedExplanation = expect["explanation"] as? String ?? (answer["explanation"] as? String ?? "")
            guard same(validated.explanation, wantedExplanation) else {
                return "\(id): explanation \(validated.explanation), wanted \(wantedExplanation)"
            }
            // **The translation is part of the record** (contract 6 §5b): a dropped or altered translation used to be
            // unobservable here, the same gap quotes had before audit round 4.
            let wantedTranslation = expect["translation"] as? String ?? (answer["translation"] as? String ?? "")
            guard same(validated.translation ?? "", wantedTranslation) else {
                return "\(id): translation \(validated.translation ?? "nil"), wanted \(wantedTranslation)"
            }
            return nil
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

    /// **Braces are read as scalars, and a stray one is refused** (audit round 4, 2026-10-25): a closing brace with no
    /// opening one is not passed through as text, and one joined to a combining accent is still the placeholder parser's
    /// brace rather than part of a literal run.
    @Test func aStrayClosingBraceIsRefusedAndACombinedOneIsStillABrace() throws {
        let question = AIQuestion(term: "hold", termRange: .notFound, sentence: "Please hold", entry: nil,
                                  language: "en", mode: .sentenceOnly)
        #expect(throws: AIComposeError.unknownPlaceholder("}")) {
            try AIComposer.compose(template: "hold }", question: question)
        }
        #expect(throws: AIComposeError.unknownPlaceholder("}")) {
            try AIComposer.compose(template: "hold }\u{0301}", question: question)
        }
        // The success case carries what the contract requires of a sentence-only template, and reads its own text first:
        // composition appends fixed blocks after it.
        #expect(try AIComposer.compose(template: "{term}: {sentence}", question: question).hasPrefix("hold: Please hold"))
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
    @Test func anEntryPlaceholderFloodIsRefusedWhileRendering() throws {
        let entry = AIEntryText(text: String(repeating: "a", count: 64 << 10), complete: true, cutAt: 0,
                                ref: AIEntryRef(edition: "e", key: "k", occurrence: 0))
        let question = AIQuestion(term: "hold", termRange: .notFound, sentence: "Please hold", entry: entry,
                                  language: "en", mode: .grounded)
        let template = String(repeating: "{entry} ", count: 1_000) + "{term} {sentence}"
        // **The refusing pass builds nothing** (audit round 2, 2026-10-25): the size is summed over the parsed pieces, so
        // the test measures the decision itself, not only the error compose happens to return.
        #expect(AIComposer.renderedBytes(try AIComposer.pieces(of: template), question: question)
                > AIComposer.questionCeilingUTF8)
        // **The sink sees nothing** (verification round 3, 2026-10-25): the refusal is decided before a piece is copied.
        var copied = 0
        do {
            try AIComposer.render(try AIComposer.pieces(of: template), question: question, ceiling: 1_024) { _ in
                copied += 1
            }
            Issue.record("the oversized question rendered")
        } catch {
            #expect(error == .questionTooLong)
        }
        #expect(copied == 0, "the refused question handed \(copied) pieces to the sink")
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
        let entryText = "1. to keep"
        let entry = AIEntryText(text: entryText, complete: true, cutAt: 0,
                                ref: AIEntryRef(edition: "e", key: "k", occurrence: 0))
        let sense = AISense(id: 1, start: 0, len: 10, text: entryText, label: "1", section: nil, whole: true)
        // **Every mode**: the fixed part now holds the entry state, the chosen sense's state, the answer-language line
        // and the contract, so a ceiling computed from the contract alone would refuse a question the contract allows.
        func check(_ mode: AIMode, _ template: String, entry: AIEntryText?, sense: AISense?) throws {
            let probe = AIQuestion(term: "a", termRange: .notFound, sentence: "x", entry: entry, sense: sense,
                                   language: "en", mode: mode)
            let templateBytes = template
                .replacingOccurrences(of: "{sentence}", with: "")
                .replacingOccurrences(of: "{term}", with: "a")
                .replacingOccurrences(of: "{entry}", with: entry?.text ?? "")
                .replacingOccurrences(of: "{sense}", with: sense?.text ?? "").utf8.count
            let room = AIComposer.questionCeilingUTF8 - AIComposer.fixedBytes(for: probe) - templateBytes
            func question(_ length: Int) -> AIQuestion {
                AIQuestion(term: "a", termRange: .notFound, sentence: String(repeating: "b", count: length),
                           entry: entry, sense: sense, language: "en", mode: mode)
            }
            let exact = try AIComposer.compose(template: template, question: question(room))
            #expect(exact.utf8.count == AIComposer.questionCeilingUTF8, "\(mode) is not exactly at the ceiling")
            #expect(throws: AIComposeError.questionTooLong) {
                try AIComposer.compose(template: template, question: question(room + 1))
            }
        }
        try check(.sentenceOnly, "{term} {sentence}", entry: nil, sense: nil)
        try check(.grounded, "{term} {sentence} {entry}", entry: entry, sense: nil)
        try check(.explainSense, "{term} {sentence} {entry} {sense}", entry: entry, sense: sense)
    }

    /// **A fixture the harness cannot use is a harness failure** (§8): malformed JSON, an unknown operation, a duplicate
    /// id, an unsupported grammar or major.
    @Test func aFixtureTheHarnessCannotUseIsAHarnessFailure() {
        let good = #"{"format":1,"contract":6,"id":"a","op":"mark","input":{"sentence":"hold","range":{"start":"not-found","length":"4"}},"expect":{"status":"ok","text":"hold"}}"#
        func run(_ text: String) throws {
            _ = try Self.suite(Data(text.utf8))
        }
        #expect(throws: Harness.self) { try run(good + "\n" + good + "\n") }
        #expect(throws: Harness.self) { try run(good.replacingOccurrences(of: #""format":1"#, with: #""format":2"#)) }
        #expect(throws: Harness.self) {
            try run(good.replacingOccurrences(of: #""contract":6"#, with: #""contract":7"#))
        }
        #expect(throws: Harness.self) { try run(good.replacingOccurrences(of: #""op":"mark""#, with: #""op":"frob""#)) }
        #expect(throws: Harness.self) { try run(#"{"#) }
        #expect(throws: Never.self) { try run(good) }
        // **An empty suite is a harness failure** (audit round 4): zero cases must not report success.
        #expect(throws: Harness.self) { _ = try Self.suite(Data()) }
        #expect(throws: Harness.self) { _ = try Self.suite(Data("\n".utf8)) }
    }

    /// **The response contract is the contract's own bytes** (`CONTRACT.md` §6): the fenced block after `## 6.`, joined by
    /// newlines with no trailing one. A reworded suffix fails here before it fails every compose case.
    @Test func theResponseContractIsTheContractsBytes() throws {
        let block = try Self.contractBlock("## 6.")
        #expect(Self.sameBytes(AIComposer.responseContract, block), "the suffix differs from CONTRACT.md §6")
    }

    /// **The answer-language line is §4b's block** (contract 4): the fenced block after `## 4b.`, with `<language>`
    /// standing for the tag. A shell that rewords it fails here before it fails every compose case.
    @Test func theLanguageLineIsTheContracts() throws {
        let block = try Self.contractBlock("## 4b.")
        for tag in ["en", "zh-Hans", "fr"] {
            #expect(Self.sameBytes(AIComposer.languageLine(tag),
                                   block.replacingOccurrences(of: "<language>", with: tag)))
        }
    }

    /// **The line is part of every composed question, and sits at the end**: after the states, one blank line before the
    /// response contract — where the model reads the answer rules.
    @Test func theLanguageLinePrecedesTheContractInEveryMode() throws {
        let entry = AIEntryText(text: "1. to keep", complete: true, cutAt: 0,
                                ref: AIEntryRef(edition: "e", key: "k", occurrence: 0))
        let sense = AISense(id: 1, start: 0, len: 10, text: "1. to keep", label: "1", section: nil, whole: true)
        let sentenceOnly = try AIComposer.compose(
            template: "{term} {sentence}",
            question: AIQuestion(term: "hold", termRange: .notFound, sentence: "Please hold", entry: nil,
                                 language: "zh-Hans", mode: .sentenceOnly))
        let grounded = try AIComposer.compose(
            template: "{term} {sentence} {entry}",
            question: AIQuestion(term: "hold", termRange: .notFound, sentence: "Please hold", entry: entry,
                                 language: "zh-Hans", mode: .grounded))
        let explained = try AIComposer.compose(
            template: "{term} {sentence} {entry} {sense}",
            question: AIQuestion(term: "hold", termRange: .notFound, sentence: "Please hold", entry: entry,
                                 sense: sense, language: "zh-Hans", mode: .explainSense))
        let line = AIComposer.languageLine("zh-Hans")
        for (mode, composed, contract) in [(AIMode.sentenceOnly, sentenceOnly, AIComposer.responseContract),
                                           (.grounded, grounded, AIComposer.responseContract),
                                           (.explainSense, explained, AIComposer.explainResponseContract)] {
            #expect(composed.hasSuffix("\n\n" + line + "\n\n" + contract), "\(mode): the line is not before the contract")
            #expect(composed.components(separatedBy: line).count == 2, "\(mode): the line appears once")
        }
        #expect(grounded.contains("The entry above is complete"), "the entry state still precedes the line")
        #expect(explained.contains("The chosen sense above is complete"), "the sense state still precedes the line")
    }

    /// **The chosen-sense suffix is §6a's block**, byte for byte (contract 3).
    @Test func theChosenSenseSuffixIsTheContracts() throws {
        let block = try Self.contractBlock("## 6a.")
        #expect(Self.sameBytes(AIComposer.explainResponseContract, block), "the suffix differs from CONTRACT.md §6a")
    }

    /// **The providers can generate every outcome the contract names** (contract 3; plan-explain-sense WI-4): the CLI's
    /// schema and Apple's guided enum carry the two chosen-sense verdicts, and the validator (the vectors above) keeps
    /// them out of the old modes.
    @Test func theProvidersCanGenerateEveryOutcomeTheContractNames() throws {
        // **Every shape's own enum, decoded** (audit round 2, 2026-10-25; contract 6): a quoted outcome elsewhere in a
        // schema proved nothing about the field the model fills, and since contract 6 one schema serves one shape.
        let outcomes = Set(AIOutcome.allCases.map(\.rawValue))
        func enumValues(in schemaText: String) throws -> Set<String> {
            let schema = try #require(try JSONSerialization.jsonObject(with: Data(schemaText.utf8))
                                        as? [String: Any], "a Claude schema is not an object")
            let properties = try #require(schema["properties"] as? [String: Any], "the schema has no properties")
            let outcome = try #require(properties["outcome"] as? [String: Any], "the schema has no outcome property")
            return Set(try #require(outcome["enum"] as? [String], "the outcome has no enum"))
        }
        let claude = try enumValues(in: AIAnswerSchema.claude)
            .union(enumValues(in: AIAnswerSchema.translation))
            .union(enumValues(in: AIAnswerSchema.grammar))
        #expect(claude == outcomes, "the Claude schemas' outcome enums and the contract disagree")
        #if canImport(FoundationModels)
        let apple = Set(AppleAnswerOutcome.allCases.map(\.rawValue))
            .union(AppleTranslationOutcome.allCases.map(\.rawValue))
            .union(AppleGrammarOutcome.allCases.map(\.rawValue))
        #expect(apple == outcomes, "the guided enums and the contract disagree")
        #endif
    }

    /// A chosen-sense record from a fixture's `sense` object.
    static func sense(_ input: [String: Any]) throws(Harness) -> AISense? {
        guard let value = input["sense"] else { return nil }
        guard let object = value as? [String: Any], let text = object["text"] as? String else {
            throw Harness(description: "sense is not an object with a text")
        }
        guard let id = unsigned(object["id"], max: UInt64(UInt32.max)), let start = unsigned(object["start"], max: UInt64.max),
              let len = unsigned(object["len"], max: UInt64.max) else {
            throw Harness(description: "sense id, start or len is not an unsigned integer in range")
        }
        let whole: Bool
        if let value = object["whole"] {
            guard let flag = boolean(value) else { throw Harness(description: "sense whole is not a boolean") }
            whole = flag
        } else {
            whole = true
        }
        for key in ["label", "section"] where object[key] != nil && !(object[key] is String || object[key] is NSNull) {
            throw Harness(description: "sense \(key) is not a string")
        }
        return AISense(id: UInt32(id), start: start, len: len, text: text,
                       label: object["label"] as? String, section: object["section"] as? String, whole: whole)
    }

    /// **A JSON boolean, and only a boolean** (audit round 3, 2026-10-25): `NSNumber` bridges numbers to `Bool`, so
    /// `as? Bool` accepted 0 and 1 as `complete` or `whole`.
    static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, String(cString: number.objCType) == "c" else { return nil }
        return number.boolValue
    }

    /// A JSON number as an unsigned integer within `max`: booleans, fractions and negatives are not integers, and nothing
    /// is truncated to fit (audit round 2, 2026-10-25).
    static func unsigned(_ value: Any?, max: UInt64) -> UInt64? {
        // A JSON boolean bridges to `NSNumber` with the char type; `CoreFoundation` is outside this target's allowed
        // imports, so the flag is read from the type (audit round 2, 2026-10-25). **The value is read as a Decimal, never
        // through a Double** (verification round 2): an int64 above 2^53 rounded through a Double could pass the bound
        // with a different value. A fractional, negative or out-of-range number is a harness failure.
        guard let number = value as? NSNumber, String(cString: number.objCType) != "c" else { return nil }
        var decimal = number.decimalValue
        var integral = Decimal()
        NSDecimalRound(&integral, &decimal, 0, .plain)
        guard decimal == integral, integral >= 0 else { return nil }
        let exact = NSDecimalNumber(decimal: integral)
        guard exact.compare(NSDecimalNumber(string: String(max))) != .orderedDescending else { return nil }
        return exact.uint64Value
    }

    /// **The fenced text block of one CONTRACT.md heading, bounded to that section** (audit round 2, 2026-10-25): three
    /// tests each searched from their heading and could read a later section's block when their own had none.
    static func contractBlock(_ heading: String) throws -> String {
        let text = try String(contentsOf: Self.root.appending(path: "conformance/ai/CONTRACT.md"), encoding: .utf8)
        let section = try #require(text.range(of: heading), "CONTRACT.md has no \(heading)")
        let after = text[section.upperBound...]
        let next = after.range(of: "\n## ")?.lowerBound ?? after.endIndex
        let body = after[..<next]
        let opening = try #require(body.range(of: "```text\n"), "\(heading) has no text block")
        let rest = body[opening.upperBound...]
        let closing = try #require(rest.range(of: "\n```"), "the text block is not closed")
        return String(rest[..<closing.lowerBound])
    }

    /// The two strings' UTF-8 bytes, compared as bytes: Swift's `==` is canonical and accepts different bytes.
    static func sameBytes(_ a: String, _ b: String) -> Bool { Array(a.utf8) == Array(b.utf8) }

    /// **A malformed operation payload is a harness failure too** (audit round 3, 2026-10-25): the fixture grammar is not
    /// enough; the entry and sense readers must refuse a broken record rather than defaulting it.
    @Test func aMalformedOperationPayloadIsAHarnessFailure() {
        var input: [String: Any] = ["template": "{term} {sentence} {entry}", "mode": "grounded", "term": "hold",
                                    "sentence": "Please hold", "language": "en"]
        input["entry"] = ["text": "1. to keep"]                       // no complete
        #expect(evaluateCompose(id: "x", input: input, expect: ["status": "ok"])?.contains("harness") == true)
        input["entry"] = ["text": "1. to keep", "complete": 1]        // a number, not a boolean
        #expect(evaluateCompose(id: "x", input: input, expect: ["status": "ok"])?.contains("harness") == true)
        var validate: [String: Any] = ["mode": "explainSense",
                                       "answer": ["outcome": "explained", "quotes": [], "explanation": "x"],
                                       "sense": ["text": "x"]]
        #expect(evaluateValidate(id: "y", input: validate, expect: ["status": "ok"])?.contains("harness") == true)
        validate["sense"] = ["text": "x", "id": 1, "start": true, "len": 1, "whole": true]
        #expect(evaluateValidate(id: "y", input: validate, expect: ["status": "ok"])?.contains("harness") == true)
    }

    /// **The shipped defaults are the files** (`CONTRACT.md` §4.7), byte for byte.
    @Test func theDefaultTemplatesAreTheFiles() throws {
        let directory = Self.root.appending(path: "conformance/ai/defaults")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        var pairs: [(String, AIMode)] = []
        for name in names.sorted() where name.hasSuffix(".txt") {
            let parts = name.dropLast(4).split(separator: ".").map(String.init)
            if parts.count == 2, let mode = AIMode(rawValue: parts[1]) { pairs.append((parts[0], mode)) }
        }
        try #require(!pairs.isEmpty, "no default templates in conformance/ai/defaults")
        // **The directory is the expected set** (audit round 4, 2026-10-25): production's language list used to define what
        // was checked, so emptying it emptied the check too.
        let files = Set(pairs.map { "\($0.0).\($0.1.rawValue)" })
        let shipped = Set(AITemplates.languages.flatMap { language in
            AIMode.allCases.map { "\(language).\($0.rawValue)" }
        })
        #expect(files == shipped, "the shipped defaults and the files disagree")
        for (language, mode) in pairs {
            let file = directory.appending(path: "\(language).\(mode.rawValue).txt")
            let wanted = try String(contentsOf: file, encoding: .utf8)
            let got = try #require(AITemplates.defaultTemplate(language: language, mode: mode),
                                   "no default for \(language)/\(mode.rawValue)")
            #expect(Self.sameBytes(got, wanted), "\(language)/\(mode.rawValue) differs from its file")
        }
    }

    // MARK: - Comparison: ordinal UTF-16, complete

    private func same(_ a: String, _ b: String) -> Bool { Array(a.utf16) == Array(b.utf16) }
}
