// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import NidoAgentKit

/// The client side of `AgentControlServer`, used by `nido act` and `nido mcp`: one connection
/// per command, one line out, one line back. Nothing is kept between commands, so the struct can
/// be shared freely; what must persist (the last screenshot's size) lives in the owner.
public struct AgentControlClient: Sendable {
    public let vmID: UUID
    /// Only for the `notRunning` message: the socket is found by id, but the user knows the name.
    public let vmName: String
    /// The VM's bundle, sent with each command: a copy of the bundle (same id) is another VM.
    public let bundle: URL
    public let root: URL
    /// Whether the VM runs (its bundle lock is held) with agent access on in its configuration,
    /// asked only when there is no socket file at all: such a VM was started before agent access
    /// was turned on.
    public let isRunningWithAgentAccess: @Sendable () -> Bool

    public init(vmID: UUID, vmName: String, bundle: URL, root: URL = AgentControlServer.defaultRoot,
                isRunningWithAgentAccess: @escaping @Sendable () -> Bool = { false }) {
        self.vmID = vmID
        self.vmName = vmName
        self.bundle = bundle
        self.root = root
        self.isRunningWithAgentAccess = isRunningWithAgentAccess
    }

    /// The client of `bundle`'s control socket (`nido act`, `nido mcp`, `nido agent`, the app's
    /// Agent pane). A VM that runs (bundle lock held) with agent access on in its configuration
    /// but has no socket file is told to restart, not to start.
    public static func forVM(bundle: VMBundle, config: VMConfig) -> AgentControlClient {
        AgentControlClient(
            vmID: config.id, vmName: config.name.rawValue, bundle: bundle.url,
            isRunningWithAgentAccess: {
                BundleLock.holder(bundle) != nil && (try? bundle.readConfig())?.agentAccess == true
            })
    }

    /// `send(_:timeout:)` with 20 seconds: longer than the owner's own limits towards the helper
    /// (`AgentClient`: 10 s, 15 s for a screenshot), so their errors arrive rather than a timeout.
    public func send(_ action: AgentAction) throws -> AgentAnswer {
        try send(action, timeout: .seconds(20))
    }

    /// Sends `action` to the owner of the running VM and returns its answer. No owner listening
    /// (no socket, or one left by a process that died) is an answer, `notRunning` (saying "restart
    /// it" when there is no socket file and `isRunningWithAgentAccess`, "start it" otherwise), and
    /// so is no answer within `timeout` (`timeout`). Throws `AgentFailure` when the connection breaks or the
    /// answer is not one, and `.unsafePath` for a socket path that cannot exist.
    public func send(_ action: AgentAction, timeout: Duration) throws -> AgentAnswer {
        let deadline = ContinuousClock.now + timeout
        let url = AgentControlServer.socketURL(vmID: vmID, root: root)
        var address = try AgentControlServer.socketAddress(url)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentControlServer.posixError() }
        defer { _ = Darwin.close(fd) }
        var one: Int32 = 1
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0
        else { throw AgentControlServer.posixError() }

        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            let code = errno
            if code == ENOENT || code == ECONNREFUSED || code == ENOTDIR {
                // The socket exists only in a VM started with agent access on. A socket file
                // nobody answers on (ECONNREFUSED) is another case: the generic text.
                if code != ECONNREFUSED, isRunningWithAgentAccess() {
                    return .failure(.notRunning, L10n.string("agent access was turned on after \(vmName) started: restart it"))
                }
                return .failure(.notRunning, L10n.string("start it with `nido start \(vmName)`"))
            }
            throw AgentControlServer.posixError(code)
        }
        // What is typed can be a password: talk only to an owner of this same user.
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw lost }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw AgentControlServer.posixError() }

        var line = try JSONEncoder().encode(AgentCommand(vmID: vmID, bundlePath: AgentCommand.bundlePath(bundle), action: action))
        line.append(0x0A)
        switch write(line, to: fd, before: deadline) {
        case .done, .closed: break  // closed: the owner refused the line; its answer may be waiting
        case .timedOut: return timedOut
        }
        switch readLine(from: fd, before: deadline) {
        case .line(let data):
            guard let answer = try? JSONDecoder().decode(AgentAnswer.self, from: data) else { throw lost }
            // Part of it is the guest's text, passed on by the owner.
            return answer.cleaned
        case .timedOut: return timedOut
        case .closed: throw lost
        }
    }

    private var timedOut: AgentAnswer {
        .failure(.timeout, L10n.string("Nido Agent did not answer in time"))
    }

    private var lost: AgentFailure {
        AgentFailure(code: .internalError, message: L10n.string("lost the connection to the running VM"))
    }

    // MARK: - I/O (non-blocking, bounded by the deadline)

    private enum WriteResult { case done, closed, timedOut }
    private enum ReadResult { case line(Data), closed, timedOut }

    /// Waits until `fd` is ready for `events` or the deadline passes.
    private func wait(_ fd: Int32, _ events: Int32, before deadline: ContinuousClock.Instant) -> Bool {
        while true {
            let left = ContinuousClock.now.duration(to: deadline)
            guard left > .zero else { return false }
            let ms = Int32(min(Double(Int32.max), (Double(left.components.seconds) * 1000
                + Double(left.components.attoseconds) / 1e15).rounded(.up)))
            var pfd = pollfd(fd: fd, events: Int16(events), revents: 0)
            let ready = poll(&pfd, 1, max(1, ms))
            if ready > 0 { return true }
            if ready < 0 && errno != EINTR { return true }  // let the read/write report the error
        }
    }

    private func write(_ data: Data, to fd: Int32, before deadline: ContinuousClock.Instant) -> WriteResult {
        data.withUnsafeBytes { raw -> WriteResult in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 {
                    offset += n
                    continue
                }
                if n < 0 && (errno == EINTR) { continue }
                guard n < 0, errno == EAGAIN else { return .closed }
                guard wait(fd, POLLOUT, before: deadline) else { return .timedOut }
            }
            return .done
        }
    }

    private func readLine(from fd: Int32, before deadline: ContinuousClock.Instant) -> ReadResult {
        var buffer: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if n > 0 {
                let start = buffer.count
                buffer.append(contentsOf: chunk[..<n])
                if let newline = buffer[start...].firstIndex(of: 0x0A) { return .line(Data(buffer[..<newline])) }
                guard buffer.count <= AgentControlServer.maxLineBytes else { return .closed }
                continue
            }
            if n < 0 && errno == EINTR { continue }
            guard n < 0, errno == EAGAIN else { return .closed }
            guard wait(fd, POLLIN, before: deadline) else { return .timedOut }
        }
    }
}
