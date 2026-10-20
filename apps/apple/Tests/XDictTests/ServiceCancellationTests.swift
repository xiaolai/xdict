import AppKit
import Foundation
import Synchronization
import Testing
import XDictAnywhere
import XDictCapture
import XDictCaptureMac
@testable import XDict

/// **A Service is held like a read** (ADR-0014 decision 4; Codex objection 1): the tasks were unretained, and only the
/// shortcut's own read was cancelled — a Service left reading could present over a newer request. A shortcut, Escape
/// or a newer Service cancels it, from either origin, and a read that answers after the cancellation changes nothing.
@MainActor
struct ServiceCancellationTests {
    enum Origin: String, CaseIterable, Sendable { case readersApp, ownWindow }
    enum Action: String, CaseIterable, Sendable { case shortcut, escape }

    struct Case: Sendable, CustomStringConvertible {
        let origin: Origin
        let action: Action
        var description: String { "\(origin.rawValue)/\(action.rawValue)" }
    }

    nonisolated static let cases = Origin.allCases.flatMap { origin in Action.allCases.map { Case(origin: origin, action: $0) } }

    /// A Service read the test suspends: it answers when released, and remembers whether its task was cancelled by then.
    final class SuspendedRead: Sendable {
        let entered: AsyncStream<Void>
        let enter: AsyncStream<Void>.Continuation
        let release: AsyncStream<Void>
        let letGo: AsyncStream<Void>.Continuation
        let cancelled = Mutex(false)
        /// The app each read was made for: the Service's is nil here (no other app), a superseded press's is the fake one.
        let apps = Mutex<[pid_t?]>([])

        init() {
            (entered, enter) = AsyncStream<Void>.makeStream()
            (release, letGo) = AsyncStream<Void>.makeStream()
        }

        func read(_ app: FrontApp?, _ clicked: CGPoint?, _ excluding: HoverPolicy) async -> SelectionOutcome? {
            apps.withLock { $0.append(app?.pid) }
            enter.yield()
            var iterator = release.makeAsyncIterator()
            _ = await iterator.next()
            cancelled.withLock { $0 = Task.isCancelled }
            return nil
        }
    }

    @Test(arguments: cases)
    func anInFlightServiceIsCancelledAndPresentsNothing(_ one: Case) async throws {
        let lookup = LookupAnywhere()
        lookup.serviceOrigin = { one.origin == .ownWindow ? .ours : .readersApp }
        // No other app: the readers-app path then activates nothing on this Mac and still reads through the seam.
        lookup.lastOtherApp = nil
        lookup.isTrusted = { true }
        lookup.gate = AccessibilityGate(check: { _ in true })
        let read = SuspendedRead()
        lookup.selectionRead = { app, clicked, excluding in await read.read(app, clicked, excluding) }
        var events: [String] = []
        lookup.observe = { event, _ in events.append(event) }
        // The tests never take the reader's Escape key: the claim is recorded, not made.
        var escapeClaims: [Bool] = []
        lookup.escapeBind = { escapeClaims.append($0) }

        lookup.service("hold")
        var entered = read.entered.makeAsyncIterator()
        _ = await entered.next()  // the Service's read is in flight
        // **Escape is held while the Service reads, with no panel yet** (audit-fix 2026-10-20 finding 2).
        #expect(escapeClaims == [true], "the Service's read held no Escape: \(escapeClaims)")
        // The shortcut's own read answers at once: only the Service's stays suspended.
        lookup.selectionRead = { _, _, _ in .nothing(.notTrusted) }
        switch one.action {
        case .shortcut: lookup.pressed()
        case .escape: lookup.close(why: "the test")
        }
        if one.action == .escape {
            #expect(escapeClaims == [true, false], "Escape was not given back when the Service ended: \(escapeClaims)")
        }
        read.letGo.yield()
        try await Task.sleep(for: .milliseconds(200))
        #expect(read.cancelled.withLock { $0 }, "the Service read was not cancelled")
        #expect(!events.contains("serviceSelection"), "a cancelled Service went on reading: \(events)")
    }

    /// **A delayed menu request does nothing once a newer Service owns presentation** (audit-fix 2026-10-20 finding 4):
    /// the menu numbers at the click and waits 150 ms; its late press used to cancel the newer Service's read. The read
    /// that reaches the seam is the Service's (no other app, so no app) — the superseded press would bring the fake one.
    @Test func aLateMenuRequestLeavesANewerServiceAlone() async throws {
        let lookup = LookupAnywhere()
        lookup.lastOtherApp = nil
        lookup.isTrusted = { true }
        lookup.gate = AccessibilityGate(check: { _ in true })
        lookup.escapeBind = { _ in }
        let read = SuspendedRead()
        lookup.selectionRead = { app, clicked, excluding in await read.read(app, clicked, excluding) }
        // A reader's app in front, so the superseded press would reach its read if the rule let it.
        lookup.frontmostApp = { FrontApp(pid: 999_999, name: "Reader", bundleID: nil) }
        lookup.lookUpFromMenu()   // numbered and claimed now; its press comes 150 ms later
        lookup.service("hold")    // a newer request claims presentation; its read suspends
        var entered = read.entered.makeAsyncIterator()
        _ = await entered.next()  // the Service's read, after its bring-forward wait
        #expect(read.apps.withLock { $0 } == [nil],
                "the menu's superseded press read the selection: \(read.apps.withLock { $0 })")
        read.letGo.yield()
        try await Task.sleep(for: .milliseconds(100))
    }

    /// **A grant owed to a superseded request resumes nothing** (round 3, finding 3): the shortcut asked for
    /// Accessibility, a Service superseded it, and the grant then arrived — no lookup may start over the Service.
    @Test func aGrantAfterARequestWasSupersededDoesNotResumeIt() async throws {
        let lookup = LookupAnywhere()
        lookup.lastOtherApp = nil
        let trusted = Mutex(false)
        lookup.gate = AccessibilityGate(check: { _ in trusted.withLock { $0 } })
        lookup.frontmostApp = { FrontApp(pid: 999_999, name: "Reader", bundleID: nil) }
        lookup.escapeBind = { _ in }
        let read = SuspendedRead()
        lookup.selectionRead = { app, clicked, excluding in await read.read(app, clicked, excluding) }
        var events: [String] = []
        lookup.observe = { event, _ in events.append(event) }
        lookup.pressed()         // no grant: the system's request is open, and its resume waits for the answer
        lookup.service("hold")   // a newer request supersedes the shortcut's
        trusted.withLock { $0 = true }
        lookup.gate.poll()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!events.contains("granted"), "a grant resumed a request that was superseded: \(events)")
        #expect(read.apps.withLock { $0 }.isEmpty, "the superseded shortcut started a read on the grant")
        read.letGo.yield()
        try await Task.sleep(for: .milliseconds(100))
    }
}
