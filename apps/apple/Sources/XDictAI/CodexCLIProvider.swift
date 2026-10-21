#if os(macOS)
import CodexAuth
import Foundation

/// **The reader's own Codex CLI as a provider** (ADR-0021 d.3): one fresh `codex exec` process per ask, in an
/// XDict-owned `CODEX_HOME`, so none of the reader's config, MCP servers, hooks or instructions is inherited. The
/// sign-in is the CLI's documented `codex login` in that home; XDict never writes a credential file itself.
///
/// `sayso`'s `CodexAuth` (pinned in `Package.swift`) supplies executable discovery, the version floor and the typed auth
/// states, which are mapped to this target's errors; the token it fetches is discarded unread.
public struct CodexCLIProvider: AIProvider {
    public struct Configuration: Sendable, Equatable {
        /// An explicitly chosen binary; nil lets sayso discover one.
        public let executable: URL?
        /// XDict's own Codex home: its sign-in, and nothing of the reader's configuration.
        public let codexHome: URL
        /// An app-owned empty folder the CLI runs in.
        public let workingDirectory: URL
        public let model: String?
        public let timeout: Duration

        public init(executable: URL? = nil, codexHome: URL, workingDirectory: URL, model: String? = nil,
                    timeout: Duration = .seconds(180)) {
            self.executable = executable
            self.codexHome = codexHome
            self.workingDirectory = workingDirectory
            self.model = model
            self.timeout = timeout
        }
    }

    /// What a probe found: sayso's state, the resolved executable and its version. Internal, so sayso's type stays out
    /// of this target's public surface.
    struct Probe: Sendable, Equatable {
        let state: CodexAuthState
        let bin: String
        let version: String

        init(state: CodexAuthState, bin: String, version: String) {
            self.state = state
            self.bin = bin
            self.version = version
        }
    }

    /// The oldest Codex this provider runs: the measured 0.163.0 has every flag below (`--ephemeral`,
    /// `--ignore-user-config`, `--ignore-rules`, `--output-schema`); sayso's own floor, 0.161.0, remains the sign-in
    /// contract's.
    public static let minimumVersion = "0.163.0"
    /// The login's deadline: the reader completes a browser sign-in.
    public static let loginTimeout: Duration = .seconds(300)

    public let id = AIProviderID(kind: .codexCLI)
    private let configuration: Configuration
    private let probe: @Sendable () async -> Probe
    /// Held so sayso's client outlives each call; nil in the test seam.
    private let credentials: Credentials?

    /// Builds sayso's client for this private home. Throws `.framework` where its configuration is refused.
    public init(configuration: Configuration) throws(AIProviderError) {
        self.configuration = configuration
        let auth = CodexAuthConfiguration(
            margin: 60, timeout: 20, source: .auto, executable: configuration.executable?.path,
            codexHome: configuration.codexHome.path, home: NSHomeDirectory(),
            confineCodexHome: configuration.codexHome.path, environment: nil, candidates: nil, clientName: "XDict")
        let credentials: Credentials
        do {
            credentials = try Credentials(auth)
        } catch {
            throw .framework("codex-config")
        }
        self.credentials = credentials
        self.probe = { [credentials] in
            do {
                _ = try await credentials.token()
                let info = await credentials.info()
                return Probe(state: .ready, bin: info.bin, version: info.codexVersion)
            } catch let error as CodexAuthError {
                let info = await credentials.info()
                return Probe(state: error.state, bin: info.bin, version: error.codexVersion)
            } catch {
                return Probe(state: .codexError, bin: "", version: "")
            }
        }
    }

    /// The test seam: a probe supplied directly, no sayso client and no sign-in touched.
    init(configuration: Configuration, probe: @escaping @Sendable () async -> Probe) {
        self.configuration = configuration
        self.probe = probe
        self.credentials = nil
    }

    /// **Whether this source can run, without asking a model** (Settings ▸ AI's live status): sayso's sign-in state, the
    /// version floor and XDict's own home. Returns the version, which the pane may show.
    public func check() async throws(AIProviderError) -> String {
        let found = await probe()
        guard !Task.isCancelled else { throw .cancelled }
        if let error = Self.mapped(found.state) { throw error }
        guard CLIVersion.atLeast(found.version, Self.minimumVersion) else { throw .versionTooOld }
        _ = try Self.resolve(configuration, found)
        try Self.prepare(configuration)
        return found.version
    }

