import AppKit
import Foundation
import Observation
import XDictContract
import XDictEntryView
import XDictLibrary
import XDictSearch
import XDictSpeech

/// **One main window** (plan-macos-v1 WI-6): its search (`SearchModel`), the library it searches, the entry view it
/// shows entries in, and what the window asks of the app — the library window, and the keyboard for its search field.
/// The entry view's links come back here and are followed in the dictionary whose entry they are in (I7); its sounds
/// and spoken words are pronounced from that dictionary, in its declared language (WI-7).
@MainActor
@Observable
public final class SearchWindowState {
    public let model: SearchModel
    public let library: Library
    public let entry: EntryViewController
    /// The entry's sounds and the system voice (WI-7): what the window's notice shows.
    public let pronunciation: Pronunciation
    /// What the dictionary service answered at launch: shown when it did not.
    public var service = LaunchStatus.asking
    /// Asks the search field for the keyboard whenever it changes (at launch, and by Search, ⌥⌘F).
    public private(set) var searchFocus = 1
    /// Asks the results list for the keyboard whenever it changes (↓ from the search field).
    public private(set) var resultsFocus = 0
    /// The dictionary whose entry the pane shows: its links are looked up there.
    public private(set) var presented: UUID?
    /// **Which lookup the entry view was last handed**, so a document's finish is acknowledged only for the lookup shown
    /// now (plan-capture WI-4 rule 3): a stale document finishing in the gap before a newer lookup's entry request
    /// acknowledged the newer term `shown`.
    @ObservationIgnored private var presentedEntry = PresentedEntry()

    /// Whether the entry view was asked to show the lookup the model shows now — the identity a finished document's
    /// acknowledgement rests on (both the lookup and its shown entry: while a newer lookup awaits its first result the
    /// shown entry is still the older lookup's). False before the first ask, and while a newer lookup is still on its way.
    public var showsPresentedLookup: Bool {
        guard let shown = model.shown else { return false }
        return presentedEntry.isCurrent(serial: shown.serial, lookup: shown.lookup)
            && shown.lookup == model.lookup?.serial
    }

    /// Settings ▸ Dictionaries, at one dictionary or none (ADR-0012 d.4: `SettingsRoute.show`).
    @ObservationIgnored public var showDictionaries: (@MainActor (UUID?) -> Void)?
    /// Each entry handed to the entry view, and whether it was: for the instruments.
    @ObservationIgnored public var onPresented: (@MainActor (SearchModel.Shown, Bool) -> Void)?
    /// A word ⌘-clicked in the entry, looked up in a new tab of this window (parity P47). Unset in the lookup popover,
    /// where a ⌘-click does nothing new.
    @ObservationIgnored public var openInNewTab: (@MainActor (String) -> Void)?

    @ObservationIgnored private let backend: any SearchBackend

    /// `window` names the window's callers in the service client, so two windows never supersede each other. `speech`
    /// is where its sound leaves the app, `speechPreferences` the reader's accent: the system's and the reader's own,
    /// unless an instrument passes a silent output and a defaults suite of its own.
    public init(library: Library, backend: any SearchBackend, entry: EntryViewController, window: String,
                speech: any PronunciationOutput = SystemOutput(),
                speechPreferences: SpeechPreferences = SpeechPreferences()) {
        self.library = library
        self.backend = backend
        self.entry = entry
        model = SearchModel(backend: backend, window: window, guesser: SystemSpellingGuesser()) { [library] in
            library.searchSources
        }
        pronunciation = Pronunciation(backend: backend, output: speech, preferences: speechPreferences)
        model.scrollReader = { [weak entry] in await entry?.scrollOffset() }
        entry.onLookup = { [weak self] query, anchor in self?.follow(query, anchor: anchor) }
        entry.onSound = { [weak self] path in self?.playRecording(path) }
        entry.onSpeak = { [weak self] text in self?.speak(text) }
        entry.onOpenInNewTab = { [weak self] word in self?.openInNewTab?(word) }
    }

    public func focusSearch() { searchFocus += 1 }
    public func focusResults() { resultsFocus += 1 }

