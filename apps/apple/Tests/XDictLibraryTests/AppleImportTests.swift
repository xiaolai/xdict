import Foundation
import Testing
import XDictAppleSource
import XDictClient
import XDictContract
import XDictLibrary

/// **The dictionary service's conversion, faked as the service does it** (contract 6; ADR-0011 decisions 4 and 9): the
/// staged copy is hashed by the shared manifest, a folder of its own is published with an MDX and an MDD of the test's
/// bytes, and the staging folder is removed whatever happens. It can refuse, hold, or publish and lose its reply.
actor FakeConversion: AppleConversionBackend {
    let root: URL
    var mdx = "edition one"
    var mdd = "resources one"
    var refusal: AppleImportRefusal?
    /// Publishes, then answers as a dying connection does: the reply is lost.
    var loseReply = false
    var holding = false
    private(set) var conversions = 0
    private var held: CheckedContinuation<Bool, Never>?

    init(root: URL) {
        self.root = root
    }

    func set(mdx: String? = nil, mdd: String? = nil) {
        if let mdx { self.mdx = mdx }
        if let mdd { self.mdd = mdd }
    }

    func refuse(_ refusal: AppleImportRefusal?) { self.refusal = refusal }
    func losingReplies() { loseReply = true }
    func hold() { holding = true }
    var isHolding: Bool { held != nil }

    func beginConversion(staging: UUID, progress: @escaping @Sendable (UInt64, UInt64) -> Void) async -> ConversionJob {
        conversions += 1
        let outcome = Task { await self.convert(staging, progress: progress) }
        return ConversionJob(outcome: { await outcome.value }, cancel: { await self.cancel() })
    }

    private func cancel() {
        held?.resume(returning: false)
        held = nil
    }

    private func convert(_ staging: UUID, progress: @Sendable (UInt64, UInt64) -> Void) async
        -> Result<Converted, ClientFailure> {
        let folder = SharedContainer.staging(in: root).appending(path: staging.uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        progress(1, 4)
        if holding {
            guard await withCheckedContinuation({ held = $0 }) else {
                return .failure(.wire(.core(.cancelled(detail: "cancelled"))))
            }
        }
        if let refusal { return .failure(.wire(.appleImport(refusal))) }
        guard let revision = try? Manifest.revision(of: folder) else {
            return .failure(.wire(.appleImport(.stagingNotFound)))
        }
        let conversion = UUID()
        let out = root.appending(path: conversion.uuidString)
        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
            try Data(mdx.utf8).write(to: out.appending(path: "dictionary.mdx"))
            try Data(mdd.utf8).write(to: out.appending(path: "dictionary.mdd"))
        } catch {
            return .failure(.wire(.appleImport(.unwritable(file: "", code: 0))))
        }
        if loseReply { return .failure(.wire(.interrupted)) }
        return .success(Converted(conversion: conversion, sourceRevision: revision, converterRevision: AppleConverter.revision,
                                  files: ["dictionary.mdx", "dictionary.mdd"], entries: 1, redirects: 0, resources: 1))
    }
}

/// **Add Apple Dictionaries… and Convert Again, against fakes of the service** (ADR-0011 decisions 4 and 7–10; plan
/// WI-5): the copy, the conversion, the library's import with its source record and lineage; already imported, refused,
/// cancelled and lost replies; Convert Again's one undoable join and the image-only change that joins nothing; a fresh
/// import after removal suggesting its join; restarts after each step, and the sweep; remove, Undo, and a copy that
/// still reads after Apple removed the bundle.
@MainActor
struct AppleImportTests {
    let dir: Scratch
    let backend = FakeBackend()
    let conversion: FakeConversion
    let storeDir: URL
    let root: URL
    let installed: URL

    init() throws {
        dir = try Scratch()
        storeDir = dir.url.appending(path: "store")
        root = dir.url.appending(path: "group/AppleImports")
        installed = dir.url.appending(path: "AssetsV2/a.asset/AssetData")
        conversion = FakeConversion(root: root)
    }

    /// A bundle on disk, with files the converter reads, a localisation and an image.
    func bundle(_ name: String = "Oxford", identifier: String = "com.apple.dictionary.NOAD") throws -> InstalledBundle {
        try dir.files("AssetsV2/a.asset/AssetData/\(name).dictionary/Contents/Info.plist",
                      "AssetsV2/a.asset/AssetData/\(name).dictionary/Contents/Resources/Body.data",
                      "AssetsV2/a.asset/AssetData/\(name).dictionary/Contents/Resources/Images/a.png",
                      "AssetsV2/a.asset/AssetData/\(name).dictionary/Contents/Resources/en.lproj/InfoPlist.strings")
        return InstalledBundle(url: installed.appending(path: "\(name).dictionary"), identifier: identifier,
                               displayName: name, version: "1.0", bytes: 4, searchLanguage: "en",
                               explanationLanguage: "zh-Hans", refusal: nil)
    }

