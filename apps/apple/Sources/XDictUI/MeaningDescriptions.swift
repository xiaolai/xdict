import XDictAI

// **Diagnostics are metadata only** (`conformance/capture/CONTRACT.md` §6; ADR-0021 d.4). The AI pane holds the
// presentation's sentence and the reader's key in memory; a default description — which prints every stored property —
// would write the sentence into a log line the first time anything described a session, and a key into a bug report.
// These conformances say what kind of value they are and never the reader's text; the empty mirrors stop `dump` and
// `Mirror` walking into it. `MeaningPrivacyTests` holds them to it.

extension MeaningHandoff: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// **Sizes only** (audit round 4, 2026-10-25): a phrase selection can equal the whole sentence, so neither the term nor
    /// the sentence may be printed.
    public var description: String {
        "MeaningHandoff(term: \(term.utf16.count) UTF-16 units, \(sentence.utf16.count) UTF-16 units)"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

extension MeaningSent: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The size and the mode, never the bytes: the prompt holds the sentence and the entry.
    public var description: String { "MeaningSent(\(text.utf8.count) bytes, \(mode.rawValue))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

extension MeaningSettings: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The source, the switch and the language: never the key, and never an endpoint's credentials.
    public var description: String {
        "MeaningSettings(\(source?.rawValue ?? "none"), entry: \(sendEntryText), language: \(language))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

extension MeaningSession: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// **The kind and nothing else** (audit round 3, 2026-10-25): the state's payload is the reader's, and a nonisolated
    /// description cannot read main-actor state — `MainActor.assumeIsolated` trapped whenever a background task described
    /// a session. A constant cannot leak and cannot trap.
    public nonisolated var description: String { "MeaningSession" }
    public nonisolated var debugDescription: String { description }
    public nonisolated var customMirror: Mirror { Mirror(self, children: [:]) }
}

extension MeaningContext: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The displayed question is still reader context: diagnostics name its size, never its words.
    public var description: String { "MeaningContext(\(sentence.utf16.count) UTF-16 units)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

extension MeaningRequestFacts: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The choices, never the reader's sentence or the sense's text.
    public var description: String {
        "MeaningRequestFacts(sense: \(chosenSense != nil), evidence: \(evidenceTarget != nil))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

extension MeaningPresentation: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The presentation carries the request sentence, source quotations and generated text, all excluded from logs.
    public var description: String { "MeaningPresentation(answer: \(!explanation.isEmpty), problem: \(problem != nil))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
