import AppKit
import Foundation
import XDictClient
import XDictContract
import XDictEntryView
import XDictInstruments
import XDictLibrary
import XDictSearch
import XDictSpeech
import XDictUI

/// `XDict --sound-report <fixtures> --library-dir <dir> --work <dir> --out <file> [--corpus <dir> --sample <json>]`: a
/// development instrument for the E2E `sound` stage (plan-macos-v1 WI-7, done-when; run on the E2E Mac only: it opens a
/// window and makes sounds, silently). **A production main window**, its sounds at volume 0 — decoded, started and run to their
/// end, unheard on the shared E2E Mac — and every link clicked in the page as a reader's click is, so it is routed by the
/// entry view, classified by the service's core and pronounced by the window:
///
/// - a `.tts` link speaks (none of the 25 writes one — measured over ~3,750 of their entries, 2026-10-15 — so the link
///   is put into a fixture's entry in the form the core rewrites `sound://hello world.tts` to, and clicked);
/// - the speak button speaks the entry's word; switching the accent changes the voice; a dictionary declared Chinese
///   speaks with a Chinese voice; every utterance also rendered into a buffer, so a voice that "spoke" nothing fails;
/// - the library's `sounds` fixture: a missing recording, a Speex one and one macOS cannot open each give their own
///   notice, in both languages, shown in the window, and are spoken instead;
/// - with the 25: sampled `sound://` links of every format they hold — mp3, WAV, Ogg Vorbis play to their end, labelled
///   as the dictionary's; Speex falls back to the voice with its notice; a recording a dictionary lacks says so.
///
/// The notice on screen is read through the Accessibility API by the stage, which holds the grant this app does not: the
/// instrument writes `<work>/checkpoint-<name>.json` (its pid) and waits for `checkpoint-<name>.ax.json` (`keys ax`).
/// Writes `Findings` to `--out`; every check is required by name by the stage.
enum SoundReport {
    static let flag = "--sound-report"

    @MainActor
    static func run(_ arguments: [String]) -> Never {
        let usage = "\(flag) <fixtures> --library-dir <dir> --work <dir> --out <file> [--corpus <dir> --sample <json>]"
        guard let fixtures = Instrument.value(after: flag, in: arguments).map(URL.init(fileURLWithPath:)),
              let directory = Instrument.value(after: "--library-dir", in: arguments).map(URL.init(fileURLWithPath:)),
              let work = Instrument.value(after: "--work", in: arguments).map(URL.init(fileURLWithPath:)),
              let out = Instrument.value(after: "--out", in: arguments).map(URL.init(fileURLWithPath:)) else {
            FileHandle.standardError.write(Data("usage: \(usage)\n".utf8))
            exit(2)
        }
        let corpus = Instrument.value(after: "--corpus", in: arguments).map(URL.init(fileURLWithPath:))
        var sample: [AppCorpusReport.Sampled] = []
        if let file = Instrument.value(after: "--sample", in: arguments) {
            guard let data = FileManager.default.contents(atPath: file),
                  let decoded = try? JSONDecoder().decode([AppCorpusReport.Sampled].self, from: data) else {
                FileHandle.standardError.write(Data("the sample \(file) could not be read\n".utf8))
                exit(2)
            }
            sample = decoded
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                                 reason: "an instrument of the E2E stages")
            let run = SoundRun(fixtures: fixtures.resolvingSymlinksInPath(), work: work,
                               corpus: corpus?.resolvingSymlinksInPath(), sample: sample)
            let findings = await run.run(libraryDirectory: directory)
            ProcessInfo.processInfo.endActivity(activity)
            do {
                try findings.json().write(to: out, options: .atomic)
            } catch {
                FileHandle.standardError.write(Data("the report could not be written: \(error)\n".utf8))
                exit(1)
            }
            exit(findings.passed ? 0 : 1)
        }
        app.run()
        exit(1)
    }
}

