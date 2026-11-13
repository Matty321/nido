// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import ObjectiveC
import Synchronization
import Virtualization

/// A way to open a byte stream to a port of one guest. The real one is virtio-socket
/// (`VsockGuestChannel`); tests use socketpairs.
public protocol GuestChannel: Sendable {
    /// Opens a connection to `port`. The returned handle owns the connection: dropping it closes it.
    func connect(port: UInt32) async throws -> FileHandle
}

/// The guest's monitor over a `GuestChannel`: one `GET /api/status` per `fetch`, HTTP/1.0,
/// answer at most 64 KiB, 2 s for everything (connect, request, answer). All I/O runs off the
/// calling actor.
public struct GuestMonitorClient: Sendable {
    public static let port: UInt32 = 7700
    public static let defaultTimeout: Duration = .seconds(2)
    public static let maxResponseBytes = 64 * 1024

    private let channel: any GuestChannel
    private let timeout: Duration

    public init(channel: any GuestChannel, timeout: Duration = GuestMonitorClient.defaultTimeout) {
        self.channel = channel
        self.timeout = timeout
    }

    /// The guest's status. Throws `MonitorError`, or `CancellationError` when the calling task is
    /// cancelled (the poller stops itself that way). A protocol major version other than 2 throws
    /// `.unsupportedVersion(version)`; use `fetchAllowingUnsupportedVersion` to still get what it sent.
    public func fetch() async throws -> GuestStatus {
        let status = try await fetchAllowingUnsupportedVersion()
        guard status.isSupportedVersion else { throw MonitorError.unsupportedVersion(status.version ?? "") }
        return status
    }

    /// Like `fetch` but returns a well-formed status of an unknown version too (check
    /// `isSupportedVersion`), so the UI can show what it has next to "versione non riconosciuta".
    public func fetchAllowingUnsupportedVersion() async throws -> GuestStatus {
        let channel = channel
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let body: Data
        do {
            body = try await Deadline.run(timeout) {
                let handle: FileHandle
                do {
                    handle = try await channel.connect(port: Self.port)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw MonitorError.unavailable
                }
                return try await Self.exchange(handle, deadline: deadline)
            }
        }
        return try GuestStatus.decode(body)
    }

    // MARK: - I/O (off the caller's actor)

    @concurrent
    private static func exchange(_ handle: FileHandle, deadline: ContinuousClock.Instant) async throws -> Data {
        let fd = handle.fileDescriptor
        guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { throw MonitorError.unavailable }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let request = Array("GET /api/status HTTP/1.0\r\nHost: guest\r\nAccept: application/json\r\n\r\n".utf8)
        try writeAll(fd, request, deadline: deadline)
        let raw = try readAll(fd, deadline: deadline)
        return try body(of: raw)
    }

    private static func millisecondsLeft(until deadline: ContinuousClock.Instant) throws -> Int32 {
        try Task.checkCancellation()
        let left = deadline - ContinuousClock.now
        guard left > .zero else { throw MonitorError.timeout }
        // Wake at least every 100 ms to notice a cancellation.
        let ms = left.components.seconds * 1000 + left.components.attoseconds / 1_000_000_000_000_000
        return Int32(min(max(ms, 1), 100))
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8], deadline: ContinuousClock.Instant) throws {
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + sent, bytes.count - sent) }
            if n > 0 { sent += n; continue }
            if n < 0, errno == EAGAIN || errno == EINTR {
                var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&p, 1, try millisecondsLeft(until: deadline))
                continue
            }
            throw MonitorError.unavailable
        }
    }

    /// Reads until the peer closes, or the headers and `Content-Length` bytes are in.
    /// Over `maxResponseBytes` is invalid.
    private static func readAll(_ fd: Int32, deadline: ContinuousClock.Instant) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            if let expected = try completeLength(of: data), data.count >= expected { return data }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&p, 1, try millisecondsLeft(until: deadline))
            if ready < 0, errno != EINTR { throw MonitorError.invalidResponse }
            if ready <= 0 { continue }
            let n = read(fd, &buffer, buffer.count)
            if n == 0 { return data }
            if n < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                // A reset after some bytes is a truncated answer, before any is "no one there".
                throw data.isEmpty ? MonitorError.unavailable : MonitorError.invalidResponse
            }
            data.append(buffer, count: n)
            if data.count > maxResponseBytes { throw MonitorError.invalidResponse }
        }
    }

    // MARK: - HTTP/1.0 (minimal)

    private static let headerEnd = Data("\r\n\r\n".utf8)

    /// Total bytes (headers plus body) of the answer when the headers are complete and carry
    /// `Content-Length`; nil while unknown.
    private static func completeLength(of data: Data) throws -> Int? {
        guard let range = data.range(of: headerEnd),
            let length = try contentLength(in: data[data.startIndex..<range.lowerBound])
        else { return nil }
        return range.upperBound - data.startIndex + length
    }

    /// The declared length; a value that is not a number, is negative or exceeds
    /// `maxResponseBytes` is an invalid response (a hostile guest must not overflow the sums).
    private static func contentLength(in head: Data) throws -> Int? {
        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].lowercased() == "content-length" {
                guard let value = Int(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)),
                    (0...maxResponseBytes).contains(value)
                else { throw MonitorError.invalidResponse }
                return value
            }
        }
        return nil
    }

    /// The body of a `200` answer; anything else, or fewer bytes than `Content-Length`, is invalid.
    static func body(of raw: Data) throws -> Data {
        guard let range = raw.range(of: headerEnd) else { throw MonitorError.invalidResponse }
        let head = raw[raw.startIndex..<range.lowerBound]
        let statusLine = String(decoding: head.prefix(while: { $0 != 13 }), as: UTF8.self)
        let parts = statusLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), parts[1] == "200" else {
            throw MonitorError.invalidResponse
        }
        let body = raw[range.upperBound...]
        if let length = try contentLength(in: head) {
            guard body.count >= length else { throw MonitorError.invalidResponse }
            return Data(body.prefix(length))
        }
        return Data(body)
    }
}

