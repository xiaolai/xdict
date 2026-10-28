import Foundation
import Testing
import XDictContract
@testable import XDictService

/// **A pack built through the contract is the pack the library writes** (plan-local-word-pack WI-5, contract 20): one
/// tiny source, pinned by its own hash, goes in through `buildWordPack`; the service answers `wordPackBuilt` with the
/// pack it installed, the file holds exactly the record the source declared, and a second build writes the same bytes.
///
/// The library's own equality is held by `xdict-pack`'s parity gate over the real sources (its pack's SHA-256 is
/// `f33954be…`); this test holds the contract's path to it — the operation carries paths and adds nothing.
struct WordPackBuildTests {
    /// The fixture's exact bytes, and its pinned SHA-256 — computed once, as the manifest pins a real download.
    static let cmudict = ";;; a comment\nhello HH AH0 L OW1\n"
    static let cmudictSha256 = "5a1bc976b9bf09a03d75f721b807aa1b9c0cb128abeb01bdba630733e176eb68"

    /// A raw directory holding one pinned CMUdict and the manifest that pins it.
    static func fixture(in root: URL) throws -> (raw: URL, manifest: URL) {
        let raw = root.appending(path: "sources")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let file = raw.appending(path: "cmudict.dict")
        try cmudict.write(to: file, atomically: true, encoding: .utf8)
        let data = try Data(contentsOf: file)
        let sha = Self.cmudictSha256
        let manifest = root.appending(path: "word_lexicon_sources.json")
        let json = """
        {"format":"xdict-word-lexicon-sources","version":2,"sources":[{"id":"cmu","provider":"cmudict",\
        "name":"The CMU Pronouncing Dictionary","url":"https://example.invalid/cmudict.dict",\
        "version":"test-1","sha256":"\(sha)","file":"cmudict.dict","bytes":\(data.count),\
        "licence":"BSD-2-Clause","attribution":"The xdict-pack tests","notice":"Copyright"}]}
        """
        try json.write(to: manifest, atomically: true, encoding: .utf8)
        return (raw, manifest)
    }

    static func build(sources: URL, manifest: URL, output: URL, service: Dictionaries) -> Outcome {
        service.run(.buildWordPack(sources: sources.path, manifest: manifest.path, output: output.path),
                    files: [], progress: nil).0
    }

    @Test func aTinyFixtureBuildsAndInstallsThroughTheContract() throws {
        let root = URL.temporaryDirectory.appending(path: "xdict-pack-build-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (raw, manifest) = try Self.fixture(in: root)
        let service = Dictionaries(storage: .init(indexes: root.appending(path: "indexes"),
                                                  registry: root.appending(path: "registry")))
        let output = root.appending(path: "WordPack/xdict-words-en.jsonl")

        let answered = Self.build(sources: raw, manifest: manifest, output: output, service: service)
        guard case .answer(.wordPackBuilt(let state)) = answered, let pack = state.pack else {
            Issue.record("the build did not answer wordPackBuilt: \(answered)")
            return
        }
        #expect(pack.records == 1, "one pronunciation record")
        #expect(pack.sources == ["cmu"], "the header lists the one source")
        #expect(pack.version == 2, "the pack schema this core reads")

        let written = try String(contentsOf: output, encoding: .utf8)
        #expect(written.contains(#""word":"hello""#), "the record the source declared: \(written)")
        #expect(written.split(separator: "\n").count == 2, "a header and one record")

        // **A second build is the same bytes**: the contract adds nothing to what the library writes.
        let second = root.appending(path: "again/xdict-words-en.jsonl")
        _ = Self.build(sources: raw, manifest: manifest, output: second, service: service)
        #expect(try Data(contentsOf: output) == (try Data(contentsOf: second)), "two builds are byte-identical")

        // **A source that fails its pinned hash writes nothing**, and the sentence names the file.
        let tampered = raw.appending(path: "cmudict.dict")
        try "hello HH AH0 L OW1\n".write(to: tampered, atomically: true, encoding: .utf8)
        let refused = root.appending(path: "refused/xdict-words-en.jsonl")
        guard case .failure(.core(.malformed(let detail))) = Self.build(sources: raw, manifest: manifest,
                                                                         output: refused, service: service) else {
            Issue.record("a corrupted source was not refused")
            return
        }
        #expect(detail.contains("cmudict.dict"), "the sentence names the file: \(detail)")
        #expect(!FileManager.default.fileExists(atPath: refused.path), "nothing is written")
    }
}
