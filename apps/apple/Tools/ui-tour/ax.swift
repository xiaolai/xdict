// ax: the UI tour's eyes on XDict (Tools/ui-tour/tour.py), through the Accessibility API and the window list. Run on
// the E2E Mac only, compiled there by tour.py (`swiftc -O ax.swift`); never on the build Mac, whose screen is the owner's.
// Every command prints one JSON object.
//
//   ax windows <pid>                    the app's on-screen windows: CGWindowID, layer, bounds (top-left origin),
//                                       the backing scale factor of the screen they are on
//   ax tree <pid>                       every AX window of the app (and its menu bar's open menu, if any) as a tree:
//                                       role, subrole, title, description, value, identifier, help, enabled, frame
//                                       (screen points); a text's font runs (name, size) or "not exposed"; what a
//                                       button shows ("text", "image", "both")
//   ax press <pid> <match>...           AXPress on the first element, in any window, whose identifier, title or
//                                       description equals one of the matches
//   ax click <pid> <match>...           a real click (HID) at the centre of that element
//   ax menu <pid> <index> [<title>...]  the menu bar item at <index> (0 = Apple); with titles, the item path chosen
//                                       (each title may be "a|b" for alternatives); without, the menu left open
//   ax menubar <pid>                    every menu bar item and its items' titles (one level of submenus)
//   ax reset <pid>                      every window but the main one closed by its close button
//   ax key <combo>                      one key with modifiers (cmd, opt, shift, ctrl), US layout: letters, digits,
//                                       = - [ ] , . / and return, tab, space, escape, arrows
//   ax extra <pid>                    the app's menu-bar extra opened (AXExtrasMenuBar), left open
//   ax at <pid> <x> <y>                 the element under a point (global top-left), as `tree` writes one
//
// The grant: started over SSH, TCC judges it as `sshd-keygen-wrapper`, which holds Accessibility on the E2E Mac. Without
// it every command refuses (exit 3), since an unread tree reads as an empty window.
import AppKit
import ApplicationServices

func emit(_ object: Any) -> Never {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
    exit(0)
}

func fail(_ why: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("ax: \(why)\n".utf8))
    exit(code)
}

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func string(_ element: AXUIElement, _ name: String) -> String? {
    guard let value = attribute(element, name) else { return nil }
    if let text = value as? String { return text }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func frame(_ element: AXUIElement) -> [Double]? {
    var point = CGPoint.zero, size = CGSize.zero
    guard let p = attribute(element, kAXPositionAttribute), let s = attribute(element, kAXSizeAttribute),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    AXValueGetValue(p as! AXValue, .cgPoint, &point)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    return [point.x, point.y, size.width, size.height].map { Double($0) }
}

var budget = 6000

/// The font of a text's first run, as Accessibility gives it (`AXAttributedStringForRange` over its whole value); a
/// sentence saying so where it does not.
func font(_ element: AXUIElement) -> Any {
    guard let count = attribute(element, kAXNumberOfCharactersAttribute) as? Int, count > 0 else { return "not exposed" }
    var range = CFRange(location: 0, length: min(count, 2_000))
    guard let rangeValue = AXValueCreate(.cfRange, &range) else { return "not exposed" }
    var value: AnyObject?
    guard AXUIElementCopyParameterizedAttributeValue(element, kAXAttributedStringForRangeParameterizedAttribute as CFString,
                                                     rangeValue, &value) == .success,
          let text = value as? NSAttributedString, text.length > 0 else { return "not exposed" }
    var runs: [[String: Any]] = []
    text.enumerateAttribute(NSAttributedString.Key("AXFont"),
                            in: NSRange(location: 0, length: text.length)) { attr, range, _ in
        guard let info = attr as? [String: Any], runs.count < 4 else { return }
        runs.append(["name": info["AXFontName"] ?? "", "size": info["AXFontSize"] ?? 0,
                     "length": range.length])
    }
    return runs.isEmpty ? "not exposed" : runs
}

func node(_ element: AXUIElement, depth: Int) -> [String: Any] {
    budget -= 1
    var out: [String: Any] = [:]
    let role = string(element, kAXRoleAttribute) ?? ""
    out["role"] = role
    for (key, name) in [("subrole", kAXSubroleAttribute), ("title", kAXTitleAttribute),
                        ("description", kAXDescriptionAttribute), ("identifier", kAXIdentifierAttribute),
                        ("help", kAXHelpAttribute), ("placeholder", kAXPlaceholderValueAttribute)] {
        if let text = string(element, name), !text.isEmpty { out[key] = text }
    }
    if let value = string(element, kAXValueAttribute), !value.isEmpty { out["value"] = String(value.prefix(300)) }
    if let enabled = attribute(element, kAXEnabledAttribute) as? Bool, !enabled { out["enabled"] = false }
    if let box = frame(element) { out["frame"] = box }
    let kids = children(element)
    if role == "AXStaticText" || role == "AXTextField" { out["font"] = font(element) }
    if role == "AXButton" || role == "AXPopUpButton" || role == "AXMenuButton" || role == "AXRadioButton" {
        let roles = Set(kids.compactMap { string($0, kAXRoleAttribute) })
        let text = !(string(element, kAXTitleAttribute) ?? "").isEmpty || roles.contains("AXStaticText")
        let image = roles.contains("AXImage")
        out["shows"] = text && image ? "both" : text ? "text" : image ? "image" : "unknown (no text or image child)"
    }
    // An entry's page is the web view's to draw; its elements are counted, not walked.
    if role == "AXWebArea" {
        out["childCount"] = kids.count
    } else if depth < 60, budget > 0, !kids.isEmpty {
        out["children"] = kids.map { node($0, depth: depth + 1) }
    }
    return out
}

func appElement(_ pid: pid_t) -> AXUIElement {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 2)
    return app
}

