import ApplicationServices
import CoreText
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

struct TitledElementTests {
    private let target = { (element: AXUIElement) in
        PointerWordReader.Target(element: element, appName: "Sample", bundleID: "com.example.sample")
    }

    private func read(_ tree: TitledTree, _ element: AXUIElement, at point: CGPoint) -> PointerWordReader.Outcome {
        switch PointerWordReader.readUnlessRefused(at: point, in: target(element), tolerance: Measured.hit,
                                                   refuses: { _ in false }, with: tree) {
        case .read(let outcome): outcome
        case .refused(let host): .miss(.noText(app: "refused \(host)", role: nil))
        }
    }

    /// The x where `word` of `text` starts and ends when `text` is laid out in `style`'s font from x = 0.
    private func span(of word: String, in text: String, style: ElementTitle.Style) throws -> ClosedRange<CGFloat> {
        let font = try #require(style.font)
        let layout = try #require(ElementTitle.Layout(text, font: font))
        let range = try #require(text.range(of: word))
        return layout.span(of: range, in: text)
    }

    private func width(of text: String, style: ElementTitle.Style) throws -> CGFloat {
        let font = try #require(style.font)
        return try #require(ElementTitle.Layout(text, font: font)).width
    }

    private func word(_ outcome: PointerWordReader.Outcome) -> String? {
        guard case .hit(let hit) = outcome else { return nil }
        return hit.word.word
    }

    // MARK: - Menus

    /// **A menu bar item's title is read** (owner's report, 2026-10-19: "File" in the menu bar was "No word found here";
    /// the item answered `AXTitle` only). The sentence is the title, the acquisition says it came from a title, and the
    /// box is the pointer's placement — no box was measured.
    @Test func aMenuBarItemsTitleIsRead() throws {
        let tree = TitledTree()
        let item = tree.add(.init(role: "AXMenuBarItem", title: "File", frame: CGRect(x: 99, y: 0, width: 42, height: 33)))
        let outcome = read(tree, item, at: CGPoint(x: 120, y: 15))
        guard case .hit(let hit) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(hit.word.word == "File")
        #expect(hit.word.sentence.text == "File")
        #expect(hit.acquisition == .elementTitle)
        #expect(hit.bounds == nil)
        let term = try hit.capturedTerm(pointer: PointerSample(point: DownPoint(x: 120, y: 15), at: nil))
        #expect(term.box == .clickPlacement(DownPoint(x: 120, y: 15)))
    }

    /// **A title of several words: the word under the pointer, each in turn** — a centred menu bar title placed by its
    /// font's own metrics.
    @Test func eachWordOfACentredTitleIsReadWhereItIs() throws {
        let text = "Bambu Studio Extras"
        let tree = TitledTree()
        let frame = CGRect(x: 43, y: 0, width: try width(of: text, style: .menuBar) + 20, height: 33)
        let item = tree.add(.init(role: "AXMenuBarItem", title: text, frame: frame))
        let origin = frame.minX + 10
        for expected in ["Bambu", "Studio", "Extras"] {
            let span = try span(of: expected, in: text, style: .menuBar)
            let x = origin + (span.lowerBound + span.upperBound) / 2
            #expect(word(read(tree, item, at: CGPoint(x: x, y: 15))) == expected, "at \(expected)")
        }
    }

    /// Outside the drawn text — in the padding of a wide button, beyond the tolerance — no word: never the nearest.
    @Test func aPointerBesideTheTextReadsNothing() throws {
        let tree = TitledTree()
        let text = "Done"
        let frame = CGRect(x: 100, y: 100, width: try width(of: text, style: .control) + 80, height: 24)
        let button = tree.add(.init(role: "AXButton", title: text, frame: frame))
        #expect(word(read(tree, button, at: CGPoint(x: frame.minX + 5, y: 112))) == nil)
        #expect(word(read(tree, button, at: CGPoint(x: frame.midX, y: 112))) == "Done")
        // Outside the frame altogether.
        #expect(word(read(tree, button, at: CGPoint(x: frame.midX, y: 140))) == nil)
    }

    /// **A label wider than its frame is not drawn there as one line** (truncated, wrapped, or not in this font): nothing
    /// is read from it, rather than a word placed where the text is not.
    @Test func aLabelWiderThanItsFrameReadsNothing() throws {
        let tree = TitledTree()
        let text = "Extraordinarily long label"
        let frame = CGRect(x: 100, y: 100, width: try width(of: text, style: .control) / 2, height: 24)
        let button = tree.add(.init(role: "AXButton", title: text, frame: frame))
        #expect(word(read(tree, button, at: CGPoint(x: frame.minX + 4, y: 112))) == nil)
    }

    /// **A menu item: leading, after an inset nobody reports.** Where every inset the frame allows puts the same word
    /// under the pointer, it is read; where the frame is so much wider than the title that the inset decides, nothing is
    /// read here (the pixels answer it), never a guess.
    @Test func aMenuItemIsReadOnlyWhereEveryInsetAgrees() throws {
        let text = "Open Recent"
        let tree = TitledTree()
        let tight = CGRect(x: 200, y: 50, width: try width(of: text, style: .menu) + 4, height: 22)
        let fitted = tree.add(.init(role: "AXMenuItem", title: text, frame: tight))
        let open = try span(of: "Open", in: text, style: .menu)
        #expect(word(read(tree, fitted, at: CGPoint(x: tight.minX + 4 + open.upperBound / 2, y: 60))) == "Open")
        let wide = tree.add(.init(role: "AXMenuItem", title: text,
                                  frame: CGRect(x: 200, y: 80, width: tight.width + 180, height: 22)))
        #expect(word(read(tree, wide, at: CGPoint(x: 230, y: 90))) == nil)
    }

