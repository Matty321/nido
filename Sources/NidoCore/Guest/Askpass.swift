// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import Synchronization

/// How the guest account password reaches `ssh` for `GuestCommand.authorizeNidoKey`, without ever
/// being on a command line, in an environment or on disk.
///
/// `GuestSSH.authorizeNidoKey` opens an `AskpassServer` (a one-shot Unix socket of this user) and
/// runs ssh with `SSH_ASKPASS=<nido>`, `SSH_ASKPASS_REQUIRE=force`, `NIDO_ASKPASS=1` and
/// `NIDO_ASKPASS_SOCKET=<socket path>`. For the password prompt ssh runs `nido "<prompt>"`, which,
/// in askpass mode (`answer`), fetches the password from the socket and prints it on its stdout,
/// read by ssh through a pipe. The socket answers once: a second prompt (a wrong password) gets
/// nothing, and `NumberOfPasswordPrompts=1` bounds ssh anyway.
public enum Askpass {
    /// The socket path, in ssh's environment and so in the askpass child's.
    public static let socketVariable = "NIDO_ASKPASS_SOCKET"
    /// `"1"`: `nido` runs as ssh's askpass instead of parsing its arguments.
    public static let modeVariable = "NIDO_ASKPASS"
    /// The longest answer accepted: a password is far shorter.
    public static let maxAnswerBytes = 4096
    /// How long `fetch` waits for the answer once connected.
    static let readTimeoutSeconds = 10

    /// `<the user's temporary folder>/nido-askpass`: per-user, private and short enough for the
    /// socket path (`confstr(_CS_DARWIN_USER_TEMP_DIR)`, as `AgentControlServer.defaultRoot`).
    public static var defaultDirectory: URL {
        directory(userTempDirectory: AgentControlServer.darwinUserTempDirectory())
    }

    /// `<userTempDirectory>/nido-askpass`; without an absolute folder,
    /// `/private/tmp/nido-askpass-<uid>` (`AskpassServer` still requires it to be private).
    static func directory(userTempDirectory: String?) -> URL {
        guard let folder = userTempDirectory, folder.hasPrefix("/") else {
            return URL(fileURLWithPath: "/private/tmp/nido-askpass-\(getuid())", isDirectory: true)
        }
        return URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent("nido-askpass", isDirectory: true)
    }

    /// Connects to `socketPath`, served by a process of this user, and reads the answer to its
    /// end (at most `maxAnswerBytes`). Throws when nobody answers (no socket, the answer already
    /// given, the server closed) or the answer is empty or too long.
    public static func fetch(socketPath: String) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentControlServer.posixError() }
        defer { _ = Darwin.close(fd) }
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw AgentControlServer.posixError() }
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: readTimeoutSeconds, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = try AgentControlServer.socketAddress(URL(fileURLWithPath: socketPath))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw AgentControlServer.posixError() }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw POSIXError(.EPERM) }

        var answer = Data()
        var buffer = [UInt8](repeating: 0, count: 512)
        defer { _ = memset_s(&buffer, buffer.count, 0, buffer.count) }
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                let error = AgentControlServer.posixError()
                answer.resetBytes(in: 0..<answer.count)
                throw error
            }
            answer.append(contentsOf: buffer[0..<count])
            guard answer.count <= maxAnswerBytes else {
                answer.resetBytes(in: 0..<answer.count)
                throw POSIXError(.EMSGSIZE)
            }
        }
        guard !answer.isEmpty else { throw POSIXError(.ECONNREFUSED) }
        return answer
    }

    /// The askpass mode of `nido`, run before any argument parsing: nil when `environment` does
    /// not ask for it (`NIDO_ASKPASS` other than `"1"`). Otherwise the exit code: 0 after handing
    /// the fetched password and a newline to `write` (ssh reads them from the child's stdout), 1
    /// with nothing written when there is no socket or no answer. Nothing is logged; ssh's
    /// prompt (the first argument) is ignored.
    public static func answer(environment: [String: String], write: (Data) throws -> Void) -> Int32? {
        guard environment[modeVariable] == "1" else { return nil }
        guard let path = environment[socketVariable], !path.isEmpty,
            var output = try? fetch(socketPath: path)
        else { return 1 }
        defer { output.resetBytes(in: 0..<output.count) }
        output.append(0x0A)
        do { try write(output) } catch { return 1 }
        return 0
    }

    /// Writes all of `data` to `descriptor` (stdout for `answer`), without stdio buffers.
    public static func writeAll(_ data: Data, to descriptor: Int32 = STDOUT_FILENO) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(descriptor, base + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw AgentControlServer.posixError()
                }
                offset += written
            }
        }
    }

    /// The `nido` that answers as ssh's askpass: `Contents/Helpers/nido` inside an app bundle
    /// (Nido.app) when it is there; otherwise the main executable itself, symlinks resolved, when
    /// it is `nido` (the CLI, also through `~/.local/bin/nido`). Nil otherwise.
    public static func executable(bundle: Bundle = .main) -> URL? {
        let helper = bundle.bundleURL.appendingPathComponent("Contents/Helpers/nido")
        if bundle.bundleURL.pathExtension == "app", FileManager.default.isExecutableFile(atPath: helper.path) {
            return helper
        }
        guard let main = bundle.executableURL, main.lastPathComponent == "nido" else { return nil }
        return main.resolvingSymlinksInPath()
    }
}

