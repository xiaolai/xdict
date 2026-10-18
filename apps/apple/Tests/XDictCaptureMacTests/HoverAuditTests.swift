import ApplicationServices
import Foundation
import Testing
import XDictCapture
@testable import XDictCaptureMac

/// **What XiaolaiDict's audit found and fixed in the two functions that moved here** (moved by name from XiaolaiDict's
/// `HoverAuditTests` at `044dac6`; capture-migration manifest §7.1): the whole-word match the pointer read re-segments by,
/// and the frame check that keeps a capture from cropping where a window used to be. Re-checked against MDX-first: both
/// read the screen only, nothing of a dictionary.
struct HoverAuditTests {
    /// A plain substring search took the first *occurrence*: hovering "he" in "there he stood" found it inside "there"
    /// and re-segmented to the wrong word.
    @Test func awholeWordMatchDoesNotHitInsideAnotherWord() throws {
        let sentence = "there he stood"
        let range = try #require(PointerWordReader.wholeWordRange(of: "he", in: sentence))
        #expect(range.location == 6, "matched inside 'there' at \(range.location)")
        #expect((sentence as NSString).substring(with: range) == "he")
    }

    @Test func awordThatIsNotThereAsAWholeWordIsNotFound() {
        #expect(PointerWordReader.wholeWordRange(of: "he", in: "therefore thereafter") == nil)
    }

    @Test func thefirstWholeWordOccurrenceIsTaken() throws {
        let range = try #require(PointerWordReader.wholeWordRange(of: "the", in: "the cat and the dog"))
        #expect(range.location == 0)
    }

    /// A window moved inside the three-second content cache would crop where it used to be. XDict hands the tolerance in
    /// (`CaptureMetrics.frameDrift`, from the tokens; 1 pt in the measured metrics), where XiaolaiDict had it built in.
    @Test func amovedWindowIsNotTreatedAsTheSameGeometry() {
        let screen = SystemScreenCapturer(frameDrift: Measured.metrics.frameDrift)
        let was = CGRect(x: 100, y: 100, width: 800, height: 600)
        #expect(screen.sameGeometry(was, was))
        // Sub-point rounding between the two APIs is not a move.
        #expect(screen.sameGeometry(was, CGRect(x: 100.4, y: 100, width: 800, height: 600)))
        #expect(!screen.sameGeometry(was, CGRect(x: 140, y: 100, width: 800, height: 600)))
        #expect(!screen.sameGeometry(was, CGRect(x: 100, y: 100, width: 640, height: 600)))
    }
}
