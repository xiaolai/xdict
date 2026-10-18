// keys: a reader's keyboard, and VoiceOver's reading of a window, for the E2E `lookup` stage (plan-macos-v1 WI-6, R10).
// Key events are posted into the HID stream, where the app cannot tell them from a keyboard; the window is read through
// the Accessibility API, as VoiceOver reads it.
//
//   keys access                 {"accessibility", "postEvents", "layout"}: asked of APIs that never prompt
//   keys front                  the frontmost application, and whether the display sleeps
//   keys type <text>            the text, character by character
//   keys press <combo>          one key with modifiers: return, tab, escape, up, down, a, f, [, ], 0–9 …; cmd+opt+[
//   keys focused <pid>          the element of that app with the keyboard, and its ancestors' identifiers
//   keys ax <pid> [max]         the app's main window as a list of elements in reading order (role, identifier,
//                               texts, depth); an entry's web content is not descended into
//   keys web <pid>              the shown entry as read: how many elements, its links (and which has the keyboard),
//                               and the app's focused element read after it
//   keys geometry <pid>         frames (screen points, top-left origin) of the main window, its toolbar, the
//                               page's notices, the entry's web area and the entry's first text
//
// **The grant it needs** (as `Tools/hostile/pointer.swift`): a command started over SSH is judged by TCC as its
// session's responsible process, `sshd-keygen-wrapper`, which needs Accessibility to post events and to read another
// app's elements. `access` says whether it has it; every other command refuses without it, since an event the system
// drops is a key never pressed, and an unread tree reads as an empty window.
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics

func die(_ message: String, _ status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(("keys: " + message + "\n").utf8))
    exit(status)
}

func emit(_ object: Any) -> Never {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { die("no JSON") }
    print(String(decoding: data, as: UTF8.self))
    exit(0)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { die("usage: keys access|front|type|press|focused|ax …", 2) }

if command == "access" {
    let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
    let layout = source.flatMap { TISGetInputSourceProperty($0, kTISPropertyInputSourceID) }
        .map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String } ?? "?"
    emit(["accessibility": AXIsProcessTrusted(), "postEvents": CGPreflightPostEventAccess(), "layout": layout])
}
if command == "front" {
    let front = NSWorkspace.shared.frontmostApplication
    emit(["pid": Int(front?.processIdentifier ?? -1), "name": front?.localizedName ?? "",
          "bundle": front?.bundleIdentifier ?? "", "displayAsleep": CGDisplayIsAsleep(CGMainDisplayID()) != 0])
}
guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
    die("this session may not post events or read other apps (Accessibility is not granted)")
}

// MARK: - Keys

/// Virtual key codes of the ANSI layout: positions, not characters (`access` names the layout in use).
let codes: [String: CGKeyCode] = [
    "return": 36, "tab": 48, "escape": 53, "space": 49, "delete": 51, "up": 126, "down": 125, "left": 123, "right": 124,
    "a": 0, "f": 3, "g": 5, "l": 37, "[": 33, "]": 30,
    "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
]

func post(_ code: CGKeyCode, _ flags: CGEventFlags, unicode: [UniChar]? = nil) {
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { die("no key event") }
        event.flags = flags
        if let unicode { event.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: unicode) }
        event.post(tap: .cghidEventTap)
        usleep(25_000)
    }
}

if command == "type" {
    guard arguments.count == 2 else { die("usage: keys type <text>", 2) }
    for character in arguments[1] {
        post(character == " " ? 49 : 0, [], unicode: Array(String(character).utf16))
        usleep(40_000)
    }
    exit(0)
}
if command == "press" {
    guard arguments.count == 2 else { die("usage: keys press <combo>", 2) }
    let parts = arguments[1].split(separator: "+", omittingEmptySubsequences: false).map(String.init)
    var flags: CGEventFlags = []
    for modifier in parts.dropLast() {
        switch modifier {
        case "cmd": flags.insert(.maskCommand)
        case "opt": flags.insert(.maskAlternate)
        case "shift": flags.insert(.maskShift)
        case "ctrl": flags.insert(.maskControl)
        default: die("no modifier \(modifier)", 2)
        }
    }
    guard let name = parts.last, let code = codes[name] else { die("no key \(parts.last ?? "")", 2) }
    post(code, flags)
    exit(0)
}

// MARK: - Reading

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func string(_ element: AXUIElement, _ name: String) -> String? {
    guard let value = attribute(element, name) else { return nil }
    if CFGetTypeID(value) == CFStringGetTypeID() { return value as? String }
    if CFGetTypeID(value) == CFNumberGetTypeID() { return (value as? NSNumber)?.stringValue }
    return nil
}

func describe(_ element: AXUIElement) -> [String: Any] {
    var texts: [String] = []
    for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] as [String] {
        if let text = string(element, name), !text.isEmpty { texts.append(String(text.prefix(400))) }
    }
    return ["role": string(element, kAXRoleAttribute) ?? "", "subrole": string(element, kAXSubroleAttribute) ?? "",
            "id": string(element, "AXIdentifier") ?? "", "texts": texts]
}

