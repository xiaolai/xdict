import AppKit
import ApplicationServices
import Foundation
import Testing
import XDictCapture
@testable import XDictCaptureMac

/// **Recorded recognitions, replayed through the production reading** (plan-capture WI-4). Each fixture in
/// `Fixtures/recognition/` is what the production recogniser's Vision path (`ScreenTextRecogniser.recognise` with
/// `recogniseWhole`, tiling included) read from an image of **synthetic text** the recorder below drew — never a screen
/// capture, never dictionary content — with the pointer and the answer the scenario expects. Replaying needs no screen and
/// no Vision: the recorded observations go through `reading`, the deterministic half, and must give that answer.
///
/// Recording is a development step on a build Mac (Vision runs there over ssh; no window, no grant):
/// `XDICT_RECORD_RECOGNITION=<dir> swift test --filter RecognitionRecorder`, then the files are copied here and read.
struct RecordedRecognitionTests {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/recognition")

    static func fixtures() throws -> [RecordedRecognition] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try JSONDecoder().decode(RecordedRecognition.self, from: Data(contentsOf: $0)) }
    }

    /// The premise: there are fixtures, each names its scenario, and each was recorded rather than written by hand.
    @Test func theFixturesAreThere() throws {
        let fixtures = try Self.fixtures()
        #expect(fixtures.count >= RecognitionScenario.all.count, "\(fixtures.count) fixtures read")
        #expect(Set(fixtures.map(\.name)) == Set(RecognitionScenario.all.map(\.name)))
        #expect(fixtures.allSatisfy { $0.recordedBy == RecordedRecognition.recorder && !$0.lines.isEmpty })
    }

    @Test(arguments: RecognitionScenario.all.map(\.name))
    func aRecordedRecognitionReadsAsItsScenarioSays(_ name: String) throws {
        let fixture = try #require(try Self.fixtures().first { $0.name == name }, "no fixture for \(name)")
        let read = try #require(fixture.replayed(), "\(name): nothing read at the pointer")
        #expect(read.word.word == fixture.expect.word, "\(name): read \(read.word.word)")
        if let sentence = fixture.expect.sentence {
            #expect(read.word.sentence.text == sentence, "\(name): sentence \(read.word.sentence.text)")
        }
        if let start = fixture.expect.startsWith {
            #expect(read.word.sentence.text.hasPrefix(start), "\(name): sentence \(read.word.sentence.text)")
        }
        if let end = fixture.expect.endsWith {
            #expect(read.word.sentence.text.hasSuffix(end), "\(name): sentence \(read.word.sentence.text)")
        }
        for absent in fixture.expect.excludes {
            #expect(!read.word.sentence.text.contains(absent), "\(name): the sentence holds \(absent)")
        }
        #expect(read.mayBeCut == fixture.expect.mayBeCut, "\(name): mayBeCut \(read.mayBeCut)")
        #expect(read.wantsMore.rawValue == fixture.expect.wantsMore, "\(name): wants \(read.wantsMore.rawValue)")
        #expect(read.mayBeCut == read.word.sentence.mayBeCut)
    }
}

/// One recorded recognition: the scenario, the observations Vision gave in the strip's normalised space (y down), and the
/// pointer and answer the scenario expects.
struct RecordedRecognition: Codable {
    static let recorder = "RecognitionRecorder (ScreenTextRecogniser.recognise + recogniseWhole), synthetic text"

    struct Run: Codable { let text: String; let utf16Offset: Int; let box: [Double] }
    struct Line: Codable { let text: String; let box: [Double]; let confidence: Double; let cutInside: Bool; let runs: [Run] }
    struct Expect: Codable {
        let word: String
        /// The whole sentence, where Vision read every character of it right; otherwise its ends.
        let sentence: String?
        let startsWith: String?
        let endsWith: String?
        let excludes: [String]
        let mayBeCut: Bool
        /// `StripSides`' raw value: 1 above, 2 below.
        let wantsMore: Int
    }

    let name: String
    let about: String
    let recordedBy: String
    /// The strip's size in points.
    let region: [Double]
    let lines: [Line]
    /// The word pointed at: the first run holding it, at the middle of its first occurrence there.
    let pointer: String
    let expect: Expect

