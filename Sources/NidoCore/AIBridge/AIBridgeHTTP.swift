// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import Synchronization

// MARK: - Transport

/// A connection from the guest, whatever carries it (virtio-socket in the app, memory in tests).
public protocol ByteStream: Sendable {
    /// Up to `maxCount` bytes as soon as some are available; empty at end of stream. Throws
    /// `ByteStreamError.timeout` when nothing arrived before `deadline`.
    func read(upTo maxCount: Int, deadline: ContinuousClock.Instant) async throws -> Data
    /// Writes all of `data` or throws.
    func write(_ data: Data) async throws
    /// Closes the connection; later calls do nothing.
    func close() async
}

public enum ByteStreamError: Error, Equatable, Sendable {
    case timeout
    case closed
    case io(Int32)
}

/// A `ByteStream` over a socket descriptor (e.g. a `VZVirtioSocketConnection`'s, `dup`ed into a
/// `FileHandle` that owns it). Non-blocking I/O; no SIGPIPE. Waiting for the descriptor holds no
/// thread: a one-shot `DispatchSource` resumes the waiting task when the descriptor is ready, at
/// the deadline, when the task is cancelled or when the stream is closed, whichever comes first.
final class FileDescriptorByteStream: ByteStream {
    private let handle: FileHandle
    private let writeTimeout: Duration
    /// Closed, and the wait in progress (at most one read and one write at a time).
    private let state = Mutex<(closed: Bool, waits: [ObjectIdentifier: ReadinessWait])>((false, [:]))

    /// Takes over `fileHandle` (closed by `close()`); a write waits at most `writeTimeout` for
    /// the guest to take bytes.
    init(fileHandle: FileHandle, writeTimeout: Duration = .seconds(30)) {
        handle = fileHandle
        self.writeTimeout = writeTimeout
        let fd = fileHandle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit {
        if !state.withLock({ $0.closed }) { try? handle.close() }
    }

    private var fd: Int32 { handle.fileDescriptor }

    public func read(upTo maxCount: Int, deadline: ContinuousClock.Instant) async throws -> Data {
        guard maxCount > 0 else { return Data() }
        var buffer = [UInt8](repeating: 0, count: maxCount)
        while true {
            guard !state.withLock({ $0.closed }) else { throw ByteStreamError.closed }
            let n = Darwin.read(fd, &buffer, maxCount)
            if n > 0 { return Data(buffer[0..<n]) }
            if n == 0 { return Data() }
            guard errno == EAGAIN || errno == EINTR else { throw ByteStreamError.io(errno) }
            try await wait(.read, until: deadline)
        }
    }

    public func write(_ data: Data) async throws {
        let deadline = ContinuousClock.now.advanced(by: writeTimeout)
        let bytes = [UInt8](data)
        var sent = 0
        while sent < bytes.count {
            guard !state.withLock({ $0.closed }) else { throw ByteStreamError.closed }
            let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + sent, bytes.count - sent) }
            if n > 0 {
                sent += n
                continue
            }
            guard n < 0, errno == EAGAIN || errno == EINTR else { throw ByteStreamError.io(n < 0 ? errno : EPIPE) }
            try await wait(.write, until: deadline)
        }
    }

    public func close() async {
        let (wasClosed, waits) = state.withLock { s -> (Bool, [ReadinessWait]) in
            defer { s.closed = true; s.waits = [:] }
            return (s.closed, Array(s.waits.values))
        }
        // The sources stop watching the descriptor before it is closed (Dispatch's rule: close
        // only after the cancel handler ran).
        for wait in waits {
            wait.finish(.failure(ByteStreamError.closed))
            await wait.sourceCancelled()
        }
        if !wasClosed { try? handle.close() }
    }

    /// Returns when `fd` is ready for `kind`; throws `.timeout` at `deadline`, `CancellationError`
    /// when the task is cancelled, `.closed` when the stream is closed meanwhile.
    private func wait(_ kind: ReadinessWait.Kind, until deadline: ContinuousClock.Instant) async throws {
        try Task.checkCancellation()
        guard deadline > .now else { throw ByteStreamError.timeout }
        let wait = ReadinessWait(fd: fd, kind: kind, deadline: deadline)
        let id = ObjectIdentifier(wait)
        let closed = state.withLock { s -> Bool in
            if !s.closed { s.waits[id] = wait }
            return s.closed
        }
        guard !closed else { throw ByteStreamError.closed }
        let result: Result<Void, any Error>
        do {
            try await withTaskCancellationHandler {
                try await wait.value()
            } onCancel: {
                wait.finish(.failure(CancellationError()))
            }
            result = .success(())
        } catch {
            result = .failure(error)
        }
        // However the wait ended, its source stops watching the descriptor before the stream can
        // close it (`close()` right after a read is the normal end of every connection).
        await wait.sourceCancelled()
        _ = state.withLock { $0.waits.removeValue(forKey: id) }
        try result.get()
    }
}

