// hands: a reader's hands in other apps, for the E2E `anywhere` sub-stages (plan-macos-v1 WI-8). Selections are made in
// TextEdit, Notes, Safari and Chrome through the Accessibility API, as VoiceOver would; keys, clicks and scrolls are
// posted into the HID stream, where no app can tell them from a person's; menus are read and chosen through the
// Accessibility API. Every command prints one JSON line.
//
//   hands access                          {"accessibility", "postEvents"}: asked of APIs that never prompt
//   hands front                           the frontmost application
//   hands activate <bundle>               brings the app forward and waits until it is frontmost
//   hands select <bundle> <needle>        selects the first occurrence of <needle> in the app's focused text (a text view's
//                                         range) or its front window's page (WebKit's markers); its box, y down
//   hands value <bundle>                  the focused element's value, as the app holds it
//   hands press <combo>                   one key: escape, return, a–z, 0–9, space; modifiers ctrl+opt+shift+cmd+
//   hands panel <pid> <combo> <seconds>   presses <combo> and polls the window list for a floating window of <pid>
//                                         coming on screen: the seconds from the key to it, measured outside the app
//   hands click <x> <y> [right]           a click at a point, y down
//   hands scroll <x> <y> <lines>          a scroll-wheel turn at a point (negative: down the page)
//   hands context <bundle> <x> <y> <title> [choose]
//                                         a right click at the point; the context menu read for <title>: "menu" (an item
//                                         of it), "services" (under its Services item), or "absent"; with `choose`, the
//                                         item chosen. The menu is closed otherwise
//   hands element <pid> <identifier>      the frame (y down) of the app's element with that identifier, in any window
//   hands menubar <pid> [title]           the app's menu-bar item: its menu's items; with a title, that one chosen
//   hands hold <combo> <seconds>          registers <combo> as an exclusive hot key, as another app would, and holds it
//
// **The grant it needs**: started over SSH it is judged by TCC as `sshd-keygen-wrapper`, which needs Accessibility to post
// events and read other apps. `access` says whether it has it; every other command refuses without it, since an event
// the system drops is a key never pressed.
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics

func die(_ message: String, _ status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(("hands: " + message + "\n").utf8))
    exit(status)
}

func json(_ value: Any?) -> Any { value ?? NSNull() }

func emit(_ object: Any) -> Never {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { die("no JSON") }
    print(String(decoding: data, as: UTF8.self))
    exit(0)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { die("usage: hands <command> …", 2) }
func argument(_ index: Int) -> String {
    guard arguments.indices.contains(index) else { die("\(command): missing argument \(index)", 2) }
    return arguments[index]
}

if command == "access" {
    emit(["accessibility": AXIsProcessTrusted(), "postEvents": CGPreflightPostEventAccess()])
}
func frontInfo() -> [String: Any] {
    let front = NSWorkspace.shared.frontmostApplication
    return ["pid": Int(front?.processIdentifier ?? -1), "bundle": front?.bundleIdentifier ?? "",
            "name": front?.localizedName ?? ""]
}
if command == "front" { emit(frontInfo()) }
guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
    die("this session may not post events or read other apps (Accessibility is not granted)")
}

// MARK: - Accessibility

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func parameterized(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyParameterizedAttributeValue(element, name as CFString, argument, &value) == .success ? value : nil
}
func element(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeDowncast(value, to: AXUIElement.self)
}
func children(_ node: AXUIElement) -> [AXUIElement] {
    ((attribute(node, kAXChildrenAttribute) as? [CFTypeRef]) ?? []).compactMap(element)
}
func string(_ node: AXUIElement, _ name: String) -> String? { attribute(node, name) as? String }
func rect(_ value: CFTypeRef?) -> CGRect? {
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var box = CGRect.zero
    return AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgRect, &box) ? box : nil
}
func frame(_ node: AXUIElement) -> CGRect? {
    guard let position = attribute(node, kAXPositionAttribute), let size = attribute(node, kAXSizeAttribute),
          CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var origin = CGPoint.zero, extent = CGSize.zero
    AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &origin)
    AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &extent)
    return CGRect(origin: origin, size: extent)
}
func describe(_ box: CGRect) -> [String: Double] {
    ["x": box.minX, "y": box.minY, "width": box.width, "height": box.height]
}
func find(_ root: AXUIElement, limit: Int = 6_000, _ matches: (AXUIElement) -> Bool) -> AXUIElement? {
    var queue = [root], head = 0
    while head < queue.count, head < limit {
        let node = queue[head]
        head += 1
        if matches(node) { return node }
        queue.append(contentsOf: children(node))
    }
    return nil
}
func running(_ bundle: String) -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
}
/// The app's process ID, from the window list where LaunchServices reports -1 (Safari on macOS 27).
func pid(of bundle: String) -> pid_t? {
    guard let app = running(bundle) else { return nil }
    if app.processIdentifier > 0 { return app.processIdentifier }
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return windows.compactMap { $0[kCGWindowOwnerPID as String] as? pid_t }
        .first { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier == bundle }
}
func application(_ bundle: String) -> AXUIElement {
    guard let pid = pid(of: bundle) else { die("\(bundle) is not running") }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 5)
    // Chromium builds its tree only when asked.
    AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    return app
}
func activate(_ bundle: String) -> Bool {
    guard let app = running(bundle) else { return false }
    for _ in 0..<3 {
        // LaunchServices, as the Dock does: `activate()` alone is cooperative on macOS 14 and later, and an app that
        // has just launched keeps the front from it (measured on the E2E Mac, 2026-10-15).
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-b", bundle]
        try? open.run()
        open.waitUntilExit()
        app.activate()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle { return true }
            usleep(100_000)
        }
    }
    return false
}

