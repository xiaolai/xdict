import Foundation
import Testing
import XDictContract
@testable import XDictService

/// What the service learns of a received descriptor before admission (Codex objection 7): its identity by `fstat`,
/// and whether it is a regular file opened read-only. A pipe, a socket or a writable file is not a dictionary file
/// the reader chose, whatever its package entry says.
struct HandleInspectionTests {
    static func scratchFile() throws -> URL {
        let file = FileManager.default.temporaryDirectory.appending(path: "xdict-inspect-\(UUID().uuidString)")
        try Data("hold".utf8).write(to: file)
        return file
    }

    @Test func aRegularFileOpenedReadOnlyPasses() throws {
        let file = try Self.scratchFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var info = stat()
        try #require(stat(file.path, &info) == 0)
        #expect(HandleInspection.facts(of: handle.fileDescriptor)
                == HandleFacts(identity: FileIdentity(stat: info), isRegularReadOnly: true))
    }

    @Test func aPipeIsRefused() throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        let facts = HandleInspection.facts(of: pipe.fileHandleForReading.fileDescriptor)
        #expect(!facts.isRegularReadOnly)
        #expect(facts.identity != nil, "a pipe has an fstat; it is its kind that is refused")
    }

    /// The same regular file, opened for writing or for both: refused, so the service never holds a way to change it.
    @Test func aWritableDescriptorIsRefused() throws {
        let file = try Self.scratchFile()
        defer { try? FileManager.default.removeItem(at: file) }
        for flags in [O_RDWR, O_WRONLY] {
            let descriptor = open(file.path, flags)
            try #require(descriptor >= 0)
            defer { close(descriptor) }
            #expect(!HandleInspection.facts(of: descriptor).isRegularReadOnly, "flags \(flags)")
        }
    }

    @Test func aDescriptorThatIsNotOpenHasNoFacts() {
        #expect(HandleInspection.facts(of: -1) == HandleFacts(identity: nil, isRegularReadOnly: false))
    }
}
