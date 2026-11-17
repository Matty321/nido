// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import NidoAgentKit
import Synchronization

/// The per-VM Unix socket through which `nido act` and `nido mcp` drive a macOS guest. It is
/// served by the process that owns the running VM (`nido start` or Nido.app), which forwards each
/// command to Nido Agent in the guest (`perform`, an `AgentClient` in production).
///
/// The socket is a security boundary: whoever can write to it can click and type in the guest.
/// So it lives in a 0700 directory of this user (`<user temp dir>/nido-agent`, see
/// `defaultRoot`), is itself 0600, never listens on the network, answers only peers of the same
/// user (`getpeereid`) and only while the VM's `agentAccess` is on, read again from `config.json`
/// before every command: turning access off takes effect at the next command, without
/// restarting the VM.
///
/// Protocol: one `AgentCommand` JSON line (at most `maxLineBytes`) in, one `AgentAnswer` line
/// out, repeated on the same connection. A line that is not a command, or is too long, gets a
/// `badRequest` answer and the connection is closed; so does `agentAccessOff`. Errors of the
/// helper or of the transport are answered and the connection stays open.
///
/// Commands of every connection go through one `AgentGate`, one at a time: two agents (or an
/// agent and the user's `nido act`) never interleave a click with another's screenshot.
public final class AgentControlServer: Sendable {
    /// `<the user's temporary folder>/nido-agent`: per-user, private, and short enough for the
    /// socket path. The folder is `confstr(_CS_DARWIN_USER_TEMP_DIR)`, not `$TMPDIR`: the owner
    /// (the app started by launchd, or `nido start`) and the client (`nido mcp`, started by any
    /// MCP client with its own environment) must agree on it whatever their environments say.
    public static var defaultRoot: URL {
        root(userTempDirectory: darwinUserTempDirectory())
    }

    /// `confstr(_CS_DARWIN_USER_TEMP_DIR)` (`/var/folders/…/T/`): this user's private temporary
    /// folder, the same for every process of the user. Nil if it cannot be read.
    static func darwinUserTempDirectory() -> String? {
        let size = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, size) == size else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// `<userTempDirectory>/nido-agent`; without an absolute folder, `/private/tmp/nido-agent-<uid>`
    /// (`prepareDirectory` still requires it to be this user's own and private).
    static func root(userTempDirectory: String?) -> URL {
        guard let folder = userTempDirectory, folder.hasPrefix("/") else {
            return URL(fileURLWithPath: "/private/tmp/nido-agent-\(getuid())", isDirectory: true)
        }
        return URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent("nido-agent", isDirectory: true)
    }

    /// A Unix socket path must fit `sockaddr_un.sun_path` (104 bytes) with its NUL.
    static let maxSocketPathBytes = 103
    /// The longest command line accepted, without its `\n`. A `type` action of a long text fits;
    /// a client cannot make the owner buffer more than this.
    static let maxLineBytes = 64 * 1024
    /// Connections served at once. Each has a thread blocked in `read`; more are closed at once.
    static let maxConnections = 32
    /// How long writing an answer may block on a client that stopped reading.
    static let sendTimeoutSeconds = 10

    /// `<root>/<first 8 hex digits of the VM id>.sock`, like `GvproxyProcess`'s runtime folders.
    public static func socketURL(vmID: UUID, root: URL = defaultRoot) -> URL {
        root.appendingPathComponent(String(vmID.uuidString.lowercased().prefix(8)) + ".sock")
    }

    private let core: Core

    private init(core: Core) {
        self.core = core
    }

    deinit { core.stop() }