    static func rect(_ box: [Double]) -> CGRect {
        box.count == 4 ? CGRect(x: box[0], y: box[1], width: box[2], height: box[3]) : .null
    }

    var recognised: [RecognisedLine] {
        lines.map { line in
            RecognisedLine(text: line.text, box: Self.rect(line.box), runs: line.runs.map {
                RecognisedRun(text: $0.text, utf16Offset: $0.utf16Offset, box: Self.rect($0.box))
            }, confidence: line.confidence, cutInside: line.cutInside)
        }
    }

    /// The production reading at the pointer.
    func replayed() -> Recognition? {
        let lines = recognised
        guard region.count == 2,
              let (line, run) = lines.enumerated().lazy.compactMap({ index, line in
                  line.runs.firstIndex { $0.text.contains(pointer) }.map { (index, $0) }
              }).first
        else { return nil }
        let target = lines[line].runs[run]
        let at = (target.text as NSString).range(of: pointer)
        let step = target.box.width / CGFloat(max(target.text.utf16.count, 1))
        let cursor = CGPoint(x: target.box.minX + (CGFloat(at.location) + CGFloat(at.length) / 2) * step, y: target.box.midY)
        return ScreenTextRecogniser.reading(
            lines, pick: RecognisedPick(line: line, run: run), at: cursor, region: CGSize(width: region[0], height: region[1]),
            appName: nil, bundleID: nil, limits: .shipped)
    }
}

/// **A picture of synthetic text, drawn at 2x, and what reading it should answer.** The text is this file's own.
struct RecognitionScenario: Sendable {
    struct Block: Sendable {
        let text: String
        let font: String
        let size: CGFloat
        /// Top-left of the block, in points, y down.
        let x: CGFloat
        let y: CGFloat
        /// Wrapped at this width, in points.
        let width: CGFloat
    }

    let name: String
    let about: String
    /// The strip's size in points.
    let size: CGSize
    let blocks: [Block]
    let pointer: String
    let expect: RecordedRecognition.Expect

    static let keeper = "The keeper of the northern light counted every ship that passed the rocks after dusk and wrote "
        + "each name into a ledger whose pages had gone soft with salt."
    static let market = "A different pane holds a different story about a market town whose clock ran fast."

    static let harbour = "The lamp burned until morning while the tide rose over the harbour wall and the gulls waited "
        + "on every roof for the fishing boats to come home before the storm."

    /// Every strip is the shipped first strip's height (300 pt), the row of text near its middle, as a hover reads one.
    static let all: [RecognitionScenario] = [
        RecognitionScenario(
            name: "terminal-path", about: "A terminal line wider than one tile (2800 px): a path read as one run, the pointer on its third segment.",
            size: CGSize(width: 1400, height: 300),
            blocks: [Block(text: "cd /Users/reader/projects/harbour-notes && make ledger-index", font: "Menlo", size: 14, x: 40,
                           y: 140, width: 1300)],
            pointer: "projects",
            expect: .init(word: "projects", sentence: "cd /Users/reader/projects/harbour-notes && make ledger-index",
                          startsWith: nil, endsWith: nil, excludes: [], mayBeCut: false, wantsMore: 0)),
        RecognitionScenario(
            name: "two-panes", about: "Two panes side by side; the sentence is the left pane's alone. Vision read the second row's 'after' as 'ter', moving that row's left edge by about a line height; the paragraph finder reads the move as a change of indentation and starts the paragraph there, not marked as cut (a recorded finding, not asserted here).",
            size: CGSize(width: 1336, height: 300),
            blocks: [Block(text: keeper, font: "Helvetica", size: 16, x: 40, y: 110, width: 520),
                     Block(text: market, font: "Helvetica", size: 16, x: 760, y: 110, width: 480)],
            pointer: "ledger",
            expect: .init(word: "ledger", sentence: nil, startsWith: nil, endsWith: "soft with salt.",
                          excludes: ["market", "clock"], mayBeCut: false, wantsMore: 0)),
        RecognitionScenario(
            name: "chinese-and-latin", about: "A Chinese sentence and a Latin one on one line; the pointer on the Latin word. Vision, detecting the line's language, read the Chinese half as Latin letters, as recorded.",
            size: CGSize(width: 900, height: 300),
            blocks: [Block(text: "今天的潮水很高。The tide was high tonight.", font: "PingFang SC", size: 20, x: 40, y: 135,
                           width: 820)],
            pointer: "tide",
            expect: .init(word: "tide", sentence: "The tide was high tonight.", startsWith: nil, endsWith: nil,
                          excludes: ["潮水"], mayBeCut: false, wantsMore: 0)),
        RecognitionScenario(
            name: "chinese", about: "A Chinese sentence alone; the pointer on a word inside it. Vision dropped one character (的), as recorded.",
            size: CGSize(width: 900, height: 300),
            blocks: [Block(text: "今天的潮水很高，渔船都回到了港口。", font: "PingFang SC", size: 20, x: 40, y: 135, width: 820)],
            pointer: "渔船",
            expect: .init(word: "渔船", sentence: nil, startsWith: "今天", endsWith: "回到了港口。", excludes: [], mayBeCut: false,
                          wantsMore: 0)),
        RecognitionScenario(
            name: "cut-below", about: "A paragraph whose second sentence runs past the strip's bottom edge: cut, and asking for more below.",
            size: CGSize(width: 900, height: 300),
            blocks: [Block(text: keeper + " " + harbour, font: "Helvetica", size: 16, x: 40, y: 205, width: 400)],
            pointer: "gulls",
            expect: .init(word: "gulls", sentence: nil, startsWith: "The lamp", endsWith: nil, excludes: ["keeper"],
                          mayBeCut: true, wantsMore: 2)),
    ]

