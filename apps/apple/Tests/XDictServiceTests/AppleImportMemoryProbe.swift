import Foundation
import Testing
import XDictAppleImport
import XDictContract
@testable import XDictService
import XDictTestSupport
import XDictAppleSource

/// **The peak memory of one conversion, for `Tools/measure-apple-import-memory.sh`** (ADR-0011 decision 5; plan WI-4),
/// which holds it to a budget. Two steps, each in its own process so each peak is that step's alone:
/// `XDICT_APPLE_MEMORY_MAKE=<dir>` writes a large, highly compressible synthetic bundle staged under `<dir>`;
/// `XDICT_APPLE_MEMORY_CONVERT=<dir>` converts it through the service's own path (`AppleImports.convert`) and prints
/// the process's peak before and after. Unset, nothing is measured, and it says so. Never an Apple bundle (ADR-0011).
struct AppleImportMemoryProbe {
    /// 64 sections of 1,024 entries, each about 4 KiB of text: 256 MiB inflated from about 2 MiB of zlib, the
    /// expansion a body section's compression allows taken far past any installed bundle's (Hungarian: 123 MB in all).
    static let sections = 64
    static let perSection = 1_024
    static let staging = UUID(uuidString: "00000000-0000-4000-8000-00000000A11E") ?? UUID()

    static func peakMiB() -> Int {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Int(usage.ru_maxrss) >> 20  // bytes on macOS
    }

    @Test func measure() throws {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["XDICT_APPLE_MEMORY_MAKE"] {
            try Self.make(URL(fileURLWithPath: dir))
        } else if let dir = env["XDICT_APPLE_MEMORY_CONVERT"] {
            try Self.convert(URL(fileURLWithPath: dir))
        } else {
            print("apple-import memory: not measured (XDICT_APPLE_MEMORY_MAKE or _CONVERT unset)")
        }
    }

    static func make(_ dir: URL) throws {
        let store = AppleImportStore(root: dir.appending(path: "AppleImports"))
        try FileManager.default.createDirectory(at: store.staging, withIntermediateDirectories: true)
        let filler = String(repeating: "lorem ipsum dolor sit amet ", count: 150)
        let sections = (0..<Self.sections).map { s in
            (0..<Self.perSection).map { e -> SyntheticAppleBundle.Entry in
                let n = s * Self.perSection + e
                return ("e\(n)", "word\(n)", "<p>\(n) \(filler)</p>", [])
            }
        }
        let bundle = try SyntheticAppleBundle.make(in: dir, sections: sections)
        try FileManager.default.moveItem(at: bundle, to: store.staging.appending(path: Self.staging.uuidString))
    }

    static func convert(_ dir: URL) throws {
        let store = AppleImportStore(root: dir.appending(path: "AppleImports"))
        let before = peakMiB()
        let converted = try AppleImports.convert(staging: Self.staging, in: store, progress: nil).get()
        print("apple-import memory: peak \(before) MiB before, \(peakMiB()) MiB after; \(converted.entries) entries")
    }
}
