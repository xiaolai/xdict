import AppKit
import Foundation
import WebKit
import XDictEntryView
import XDictTokens

/// **`--hover-script`: the entry's hover script against synthetic pages** (verifier, 2026-10-19), for
/// `HoverWordScriptTests`, which writes the pages and holds the answers. A web view in no window, with the hover script
/// installed as every entry installs the shell's scripts (`EntryWebView.withHoverScript`), each page loaded with no base
/// URL and asked through the shell's own call (`hoverText`). The test cannot host the web view itself: in `swift test`'s runner a web
/// view never starts loading (measured 2026-10-19: progress 0.1 after ten seconds). A page may ask for every script an
/// entry installs instead (`EntryWebView.withEntryScripts`), so the run also times what they cost a hostile page to load.
@MainActor
enum HoverScriptRun {
    struct Case: Decodable {
        let name: String
        /// The page's body.
        let body: String
        /// The element aimed at, and the character of its first text node — or its box's middle, where nil.
        let target: String
        let offset: Int?
        let max: Int
        /// "entry" for every script an entry installs; the hover script alone otherwise.
        let scripts: String?
        /// A function body run on the loaded page, outside the shell's world, whose string answer is reported.
        let probe: String?
        /// A function body run on the loaded page, outside the shell's world, that makes a selection: the page is then
        /// asked for its selection (`selectionText`, the text around it where `sentence`) instead of a hover's word.
        let select: String?
        let sentence: Bool?
    }

    /// Whether the page in flight loaded: answered once, whether its end comes before or after the wait.
    @MainActor
    final class Loads: NSObject, WKNavigationDelegate {
        private var waiting: CheckedContinuation<Bool, Never>?
        private var outcome: Bool?

        func reset() { outcome = nil }

        func wait() async -> Bool {
            if let outcome { return outcome }
            return await withCheckedContinuation { waiting = $0 }
        }

        private func finish(_ loaded: Bool) {
            guard outcome == nil else { return }
            outcome = loaded
            waiting?.resume(returning: loaded)
            waiting = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) { finish(true) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: any Error) { finish(false) }
        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: any Error
        ) { finish(false) }
    }

    /// The world the run reads the page in to aim: not the shell's.
    private static let aiming = WKContentWorld.world(name: "xdict-lab-hover")

    static func run(cases file: URL) async throws -> [String: Any] {
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: file))
        // The lab's entry window's size, as an entry is laid out there.
        let size = CGRect(origin: .zero, size: Tokens.InstrumentFrame.labWindow.size)
        let hoverView = EntryWebView.withHoverScript(frame: size)
        let entryView = EntryWebView.withEntryScripts(frame: size)
        let loads = Loads()
        hoverView.navigationDelegate = loads
        entryView.navigationDelegate = loads
        var results: [[String: Any]] = []
        for item in cases {
            let view = item.scripts == "entry" ? entryView : hoverView
            // Which page is in flight, so a page that hangs the run is named by whoever ends it.
            FileHandle.standardError.write(Data("hover-script: \(item.name)\n".utf8))
            let loading = ContinuousClock.now
            defer {
                let took = Int((ContinuousClock.now - loading) / .milliseconds(1))
                FileHandle.standardError.write(Data("hover-script: \(item.name) done in \(took) ms\n".utf8))
            }
            loads.reset()
            view.loadHTMLString("<!doctype html><html><head><meta charset=utf-8></head>"
                                + "<body style='margin:0;font:24px Helvetica'>" + item.body + "</body></html>", baseURL: nil)
            guard await loads.wait() else { throw LabFailure(description: "\(item.name): the page did not load") }
            let loaded = Int((ContinuousClock.now - loading) / .milliseconds(1))
            var probed: Any = NSNull()
            if let probe = item.probe {
                probed = try await view.callAsyncJavaScript(probe, arguments: [:], in: nil, contentWorld: aiming) as? String
                    ?? NSNull()
            }
            // Aiming lays the page out, as an entry on screen is laid out before any hover.
            let aimed = try await view.callAsyncJavaScript("""
                var e = document.getElementById(id); if (!e) return null;
                function box() {
                  if (off === null) return e.getBoundingClientRect();
                  var g = document.createRange(); g.setStart(e.firstChild, off); g.setEnd(e.firstChild, off + 1);
                  return g.getBoundingClientRect();
                }
                // The aimed character itself into view: an element taller than the view would leave it outside.
                var r = box();
                window.scrollBy(r.left - innerWidth / 2, r.top - innerHeight / 2);
                r = box();
                return [r.left + Math.min(r.width / 2, 3), r.top + r.height / 2];
                """, arguments: ["id": item.target, "off": item.offset.map { $0 as Any } ?? NSNull()], in: nil,
                contentWorld: aiming)
            guard let xy = (aimed as? [NSNumber])?.map(\.doubleValue), xy.count == 2 else {
                throw LabFailure(description: "\(item.name): no point for #\(item.target)")
            }
            if let select = item.select {
                _ = try await view.callAsyncJavaScript(select, arguments: [:], in: nil, contentWorld: aiming)
                let started = ContinuousClock.now
                let selection = await view.selectionText(sentence: item.sentence ?? true, maxUTF16: item.max)
                let took = ContinuousClock.now - started
                results.append(["name": item.name, "milliseconds": Int(took / .milliseconds(1)), "loaded": loaded,
                                "probe": probed, "answer": NSNull(), "selection": Self.reported(selection)])
                continue
            }
            let started = ContinuousClock.now
            let answer = await view.hoverText(at: CGPoint(x: xy[0], y: xy[1]), maxUTF16: item.max)
            let took = ContinuousClock.now - started
            results.append([
                "name": item.name,
                "milliseconds": Int(took / .milliseconds(1)),
                "loaded": loaded,
                "probe": probed,
                "answer": answer.map { Self.reported(word: $0) } ?? NSNull(),
            ])
        }
        return ["cases": results]
    }

    /// An answer as the script wrote it, for the test to check again as the shell does.
    private static func reported(word text: EntryHoverText) -> [String: Any] {
        ["text": text.text, "offset": text.offset, "cutStart": text.cutStart, "cutEnd": text.cutEnd]
    }

    private static func reported(_ selection: EntrySelectionText?) -> Any {
        switch selection {
        case nil: NSNull()
        case .tooLong: ["over": true]
        case .selected(let selected, let around?): ["selected": selected, "around": reported(word: around)]
        case .selected(let selected, nil): ["selected": selected, "around": NSNull()]
        }
    }
}
