import Foundation
import Synchronization
import Testing
import XDictCaptureMac

/// **One owner for the Accessibility grant, and it never asks** (moved from XiaolaiDict's `AccessibilityAccessTests`;
/// XDict ADR-0014 decision 7). The asking cases stayed behind: asking is `AccessibilityGate`'s, in the composition layer,
/// whose own tests hold it to once per request.
struct AccessibilityAccessTests {
    /// Counts how often the probe was read, so a test can tell an answer from a probe nobody asked.
    final class Counter: Sendable {
        private let count = Mutex(0)
        var reads: Int { count.withLock { $0 } }
        func bump() { count.withLock { $0 += 1 } }
    }

    private func access(_ found: PermissionProbe) -> (AccessibilityAccess, Counter) {
        let counter = Counter()
        return (AccessibilityAccess(probe: { counter.bump(); return found }), counter)
    }

    @Test func aGrantedPermissionIsNeverAskedFor() {
        let (permission, counter) = access(.granted)
        #expect(permission.state() == .granted)
        #expect(permission.granted())
        #expect(counter.reads == 2, "each answer is the system's, read again, never a stored flag")
    }

    /// **`couldNotTell` never reads as granted**, nor as declined: a gate written as `!= .declined` would let a capture
    /// through on it.
    @Test func anUnreadableProbeNeitherPromptsNorPasses() {
        let (permission, _) = access(.couldNotTell)
        #expect(permission.state() == .couldNotTell)
        #expect(!permission.granted())
    }

    /// **Nothing in the capture target can prompt, however the probe answers.** The type has no asking half, and the
    /// target's sources name neither the prompting call nor its option: a prompt reintroduced anywhere in it fails here.
    @Test func theHoverGateNeverPrompts() throws {
        for found: PermissionProbe in [.granted, .declined, .couldNotTell] {
            let (permission, _) = access(found)
            #expect(permission.granted() == (found == .granted))
        }
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/XDictCaptureMac")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty, "the scan read nothing of \(sources.path)")
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for prompting in ["AXIsProcessTrustedWithOptions", "AXTrustedCheckOptionPrompt", "kAXTrustedCheckOptionPrompt"] {
                #expect(!text.contains(prompting), "\(file.lastPathComponent) names \(prompting)")
            }
        }
    }
}
