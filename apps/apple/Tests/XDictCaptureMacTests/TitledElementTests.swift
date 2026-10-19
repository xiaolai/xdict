import AppKit
import ApplicationServices
import Foundation
import Testing
import XDictCapture
@testable import XDictCaptureMac

/// A synthetic Accessibility tree of controls whose text is only a string — **shaped like what macOS 27.0.1 answered on
/// 2026-10-19** (a menu bar item: `AXTitle`, a 33 pt tall frame, no parameterized attribute; a toolbar whose hit lands on
/// the toolbar while the text is the window's title element beside it; a SwiftUI pop-up button's `AXValue`) — with
/// made-up elements and text, never a capture of anyone's screen. Every element is a fake `AXUIElement` (an application
/// element of a pid nothing runs as); `parameterized` answers nothing, as those controls do.
final class TitledTree: AccessibilityReading, @unchecked Sendable {
    struct Node {
        var role: String
        var subrole: String?
        var title: String?
        var value: String?
        var description: String?
        var placeholder: String?
        var frame: CGRect?
        var children: [AXUIElement] = []
        var window: AXUIElement?
        var parent: AXUIElement?
        var protected = false
        /// A web area's address.
        var url: String?
    }

    private(set) var nodes: [AXUIElement: Node] = [:]
    /// Every text-bearing attribute asked, and of which element: what a refused element must never be asked.
    private(set) var asked: [(element: AXUIElement, name: String)] = []
    var textAsked: [String] { asked.map(\.name) }
    func textAsked(of element: AXUIElement) -> [String] { asked.filter { $0.element == element }.map(\.name) }
    private var nextPid: pid_t = 4_600_000

    @discardableResult
    func add(_ node: Node) -> AXUIElement {
        nextPid += 1
        let element = AXUIElementCreateApplication(nextPid)
        nodes[element] = node
        return element
    }

    func update(_ element: AXUIElement, _ change: (inout Node) -> Void) {
        guard var node = nodes[element] else { return }
        change(&node)
        nodes[element] = node
    }

    func attribute(_ element: AXUIElement, _ name: String, ofApplication: Bool) throws(CaptureError) -> CFTypeRef? {
        guard let node = nodes[element] else { return nil }
        switch name {
        case kAXRoleAttribute: return node.role as CFString
        case kAXSubroleAttribute: return node.subrole as CFString?
        case kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute,
             kAXNumberOfCharactersAttribute, kAXSelectedTextAttribute:
            asked.append((element, name))
            switch name {
            case kAXTitleAttribute: return node.title as CFString?
            case kAXValueAttribute: return node.value as CFString?
            case kAXDescriptionAttribute: return node.description as CFString?
            case kAXPlaceholderValueAttribute: return node.placeholder as CFString?
            default: return nil
            }
        case "AXContainsProtectedContent": return node.protected ? kCFBooleanTrue : nil
        case kAXURLAttribute: return node.url as CFString?
        case kAXChildrenAttribute: return node.children as CFArray
        case kAXWindowAttribute: return node.window
        case kAXParentAttribute: return node.parent
        case kAXPositionAttribute:
            guard var origin = node.frame?.origin else { return nil }
            return AXValueCreate(.cgPoint, &origin)
        case kAXSizeAttribute:
            guard var size = node.frame?.size else { return nil }
            return AXValueCreate(.cgSize, &size)
        default: return nil
        }
    }

    func parameterized(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) throws(CaptureError) -> CFTypeRef? {
        asked.append((element, name))
        return nil
    }
}

/// **Where a title answers, and where it is left to the pixels.** The geometry each test answers in is the rule's own
/// (`ElementTitle`: every placement and size must agree), measured by sweeping these frames on 2026-10-19 and listed
/// beside each test; `TitleOracleTests` holds the rule to the truth, these hold the reader's wiring and its refusals.
struct TitledElementTests {
    private let target = { (element: AXUIElement) in
        PointerWordReader.Target(element: element, appName: "Sample", bundleID: "com.example.sample")
    }

    private func read(
        _ tree: TitledTree, _ element: AXUIElement, at point: CGPoint, refuses: (HostReading) -> Bool = { _ in false }
    ) -> PointerWordReader.Outcome {
        switch PointerWordReader.readUnlessRefused(at: point, in: target(element), tolerance: Measured.hit,
                                                   labels: Measured.label, refuses: refuses, with: tree) {
        case .read(let outcome): outcome
        case .refused(let host): .miss(.noText(app: "refused \(host)", role: nil))
        }
    }

