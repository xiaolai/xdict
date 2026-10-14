import Foundation
import WebKit

/// **WebKit's side of the `xdict:` scheme**, kept thin: each request is handed to the view's `EntryResourceServer`, and
/// its answer to the task — unless WebKit stopped the task first. Answering a stopped task raises an Objective-C
/// exception, so a task is answered only while it is still in `running` (spike 2: every cancellation reached
/// `stop`). One handler per web view, bound to one dictionary for that web view's life (`EntryBinding`).
@MainActor
final class EntrySchemeHandler: NSObject, WKURLSchemeHandler {
    let server: EntryResourceServer
    private let record: @MainActor (EntryEvent) -> Void
    private var running: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var closed = false

    init(server: EntryResourceServer, record: @escaping @MainActor (EntryEvent) -> Void) {
        self.server = server
        self.record = record
    }

    /// No request is answered after this, and none in flight ever is.
    func close() {
        closed = true
        for task in running.values { task.cancel() }
        running.removeAll()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let request = urlSchemeTask.request
        let url = request.url?.absoluteString ?? ""
        guard !closed else {
            record(.refusedRequest(handle: server.content.binding.handle, url: url, reason: "the view is closed"))
            urlSchemeTask.didFailWithError(URLError(.cancelled))
            return
        }
        let id = ObjectIdentifier(urlSchemeTask)
        running[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            let serving = await self.server.serve(request)
            // Stopped (or the view closed) while the dictionary answered: the task is WebKit's no longer.
            guard self.running.removeValue(forKey: id) != nil, !Task.isCancelled else { return }
            Self.deliver(serving, url: request.url, handle: self.server.content.binding.handle, to: urlSchemeTask,
                         record: self.record)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        running.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }

    private static func deliver(_ serving: EntryResourceServer.Serving, url: URL?, handle: String,
                                to task: any WKURLSchemeTask, record: @MainActor (EntryEvent) -> Void) {
        let text = url?.absoluteString ?? ""
        switch serving {
        case .refuse(let why):
            record(.refusedRequest(handle: handle, url: text, reason: why))
            task.didFailWithError(URLError(.resourceUnavailable))
        case .answer(let answer):
            guard let url, let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1",
                                                          headerFields: answer.headers) else {
                record(.refusedRequest(handle: handle, url: text, reason: "no response could be built"))
                task.didFailWithError(URLError(.badURL))
                return
            }
            task.didReceive(response)
            if !answer.body.isEmpty { task.didReceive(answer.body) }
            task.didFinish()
            record(.served(handle: handle, url: text, status: answer.status,
                           mime: answer.headers["Content-Type"] ?? "", bytes: answer.body.count))
        }
    }
}