/// A one-shot Unix socket that hands the guest password to the askpass child of one ssh run.
///
/// It lives in a 0700 directory of this user (`Askpass.defaultDirectory`) under a random name,
/// is itself 0600, and answers **one** connection whose peer is this user (`getpeereid`) and is
/// the askpass child of the one ssh the caller launched for it (`expect(ssh:)`, checked by
/// `isAskpass(_:ofSSH:)` with the peer's pid from `LOCAL_PEERPID`): it stops listening and
/// removes the socket, then writes the password's UTF-8 bytes and hangs up. Before
/// `expect(ssh:)` no peer passes. Any other connection is closed without an answer and does not
/// use it up. Nobody connecting within `idleTimeout` also ends it. `close()` (idempotent, also run on
/// deinit) removes the socket and forgets the password.
public final class AskpassServer: Sendable {
    /// How long the socket waits for its one connection.
    public static let idleTimeout: Duration = .seconds(60)
    /// The ssh whose askpass may get the password (`GuestSSH` runs this one).
    static let sshPath = "/usr/bin/ssh"

    public let socketPath: String
    private let core: Core

    public convenience init(password: GuestPassword, directory: URL = Askpass.defaultDirectory) throws {
        try self.init(
            password: password, directory: directory, idleTimeout: Self.idleTimeout,
            peerCheck: { peer, ssh in Self.isAskpass(peer, ofSSH: ssh) })
    }