func find(_ root: AXUIElement, _ matches: Set<String>, depth: Int = 0) -> AXUIElement? {
    for key in [kAXIdentifierAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
        if let text = string(root, key), matches.contains(text) { return root }
    }
    guard depth < 60, string(root, kAXRoleAttribute) != "AXWebArea" else { return nil }
    for child in children(root) {
        if let hit = find(child, matches, depth: depth + 1) { return hit }
    }
    return nil
}

func windows(_ app: AXUIElement) -> [AXUIElement] {
    (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
}

func clickAt(_ x: Double, _ y: Double) {
    let point = CGPoint(x: x, y: y)
    for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        usleep(type == .mouseMoved ? 80_000 : 40_000)
    }
}

func menuItems(_ menu: AXUIElement, depth: Int) -> [[String: Any]] {
    children(menu).filter { string($0, kAXRoleAttribute) == "AXMenuItem" }.map { item in
        var out: [String: Any] = ["title": string(item, kAXTitleAttribute) ?? ""]
        if let key = string(item, "AXMenuItemCmdChar"), !key.isEmpty { out["key"] = key }
        if let mods = attribute(item, "AXMenuItemCmdModifiers") as? Int { out["mods"] = mods }
        if let enabled = attribute(item, kAXEnabledAttribute) as? Bool, !enabled { out["enabled"] = false }
        if depth < 1, let sub = children(item).first(where: { string($0, kAXRoleAttribute) == "AXMenu" }) {
            out["items"] = menuItems(sub, depth: depth + 1)
        }
        return out
    }
}

/// ANSI key codes of the US layout, for `key`.
let keyCodes: [String: CGKeyCode] = {
    var table: [String: CGKeyCode] = ["return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53, "left": 123,
                                      "right": 124, "down": 125, "up": 126, "=": 24, "-": 27, "[": 33, "]": 30,
                                      ",": 43, ".": 47, "/": 44, ";": 41, "'": 39, "`": 50, "\\": 42]
    let letters = "asdfhgzxcv_bqweryt123465_97_80_ou_ip_lj_k____nm"
    for (code, char) in letters.enumerated() where char != "_" { table[String(char)] = CGKeyCode(code) }
    return table
}()

