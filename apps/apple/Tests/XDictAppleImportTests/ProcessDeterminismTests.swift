import Foundation
import Testing
@testable import XDictAppleImport
import XDictTestSupport
import XDictAppleSource

/// **The same snapshot writes the same bytes in another process** (ADR-0011 decision 6). Swift seeds its hashing per
/// process, so an output that followed a `Set` or `Dictionary`'s order would pass every in-process test and still
/// differ between two runs of the service. This test launches this test bundle twice more, each child converting the
/// acceptance bundle under its own time zone (`TZ`) and output name, and compares the children's MDX and MDD byte for
/// byte.
struct ProcessDeterminismTests {
    @Test func twoProcessesWriteTheSameBytes() throws {
        let root = try SyntheticAppleBundle.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try DeterminismChild.run(in: root.appendingPathComponent("a"), tz: "Pacific/Kiritimati", name: "First", salt: false)
        let b = try DeterminismChild.run(in: root.appendingPathComponent("b"), tz: "Pacific/Pago_Pago", name: "Second name", salt: false)
        #expect(a.mdx == b.mdx, "MDX differs between processes")
        #expect(a.mdd == b.mdd, "MDD differs between processes")
    }

    /// **The control**: a child told to salt its bundle with a per-process random value writes different bytes, and the
    /// comparison above sees it. A comparison that cannot fail would pass a nondeterministic converter.
    @Test func aPerProcessSaltIsSeen() throws {
        let root = try SyntheticAppleBundle.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try DeterminismChild.run(in: root.appendingPathComponent("a"), tz: "UTC", name: "T", salt: true)
        let b = try DeterminismChild.run(in: root.appendingPathComponent("b"), tz: "UTC", name: "T", salt: true)
        #expect(a.mdx != b.mdx)
    }
}

/// The child's side: runs only when the parent launches it with `XDICT_DETERMINISM_OUT` set.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["XDICT_DETERMINISM_OUT"] != nil))
struct DeterminismChild {
    static let outKey = "XDICT_DETERMINISM_OUT"
    static let nameKey = "XDICT_DETERMINISM_NAME"
    static let saltKey = "XDICT_DETERMINISM_SALT"

    struct ChildFailed: Error, CustomStringConvertible {
        let description: String
    }

    /// Converts the acceptance bundle into `out` (named by the parent) and leaves the pair there.
    @Test func convertAndKeep() throws {
        let env = ProcessInfo.processInfo.environment
        let out = URL(fileURLWithPath: try #require(env[Self.outKey]))
        let name = try #require(env[Self.nameKey])
        let work = try SyntheticAppleBundle.tempDir()
        defer { try? FileManager.default.removeItem(at: work) }
        var bundle = try AppleImportAcceptance.bundle(in: work, .faithful)
        if env[Self.saltKey] == "1" {
            // The control's nondeterminism, outside the converter: a value no two processes share.
            try FileManager.default.removeItem(at: bundle)
            bundle = try SyntheticAppleBundle.make(in: work, entries: [("e1", "salt", "<p>\(UUID().uuidString)</p>", [])])
        }
        try convert(snapshot: bundle, into: out, name: name)
    }

    /// Launches this test bundle again, filtered to `convertAndKeep`, and returns what it wrote. Loud if the child
    /// fails or writes nothing: a child that silently did no work would make the comparison vacuous.
    static func run(in dir: URL, tz: String, name: String, salt: Bool) throws -> (mdx: Data, mdd: Data) {
        let args = ProcessInfo.processInfo.arguments
        guard let at = args.firstIndex(of: "--test-bundle-path"), at + 1 < args.count, let helper = args.first else {
            throw ChildFailed(description: "not launched by swiftpm-testing-helper: \(args)")
        }
        let testBundle = args[at + 1]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = ["--test-bundle-path", testBundle, "--filter", "DeterminismChild", testBundle,
                             "--testing-library", "swift-testing"]
        var env = ProcessInfo.processInfo.environment
        env["TZ"] = tz
        env[outKey] = dir.path
        env[nameKey] = name
        env[saltKey] = salt ? "1" : "0"
        process.environment = env
        let log = Pipe()
        process.standardOutput = log
        process.standardError = log
        try process.run()
        let said = log.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ChildFailed(description: "child exited \(process.terminationStatus): \(String(decoding: said, as: UTF8.self))")
        }
        let mdx = dir.appendingPathComponent("\(name).mdx"), mdd = dir.appendingPathComponent("\(name).mdd")
        guard let x = try? Data(contentsOf: mdx), let d = try? Data(contentsOf: mdd), !x.isEmpty, !d.isEmpty else {
            throw ChildFailed(description: "child wrote no pair: \(String(decoding: said, as: UTF8.self))")
        }
        return (x, d)
    }
}
