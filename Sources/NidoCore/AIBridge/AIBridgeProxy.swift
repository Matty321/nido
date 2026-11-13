// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization

/// An answer of the bridge to the guest: status, content type and the body as it is produced.
/// Without `contentLength` the body ends when the connection closes (SSE).
public struct AIBridgeResponse: Sendable {
    public let status: Int
    public let contentType: String?
    public let contentLength: Int?
    public let body: AIBridgeBody

    /// Status line and headers: only `Content-Type`, `Content-Length` and `Connection: close`.
    public var head: Data {
        AIBridgeHTTP.responseHead(status: status, contentType: contentType, contentLength: contentLength)
    }

    static func complete(status: Int, contentType: String?, body: Data) -> AIBridgeResponse {
        AIBridgeResponse(
            status: status, contentType: contentType, contentLength: body.count,
            body: AIBridgeBody(ChunkChannel(complete: body.isEmpty ? [] : [body])))
    }

    static func failure(_ failure: AIBridgeFailure) -> AIBridgeResponse {
        complete(status: failure.status, contentType: "application/json", body: failure.body)
    }
}

/// The body of an `AIBridgeResponse`, pulled by its reader: a streamed answer is read from the
/// router only as fast as the guest takes it (at most `ChunkChannel.capacity` chunks wait).
/// Dropping the body (or `cancel()`) stops the upstream call.
public struct AIBridgeBody: AsyncSequence, Sendable {
    public typealias Element = Data

    private let channel: ChunkChannel
    private let reader: Reader

    init(_ channel: ChunkChannel) {
        self.channel = channel
        reader = Reader(channel)
    }

    public func makeAsyncIterator() -> Iterator { Iterator(channel: channel, reader: reader) }

    /// Stops the body: the producer is cancelled; later reads end.
    public func cancel() { channel.cancel() }

    public struct Iterator: AsyncIteratorProtocol {
        let channel: ChunkChannel
        let reader: Reader
        public mutating func next() async throws -> Data? { try await channel.receive() }
    }

    /// Cancels the channel when the last copy of the body (or of an iterator) goes away.
    final class Reader: Sendable {
        let channel: ChunkChannel
        init(_ channel: ChunkChannel) { self.channel = channel }
        deinit { channel.cancel() }
    }
}

/// A bounded single-producer, single-consumer queue of chunks with backpressure: `send` waits
/// while `capacity` chunks are queued. `cancel` (from the reader) wakes both sides and cancels
/// the attached producer task.
final class ChunkChannel: Sendable {
    static let capacity = 4

    private struct State {
        var queue: [Data] = []
        var finished = false
        var failure: (any Error)?
        var cancelled = false
        var consumer: CheckedContinuation<Data?, any Error>?
        var producer: CheckedContinuation<Bool, Never>?
        var pump: Task<Void, Never>?
    }

    private let state: Mutex<State>

    init() { state = Mutex(State()) }

    /// A channel already holding all of its chunks.
    init(complete chunks: [Data]) { state = Mutex(State(queue: chunks, finished: true)) }

    /// The task producing into this channel, cancelled by `cancel`.
    func attach(_ task: Task<Void, Never>) {
        let cancelled = state.withLock { s -> Bool in
            if s.cancelled { return true }
            s.pump = task
            return false
        }
        if cancelled { task.cancel() }
    }