    /// A link in the shown entry: looked up in link mode in that entry's dictionary (on the All page, the dictionary
    /// of the frame it is in).
    public func follow(_ query: String, anchor: String?) {
        guard let from = entry.activeItem ?? presented else { return }
        model.follow(query, anchor: anchor, from: from)
    }

    // MARK: - Sound and speech (WI-7)

    /// The language the shown entry's dictionary is declared in (the library's, WI-5): what its sounds are spoken in.
    public var presentedLanguage: String? {
        guard let dictionary = entry.activeItem ?? presented else { return nil }
        return library.entries.first { $0.id == dictionary }?.languages.pair.search
    }

    /// The shown entry's word: its headword as its dictionary gives it, else its key.
    public var shownWord: String? {
        guard let shown = model.shown else { return nil }
        return model.hit(shown.result)?.headword ?? shown.result.entry.key
    }

    /// Whether the speak button has a word, in a dictionary, to say.
    public var canPronounce: Bool { presented != nil && shownWord != nil }

    /// A `sound://` link in the shown entry: its recording, from the open dictionary the entry was read from, or the
    /// entry's word spoken in its place.
    public func playRecording(_ path: String) {
        guard let handle = entry.binding?.handle else { return }
        let word = shownWord ?? "", language = presentedLanguage
        Task { await pronunciation.playRecording(path, from: DictId(rawValue: handle), word: word, language: language) }
    }

    /// A `.tts` link in the shown entry: its text, in the dictionary's language.
    public func speak(_ text: String) {
        pronunciation.speak(text, language: presentedLanguage)
    }

    /// The speak button: the shown entry's word, as written.
    public func pronounceShown() {
        guard let word = shownWord else { return }
        speak(word)
    }

    /// What the speaker says: the selection, trimmed, when there is one, else the entry's word.
    public static func spokenText(selection: String?, word: String?) -> String? {
        let selected = selection?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return selected.isEmpty ? word : selected
    }

    /// The title bar's speaker and Edit ▸ Pronounce: the entry's selected text, else the shown word.
    public func pronounceSelectionOrShown() {
        Task { @MainActor in
            guard let text = Self.spokenText(selection: await entry.selectedText(), word: shownWord) else { return }
            speak(text)
        }
    }

    /// Shows the model's entry in the pane, from its dictionary as the library has it now: for a typed word over every
    /// dictionary, the All page (P15) with every dictionary's entry, the shown one among them.
    public func present(_ shown: SearchModel.Shown) async {
        if let lookup = model.lookup, AllPage.applies(scope: lookup.scope, mode: lookup.mode) {
            await presentPage(shown)
            return
        }
        guard let source = model.source(shown.result.dictionary),
              let content = ServiceEntryContent(source: source, backend: backend, preferences: entry.preferences) else {
            onPresented?(shown, false)
            return
        }
        presented = source.id
        let landing: EntryLanding = switch shown.landing {
        case .top: .top
        case .anchor(let name): .anchor(name)
        case .offset(let y): .offset(y)
        }
        let reference = EntryReference(key: shown.result.entry.key, occurrence: shown.result.entry.occurrence)
        let done = await entry.show(reference, from: content, landing: landing)
        if done { presentedEntry.asked(serial: shown.serial, lookup: shown.lookup) }
        onPresented?(shown, done)
    }

    // MARK: - The All page (P15)

    /// The entries the All page holds now: changes as each dictionary answers, so the page grows in the reader's order.
    /// Nil when no page is due.
    public var pageResults: [ResultID]? {
        guard let shown = model.shown, let lookup = model.lookup, AllPage.applies(scope: lookup.scope, mode: lookup.mode)
        else { return nil }
        return AllPage.results(sections: model.sections, shown: shown.result, headword: model.hit(shown.result)?.headword)
    }

    private func pageItems(_ results: [ResultID]) -> [EntryPageItem] {
        results.compactMap { result in
            guard let source = model.source(result.dictionary),
                  let content = ServiceEntryContent(source: source, backend: backend, preferences: entry.preferences)
            else { return nil }
            return EntryPageItem(id: source.id, name: source.name, content: content,
                                 reference: EntryReference(key: result.entry.key, occurrence: result.entry.occurrence))
        }
    }

