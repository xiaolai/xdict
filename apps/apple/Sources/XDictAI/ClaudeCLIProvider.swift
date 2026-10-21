import Foundation

/// **The reader's own Claude CLI as a provider** (ADR-0021 d.3): one fresh `claude -p` process per ask, in an
/// XDict-owned `CLAUDE_CONFIG_DIR`, with the tool, hook and MCP switches off. Claude Code writes and owns its credential
/// for that folder in the reader's Keychain (the service name it derives from the config dir); XDict never reads it,
/// never stores it, and never looks at `~/.claude`.
///
/// One-shot by construction (`--no-session-persistence`, no `--resume`): the next ask cannot see this one's sentence.
public struct ClaudeCLIProvider: AIProvider {
    public struct Configuration: Sendable, Equatable {
        /// An explicitly chosen binary; nil discovers one (`PATH`, then the folders a Finder-launched app misses).
        public let executable: URL?
        /// XDict's own configuration folder for Claude Code; the credential's keychain slot follows from it.
        public let configDirectory: URL
        /// An app-owned empty folder the CLI runs in.
        public let workingDirectory: URL
        public let model: String?
        public let timeout: Duration
        /// The search path for discovery, for tests; nil uses the process's own `PATH`.
        public let searchPath: String?

        public init(executable: URL? = nil, configDirectory: URL, workingDirectory: URL, model: String? = nil,
                    timeout: Duration = .seconds(120), searchPath: String? = nil) {
            self.executable = executable
            self.configDirectory = configDirectory
            self.workingDirectory = workingDirectory
            self.model = model
            self.timeout = timeout
            self.searchPath = searchPath
        }
    }

    /// The oldest CLI this provider runs: `--json-schema` and `--safe-mode` are both in it. Measured on the build host
    /// on 2026-10-20: `claude` 2.1.304.
    public static let minimumVersion = "2.1.0"
    /// The answer's shape (`CONTRACT.md` §5), handed to `--json-schema`.
    public static let answerSchema = #"{"type":"object","properties":{"outcome":{"type":"string","enum":["matched","ambiguous","noMatchingSense","insufficientContext","incompleteInput","explanationOnly","refused","guardrail"]},"quotes":{"type":"array","items":{"type":"string"},"maxItems":3},"explanation":{"type":"string"}},"required":["outcome","quotes","explanation"],"additionalProperties":false}"#

    public let id = AIProviderID(kind: .claudeCLI)
    private let configuration: Configuration

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// **Whether this source can run, without asking a model** (Settings ▸ AI's live status): the executable found, its
    /// version at or over the floor, and XDict's own folders prepared. Returns the version, which the pane may show.
    public func check() async throws(AIProviderError) -> String {
        let executable = try Self.discover(configuration)
        let version = try await Self.version(of: executable,
                                             environment: Self.environment(configuration, executable: executable),
                                             deadline: configuration.timeout)
        guard Self.atLeast(version, Self.minimumVersion) else { throw .versionTooOld }
        try Self.prepare(configuration)
        return version
    }

    public func answer(to question: String) async throws(AIProviderError) -> String {
        let executable = try Self.discover(configuration)
        let version = try await Self.version(of: executable, environment: Self.environment(configuration, executable: executable),
                                            deadline: configuration.timeout)
        guard Self.atLeast(version, Self.minimumVersion) else { throw .versionTooOld }
        try Self.prepare(configuration)
        // The lean, measured set (XiaolaiDict), plus what makes this ask a closed box: no tools, no MCP, no settings,
        // no slash commands, nobody to answer a permission prompt, no session on disk. `--bare` is deliberately absent:
        // it reads no OAuth, and the reader's sign-in is the point.
        var arguments = [
            "-p", "--output-format", "json", "--json-schema", Self.answerSchema,
            "--no-session-persistence", "--tools", "", "--strict-mcp-config", "--setting-sources", "",
            "--disable-slash-commands", "--permission-prompts", "none", "--safe-mode",
        ]
        if let model = configuration.model, !model.isEmpty { arguments += ["--model", model] }
        let environment = Self.environment(configuration, executable: executable)
        let run: CLIProcess.Run
        do {
            run = try await CLIProcess.run(
                executable: executable, arguments: arguments, environment: environment,
                workingDirectory: configuration.workingDirectory, input: question, deadline: configuration.timeout)
        } catch {
            throw Self.mapped(error)
        }
        guard run.status == 0 else { throw Self.classify(run) }
        return try Self.text(from: run.stdout)
    }

    // MARK: - Discovery