/// One key with modifiers ("cmd+opt+p", "ctrl+opt+d", "cmd+,"), posted into the HID stream.
func press(_ combo: String) {
    var parts = combo.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
    if combo.hasSuffix("++") { parts = Array(parts.dropLast(2)) + ["="] }
    guard let name = parts.last, let code = keyCodes[name] else { fail("no key \(combo)") }
    var flags = CGEventFlags()
    for modifier in parts.dropLast() {
        switch modifier {
        case "cmd": flags.insert(.maskCommand)
        case "opt": flags.insert(.maskAlternate)
        case "shift": flags.insert(.maskShift)
        case "ctrl": flags.insert(.maskControl)
        default: fail("no modifier \(modifier)")
        }
    }
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
        usleep(30_000)
    }
}

let arguments = CommandLine.arguments
if arguments.count == 3, arguments[1] == "key" {
    guard AXIsProcessTrusted() else { fail("this session holds no Accessibility grant", code: 3) }
    press(arguments[2])
    emit(["pressed": arguments[2]])
}
guard arguments.count >= 3, let pidNumber = Int32(arguments[2]) else {
    fail("usage: ax windows|tree|press|click|menu|menubar|extra <pid> …", code: 2)
}
guard AXIsProcessTrusted() else { fail("this session holds no Accessibility grant", code: 3) }
let pid = pid_t(pidNumber)
let app = appElement(pid)

switch arguments[1] {
case "windows":
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]]) ?? []
    let mine = list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }.map { info -> [String: Any] in
        let bounds = info[kCGWindowBounds as String] as? [String: Double] ?? [:]
        let box = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0,
                         height: bounds["Height"] ?? 0)
        // NSScreen frames are bottom-left; the main screen's height flips them to the window list's top-left.
        let top = NSScreen.screens.first?.frame.height ?? 0
        let screen = NSScreen.screens.first { screen in
            let f = screen.frame
            return CGRect(x: f.minX, y: top - f.maxY, width: f.width, height: f.height).contains(CGPoint(x: box.midX, y: box.midY))
        }
        return ["id": info[kCGWindowNumber as String] ?? 0, "scale": screen?.backingScaleFactor ?? 0, "layer": info[kCGWindowLayer as String] ?? 0,
                "name": info[kCGWindowName as String] ?? "", "alpha": info[kCGWindowAlpha as String] ?? 1,
                "frame": [bounds["X"] ?? 0, bounds["Y"] ?? 0, bounds["Width"] ?? 0, bounds["Height"] ?? 0]]
    }
    emit(["windows": mine])
case "tree":
    var out: [[String: Any]] = windows(app).map { node($0, depth: 0) }
    if let bar = attribute(app, kAXMenuBarAttribute) {
        for item in children(bar as! AXUIElement) where (attribute(item, kAXSelectedAttribute) as? Bool) == true {
            out.append(node(item, depth: 0))
        }
    }
    if let extras = attribute(app, "AXExtrasMenuBar") {
        for item in children(extras as! AXUIElement) {
            let menus = children(item).filter { string($0, kAXRoleAttribute) == "AXMenu" }
            if !menus.isEmpty { out.append(node(item, depth: 0)) }
        }
    }
    emit(["windows": out, "truncated": budget <= 0])
case "press", "click":
    let matches = Set(arguments.dropFirst(3))
    guard let hit = windows(app).lazy.compactMap({ find($0, matches) }).first else {
        fail("no element matching \(matches.sorted()) in any window")
    }
    if arguments[1] == "press" {
        let result = AXUIElementPerformAction(hit, kAXPressAction as CFString)
        guard result == .success || result == .cannotComplete else { fail("AXPress failed: \(result.rawValue)") }
        emit(["pressed": string(hit, kAXRoleAttribute) ?? ""])
    }
    guard let box = frame(hit) else { fail("the element has no frame") }
    clickAt(box[0] + box[2] / 2, box[1] + box[3] / 2)
    emit(["clicked": box])
