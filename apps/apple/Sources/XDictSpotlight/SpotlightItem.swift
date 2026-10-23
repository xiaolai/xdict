import CoreSpotlight
import Foundation

/// **One word as Core Spotlight stores it** (plan-setup-v2 WI-6; ADR-0028, headwords only): the word, and the
/// dictionary it came from. Nothing about the entry travels — no definition, no text — so an item is a title and a
/// place to open.
public struct SpotlightItem: Hashable, Sendable {
    /// The word itself, as the dictionary's key spells it.
    public let word: String
    /// The dictionary's stable id, used as the item's domain: deleting the dictionary deletes its domain, and nothing
    /// else in the index is touched.
    public let domain: String

    public init(word: String, domain: String) {
        self.word = word
        self.domain = domain
    }

    /// **The one identifier an item has**: the domain, a `/`, and the word. A domain is an id the library minted and
    /// never contains `/`, so splitting at the first one gives the word back whatever the word holds.
    public var identifier: String { "\(domain)/\(word)" }

    /// The item an identifier names, or nil when it is not one of ours: the domain is what the library minted, and
    /// everything after the first `/` — a `/` of its own included — is the word.
    public static func item(of identifier: String) -> SpotlightItem? {
        guard let slash = identifier.firstIndex(of: "/") else { return nil }
        let domain = String(identifier[identifier.startIndex..<slash])
        let word = String(identifier[identifier.index(after: slash)...])
        guard !domain.isEmpty, !word.isEmpty else { return nil }
        return SpotlightItem(word: word, domain: domain)
    }

    /// The word an identifier names, or nil when it is not one of ours.
    public static func word(of identifier: String) -> String? { item(of: identifier)?.word }
}

/// **What a word becomes in the index** (ADR-0028 decision 2, as revised 2026-10-22): `title` is the word, `keywords`
/// carries it too — so a search finds it however Spotlight weighs the fields — and nothing else is written.
public enum SpotlightItems {
    /// The searchable item for one word. `contentType` is `.text`: macOS does not reliably show `.content`.
    public static func item(_ item: SpotlightItem) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = item.word
        attributes.keywords = [item.word]
        return CSSearchableItem(uniqueIdentifier: item.identifier, domainIdentifier: item.domain,
                                attributeSet: attributes)
    }
}
