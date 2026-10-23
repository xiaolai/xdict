import Foundation

/// **One system fact a row depends on, as XDict could read it** (plan-setup-v2 WI-1, WI-5): three-valued, because
/// "XDict could not read this" is not "off" and must never draw as a finished row. Every probe that fills one of these
/// is read-only — nothing in this type, or in anything that builds one, writes a system preference.
public enum SystemFact: Equatable, Sendable {
    /// Read, and in the state XDict wants.
    case ready
    /// Read, and in the state the reader can change; `count` is what the row can name (Apple's active dictionaries),
    /// nil where there is nothing to count.
    case waiting(count: Int?)
    /// XDict could not read it: the row says to check, never a guess.
    case unreadable
}

/// **Apple's Look Up, as three separate facts** (plan-setup-v2 step 6): the symbolic hotkey, the trackpad gesture and
/// Apple's own active dictionaries. Each is its own row line and its own button, so a reader told "something is on"
/// can see what. All three default to `.unreadable`: a board nobody probed says "check", never green.
public struct AppleLookUp: Equatable, Sendable {
    public enum Part: String, CaseIterable, Sendable {
        case shortcut, trackpad, dictionaries
    }

    public var shortcut: SystemFact
    public var trackpad: SystemFact
    public var dictionaries: SystemFact

    public init(shortcut: SystemFact = .unreadable, trackpad: SystemFact = .unreadable,
                dictionaries: SystemFact = .unreadable) {
        self.shortcut = shortcut
        self.trackpad = trackpad
        self.dictionaries = dictionaries
    }

    public func fact(_ part: Part) -> SystemFact {
        switch part {
        case .shortcut: shortcut
        case .trackpad: trackpad
        case .dictionaries: dictionaries
        }
    }

    /// Whether every part was read and is off.
    public var isClear: Bool {
        Part.allCases.allSatisfy { fact($0) == .ready }
    }

    public var isUnreadable: Bool {
        Part.allCases.contains { fact($0) == .unreadable }
    }
}

/// **What a fresh install still needs, read from live state every time it is asked** (plan-macos-v1 WI-9; adapted from
/// XiaolaiDict's `SetupBoard`; ordered and made required/optional by plan-setup-v2 WI-1). A board, not a wizard: each
/// row is a fact about now — dictionaries added (none are bundled), Accessibility granted, the shortcut registered,
/// hover on, the Service enabled, Apple's Look Up triggers off, a meaning source chosen — so a
/// permission granted in System Settings completes its row with no relaunch, and setting up again is only opening the
/// pane. The order is the recommended path; nothing is remembered.
public struct SetupBoard: Equatable, Sendable {
    public enum Step: String, CaseIterable, Identifiable, Sendable {
        case dictionaries, accessibility, shortcut, hover, services, appleLookUp, spotlight, ai

        public var id: String { rawValue }

        /// **The three a working XDict needs** (plan-setup-v2 "Required vs optional"). The rest are recommended or
        /// optional, and a reader who leaves them alone has a working XDict and a board that says so.
        public var isRequired: Bool {
            switch self {
            case .dictionaries, .accessibility, .shortcut: true
            case .hover, .services, .appleLookUp, .spotlight, .ai: false
            }
        }
    }

    public enum State: Equatable, Sendable {
        case done
        /// A required row whose fact is not there yet.
        case needed
        /// Read, and failed in a way choosing again fixes: the shortcut is taken by another app.
        case problem
        /// A fact XDict could not read. Gray, and never green: a guess here is worse than saying "check".
        case needsCheck
        /// An optional row whose fact is not there, which is allowed.
        case optional
    }