    /// The scenario drawn at 2x, black on white.
    func image() throws -> CGImage {
        let scale: CGFloat = 2
        let width = Int(size.width * scale), height = Int(size.height * scale)
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        for block in blocks {
            let font = NSFont(name: block.font, size: block.size) ?? NSFont.systemFont(ofSize: block.size)
            let text = NSAttributedString(string: block.text, attributes: [.font: font, .foregroundColor: NSColor.black])
            // AppKit's origin is bottom-left: the block's top, y down, flipped.
            let bounds = text.boundingRect(with: NSSize(width: block.width, height: size.height), options: [.usesLineFragmentOrigin])
            text.draw(with: NSRect(x: block.x, y: size.height - block.y - bounds.height, width: block.width, height: bounds.height),
                      options: [.usesLineFragmentOrigin])
        }
        NSGraphicsContext.restoreGraphicsState()
        return try #require(rep.cgImage)
    }
}

/// **The recorder** — off unless `XDICT_RECORD_RECOGNITION` names a directory. It runs Vision, so it is a development step,
/// not a test: on a build Mac, never on the Air.
struct RecognitionRecorder {
    static let output = ProcessInfo.processInfo.environment["XDICT_RECORD_RECOGNITION"]

    @Test(.enabled(if: output != nil)) func recordEveryScenario() throws {
        let directory = try #require(Self.output.map(URL.init(fileURLWithPath:)))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        for scenario in RecognitionScenario.all {
            let lines = try ScreenTextRecogniser.recognise(try scenario.image(), limits: .shipped, slack: Measured.tiling) {
                try ScreenTextRecogniser.recogniseWhole($0)
            }
            func box(_ rect: CGRect) -> [Double] {
                [rect.minX, rect.minY, rect.width, rect.height].map { (Double($0) * 1_000_000).rounded() / 1_000_000 }
            }
            let recorded = RecordedRecognition(
                name: scenario.name, about: scenario.about, recordedBy: RecordedRecognition.recorder,
                region: [scenario.size.width, scenario.size.height],
                lines: lines.map { line in
                    .init(text: line.text, box: box(line.box), confidence: line.confidence, cutInside: line.cutInside,
                          runs: line.runs.map { .init(text: $0.text, utf16Offset: $0.utf16Offset, box: box($0.box)) })
                },
                pointer: scenario.pointer, expect: scenario.expect)
            try encoder.encode(recorded).write(to: directory.appending(path: "\(scenario.name).json"))
        }
    }
}
