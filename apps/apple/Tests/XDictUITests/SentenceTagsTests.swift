import AppKit
import Foundation
import SwiftUI
import Testing
@testable import XDictUI

/// **The system's reading, measured and labelled** (plan-context-tools WI-10; ADR-0034 d.6): a sentence of a covered
/// language is read into tokens with their class and, where the tagger has one, their lemma; an uncovered language is
/// stated as such; and a token the tagger could not label is drawn as a dash, never as an invented word.
@MainActor
struct SentenceTagsTests {
    @Test func anEnglishSentenceIsReadIntoClassedTokens() {
        let reading = SentenceTagReader.read("Please hold the door.")
        #expect(reading.covered, "English is in the measured set")
        #expect(reading.language == "en")
        #expect(!reading.tags.isEmpty)
        #expect(reading.tags.allSatisfy { $0.lexicalClass != nil }, "every token is classed in English")
        #expect(reading.tags.contains { $0.lemma != nil }, "English has lemmas")
    }

    @Test func aChineseSentenceIsCoveredAndClassed() {
        let reading = SentenceTagReader.read("请把门扶着，我去找钥匙。")
        #expect(reading.covered, "Simplified Chinese is in the measured set")
        #expect(!reading.tags.isEmpty)
        #expect(reading.tags.allSatisfy { $0.lexicalClass != nil }, "the measurement classed every Chinese token")
    }

    @Test func anUnmeasuredLanguageIsNotPresentedAsAReading() {
        // Bengali: in the Apple-dictionary manifest, measured for scheme availability only — never sampled.
        let reading = SentenceTagReader.read("অনুগ্রহ করে দরজাটি ধরে রাখুন।")
        #expect(!reading.covered, "an unmeasured language must say so, not draw a half table")
    }

    @Test func aTokenWithoutTagsIsADashAndALemmaIsShownOnlyWhenItDiffers() {
        #expect(SentenceViewDescription.of(SentenceTag(token: "zzz", lexicalClass: nil, lemma: nil)) == "—")
        #expect(SentenceViewDescription.of(SentenceTag(token: "holds", lexicalClass: "verb", lemma: nil)) == "verb")
        #expect(SentenceViewDescription.of(SentenceTag(token: "holds", lexicalClass: "verb", lemma: "hold"))
                == "verb · → hold")
        #expect(SentenceViewDescription.of(SentenceTag(token: "hold", lexicalClass: "verb", lemma: "hold")) == "verb",
                "a lemma equal to its token is not repeated")
    }

    @Test func theViewDrawsForACoveredAndAnUncoveredLanguage() {
        let covered = NSHostingView(rootView: SystemReadingView(sentence: "Please hold the door."))
        #expect(covered.fittingSize.height > 0)
        let uncovered = NSHostingView(rootView: SystemReadingView(sentence: "অনুগ্রহ করে দরজাটি ধরে রাখুন।"))
        #expect(uncovered.fittingSize.height > 0, "the uncovered language draws its stated sentence, not nothing")
    }
}

/// The description function the view uses, reachable from the test without exposing the view's internals. Main-actor,
/// as the view it forwards to is.
@MainActor
enum SentenceViewDescription {
    static func of(_ tag: SentenceTag) -> String {
        SystemReadingView.description(of: tag)
    }
}