// MARK: - Events

let codes: [String: CGKeyCode] = [
    "return": 36, "tab": 48, "escape": 53, "space": 49, "delete": 51,
    "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4, "i": 34, "j": 38, "k": 40, "l": 37, "m": 46,
    "n": 45, "o": 31, "p": 35, "q": 12, "r": 15, "s": 1, "t": 17, "u": 32, "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
    "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
]
func combo(_ text: String) -> (CGKeyCode, CGEventFlags) {
    let parts = text.split(separator: "+").map(String.init)
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
    guard let name = parts.last, let code = codes[name] else { die("no key \(text)", 2) }
    return (code, flags)
}
func press(_ text: String) {
    let (code, flags) = combo(text)
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { die("no key event") }
        event.flags = flags
        event.post(tap: .cghidEventTap)
        usleep(20_000)
    }
}
func click(_ point: CGPoint, right: Bool = false) {
    let kinds: [CGEventType] = right ? [.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp]
    if let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
        move.post(tap: .cghidEventTap)
        usleep(60_000)
    }
    for kind in kinds {
        let event = CGEvent(mouseEventSource: nil, mouseType: kind, mouseCursorPosition: point,
                            mouseButton: right ? .right : .left)
        event?.post(tap: .cghidEventTap)
        usleep(50_000)
    }
}

/// The text-marker range on `page` that reads back as exactly `needle`, searched from `index` outwards (start within
/// ±`spread`, length within ±2), or nil: never a range that merely starts near it.
func verifiedMarkers(_ page: AXUIElement, needle: String, at index: Int, length: Int, spread: Int = 24) -> CFTypeRef? {
    for delta in [0] + (1...spread).flatMap({ [-$0, $0] }) where index + delta >= 0 {
        for extra in [0, -1, 1, -2, 2] where length + extra > 0 {
            let start = index + delta
            guard let first = parameterized(page, "AXTextMarkerForIndex", start as CFNumber),
                  let last = parameterized(page, "AXTextMarkerForIndex", (start + length + extra) as CFNumber),
                  let range = parameterized(page, "AXTextMarkerRangeForUnorderedTextMarkers", [first, last] as CFArray)
            else { continue }
            if parameterized(page, "AXStringForTextMarkerRange", range) as? String == needle { return range }
        }
    }
    return nil
}

/// The needle's markers from the text element that holds it, where the page's indices place it nowhere (Chrome, E2E
/// 2026-10-18: no range near the index read back as the phrase). The element's own range (`AXTextMarkerRangeForUIElement`)
/// gives its first marker; `AXNextTextMarkerForTextMarker` steps from it to the needle and across it, counted in
/// characters and, failing that, in UTF-16 units. Taken only when the range reads back as exactly the needle.
func elementMarkers(_ page: AXUIElement, needle: String) -> CFTypeRef? {
    guard let holder = find(page, { node in
        string(node, kAXRoleAttribute) == "AXStaticText" && (string(node, kAXValueAttribute)?.contains(needle) ?? false)
    }), let value = string(holder, kAXValueAttribute), let at = value.range(of: needle),
          let own = parameterized(holder, "AXTextMarkerRangeForUIElement", holder),
          CFGetTypeID(own) == AXTextMarkerRangeGetTypeID()
    else { return nil }
    let start = AXTextMarkerRangeCopyStartMarker(unsafeDowncast(own, to: AXTextMarkerRange.self))
    func step(_ marker: CFTypeRef, _ count: Int) -> CFTypeRef? {
        var current = marker
        for _ in 0..<count {
            guard let next = parameterized(page, "AXNextTextMarkerForTextMarker", current) else { return nil }
            current = next
        }
        return current
    }
    let counts = [(value.distance(from: value.startIndex, to: at.lowerBound), needle.count),
                  (value.utf16.distance(from: value.startIndex, to: at.lowerBound), needle.utf16.count)]
    for (offset, length) in counts {
        guard let first = step(start, offset), let last = step(first, length),
              let range = parameterized(page, "AXTextMarkerRangeForUnorderedTextMarkers", [first, last] as CFArray)
        else { continue }
        if parameterized(page, "AXStringForTextMarkerRange", range) as? String == needle { return range }
    }
    return nil
}

