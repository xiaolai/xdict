import Foundation
import Synchronization

/// **An OpenAI-compatible endpoint — a cloud one or a server the reader runs — as transport only** (ADR-0021 d.3, d.10).
///
/// No locality tier and no locality claim: the endpoint is the reader's address and the app promises nothing about what
/// serves it. The key lives in this value, in memory, and never in an error, a log line or a description. Requests run
/// on one kept `URLSession` (a connection per call measured +1.5–2 s in XiaolaiDict), at temperature 0, non-streaming.
public struct HTTPProvider: AIProvider {
    /// What the reader configured: an address, a model name and, for most cloud services, a key.
    public struct Configuration: Sendable, Equatable {
        public let endpoint: URL
        public let model: String
        /// In memory only; the app's Keychain storage is a later item. Absent is legal: a local server often takes none.
        public let apiKey: String?

        public init(endpoint: URL, model: String, apiKey: String? = nil) {
            self.endpoint = endpoint
            self.model = model
            self.apiKey = apiKey
        }
    }

    /// The most tokens one answer may take: a quoted sense and one sentence fit well inside it; a larger budget only
    /// invites a truncated, unusable reply.
    public static let answerTokens = 1_024
    /// The probe's budget: one token is enough to prove the endpoint, the model and the key.
    public static let probeTokens = 1
    /// Per-request and whole-request ceilings; a hung endpoint fails as `.timeout`, never as a hang.
    public static let requestTimeout: TimeInterval = 60
    /// The largest response body accepted; an answer is far smaller, and anything past this is refused as a bad shape.
    public static let responseCap = 1 << 20
    public static let resourceTimeout: TimeInterval = 90

    /// What `probe()` reports: the endpoint answered, and how long it took.
    public enum Probe: Sendable, Equatable {
        case ready(latency: Duration)
    }

    public let id: AIProviderID
    private let configuration: Configuration
    private let session: URLSession
    /// The endpoint's origin, recorded at construction and re-checked against every redirect (d.10).
    private let origin: Origin

