import Foundation
import Testing
import XDictContract
import XDictCore
@testable import XDictService

/// **The service's half of the contract: the core's types into the contract's, and the contract's parameters into
/// the core's** (ADR-0007 decision 10: every `CoreError` crosses as its own kind, typed, `detail` for logs). The
/// mapping's switches are exhaustive over the core's enums, so a variant the core adds stops the service compiling;
/// these tests hold what each variant becomes.
struct CoreMappingTests {
    /// Each `CoreError` variant, as the binding spells it, becomes the contract's kind with its payload and detail.
    @Test func everyCoreErrorCrossesAsItsOwnKind() {
        let pairs: [(CoreError, CoreFailure)] = [
            (.Unsupported(feature: .registrationCode, detail: "u"), .unsupported(feature: .registrationCode, detail: "u")),
            (.Malformed(detail: "m"), .malformed(detail: "m")),
            (.TooLarge(limit: .body, detail: "t"), .tooLarge(limit: .body, detail: "t")),
            (.NotFound(what: .entry, detail: "n"), .notFound(what: .entry, detail: "n")),
            (.Io(kind: .shortRead, detail: "i"), .io(kind: .shortRead, detail: "i")),
            (.StaleHandle(detail: "s"), .staleHandle(detail: "s")),
            (.EditionMismatch(detail: "e"), .editionMismatch(detail: "e")),
            (.SourceChanged(detail: "c"), .sourceChanged(detail: "c")),
            (.Cancelled(detail: "x"), .cancelled(detail: "x")),
            (.Incompatible(core: 1, client: 9, detail: "p"), .incompatible(core: 1, client: 9, detail: "p")),
            (.Internal(detail: "f"), .internalFault(detail: "f")),
        ]
        for (core, wire) in pairs { #expect(CoreFailure(core) == wire, "\(core)") }
        #expect(WireError(core: .SourceChanged(detail: "c")) == .core(.sourceChanged(detail: "c")))
    }

    @Test func everyPayloadOfAnErrorKeepsItsValues() {
        let features: [(XDictCore.Feature, XDictContract.Feature)] = [
            (.formatVersion(version: "3.0"), .formatVersion(version: "3.0")), (.resourceLibraryV3, .resourceLibraryV3),
            (.registrationCode, .registrationCode), (.encryptionFlags(flags: 3), .encryptionFlags(flags: 3)),
            (.lzoInV3, .lzoInV3), (.compressionType(code: 7), .compressionType(code: 7)),
            (.blockEncryption(code: 2), .blockEncryption(code: 2)), (.encoding(name: "GBK"), .encoding(name: "GBK")),
        ]
        for (core, wire) in features { #expect(XDictContract.Feature(core) == wire) }
        #expect([XDictCore.Limit.file, .page, .body].map(XDictContract.Limit.init) == [.file, .page, .body])
        #expect([XDictCore.Missing.file, .entry, .edition, .lineage].map(XDictContract.Missing.init)
                == [.file, .entry, .edition, .lineage])
        #expect([XDictCore.IoKind.notFound, .permissionDenied, .shortRead, .outOfMemory, .other].map(XDictContract.IoKind.init)
                == [.notFound, .permissionDenied, .shortRead, .outOfMemory, .other])
    }

