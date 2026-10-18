import Foundation
import Testing
import XDictAppleImport
import XDictContract
@testable import XDictService
import XDictTestSupport

/// **The service's conversion of a staged snapshot** (ADR-0011 decisions 4, 5, 9 and 11; plan WI-4): resolved by UUID
/// in `AppleImports/staging/`, bounded, hashed, converted and published into a folder of its own; refused by kind; and
/// whatever happens, the staging folder is gone afterwards, and nothing is left but a published conversion.
struct AppleImportServiceTests {
    @Test func aGoodSnapshotIsPublishedIntoItsOwnFolder() throws {
        let staging = try AppleStaging()
        let id = try staging.stage()
        let converted = try staging.convert(id).get()
        #expect(converted.entries == 2 && converted.redirects == 1 && converted.resources == 1)
        #expect(converted.files == ["dictionary.mdx", "dictionary.mdd"])
        #expect(converted.converterRevision == UInt32(AppleImport.converterRevision))
        #expect(converted.sourceRevision.hasPrefix("m1:") && converted.sourceRevision.count == 3 + 64)
        #expect(staging.leftovers == [converted.conversion.uuidString], "the staging folder is consumed")
        let published = staging.store.root.appending(path: converted.conversion.uuidString)
        #expect(try FileManager.default.contentsOfDirectory(atPath: published.path).sorted() == ["dictionary.mdd", "dictionary.mdx"])
    }

    /// The same snapshot converted twice is two conversions, two folders: never reused, never overwritten (decision 9);
    /// the same source revision, and the same bytes (decision 6).
    @Test func eachConversionHasAFolderOfItsOwn() throws {
        let staging = try AppleStaging()
        let id = try staging.stage()
        let copy = UUID()
        try FileManager.default.copyItem(at: staging.folder(id), to: staging.folder(copy))
        let first = try staging.convert(id).get()
        let second = try staging.convert(copy).get()
        #expect(first.conversion != second.conversion && first.sourceRevision == second.sourceRevision)
        let mdx = { (c: Converted) in try Data(contentsOf: staging.store.root.appending(path: "\(c.conversion.uuidString)/dictionary.mdx")) }
        #expect(try mdx(first) == mdx(second))
        #expect(staging.leftovers.count == 2)
    }

    // MARK: - Refused by kind, leaving nothing

    static func refusal(_ overrides: SyntheticAppleBundle.Overrides = .init(),
                        entries: [SyntheticAppleBundle.Entry] = SyntheticAppleBundle.defaultEntries,
                        snapshot: SnapshotBounds = .production, converter: Bounds = .production) throws -> WireError? {
        let staging = try AppleStaging(snapshot: snapshot, converter: converter)
        let id = try staging.stage(entries: entries, overrides)
        let outcome = staging.convert(id)
        #expect(staging.leftovers.isEmpty, "a refused conversion leaves nothing: \(staging.leftovers)")
        guard case .failure(let error) = outcome else { return nil }
        return error
    }

    @Test func formatOneIsRefused() throws {
        var o = SyntheticAppleBundle.Overrides()
        o.plist = try SyntheticAppleBundle.plist(version: 1, keyTextIndex: false)
        #expect(try Self.refusal(o) == .appleImport(.notVersion3(found: 1)))
    }

    @Test func version4IsRefused() throws {
        var o = SyntheticAppleBundle.Overrides()
        o.plist = try SyntheticAppleBundle.plist(version: 4)
        #expect(try Self.refusal(o) == .appleImport(.notVersion3(found: 4)))
    }

    @Test func noKeyTextIndexIsRefused() throws {
        var o = SyntheticAppleBundle.Overrides()
        o.plist = try SyntheticAppleBundle.plist(keyTextIndex: false)
        #expect(try Self.refusal(o) == .appleImport(.noKeyTextIndex))
    }

    @Test func aMalformedInfoPlistIsRefused() throws {
        var o = SyntheticAppleBundle.Overrides()
        o.plist = Data("not a plist".utf8)
        #expect(try Self.refusal(o) == .appleImport(.malformedInfoPlist(detail: "unparsable")))
    }

