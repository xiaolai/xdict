import Foundation
import Testing
import XDictClient
import XDictContract
import XDictEntryView
import XDictSearch

/// **The entry view's three calls, answered by the service** (plan-macos-v1 WI-6; WI-4's seam): each becomes the
/// contract's operation for the dictionary the view is bound to, under the reader's render context, and each answer
/// becomes the view's own value; a failure is thrown, so the view refuses it.
struct ServiceEntryContentTests {
    static let handle = DictId(rawValue: "0123456789abcdef")
    static let edition = Edition(rawValue: "mdx-sha256-v1:abc")
    static let source = SearchSource(id: Fixture.id(1), name: "A", edition: edition, preferencesKey: "lineage-a",
                                     enabled: true, state: .ready(handle))

    static func content(_ answer: @escaping @Sendable (ServiceOperation) -> ClientOutcome) async throws
        -> (ServiceEntryContent, FakeSearchBackend) {
        let backend = FakeSearchBackend { _, _, _ in .success(Fixture.page([])) }
        await backend.setAnswer(answer)
        return (try #require(ServiceEntryContent(source: source, backend: backend)), backend)
    }

    @Test func itIsBoundToTheDictionaryItsSourceNames() async throws {
        let (content, _) = try await Self.content { _ in .failure(.wire(.interrupted)) }
        #expect(content.binding == EntryBinding(dictionary: "lineage-a", edition: Self.edition.rawValue,
                                                handle: Self.handle.rawValue))
        let indexing = SearchSource(id: Fixture.id(2), name: "B", edition: Self.edition, preferencesKey: "b", enabled: true,
                                    state: .indexing(fraction: nil))
        #expect(ServiceEntryContent(source: indexing, backend: FakeSearchBackend { _, _, _ in .success(Fixture.page([])) })
                == nil, "a dictionary that cannot answer gives no content")
    }

    @Test func anEntryIsTheServicesHTMLUnderItsPolicy() async throws {
        let html = Data("<p>run</p>".utf8)
        let (content, backend) = try await Self.content { operation in
            guard case .entry(_, let entry, _) = operation else { return .failure(.wire(.interrupted)) }
            return .success(Delivered(answer: .entry(Entry(entry: entry, csp: "default-src xdict:", lossyBytes: 0)),
                                      payload: html))
        }
        let document = try await content.entry(EntryReference(key: "run", occurrence: 2))
        #expect(document.html == html)
        #expect(document.policy == "default-src xdict:")
        #expect(await backend.requests == [.entry(dict: Self.handle, entry: EntryRef(edition: Self.edition, key: "run",
                                                                                     occurrence: 2), render: .reader)])
    }

    @Test func aResourceIsFoundWithItsTypeOrMissing() async throws {
        let (content, backend) = try await Self.content { operation in
            guard case .resource(_, let path, _) = operation else { return .failure(.wire(.interrupted)) }
            return path == "img/a%20b.png"
                ? .success(Delivered(answer: .resource(.found(path: path, mime: "image/png")), payload: Data([1, 2])))
                : .success(Delivered(answer: .resource(.missing(path: path)), payload: nil))
        }
        #expect(try await content.resource("img/a%20b.png") == .found(mime: "image/png", bytes: Data([1, 2])))
        #expect(try await content.resource("gone.png") == .missing)
        #expect(await backend.requests.first == .resource(dict: Self.handle, path: "img/a%20b.png", render: .reader),
                "the path travels as the view gives it, encoded once")
    }

    @Test func everyLinkIsTheViewsOwnKindFromWhereItAppeared() async throws {
        let answers: [String: Link] = [
            "entry://walk#s2": .lookup(query: "walk", anchor: "s2"), "r": .resource(path: "a.css"),
            "sound://a.mp3": .sound(path: "a.mp3"), "sound://hi.tts": .speak(text: "hi"), "#top": .anchor(name: "top"),
            "https://x.test/": .blocked(why: .remote(url: "https://x.test/")),
            "javascript:x": .blocked(why: .script), "foo:bar": .blocked(why: .unknownScheme(scheme: "foo")),
        ]
        let (content, backend) = try await Self.content { operation in
            guard case .link(_, let url, _, _) = operation, let link = answers[url] else { return .failure(.wire(.interrupted)) }
            return .success(Delivered(answer: .link(link), payload: nil))
        }
        let from = EntryReference(key: "run", occurrence: 1)
        #expect(try await content.link("entry://walk#s2", origin: .entry(from)) == .lookup(query: "walk", anchor: "s2"))
        #expect(try await content.link("r", origin: .resource(path: "styles/main.css")) == .resource(path: "a.css"))
        #expect(try await content.link("sound://a.mp3", origin: .entry(from)) == .sound(path: "a.mp3"))
        #expect(try await content.link("sound://hi.tts", origin: .entry(from)) == .speak(text: "hi"))
        #expect(try await content.link("#top", origin: .entry(from)) == .anchor(name: "top"))
        #expect(try await content.link("https://x.test/", origin: .entry(from)) == .blocked(.remote(url: "https://x.test/")))
        #expect(try await content.link("javascript:x", origin: .entry(from)) == .blocked(.script))
        #expect(try await content.link("foo:bar", origin: .entry(from)) == .blocked(.unknownScheme("foo")))
        let requests = await backend.requests
        #expect(requests.first == .link(dict: Self.handle, url: "entry://walk#s2",
                                        origin: .entry(entry: EntryRef(edition: Self.edition, key: "run", occurrence: 1)),
                                        render: .reader))
        #expect(requests.dropFirst().first == .link(dict: Self.handle, url: "r", origin: .resource(path: "styles/main.css"),
                                                    render: .reader))
    }

    @Test func aFailureOrAnotherAnswerIsThrown() async throws {
        let (content, _) = try await Self.content { operation in
            if case .entry = operation { return .failure(.wire(.core(.editionMismatch(detail: "")))) }
            return .success(Delivered(answer: .closed, payload: nil))
        }
        await #expect(throws: ClientFailure.self) { try await content.entry(EntryReference(key: "x")) }
        await #expect(throws: ClientFailure.self) { try await content.resource("a.png") }
        await #expect(throws: ClientFailure.self) { try await content.link("entry://x", origin: .resource(path: "a.css")) }
    }
}
