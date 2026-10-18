import ApplicationServices
import Foundation
import Testing
import XDictCapture
@testable import XDictCaptureMac

/// **The recogniser reads within capture's acquisition limits** (ADR-0014 decision 3; carried from WI-1's verification):
/// the tiles are `CaptureLimits.tilePixels` wide, overlapping by `tileOverlapPixels`, and at most `observations`
/// observations are taken from one capture, applied before any line is joined. Each is shown with limits other than the
/// shipped ones, so a recogniser that kept constants of its own fails.
struct RecognitionLimitTests {
    private static func band(width: Int, height: Int = 200) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        return try #require(context.makeImage())
    }

    private static func line(_ text: String, y: CGFloat) -> RecognisedLine {
        let box = CGRect(x: 0.4, y: y, width: 0.2, height: 0.01)
        return RecognisedLine(text: text, box: box, runs: [RecognisedRun(text: text, utf16Offset: 0, box: box)])
    }

    /// **The tile limits are the limits handed in**: 1000 px tiles overlapping by 300 over a 2500 px band are the plan
    /// `BandTiling` makes for those numbers, not for 2000 and 600.
    @Test func theTilesAreTheLimitsHandedIn() throws {
        let limits = try #require(CaptureLimits(
            readRadiusUTF16: 10, contextUTF16: 10, observations: 100, tilePixels: 1000, tileOverlapPixels: 300))
        var widths: [Int] = []
        _ = try ScreenTextRecogniser.recognise(try Self.band(width: 2500), limits: limits, slack: Measured.tiling) { tile in
            widths.append(tile.width)
            return []
        }
        #expect(widths == BandTiling.tiles(forWidth: 2500, maximum: 1000, overlap: 300).map(\.width))
        #expect(widths.count == 4, "read in \(widths.count) tiles")
    }

    /// **At most `observations` from one capture**: a band that fits one tile and reads more is cut to the limit, keeping
    /// the first ones Vision gave, before anything is joined.
    @Test func noMoreObservationsThanTheLimitAreTaken() throws {
        let limits = try #require(CaptureLimits(
            readRadiusUTF16: 10, contextUTF16: 10, observations: 3, tilePixels: 2000, tileOverlapPixels: 600))
        let read = (0..<10).map { Self.line("w\($0)", y: CGFloat($0) * 0.05) }
        let lines = try ScreenTextRecogniser.recognise(try Self.band(width: 800), limits: limits, slack: Measured.tiling) { _ in
            read
        }
        #expect(lines.map(\.text) == ["w0", "w1", "w2"])
    }

    /// **Across tiles the limit is one budget**: once it is spent no further tile is read at all.
    @Test func aSpentLimitReadsNoFurtherTile() throws {
        let limits = try #require(CaptureLimits(
            readRadiusUTF16: 10, contextUTF16: 10, observations: 5, tilePixels: 1000, tileOverlapPixels: 300))
        var calls = 0
        let lines = try ScreenTextRecogniser.recognise(try Self.band(width: 2500), limits: limits, slack: Measured.tiling) { _ in
            calls += 1
            return (0..<4).map { Self.line("t\(calls)w\($0)", y: CGFloat($0) * 0.05) }
        }
        #expect(calls == 2, "\(calls) tiles were read for a limit of five observations")
        #expect(lines.flatMap(\.runs).count <= 5)
    }

    /// **The context limit reaches the reading**: a sentence longer than `contextUTF16` is never assembled whole.
    @Test func theContextLimitIsAppliedBeforeTheSentence() throws {
        let words = (0..<40).map { "word\($0)" }
        let rows = stride(from: 0, to: words.count, by: 5).map { words[$0..<min($0 + 5, words.count)].joined(separator: " ") }
        let lines = rows.enumerated().map { index, text -> RecognisedLine in
            let box = CGRect(x: 0.1, y: 0.1 + CGFloat(index) * 0.06, width: 0.5, height: 0.04)
            return RecognisedLine(text: text, box: box, runs: [RecognisedRun(text: text, utf16Offset: 0, box: box)])
        }
        let small = try #require(CaptureLimits(
            readRadiusUTF16: 10, contextUTF16: 60, observations: 100, tilePixels: 2000, tileOverlapPixels: 600))
        let pick = RecognisedPick(line: 3, run: 0)
        let cursor = CGPoint(x: lines[3].box.minX, y: lines[3].box.midY)
        let read = try #require(ScreenTextRecogniser.reading(
            lines, pick: pick, at: cursor, region: CGSize(width: 1000, height: 300), appName: nil, bundleID: nil,
            limits: small))
        #expect(read.word.sentence.text.utf16.count <= 60, "\(read.word.sentence.text.utf16.count) units joined")
        let whole = try #require(ScreenTextRecogniser.reading(
            lines, pick: pick, at: cursor, region: CGSize(width: 1000, height: 300), appName: nil, bundleID: nil,
            limits: .shipped))
        #expect(whole.word.sentence.text.utf16.count > 60, "the control: the shipped limit joins the whole paragraph")
    }
}

