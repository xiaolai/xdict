import CoreGraphics
import Foundation
import XDictCapture

/// **What `--read-point` prints: the term as capture hands it to search** (ADR-0014 decision 2; after XiaolaiDict's
/// `PointReport`) — the dialect as the acquisition, the source app, the measured box (y down) or none, and the context's
/// outcome. One JSON line. A pending context is never reported: only the reading's end decides it, so the lab waits.
///
/// The sentence is printed. The lab is an instrument run on the E2E Mac against synthetic text, and never part of the
/// application whose sentence decision 9 keeps in memory; that it can print what is on the screen is why it never ships.
struct PointReport: Encodable, Equatable {
    let term: String
    /// `CaptureAcquisition`'s name: `textRange`, `textMarkers`, `boundsScan` or `recognition`.
    let acquisition: String
    let bundleID: String?
    let confidence: Double
    /// Where the word is, y down, and how well that is known; absent where the reading could not say.
    let bounds: Bounds?
    let context: Context
    let milliseconds: Int
    /// **The first reading, where the rest of its sentence was still being read**: what hover presents at once, when it
    /// arrived and how its context ended. Absent where the first reading was the whole one.
    var first: First?

    struct Bounds: Encodable, Equatable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        let quality: String
    }

    struct Context: Encodable, Equatable {
        /// `available` or `unavailable`.
        let state: String
        let sentence: String?
        /// The sentence's ends that are cuts in a longer text: `start`, `end`.
        let cut: [String]?
        let gap: String?
        /// Why there is none, where there is none.
        let reason: String?
    }

    struct First: Encodable, Equatable {
        let context: Context
        let milliseconds: Int
        /// `settled` (the rest was read) or `overdue` (not within the deadline: this reading stands).
        let end: String
    }

    enum Refusal: Error, Equatable {
        case pendingContext
    }

    init(_ term: CapturedTerm, milliseconds: Int) throws(Refusal) {
        self.term = term.term
        acquisition = term.acquisition.rawValue
        bundleID = term.source.bundleID
        confidence = term.confidence
        if case .measured(let read) = term.box {
            let rect = read.rect.cg
            bounds = Bounds(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height,
                            quality: read.quality.rawValue)
        } else {
            bounds = nil
        }
        context = try Context(term.context)
        self.milliseconds = milliseconds
    }

    func jsonLine() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

extension PointReport.Context {
    init(_ outcome: ContextOutcome) throws(PointReport.Refusal) {
        switch outcome {
        case .available(let sentence, _, let cut, let gap):
            let ends = [(CutEnds.start, "start"), (CutEnds.end, "end")].filter { cut.contains($0.0) }.map(\.1)
            self.init(state: "available", sentence: sentence, cut: ends.isEmpty ? nil : ends, gap: gap?.rawValue,
                      reason: nil)
        case .unavailable(let why):
            self.init(state: "unavailable", sentence: nil, cut: nil, gap: nil, reason: why.rawValue)
        case .pending:
            throw .pendingContext
        }
    }
}