    /// The versions the service answers with are the binding's own, under the contract's names.
    @Test func theVersionsAreTheCoresOwn() {
        let core = XDictCore.versions()
        #expect(XDictContract.Versions(core) == XDictContract.Versions(
            protocolVersion: core.protocol, core: core.core, indexFormat: core.indexFormat, normalization: core.normalization))
    }

    /// **An entry's HTML leaves as the payload, as UTF-8, and its answer holds the rest.**
    @Test func anEntrysHTMLBecomesThePayload() {
        let ref = XDictCore.EntryRef(edition: "mdx-sha256-v1:00", key: "hold", occurrence: 2)
        let (answer, payload) = Answer.of(XDictCore.Entry(entry: ref, html: "<b>hold</b> — 持有", csp: "default-src 'none'",
                                                          lossyBytes: 1))
        #expect(answer == .entry(XDictContract.Entry(
            entry: XDictContract.EntryRef(edition: Edition(rawValue: "mdx-sha256-v1:00"), key: "hold", occurrence: 2),
            csp: "default-src 'none'", lossyBytes: 1)))
        #expect(payload == Data("<b>hold</b> — 持有".utf8))
    }

    /// A found resource's bytes leave as the payload; a missing one has none.
    @Test func aResourcesBytesBecomeThePayload() {
        let (found, bytes) = Answer.of(XDictCore.Resource.found(path: "a b.png", mime: "image/png", bytes: Data([1, 2, 3])))
        #expect(found == .resource(.found(path: "a b.png", mime: "image/png")))
        #expect(bytes == Data([1, 2, 3]))
        let (missing, none) = Answer.of(XDictCore.Resource.missing(path: "gone.png"))
        #expect(missing == .resource(.missing(path: "gone.png")))
        #expect(none == nil)
    }

    @Test func aPageCrossesWithEveryKindOfMatchAndProblem() {
        let ref = XDictCore.EntryRef(edition: "e", key: "k", occurrence: 0)
        let page = XDictCore.Page(
            hits: [
                XDictCore.Hit(dict: "d", entry: ref, headword: "a", how: .exact, problems: []),
                XDictCore.Hit(dict: "d", entry: ref, headword: "b", how: .folded, problems: []),
                XDictCore.Hit(dict: "d", entry: ref, headword: "c", how: .unmarked, problems: []),
                XDictCore.Hit(dict: "d", entry: ref, headword: "e", how: .redirect(chain: ["e", "k"]),
                              problems: [.redirectLimit(chain: ["e"])]),
            ],
            total: 4, generation: 9,
            problems: [.danglingRedirect(from: "x", target: "y"), .redirectLoop(chain: ["z", "z"])])
        let wireRef = XDictContract.EntryRef(edition: Edition(rawValue: "e"), key: "k", occurrence: 0)
        let dict = DictId(rawValue: "d")
        #expect(XDictContract.Page(page) == XDictContract.Page(
            hits: [
                XDictContract.Hit(dict: dict, entry: wireRef, headword: "a", how: .exact, problems: []),
                XDictContract.Hit(dict: dict, entry: wireRef, headword: "b", how: .folded, problems: []),
                XDictContract.Hit(dict: dict, entry: wireRef, headword: "c", how: .unmarked, problems: []),
                XDictContract.Hit(dict: dict, entry: wireRef, headword: "e", how: .redirect(chain: ["e", "k"]),
                                  problems: [.redirectLimit(chain: ["e"])]),
            ],
            total: 4, generation: 9,
            problems: [.danglingRedirect(from: "x", target: "y"), .redirectLoop(chain: ["z", "z"])]))
    }

    @Test func openedImportedAndLinksCrossWhole() {
        let info = XDictCore.DictInfo(title: "T", description: "D", formatVersion: "2.0", keys: 3)
        let wireInfo = XDictContract.DictInfo(title: "T", description: "D", formatVersion: "2.0", keys: 3)
        #expect(XDictContract.Opened(.ready(dict: "d", edition: "e", info: info))
                == .ready(dict: DictId(rawValue: "d"), edition: Edition(rawValue: "e"), info: wireInfo))
        let reasons: [XDictCore.ImportReason] = [.new, .changed, .indexMissing, .indexOutdated, .noIdentity]
        let wireReasons: [XDictContract.ImportReason] = [.new, .changed, .indexMissing, .indexOutdated, .noIdentity]
        #expect(reasons.map { XDictContract.Opened(XDictCore.Opened.needsImport(reason: $0)) }
                == wireReasons.map { XDictContract.Opened.needsImport(reason: $0) })
        let imported = XDictCore.Imported(edition: "e", lineage: "l", info: info, problems: [
            .volumeUnreadable(name: "v", error: .Malformed(detail: "bad")),
        ])
        #expect(XDictContract.Imported(imported) == XDictContract.Imported(
            edition: Edition(rawValue: "e"), lineage: LineageId(rawValue: "l"), info: wireInfo,
            problems: [.volumeUnreadable(name: "v", error: .malformed(detail: "bad"))]))
        let links: [(XDictCore.Link, XDictContract.Link)] = [
            (.lookup(query: "q", anchor: "a"), .lookup(query: "q", anchor: "a")), (.resource(path: "p"), .resource(path: "p")),
            (.sound(path: "s"), .sound(path: "s")), (.speak(text: "t"), .speak(text: "t")), (.anchor(name: "n"), .anchor(name: "n")),
            (.blocked(why: .remote(url: "u")), .blocked(why: .remote(url: "u"))), (.blocked(why: .script), .blocked(why: .script)),
            (.blocked(why: .unknownScheme(scheme: "x")), .blocked(why: .unknownScheme(scheme: "x"))),
        ]
        for (core, wire) in links { #expect(XDictContract.Link(core) == wire) }
    }

    /// The contract's parameters become the core's: the entry reference, the lookup options, a link's origin, the file
    /// identity, and the render context with the one base the contract allows.
    @Test func theContractsParametersBecomeTheCores() {
        let ref = XDictContract.EntryRef(edition: Edition(rawValue: "e"), key: "k", occurrence: 3)
        #expect(XDictCore.EntryRef(ref) == XDictCore.EntryRef(edition: "e", key: "k", occurrence: 3))
        #expect(XDictCore.LookupOptions(XDictContract.LookupOptions(limit: 10, offset: 20, mode: .link, generation: 5))
                == XDictCore.LookupOptions(limit: 10, offset: 20, mode: .link, generation: 5))
        #expect(XDictCore.LinkOrigin(.entry(entry: ref)) == .entry(entry: XDictCore.EntryRef(ref)))
        #expect(XDictCore.LinkOrigin(.resource(path: "styles/a.css")) == .resource(path: "styles/a.css"))
        #expect(XDictCore.View(RenderContext(maxBodyBytes: 1_024)) == XDictCore.View(baseUrl: "xdict://d/", maxBodyBytes: 1_024))
        let identity = XDictContract.FileIdentity(device: .max, inode: 2, size: 3, mtimeNs: -4, ctimeNs: 5)
        #expect(XDictCore.FileIdentity(identity) == XDictCore.FileIdentity(device: .max, inode: 2, size: 3, mtimeNs: -4, ctimeNs: 5))
    }
}
