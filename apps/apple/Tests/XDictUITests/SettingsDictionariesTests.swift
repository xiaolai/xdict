import Foundation
import Testing
import XDictLibrary
import XDictTestSupport
import XDictUI

/// **Settings ▸ Dictionaries as Apple's Dictionary draws it** (parity ledger P39, P40): the decisions the pane makes,
/// without a window (the build Mac opens none). The look is checked by the UI tour's capture and its tree check.
struct SettingsDictionariesTests {
    static func text(_ resource: LocalizedStringResource, _ language: String = "en") -> String {
        (try? CompiledCatalog.text(resource, in: language)) ?? "the catalog did not compile"
    }

    // MARK: - P39: the list

    /// Apple's Settings window is 600 pt wide and its table's rows 20 pt (settings.ax.json, 2026-10-17).
    @Test func thePaneHasApplesMeasures() {
        #expect(SettingsDictionaries.paneWidth == 600)
        #expect(SettingsDictionaries.rowHeight == 20)
    }

    /// Apple's line above the list, and the table's accessibility name, in English and in Chinese.
    @Test func theLabelsAreApples() {
        #expect(Self.text(SettingsDictionaries.instruction) == "Drag reference sources into the order you prefer:")
        #expect(Self.text(SettingsDictionaries.tableName) == "Dictionaries")
        #expect(Self.text(SettingsDictionaries.instruction, "zh-Hans") == "将参考来源拖移到您偏好的顺序：")
        #expect(Self.text(SettingsDictionaries.tableName, "zh-Hans") == "词典")
    }

    /// The language column: one language once, two as "search-explanation", nothing when neither is known (Apple
    /// leaves the cell empty for a dictionary that names none).
    @Test func theLanguageColumnNamesThePair() {
        let english = Locale(identifier: "en")
        #expect(SettingsDictionaries.language(LanguagePair(search: "en", explanation: "en"), in: english) == "English")
        #expect(SettingsDictionaries.language(LanguagePair(search: "fr", explanation: "en"), in: english)
            == "French-English")
        #expect(SettingsDictionaries.language(LanguagePair(search: "en", explanation: nil), in: english) == "English")
        #expect(SettingsDictionaries.language(LanguagePair(search: nil, explanation: nil), in: english) == "")
    }

    /// Dragging rows onto a place moves them there, in the library's own terms (`move(fromOffsets:toOffset:)`).
    @Test func aDropMovesTheDraggedRows() {
        let ids = (0..<4).map { _ in UUID() }
        let move = SettingsDictionaries.move(dragged: [ids[3].uuidString], to: 1, in: ids)
        #expect(move?.offsets == IndexSet(integer: 3))
        #expect(move?.destination == 1)
        #expect(SettingsDictionaries.move(dragged: ["not an id"], to: 0, in: ids) == nil)
        #expect(SettingsDictionaries.move(dragged: [UUID().uuidString], to: 0, in: ids) == nil)
    }

    // MARK: - P40: the selected dictionary's own options, under the list

    /// With nothing selected the slot says so; Apple's slot is empty, XDict says what will appear there.
    @Test func theOptionsSlotSaysWhatItHolds() {
        #expect(Self.text(SettingsDictionaries.noSelection) == "Select a dictionary to see its options.")
        #expect(Self.text(SettingsDictionaries.noSelection, "zh-Hans") == "选择一部词典以查看它的选项。")
        #expect(Self.text(SettingsDictionaries.details) == "Details…")
        #expect(Self.text(SettingsDictionaries.details, "zh-Hans") == "详细信息…")
    }

    // MARK: - ADR-0012: what the Library window did

    /// `+` is a menu (d.2): Add MDX Files… (⌘O), and Add Apple Dictionaries…, in the code but not offered until WI-5.
    @Test func thePlusMenuOffersMDXFilesOnly() {
        #expect(SettingsDictionaries.AddItem.allCases == [.mdxFiles, .appleDictionaries])
        #expect(SettingsDictionaries.addMenu == [.mdxFiles])
        #expect(SettingsDictionaries.AddItem.mdxFiles.opensWithCommandO)
        #expect(!SettingsDictionaries.AddItem.appleDictionaries.opensWithCommandO)
        #expect(Self.text(SettingsDictionaries.AddItem.mdxFiles.title) == "Add MDX Files…")
        #expect(Self.text(SettingsDictionaries.AddItem.appleDictionaries.title) == "Add Apple Dictionaries…")
        #expect(Self.text(SettingsDictionaries.AddItem.mdxFiles.title, "zh-Hans") == "添加 MDX 文件…")
    }

    /// The importer offers what the Library's did: folders, .mdx and .mdd.
    @Test func theImporterTakesFoldersMdxAndMdd() {
        #expect(SettingsDictionaries.choosesFolders)
        #expect(SettingsDictionaries.chooseableExtensions == ["mdx", "mdd"])
    }

    /// d.6: the table at least 200 pt tall; the pane at most the screen's visible height less its margins.
    @Test func thePaneFollowsTheSizeRules() {
        #expect(SettingsDictionaries.tableMinHeight == 200)
        #expect(SettingsDictionaries.maxPaneHeight(visible: 800) == 720)
        #expect(SettingsDictionaries.maxPaneHeight(visible: 300) >= SettingsDictionaries.tableMinHeight)
    }

    /// The Details… sheet never hangs past the Settings window (tour, light-en, 2026-10-18: window to ~605 pt, sheet to
    /// ~800): the pane's width, and no taller than the pane it covers less a margin; its form scrolls inside.
    @Test func theDetailsSheetFitsInsideThePane() {
        let size = SettingsDictionaries.detailsSheetSize(paneHeight: 540)
        #expect(size.width == SettingsDictionaries.paneWidth)
        #expect(size.height == 540 - 2 * SettingsDictionaries.sheetMargin)
        #expect(SettingsDictionaries.detailsSheetSize(paneHeight: 2_000).height <= SettingsDictionaries.detailsSheetMaxHeight)
        // A pane not yet measured, or tiny, still gives a usable sheet, never one taller than the pane.
        #expect(SettingsDictionaries.detailsSheetSize(paneHeight: 0).height == SettingsDictionaries.detailsSheetMinHeight)
        #expect(SettingsDictionaries.detailsSheetSize(paneHeight: 250).height <= 250)
    }

    /// The strip names only what is under way; a ready or a troubled dictionary is not in it (the call of 2026-10-18:
    /// no "Ready" text).
    @Test func theStripHoldsWhatIsUnderWay() {
        let ids = (0..<6).map { _ in UUID() }
        let phases: [UUID: EntryPhase] = [ids[0]: .ready, ids[1]: .importing(done: 1, total: 4), ids[2]: .waiting,
                                          ids[3]: .missing(fileName: "x.mdx"), ids[4]: .opening, ids[5]: .cancelling]
        #expect(SettingsDictionaries.underWay(order: ids, phases: phases) == [ids[1], ids[2], ids[4], ids[5]])
    }

    /// The removed-dictionary sentence, in both languages.
    @Test func aRemovedDictionaryIsSaid() {
        #expect(Self.text(SettingsDictionaries.removedNotice) == "That dictionary is no longer in your library.")
        #expect(Self.text(SettingsDictionaries.removedNotice, "zh-Hans") == "那部词典已不在你的词库中。")
    }
}