    public func answer(to question: String) async throws(AIProviderError) -> String {
        let found = await probe()
        guard !Task.isCancelled else { throw .cancelled }
        if let error = Self.mapped(found.state) { throw error }
        guard CLIVersion.atLeast(found.version, Self.minimumVersion) else { throw .versionTooOld }
        let executable = try Self.resolve(configuration, found)
        try Self.prepare(configuration)
        let message = configuration.workingDirectory.appending(path: "last-message-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: message) }
        // The one-shot, boxed turn: no session on disk, no user config or rules, a read-only sandbox, no approvals, and
        // the answer written to a file of our own. The prompt arrives on stdin; no shell ever sees it.
        var arguments = [
            "exec", "--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "--ignore-rules",
            // **No tools at all** (ADR-0021 d.8; audit finding 2026-10-20): `-s read-only` stops writes but still lets
            // the model run shell commands, so an entry's injected text could ask it to read a local file. Both built-in
            // tool sets are disabled; the prompt is data on stdin and the answer is the only thing that leaves.
            "--disable", "shell_tool", "--disable", "browser_use",
            "-s", "read-only", "-C", configuration.workingDirectory.path,
            "-c", #"approval_policy="never""#, "-o", message.path,
        ]
        if let model = configuration.model, !model.isEmpty { arguments += ["-m", model] }
        arguments.append("-")
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
        return try Self.text(at: message)
    }

    /// **The documented login, in XDict's own home**: `codex login`, its output (the URL and code) passed to `onLine` as
    /// it arrives, and returned whole. XDict writes no credential file and reads none.
    public func login(onLine: @escaping @Sendable (String) -> Void = { _ in }) async throws(AIProviderError) -> String {
        let found = await probe()
        guard !Task.isCancelled else { throw .cancelled }
        let executable = try Self.resolve(configuration, found)
        try Self.prepare(configuration)
        let environment = Self.environment(configuration, executable: executable)
        let run: CLIProcess.Run
        do {
            run = try await CLIProcess.run(
                executable: executable, arguments: ["login"], environment: environment,
                workingDirectory: configuration.workingDirectory, input: nil, deadline: Self.loginTimeout,
                onLine: onLine)
        } catch {
            throw Self.mapped(error)
        }
        guard run.status == 0 else { throw Self.classify(run) }
        return run.stdout + run.stderr
    }

    // MARK: - Mapping

    /// sayso's state as this target's error; nil for `ready`.
    static func mapped(_ state: CodexAuthState) -> AIProviderError? {
        switch state {
        case .ready: nil
        case .noCodex: .notInstalled
        case .codexTooOld: .versionTooOld
        case .notSignedIn, .noSignInFile, .expired: .notSignedIn
        case .apiKey, .unsupportedAuth, .appServerAuthUnavailable, .providerWithoutOpenAIAuth: .unsupportedAuth
        case .codexError: .framework("codex")
        }
    }

    static func mapped(_ failure: CLIProcess.Failure) -> AIProviderError {
        switch failure {
        case .notInstalled: .notInstalled
        case .timeout: .timeout
        case .cancelled: .cancelled
        case .spawn(let code): .framework("spawn \(code)")
        }
    }

    static func classify(_ run: CLIProcess.Run) -> AIProviderError {
        let lower = (run.stdout + "\n" + run.stderr).lowercased()
        for marker in ["not signed in", "please log in", "codex login", "unauthorized", "authentication"] {
            if lower.contains(marker) { return .notSignedIn }
        }
        if lower.contains("rate limit") || lower.contains("usage limit") || lower.contains("quota") {
            return .rateLimited
        }
        if lower.contains("refus") || lower.contains("declined") || lower.contains("policy") { return .refused }
        return .framework("codex exit \(run.status)")
    }

    // MARK: - Files and environment

    static func resolve(_ configuration: Configuration, _ found: Probe) throws(AIProviderError) -> URL {
        if let explicit = configuration.executable {
            guard CLIProcess.isExecutable(explicit) else { throw .notInstalled }
            return explicit
        }
        if !found.bin.isEmpty {
            let candidate = URL(fileURLWithPath: found.bin)
            if CLIProcess.isExecutable(candidate) { return candidate }
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let resolved = CodexExecutable.resolve(
            explicit: nil, path: path, candidates: CodexExecutable.candidates(home: NSHomeDirectory()))
        guard let resolved, !resolved.isEmpty, CLIProcess.isExecutable(URL(fileURLWithPath: resolved)) else {
            throw .notInstalled
        }
        return URL(fileURLWithPath: resolved)
    }

    static func prepare(_ configuration: Configuration) throws(AIProviderError) {
        for folder in [configuration.codexHome, configuration.workingDirectory] {
            do {
                try FileManager.default.createDirectory(
                    at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch {
                throw .framework("folder")
            }
        }
    }

    /// sayso's own rule (`CodexExecutable.childEnvironment`): the app's environment minus every authentication
    /// override, `CODEX_HOME` replaced by XDict's own, `PATH` repaired so an npm-installed CLI finds `node`.
    static func environment(_ configuration: Configuration, executable: URL) -> [String: String] {
        var base = ["HOME": NSHomeDirectory()]
        if let path = ProcessInfo.processInfo.environment["PATH"] { base["PATH"] = path }
        if let temporary = ProcessInfo.processInfo.environment["TMPDIR"] { base["TMPDIR"] = temporary }
        return CodexExecutable.childEnvironment(
            base, bin: executable.path, codexHome: configuration.codexHome.path)
    }

    /// The final message `codex exec` wrote, bounded **while reading**: a huge or hostile file must not be loaded before
    /// its size is known. (Audit finding, 2026-10-20.)
    static func text(at url: URL) throws(AIProviderError) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw .badShape }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: CLIProcess.stdoutCap + 1), data.count <= CLIProcess.stdoutCap,
              let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw .badShape }
        return text
    }
}
#endif
