// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The only two calls the bridge makes to the Hugging Face router.
public enum RouterEndpoint: Sendable, Equatable {
    /// `POST /v1/chat/completions`.
    case chatCompletions
    /// `GET /v1/models`.
    case models

    var path: String {
        switch self {
        case .chatCompletions: "chat/completions"
        case .models: "models"
        }
    }

    var method: String {
        switch self {
        case .chatCompletions: "POST"
        case .models: "GET"
        }
    }
}

/// An answer of the router: its status, the two headers the bridge uses and the body as it
/// arrives (chunks; SSE is not reassembled). Every other header is dropped here.
public struct RouterResponse: Sendable {
    public var status: Int
    public var contentType: String?
    /// The provider that served the call, when the router names it (for the log only).
    public var provider: String?
    public var body: AsyncThrowingStream<Data, any Error>

    public init(status: Int, contentType: String?, provider: String?, body: AsyncThrowingStream<Data, any Error>) {
        self.status = status
        self.contentType = contentType
        self.provider = provider
        self.body = body
    }
}

/// Sends one call to the Hugging Face router. The real one is `URLSessionRouterClient`; tests
/// use fakes. There is no way to pass a URL or a header: the endpoint, the body, `Accept` and
/// the token are all a caller can choose.
public protocol RouterClient: Sendable {
    func send(_ endpoint: RouterEndpoint, body: Data?, accept: String, token: HFToken?) async throws -> RouterResponse
}

/// The router over an ephemeral `URLSession`: fixed base `https://router.huggingface.co/v1`, no
/// cache, no cookies, no stored credentials, redirects refused (`RedirectRefusingDelegate`: a 3xx
/// comes back as it is), 120 s timeout, body read lazily from `bytes(for:)` (only as fast as it
/// is consumed; dropping it cancels the request).
public final class URLSessionRouterClient: RouterClient {
    public static let baseURL = URL(string: "https://router.huggingface.co/v1")!
    public static let timeout: TimeInterval = 120
    /// Bytes gathered before handing a chunk on, unless a newline comes first (SSE events end in one).
    static let chunkSize = 16 * 1024

    private let session: URLSession

    public init() {
        session = URLSession(
            configuration: Self.makeConfiguration(), delegate: RedirectRefusingDelegate(), delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        return configuration
    }

    /// The request for `endpoint`: our headers only (`Authorization` when there is a token,
    /// `Content-Type` with a body, `Accept`).
    static func makeRequest(_ endpoint: RouterEndpoint, body: Data?, accept: String, token: HFToken?) -> URLRequest {
        var request = URLRequest(
            url: baseURL.appendingPathComponent(endpoint.path), cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: timeout)
        request.httpMethod = endpoint.method
        request.httpShouldHandleCookies = false
        if let token { request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue(accept, forHTTPHeaderField: "Accept")
        return request
    }

    public func send(_ endpoint: RouterEndpoint, body: Data?, accept: String, token: HFToken?) async throws -> RouterResponse {
        let request = Self.makeRequest(endpoint, body: body, accept: accept, token: token)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw URLError(.badServerResponse)
        }
        let task = bytes.task
        let stream = Self.chunks(of: bytes, onDrop: { task.cancel() })
        return RouterResponse(
            status: http.statusCode, contentType: http.value(forHTTPHeaderField: "Content-Type"),
            provider: http.value(forHTTPHeaderField: "x-inference-provider"), body: stream)
    }
}

extension URLSessionRouterClient {
    /// `bytes` as chunks (ending at a newline or after `chunkSize` bytes), read only when the
    /// consumer asks for the next chunk: nothing is buffered ahead, so the network is read at the
    /// pace of whoever reads the body (in the bridge, the guest). `onDrop` runs when the stream is
    /// released and as soon as the reading task is cancelled (e.g. to cancel the URLSession task:
    /// a cancelled bridge connection never waits for the next byte or the 120 s timeout).
    static func chunks<Bytes: AsyncSequence & Sendable>(
        of bytes: Bytes, onDrop: @escaping @Sendable () -> Void
    ) -> AsyncThrowingStream<Data, any Error> where Bytes.Element == UInt8 {
        let reader = ChunkReader(bytes.makeAsyncIterator(), onDrop: onDrop)
        return AsyncThrowingStream(unfolding: {
            try await withTaskCancellationHandler { try await reader.next() } onCancel: { onDrop() }
        })
    }
}

/// Pulls one chunk at a time from a byte iterator. `@unchecked Sendable`: `AsyncThrowingStream`
/// calls `unfolding` once at a time (one consumer, each call awaited before the next), so the
/// iterator is never used concurrently.
private final class ChunkReader<Iterator: AsyncIteratorProtocol>: @unchecked Sendable where Iterator.Element == UInt8 {
    private var iterator: Iterator
    private var ended = false
    private let onDrop: @Sendable () -> Void

    init(_ iterator: Iterator, onDrop: @escaping @Sendable () -> Void) {
        self.iterator = iterator
        self.onDrop = onDrop
    }

    deinit { onDrop() }

    func next() async throws -> Data? {
        guard !ended else { return nil }
        var chunk = Data()
        var it = iterator
        defer { iterator = it }
        while let byte = try await it.next() {
            chunk.append(byte)
            if byte == 0x0A || chunk.count >= URLSessionRouterClient.chunkSize { return chunk }
        }
        ended = true
        return chunk.isEmpty ? nil : chunk
    }
}

/// Refuses every HTTP redirect: the bridge talks to `router.huggingface.co` and nothing else.
final class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