/// One run: the library, the window, and what its pronunciation did, with when.
@MainActor
final class SoundRun {
    let fixtures: URL
    let work: URL
    let corpus: URL?
    let sample: [AppCorpusReport.Sampled]
    private(set) var heard: [(time: ContinuousClock.Instant, event: PronunciationEvent)] = []
    private var findings = Findings()
    private let preferences = SpeechPreferences(defaults: UserDefaults(suiteName: InstrumentWindow.speechSuite) ?? .standard)

    init(fixtures: URL, work: URL, corpus: URL?, sample: [AppCorpusReport.Sampled]) {
        self.fixtures = fixtures
        self.work = work
        self.corpus = corpus
        self.sample = sample
    }

    func run(libraryDirectory: URL) async -> Findings {
        let client = ServiceClient()
        let tiny = fixtures.appending(path: "tiny/tiny.mdx")
        let sounds = fixtures.appending(path: "library/sounds")
        var adding = [tiny, sounds]
        let names = corpusNames()
        if let corpus { adding += names.map { corpus.appending(path: $0) } }
        let (library, settled) = await instrumentLibrary(libraryDirectory, client: client, adding: adding,
                                                         within: .seconds(3_600))
        let title = "sound"
        let window = InstrumentWindow(title, frame: NSRect(x: 120, y: 90, width: 900, height: 650), library: library,
                                      backend: client, suite: "ai.xdict.app.e2e.sound", opener: RecordingOpener(),
                                      speech: SystemOutput(volume: 0), speechPreferences: preferences)
        defer { window.close() }
        // The app's main window, so the stage's reading (`kAXMainWindowAttribute`) finds it.
        window.window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window.state.pronunciation.onEvent = { [weak self] event in self?.heard.append((.now, event)) }
        let tinySource = source(library, file: tiny)
        let soundsSource = source(library, file: sounds.appending(path: "sounds.mdx"))
        findings.check("sound.setup.library", settled && tinySource != nil && soundsSource != nil,
                       "settled \(settled); tiny \(tinySource != nil); sounds \(soundsSource != nil); "
                       + "\(library.entries.count) dictionaries")
        findings.fact("volume", "0")
        findings.fact("voices", "\(Voices.installed.count)")
        guard let tinySource, let soundsSource else { return findings }

        await speech(library: library, tiny: tinySource, window: window)
        await notices(sounds: soundsSource, window: window)
        if corpus != nil {
            await corpusSounds(library: library, client: client, names: names, window: window)
        }
        findings.merge(Self.sentences())
        return findings
    }

    // MARK: - The voice: a `.tts` link, the speak button, the accent, a Chinese dictionary

    private func speech(library: Library, tiny: SearchSource, window: InstrumentWindow) async {
        let state = window.state
        library.setLanguages(tiny.id, LanguagePair(search: "en", explanation: "en"))
        preferences.accent = .american
        let reached = await reach("run", in: tiny, by: window) != nil
        findings.check("sound.setup.entry", reached, "tiny's “run” shown in the window: \(reached)")
        guard reached else { return }

        // A `.tts` link, as the core rewrites `sound://hello world.tts`, clicked in the page.
        let tts = await clickNew("xdict://d/sound/hello%20world.tts", in: window)
        let routed = window.log.events.contains { if case .linkRouted(let url, "speak") = $0.event { url.contains("hello") } else { false } }
        let american = tts.utterance
        let ttsFrames = await frames(american)
        findings.check("sound.tts.speaks", routed && tts.finished && american?.text == "hello world"
                       && american?.language.hasPrefix("en-US") == true && (ttsFrames ?? 0) > 0,
                       "routed as speak \(routed); \(tts.describe); frames \(ttsFrames.map(String.init) ?? "none")")

        // The speak button: the entry's word, in the accent; then the other accent.
        let button = await awaitSpeech { state.pronounceShown() }
        preferences.accent = .british
        let british = await awaitSpeech { state.pronounceShown() }
        let britishFrames = await frames(british.utterance)
        findings.check("sound.speakButton.speaks", button.finished && button.utterance?.text == state.shownWord,
                       "word \(state.shownWord ?? "none"); \(button.describe)")
        findings.check("sound.accent.changesVoice",
                       button.utterance?.language == "en-US" && british.utterance?.language == "en-GB"
                       && button.utterance?.voiceIdentifier != british.utterance?.voiceIdentifier && british.finished
                       && (britishFrames ?? 0) > 0 && preferences.accent == .british,
                       "American: \(button.describe); British: \(british.describe); frames \(britishFrames ?? -1)")
        preferences.accent = .american

        // Declared Chinese by the reader: a `.tts` link of Chinese text speaks with a Chinese voice.
        library.setLanguages(tiny.id, LanguagePair(search: "zh-Hans", explanation: "en"))
        let chinese = await clickNew("xdict://d/sound/%E4%BD%A0%E5%A5%BD.tts", in: window)
        let chineseFrames = await frames(chinese.utterance)
        findings.check("sound.chinese.speaksChinese",
                       chinese.finished && chinese.utterance?.language.hasPrefix("zh") == true
                       && chinese.utterance?.text == "你好" && (chineseFrames ?? 0) > 0,
                       "\(chinese.describe); frames \(chineseFrames ?? -1)")
        library.setLanguages(tiny.id, LanguagePair(search: "en", explanation: "en"))
    }

