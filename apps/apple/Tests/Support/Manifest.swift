import Foundation

/// This package as SwiftPM evaluates it (`swift package dump-package`), and where its files are. The checks that hold
/// a rule over "every target" read the targets from here, never from a list kept by hand: a target added later and
/// left off a hand-kept list is a target the rule does not cover, and it goes on passing.
public enum Manifest {
    /// The package's own directory, `apps/apple`.
    public static let package = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Support
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // apps/apple

    /// One target as SwiftPM declares it.
    public struct Target: Sendable, Equatable {
        public let name: String
        /// `regular`, `executable`, `test` or `binary`.
        public let type: String
        /// Its in-package dependencies, by name.
        public let dependencies: Set<String>
        /// Its sources' directory, relative to the package.
        public let path: String
        /// Each Swift setting as `<kind> <argument>`, as `dump-package` writes it: `treatAllWarnings error`.
        public let swiftSettings: Set<String>

        /// A target by hand, for a control that plants a graph no manifest declares.
        public init(name: String, type: String, dependencies: Set<String>, path: String, swiftSettings: Set<String>) {
            self.name = name
            self.type = type
            self.dependencies = dependencies
            self.path = path
            self.swiftSettings = swiftSettings
        }
    }

    /// What `dump-package` said: the targets by name, and the platforms as `<name> <version>`.
    public struct Dump: Sendable {
        public let targets: [String: Target]
        public let platforms: [String]
    }

    public struct Refused: Error, CustomStringConvertible {
        public let description: String
    }

    /// The manifest at `root` (this package's unless given), evaluated by SwiftPM — with a scratch path of its own, so
    /// nothing of the running `swift test`'s `.build` is waited on.
    public static func dump(of root: URL = package) throws -> Dump {
        let scratch = try TemporaryDirectory(named: "xdict-dump-package")
        let arguments = ["swift", "package", "--package-path", root.path,
                         "--scratch-path", scratch.appending("build").path, "dump-package"]
        let (status, output, said) = try run("/usr/bin/xcrun", arguments)
        guard status == 0 else { throw Refused(description: "\(arguments.joined(separator: " ")) exited \(status): \(said)") }
        guard let dump = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              let targets = dump["targets"] as? [[String: Any]] else {
            throw Refused(description: "dump-package wrote no targets")
        }
        let names = Set(targets.compactMap { $0["name"] as? String })
        var byName: [String: Target] = [:]
        for target in targets {
            guard let name = target["name"] as? String, let type = target["type"] as? String else {
                throw Refused(description: "a target with no name or type")
            }
            let dependencies = (target["dependencies"] as? [[String: Any]] ?? []).compactMap { dependency in
                ((dependency["byName"] ?? dependency["target"]) as? [Any])?.first as? String
            }
            let settings = (target["settings"] as? [[String: Any]] ?? []).compactMap(swiftSetting)
            let defaultRoot = type == "test" ? "Tests" : "Sources"
            byName[name] = Target(
                name: name, type: type, dependencies: Set(dependencies).intersection(names),
                path: target["path"] as? String ?? "\(defaultRoot)/\(name)", swiftSettings: Set(settings))
        }
        let platforms = (dump["platforms"] as? [[String: Any]] ?? []).map { platform in
            "\(platform["platformName"] as? String ?? "?") \(platform["version"] as? String ?? "?")"
        }
        return Dump(targets: byName, platforms: platforms)
    }

    /// A setting this cannot read is not one it found: it reads as absent, never as present.
    private static func swiftSetting(_ setting: [String: Any]) -> String? {
        guard setting["tool"] as? String == "swift", let kind = setting["kind"] as? [String: Any],
              kind.count == 1, let entry = kind.first else { return nil }
        let argument = (entry.value as? [String: Any])?["_0"]
        if let argument = argument as? String { return "\(entry.key) \(argument)" }
        return entry.key
    }

    /// Every target that reaches `module`, directly or through another, `module` itself left out.
    public static func reaching(_ module: String, in targets: [String: Target]) -> Set<String> {
        Set(targets.keys.filter { name in
            var seen: Set<String> = [], pending = Array(targets[name]?.dependencies ?? [])
            while let next = pending.popLast() {
                if next == module { return true }
                guard seen.insert(next).inserted else { continue }
                pending += targets[next]?.dependencies ?? []
            }
            return false
        })
    }

    /// Runs a program and waits; its status, standard output and standard error.
    public static func run(_ executable: String, _ arguments: [String]) throws -> (Int32, String, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        // Read before waiting: a child that fills a pipe's buffer waits for a reader that is waiting for it.
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }
}
