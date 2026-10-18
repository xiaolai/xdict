import Foundation
import XDictAppleSource
import XDictContract
import XDictLibrary

/// **The Add Apple Dictionaries… sheet as data** (ADR-0011 decisions 1 and 11; plan WI-5): the installed bundles, which
/// ones the reader ticked, which are already in the library, which XDict will not convert and why, and where each import
/// is. Pure: the sheet draws it, the tests hold it.
public struct AppleImportChoice: Equatable, Sendable {
    /// What a row can be.
    public enum Availability: Equatable, Sendable {
        case available
        /// The library already has a dictionary converted from this bundle.
        case alreadyImported
        /// XDict will not convert it: greyed, with its sentence.
        case refused(AppleImportRefusal)
    }

    public struct Row: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        /// Its languages as the dictionary table writes them; empty when it declares none.
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
    public private(set) var chosen: Set<String> = []

    public init(bundles: [InstalledBundle] = [], imported: Set<String> = []) {
        self.bundles = bundles
        self.imported = imported
    }

    /// The bundles as found again, and the library's imported ones: a tick on what is no longer available goes.
    public mutating func update(bundles: [InstalledBundle], imported: Set<String>) {
        self.bundles = bundles
        self.imported = imported
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

    public func rows(steps: [String: AppleImportStep], locale: Locale = .current) -> [Row] {
        bundles.map { bundle in
            let availability = availability(of: bundle)
            let pair = LanguagePair(search: bundle.searchLanguage, explanation: bundle.explanationLanguage)
            return Row(id: bundle.identifier, name: bundle.displayName,
                       language: SettingsDictionaries.language(pair, in: locale), bytes: bundle.bytes,
                       availability: availability, isChosen: chosen.contains(bundle.identifier) && availability == .available,
                       step: steps[bundle.identifier])
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