    /// Dictionaries that answer lookups.
    public var dictionaries: Int
    /// Whether macOS trusts XDict with Accessibility.
    public var trusted: Bool
    /// Whether the lookup shortcut is registered.
    public var shortcutWorks: Bool
    /// Whether the reader has hover on.
    public var hoverOn: Bool
    /// The lookup shortcut's own symbol, as `HoverModifier.symbol` writes it ("⌥"): what the reader holds or taps.
    public var hoverKey: String
    /// Whether the reader's gesture is a double tap rather than a hold.
    public var hoverDoubleTap: Bool
    /// Whether the Service is switched on, as `pbs` says; `.unreadable` when it cannot be read.
    public var services: SystemFact
    /// Apple's three Look Up triggers.
    public var appleLookUp: AppleLookUp
    /// Whether the reader included the library's headwords in Spotlight (plan-setup-v2 WI-6; ADR-0028).
    public var spotlightEnabled: Bool
    /// **Whether the last Spotlight run failed** (audit-fix 2026-10-22 finding 7): the switch records it, and the row
    /// must say so rather than read `done` over a run that achieved nothing.
    public var spotlightFailed: Bool
    /// Whether a meaning source is set up.
    public var aiConfigured: Bool

    /// The new inputs default to the honest unknown: an optional row nobody read says "off"/"check", never "done".
    public init(dictionaries: Int, trusted: Bool, shortcutWorks: Bool, hoverOn: Bool = false, hoverKey: String = "⌥",
                hoverDoubleTap: Bool = false, services: SystemFact = .unreadable, appleLookUp: AppleLookUp = AppleLookUp(),
                spotlightEnabled: Bool = false, spotlightFailed: Bool = false, aiConfigured: Bool = false) {
        self.dictionaries = dictionaries
        self.trusted = trusted
        self.shortcutWorks = shortcutWorks
        self.hoverOn = hoverOn
        self.hoverKey = hoverKey
        self.hoverDoubleTap = hoverDoubleTap
        self.services = services
        self.appleLookUp = appleLookUp
        self.spotlightEnabled = spotlightEnabled
        self.spotlightFailed = spotlightFailed
        self.aiConfigured = aiConfigured
    }

    public func state(of step: Step) -> State {
        switch reading(of: step) {
        case .ready: return .done
        case .failed: return .problem
        case .unreadable: return .needsCheck
        case .absent: return step.isRequired ? .needed : .optional
        }
    }

    /// What the row's own facts say, before requiredness decides how loudly to say it.
    private enum Reading { case ready, absent, failed, unreadable }

    private func reading(of step: Step) -> Reading {
        switch step {
        case .dictionaries: return dictionaries > 0 ? .ready : .absent
        case .accessibility: return trusted ? .ready : .absent
        case .shortcut: return shortcutWorks ? .ready : .failed
        case .hover: return hoverOn ? .ready : .absent
        case .services: return Self.reading(services)
        case .appleLookUp:
            if appleLookUp.isUnreadable { return .unreadable }
            return appleLookUp.isClear ? .ready : .absent
        case .spotlight:
            // A run that achieved nothing is the row's problem whatever the switch says: a failed deletion still left
            // the index as it was (audit-fix 2026-10-22 finding 7).
            if spotlightFailed { return .failed }
            return spotlightEnabled ? .ready : .absent
        case .ai: return aiConfigured ? .ready : .absent
        }
    }

    private static func reading(_ fact: SystemFact) -> Reading {
        switch fact {
        case .ready: return .ready
        case .waiting: return .absent
        case .unreadable: return .unreadable
        }
    }

    /// **Every required row is done** — not every row: a reader who leaves hover, the Service, Apple's triggers and AI
    /// alone has a working XDict (`Summary.needsUser` is empty).
    public var isComplete: Bool {
        summary.needsUser.isEmpty
    }

    /// What the footer says, as steps, in the board's order: what is verified, what still needs the reader, and what
    /// is optional and left undone.
    public struct Summary: Equatable, Sendable {
        public let verified: [Step]
        public let needsUser: [Step]
        public let optionalLeft: [Step]
    }

    public var summary: Summary {
        var verified: [Step] = [], needsUser: [Step] = [], optionalLeft: [Step] = []
        for step in Step.allCases {
            if state(of: step) == .done {
                verified.append(step)
            } else if step.isRequired {
                needsUser.append(step)
            } else {
                optionalLeft.append(step)
            }
        }
        return Summary(verified: verified, needsUser: needsUser, optionalLeft: optionalLeft)
    }

