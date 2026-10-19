import Carbon.HIToolbox
import Foundation
import Testing
import XDictAnywhere
import XDictCaptureMac
import XDictUI

/// **What lookup from anywhere tells the reader** (plan-macos-v1 WI-8): why a selection could not be looked up, each
/// reason its own sentence naming the app; and what happened to the shortcut — a clash says who holds it and which
/// shortcut still works, or that none does. Read here in the source language; both are `StringCatalogTests`'.
struct AnywhereSentencesTests {
    @Test func eachSelectionRefusalIsItsOwnSentenceNamingTheApp() {
        let refusals: [SelectionRefusal] = [
            .nothingSelected(app: "Notes"), .searchLimitReached(app: "Notes", limit: 400), .noWord(app: "Notes"),
            .tooLong(app: "Notes", characters: 300), .failed(.notResponding, app: "Notes"),
            .failed(.accessibilityRefused, app: "Notes"), .failed(.deadlineExceeded, app: "Notes"),
            .failed(.accessibilityDisabled, app: "Notes"), .failed(.appUnavailable, app: "Notes"), .notTrusted, .noApp,
            .tooLongToRead(app: "Notes"),
        ]
        let texts = refusals.map { String(localized: AnywhereSentences.refusal($0)) }
        #expect(Set(texts).count == refusals.count, "\(texts)")
        for (refusal, text) in zip(refusals, texts) {
            switch refusal {
            case .notTrusted, .noApp: continue
            default: #expect(text.contains("Notes"), "\(text)")
            }
        }
        #expect(texts[3].contains("300"))
        #expect(texts[9].contains("Accessibility"))
    }

    @Test func aClashSaysWhoHoldsItAndWhatStillWorks() {
        let chosen = Shortcut(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(controlKey | optionKey))
        let kept = String(localized: AnywhereSentences.problem(.refused(chosen, .takenByAnotherApp,
                                                                        stillUsing: .defaultLookUp)))
        #expect(kept.contains(chosen.label()) && kept.contains(Shortcut.defaultLookUp.label()), "\(kept)")
        #expect(kept.contains("Another app"), "\(kept)")
        let lost = String(localized: AnywhereSentences.problem(.refused(chosen, .takenByAnotherApp, stillUsing: nil)))
        #expect(lost != kept && lost.contains("no shortcut"), "\(lost)")
        let problems: [ShortcutProblem] = [
            .unavailable(.defaultLookUp, .takenByAnotherApp), .unavailable(.defaultLookUp, .heldByXDict),
            .unavailable(.defaultLookUp, .unreleasedByXDict), .unavailable(.defaultLookUp, .status(-9878)),
            .reserved(chosen), .unusable(chosen), .notSaved(chosen),
        ]
        let texts = problems.map { String(localized: AnywhereSentences.problem($0)) }
        #expect(Set(texts).count == problems.count, "\(texts)")
        #expect(texts[3].contains("-9878"))
    }
}
