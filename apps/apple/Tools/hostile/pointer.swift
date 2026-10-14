// pointer: a person's hands for the reader-driven egress test (plan-macos-v1 WI-4; ADR-0009 refutation, item 8), as
// real events posted into the HID stream, where WebKit cannot tell them from a mouse. Adapted from XiaolaiDict's E2E
// helpers (`Tools/e2e/drag-card.swift`, `keys.swift`, `session-access.swift`).
//
//   pointer access                         {"accessibility": …, "postEvents": …}: asked of APIs that never prompt
//   pointer move <x> <y>                   hover (global display points, origin top left)
//   pointer click <x> <y> [mods] [button]  mods: none, cmd, opt, shift, ctrl (joined with +); button: left, right
//   pointer drag <x1> <y1> <x2> <y2>       press, move in steps, release
//   pointer key <name>                     escape, return
//
// **Which grant it needs** (XiaolaiDict, 2026-10-08): a command started over SSH is judged by TCC as its session's
// responsible process, `sshd-keygen-wrapper`, which needs Accessibility (macOS 27: Privacy & Security, "Device Control
// and Data Access") to post events. `access` says whether it has it; every other command refuses without it, since
// an event the system drops is a click that never happened and would read as "nothing left".
import AppKit
import ApplicationServices
import CoreGraphics

func die(_ message: String, _ status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(("pointer: " + message + "\n").utf8))
    exit(status)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { die("usage: pointer access|move|click|drag|key …", 2) }

if command == "access" {
    let report: [String: Any] = ["accessibility": AXIsProcessTrusted(), "postEvents": CGPreflightPostEventAccess()]
    guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) else { die("no report") }
    print(String(decoding: data, as: UTF8.self))
    exit(0)
}
guard CGPreflightPostEventAccess() else { die("this session may not post events (Accessibility is not granted)") }

func number(_ index: Int) -> Double {
    guard index < arguments.count, let value = Double(arguments[index]), value.isFinite, abs(value) < 20_000 else {
        die("argument \(index) is not a coordinate", 2)
    }
    return value
}

func flags(_ text: String) -> CGEventFlags {
    var out: CGEventFlags = []
    for part in text.split(separator: "+") {
        switch part {
        case "none": break
        case "cmd": out.insert(.maskCommand)
        case "opt": out.insert(.maskAlternate)
        case "shift": out.insert(.maskShift)
        case "ctrl": out.insert(.maskControl)
        default: die("no modifier \(part)", 2)
        }
    }
    return out
}

func post(_ type: CGEventType, _ point: CGPoint, _ modifiers: CGEventFlags = [], button: CGMouseButton = .left,
          clicks: Int64 = 1) {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
    else { die("no \(type) event could be made") }
    event.flags = modifiers
    event.setIntegerValueField(.mouseEventClickState, value: clicks)
    event.post(tap: .cghidEventTap)
}

func key(_ code: CGKeyCode) {
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { die("no key event") }
        event.post(tap: .cghidEventTap)
        usleep(30_000)
    }
}

switch command {
case "move":
    let to = CGPoint(x: number(1), y: number(2))
    post(.mouseMoved, CGPoint(x: to.x - 30, y: to.y - 10))
    usleep(80_000)
    post(.mouseMoved, to)
case "click":
    let at = CGPoint(x: number(1), y: number(2))
    let modifiers = flags(arguments.count > 3 ? arguments[3] : "none")
    let right = arguments.count > 4 && arguments[4] == "right"
    post(.mouseMoved, at, modifiers)
    usleep(120_000)
    post(right ? .rightMouseDown : .leftMouseDown, at, modifiers, button: right ? .right : .left)
    usleep(60_000)
    post(right ? .rightMouseUp : .leftMouseUp, at, modifiers, button: right ? .right : .left)
case "drag":
    let from = CGPoint(x: number(1), y: number(2)), to = CGPoint(x: number(3), y: number(4))
    post(.mouseMoved, from)
    usleep(120_000)
    post(.leftMouseDown, from)
    usleep(400_000)
    // A few short moves first, past the drag threshold, as a hand starts a drag; then the way to the target, a pause
    // over it (the target is asked while the drag hovers), and the release.
    for step in 1...6 {
        post(.leftMouseDragged, CGPoint(x: from.x + Double(step) * 2, y: from.y + Double(step)))
        usleep(40_000)
    }
    let steps = 60
    for step in 1...steps {
        let part = Double(step) / Double(steps)
        post(.leftMouseDragged, CGPoint(x: from.x + 12 + (to.x - from.x - 12) * part,
                                        y: from.y + 6 + (to.y - from.y - 6) * part))
        usleep(20_000)
    }
    for _ in 1...5 {
        post(.leftMouseDragged, to)
        usleep(80_000)
    }
    post(.leftMouseUp, to)
case "key":
    switch arguments.count > 1 ? arguments[1] : "" {
    case "escape": key(53)
    case "return": key(36)
    default: die("no key \(arguments.count > 1 ? arguments[1] : "")", 2)
    }
default:
    die("no command \(command)", 2)
}
usleep(100_000)
