import Foundation
import NaturalLanguage
import Testing

/// **What Apple's tagger really covers** (plan-context-tools WI-1; ADR-0034 d.6): for every language the reader is likely
/// to meet, which tag schemes exist for words, and — where a written sample exists — how many of its tokens get a lexical
/// class and a lemma. Apple's own documentation says “Some tag schemes are only available for certain units and languages”,
/// so the table is measured, never assumed.
///
/// It writes the table and nothing else, and runs only when `XDICT_NL_COVERAGE_OUT` names its file:
///
///   XDICT_NL_COVERAGE_OUT=dev-docs/measurements/…/coverage.tsv \
///   XDICT_APPLE_MANIFEST=~/xdict-corpus/apple/manifest.json \
///   swift test --filter NLTagCoverageTests
///
/// The manifest adds the Apple dictionaries' own languages; their availability is measured without a sample, because no
/// sentence is written for them here and dictionary content is never a fixture.
struct NLTagCoverageTests {
    static var output: String? { ProcessInfo.processInfo.environment["XDICT_NL_COVERAGE_OUT"] }

    /// The languages a reader of XDict's dictionaries most often meets, each with one simple sentence so a tag rate can be
    /// counted. Written for this measurement, never taken from a dictionary.
    static let samples: [(language: String, sentence: String)] = [
        ("en", "Please hold the door while I find the key."),
        ("zh-Hans", "请把门扶着，我去找钥匙。"),
        ("zh-Hant", "請把門扶著，我去找鑰匙。"),
        ("ja", "ドアを押さえていてください。"),
        ("ko", "문을 잡고 있어 주세요."),
        ("fr", "Tenez la porte, s'il vous plaît."),
        ("de", "Bitte halten Sie die Tür."),
        ("es", "Por favor, sujeta la puerta."),
        ("ru", "Пожалуйста, подержите дверь."),
        ("ar", "من فضلك أمسك الباب."),
        ("hi", "कृपया दरवाज़ा पकड़िए।"),
        ("th", "กรุณาจับประตูไว้"),
        ("he", "בבקשה תחזיק את הדלת."),
        ("tr", "Lütfen kapıyı tut."),
        ("pl", "Proszę przytrzymać drzwi."),
        ("vi", "Xin hãy giữ cửa."),
        ("id", "Tolong pegang pintunya."),
        ("pt", "Por favor, segure a porta."),
        ("it", "Per favore, tieni la porta."),
        ("nl", "Houd alsjeblieft de deur vast."),
    ]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["XDICT_NL_COVERAGE_OUT"] != nil))
    func theCoverageTable() throws {
        let path = try #require(Self.output, "XDICT_NL_COVERAGE_OUT names the table")
        var rows: [Row] = []
        for sample in Self.samples {
            rows.append(Self.measure(language: sample.language, sentence: sample.sentence, source: "sample"))
        }
        for language in Self.manifestLanguages() where !Self.samples.contains(where: { $0.language == language }) {
            rows.append(Self.measure(language: language, sentence: nil, source: "manifest"))
        }
        rows.sort { $0.language < $1.language }

        var lines = ["language\tsource\tschemes\ttokens\tclasses\tlemmas\tasset"]
        for row in rows {
            lines.append([row.language, row.source, row.schemes.joined(separator: ","),
                          row.tokens.map(String.init) ?? "", row.classes.map(String.init) ?? "",
                          row.lemmas.map(String.init) ?? "", row.asset].joined(separator: "\t"))
        }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        // **The measurement is the assertion**: a table with no sampled language would prove nothing.
        #expect(rows.contains { $0.tokens != nil }, "no language was sampled")
        print("nl-tag-coverage: \(rows.count) languages, \(rows.filter { $0.tokens != nil }.count) sampled, \(url.path)")
    }

    /// One language's row: its word schemes, and — with a sentence — how many tokens the tagger labels.
    struct Row {
        let language: String
        let source: String
        let schemes: [String]
        let tokens: Int?
        let classes: Int?
        let lemmas: Int?
        let asset: String
    }

    static func measure(language: String, sentence: String?, source: String) -> Row {
        let schemes = NLTagger.availableTagSchemes(for: .word, language: NLLanguage(rawValue: language))
            .map(\.rawValue)
        guard let sentence else {
            return Row(language: language, source: source, schemes: schemes, tokens: nil, classes: nil, lemmas: nil,
                       asset: "not-measured")
        }
        // **Assets may need downloading** (the framework's own `requestAssets` exists for that): ask, wait, and say in the
        // table whether the wait finished, so a first run that measured nothing is visible rather than silently zero.
        let asset = requestAssets(language: language)
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
        tagger.string = sentence
        var tokens = 0
        var classes = 0
        var lemmas = 0
        tagger.enumerateTags(in: sentence.startIndex..<sentence.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            tokens += 1
            if tag != nil { classes += 1 }
            if tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0 != nil { lemmas += 1 }
            return true
        }
        return Row(language: language, source: source, schemes: schemes, tokens: tokens, classes: classes,
                   lemmas: lemmas, asset: asset)
    }

    /// Waits for `.lexicalClass` and `.lemma` assets, bounded: an asset download that hangs must not hang the measurement.
    /// A timeout is recorded, not raised — the tagging below still runs, and a row that measured nothing shows why.
    static func requestAssets(language: String) -> String {
        let available = NLTagger.availableTagSchemes(for: .word, language: NLLanguage(rawValue: language))
        let needed = [NLTagScheme.lexicalClass, .lemma].filter(available.contains)
        guard !needed.isEmpty else { return "not-needed" }
        let group = DispatchGroup()
        for scheme in needed {
            group.enter()
            NLTagger.requestAssets(for: NLLanguage(rawValue: language), tagScheme: scheme) { _, _ in group.leave() }
        }
        return group.wait(timeout: .now() + 5) == .timedOut ? "timeout" : "requested"
    }

    /// The Apple dictionaries' index languages, when the local measurement set is named; never dictionary content.
    static func manifestLanguages() -> [String] {
        guard let path = ProcessInfo.processInfo.environment["XDICT_APPLE_MANIFEST"],
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let dictionaries = object["dictionaries"] as? [[String: Any]] else { return [] }
        var languages = Set<String>()
        for dictionary in dictionaries {
            for entry in dictionary["languages"] as? [[String: Any]] ?? [] {
                for key in ["DCSDictionaryIndexLanguage", "DCSDictionaryDescriptionLanguage"] {
                    if let tag = entry[key] as? String, !tag.isEmpty { languages.insert(tag) }
                }
            }
        }
        return languages.sorted()
    }
}
