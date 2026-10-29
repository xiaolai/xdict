import Foundation
import XDictClient
import XDictContract
import XDictEntryView

/// **The entry view's three calls, answered by the dictionary service** (plan-macos-v1 WI-6; WI-4's seam, through which
/// the view never sees the contract): an entry, a resource and a link of one open dictionary, under the reader's render
/// context (`RenderContext.reader`), whose base the service fills in. Bound to the dictionary's handle and edition as
/// they were when it was made: another handle is another binding, and so another web view (ADR-0009 refutation, item 13).
public final class ServiceEntryContent: EntryContent {
    public let binding: EntryBinding
    /// **The dictionary's declared language** (owner, 2026-10-29): the view sets it on the document, where the reading
    /// style keys Chinese leading off `:lang(zh)`.
    public let language: String?
    private let backend: any SearchBackend
    private let dict: DictId
    private let edition: Edition

    private let preferences: EntryPreferences

    /// The content of `source`, while it answers; nil when it cannot (not open, or never imported). `preferences` holds
    /// the reader's "Original style" for it, read at each request.
    public init?(source: SearchSource, backend: any SearchBackend, preferences: EntryPreferences = EntryPreferences()) {
        self.preferences = preferences
        guard let handle = source.handle, let edition = source.edition else { return nil }
        language = source.language
        self.backend = backend
        dict = handle
        self.edition = edition
        binding = EntryBinding(dictionary: source.preferencesKey, edition: edition.rawValue, handle: handle.rawValue)
    }

    private func reference(_ reference: EntryReference) -> EntryRef {
        EntryRef(edition: edition, key: reference.key, occurrence: reference.occurrence)
    }

    /// The reader's render context, in the style the reader chose for this dictionary now (ADR-0010 Q3).
    private var render: RenderContext {
        RenderContext(maxBodyBytes: RenderContext.reader.maxBodyBytes,
                      originalStyle: preferences.originalStyle(for: binding.dictionary))
    }

    public func entry(_ reference: EntryReference) async throws -> EntryDocument {
        let delivered = try await backend.request(.entry(dict: dict, entry: self.reference(reference), render: render)).get()
        guard case .entry(let entry) = delivered.answer, let html = delivered.payload else {
            throw ClientFailure.wire(.undecodable(detail: "not an entry"))
        }
        return EntryDocument(html: html, policy: entry.csp)
    }

    public func resource(_ path: String) async throws -> EntryResource {
        let delivered = try await backend.request(.resource(dict: dict, path: path, render: render)).get()
        switch delivered.answer {
        case .resource(.found(_, let mime)):
            guard let bytes = delivered.payload else { throw ClientFailure.wire(.undecodable(detail: "no bytes")) }
            return .found(mime: mime, bytes: bytes)
        case .resource(.missing):
            return .missing
        default:
            throw ClientFailure.wire(.undecodable(detail: "not a resource"))
        }
    }

    /// What the bound edition declares (ADR-0013), as the core read it in the service. An answer with an option outside
    /// the catalogue's shape is refused whole, so nothing of it reaches a page; the view records why.
    public func displayOptions() async throws -> EntryDisplayOptions {
        let delivered = try await backend.request(.displayOptions(dict: dict)).get()
        guard case .displayOptions(let declared) = delivered.answer else {
            throw ClientFailure.wire(.undecodable(detail: "not display options"))
        }
        let options = try declared.options.map { option in
            guard let taken = EntryDisplayOption(id: option.id, attribute: option.attribute, values: option.values,
                                                 defaultValue: option.defaultValue) else {
                throw ClientFailure.wire(.undecodable(detail: "a display option not in the catalogue's shape: \(option.id)"))
            }
            return taken
        }
        return EntryDisplayOptions(options: options, css: declared.css)
    }

    public func link(_ url: String, origin: EntryLinkOrigin) async throws -> EntryLink {
        let from: LinkOrigin = switch origin {
        case .entry(let reference): .entry(entry: self.reference(reference))
        case .resource(let path): .resource(path: path)
        }
        let delivered = try await backend.request(.link(dict: dict, url: url, origin: from, render: .reader)).get()
        guard case .link(let link) = delivered.answer else { throw ClientFailure.wire(.undecodable(detail: "not a link")) }
        return switch link {
        case .lookup(let query, let anchor): .lookup(query: query, anchor: anchor)
        case .resource(let path): .resource(path: path)
        case .sound(let path): .sound(path: path)
        case .speak(let text): .speak(text: text)
        case .anchor(let name): .anchor(name: name)
        case .blocked(.remote(let url)): .blocked(.remote(url: url))
        case .blocked(.script): .blocked(.script)
        case .blocked(.unknownScheme(let scheme)): .blocked(.unknownScheme(scheme))
        }
    }
}
