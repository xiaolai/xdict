import XDictAI

// **Diagnostics are metadata only** (`conformance/capture/CONTRACT.md` §6; ADR-0021 d.4). The AI pane holds the
// presentation's sentence and the reader's key in memory; a default description — which prints every stored property —
// would write the sentence into a log line the first time anything described a session, and a key into a bug report.
// These conformances say what kind of value they are and never the reader's text; the empty mirrors stop `dump` and
// `Mirror` walking into it. `MeaningPrivacyTests` holds them to it.

extension MeaningHandoff: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "MeaningHandoff(term: \(term), \(sentence.utf16.count) UTF-16 units)" }
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
    /// The state's name, not its payload: an answer's quotes and explanation are the entry's words, and the held
    /// sentence is the reader's. Neither belongs in a log. The session is main-actor only, so describing it from
    /// anywhere else is a programming error that traps rather than a quiet read off the actor.
    public nonisolated var description: String {
        MainActor.assumeIsolated { "MeaningSession(\(Self.label(state)), held: \(held != nil))" }
    }
    public nonisolated var debugDescription: String { description }
    public nonisolated var customMirror: Mirror { Mirror(self, children: [:]) }

    static func label(_ state: State) -> String {
        switch state {
        case .idle: "idle"
        case .asking: "asking"
        case .preview: "preview"
        case .answer: "answer"
        case .template: "template"
        case .invalid: "invalid"
        case .unavailable: "unavailable"
        case .cancelled: "cancelled"
        }
    }
}

extension MeaningContext: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The displayed question is still reader context: diagnostics name its size, never its words.
    public var description: String { "MeaningContext(\(sentence.utf16.count) UTF-16 units)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

extension MeaningPresentation: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The presentation carries the request sentence, source quotations and generated text, all excluded from logs.
    public var description: String { "MeaningPresentation(answer: \(!explanation.isEmpty), problem: \(problem != nil))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
