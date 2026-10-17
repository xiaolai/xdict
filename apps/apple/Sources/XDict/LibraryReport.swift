import Foundation
import XDictClient
import XDictContract
import XDictInstruments
import XDictLibrary
import XDictUI

/// `XDict --library-report <fixtures>`: a development instrument, for the E2E `library` stage (run on the E2E Mac only).
/// The library with generated packages (`LibraryScenario`) through this bundle's own signed service, then the sentences
/// the three refusals are shown with, read from this bundle's tables in English and in Simplified Chinese. Prints one
/// JSON object (`Findings`) and exits 0 when every check passed. Opens no window.
enum LibraryReport {
    static let flag = "--library-report"

    static func run(_ arguments: [String]) -> Never {
        Instrument.report {
            guard let fixtures = Instrument.value(after: flag, in: arguments).map(URL.init(fileURLWithPath:)) else {
                return Instrument.usage("\(flag) <fixtures>")
            }
            let scratch = FileManager.default.temporaryDirectory.appending(path: "xdict-library-report-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: scratch) }
            var findings = await LibraryScenario(client: ServiceClient(), fixtures: fixtures, scratch: scratch).run()
            findings.merge(sentences())
            return findings
        }
    }

    /// **Each finding the reader was told shows its sentence** (WI-12), from the bundle's own tables, in both languages
    /// and translated, with its count in it.
    static func healthSentences(_ told: [HealthFinding]) -> Findings {
        var findings = Findings()
        var bad: [String] = []
        for finding in told {
            var english = LibrarySentences.health(finding), chinese = english
            english.locale = Locale(identifier: "en")
            chinese.locale = Locale(identifier: "zh-Hans")
            let en = String(localized: english), zh = String(localized: chinese)
            let translated = zh != en && zh.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
            let counted = [en, zh].allSatisfy { text in
                text.filter(\.isNumber).contains(String(finding.count)) || text.contains(finding.count.formatted())
            }
            if en.isEmpty || !translated || !counted { bad.append("\(finding.kind.rawValue): en \(en) | zh-Hans \(zh)") }
        }
        findings.check("health.sentencesInBothLanguages", bad.isEmpty && !told.isEmpty,
                       bad.isEmpty ? "\(told.count) findings, each a sentence in English and Chinese" : "\(bad.prefix(3))")
        return findings
    }

    /// **Each refusal shows its sentence**: the one the library row and details show for it, from the bundle's own
    /// tables, present in both languages and translated (not the English key standing in).
    static func sentences() -> Findings {
        var findings = Findings()
        let shown: [(String, LocalizedStringResource)] = [
            ("sentence.resourceLibraryV3", LibrarySentences.note(.volumeUnreadable(fileName: "v3.mdd", reason: .resourceLibraryV3))),
            ("sentence.registrationCode", LibrarySentences.notice(.locked(fileName: "regcode.mdx"))),
            ("sentence.damaged", LibrarySentences.phase(.refused(.damaged))),
        ]
        for (name, resource) in shown {
            var english = resource, chinese = resource
            english.locale = Locale(identifier: "en")
            chinese.locale = Locale(identifier: "zh-Hans")
            let en = String(localized: english), zh = String(localized: chinese)
            let translated = zh != en && zh.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
            findings.check(name, !en.isEmpty && translated, "en: \(en) | zh-Hans: \(zh)")
        }
        return findings
    }
}

/// `XDict --library-corpus import <corpus> --library-dir <dir> --expected <editions.json>`, then `relaunch --library-dir
/// <dir> --moved-to <folder> [--no-relink]`, then `rewrite --library-dir <dir>`: the library with the owner's
/// dictionaries, one launch per phase (`LibraryCorpus`), for the E2E `library` stage. Prints `Findings` and exits 0 when
/// every check passed. Opens no window, and keeps its library in `<dir>`, never the reader's.
enum LibraryCorpusReport {
    static let flag = "--library-corpus"

    static func run(_ arguments: [String]) -> Never {
        Instrument.report {
            let usage = "\(flag) import <corpus> --library-dir <dir> --expected <json> | relaunch --library-dir <dir> "
                + "--moved-to <folder> [--no-relink] | rewrite --library-dir <dir> | health <corpus> --library-dir <dir> "
                + "--expected <health-expected.json>"
            guard let phase = Instrument.value(after: flag, in: arguments),
                  let directory = Instrument.value(after: "--library-dir", in: arguments).map(URL.init(fileURLWithPath:))
            else { return Instrument.usage(usage) }
            let corpus = LibraryCorpus(client: ServiceClient(), libraryDirectory: directory)
            switch phase {
            case "import":
                guard let folder = arguments.firstIndex(of: phase).flatMap({ arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }),
                      let expectedFile = Instrument.value(after: "--expected", in: arguments),
                      let data = FileManager.default.contents(atPath: expectedFile),
                      let expected = try? JSONDecoder().decode([String: String].self, from: data)
                else { return Instrument.usage(usage) }
                return await corpus.importing(URL(fileURLWithPath: folder), expected: expected)
            case "relaunch":
                guard let moved = Instrument.value(after: "--moved-to", in: arguments) else { return Instrument.usage(usage) }
                return await corpus.relaunch(movedTo: URL(fileURLWithPath: moved), relinking: !arguments.contains("--no-relink"))
            case "rewrite":
                return await corpus.rewrite()
            case "health":
                guard let folder = arguments.firstIndex(of: phase).flatMap({ arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }),
                      let expectedFile = Instrument.value(after: "--expected", in: arguments),
                      let data = FileManager.default.contents(atPath: expectedFile),
                      let expected = LibraryHealth.expected(data)
                else { return Instrument.usage(usage) }
                var (findings, told) = await LibraryHealth(client: ServiceClient(), libraryDirectory: directory)
                    .run(URL(fileURLWithPath: folder), expected: expected)
                findings.merge(LibraryReport.healthSentences(told))
                return findings
            default:
                return Instrument.usage(usage)
            }
        }
    }
}

/// What the app's instruments share: their arguments, and one JSON report on stdout with the exit status it earns.
enum Instrument {
    static func value(after option: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: option).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    }

    static func usage(_ text: String) -> Findings {
        var findings = Findings()
        findings.check("arguments", false, "usage: \(text)")
        return findings
    }

    /// Runs `body` on the main actor, held out of App Nap, prints its findings and exits: 0 when every check passed.
    static func report(_ body: @escaping @MainActor () async -> Findings) -> Never {
        Task { @MainActor in
            let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                                 reason: "an instrument of the E2E stages")
            let findings = await body()
            ProcessInfo.processInfo.endActivity(activity)
            emit(findings)
        }
        dispatchMain()
    }

    @MainActor
    static func emit(_ findings: Findings) -> Never {
        do {
            FileHandle.standardOutput.write(try findings.json() + Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("the report could not be encoded: \(error)\n".utf8))
            exit(1)
        }
        exit(findings.passed ? 0 : 1)
    }
}