    public static func title(_ step: Step) -> LocalizedStringResource {
        switch step {
        case .dictionaries: LocalizedStringResource("Dictionaries")
        case .accessibility: LocalizedStringResource("Accessibility")
        case .shortcut: LocalizedStringResource("Lookup shortcut")
        case .hover: LocalizedStringResource("Pointer gesture")
        case .services: LocalizedStringResource("Look Up in XDict Service")
        case .appleLookUp: LocalizedStringResource("Apple’s Look Up")
        case .spotlight: LocalizedStringResource("Spotlight")
        case .ai: LocalizedStringResource("AI")
        }
    }

    /// **The one sentence every row says when XDict could not read its fact** (plan-setup-v2 step 6): the same words
    /// in every such row, because the next action is the same and a reader comparing rows should not have to.
    public static let checkInSystemSettings = LocalizedStringResource("Check this in System Settings")

    public func detail(_ step: Step) -> LocalizedStringResource {
        let state = state(of: step)
        // **A fact nobody read is said first, and nothing else is claimed over it.** Every other state below picks
        // between what the row says when it is done and when it is not; a state a step cannot reach takes the "not"
        // sentence, which is the true one for every optional row and for a failure retrying fixes.
        if state == .needsCheck { return Self.checkInSystemSettings }
        switch step {
        case .dictionaries:
            return state == .done
                ? LocalizedStringResource("Dictionaries answering lookups: \(dictionaries).")
                : LocalizedStringResource("XDict comes with no dictionaries. Add your own MDict files (.mdx and .mdd).")
        case .accessibility:
            return state == .done
                ? LocalizedStringResource("Granted. The shortcut can read the selection in any app.")
                : LocalizedStringResource("""
                    Needed to read the word you select in another app. Turn XDict on in System Settings ▸ Privacy & \
                    Security ▸ Accessibility; this row updates by itself.
                    """)
        case .shortcut:
            return state == .done
                ? LocalizedStringResource("Select a word anywhere and press the shortcut to look it up.")
                : LocalizedStringResource("The shortcut is in use by another app. Choose another one.")
        case .hover:
            // The verb carries the gesture and the key is the key itself: "Tap ⌥ twice", never "Tap ⌥⌥ twice".
            switch (state, hoverDoubleTap) {
            case (.done, true):
                return LocalizedStringResource(
                    "Tap \(hoverKey) twice with the pointer resting on a word. Change the key in General.")
            case (.done, false):
                return LocalizedStringResource(
                    "Hold \(hoverKey) and rest the pointer on a word in any app. Change the key in General.")
            case (_, true):
                return LocalizedStringResource("""
                    Off. Turn it on to look up the word under the pointer: tap \(hoverKey) twice with it resting on a \
                    word, in any app, with no BetterTouchTool.
                    """)
            case (_, false):
                return LocalizedStringResource("""
                    Off. Turn it on to look up the word under the pointer: hold \(hoverKey) and rest it on a word, in \
                    any app, with no BetterTouchTool.
                    """)
            }
        case .services:
            return state == .done
                ? LocalizedStringResource("The service is on: Look Up in XDict is in every app’s Services menu.")
                : LocalizedStringResource("""
                    macOS 26 and later needs you to turn this on: open Keyboard Shortcuts, then Services, and tick Look \
                    Up in XDict. XDict must be signed for the service to appear.
                    """)
        case .appleLookUp:
            return state == .done
                ? LocalizedStringResource("""
                    All three of Apple’s Look Up triggers are off: its keyboard shortcut, its three-finger tap and its \
                    own dictionaries.
                    """)
                : LocalizedStringResource("""
                    Nothing here is required, but whatever Apple’s Look Up still has on shows its own panel before \
                    XDict’s. The lines below say what is on.
                    """)
        case .spotlight:
            return state == .done
                ? LocalizedStringResource("""
                    Included: a Spotlight search for a headword finds it, and Return opens it in XDict. The index \
                    holds the words only, and stays on this Mac.
                    """)
                : LocalizedStringResource("""
                    Off. Include your dictionaries’ headwords in Spotlight to find them while you search — the \
                    words only, on this Mac.
                    """)
        case .ai:
            return state == .done
                ? LocalizedStringResource("A source is chosen in Settings ▸ AI. Whether it answers is checked there.")
                : LocalizedStringResource("Off. Choose a source in Settings ▸ AI to look up a meaning in context.")
        }
    }