    /// Fails with `.insecureEndpoint` for an `http` address that is not loopback, before anything is sent.
    public init(configuration: Configuration, session: URLSession? = nil) throws(AIProviderError) {
        guard let origin = Origin(configuration.endpoint) else { throw .insecureEndpoint }
        guard origin.isAcceptable else { throw .insecureEndpoint }
        self.origin = origin
        self.configuration = configuration
        self.id = AIProviderID(kind: .http, endpoint: configuration.endpoint)
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = Self.requestTimeout
            config.timeoutIntervalForResource = Self.resourceTimeout
            self.session = URLSession(configuration: config)
        }
    }

    public func answer(to question: String) async throws(AIProviderError) -> String {
        let body = Body(model: configuration.model, question: question, tokens: Self.answerTokens, tokenField: .completion)
        let reply = try await ask(body)
        try Self.statusError(reply.status)
        return try Self.content(of: reply.data, status: reply.status)
    }

    /// **One request, with the token-field negotiation both callers need**: some servers (and older OpenAI models) refuse
    /// `max_completion_tokens`; the 400 that names it is answered once with the older field, and only then. The probe
    /// used to skip this, so a server that answers questions failed its own connection test. (Audit finding, 2026-10-20.)
    private func ask(_ body: Body) async throws(AIProviderError) -> Reply {
        var reply = try await send(body)
        if reply.status == 400, reply.bodyText.contains("max_completion_tokens"), body.tokenField == .completion {
            reply = try await send(Body(model: body.model, question: body.question, tokens: body.tokens, tokenField: .max))
        }
        return reply
    }

    /// **The Settings ▸ AI test**: one token spent proving the address, the model and the key. Nothing runs unless this is
    /// called (ADR-0021 d.12).
    public func probe() async throws(AIProviderError) -> Probe {
        let body = Body(model: configuration.model, question: "ping", tokens: Self.probeTokens, tokenField: .completion)
        let clock = ContinuousClock()
        let start = clock.now
        let reply = try await ask(body)
        try Self.statusError(reply.status)
        // A one-token probe normally ends at the token ceiling; that is success here, not truncation.
        _ = try Self.content(of: reply.data, status: reply.status, allowEmpty: true, allowLength: true)
        return .ready(latency: clock.now - start)
    }

    // MARK: - The wire

    struct Reply: Sendable {
        let status: Int
        let data: Data
        var bodyText: String { String(decoding: data, as: UTF8.self) }
    }

    private enum TokenField: String, Sendable {
        case completion = "max_completion_tokens"
        case max = "max_tokens"
    }

    private struct Body: Sendable {
        let model: String
        let question: String
        let tokens: Int
        let tokenField: TokenField

        func json() throws(AIProviderError) -> Data {
            let object: [String: Any] = [
                "model": model,
                "messages": [["role": "user", "content": question]],
                "temperature": 0,
                "stream": false,
                tokenField.rawValue: tokens,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { throw .badShape }
            return data
        }
    }

    private func send(_ body: Body) async throws(AIProviderError) -> Reply {
        var request = URLRequest(url: configuration.endpoint.appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = configuration.apiKey {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try body.json()
        let delegate = RedirectGuard(origin: origin)
        do {
            // **The body is read with a ceiling** (audit finding, 2026-10-20): `data(for:)` buffers whatever the server
            // sends; a hostile or broken server could exhaust the app's memory. `bytes(for:)` streams, and the loop
            // stops — and cancels the task — one byte past the cap.
            let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
            guard let http = response as? HTTPURLResponse else { throw AIProviderError.badShape }
            if delegate.refused { throw AIProviderError.redirectRefused }
            guard origin == Origin(http.url ?? configuration.endpoint) else { throw AIProviderError.redirectRefused }
            var data = Data()
            data.reserveCapacity(min(64 << 10, Self.responseCap))
            for try await byte in bytes {
                data.append(byte)
                if data.count > Self.responseCap {
                    // **Stop this transfer and only this one**: invalidating the session would cancel a caller's other
                    // work and leave the session unusable.
                    bytes.task.cancel()
                    throw AIProviderError.badShape
                }
            }
            return Reply(status: http.statusCode, data: data)
        } catch let error as AIProviderError {
            throw error
        } catch let error as URLError {
            throw Self.transport(error)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .unreachable
        }
    }

    static func transport(_ error: URLError) -> AIProviderError {
        switch error.code {
        case .cancelled: .cancelled
        case .timedOut: .timeout
        case .cannotConnectToHost, .cannotFindHost, .notConnectedToInternet, .networkConnectionLost,
             .dnsLookupFailed, .secureConnectionFailed, .serverCertificateUntrusted:
            .unreachable
        default: .unreachable
        }
    }

    static func statusError(_ status: Int) throws(AIProviderError) {
        switch status {
        case 200..<300: return
        case 401, 403: throw .unauthorised
        case 404: throw .modelNotFound
        case 429: throw .rateLimited
        case 300..<400: throw .redirectRefused
        default: throw .badShape
        }
    }

    /// The answer text in a chat-completions reply; `.truncated` when the server says it stopped at the token ceiling,
    /// `.refused` when the model or a filter declined, `.badShape` for anything that is not one usable answer.
    static func content(of data: Data, status: Int, allowEmpty: Bool = false,
                        allowLength: Bool = false) throws(AIProviderError) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw .badShape }
        // **The envelope is required even for a probe**: a 200 carrying `{}` proves nothing about the address or the
        // model (audit finding, 2026-10-20). Only the content itself may be empty for a probe.
        guard let choices = object["choices"] as? [[String: Any]], let first = choices.first else { throw .badShape }
        if let finish = first["finish_reason"] as? String {
            if finish == "length", !allowLength { throw .truncated }
            if finish == "content_filter" { throw .refused }
        }
        guard let message = first["message"] as? [String: Any] else { throw .badShape }
        if let refusal = message["refusal"] as? String, !refusal.isEmpty { throw .refused }
        guard let content = message["content"] as? String else { throw .badShape }
        if content.isEmpty, !allowEmpty { throw .badShape }
        return content
    }

    /// **Same origin or refused.** The guard is a task delegate so the `Authorization` header is never replayed to
    /// another host: the default behaviour would follow a redirect and carry the key with it.
    final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let origin: Origin
        private let refusedFlag = Mutex(false)
        var refused: Bool { refusedFlag.withLock { $0 } }

        init(origin: Origin) {
            self.origin = origin
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? {
            guard origin == Origin(request.url) else {
                refusedFlag.withLock { $0 = true }
                return nil
            }
            return request
        }
    }
}

/// An endpoint's scheme, host and port: what must not change under a redirect.
struct Origin: Sendable, Equatable {
    let scheme: String
    let host: String
    let port: Int?

    init?(_ url: URL?) {
        guard let url, let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : nil)
    }

    /// `https` anywhere; `http` only on loopback (the reader's own server), never on a network address.
    var isAcceptable: Bool {
        switch scheme {
        case "https": true
        case "http": Self.loopbackHosts.contains(host)
        default: false
        }
    }

    static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]
}