/// One wait for a descriptor to become readable or writable: a dispatch source on the descriptor
/// and a timer for the deadline, cancelled together by the first `finish`, which resumes the
/// waiting task once. `@unchecked Sendable`: the sources are made and resumed in `init` and then
/// only cancelled (by the first `finish` and in `deinit`), which Dispatch allows from any thread
/// and more than once; the continuation is only touched under `lock`.
private final class ReadinessWait: @unchecked Sendable {
    enum Kind { case read, write }

    private enum State {
        case pending
        case waiting(CheckedContinuation<Void, any Error>)
        case finished(Result<Void, any Error>)
    }

    private static let queue = DispatchQueue(label: "nido.ai-bridge.readiness")
    private let lock = Mutex<State>(.pending)
    private let source: any DispatchSourceProtocol
    private let timer: any DispatchSourceTimer
    /// Left when the descriptor's source has been cancelled.
    private let sourceGone = DispatchGroup()

    init(fd: Int32, kind: Kind, deadline: ContinuousClock.Instant) {
        source = switch kind {
        case .read: DispatchSource.makeReadSource(fileDescriptor: fd, queue: Self.queue)
        case .write: DispatchSource.makeWriteSource(fileDescriptor: fd, queue: Self.queue)
        }
        timer = DispatchSource.makeTimerSource(queue: Self.queue)
        let left = deadline - .now
        let nanoseconds = max(0, left.components.seconds) * 1_000_000_000
            + max(0, left.components.attoseconds / 1_000_000_000)
        // Wall time, like the `ContinuousClock` deadline: it keeps counting while the Mac sleeps.
        timer.schedule(wallDeadline: .now() + .nanoseconds(Int(min(nanoseconds, Int64(Int.max)))))
        source.setEventHandler { [weak self] in self?.finish(.success(())) }
        sourceGone.enter()
        source.setCancelHandler { [sourceGone] in sourceGone.leave() }
        timer.setEventHandler { [weak self] in self?.finish(.failure(ByteStreamError.timeout)) }
        source.resume()
        timer.resume()
    }

    func value() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let early = lock.withLock { state -> Result<Void, any Error>? in
                switch state {
                case .pending:
                    state = .waiting(continuation)
                    return nil
                case .finished(let result):
                    return result
                case .waiting:
                    preconditionFailure("ReadinessWait awaited twice")
                }
            }
            if let early { continuation.resume(with: early) }
        }
    }

    /// The first call wins: stops both sources and resumes the waiting task (or keeps the result
    /// for a `value()` still to come).
    func finish(_ result: Result<Void, any Error>) {
        let continuation = lock.withLock { state -> CheckedContinuation<Void, any Error>?? in
            switch state {
            case .pending:
                state = .finished(result)
                return .some(nil)
            case .waiting(let continuation):
                state = .finished(result)
                return .some(continuation)
            case .finished:
                return nil
            }
        }
        guard let continuation else { return }
        source.cancel()
        timer.cancel()
        continuation?.resume(with: result)
    }

    /// Returns once the descriptor's source no longer watches it.
    func sourceCancelled() async {
        await withCheckedContinuation { continuation in
            sourceGone.notify(queue: Self.queue) { continuation.resume() }
        }
    }

    deinit {
        source.cancel()
        timer.cancel()
    }
}