/// `value` as an element, when it is one: checked by its type, so the cast cannot fail.
func element(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func application(_ text: String?) -> AXUIElement {
    guard let text, let pid = Int32(text) else { die("a pid is needed", 2) }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 5)
    return app
}

if command == "focused" {
    let app = application(arguments.dropFirst().first)
    guard let focused = element(attribute(app, kAXFocusedUIElementAttribute)) else { emit(["focused": NSNull()]) }
    var ancestors: [String] = []
    var cursor = element(attribute(focused, kAXParentAttribute))
    while let parent = cursor, ancestors.count < 30 {
        ancestors.append("\(string(parent, kAXRoleAttribute) ?? "")#\(string(parent, "AXIdentifier") ?? "")")
        cursor = element(attribute(parent, kAXParentAttribute))
    }
    emit(["focused": describe(focused), "ancestors": ancestors])
}

if command == "ax" {
    let app = application(arguments.dropFirst().first)
    let limit = arguments.count > 2 ? Int(arguments[2]) ?? 6_000 : 6_000
    guard let main = element(attribute(app, kAXMainWindowAttribute)) else {
        emit(["nodes": [], "why": "the app has no main window"])
    }
    var nodes: [[String: Any]] = []
    func walk(_ element: AXUIElement, _ depth: Int) {
        guard nodes.count < limit, depth < 60 else { return }
        var node = describe(element)
        node["depth"] = depth
        nodes.append(node)
        // An entry's content is the dictionary's, and can be long: its own checks read it, not this one.
        guard node["role"] as? String != "AXWebArea" else { return }
        for child in children(element) { walk(child, depth + 1) }
    }
    walk(main, 0)
    emit(["nodes": nodes, "truncated": nodes.count >= limit])
}

if command == "web" {
    let app = application(arguments.dropFirst().first)
    guard let main = element(attribute(app, kAXMainWindowAttribute)) else {
        emit(["web": NSNull(), "why": "the app has no main window"])
    }
    func area(in element: AXUIElement, _ depth: Int) -> AXUIElement? {
        if string(element, kAXRoleAttribute) == "AXWebArea" { return element }
        guard depth < 40 else { return nil }
        for child in children(element) {
            if let found = area(in: child, depth + 1) { return found }
        }
        return nil
    }
    guard let web = area(in: main, 0) else { emit(["web": NSNull(), "why": "no web area in the main window"]) }
    var count = 0
    var links: [[String: Any]] = []
    func walk(_ element: AXUIElement, _ depth: Int) {
        guard count < 3_000, depth < 80 else { return }
        count += 1
        if string(element, kAXRoleAttribute) == "AXLink", links.count < 20 {
            var link = describe(element)
            link["focused"] = (attribute(element, kAXFocusedAttribute) as? Bool) ?? false
            link["inner"] = children(element).flatMap { [describe($0)] + children($0).map(describe) }
                .flatMap { $0["texts"] as? [String] ?? [] }
            links.append(link)
        }
        for child in children(element) { walk(child, depth + 1) }
    }
    walk(web, 0)
    let focused: Any = element(attribute(app, kAXFocusedUIElementAttribute)).map(describe) ?? NSNull()
    emit(["web": ["elements": count, "links": links], "focused": focused])
}
/// An element's frame in screen points (top-left origin), or nil when it has none.
func frame(_ element: AXUIElement) -> [String: Double]? {
    guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute),
          CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    var extent = CGSize.zero
    // Checked by type above, so the casts cannot fail.
    guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
          AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
    return ["x": point.x, "y": point.y, "width": extent.width, "height": extent.height]
}

// The main window's toolbar, entry and the entry's first text, as frames: where the entry starts and how far its text
// stands from the pane's edge.
if command == "geometry" {
    let app = application(arguments.dropFirst().first)
    guard let main = element(attribute(app, kAXMainWindowAttribute)) else {
        emit(["why": "the app has no main window"])
    }
    func first(in element: AXUIElement, _ depth: Int, _ match: (AXUIElement) -> Bool) -> AXUIElement? {
        if match(element) { return element }
        guard depth < 60 else { return nil }
        for child in children(element) {
            if let found = first(in: child, depth + 1, match) { return found }
        }
        return nil
    }
    let toolbar = first(in: main, 0) { string($0, kAXRoleAttribute) == "AXToolbar" }
    let web = first(in: main, 0) { string($0, kAXRoleAttribute) == "AXWebArea" }
    let text = web.flatMap { area in
        first(in: area, 0) {
            string($0, kAXRoleAttribute) == "AXStaticText" && !(string($0, kAXValueAttribute) ?? "").isEmpty
        }
    }
    // What may stand between the toolbar and the entry (P6): the page's notices while a dictionary could not search;
    // the scope is the search field's menu since 2026-10-18, not a row of its own.
    let notices = first(in: main, 0) { string($0, "AXIdentifier") == "page.notices" }
    var found: [String: Any] = [:]
    for (name, item) in [("window", main), ("toolbar", toolbar), ("notices", notices), ("web", web), ("text", text)] {
        found[name] = item.flatMap(frame) ?? NSNull()
    }
    found["textValue"] = text.flatMap { string($0, kAXValueAttribute) } ?? NSNull()
    emit(found)
}
die("no command \(command)", 2)