    private func width(of text: String, style: ElementTitle.Style) throws -> CGFloat {
        let font = try #require(style.font)
        return try #require(ElementTitle.Layout(text, font: font)).width
    }

    /// A frame `pad` wider than `text` in `style`'s font, its width rounded up as a view's is.
    private func frame(
        _ text: String, _ style: ElementTitle.Style, pad: CGFloat, x: CGFloat, y: CGFloat, height: CGFloat
    ) throws -> CGRect {
        CGRect(x: x, y: y, width: (try width(of: text, style: style) + pad).rounded(.up), height: height)
    }

    private func word(_ outcome: PointerWordReader.Outcome) -> String? {
        guard case .hit(let hit) = outcome else { return nil }
        return hit.word.word
    }

    /// Every half point across `frame` and 4 pt beyond, at its middle: the words answered.
    private func answers(_ tree: TitledTree, _ element: AXUIElement, across frame: CGRect) -> Set<String> {
        Set(stride(from: frame.minX - 4, through: frame.maxX + 4, by: 0.5).compactMap {
            word(read(tree, element, at: CGPoint(x: $0, y: frame.midY)))
        })
    }

    // MARK: - Menus

    /// **A menu bar item's title is read** (owner's report, 2026-10-19: titles in the menu bar were "No word found
    /// here"; the item answered `AXTitle` only). The sentence is the title, the acquisition says it came from a title,
    /// and the box is the pointer's placement — no box was measured. Above the line's height, nothing. (W+8: "Bookmarks"
    /// answers over 22…54.)
    @Test func aMenuBarItemsTitleIsRead() throws {
        let tree = TitledTree()
        let box = try frame("Bookmarks", .menuBar, pad: 8, x: 99, y: 0, height: 33)
        let item = tree.add(.init(role: "AXMenuBarItem", title: "Bookmarks", frame: box))
        let point = CGPoint(x: box.minX + 38, y: box.midY)
        let outcome = read(tree, item, at: point)
        guard case .hit(let hit) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(hit.word.word == "Bookmarks")
        #expect(hit.word.sentence.text == "Bookmarks")
        #expect(hit.acquisition == .elementTitle)
        #expect(hit.bounds == nil)
        let down = DownPoint(x: Double(point.x), y: Double(point.y))
        let term = try hit.capturedTerm(pointer: PointerSample(point: down, at: nil))
        #expect(term.box == .clickPlacement(down))
        // Inside the frame, above the line.
        #expect(word(read(tree, item, at: CGPoint(x: point.x, y: box.minY + 2))) == nil)
    }

    /// **A title shorter than the placements can move it is left to the pixels** (a gap, not a guess): "File" is 21 pt
    /// wide, and a label pushed 12 pt either way moves further than that — so no point of it answers.
    @Test func aShortTitleIsLeftToThePixels() {
        let tree = TitledTree()
        let box = CGRect(x: 99, y: 0, width: 42, height: 33)
        let item = tree.add(.init(role: "AXMenuBarItem", title: "File", frame: box))
        #expect(answers(tree, item, across: box).isEmpty)
    }

    /// **The Apple menu is a logo, not a word**: refused by name, however its frame is measured.
    @Test func theAppleMenuIsNeverAWord() throws {
        let tree = TitledTree()
        for pad: CGFloat in [-1, 8, 40] {
            let box = try frame("Apple", .menuBar, pad: pad, x: 0, y: 0, height: 33)
            let apple = tree.add(.init(role: "AXMenuBarItem", title: "Apple", frame: box))
            #expect(answers(tree, apple, across: box).isEmpty, "pad \(pad)")
        }
    }

    /// **A title of several words: a word only where every placement puts the pointer in it** (W+8: "Bambu" answers
    /// over 28.5…33, "Studio" over 67.5…71.5, "Extras" nowhere, its placements disagreeing). 20 pt wider, nothing.
    @Test func wordsOfATitleAreReadOnlyWhereEveryPlacementAgrees() throws {
        let text = "Bambu Studio Extras"
        let tree = TitledTree()
        let box = try frame(text, .menuBar, pad: 8, x: 43, y: 0, height: 33)
        let item = tree.add(.init(role: "AXMenuBarItem", title: text, frame: box))
        #expect(word(read(tree, item, at: CGPoint(x: box.minX + 30.5, y: box.midY))) == "Bambu")
        #expect(word(read(tree, item, at: CGPoint(x: box.minX + 69.5, y: box.midY))) == "Studio")
        #expect(answers(tree, item, across: box) == ["Bambu", "Studio"])
        let roomy = try frame(text, .menuBar, pad: 20, x: 43, y: 40, height: 33)
        let wide = tree.add(.init(role: "AXMenuBarItem", title: text, frame: roomy))
        #expect(answers(tree, wide, across: roomy).isEmpty)
    }

