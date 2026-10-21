import Foundation
import Testing
import XDictTestSupport

/// **The drawer's motion is the animation's own** (owner, 2026-10-21: "drawer slide in and out animation not consistent";
/// XiaolaiDict's lessons, kept). The open's spring starts one runloop turn after the window is ordered front, so the
/// parked frame is on screen before anything moves — a state change made in the turn the window first lays out animates
/// from no rendered frame, and the first open snapped while every later one slid. The close's window is ordered out by
/// the animation's own completion, never by a duration kept in step with the spring by hand — a fixed delay cut the
/// close mid-flight on a loaded machine, so the next open began wherever that cut left the content. Read off the
/// controller, since no gate launches the app.
struct DrawerMotionWiringTests {
    @Test func theDrawerAnimatesFromARenderedFrameAndClosesOnItsCompletion() throws {
        let ui = Manifest.package.appending(path: "Sources/XDictUI")
        let controller = try SourceScan.files(under: ui)
            .first { $0.file.lastPathComponent == "HistoryDrawerController.swift" }
        let text = try #require(controller?.text, "the drawer's controller was not read")
        #expect(Self.problems(SourceScan.codeOnly(text)) == [])
    }

    @Test func eachMistakeIsNamed() {
        let right = """
            panel.animationBehavior = .none
            panel.orderFrontRegardless()
            DispatchQueue.main.async { withAnimation(Motion.drawerOpen) { presentation.revealed = true } }
            withAnimation(Motion.drawerClose) { presentation.revealed = false } completion: { panel?.orderOut(nil) }
            """
        #expect(Self.problems(right) == [])
        let snapped = """
            panel.animationBehavior = .none
            panel.orderFrontRegardless()
            withAnimation(Motion.drawerOpen) { presentation.revealed = true }
            withAnimation(Motion.drawerClose) { presentation.revealed = false } completion: { panel?.orderOut(nil) }
            """
        #expect(Self.problems(snapped) == ["the open animates in the turn the window first lays out"])
        let timed = """
            panel.animationBehavior = .none
            DispatchQueue.main.async { withAnimation(Motion.drawerOpen) { presentation.revealed = true } }
            withAnimation(Motion.drawerClose) { presentation.revealed = false }
            hiding = Task { try? await Task.sleep(for: .milliseconds(320)); panel?.orderOut(nil) }
            """
        // The old shape names two mistakes, because a timer beside the spring and an order-out without the completion are
        // separate defects: the first cuts the close, the second hides the window whenever the timer says so.
        #expect(Self.problems(timed) == ["the close waits a fixed duration instead of the animation's completion",
                                         "the close orders the window out outside the animation's completion"])
        let cut = """
            panel.animationBehavior = .none
            DispatchQueue.main.async { withAnimation(Motion.drawerOpen) { presentation.revealed = true } }
            withAnimation(Motion.drawerClose) { presentation.revealed = false }
            panel?.orderOut(nil)
            """
        #expect(Self.problems(cut) == ["the close orders the window out outside the animation's completion"])
        let faded = """
            DispatchQueue.main.async { withAnimation(Motion.drawerOpen) { presentation.revealed = true } }
            withAnimation(Motion.drawerClose) { presentation.revealed = false } completion: { panel?.orderOut(nil) }
            """
        #expect(Self.problems(faded) == ["the window keeps the system's own ordering animation"])
    }

    static func problems(_ code: String) -> [String] {
        var found: [String] = []
        if code.contains("Task.sleep") || code.contains("drawerSettleMilliseconds") {
            found.append("the close waits a fixed duration instead of the animation's completion")
        }
        if !code.contains(/(?s)DispatchQueue\.main\.async.{0,600}?withAnimation\(Motion\.drawerOpen\)/) {
            found.append("the open animates in the turn the window first lays out")
        }
        if !code.contains(/(?s)withAnimation\(Motion\.drawerClose\).{0,600}?completion:.{0,600}?orderOut\(/) {
            found.append("the close orders the window out outside the animation's completion")
        }
        if !code.contains("animationBehavior = .none") {
            found.append("the window keeps the system's own ordering animation")
        }
        return found
    }
}