    /// Hands `data` to the reader, waiting while the queue is full; false once the reader cancelled.
    func send(_ data: Data) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            enum Action { case done(Bool), deliver(CheckedContinuation<Data?, any Error>), wait }
            let action = state.withLock { s -> Action in
                if s.cancelled || s.finished { return .done(false) }
                if let consumer = s.consumer {
                    s.consumer = nil
                    return .deliver(consumer)
                }
                s.queue.append(data)
                // At most `capacity` chunks queued: the producer waits on the last one.
                if s.queue.count < Self.capacity { return .done(true) }
                s.producer = continuation
                return .wait
            }
            switch action {
            case .done(let ok): continuation.resume(returning: ok)
            case .deliver(let consumer):
                consumer.resume(returning: data)
                continuation.resume(returning: true)
            case .wait: break
            }
        }
    }

    /// No more chunks (after the queued ones); `error` is thrown to the reader at the end.
    func finish(throwing error: (any Error)? = nil) {
        let consumer = state.withLock { s -> CheckedContinuation<Data?, any Error>? in
            guard !s.finished else { return nil }
            s.finished = true
            s.failure = error
            defer { s.consumer = nil }
            return s.consumer
        }
        if let error { consumer?.resume(throwing: error) } else { consumer?.resume(returning: nil) }
    }

    func receive() async throws -> Data? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, any Error>) in
                enum Action { case value(Data, CheckedContinuation<Bool, Never>?), end((any Error)?), cancelled, wait }
                let action = state.withLock { s -> Action in
                    if !s.queue.isEmpty {
                        let data = s.queue.removeFirst()
                        defer { s.producer = nil }
                        return .value(data, s.producer)
                    }
                    if s.cancelled { return .cancelled }
                    if s.finished { return .end(s.failure) }
                    s.consumer = continuation
                    return .wait
                }
                switch action {
                case .value(let data, let producer):
                    producer?.resume(returning: true)
                    continuation.resume(returning: data)
                case .end(let error):
                    if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: nil) }
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .wait: break
                }
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        let (consumer, producer, pump) = state.withLock { s in
            s.cancelled = true
            s.queue = []
            defer {
                s.consumer = nil
                s.producer = nil
                s.pump = nil
            }
            return (s.consumer, s.producer, s.pump)
        }
        consumer?.resume(throwing: CancellationError())
        producer?.resume(returning: false)
        pump?.cancel()
    }
}

/// The host side of the remote AI bridge for one VM. The guest reaches it over one connection
/// per request (`serve`); it answers only `GET /v1/models` and `POST /v1/chat/completions`
/// (anything else `404`), and only when the VM's policy is on (`403 bridge_disabled`) and the
/// Mac has a token (`401 token_missing`). `GET /v1/models` counts against the VM's requests per
/// minute (no tokens) and is served from `ModelCatalog` (cached, failures too, fetches shared).
///
/// A chat request is parsed (UTF-8 JSON without BOM, an object nested at most `JSONDepth.limit`
/// deep with a string
/// `model`, else `400`), its model checked against the policy (`403 model_not_allowed`),
/// rewritten (`max_tokens` / `max_completion_tokens` must be integers ≥ 1, else `400`, and are
/// clamped to the policy's maximum; `max_tokens` is set when neither is there;
/// `stream_options.include_usage` is forced on for `stream: true`; nothing else is touched) and
/// admitted by the `AIBridgeLimiter` (`429 rate_limited` / `daily_budget_exhausted`) before it
/// goes to the router with the Mac's token. No header of the guest is forwarded: the router gets
/// the rewritten body, our `Accept` and our `Authorization` only.
///
/// Answers: a `2xx` goes back with only its `Content-Type` (SSE streamed as the guest reads it:
/// the router's body is pulled through `ChunkChannel`, and `URLSessionRouterClient` reads the
/// network only when pulled; for at most `maxStreamDuration`; the rest with `Content-Length`); a `4xx`/`5xx` of the router
/// keeps its status with a fixed explanation (`AIBridgeFailure.router(status:)`, the router's
/// body is never read); anything else, a transport failure or a body
/// containing the token is `502 upstream_error`. The token is searched in every body the guest
/// would get, streams included (a stream holding it is cut before the token's first byte).
///
/// Accounting (`AIBridgeLimiter.commit`): once the router answered `2xx`, the provider has the
/// prompt, so the call is always charged: the router's `usage` (also from the last SSE event),
/// with the estimate standing in for a missing part (`ceil(body bytes / 4)` for the input,
/// `max_tokens × n` for the output; logged as `estimated`), even when the guest went away, the
/// stream broke or was cut. Nothing is charged when the router could not be reached or answered
/// with an error status.
public struct AIBridgeProxy: Sendable {
    /// Largest non-streaming answer accepted from the router.
    static let maxJSONResponseBytes = 8 << 20
    /// Longest streamed answer: checked at every chunk (a silent router is ended earlier by the
    /// 120 s timeout of `URLSessionRouterClient`).
    public static let maxStreamDuration: TimeInterval = 600