case "menu":
    guard arguments.count >= 4, let index = Int(arguments[3]),
          let barObject = attribute(app, kAXMenuBarAttribute) else { fail("no menu bar, or no index") }
    let items = children(barObject as! AXUIElement)
    guard index >= 0, index < items.count else { fail("menu bar has \(items.count) items, not \(index + 1)") }
    var current = items[index]
    let path = Array(arguments.dropFirst(4))
    if path.isEmpty {
        _ = AXUIElementPerformAction(current, kAXPressAction as CFString)
        emit(["opened": string(current, kAXTitleAttribute) ?? ""])
    }
    for (step, wanted) in path.enumerated() {
        let options = Set(wanted.split(separator: "|").map(String.init))
        let menu = children(current).first(where: { string($0, kAXRoleAttribute) == "AXMenu" })
        let entries = menu.map(children)?.filter { string($0, kAXRoleAttribute) == "AXMenuItem" } ?? []
        // "#n" picks the n-th item (0-based), for items whose titles the system localizes (About XDict).
        let byIndex = wanted.hasPrefix("#") ? Int(wanted.dropFirst()).flatMap { $0 < entries.count ? entries[$0] : nil } : nil
        guard let item = byIndex ?? entries.first(where: { options.contains(string($0, kAXTitleAttribute) ?? "") })
        else {
            fail("no menu item \(wanted) at step \(step + 1) under \(string(current, kAXTitleAttribute) ?? "?")")
        }
        current = item
    }
    let result = AXUIElementPerformAction(current, kAXPressAction as CFString)
    guard result == .success || result == .cannotComplete else { fail("AXPress on the item failed: \(result.rawValue)") }
    emit(["chose": path])
case "menubar":
    guard let barObject = attribute(app, kAXMenuBarAttribute) else { fail("no menu bar") }
    let bar = children(barObject as! AXUIElement).map { item -> [String: Any] in
        let menu = children(item).first(where: { string($0, kAXRoleAttribute) == "AXMenu" })
        return ["title": string(item, kAXTitleAttribute) ?? "", "items": menu.map { menuItems($0, depth: 0) } ?? []]
    }
    emit(["menubar": bar])
case "reset":
    // Every window but the main one closed (the main window's search field holds the `scope.menu` button), by its own
    // close button.
    var closed = 0
    for window in windows(app) where find(window, ["scope.menu"]) == nil {
        if let button = attribute(window, kAXCloseButtonAttribute) {
            if AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success { closed += 1 }
        }
    }
    emit(["closed": closed])
case "size":
    // The main window (the one holding the `scope.menu` button) set to a width and height in points: the routes at the
    // window's minimum width.
    guard arguments.count == 5, let width = Double(arguments[3]), let height = Double(arguments[4]) else {
        fail("size <pid> <width> <height>", code: 2)
    }
    guard let main = windows(app).first(where: { find($0, ["scope.menu"]) != nil }) else { fail("no main window") }
    var size = CGSize(width: width, height: height)
    guard let value = AXValueCreate(.cgSize, &size),
          AXUIElementSetAttributeValue(main, kAXSizeAttribute as CFString, value) == .success else {
        fail("the main window's size could not be set")
    }
    emit(["size": [width, height]])
case "extra":
    guard let extras = attribute(app, "AXExtrasMenuBar"),
          let item = children(extras as! AXUIElement).first else { fail("the app shows no menu-bar extra") }
    _ = AXUIElementPerformAction(item, kAXPressAction as CFString)
    emit(["opened": frame(item) ?? []])
case "at":
    // What is under a point (global top-left): a refused drop names what it landed on.
    guard arguments.count >= 5, let x = Float(arguments[3]), let y = Float(arguments[4]) else {
        fail("usage: ax at <pid> <x> <y>", code: 2)
    }
    var hit: AXUIElement?
    let result = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), x, y, &hit)
    guard result == .success, let hit else { emit(["at": [x, y], "element": NSNull()]) }
    emit(["at": [x, y], "element": node(hit, depth: 59)])
default:
    fail("unknown command \(arguments[1])", code: 2)
}