    /// Outside the drawn text, nothing — never the nearest word; and in a button far wider than its label, where the
    /// padding decides the place, nothing anywhere. (W+8: "Dictionaries" answers over 22…58.)
    @Test func aPointerBesideTheTextReadsNothing() throws {
        let tree = TitledTree()
        let box = try frame("Dictionaries", .control, pad: 8, x: 100, y: 100, height: 24)
        let button = tree.add(.init(role: "AXButton", title: "Dictionaries", frame: box))
        #expect(word(read(tree, button, at: CGPoint(x: box.minX + 40, y: box.midY))) == "Dictionaries")
        #expect(word(read(tree, button, at: CGPoint(x: box.minX + 2, y: box.midY))) == nil)
        #expect(word(read(tree, button, at: CGPoint(x: box.midX, y: box.maxY + 20))) == nil)
        let roomy = try frame("Done", .control, pad: 80, x: 100, y: 200, height: 24)
        let done = tree.add(.init(role: "AXButton", title: "Done", frame: roomy))
        #expect(answers(tree, done, across: roomy).isEmpty)
    }

    /// **A label not narrower than its frame by the tolerance is not known to be drawn there as one line** (truncated,
    /// wrapped, or not in this font): nothing is read from it, rather than a word placed where the text is not.
    @Test func aLabelNotNarrowerThanItsFrameReadsNothing() throws {
        let tree = TitledTree()
        let text = "Extraordinarily long label"
        let half = CGRect(x: 100, y: 100, width: try width(of: text, style: .control) / 2, height: 24)
        let button = tree.add(.init(role: "AXButton", title: text, frame: half))
        #expect(answers(tree, button, across: half).isEmpty)
        let exact = try frame("Collins", .control, pad: 0, x: 10, y: 10, height: 22)
        let popUp = tree.add(.init(role: "AXPopUpButton", value: "Collins", frame: exact))
        #expect(answers(tree, popUp, across: exact).isEmpty)
    }

    /// **A menu item: wherever its inset puts it.** In a tight frame "Recent" answers over 53…64.5; in a frame 40 pt
    /// wider than its title, where the inset nobody reports decides, nothing is read here (the pixels answer it).
    @Test func aMenuItemIsReadOnlyWhereEveryInsetAgrees() throws {
        let text = "Open Recent"
        let tree = TitledTree()
        let tight = try frame(text, .menu, pad: 8, x: 200, y: 50, height: 22)
        let fitted = tree.add(.init(role: "AXMenuItem", title: text, frame: tight))
        #expect(word(read(tree, fitted, at: CGPoint(x: tight.minX + 58, y: tight.midY))) == "Recent")
        let roomy = try frame(text, .menu, pad: 40, x: 200, y: 80, height: 22)
        let wide = tree.add(.init(role: "AXMenuItem", title: text, frame: roomy))
        #expect(answers(tree, wide, across: roomy).isEmpty)
    }

    // MARK: - Controls

    /// **A pop-up button shows its value** (a SwiftUI picker: `AXValue`, no title; a chevron beside it, W+24: answers
    /// over 31…34), and a radio button (a tab, a segment) its title in a tight frame; a tab much wider than its title
    /// reads nothing.
    @Test func aPopUpButtonsValueAndATabsTitleAreRead() throws {
        let tree = TitledTree()
        let picker = try frame("Collins", .control, pad: 24, x: 10, y: 10, height: 22)
        let popUp = tree.add(.init(role: "AXPopUpButton", value: "Collins", frame: picker))
        #expect(word(read(tree, popUp, at: CGPoint(x: picker.minX + 32.5, y: picker.midY))) == "Collins")
        let tabFrame = try frame("General", .control, pad: 10, x: 300, y: 10, height: 28)
        let tab = tree.add(.init(role: "AXRadioButton", subrole: "AXTabButton", title: "General", frame: tabFrame))
        #expect(word(read(tree, tab, at: CGPoint(x: tabFrame.midX, y: tabFrame.midY))) == "General")
        let roomy = try frame("General", .control, pad: 40, x: 300, y: 50, height: 28)
        let wideTab = tree.add(.init(role: "AXRadioButton", subrole: "AXTabButton", title: "General", frame: roomy))
        #expect(answers(tree, wideTab, across: roomy).isEmpty)
    }