    private let router: any RouterClient
    private let tokenStore: any TokenStore
    private let limiter: AIBridgeLimiter
    private let log: AIBridgeLog?
    private let catalog: ModelCatalog?
    private let readTimeout: Duration
    private let now: @Sendable () -> Date

    public init(
        router: any RouterClient, tokenStore: any TokenStore, limiter: AIBridgeLimiter, log: AIBridgeLog?,
        catalog: ModelCatalog?, readTimeout: Duration = AIBridgeHTTP.readTimeout,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.router = router
        self.tokenStore = tokenStore
        self.limiter = limiter
        self.log = log
        self.catalog = catalog
        self.readTimeout = readTimeout
        self.now = now
    }

    /// Serves one request on `connection` and closes it. `policy` is read once the request is in
    /// (nil = bridge off), so a change made meanwhile applies.
    public func serve(connection: some ByteStream, policy: @Sendable () -> AIBridgePolicy?) async {
        let request: AIBridgeRequest
        do {
            request = try await AIBridgeHTTP.readRequest(from: connection, timeout: readTimeout)
        } catch {
            try? await connection.write(AIBridgeHTTP.errorResponse(error))
            await connection.close()
            return
        }
        let response = await handle(request: request, policy: policy())
        do {
            try await connection.write(response.head)
            for try await chunk in response.body {
                try await connection.write(chunk)
            }
        } catch {}
        // The guest went away or the answer is over: stop the upstream call, if any.
        response.body.cancel()
        await connection.close()
    }

    /// The answer to `request` under `policy`.
    public func handle(request: AIBridgeRequest, policy: AIBridgePolicy?) async -> AIBridgeResponse {
        enum Route { case chat, models }
        let route: Route
        switch (request.method, request.path) {
        case ("POST", "/v1/chat/completions"): route = .chat
        case ("GET", "/v1/models"): route = .models
        default: return .failure(.notFound)
        }
        guard let policy, policy.enabled else { return .failure(.bridgeDisabled) }
        // A Keychain failure is reported like a missing token: the guest learns nothing more.
        guard let token = await Self.readToken(tokenStore) else { return .failure(.tokenMissing) }
        switch route {
        case .models:
            do {
                try await limiter.admitListing(policy: policy)
            } catch {
                return .failure(.rateLimited)
            }
            let models = try? await catalog?.models()
            return .complete(
                status: 200, contentType: "application/json",
                body: ModelCatalog.guestList(catalog: models, allowed: policy.allowedModels))
        case .chat:
            return await chat(request.body, policy: policy, token: token)
        }
    }

