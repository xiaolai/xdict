import Foundation

/// **What the view does with a link the core has classified** (plan-macos-v1 WI-4; ADR-0007 decision 7): a lookup goes
/// to the window, in link mode; an anchor scrolls; a sound or a spoken word goes to the speech layer (WI-7); a remote
/// link the reader activated is offered to their browser, after they say yes; everything else does nothing, and is
/// logged so that "nothing" can be told from "never asked".
public enum EntryLinkAction: Equatable, Sendable {
    case lookup(query: String, anchor: String?)
    case scroll(anchor: String)
    case sound(path: String)
    case speak(text: String)
    case askReader(URL)
    case nothing(String)

    public static func `for`(_ link: EntryLink, activatedByALink: Bool) -> EntryLinkAction {
        switch link {
        case .lookup(let query, let anchor): return .lookup(query: query, anchor: anchor)
        case .anchor(let name): return .scroll(anchor: name)
        case .sound(let path): return .sound(path: path)
        case .speak(let text): return .speak(text: text)
        case .resource(let path): return .nothing("a link to the resource \(path) is not opened")
        case .blocked(.remote(let url)):
            guard activatedByALink else { return .nothing("a remote URL not activated by a link: \(url)") }
            guard let remote = RemoteOpenGate.openable(url) else { return .nothing("a remote URL no browser opens: \(url)") }
            return .askReader(remote)
        case .blocked(.script): return .nothing("a script URL")
        case .blocked(.unknownScheme(let scheme)): return .nothing("an unknown scheme: \(scheme)")
        }
    }

    /// The word the log and the lab use for this action.
    public var name: String {
        switch self {
        case .lookup: "lookup"
        case .scroll: "scroll"
        case .sound: "sound"
        case .speak: "speak"
        case .askReader: "ask-reader"
        case .nothing: "nothing"
        }
    }
}
