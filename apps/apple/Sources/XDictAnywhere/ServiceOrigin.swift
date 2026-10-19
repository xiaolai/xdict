/// **Whose selection a Service request is** (verifier, 2026-10-20), decided from XDict's own state **at the moment macOS
/// hands the text over**, never from the reader's last Control-click: a click may be stale, and the Services menu of a
/// menu bar or a Services keyboard shortcut records none. macOS brings the provider forward only after another app's
/// request (measured on the E2E Mac, 2026-10-15), so then XDict is not active; a request from XDict's own window finds
/// XDict active with that window key.
public enum ServiceOrigin: Equatable, Sendable {
    /// One of XDict's own windows: XDict's selection is read, and XDict stays in front.
    case ours
    /// The reader's app: put back in front, and its selection read.
    case readersApp

    /// Known gap: a context menu on another app's window behind XDict's, opened while XDict is active, is taken as
    /// XDict's. Its selection then disagrees with the Service's text, which stays the query; only the sentence and the
    /// box are lost.
    public static func at(xdictActive: Bool, xdictHasKeyWindow: Bool) -> ServiceOrigin {
        xdictActive && xdictHasKeyWindow ? .ours : .readersApp
    }
}
