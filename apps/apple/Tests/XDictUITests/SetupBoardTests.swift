import Foundation
import Testing
import XDictAnywhere
import XDictUI

/// **The setup board reads live state, every time** (plan-macos-v1 WI-9; adapted from XiaolaiDict's `SetupBoardTests`;
/// ordered, required/optional and `needsCheck` by plan-setup-v2 WI-1): each row is a fact about now, so a permission
/// granted in System Settings completes its row with no relaunch and no remembered progress, and an optional row left
/// alone leaves the board complete.
struct SetupBoardTests {
    /// Every fact read and ready: what a fully set-up account's board says.
    static func ready(dictionaries: Int = 3) -> SetupBoard {
        SetupBoard(dictionaries: dictionaries, trusted: true, shortcutWorks: true, hoverOn: true,
                   screenRecording: .allowed, services: .ready,
                   appleLookUp: AppleLookUp(shortcut: .ready, trackpad: .ready, dictionaries: .ready),
                   spotlightEnabled: true, aiConfigured: true)
    }

    /// Every fact read, and in the state the reader must change: the board nothing is set up on shows. Its lookup
    /// shortcut failed to register, which is the one state whose line is its own.
    static func fresh() -> SetupBoard {
        SetupBoard(dictionaries: 0, trusted: false, shortcutWorks: false,
                   services: .waiting(count: nil),
                   appleLookUp: AppleLookUp(shortcut: .waiting(count: nil), trackpad: .waiting(count: nil),
                                            dictionaries: .waiting(count: 3)))
    }

    @Test func aFreshAccountNeedsDictionariesAndAccessibility() {
        let board = SetupBoard(dictionaries: 0, trusted: false, shortcutWorks: true)
        #expect(board.state(of: .dictionaries) == .needed)
        #expect(board.state(of: .accessibility) == .needed)
        #expect(board.state(of: .shortcut) == .done)
        #expect(!board.isComplete)
    }

    @Test func aGrantCompletesItsRowAlone() {
        let before = SetupBoard(dictionaries: 2, trusted: false, shortcutWorks: true)
        let after = SetupBoard(dictionaries: 2, trusted: true, shortcutWorks: true)
        #expect(before.state(of: .accessibility) == .needed)
        #expect(after.state(of: .accessibility) == .done)
        #expect(before.state(of: .dictionaries) == after.state(of: .dictionaries))
        #expect(after.isComplete)
        #expect(!before.isReadyForOtherApps)
        #expect(after.isReadyForOtherApps)
    }

    /// **A shortcut that cannot register is a problem of lookup from other apps**, not of XDict's own window (UI38).
    @Test func aShortcutThatCannotRegisterIsAProblem() {
        let board = SetupBoard(dictionaries: 1, trusted: true, shortcutWorks: false)
        #expect(board.state(of: .shortcut) == .problem)
        #expect(board.isComplete, "the window looks words up without a global shortcut")
        #expect(!board.isReadyForOtherApps)
        #expect(board.summary.otherAppsNeed == [.shortcut])
    }

