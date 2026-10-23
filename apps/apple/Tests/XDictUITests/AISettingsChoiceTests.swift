import Foundation
import Testing
import XDictAI
@testable import XDictUI

/// **Settings ▸ AI's source is one native single choice** (UI32), its prompt customisation is advanced (UI18), and the
/// Codex sign-in is structured and cancellable (UI33): the decisions, without a window.
@MainActor
struct AISettingsChoiceTests {
    static func preferences() -> MeaningPreferences {
        let suite = "ai.xdict.tests.ai-choice." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return MeaningPreferences(defaults: defaults, keys: MemoryKeyStore())
    }

    /// Six choices, in the order of what each costs to set up; each maps to exactly one stored source.
    @Test func theSourcesAreOneChoiceInOrder() {
        #expect(AISourceChoice.allCases == [.off, .apple, .local, .cloud, .codex, .claude])
        #expect(AISourceChoice.allCases.map(\.identifier) == ["off", "apple", "local", "cloud", "codex", "claude"])
        #expect(Set(AISourceChoice.allCases.map { "\(String(describing: $0.kind))-\($0.cloud)" }).count == 6)
    }

    /// The picker reads what is stored, and writing a choice stores it: the two endpoint rows stay distinct.
    @Test func theChoiceRoundTripsThroughThePreferences() {
        let model = AISettingsModel(preferences: Self.preferences())
        #expect(model.choice == .off)
        for choice in AISourceChoice.allCases {
            model.choice = choice
            #expect(model.choice == choice, "\(choice)")
            #expect(model.preferences.settings.source == choice.kind)
            #expect(model.preferences.httpCloud == choice.cloud)
        }
    }

    /// **An edited prompt is visible from outside the disclosure** (UI18; ADR-0021: *your wording, not measured*): the
    /// advanced group says so while closed, for any kind in the answer language.
    @Test func anEditedPromptIsSaidOutsideTheDisclosure() {
        let model = AISettingsModel(preferences: Self.preferences())
        #expect(!model.hasEditedPrompt)
        model.promptKind = .sentenceOnly
        model.loadDraft()
        model.draft += " Be brief."
        model.draftChanged()
        model.promptKind = .grounded
        model.loadDraft()
        #expect(model.hasEditedPrompt, "an edit to another kind is still the reader's wording")
        model.promptKind = .sentenceOnly
        model.resetDraft()
        #expect(!model.hasEditedPrompt)
    }

    // MARK: - The Codex sign-in (UI33)

    /// The address and the code, read out of the login's own lines; ANSI colour and trailing punctuation dropped.
    @Test func theLoginLinesYieldTheAddressAndTheCode() {
        let device = CodexLogin.parse([
            "Welcome to Codex",
            "1. Open this link in your browser: \u{1B}[94mhttps://auth.openai.com/codex/device\u{1B}[0m",
            "2. Enter this one-time code (expires in 15 minutes)",
            "   \u{1B}[94mABCD-12345\u{1B}[0m",
        ])
        #expect(device.url == URL(string: "https://auth.openai.com/codex/device"))
        #expect(device.code == "ABCD-12345")

        let inline = CodexLogin.parse(["Open https://example.invalid/device, then enter the code WXYZ-9876."])
        #expect(inline.url == URL(string: "https://example.invalid/device"))
        #expect(inline.code == "WXYZ-9876")

        // No word "code": nothing is guessed to be one; the raw lines stay under Details.
        let unlabelled = CodexLogin.parse(["Open https://example.invalid/device and enter ABCD"])
        #expect(unlabelled.url == URL(string: "https://example.invalid/device"))
        #expect(unlabelled.code == nil)
        #expect(CodexLogin.parse([]) == CodexLogin(url: nil, code: nil))
        // Only a web address is offered as one: a file URL in the output is not a link to open.
        #expect(CodexLogin.parse(["see file:///tmp/x"]).url == nil)
    }

    /// **Cancel ends the sign-in** (UI33): the login task is cancelled, the pane is no longer signing in, and a cancelled
    /// login is not reported as a failure of the source.
    @Test func cancelEndsTheSignIn() async {
        let started = AsyncStream<Void>.makeStream()
        let model = AISettingsModel(preferences: Self.preferences(), login: { onLine in
            onLine("Open https://example.invalid/device and enter the code ABCD-1234")
            started.continuation.yield()
            try await Task.sleep(for: .seconds(30))
        })
        model.startSignIn()
        #expect(model.signingIn)
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        await Task.yield()
        #expect(await eventually { model.login.code == "ABCD-1234" })
        model.cancelSignIn()
        #expect(await eventually { !model.signingIn })
        #expect(model.loginLines.isEmpty)
        if case .failed = model.status { Issue.record("a cancelled sign-in is not the source's failure") }
    }

    /// Starting twice runs one login.
    @Test func aSecondStartDoesNotRunASecondLogin() async {
        let runs = Counter()
        let model = AISettingsModel(preferences: Self.preferences(), login: { _ in
            runs.add()
            try await Task.sleep(for: .seconds(30))
        })
        model.startSignIn()
        model.startSignIn()
        #expect(await eventually { runs.value == 1 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(runs.value == 1)
        model.cancelSignIn()
    }

    @MainActor final class Counter {
        var value = 0
        func add() { value += 1 }
    }

    func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