/// Runs `work`, giving up with `MonitorError.timeout` after `limit`. The result of work that is
/// not cancellable (e.g. a pending `connect`) is dropped when it finally arrives.
private enum Deadline {
    static func run<T: Sendable>(
        _ limit: Duration, _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let gate = Gate<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                let worker = Task {
                    do { gate.finish(.success(try await work())) } catch { gate.finish(.failure(error)) }
                }
                let timer = Task {
                    do {
                        try await Task.sleep(for: limit)
                        gate.finish(.failure(MonitorError.timeout))
                    } catch {}
                }
                gate.onFinish { worker.cancel(); timer.cancel() }
            }
        } onCancel: {
            gate.finish(.failure(CancellationError()))
        }
    }

    /// Delivers the first result to the continuation, once.
    private final class Gate<T: Sendable>: Sendable {
        private struct State {
            var continuation: CheckedContinuation<T, any Error>?
            var finished = false
            var result: Result<T, any Error>?
            var cleanup: (@Sendable () -> Void)?
        }
        private let state = Mutex(State())

        func install(_ continuation: CheckedContinuation<T, any Error>) {
            let early = state.withLock { s -> Result<T, any Error>? in
                s.continuation = continuation
                return s.finished ? s.result : nil
            }
            if let early { continuation.resume(with: early) }
        }

        func onFinish(_ cleanup: @escaping @Sendable () -> Void) {
            let run = state.withLock { s -> Bool in
                s.cleanup = cleanup
                return s.finished
            }
            if run { cleanup() }
        }

        func finish(_ result: Result<T, any Error>) {
            let (continuation, cleanup) = state.withLock { s -> (CheckedContinuation<T, any Error>?, (@Sendable () -> Void)?) in
                guard !s.finished else { return (nil, nil) }
                s.finished = true
                s.result = result
                return (s.continuation, s.cleanup)
            }
            continuation?.resume(with: result)
            cleanup?()
        }
    }
}

/// The real channel: virtio-socket to a VM's session. `connect` runs on the main actor (the
/// VM's queue); the connection's file descriptor is then used off it by the client.
public struct VsockGuestChannel: GuestChannel {
    private let session: VMSession

    public init(session: VMSession) {
        self.session = session
    }

    public func connect(port: UInt32) async throws -> FileHandle {
        try await Self.open(session: session, port: port)
    }

    @MainActor
    private static func open(session: VMSession, port: UInt32) async throws -> FileHandle {
        guard let device = session.socketDevice else { throw MonitorError.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            device.connect(toPort: port) { result in
                switch result {
                case .success(let connection):
                    continuation.resume(returning: ConnectionHandle.make(connection))
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// A `FileHandle` on a vsock connection's descriptor that keeps the `VZVirtioSocketConnection`
/// alive (closing the connection closes the descriptor) and does not close it itself.
private enum ConnectionHandle {
    nonisolated(unsafe) private static var key: UInt8 = 0

    static func make(_ connection: VZVirtioSocketConnection) -> FileHandle {
        let handle = FileHandle(fileDescriptor: connection.fileDescriptor, closeOnDealloc: false)
        objc_setAssociatedObject(handle, &key, connection, .OBJC_ASSOCIATION_RETAIN)
        return handle
    }
}