switch command {
case "activate":
    emit(["front": activate(argument(1)), "now": frontInfo()])

case "press":
    press(argument(1))
    emit(["pressed": argument(1), "at": Date().timeIntervalSince1970])

case "panel":
    guard let owner = Int32(argument(1)), let budget = Double(argument(3)) else { die("usage: panel <pid> <combo> <s>", 2) }
    func floating() -> CGRect? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for window in windows where window[kCGWindowOwnerPID as String] as? pid_t == owner
            && (window[kCGWindowLayer as String] as? Int ?? 0) == Int(CGWindowLevelForKey(.floatingWindow)) {
            if let bounds = window[kCGWindowBounds as String] as? NSDictionary,
               let box = CGRect(dictionaryRepresentation: bounds) { return box }
        }
        return nil
    }
    let before = floating()
    let started = Date()
    press(argument(2))
    while Date().timeIntervalSince(started) < budget {
        if let box = floating() {
            emit(["seconds": Date().timeIntervalSince(started), "frame": describe(box), "wasShown": before != nil,
                  "at": started.timeIntervalSince1970])
        }
        usleep(2_000)
    }
    emit(["seconds": NSNull(), "wasShown": before != nil, "at": started.timeIntervalSince1970])

case "click":
    guard let x = Double(argument(1)), let y = Double(argument(2)) else { die("usage: click <x> <y>", 2) }
    click(CGPoint(x: x, y: y), right: arguments.count > 3 && arguments[3] == "right")
    emit(["clicked": [x, y]])

case "scroll":
    guard let x = Double(argument(1)), let y = Double(argument(2)), let lines = Int32(argument(3)) else {
        die("usage: scroll <x> <y> <lines>", 2)
    }
    if let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: x, y: y),
                          mouseButton: .left) {
        move.post(tap: .cghidEventTap)
        usleep(80_000)
    }
    for _ in 0..<abs(lines) {
        CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines < 0 ? -1 : 1, wheel2: 0, wheel3: 0)?
            .post(tap: .cghidEventTap)
        usleep(15_000)
    }
    emit(["scrolled": lines])

case "value":
    let app = application(argument(1))
    let focused = element(attribute(app, kAXFocusedUIElementAttribute))
    emit(["value": json(focused.flatMap { string($0, kAXValueAttribute) }),
          "role": json(focused.flatMap { string($0, kAXRoleAttribute) })])