// MARK: - Errors for the guest

/// A refusal of the bridge, sent to the guest as an OpenAI-style error
/// `{"error": {"message", "type", "code"}}` with an English message. Codes (status):
/// `bridge_disabled` (403), `token_missing` (401), `model_not_allowed` (403), `rate_limited`
/// (429), `daily_budget_exhausted` (429), `request_too_large` (413), `length_required` (411),
/// `not_found` (404), `invalid_request` (400; and 408 when the request is not fully received
/// within `AIBridgeHTTP.readTimeout`), `upstream_error` (502). A `4xx`/`5xx` of the router itself
/// keeps its status with a fixed explanation (`router(status:)`): never the router's own body,
/// which may name the account behind the token.
public struct AIBridgeFailure: Error, Equatable, Sendable {
    public let status: Int
    public let type: String
    public let code: String
    public let message: String

    public init(status: Int, type: String, code: String, message: String) {
        self.status = status
        self.type = type
        self.code = code
        self.message = message
    }

    public static let bridgeDisabled = AIBridgeFailure(
        status: 403, type: "permission_error", code: "bridge_disabled",
        message: "The Nido AI bridge is turned off for this VM. Turn it on in Nido on the Mac.")
    public static let tokenMissing = AIBridgeFailure(
        status: 401, type: "authentication_error", code: "token_missing",
        message: "No Hugging Face token is set up in Nido on the Mac.")
    public static let modelNotAllowed = AIBridgeFailure(
        status: 403, type: "permission_error", code: "model_not_allowed",
        message: "This model is not allowed for this VM. Allow it in Nido on the Mac.")
    public static let rateLimited = AIBridgeFailure(
        status: 429, type: "rate_limit_error", code: "rate_limited",
        message: "Too many requests for this VM. Wait a moment and try again.")
    public static let dailyBudgetExhausted = AIBridgeFailure(
        status: 429, type: "insufficient_quota", code: "daily_budget_exhausted",
        message: "The daily token budget of this VM is used up. It resets at local midnight.")
    public static let requestTooLarge = AIBridgeFailure(
        status: 413, type: "invalid_request_error", code: "request_too_large",
        message: "The request is too large (headers at most 16 KiB, body at most 1 MiB).")
    public static let lengthRequired = AIBridgeFailure(
        status: 411, type: "invalid_request_error", code: "length_required",
        message: "A Content-Length header is required; chunked requests are not accepted.")
    public static let notFound = AIBridgeFailure(
        status: 404, type: "invalid_request_error", code: "not_found",
        message: "Only POST /v1/chat/completions and GET /v1/models are available.")
    public static let requestTimeout = AIBridgeFailure(
        status: 408, type: "invalid_request_error", code: "invalid_request",
        message: "The request was not received in time.")
    public static let upstreamError = AIBridgeFailure(
        status: 502, type: "api_error", code: "upstream_error",
        message: "The Hugging Face router could not be reached or gave an invalid answer.")

