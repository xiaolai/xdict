import CoreGraphics
import Foundation
import Testing
import XDictAnywhere
import XDictCapture
import XDictTokens

/// **The scripts hover may look up, derived from the enabled dictionaries' search languages** (plan-capture WI-3;
/// ADR-0014 d.10: capture's own filter, handed in by the consumer, never a stored study setting).
struct HoverScriptsTests {
    @Test func eachLanguageGivesTheScriptItIsWrittenIn() {
        #expect(HoverScripts.allowed(searchLanguages: ["en"]) == [.latin])
        #expect(HoverScripts.allowed(searchLanguages: ["zh-Hans"]) == [.han])
        #expect(HoverScripts.allowed(searchLanguages: ["zh"]) == [.han])
        #expect(HoverScripts.allowed(searchLanguages: ["ja"]) == [.han, .kana])
        #expect(HoverScripts.allowed(searchLanguages: ["ko"]) == [.hangul])
        #expect(HoverScripts.allowed(searchLanguages: ["en", "fr", "zh-Hant"]) == [.latin, .han])
    }

    /// **Filtering nothing is the safe answer whenever a dictionary could hold any script**: a dictionary whose search
    /// language is not known, a language that cannot be read, or no dictionary at all. Refusing there would make the filter
    /// quietly wider than any dictionary asked for.
    @Test func anUnknownLanguageFiltersNothing() {
        #expect(HoverScripts.allowed(searchLanguages: ["en", nil]) == nil)
        #expect(HoverScripts.allowed(searchLanguages: ["en", "not a language tag"]) == nil)
        #expect(HoverScripts.allowed(searchLanguages: []) == nil)
    }

    /// A language written in a script capture cannot name (Cyrillic) adds nothing to the set: such words carry no
    /// script `CaptureScript` knows, so `HoverPolicy.allows` admits them whatever the set.
    @Test func aScriptCaptureCannotNameAddsNothing() {
        #expect(HoverScripts.allowed(searchLanguages: ["en", "ru"]) == [.latin])
        #expect(HoverScripts.allowed(searchLanguages: ["ru"]) == nil, "an empty set must filter nothing, and say so")
    }
}

/// **The one terminal acknowledgement each presented request is owed, from what the popover did** (ADR-0014 d.4):
/// "shown" is the consumer's, and neither the invisible anchor window nor `popover.isShown` alone is a draw of the new
/// content. Shown is the popover up **and** the presented term's own entry finished, or its lookup settled with nothing
/// to show; not shown is a popover that did not come up.
struct PresentationAcksTests {
    private let first = CaptureRequest(number: 4, trigger: .pointerGesture)
    private let second = CaptureRequest(number: 5, trigger: .selection)

    @Test func shownIsThePopoverUpAndTheTermsOwnEntryDrawn() {
        var acks = PresentationAcks()
        acks.delivered(first, generation: 9, term: "tide")
        #expect(acks.shown(popoverVisible: true) == nil, "the popover coming up is not a draw of the new content")
        #expect(acks.drew(query: "wave", popoverVisible: true) == nil, "another query's entry was taken for this one")
        #expect(acks.drew(query: "tide", popoverVisible: false) == nil, "an entry drawn in a hidden popover was shown")
        #expect(acks.drew(query: "tide", popoverVisible: true) == PresentationAck(request: first, generation: 9, outcome: .shown))
        #expect(acks.drew(query: "tide", popoverVisible: true) == nil, "one terminal acknowledgement")
    }

    @Test func aPopoverThatDidNotComeUpIsNotShown() {
        var acks = PresentationAcks()
        acks.delivered(first, generation: 9, term: "tide")
        #expect(acks.shown(popoverVisible: false) == PresentationAck(request: first, generation: 9, outcome: .notShown))
        #expect(acks.drew(query: "tide", popoverVisible: true) == nil)
    }

    /// **Each acknowledgement carries its own request and generation**: a newer delivery replaces the older, whose later
    /// draw acknowledges nothing; the same request presented again is acknowledged under its newer generation.
    @Test func aNewerDeliveryReplacesTheOlder() {
        var acks = PresentationAcks()
        acks.delivered(first, generation: 9, term: "tide")
        acks.delivered(second, generation: 10, term: "wave")
        #expect(acks.drew(query: "tide", popoverVisible: true) == nil, "the replaced request was acknowledged")
        #expect(acks.drew(query: "wave", popoverVisible: true) == PresentationAck(request: second, generation: 10, outcome: .shown))
        acks.delivered(second, generation: 11, term: "wave")
        #expect(acks.drew(query: "wave", popoverVisible: true) == PresentationAck(request: second, generation: 11, outcome: .shown))
    }

    @Test func closingForgetsWhatWasPresented() {
        var acks = PresentationAcks()
        acks.delivered(first, generation: 9, term: "tide")
        acks.closed()
        #expect(acks.drew(query: "tide", popoverVisible: true) == nil)
        #expect(acks.presenting == nil)
    }
}

/// **Where the popover points, from the box capture handed over** (plan-capture WI-3): a measured box flipped once into
/// AppKit's space; a click-based fallback made a word of no width on one reading line, as the Service has done since
/// WI-8; no box, no anchor (the pointer rule).
struct PanelAnchorTests {
    @Test func aMeasuredBoxIsFlippedAboutThePrimaryDisplay() {
        let box = WordBox.measured(ReadBounds(rect: DownRect(x: 90, y: 890, width: 40, height: 20), quality: .exact))
        #expect(PanelAnchor.rect(for: box, primaryHeight: 1_000) == CGRect(x: 90, y: 90, width: 40, height: 20))
    }

    @Test func aClickedPlaceIsAWordOfNoWidthOnOneLine() {
        let box = WordBox.clickPlacement(DownPoint(x: 300, y: 400))
        #expect(PanelAnchor.rect(for: box, primaryHeight: 1_000)
                == CGRect(x: 300, y: 600 - Tokens.Inset.clickedWordRise, width: Tokens.Size.pointAnchor.width,
                          height: Tokens.Row.clickedWord))
    }

    @Test func noBoxIsNoAnchor() {
        #expect(PanelAnchor.rect(for: .absent, primaryHeight: 1_000) == nil)
    }
}
