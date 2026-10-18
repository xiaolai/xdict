/// **The apps capture never reads, by bundle identifier** — capture's own list (ADR-0014 decision 10), not a study
/// ledger's place policy. Password managers at minimum: capture always takes the sentence around a word, and in a
/// password manager the whole surface is secrets (XiaolaiDict ADR-0015). Terminals are not here: hover was measured
/// working in them, and the gesture gate keeps it off a half-typed command (`HoverPolicy.terminals`).
public enum CaptureExclusions {
    public static let passwordManagers: Set<String> = [
        "com.1password.1password",
        "com.1password.1password-launcher",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop",
        "com.dashlane.Dashlane",
        "in.sinew.Enpass-Desktop",
        "com.keepassium.mac",
        "org.keepassxc.keepassxc",
        "com.lastpass.LastPass",
        "com.apple.keychainaccess",
        "com.apple.Passwords",
    ]
}
