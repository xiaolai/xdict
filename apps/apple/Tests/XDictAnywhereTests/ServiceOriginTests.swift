import Testing
import XDictAnywhere

/// **Whose selection a Service request is, decided at the moment macOS hands the text over** (verifier, 2026-10-20):
/// from XDict's own state then — active, with a key window — never from the reader's last Control-click, which may be
/// stale (up to 15 s) or never recorded (the Services menu of a menu bar, a Services keyboard shortcut). macOS brings
/// the provider forward only after the request (measured 2026-10-15), so another app's request finds XDict inactive.
struct ServiceOriginTests {
    /// Misroute A: the reader right-clicked in XDict, then used another app's Services within 15 s. That app is in
    /// front, XDict is not active: the reader's app. Red where a recent click in XDict decides.
    @Test func anotherAppsServiceAfterAClickInXDictIsTheReadersApp() {
        #expect(ServiceOrigin.at(xdictActive: false, xdictHasKeyWindow: false) == .readersApp)
    }

    /// Misroute B: the reader right-clicked in another app, then used XDict's own Services within 15 s. XDict is active
    /// with its window key: XDict's own. Red where a recent click elsewhere decides.
    @Test func xdictsOwnServiceAfterAClickElsewhereIsOurs() {
        #expect(ServiceOrigin.at(xdictActive: true, xdictHasKeyWindow: true) == .ours)
    }

    /// The plain cases: another app's request with no click at all, and XDict active with no window that could hold a
    /// selection (only the menu-bar item) — neither is XDict's selection.
    @Test func withoutAnActiveXDictWindowItIsTheReadersApp() {
        #expect(ServiceOrigin.at(xdictActive: false, xdictHasKeyWindow: true) == .readersApp)
        #expect(ServiceOrigin.at(xdictActive: true, xdictHasKeyWindow: false) == .readersApp)
    }
}