    /// The router refused the call with `status` (`4xx`/`5xx`).
    public static func router(status: Int) -> AIBridgeFailure {
        switch status {
        case 401, 403:
            AIBridgeFailure(
                status: status, type: "authentication_error", code: "upstream_unauthorized",
                message: "Hugging Face refused the token set up in Nido on the Mac.")
        case 402:
            AIBridgeFailure(
                status: status, type: "insufficient_quota", code: "upstream_payment_required",
                message: "Hugging Face asks for payment or credits for this call. Check the account in Nido on the Mac.")
        case 404:
            AIBridgeFailure(
                status: status, type: "invalid_request_error", code: "upstream_not_found",
                message: "Hugging Face does not serve this model with this provider.")
        case 408, 504:
            AIBridgeFailure(
                status: status, type: "api_error", code: "upstream_timeout",
                message: "Hugging Face or the provider did not answer in time. Try again.")
        case 429:
            AIBridgeFailure(
                status: status, type: "rate_limit_error", code: "upstream_rate_limited",
                message: "Hugging Face is limiting requests. Wait a moment and try again.")
        case 500..<600:
            AIBridgeFailure(
                status: status, type: "api_error", code: "upstream_unavailable",
                message: "Hugging Face or the provider had an error. Try again later.")
        default:
            AIBridgeFailure(
                status: status, type: "invalid_request_error", code: "upstream_invalid_request",
                message: "Hugging Face refused the request as invalid (model, parameters or size).")
        }
    }

    public static func invalidRequest(_ message: String) -> AIBridgeFailure {
        AIBridgeFailure(status: 400, type: "invalid_request_error", code: "invalid_request", message: message)
    }

    /// The JSON body.
    public var body: Data {
        let object = ["error": ["message": message, "type": type, "code": code]]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}

// MARK: - HTTP/1.1

/// A request of the guest. Header names are lowercased; the query string is not kept.
public struct AIBridgeRequest: Sendable, Equatable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

/// The minimal server side of HTTP/1.1 the bridge needs: one request per connection
/// (request line and headers at most 16 KiB, `Content-Length` required for a body, no
/// `Transfer-Encoding`, body at most 1 MiB, everything within 10 s) and answers that always
/// close the connection.
public enum AIBridgeHTTP {
    public static let maxHeaderBytes = 16 * 1024
    public static let maxBodyBytes = 1 << 20
    public static let readTimeout: Duration = .seconds(10)

    private static let headerEnd = Data("\r\n\r\n".utf8)

    /// Reads one request from `stream`, or throws the refusal to send back.
    public static func readRequest(
        from stream: some ByteStream, timeout: Duration = AIBridgeHTTP.readTimeout
    ) async throws(AIBridgeFailure) -> AIBridgeRequest {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var buffer = Data()
        var headRange: Range<Data.Index>?
        while headRange == nil {
            let chunk = try await read(stream, upTo: maxHeaderBytes + 4 - buffer.count, deadline: deadline)
            guard !chunk.isEmpty else { throw .invalidRequest("The request ended before its headers.") }
            buffer.append(chunk)
            headRange = buffer.range(of: headerEnd)
            if headRange == nil, buffer.count >= maxHeaderBytes + 4 { throw .requestTooLarge }
        }
        guard let headRange, headRange.lowerBound - buffer.startIndex <= maxHeaderBytes else {
            throw .requestTooLarge
        }
        var request = try parseHead(buffer[buffer.startIndex..<headRange.lowerBound])
        let length = try bodyLength(method: request.method, headers: request.headers)
        var body = Data(buffer[headRange.upperBound...])
        while body.count < length {
            let chunk = try await read(stream, upTo: min(64 * 1024, length - body.count), deadline: deadline)
            guard !chunk.isEmpty else { throw .invalidRequest("The request body is shorter than its Content-Length.") }
            body.append(chunk)
        }
        request.body = Data(body.prefix(length))
        return request
    }

    private static func read(
        _ stream: some ByteStream, upTo count: Int, deadline: ContinuousClock.Instant
    ) async throws(AIBridgeFailure) -> Data {
        do {
            return try await stream.read(upTo: max(count, 1), deadline: deadline)
        } catch ByteStreamError.timeout {
            throw .requestTimeout
        } catch {
            throw .invalidRequest("The connection failed while reading the request.")
        }
    }

