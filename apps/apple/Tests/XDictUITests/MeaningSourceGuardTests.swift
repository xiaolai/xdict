import Foundation
import Testing
import XDictAI
import XDictClient
import XDictContract
import XDictUI

/// **Two silent-failure guards, read off the composition's one source file** (plan-ai-meaning WI-5):
///
/// - the session can reach no capture book: a sentence arrives only as a value handed to it, so "no context without a
///   capture" is a property of the module edge, not of a reviewer's memory;
/// - one ask builds one provider and calls it once: there is no fallback chain in the file to fire by accident.
///
/// A behavioural test proves what a fake can observe; these two prove what the file may not contain. Each is red if the
/// forbidden thing is added — the counts and the names below are the whole check.
@Suite struct MeaningSourceGuardTests {
    static let source = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources/XDictUI/MeaningSession.swift")

    @Test func theSessionCannotReachTheCaptureBook() throws {
        let text = try String(contentsOf: Self.source, encoding: .utf8)
        for forbidden in ["CaptureRequests", "CaptureContextSession", "CapturedTerm", "contextSession", "acknowledge"] {
            #expect(!text.contains(forbidden), "MeaningSession names \(forbidden): the sentence must be a handed-over value")
        }
    }

    @Test func theSessionBuildsOneProviderAndCallsItOnce() throws {
        let text = try String(contentsOf: Self.source, encoding: .utf8)
        // One `send`, shared by the composed ask and the preview's frozen Send: one provider and one call in the whole
        // file, so neither path can try a second source (audit finding, 2026-10-23 — the two paths used to duplicate
        // this, and a fix in one could miss the other).
        #expect(text.components(separatedBy: "makeProvider(settings,").count - 1 == 1, "one provider for every ask")
        #expect(text.components(separatedBy: "provider.answer(to:").count - 1 == 1, "one call for every ask")
        #expect(!text.contains("fallback"), "no fallback chain")
    }
}
