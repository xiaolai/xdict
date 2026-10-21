import Foundation

/// **What this build's Apple source needs from the system** (ADR-0026; plan-history-and-learning §3.2): the version the
/// implementation actually requires, and the reader-facing consequence when the Mac is older. The decision is a pure
/// function — the running version is passed in — so an old Mac's answer is tested without an old Mac.
public enum AppleSource {
    /// macOS 27 today: `LanguageModelError` is 27 and `SystemLanguageModel.tokenCount` is 26.4, so the floor the code
    /// actually has is 27. The provider's restructure (plan WI-5) may lower it to 26; until it lands the sentence names
    /// 27, because that is what runs.
    public static let requiredMacOS = 27

    /// The availability this system gets: the framework's own answer when it is new enough, and the typed system case —
    /// both versions named — when it is not. `framework` is an autoclosure so a framework the running system does not
    /// have is never touched: below the floor there is nothing to ask.
    public static func availability(running: String,
                                    framework: @autoclosure () -> AppleAvailability) -> AppleAvailability {
        guard let major = Int(running.split(separator: ".").first ?? ""), major >= requiredMacOS else {
            return .system(required: String(requiredMacOS), running: running)
        }
        return framework()
    }

    /// The running system, major and minor (`27.0`): what the reader's sentence names.
    public static var running: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion)"
    }
}
