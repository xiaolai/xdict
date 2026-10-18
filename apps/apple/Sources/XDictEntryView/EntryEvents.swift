import Foundation
import XDictBase
import os

/// **What the entry view did, as it did it** — every request it served or refused, every navigation it decided, every
/// link it routed, every prompt. Logged under `ai.xdict.app` / `entry`, and handed to whoever listens: the window later,
/// the E2E lab now, which joins it with what its observers saw. A refusal that leaves no trace reads exactly like a
/// request that was never made.
public enum EntryEvent: Sendable, Equatable {
    /// The view refused to render at all, and why (the switches, the rule list, an empty policy).
    case refusedToRender(EntryRefusal)
    case documentRequested(EntryReference)
    case documentFailed(EntryReference, String)
    /// The main document finished loading (`didFinish`).
    case documentFinished(URL)
    /// A request answered, and the open handle of the dictionary it was answered from.
    case served(handle: String, url: String, status: Int, mime: String, bytes: Int)
    case refusedRequest(handle: String, url: String, reason: String)
    case navigation(url: String, verdict: String, mainFrame: Bool, type: Int)
    case navigationResponseRefused(url: String)
    case linkRouted(url: String, action: String)
    case remotePromptRaised(url: String)
    case remotePromptDropped(url: String)
    case remotePromptAnswered(url: String, consent: Bool)
    case remoteOpened(url: String)
    case popupRefused(url: String)
    case downloadRefused(url: String)
    case menuFiltered(kept: [String], removed: [String])
    case contentProcessTerminated
    /// A ⌘-clicked word handed to the window for a new tab (P47), or a message from the shell's script refused.
    case wordOpenedInNewTab(word: String)
    case messageRefused
}

enum EntryLog {
    static let logger = Logger(subsystem: XDictIdentity.app, category: "entry")

    static func record(_ event: EntryEvent) {
        switch event {
        case .refusedToRender(let why):
            logger.error("entry view refused to render: \(String(describing: why), privacy: .public)")
        case .refusedRequest(_, let url, let reason):
            logger.info("refused \(url, privacy: .private(mask: .hash)): \(reason, privacy: .public)")
        case .navigation(let url, let verdict, let main, let type):
            logger.info("navigation \(verdict, privacy: .public) main=\(main) type=\(type) \(url, privacy: .private(mask: .hash))")
        case .linkRouted(let url, let action):
            logger.info("link \(action, privacy: .public): \(url, privacy: .private(mask: .hash))")
        case .popupRefused, .downloadRefused, .remotePromptDropped, .navigationResponseRefused:
            logger.info("\(String(describing: event), privacy: .private(mask: .hash))")
        case .contentProcessTerminated:
            logger.error("the entry's web content process ended")
        default:
            logger.debug("\(String(describing: event), privacy: .private(mask: .hash))")
        }
    }
}