    // MARK: - Controls

    /// **A pop-up button shows its value** (a SwiftUI picker: `AXValue`, no title), and a radio button (a tab, a
    /// segment) its title.
    @Test func aPopUpButtonsValueAndATabsTitleAreRead() throws {
        let tree = TitledTree()
        let value = "Collins"
        let popUp = tree.add(.init(role: "AXPopUpButton", value: value,
                                   frame: CGRect(x: 10, y: 10, width: try width(of: value, style: .control), height: 22)))
        #expect(word(read(tree, popUp, at: CGPoint(x: 12, y: 20))) == "Collins")
        let tab = tree.add(.init(role: "AXRadioButton", subrole: "AXTabButton", title: "General",
                                 frame: CGRect(x: 300, y: 10, width: 90, height: 28)))
        #expect(word(read(tree, tab, at: CGPoint(x: 345, y: 24))) == "General")
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
    @Test func aMenuBarHitIsDescendedToItsItem() {
        let tree = TitledTree()
        let file = tree.add(.init(role: "AXMenuBarItem", title: "File", frame: CGRect(x: 99, y: 0, width: 42, height: 33)))
        let edit = tree.add(.init(role: "AXMenuBarItem", title: "Edit", frame: CGRect(x: 140, y: 0, width: 44, height: 33)))
        let bar = tree.add(.init(role: "AXMenuBar", frame: CGRect(x: 0, y: 0, width: 1728, height: 33), children: [file, edit]))
        #expect(word(read(tree, bar, at: CGPoint(x: 162, y: 15))) == "Edit")
    }

    /// **A toolbar hit whose text is the window's title beside it**: the toolbar has no child there, so the window is
    /// descended — the title element is the window's, not the toolbar's (as XDict's window answers).
    @Test func aToolbarHitIsReadThroughItsWindow() throws {
        let tree = TitledTree()
        let text = "Lexicon"
        let titleFrame = CGRect(x: 667, y: 426, width: try width(of: text, style: .control), height: 19)
        let title = tree.add(.init(role: "AXStaticText", value: text, frame: titleFrame))
        let back = tree.add(.init(role: "AXButton", description: "Back", frame: CGRect(x: 590, y: 418, width: 36, height: 36)))
        let toolbar = tree.add(.init(role: "AXToolbar", frame: CGRect(x: 494, y: 410, width: 810, height: 52),
                                     children: [back]))
        let window = tree.add(.init(role: "AXWindow", frame: CGRect(x: 494, y: 410, width: 810, height: 545),
                                    children: [toolbar, title]))
        tree.update(toolbar) { $0.window = window }
        #expect(word(read(tree, toolbar, at: CGPoint(x: titleFrame.minX + 3, y: 436))) == "Lexicon")
        // The miss names the role the read ended on, so the next log tells where it stopped.
        let empty = read(tree, toolbar, at: CGPoint(x: 1290, y: 436))
        #expect(empty == .miss(.noText(app: "Sample", role: "AXToolbar")))
    }

    /// A list row whose text is its cell's: the row is descended to the text inside it.
    @Test func aListRowIsReadThroughItsCell() throws {
        let tree = TitledTree()
        let text = "Thesaurus"
        let label = tree.add(.init(role: "AXStaticText", value: text,
                                   frame: CGRect(x: 20, y: 102, width: try width(of: text, style: .control), height: 16)))
        let cell = tree.add(.init(role: "AXCell", frame: CGRect(x: 10, y: 100, width: 200, height: 20), children: [label]))
        let row = tree.add(.init(role: "AXRow", frame: CGRect(x: 0, y: 100, width: 220, height: 20), children: [cell]))
        #expect(word(read(tree, row, at: CGPoint(x: 30, y: 110))) == "Thesaurus")
    }

    // MARK: - Scripts

    /// Right-to-left and CJK titles: the word under the pointer in either direction.
    @Test func rightToLeftAndCJKTitlesAreRead() throws {
        let tree = TitledTree()
        let arabic = "قاموس عربي"
        let rtl = tree.add(.init(role: "AXMenuBarItem", title: arabic,
                                 frame: CGRect(x: 0, y: 0, width: try width(of: arabic, style: .menuBar) + 20, height: 33)))
        let first = try span(of: "قاموس", in: arabic, style: .menuBar)
        #expect(word(read(tree, rtl, at: CGPoint(x: 10 + (first.lowerBound + first.upperBound) / 2, y: 15))) == "قاموس")
        let chinese = "牛津词典"
        let cjk = tree.add(.init(role: "AXMenuBarItem", title: chinese,
                                 frame: CGRect(x: 0, y: 40, width: try width(of: chinese, style: .menuBar) + 20, height: 33)))
        let hit = word(read(tree, cjk, at: CGPoint(x: 12, y: 55)))
        #expect(hit.map { chinese.hasPrefix($0) } == true, "got \(String(describing: hit))")
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