/// **What the recogniser hands over** (decision 2): acquisition `recognition`, Vision's confidence, the run's box as
/// `containing`, and the sentence's internal gap kept apart from its cut ends.
struct RecognitionTermTests {
    private static func recognition(gap: InternalGap?, cut: TextSegmenter.Clipping, confidence: Double = 0.4) throws -> Recognition {
        let text = "The tide was high."
        let sentence = try #require(SentenceContext(
            text: text, mayBeCut: !cut.isEmpty || gap != nil, selection: NSRange(location: 4, length: 4), cut: cut))
        return Recognition(word: WordAtPoint(word: "tide", sentence: sentence), confidence: confidence,
                           mayBeCut: sentence.mayBeCut, appName: "Ghostty", bundleID: "com.mitchellh.ghostty", gap: gap,
                           bounds: ReadBounds(rect: DownRect(x: 10, y: 20, width: 30, height: 12), quality: .containing))
    }

    @Test func theTermIsARecognitionWithItsOwnConfidenceAndBox() throws {
        let term = try Self.recognition(gap: nil, cut: []).capturedTerm(pointer: nil)
        #expect(term.term == "tide")
        #expect(term.acquisition == .recognition)
        #expect(term.trigger == .pointerGesture)
        #expect(term.confidence == 0.4)
        #expect(term.box == .measured(ReadBounds(rect: DownRect(x: 10, y: 20, width: 30, height: 12), quality: .containing)))
        #expect(term.source.bundleID == "com.mitchellh.ghostty")
        #expect(term.context == .available(sentence: "The tide was high.", term: NSRange(location: 4, length: 4), cut: [],
                                           gap: nil))
    }

    /// The gap is not an end: a sentence cut inside keeps its ends whole and says where text is missing.
    @Test func anInternalGapIsKeptApartFromTheEnds() throws {
        let term = try Self.recognition(gap: .joinedAcrossTiles, cut: [.end]).capturedTerm(pointer: nil)
        #expect(term.context == .available(sentence: "The tide was high.", term: NSRange(location: 4, length: 4),
                                           cut: [.end], gap: .joinedAcrossTiles))
    }

    /// Still being read: the term carries the handle, and nothing of the first reading travels in it.
    @Test func aPendingContextTravelsAsItsHandle() throws {
        let term = try Self.recognition(gap: nil, cut: [.end]).capturedTerm(
            pointer: nil, context: .pending(PendingContextHandle(id: 4)))
        #expect(term.context == .pending(PendingContextHandle(id: 4)))
    }

    /// **Metadata only**: a recognition's descriptions never carry its sentence.
    @Test func noDescriptionOfARecognitionCarriesItsSentence() throws {
        let read = try Self.recognition(gap: nil, cut: [])
        var dumped = ""
        dump(read, to: &dumped)
        for text in [String(describing: read), String(reflecting: read), dumped] {
            #expect(!text.contains("tide") && !text.contains("high"), "a recognition described its sentence: \(text)")
        }
    }
}
