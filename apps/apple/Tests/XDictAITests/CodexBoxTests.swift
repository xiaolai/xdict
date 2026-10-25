import CodexAuth
import Foundation
import Testing
@testable import SaySoAICLI

/// **The Codex turn's box, checked where it can be built without a sign-in** (ADR-0021 d.9): sayso's provider takes a
/// test probe through an internal seam, so this reaches it with `@testable` — the alternative was to lose the assertion
/// with the move. The same proof runs for Claude through the public API in `AIHostileTests`.
struct CodexBoxTests {
    static func stub() throws -> (CLIStub, URL) {
        let stub = try CLIStub()
        var body = stub.recordingPreamble()
        body += """
        out=""; prev=""
        for a in "$@"; do
          if [ "$prev" = "-o" ]; then out="$a"; fi
          prev="$a"
        done
        if [ -n "$out" ]; then cat "$D/response" > "$out"; fi
        exit $(cat "$D/exit" 2>/dev/null || echo 0)
        """ + "\n"
        return (stub, try stub.script("codex", body: body))
    }

    static func provider(_ stub: CLIStub, _ url: URL) -> CodexCLIProvider {
        let configuration = CodexCLIProvider.Configuration(
            executable: url, codexHome: stub.directory.appending(path: "codex-home"),
            workingDirectory: stub.directory.appending(path: "work"), timeout: .seconds(30))
        return CodexCLIProvider(configuration: configuration) { _ in
            CodexCLIProvider.Probe(state: .ready, bin: url.path, version: "0.163.0")
        }
    }

    @Test func codexGetsTheTextAsDataAndItsToolsStayOff() async throws {
        let (stub, url) = try Self.stub()
        try stub.write("response", #"{"outcome":"refused","quotes":[],"explanation":"The text asked for actions."}"#)
        _ = try await Self.provider(stub, url).answer(to: AIHostileTests.hostile)
        let ask = try stub.invocation(1)
        #expect(ask.stdin == AIHostileTests.hostile, "the instruction is data on stdin, byte for byte")
        #expect(!ask.arguments.contains { $0.contains("id_rsa") || $0.contains("rm -rf") || $0.contains("example.com") },
                "no word of the text reaches the argument vector: \(ask.arguments)")
        #expect(ask.arguments.contains("read-only"), "the sandbox stays read-only")
        // `-s read-only` still allows reads through the shell tool; the tool itself must be disabled.
        #expect(ask.arguments.contains("shell_tool"), "the shell tool must be off: \(ask.arguments)")
        #expect(ask.arguments.contains("browser_use"), "the browser tool must be off: \(ask.arguments)")
        #expect(ask.environment["OPENAI_API_KEY"] == nil)
        #expect(ask.environment["CODEX_API_KEY"] == nil)
    }
}
