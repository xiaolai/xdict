import Foundation

/// **One display option a dictionary's edition declares** (ADR-0013 decision 2), as the entry view takes it: its id, the
/// root attribute the shell sets to the reader's choice, its values in order and its default for the edition. The core
/// writes these from its own catalogue; the view takes one only in that shape (zero trust at the boundary), since its
/// attribute and value are written into the page: a plain id, the attribute `data-xdict-opt-<id>`, plain values, none
/// repeated, the default among them. Anything else is nil and never reaches a page.
public struct EntryDisplayOption: Hashable, Sendable {
    public let id: String
    public let attribute: String
    public let values: [String]
    public let defaultValue: String

    /// The prefix every option's root attribute has (`xdict_entry::options`).
    public static let attributePrefix = "data-xdict-opt-"

    public init?(id: String, attribute: String, values: [String], defaultValue: String) {
        guard Self.plain(id), attribute == Self.attributePrefix + id, !values.isEmpty, values.allSatisfy(Self.plain),
              Set(values).count == values.count, values.contains(defaultValue) else { return nil }
        self.id = id
        self.attribute = attribute
        self.values = values
        self.defaultValue = defaultValue
    }

    /// An ASCII letter, then letters, digits, `-` and `_`: the core's own test for a catalogue constant (`plain`).
    static func plain(_ token: String) -> Bool {
        guard let first = token.unicodeScalars.first, first.isASCII, first.properties.isAlphabetic else { return false }
        return token.unicodeScalars.allSatisfy {
            $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || $0 == "-" || $0 == "_")
        }
    }
}

/// What an edition declares: its options, in the catalogue's order, and the core's CSS keyed on their root attributes.
public struct EntryDisplayOptions: Hashable, Sendable {
    public let options: [EntryDisplayOption]
    public let css: String

    public init(options: [EntryDisplayOption], css: String) {
        self.options = options
        self.css = css
    }

    /// An edition that declares nothing, and a content that cannot say (the lab, the tests).
    public static let none = EntryDisplayOptions(options: [], css: "")
}

/// One root attribute and the value the page is given for it.
public struct EntryDisplayValue: Hashable, Sendable {
    public let attribute: String
    public let value: String

    public init(attribute: String, value: String) {
        self.attribute = attribute
        self.value = value
    }
}