    /// Creates the socket for the VM `vmID` (whose bundle is `bundle`) and serves it on a thread
    /// of its own until `stop()`. `root` is created 0700 if missing and refused (`.unsafePath`)
    /// if it is a symlink, belongs to someone else or is open to others; a leftover socket from a
    /// process that died is replaced, one another running owner serves is not (`claim`). Throws
    /// `.unsafePath` for a path too long for a socket, `.agentSocketInUse` when another owner
    /// serves the name, and a `POSIXError` when the socket cannot be made.
    public static func start(
        bundle: VMBundle, vmID: UUID,
        perform: @escaping @Sendable (AgentRequest) async throws(AgentFailure) -> (AgentReply, Data?),
        root: URL = defaultRoot
    ) throws -> AgentControlServer {
        try start(bundle: bundle, vmID: vmID, perform: perform, root: root, sendTimeoutSeconds: sendTimeoutSeconds)
    }

    /// `start` with the send timeout injectable (tests).
    static func start(
        bundle: VMBundle, vmID: UUID,
        perform: @escaping @Sendable (AgentRequest) async throws(AgentFailure) -> (AgentReply, Data?),
        root: URL, sendTimeoutSeconds: Int
    ) throws -> AgentControlServer {
        let url = socketURL(vmID: vmID, root: root)
        guard url.path.utf8.count <= maxSocketPathBytes else { throw NidoError.unsafePath(url.path) }
        let vmName = try bundle.readConfig().name.rawValue
        try prepareDirectory(root)
        // Held until the socket listens: two owners starting at once never both find the name
        // free, and none removes a socket another has bound but not yet listened on.
        let lock = try lockDirectory(root)
        defer { _ = Darwin.close(lock) }
        try claim(url)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError() }
        var wake: [Int32] = [-1, -1]
        var bound = false
        do {
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw posixError() }
            var address = try socketAddress(url)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw posixError() }
            bound = true
            // The 0700 directory already keeps others out; 0600 holds even if it is ever widened.
            guard chmod(url.path, 0o600) == 0 else { throw posixError() }
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw posixError() }
            guard listen(fd, 16) == 0 else { throw posixError() }
            // Non-blocking: a client gone between `poll` and `accept` must not block the loop.
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw posixError() }
            guard pipe(&wake) == 0 else { throw posixError() }
            for end in wake { _ = fcntl(end, F_SETFD, FD_CLOEXEC) }

            let core = Core(
                listenFD: fd, wakeRead: wake[0], wakeWrite: wake[1], socketURL: url,
                socketID: (info.st_dev, info.st_ino), vmID: vmID,
                bundlePath: AgentCommand.bundlePath(bundle.url), vmName: vmName,
                sendTimeoutSeconds: sendTimeoutSeconds,
                gate: AgentGate(bundle: bundle, vmName: vmName, perform: perform))
            Thread { core.acceptLoop() }.start()
            return AgentControlServer(core: core)
        } catch {
            if bound { _ = Darwin.unlink(url.path) }
            _ = Darwin.close(fd)
            for end in wake where end >= 0 { _ = Darwin.close(end) }
            throw error
        }
    }

    /// Stops accepting, closes every open connection, removes the socket file (only if it is
    /// still the one this server made) and waits for the accept thread to end. A command already
    /// handed to the helper finishes there (`AgentClient` bounds it); queued ones are dropped.
    /// Idempotent; also run on deinit.
    public func stop() {
        core.stop()
    }

    // MARK: - Directory

    /// `root` must be a real directory of this user that no one else can enter: created 0700
    /// when missing, refused otherwise (a symlink, another owner, any group or other bit). An
    /// existing directory's mode is not repaired: a wider one means something else made it.
    static func prepareDirectory(_ root: URL) throws {
        if mkdir(root.path, 0o700) == 0 {
            // `mkdir` applies the umask; the mode must be exactly 0700.
            guard chmod(root.path, 0o700) == 0 else { throw posixError() }
        } else if errno != EEXIST {
            throw posixError()
        }
        var info = stat()
        guard lstat(root.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(),
            info.st_mode & 0o077 == 0
        else { throw NidoError.unsafePath(root.path) }
    }

    /// An exclusive `flock` on `root` (a directory this user owns, see `prepareDirectory`), held
    /// while the descriptor is open. Every owner takes it to claim and bind its socket name, which
    /// takes milliseconds (at most about 200 ms for a dead socket): the wait is bounded at 3 s, so
    /// an owner stuck while holding it (stopped in a debugger) cannot hang another one's start.
    static func lockDirectory(_ root: URL) throws -> Int32 {
        let fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError() }
        let deadline = ContinuousClock.now + .seconds(3)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            guard code == EINTR || (code == EWOULDBLOCK && ContinuousClock.now < deadline) else {
                _ = Darwin.close(fd)
                throw posixError(code)
            }
            if code == EWOULDBLOCK { usleep(20_000) }
        }
        return fd
    }

    /// Makes the socket name `url` free for this owner, under `lockDirectory`. Nothing there:
    /// free. A socket some process accepts on belongs to another running owner (a VM whose id
    /// starts with the same 8 hex digits, or a copy of the same bundle): never touched,
    /// `.agentSocketInUse`. A socket nobody accepts on (`ECONNREFUSED`: its owner died without
    /// `stop()`) or any other file (planted by this same user in the 0700 directory): removed.
    /// A live owner whose backlog is full also refuses a connection, so the probe asks three
    /// times, 100 ms apart, before it takes the socket for dead. Any other answer of the probe
    /// is thrown rather than taken for a dead socket.
    static func claim(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            guard errno == ENOENT else { throw posixError() }
            return
        }
        if (info.st_mode & S_IFMT) == S_IFSOCK {
            for attempt in 1...3 {
                let code = try probe(url)
                if code == 0 { throw NidoError.agentSocketInUse(url.path) }
                if code == ENOENT { break }
                guard code == ECONNREFUSED else { throw posixError(code) }
                if attempt < 3 { usleep(100_000) }
            }
        }
        guard Darwin.unlink(url.path) == 0 || errno == ENOENT else { throw posixError() }
    }

    /// Connects to the socket at `url` and hangs up at once: 0 when a process accepts on it,
    /// otherwise `connect`'s `errno`.
    private static func probe(_ url: URL) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError() }
        defer { _ = Darwin.close(fd) }
        var address = try socketAddress(url)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return connected == 0 ? 0 : errno
    }

    static func socketAddress(_ url: URL) throws -> sockaddr_un {
        let path = Array(url.path.utf8)
        var address = sockaddr_un()
        guard path.count < MemoryLayout.size(ofValue: address.sun_path) else { throw NidoError.unsafePath(url.path) }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (i, byte) in path.enumerated() { raw[i] = byte }
        }
        return address
    }

    static func posixError(_ code: Int32 = errno) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    // MARK: - Core

    /// What the accept thread and the connection threads share. Connection descriptors are owned
    /// by their thread, which closes them; `stop()` only shuts them down, and only while they are
    /// registered, so it never touches a descriptor number that was closed and reused.
    private final class Core: Sendable {
        let listenFD: Int32
        let wakeRead: Int32
        let wakeWrite: Int32
        let socketURL: URL
        let socketID: (dev_t, ino_t)
        /// The VM this socket serves: a command for another id, or for another bundle with the
        /// same id (a copy made in Finder), is refused.
        let vmID: UUID
        /// `AgentCommand.bundlePath` of the served bundle.
        let bundlePath: String
        let vmName: String
        let sendTimeoutSeconds: Int
        let gate: AgentGate
        private let acceptEnded = DispatchSemaphore(value: 0)

        private struct State {
            var stopped = false
            var connections: Set<Int32> = []
        }
        private let state = Mutex(State())

        init(listenFD: Int32, wakeRead: Int32, wakeWrite: Int32, socketURL: URL, socketID: (dev_t, ino_t),
             vmID: UUID, bundlePath: String, vmName: String, sendTimeoutSeconds: Int, gate: AgentGate) {
            self.bundlePath = bundlePath
            self.listenFD = listenFD
            self.wakeRead = wakeRead
            self.wakeWrite = wakeWrite
            self.socketURL = socketURL
            self.socketID = socketID
            self.vmID = vmID
            self.vmName = vmName
            self.sendTimeoutSeconds = sendTimeoutSeconds
            self.gate = gate
        }

        var isStopped: Bool { state.withLock { $0.stopped } }

        func stop() {
            let first = state.withLock { s -> Bool in
                guard !s.stopped else { return false }
                s.stopped = true
                for fd in s.connections { shutdown(fd, SHUT_RDWR) }  // their threads see EOF
                return true
            }
            guard first else { return }
            removeSocketFile()
            var byte: UInt8 = 1
            _ = Darwin.write(wakeWrite, &byte, 1)
            acceptEnded.wait()
            _ = Darwin.close(listenFD)
            _ = Darwin.close(wakeRead)
            _ = Darwin.close(wakeWrite)
        }

        /// Removes the socket only if it is still ours: a new owner of the same VM may already
        /// have replaced it.
        private func removeSocketFile() {
            var info = stat()
            guard lstat(socketURL.path, &info) == 0, info.st_dev == socketID.0, info.st_ino == socketID.1 else { return }
            _ = Darwin.unlink(socketURL.path)
        }

        func acceptLoop() {
            defer { acceptEnded.signal() }
            var fds = [pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)]
            while !isStopped {
                let ready = poll(&fds, 2, -1)
                if ready < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if fds[1].revents != 0 { return }
                guard fds[0].revents & Int16(POLLIN) != 0 else {
                    if fds[0].revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { return }
                    continue
                }
                let fd = accept(listenFD, nil, nil)
                if fd < 0 {
                    switch errno {
                    case EINTR, EAGAIN, ECONNABORTED: continue
                    case EMFILE, ENFILE, ENOBUFS, ENOMEM: usleep(100_000)  // let descriptors free up
                    default: return
                    }
                    continue
                }
                admit(fd)
            }
        }

        /// Checks the peer and hands the connection to a thread of its own, or closes it.
        private func admit(_ fd: Int32) {
            var uid: uid_t = 0
            var gid: gid_t = 0
            // Another user (the directory should already make that impossible): closed, no reply.
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, getpeereid(fd, &uid, &gid) == 0, uid == getuid(),
                configure(fd)
            else {
                _ = Darwin.close(fd)
                return
            }
            let admitted = state.withLock { s -> Bool in
                guard !s.stopped, s.connections.count < AgentControlServer.maxConnections else { return false }
                s.connections.insert(fd)
                return true
            }
            guard admitted else {
                _ = Darwin.close(fd)
                return
            }
            Thread { [self] in serve(fd) }.start()
        }

        /// Blocking I/O (the socket inherits O_NONBLOCK from the listener), no SIGPIPE (Nido.app
        /// does not ignore it: a client that hangs up must give EPIPE, not kill the VM's owner),
        /// and a bound on how long an answer may wait for a client that stopped reading.
        private func configure(_ fd: Int32) -> Bool {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == 0 else { return false }
            var one: Int32 = 1
            guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0
            else { return false }
            var timeout = timeval(tv_sec: sendTimeoutSeconds, tv_usec: 0)
            return setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0
        }

        /// One connection, on its own thread, until EOF, an error, or an answer that closes it.
        /// The gate is held only while a command runs: the answer is written after it is released,
        /// so a client that stops reading blocks its own thread, never the other connections.
        private func serve(_ fd: Int32) {
            defer {
                state.withLock { _ = $0.connections.remove(fd) }
                _ = Darwin.close(fd)
            }
            var reader = LineReader(fd: fd, limit: AgentControlServer.maxLineBytes)
            while true {
                let command: AgentCommand
                switch reader.next() {
                case .end:
                    return
                case .tooLong:
                    _ = Self.write(.failure(.badRequest, L10n.string("command longer than 64 KiB")), to: fd)
                    return
                case .line(let line):
                    guard let decoded = try? JSONDecoder().decode(AgentCommand.self, from: line) else {
                        _ = Self.write(.failure(.badRequest, L10n.string("invalid command")), to: fd)
                        return
                    }
                    // Another VM whose socket name is the same, or a copy of this bundle (same
                    // id, another folder): as if the VM asked for were not running.
                    guard decoded.vmID == vmID, decoded.bundlePath == bundlePath else {
                        _ = Self.write(.failure(.notRunning, L10n.string(
                            "this agent socket belongs to another running VM (\(vmName))")), to: fd)
                        return
                    }
                    command = decoded
                }
                guard let outcome = run(command) else { return }
                guard Self.write(outcome.answer, to: fd), !outcome.close else { return }
            }
        }

        /// Runs `command` through the gate, blocking this (non-cooperative) connection thread
        /// until it is done. Nil once the server is stopping.
        private func run(_ command: AgentCommand) -> AgentGate.Outcome? {
            let result = Mutex<AgentGate.Outcome?>(nil)
            let done = DispatchSemaphore(value: 0)
            let gate = gate
            Task { [self] in
                let outcome = await gate.run(command, stopped: { self.isStopped })
                result.withLock { $0 = outcome }
                done.signal()
            }
            done.wait()
            return result.withLock { $0 }
        }

        /// Writes `answer` and its `\n`. False if the client is gone or did not read within
        /// `sendTimeoutSeconds`.
        private static func write(_ answer: AgentAnswer, to fd: Int32) -> Bool {
            guard var line = try? JSONEncoder().encode(answer) else { return false }
            line.append(0x0A)
            return line.withUnsafeBytes { raw -> Bool in
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { return false }
                    offset += n
                }
                return true
            }
        }
    }
}

