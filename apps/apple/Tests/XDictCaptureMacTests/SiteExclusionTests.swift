import ApplicationServices
import Foundation
import Synchronization
import Testing
import XDictCapture
@testable import XDictCaptureMac

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

        /// `element`'s parent can no longer be read.
        func detach(_ element: AXUIElement) { parents[element] = nil }
        /// `element` names `parent` as its parent, closing a cycle where it is below it.
        func reparent(_ element: AXUIElement, to parent: AXUIElement) { parents[element] = parent }
        /// Requests that read text: a hover's dialects, never the site check.
        private(set) var textAsked = 0

        func attribute(_ element: AXUIElement, _ name: String, ofApplication: Bool) throws(CaptureError) -> CFTypeRef? {
            switch name {
            case kAXValueAttribute, kAXNumberOfCharactersAttribute:
                textAsked += 1
                return nil
            case kAXRoleAttribute: return roles[element] as CFString?
            case kAXParentAttribute: return parents[element]
            case kAXURLAttribute: return urls[element] as CFString?
            default: return nil
            }
        }

        func parameterized(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) throws(CaptureError) -> CFTypeRef? {
            textAsked += 1
            return nil
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
        let inner = tree.area(3, "about:blank", in: tree.group(4, in: outer))
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

    // MARK: - Fail-closed by construction (second round)

    /// **A frame whose own parent cannot be read is not the top**: not knowing what encloses it, the answer is unknown.
    @Test func aFrameWhoseParentCannotBeReadIsUnreadable() {
        let tree = SiteTree()
        let page = tree.area(1, "https://bank.example/", in: tree.application)
        let frame = tree.area(2, "https://news.example/", in: page)
        tree.detach(frame)
        #expect(host(tree, from: frame) == .unreadable)
    }

    /// **A frame with no readable address is not an `about:` frame**: it makes the chain unknown, even inside an
    /// allowed page.
    @Test func aFrameWithNoAddressInsideAnAllowedPageIsUnreadable() {
        let tree = SiteTree()
        let page = tree.area(1, "https://news.example/", in: tree.application)
        let frame = tree.area(2, nil, in: page)
        #expect(host(tree, from: frame) == .unreadable)
    }

    /// **A chain longer than the walk's limit is unknown**, never complete: seventy frames under an excluded page.
    @Test func framesBeyondTheWalksLimitAreUnreadable() {
        let tree = SiteTree()
        var parent = tree.area(1, "https://bank.example/", in: tree.application)
        for index in 2...71 { parent = tree.area(Int32(index), "https://widget.example/", in: parent) }
        #expect(host(tree, from: parent) == .unreadable)
    }

    /// Forty-two frames under an excluded page, within the limit: the walk reaches the page and refuses.
    @Test func framesWithinTheLimitUnderAnExcludedPageAreRefused() {
        let tree = SiteTree()
        var parent = tree.area(1, "https://bank.example/", in: tree.application)
        for index in 2...43 { parent = tree.area(Int32(index), "https://widget.example/", in: parent) }
        #expect(host(tree, from: parent) == .known("bank.example"))
    }

    /// **`data:` and `javascript:` frames have no host and are not `about:`**: they do not defer to the page around
    /// them, even an allowed one.
    @Test func dataAndJavascriptFramesAreUnreadable() {
        for address in ["data:text/html,<p>hi</p>", "javascript:void(0)"] {
            let tree = SiteTree()
            let page = tree.area(1, "https://news.example/", in: tree.application)
            #expect(host(tree, from: tree.area(2, address, in: page)) == .unreadable, "\(address)")
        }
    }

    /// A cycle of parents never reaches the application: unknown. (It cannot go red alone: without the repeat check the
    /// walk still ends at its limit, which is also unknown; the repeat check only ends it sooner.)
    @Test func aCycleOfParentsIsUnreadable() {
        let tree = SiteTree()
        let outer = tree.area(1, "https://news.example/", in: tree.application)
        let inner = tree.area(2, "about:blank", in: outer)
        tree.reparent(outer, to: inner)
        #expect(host(tree, from: inner) == .unreadable)
    }

    // MARK: - One job: the check, then the read

    private func gated(_ tree: SiteTree, from element: AXUIElement, excluding excluded: Set<String>) -> PointerWordReader.GatedOutcome {
        let target = PointerWordReader.Target(element: element, appName: "Safari", bundleID: "com.apple.Safari")
        let policy = { (site: HostReading) -> Bool in
            switch site {
            case .known(let host): excluded.contains(host)
            case .notWebContent: false
            case .unreadable: !excluded.isEmpty
            }
        }
        return PointerWordReader.readUnlessRefused(at: .zero, in: target, tolerance: Measured.hit, labels: Measured.label,
                                                   refuses: policy, with: tree)
    }

    /// **The text is not read where the site refuses** — excluded, or unknown while anything is excluded — and is read
    /// where it does not.
    @Test func theReadDoesNotRunWhereTheSiteRefuses() {
        let excluded = SiteTree()
        let bank = excluded.area(1, "https://bank.example/", in: excluded.application)
        #expect(gated(excluded, from: excluded.area(2, "about:blank", in: bank), excluding: Self.excluded)
                == .refused(.known("bank.example")))
        #expect(excluded.textAsked == 0, "text was read from an excluded site")
        let unknown = SiteTree()
        let page = unknown.area(1, nil, in: unknown.application)
        #expect(gated(unknown, from: page, excluding: Self.excluded) == .refused(.unreadable))
        #expect(unknown.textAsked == 0, "text was read from a page that could not be named")
        let allowed = SiteTree()
        let news = allowed.area(1, "https://news.example/", in: allowed.application)
        guard case .read = gated(allowed, from: news, excluding: Self.excluded) else { Issue.record("not read"); return }
        #expect(allowed.textAsked > 0)
    }

    /// **The check and the read are one lane job**: one entry into the lane, so nothing can run between them.
    @Test func theCheckAndTheReadAreOneLaneJob() async {
        let entries = Mutex(0)
        let lane = AccessibilityLane.patient { _ in entries.withLock { $0 += 1 } }
        let source = SystemPointerWords(metrics: Measured.metrics, lane: lane, access: AccessibilityAccess(probe: { .granted }),
                                        client: { _ in
                                            let tree = SiteTree()
                                            _ = tree.area(1, "https://news.example/", in: tree.application)
                                            return tree
                                        })
        let target = PointerWordReader.Target(element: AXUIElementCreateApplication(4_400_001), appName: "Safari",
                                              bundleID: "com.apple.Safari")
        let outcome = await source.readUnlessRefused(at: .zero, in: target, refuses: { _ in false }, budget: .seconds(2))
        guard case .read = outcome else { Issue.record("got \(outcome)"); return }
        #expect(entries.withLock { $0 } == 1)
    }

    // MARK: - Random trees against a model of the rule

    /// One element on the chain from the pointed one upward.
    private struct Node {
        enum Address { case host(String), file, about, missing }
        let isArea: Bool
        let address: Address
        let parentReadable: Bool
    }

    /// A small deterministic generator, so a failure names its seed.
    private struct Generator {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    private enum Verdict { case refuse, unknown, allowed }

    /// **The model, written apart from the function**: refuse if any host on the chain is excluded; unknown on any parent
    /// that cannot be read, any web area with a missing address, a chain past the limit, or areas that are all `about:`;
    /// allowed otherwise. A refusal reached before an unknown is still a refusal.
    private func oracle(_ chain: [Node]) -> Verdict {
        if chain.count > PointerWordReader.siteWalkLimit - 1 { return .unknown }
        var hostOrFile = false, areas = 0
        for node in chain {
            if node.isArea {
                areas += 1
                switch node.address {
                case .host(let host): if Self.excluded.contains(host) { return .refuse }; hostOrFile = true
                case .file: hostOrFile = true
                case .about: break
                case .missing: return .unknown
                }
            }
            if !node.parentReadable { return .unknown }
        }
        return areas == 0 || hostOrFile ? .allowed : .unknown
    }

    @Test func randomTreesNeverAllowWhatTheModelRefusesOrCannotTell() {
        var generator = Generator(state: 20_261_018)
        let hosts = ["bank.example", "news.example", "widget.example"]
        var checked = (refuse: 0, unknown: 0, allowed: 0)
        for _ in 0..<600 {
            let depth = 1 + generator.next(50)
            let chain = (0..<depth).map { _ -> Node in
                let address: Node.Address = switch generator.next(4) {
                case 0: .host(hosts[generator.next(hosts.count)])
                case 1: .file
                case 2: .about
                default: generator.next(3) == 0 ? .missing : .host(hosts[generator.next(hosts.count)])
                }
                return Node(isArea: generator.next(2) == 0, address: address, parentReadable: generator.next(25) != 0)
            }
            let tree = SiteTree()
            var parent = tree.application
            var elements: [AXUIElement] = []
            for (index, node) in chain.reversed().enumerated() {
                let number = Int32(index + 1)
                let element: AXUIElement
                if node.isArea {
                    let url: String? = switch node.address {
                    case .host(let host): "https://\(host)/"
                    case .file: "file:///tmp/page.html"
                    case .about: "about:blank"
                    case .missing: nil
                    }
                    element = tree.area(number, url, in: parent)
                } else {
                    element = tree.group(number, in: parent)
                }
                if !node.parentReadable { tree.detach(element) }
                elements.append(element)
                parent = element
            }
            let answer = host(tree, from: parent)
            let allowed: Bool = switch answer {
            case .known(let host): !Self.excluded.contains(host)
            case .notWebContent: true
            case .unreadable: false
            }
            let verdict = oracle(chain)
            switch verdict {
            case .refuse: checked.refuse += 1
            case .unknown: checked.unknown += 1
            case .allowed: checked.allowed += 1
            }
            if verdict != .allowed, allowed {
                Issue.record("allowed \(answer) where the model says \(verdict), depth \(depth)")
                return
            }
        }
        #expect(checked.refuse > 20 && checked.unknown > 20 && checked.allowed > 5, "the trees did not cover the rule")
    }
}