    // MARK: - Missing, unsupported, undecodable: each its notice, shown, and spoken instead

    private func notices(sounds: SearchSource, window: InstrumentWindow) async {
        guard await reach("sounds", in: sounds, by: window) != nil else {
            findings.check("sound.notices.toldApart", false, "the sounds fixture's entry was not shown")
            return
        }
        var told: [String: Heard] = [:]
        for name in ["gone.mp3", "present.spx", "here.mp3"] {
            told[name] = await clickExisting(containing: name, in: window)
        }
        let gone = told["gone.mp3"], speex = told["present.spx"], broken = told["here.mp3"]
        let kinds = [gone?.notice, speex?.notice, broken?.notice]
        let expected: [Bool] = [
            { if case .fallback(.missing, .spoken)? = gone?.notice { true } else { false } }(),
            { if case .fallback(.unsupported(format: "spx"), .spoken)? = speex?.notice { true } else { false } }(),
            { if case .fallback(.undecodable(format: "mp3"), .spoken)? = broken?.notice { true } else { false } }(),
        ]
        let sentences = kinds.compactMap { $0.map { SpeechSentences.lines($0).map { String(localized: $0) }.joined(separator: " ") } }
        findings.check("sound.notices.toldApart", !expected.contains(false) && Set(sentences).count == 3,
                       told.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.describe)" }.joined(separator: "; "))
        findings.check("sound.fallback.speaks", [gone, speex, broken].allSatisfy { $0?.finished == true },
                       "each spoken to its end instead: \([gone, speex, broken].map { $0?.finished ?? false })")
        // The last notice, on screen: the window read through the Accessibility API, as VoiceOver reads it, by the
        // stage (`keys ax`), which holds the grant this app does not.
        let shown = await readAccessibility("notice")
        let expectedText = broken?.notice.map { SpeechSentences.lines($0).map { String(localized: $0) } } ?? []
        findings.check("sound.notices.shown", !expectedText.isEmpty && expectedText.allSatisfy { line in shown.contains { $0.contains(line) } },
                       "read under pronunciation-notice: \(shown.joined(separator: " | ").prefix(400)); expected: \(expectedText)")
    }

    // MARK: - The 25: every format they hold