/// Reads `\n`-terminated lines from a blocking socket, never holding more than `limit` bytes of
/// a line plus one read: a client that never sends `\n` is cut off at the limit, not buffered.
struct LineReader {
    enum Next: Equatable { case line(Data), tooLong, end }

    let fd: Int32
    let limit: Int
    private var buffer: [UInt8] = []
    /// How much of `buffer` is known to hold no `\n`.
    private var scanned = 0

    init(fd: Int32, limit: Int) {
        self.fd = fd
        self.limit = limit
    }

    mutating func next() -> Next {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if let newline = buffer[scanned...].firstIndex(of: 0x0A) {
                guard newline <= limit else { return .tooLong }
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                scanned = 0
                return .line(line)
            }
            scanned = buffer.count
            guard buffer.count <= limit else { return .tooLong }
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return .end }
            buffer.append(contentsOf: chunk[..<n])
        }
    }
}

/// The one place commands run, in arrival order, one at a time across all connections. An actor
/// alone is not enough (it lets another call in at every `await`, here the helper round trip),
/// so it also holds a FIFO lock: `run` waits its turn, then keeps the turn across `perform`.
actor AgentGate {
    struct Outcome: Sendable {
        var answer: AgentAnswer
        /// Close the connection after the answer.
        var close: Bool
    }

    private let bundle: VMBundle
    /// The name at start, used when `config.json` cannot be read.
    private let vmName: String
    private let perform: @Sendable (AgentRequest) async throws(AgentFailure) -> (AgentReply, Data?)
    /// The sizes of the last screenshot the agent saw: the coordinates of the next click, drag or
    /// scroll refer to that image, and the helper maps them back to points with it.
    private var lastShot: (image: PixelSize, screen: ScreenSize)?
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(bundle: VMBundle, vmName: String,
         perform: @escaping @Sendable (AgentRequest) async throws(AgentFailure) -> (AgentReply, Data?)) {
        self.bundle = bundle
        self.vmName = vmName
        self.perform = perform
    }

    /// Nil when `stopped()` is true by the time the command's turn comes: the server is going
    /// away and the command must not reach the guest.
    func run(_ command: AgentCommand, stopped: @Sendable () -> Bool) async -> Outcome? {
        await acquire()
        defer { release() }
        guard !stopped() else { return nil }
        return await handle(command.action)
    }

    private func acquire() async {
        guard busy else {
            busy = true
            return
        }
        // `release` hands the turn over without clearing `busy`, so no one cuts in.
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }

    private func handle(_ action: AgentAction) async -> Outcome {
        // The guest's clipboard is the owner's alone (Settings › Agent, after Touch ID): an agent
        // or `nido act` never writes it. Answered without the text.
        if case .setClipboard = action {
            return Outcome(answer: .failure(.badRequest, L10n.string("only Nido can use the VM’s clipboard")),
                           close: false)
        }
        let config = try? bundle.readConfig()
        guard let config, config.agentAccess == true else {
            let name = config?.name.rawValue ?? vmName
            return Outcome(answer: .failure(
                .agentAccessOff, L10n.string("Agent access is off for \(name): turn it on with nido agent enable \(name)")),
                close: true)
        }
        var request = AgentRequest(v: AgentProtocol.version, action: action)
        if Self.carriesPoint(action) {
            guard let lastShot else {
                return Outcome(answer: .failure(
                    .noScreenshot, L10n.string("take a screenshot first: coordinates refer to the last screenshot")),
                    close: false)
            }
            request.image = lastShot.image
            request.screen = lastShot.screen
        }
        if case .zoom = action {
            // A helper older than the zoom op answers "unknown action": ask its version first,
            // through the same path, so the op never reaches it. Nothing interleaves: this is one turn.
            let statusRequest = AgentRequest(v: AgentProtocol.version, action: .status)
            do {
                let (statusReply, _) = try await perform(statusRequest)
                let version = statusReply.status?.helperVersion
                // The helper's own refusal (busy, too slow...) is not an old version: forward it.
                guard statusReply.ok else {
                    return Outcome(answer: .failure(statusReply.error ?? .internalError, statusReply.message ?? ""),
                                   close: false)
                }
                guard let version,
                      MacAgentInstaller.compareVersions(version, AgentProtocol.minimumZoomHelperVersion) >= 0 else {
                    return Outcome(answer: .failure(.versionMismatch, L10n.string(
                        "Nido Agent is too old to zoom: run nido agent setup \(config.name.rawValue) to update it")),
                        close: false)
                }
            } catch where error.code == .versionMismatch {
                return Outcome(answer: .failure(.versionMismatch, L10n.string(
                    "incompatible Nido Agent version: run nido agent setup \(config.name.rawValue) to update Nido Agent")),
                    close: false)
            } catch {
                return Outcome(answer: .failure(error.code, error.message), close: false)
            }
        }

        let reply: AgentReply
        let png: Data?
        do {
            (reply, png) = try await perform(request)
        } catch where error.code == .versionMismatch {
            // `AgentClient` does not know the VM: the command that updates the helper is named here.
            return Outcome(answer: .failure(.versionMismatch, L10n.string(
                "incompatible Nido Agent version: run nido agent setup \(config.name.rawValue) to update Nido Agent")),
                close: false)
        } catch {
            return Outcome(answer: .failure(error.code, error.message), close: false)
        }
        var answer = AgentAnswer(ok: reply.ok, status: reply.status, image: reply.image, screen: reply.screen,
                                 error: reply.error, message: reply.message)
        if action.isImageAction, reply.ok {
            guard let png, let image = reply.image, let screen = reply.screen else {
                return Outcome(answer: .failure(.internalError, L10n.string("could not talk to Nido Agent")), close: false)
            }
            do {
                answer.path = try AgentShots.write(png, in: bundle).path
            } catch {
                return Outcome(answer: .failure(.internalError, L10n.string("could not save the screenshot")), close: false)
            }
            // A zoom never changes what coordinates refer to.
            if case .screenshot = action { lastShot = (image, screen) }
        }
        return Outcome(answer: answer, close: false)
    }

    /// Actions whose coordinates refer to the last screenshot. A scroll without a point scrolls
    /// where the pointer is and needs none.
    static func carriesPoint(_ action: AgentAction) -> Bool {
        switch action {
        case .click, .drag, .zoom: true
        case .scroll(_, _, let x, let y): x != nil || y != nil
        case .status, .screenshot, .type, .key, .setClipboard: false
        }
    }
}
