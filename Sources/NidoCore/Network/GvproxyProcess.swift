// SPDX-License-Identifier: Apache-2.0
import Foundation
import Security
import Synchronization

/// One `gvproxy` per controlled VM: the userspace NAT behind the controlled-network relay.
///
/// Each process gets its own runtime directory, `<runtimeRoot>/<first 8 hex digits of the VM id>/`
/// (0700), holding:
/// - `vfkit.sock`: the `SOCK_DGRAM` socket `gvproxy` listens on (one raw Ethernet frame per
///   datagram, no handshake);
/// - `client.sock`: the path Nido's side binds before sending (`gvproxy` answers only a named peer);
/// - `gvproxy.pid`: the PID, then the start time of the process (`proc_bsdinfo`);
/// - `gvproxy.yaml` and `token` (0600): the configuration and the API token, see below;
/// - `owner.lock`: held with `flock(2)` by the Nido process that started `gvproxy` for as long as it
///   lives. A free lock marks an orphan left by a Nido that died (`sweepOrphans`).
///
/// `gvproxy` is always started with a configuration file: the VM's MAC gets the static lease
/// `192.168.127.2`, the only forward is `127.0.0.1:<sshPort>` to `192.168.127.2:22`. It is always
/// started with `-api-token-file` holding a fresh random token Nido never uses, so the HTTP API the
/// gateway offers the guest on port 80 answers 401. `-listen` (the control API) is never passed.
/// What `gvproxy` prints goes to `VMBundle.gvproxyLogURL`; it never holds traffic content
/// (`-debug` is never passed).
///
/// `gvproxy` outlives its parent: `stop()` must be called when the VM stops, and `sweepOrphans`
/// (run at every `start`, at the app's launch and at the beginning of `nido start`) ends the ones
/// a dead Nido left behind.
public final class GvproxyProcess: Sendable {
    /// `gvproxy`'s vfkit socket.
    public let socketURL: URL
    /// The path Nido's side of the vfkit socket binds to.
    public let clientSocketURL: URL
    /// The loopback port `gvproxy` forwards to the guest's SSH.
    public let sshPort: UInt16
    public let pid: Int32

    private let bundle: VMBundle
    private let claim: Claim
    private let state = Mutex(State())
    /// Entered at spawn, left once the process is reaped.
    private let exited = DispatchGroup()
    private let handlerQueue = DispatchQueue(label: "nido.gvproxy.exit")

    private struct State {
        /// True from the moment the process is known to be dead (a zombie, not yet reaped): no
        /// signal is sent after that, so a reused PID is never hit.
        var dead = false
        /// Set once the process is reaped: its exit code, or 128 + the signal.
        var exitCode: Int32?
        var handlers: [@Sendable (Int32) -> Void] = []
        var stopped = false
    }

    /// Fixed addresses of `gvproxy`'s network (see the spike document).
    public static let guestAddress = "192.168.127.2"
    /// A Unix socket path must fit `sockaddr_un.sun_path` (104 bytes) with its NUL.
    static let maxSocketPathBytes = 103
    /// Above this size `gvproxy.log` is emptied at the next start.
    static let maxLogBytes: off_t = 1 << 20
    /// How long `stop()` waits after SIGTERM before SIGKILL.
    static let termGrace: Double = 2

