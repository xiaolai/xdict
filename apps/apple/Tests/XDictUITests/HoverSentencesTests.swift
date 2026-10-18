import Foundation
import Testing
import XDictAnywhere
import XDictCapture
import XDictUI

/// **What hover's settings and menu say, in the reader's language** (plan-capture WI-3): capture hands kinds (ADR-0014
/// decision 4), these word them. Read here in the source language; both languages are `StringCatalogTests`'.
struct HoverSentencesTests {
    @Test func everyKeyGestureAndScriptHasANameOfItsOwn() {
        let keys = HoverModifier.allCases.map { String(localized: HoverSentences.modifier($0)) }
        #expect(Set(keys).count == HoverModifier.allCases.count, "\(keys)")
        let gestures = HoverGesture.allCases.map { String(localized: HoverSentences.gesture($0)) }
        #expect(Set(gestures).count == HoverGesture.allCases.count, "\(gestures)")
        let scripts = CaptureScript.allCases.map { String(localized: HoverSentences.script($0)) }
        #expect(Set(scripts).count == CaptureScript.allCases.count, "\(scripts)")
    }

    /// **The scripts line says what the gate does**: every script where the dictionaries could hold any, else the named
    /// scripts, in one order whatever the set's.
    @Test func theScriptsLineNamesWhatHoverLooksUp() {
        let every = String(localized: HoverSentences.scripts(nil))
        let some = String(localized: HoverSentences.scripts([.han, .latin]))
        #expect(every != some)
        #expect(some.contains(String(localized: HoverSentences.script(.latin))))
        #expect(some.contains(String(localized: HoverSentences.script(.han))))
        #expect(some == String(localized: HoverSentences.scripts([.latin, .han])), "the order followed the set's")
    }

    /// **Each notice capture can give is its own sentence**, the stuck lane saying what still works.
    @Test func eachNoticeIsItsOwnSentence() {
        let texts = CaptureNotice.allCases.map { String(localized: HoverSentences.notice($0)) }
        #expect(Set(texts).count == CaptureNotice.allCases.count, "\(texts)")
        #expect(String(localized: HoverSentences.notice(.captureStuck)).contains("selection"))
    }

    /// **The pause group's lines**: a pause length per duration, a paused hover saying when it comes back, and hover
    /// switched off said rather than left out.
    @Test func thePauseLinesSayWhatTheyDo() {
        let lengths = HoverPause.durations.map { String(localized: HoverSentences.pauseLength($0)) }
        #expect(Set(lengths).count == HoverPause.durations.count, "\(lengths)")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let resumes = HoverSentences.pauseEntry(.resumesAt(now.addingTimeInterval(900)), now: now,
                                                locale: Locale(identifier: "en"))
        #expect(resumes.contains("15"), "\(resumes)")
        let titles = [HoverPauseMenu.Entry.pause, .resume, .hoverIsOff].map {
            HoverSentences.pauseEntry($0, now: now, locale: Locale(identifier: "en"))
        }
        #expect(Set(titles).count == 3, "\(titles)")
    }
}
