import Foundation

/// **What a fresh install still needs, read from live state every time it is asked** (plan-macos-v1 WI-9; adapted from
/// XiaolaiDict's `SetupBoard`). A board, not a wizard: each row is a fact about now — dictionaries added (none are
/// bundled), Accessibility granted (for the selection shortcut), the shortcut registered — so a permission granted in
/// System Settings completes its row with no relaunch, and setting up again is only opening the window. Nothing here is
/// ordered or remembered.
public struct SetupBoard: Equatable, Sendable {
    public enum Step: String, CaseIterable, Identifiable, Sendable {
        case dictionaries, accessibility, shortcut

        public var id: String { rawValue }
    }

    public enum State: Equatable, Sendable {
        case done
        case needed
        /// Tried and failed: the shortcut is taken by another app.
        case problem
    }

    /// Dictionaries that answer lookups.
    public var dictionaries: Int
    /// Whether macOS trusts XDict with Accessibility.
    public var trusted: Bool
    /// Whether the lookup shortcut is registered.
    public var shortcutWorks: Bool

    public init(dictionaries: Int, trusted: Bool, shortcutWorks: Bool) {
        self.dictionaries = dictionaries
        self.trusted = trusted
        self.shortcutWorks = shortcutWorks
    }

    public func state(of step: Step) -> State {
        switch step {
        case .dictionaries: dictionaries > 0 ? .done : .needed
        case .accessibility: trusted ? .done : .needed
        case .shortcut: shortcutWorks ? .done : .problem
        }
    }

    public var isComplete: Bool { Step.allCases.allSatisfy { state(of: $0) == .done } }

    public static func title(_ step: Step) -> LocalizedStringResource {
        switch step {
        case .dictionaries: LocalizedStringResource("Dictionaries")
        case .accessibility: LocalizedStringResource("Accessibility")
        case .shortcut: LocalizedStringResource("Lookup shortcut")
        }
    }

    public func detail(_ step: Step) -> LocalizedStringResource {
        switch (step, state(of: step)) {
        case (.dictionaries, .done):
            LocalizedStringResource("Dictionaries answering lookups: \(dictionaries).")
        case (.dictionaries, _):
            LocalizedStringResource("XDict comes with no dictionaries. Add your own MDict files (.mdx and .mdd).")
        case (.accessibility, .done):
            LocalizedStringResource("Granted. The shortcut can read the selection in any app.")
        case (.accessibility, _):
            LocalizedStringResource("""
                Needed to read the word you select in another app. Turn XDict on in System Settings ▸ Privacy & \
                Security ▸ Accessibility; this row updates by itself.
                """)
        case (.shortcut, .done):
            LocalizedStringResource("Select a word anywhere and press the shortcut to look it up.")
        case (.shortcut, _):
            LocalizedStringResource("The shortcut is in use by another app. Choose another one.")
        }
    }
}

/// **The setup window as the E2E stage reads it from outside** (`Tools/lookup/keys.swift ax`; G7, 2026-10-18): SwiftUI does
/// not expose the board's rows to a walk of the app's own views, which read an empty tree while the external walk read
/// every row. The `setup` checks read the external walk's nodes (role, id, texts, depth, in reading order).
public enum SetupWindowReading {
    /// The nodes of a `keys ax` answer; nil when it is not one (the tool refused, or wrote something else).
    public static func nodes(fromKeysAX data: Data) -> [[String: Any]]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["nodes"] as? [[String: Any]]
    }

    public static func identifiers(_ nodes: [[String: Any]]) -> Set<String> {
        Set(nodes.compactMap { $0["id"] as? String }.filter { !$0.isEmpty })
    }

    /// The texts of the window's content: its first child and everything under it, as the window's content view was
    /// read before; the title bar's buttons and title come after it and are left out.
    public static func contentTexts(_ nodes: [[String: Any]]) -> [String] {
        guard let start = nodes.firstIndex(where: { $0["depth"] as? Int == 1 }) else { return [] }
        var out: [String] = []
        for (index, node) in nodes[start...].enumerated() {
            if index > 0, (node["depth"] as? Int ?? 0) <= 1 { break }
            out += node["texts"] as? [String] ?? []
        }
        return out
    }
}

/// **Whether the setup window speaks only Chinese** (E2E `setup.chineseOnly`): the English it still shows, from the texts
/// its Accessibility tree read; and the verdict, which fails on no text at all, since an empty tree (a window not yet
/// drawn, or read before it was) has no English in it and would otherwise pass without reading anything.
public enum SetupLanguageCheck {
    /// A run of three Latin letters that is not one of the names kept in every language: XDict's own (XDict, MDict, mdx,
    /// mdd) and those Apple's Simplified Chinese keeps in Latin letters ("任何 App", "Control 键"). Whole words only, so
    /// "Apple" or "Applications" still count.
    public static func isEnglish(_ text: String) -> Bool {
        text.split { !($0.isASCII && $0.isLetter) }.contains { $0.count >= 3 && !keptNames.contains($0.lowercased()) }
    }

    /// Lowercase, compared lowercased: written as the names, these would read as prose to the string catalog's check.
    private static let keptNames: Set<String> = ["xdict", "mdict", "mdx", "mdd", "app", "control", "option", "command",
                                                 "shift"]

    public static func english(in texts: [String]) -> [String] { texts.filter(isEnglish) }

    /// Some text was read, none of it English, and the first preferred language is Chinese.
    public static func chineseOnly(texts: [String], preferredLanguage: String?) -> Bool {
        !texts.isEmpty && english(in: texts).isEmpty && preferredLanguage?.hasPrefix("zh") == true
    }
}
