import Foundation
import XDictContract
import XDictCore

// **The service's half of the frozen contract: the core's types into the contract's, and back for parameters**
// (ADR-0007 decision 10: every `CoreError` variant crosses as its own kind). Every switch over a core enum is
// exhaustive, so a variant the core adds stops the service compiling instead of crossing as something else. The two
// modules share many names (`Entry`, `Link`, `Page`…), so every type here is written with its module.

// MARK: - Errors

extension CoreFailure {
    init(_ error: CoreError) {
        switch error {
        case .Unsupported(let feature, let detail): self = .unsupported(feature: XDictContract.Feature(feature), detail: detail)
        case .Malformed(let detail): self = .malformed(detail: detail)
        case .TooLarge(let limit, let detail): self = .tooLarge(limit: XDictContract.Limit(limit), detail: detail)
        case .NotFound(let what, let detail): self = .notFound(what: XDictContract.Missing(what), detail: detail)
        case .Io(let kind, let detail): self = .io(kind: XDictContract.IoKind(kind), detail: detail)
        case .StaleHandle(let detail): self = .staleHandle(detail: detail)
        case .EditionMismatch(let detail): self = .editionMismatch(detail: detail)
        case .SourceChanged(let detail): self = .sourceChanged(detail: detail)
        case .Cancelled(let detail): self = .cancelled(detail: detail)
        case .Incompatible(let core, let client, let detail): self = .incompatible(core: core, client: client, detail: detail)
        case .Internal(let detail): self = .internalFault(detail: detail)
        }
    }
}

extension WireError {
    init(core error: CoreError) {
        self = .core(CoreFailure(error))
    }
}

extension XDictContract.Feature {
    init(_ feature: XDictCore.Feature) {
        switch feature {
        case .formatVersion(let version): self = .formatVersion(version: version)
        case .resourceLibraryV3: self = .resourceLibraryV3
        case .registrationCode: self = .registrationCode
        case .encryptionFlags(let flags): self = .encryptionFlags(flags: flags)
        case .lzoInV3: self = .lzoInV3
        case .compressionType(let code): self = .compressionType(code: code)
        case .blockEncryption(let code): self = .blockEncryption(code: code)
        case .encoding(let name): self = .encoding(name: name)
        }
    }
}

extension XDictContract.Limit {
    init(_ limit: XDictCore.Limit) {
        switch limit {
        case .file: self = .file
        case .page: self = .page
        case .body: self = .body
        }
    }
}

extension XDictContract.Missing {
    init(_ missing: XDictCore.Missing) {
        switch missing {
        case .file: self = .file
        case .entry: self = .entry
        }
    }
}

extension XDictContract.IoKind {
    init(_ kind: XDictCore.IoKind) {
        switch kind {
        case .notFound: self = .notFound
        case .permissionDenied: self = .permissionDenied
        case .shortRead: self = .shortRead
        case .outOfMemory: self = .outOfMemory
        case .other: self = .other
        }
    }
}

// MARK: - Answers

extension XDictContract.Versions {
    init(_ versions: XDictCore.Versions) {
        self.init(protocolVersion: versions.protocol, core: versions.core, indexFormat: versions.indexFormat,
                  normalization: versions.normalization)
    }
}

extension XDictContract.DictInfo {
    init(_ info: XDictCore.DictInfo) {
        self.init(title: info.title, description: info.description, formatVersion: info.formatVersion, keys: info.keys)
    }
}

extension XDictContract.Problem {
    init(_ problem: XDictCore.Problem) {
        switch problem {
        case .volumeUnreadable(let name, let error): self = .volumeUnreadable(name: name, error: CoreFailure(error))
        }
    }
}

extension XDictContract.Imported {
    init(_ imported: XDictCore.Imported) {
        self.init(edition: Edition(rawValue: imported.edition), lineage: LineageId(rawValue: imported.lineage),
                  info: XDictContract.DictInfo(imported.info), problems: imported.problems.map(XDictContract.Problem.init))
    }
}

extension XDictContract.ImportReason {
    init(_ reason: XDictCore.ImportReason) {
        switch reason {
        case .new: self = .new
        case .changed: self = .changed
        case .indexMissing: self = .indexMissing
        case .indexOutdated: self = .indexOutdated
        case .noIdentity: self = .noIdentity
        }
    }
}

extension XDictContract.Opened {
    init(_ opened: XDictCore.Opened) {
        switch opened {
        case .ready(let dict, let edition, let info):
            self = .ready(dict: DictId(rawValue: dict), edition: Edition(rawValue: edition), info: XDictContract.DictInfo(info))
        case .needsImport(let reason): self = .needsImport(reason: XDictContract.ImportReason(reason))
        }
    }
}

