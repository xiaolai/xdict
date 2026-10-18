import Foundation
import Testing
@testable import XDictEntryView

/// **The `xdict:` scheme: one authority, four routes, everything else refused, nothing redirected** (ADR-0007 decision
/// 14; ADR-0009 decision 7), and **the core's policy as a header on every response** — of every kind the handler gives.
@MainActor
struct SchemeTests {
    // MARK: - Routes

    @Test func eachRouteIsReadFromItsURL() {
        let entry = URL(string: "xdict://d/entry/run")
        #expect(EntryRoutes.route(entry, method: "GET") == .document(entry ?? URL(fileURLWithPath: "/")))
        #expect(EntryRoutes.route(URL(string: "xdict://d/r/img/a%20b.png"), method: nil) == .resource(path: "img/a%20b.png"))
        #expect(EntryRoutes.route(URL(string: "xdict://d/r/a.css?v=2"), method: "GET") == .resource(path: "a.css?v=2"))
        #expect(EntryRoutes.route(URL(string: "xdict://d/sound/us/run.mp3"), method: "GET") == .sound(path: "us/run.mp3"))
        // The core encodes the whole remote URL; it is decoded exactly once.
        #expect(EntryRoutes.route(URL(string: "xdict://d/blocked/https%3A%2F%2Fexample.com%2Fa%253F"), method: "GET")
                == .blocked(remote: "https://example.com/a%3F"))
    }

    @Test func everythingElseIsRefused() {
        let refused: [(String, String, EntryRoutes.Refusal)] = [
            ("http://127.0.0.1/x", "GET", .notThisScheme),
            ("https://example.com/r/x", "GET", .notThisScheme),
            ("xdict://e/r/x", "GET", .notThisAuthority),
            ("xdict://D/r/x", "GET", .notThisAuthority),
            ("xdict://d:8080/r/x", "GET", .credentialsOrPort),
            ("xdict://u:p@d/r/x", "GET", .credentialsOrPort),
            ("xdict://d/r/", "GET", .emptyPath),
            ("xdict://d/entry/", "GET", .emptyPath),
            ("xdict://d/blocked/", "GET", .emptyPath),
            ("xdict://d/", "GET", .unknownRoute),
            ("xdict://d/other/x", "GET", .unknownRoute),
            ("xdict://d/R/x", "GET", .unknownRoute),
            ("xdict://d/r/x", "POST", .notGet),
        ]
        for (url, method, why) in refused {
            #expect(EntryRoutes.route(URL(string: url), method: method) == .refused(why), "\(url) \(method)")
        }
        #expect(EntryRoutes.route(nil, method: "GET") == .refused(.undecodable))
    }

    @Test func aDocumentURLIsTheKeyUnderEntryInASCII() {
        #expect(EntryRoutes.documentURL(for: EntryReference(key: "café au lait"))?.absoluteString
                == "xdict://d/entry/caf%C3%A9%20au%20lait")
        #expect(EntryRoutes.documentURL(for: EntryReference(key: "a/b?c#d", occurrence: 2))?.absoluteString
                == "xdict://d/entry/a%2Fb%3Fc%23d?occurrence=2")
        #expect(EntryRoutes.isOwn(URL(string: "xdict://d/r/x")))
        #expect(!EntryRoutes.isOwn(URL(string: "xdict://d:1/r/x")))
        #expect(!EntryRoutes.isOwn(URL(string: "https://d/r/x")))
    }

    // MARK: - The server

    static func server(_ content: FakeContent, attaches: Bool = true) -> EntryResourceServer {
        EntryResourceServer(content: content, attachesPolicy: attaches) { "Image from \($0)" }
    }

    static func document(_ server: EntryResourceServer, policy: String = corePolicy) -> URL {
        let url = URL(string: "xdict://d/entry/run") ?? URL(fileURLWithPath: "/")
        server.register(EntryDocument(html: Data("<p>run</p>".utf8), policy: policy), at: url)
        return url
    }

    /// Nothing is answered before there is a document, and so a policy to send with it: fail closed.
    @Test func withNoDocumentNothingIsAnswered() async {
        let content = FakeContent("a")
        content.resources["a.css"] = .found(mime: "text/css", bytes: Data("b{}".utf8))
        let server = Self.server(content)
        guard case .refuse = await server.serve(request("xdict://d/r/a.css")) else {
            Issue.record("a resource was answered with no policy to send")
            return
        }
        #expect(content.asked.isEmpty, "the dictionary was asked before there was a policy")
        _ = Self.document(server, policy: "  ")
        guard case .refuse = await server.serve(request("xdict://d/r/a.css")) else {
            Issue.record("a resource was answered under an empty policy")
            return
        }
    }

    /// **The header on every kind of response**, the only layer spike 3 saw cover an SVG document under `r/`; and never a
    /// redirect, a `Refresh` or an attachment.
    @Test func everyResponseCarriesThePolicyAndNoRedirect() async throws {
        let content = FakeContent("a")
        content.resources = [
            "a.css": .found(mime: "text/css", bytes: Data("b{}".utf8)),
            "page.html": .found(mime: "text/html", bytes: Data("<p>x</p>".utf8)),
            "pic.svg": .found(mime: "image/svg+xml", bytes: Data("<svg/>".utf8)),
            "pic.png": .found(mime: "image/png", bytes: Data([0x89, 0x50])),
            "s.js": .found(mime: "text/javascript", bytes: Data("1".utf8)),
            "run.mp3": .found(mime: "audio/mpeg", bytes: Data([1, 2, 3])),
        ]
        let server = Self.server(content)
        let document = Self.document(server)
        var kinds: [String] = []
        for url in [document.absoluteString, "xdict://d/r/a.css", "xdict://d/r/page.html", "xdict://d/r/pic.svg",
                    "xdict://d/r/pic.png", "xdict://d/r/s.js", "xdict://d/sound/run.mp3", "xdict://d/r/absent.png",
                    "xdict://d/blocked/http%3A%2F%2Fexample.com%2Fa.png"] {
            guard case .answer(let answer) = await server.serve(request(url)) else {
                Issue.record("\(url) was refused")
                continue
            }
            #expect(answer.headers["Content-Security-Policy"] == corePolicy, "\(url) went without the policy")
            #expect(![301, 302, 303, 307, 308].contains(answer.status), "\(url) redirected")
            for header in ["Location", "Refresh", "Content-Disposition"] {
                #expect(answer.headers[header] == nil, "\(url) carried \(header)")
            }
            #expect(answer.headers["X-Content-Type-Options"] == "nosniff")
            kinds.append("\(answer.status) \(answer.headers["Content-Type"] ?? "")")
        }
        #expect(kinds == ["200 text/html; charset=utf-8", "200 text/css", "200 text/html", "200 image/svg+xml",
                          "200 image/png", "200 text/javascript", "200 audio/mpeg", "404 text/plain; charset=utf-8",
                          "200 image/svg+xml"])
    }

    /// The control for the test above: the lab's server for the CSP layer's isolated control sends no header, and the
    /// check sees it.
    @Test func withoutThePolicyLayerTheHeaderIsAbsent() async {
        let server = Self.server(FakeContent("a"), attaches: false)
        let document = Self.document(server)
        guard case .answer(let answer) = await server.serve(request(document.absoluteString)) else {
            Issue.record("the document was refused")
            return
        }
        #expect(answer.headers["Content-Security-Policy"] == nil)
    }

    @Test func anEntryURLThatIsNotTheDocumentIsRefused() async {
        let server = Self.server(FakeContent("a"))
        _ = Self.document(server)
        guard case .refuse = await server.serve(request("xdict://d/entry/walk")) else {
            Issue.record("an entry URL other than the shown document was served as a page")
            return
        }
    }

    @Test func aRefusedRouteNeverAsksTheDictionary() async {
        let content = FakeContent("a")
        let server = Self.server(content)
        _ = Self.document(server)
        for url in ["xdict://e/r/a.css", "xdict://d/x/a.css", "http://127.0.0.1/r/a.css"] {
            guard case .refuse = await server.serve(request(url)) else {
                Issue.record("\(url) was answered")
                continue
            }
        }
        guard case .refuse = await server.serve(request("xdict://d/r/a.css", method: "POST")) else {
            Issue.record("a POST was answered")
            return
        }
        #expect(content.asked.isEmpty)
    }

    @Test func aDictionaryThatFailsIsRefusedNotGuessed() async {
        let content = FakeContent("a")
        let server = Self.server(content)
        _ = Self.document(server)
        content.failing = true
        guard case .refuse = await server.serve(request("xdict://d/r/a.css")) else {
            Issue.record("a failed resource was answered")
            return
        }
    }

    @Test func aBodyPastItsCeilingIsRefused() async {
        let content = FakeContent("a")
        content.resources["big.html"] = .found(mime: "text/html", bytes: Data(count: EntryResourceServer.maxRenderedBytes + 1))
        content.resources["big.png"] = .found(mime: "image/png", bytes: Data(count: EntryResourceServer.maxRenderedBytes + 1))
        let server = Self.server(content)
        _ = Self.document(server)
        guard case .refuse = await server.serve(request("xdict://d/r/big.html")) else {
            Issue.record("a rendered body past 16 MiB was answered")
            return
        }
        guard case .answer = await server.serve(request("xdict://d/r/big.png")) else {
            Issue.record("an image under 64 MiB was refused")
            return
        }
    }

    @Test func aTypeThatIsNotOneBecomesOctetStream() {
        #expect(EntryResourceServer.sanitized("text/css") == "text/css")
        #expect(EntryResourceServer.sanitized("Image/SVG+XML") == "image/svg+xml")
        #expect(EntryResourceServer.sanitized("text/html\r\nLocation: http://x") == "application/octet-stream")
        #expect(EntryResourceServer.sanitized("text") == "application/octet-stream")
        #expect(EntryResourceServer.sanitized("a/b/c") == "application/octet-stream")
    }

    @Test func aBlockedImageIsAPlaceholderNamingItsHostEscaped() async {
        let server = Self.server(FakeContent("a"))
        _ = Self.document(server)
        guard case .answer(let answer) = await server.serve(request("xdict://d/blocked/https%3A%2F%2Fexample.org%2Fx.png")) else {
            Issue.record("the placeholder was refused")
            return
        }
        #expect(String(decoding: answer.body, as: UTF8.self).contains("Image from example.org"))
        let svg = String(decoding: EntryResourceServer.placeholder(label: "<script>&\""), as: UTF8.self)
        #expect(!svg.contains("<script>") && svg.contains("&lt;script&gt;&amp;&quot;"))
    }

    /// The placeholder drawn from the tokens is the picture it was when its numbers were written in (2026-10-18), at
    /// the narrowest box and at a cut-off one.
    @Test func thePlaceholderIsTheTokensPicture() {
        func svg(_ label: String) -> String { String(decoding: EntryResourceServer.placeholder(label: label), as: UTF8.self) }
        #expect(svg("ab") == ##"<svg xmlns="http://www.w3.org/2000/svg" width="80" height="28" role="img" aria-label="ab">"##
            + ##"<rect x="0.5" y="0.5" width="79" height="27" rx="4" fill="#f2f2f2" stroke="#8a8a8a" stroke-dasharray="3 2"/>"##
            + ##"<text x="12" y="18" font-family="-apple-system, sans-serif" font-size="12" fill="#3a3a3a">ab</text></svg>"##)
        #expect(svg(String(repeating: "x", count: 20)).hasPrefix(##"<svg xmlns="http://www.w3.org/2000/svg" width="164""##))
        #expect(svg(String(repeating: "x", count: 100)).contains(##"width="480""##))
    }

    /// **Each answer keeps its package** (ADR-0009 refutation, item 13): two views bound to A and B ask the same path; A's
    /// answer is held while B's is given; released, A's is A's.
    @Test func eachViewIsAnsweredFromItsOwnDictionary() async {
        let a = FakeContent("a"), b = FakeContent("b")
        a.resources["marker.css"] = .found(mime: "text/css", bytes: Data("A".utf8))
        b.resources["marker.css"] = .found(mime: "text/css", bytes: Data("B".utf8))
        a.held = ["marker.css"]
        let serverA = Self.server(a), serverB = Self.server(b)
        _ = Self.document(serverA)
        _ = Self.document(serverB)
        let late = Task { @MainActor in await serverA.serve(request("xdict://d/r/marker.css")) }
        while a.holding == 0 { await Task.yield() }
        let fromB = await serverB.serve(request("xdict://d/r/marker.css"))
        a.release()
        let fromA = await late.value
        guard case .answer(let answerB) = fromB, case .answer(let answerA) = fromA else {
            Issue.record("a marker was refused")
            return
        }
        #expect(String(decoding: answerB.body, as: UTF8.self) == "B")
        #expect(String(decoding: answerA.body, as: UTF8.self) == "A")
        #expect(serverA.content.binding != serverB.content.binding)
    }
}
