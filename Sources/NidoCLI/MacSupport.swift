// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import NidoCore
import Synchronization

// macOS guests on the command line: `create --ipsw`, `start --console`, `ssh`. The logic,
// testable without ArgumentParser.

/// Where `create --account` takes the account's password from.
public enum AccountPasswordSource: Sendable, Equatable {
    /// Nido generates it (`GuestPassword.generate`).
    case generate
    /// One line from stdin (`--password-stdin`).
    case stdin
    /// Asked twice on the terminal (`--choose-password`).
    case choose
}

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
        cpus: Int?, memory: String?, disk: String?, noPackages: Bool, noGuestTools: Bool,
        account: String? = nil, passwordSource: AccountPasswordSource = .generate, agent: Bool = false,
        hostMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
        readStdinLine: () -> String? = { readLine(strippingNewline: true) },
        askPassword: (String) -> String? = { readPassphrase(prompt: $0) },
        stdinIsTerminal: Bool = isatty(0) != 0,
        host: HostPlatform = .current
    ) throws -> MacCreateOptions {
        try HostChecks.requireMacGuests(host)
        guard image == nil, imageFile == nil, !noPackages, !noGuestTools else { throw CLIError.ipswConflict }
        let vmName = try VMName(name)
        guard let user else { throw CLIError.missingUser }
        try VMConfig.validateSSHUser(user)
        guard let sshKey else { throw CLIError.missingSSHKey }
        let memoryBytes = try memory.map(ByteSize.parse)
        let diskBytes = try ByteSize.parse(disk ?? macDefaultDisk)
        var request: MacAccountRequest?
        if let account {
            guard hostMajor >= 27 else { throw CLIError.accountNeedsHost27 }
            // As the wizard: a blank full name is refused, spaces around it are dropped.
            let fullName = account.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fullName.isEmpty else { throw CLIError.accountNameEmpty }
            let password = try accountPassword(
                source: passwordSource, user: user, readStdinLine: readStdinLine, askPassword: askPassword,
                stdinIsTerminal: stdinIsTerminal)
            request = MacAccountRequest(fullName: fullName, password: password)
        } else if passwordSource != .generate {
            throw CLIError.passwordOptionNeedsAccount
        }
        return MacCreateOptions(
            name: vmName, ipsw: URL(fileURLWithPath: ipsw), sshKeyPath: URL(fileURLWithPath: sshKey),
            user: user, cpuCount: cpus, memoryBytes: memoryBytes, diskBytes: diskBytes,
            account: request, agentAccess: agent)
    }

    /// The account's password: generated, one line of stdin, or asked twice. Empty, a mismatch and a
    /// missing terminal are told; a password `GuestPassword` refuses is `.passwordUnusable`.
    /// `--password-stdin` from a terminal asks once without echo (`readpassphrase`), never reading
    /// a line the terminal would show.
    static func accountPassword(
        source: AccountPasswordSource, user: String, readStdinLine: () -> String?,
        askPassword: (String) -> String?, stdinIsTerminal: Bool = false
    ) throws -> GuestPassword {
        let typed: String
        switch source {
        case .generate:
            return GuestPassword.generate()
        case .stdin where stdinIsTerminal:
            guard let line = askPassword(L10n.string("Password for \(user): ")) else {
                throw CLIError.noTerminalForPassword
            }
            typed = line
        case .stdin:
            typed = readStdinLine() ?? ""
        case .choose:
            guard let first = askPassword(L10n.string("Password for \(user): ")) else {
                throw CLIError.noTerminalForPassword
            }
            guard let again = askPassword(L10n.string("Again: ")) else { throw CLIError.noTerminalForPassword }
            guard first == again else { throw CLIError.passwordsDontMatch }
            typed = first
        }
        if typed.isEmpty { throw CLIError.passwordEmpty }
        guard let password = GuestPassword(typed) else { throw CLIError.passwordUnusable }
        return password
    }

    /// Asks for a password on the terminal without echo (`readpassphrase` reads /dev/tty); nil when
    /// there is no terminal. The buffer is zeroed after use with `memset_s`, which the compiler
    /// may not drop.
    public static func readPassphrase(prompt: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 1100)
        defer { _ = buffer.withUnsafeMutableBytes { memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        guard Darwin.readpassphrase(prompt, &buffer, buffer.count, RPP_REQUIRE_TTY) != nil else { return nil }
        // The returned `String` is a copy Swift cannot zero: unavoidable, it lives until the caller
        // turns it into a `GuestPassword`.
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    /// What `nido start` does after a start that sent guest provisioning.
    public enum ProvisionedStartFollowUp: Equatable, Sendable {
        case none
        /// Agent access is on: set Nido Agent up while the VM runs.
        case setUpAgent
        /// Only say that the account is made and logs in by itself.
        case loggedIn
    }

    public static func provisionedStartFollowUp(sentProvisioning: Bool, agentAccess: Bool?) -> ProvisionedStartFollowUp {
        guard sentProvisioning else { return .none }
        return agentAccess == true ? .setUpAgent : .loggedIn
    }

    /// How long `nido start` waits for its setup task once the VM stopped.
    public static let setupTaskStopLimit: Duration = .seconds(5)

    /// Cancels `task` and waits for it to end, at most `limit`: true when it ended (or there was
    /// none), false when it is still running at the limit (it is then left alone). `nido start`
    /// runs it for its setup task when the VM stops, so nothing prints after the VM is gone.
    public static func cancelAndWait(_ task: Task<Void, Never>?, within limit: Duration) async -> Bool {
        guard let task else { return true }
        task.cancel()
        let outcome = FirstOutcome()
        return await withCheckedContinuation { continuation in
            let timer = Task {
                try? await Task.sleep(for: limit)
                outcome.resume(continuation, with: false)
            }
            Task {
                await task.value
                // Resume first: a cancelled timer wakes at once and would answer false.
                outcome.resume(continuation, with: true)
                timer.cancel()
            }
        }
    }

    /// Resumes a continuation once: the first of the task's end and the time limit wins.
    private final class FirstOutcome: Sendable {
        private let done = Mutex(false)

        func resume(_ continuation: CheckedContinuation<Bool, Never>, with value: Bool) {
            let first = done.withLock { done -> Bool in
                defer { done = true }
                return !done
            }
            if first { continuation.resume(returning: value) }
        }
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
        if options.account != nil {
            guard let major = MacFirstBoot.guestMajor(info.version), major >= 27 else {
                throw CLIError.accountNeedsImage27
            }
        }
        let resources = macResources(
            cpuCount: options.cpuCount, memoryBytes: options.memoryBytes,
            minimumCPUCount: info.minimumCPUCount, minimumMemoryBytes: info.minimumMemoryBytes)
        try ResourceLimits.validate(cpuCount: resources.cpuCount, memoryBytes: resources.memoryBytes)
        let request = MacVMRequest(
            name: options.name, ipsw: options.ipsw, cpuCount: resources.cpuCount,
            memoryBytes: resources.memoryBytes, diskBytes: options.diskBytes, sshUser: options.user,
            publicKey: publicKey, sshPublicKeyPath: options.sshKeyPath.path,
            account: options.account, agentAccess: options.agentAccess)
        let version = info.version
        do {
            _ = try await installer.install(request, owner: .cliOperation) { fraction in
                line.show(installing: version, fraction: fraction)
            }
        } catch is CancellationError {
            throw CLIError.installCancelled
        }
        if options.account != nil {
            let vm = options.name.rawValue
            return L10n.string("VM \(vm) installed. Its account is created at the first start: nido start \(vm).")
                + "\n" + L10n.string("The password of \(options.user) is in your Mac’s Keychain: `nido agent password \(vm)` shows it.")
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

    /// How `nido ssh` probes a macOS guest's SSH (`PortProbe.remoteLogin`, shared with agent setup).
    public static func remoteLoginProbe(controlledNetwork: Bool) -> @Sendable (SSHEndpoint) -> PortProbe.Result {
        PortProbe.remoteLogin(controlledNetwork: controlledNetwork)
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

    /// What to say after ssh failed on its own (status 255) against a macOS guest: the key is
    /// refused most often because the VM waits at its FileVault login window. Nil for a Linux
    /// guest, and for any other ending (a remote command's status is never 255 in practice).
    public static func loginWindowHint(config: VMConfig, exit: SSHExit) -> String? {
        guard config.guest == .macos, exit == .exited(255) else { return nil }
        let name = config.name.rawValue
        return L10n.string("If \(name) is waiting at its login window (FileVault), log in through its window, then try again.")
    }

    /// Runs `/usr/bin/ssh` with `argv` (argv[0] included) as a child sharing this terminal, and
    /// waits for it: no shell, absolute path, explicit argv. Returns how it ended.
    ///
    /// ssh stopped (its `~^Z` escape, or a stop signal): `nido` stops with the same signal, so the
    /// shell takes the terminal back; once `nido` is continued (`fg`), ssh is continued too and
    /// the wait goes on.
    public static func runSSH(_ argv: [String]) throws -> SSHExit {
        var cArguments: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { cArguments.forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, "/usr/bin/ssh", nil, nil, &cArguments, environ)
        guard spawned == 0 else { throw POSIXError(POSIXErrorCode(rawValue: spawned) ?? .ENOEXEC) }
        while true {
            var status: Int32 = 0
            guard waitpid(pid, &status, WUNTRACED) >= 0 else {
                guard errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECHILD) }
                continue
            }
            switch sshWaitStatus(status) {
            case .ended(let exit):
                return exit
            case .stopped(let signal):
                // Returns once this process is continued.
                raise(signal)
                kill(pid, SIGCONT)
            }
        }
    }

    /// A `waitpid` status of the child ssh, decoded by hand (WIFEXITED, WEXITSTATUS, WIFSIGNALED,
    /// WTERMSIG, WIFSTOPPED, WSTOPSIG are macros, not imported into Swift).
    static func sshWaitStatus(_ status: Int32) -> SSHWaitStatus {
        let low = status & 0x7f
        if low == 0x7f { return .stopped((status >> 8) & 0xff) }
        return low == 0 ? .ended(.exited((status >> 8) & 0xff)) : .ended(.signaled(low))
    }
}

/// What `waitpid` (with `WUNTRACED`) said of the child ssh.
enum SSHWaitStatus: Equatable {
    /// It ended.
    case ended(SSHExit)
    /// A signal stopped it (SIGTSTP for `~^Z`).
    case stopped(Int32)
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
