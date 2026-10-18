import Foundation
import Testing
import XDictTestSupport

/// **Every button of the shell is placed by the shared blocks, or named as an exclusion** (owner, 2026-10-18: one set
/// of rules, not piecemeal fixes). `Sources/XDictUI/ActionLayout.swift` holds the rules (R1–R5) and the blocks:
/// `ActionRow`, `TrailingActions`, `ProgressRow`, `SheetFooter`, `EmptyStateActions`.
///
/// Three checks over the shell's sources, each with a positive control below:
/// - **A, every button is in a block's action slot** (not its sentence), or under an exclusion marker: a button under
///   its sentence in a `VStack`, or anywhere else by hand, fails.
/// - **B, no control after a `Spacer` in one `HStack`**: a trailing action pushed there by hand.
/// - **C, no size, key or style by hand**: `.controlSize(`, AppKit's `controlSize = .`, Return or Escape bound by hand,
///   a bordered or tinted style.
///
/// **An exclusion is a marker on the very line**: `// placement: <id>`, the id one of `exclusions` below. On a line
/// that opens a block, it covers the block for check A; checks B and C want it on the line itself, so a second
/// `.borderedProminent` in a marked file still fails.
struct ButtonPlacementTests {
    static let sharedBlocks = "Sources/XDictUI/ActionLayout.swift"
    /// The shell's interface modules: the rest of `Sources/` holds no button.
    static let roots = ["Sources/XDictUI", "Sources/XDict", "Sources/XDictEntryView", "Sources/XDictEntryLab"]

    /// **R6 and the other places Apple's or the system's layout decides** (owner, 2026-10-18): each id a marker may
    /// name, with its parity row (`Tools/parity/apple-dictionary.tsv`) where Apple's measured layout is the reason.
    /// One no marker names fails (`everyExclusionIsUsedAndKnown`), so the list never outlives its sites.
    static let exclusions: [String: String] = [
        "P3": "the toolbar: Back/Forward and Smaller/Bigger Text, Apple's segmented pairs (SearchWindow.toolbar)",
        "P48": "the toolbar's speaker and Edit ▸ Pronounce, XDict's own addition to Apple's toolbar and Edit menu",
        "P6": "the scope bar's radio buttons and overflow pop-up (ScopeBar; being replaced in parallel, remove then)",
        "P30": "the find bar's chevron pair and Done (EntryFindBar)",
        "P31": "the app menu: Set Up XDict…, Acknowledgments",
        "P32": "the File menu: New Tab, Add Dictionaries…, Print…",
        "P33": "the Edit menu's Find submenu",
        "P34": "the View menu: text size, Expand and Collapse All",
        "P35": "the Go menu",
        "P36": "the Search menu: the scope list",
        "P38": "the Help menu: XDict Help",
        "P39": "Settings ▸ Dictionaries' table: its checkbox column and the + menu and − button under it",
        "P41": "the lookup popover: the speaker in its title row and its two footer rows",
        "menu-bar-extra": "XDict's menu-bar item's menu, a menu the system lays out; Apple's Dictionary has none",
        "system-alert": "an NSAlert: AppKit puts the default rightmost with Return and Cancel left of it with Escape (R3)",
        "glyph": "an icon-only button at its symbol's own size, beside what it acts on (a notice's close, Copy)",
        "spinner": "a small spinner while a pane loads, not a button",
        "shortcut-field": "the shortcut recorder, a field drawn as a button, placed by its container",
        "form-row": "a button as a grouped Form's LabeledContent value, which the system puts trailing (R5)",
    ]

    struct Finding: Equatable, CustomStringConvertible {
        let file: String
        let line: Int
        let rule: String
        var description: String { "\(file):\(line) \(rule)" }
    }

    // MARK: - Reading a file's structure

    /// What a `{` opens, for check A: a shared block's sentence slot, one of its action slots, or anything else.
    enum Slot { case sentence, actions, other }

    struct Frame {
        let parent: Int?
        let slot: Slot
        let marker: String?
        let open: Int
        var close: Int
    }

    /// A file's braces, with which characters are code (not a comment or a string) and the innermost brace each sits
    /// in. Strings (raw, multi-line, interpolated), comments and `#/regex/#` literals are skipped.
    struct Structure {
        let characters: [Character]
        var frames: [Frame] = []
        var innermost: [Int?]
        var isCode: [Bool]
        var lineOf: [Int]
        var markers: [Int: String] = [:]
        var balanced = false

        init(_ text: String) {
            characters = Array(text)
            innermost = Array(repeating: nil, count: characters.count)
            isCode = Array(repeating: false, count: characters.count)
            lineOf = Array(repeating: 1, count: characters.count)
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                if let marker = line.firstMatch(of: #/\/\/\s*placement:\s*([A-Za-z0-9-]+)/#) {
                    markers[index + 1] = String(marker.1)
                }
            }
            read()
        }

