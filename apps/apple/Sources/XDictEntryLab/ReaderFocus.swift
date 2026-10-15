import AppKit
import Foundation

/// **Why a hand's event did or did not land**, for the `reader` stage (`Tools/hostile/reader.py`): which application
/// the system made active and when, which of the lab's windows became or stopped being key, and every button and key
/// event that reached the lab, with whether the lab was active and the window key as it arrived. A step can then say
/// whether its click never reached the lab, reached it while another application was active (the click that only
/// activates, which a web view does not take), or reached it and did nothing.
@MainActor
final class FocusLog {
    private(set) var timeline: [[String: Any]] = []
    private var observers: [NSObjectProtocol] = []
    private var monitor: Any?

    func start() {
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didChangeOcclusionStateNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let what = note.name.rawValue
                let window = note.object as? NSWindow
                MainActor.assumeIsolated { self?.note(what, window: window) }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let name = app?.localizedName ?? "?", pid = Int(app?.processIdentifier ?? -1)
                MainActor.assumeIsolated { self?.append(["what": "activated", "app": name, "appPid": pid]) }
            })
        let kinds: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .keyDown]
        monitor = NSEvent.addLocalMonitorForEvents(matching: kinds) { [weak self] event in
            MainActor.assumeIsolated { self?.received(event) }
            return event
        }
    }

    /// The lab's own view of its focus now: active, the reader window key, visible and not covered.
    static func focus(of window: NSWindow?) -> [String: Any] {
        let front = NSWorkspace.shared.frontmostApplication
        return [
            "active": NSApp.isActive,
            "key": window?.isKeyWindow ?? false,
            "main": window?.isMainWindow ?? false,
            "visible": window?.isVisible ?? false,
            "unoccluded": window?.occlusionState.contains(.visible) ?? false,
            "keyWindow": NSApp.keyWindow.map(Self.name) ?? "",
            "frontmost": front?.localizedName ?? "",
            "frontmostPid": Int(front?.processIdentifier ?? -1),
            "windowNumber": window?.windowNumber ?? -1,
        ]
    }

    private static func name(_ window: NSWindow) -> String {
        window.title.isEmpty ? (window.isSheet ? "sheet" : String(describing: type(of: window))) : window.title
    }

    private func note(_ what: String, window: NSWindow?) {
        var entry: [String: Any] = ["what": what.replacingOccurrences(of: "NSApplication", with: "app ")
            .replacingOccurrences(of: "NSWindow", with: "window ").replacingOccurrences(of: "Notification", with: "")]
        if let window {
            entry["window"] = Self.name(window)
            if what == NSWindow.didChangeOcclusionStateNotification.rawValue {
                entry["visible"] = window.occlusionState.contains(.visible)
            }
        }
        append(entry)
    }

    private func received(_ event: NSEvent) {
        let screen = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
        let kind = [NSEvent.EventType.leftMouseDown: "leftMouseDown", .leftMouseUp: "leftMouseUp",
                    .rightMouseDown: "rightMouseDown", .keyDown: "keyDown"][event.type] ?? "\(event.type.rawValue)"
        append(["what": kind, "window": event.window.map(Self.name) ?? "",
                "at": ReaderRun.global(screen), "active": NSApp.isActive, "key": event.window?.isKeyWindow ?? false,
                "flags": event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue])
    }

    private func append(_ entry: [String: Any]) {
        timeline.append(entry.merging(["t": Date().timeIntervalSince1970]) { old, _ in old })
    }
}
