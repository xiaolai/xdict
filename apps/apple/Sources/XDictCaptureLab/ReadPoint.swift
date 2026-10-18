import CoreGraphics
import XDictCapture
import XDictCaptureMac

/// **`--read-point`: the word under one screen point, through hover's own reader** (ported from XiaolaiDict's
/// `LookupCommand.readPoint`, plan-capture WI-4). The shipped policy with its key held and the pointer at rest, so the
/// path is the shipped hold: Accessibility first, the pixels where it found no word, the site and app checks, the one
/// capture. A recognised word waits for the rest of its sentence, and the report says what was read first.
///
/// **Screen Recording is never asked for here.** The recogniser touches ScreenCaptureKit only where macOS already reports
/// a grant (ADR-0014 decision 7); without one the lab says where the grant is given and fails. The lab's grants are its
/// own, by its own signature: it borrows none of XDict.app's.
enum ReadPoint {
    /// **Generous on purpose: this is the instrument, not the product.** The shipped deadline protects a reader from a
    /// wedged capture; here it would only hide how long the path takes (XiaolaiDict reported "deadline exceeded" for a
    /// read seconds from finishing).
    static let captureDeadline: Duration = .seconds(30)

    struct Failure: Error, Equatable {
        let message: String
    }

    static let screenRecordingNeeded = "nothing read: only the pixels could answer, and XDictCaptureLab has no Screen "
        + "Recording grant. Allow it in System Settings > Privacy & Security > Screen & System Audio Recording."

    @MainActor
    static func run(at point: CGPoint, source: any PointerWordSource, policy: HoverPolicy = .shipped) async
        -> Result<PointReport, Failure> {
        let started = ContinuousClock.now
        func elapsed() -> Int { Int((ContinuousClock.now - started) / .milliseconds(1)) }
        let reader = HoverReader(policy: { policy }, source: source, contexts: PendingContexts(),
                                 captureDeadline: captureDeadline)
        let outcome = await reader.read(
            at: point, modifiersHeld: [policy.modifier], tappedTwice: false, pointerStillFor: .seconds(1),
            begin: { CaptureRequest(number: 1, trigger: .pointerGesture) })
        let pointer = PointerSample(point: DownPoint(point), at: nil)
        do {
            switch outcome {
            case .word(let hit, _, _):
                return .success(try PointReport(try hit.capturedTerm(pointer: pointer), milliseconds: elapsed()))
            case .recognised(let recognition, _, _, nil):
                return .success(try PointReport(try recognition.capturedTerm(pointer: pointer), milliseconds: elapsed()))
            case .recognised(let recognition, _, _, let context?):
                let firstAt = elapsed()
                let (settled, end): (ContextOutcome, String)
                switch await ended(context) {
                case .settled(let outcome): (settled, end) = (outcome, "settled")
                case .overdue(let outcome): (settled, end) = (outcome, "overdue")
                case .cancelled: return .failure(Failure(message: "nothing read: the sentence's reading was cancelled"))
                }
                var report = try PointReport(try recognition.capturedTerm(pointer: pointer, context: settled),
                                             milliseconds: elapsed())
                report.first = PointReport.First(context: try PointReport.Context(recognition.context),
                                                 milliseconds: firstAt, end: end)
                return .success(report)
            case .quiet(let refusal):
                return .failure(Failure(message: "nothing read: hover stayed quiet (\(refusal.rawValue))"))
            case .nothing(let why):
                return .failure(Failure(message: "nothing read: \(why)"))
            case .needsScreenRecording:
                return .failure(Failure(message: screenRecordingNeeded))
            }
        } catch {
            return .failure(Failure(message: "nothing read: the reading is not a valid term (\(error))"))
        }
    }

    /// How a pending context ended — at once where it already has.
    static func ended(_ context: PendingContext) async -> PendingContextEnd {
        await withCheckedContinuation { continuation in context.onEnd { continuation.resume(returning: $0) } }
    }
}