    /// The token from the store, read on a dispatch queue: a Keychain read can wait for the user
    /// (macOS asks again after the app is re-signed) and must not hold a thread of Swift's
    /// cooperative pool meanwhile. A Keychain failure is reported like a missing token.
    private static func readToken(_ store: any TokenStore) async -> HFToken? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: (try? store.read()) ?? nil)
            }
        }
    }

    // MARK: - Chat

    private func chat(_ body: Data, policy: AIBridgePolicy, token: HFToken) async -> AIBridgeResponse {
        let rewrite: ChatRewrite
        do {
            rewrite = try ChatRewrite(body, maxTokens: policy.maxTokensPerRequest)
        } catch {
            return .failure(error)
        }
        guard policy.isAllowed(model: rewrite.model) else { return .failure(.modelNotAllowed) }
        let started = now()
        let reservation: AIBridgeReservation
        do {
            reservation = try await limiter.reserve(estimate: rewrite.estimate, policy: policy)
        } catch {
            let failure: AIBridgeFailure = error == .dailyBudgetExhausted ? .dailyBudgetExhausted : .rateLimited
            record(rewrite, provider: nil, input: 0, output: 0, estimated: false, status: failure.status, started: started)
            return .failure(failure)
        }
        let call = UpstreamCall(proxy: self, rewrite: rewrite, reservation: reservation, started: started)

        let upstream: RouterResponse
        do {
            upstream = try await router.send(
                .chatCompletions, body: rewrite.body, accept: rewrite.stream ? "text/event-stream" : "application/json",
                token: token)
        } catch {
            await call.settle(usage: nil, accepted: false, status: 502, provider: nil)
            return .failure(.upstreamError)
        }
        let provider = Self.sanitizedProvider(upstream.provider)
        let secret = Data(token.value.utf8)

        guard (200..<300).contains(upstream.status) else {
            guard (400..<600).contains(upstream.status) else {
                await call.settle(usage: nil, accepted: false, status: 502, provider: provider)
                return .failure(.upstreamError)
            }
            // The router's own explanation may name the account behind the token (user,
            // organisation, credits): the guest gets the status and a fixed text only. The body is
            // never read; dropping it cancels the request.
            await call.settle(usage: nil, accepted: false, status: upstream.status, provider: provider)
            return .failure(.router(status: upstream.status))
        }

        // From here on the router accepted the call: it is charged whatever happens next.
        let isEventStream = upstream.contentType?.lowercased().contains("text/event-stream")
            ?? rewrite.stream
        if isEventStream {
            return stream(upstream, call: call, secret: secret, provider: provider)
        }
        guard let answer = try? await Self.collect(upstream.body, limit: Self.maxJSONResponseBytes),
            answer.range(of: secret) == nil
        else {
            await call.settle(usage: nil, accepted: true, status: 502, provider: provider)
            return .failure(.upstreamError)
        }
        let object = !JSONDepth.isSafe(answer) ? nil : try? JSONSerialization.jsonObject(with: answer) as? [String: Any]
        await call.settle(usage: object.flatMap(Usage.init), accepted: true, status: upstream.status, provider: provider)
        return .complete(status: upstream.status, contentType: upstream.contentType, body: answer)
    }

    /// Streams the router's SSE to the guest as it reads it, cut before any copy of the token or
    /// after `maxStreamDuration`, then settles (also when the guest goes away).
    private func stream(
        _ upstream: RouterResponse, call: UpstreamCall, secret: Data, provider: String?
    ) -> AIBridgeResponse {
        let channel = ChunkChannel()
        let now = now
        let pump = Task {
            var filter = SecretFilter(secret: secret)
            var scanner = SSEUsageScanner()
            var status = upstream.status
            do {
                for try await chunk in upstream.body {
                    guard now().timeIntervalSince(call.started) <= Self.maxStreamDuration else {
                        status = 504
                        break
                    }
                    scanner.feed(chunk)
                    guard let safe = filter.feed(chunk) else {
                        status = 502
                        break
                    }
                    if !safe.isEmpty, !(await channel.send(safe)) { break }
                }
                if status == upstream.status, !Task.isCancelled {
                    let rest = filter.finish()
                    if !rest.isEmpty { _ = await channel.send(rest) }
                }
            } catch {
                status = 502
            }
            await call.settle(usage: scanner.usage, accepted: true, status: status, provider: provider)
            channel.finish()
        }
        channel.attach(pump)
        return AIBridgeResponse(
            status: upstream.status, contentType: upstream.contentType ?? "text/event-stream", contentLength: nil,
            body: AIBridgeBody(channel))
    }

    /// One admitted call: settles its reservation and writes its log line.
    private struct UpstreamCall: Sendable {
        let proxy: AIBridgeProxy
        let rewrite: ChatRewrite
        let reservation: AIBridgeReservation
        let started: Date

        /// `accepted`: the router answered `2xx`, so the call is charged (usage, else estimate).
        func settle(usage: Usage?, accepted: Bool, status: Int, provider: String?) async {
            var input = 0
            var output = 0
            var estimated = false
            let charged: Int
            if accepted {
                input = usage?.input ?? rewrite.promptEstimate
                output = usage?.output ?? rewrite.outputEstimate
                estimated = usage?.input == nil || usage?.output == nil
                let (total, overflow) = input.addingReportingOverflow(output)
                charged = await proxy.limiter.commit(
                    reservation, usage: overflow ? Int.max : total, chargeEstimateWithoutUsage: true)
            } else {
                charged = await proxy.limiter.commit(reservation, usage: nil, chargeEstimateWithoutUsage: false)
            }
            if charged == 0 { (input, output, estimated) = (0, 0, false) }
            proxy.record(
                rewrite, provider: provider, input: input, output: output, estimated: estimated, status: status,
                started: started)
        }
    }

    private func record(
        _ rewrite: ChatRewrite, provider: String?, input: Int, output: Int, estimated: Bool, status: Int, started: Date
    ) {
        guard let log else { return }
        let elapsed = max(0, now().timeIntervalSince(started)) * 1000
        log.append(AIBridgeLogEntry(
            time: started, model: rewrite.model, provider: provider, inputTokens: input, outputTokens: output,
            estimated: estimated, status: status, durationMs: elapsed < 1e12 ? Int(elapsed) : Int(1e12)))
    }

    /// The provider name for the log when it looks like one (`[A-Za-z0-9._-]{1,64}`).
    static func sanitizedProvider(_ value: String?) -> String? {
        guard let value, (1...64).contains(value.utf8.count),
            value.utf8.allSatisfy({ $0.isASCIIAlnum || $0 == 0x2D || $0 == 0x2E || $0 == 0x5F })
        else { return nil }
        return value
    }

    /// The whole body; throws when it fails or exceeds `limit`.
    static func collect(_ body: AsyncThrowingStream<Data, any Error>, limit: Int) async throws -> Data {
        var data = Data()
        for try await chunk in body {
            data.append(chunk)
            if data.count > limit { throw ByteStreamError.closed }
        }
        return data
    }
}