extension XDictContract.EntryRef {
    init(_ ref: XDictCore.EntryRef) {
        self.init(edition: Edition(rawValue: ref.edition), key: ref.key, occurrence: ref.occurrence)
    }
}

extension XDictContract.How {
    init(_ how: XDictCore.How) {
        switch how {
        case .exact: self = .exact
        case .folded: self = .folded
        case .unmarked: self = .unmarked
        case .redirect(let chain): self = .redirect(chain: chain)
        }
    }
}

extension XDictContract.HitProblem {
    init(_ problem: XDictCore.HitProblem) {
        switch problem {
        case .danglingRedirect(let from, let target): self = .danglingRedirect(from: from, target: target)
        case .redirectLoop(let chain): self = .redirectLoop(chain: chain)
        case .redirectLimit(let chain): self = .redirectLimit(chain: chain)
        }
    }
}

extension XDictContract.Hit {
    init(_ hit: XDictCore.Hit) {
        self.init(dict: DictId(rawValue: hit.dict), entry: XDictContract.EntryRef(hit.entry), headword: hit.headword,
                  how: XDictContract.How(hit.how), problems: hit.problems.map(XDictContract.HitProblem.init))
    }
}

extension XDictContract.Page {
    init(_ page: XDictCore.Page) {
        self.init(hits: page.hits.map(XDictContract.Hit.init), total: page.total, generation: page.generation,
                  problems: page.problems.map(XDictContract.HitProblem.init))
    }
}

extension XDictContract.BlockReason {
    init(_ reason: XDictCore.BlockReason) {
        switch reason {
        case .remote(let url): self = .remote(url: url)
        case .script: self = .script
        case .unknownScheme(let scheme): self = .unknownScheme(scheme: scheme)
        }
    }
}

extension XDictContract.Link {
    init(_ link: XDictCore.Link) {
        switch link {
        case .lookup(let query, let anchor): self = .lookup(query: query, anchor: anchor)
        case .resource(let path): self = .resource(path: path)
        case .sound(let path): self = .sound(path: path)
        case .speak(let text): self = .speak(text: text)
        case .anchor(let name): self = .anchor(name: name)
        case .blocked(let why): self = .blocked(why: XDictContract.BlockReason(why))
        }
    }
}

extension Answer {
    /// An entry's answer, and its HTML as the payload, UTF-8: never inside the JSON.
    static func of(_ entry: XDictCore.Entry) -> (Answer, Data) {
        (.entry(XDictContract.Entry(entry: XDictContract.EntryRef(entry.entry), csp: entry.csp, lossyBytes: entry.lossyBytes)),
         Data(entry.html.utf8))
    }

    /// A resource's answer, and its bytes as the payload when it was found.
    static func of(_ resource: XDictCore.Resource) -> (Answer, Data?) {
        switch resource {
        case .found(let path, let mime, let bytes): (.resource(.found(path: path, mime: mime)), bytes)
        case .missing(let path): (.resource(.missing(path: path)), nil)
        }
    }
}

// MARK: - Parameters, the other way

extension XDictCore.EntryRef {
    init(_ ref: XDictContract.EntryRef) {
        self.init(edition: ref.edition.rawValue, key: ref.key, occurrence: ref.occurrence)
    }
}

extension XDictCore.MatchMode {
    init(_ mode: XDictContract.MatchMode) {
        switch mode {
        case .reader: self = .reader
        case .link: self = .link
        }
    }
}

extension XDictCore.LookupOptions {
    init(_ options: XDictContract.LookupOptions) {
        self.init(limit: options.limit, offset: options.offset, mode: XDictCore.MatchMode(options.mode),
                  generation: options.generation)
    }
}

extension XDictCore.LinkOrigin {
    init(_ origin: XDictContract.LinkOrigin) {
        switch origin {
        case .entry(let entry): self = .entry(entry: XDictCore.EntryRef(entry))
        case .resource(let path): self = .resource(path: path)
        }
    }
}

extension XDictCore.View {
    /// The core's view for a render context: the contract's one base, the request's ceiling.
    init(_ render: RenderContext) {
        self.init(baseUrl: RenderContext.baseURL, maxBodyBytes: render.maxBodyBytes)
    }
}

extension XDictCore.FileIdentity {
    init(_ identity: XDictContract.FileIdentity) {
        self.init(device: identity.device, inode: identity.inode, size: identity.size, mtimeNs: identity.mtimeNs,
                  ctimeNs: identity.ctimeNs)
    }
}
