import ApplicationServices
import Observation

/// **Asking macOS for Accessibility** (plan-macos-v1 WI-8): reading another app's selection needs it, and only the
/// system can grant it. The first selection lookup without the grant makes the system's own request appear
/// (`AXIsProcessTrustedWithOptions` with the prompt option) — **once per request**: further presses while it is open
/// prompt no more, nothing prompts at launch, and nothing prompts in a loop. While the request is open the trusted state
/// is polled (`poll`, driven by the app's timer), so a grant carries the waiting lookup on without a relaunch. The trust
/// check is injected, so tests never ask the Mac they run on.
@MainActor
@Observable
public final class AccessibilityGate {
    public enum Answer: Equatable, Sendable {
        case trusted
        /// The system's request was made just now.
        case asked
        /// The request is already open; nothing was asked again.
        case waiting
    }

    /// How often the app polls while the request is open, and how many times before it gives up.
    public static let interval: Duration = .milliseconds(500)
    public static let defaultPolls = 1_200  // ten minutes

    @ObservationIgnored private let check: @MainActor (_ prompt: Bool) -> Bool
    @ObservationIgnored private let polls: Int
    @ObservationIgnored private var left = 0
    /// What a grant resumes: the lookup that found no grant.
    @ObservationIgnored public var onGranted: (@MainActor () -> Void)?
    public private(set) var isWaiting = false

    public init(check: @escaping @MainActor (_ prompt: Bool) -> Bool, polls: Int = AccessibilityGate.defaultPolls) {
        self.check = check
        self.polls = polls
    }

    /// The system's own check: with `prompt`, its request appears if the app is not trusted.
    public static func system(_ prompt: Bool) -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// A lookup needs the grant: trusted already, or the request made once and polled.
    public func request() -> Answer {
        if isWaiting { return .waiting }
        if check(false) { return .trusted }
        _ = check(true)
        isWaiting = true
        left = polls
        return .asked
    }

    /// One poll while the request is open; the grant ends it and resumes the waiting lookup, once.
    public func poll() {
        guard isWaiting else { return }
        left -= 1
        if check(false) {
            isWaiting = false
            onGranted?()
        } else if left <= 0 {
            isWaiting = false
        }
    }
}