private extension UInt8 {
    var isASCIIAlnum: Bool { (0x30...0x39).contains(self) || (0x41...0x5A).contains(self) || (0x61...0x7A).contains(self) }
}

// MARK: - JSON depth

/// A linear pre-check before any recursive JSON parser touches data from the guest or the
/// network: deeply nested arrays or objects would exhaust the (small) stack of the thread
/// parsing them and crash the app. The scan reads bytes as UTF-8, while the Foundation parsers
/// also detect UTF-16/32: `isSafe` therefore first requires strict UTF-8 without BOM or NUL (a
/// UTF-16 body could otherwise hide its nesting from the scan). `JSONValue` bounds its own
/// depth too, whatever the encoding.
enum JSONDepth {
    /// Deepest nesting of `[` / `{` accepted.
    static let limit = 32

    /// Why `check` refused data.
    enum Refusal: Equatable {
        case notUTF8
        case tooDeep
    }

    /// Nil when `data` may go to a JSON parser: strict UTF-8, no byte-order mark, no NUL byte,
    /// nested at most `limit` deep.
    static func check(_ data: Data) -> Refusal? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) || data.contains(0) { return .notUTF8 }
        guard String(validating: data, as: UTF8.self) != nil else { return .notUTF8 }
        return exceeds(data) ? .tooDeep : nil
    }

    static func isSafe(_ data: Data) -> Bool { check(data) == nil }

    /// True when brackets outside strings nest deeper than `limit`.
    static func exceeds(_ data: Data, limit: Int = JSONDepth.limit) -> Bool {
        var depth = 0
        var inString = false
        var escaped = false
        for byte in data {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                }
                continue
            }
            switch byte {
            case 0x22: inString = true
            case 0x5B, 0x7B:
                depth += 1
                if depth > limit { return true }
            case 0x5D, 0x7D: depth -= 1
            default: break
            }
        }
        return false
    }
}

