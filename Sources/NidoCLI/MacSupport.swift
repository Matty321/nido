// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import NidoCore

/// macOS guests on the command line: `create --ipsw`, `start --console`, `ssh`. The logic,
/// testable without ArgumentParser.
extension CLISupport {
    // MARK: - create --ipsw

    /// Default resources of a macOS VM (`macResources`) and its default disk.
    public static let macDefaultCPUCount = 4
    public static let macDefaultMemoryBytes: UInt64 = 8 << 30
    public static let macDefaultDisk = "64G"

    /// Validates `create --ipsw` arguments without touching the disk: `--image`, `--image-file`,
    /// `--no-packages` and `--no-guest-tools` are refused (`.ipswConflict`); `--user` and
    /// `--ssh-key` are required, the user name is validated.
    public static func parseMacCreateOptions(
        name: String, ipsw: String, image: String?, imageFile: String?, sshKey: String?, user: String?,
        cpus: Int?, memory: String?, disk: String?, noPackages: Bool, noGuestTools: Bool
    ) throws -> MacCreateOptions {
        guard image == nil, imageFile == nil, !noPackages, !noGuestTools else { throw CLIError.ipswConflict }
        let vmName = try VMName(name)
        guard let user else { throw CLIError.missingUser }
        try VMConfig.validateSSHUser(user)
        guard let sshKey else { throw CLIError.missingSSHKey }
        let memoryBytes = try memory.map(ByteSize.parse)
        let diskBytes = try ByteSize.parse(disk ?? macDefaultDisk)
        return MacCreateOptions(
            name: vmName, ipsw: URL(fileURLWithPath: ipsw), sshKeyPath: URL(fileURLWithPath: sshKey),
            user: user, cpuCount: cpus, memoryBytes: memoryBytes, diskBytes: diskBytes)
    }

    /// CPU and memory of a new macOS VM: what the user asked, as is (the installer refuses values
    /// below the image's minimums); otherwise 4 CPU and 8 GiB, reduced to this host's limits and
    /// raised to the image's minimums.
    public static func macResources(
        cpuCount: Int?, memoryBytes: UInt64?, minimumCPUCount: Int, minimumMemoryBytes: UInt64,
        hostCores: Int = ProcessInfo.processInfo.activeProcessorCount,
        maxMemoryBytes: UInt64 = ResourceLimits.memoryRange.upperBound
    ) -> (cpuCount: Int, memoryBytes: UInt64) {
        let cpus = cpuCount
            ?? max(min(macDefaultCPUCount, ResourceLimits.maxCPUCount(hostCores: hostCores)), minimumCPUCount)
        let memory = memoryBytes ?? max(min(macDefaultMemoryBytes, maxMemoryBytes), minimumMemoryBytes)
        return (cpus, memory)
    }

    /// Installs a macOS VM (`MacInstaller`, lock owner `.cliOperation`) and returns the text for
    /// stdout. The IPSW is inspected first (`loader`) for its version (shown in the progress line)
    /// and its minimums (the default resources). Cancelling the task stops the installation; the
    /// installer removes what it created and this throws `.installCancelled`. `line` is finished on
    /// every exit path.
    public static func createMac(
        _ options: MacCreateOptions, paths: NidoPaths, installer: MacInstaller,
        loader: any MacRestoreImageLoading = LiveRestoreImageLoader(), line: ProgressLine
    ) async throws -> String {
        defer { line.finish() }
        let publicKey = try VMControl.readPublicKey(at: options.sshKeyPath)
        let info = try await MacRestoreImage.inspect(options.ipsw, loader: loader)
        let resources = macResources(
            cpuCount: options.cpuCount, memoryBytes: options.memoryBytes,
            minimumCPUCount: info.minimumCPUCount, minimumMemoryBytes: info.minimumMemoryBytes)
        try ResourceLimits.validate(cpuCount: resources.cpuCount, memoryBytes: resources.memoryBytes)
        let request = MacVMRequest(
            name: options.name, ipsw: options.ipsw, cpuCount: resources.cpuCount,
            memoryBytes: resources.memoryBytes, diskBytes: options.diskBytes, sshUser: options.user,
            publicKey: publicKey, sshPublicKeyPath: options.sshKeyPath.path)
        let version = info.version
        do {
            _ = try await installer.install(request, owner: .cliOperation) { fraction in
                line.show(installing: version, fraction: fraction)
            }
        } catch is CancellationError {
            throw CLIError.installCancelled
        }
        return L10n.string("VM \(options.name.rawValue) installed. Open it in Nido to finish setting up macOS and turn on terminal access.")
    }