    // MARK: - Apple's Look Up, part by part (the row's three lines)

    public static func appleLookUpTitle(_ part: AppleLookUp.Part) -> LocalizedStringResource {
        switch part {
        case .shortcut: LocalizedStringResource("Keyboard shortcut")
        case .trackpad: LocalizedStringResource("Three-finger tap")
        case .dictionaries: LocalizedStringResource("Apple’s dictionaries")
        }
    }

    /// One part's line: what it is doing now, and the one place to change it. The count Apple's dictionaries carry is
    /// read from the probe, so the row names it rather than saying "some are on".
    public func appleLookUpDetail(_ part: AppleLookUp.Part) -> LocalizedStringResource {
        switch (part, appleLookUp.fact(part)) {
        // **A part XDict could not read says so, and says nothing else** (audit-fix 2026-10-22): the row is
        // `.needsCheck` as a whole, and a line asserting "On. Turn it off" over a fact nobody read is the guess this
        // board exists to avoid.
        case (_, .unreadable):
            Self.checkInSystemSettings
        case (.shortcut, .ready):
            LocalizedStringResource("Off. Apple’s Look Up shortcut does nothing.")
        case (.shortcut, _):
            LocalizedStringResource("On. Turn off Look Up in Dictionary under Keyboard Shortcuts ▸ Services.")
        case (.trackpad, .ready):
            LocalizedStringResource("Off. A three-finger tap does not look a word up.")
        case (.trackpad, _):
            LocalizedStringResource("""
                On. Turn off Look Up & data detectors in Trackpad; Force Click is in the same pane.
                """)
        case (.dictionaries, .ready):
            LocalizedStringResource("None of Apple’s dictionaries is active in Dictionary.app.")
        case (.dictionaries, .waiting(let count?)):
            LocalizedStringResource("\(count) Apple dictionaries are in use in Dictionary.app.")
        case (.dictionaries, _):
            LocalizedStringResource("Apple’s own dictionaries are active in Dictionary.app.")
        }
    }
}

/// **The setup pane as the E2E stage reads it from outside** (`Tools/lookup/keys.swift ax`; G7, 2026-10-18): SwiftUI does
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

/// **Whether the setup pane speaks only Chinese** (E2E `setup.chineseOnly`): the English it still shows, from the texts
/// its Accessibility tree read; and the verdict, which fails on no text at all, since an empty tree (a pane not yet
/// drawn, or read before it was) has no English in it and would otherwise pass without reading anything.
public enum SetupLanguageCheck {
    /// A run of three Latin letters that is not one of the names kept in Latin in every language: XDict's own (XDict,
    /// MDict, mdx, mdd), Apple's brand and system names as Apple's own Chinese writes them ("任何 App", "Apple 词典",
    /// "macOS 26", "Control 键"), and the modifier keys. Whole words only, so "Applications" still counts.
    public static func isEnglish(_ text: String) -> Bool {
        text.split { !($0.isASCII && $0.isLetter) }.contains { $0.count >= 3 && !keptNames.contains($0.lowercased()) }
    }

    /// Lowercase, compared lowercased: written as the names, these would read as prose to the string catalog's check.
    /// **"apple", "mac", "macos" and "spotlight" joined this list on 2026-10-22** (plan-setup-v2 WI-5, WI-6): the board's rows
    /// name Apple's own Look Up, macOS's version and the Spotlight switch, and Apple's Simplified Chinese writes all
    /// three in Latin — "Apple 词典", "macOS 26", "Spotlight" — so counting them as English would demand Chinese that
    /// Apple itself does not use. An untranslated sentence is still caught by every other word in it.
    private static let keptNames: Set<String> = ["xdict", "mdict", "mdx", "mdd", "app", "apple", "mac", "macos",
                                                 "spotlight", "control", "option", "command", "shift"]

    public static func english(in texts: [String]) -> [String] { texts.filter(isEnglish) }

    /// Some text was read, none of it English, and the first preferred language is Chinese.
    public static func chineseOnly(texts: [String], preferredLanguage: String?) -> Bool {
        !texts.isEmpty && english(in: texts).isEmpty && preferredLanguage?.hasPrefix("zh") == true
    }
}
