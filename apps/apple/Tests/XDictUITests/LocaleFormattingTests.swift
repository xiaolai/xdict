import Foundation
import Testing
import XDictContract
import XDictLibrary
import XDictTestSupport
import XDictUI

/// **Numbers, sizes and shares are written as the reader's language writes them** (owner's i18n round, 2026-10-17):
/// a count, a byte size and a percentage reach the sentence as values and are formatted when the sentence is read, in
/// the language XDict speaks (`Locale.current` follows XDict's own `AppleLanguages` in the bundle), never as "\(n)%"
/// or a size written into the key. Read through the real catalog, compiled, as the reader reads it.
struct LocaleFormattingTests {
    static let french = Locale(identifier: "fr_FR")

    static func huge(_ count: UInt64) -> LocalizedStringResource {
        LibrarySentences.health(HealthFinding(kind: .hugeEntries, count: count, name: nil, examples: []))
    }

    /// A count and a byte size, in English and in Simplified Chinese, in the plural each count takes.
    @Test func aCountAndAByteSizeReadInEachLanguage() throws {
        #expect(try CompiledCatalog.text(Self.huge(1_234), in: "en") == "1,234 entries are larger than 1 MB and may be slow to show.")
        #expect(try CompiledCatalog.text(Self.huge(1), in: "en") == "1 entry is larger than 1 MB and may be slow to show.")
        #expect(try CompiledCatalog.text(Self.huge(1_234), in: "zh-Hans") == "1,234 个词条大于 1 MB，显示时可能较慢。")
    }

    /// The formats come from the locale, not from the key: French groups and names sizes its own way.
    @Test func theFormatsFollowTheLocaleNotTheKey() throws {
        let text = try CompiledCatalog.text(Self.huge(1_234), in: "en", locale: Self.french)
        let count = 1_234.formatted(.number.locale(Self.french))
        let size = Int64(1 << 20).formatted(.byteCount(style: .memory).locale(Self.french))
        #expect(count != "1,234" && size != "1 MB", "French formats nothing differently, so this proves nothing")
        #expect(text == "\(count) entries are larger than \(size) and may be slow to show.")
    }

    /// A share is the language's percentage, whole and rounded down while the check runs.
    @Test func aShareIsTheLanguagesPercentage() throws {
        let checking = LibrarySentences.healthStatus(.checking(done: 999, total: 4_000))
        #expect(try CompiledCatalog.text(checking, in: "en") == "Checking entries… 24%")
        #expect(try CompiledCatalog.text(checking, in: "zh-Hans") == "正在检查词条…… 24%")
        let french = 0.24.formatted(.percent.precision(.fractionLength(0)).locale(Self.french))
        #expect(try CompiledCatalog.text(checking, in: "en", locale: Self.french) == "Checking entries… \(french)")
    }

    /// The UI-fix round's "all N entries": one entry is "its 1 entry" in English, and reads in Chinese for any count.
    @Test func checkedEntriesTakeTheirPlural() throws {
        func checked(_ entries: UInt64) -> LocalizedStringResource {
            LibrarySentences.healthStatus(.checked(Health(version: 1, entries: entries, findings: [], classes: [])))
        }
        #expect(try CompiledCatalog.text(checked(1), in: "en") == "Healthy. Checked its 1 entry.")
        #expect(try CompiledCatalog.text(checked(2_000), in: "en") == "Healthy. Checked all 2,000 entries.")
        #expect(try CompiledCatalog.text(checked(1), in: "zh-Hans") == "状况良好。已检查全部词条（共 1 个）。")
        #expect(try CompiledCatalog.text(LibrarySentences.noticesHeadline(1), in: "en") == "1 file could not be added.")
    }

    /// **A skipped sheet is the reader's sentence; the core's English is only a diagnostic** beside it. Every reason
    /// reads in Chinese with the dictionary's path quoted, and none carries the core's detail into the sentence.
    @Test func aSkippedSheetIsWordedByTheShell() throws {
        let detail = "the core's own English"
        let reasons: [SkipReason] = [.tooMany(limit: 256), .tooLarge(limit: 32 << 20, detail: detail), .notFound,
                                     .unreadable(detail: detail)]
        for reason in reasons {
            let sheet = SkippedSheet(path: "in/side.css", reason: reason)
            for language in ["en", "zh-Hans"] {
                let text = try CompiledCatalog.text(LibrarySentences.skipped(sheet), in: language)
                #expect(text.contains("“in/side.css”") && !text.contains(detail) && !text.contains("%"), "\(language): \(text)")
            }
            let chinese = try CompiledCatalog.text(LibrarySentences.skipped(sheet), in: "zh-Hans")
            #expect(chinese.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }, "not Chinese: \(chinese)")
        }
        let large = SkippedSheet(path: "big.css", reason: .tooLarge(limit: 32 << 20, detail: detail))
        #expect(try CompiledCatalog.text(LibrarySentences.skipped(large), in: "en")
            == "“big.css” was not read: XDict reads at most 32 MB of a dictionary’s style sheets.")
        #expect(LibrarySentences.skippedDetail(large) == detail)
        #expect(LibrarySentences.skippedDetail(SkippedSheet(path: "x.css", reason: .notFound)) == nil)
    }
}