    func library(_ backend: FakeBackend? = nil) -> Library {
        Library(store: LibraryStore(directory: storeDir), backend: backend ?? self.backend)
    }

    func importer(_ library: Library) -> AppleImporter {
        AppleImporter(library: library, backend: conversion, root: root)
    }

    func contents(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    var staging: [String] { contents(root.appending(path: "staging")) }

    var outputs: [String] { contents(root).filter { $0 != "staging" } }

    // MARK: - Importing

    @Test func anImportCopiesConvertsAndAddsWithItsSourceAndAFreshLineage() async throws {
        let oxford = try bundle()
        let library = library()
        await library.start()
        let importer = importer(library)
        importer.importBundles([oxford])
        await importer.settle()
        await library.settle()
        let entry = try #require(library.entries.first)
        let source = try #require(entry.appleSource)
        #expect(importer.steps[oxford.identifier] == .added(entry.id))
        #expect(source.bundleIdentifier == oxford.identifier && source.bundleVersion == "1.0")
        #expect(source.sourceRevision == (try Manifest.revision(of: oxford.url)), "the service hashed a byte-for-byte copy")
        #expect(source.converterRevision == AppleConverter.revision)
        #expect(outputs == [source.conversion.uuidString] && staging.isEmpty)
        #expect(entry.files.map(\.fileName) == ["dictionary.mdx", "dictionary.mdd"])
        #expect(library.phases[entry.id] == .ready && entry.lineage != nil && entry.offer == nil)
        #expect(entry.languages.pair == LanguagePair(search: "en", explanation: "zh-Hans") && !entry.languages.needsAsking)
        #expect(library.importedAppleBundles == [oxford.identifier])
        let saved = try #require(try LibraryStore(directory: storeDir).load())
        #expect(saved.version == 2 && saved.entries.first?.appleSource == source)
        #expect(saved.appleLineages[oxford.identifier]?.lineage == entry.lineage)
    }

    @Test func anAlreadyImportedOrRefusedBundleIsNotConvertedAgain() async throws {
        let oxford = try bundle()
        let refused = InstalledBundle(url: oxford.url, identifier: "com.apple.dictionary.AppleDictionary",
                                      displayName: "Apple Dictionary", version: nil, bytes: 1, searchLanguage: nil,
                                      explanationLanguage: nil, refusal: .noKeyTextIndex)
        let library = library()
        await library.start()
        let importer = importer(library)
        importer.importBundles([oxford])
        await importer.settle()
        importer.importBundles([oxford, refused])
        await importer.settle()
        #expect(await conversion.conversions == 1 && library.entries.count == 1)
        #expect(importer.steps[refused.identifier] == nil)
    }

    @Test func aRefusalIsNamedAndAddsNothing() async throws {
        let oxford = try bundle()
        await conversion.refuse(.notVersion3(found: 1))
        let library = library()
        await library.start()
        let importer = importer(library)
        importer.importBundles([oxford])
        await importer.settle()
        #expect(importer.steps[oxford.identifier] == .failed(.refused(.notVersion3(found: 1))))
        #expect(library.entries.isEmpty && outputs.isEmpty && staging.isEmpty)
    }

    @Test func noSharedContainerIsSaidAndNothingIsCopied() async throws {
        let oxford = try bundle()
        let library = library()
        await library.start()
        let importer = AppleImporter(library: library, backend: conversion, root: nil)
        importer.importBundles([oxford])
        await importer.settle()
        #expect(importer.steps[oxford.identifier] == .failed(.noContainer) && library.entries.isEmpty)
    }

    @Test func aCancelledConversionAddsNothing() async throws {
        let oxford = try bundle()
        await conversion.hold()
        let library = library()
        await library.start()
        let importer = importer(library)
        importer.importBundles([oxford])
        for _ in 0..<500 where !(await conversion.isHolding) { try await Task.sleep(for: .milliseconds(10)) }
        await importer.cancel(oxford.identifier)
        await importer.settle()
        #expect(importer.steps[oxford.identifier] == .cancelled)
        #expect(library.entries.isEmpty && staging.isEmpty)
    }

    /// **A lost reply** (decision 10): the service published, the app never heard. No entry, so no false "Already
    /// imported" and no second lineage; the unnamed folder goes at the sweep once a day old.
    @Test func aLostReplyLeavesOnlyAFolderTheSweepRemoves() async throws {
        let oxford = try bundle()
        await conversion.losingReplies()
        let library = library()
        await library.start()
        let importer = importer(library)
        importer.importBundles([oxford])
        await importer.settle()
        #expect(importer.steps[oxford.identifier] == .failed(.service))
        #expect(library.entries.isEmpty && library.importedAppleBundles.isEmpty && outputs.count == 1)
        #expect(importer.sweep()?.young.count == 1 && outputs.count == 1, "a young folder may still be imported")
        #expect(importer.sweep(now: Date(timeIntervalSinceNow: 2 * AppleImportSweep.maxAge))?.outputs.count == 1)
        #expect(outputs.isEmpty)
    }

    // MARK: - Restarts (decision 9)

    /// The app dies after the copy: a staging folder no conversion will take, removed at the next launch.
    @Test func aRestartAfterTheCopyRemovesTheStagingFolder() async throws {
        let oxford = try bundle()
        _ = try SnapshotCopy.copy(oxford.url, into: root)
        #expect(staging.count == 1)
        let library = library()
        await library.start()
        importer(library).sweep()
        #expect(staging.isEmpty && library.entries.isEmpty)
    }

    /// The app dies after the service converted and published, before the library heard: the same as a lost reply.
    @Test func aRestartAfterPublishingLeavesNoEntryAndTheFolderGoesWhenOld() async throws {
        try dir.files("group/AppleImports/\(UUID().uuidString)/dictionary.mdx")
        let library = library()
        await library.start()
        let importer = importer(library)
        #expect(importer.sweep()?.outputs.isEmpty == true && outputs.count == 1)
        #expect(library.importedAppleBundles.isEmpty)
        importer.sweep(now: Date(timeIntervalSinceNow: 2 * AppleImportSweep.maxAge))
        #expect(outputs.isEmpty)
    }

    /// The app dies after the entry was saved, while its import ran: the next launch imports it and keeps its folder.
    @Test func aRestartDuringTheImportFinishesItAndKeepsTheFolder() async throws {
        let oxford = try bundle()
        await backend.hold()
        let first = library()
        await first.start()
        let importer = importer(first)
        importer.importBundles([oxford])
        await importer.settle()
        #expect(first.entries.count == 1 && first.phases[first.entries[0].id] != .ready)

        let restarted = library(FakeBackend())
        await restarted.start()
        await restarted.settle()
        let entry = try #require(restarted.entries.first)
        #expect(restarted.phases[entry.id] == .ready && entry.appleSource != nil)
        let later = Date(timeIntervalSinceNow: 2 * AppleImportSweep.maxAge)
        #expect(self.importer(restarted).sweep(now: later)?.outputs.isEmpty == true && outputs.count == 1)
        await backend.release()
    }

    /// After the save, a restart opens it as any dictionary; the sweep keeps what the library names.
    @Test func aRestartAfterTheSaveReadsItAgain() async throws {
        let oxford = try bundle()
        let first = library()
        await first.start()
        let importer = importer(first)
        importer.importBundles([oxford])
        await importer.settle()
        await first.settle()
        let restarted = library(FakeBackend())
        await restarted.start()
        await restarted.settle()
        let entry = try #require(restarted.entries.first)
        #expect(restarted.phases[entry.id] == .ready && entry.id == first.entries.first?.id)
        #expect(entry.appleSource == first.entries.first?.appleSource && entry.appleSource != nil)
        self.importer(restarted).sweep(now: Date(timeIntervalSinceNow: 2 * AppleImportSweep.maxAge))
        #expect(outputs == [try #require(entry.appleSource).conversion.uuidString])
    }

    /// A library that cannot be read names no folder; sweeping then would delete its dictionaries' files.
    @Test func nothingIsSweptWhileTheLibraryCannotBeRead() async throws {
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        try Data("damaged".utf8).write(to: storeDir.appending(path: LibraryStore.fileName))
        try dir.files("group/AppleImports/staging/x/a", "group/AppleImports/\(UUID().uuidString)/dictionary.mdx")
        let library = library()
        await library.start()
        #expect(importer(library).sweep(now: Date(timeIntervalSinceNow: 9 * AppleImportSweep.maxAge)) == nil)
        #expect(staging == ["x"] && outputs.count == 1)
    }

    // MARK: - Updates, Convert Again and joins (decisions 7 and 8)

    func imported(_ oxford: InstalledBundle) async throws -> (Library, AppleImporter, LibraryEntry) {
        let library = library()
        await library.start()
        let importer = importer(library)
        importer.importBundles([oxford])
        await importer.settle()
        await library.settle()
        return (library, importer, try #require(library.entries.first))
    }

    @Test func anImageChangeOffersConvertAgainWhichKeepsTheEditionWithANewMDD() async throws {
        let oxford = try bundle()
        let (library, importer, entry) = try await imported(oxford)
        await importer.checkForUpdates(installed: [oxford])
        #expect(library.appleStatus[entry.id] == .current)
        try Data("new image".utf8).write(to: oxford.url.appending(path: "Contents/Resources/Images/a.png"))
        await importer.checkForUpdates(installed: [oxford])
        #expect(library.appleStatus[entry.id] == .updated)

        await conversion.set(mdd: "resources two")
        importer.convertAgain(entry.id, from: oxford)
        await importer.settle()
        await library.settle()
        let again = try #require(library.entries.first)
        #expect(again.edition == entry.edition && again.lineage == entry.lineage && again.join == nil && again.offer == nil)
        #expect(again.appleSource?.conversion != entry.appleSource?.conversion)
        let mdd = try #require(again.files.first { $0.role == .mdd })
        #expect(try String(contentsOf: URL(filePath: mdd.location.path), encoding: .utf8) == "resources two")
        await importer.checkForUpdates(installed: [oxford])
        #expect(library.appleStatus[entry.id] == .current && library.phases[entry.id] == .ready)
    }

    @Test func aLocalisationOnlyChangeOffersNothing() async throws {
        let oxford = try bundle()
        let (library, importer, entry) = try await imported(oxford)
        try Data("translated".utf8).write(to: oxford.url.appending(path: "Contents/Resources/en.lproj/InfoPlist.strings"))
        await importer.checkForUpdates(installed: [oxford])
        #expect(library.appleStatus[entry.id] == .current)
    }

    @Test func aConverterBumpOffersConvertAgain() throws {
        let record = AppleSourceRecord(bundleIdentifier: "x", bundleVersion: nil,
                                       sourceRevision: "m1:" + String(repeating: "a", count: 64), converterRevision: 1,
                                       conversion: UUID())
        let same = InstalledSource(sourceRevision: record.sourceRevision)
        #expect(AppleStatus.of(record, installed: same, converter: 1) == .current)
        #expect(AppleStatus.of(record, installed: same, converter: 2) == .updated)
        #expect(AppleStatus.of(record, installed: InstalledSource(sourceRevision: "m1:" + String(repeating: "b", count: 64)),
                               converter: 1) == .updated)
        #expect(AppleStatus.of(record, installed: nil, converter: 1) == .removed)
        #expect(AppleStatus.of(record, installed: InstalledSource(sourceRevision: nil), converter: 2) == .current,
                "a bundle that cannot be read now offers nothing")
    }

    /// Revision 2 keeps Apple's pronunciation markers (ADR-0013 decision 1): an import made by revision 1 is offered
    /// Convert Again by the revision the app ships, never regenerated silently.
    @Test func aRevisionOneImportIsOfferedConvertAgain() throws {
        #expect(AppleConverter.revision == 2)
        let record = AppleSourceRecord(bundleIdentifier: "x", bundleVersion: nil,
                                       sourceRevision: "m1:" + String(repeating: "a", count: 64), converterRevision: 1,
                                       conversion: UUID())
        let same = InstalledSource(sourceRevision: record.sourceRevision)
        #expect(AppleStatus.of(record, installed: same, converter: AppleConverter.revision) == .updated)
    }

    /// Convert Again's new edition joins the dictionary as one recorded join, which Undo splits exactly (ADR-0002 d.3).
    @Test func convertAgainJoinsTheNewEditionOnceAndUndoes() async throws {
        let oxford = try bundle()
        let (library, importer, entry) = try await imported(oxford)
        let original = try #require(entry.lineage)
        try Data("new body".utf8).write(to: oxford.url.appending(path: "Contents/Resources/Body.data"))
        await conversion.set(mdx: "edition two")
        importer.convertAgain(entry.id, from: oxford)
        await importer.settle()
        await library.settle()
        let again = try #require(library.entries.first)
        let join = try #require(again.join, "the join is recorded")
        #expect(again.edition != entry.edition && again.lineage == original && again.offer == nil)
        #expect(join.joinedTo == original && join.previous != original)
        #expect(await backend.lineageCalls == [.join(join.edition, original)], "one join")
        #expect(await library.undoJoin(entry.id))
        #expect(library.entries.first?.lineage == join.previous && library.entries.first?.offer != nil)
    }

    /// A fresh import of a bundle the reader removed is a new lineage; the join is suggested, never applied.
    @Test func aReImportAfterRemovalIsANewLineageWithTheJoinSuggested() async throws {
        let oxford = try bundle()
        let (library, importer, entry) = try await imported(oxford)
        await library.remove(entry.id)
        #expect(library.importedAppleBundles.isEmpty)
        await conversion.set(mdx: "edition two")
        importer.importBundles([oxford])
        await importer.settle()
        await library.settle()
        let fresh = try #require(library.entries.first)
        let offer = try #require(fresh.offer, "the join is suggested")
        #expect(fresh.id != entry.id && fresh.lineage != entry.lineage && offer.earlierLineage == entry.lineage)
        #expect(await backend.lineageCalls.isEmpty, "never applied")
        #expect(try LibraryStore(directory: storeDir).load()?.appleLineages[oxford.identifier]?.lineage == entry.lineage)
    }

    /// **Removal keeps the folder until the sweep** (decision 9): Undo brings back a dictionary that reads, even after
    /// Apple removed the bundle.
    @Test func removeThenUndoStillReadsAfterTheBundleIsGone() async throws {
        let oxford = try bundle()
        let (library, importer, entry) = try await imported(oxford)
        let removed = try #require(await library.removeForUndo(entry.id))
        #expect(importer.sweep()?.young.count == 1 && outputs.count == 1, "a removed dictionary's folder stays")
        try FileManager.default.removeItem(at: oxford.url)
        library.restore(removed)
        await library.settle()
        #expect(library.phases[entry.id] == .ready)
        await importer.checkForUpdates(installed: [])
        #expect(library.appleStatus[entry.id] == .removed)
        #expect(importer.sweep(now: Date(timeIntervalSinceNow: 2 * AppleImportSweep.maxAge))?.outputs.isEmpty == true)
    }

    // MARK: - The document (decision 10)

    func write(_ json: String) throws {
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: storeDir.appending(path: LibraryStore.fileName))
    }

    @Test func aVersionOneLibraryIsReadAndWrittenBackAsTwo() async throws {
        try write(#"{"version": 1, "entries": []}"#)
        let library = library()
        await library.start()
        #expect(library.unreadable == nil && library.appleLineages.isEmpty)
        library.add([])
        #expect(try LibraryStore(directory: storeDir).load()?.version == 2)
        let text = try String(contentsOf: storeDir.appending(path: LibraryStore.fileName), encoding: .utf8)
        #expect(text.contains(#""version" : 2"#) && text.contains("appleLineages"))
    }

    @Test func aNewerLibraryIsRefused() throws {
        try write(#"{"version": 3, "entries": [], "appleLineages": {}}"#)
        #expect(throws: LibraryStoreError.newerVersion(3)) { try LibraryStore(directory: storeDir).load() }
    }

    @Test func aVersionTwoLibraryWithoutItsLineagesIsDamaged() throws {
        try write(#"{"version": 2, "entries": []}"#)
        #expect(throws: LibraryStoreError.damaged) { try LibraryStore(directory: storeDir).load() }
    }

    /// A source record this version could not have written is damage, never "not an Apple dictionary"; the control is the
    /// same record well formed.
    @Test func aDamagedSourceRecordIsADamagedLibrary() async throws {
        let oxford = try bundle()
        let (_, _, entry) = try await imported(oxford)
        let file = storeDir.appending(path: LibraryStore.fileName)
        let good = try String(contentsOf: file, encoding: .utf8)
        let revision = try #require(entry.appleSource?.sourceRevision)
        #expect(try LibraryStore(directory: storeDir).load()?.entries.first?.appleSource == entry.appleSource)
        try Data(good.replacingOccurrences(of: revision, with: "m1:nothex").utf8).write(to: file)
        #expect(throws: LibraryStoreError.damaged) { try LibraryStore(directory: storeDir).load() }
        try Data(good.replacingOccurrences(of: oxford.identifier, with: "").utf8).write(to: file)
        #expect(throws: LibraryStoreError.damaged) { try LibraryStore(directory: storeDir).load() }
    }
}

extension AppleImporter {
    func settle(sourceLocation: SourceLocation = #_sourceLocation) async {
        let settled = await settled(within: .seconds(30))
        #expect(settled, "the Apple import was still working after 30 s", sourceLocation: sourceLocation)
    }
}
