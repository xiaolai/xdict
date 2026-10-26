import Foundation
import Testing
import XDictContract

/// What the service refuses before it reaches the core, read off the request, what it learned of each handle, and
/// what each open dictionary is made of. The same function answers on both sides, so a client can refuse its own
/// mistake before sending it.
struct AdmissionTests {
    static let open = ServiceOperation.openPackage(spec: Fixtures.package)
    static let entry = ServiceOperation.entry(dict: Fixtures.dict, entry: Fixtures.entryRef, render: .reader)

    static func refusal(_ request: Request, handles: [HandleFacts]? = nil) -> Refusal? {
        request.refusal(handles: handles ?? Fixtures.handles(for: request.operation), filesOf: Fixtures.filesOf)
    }

    /// A request with this many good handles: each a regular read-only file, the package's files' in order.
    static func good(_ count: Int) -> [HandleFacts] {
        (0..<count).map { _ in HandleFacts(identity: Fixtures.identity, isRegularReadOnly: true) }
    }

    /// **A request that reads an edition's dictionary must carry that dictionary's files** (audit rounds 1–4,
    /// 2026-10-26): `studyNoteAt` and `studyReanchor` name an edition, not a handle, and both read entry bodies. Without
    /// the edition resolved, the request names no files at all — the hole this closes; resolved, its dictionary's files
    /// are required like any other.
    @Test func anEditionNamedReadNeedsThatDictionarysFiles() {
        let edition = Fixtures.entryRef.edition
        let operation = ServiceOperation.studyNoteAt(entry: Fixtures.entryRef, text: "my own words", name: "Tiny",
                                                     stamp: Fixtures.studyStamp, operation: "op")
        let request = Fixtures.request(operation)
        #expect(request.refusal(handles: [], filesOf: Fixtures.filesOf, editions: [:]) == nil,
                "an unresolved edition reads nothing, by name")
        let first = Fixtures.filesOf[Fixtures.dict]?.first ?? UUID()
        let lacking = Request(id: 7, tokens: Fixtures.tokens.filter { $0.file != first }, operation: operation)
        #expect(lacking.refusal(handles: [], filesOf: Fixtures.filesOf, editions: [edition: Fixtures.dict])
                == .missingToken(file: first))
        #expect(request.refusal(handles: [], filesOf: Fixtures.filesOf, editions: [edition: Fixtures.dict]) == nil,
                "the whole dictionary's tokens did not admit it")
        // **Reanchor renders entries like an entry read does**, so it holds a bulk credit rather than none.
        #expect(ServiceOperation.studyReanchor(oldEdition: edition, newEdition: edition, stamp: Fixtures.studyStamp,
                                               operationPrefix: "move").creditClass == .bulk)
    }

    @Test func aWellFormedRequestIsAdmitted() {
        for operation in Fixtures.operations {
            #expect(Self.refusal(Fixtures.request(operation)) == nil, "\(operation)")
        }
    }

    // MARK: - Handles

    /// **A package with no handle is refused**: sent through `call`, or with an empty list. A path is never the
    /// fallback — the contract has nowhere to put one, and the service opens nothing by name.
    @Test func aPackageWithNoHandleIsRefused() {
        #expect(Self.refusal(Fixtures.request(Self.open), handles: []) == .missingHandle)
        #expect(Self.refusal(Fixtures.request(.importPackage(spec: Fixtures.package)), handles: []) == .missingHandle)
    }

    /// Handles travel in the order of the package's files, so their counts must agree, or a handle would be read as
    /// another file's.
    @Test func handlesThatDoNotMatchTheFilesInNumberAreRefused() {
        #expect(Self.refusal(Fixtures.request(Self.open), handles: Self.good(3)) == .handleCountMismatch(files: 4, handles: 3))
        #expect(Self.refusal(Fixtures.request(Self.open), handles: Self.good(5)) == .handleCountMismatch(files: 4, handles: 5))
    }

    @Test func handlesWithAnOperationThatReadsNoneAreRefused() {
        #expect(Self.refusal(Fixtures.request(.close(dict: Fixtures.dict)), handles: Self.good(1)) == .unexpectedHandles(count: 1))
    }

    /// **A handle that is not the file its path names is refused before the core sees it** (Codex objection 1): the
    /// core would hash the handle's bytes and register them under the token's identity, binding one file's edition to
    /// another file's identity. Same device and inode, or refused; a path with nothing at it names no handle.
    @Test func aHandleThatIsNotThePathsFileIsRefused() {
        var handles = Fixtures.handles(for: Self.open)
        let held = Fixtures.identities[Fixtures.volumeID] ?? Fixtures.identity
        handles[1] = HandleFacts(identity: FileIdentity(device: held.device, inode: held.inode + 100, size: held.size,
                                                        mtimeNs: held.mtimeNs, ctimeNs: held.ctimeNs), isRegularReadOnly: true)
        #expect(Self.refusal(Fixtures.request(Self.open), handles: handles) == .handleIsNotThePathsFile(file: Fixtures.volumeID))
        handles[1] = HandleFacts(identity: FileIdentity(device: held.device + 1, inode: held.inode, size: held.size,
                                                        mtimeNs: held.mtimeNs, ctimeNs: held.ctimeNs), isRegularReadOnly: true)
        #expect(Self.refusal(Fixtures.request(Self.open), handles: handles) == .handleIsNotThePathsFile(file: Fixtures.volumeID))
        handles[1] = HandleFacts(identity: nil, isRegularReadOnly: true)
        #expect(Self.refusal(Fixtures.request(Self.open), handles: handles) == .handleIsNotThePathsFile(file: Fixtures.volumeID))

        let missing = Fixtures.tokens.map { $0.file == Fixtures.sidecarID ? FileToken(file: $0.file, observed: 1, state: .missing) : $0 }
        #expect(Self.refusal(Request(id: 1, tokens: missing, operation: Self.open))
                == .handleIsNotThePathsFile(file: Fixtures.sidecarID))
    }

    /// The same file rewritten between the app's `stat` and its `open` keeps its device and inode: admitted, and the
    /// core's own identity check sees the rest (`IdentityRule`).
    @Test func theSameFileWithOtherTimesIsAdmitted() {
        var handles = Fixtures.handles(for: Self.open)
        let held = Fixtures.identities[Fixtures.mdxID] ?? Fixtures.identity
        handles[0] = HandleFacts(identity: FileIdentity(device: held.device, inode: held.inode, size: held.size + 1,
                                                        mtimeNs: held.mtimeNs + 1, ctimeNs: held.ctimeNs + 1), isRegularReadOnly: true)
        #expect(Self.refusal(Fixtures.request(Self.open), handles: handles) == nil)
    }

    /// The service's inspection found a descriptor that is not a regular file opened read-only (a pipe, a socket, a
    /// writable file): refused, by the file it stood for (Codex objection 7).
    @Test func aHandleThatIsNotARegularReadOnlyFileIsRefused() {
        var handles = Fixtures.handles(for: Self.open)
        handles[3] = HandleFacts(identity: Fixtures.identities[Fixtures.sidecarID], isRegularReadOnly: false)
        #expect(Self.refusal(Fixtures.request(Self.open), handles: handles) == .notARegularReadOnlyFile(file: Fixtures.sidecarID))
    }

    // MARK: - Tokens

    /// **Every file an operation may read carries a token** (Codex objection 4): without one the service's identity
    /// check falls back to `fstat`, which a swapped folder leaves untouched. Import and open need one per file of the
    /// package; entry, link and resource per file of their dictionary; lookup and suggest per file of every listed one.
    @Test func everyFileAnOperationMayReadNeedsAToken() {
        let lacking = { (file: UUID) in Fixtures.tokens.filter { $0.file != file } }
        for operation in [Self.open, .importPackage(spec: Fixtures.package)] {
            #expect(Self.refusal(Request(id: 1, tokens: lacking(Fixtures.secondVolumeID), operation: operation))
                    == .missingToken(file: Fixtures.secondVolumeID), "\(operation)")
        }
        let readsDict: [ServiceOperation] = [
            Self.entry,
            .link(dict: Fixtures.dict, url: "x", origin: .resource(path: "a.css"), render: .reader),
            .resource(dict: Fixtures.dict, path: "a.png", render: .reader),
            .lookup(query: "a", dicts: [Fixtures.other, Fixtures.dict],
                    options: LookupOptions(limit: 1, offset: 0, mode: .reader, generation: nil)),
            .suggest(prefix: "a", dicts: [Fixtures.other, Fixtures.dict], limit: 1),
        ]
        for operation in readsDict {
            #expect(Self.refusal(Request(id: 1, tokens: lacking(Fixtures.sidecarID), operation: operation))
                    == .missingToken(file: Fixtures.sidecarID), "\(operation)")
            #expect(Self.refusal(Request(id: 1, tokens: [], operation: operation)) != nil, "\(operation) with no token at all")
        }
        // The other dictionary's file is needed only where that dictionary is listed.
        #expect(Self.refusal(Request(id: 1, tokens: lacking(Fixtures.otherMDXID), operation: Self.entry)) == nil)
        #expect(Self.refusal(Request(id: 1, tokens: lacking(Fixtures.otherMDXID), operation: .suggest(
            prefix: "a", dicts: [Fixtures.other], limit: 1))) == .missingToken(file: Fixtures.otherMDXID))
    }

    /// Operations that read no file need no token; a dictionary the service has no files for is the core's to
    /// refuse (`staleHandle`), not admission's.
    @Test func operationsThatReadNoFileNeedNoToken() {
        for operation: ServiceOperation in [.versions, .close(dict: Fixtures.dict), .cancel(request: 1),
                                            .joinLineage(edition: Fixtures.edition, lineage: Fixtures.lineage),
                                            .splitLineage(edition: Fixtures.edition, newLineage: Fixtures.newLineage),
                                            .lineageOf(edition: Fixtures.edition)] {
            #expect(Self.refusal(Request(id: 1, tokens: [], operation: operation)) == nil, "\(operation)")
        }
        let unknown = ServiceOperation.entry(dict: DictId(rawValue: "ffffffff00000009"), entry: Fixtures.entryRef, render: .reader)
        #expect(Self.refusal(Request(id: 1, tokens: [], operation: unknown)) == nil)
    }

    /// Two tokens for one file would leave the service to guess which is current.
    @Test func twoTokensForOneFileAreRefused() {
        let request = Request(id: 1, tokens: Fixtures.tokens + [FileToken(file: Fixtures.mdxID, observed: 999, state: .missing)],
                              operation: .versions)
        #expect(Self.refusal(request) == .duplicateToken(file: Fixtures.mdxID))
    }

    // MARK: - Bounds

    @Test func anInvalidPackageIsRefusedWithItsProblem() {
        let bad = PackageSpec(files: [.mdx(id: Fixtures.mdxID), FileSpec(id: Fixtures.volumeID, name: "/tmp/a.mdd", role: .mdd, order: 0)])
        #expect(Self.refusal(Fixtures.request(.openPackage(spec: bad)), handles: Self.good(2))
                == .invalidPackage(.notNamedByID(file: Fixtures.volumeID)))
    }

    /// The body ceiling a request asks for is at most the contract's 16 MiB, and at least one byte.
    @Test func aRenderLimitOutsideTheContractsIsRefused() {
        let ceiling = Limits.maxBodyBytes
        for asked: UInt64 in [0, ceiling + 1, 64 << 20] {
            let render = RenderContext(maxBodyBytes: asked)
            #expect(Self.refusal(Fixtures.request(.entry(dict: Fixtures.dict, entry: Fixtures.entryRef, render: render)))
                    == .renderLimitOutOfRange(requested: asked, ceiling: ceiling))
            #expect(Self.refusal(Fixtures.request(.resource(dict: Fixtures.dict, path: "a.css", render: render)))
                    == .renderLimitOutOfRange(requested: asked, ceiling: ceiling))
        }
        #expect(Self.refusal(Fixtures.request(.entry(dict: Fixtures.dict, entry: Fixtures.entryRef,
                                                     render: RenderContext(maxBodyBytes: ceiling)))) == nil)
    }

    /// At most `Limits.maxSuggestions` per call (Codex objection 2); the core's own cap is ten times that.
    @Test func moreSuggestionsThanTheContractsAreRefused() {
        let asked = { (limit: UInt32) in Self.refusal(Fixtures.request(.suggest(prefix: "", dicts: [Fixtures.dict], limit: limit))) }
        #expect(asked(Limits.maxSuggestions) == nil)
        #expect(asked(Limits.maxSuggestions + 1) == .suggestLimitOutOfRange(requested: Limits.maxSuggestions + 1,
                                                                            ceiling: Limits.maxSuggestions))
        #expect(asked(.max) == .suggestLimitOutOfRange(requested: .max, ceiling: Limits.maxSuggestions))
    }

    /// A package of more files than `Limits.maxPackageFiles` is refused before anything is opened: each volume is an
    /// import thread and each file a held descriptor.
    @Test func aPackageOfTooManyFilesIsRefused() {
        let volumes = (0..<Limits.maxPackageFiles).map { FileSpec.volume(id: UUID(), order: $0) }
        let spec = PackageSpec(files: [.mdx(id: Fixtures.mdxID)] + volumes)
        #expect(spec.problem == .tooManyFiles(found: Limits.maxPackageFiles + 1, limit: Limits.maxPackageFiles))
        #expect(PackageSpec(files: [.mdx(id: Fixtures.mdxID)] + volumes.dropLast()).problem == nil)
    }

    /// An envelope larger than `Limits.maxEnvelopeBytes` is refused before a byte of it is decoded.
    @Test func anOversizedRequestIsRefusedBeforeDecoding() {
        let huge = Data(repeating: UInt8(ascii: " "), count: Int(Limits.maxEnvelopeBytes) + 1)
        #expect(Request.receive(huge, handles: [], filesOf: [:]) == .answered(Response(id: nil, outcome: .failure(
            .refused(.envelopeTooLarge(bytes: Limits.maxEnvelopeBytes + 1, limit: Limits.maxEnvelopeBytes))))))
    }

    /// `receive` applies the same refusals, answering at once with the request's id.
    @Test func receivingARefusedRequestAnswersItAtOnce() throws {
        let request = Fixtures.request(Self.open, id: 12)
        #expect(Request.receive(try request.encoded(), handles: [], filesOf: Fixtures.filesOf)
                == .answered(Response(id: 12, outcome: .failure(.refused(.missingHandle)))))
    }

    /// The base every entry is rewritten under is the contract's, not the request's: the one authority the entry
    /// view's scheme handler answers (plan WI-4), so no request can have the core write an entry's URLs elsewhere.
    @Test func theRenderBaseIsFixed() throws {
        #expect(RenderContext.baseURL == "xdict://d/")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RenderContext.reader)) as? [String: Any]
        // The ceiling and the reader's "Original style" (ADR-0010 Q3), never a base.
        #expect(Set(json?.keys ?? [:].keys) == ["maxBodyBytes", "originalStyle"])
        #expect(RenderContext.reader.maxBodyBytes == Limits.maxBodyBytes)
    }
}
