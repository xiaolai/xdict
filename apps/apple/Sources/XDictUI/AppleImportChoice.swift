import Foundation
import XDictAppleSource
import XDictContract
import XDictLibrary

/// **The Add Apple Dictionaries… sheet as data** (ADR-0011 decisions 1 and 11; plan WI-5; the not-installed ones by
/// plan-setup-v2 WI-3): the installed bundles, what Dictionary.app knows is available on this Mac, which ones the reader
/// ticked, which are already in the library, which XDict will not convert and why, and where each import is. Pure: the
/// sheet draws it, the tests hold it.
public struct AppleImportChoice: Equatable, Sendable {
    /// What a row can be.
    public enum Availability: Equatable, Sendable {
        case available
        /// The library already has a dictionary converted from this bundle.
        case alreadyImported
        /// XDict will not convert it: greyed, with its sentence.
        case refused(AppleImportRefusal)
        /// **Dictionary.app knows it and this Mac has not downloaded it** (plan-setup-v2 WI-3): named, "not installed",
        /// and sent to Dictionary.app, which is the only thing that can download it.
        case notInstalled
    }

    public struct Row: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        /// Its languages as the dictionary table writes them; empty when it declares none — and for one this Mac has
        /// not downloaded, which declares nothing at all.
        public let language: String
        public let bytes: UInt64
        public let availability: Availability
        public let isChosen: Bool
        /// Its import this session, if one was asked.
        public let step: AppleImportStep?

        /// A checkbox the reader may change: an available bundle not already on its way.
        public var isChooseable: Bool { availability == .available && !Self.isUnderWay(step) }
        /// Whether its import is waiting, copying or converting: what the row's Cancel stops.
        public var canCancel: Bool { Self.isUnderWay(step) && step != .cancelling }

        static func isUnderWay(_ step: AppleImportStep?) -> Bool {
            switch step {
            case .waiting, .copying, .converting, .cancelling: true
            case .added, .cancelled, .failed, nil: false
            }
        }
    }

    public private(set) var bundles: [InstalledBundle]
    public private(set) var imported: Set<String>
    /// What Dictionary.app knows and this Mac has not downloaded; **nil when the preference could not be read**, which
    /// the sheet says in words rather than drawing an empty section (plan-setup-v2 WI-3).
    public private(set) var available: [AvailableBundle]?
    public private(set) var chosen: Set<String> = []

    public init(bundles: [InstalledBundle] = [], imported: Set<String> = [], available: [AvailableBundle]? = nil) {
        self.bundles = bundles
        self.imported = imported
        self.available = available
    }

    /// The bundles as found again, the library's imported ones, and what Dictionary.app knows: a tick on something no
    /// longer available goes.
    public mutating func update(bundles: [InstalledBundle], imported: Set<String>, available: [AvailableBundle]?) {
        self.bundles = bundles
        self.imported = imported
        self.available = available
        chosen = chosen.filter { id in bundles.contains { $0.identifier == id && availability(of: $0) == .available } }
    }

    public func availability(of bundle: InstalledBundle) -> Availability {
        if imported.contains(bundle.identifier) { return .alreadyImported }
        if let refusal = bundle.refusal { return .refused(refusal) }
        return .available
    }

    /// Ticks or unticks a bundle; one that cannot be chosen stays as it is.
    public mutating func toggle(_ id: String, steps: [String: AppleImportStep] = [:]) {
        guard let row = rows(steps: steps).first(where: { $0.id == id }), row.isChooseable else { return }
        if chosen.contains(id) { chosen.remove(id) } else { chosen.insert(id) }
    }

    /// Every row the sheet draws: the installed bundles first, then the ones Dictionary.app knows.
    public func rows(steps: [String: AppleImportStep], locale: Locale = .current, filter: String = "") -> [Row] {
        matching(installedRows(steps: steps, locale: locale) + availableRows(), filter)
    }

    /// **What the reader's filter keeps** (owner, 2026-10-23: the list had none): a row whose name or languages hold
    /// what they typed, case- and diacritic-insensitively; a filter of nothing — or spaces — keeps every row.
    public func matching(_ rows: [Row], _ text: String) -> [Row] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return rows }
        return rows.filter {
            $0.name.localizedStandardContains(needle) || $0.language.localizedStandardContains(needle)
        }
    }

    /// The bundles on this Mac, in the order they were found.
    public func installedRows(steps: [String: AppleImportStep], locale: Locale = .current) -> [Row] {
        bundles.map { bundle in
            let availability = availability(of: bundle)
            let pair = LanguagePair(search: bundle.searchLanguage, explanation: bundle.explanationLanguage)
            return Row(id: bundle.identifier, name: bundle.displayName,
                       language: SettingsDictionaries.language(pair, in: locale), bytes: bundle.bytes,
                       availability: availability, isChosen: chosen.contains(bundle.identifier) && availability == .available,
                       step: steps[bundle.identifier])
        }
    }

    /// The dictionaries Dictionary.app knows and this Mac has not downloaded, by name. Never ticked, never imported:
    /// macOS downloads them, and XDict lists them so the reader can see what there is.
    public func availableRows() -> [Row] {
        (available ?? []).map { bundle in
            Row(id: bundle.name, name: bundle.name, language: "", bytes: 0, availability: .notInstalled, isChosen: false,
                step: nil)
        }
    }

    /// What Import converts: the ticked bundles still available and not already on their way, in the list's order.
    public func toImport(steps: [String: AppleImportStep]) -> [InstalledBundle] {
        bundles.filter { chosen.contains($0.identifier) && availability(of: $0) == .available
            && !Row.isUnderWay(steps[$0.identifier]) }
    }

    /// The bundles of `ids` taken off the ticked set: Import started them.
    public mutating func started(_ ids: [String]) {
        chosen.subtract(ids)
    }
}
