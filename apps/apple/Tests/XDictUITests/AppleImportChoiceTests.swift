import Foundation
import Testing
import XDictAppleSource
import XDictContract
import XDictLibrary
import XDictTestSupport
@testable import XDictUI

/// **The Add Apple Dictionaries… sheet's logic** (ADR-0011 decisions 1 and 11; plan WI-5): a checkbox per bundle,
/// "Already imported" for one the library has, refused ones greyed with their sentence and never chosen, Import only
/// over ticked available bundles not already on their way, each import's progress and its Cancel; and the sheet's and
/// the problem row's sentences in both languages.
struct AppleImportChoiceTests {
    static func bundle(_ id: String, _ name: String, refusal: AppleImportRefusal? = nil, bytes: UInt64 = 2 << 20,
                       languages: (String?, String?) = ("en", "en")) -> InstalledBundle {
        InstalledBundle(url: URL(filePath: "/tmp/\(id).dictionary"), identifier: id, displayName: name, version: "1",
                        bytes: bytes, searchLanguage: languages.0, explanationLanguage: languages.1, refusal: refusal)
    }

    static let oxford = bundle("noad", "Oxford Dictionary of English")
    static let chinese = bundle("zh", "Chinese–English", languages: ("zh-Hans", "en"))
    static let apple = bundle("apple", "Apple Dictionary", refusal: .noKeyTextIndex)
    static let thesaurus = bundle("oawt", "Oxford Thesaurus")

    static func text(_ resource: LocalizedStringResource, _ language: String = "en") -> String {
        (try? CompiledCatalog.text(resource, in: language)) ?? "the catalog did not compile"
    }

    @Test func eachBundleIsARowWithItsAvailability() {
        let choice = AppleImportChoice(bundles: [Self.oxford, Self.chinese, Self.apple, Self.thesaurus],
                                       imported: ["oawt"])
        let rows = choice.rows(steps: [:], locale: Locale(identifier: "en"))
        #expect(rows.map(\.name) == ["Oxford Dictionary of English", "Chinese–English", "Apple Dictionary", "Oxford Thesaurus"])
        #expect(rows.map(\.availability) == [.available, .available, .refused(.noKeyTextIndex), .alreadyImported])
        #expect(rows.map(\.isChooseable) == [true, true, false, false])
        #expect(rows[0].language == "English" && rows[1].language.hasSuffix("-English") && rows[1].language != "English")
        #expect(rows.allSatisfy { !$0.isChosen })
    }

    @Test func onlyAvailableBundlesCanBeTickedAndImported() {
        var choice = AppleImportChoice(bundles: [Self.oxford, Self.apple, Self.thesaurus], imported: ["oawt"])
        choice.toggle("noad")
        choice.toggle("apple")
        choice.toggle("oawt")
        #expect(choice.chosen == ["noad"])
        #expect(choice.toImport(steps: [:]).map(\.identifier) == ["noad"])
        choice.toggle("noad")
        #expect(choice.toImport(steps: [:]).isEmpty, "unticked")
    }

    /// Import starts the ticked ones; a bundle on its way cannot be ticked or imported twice, and offers Cancel.
    @Test func aBundleOnItsWayShowsItsStepAndCancel() {
        var choice = AppleImportChoice(bundles: [Self.oxford, Self.chinese])
        choice.toggle("noad")
        choice.toggle("zh")
        let started = choice.toImport(steps: [:]).map(\.identifier)
        choice.started(started)
        #expect(started == ["noad", "zh"] && choice.chosen.isEmpty)
        let steps: [String: AppleImportStep] = ["noad": .converting(done: 1, total: 4), "zh": .waiting]
        let rows = choice.rows(steps: steps)
        #expect(rows.map(\.canCancel) == [true, true] && rows.map(\.isChooseable) == [false, false])
        choice.toggle("noad", steps: steps)
        #expect(choice.toImport(steps: steps).isEmpty)
        let ending = choice.rows(steps: ["noad": .cancelling, "zh": .failed(.service)])
        #expect(ending.map(\.canCancel) == [false, false] && ending[1].isChooseable, "a failed one may be tried again")
    }

    /// Once the library has it, a bundle is "Already imported", and a tick left on it goes.
    @Test func anImportedBundleLosesItsTick() {
        var choice = AppleImportChoice(bundles: [Self.oxford])
        choice.toggle("noad")
        choice.update(bundles: choice.bundles, imported: ["noad"], available: nil)
        #expect(choice.chosen.isEmpty && choice.rows(steps: [:]).first?.availability == .alreadyImported)
        #expect(choice.toImport(steps: [:]).isEmpty)
    }

