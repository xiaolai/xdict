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
        #expect(Self.text(SettingsDictionaries.showInLibrary) == "Show in Library…")
        #expect(Self.text(SettingsDictionaries.showInLibrary, "zh-Hans") == "在词库中显示…")
    }
}
