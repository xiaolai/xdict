/// **The word a ⌘-click opens in a new tab** (parity P47), handed over before the tab's window is made and taken once
/// by the first main window made after it: a window made by New Tab or at launch finds nothing, and looks nothing up.
@MainActor
public final class NewTabLookups {
    public static let shared = NewTabLookups()

    private var pending: String?

    public init() {}

    public func hand(_ word: String) { pending = word }

    public func take() -> String? {
        defer { pending = nil }
        return pending
    }
}