    /// **What Dictionary.app knows and this Mac has not downloaded** (plan-setup-v2 WI-3): listed after the installed
    /// ones, named, never ticked and never imported — macOS downloads them, not XDict.
    @Test func theNotInstalledOnesAreListedAndCannotBeImported() {
        let available = [AvailableBundle(name: "Assamese - English"), AvailableBundle(name: "Bulgarian")]
        var choice = AppleImportChoice(bundles: [Self.oxford], available: available)
        let rows = choice.rows(steps: [:], locale: Locale(identifier: "en"))
        #expect(rows.map(\.name) == ["Oxford Dictionary of English", "Assamese - English", "Bulgarian"])
        #expect(rows.map(\.availability) == [.available, .notInstalled, .notInstalled])
        #expect(rows.map(\.isChooseable) == [true, false, false])
        #expect(rows.dropFirst().allSatisfy { $0.bytes == 0 && $0.language.isEmpty && $0.step == nil })
        choice.toggle("Assamese - English")
        #expect(choice.chosen.isEmpty, "one this Mac has not downloaded cannot be ticked")
        #expect(choice.toImport(steps: [:]).isEmpty)
        // The older accessor still means the installed ones, in the order they were found.
        #expect(choice.installedRows(steps: [:]).map(\.id) == ["noad"])
    }

    /// **A list that could not be read is not an empty list** (plan-setup-v2 WI-3 item 4): the sheet says so and offers
    /// Dictionary.app, rather than a section that looks like nothing exists.
    @Test func anUnreadablePreferenceIsNotAnEmptyList() {
        var choice = AppleImportChoice(bundles: [Self.oxford])
        #expect(choice.available == nil)
        #expect(choice.availableRows().isEmpty)
        choice.update(bundles: choice.bundles, imported: [], available: [])
        #expect(choice.available == [], "read, and nothing left to download")
        #expect(choice.availableRows().isEmpty)
    }

    @Test func theSheetSpeaksBothLanguages() {
        #expect(Self.text(AppleImportSentences.availableSection, "zh-Hans") != Self.text(AppleImportSentences.availableSection))
        #expect(Self.text(AppleImportSentences.availableNote).contains("Dictionary ▸ Settings"))
        #expect(Self.text(AppleImportSentences.notInstalled, "zh-Hans") != Self.text(AppleImportSentences.notInstalled))
        #expect(Self.text(AppleImportSentences.download, "zh-Hans") != Self.text(AppleImportSentences.download))
        #expect(Self.text(AppleImportSentences.rescan, "zh-Hans") != Self.text(AppleImportSentences.rescan))
        #expect(Self.text(AppleImportSentences.openDictionary, "zh-Hans") != Self.text(AppleImportSentences.openDictionary))
        #expect(Self.text(AppleImportSentences.availableUnreadable, "zh-Hans")
                != Self.text(AppleImportSentences.availableUnreadable), "the fallback says the list could not be read")
        #expect(Self.text(AppleImportSentences.title) == "Add Apple Dictionaries")
        #expect(Self.text(AppleImportSentences.alreadyImported, "zh-Hans") == "已导入")
        #expect(Self.text(AppleImportSentences.howToDownload).contains("Dictionary.app ▸ Settings"))
        #expect(Self.text(AppleImportSentences.howToDownload, "zh-Hans").contains("Dictionary.app"))
        #expect(Self.text(AppleImportSentences.updated(name: "Oxford")) == "Apple updated Oxford.")
        #expect(Self.text(AppleImportSentences.updated(name: "Oxford"), "zh-Hans") == "Apple 更新了 Oxford。")
        #expect(Self.text(AppleImportSentences.convertAgain, "zh-Hans") == "重新转换")
        #expect(Self.text(AppleImportSentences.removed) == "Apple removed this dictionary’s files; this copy still reads.")
        #expect(Self.text(AppleImportSentences.failure(.refused(.noKeyTextIndex)))
                == "This dictionary has no search words, so XDict cannot convert it.")
        let steps: [AppleImportStep] = [.waiting, .copying, .converting(done: 0, total: 1), .cancelling,
                                        .added(UUID()), .cancelled, .failed(.service), .failed(.notAdded)]
        for step in steps {
            let sentence = AppleImportSentences.step(step)
            #expect(sentence.map { Self.text($0, "zh-Hans") != Self.text($0) } == true, "\(step) has its Chinese")
        }
        #expect(AppleImportSentences.step(nil) == nil)
    }
}
