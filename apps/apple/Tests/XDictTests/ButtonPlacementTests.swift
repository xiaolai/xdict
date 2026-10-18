import Foundation
import Testing
import XDictTestSupport

/// **Every button of the shell is placed by the shared blocks** (owner, 2026-10-18: one set of rules, not piecemeal
/// fixes). `Sources/XDictUI/ActionLayout.swift` holds the rules (R1–R5): a pane's sentence leading with its actions
/// trailing at regular size, a strip's or a row's at small size and their own width, a sheet's footer with Cancel left of
/// the default action and a destructive one apart. Anywhere else, the spellings that place or size a button by hand fail
/// here, unless the site is named below with why.
struct ButtonPlacementTests {
    static let sharedBlocks = "Sources/XDictUI/ActionLayout.swift"

    /// What is placed by hand and why. Each entry is a file and the exact line, trimmed; one that no longer matches
    /// anything fails (`noExclusionIsStale`), so the list never outlives its sites.
    static let exclusions: [(file: String, line: String, why: String)] = [
        // Spinners, not buttons: a pane still loading shows the small spinner AppKit draws for it.
        ("Sources/XDictUI/LookupPanelView.swift", "ProgressView().controlSize(.small).coversPane()",
         "a spinner while the popover reads (P41), not a button"),
        ("Sources/XDictUI/AppleImportSheet.swift", "ProgressView().controlSize(.small)",
         "a spinner while the installed bundles are found, not a button"),
        // An empty state's actions sit centred under its sentence, where ContentUnavailableView lays them out; the
        // first way on is the prominent one.
        ("Sources/XDictUI/SearchWindow.swift", ".buttonStyle(.borderedProminent)",
         "ContentUnavailableView's actions, the system's own layout"),
    ]

    struct Finding: Equatable, CustomStringConvertible {
        let file: String
        let line: Int
        let text: String
        let rule: String
        var description: String { "\(file):\(line) \(rule): \(text)" }
    }

    /// Each spelling that places or sizes a button outside the blocks, and the rule it would break.
    static let handPlaced: [(pattern: String, rule: String)] = [
        (".controlSize(", "a size by hand (R2, R4: the surface decides it)"),
        (".keyboardShortcut(.defaultAction", "a default action outside a sheet's footer (R3)"),
        (".keyboardShortcut(.cancelAction", "a Cancel outside a sheet's footer (R3)"),
        (".buttonStyle(.borderedProminent", "a prominent button outside a sheet's footer (R3)"),
    ]

    /// The findings in one file's text: the spellings above, and a button after a `Spacer` in the same `HStack` (a
    /// trailing action placed by hand, R1, R2, R5).
    static func findings(file: String, text: String) -> [Finding] {
        let lines = text.components(separatedBy: "\n")
        var found: [Finding] = []
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") { continue }
            for (pattern, rule) in handPlaced where line.contains(pattern) {
                found.append(Finding(file: file, line: index + 1, text: line, rule: rule))
            }
        }
        for line in buttonsAfterSpacers(in: text) {
            found.append(Finding(file: file, line: line, text: lines[line - 1].trimmingCharacters(in: .whitespaces),
                                 rule: "a button pushed trailing by a Spacer (R1, R2, R5: ActionRow)"))
        }
        return found
    }

    /// The lines of each `Button` that follows a `Spacer(` inside one `HStack { … }`, braces matched.
    static func buttonsAfterSpacers(in text: String) -> [Int] {
        let source = text
        var lines: Set<Int> = []
        var search = source.startIndex
        while let stack = source.range(of: "HStack", range: search..<source.endIndex) {
            search = stack.upperBound
            guard let open = source[stack.upperBound...].firstIndex(of: "{") else { break }
            var depth = 0
            var close = open
            for index in source.indices[open...] {
                if source[index] == "{" { depth += 1 }
                if source[index] == "}" { depth -= 1 }
                if depth == 0 { close = index; break }
            }
            let body = source[open...close]
            guard let spacer = body.range(of: "Spacer(") else { continue }
            for button in body[spacer.upperBound...].matches(of: #/\bButton\s*[({]/#) {
                lines.insert(source[..<button.range.lowerBound].count(where: { $0 == "\n" }) + 1)
            }
        }
        return lines.sorted()
    }

    static func scan() throws -> [Finding] {
        let root = Manifest.package.appending(path: "Sources")
        return try SourceScan.files(under: root).flatMap { file, text -> [Finding] in
            let path = "Sources/" + file.path.dropFirst(root.path.count + 1)
            return path == sharedBlocks ? [] : findings(file: path, text: text)
        }
    }

    static func isExcluded(_ finding: Finding) -> Bool {
        exclusions.contains { $0.file == finding.file && $0.line == finding.text }
    }

    /// The scan sees the app and the blocks: a scan of nothing would pass.
    @Test func theScanReadsTheShell() throws {
        let files = try SourceScan.files(under: Manifest.package.appending(path: "Sources"))
        #expect(files.contains { $0.file.path.hasSuffix(Self.sharedBlocks) && $0.text.contains("struct ActionRow") })
        #expect(files.contains { $0.file.path.hasSuffix("Sources/XDictUI/SettingsDictionariesParts.swift") })
    }

    @Test func everyButtonIsPlacedByTheSharedBlocks() throws {
        let stray = try Self.scan().filter { !Self.isExcluded($0) }
        #expect(stray.isEmpty, """
            place these through ActionLayout.swift (ActionRow, ProgressRow, SheetFooter), or name the site in \
            ButtonPlacementTests.exclusions with why: \(stray)
            """)
    }

    @Test func noExclusionIsStale() throws {
        let findings = try Self.scan()
        for exclusion in Self.exclusions {
            #expect(findings.contains { $0.file == exclusion.file && $0.text == exclusion.line },
                    "\(exclusion.file): \(exclusion.line) is excluded but no longer there")
        }
    }

    /// Positive control: each spelling, and a button pushed trailing by a Spacer, is seen; the blocks' own use is not.
    @Test func theScanSeesEachWayAButtonIsPlacedByHand() {
        let planted = """
            HStack(alignment: .firstTextBaseline) {
                Text("A sentence.")
                Spacer()
                Button("Undo") { undo() }
            }
            Button("Cancel") { cancel() }.controlSize(.small)
            Button("Done") { done() }.keyboardShortcut(.defaultAction)
            Button("Close") { close() }.keyboardShortcut(.cancelAction)
            Button("Add") { add() }.buttonStyle(.borderedProminent)
            // Button("Commented") { }.controlSize(.small)
            """
        let found = Self.findings(file: "planted.swift", text: planted)
        #expect(found.map(\.line) == [6, 7, 8, 9, 4])
        let clean = """
            HStack {
                Button(action: remove) { Image(systemName: "minus") }
                Spacer()
            }
            ActionRow { Text("A sentence.") } actions: { Button("Undo") { undo() } }
            Button { act() } label: { HStack { Text("Open"); Spacer(); Image(systemName: "gear") } }
            """
        #expect(Self.findings(file: "clean.swift", text: clean).isEmpty)
    }
}
