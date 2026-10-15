import Testing
import XDictAnywhere

/// **Asking for Accessibility** (plan-macos-v1 WI-8): the first selection lookup without the grant makes the system's
/// own request appear — once, never at launch, never in a loop — and while it is open the trusted state is polled, so
/// the grant carries the lookup on without a relaunch. The trust check is injected: no test asks this Mac.
@MainActor
struct AccessibilityGateTests {
    /// A scripted trust check: the answer, and every call with whether it prompted.
    @MainActor final class Trust {
        var trusted = false
        var calls: [Bool] = []
        func check(_ prompt: Bool) -> Bool {
            calls.append(prompt)
            return trusted
        }
        var prompts: Int { calls.filter { $0 }.count }
    }

    @Test func nothingIsAskedUntilALookupNeedsIt() {
        let trust = Trust()
        _ = AccessibilityGate(check: { trust.check($0) })
        #expect(trust.calls.isEmpty, "the gate asked at launch: \(trust.calls)")
    }

    @Test func trustedAlreadyNeedsNoPrompt() {
        let trust = Trust()
        trust.trusted = true
        let gate = AccessibilityGate(check: { trust.check($0) })
        #expect(gate.request() == .trusted)
        #expect(trust.prompts == 0)
    }

    /// The first lookup without the grant prompts once; more presses while the request is open prompt no more.
    @Test func theSystemsRequestAppearsOnceAndNeverLoops() {
        let trust = Trust()
        let gate = AccessibilityGate(check: { trust.check($0) })
        #expect(gate.request() == .asked)
        #expect(gate.request() == .waiting)
        #expect(gate.request() == .waiting)
        for _ in 0..<50 { gate.poll() }
        #expect(trust.prompts == 1, "prompted \(trust.prompts) times")
        #expect(gate.isWaiting)
    }

    /// The grant, seen by the poll, carries on: the waiting lookup is resumed once and the polling stops.
    @Test func theGrantCarriesOnWithoutARelaunch() {
        let trust = Trust()
        let gate = AccessibilityGate(check: { trust.check($0) })
        var resumed = 0
        gate.onGranted = { resumed += 1 }
        #expect(gate.request() == .asked)
        gate.poll()
        #expect(resumed == 0)
        trust.trusted = true
        gate.poll()
        gate.poll()
        #expect(resumed == 1)
        #expect(!gate.isWaiting)
        let calls = trust.calls.count
        gate.poll()
        #expect(trust.calls.count == calls, "polled after the grant")
        #expect(gate.request() == .trusted)
    }

    /// The reader ignored the request until the polling gave up: a later lookup may ask once more — one press, one
    /// prompt, never more.
    @Test func afterThePollingGivesUpALaterLookupAsksOnceMore() {
        let trust = Trust()
        let gate = AccessibilityGate(check: { trust.check($0) }, polls: 3)
        #expect(gate.request() == .asked)
        for _ in 0..<3 { gate.poll() }
        #expect(!gate.isWaiting)
        #expect(gate.request() == .asked)
        #expect(trust.prompts == 2)
    }
}
