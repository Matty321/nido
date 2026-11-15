// SPDX-License-Identifier: Apache-2.0
import CVsock
import Darwin
import Foundation
import NidoAgentKit
import os

/// Listens on vsock port 7710 for the host (the process that owns the VM). One connection per
/// request: read one `AgentRequest` frame, write one `AgentReply` frame (plus the PNG of a
/// screenshot), close. Connections are served one at a time on a dedicated thread.
final class VsockListener: Sendable {
    enum State: Equatable, Sendable {
        case starting
        /// Listening for the host.
        case ready
        /// The VM has no vsock device: agent access is off for it in Nido.
        case agentAccessOff
        /// Something else went wrong; retrying.
        case failed(errno: Int32)
    }

    /// How long a stalled host may hold a connection, per read or write.
    static let ioTimeout: Int = 15
    /// How long one request may take in the dispatcher before the host is told it timed out.
    static let handleTimeout: TimeInterval = 20
    /// Delay before trying to listen again.
    static let retryDelay: TimeInterval = 5
    /// Largest request frame accepted (a request is small JSON; text is at most 4096 bytes).
    static let maxRequestBytes = 1 << 16

    private let dispatcher: AgentDispatcher
    private let onState: @Sendable (State) -> Void
    private let lastState = OSAllocatedUnfairLock<State?>(initialState: nil)
    /// True while a dispatcher task runs, including one whose request already timed out.
    private let busy = OSAllocatedUnfairLock(initialState: false)