        private enum Mode {
            case code(interpolation: Bool, parens: Int)
            case string(multiline: Bool, hashes: Int)
        }

        private func at(_ index: Int) -> Character? { index < characters.count ? characters[index] : nil }

        private func run(of character: Character, from index: Int) -> Int {
            var end = index
            while at(end) == character { end += 1 }
            return end - index
        }

        private mutating func read() {
            var modes: [Mode] = [.code(interpolation: false, parens: 0)]
            var top: Int?
            var lastClosed: [Int: Slot] = [:]
            var line = 1
            var lineStart = 0
            var index = 0
            var marked = 0
            func mark(to end: Int, code: Bool) {
                while marked < min(end, characters.count) {
                    innermost[marked] = top
                    isCode[marked] = code
                    lineOf[marked] = line
                    if characters[marked] == "\n" {
                        line += 1
                        lineStart = marked + 1
                    }
                    marked += 1
                }
            }
            while index < characters.count {
                guard let mode = modes.last else { return }
                let character = characters[index]
                switch mode {
                case .code(let interpolation, let parens):
                    if character == "/", at(index + 1) == "/" {
                        var end = index
                        while let next = at(end), next != "\n" { end += 1 }
                        mark(to: end, code: false)
                        index = end
                    } else if character == "/", at(index + 1) == "*" {
                        var end = index + 2
                        while end < characters.count, !(characters[end] == "*" && at(end + 1) == "/") { end += 1 }
                        mark(to: end + 2, code: false)
                        index = end + 2
                    } else if character == "#" || character == "\"" {
                        let hashes = run(of: "#", from: index)
                        let after = index + hashes
                        if at(after) == "\"" {
                            let multiline = run(of: "\"", from: after) >= 3
                            let end = after + (multiline ? 3 : 1)
                            mark(to: end, code: false)
                            modes.append(.string(multiline: multiline, hashes: hashes))
                            index = end
                        } else if hashes > 0, at(after) == "/" {
                            var end = after + 1
                            while end < characters.count,
                                  !(characters[end] == "/" && run(of: "#", from: end + 1) >= hashes) { end += 1 }
                            mark(to: end + 1 + hashes, code: false)
                            index = end + 1 + hashes
                        } else {
                            mark(to: index + max(hashes, 1), code: true)
                            index += max(hashes, 1)
                        }
                    } else {
                        mark(to: index, code: true)
                        if interpolation, character == "(" {
                            modes[modes.count - 1] = .code(interpolation: true, parens: parens + 1)
                        } else if interpolation, character == ")" {
                            if parens == 0 {
                                mark(to: index + 1, code: true)
                                modes.removeLast()
                                index += 1
                                continue
                            }
                            modes[modes.count - 1] = .code(interpolation: true, parens: parens - 1)
                        } else if character == "{" {
                            let prefix = String(characters[lineStart..<index])
                            let slot: Slot
                            if prefix.firstMatch(of: #/\}\s*,?\s*[A-Za-z]+:\s*$/#) != nil {
                                // `} actions: {`: the next trailing closure of the call whose closure just closed.
                                slot = lastClosed[top ?? -1].map { $0 == .other ? Slot.other : .actions } ?? .other
                            } else if prefix.firstMatch(of: #/\b(ActionRow|ProgressRow)\b/#) != nil {
                                slot = .sentence
                            } else if prefix.firstMatch(of: #/\b(SheetFooter|TrailingActions|EmptyStateActions)\b/#) != nil {
                                slot = .actions
                            } else {
                                slot = .other
                            }
                            frames.append(Frame(parent: top, slot: slot, marker: markers[line], open: index, close: index))
                            top = frames.count - 1
                        } else if character == "}" {
                            guard let closing = top else { return }
                            frames[closing].close = index
                            lastClosed[frames[closing].parent ?? -1] = frames[closing].slot
                            top = frames[closing].parent
                        }
                        mark(to: index + 1, code: true)
                        index += 1
                    }
                case .string(let multiline, let hashes):
                    if character == "\\" {
                        let escapeHashes = run(of: "#", from: index + 1)
                        if escapeHashes == hashes, at(index + 1 + hashes) == "(" {
                            mark(to: index + 2 + hashes, code: false)
                            modes.append(.code(interpolation: true, parens: 0))
                            index += 2 + hashes
                        } else {
                            let skip = escapeHashes >= hashes ? 2 + hashes : 1
                            mark(to: index + skip, code: false)
                            index += skip
                        }
                    } else if character == "\"", run(of: "\"", from: index) >= (multiline ? 3 : 1),
                              run(of: "#", from: index + (multiline ? 3 : 1)) >= hashes {
                        let end = index + (multiline ? 3 : 1) + hashes
                        mark(to: end, code: false)
                        modes.removeLast()
                        index = end
                    } else {
                        mark(to: index + 1, code: false)
                        index += 1
                    }
                }
            }
            mark(to: characters.count, code: true)
            balanced = top == nil && modes.count == 1
        }

