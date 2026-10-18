// **Diagnostics are metadata only** (ADR-0014 decision 9). The context sentence lives in one ephemeral session on the
// capture side, and the existing observation hooks stringify outcomes into `events.jsonl` — so a default description,
// which prints every stored property, would log the sentence the first time anything described a captured term. These
// conformances say what kind of thing a value is and never the reader's text around the term; the empty mirrors stop
// `dump` and `Mirror` walking into it. The term itself is not context: it is what goes to search.

extension SentenceContext: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "SentenceContext(\(text.utf16.count) UTF-16 units, cut: \(cut.contains(.start) ? "start" : "")"
            + "\(cut.contains(.end) ? " end" : ""), placed: \(selection != nil))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

extension ContextOutcome: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        switch self {
        case .available(let sentence, _, _, let gap):
            "available(\(sentence.utf16.count) UTF-16 units\(gap.map { ", gap: \($0.rawValue)" } ?? ""))"
        case .pending(let handle): "pending(\(handle.id))"
        case .unavailable(let why): "unavailable(\(why.rawValue))"
        }
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

extension CapturedTerm: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "CapturedTerm(\(trigger.rawValue), \(acquisition.rawValue), app: \(source.bundleID ?? "unknown"), context: \(context))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
