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
    /// The owner's limit on a reply that brings an image (a screenshot or a zoom).
    public static let defaultImageTimeout: Duration = .seconds(15)

    public init(channel: any GuestChannel, timeout: Duration = defaultTimeout,
                screenshotTimeout: Duration = defaultImageTimeout) {
        self.channel = channel
        self.timeout = timeout
        self.screenshotTimeout = screenshotTimeout
    }

    /// Sends `request` and returns the helper's reply, plus the PNG that follows a successful
    /// screenshot reply. Throws `AgentFailure` for transport problems and for a helper that
    /// speaks another protocol version (`.versionMismatch`).
    public func perform(_ request: AgentRequest) async throws(AgentFailure) -> (reply: AgentReply, png: Data?) {
        let limit: Duration
        limit = request.action.isImageAction ? screenshotTimeout : timeout
        let channel = channel
        let connection = Connection()
        let result: (reply: AgentReply, png: Data?)
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
    private static func exchange(_ handle: FileHandle, _ request: AgentRequest) async throws -> (reply: AgentReply, png: Data?) {
        let fd = handle.fileDescriptor
        // A guest that drops the connection must give EPIPE, not kill the app with SIGPIPE.
        var one: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw AgentFrame.FrameError.io(errno: errno)
        }
        try AgentFrame.writeJSON(request, to: fd)
        let reply = try AgentFrame.readJSON(AgentReply.self, from: fd)
        guard request.action.isImageAction, reply.ok else { return (reply, nil) }
        return (reply, try AgentFrame.read(from: fd))
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
    var isImageAction: Bool {
        switch self {
        case .screenshot, .zoom: true
        default: false
        }
    }
}