    // MARK: - start --console

    /// `nido start --console` needs the serial console only Linux guests have.
    public static func checkConsoleFlag(_ console: Bool, guest: GuestOS) throws {
        if console, guest == .macos { throw CLIError.macConsoleUnavailable }
    }

    // MARK: - ip

    /// What `nido ip` prints. A VM on Apple's NAT: its address. A controlled-network VM: its
    /// address inside `gvproxy` and how the Mac reaches its SSH.
    public static func ipDescription(bundle: VMBundle, leasesURL: URL) throws -> String {
        let endpoint = try VMControl.resolveSSH(bundle: bundle, leasesURL: leasesURL)
        guard try bundle.readConfig().controlledNetwork == true else { return endpoint.host }
        return L10n.string("\(GvproxyProcess.guestAddress) (SSH from the Mac: \(endpoint.host):\(String(endpoint.port)))")
    }

    // MARK: - ssh

    /// The argv of `nido ssh` (see `SSHArguments.make`) as `config.sshUser ?? "nido"`. For a macOS
    /// guest, the SSH port is probed once first (`probe(endpoint)`, by default `remoteLoginProbe`): a
    /// refused connection means Remote Login is off in the guest (`.remoteLoginOff`, with what to
    /// do), which ssh would only report as "Connection refused" (or, through gvproxy,
    /// "kex_exchange_identification"). Linux guests are not probed (ssh says what happens). A
    /// controlled-network VM gets every forward cleared (see `SSHArguments.make`).
    public static func sshArguments(
        config: VMConfig, endpoint: SSHEndpoint, knownHosts: URL, extra: [String],
        probe: ((SSHEndpoint) -> PortProbe.Result)? = nil,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) throws -> [String] {
        let controlled = config.controlledNetwork == true
        let identity = SSHArguments.interactiveIdentity(publicKeyPath: config.sshPublicKeyPath, fileExists: fileExists)
        let argv = try SSHArguments.make(
            endpoint: endpoint, vmID: config.id, knownHosts: knownHosts, user: config.sshUser ?? "nido",
            identity: identity, controlledNetwork: controlled, extra: extra)
        let probe = probe ?? remoteLoginProbe(controlledNetwork: controlled)
        if config.guest == .macos, probe(endpoint) == .refused { throw CLIError.remoteLoginOff }
        return argv
    }

    /// How `nido ssh` probes a macOS guest's SSH. On Apple's NAT a TCP connection to the guest is
    /// enough: the guest itself refuses it when Remote Login is off. On the controlled network the
    /// endpoint is gvproxy's forward on 127.0.0.1, which accepts every connection and closes it when
    /// the guest refuses: there the probe waits up to 2 s for the SSH banner (`awaitingBanner`).
    public static func remoteLoginProbe(controlledNetwork: Bool) -> (SSHEndpoint) -> PortProbe.Result {
        { endpoint in
            PortProbe.tcp(host: endpoint.host, port: endpoint.port, timeout: .seconds(2), awaitingBanner: controlledNetwork)
        }
    }
}

// MARK: - ssh: the first success on a macOS guest

extension CLISupport {
    /// Whether `nido ssh` waits for ssh instead of replacing itself with it: only for a macOS VM
    /// whose guest it never reached, so the first success can be recorded (`recordSSHResult`).
    public static func watchesSSHResult(config: VMConfig) -> Bool {
        config.guest == .macos && config.sshSucceeded != true
    }

    /// Options with which ssh never logs in (version, configuration dump, queries, control of a
    /// master connection): their success says nothing about the guest.
    static let sshOptionsWithoutLogin: Set<String> = ["-V", "-G", "-Q", "-O"]

    /// ssh logged in: it exited normally (not killed by a signal) with a status other than 255,
    /// which ssh uses for its own errors (connection refused, host key, authentication); any
    /// other status is the remote command's. Never for the options in `sshOptionsWithoutLogin`.
    public static func sshReachedGuest(_ exit: SSHExit, extra: [String]) -> Bool {
        guard !extra.contains(where: sshOptionsWithoutLogin.contains) else { return false }
        guard case .exited(let status) = exit else { return false }
        return status != 255
    }