    init(dispatcher: AgentDispatcher, onState: @escaping @Sendable (State) -> Void) {
        self.dispatcher = dispatcher
        self.onState = onState
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "Nido Agent vsock listener"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    // MARK: - Listening

    private func run() {
        report(.starting)
        while true {
            let fd = socket(AF_VSOCK, SOCK_STREAM, 0)
            if fd < 0 {
                notListening(errno, during: "socket(AF_VSOCK)")
                Thread.sleep(forTimeInterval: Self.retryDelay)
                continue
            }
            if let err = Self.bindAndListen(fd) {
                close(fd)
                notListening(err, during: "bind/listen on vsock port \(AgentProtocol.port)")
                Thread.sleep(forTimeInterval: Self.retryDelay)
                continue
            }
            Log.listener.notice("listening on vsock port \(AgentProtocol.port, privacy: .public)")
            report(.ready)
            let err = acceptLoop(fd)
            close(fd)
            Log.listener.error("accept failed: errno \(err, privacy: .public); listening again in 5 s")
            report(.failed(errno: err))
            Thread.sleep(forTimeInterval: Self.retryDelay)
        }
    }

    /// ENODEV (no vsock device) or EADDRNOTAVAIL (no vsock address) means the VM has no vsock
    /// device, which Nido attaches only with agent access on. Anything else is a real failure.
    private func notListening(_ err: Int32, during step: String) {
        if err == ENODEV || err == EADDRNOTAVAIL {
            if lastState.withLock({ $0 }) != .agentAccessOff {
                Log.listener.notice("\(step, privacy: .public): errno \(err, privacy: .public), no vsock device: agent access is off for this VM; retrying every 5 s")
            }
            report(.agentAccessOff)
        } else {
            Log.listener.error("\(step, privacy: .public) failed: errno \(err, privacy: .public)")
            report(.failed(errno: err))
        }
    }

    /// Returns errno on failure.
    private static func bindAndListen(_ fd: Int32) -> Int32? {
        var address = sockaddr_vm()
        address.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
        address.svm_family = sa_family_t(AF_VSOCK)
        address.svm_port = AgentProtocol.port
        address.svm_cid = UInt32.max  // VMADDR_CID_ANY, (-1U): a macro Swift does not import.
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_vm>.size))
            }
        }
        guard bound == 0 else { return errno }
        guard listen(fd, 4) == 0 else { return errno }
        return nil
    }

    /// Serves connections until `accept` fails for good; returns its errno.
    private func acceptLoop(_ listener: Int32) -> Int32 {
        while true {
            var peer = sockaddr_vm()
            var length = socklen_t(MemoryLayout<sockaddr_vm>.size)
            let fd = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listener, $0, &length) }
            }
            if fd < 0 {
                let err = errno
                if err == EINTR || err == ECONNABORTED { continue }
                return err
            }
            guard peer.svm_cid == UInt32(VMADDR_CID_HOST) else {
                Log.listener.notice("dropped a connection from cid \(peer.svm_cid, privacy: .public): only the host may connect")
                close(fd)
                continue
            }
            serve(fd)
            close(fd)
        }
    }

    // MARK: - One connection

    private func serve(_ fd: Int32) {
        Self.configure(fd)
        let frame: Data
        do {
            frame = try AgentFrame.read(from: fd, maxBytes: Self.maxRequestBytes)
        } catch {
            if case .tooLarge = error as? AgentFrame.FrameError {
                write(AgentReply(ok: false, error: .badRequest, message: "the request is too large"), png: nil, to: fd)
            } else {
                // The host went away or stalled; there is nobody to answer.
                Log.listener.error("could not read a request: \(String(describing: error), privacy: .public)")
            }
            return
        }

        switch AgentDispatcher.decodeRequest(frame) {
        case .refused(let reply):
            write(reply, png: nil, to: fd)
        case .request(let request):
            let (reply, png) = handle(request)
            write(reply, png: png, to: fd)
        }
    }

    /// Runs the async dispatcher from this (non-async) thread and waits for it, bounded.
    /// One request at a time for real: while a timed-out request's task is still running,
    /// new requests are refused, so its late input never interleaves with new input.
    private func handle(_ request: AgentRequest) -> (AgentReply, Data?) {
        let wasBusy = busy.withLock { busy in
            defer { busy = true }
            return busy
        }
        if wasBusy {
            Log.listener.notice("refused a request: the previous one is still running")
            return (AgentReply(ok: false, error: .timeout, message: "Nido Agent is still finishing the previous action"), nil)
        }
        let result = OSAllocatedUnfairLock<(AgentReply, Data?)?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        let dispatcher = dispatcher
        let busy = busy
        Task.detached {
            let outcome = await dispatcher.handle(request)
            result.withLock { $0 = outcome }
            // Clear before signalling, so the next request never sees a finished task as busy.
            busy.withLock { $0 = false }
            done.signal()
        }
        guard done.wait(timeout: .now() + Self.handleTimeout) == .success, let outcome = result.withLock({ $0 }) else {
            Log.listener.error("a request took longer than \(Int(Self.handleTimeout), privacy: .public) s")
            return (AgentReply(ok: false, error: .timeout, message: "Nido Agent took too long to answer"), nil)
        }
        return outcome
    }

    private func write(_ reply: AgentReply, png: Data?, to fd: Int32) {
        do {
            try AgentFrame.writeJSON(reply, to: fd)
            if let png { try AgentFrame.write(png, to: fd) }
        } catch {
            Log.listener.error("could not write the reply: \(String(describing: error), privacy: .public)")
        }
    }

    /// No SIGPIPE when the host drops the connection, and bounded reads and writes so a
    /// stalled host cannot wedge the listener.
    private static func configure(_ fd: Int32) {
        var on: Int32 = 1
        if setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) != 0 {
            Log.listener.error("SO_NOSIGPIPE failed: errno \(errno, privacy: .public)")
        }
        var timeout = timeval(tv_sec: ioTimeout, tv_usec: 0)
        for option in [SO_RCVTIMEO, SO_SNDTIMEO] where setsockopt(
            fd, SOL_SOCKET, option, &timeout, socklen_t(MemoryLayout<timeval>.size)) != 0 {
            Log.listener.error("socket timeout option \(option, privacy: .public) failed: errno \(errno, privacy: .public)")
        }
    }

    private func report(_ state: State) {
        let changed = lastState.withLock { last -> Bool in
            defer { last = state }
            return last != state
        }
        if changed { onState(state) }
    }
}