// MARK: - Usage

/// `usage.prompt_tokens` and `usage.completion_tokens` of an answer (or of an SSE event); a part
/// that is missing is nil (the estimate stands in for it).
struct Usage: Sendable, Equatable {
    let input: Int?
    let output: Int?

    init(input: Int?, output: Int?) {
        self.input = input
        self.output = output
    }

    /// Nil when there is no `usage` object or it has neither count (`total_tokens` alone counts
    /// as the input).
    init?(_ object: [String: Any]) {
        guard let usage = object["usage"] as? [String: Any] else { return nil }
        let prompt = Self.count(usage["prompt_tokens"])
        let completion = Self.count(usage["completion_tokens"])
        if prompt == nil, completion == nil {
            guard let total = Self.count(usage["total_tokens"]) else { return nil }
            (input, output) = (total, 0)
            return
        }
        (input, output) = (prompt, completion)
    }

    private static func count(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        guard d.isFinite, d >= 0 else { return nil }
        return d < 1e15 ? Int(d) : Int(1e15)
    }
}

/// Finds the `usage` of an SSE stream: the last `data:` event carrying one wins. Events nested
/// deeper than `JSONDepth.limit` are ignored.
struct SSEUsageScanner {
    private static let maxLine = 1 << 20
    private var line = Data()
    private var overflowed = false
    private(set) var usage: Usage?

    mutating func feed(_ chunk: Data) {
        for byte in chunk {
            if byte == 0x0A {
                if !overflowed { process(line) }
                line.removeAll(keepingCapacity: true)
                overflowed = false
            } else if !overflowed {
                line.append(byte)
                if line.count > Self.maxLine {
                    overflowed = true
                    line.removeAll()
                }
            }
        }
    }

    private mutating func process(_ line: Data) {
        var text = String(decoding: line, as: UTF8.self)
        if text.hasSuffix("\r") { text.removeLast() }
        guard text.hasPrefix("data:") else { return }
        let payload = Data(text.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)
        guard payload.first == 0x7B, JSONDepth.isSafe(payload),
            let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
            let found = Usage(object)
        else { return }
        usage = found
    }
}

/// Passes a stream on while making sure no complete copy of `secret` ever goes out. The secret
/// is visible ASCII without newlines, so only the bytes after the last newline, at most
/// `secret.count - 1` of them, are held back until the next chunk.
struct SecretFilter {
    let secret: Data
    private var pending = Data()

    init(secret: Data) { self.secret = secret }

    /// The bytes that can go out now, or nil when the secret appeared (stop the stream).
    mutating func feed(_ chunk: Data) -> Data? {
        pending.append(chunk)
        guard !secret.isEmpty else {
            defer { pending = Data() }
            return pending
        }
        if pending.range(of: secret) != nil { return nil }
        let afterNewline = pending.lastIndex(of: 0x0A).map { pending.endIndex - $0 - 1 } ?? pending.count
        let hold = min(afterNewline, secret.count - 1)
        let out = Data(pending.prefix(pending.count - hold))
        pending = Data(pending.suffix(hold))
        return out
    }

    /// What was held back, at the end of a stream that never held the secret.
    mutating func finish() -> Data {
        defer { pending = Data() }
        return pending
    }
}

// MARK: - Request rewriting

/// A chat request checked and rewritten for the router.
struct ChatRewrite: Sendable {
    let model: String
    let body: Data
    let stream: Bool
    /// `ceil(body bytes / 4)`.
    let promptEstimate: Int
    /// The effective `max_tokens` × `n`.
    let outputEstimate: Int

    var estimate: Int {
        let (sum, overflow) = promptEstimate.addingReportingOverflow(outputEstimate)
        return overflow ? Int.max : sum
    }

