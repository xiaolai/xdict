import Testing
@testable import XDictAppleImport
import XDictTestSupport

@Suite struct ZlibTests {
    func inflate(_ stream: [UInt8], expected: Int) throws -> [UInt8] {
        try stream.withUnsafeBufferPointer { try zlibInflate($0, from: 0, to: stream.count, expected: expected, budget: nil, corrupt: .body(offset: 0)) }
    }

    @Test func roundTripsEmptyAndLargeInput() throws {
        for size in [0, 1, 70_000] {
            let data = (0..<size).map { UInt8($0 % 251) }
            #expect(try inflate(try zlibCompress(data), expected: size) == data)
        }
    }

    @Test func rejectsTruncatedTrailingAndCorruptStreams() throws {
        let data = [UInt8](repeating: 7, count: 1000)
        let z = try zlibCompress(data)
        #expect(throws: AppleImportError.self) { try inflate(Array(z.dropLast(3)), expected: 1000) }
        #expect(throws: AppleImportError.self) { try inflate(z + [0], expected: 1000) }
        var bad = z
        bad[bad.count - 1] ^= 0xff  // Adler-32
        #expect(throws: AppleImportError.self) { try inflate(bad, expected: 1000) }
        #expect(throws: AppleImportError.self) { try inflate(z, expected: 999) }
        #expect(throws: AppleImportError.self) { try inflate(z, expected: 1001) }
    }

    @Test func rejectsInvalidHeaders() throws {
        var z = try zlibCompress([1, 2, 3])
        z[0] = 0x88  // CINFO 8: window size beyond 32 KiB
        z[1] = 0x1c
        #expect(throws: AppleImportError.self) { try inflate(z, expected: 3) }
        #expect(throws: AppleImportError.self) { try inflate([], expected: 0) }
    }

    @Test func refusesImplausibleSizeClaims() throws {
        let z = try zlibCompress([UInt8](repeating: 0, count: 1 << 20))
        #expect(throws: AppleImportError.self) { try inflate(z, expected: 1 << 30) }
        #expect(throws: AppleImportError.self) { try inflate(z, expected: -1) }
    }
}