    /// **An icon's spoken label is not text on screen**: a toolbar button with only `AXDescription` ("Back", as XDict's
    /// own toolbar answers) reads nothing, and its description is never asked.
    @Test func anIconButtonsDescriptionIsNeverRead() {
        let tree = TitledTree()
        let button = tree.add(.init(role: "AXButton", subrole: "AXSegment", title: "", description: "Back",
                                    frame: CGRect(x: 590, y: 418, width: 36, height: 36)))
        #expect(word(read(tree, button, at: CGPoint(x: 608, y: 436))) == nil)
        #expect(!tree.textAsked.contains(kAXDescriptionAttribute))
    }

    // MARK: - Containers

    /// **A hit on a container is descended to the child under the pointer** (the owner's log: `AXMenuBar`, `AXToolbar`):
    /// a menu bar's item.
    @Test func aMenuBarHitIsDescendedToItsItem() throws {
        let tree = TitledTree()
        let first = try frame("Bookmarks", .menuBar, pad: 8, x: 99, y: 0, height: 33)
        let second = try frame("History", .menuBar, pad: 8, x: first.maxX, y: 0, height: 33)
        let bookmarks = tree.add(.init(role: "AXMenuBarItem", title: "Bookmarks", frame: first))
        let history = tree.add(.init(role: "AXMenuBarItem", title: "History", frame: second))
        let bar = tree.add(.init(role: "AXMenuBar", frame: CGRect(x: 0, y: 0, width: 1728, height: 33),
                                 children: [bookmarks, history]))
        #expect(word(read(tree, bar, at: CGPoint(x: second.midX, y: second.midY))) == "History")
    }

    /// **A toolbar hit whose text is the window's title beside it**: the toolbar has no child there, so the window is
    /// descended — the title element is the window's, not the toolbar's (as XDict's window answers).
    @Test func aToolbarHitIsReadThroughItsWindow() throws {
        let tree = TitledTree()
        let text = "Lexicon"
        let titleFrame = try frame(text, .control, pad: 8, x: 667, y: 426, height: 19)
        let title = tree.add(.init(role: "AXStaticText", value: text, frame: titleFrame))
        let back = tree.add(.init(role: "AXButton", description: "Back", frame: CGRect(x: 590, y: 418, width: 36, height: 36)))
        let toolbar = tree.add(.init(role: "AXToolbar", frame: CGRect(x: 494, y: 410, width: 810, height: 52),
                                     children: [back]))
        let window = tree.add(.init(role: "AXWindow", frame: CGRect(x: 494, y: 410, width: 810, height: 545),
                                    children: [toolbar, title]))
        tree.update(toolbar) { $0.window = window }
        #expect(word(read(tree, toolbar, at: CGPoint(x: titleFrame.midX, y: titleFrame.midY))) == "Lexicon")
        // The miss names the role the read ended on, so the next log tells where it stopped.
        let empty = read(tree, toolbar, at: CGPoint(x: 1290, y: 436))
        #expect(empty == .miss(.noText(app: "Sample", role: "AXToolbar")))
    }

    /// **The element a container is descended to is checked for its site again** — a window holding an excluded page:
    /// the window itself is no web content, its page is. The page's text is refused, and never asked.
    @Test func anElementReachedByDescentIsCheckedForItsSite() throws {
        let tree = TitledTree()
        let text = "Lexicon"
        let textFrame = try frame(text, .control, pad: 8, x: 40, y: 140, height: 19)
        let app = tree.add(.init(role: kAXApplicationRole))
        let window = tree.add(.init(role: "AXWindow", frame: CGRect(x: 0, y: 0, width: 800, height: 600), parent: app))
        let page = tree.add(.init(role: "AXWebArea", frame: CGRect(x: 0, y: 100, width: 800, height: 500), parent: window,
                                  url: "https://blocked.example/entry"))
        let label = tree.add(.init(role: "AXStaticText", value: text, frame: textFrame, parent: page))
        tree.update(window) { $0.children = [page] }
        tree.update(page) { $0.children = [label] }
        let blocked = { (site: HostReading) in site == .known("blocked.example") }
        let outcome = PointerWordReader.readUnlessRefused(
            at: CGPoint(x: textFrame.midX, y: textFrame.midY), in: target(window), tolerance: Measured.hit,
            labels: Measured.label, refuses: blocked, with: tree)
        #expect(outcome == .refused(.known("blocked.example")))
        #expect(tree.textAsked(of: label).isEmpty, "asked \(tree.textAsked(of: label))")
        // The control: the same tree with nothing excluded reads the label.
        #expect(word(read(tree, window, at: CGPoint(x: textFrame.midX, y: textFrame.midY))) == text)
    }