    /// `init` with the idle timeout and the peer check injectable (tests: the real check refuses
    /// the test process, which is no ssh's child). The check gets the peer's pid and the ssh named
    /// by `expect(ssh:)`, nil until then.
    init(
        password: GuestPassword, directory: URL, idleTimeout: Duration = AskpassServer.idleTimeout,
        peerCheck: @escaping @Sendable (pid_t, pid_t?) -> Bool
    ) throws {
        try AgentControlServer.prepareDirectory(directory)
        let name = String(UInt64.random(in: .min ... .max), radix: 16) + ".sock"
        let url = directory.appendingPathComponent(name)
        guard url.path.utf8.count <= AgentControlServer.maxSocketPathBytes else {
            throw NidoError.unsafePath(url.path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentControlServer.posixError() }
        var wake: [Int32] = [-1, -1]
        var bound = false
        do {
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw AgentControlServer.posixError() }
            var address = try AgentControlServer.socketAddress(url)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw AgentControlServer.posixError() }
            bound = true
            guard chmod(url.path, 0o600) == 0 else { throw AgentControlServer.posixError() }
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw AgentControlServer.posixError() }
            guard listen(fd, 4) == 0 else { throw AgentControlServer.posixError() }
            // Non-blocking: a client gone between `poll` and `accept` must not block the thread.
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw AgentControlServer.posixError() }
            guard pipe(&wake) == 0 else { throw AgentControlServer.posixError() }
            for end in wake {
                _ = fcntl(end, F_SETFD, FD_CLOEXEC)
                let flags = fcntl(end, F_GETFL)
                if flags >= 0 { _ = fcntl(end, F_SETFL, flags | O_NONBLOCK) }
            }
            let core = Core(
                password: password, listenFD: fd, wakeRead: wake[0], wakeWrite: wake[1], path: url.path,
                socketID: (info.st_dev, info.st_ino), deadline: .now + idleTimeout, peerCheck: peerCheck)
            self.core = core
            self.socketPath = url.path
            Thread { core.serve() }.start()
        } catch {
            if bound { _ = Darwin.unlink(url.path) }
            _ = Darwin.close(fd)
            for end in wake where end >= 0 { _ = Darwin.close(end) }
            throw error
        }
    }

    deinit { core.close() }

    /// Names the ssh the caller launched (its pid, from the runner's `onLaunch`): only its
    /// askpass child can get the password.
    public func expect(ssh pid: pid_t) {
        core.expect(ssh: pid)
    }

    /// True once the one answer was written to a client: ssh's askpass got the password. False
    /// when nobody of this user fetched it (ssh never asked, or the askpass failed to connect).
    public var answered: Bool { core.answered }

    /// Removes the socket (if it is still the one this server made), forgets the password and
    /// waits for the serving thread to end. Idempotent.
    public func close() {
        core.close()
    }

    // MARK: - Peer check

    /// True when `peer` (the process connected to the socket) is a child of `ssh`, the
    /// `/usr/bin/ssh` the caller launched, itself a child of this process: the askpass that ssh
    /// runs for its password prompt. Not another process of the same user that found the
    /// socket, nor the askpass of another ssh this process runs. Nil `ssh` (not launched yet):
    /// false.
    ///
    /// `LOCAL_PEERPID` is enough, no `LOCAL_PEERTOKEN` (audit token) is needed: the launched ssh
    /// is our unreaped child while it runs, so its pid stays its own and only it can be the parent
    /// of a process with that parent pid. A peer pid reused after the askpass exited would need
    /// that ssh as its parent too; an ssh pid reused after ssh exited would need to be
    /// `/usr/bin/ssh` and a child of this process, which only a launch of ours makes.
    static func isAskpass(_ peer: pid_t, ofSSH ssh: pid_t?) -> Bool {
        isAskpass(peer, ofSSH: ssh, ownPID: getpid(), parent: parentPID(of:), executable: executablePath(of:))
    }

    /// `isAskpass(_:ofSSH:)` with the process lookups injectable (tests).
    static func isAskpass(
        _ peer: pid_t, ofSSH ssh: pid_t?, ownPID: pid_t, parent: (pid_t) -> pid_t?, executable: (pid_t) -> String?
    ) -> Bool {
        guard peer > 0, let ssh, ssh > 1, parent(peer) == ssh, executable(ssh) == sshPath, parent(ssh) == ownPID
        else { return false }
        return true
    }

    /// The parent of `pid` (`sysctl` `KERN_PROC_PID`), nil when there is no such process.
    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size == MemoryLayout<kinfo_proc>.stride,
            info.kp_proc.p_pid == pid
        else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// The executable of `pid` (`proc_pidpath`), nil when it cannot be read.
    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    /// The pid of the process at the other end of the Unix socket `fd` (`LOCAL_PEERPID`).
    static func peerPID(_ fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0 else { return nil }
        return pid
    }

    /// What the serving thread and `close()` share. The thread owns `listenFD` and closes it when
    /// it ends; the first `close()` closes the wake pipe after the thread has ended.
    private final class Core: Sendable {
        struct State {
            var password: GuestPassword?
            /// The ssh whose askpass may connect (`expect(ssh:)`).
            var ssh: pid_t?
            var closed = false
            var socketRemoved = false
            var answered = false
        }

        var answered: Bool { state.withLock { $0.answered } }

        private let state: Mutex<State>
        private let listenFD: Int32
        private let wakeRead: Int32
        private let wakeWrite: Int32
        private let path: String
        private let socketID: (dev_t, ino_t)
        private let deadline: ContinuousClock.Instant
        private let ended = DispatchSemaphore(value: 0)
        private let peerCheck: @Sendable (pid_t, pid_t?) -> Bool

        init(
            password: GuestPassword, listenFD: Int32, wakeRead: Int32, wakeWrite: Int32, path: String,
            socketID: (dev_t, ino_t), deadline: ContinuousClock.Instant,
            peerCheck: @escaping @Sendable (pid_t, pid_t?) -> Bool
        ) {
            self.peerCheck = peerCheck
            self.state = Mutex(State(password: password))
            self.listenFD = listenFD
            self.wakeRead = wakeRead
            self.wakeWrite = wakeWrite
            self.path = path
            self.socketID = socketID
            self.deadline = deadline
        }

        func expect(ssh pid: pid_t) {
            state.withLock { $0.ssh = pid }
        }

        func close() {
            let first = state.withLock { s -> Bool in
                guard !s.closed else { return false }
                s.closed = true
                s.password = nil
                return true
            }
            guard first else { return }
            removeSocket()
            var byte: UInt8 = 1
            _ = Darwin.write(wakeWrite, &byte, 1)
            ended.wait()
            _ = Darwin.close(wakeRead)
            _ = Darwin.close(wakeWrite)
        }

        /// Unlinks the socket file once, only while it is still the one this server bound.
        private func removeSocket() {
            state.withLock { s in
                guard !s.socketRemoved else { return }
                s.socketRemoved = true
                var info = stat()
                if lstat(path, &info) == 0, info.st_dev == socketID.0, info.st_ino == socketID.1 {
                    _ = Darwin.unlink(path)
                }
            }
        }

        /// Waits for the one connection of this user, answers it and ends; also ends on
        /// `close()` (the wake pipe) or at the deadline.
        func serve() {
            defer {
                removeSocket()
                _ = Darwin.close(listenFD)
                state.withLock { $0.password = nil }
                ended.signal()
            }
            while true {
                let remaining = ContinuousClock.now.duration(to: deadline)
                guard remaining > .zero else { return }
                let (seconds, attoseconds) = remaining.components
                let milliseconds = min(Int32(clamping: seconds * 1000 + attoseconds / 1_000_000_000_000_000 + 1), 1000)
                var fds = [
                    pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0),
                    pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0),
                ]
                let ready = poll(&fds, 2, milliseconds)
                if ready < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if fds[1].revents != 0 { return }
                guard fds[0].revents != 0 else { continue }
                let connection = accept(listenFD, nil, nil)
                guard connection >= 0 else { continue }
                if answer(connection) { return }
            }
        }

        /// Answers `connection` when its peer is this user and passes `peerCheck` (by its pid):
        /// true once the answer is used up. Another peer is hung up on and the socket keeps
        /// waiting.
        private func answer(_ connection: Int32) -> Bool {
            defer { _ = Darwin.close(connection) }
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard fcntl(connection, F_SETFD, FD_CLOEXEC) == 0, getpeereid(connection, &uid, &gid) == 0,
                uid == getuid(), let pid = AskpassServer.peerPID(connection),
                peerCheck(pid, state.withLock { $0.ssh }),
                Self.prepare(connection)
            else { return false }
            let password = state.withLock { s -> GuestPassword? in
                defer { s.password = nil }
                return s.password
            }
            // No second connection can reach the socket any more, before the answer is written.
            removeSocket()
            guard let password else { return true }
            var bytes = Array(password.value.utf8)
            defer { _ = memset_s(&bytes, bytes.count, 0, bytes.count) }
            var offset = 0
            while offset < bytes.count {
                let written = bytes.withUnsafeBytes { raw in
                    Darwin.write(connection, raw.baseAddress! + offset, raw.count - offset)
                }
                if written < 0 {
                    if errno == EINTR { continue }
                    break
                }
                offset += written
            }
            if offset == bytes.count { state.withLock { $0.answered = true } }
            return true
        }

        /// Blocking writes (the socket inherits O_NONBLOCK from the listener), no SIGPIPE and a
        /// bound on a client that stopped reading.
        private static func prepare(_ fd: Int32) -> Bool {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == 0 else { return false }
            var one: Int32 = 1
            guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0
            else { return false }
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            return setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0
        }
    }
}