    /// `<$TMPDIR>/nido-gv`: short enough for the socket paths, private to this user.
    public static var defaultRuntimeRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("nido-gv", isDirectory: true)
    }

    private init(socketURL: URL, clientSocketURL: URL, sshPort: UInt16, pid: Int32, bundle: VMBundle, claim: Claim) {
        self.socketURL = socketURL
        self.clientSocketURL = clientSocketURL
        self.sshPort = sshPort
        self.pid = pid
        self.bundle = bundle
        self.claim = claim
        exited.enter()
        Thread { [self] in self.reap() }.start()
    }

    // MARK: - Start

    /// Starts `gvproxy` for the VM `vmID` (whose MAC is read from `bundle`'s `config.json`) and
    /// waits until its vfkit socket exists and its SSH port accepts connections on `127.0.0.1`,
    /// at most `timeout`. Runs `sweepOrphans(runtimeRoot:)` first. If `gvproxy` cannot bind the
    /// chosen port (another process took it in the meantime), it is tried once more with a new one.
    /// On success `bundle.sshForwardURL` holds the port and the PID.
    /// Throws `NidoError.controlledNetworkUnavailable` (localized, without paths); nothing is left
    /// running or on disk then.
    public static func start(
        vmID: UUID, bundle: VMBundle, binary: URL, runtimeRoot: URL = GvproxyProcess.defaultRuntimeRoot,
        timeout: Duration = .seconds(10)
    ) throws -> GvproxyProcess {
        try start(vmID: vmID, bundle: bundle, binary: binary, runtimeRoot: runtimeRoot, timeout: timeout,
                  pickPort: freeLoopbackPort)
    }

    /// `start` with the port choice injectable (tests).
    static func start(
        vmID: UUID, bundle: VMBundle, binary: URL, runtimeRoot: URL, timeout: Duration,
        pickPort: () throws -> UInt16
    ) throws -> GvproxyProcess {
        sweepOrphans(runtimeRoot: runtimeRoot)

        let short = String(vmID.uuidString.lowercased().prefix(8))
        let directory = runtimeRoot.appendingPathComponent(short, isDirectory: true)
        let socketURL = directory.appendingPathComponent("vfkit.sock")
        let clientSocketURL = directory.appendingPathComponent("client.sock")
        guard socketURL.path.utf8.count <= maxSocketPathBytes, clientSocketURL.path.utf8.count <= maxSocketPathBytes
        else { throw NidoError.controlledNetworkUnavailable(L10n.string("gvproxy socket path too long")) }
        // The path goes into a `unixgram://` URL that gvproxy parses: nothing that URL syntax could
        // reinterpret.
        guard directory.path.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "/._-".contains($0)) })
        else { throw NidoError.controlledNetworkUnavailable(L10n.string("invalid gvproxy path")) }

        let mac = try normalizedMAC(bundle.readConfig().macAddress)
        try prepareRoot(runtimeRoot)
        let claim = try Claim.take(directory, root: runtimeRoot, name: short)

        let logFD: Int32
        let token = directory.appendingPathComponent("token")
        let configURL = directory.appendingPathComponent("gvproxy.yaml")
        do {
            try writePrivate(Data(randomToken().utf8), to: token)
            logFD = try openLog(bundle.gvproxyLogURL)
        } catch {
            claim.release()
            throw error
        }
        defer { _ = Darwin.close(logFD) }

        for attempt in 0..<2 {
            let port: UInt16
            let pid: Int32
            let logOffset: off_t
            do {
                port = try pickPort()
                try PrivateFile.writeAtomically(Data(configuration(mac: mac, sshPort: port).utf8), to: configURL)
                _ = Darwin.unlink(socketURL.path)  // gvproxy refuses a path that exists
                logOffset = lseek(logFD, 0, SEEK_END)
                pid = try spawn(binary, arguments: [
                    "-config", configURL.path,
                    "-listen-vfkit", "unixgram://" + socketURL.path,
                    "-api-token-file", token.path,
                ], output: logFD)
            } catch {
                claim.release()
                throw (error as? NidoError) ?? NidoError.controlledNetworkUnavailable(L10n.string("gvproxy didn’t start"))
            }
            let process = GvproxyProcess(
                socketURL: socketURL, clientSocketURL: clientSocketURL, sshPort: port, pid: pid,
                bundle: bundle, claim: claim)
            do {
                try PrivateFile.writeAtomically(Data(pidRecord(pid).utf8), to: directory.appendingPathComponent("gvproxy.pid"))
            } catch {
                process.stop()
                throw NidoError.controlledNetworkUnavailable(L10n.string("gvproxy didn’t start"))
            }

            switch process.waitUntilReady(timeout: timeout) {
            case .ready:
                do {
                    let record = try JSONEncoder.sorted.encode(SSHForward(port: port, pid: pid, start: startTime(pid)))
                    try PrivateFile.writeAtomically(record, to: bundle.sshForwardURL)
                } catch {
                    process.stop()
                    throw NidoError.controlledNetworkUnavailable(L10n.string("gvproxy didn’t start"))
                }
                return process
            case .exited:
                // The process is gone and reaped: the directory and the lock stay for the retry.
                if attempt == 0, logText(bundle.gvproxyLogURL, from: logOffset).contains("address already in use") {
                    continue
                }
                process.stop()
                throw NidoError.controlledNetworkUnavailable(L10n.string("gvproxy stopped while starting"))
            case .timedOut:
                process.stop()
                throw NidoError.controlledNetworkUnavailable(L10n.string("gvproxy isn’t responding"))
            }
        }
        claim.release()
        throw NidoError.controlledNetworkUnavailable(L10n.string("gvproxy stopped while starting"))
    }

    private enum Readiness { case ready, exited, timedOut }

    /// Ready once the vfkit socket exists (gvproxy creates it after binding the forward) and the SSH
    /// port accepts a connection on 127.0.0.1.
    private func waitUntilReady(timeout: Duration) -> Readiness {
        let deadline = DispatchTime.now() + timeout.seconds
        while DispatchTime.now() < deadline {
            if exited.wait(timeout: .now()) == .success { return .exited }
            var info = stat()
            if lstat(socketURL.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK,
                Self.acceptsLoopback(sshPort) {
                return .ready
            }
            usleep(20_000)
        }
        return exited.wait(timeout: .now()) == .success ? .exited : .timedOut
    }

    // MARK: - Exit and stop

    /// Calls `handler` once, on a queue of its own, with the exit code of `gvproxy` (or 128 + the
    /// signal that ended it). Called at once (asynchronously) if it has already exited.
    public func onExit(_ handler: @escaping @Sendable (Int32) -> Void) {
        state.withLock { state in
            if let code = state.exitCode {
                handlerQueue.async { handler(code) }
            } else {
                state.handlers.append(handler)
            }
        }
    }

    /// Ends `gvproxy` (SIGTERM, then SIGKILL after 2 s), then removes its runtime directory and
    /// `ssh-forward.json` and releases the ownership lock. Safe to call more than once.
    ///
    /// `keepingForwardRecord`: when gvproxy is lost while the VM still runs, `ssh-forward.json`
    /// stays, its PID now dead, so `nido ssh` says the controlled network was interrupted (see
    /// `VMControl.resolveSSH`) instead of "not on the network yet". A later `stop()` (the VM's
    /// own stop) removes it.
    ///
    /// The record goes before the signal, so nothing reads a dead PID in it during a normal stop
    /// (the Rete view would show "interrupted" for a moment), and only when it is this process's
    /// own: a newer run of the same VM may have written its own meanwhile.
    public func stop(keepingForwardRecord: Bool = false) {
        let first = state.withLock { state in
            defer { state.stopped = true }
            return !state.stopped
        }
        if !keepingForwardRecord { removeOwnForwardRecord() }
        if first {
            signal(SIGTERM)
            if exited.wait(timeout: .now() + Self.termGrace) == .timedOut {
                signal(SIGKILL)
                _ = exited.wait(timeout: .now() + 5)
            }
            claim.release()
        }
    }

    /// Removes `ssh-forward.json` when it names this process (its PID).
    private func removeOwnForwardRecord() {
        guard let data = try? Data(contentsOf: bundle.sshForwardURL),
              let record = try? JSONDecoder().decode(SSHForward.self, from: data), record.pid == pid
        else { return }
        _ = Darwin.unlink(bundle.sshForwardURL.path)
    }

    /// Sends `signal` while the process is still alive (never once it is known dead: its PID could
    /// be reused after it is reaped).
    private func signal(_ signal: Int32) {
        state.withLock { state in
            if !state.dead { _ = kill(pid, signal) }
        }
    }

    /// Waits for the child without reaping it, marks it dead, then reaps it and reports the code.
    private func reap() {
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) != 0 {
            guard errno == EINTR else { break }
        }
        state.withLock { $0.dead = true }
        var status: Int32 = 0
        var reaped: pid_t
        repeat { reaped = waitpid(pid, &status, 0) } while reaped < 0 && errno == EINTR
        // WIFEXITED / WEXITSTATUS / WTERMSIG are macros, not imported into Swift.
        let signal = status & 0x7f
        let code: Int32 = reaped < 0 ? -1 : (signal == 0 ? (status >> 8) & 0xff : 128 + signal)
        let handlers = state.withLock { state in
            state.exitCode = code
            defer { state.handlers = [] }
            return state.handlers
        }
        handlerQueue.async { handlers.forEach { $0(code) } }
        exited.leave()
    }

    /// Releases the ownership lock without stopping anything, as if this Nido had died (tests).
    func abandonForTesting() {
        claim.abandon()
    }

    // MARK: - Orphans

    /// Ends what a Nido that died left in `runtimeRoot`: every VM directory whose ownership lock is
    /// free. Its `gvproxy` is terminated only if the PID in `gvproxy.pid` still belongs to a process
    /// named `gvproxy` started at the recorded time; then the directory is removed. Directories of
    /// a live Nido (this one included) are left alone. Best effort: errors are ignored.
    public static func sweepOrphans(runtimeRoot: URL = GvproxyProcess.defaultRuntimeRoot) {
        guard isPrivateDirectory(runtimeRoot),
            let entries = try? FileManager.default.contentsOfDirectory(atPath: runtimeRoot.path)
        else { return }
        for entry in entries {
            let isVMDirectory = isShortID(entry)
            guard isVMDirectory || Claim.isPendingName(entry) else { continue }
            let directory = runtimeRoot.appendingPathComponent(entry, isDirectory: true)
            guard isPrivateDirectory(directory) else { continue }
            let lockFD = Darwin.open(
                directory.appendingPathComponent(Claim.lockName).path, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            if lockFD >= 0 {
                defer { _ = Darwin.close(lockFD) }
                guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { continue }  // a live owner
                terminateRecordedGvproxy(in: directory)
                try? FileManager.default.removeItem(at: directory)
            } else if isVMDirectory || isOlderThan(directory, seconds: 60) {
                // A VM directory is made by renaming a claimed one, so it always had a lock: without
                // it the directory is stale. A pending claim without a lock may be one being made.
                terminateRecordedGvproxy(in: directory)
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    /// Ends the process recorded in `gvproxy.pid` if it is the `gvproxy` that was started then.
    private static func terminateRecordedGvproxy(in directory: URL) {
        guard let text = try? readSmall(directory.appendingPathComponent("gvproxy.pid")) else { return }
        let lines = text.split(separator: "\n")
        guard lines.count == 2, let pid = Int32(lines[0]), pid > 1, processName(pid) == "gvproxy",
            startTime(pid) == String(lines[1])
        else { return }
        _ = kill(pid, SIGTERM)
        if !waitGone(pid, seconds: termGrace) {
            if processName(pid) == "gvproxy", startTime(pid) == String(lines[1]) { _ = kill(pid, SIGKILL) }
            _ = waitGone(pid, seconds: 2)
        }
    }

    /// Polls until `pid` is no longer a `gvproxy`, at most `seconds`.
    private static func waitGone(_ pid: Int32, seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if kill(pid, 0) != 0 && errno == ESRCH { return true }
            usleep(20_000)
        } while Date() < deadline
        return kill(pid, 0) != 0 && errno == ESRCH
    }

    // MARK: - Helpers

    /// A free TCP port on 127.0.0.1: bound to port 0, read back, closed at once.
    static func freeLoopbackPort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NidoError.controlledNetworkUnavailable(L10n.string("no free port for SSH")) }
        defer { _ = Darwin.close(fd) }
        var address = loopback(port: 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        let port = UInt16(bigEndian: address.sin_port)
        guard bound == 0, named == 0, port != 0 else {
            throw NidoError.controlledNetworkUnavailable(L10n.string("no free port for SSH"))
        }
        return port
    }

    private static func loopback(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        return address
    }

    /// True when 127.0.0.1:`port` accepts a TCP connection within 200 ms; no data is sent.
    private static func acceptsLoopback(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { _ = Darwin.close(fd) }
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }
        var address = loopback(port: port)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        var ready: Int32
        repeat { ready = poll(&pollFD, 1, 200) } while ready < 0 && errno == EINTR
        guard ready > 0 else { return false }
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        return getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 && socketError == 0
    }

    /// `aa:bb:cc:dd:ee:ff`, lowercase with two digits per byte, as gvproxy's DHCP server keys its
    /// leases.
    static func normalizedMAC(_ text: String) throws -> String {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        let bytes = parts.compactMap { part in part.count <= 2 ? UInt8(part, radix: 16) : nil }
        guard parts.count == 6, bytes.count == 6 else {
            throw NidoError.controlledNetworkUnavailable(L10n.string("invalid VM MAC address"))
        }
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    /// The configuration file: gvproxy's default network, the VM's MAC on the static lease of
    /// `guestAddress`, and the SSH forward as the only one. No DNS zones, no other forwards.
    static func configuration(mac: String, sshPort: UInt16) -> String {
        """
        stack:
          subnet: 192.168.127.0/24
          gatewayIP: 192.168.127.1
          deviceIP: \(guestAddress)
          hostIP: 192.168.127.254
          dhcpStaticLeases:
            \(guestAddress): "\(mac)"
          forwards:
            "127.0.0.1:\(sshPort)": "\(guestAddress):22"

        """
    }

    /// 32 random bytes in hex. Nido never uses the token: it only locks gvproxy's HTTP API.
    private static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw NidoError.controlledNetworkUnavailable(L10n.string("gvproxy didn’t start"))
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// `posix_spawn` of `binary` with `arguments`, no shell: stdin from /dev/null, stdout and stderr
    /// on `output`, every other descriptor closed, default signal handling, an empty signal mask, a
    /// minimal environment and a process group of its own (Ctrl-C or Ctrl-Z on the terminal of
    /// `nido start` reach its foreground group, never `gvproxy`: only `stop()` ends it).
    private static func spawn(_ binary: URL, arguments: [String], output: Int32) throws -> Int32 {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, output, 1)
        posix_spawn_file_actions_adddup2(&actions, output, 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults: sigset_t = ~0
        defaults &= ~(sigset_t(1) << (SIGKILL - 1)) & ~(sigset_t(1) << (SIGSTOP - 1))
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask: sigset_t = 0
        posix_spawnattr_setsigmask(&attributes, &mask)

        let argv: [UnsafeMutablePointer<CChar>?] = ([binary.path] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = [strdup("PATH=/usr/bin:/bin"), nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, binary.path, &actions, &attributes, argv, envp)
        guard result == 0 else { throw NidoError.controlledNetworkUnavailable(L10n.string("gvproxy didn’t start")) }
        return pid
    }

    /// `gvproxy.log`: opened through `PrivateFile` (0600, no symlink) in append mode, emptied first
    /// when it is over `maxLogBytes`.
    private static func openLog(_ url: URL) throws -> Int32 {
        let fd: Int32
        do {
            fd = try PrivateFile.open(url, flags: O_WRONLY | O_CREAT | O_APPEND, label: "gvproxy.log")
        } catch {
            throw NidoError.controlledNetworkUnavailable(L10n.string("can’t write the gvproxy log"))
        }
        var info = stat()
        if fstat(fd, &info) == 0, info.st_size > maxLogBytes { _ = ftruncate(fd, 0) }
        return fd
    }

    /// What the log gained from `offset` on (at most 64 KiB), to tell why gvproxy stopped.
    private static func logText(_ url: URL, from offset: off_t) -> String {
        guard let fd = try? PrivateFile.open(url, flags: O_RDONLY, label: "gvproxy.log") else { return "" }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard (try? handle.seek(toOffset: UInt64(max(0, offset)))) != nil,
            let data = try? handle.read(upToCount: 64 * 1024)
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Creates `url` (0600, exclusive, no symlink) holding `data`.
    private static func writePrivate(_ data: Data, to url: URL) throws {
        let fd = try PrivateFile.open(url, flags: O_WRONLY | O_CREAT | O_EXCL, label: url.lastPathComponent)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
    }

    private static func readSmall(_ url: URL) throws -> String {
        let fd = try PrivateFile.open(url, flags: O_RDONLY, label: url.lastPathComponent)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        return String(decoding: try handle.read(upToCount: 256) ?? Data(), as: UTF8.self)
    }

    /// `<pid>\n<start time>\n`.
    private static func pidRecord(_ pid: Int32) -> String {
        "\(pid)\n\(startTime(pid) ?? "?")\n"
    }

    /// The process start time as `<seconds>.<microseconds>`, nil when there is no such process.
    static func startTime(_ pid: Int32) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return "\(info.pbi_start_tvsec).\(info.pbi_start_tvusec)"
    }

    /// True when `pid` is a live process named `gvproxy`.
    static func isGvproxy(_ pid: Int32) -> Bool {
        processName(pid) == "gvproxy"
    }

    static func processName(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 64)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func isShortID(_ entry: String) -> Bool {
        entry.utf8.count == 8 && entry.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// A real directory (not a symlink) of this user.
    private static func isPrivateDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == getuid()
    }

    private static func isOlderThan(_ url: URL, seconds: TimeInterval) -> Bool {
        guard let changed = VMBundle.statChangeTime(url) else { return false }
        return Date().timeIntervalSince(changed) > seconds
    }

    /// Creates `root` if needed; it must be a directory of this user, then made 0700.
    private static func prepareRoot(_ root: URL) throws {
        try? FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard isPrivateDirectory(root), chmod(root.path, 0o700) == 0 else {
            throw NidoError.controlledNetworkUnavailable(L10n.string("unsafe gvproxy folder"))
        }
    }

    /// The content of `ssh-forward.json`. `start` (`startTime`, absent in records of earlier
    /// builds) tells this gvproxy from a later process given the same PID.
    struct SSHForward: Codable, Equatable {
        let port: UInt16
        let pid: Int32
        var start: String? = nil
    }

    /// True while the record's process is the gvproxy that wrote it: alive, named `gvproxy`, and
    /// started when the record says (when it says).
    static func isLive(_ forward: SSHForward, isGvproxy: (Int32) -> Bool = isGvproxy) -> Bool {
        guard isGvproxy(forward.pid) else { return false }
        guard let start = forward.start else { return true }
        return startTime(forward.pid) == start
    }
}

/// A runtime directory owned by this process: made under a pending name, locked, then renamed into
/// place, so `sweepOrphans` in another process never sees it unlocked.
private final class Claim: Sendable {
    static let lockName = "owner.lock"
    let directory: URL
    private let lockFD: Mutex<Int32>

    private init(directory: URL, lockFD: Int32) {
        self.directory = directory
        self.lockFD = Mutex(lockFD)
    }

    /// `.<short>.<8 hex>`: a directory being claimed.
    static func isPendingName(_ entry: String) -> Bool {
        let parts = entry.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0].isEmpty && parts[1].count == 8 && parts[2].count == 8
    }

    static func take(_ directory: URL, root: URL, name: String) throws -> Claim {
        let pending = root.appendingPathComponent(
            ".\(name).\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
        guard mkdir(pending.path, 0o700) == 0 else {
            throw NidoError.controlledNetworkUnavailable(L10n.string("gvproxy folder not created"))
        }
        let fd = Darwin.open(
            pending.appendingPathComponent(lockName).path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if fd >= 0 { _ = Darwin.close(fd) }
            try? FileManager.default.removeItem(at: pending)
            throw NidoError.controlledNetworkUnavailable(L10n.string("gvproxy folder not created"))
        }
        // rename(2) fails on a non-empty target: a live gvproxy of this VM (its directory holds a
        // held lock, `sweepOrphans` kept it) is never replaced.
        guard Darwin.rename(pending.path, directory.path) == 0 else {
            try? FileManager.default.removeItem(at: pending)
            _ = Darwin.close(fd)
            throw NidoError.controlledNetworkUnavailable(L10n.string("gvproxy is already running for this VM"))
        }
        return Claim(directory: directory, lockFD: fd)
    }

    /// Removes the directory, then releases the lock. Safe to call more than once.
    func release() {
        lockFD.withLock { fd in
            guard fd >= 0 else { return }
            try? FileManager.default.removeItem(at: directory)
            _ = Darwin.close(fd)
            fd = -1
        }
    }

    /// Releases the lock and leaves the directory (tests: a Nido that died).
    func abandon() {
        lockFD.withLock { fd in
            guard fd >= 0 else { return }
            _ = Darwin.close(fd)
            fd = -1
        }
    }
}

private extension Duration {
    var seconds: Double {
        let (whole, fraction) = components
        return Double(whole) + Double(fraction) / 1e18
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
