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
    /// The suggestion ↑ and ↓ have reached, which Return looks up.
    public var highlighted: String?
    /// Asks the search field for the keyboard whenever it changes (at launch, and by Search, ⌥⌘F).
    public private(set) var searchFocus = 1
    /// Asks the results list for the keyboard whenever it changes (↓ from the search field).
    public private(set) var resultsFocus = 0
    /// The dictionary whose entry the pane shows: its links are looked up there.
    public private(set) var presented: UUID?

    /// The library window, at one dictionary or none.
    @ObservationIgnored public var openLibrary: (@MainActor (UUID?) -> Void)?
    /// Each entry handed to the entry view, and whether it was: for the instruments.
    @ObservationIgnored public var onPresented: (@MainActor (SearchModel.Shown, Bool) -> Void)?

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
        model = SearchModel(backend: backend, window: window) { [library] in library.searchSources }
        pronunciation = Pronunciation(backend: backend, output: speech, preferences: speechPreferences)
        model.scrollReader = { [weak entry] in await entry?.scrollOffset() }
        entry.onLookup = { [weak self] query, anchor in self?.follow(query, anchor: anchor) }
        entry.onSound = { [weak self] path in self?.playRecording(path) }
        entry.onSpeak = { [weak self] text in self?.speak(text) }
    }

    public func focusSearch() { searchFocus += 1 }
    public func focusResults() { resultsFocus += 1 }

    /// A link in the shown entry: looked up in link mode in that entry's dictionary.
    public func follow(_ query: String, anchor: String?) {
        guard let from = presented else { return }
        model.follow(query, anchor: anchor, from: from)
    }

    // MARK: - Sound and speech (WI-7)

    /// The language the shown entry's dictionary is declared in (the library's, WI-5): what its sounds are spoken in.
    public var presentedLanguage: String? {
        guard let presented else { return nil }
        return library.entries.first { $0.id == presented }?.languages.pair.search
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

    /// Shows the model's entry in the pane, from its dictionary as the library has it now.
    public func present(_ shown: SearchModel.Shown) async {
        guard let source = model.source(shown.result.dictionary),
              let content = ServiceEntryContent(source: source, backend: backend) else {
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
        onPresented?(shown, done)
    }

    /// What a section's next action does (Q11).
    public func perform(_ next: NextAction) {
        switch next {
        case .wait, .checkSpelling:
            break
        case .openLibrary(let id):
            openLibrary?(id)
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

    /// Return in the search field: the highlighted suggestion, or what was typed.
    public func submit() {
        let chosen = model.showsSuggestions ? highlighted : nil
        highlighted = nil
        model.submit(chosen)
    }

    /// ↑ or ↓ in the search field: through the suggestions while they show, else ↓ into the results.
    public func move(_ step: Int) -> Bool {
        guard model.showsSuggestions else {
            guard step > 0, !model.sections.isEmpty else { return false }
            focusResults()
            return true
        }
        let list = model.suggestions
        let at = highlighted.flatMap { list.firstIndex(of: $0) }
        let next = at.map { $0 + step } ?? (step > 0 ? 0 : list.count - 1)
        highlighted = list.indices.contains(next) ? list[next] : nil
        return true
    }

    /// Escape in the search field: puts the suggestions away, if they show.
    public func cancel() -> Bool {
        guard model.showsSuggestions else { return false }
        highlighted = nil
        model.dismissSuggestions()
        return true
    }
}