    static func discover(_ configuration: Configuration) throws(AIProviderError) -> URL {
        if let executable = configuration.executable {
            guard CLIProcess.isExecutable(executable) else { throw .notInstalled }
            return executable
        }
        let repair = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        let inherited = configuration.searchPath ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        let home = NSHomeDirectory()
        let gui = [home + "/.local/bin", home + "/.npm-global/bin", home + "/.volta/bin", home + "/.bun/bin",
                   home + "/Library/pnpm"]
        let folders = ((inherited + ":" + repair).split(separator: ":").map(String.init) + gui)
            .filter { !$0.isEmpty }
        for folder in folders where !folder.isEmpty {
            let candidate = URL(fileURLWithPath: folder).appending(path: "claude")
            if CLIProcess.isExecutable(candidate) { return candidate }
        }
        throw .notInstalled
    }

    static func version(of executable: URL, environment: [String: String], deadline: Duration) async throws(AIProviderError) -> String {
        let run: CLIProcess.Run
        do {
            run = try await CLIProcess.run(
                executable: executable, arguments: ["--version"], environment: environment,
                workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()), deadline: min(deadline, .seconds(15)))
        } catch {
            throw mapped(error)
        }
        guard run.status == 0, let first = run.stdout.split(whereSeparator: { $0.isWhitespace }).first else {
            throw .framework("claude --version")
        }
        return String(first)
    }

    /// Numeric components, compared as integers (sayso's rule); a non-numeric component is 0.
    static func atLeast(_ version: String, _ minimum: String) -> Bool {
        CLIVersion.atLeast(version, minimum)
    }

    // MARK: - The box

    static func prepare(_ configuration: Configuration) throws(AIProviderError) {
        for folder in [configuration.configDirectory, configuration.workingDirectory] {
            do {
                try FileManager.default.createDirectory(
                    at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch {
                throw .framework("folder")
            }
        }
    }

    /// The child's whole environment: the app's home and temp, a repaired `PATH` (an npm-installed CLI needs `node`),
    /// and XDict's config folder. Nothing else — no `ANTHROPIC_*`, no key the app happens to hold.
    static func environment(_ configuration: Configuration, executable: URL) -> [String: String] {
        let folder = executable.deletingLastPathComponent().path
        var path = folder + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        if let inherited = ProcessInfo.processInfo.environment["PATH"], !inherited.isEmpty {
            path += ":" + inherited
        }
        var environment = [
            "HOME": NSHomeDirectory(),
            "PATH": path,
            "CLAUDE_CONFIG_DIR": configuration.configDirectory.path,
        ]
        if let temporary = ProcessInfo.processInfo.environment["TMPDIR"] { environment["TMPDIR"] = temporary }
        return environment
    }

    // MARK: - The answer

    /// The model's answer text: `structured_output` when the CLI returns it, else `result`. An error envelope is
    /// classified, never returned as an answer.
    static func text(from stdout: String) throws(AIProviderError) -> String {
        guard let data = stdout.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw .badShape
        }
        let subtype = object["subtype"] as? String
        let isError = object["is_error"] as? Bool ?? false
        if let structured = object["structured_output"] as? [String: Any] {
            guard !isError, subtype == nil || subtype == "success" else { throw .refused }
            guard let encoded = try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys]) else {
                throw .badShape
            }
            return String(decoding: encoded, as: UTF8.self)
        }
        guard let result = object["result"] as? String, !result.isEmpty else { throw .badShape }
        if isError || (subtype != nil && subtype != "success") { throw classify(text: result, status: 0) }
        return result
    }

    static func classify(_ run: CLIProcess.Run) -> AIProviderError {
        if run.status != 0 { return classify(text: run.stdout + "\n" + run.stderr, status: run.status) }
        return .refused
    }

    static func classify(text: String, status: Int32) -> AIProviderError {
        let lower = text.lowercased()
        let signIn = ["not signed in", "please run /login", "please log in", "authentication required",
                      "invalid api key", "unauthorized", "oauth"]
        if signIn.contains(where: { lower.contains($0) }) { return .notSignedIn }
        if lower.contains("rate limit") || lower.contains("usage limit") || lower.contains("quota") {
            return .rateLimited
        }
        if lower.contains("refus") || lower.contains("declined") || lower.contains("policy") { return .refused }
        return .framework("claude exit \(status)")
    }

    static func mapped(_ failure: CLIProcess.Failure) -> AIProviderError {
        switch failure {
        case .notInstalled: .notInstalled
        case .timeout: .timeout
        case .cancelled: .cancelled
        case .spawn(let code): .framework("spawn \(code)")
        }
    }
}
