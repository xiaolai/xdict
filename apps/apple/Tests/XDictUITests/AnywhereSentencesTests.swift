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
            .tooLongToRead(app: "Notes"), .doesNotShareSelections(app: "Notes"),
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
        // The pane by the name this macOS gives it: macOS 27 renamed the list (Device Control and Data Access), and the
        // old wording would send the reader to a pane no longer called that (`PrivacySettings`).
        #expect(texts[9].contains(PrivacySettings.accessibility()), "\(texts[9])")
    }

    /// **The refusal's title says what is missing** (owner, 2026-10-30: "Nothing to Look Up" was "an ugly and stupid
    /// tip"): one blanket title read an Accessibility restriction as the app having nothing to offer.
    @Test func eachRefusalFamilyHasItsOwnTitle() {
        let families: [(SelectionRefusal, String)] = [
            (.nothingSelected(app: "Notes"), "No Word Selected"),
            (.noWord(app: "Notes"), "No Word Selected"),
            (.tooLong(app: "Notes", characters: 300), "The Selection Is Too Long"),
            (.tooLongToRead(app: "Notes"), "The Selection Is Too Long"),
            (.notTrusted, "Accessibility Is Off for XDict"),
            (.failed(.accessibilityDisabled, app: "Notes"), "Accessibility Is Off for XDict"),
            (.noApp, "The Selection Could Not Be Read"),
            (.searchLimitReached(app: "Notes", limit: 400), "The Selection Could Not Be Read"),
            (.failed(.cancelled, app: "Notes"), "The Lookup Was Replaced"),
            (.doesNotShareSelections(app: "Notes"), "Notes Does Not Share Selections"),
        ]
        for (refusal, title) in families {
            #expect(String(localized: AnywhereSentences.refusalTitle(refusal)) == title, "\(refusal)")
        }
        #expect(!String(localized: AnywhereSentences.refusalTitle(.notTrusted)).contains("Nothing to Look Up"))
    }

    /// The Accessibility button is offered exactly where the grant is the obstacle.
    @Test func theAccessibilityFamilyIsTheOneTheButtonServes() {
        #expect(AnywhereSentences.refusalNeedsAccessibility(.notTrusted))
        #expect(AnywhereSentences.refusalNeedsAccessibility(.failed(.accessibilityDisabled, app: "Notes")))
        #expect(!AnywhereSentences.refusalNeedsAccessibility(.nothingSelected(app: "Notes")))
        #expect(!AnywhereSentences.refusalNeedsAccessibility(.failed(.notResponding, app: "Notes")))
    }

    /// **The hover sentence is the reader's own gesture** (owner, 2026-10-30: "suggest users use hovering"): holding the
    /// key says hold, the double-tap setting says double-press, and neither is offered where hover cannot help.
    @Test func aHoverSuggestionSpeaksTheReadersOwnGesture() {
        let hold = AnywhereSentences.HoverHint(symbol: "⌥", tapped: false)
        let tap = AnywhereSentences.HoverHint(symbol: "⌥", tapped: true)
        let held = String(localized: AnywhereSentences.hoverAlternative(hold))
        let tapped = String(localized: AnywhereSentences.hoverAlternative(tap))
        #expect(held.contains("hold ⌥") && tapped.contains("double-press ⌥"), "\(held) / \(tapped)")
        #expect(held != tapped)
        #expect(AnywhereSentences.refusalSuggestsHover(.nothingSelected(app: "Notes")))
        #expect(AnywhereSentences.refusalSuggestsHover(.noWord(app: "Notes")))
        #expect(AnywhereSentences.refusalSuggestsHover(.doesNotShareSelections(app: "Notes")))
        #expect(!AnywhereSentences.refusalSuggestsHover(.notTrusted))
        #expect(!AnywhereSentences.refusalSuggestsHover(.tooLong(app: "Notes", characters: 300)))
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