    /// Records in the config that ssh reached the guest (`VMConfig.sshSucceeded`), once. Never
    /// fails the command: a config that cannot be written only means the panel keeps opening.
    public static func recordSSHResult(bundle: VMBundle, exit: SSHExit, extra: [String]) {
        guard sshReachedGuest(exit, extra: extra) else { return }
        _ = try? bundle.updateConfig { $0.sshSucceeded = true }
    }

    /// Runs `/usr/bin/ssh` with `argv` (argv[0] included) as a child sharing this terminal, and
    /// waits for it: no shell, absolute path, explicit argv. Returns how it ended.
    public static func runSSH(_ argv: [String]) throws -> SSHExit {
        var cArguments: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { cArguments.forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, "/usr/bin/ssh", nil, nil, &cArguments, environ)
        guard spawned == 0 else { throw POSIXError(POSIXErrorCode(rawValue: spawned) ?? .ENOEXEC) }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            guard errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECHILD) }
        }
        // WIFEXITED / WEXITSTATUS / WTERMSIG (macros, not imported into Swift).
        let signal = status & 0x7f
        return signal == 0 ? .exited((status >> 8) & 0xff) : .signaled(signal)
    }
}

/// How a child ssh ended.
public enum SSHExit: Equatable, Sendable {
    /// It exited normally with this status.
    case exited(Int32)
    /// A signal ended it.
    case signaled(Int32)

    /// The status `nido ssh` exits with: ssh's own, or 128 + the signal, as a shell reports it.
    public var exitCode: Int32 {
        switch self {
        case .exited(let status): status
        case .signaled(let signal): 128 + signal
        }
    }
}

/// One TCP connection attempt, closed at once: no data is sent.
public enum PortProbe {
    public enum Result: Equatable, Sendable {
        /// The connection was accepted.
        case open
        /// The host answered that nothing listens on the port (`ECONNREFUSED`).
        case refused
        /// No answer within the timeout, no route, or `host` is not an IPv4 address.
        case noAnswer
    }

    /// Connects to `host` (an IPv4 address, as in the DHCP leases) on `port`, waiting at most
    /// `timeout`. With `awaitingBanner` (a forward that accepts on behalf of the guest, such as
    /// gvproxy's), an accepted connection then waits at most `timeout` again for the server's first
    /// bytes (the SSH banner): the connection closed or reset before them is `.refused`, nothing
    /// within the timeout is `.noAnswer`.
    public static func tcp(host: String, port: UInt16, timeout: Duration, awaitingBanner: Bool = false) -> Result {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return .noAnswer }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return .noAnswer }
        defer { _ = Darwin.close(fd) }
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return .noAnswer }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        let (seconds, attoseconds) = timeout.components
        let milliseconds = Int32(clamping: seconds * 1000 + attoseconds / 1_000_000_000_000_000)
        if connected == 0 { return awaitingBanner ? banner(fd, milliseconds: milliseconds) : .open }
        if errno == ECONNREFUSED { return .refused }
        guard errno == EINPROGRESS else { return .noAnswer }

        var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        var ready: Int32
        repeat {
            ready = poll(&pollFD, 1, milliseconds)
        } while ready < 0 && errno == EINTR
        guard ready > 0 else { return .noAnswer }
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else { return .noAnswer }
        switch socketError {
        case 0: return awaitingBanner ? banner(fd, milliseconds: milliseconds) : .open
        case ECONNREFUSED: return .refused
        default: return .noAnswer
        }
    }

    /// Waits on the connected `fd` for the server's first bytes: some arrive, `.open`; the peer
    /// closes or resets first, `.refused`; none within `milliseconds`, `.noAnswer`.
    private static func banner(_ fd: Int32, milliseconds: Int32) -> Result {
        var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        var ready: Int32
        repeat {
            ready = poll(&pollFD, 1, milliseconds)
        } while ready < 0 && errno == EINTR
        guard ready > 0 else { return .noAnswer }
        var byte: UInt8 = 0
        var received: Int
        repeat {
            received = recv(fd, &byte, 1, MSG_PEEK)
        } while received < 0 && errno == EINTR
        if received > 0 { return .open }
        if received == 0 || errno == ECONNRESET { return .refused }
        return .noAnswer
    }
}
