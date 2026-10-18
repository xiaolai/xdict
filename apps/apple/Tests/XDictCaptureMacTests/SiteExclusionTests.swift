import ApplicationServices
import Foundation
import Testing
import XDictCapture
import XDictCaptureMac

/// **An excluded site is refused through every frame it holds** (security review of plan-capture WI-2): an
/// `about:blank` or `srcdoc` frame inside an excluded page has no host of its own, and must not read as harmless.
struct SiteExclusionTests {
    /// A scripted tree of web areas: each element's role, parent and address.
    final class SiteTree: AccessibilityReading {
        private var roles: [AXUIElement: String] = [:]
        private var parents: [AXUIElement: AXUIElement] = [:]
        private var urls: [AXUIElement: String] = [:]
        let application = AXUIElementCreateApplication(4_400_000)

        func element(_ number: Int32) -> AXUIElement { AXUIElementCreateApplication(4_400_000 + number) }

        /// A web area at `url` (nil: no readable address), inside `parent`.
        @discardableResult
        func area(_ number: Int32, _ url: String?, in parent: AXUIElement) -> AXUIElement {
            let area = element(number)
            roles[area] = "AXWebArea"
            parents[area] = parent
            urls[area] = url
            return area
        }

        /// A plain element (a group, a text run) inside `parent`.
        func group(_ number: Int32, in parent: AXUIElement) -> AXUIElement {
            let node = element(number)
            roles[node] = "AXGroup"
            parents[node] = parent
            return node
        }

        init() { roles[application] = kAXApplicationRole }

        func attribute(_ element: AXUIElement, _ name: String, ofApplication: Bool) throws(CaptureError) -> CFTypeRef? {
            switch name {
            case kAXRoleAttribute: roles[element] as CFString?
            case kAXParentAttribute: parents[element]
            case kAXURLAttribute: urls[element] as CFString?
            default: nil
            }
        }

        func parameterized(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) throws(CaptureError) -> CFTypeRef? {
            nil
        }
    }

    private static let excluded: Set<String> = ["bank.example"]
    private func host(_ tree: SiteTree, from element: AXUIElement) -> HostReading {
        let target = PointerWordReader.Target(element: element, appName: "Safari", bundleID: "com.apple.Safari")
        return PointerWordReader.host(of: target, isExcluded: { Self.excluded.contains($0) }, with: tree)
    }

    @Test func anExcludedSiteHoldingAnAboutBlankFrameIsRefused() {
        let tree = SiteTree()
        let page = tree.area(1, "https://bank.example/login", in: tree.application)
        let frame = tree.area(2, "about:blank", in: tree.group(3, in: page))
        #expect(host(tree, from: tree.group(4, in: frame)) == .known("bank.example"))
    }

    @Test func framesTwoDeepInsideAnExcludedSiteAreRefused() {
        let tree = SiteTree()
        let page = tree.area(1, "https://bank.example/", in: tree.application)
        let outer = tree.area(2, "about:srcdoc", in: page)
        let inner = tree.area(3, nil, in: tree.group(4, in: outer))
        #expect(host(tree, from: inner) == .known("bank.example"))
    }

    @Test func anAboutFrameWithNoReadableHostAboveIsUnreadable() {
        let tree = SiteTree()
        let outer = tree.area(1, nil, in: tree.application)
        let frame = tree.area(2, "about:blank", in: outer)
        #expect(host(tree, from: frame) == .unreadable)
    }

    @Test func aSiteNotExcludedIsAllowed() {
        let tree = SiteTree()
        let page = tree.area(1, "https://news.example/", in: tree.application)
        let frame = tree.area(2, "about:blank", in: page)
        #expect(host(tree, from: frame) == .known("news.example"))
    }

    @Test func aLocalFileIsAPageWithNoSite() {
        let tree = SiteTree()
        let page = tree.area(1, "file:///tmp/notes.html", in: tree.application)
        #expect(host(tree, from: tree.group(2, in: page)) == .notWebContent)
    }

    @Test func noWebAreaIsNotWebContent() {
        let tree = SiteTree()
        #expect(host(tree, from: tree.group(1, in: tree.application)) == .notWebContent)
    }
}