    /// Request line and headers (without the final empty line).
    static func parseHead(_ head: Data) throws(AIBridgeFailure) -> AIBridgeRequest {
        // Visible ASCII, space, tab and CRLF only.
        guard head.allSatisfy({ (0x20...0x7E).contains($0) || $0 == 0x09 || $0 == 0x0D || $0 == 0x0A }) else {
            throw .invalidRequest("The request headers contain invalid characters.")
        }
        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        // A bare CR or LF inside a line (only CRLF separates lines) is refused.
        guard !lines.contains(where: { $0.utf8.contains(0x0D) || $0.utf8.contains(0x0A) }) else {
            throw .invalidRequest("The request contains a bare CR or LF.")
        }
        let parts = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, parts[0].allSatisfy({ $0.isUppercase && $0.isASCII }),
            parts[1].hasPrefix("/"), parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0"
        else { throw .invalidRequest("The request line is not valid HTTP/1.1.") }
        let target = parts[1]
        let path = target.firstIndex(of: "?").map { String(target[..<$0]) } ?? String(target)

        var headers: [String: String] = [:]
        var lengths: Set<String> = []
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                throw .invalidRequest("A request header is malformed.")
            }
            let name = line[..<colon]
            guard !name.isEmpty, name.allSatisfy({ $0.isASCII && !$0.isWhitespace && $0 != "\t" }) else {
                throw .invalidRequest("A request header is malformed.")
            }
            let key = name.lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if key == "content-length" { lengths.insert(value) }
            headers[key] = headers[key].map { "\($0), \(value)" } ?? value
        }
        if lengths.count > 1 { throw .invalidRequest("Conflicting Content-Length headers.") }
        if let length = lengths.first { headers["content-length"] = length }
        return AIBridgeRequest(method: String(parts[0]), path: path, headers: headers)
    }

    /// The declared body length: `Transfer-Encoding` of any kind and a `POST` without
    /// `Content-Length` are `411`, over `maxBodyBytes` is `413`.
    private static func bodyLength(method: String, headers: [String: String]) throws(AIBridgeFailure) -> Int {
        if headers["transfer-encoding"] != nil { throw .lengthRequired }
        guard let value = headers["content-length"] else {
            if method == "POST" { throw .lengthRequired }
            return 0
        }
        guard !value.isEmpty, value.count <= 12, value.allSatisfy({ $0.isASCII && $0.isNumber }), let length = Int(value)
        else { throw .invalidRequest("Content-Length is not a valid number.") }
        guard length <= maxBodyBytes else { throw .requestTooLarge }
        return length
    }

    // MARK: Answers

    /// Status line and headers of an answer. Without `contentLength` the body ends when the
    /// connection closes (used for SSE).
    public static func responseHead(status: Int, contentType: String?, contentLength: Int?) -> Data {
        var head = "HTTP/1.1 \(status) \(reasonPhrase(status))\r\n"
        if let contentType = sanitizedContentType(contentType) { head += "Content-Type: \(contentType)\r\n" }
        if let contentLength { head += "Content-Length: \(contentLength)\r\n" }
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8)
    }

    /// A whole error answer.
    public static func errorResponse(_ failure: AIBridgeFailure) -> Data {
        let body = failure.body
        return responseHead(status: failure.status, contentType: "application/json", contentLength: body.count) + body
    }

    /// The router's content type when it is short visible ASCII (never a header injection).
    static func sanitizedContentType(_ value: String?) -> String? {
        guard let value, (1...200).contains(value.utf8.count),
            value.utf8.allSatisfy({ (0x20...0x7E).contains($0) })
        else { return nil }
        return value
    }

    static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 402: "Payment Required"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 408: "Request Timeout"
        case 411: "Length Required"
        case 413: "Content Too Large"
        case 422: "Unprocessable Content"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        case 504: "Gateway Timeout"
        default: "Status"
        }
    }
}