    private func presentPage(_ shown: SearchModel.Shown) async {
        guard let results = pageResults, model.source(shown.result.dictionary) != nil else {
            onPresented?(shown, false)
            return
        }
        presented = shown.result.dictionary
        let landing: EntryLanding = if case .offset(let y) = shown.landing { .offset(y) } else { .top }
        let done = await entry.showPage(pageItems(results), primary: shown.result.dictionary, landing: landing)
        if done { presentedEntry.asked(serial: shown.serial, lookup: shown.lookup) }
        onPresented?(shown, done)
    }

    /// Another dictionary answered while the page is shown: the page again, its frames kept, the new ones in place.
    public func pageResultsChanged() {
        guard let results = pageResults, entry.pageFrames != nil else { return }
        let primary = model.shown?.result.dictionary
        Task { await entry.showPage(pageItems(results), primary: primary) }
    }

    /// What covers the entry pane now (UI review X1): "No entries found." only once the list has settled empty, so it
    /// never flashes before a completion or a guess is shown (P10, P13).
    public var placeholder: EntryPlaceholder {
        let pending = model.listing.map { !$0.settled || !$0.headwords.isEmpty } ?? false
        let unsearched = model.sections.filter { if case .unavailable(let why) = $0.status {
            if case .indexing = why { false } else { true } } else { false } }.count
        return EntryPlaceholder.of(noDictionaries: library.entries.isEmpty && library.unreadable == nil,
                                   query: model.lookup?.query, selection: model.selection,
                                   searching: model.isSearching, unsearched: unsearched, pending: pending)
    }

    /// Whether an entry, or the All page, is shown: what the menus' entry commands (Print…, Find…, Expand All…) are
    /// enabled by. Read from the observed model, never from the entry view's web view, which SwiftUI cannot observe:
    /// keyed on that, every such item stayed disabled on the All page after a search (UI tour `page.print`, 2026-10-18).
    public var hasEntry: Bool { model.shown != nil }

    /// The dictionary the shown entry is read from: named beside its headword (Codex §5).
    public var shownSourceName: String? {
        model.shown.flatMap { model.source($0.result.dictionary)?.name }
    }

    /// A placeholder that covers the pane closes the entry under it, so VoiceOver cannot reach a previous lookup's
    /// entry either (UI review X1). Called when the placeholder changes.
    public func placeholderChanged() {
        guard placeholder.clearsEntry, entry.reference != nil else { return }
        entry.closeEntry()
        presented = nil
    }

    /// What a section's next action does (Q11).
    public func perform(_ next: NextAction) {
        switch next {
        case .wait, .checkSpelling:
            break
        case .showInSettings(let id):
            showDictionaries?(id)
        case .retryImport(let id):
            library.retry(id)
        case .retryLookup(let id):
            model.retry(id)
        case .reopen:
            Task { await library.refresh() }
        case .searchEverywhere(let query):
            model.setScope(.all)
            model.submit(query)
        }
    }

    /// **The reader typed** in the search field. Only typing comes here: a text the window sets (a visit adopted from
    /// the panel, Back, Forward) reaches the field through `model.text` and starts no search.
    public func typedText(_ text: String) {
        model.text = text
        model.textDidChange()
    }

    /// Return in the search field: what typing shows confirmed, or what was typed looked up (P10).
    public func submit() {
        model.submit()
    }

    /// ↓ in the search field: the next row of the list chosen and the list given the keyboard, so the arrows go on
    /// through it (P11); ↑ does nothing there.
    public func move(_ step: Int) -> Bool {
        guard step > 0, let rows = model.listing?.headwords, !rows.isEmpty else { return false }
        let at = model.selectedHeadword.flatMap { rows.firstIndex(of: $0) }
        let next = at.map { min($0 + 1, rows.count - 1) } ?? 0
        if rows[next] != model.selectedHeadword { model.choose(headword: rows[next]) }
        focusResults()
        return true
    }

    /// Escape in the search field: the field clears itself, as a search field does.
    public func cancel() -> Bool { false }
}
