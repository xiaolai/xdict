/// The bundle identities, fixed by ADR-0001 decision 3: changing one later costs readers their settings and their
/// Accessibility and Screen Recording grants. The Info.plists state the same (`BundleFactsTests`).
public enum XDictIdentity {
    /// The app, and the subsystem its log writes under.
    public static let app = "ai.xdict.app"
    /// The dictionary XPC service: its bundle identifier, which is also the name the app connects to.
    public static let dictionaryService = "ai.xdict.app.DictionaryService"
}