    private func corpusNames() -> [String] {
        guard let corpus else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: corpus.path)) ?? []
        return names.filter { !$0.hasPrefix("_") && !$0.hasPrefix(".") }
            .filter { (try? corpus.appending(path: $0).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted()
    }

    private func corpusSounds(library: Library, client: ServiceClient, names: [String], window: InstrumentWindow) async {
        let run = AppCorpusRun(library: library, client: client, corpus: corpus ?? fixtures)
        let byDict = Dictionary(grouping: sample, by: \.dict)
        var clicks: [[String: String]] = []
        var seen: [String: Int] = [:]
        var failures: [String] = []
        for name in names {
            guard let source = run.source(name), let handle = source.handle, let edition = source.edition else {
                failures.append("\(name): not answering")
                continue
            }
            // Entries with recordings, found by asking the service for sampled entries (fast), two per format.
            var chosen: [(AppCorpusReport.Sampled, String)] = []
            var perFormat: [String: Int] = [:]
            for entry in byDict[name] ?? [] where chosen.count < 8 {
                let reference = EntryRef(edition: edition, key: entry.key, occurrence: entry.occurrence)
                let asked = await client.request(.entry(dict: handle, entry: reference, render: .reader))
                guard case .success(let delivered) = asked, let html = delivered.payload else { continue }
                let formats = Set(Self.soundRoutes(in: String(decoding: html, as: UTF8.self)).map(Self.format))
                for format in formats.sorted() where perFormat[format, default: 0] < 2 {
                    perFormat[format, default: 0] += 1
                    chosen.append((entry, format))
                }
            }
            for (entry, format) in chosen {
                guard await run.reach(entry.key, occurrence: entry.occurrence, in: source, by: window) != nil else {
                    failures.append("\(name) \(entry.key): not shown")
                    continue
                }
                for href in await links(in: window).filter({ Self.format($0) == format }).prefix(2) {
                    let heard = await clickExisting(href: href, in: window)
                    seen[format, default: 0] += 1
                    clicks.append(["dict": name, "format": format, "href": String(href.prefix(160)), "heard": heard.describe,
                                   "verdict": heard.verdict(format: format)])
                }
            }
        }
        let byVerdict = Dictionary(grouping: clicks, by: { $0["verdict"] ?? "" })
        let tally = byVerdict.mapValues(\.count).sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
        findings.fact("corpus.clicks", "\(clicks.count): \(tally.joined(separator: ", "))")
        findings.fact("corpus.formats", seen.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        findings.fact("corpus.samples", clicks.prefix(80).map { "\($0["dict"] ?? "") \($0["format"] ?? ""): \($0["verdict"] ?? "")" }
                      .joined(separator: "; "))
        let formats = Set(clicks.compactMap { $0["format"] })
        findings.check("sound.corpus.formatsSeen", ["mp3", "wav", "ogg", "spx"].allSatisfy(formats.contains),
                       "formats clicked: \(formats.sorted()); \(failures.prefix(6))")
        let playable = clicks.filter { ["mp3", "wav", "ogg"].contains($0["format"] ?? "") }
        let played = playable.filter { $0["verdict"] == "played" }
        let lacking = playable.filter { $0["verdict"] == "missing" }
        let wrong = playable.filter { $0["verdict"] != "played" && $0["verdict"] != "missing" }
        findings.check("sound.corpus.playablePlay",
                       !played.isEmpty && wrong.isEmpty
                       && ["mp3", "wav", "ogg"].allSatisfy { format in played.contains { $0["format"] == format } },
                       "\(played.count) played to their end, \(lacking.count) the dictionary lacks "
                       + "(\(Set(lacking.compactMap { $0["dict"] }).sorted())); wrong: \(wrong.prefix(4))")
        let speex = clicks.filter { $0["format"] == "spx" }
        let speexWrong = speex.filter { $0["verdict"] != "spokenInstead" }
        findings.check("sound.corpus.speexFallsBack", !speex.isEmpty && speexWrong.isEmpty,
                       "\(speex.count) Speex clicks in \(Set(speex.compactMap { $0["dict"] }).sorted()); wrong: \(speexWrong.prefix(4))")
        let unanswered = clicks.filter { $0["verdict"] == "unanswered" }
        findings.check("sound.corpus.everyClickAnswered", !clicks.isEmpty && unanswered.isEmpty && failures.isEmpty,
                       "\(clicks.count) clicks, \(unanswered.count) with no answer; \(failures.prefix(6))")
    }

    // MARK: - Clicking, and hearing what followed

    /// What one click led to: the notice, what played, what was said, and whether it ran to its end.
    struct Heard {
        var notice: PronunciationNotice?
        var playback: Playback?
        var utterance: Utterance?
        var finished = false

        var describe: String {
            let notice = notice.map { "\($0)" } ?? "no notice"
            let playback = playback.map { "played \(String(format: "%.2f", $0.duration)) s \($0.format) playing \($0.isPlaying)" }
            let said = utterance.map { "said “\($0.text)” by \($0.voiceName) \($0.language) [\($0.voiceIdentifier)]" }
            return ([notice] + [playback, said].compactMap { $0 } + ["to the end \(finished)"]).joined(separator: ", ")
        }

        /// The click's verdict, as the checks count it.
        func verdict(format: String) -> String {
            switch notice {
            case .recording?: playback.map { $0.isPlaying && $0.duration > 0 && finished } == true ? "played" : "notToTheEnd"
            case .fallback(.unsupported, .spoken)?: finished ? "spokenInstead" : "notSpoken"
            case .fallback(.missing, _)?: "missing"
            case .fallback(.undecodable, _)?: "undecodable"
            case .fallback(.notStarted, _)?: "notStarted"
            case .fallback(.unavailable, _)?: "unavailable"
            case .fallback, .speech: "other"
            case nil: "unanswered"
            }
        }
    }

    /// Clicks a new link put at the end of the entry, as a reader's click is routed.
    private func clickNew(_ href: String, in window: InstrumentWindow) async -> Heard {
        await awaitSound {
            _ = await InstrumentPage.evaluate(window.state.entry.webView, """
                var a = document.createElement('a'); a.href = href; a.textContent = 'say'; document.body.appendChild(a);
                a.click(); return a.getAttribute('href');
                """, ["href": href])
        }
    }

    /// Clicks the entry's own recording link whose `href` contains `fragment`.
    private func clickExisting(containing fragment: String, in window: InstrumentWindow) async -> Heard {
        guard let href = await links(in: window).first(where: { $0.contains(fragment) }) else { return Heard() }
        return await clickExisting(href: href, in: window)
    }

    private func clickExisting(href: String, in window: InstrumentWindow) async -> Heard {
        await awaitSound {
            _ = await InstrumentPage.evaluate(window.state.entry.webView, """
                var a = Array.from(document.querySelectorAll('a')).find(function (e) { return e.getAttribute('href') === href; });
                if (a) a.click(); return !!a;
                """, ["href": href])
        }
    }

    /// The entry's own recording links, as written in its page.
    private func links(in window: InstrumentWindow) async -> [String] {
        await InstrumentPage.evaluate(window.state.entry.webView, """
            return Array.from(document.querySelectorAll('a')).map(function (e) { return e.getAttribute('href') || ''; })
              .filter(function (h) { return h.indexOf('xdict://d/sound/') === 0; });
            """) as? [String] ?? []
    }

    private func awaitSpeech(_ act: () -> Void) async -> Heard {
        await awaitSound { act() }
    }

    /// Does `act`, then waits for the notice it leads to and for its sound to end: a recording within its length and
    /// ten seconds more, speech within twenty.
    private func awaitSound(_ act: () async -> Void) async -> Heard {
        let from = heard.count
        await act()
        var result = Heard()
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            result = Heard()
            for (_, event) in heard.dropFirst(from) {
                switch event {
                case .notice(let notice): result.notice = notice
                case .output(.playbackStarted(let playback)): result.playback = playback
                case .output(.playbackEnded(let finished)): result.finished = finished
                case .output(.speechStarted(let utterance)): result.utterance = utterance
                case .output(.speechEnded(let utterance, let finished)):
                    result.utterance = utterance
                    result.finished = finished
                }
            }
            if result.notice != nil, result.finished || Self.silent(result.notice) { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return result
    }

    /// A notice after which nothing sounds, so there is no end to wait for.
    private static func silent(_ notice: PronunciationNotice?) -> Bool {
        switch notice {
        case .speech(.spoken)?, .recording?, .fallback(_, .spoken)?, nil: false
        default: true
        }
    }

    /// Asks the stage to read the window now, and waits up to 15 s for its reading: the texts under the element the
    /// notice is (`pronunciation-notice`), or none.
    private func readAccessibility(_ name: String) async -> [String] {
        let ask = work.appending(path: "checkpoint-\(name).json")
        let answer = work.appending(path: "checkpoint-\(name).ax.json")
        try? JSONSerialization.data(withJSONObject: ["pid": Int(getpid())]).write(to: ask, options: .atomic)
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if let data = try? Data(contentsOf: answer),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let nodes = object["nodes"] as? [[String: Any]] {
                return Self.texts(under: "pronunciation-notice", in: nodes)
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return []
    }

    /// The texts of the element `identifier` names and of everything under it, in `keys ax`'s list (reading order, with
    /// depths).
    static func texts(under identifier: String, in nodes: [[String: Any]]) -> [String] {
        guard let start = nodes.firstIndex(where: { $0["id"] as? String == identifier }),
              let depth = nodes[start]["depth"] as? Int else { return [] }
        var out: [String] = []
        for (index, node) in nodes[start...].enumerated() {
            if index > 0, (node["depth"] as? Int ?? 0) <= depth { break }
            out += node["texts"] as? [String] ?? []
        }
        return out
    }

    private func frames(_ utterance: Utterance?) async -> Int? {
        guard let utterance else { return nil }
        return await SystemOutput.renderedFrames(of: utterance.text, voiceIdentifier: utterance.voiceIdentifier)
    }

    private func reach(_ key: String, in source: SearchSource, by window: InstrumentWindow) async -> SearchModel.Shown? {
        let model = window.state.model
        model.follow(key, anchor: nil, from: source.id)
        await model.idle()
        await model.answersSettled()
        guard model.lookup?.query == key, model.selection != nil else { return nil }
        return await window.shownAndLoaded(within: .seconds(20))
    }

    private func source(_ library: Library, file: URL) -> SearchSource? {
        let path = file.resolvingSymlinksInPath().path
        guard let entry = library.entries.first(where: { $0.mdx?.location.path == path }) else { return nil }
        return library.searchSources.first { $0.id == entry.id && $0.handle != nil }
    }

    // MARK: - Reading

    static func soundRoutes(in html: String) -> [String] {
        var out: [String] = []
        var rest = html[...]
        while let range = rest.range(of: "xdict://d/sound/") {
            let tail = rest[range.lowerBound...]
            let end = tail.firstIndex { "\"' <>\n)".contains($0) } ?? tail.endIndex
            out.append(String(tail[..<end]))
            rest = tail[end...]
        }
        return out
    }

    /// A recording link's format: its extension, lower-cased.
    static func format(_ href: String) -> String {
        let name = href.split(separator: "/").last.map(String.init) ?? href
        guard let dot = name.lastIndex(of: ".") else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    /// **The notices in both languages**: from this bundle's tables, each translated, missing and unsupported apart.
    static func sentences() -> Findings {
        var findings = Findings()
        let notices: [(String, PronunciationNotice)] = [
            ("missing", .fallback(.missing(path: "gone.mp3"), .spoken(voice: "Samantha", language: "en-US"))),
            ("unsupported", .fallback(.unsupported(format: "spx"), .spoken(voice: "Samantha", language: "en-US"))),
            ("undecodable", .fallback(.undecodable(format: "mp3"), .spoken(voice: "Samantha", language: "en-US"))),
            ("notStarted", .fallback(.notStarted(format: "ogg"), .spoken(voice: "Samantha", language: "en-US"))),
            ("recording", .recording(format: "mp3")),
        ]
        var english: [String] = [], chinese: [String] = []
        for (_, notice) in notices {
            let lines = SpeechSentences.lines(notice)
            english.append(lines.map { var line = $0; line.locale = Locale(identifier: "en"); return String(localized: line) }
                .joined(separator: " "))
            chinese.append(lines.map { var line = $0; line.locale = Locale(identifier: "zh-Hans"); return String(localized: line) }
                .joined(separator: " "))
        }
        let translated = zip(english, chinese).allSatisfy { en, zh in
            zh != en && zh.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        }
        findings.check("sound.sentences.bothLanguages",
                       translated && Set(english).count == notices.count && Set(chinese).count == notices.count,
                       zip(english, chinese).map { "en: \($0) | zh-Hans: \($1)" }.joined(separator: " || "))
        return findings
    }
}
