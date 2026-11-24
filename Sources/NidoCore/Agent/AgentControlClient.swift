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
    /// Sent with each command for the activity log (`AgentCommand.client`).
    public let client: String?
    /// Sent with each command: the activity log's session of this client, the same across its
    /// connections (`AgentCommand.session`).
    public let session: String?

    public init(vmID: UUID, vmName: String, bundle: URL, root: URL = AgentControlServer.defaultRoot,
                isRunningWithAgentAccess: @escaping @Sendable () -> Bool = { false },
                client: String? = nil, session: String? = nil) {
        self.vmID = vmID
        self.vmName = vmName
        self.bundle = bundle
        self.root = root
        self.isRunningWithAgentAccess = isRunningWithAgentAccess
        self.client = client
        self.session = session
    }

    /// The client of `bundle`'s control socket (`nido act`, `nido mcp`, `nido agent`, the app's
    /// Agent pane), naming itself `client` with `session` in the activity log. A VM that runs
    /// (bundle lock held) with agent access on in its configuration but has no socket file is
    /// told to restart, not to start.
    public static func forVM(bundle: VMBundle, config: VMConfig, client: String? = nil,
                             session: String? = nil) -> AgentControlClient {
        AgentControlClient(
            vmID: config.id, vmName: config.name.rawValue, bundle: bundle.url,
            isRunningWithAgentAccess: {
                BundleLock.holder(bundle) != nil && (try? bundle.readConfig())?.agentAccess == true
            },
            client: client, session: session)
    }

    /// `send(_:timeout:)` with `timeout(for:)`.
    public func send(_ action: AgentAction) throws -> AgentAnswer {
        try send(action, timeout: Self.timeout(for: action))
    }

    /// Added to the owner's own limits towards the helper.
    static let ownerMargin: Duration = .seconds(5)

    /// How long the client waits for a checkpoint.
    static let checkpointTimeout: Duration = .seconds(120)

    /// How long the client waits for `action`: longer than the owner's own limits towards the
    /// helper (`AgentClient`: `defaultTimeout`, `defaultImageTimeout` for an image), so their
    /// errors arrive rather than a timeout. A zoom asks `status` first, then the image: both
    /// limits; a `uiTree` asks `status` first, then the tree. A file's transfer asks `status`
    /// first, then the bytes (the image limit); a `listFiles`, `status` then the list. A
    /// checkpoint saves the VM's memory (several GiB): `checkpointTimeout`.
    static func timeout(for action: AgentAction) -> Duration {
        switch action {
        case .checkpoint: checkpointTimeout
        case .zoom, .putFile, .getFile: AgentClient.defaultTimeout + AgentClient.defaultImageTimeout + ownerMargin
        case .uiTree, .listFiles: AgentClient.defaultTimeout + AgentClient.defaultTimeout + ownerMargin
        default: AgentClient.defaultImageTimeout + ownerMargin
        }
    }

    /// The text on the VM's screen (read text): the owner takes a capture at native density of
    /// `region` (pixels of the latest screenshot, nil: all of it), recognizes the text on the Mac
    /// and answers `lines` and `truncated` (at most `maxLines`), never the capture.
    public func readText(region: PixelRect?, maxLines: Int) throws -> AgentAnswer {
        try readText(region: region, maxLines: maxLines, timeout: Self.readTextTimeout)
    }

    func readText(region: PixelRect?, maxLines: Int, timeout: Duration) throws -> AgentAnswer {
        let answer = try send(.status, staged: nil, readText: ReadTextRequest(region: region, maxLines: maxLines),
                              timeout: timeout)
        // The first recognition after the owner starts loads Vision's model: say so, not "no answer".
        if answer.error == .timeout {
            return .failure(.timeout, L10n.string(
                "Text recognition is still starting on this Mac: try read_text again in a minute"))
        }
        // An owner started before read text existed ignores the unknown key and answers a plain
        // status: an ok answer without lines.
        if answer.ok, answer.lines == nil {
            return .failure(.versionMismatch, L10n.string(
                "The VM was started by an older Nido that can’t read text: restart \(vmName) with this version"))
        }
        return answer
    }

    /// How long the client waits for read text: a zoom's, plus the recognition on the Mac, which
    /// on the first call of the owner's process includes loading Vision's text model (over a minute
    /// seen); the owner warms it up at start, so this is only for a read that comes too early.
    static let readTextTimeout: Duration = timeout(for: .zoom(x: 0, y: 0, width: 1, height: 1, maxLongEdge: 1))
        + .seconds(150)

    /// Copies `data` to `path` in the guest's `~/NidoTransfer` (`putFile`): the bytes are staged
    /// in the bundle (`AgentFiles`) and only their name travels to the owner, which reads and
    /// deletes them; whatever the answer, nothing of this call stays staged. More than
    /// `AgentProtocol.maxTransferBytes` is refused here, before anything is written.
    public func putFile(_ data: Data, to path: String) throws -> AgentAnswer {
        guard data.count <= AgentProtocol.maxTransferBytes else {
            return .failure(.badRequest, L10n.string("the file is larger than 16 MiB"))
        }
        let vmBundle = VMBundle(url: bundle)
        let staged: String
        do {
            staged = try AgentFiles.stage(data, in: vmBundle)
        } catch {
            return .failure(.internalError, L10n.string("could not save the file"))
        }
        // The owner deletes what it takes; a refusal before that (agent access off, a VM that
        // does not run) leaves it to this client.
        defer { AgentFiles.remove(staged, in: vmBundle) }
        let action = AgentAction.putFile(path: path, size: data.count)
        return try send(action, staged: staged, timeout: Self.timeout(for: action))
    }

    /// The file at `path` in the guest's `~/NidoTransfer` (`getFile`), at most `maxBytes`
    /// (bounded by `AgentProtocol.maxTransferBytes`): the answer, and the bytes when it is ok.
    /// The owner stages them in the bundle; they are read and deleted here.
    public func getFile(_ path: String, maxBytes: Int) throws -> (AgentAnswer, Data?) {
        let action = AgentAction.getFile(path: path, maxBytes: max(0, min(maxBytes, AgentProtocol.maxTransferBytes)))
        let answer = try send(action, timeout: Self.timeout(for: action))
        guard answer.ok else {
            if let staged = answer.staged { AgentFiles.remove(staged, in: VMBundle(url: bundle)) }
            return (answer, nil)
        }
        return Self.takeStaged(answer, in: VMBundle(url: bundle))
    }

    /// The bytes of the file `answer` names (`staged`), read and deleted, and the answer without
    /// the name. A name that is not a staged file's, a file that is not a regular one of this
    /// user, or a size other than `bytes`: an `internalError` answer, no bytes.
    static func takeStaged(_ answer: AgentAnswer, in bundle: VMBundle) -> (AgentAnswer, Data?) {
        let refused = AgentAnswer.failure(.internalError, L10n.string("could not read the copied file"))
        guard let staged = answer.staged, let data = try? AgentFiles.take(staged, in: bundle) else {
            return (refused, nil)
        }
        guard answer.bytes == nil || answer.bytes == data.count else { return (refused, nil) }
        var copy = answer
        copy.staged = nil
        copy.bytes = data.count
        return (copy, data)
    }

    /// Sends `action` to the owner of the running VM and returns its answer. No owner listening
    /// (no socket, or one left by a process that died) is an answer, `notRunning` (saying "restart
    /// it" when there is no socket file and `isRunningWithAgentAccess`, "start it" otherwise), and
    /// so is no answer within `timeout` (`timeout`). Throws `AgentFailure` when the connection breaks or the
    /// answer is not one, and `.unsafePath` for a socket path that cannot exist.
    public func send(_ action: AgentAction, timeout: Duration) throws -> AgentAnswer {
        try send(action, staged: nil, timeout: timeout)
    }

    /// The command as it goes on the wire, without the line end. Sorted keys put `action` first,
    /// and its `op` before its `text` (`AgentControlServer.longLinePrefix`).
    static func encode(_ command: AgentCommand) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(command)
    }

    /// `send(_:timeout:)` with the name of the staged file that holds a `putFile`'s bytes.
    func send(_ action: AgentAction, staged: String?, readText: ReadTextRequest? = nil,
              timeout: Duration) throws -> AgentAnswer {
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

        // Sorted keys put `action` first, and its `op` before its `text`: the owner lets only a
        // line that starts so with `writeClipboard` be longer than `maxLineBytes`.
        var line = try Self.encode(AgentCommand(
            vmID: vmID, bundlePath: AgentCommand.bundlePath(bundle), action: action, client: client, session: session,
            staged: staged, readText: readText))
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
                guard buffer.count <= AgentControlServer.maxClipboardAnswerBytes + 1 else { return .closed }
                continue
            }
            if n < 0 && errno == EINTR { continue }
            guard n < 0, errno == EAGAIN else { return .closed }
            guard wait(fd, POLLIN, before: deadline) else { return .timedOut }
        }
    }
}
