import Foundation
import Testing
import XDictCapture

/// **Acquisition limits are capture's, applied before segmentation, and never cut the term** (ADR-0014 decision 3).
struct CaptureLimitsTests {
    private func limits(context: Int) throws -> CaptureLimits {
        try #require(CaptureLimits(readRadiusUTF16: 2000, contextUTF16: context, observations: 512, tilePixels: 2000,
                                   tileOverlapPixels: 600))
    }

    @Test func aLimitThatCannotBeAppliedIsRefused() {
        #expect(CaptureLimits(readRadiusUTF16: 0, contextUTF16: 1, observations: 1, tilePixels: 2, tileOverlapPixels: 1) == nil)
        #expect(CaptureLimits(readRadiusUTF16: 1, contextUTF16: 1, observations: 1, tilePixels: 600, tileOverlapPixels: 600)
                == nil, "a tile no wider than its overlap cannot tile")
        #expect(CaptureLimits.shipped.contextUTF16 == 1000)
        #expect(CaptureLimits.shipped.tilePixels > CaptureLimits.shipped.tileOverlapPixels)
    }

    @Test func textInsideTheLimitIsUntouched() throws {
        let text = "the ship's hold"
        let window = try #require(try limits(context: 100).window(of: text, around: NSRange(location: 11, length: 4)))
        #expect(window.text == text)
        #expect(window.range == NSRange(location: 11, length: 4))
    }

    @Test func longTextIsCutAroundTheTermAndTheRangeMoves() throws {
        let text = String(repeating: "x", count: 500) + "hold" + String(repeating: "y", count: 500)
        let window = try #require(try limits(context: 100).window(of: text, around: NSRange(location: 500, length: 4)))
        #expect(window.text.utf16.count <= 100)
        #expect((window.text as NSString).substring(with: window.range) == "hold")
    }

    @Test func theCutNeverSplitsASurrogatePair() throws {
        let text = String(repeating: "𠮷", count: 300) + "hold" + String(repeating: "𠮷", count: 300)
        let window = try #require(try limits(context: 101).window(of: text, around: NSRange(location: 600, length: 4)))
        #expect(!window.text.unicodeScalars.contains("\u{FFFD}"), "a half pair was decoded as a replacement")
        #expect((window.text as NSString).substring(with: window.range) == "hold")
    }

    /// **The start of the cut lands on a low surrogate and is moved past it**: 99 units around `hold` at 600 start at
    /// 553, the second half of a 𠮷.
    @Test func theStartOfTheCutNeverBeginsOnALowSurrogate() throws {
        let text = String(repeating: "𠮷", count: 300) + "hold" + String(repeating: "𠮷", count: 300)
        let window = try #require(try limits(context: 99).window(of: text, around: NSRange(location: 600, length: 4)))
        #expect(!window.text.unicodeScalars.contains("\u{FFFD}"), "the cut began on half a pair")
        #expect(window.text.utf16.count <= 99)
        #expect((window.text as NSString).substring(with: window.range) == "hold")
    }

    /// **Nor a combining sequence**: both ends of a 100-unit cut around the é at 600 land inside an é (an e and its
    /// combining acute, two units each, starting at even offsets) and are moved to whole characters.
    @Test func theCutNeverSplitsACombiningSequence() throws {
        let text = String(repeating: "e\u{301}", count: 600)
        let window = try #require(try limits(context: 100).window(of: text, around: NSRange(location: 600, length: 2)))
        #expect(window.text.utf16.count <= 100)
        #expect(window.text.allSatisfy { $0 == "e\u{301}" }, "a character was cut: \(window.text.unicodeScalars.first.map(\.value) ?? 0)")
        #expect(window.text.unicodeScalars.first == "e" && window.text.unicodeScalars.last == "\u{301}")
        #expect((window.text as NSString).substring(with: window.range) == "e\u{301}")
    }

    /// **A limit may tighten the ceiling, never loosen it**: the captured term refuses a longer sentence whatever a reader
    /// was handed.
    @Test func aContextLimitOverTheCeilingIsRefused() throws {
        #expect(CaptureLimits(readRadiusUTF16: 10, contextUTF16: CaptureLimits.contextCeilingUTF16 + 1, observations: 1,
                              tilePixels: 2, tileOverlapPixels: 1) == nil)
        #expect(try limits(context: CaptureLimits.contextCeilingUTF16).contextUTF16 == CaptureLimits.contextCeilingUTF16)
    }

    /// **A term longer than the limit is refused, not cut**: capture never truncates a key.
    @Test func aTermLongerThanTheLimitIsNotCut() throws {
        let term = String(repeating: "a", count: 201)
        #expect(try limits(context: 200).window(of: term, around: NSRange(location: 0, length: 201)) == nil)
        #expect(try limits(context: 200).window(of: "x", around: NSRange(location: NSNotFound, length: 1)) == nil)
    }
}

/// **Notices are typed; the consumer words them** (ADR-0014 decision 4).
struct CaptureNoticeTests {
    @Test func theNoticesAreKindsNotSentences() {
        #expect(Set(CaptureNotice.allCases) == [.screenRecordingNeeded, .captureStuck])
        #expect(CaptureNotice.captureStuck.rawValue == "captureStuck")
    }
}
