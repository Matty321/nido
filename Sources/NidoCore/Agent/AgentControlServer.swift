// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import NidoAgentKit
import Synchronization

/// The per-VM Unix socket through which `nido act` and `nido mcp` drive a macOS guest. It is
/// served by the process that owns the running VM (`nido start` or Nido.app), which forwards each
/// command to Nido Agent in the guest (`perform`, an `AgentClient` in production), but for the
/// checkpoint ops, which the owner answers itself (`AgentCheckpointHandling`).
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
/// agent and the user's `nido act`) never interleave a click with another's screenshot. The gate
/// also records each command it handles in the VM's activity log (`AgentActivityLog`).
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
    /// The longest line a `writeClipboard` command may be: 1 MiB of text JSON-escapes to at most
    /// six times its size (a control character is `\u00XX`), plus the envelope. Any other
    /// command over `maxLineBytes` is refused once its line is read.
    static let maxClipboardLineBytes = 6 * AgentProtocol.maxClipboardBytes + maxLineBytes
    /// How a line over `maxLineBytes` must start to be read at all: the client encodes with sorted
    /// keys (`AgentControlClient.encode`), which puts `action` first and its `op` before `text`.
    static let longLinePrefix = Data(#"{"action":{"op":"writeClipboard""#.utf8)

    /// The longest `AgentAnswer` line (a `uiTree` of 1000 elements with long names is far above
    /// `maxLineBytes`, which only bounds the commands the server reads).
    static let maxAnswerBytes = 2 * 1024 * 1024
    /// The longest answer that carries clipboard text: 1 MiB escapes to six times that.
    static let maxClipboardAnswerBytes = maxClipboardLineBytes
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
    ///
    /// `checkpoints` answers `checkpoint`, `checkpoints` and `rollback` (the owner's own work,
    /// never forwarded to the helper); without it they are refused (`badRequest`).
    public static func start(
        bundle: VMBundle, vmID: UUID,
        perform: @escaping @Sendable (AgentRequest) async throws(AgentFailure) -> (AgentReply, Data?),
        checkpoints: (any AgentCheckpointHandling)? = nil,
        recognizer: any TextRecognizing = VisionTextRecognizer(),
        root: URL = defaultRoot
    ) throws -> AgentControlServer {
        try start(bundle: bundle, vmID: vmID, perform: perform, checkpoints: checkpoints, root: root,
                  sendTimeoutSeconds: sendTimeoutSeconds, recognizer: recognizer)
    }

    /// `start` with the send timeout, the activity log's clock and its writer injectable (tests).
    static func start(
        bundle: VMBundle, vmID: UUID,
        perform: @escaping @Sendable (AgentRequest) async throws(AgentFailure) -> (AgentReply, Data?),
        checkpoints: (any AgentCheckpointHandling)? = nil,
        root: URL, sendTimeoutSeconds: Int, now: @escaping @Sendable () -> Date = { Date() },
        appendLog: AgentActivityWriter.Append? = nil, recognizer: any TextRecognizing = VisionTextRecognizer(),
        warmUp: Bool = true
    ) throws -> AgentControlServer {
        let url = socketURL(vmID: vmID, root: root)
        guard url.path.utf8.count <= maxSocketPathBytes else { throw NidoError.unsafePath(url.path) }
        let config = try bundle.readConfig()
        let vmName = config.name.rawValue
        // Vision loads its text model on the first recognition of a process, which can take tens of
        // seconds: with agent access on, do it now in the background, so the first read_text finds it
        // loaded. Requests that come meanwhile await this same load.
        let recognizer = (warmUp && config.agentAccess == true) ? WarmedTextRecognizer(recognizer) : recognizer
        // Files a previous owner staged and nobody read (it crashed, or its clients went away).
        AgentFiles.sweep(in: bundle, olderThan: AgentFiles.maxAge)
        let log = appendLog.map { AgentActivityWriter(vmName: vmName, append: $0) }
            ?? AgentActivityWriter(bundle: bundle, vmName: vmName)
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
                bundle: bundle, bundlePath: AgentCommand.bundlePath(bundle.url), vmName: vmName,
                sendTimeoutSeconds: sendTimeoutSeconds,
                gate: AgentGate(bundle: bundle, vmName: vmName, perform: perform, checkpoints: checkpoints,
                                recognizer: recognizer, now: now, log: log))
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

    /// Returns once the activity log has every entry handed to it so far (tests).
    func waitForLog() {
        core.gate.log.flush()
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
        /// The served bundle, for its staged files (`AgentFiles`).
        let bundle: VMBundle
        private let acceptEnded = DispatchSemaphore(value: 0)

        private struct State {
            var stopped = false
            var connections: Set<Int32> = []
        }
        private let state = Mutex(State())

        init(listenFD: Int32, wakeRead: Int32, wakeWrite: Int32, socketURL: URL, socketID: (dev_t, ino_t),
             vmID: UUID, bundle: VMBundle, bundlePath: String, vmName: String, sendTimeoutSeconds: Int,
             gate: AgentGate) {
            self.bundle = bundle
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
            // The last entries reach the disk before the owner goes on (the app may quit).
            gate.log.flush()
            AgentFiles.sweep(in: bundle, olderThan: AgentFiles.maxAge)
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
            var reader = LineReader(
                fd: fd, limit: AgentControlServer.maxClipboardLineBytes, softLimit: AgentControlServer.maxLineBytes,
                longPrefix: AgentControlServer.longLinePrefix)
            // The activity log's session of this connection, set by its first command.
            var session: String?
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
                    // Only a clipboard write may be longer than `maxLineBytes`.
                    if line.count > AgentControlServer.maxLineBytes {
                        guard case .writeClipboard = decoded.action else {
                            _ = Self.write(.failure(.badRequest, L10n.string("command longer than 64 KiB")), to: fd)
                            return
                        }
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
                guard let outcome = run(command, session: session) else { return }
                session = outcome.session
                guard Self.write(outcome.answer, to: fd) else {
                    // The client went away (it gave up waiting, was interrupted): nobody will
                    // read the file staged for it.
                    if let staged = outcome.answer.staged { AgentFiles.remove(staged, in: bundle) }
                    return
                }
                guard !outcome.close else { return }
            }
        }

        /// Runs `command` through the gate, blocking this (non-cooperative) connection thread
        /// until it is done. `session` is the connection's, nil before its first command. Nil
        /// once the server is stopping.
        private func run(_ command: AgentCommand, session: String?) -> AgentGate.Outcome? {
            let result = Mutex<AgentGate.Outcome?>(nil)
            let done = DispatchSemaphore(value: 0)
            let gate = gate
            Task { [self] in
                let outcome = await gate.run(command, connectionSession: session, stopped: { self.isStopped })
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
            let limit = answer.clipboard == nil
                ? AgentControlServer.maxAnswerBytes : AgentControlServer.maxClipboardAnswerBytes
            if line.count > limit {
                // The client would give up on this line as a lost connection: say what is wrong.
                let failure = AgentAnswer.failure(.internalError, L10n.string("the answer is too large: ask for fewer elements"))
                guard let small = try? JSONEncoder().encode(failure) else { return false }
                line = small
            }
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
    /// A line longer than `softLimit` is cut off unless it starts with `longPrefix` (the start of
    /// the one command allowed to be long, as `AgentControlClient` writes it with sorted keys), so
    /// a client cannot make the reader buffer more than `softLimit` bytes of any other command,
    /// nor have it decoded.
    let softLimit: Int
    let longPrefix: Data?
    private var buffer: [UInt8] = []
    /// How much of `buffer` is known to hold no `\n`.
    private var scanned = 0

    init(fd: Int32, limit: Int, softLimit: Int? = nil, longPrefix: Data? = nil) {
        self.fd = fd
        self.limit = limit
        self.softLimit = softLimit ?? limit
        self.longPrefix = longPrefix
    }

    /// Whether a line already past `softLimit` bytes may go on.
    private func longMayContinue() -> Bool {
        guard let longPrefix else { return false }
        return buffer.starts(with: longPrefix)
    }

    mutating func next() -> Next {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if let newline = buffer[scanned...].firstIndex(of: 0x0A) {
                guard newline <= limit else { return .tooLong }
                guard newline <= softLimit || longMayContinue() else { return .tooLong }
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                scanned = 0
                return .line(line)
            }
            scanned = buffer.count
            guard buffer.count <= limit else { return .tooLong }
            guard buffer.count <= softLimit || longMayContinue() else { return .tooLong }
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
///
/// Each command handled is handed to the activity log's writer within its turn, so entries keep
/// the order of the commands and never interleave; the writer appends them on a queue of its own
/// (`AgentActivityWriter`), so the answer never waits for the disk. Its session: the one the client sends (a `nido
/// mcp` run, one connection per command), else the connection's, else, for `act`, the last `act`
/// session when its last entry is less than `actSessionReuse` old (each `nido act` is a
/// connection of its own), else a new one.
actor AgentGate {
    struct Outcome: Sendable {
        var answer: AgentAnswer
        /// Close the connection after the answer.
        var close: Bool
        /// The PNG of a screenshot or zoom the agent got, for the log's thumbnail.
        var png: Data? = nil
        /// The activity log's session of the command.
        var session: String? = nil
    }

    /// How long after an `act` entry the next `act` command joins its session.
    static let actSessionReuse: TimeInterval = 10 * 60
    /// The longest session id a client may send.
    static let maxSessionCharacters = 64

    private let bundle: VMBundle
    /// The name at start, used when `config.json` cannot be read.
    private let vmName: String
    private let perform: @Sendable (AgentRequest) async throws(AgentFailure) -> (AgentReply, Data?)
    /// The owner's checkpoints; nil when the owner takes none.
    private let checkpoints: (any AgentCheckpointHandling)?
    /// Reads the text of a capture (read text), on the Mac.
    private let recognizer: any TextRecognizing
    /// The region the read-text command being handled captures, once known (for the log).
    private var readTextRegion: PixelRect?
    /// The sizes of the last screenshot the agent saw: the coordinates of the next click, drag or
    /// scroll refer to that image, and the helper maps them back to points with it.
    private var lastShot: (image: PixelSize, screen: ScreenSize)?
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private let now: @Sendable () -> Date
    /// The last `act` entry's session and time.
    private var lastAct: (session: String, time: Date)?
    /// Writes the activity log off the turn.
    nonisolated let log: AgentActivityWriter

    init(bundle: VMBundle, vmName: String,
         perform: @escaping @Sendable (AgentRequest) async throws(AgentFailure) -> (AgentReply, Data?),
         checkpoints: (any AgentCheckpointHandling)? = nil,
         recognizer: any TextRecognizing = VisionTextRecognizer(),
         now: @escaping @Sendable () -> Date = { Date() }, log: AgentActivityWriter) {
        self.bundle = bundle
        self.vmName = vmName
        self.perform = perform
        self.checkpoints = checkpoints
        self.recognizer = recognizer
        self.now = now
        self.log = log
    }

    /// Nil when `stopped()` is true by the time the command's turn comes: the server is going
    /// away and the command must not reach the guest. `connectionSession` is the session of the
    /// command's connection (nil before its first command); the outcome carries the one used.
    func run(_ command: AgentCommand, connectionSession: String?, stopped: @Sendable () -> Bool) async -> Outcome? {
        await acquire()
        defer { release() }
        guard !stopped() else { return nil }
        let time = now()
        let started = ContinuousClock.now
        var outcome = await handle(command)
        let elapsed = started.duration(to: .now).components
        let ms = Int(elapsed.seconds) * 1000 + Int(elapsed.attoseconds / 1_000_000_000_000_000)
        outcome.session = record(command, outcome: outcome, connectionSession: connectionSession, time: time, ms: ms)
        outcome.png = nil
        return outcome
    }

    /// Hands `command`'s entry to the log's writer (but for `setClipboard` and Nido's own
    /// `status` checks) and returns its session. Writing it never delays nor changes the answer.
    private func record(_ command: AgentCommand, outcome: Outcome, connectionSession: String?, time: Date,
                        ms: Int) -> String {
        let client = Self.clientKind(command.client)
        let session: String
        if let sent = Self.validSession(command.session) {
            session = sent
        } else if let connectionSession {
            session = connectionSession
        } else if client == AgentCommand.Client.act, let lastAct,
            case let age = time.timeIntervalSince(lastAct.time), age >= 0, age < Self.actSessionReuse {
            session = lastAct.session
        } else {
            session = UUID().uuidString.lowercased()
        }
        if client == AgentCommand.Client.act { lastAct = (session, time) }

        // A read-text command carries `.status` as its action: only a plain status is filtered out
        // here, so the `readText` check must stay with it.
        if client == AgentCommand.Client.nido, command.action == .status, command.readText == nil {
            return session
        }
        guard let entry = command.readText != nil
            ? AgentActivityEntry.makeReadText(
                region: readTextRegion, answer: outcome.answer, session: session, client: client, time: time, ms: ms)
            : AgentActivityEntry.make(
                action: command.action, answer: outcome.answer, session: session, client: client, time: time, ms: ms)
        else { return session }
        log.enqueue(entry, png: outcome.png)
        return session
    }

    /// `client` as the log records it: `mcp` or `nido` as sent, anything else (none included) `act`.
    static func clientKind(_ client: String?) -> String {
        switch client {
        case AgentCommand.Client.mcp: AgentCommand.Client.mcp
        case AgentCommand.Client.nido: AgentCommand.Client.nido
        default: AgentCommand.Client.act
        }
    }

    /// A session id a client sent, when it is a short token (ASCII letters, digits, `-`, `_`).
    static func validSession(_ session: String?) -> String? {
        guard let session, !session.isEmpty, session.utf8.count <= maxSessionCharacters,
            session.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") })
        else { return nil }
        return session
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

    private func handle(_ command: AgentCommand) async -> Outcome {
        readTextRegion = nil
        var action = command.action
        let readText = command.readText
        // A read-text command is a status carrying the request: on any other action it is malformed.
        if readText != nil, action != .status {
            return Outcome(answer: .failure(.badRequest, L10n.string("read_text does not go with another action")),
                           close: false)
        }
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
        if let answer = await answerCheckpoint(action) {
            return Outcome(answer: answer, close: false)
        }
        if let readText {
            // Host-only: the guest is asked for an ordinary zoom of the region, at native density.
            guard let lastShot else {
                return Outcome(answer: .failure(
                    .noScreenshot, L10n.string("take a screenshot first: coordinates refer to the last screenshot")),
                    close: false)
            }
            guard let region = Self.clamp(readText.region, to: lastShot.image) else {
                return Outcome(answer: .failure(.badRequest, L10n.string("the region is outside the screenshot")),
                               close: false)
            }
            readTextRegion = region
            action = .zoom(x: Double(region.x), y: Double(region.y), width: Double(region.w),
                           height: Double(region.h), maxLongEdge: Self.readTextLongEdge)
        }
        var request = AgentRequest(v: AgentProtocol.version, action: action)
        if case .putFile(_, let size) = action {
            // The bytes wait in the bundle under the name the client sent: only a staged file's
            // name, read from the staging folder without following a symlink, and only as many
            // bytes as the command says. Taken (so deleted) before anything reaches the helper.
            guard let staged = command.staged, let data = try? AgentFiles.take(staged, in: bundle),
                data.count == size
            else {
                return Outcome(answer: .failure(.badRequest, L10n.string("the staged file is missing or invalid")),
                               close: false)
            }
            request.payload = data
        }
        if Self.carriesPoint(action) {
            guard let lastShot else {
                return Outcome(answer: .failure(
                    .noScreenshot, L10n.string("take a screenshot first: coordinates refer to the last screenshot")),
                    close: false)
            }
            request.image = lastShot.image
            request.screen = lastShot.screen
        }
        if let minimum = Self.minimumHelperVersion(for: action) {
            // A helper older than the op answers "unknown action": ask its version first,
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
                      MacAgentInstaller.compareVersions(version, minimum) >= 0 else {
                    let name = config.name.rawValue
                    let message: String
                    switch action {
                    case .zoom where readText != nil:
                        message = L10n.string("Nido Agent is too old for read_text: run nido agent setup \(name) to update it")
                    case .uiTree:
                        message = L10n.string("Nido Agent is too old for ui_tree: run nido agent setup \(name) to update it")
                    case .putFile, .getFile, .listFiles:
                        message = L10n.string("Nido Agent is too old for files: run nido agent setup \(name) to update it")
                    case .readClipboard, .writeClipboard:
                        message = L10n.string("Nido Agent is too old for the clipboard: run nido agent setup \(name) to update it")
                    default:
                        message = L10n.string("Nido Agent is too old to zoom: run nido agent setup \(name) to update it")
                    }
                    return Outcome(answer: .failure(.versionMismatch, message), close: false)
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
        let frame: Data?
        do {
            (reply, frame) = try await perform(request)
        } catch where error.code == .versionMismatch {
            // `AgentClient` does not know the VM: the command that updates the helper is named here.
            return Outcome(answer: .failure(.versionMismatch, L10n.string(
                "incompatible Nido Agent version: run nido agent setup \(config.name.rawValue) to update Nido Agent")),
                close: false)
        } catch {
            return Outcome(answer: .failure(error.code, error.message), close: false)
        }
        var answer = AgentAnswer(ok: reply.ok, status: reply.status, image: reply.image, screen: reply.screen,
                                 error: reply.error, message: reply.message, tree: reply.tree, files: reply.files,
                                 truncated: reply.truncated, bytes: reply.bytes, clipboard: reply.clipboard)
        if case .getFile = action, reply.ok {
            // The bytes go to the client through the bundle, never in the answer's line.
            guard let data = frame else {
                return Outcome(answer: .failure(.internalError, L10n.string("could not talk to Nido Agent")), close: false)
            }
            do {
                answer.staged = try AgentFiles.stage(data, in: bundle)
            } catch {
                return Outcome(answer: .failure(.internalError, L10n.string("could not save the file")), close: false)
            }
            answer.bytes = data.count
            return Outcome(answer: answer, close: false)
        }
        if let readText, reply.ok {
            // Fail closed: a read-text command never falls through to the plain image branch,
            // which would save the capture in agent-shots.
            guard let region = readTextRegion, let shot = lastShot, let png = frame else {
                return Outcome(answer: .failure(.internalError, L10n.string("could not talk to Nido Agent")), close: false)
            }
            let found: [RecognizedText]
            do {
                found = try await recognizer.recognize(png: png)
            } catch {
                return Outcome(answer: .failure(.internalError, L10n.string("could not read the text on the screen")),
                               close: false)
            }
            let result = TextReading.lines(
                found, region: region, screenshot: shot.image, maxLines: max(1, min(readText.maxLines, Self.maxReadTextLines)))
            // Text only: the capture is for the log's thumbnail, never for the client.
            return Outcome(answer: AgentAnswer(ok: true, image: shot.image, screen: shot.screen, lines: result.lines,
                                               truncated: result.truncated),
                           close: false, png: png)
        }
        if action.isImageAction, reply.ok {
            guard let png = frame, let image = reply.image, let screen = reply.screen else {
                return Outcome(answer: .failure(.internalError, L10n.string("could not talk to Nido Agent")), close: false)
            }
            do {
                answer.path = try AgentShots.write(png, in: bundle).path
            } catch {
                return Outcome(answer: .failure(.internalError, L10n.string("could not save the screenshot")), close: false)
            }
            // A zoom never changes what coordinates refer to.
            if case .screenshot = action { lastShot = (image, screen) }
            return Outcome(answer: answer, close: false, png: png)
        }
        return Outcome(answer: answer, close: false)
    }

    /// The owner's answer to a checkpoint op (nil for any other action): checkpoints are the
    /// owner's own work, never Nido Agent's. An owner that takes none refuses them.
    private func answerCheckpoint(_ action: AgentAction) async -> AgentAnswer? {
        let refused = AgentAnswer.failure(.badRequest, L10n.string("this VM’s owner can’t take checkpoints"))
        switch action {
        case .checkpoint(let name):
            return await checkpoints?.checkpoint(name: name) ?? refused
        case .rollback(let name):
            return await checkpoints?.rollback(name: name) ?? refused
        case .checkpoints:
            return await checkpoints?.checkpoints() ?? refused
        default:
            return nil
        }
    }

    /// The long edge of a read-text capture, the most a zoom takes: native density, for small text.
    static let readTextLongEdge = 4096
    /// The most lines a read-text answer holds.
    static let maxReadTextLines = 1000

    /// `region` (nil: all of `image`) cut to `image`'s bounds, like a zoom; nil if nothing is left.
    static func clamp(_ region: PixelRect?, to image: PixelSize) -> PixelRect? {
        guard let region else { return PixelRect(x: 0, y: 0, w: image.width, h: image.height) }
        // Each component is bounded before any sum: the numbers come off the socket unchecked.
        let limit = Int(Int32.max)
        let rx = min(max(region.x, 0), limit), ry = min(max(region.y, 0), limit)
        let rw = min(max(region.w, 0), limit), rh = min(max(region.h, 0), limit)
        let x0 = min(rx, image.width), y0 = min(ry, image.height)
        let x1 = min(max(rx + rw, x0), image.width), y1 = min(max(ry + rh, y0), image.height)
        guard x1 > x0, y1 > y0 else { return nil }
        return PixelRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
    }

    /// The first Nido Agent that understands `action`, or nil when every helper does.
    static func minimumHelperVersion(for action: AgentAction) -> String? {
        switch action {
        case .zoom: AgentProtocol.minimumZoomHelperVersion
        case .uiTree: AgentProtocol.minimumUITreeHelperVersion
        case .putFile, .getFile, .listFiles: AgentProtocol.minimumFilesHelperVersion
        case .readClipboard, .writeClipboard: AgentProtocol.minimumClipboardHelperVersion
        default: nil
        }
    }

    /// Actions whose coordinates refer to the last screenshot. A scroll without a point scrolls
    /// where the pointer is and needs none.
    static func carriesPoint(_ action: AgentAction) -> Bool {
        switch action {
        case .click, .drag, .zoom, .uiTree: true
        case .scroll(_, _, let x, let y): x != nil || y != nil
        case .status, .screenshot, .type, .key, .setClipboard, .readClipboard, .writeClipboard, .checkpoint, .rollback, .checkpoints,
             .putFile, .getFile, .listFiles: false
        }
    }
}