    init(_ raw: Data, maxTokens: Int) throws(AIBridgeFailure) {
        switch JSONDepth.check(raw) {
        case .notUTF8?: throw .invalidRequest("The request body must be UTF-8 JSON without a byte-order mark.")
        case .tooDeep?: throw .invalidRequest("The request body is nested too deeply (at most \(JSONDepth.limit) levels).")
        case nil: break
        }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: raw) else {
            throw .invalidRequest("The request body is not valid JSON.")
        }
        guard case .object(var object) = value else {
            throw .invalidRequest("The request body must be a JSON object.")
        }
        guard case .string(let model)? = object["model"], !model.isEmpty else {
            throw .invalidRequest("The request needs a model (a string).")
        }

        // Token limits: integers ≥ 1 (else refused: some backends read 0 or less as "no
        // limit"), clamped, and set when the guest gave none. `null` counts as absent.
        let limit = max(1, maxTokens)
        var requested: [Int] = []
        for key in ["max_tokens", "max_completion_tokens"] {
            guard let field = object[key] else { continue }
            if field == .null {
                object[key] = nil
                continue
            }
            guard let n = field.integer, n >= 1 else { throw .invalidRequest("\(key) must be an integer of at least 1.") }
            let clamped = min(n, limit)
            object[key] = .int(Int64(clamped))
            requested.append(clamped)
        }
        if requested.isEmpty {
            object["max_tokens"] = .int(Int64(limit))
            requested = [limit]
        }
        let perChoice = requested.max() ?? limit

        var choices = 1
        if let field = object["n"], field != .null {
            guard let n = field.integer, n >= 1 else { throw .invalidRequest("n must be a positive integer.") }
            choices = n
        }

        var stream = false
        if case .bool(true)? = object["stream"] {
            stream = true
            var options: [String: JSONValue]
            switch object["stream_options"] {
            case nil, .null?: options = [:]
            case .object(let existing)?: options = existing
            default: throw .invalidRequest("stream_options must be an object.")
            }
            options["include_usage"] = .bool(true)
            object["stream_options"] = .object(options)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let body = try? encoder.encode(JSONValue.object(object)) else {
            throw .invalidRequest("The request body could not be rewritten.")
        }
        self.model = model
        self.body = body
        self.stream = stream
        promptEstimate = (body.count + 3) / 4
        let (product, overflow) = perChoice.multipliedReportingOverflow(by: choices)
        outputEstimate = overflow ? Int.max : product
    }
}

/// Any JSON value, decoded and encoded without losing integers (64-bit) or the short form of
/// decimals (`0.7` stays `0.7`, unlike `JSONSerialization`).
enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Deepest coding path decoded or encoded (beyond `JSONDepth.limit`), whatever the encoding
    /// of the data: the recursion of this type stays bounded even if a pre-check is bypassed.
    static let maxCodingDepth = JSONDepth.limit + 1

    init(from decoder: any Decoder) throws {
        guard decoder.codingPath.count < Self.maxCodingDepth else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "JSON nested too deeply"))
        }
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int64.self) {
            self = .int(i)
        } else if let u = try? c.decode(UInt64.self) {
            self = .uint(u)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        guard encoder.codingPath.count <= Self.maxCodingDepth else {
            throw EncodingError.invalidValue(self, .init(codingPath: [], debugDescription: "JSON nested too deeply"))
        }
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .uint(let u): try c.encode(u)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// The value as an `Int` when it is a whole number (saturating), else nil.
    var integer: Int? {
        switch self {
        case .int(let i): return Int(i)
        case .uint(let u): return u > UInt64(Int.max) ? Int.max : Int(u)
        case .double(let d):
            guard d.isFinite, d.rounded() == d else { return nil }
            if d >= 9.2e18 { return Int.max }
            if d <= -9.2e18 { return Int.min }
            return Int(d)
        default: return nil
        }
    }
}
