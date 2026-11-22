// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import NidoAgentKit
import Synchronization

/// Why an agent action did not reach the helper, or could not be understood. `message` is
/// localized for the user. Errors the helper itself reports (`screenChanged`, `permissionMissing`,
/// …) are not failures: they come back in `AgentReply.error`.
public struct AgentFailure: Error, Equatable, Sendable {
    public let code: AgentErrorCode
    public let message: String

    public init(code: AgentErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

/// The owner's side of the agent protocol: one vsock connection to Nido Agent (port 7710) per
/// `perform`, closed after the reply. All I/O runs off the calling actor, bounded by a deadline.
public struct AgentClient: Sendable {
    private let channel: any GuestChannel
    private let timeout: Duration
    private let screenshotTimeout: Duration

    /// The owner's limit on a reply of the helper.
    public static let defaultTimeout: Duration = .seconds(10)
    /// The owner's limit on a reply that brings an image (a screenshot or a zoom), or on a
    /// file's transfer (`putFile`, `getFile`: at most 16 MiB).
    public static let defaultImageTimeout: Duration = .seconds(15)

    public init(channel: any GuestChannel, timeout: Duration = defaultTimeout,
                screenshotTimeout: Duration = defaultImageTimeout) {
        self.channel = channel
        self.timeout = timeout
        self.screenshotTimeout = screenshotTimeout
    }

    /// Sends `request` and returns the helper's reply, plus the data frame that follows a
    /// successful screenshot, zoom or `getFile` reply (the PNG, the file's bytes). A `putFile`
    /// sends `request.payload` as a frame after the request: it must be there, `size` bytes long,
    /// at most `AgentProtocol.maxTransferBytes`, or nothing is sent (`.badRequest`). Throws
    /// `AgentFailure` for transport problems and for a helper that speaks another protocol
    /// version (`.versionMismatch`).
    public func perform(_ request: AgentRequest) async throws(AgentFailure) -> (reply: AgentReply, data: Data?) {
        if case .putFile(_, let size) = request.action {
            // The guest closes the connection on a size it refuses: never send one.
            guard let payload = request.payload, payload.count == size, size <= AgentProtocol.maxTransferBytes else {
                throw AgentFailure(code: .badRequest, message: L10n.string("the file’s data is missing, too large or of the wrong size"))
            }
        }
        let limit: Duration
        limit = request.action.isImageAction || request.action.isTransferAction ? screenshotTimeout : timeout
        let channel = channel
        let connection = Connection()
        let result: (reply: AgentReply, data: Data?)
        do {
            result = try await Deadline.run(limit) {
                let handle: FileHandle
                do {
                    handle = try await channel.connect(port: AgentProtocol.port)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw Self.connectFailure(error)
                }
                try connection.adopt(handle)
                return try await Self.exchange(handle, request)
            }
        } catch {
            connection.abort()  // unblocks a read that is still waiting for the helper
            throw Self.failure(error)
        }
        if result.reply.error == .versionMismatch {
            throw AgentFailure(
                code: .versionMismatch,
                message: L10n.string("incompatible Nido Agent version: run nido agent setup to update Nido Agent"))
        }
        return result
    }

    // MARK: - I/O (off the caller's actor)

    @concurrent
    private static func exchange(_ handle: FileHandle, _ request: AgentRequest) async throws -> (reply: AgentReply, data: Data?) {
        let fd = handle.fileDescriptor
        // A guest that drops the connection must give EPIPE, not kill the app with SIGPIPE.
        var one: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw AgentFrame.FrameError.io(errno: errno)
        }
        try AgentFrame.writeJSON(request, to: fd)
        // A guest that refuses the bytes closes the connection: EPIPE, a failure like any other.
        if case .putFile = request.action, let payload = request.payload {
            try AgentFrame.write(payload, to: fd)
        }
        let reply = try AgentFrame.readJSON(AgentReply.self, from: fd)
        guard reply.ok else { return (reply, nil) }
        switch request.action {
        case .getFile(_, let maxBytes):
            let data = try AgentFrame.read(from: fd, maxBytes: max(0, min(maxBytes, AgentProtocol.maxTransferBytes)))
            guard reply.bytes == data.count else {
                throw AgentFailure(code: .internalError, message: L10n.string("could not talk to Nido Agent"))
            }
            return (reply, data)
        case _ where request.action.isImageAction:
            return (reply, try AgentFrame.read(from: fd))
        default:
            return (reply, nil)
        }
    }

    // MARK: - Errors

    /// A reset, or no socket device at all, means no helper is listening yet (no login, or Nido
    /// Agent not started).
    private static func connectFailure(_ error: any Error) -> any Error {
        let nsError = error as NSError
        if let posix = error as? POSIXError, posix.code == .ECONNRESET { return notReady }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ECONNRESET) { return notReady }
        if let monitor = error as? MonitorError, monitor == .unavailable { return notReady }
        return error
    }

    private static var notReady: AgentFailure {
        AgentFailure(code: .notReady, message: L10n.string("waiting for login or Nido Agent"))
    }

    private static func failure(_ error: any Error) -> AgentFailure {
        if let failure = error as? AgentFailure { return failure }
        if let monitor = error as? MonitorError, monitor == .timeout {
            return AgentFailure(code: .timeout, message: L10n.string("Nido Agent did not answer in time"))
        }
        if error is CancellationError {
            return AgentFailure(code: .internalError, message: L10n.string("cancelled"))
        }
        return AgentFailure(code: .internalError, message: L10n.string("could not talk to Nido Agent"))
    }

    /// The connection once it exists, so a timeout can shut it down and free the blocked reader.
    /// A `connect` that finishes after the abort is shut down on adoption, so no worker stays
    /// blocked on a socket nobody waits for.
    private final class Connection: Sendable {
        private struct State {
            var handle: FileHandle?
            var aborted = false
        }
        private let state = Mutex(State())

        func adopt(_ new: FileHandle) throws {
            let aborted = state.withLock { s -> Bool in
                if !s.aborted { s.handle = new }
                return s.aborted
            }
            if aborted {
                shutdown(new.fileDescriptor, SHUT_RDWR)
                throw CancellationError()
            }
        }

        func abort() {
            let fd = state.withLock { s -> Int32? in
                s.aborted = true
                return s.handle?.fileDescriptor
            }
            if let fd { shutdown(fd, SHUT_RDWR) }
        }
    }
}

extension AgentAction {
    /// Actions the helper answers with a reply and then a PNG frame (a screenshot or a zoom).
    /// A `uiTree` answers with a reply only.
    var isImageAction: Bool {
        switch self {
        case .screenshot, .zoom: true
        default: false
        }
    }

    /// Actions that carry a file's bytes after the request (`putFile`) or the reply (`getFile`).
    var isTransferAction: Bool {
        switch self {
        case .putFile, .getFile: true
        default: false
        }
    }
}