    @Test func tooManyFilesAreRefusedBeforeAnyIsRead() throws {
        #expect(try Self.refusal(snapshot: SnapshotBounds(files: 3, bytes: 512 << 20))
                    == .appleImport(.boundExceeded(.fileCount(limit: 3))))
    }

    @Test func tooManyBytesAreRefusedBeforeAnyIsRead() throws {
        #expect(try Self.refusal(snapshot: SnapshotBounds(files: 512, bytes: 100))
                    == .appleImport(.boundExceeded(.snapshotBytes(limit: 100))))
    }

    @Test func eachConverterBoundIsRefusedByKind() throws {
        let p = Bounds.production
        #expect(try Self.refusal(converter: Bounds(sourceFileBytes: 16, infoPlistBytes: p.infoPlistBytes,
                                                   decompressedBytes: p.decompressedBytes, outputBytes: p.outputBytes))
                    == .appleImport(.boundExceeded(.sourceFile(name: "Body.data", limit: 16))))
        #expect(try Self.refusal(converter: Bounds(sourceFileBytes: p.sourceFileBytes, infoPlistBytes: p.infoPlistBytes,
                                                   decompressedBytes: 10, outputBytes: p.outputBytes))
                    == .appleImport(.boundExceeded(.decompression(limit: 10))))
        #expect(try Self.refusal(converter: Bounds(sourceFileBytes: p.sourceFileBytes, infoPlistBytes: p.infoPlistBytes,
                                                   decompressedBytes: p.decompressedBytes, outputBytes: 10))
                    == .appleImport(.boundExceeded(.output(limit: 10))))
    }

    /// A section claiming more than any block may inflate to is refused before its buffer is allocated.
    @Test func aLyingBlockIsRefusedByItsClaim() throws {
        let buf = [SyntheticAppleBundle.entry("e1", "alpha")].flatMap { SyntheticAppleBundle.i32($0.count) + $0 }
        let z = try SyntheticAppleBundle.zlib(buf)
        var o = SyntheticAppleBundle.Overrides()
        o.body = SyntheticAppleBundle.window(SyntheticAppleBundle.i32(8 + z.count) + SyntheticAppleBundle.i32(4 + z.count)
                                             + SyntheticAppleBundle.i32(1 << 29) + z)
        #expect(try Self.refusal(o) == .appleImport(.boundExceeded(.inflatedBlock(claimed: 1 << 29))))
    }

    @Test func aKeyLongerThanTheFormatHoldsIsRefused() throws {
        var o = SyntheticAppleBundle.Overrides()
        o.keytext = try SyntheticAppleBundle.keytext([SyntheticAppleBundle.record([SyntheticAppleBundle.lexeme(0, "a", first: true)])])
        let title = String(repeating: "a", count: 70_000)
        #expect(try Self.refusal(o, entries: [("e1", title, "<p>long</p>", [])])
                    == .appleImport(.boundExceeded(.keyLength(units: 70_000))))
    }

    /// Apple's files keep stale bytes after `KeyText.data`'s terminator (megabytes in Croatian and Korean): accepted.
    @Test func aStaleKeyTextTailIsAccepted() throws {
        let entries = SyntheticAppleBundle.defaultEntries
        var records: [[UInt8]] = []
        var pos = 0
        for e in entries {
            records.append(SyntheticAppleBundle.record(([e.title] + e.keys).enumerated().map {
                SyntheticAppleBundle.lexeme(pos, $0.element, first: $0.offset == 0)
            }))
            pos += 4 + SyntheticAppleBundle.entry(e.id, e.title, e.body).count
        }
        let buf = records.flatMap { $0 }
        let z = try SyntheticAppleBundle.zlib(buf)
        var o = SyntheticAppleBundle.Overrides()
        o.keytext = SyntheticAppleBundle.window(SyntheticAppleBundle.i32(0) + SyntheticAppleBundle.i32(z.count + 4)
                                                + SyntheticAppleBundle.i32(buf.count) + z + SyntheticAppleBundle.i32(0)
                                                + SyntheticAppleBundle.i32(0) + [UInt8](repeating: 0xAB, count: 4096))
        let staging = try AppleStaging()
        let converted = try staging.convert(try staging.stage(entries: entries, o)).get()
        #expect(converted.entries == 2 && converted.redirects == 1)
    }

    // MARK: - The staging folder, resolved by name only

    @Test func anUnknownStagingFolderIsNotFound() throws {
        let staging = try AppleStaging()
        #expect(staging.convert(UUID()) == .failure(.appleImport(.stagingNotFound)))
    }

    @Test func aStagingNameThatIsALinkIsRefusedAndRemovedWithoutFollowingIt() throws {
        let staging = try AppleStaging()
        let elsewhere = try staging.stage()
        let id = UUID()
        try FileManager.default.createSymbolicLink(at: staging.folder(id), withDestinationURL: staging.folder(elsewhere))
        #expect(staging.convert(id) == .failure(.appleImport(.stagingNotAFolder)))
        #expect(staging.leftovers == ["staging/\(elsewhere.uuidString)"], "the link is removed, its target untouched")
    }

    @Test func aStagingNameThatIsAFileIsRefused() throws {
        let staging = try AppleStaging()
        let id = UUID()
        try Data("x".utf8).write(to: staging.folder(id))
        #expect(staging.convert(id) == .failure(.appleImport(.stagingNotAFolder)))
        #expect(staging.leftovers.isEmpty)
    }

    @Test func aLinkInsideTheSnapshotIsRefusedNeverFollowed() throws {
        let staging = try AppleStaging()
        let id = try staging.stage()
        try FileManager.default.createSymbolicLink(at: staging.folder(id).appending(path: "Contents/Resources/out.css"),
                                                   withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        #expect(staging.convert(id) == .failure(.appleImport(.symbolicLink(path: "Contents/Resources/out.css"))))
        #expect(staging.leftovers.isEmpty)
    }

    @Test func aPipeInsideTheSnapshotIsRefused() throws {
        let staging = try AppleStaging()
        let id = try staging.stage()
        let fifo = staging.folder(id).appending(path: "Contents/Resources/pipe")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(staging.convert(id) == .failure(.appleImport(.notARegularFile(path: "Contents/Resources/pipe"))))
        #expect(staging.leftovers.isEmpty)
    }

    // MARK: - Cancelled where it is asked, leaving nothing

    static func cancelled(at stop: @escaping @Sendable (ConversionStep) -> Bool,
                          make: (URL) throws -> URL) throws -> (Result<Converted, WireError>, [String]) {
        let progress = ImportProgress { _, _ in }
        let staging = try AppleStaging(onStep: { if stop($0) { progress.cancel() } })
        let id = try staging.stage(make)
        let outcome = staging.convert(id, progress: progress)
        return (outcome, staging.leftovers)
    }

    @Test func cancelledMidInflateItLeavesNothing() throws {
        let (outcome, left) = try Self.cancelled(at: { $0.phase == .reading && $0.done > 0 }) {
            try SyntheticAppleBundle.make(in: $0, sections: [Self.big(1, from: 0), Self.big(1, from: 1), Self.big(1, from: 2)])
        }
        guard case .failure(.core(.cancelled)) = outcome else {
            Issue.record("not cancelled: \(outcome)")
            return
        }
        #expect(left.isEmpty, "\(left)")
    }

    @Test func cancelledMidWriteItLeavesNothing() throws {
        let (outcome, left) = try Self.cancelled(at: { $0.phase == .writing && $0.done > 0 }) {
            try SyntheticAppleBundle.make(in: $0, entries: Self.big(4, from: 0))
        }
        guard case .failure(.core(.cancelled)) = outcome else {
            Issue.record("not cancelled: \(outcome)")
            return
        }
        #expect(left.isEmpty, "\(left)")
    }

    /// Progress rises and ends at its total: hashing, then reading, then writing.
    @Test func progressRisesToItsTotal() throws {
        let reports = ReportLog()
        let staging = try AppleStaging()
        _ = try staging.convert(try staging.stage(entries: Self.big(3, from: 0)),
                                progress: ImportProgress { done, total in reports.add(done, total) }).get()
        let seen = reports.all
        #expect(seen.count >= 3 && seen.map(\.0) == seen.map(\.0).sorted(), "\(seen)")
        #expect(Set(seen.map(\.1)).count == 1 && seen.last.map { $0.0 == $0.1 } == true, "\(seen)")
    }

    static func big(_ n: Int, from first: Int) -> [SyntheticAppleBundle.Entry] {
        (first..<(first + n)).map { ("e\($0)", "word\($0)", "<p>" + String(repeating: "text\($0) ", count: 8000) + "</p>", []) }
    }
}

final class ReportLog: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [(UInt64, UInt64)] = []

    func add(_ done: UInt64, _ total: UInt64) {
        lock.withLock { reports.append((done, total)) }
    }

    var all: [(UInt64, UInt64)] {
        lock.withLock { reports }
    }
}