        /// Each code match of a pattern, as its first character's index.
        func matches(_ pattern: Regex<AnyRegexOutput>) -> [Int] {
            let text = String(characters)
            // Simple word boundaries: Unicode's put none inside `button.controlSize`, so `\b` would miss it.
            return text.matches(of: pattern.wordBoundaryKind(.simple)).compactMap { match in
                let index = text.distance(from: text.startIndex, to: match.range.lowerBound)
                return index < isCode.count && isCode[index] ? index : nil
            }
        }

        /// Whether a button at `index` is in a block's action slot or under an exclusion marker (check A).
        func isPlaced(_ index: Int) -> Bool {
            if markers[lineOf[index]] != nil { return true }
            var frame = innermost[index]
            while let current = frame {
                if frames[current].marker != nil { return true }
                switch frames[current].slot {
                case .actions: return true
                case .sentence: return false
                case .other: frame = frames[current].parent
                }
            }
            return false
        }
    }

    // MARK: - The checks

    /// Check A's sites: every control that performs an action.
    static var actionControl: Regex<AnyRegexOutput> {
        Regex(#/\b(Button|NSButton|NSPopUpButton|NSSegmentedControl|Menu|CommandMenu|ControlGroup|Link)\s*[({]|\.addButton\(/#)
    }
    /// Check B's: a control of any kind.
    static var anyControl: Regex<AnyRegexOutput> { Regex(#/\b(Button|Toggle|Menu|NSButton|Link|Picker)\s*[({]/#) }
    /// Check C's spellings, and the rule each breaks.
    static var byHand: [(pattern: Regex<AnyRegexOutput>, rule: String)] {
        [
            (Regex(#/\.controlSize\(/#), "a size by hand (R2, R4: the surface decides it)"),
            (Regex(#/\bcontrolSize\s*=\s*\./#), "an AppKit size by hand (R2, R4)"),
            (Regex(#/\.keyboardShortcut\(\s*\.(defaultAction|cancelAction|return|escape)\b/#),
             "Return or Escape bound by hand (R3: SheetFooter binds them)"),
            (Regex(#/\.buttonStyle\(\s*\.bordered/#), "a bordered or prominent style by hand (R3)"),
            (Regex(#/\.tint\(/#), "a tinted button by hand (R3)"),
        ]
    }

    static func findings(file: String, text: String) -> [Finding] {
        let structure = Structure(text)
        guard structure.balanced else {
            return [Finding(file: file, line: 1, rule: "its braces, strings or comments could not be read")]
        }
        var found: [Finding] = []
        let line = { (index: Int) in structure.lineOf[index] }
        for index in structure.matches(actionControl) where !structure.isPlaced(index) {
            found.append(Finding(file: file, line: line(index),
                                 rule: "a button outside the shared blocks' action slots (R1–R5), unmarked"))
        }
        for frame in structure.frames {
            let opening = String(structure.characters[...frame.open].suffix(80))
            guard opening.firstMatch(of: #/\bHStack\b[^{]*\{$/#) != nil else { continue }
            let spacers = structure.matches(Regex(#/Spacer\(/#)).filter { $0 > frame.open && $0 < frame.close }
            guard let spacer = spacers.first else { continue }
            for index in structure.matches(anyControl) where index > spacer && index < frame.close
                && structure.markers[line(index)] == nil {
                found.append(Finding(file: file, line: line(index),
                                     rule: "a control pushed trailing by a Spacer (R1, R2, R5: ActionRow)"))
            }
        }
        for (pattern, rule) in byHand {
            for index in structure.matches(pattern) where structure.markers[line(index)] == nil {
                found.append(Finding(file: file, line: line(index), rule: rule))
            }
        }
        for (marked, id) in structure.markers where exclusions[id] == nil {
            found.append(Finding(file: file, line: marked, rule: "a placement marker naming no exclusion: \(id)"))
        }
        return found.sorted { ($0.line, $0.rule) < ($1.line, $1.rule) }
    }

    static func sources() throws -> [(path: String, text: String)] {
        try roots.flatMap { root in
            let base = Manifest.package.appending(path: root)
            return try SourceScan.files(under: base).map { file, text in
                (root + "/" + file.path.dropFirst(base.path.count + 1), text)
            }
        }
    }

    // MARK: - Over the tree

    /// The scan sees the shell and the blocks: a scan of nothing would pass.
    @Test func theScanReadsTheShell() throws {
        let files = try Self.sources()
        #expect(files.contains { $0.path == Self.sharedBlocks && $0.text.contains("struct ActionRow") })
        #expect(files.contains { $0.path == "Sources/XDictUI/SettingsDictionariesParts.swift" })
        #expect(files.contains { $0.path == "Sources/XDictEntryView/EntryViewController.swift" })
    }

    @Test func everyButtonIsPlacedByTheSharedBlocksOrNamed() throws {
        let stray = try Self.sources().filter { $0.path != Self.sharedBlocks }.flatMap { Self.findings(file: $0.path, text: $0.text) }
        #expect(stray.isEmpty, """
            place these through ActionLayout.swift (ActionRow, ProgressRow, SheetFooter, EmptyStateActions), or mark \
            the line `// placement: <id>` with an id of ButtonPlacementTests.exclusions: \(stray)
            """)
    }

    @Test func everyExclusionIsUsedAndKnown() throws {
        let used = Set(try Self.sources().flatMap { Structure($0.text).markers.values })
        #expect(Set(Self.exclusions.keys).subtracting(used).isEmpty,
                "exclusions no marker names: \(Set(Self.exclusions.keys).subtracting(used).sorted())")
    }

    // MARK: - Positive controls

    static func lines(_ snippet: String) -> [Int] { findings(file: "planted.swift", text: snippet).map(\.line) }

    /// Check A: a button under its sentence in a VStack, in a sentence slot, or in an empty state by hand.
    @Test func checkASeesAButtonOutsideTheBlocks() {
        #expect(Self.lines("""
            VStack(alignment: .leading) {
                Text("A sentence.")
                Button("Open") { open() }
            }
            ActionRow {
                Button("Wrong") { wrong() }
            } actions: {
                Button("Right") { right() }
            }
            ContentUnavailableView {
                Label("Nothing", systemImage: "x")
            } actions: {
                Button("Add") { add() }
            }
            """) == [3, 6, 13])
    }

    @Test func checkALetsTheBlocksAndMarkedSitesThrough() {
        #expect(Self.lines("""
            ActionRow(.strip) {
                Text("A brace { and \\(value) and a \\"quote\\" inside.")
            } secondary: {
                Button("Show") { show() }
            } primary: {
                Button { Task { await go() } } label: { Text("Go") }
            }
            SheetFooter(destructive: {
                Button("Remove", role: .destructive) { remove() }
            }, primary: {
                Button("Done") { done() }
            })
            CommandMenu("Go") {  // placement: P35
                Button("Back") { back() }
            }
            let close = NSButton()  // placement: P30
            let raw = #"a { brace "quoted" \\#(x)"#
            """).isEmpty)
    }

    /// Check B: a Toggle, Menu, NSButton or Link after a Spacer in one HStack.
    @Test func checkBSeesEachControlAfterASpacer() {
        #expect(Self.findings(file: "planted.swift", text: """
            HStack {
                Text("A sentence.")
                Spacer()
                Toggle(isOn: $on) { Text("On") }
                Menu("More") { }
                Link("Site", destination: url)
            }
            """).filter { $0.rule.contains("Spacer") }.map(\.line) == [4, 5, 6])
        #expect(Self.findings(file: "planted.swift", text: "HStack { Spacer(); NSButton(title: \"\", target: nil, action: nil) }")
            .contains { $0.rule.contains("Spacer") })
    }

    /// Check C: each spelling, on an unmarked line; a marker on one line does not cover a second.
    @Test func checkCSeesEachSpellingByHand() {
        #expect(Self.lines("""
            ActionRow { Text("x") } actions: { Button("A") { a() }.controlSize(.small) }
            button.controlSize = .small
            ActionRow { Text("x") } actions: { Button("B") { b() }.keyboardShortcut(.return) }
            ActionRow { Text("x") } actions: { Button("C") { c() }.keyboardShortcut(.escape) }
            ActionRow { Text("x") } actions: { Button("D") { d() }.buttonStyle(.bordered).tint(.red) }
            ProgressView().controlSize(.small)  // placement: spinner
            ProgressView().controlSize(.small)
            // Button("Commented") { }.controlSize(.small)
            """) == [1, 2, 3, 4, 5, 5, 7])
    }

    @Test func aMarkerMustNameAnExclusion() {
        #expect(Self.findings(file: "planted.swift", text: "let b = NSButton()  // placement: P99")
            .map(\.rule).contains { $0.contains("P99") })
    }

    @Test func anUnreadableFileFails() {
        #expect(Self.lines("HStack {\n    Text(\"open\")\n") == [1])
    }
}
