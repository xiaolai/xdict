import Foundation

// **The seam between the entry view and whoever holds the dictionary.** The view never sees the IPC contract: WI-3's
// `ServiceClient` answers these three calls for one open dictionary (the contract's `entry`, `resource` and `link`, with
// `RenderContext.reader`), the development lab answers them from the core linked in directly, and the tests from values.
// The shapes are the core's (ADR-0007 decisions 6–8, 14), less what the view does not need.

/// One dictionary as the view sees it, **bound for the whole life of one web view** (ADR-0009 refutation, item 13):
/// every package writes the same routes under `xdict://d/`, so a late request from an old document could otherwise be
/// answered from another package. Showing another binding's entry builds another web view.
public struct EntryBinding: Hashable, Sendable {
    /// What the reader's preferences for this dictionary are kept under (zoom, appearance): stable across launches, as
    /// the dictionary's lineage is (ADR-0002). Never shown.
    public let dictionary: String
    /// The edition the view's documents come from.
    public let edition: String
    /// The open handle this binding answers through: valid while the dictionary stays open (ADR-0007 decision 2).
    public let handle: String

    public init(dictionary: String, edition: String, handle: String) {
        self.dictionary = dictionary
        self.edition = edition
        self.handle = handle
    }
}

/// Which record to show: a key exactly as the file spells it, and which of the records under it (ADR-0007 decision 2).
public struct EntryReference: Hashable, Sendable {
    public let key: String
    public let occurrence: UInt32

    public init(key: String, occurrence: UInt32 = 0) {
        self.key = key
        self.occurrence = occurrence
    }
}

/// An entry ready for the view: its HTML, already rewritten by the core under `xdict://d/`, and the policy the view must
/// enforce on it and on everything served beside it.
public struct EntryDocument: Sendable {
    public let html: Data
    /// The core's Content-Security-Policy (ADR-0007 decision 14). The view sends it as a header on every response.
    public let policy: String

    public init(html: Data, policy: String) {
        self.html = html
        self.policy = policy
    }
}

/// A resource's bytes and type, or the fact that the dictionary has none by that path (a value, not an error).
public enum EntryResource: Sendable, Equatable {
    case found(mime: String, bytes: Data)
    case missing
}

/// Where a URL appeared, for resolving it (ADR-0007 decision 7).
public enum EntryLinkOrigin: Hashable, Sendable {
    case entry(EntryReference)
    /// A stylesheet or script, by its path in the package.
    case resource(path: String)
}

/// What a URL means, as the core says (ADR-0007 decision 7).
public enum EntryLink: Hashable, Sendable {
    /// Look this up, in link mode.
    case lookup(query: String, anchor: String?)
    case resource(path: String)
    case sound(path: String)
    case speak(text: String)
    case anchor(name: String)
    case blocked(EntryBlock)
}

public enum EntryBlock: Hashable, Sendable {
    /// A remote URL, as the dictionary wrote it. Never loaded by the view; the reader may open it in their browser.
    case remote(url: String)
    /// `javascript:` and the like.
    case script
    case unknownScheme(String)
}

/// The three calls the view makes, for one bound dictionary. Every one may throw; the view refuses what fails.
public protocol EntryContent: Sendable {
    var binding: EntryBinding { get }
    /// **The language this dictionary's entries are written in**, as the library declares it (`en`, `zh-Hans`), or nil
    /// when nothing is known. The view puts it on the document, where the reading style's `:lang(zh)` gives Chinese
    /// text its own leading (owner, 2026-10-29; dev-docs/note-cjk-typography-2026-10-29.md).
    var language: String? { get }
    func entry(_ reference: EntryReference) async throws -> EntryDocument
    /// `path` as it travels: the part of the URL after `r/` or `sound/`, still percent-encoded (ADR-0007 decision 8).
    func resource(_ path: String) async throws -> EntryResource
    func link(_ url: String, origin: EntryLinkOrigin) async throws -> EntryLink
    /// The display options the bound edition declares (ADR-0013), asked once per web view, before its first entry.
    func displayOptions() async throws -> EntryDisplayOptions
}

extension EntryContent {
    /// A content that cannot say declares nothing: its entries show as the dictionary wrote them.
    public func displayOptions() async throws -> EntryDisplayOptions { .none }
    /// And a content that cannot say what language its dictionary is in leaves the document as it was.
    public var language: String? { nil }
}

/// Where the view lands in an entry once it has loaded (plan-macos-v1 WI-6): its top; the anchor a link named; or the
/// scroll offset a place in the reader's trail was left at, in CSS pixels from the top, which Back restores (I8).
public enum EntryLanding: Hashable, Sendable {
    case top
    case anchor(String)
    case offset(Double)
}