    /// **The order is the recommended path** (plan-setup-v2's table), and each row says something of its own in each
    /// state it can be in.
    @Test func eachRowSaysItsOwnState() {
        #expect(SetupBoard.Step.allCases == [.dictionaries, .accessibility, .screenRecording, .shortcut, .hover,
                                             .services, .appleLookUp, .spotlight, .ai])
        let fresh = Self.fresh()
        let ready = Self.ready()
        var sentences: [String] = []
        for step in SetupBoard.Step.allCases {
            sentences.append(String(localized: SetupBoard.title(step)))
            sentences.append(String(localized: fresh.detail(step)))
            sentences.append(String(localized: ready.detail(step)))
        }
        #expect(Set(sentences).count == sentences.count, "\(sentences)")
        #expect(String(localized: ready.detail(.dictionaries)) == "Dictionaries answering lookups: 3.")
    }

    /// **Only dictionaries are required to look a word up in XDict's window** (UI38, owner-approved 2026-10-23,
    /// reopening plan-setup-v2's "Required vs optional"): Accessibility and the global shortcut are required for lookup
    /// from other apps, and only for it.
    @Test func onlyDictionariesAreRequiredForXDictsOwnWindow() {
        #expect(SetupBoard.Step.allCases.filter(\.isRequired) == [.dictionaries])
        #expect(SetupBoard.Step.allCases.filter(\.isRequiredForOtherApps) == [.accessibility, .shortcut])
        #expect(SetupBoard.Step.allCases.filter { !$0.isRequired && !$0.isRequiredForOtherApps }
            == [.screenRecording, .hover, .services, .appleLookUp, .spotlight, .ai])
    }

    /// **Progressive setup** (UI37): the board's rows in three groups, in the recommended order — XDict's own window
    /// first, lookup from other apps next, the rest last — and each group in the board's order.
    @Test func theRowsComeInThreeGroups() {
        #expect(SetupBoard.Group.allCases == [.inXDict, .otherApps, .more])
        #expect(SetupBoard.Group.inXDict.steps == [.dictionaries])
        #expect(SetupBoard.Group.otherApps.steps == [.accessibility, .screenRecording, .shortcut, .hover, .services,
                                                     .appleLookUp])
        #expect(SetupBoard.Group.more.steps == [.spotlight, .ai])
        #expect(SetupBoard.Group.allCases.flatMap(\.steps) == SetupBoard.Step.allCases)
    }

    /// **A reader who uses only the window finishes setup with no permission granted** (UI38 acceptance): dictionaries
    /// added, Accessibility not granted, and the board is complete — while lookup from other apps says what it needs.
    @Test func theWindowIsReadyWithoutAccessibility() {
        let board = SetupBoard(dictionaries: 2, trusted: false, shortcutWorks: true)
        #expect(board.isComplete)
        #expect(board.summary.needsUser.isEmpty)
        #expect(board.summary.otherAppsNeed == [.accessibility])
        #expect(!board.isReadyForOtherApps)
        #expect(!board.summary.optionalLeft.contains(.accessibility), "said once, in its own line")
        // The row itself still says the grant is needed — for the group it belongs to (`setup.accessibility.needed`).
        #expect(board.state(of: .accessibility) == .needed)
    }

    /// **Screen Recording is a row of the board** (owner, 2026-10-23: setup did not include the grant hover's screen
    /// reading needs, so the reader had to find it elsewhere): allowed is done, a refusal is a problem with its own
    /// sentence, a grant nobody could read is "check", and leaving it unset is optional — as a working XDict is.
    @Test func theScreenRecordingRowFollowsTheGrant() {
        var board = SetupBoard(dictionaries: 1, trusted: true, shortcutWorks: true)
        #expect(board.state(of: .screenRecording) == .optional, "unset is not a failure")
        #expect(!SetupBoard.Step.screenRecording.isRequired)
        board.screenRecording = .allowed
        #expect(board.state(of: .screenRecording) == .done)
        board.screenRecording = .notAllowed
        #expect(board.state(of: .screenRecording) == .problem)
        board.screenRecording = .couldNotTell
        #expect(board.state(of: .screenRecording) == .needsCheck)
    }

    /// **An optional row's switch off is `.optional`, not a failure**, and the board is complete regardless.
    @Test func anOptionalStepLeftOffLeavesTheBoardComplete() {
        let board = SetupBoard(dictionaries: 2, trusted: true, shortcutWorks: true)
        for step in SetupBoard.Step.allCases where !step.isRequired {
            #expect(board.state(of: step) != .needed, "\(step) is optional")
        }
        #expect(board.state(of: .hover) == .optional)
        #expect(board.state(of: .ai) == .optional)
        #expect(board.isComplete)
    }

    /// **A fact XDict could not read is never green** (plan-setup-v2 step 6): every probe-backed row says so, with the
    /// one sentence, and no guess is drawn as done.
    @Test func aFactThatCannotBeReadIsNeverDone() {
        let board = SetupBoard(dictionaries: 2, trusted: true, shortcutWorks: true)
        #expect(board.services == .unreadable, "a board nobody probed says so")
        #expect(board.state(of: .services) == .needsCheck)
        #expect(board.state(of: .appleLookUp) == .needsCheck, "all three parts default to unreadable")
        #expect(String(localized: board.detail(.services)) == "Check this in System Settings")
        #expect(String(localized: board.detail(.appleLookUp)) == "Check this in System Settings")
        #expect(String(localized: SetupBoard.checkInSystemSettings) == "Check this in System Settings")
    }

    /// One unreadable part is enough: the row never claims the other two are the whole story.
    @Test func oneUnreadableAppleTriggerMakesTheRowUnreadable() {
        var board = Self.ready()
        board.appleLookUp.trackpad = .unreadable
        #expect(board.state(of: .appleLookUp) == .needsCheck)
    }

    /// **Apple's triggers are `.done` only when all three are off** (WI-5's acceptance), and the row is optional when
    /// one is on, so the board never calls a complete setup incomplete over them.
    @Test func applesTriggersAreDoneOnlyWhenAllThreeAreOff() {
        var board = Self.ready()
        board.appleLookUp.dictionaries = .waiting(count: 3)
        #expect(board.state(of: .appleLookUp) == .optional)
        #expect(board.isComplete)
        #expect(String(localized: board.appleLookUpDetail(.dictionaries))
            == "3 Apple dictionaries are in use in Dictionary.app.")
        board.appleLookUp.dictionaries = .ready
        board.appleLookUp.shortcut = .waiting(count: nil)
        #expect(board.state(of: .appleLookUp) == .optional)
        #expect(String(localized: board.appleLookUpDetail(.shortcut))
            .hasPrefix("On. Turn off Look Up in Dictionary"), "the line names which trigger is on")
        #expect(String(localized: SetupBoard.appleLookUpTitle(.shortcut)) == "Keyboard shortcut")
    }

    /// **The Spotlight switch is a row like the others** (plan-setup-v2 WI-6; ADR-0028): off is `.optional`, on is
    /// `.done`, and neither the board nor the summary calls a reader who leaves it off incomplete.
    @Test func theSpotlightRowFollowsTheSwitch() {
        var board = SetupBoard(dictionaries: 1, trusted: true, shortcutWorks: true)
        #expect(board.state(of: .spotlight) == .optional)
        #expect(board.isComplete)
        board.spotlightEnabled = true
        #expect(board.state(of: .spotlight) == .done)
        #expect(String(localized: board.detail(.spotlight)).hasPrefix("Included:"))
        board.spotlightEnabled = false
        #expect(String(localized: board.detail(.spotlight)).hasPrefix("Off."))
        #expect(SetupBoard.Step.spotlight.isRequired == false, "the reader's library is not the system's")
    }

    /// **A run that failed is a problem, not a done row** (audit-fix 2026-10-22 finding 7): the switch records the run,
    /// and the row says so whether it is on or off — a failed deletion still left the index as it was.
    @Test func aFailedSpotlightRunIsAProblem() {
        var board = SetupBoard(dictionaries: 1, trusted: true, shortcutWorks: true, spotlightEnabled: true)
        #expect(board.state(of: .spotlight) == .done)
        board.spotlightFailed = true
        #expect(board.state(of: .spotlight) == .problem)
        board.spotlightEnabled = false
        #expect(board.state(of: .spotlight) == .problem, "a failed deletion says nothing about the switch")
        board.spotlightFailed = false
        #expect(board.state(of: .spotlight) == .optional)
    }

    /// **The summary says what is verified, what still needs the reader, and what is optional and left** — and
    /// `isComplete` is exactly "nothing needs the reader".
    @Test func theSummarySaysWhatIsLeft() {
        let fresh = Self.fresh()
        #expect(fresh.summary.verified == [])
        #expect(fresh.summary.needsUser == [.dictionaries])
        #expect(fresh.summary.otherAppsNeed == [.accessibility, .shortcut])
        #expect(fresh.summary.optionalLeft == [.screenRecording, .hover, .services, .appleLookUp, .spotlight, .ai])
        #expect(fresh.summary.needsUser.isEmpty == fresh.isComplete)

        let ready = Self.ready()
        #expect(ready.summary.verified == SetupBoard.Step.allCases)
        #expect(ready.summary.needsUser.isEmpty)
        #expect(ready.summary.optionalLeft.isEmpty)
        #expect(ready.summary.otherAppsNeed.isEmpty)
        #expect(ready.isComplete)
        #expect(ready.isReadyForOtherApps)

        var almost = Self.ready()
        almost.aiConfigured = false
        #expect(almost.summary.optionalLeft == [.ai])
        #expect(almost.isComplete, "a meaning source is not required for a working XDict")
    }

    /// **The pointer gesture's line names the key and the gesture the reader actually has** (plan-setup-v2 WI-4): the
    /// same sentence for a hold and a double tap would tell a double-tap reader to hold a key.
    @Test func theHoverLineNamesTheKeyAndTheGesture() {
        var board = Self.ready()
        #expect(String(localized: board.detail(.hover)).hasPrefix("Hold ⌥ and rest the pointer"))
        // The verb carries the gesture and the key is the key itself: "Tap ⌥ twice", never "Tap ⌥⌥ twice".
        board.hoverDoubleTap = true
        #expect(String(localized: board.detail(.hover)).hasPrefix("Tap ⌥ twice"))
        board.hoverOn = false
        #expect(board.state(of: .hover) == .optional)
        #expect(String(localized: board.detail(.hover)).hasPrefix("Off. Turn it on"))
        #expect(String(localized: board.detail(.hover)).contains("⌥"), "the key is named while it is off too")
    }

    /// **A part XDict could not read is never drawn as on** (audit finding, 2026-10-22): the row as a whole says
    /// "check", and each of its three lines does too, rather than telling the reader to turn off something nobody read.
    @Test func anUnreadableAppleTriggerSaysCheckOnItsOwnLineToo() {
        var board = Self.ready()
        board.appleLookUp.trackpad = .unreadable
        #expect(board.state(of: .appleLookUp) == .needsCheck)
        #expect(String(localized: board.appleLookUpDetail(.trackpad)) == "Check this in System Settings")
        #expect(String(localized: board.appleLookUpDetail(.shortcut)).hasPrefix("Off."), "a part that was read keeps its line")
        #expect(String(localized: board.appleLookUpDetail(.dictionaries))
            == "None of Apple’s dictionaries is active in Dictionary.app.")
        // A board nobody probed: all three say so, and none of them claims to know.
        let unread = SetupBoard(dictionaries: 2, trusted: true, shortcutWorks: true)
        for part in AppleLookUp.Part.allCases {
            #expect(String(localized: unread.appleLookUpDetail(part)) == "Check this in System Settings", "\(part)")
        }
    }

    /// **Every row that can be reached says something no other row says** (plan-setup-v2 WI-1: "every sentence
    /// unique") — the one exception being the sentence every unreadable row shares on purpose.
    @Test func everyReachableLineIsItsOwn() {
        // One sentence per reachable (step, state): two boards in the same state must not be counted twice, or the test
        // would fail on the board rather than on the writing.
        var lines: [String: String] = [:]
        for board in [Self.fresh(), Self.ready(), SetupBoard(dictionaries: 1, trusted: true, shortcutWorks: false),
                      SetupBoard(dictionaries: 1, trusted: true, shortcutWorks: true)] {
            for step in SetupBoard.Step.allCases {
                let key = "\(step.rawValue).\(board.state(of: step))"
                if lines[key] == nil { lines[key] = String(localized: board.detail(step)) }
            }
        }
        let shared = String(localized: SetupBoard.checkInSystemSettings)
        let own = lines.filter { $0.value != shared }.map(\.value)
        let repeated = Set(own.filter { line in own.filter { $0 == line }.count > 1 })
        #expect(repeated.isEmpty, "\(repeated) — \(lines.filter { repeated.contains($0.value) })")
    }

    /// What the pointer gesture's part lines say, so a reader is told which of the three is on rather than "some are".
    @Test func eachAppleTriggerHasItsOwnLine() {
        let fresh = Self.fresh()
        let lines = AppleLookUp.Part.allCases.map { String(localized: fresh.appleLookUpDetail($0)) }
        #expect(Set(lines).count == 3, "\(lines)")
        #expect(lines[0].hasPrefix("On. Turn off Look Up in Dictionary"))
        #expect(lines[1].hasPrefix("On. Turn off Look Up & data detectors"))
        #expect(lines[2] == "3 Apple dictionaries are in use in Dictionary.app.")
        let ready = Self.ready()
        #expect(String(localized: ready.appleLookUpDetail(.dictionaries)) == "None of Apple’s dictionaries is active in Dictionary.app.")
    }

    /// **The setup pane as the stage reads it from outside** (`keys ax`, lookup E2E G7, 2026-10-18): SwiftUI does not
    /// expose the rows to a walk from inside the app, so the setup checks read the external walk's nodes: every
    /// identifier, and the texts of the window's content (its first child), not its title bar.
    @Test func theSetupWindowIsReadFromTheExternalWalk() throws {
        func node(_ role: String, _ id: String = "", texts: [String] = [], depth: Int) -> [String: Any] {
            ["role": role, "id": id, "texts": texts, "depth": depth]
        }
        let nodes = [node("AXWindow", "setup", texts: ["Set Up XDict"], depth: 0), node("AXGroup", depth: 1),
                     node("AXGroup", "setup.dictionaries.needed", depth: 2),
                     node("AXStaticText", texts: ["词典"], depth: 3),
                     node("AXGroup", "setup.accessibility.done", depth: 2),
                     node("AXButton", "shortcut.recorder", texts: ["查词快捷键"], depth: 3),
                     node("AXStaticText", texts: ["Set Up XDict"], depth: 1)]
        let data = try JSONSerialization.data(withJSONObject: ["nodes": nodes, "truncated": false])
        let read = try #require(SetupWindowReading.nodes(fromKeysAX: data))
        #expect(SetupWindowReading.identifiers(read).isSuperset(of: ["setup.dictionaries.needed",
                                                                    "setup.accessibility.done", "shortcut.recorder"]))
        #expect(SetupWindowReading.contentTexts(read) == ["词典", "查词快捷键"], "the title bar is not the content")
        #expect(SetupWindowReading.contentTexts([]).isEmpty)
        #expect(SetupWindowReading.nodes(fromKeysAX: Data("keys: no access".utf8)) == nil)
        #expect(SetupWindowReading.nodes(fromKeysAX: Data(#"{"nodes": [], "why": "no main window"}"#.utf8))?.isEmpty
            == true)
    }

    /// **`setup.chineseOnly` reads something before it passes**: an empty Accessibility tree has no English in it, and
    /// passed the check without the window having been read (lookup E2E diagnosis, 2026-10-18).
    @Test func chineseOnlyFailsWhenNothingWasRead() {
        #expect(!SetupLanguageCheck.chineseOnly(texts: [], preferredLanguage: "zh-Hans-CN"))
        #expect(SetupLanguageCheck.chineseOnly(texts: ["词典", "XDict 设置"], preferredLanguage: "zh-Hans-CN"))
        #expect(!SetupLanguageCheck.chineseOnly(texts: ["词典", "Accessibility"], preferredLanguage: "zh-Hans-CN"))
        #expect(!SetupLanguageCheck.chineseOnly(texts: ["词典"], preferredLanguage: "en-US"))
        #expect(SetupLanguageCheck.english(in: ["词典", "Add Dictionaries", "mdx"]) == ["Add Dictionaries"])
    }

    /// **Apple's Simplified Chinese keeps its own names in Latin letters** — "任何 App", "Apple 词典", "macOS 26",
    /// "Control 键" — so a translated string holding them is not English left behind (E2E re-run, 2026-10-18: the
    /// window's two such strings were reported as English once the check read the window; "Apple" and "macOS" joined
    /// the list on 2026-10-22). A whole word only: an untranslated sentence still counts, word by word.
    @Test func applesLatinNamesInChineseAreNotEnglish() {
        #expect(!SetupLanguageCheck.isEnglish("已授权。快捷键可以读取任何 App 中选中的文字。"))
        #expect(!SetupLanguageCheck.isEnglish("查询快捷键，Control-Option-D"))
        #expect(!SetupLanguageCheck.isEnglish("Command-Shift-L"))
        #expect(!SetupLanguageCheck.isEnglish("Apple 词典"))
        #expect(!SetupLanguageCheck.isEnglish("macOS 26 及更高版本需要你手动开启"))
        #expect(!SetupLanguageCheck.isEnglish("收录到 Spotlight 中"), "a product name, as Apple writes it")
        #expect(!SetupLanguageCheck.isEnglish("索引只含词头，保存在这台 Mac 上。"), "Apple's Chinese writes \"Mac\"")
        #expect(SetupLanguageCheck.isEnglish("Granted. The shortcut can read the selection in any app."))
        #expect(SetupLanguageCheck.isEnglish("Look Up in Dictionary under Keyboard Shortcuts"))
        #expect(SetupLanguageCheck.isEnglish("Applications"), "a word that merely starts like a kept name")
        #expect(SetupLanguageCheck.isEnglish("Apple 的查询 Look Up"), "an English word beside a kept name is still English")
    }
}