case "select":
    let bundle = argument(1), needle = argument(2)
    guard activate(bundle) else { die("\(bundle) would not come to the front (\(frontInfo()))") }
    let app = application(bundle)
    // A text view: the focused element's value holds the needle; its range is set.
    if let focused = element(attribute(app, kAXFocusedUIElementAttribute)), let value = string(focused, kAXValueAttribute),
       string(focused, kAXRoleAttribute) != "AXWebArea", value.contains(needle) {
        let found = (value as NSString).range(of: needle)
        guard found.location != NSNotFound else { die("the focused text in \(bundle) has no '\(needle)'") }
        var range = CFRange(location: found.location, length: found.length)
        guard let wanted = AXValueCreate(.cfRange, &range) else { die("no range value") }
        let status = AXUIElementSetAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, wanted)
        guard status == .success else { die("setting the selection failed: AXError \(status.rawValue)") }
        usleep(200_000)
        let box = rect(parameterized(focused, kAXBoundsForRangeParameterizedAttribute, wanted))
        emit(["dialect": "range", "selected": json(string(focused, kAXSelectedTextAttribute)),
              "box": json(box.map(describe))])
    }
    // A page: the front window's web area; the needle found in its whole text, selected by markers.
    // Chromium builds its tree a moment after it is asked to (`AXManualAccessibility`): looked for a few seconds.
    var found: AXUIElement?
    for _ in 0..<25 {
        if let window = element(attribute(app, kAXFocusedWindowAttribute)) ?? element(attribute(app, kAXMainWindowAttribute)),
           let area = find(window, { string($0, kAXRoleAttribute) == "AXWebArea" }) {
            found = area
            break
        }
        usleep(200_000)
    }
    // The front window named, so a host's own window in the way (Chrome's profile picker) is told from XDict failing.
    guard let page = found else {
        let window = element(attribute(app, kAXFocusedWindowAttribute)) ?? element(attribute(app, kAXMainWindowAttribute))
        let title = window.flatMap { string($0, kAXTitleAttribute) } ?? ""
        die("\(bundle) shows no text view and no page; its front window is \"\(title)\"")
    }
    var located: (NSRange, CFTypeRef)?
    for _ in 0..<50 {
        if let start = attribute(page, "AXStartTextMarker"), let end = attribute(page, "AXEndTextMarker"),
           let whole = parameterized(page, "AXTextMarkerRangeForUnorderedTextMarkers", [start, end] as CFArray),
           let text = parameterized(page, "AXStringForTextMarkerRange", whole) as? NSString {
            let found = text.range(of: needle)
            // The markers for the needle's place in the page's text, read back to be the needle: Chromium's
            // `AXTextMarkerForIndex` counts the page's text its own way (line breaks between blocks), so the index in
            // `AXStringForTextMarkerRange`'s string can land a few places off, on another line (E2E 2026-10-18: the
            // first line selected for the third). The nearest start and length that read back as the needle are taken.
            if found.location != NSNotFound,
               let markers = verifiedMarkers(page, needle: needle, at: found.location, length: found.length)
                   ?? elementMarkers(page, needle: needle) {
                located = (found, markers)
                break
            }
        }
        usleep(200_000)
    }
    guard let (_, markers) = located else { die("the page in \(bundle) has no '\(needle)'") }
    // Focus into the page first, as a reader's click puts it: a click on the page's own corner, clear of the text.
    if let box = frame(page) { click(CGPoint(x: box.maxX - 30, y: box.maxY - 30)) }
    usleep(300_000)
    let status = AXUIElementSetAttributeValue(page, "AXSelectedTextMarkerRange" as CFString, markers)
    guard status == .success else { die("setting the page's selection failed: AXError \(status.rawValue)") }
    usleep(200_000)
    func selectedNow() -> (String?, CGRect?) {
        guard let now = attribute(page, "AXSelectedTextMarkerRange") else { return (nil, nil) }
        return (parameterized(page, "AXStringForTextMarkerRange", now) as? String,
                rect(parameterized(page, "AXBoundsForTextMarkerRange", now)))
    }
    var (text, box) = selectedNow()
    var how = "markers"
    if text != needle {
        // A host that takes no selection set by markers (Chrome, measured on the E2E Mac, 2026-10-15):
        // the reader's way instead — Find, the text typed, then Escape, which leaves the match selected.
        press("cmd+f")
        usleep(400_000)
        for character in needle {
            let units = Array(String(character).utf16)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                event?.post(tap: .cghidEventTap)
                usleep(15_000)
            }
            usleep(30_000)
        }
        usleep(500_000)
        press("return")
        usleep(300_000)
        press("escape")
        usleep(500_000)
        (text, box) = selectedNow()
        how = "find"
    }
    emit(["dialect": how, "selected": json(text), "box": json(box.map(describe))])