    /// A list row whose text is its cell's: the row is descended to the text inside it.
    @Test func aListRowIsReadThroughItsCell() throws {
        let tree = TitledTree()
        let text = "Thesaurus"
        let labelFrame = try frame(text, .control, pad: 8, x: 20, y: 102, height: 16)
        let label = tree.add(.init(role: "AXStaticText", value: text, frame: labelFrame))
        let cell = tree.add(.init(role: "AXCell", frame: CGRect(x: 10, y: 100, width: 200, height: 20), children: [label]))
        let row = tree.add(.init(role: "AXRow", frame: CGRect(x: 0, y: 100, width: 220, height: 20), children: [cell]))
        #expect(word(read(tree, row, at: CGPoint(x: labelFrame.midX, y: labelFrame.midY))) == "Thesaurus")
    }

    // MARK: - Scripts

    /// A right-to-left title: the word under the pointer, laid out right to left (W+8: "قاموس" answers over 45.5…51.5).
    /// A CJK title's words are narrower than the placements can move, so it is left to the pixels — a gap, not a guess.
    @Test func rightToLeftTitlesAreReadAndCJKOnesLeftToThePixels() throws {
        let tree = TitledTree()
        let arabic = "قاموس عربي"
        let rtlFrame = try frame(arabic, .menuBar, pad: 8, x: 0, y: 0, height: 33)
        let rtl = tree.add(.init(role: "AXMenuBarItem", title: arabic, frame: rtlFrame))
        #expect(word(read(tree, rtl, at: CGPoint(x: rtlFrame.minX + 48.5, y: rtlFrame.midY))) == "قاموس")
        #expect(answers(tree, rtl, across: rtlFrame) == ["قاموس"])
        let chinese = "牛津词典"
        let cjkFrame = try frame(chinese, .menuBar, pad: 8, x: 0, y: 40, height: 33)
        let cjk = tree.add(.init(role: "AXMenuBarItem", title: chinese, frame: cjkFrame))
        #expect(answers(tree, cjk, across: cjkFrame).isEmpty)
    }

    // MARK: - Secure fields

    /// **A secure field is never read** — not its value, not its title, not its placeholder, not its text range: refused
    /// before any text attribute is asked, by its subrole or by the protected-content flag.
    @Test func aSecureFieldIsNeverRead() {
        for (subrole, protected) in [(Optional(kAXSecureTextFieldSubrole), false), (nil, true)] {
            let tree = TitledTree()
            let field = tree.add(.init(role: "AXTextField", subrole: subrole, title: "Password", value: "hunter2",
                                       placeholder: "Password", frame: CGRect(x: 0, y: 0, width: 200, height: 22),
                                       protected: protected))
            let outcome = read(tree, field, at: CGPoint(x: 10, y: 11))
            #expect(word(outcome) == nil)
            #expect(tree.textAsked.isEmpty, "asked \(tree.textAsked)")
        }
    }

    /// And a secure field reached by descending a container is refused the same way.
    @Test func aSecureFieldReachedByDescentIsNeverRead() {
        let tree = TitledTree()
        let field = tree.add(.init(role: "AXTextField", subrole: kAXSecureTextFieldSubrole, title: "Secret",
                                   value: "hunter2", frame: CGRect(x: 0, y: 0, width: 200, height: 22)))
        let group = tree.add(.init(role: "AXGroup", frame: CGRect(x: 0, y: 0, width: 400, height: 100), children: [field]))
        #expect(word(read(tree, group, at: CGPoint(x: 10, y: 11))) == nil)
        #expect(tree.textAsked(of: field).isEmpty, "asked \(tree.textAsked(of: field))")
    }
}