case "context":
    let bundle = argument(1), title = argument(4)
    guard let x = Double(argument(2)), let y = Double(argument(3)) else { die("usage: context <bundle> <x> <y> <title>", 2) }
    let choose = arguments.count > 5 && arguments[5] == "choose"
    let app = application(bundle)
    click(CGPoint(x: x, y: y), right: true)
    func menu() -> AXUIElement? {
        // An open context menu is a child of the element it was opened on — TextEdit's text area (measured on the E2E
        // Mac, 2026-10-15) — so it is looked for in the windows, never the menu bar, as a menu not under a menu item.
        for window in ((attribute(app, kAXWindowsAttribute) as? [CFTypeRef]) ?? []).compactMap(element) {
            if let menu = find(window, limit: 4_000, { node in
                string(node, kAXRoleAttribute) == kAXMenuRole as String
                    && element(attribute(node, kAXParentAttribute)).flatMap { string($0, kAXRoleAttribute) }
                        != kAXMenuItemRole as String
            }) { return menu }
        }
        return children(app).first { string($0, kAXRoleAttribute) == kAXMenuRole as String }
    }
    var open: AXUIElement?
    for _ in 0..<40 {
        open = menu()
        if open != nil { break }
        usleep(100_000)
    }
    guard let open else { press("escape"); die("no context menu opened in \(bundle)") }
    let items = children(open)
    let titles = items.map { string($0, kAXTitleAttribute) ?? "" }
    var placed = "absent", services: [String] = []
    var target = items.first { string($0, kAXTitleAttribute) == title }
    if target != nil { placed = "menu" }
    if target == nil, let item = items.first(where: { string($0, kAXTitleAttribute) == "Services" || string($0, kAXTitleAttribute) == "服务" }) {
        // Open the submenu as a pointer does: over the item.
        if let box = frame(item), let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                                       mouseCursorPosition: CGPoint(x: box.midX, y: box.midY), mouseButton: .left) {
            move.post(tap: .cghidEventTap)
        }
        for _ in 0..<30 {
            if let sub = children(item).first(where: { string($0, kAXRoleAttribute) == kAXMenuRole as String }) {
                let subItems = children(sub)
                services = subItems.map { string($0, kAXTitleAttribute) ?? "" }
                target = subItems.first { string($0, kAXTitleAttribute) == title }
                if target != nil || !services.isEmpty { break }
            }
            usleep(100_000)
        }
        if target != nil { placed = "services" }
    }
    var chosen = false
    if choose, let target {
        chosen = AXUIElementPerformAction(target, kAXPressAction as CFString) == .success
    }
    if !chosen {
        press("escape")
        usleep(150_000)
        if menu() != nil { press("escape") }
    }
    emit(["placed": placed, "chosen": chosen, "items": titles, "services": services])

case "element":
    guard let owner = Int32(argument(1)) else { die("usage: element <pid> <identifier>", 2) }
    let app = AXUIElementCreateApplication(owner)
    AXUIElementSetMessagingTimeout(app, 5)
    let wanted = argument(2)
    for window in ((attribute(app, kAXWindowsAttribute) as? [CFTypeRef]) ?? []).compactMap(element) {
        if let found = find(window, { string($0, "AXIdentifier") == wanted }), let box = frame(found) {
            emit(["frame": describe(box), "role": string(found, kAXRoleAttribute) ?? ""])
        }
    }
    emit(["frame": NSNull()])

case "menubar":
    guard let owner = Int32(argument(1)) else { die("usage: menubar <pid> [title]", 2) }
    let app = AXUIElementCreateApplication(owner)
    AXUIElementSetMessagingTimeout(app, 5)
    guard let extras = element(attribute(app, "AXExtrasMenuBar")), let item = children(extras).first else {
        emit(["item": false])
    }
    let label = string(item, kAXDescriptionAttribute) ?? string(item, kAXTitleAttribute) ?? ""
    AXUIElementPerformAction(item, kAXPressAction as CFString)
    var titles: [String] = []
    var menuItems: [AXUIElement] = []
    for _ in 0..<30 {
        if let menu = children(item).first(where: { string($0, kAXRoleAttribute) == kAXMenuRole as String }) {
            menuItems = children(menu)
            titles = menuItems.map { string($0, kAXTitleAttribute) ?? "" }
            if !titles.isEmpty { break }
        }
        usleep(100_000)
    }
    var chosen = false
    if arguments.count > 2, let target = menuItems.first(where: { (string($0, kAXTitleAttribute) ?? "").hasPrefix(arguments[2]) }) {
        chosen = AXUIElementPerformAction(target, kAXPressAction as CFString) == .success
    } else {
        press("escape")
    }
    emit(["item": true, "label": label, "items": titles, "chosen": chosen])

case "hold":
    let (code, flags) = combo(argument(1))
    guard let seconds = Double(argument(2)) else { die("usage: hold <combo> <seconds>", 2) }
    var modifiers: UInt32 = 0
    if flags.contains(.maskCommand) { modifiers |= UInt32(cmdKey) }
    if flags.contains(.maskAlternate) { modifiers |= UInt32(optionKey) }
    if flags.contains(.maskControl) { modifiers |= UInt32(controlKey) }
    if flags.contains(.maskShift) { modifiers |= UInt32(shiftKey) }
    var reference: EventHotKeyRef?
    let status = RegisterEventHotKey(UInt32(code), modifiers, EventHotKeyID(signature: 0x484E_4453, id: 1),
                                     GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
    print("{\"held\": \(status == noErr), \"status\": \(status)}")
    fflush(stdout)
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    exit(0)

default:
    die("no command \(command)", 2)
}
