// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A fixed command run in the guest. Only constants and validated identifiers become part of the
/// remote command line: nothing the user typed is ever pasted into it.
public enum GuestCommand: Equatable, Sendable {
    /// Installs the Guest Tools of the bundled payload (the tar archive goes in on stdin).
    case installGuestTools
    /// `systemctl is-active <unit>` for a unit name made of letters, digits and `-_.@`.
    case isServiceActive(String)
    /// A phase 2 step in the guest: `sudo -n /opt/nido-guest-tools/bin/nido-provision <step>`.
    case ollama(OllamaAction)
    /// `nido-provision status`: JSON with Ollama, its models and the provisioning steps.
    case provisionStatus
    /// `nido-provision log`: the tail of `/var/log/nido-provision.log`.
    case readProvisionLog
    /// `cat /opt/nido-guest-tools/VERSION`: the Guest Tools release installed in the guest (the
    /// command fails when there are none).
    case readGuestToolsVersion
    /// One chat request to the guest's local Ollama: the JSON body goes in on stdin, the NDJSON
    /// answer streams on stdout. The argv is fixed: constants only (no proxy for the guest's
    /// loopback, 15 minutes at most per answer).
    case chat
    /// Writes `GuestPanicSettings` (kernel messages on the virtio console, reboot after a panic)
    /// in a VM created before them and runs `update-grub` and `sysctl --system`: a constant
    /// script, idempotent, only when the user asks for it (never automatically).
    case applyPanicSettings
    /// Turns off the guest's background requests (`GuestBackgroundRequests`): apt's SRV lookups,
    /// and on Ubuntu snapd, motd-news, Ubuntu Pro, apt news, pollinate and the release check.
    /// A constant script, idempotent, only when the user asks for it.
    case quietBackground(ubuntu: Bool)
    /// Installs `NidoAgent.app` in `~/Applications` of a macOS guest's user (a tar archive of the
    /// app goes in on stdin): a constant script, see `MacAgentInstaller.installScript`.
    case installMacAgent
    /// Opens the installed `NidoAgent.app` without bringing it to the front (needs a logged-in
    /// session of that user in the guest).
    case openMacAgent
    /// Reads FileVault's state and the automatic login user of a macOS guest (two lines, no sudo).
    case readMacLoginState
    /// Adds Nido's key (one line on stdin) to `~/.ssh/authorized_keys` of a macOS guest's user:
    /// a constant script, idempotent, see `authorizeKeyScript`. The only command run with the
    /// account's password (`GuestSSH.authorizeNidoKey`); every other one needs a key.
    case authorizeNidoKey

    public enum OllamaAction: Equatable, Sendable {
        case install, verify, start, stop, restart, update
        /// `ollama-install --archive-stdin` / `ollama-update --archive-stdin`: the Ollama archive
        /// Nido downloaded and verified on the Mac goes in on stdin (`AIRuntime`); the guest
        /// checks it again and never downloads it.
        case installFromStdin, updateFromStdin
        case uninstall(removeModels: Bool)
        /// The name is validated with `GuestCommand.validateModelName`; `force` re-pulls a model
        /// already present (only after the user confirmed).
        case pull(model: String, force: Bool = false)
        case remove(model: String)

        /// The `nido-provision` step name (also its key in `state.json`).
        public var stepName: String {
            switch self {
            case .install, .installFromStdin: "ollama-install"
            case .verify: "ollama-verify"
            case .start: "ollama-start"
            case .stop: "ollama-stop"
            case .restart: "ollama-restart"
            case .update, .updateFromStdin: "ollama-update"
            case .uninstall: "ollama-uninstall"
            case .pull: "model-pull"
            case .remove: "model-remove"
            }
        }

        func arguments() throws(GuestSSHError) -> [String] {
            switch self {
            case .uninstall(let removeModels):
                return [stepName, removeModels ? "--remove-models" : "--keep-models"]
            case .pull(let model, let force):
                return [stepName, try GuestCommand.validateModelName(model)] + (force ? ["--force"] : [])
            case .remove(let model):
                return [stepName, try GuestCommand.validateModelName(model)]
            case .installFromStdin, .updateFromStdin:
                return [stepName, "--archive-stdin"]
            default:
                return [stepName]
            }
        }
    }

    static let provisionTool = ["sudo", "-n", "/opt/nido-guest-tools/bin/nido-provision"]

    /// `authorizeNidoKey`: reads one key line from stdin, makes `~/.ssh` (0700) and
    /// `~/.ssh/authorized_keys` (0600) with a 077 umask, and appends the key only when no line
    /// is exactly it (`grep -qxF`), after a newline when the file does not end with one. Prints
    /// nothing; any failure (no key, a `grep` error, a write) exits non-zero.
    static let authorizeKeyScript = #"""
        umask 077
        set -eu
        key=
        IFS= read -r key || [ -n "$key" ]
        [ -n "$key" ]
        dir="$HOME/.ssh"
        file="$dir/authorized_keys"
        mkdir -p "$dir"
        chmod 700 "$dir"
        [ -e "$file" ] || : > "$file"
        chmod 600 "$file"
        if [ -s "$file" ] && [ -n "$(tail -c 1 "$file")" ]; then printf '\n' >> "$file"; fi
        if grep -qxF -- "$key" "$file"; then exit 0; else status=$?; fi
        [ "$status" -eq 1 ]
        printf '%s\n' "$key" >> "$file"
        """#

    /// The remote argv, element by element. Every element is a constant or a validated identifier.
    func argv() throws(GuestSSHError) -> [String] {
        switch self {
        case .installGuestTools:
            return ["sudo", "-n", "/bin/sh", "-c", GuestToolsInstaller.bootstrapScript]
        case .isServiceActive(let unit):
            return ["systemctl", "is-active", try Self.validateUnitName(unit)]
        case .ollama(let action):
            return Self.provisionTool + (try action.arguments())
        case .provisionStatus:
            return Self.provisionTool + ["status"]
        case .readProvisionLog:
            return Self.provisionTool + ["log"]
        case .readGuestToolsVersion:
            return ["cat", "/opt/nido-guest-tools/VERSION"]
        case .applyPanicSettings:
            return ["sudo", "-n", "/bin/sh", "-c", GuestPanicSettings.applyScript]
        case .quietBackground(let ubuntu):
            return ["sudo", "-n", "/bin/sh", "-c", GuestBackgroundRequests.applyScript(ubuntu: ubuntu)]
        case .installMacAgent:
            return ["/bin/sh", "-c", MacAgentInstaller.installScript]
        case .openMacAgent:
            return ["/bin/sh", "-c", MacAgentInstaller.openScript]
        case .readMacLoginState:
            return ["/bin/sh", "-c", MacAgentInstaller.loginStateScript]
        case .authorizeNidoKey:
            return ["/bin/sh", "-c", Self.authorizeKeyScript]
        case .chat:
            return [
                "curl", "-sN", "--noproxy", "*", "--max-time", "900", "--data-binary", "@-",
                "http://127.0.0.1:11434/api/chat",
            ]
        }
    }

    /// ssh sends one string to the guest's login shell: each argv element is single-quoted so the
    /// shell sees exactly the elements and nothing is expanded.
    func remoteCommand() throws(GuestSSHError) -> String {
        try argv().map(Self.shellQuote).joined(separator: " ")
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        (0x30...0x39).contains(scalar.value) || (0x41...0x5A).contains(scalar.value)
            || (0x61...0x7A).contains(scalar.value)
    }

    private static func isSafe(_ s: String, extra: String, maxLength: Int) -> Bool {
        guard s.utf8.count <= maxLength, let first = s.unicodeScalars.first, isAlphanumeric(first) else {
            return false
        }
        return s.unicodeScalars.allSatisfy { isAlphanumeric($0) || extra.unicodeScalars.contains($0) }
    }

    /// An Ollama model name such as `llama3.2:1b` or `library/qwen2.5-coder:7b`: starts with a
    /// letter or digit (never `-`), then letters, digits and `._:/-`, at most 128 bytes.
    public static func validateModelName(_ name: String) throws(GuestSSHError) -> String {
        guard isSafe(name, extra: "._:/-", maxLength: 128) else { throw .invalidIdentifier(name) }
        return name
    }

    static func validateUnitName(_ name: String) throws(GuestSSHError) -> String {
        guard isSafe(name, extra: "._@-", maxLength: 128) else { throw .invalidIdentifier(name) }
        return name
    }
}

public struct GuestCommandResult: Equatable, Sendable {
    public let stdout: String
    public init(stdout: String) { self.stdout = stdout }
}

public enum GuestSSHError: Error, Equatable, Sendable {
    /// The private key is missing (the associated value is its path) or cannot sign without a
    /// passphrase prompt.
    case keyUnavailable(String)
    /// The VM has no recorded SSH key: the user chooses one.
    case keyNotConfigured
    case hostKeyChanged
    case unreachable
    case timeout
    /// The remote command exited non-zero; the text is the sanitized tail of ssh's stderr.
    case commandFailed(code: Int32, stderrTail: String)
    case invalidIdentifier(String)
    /// The ssh process could not be started (a bug or a broken system, not the VM).
    case launchFailed(String)
    /// The caller's task was cancelled: the ssh process was stopped.
    case cancelled
    /// The guest refused the account password of `user` in the VM `vm` (`authorizeNidoKey` only).
    case passwordRejected(user: String, vm: String)
    /// ssh's login was refused before the askpass handed it the password (`authorizeNidoKey`
    /// only): the askpass failed, or the guest asked for no password at all.
    case passwordNotDelivered
    /// A password login (`authorizeNidoKey`) was asked for a VM that is not a macOS guest.
    case macGuestOnly
}

extension GuestSSHError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .keyUnavailable(let path):
            return L10n.string("the key \(path) isn’t available or isn’t authorized in the VM: if it has a passphrase, add it to the agent (ssh-add) or open Terminal")
        case .keyNotConfigured:
            return L10n.string("this VM has no SSH key on record: choose the public key it was created with")
        case .hostKeyChanged:
            return L10n.string("the VM’s host key has changed: Nido won’t connect, to be safe")
        case .unreachable:
            return L10n.string("the VM isn’t responding over SSH: check that it’s running and reachable on the network")
        case .timeout:
            return L10n.string("the command in the VM timed out")
        case .commandFailed(let code, let tail):
            return tail.isEmpty
                ? L10n.string("the command in the VM failed (code \(String(code)))")
                : L10n.string("the command in the VM failed (code \(String(code))): \(tail)")
        case .launchFailed(let why):
            return L10n.string("can’t start ssh: \(GuestSSH.sanitize(why, limit: 120))")
        case .invalidIdentifier(let name):
            return L10n.string("invalid name: \(GuestSSH.sanitize(name, limit: 60))")
        case .cancelled:
            return L10n.string("operation canceled")
        case .passwordRejected(let user, let vm):
            return L10n.string("the password for \(user) in \(vm) was refused")
        case .passwordNotDelivered:
            return L10n.string("Nido couldn’t pass the password to ssh")
        case .macGuestOnly:
            return L10n.string("Nido’s key can be authorized with a password only in a macOS VM")
        }
    }
}

/// Background SSH from the host to the guest as `nido`, with the user's key: fixed argv, no shell
/// on the Mac, the command's input on stdin. The private key is never opened by Nido: only
/// `lstat` checks that it exists, ssh does the rest (key file, agent).
public struct GuestSSH: Sendable {
    public static let maxStderrTail = 400

    private let bundle: VMBundle
    private let config: VMConfig
    private let runner: ProcessRunner
    private let resolveSSH: @Sendable (VMBundle) throws -> SSHEndpoint
    private let callerEnvironment: [String: String]
    /// Which process may fetch the password from `authorizeNidoKey`'s askpass socket, given the
    /// peer's pid and the pid of the ssh that call launched (nil until it started): that ssh's
    /// askpass child. Tests replace it (their fetch comes from the test process itself).
    var askpassPeerCheck: @Sendable (pid_t, pid_t?) -> Bool = AskpassServer.isAskpass(_:ofSSH:)

    public init(
        bundle: VMBundle, config: VMConfig, runner: ProcessRunner,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        resolveSSH: @escaping @Sendable (VMBundle) throws -> SSHEndpoint = { bundle in
            try VMControl.resolveSSH(bundle: bundle, leasesURL: DHCPLeases.defaultURL)
        }
    ) {
        self.bundle = bundle
        self.config = config
        self.runner = runner
        self.resolveSSH = resolveSSH
        self.callerEnvironment = environment
    }

    /// `SSH_AUTH_SOCK` for the ssh child of a macOS guest, as `nido ssh` inherits it (the runner's
    /// environment is minimal, so without it a key held only by an agent is out of reach): only
    /// when it is an absolute path to a socket owned by the current user. Linux guests get none.
    static func agentEnvironment(
        guest: GuestOS, environment: [String: String], uid: uid_t = getuid()
    ) -> [String: String] {
        guard guest == .macos, let path = environment["SSH_AUTH_SOCK"], path.hasPrefix("/"),
            !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { return [:] }
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == uid else { return [:] }
        return ["SSH_AUTH_SOCK": path]
    }

    /// The private key: the public key path without `.pub`.
    static func privateKeyPath(publicKeyPath: String) -> String? {
        publicKeyPath.hasSuffix(".pub") && publicKeyPath.count > 4 ? String(publicKeyPath.dropLast(4)) : nil
    }

    /// The argv of the ssh process for `command` (testable without running anything). `identity`
    /// is nil only for a macOS guest reached with the user's default keys or agent, as `nido ssh`
    /// does; `user` is the guest account (`nido` on Linux).
    func argv(
        for command: GuestCommand, endpoint: SSHEndpoint, identity: String?, user: String = "nido"
    ) throws(GuestSSHError) -> [String] {
        let remote = try command.remoteCommand()
        do {
            return try SSHArguments.background(
                identity: identity, endpoint: endpoint, vmID: config.id, knownHosts: bundle.knownHostsURL,
                remoteCommand: remote, user: user)
        } catch {
            throw .unreachable
        }
    }

    /// The ssh argv (without the executable) and the private key path for `command`.
    private func prepare(_ command: GuestCommand) throws(GuestSSHError) -> (arguments: [String], identity: String) {
        let chosen: String?
        let user: String
        if config.guest == .macos {
            // As `nido ssh` does for a macOS guest: the account given at creation, the private key
            // beside the recorded public key, else the public key itself (ssh then signs with the
            // agent's matching key), else ssh's default keys. Never a reason to refuse.
            user = config.sshUser ?? "nido"
            do { try VMConfig.validateSSHUser(user) } catch { throw .invalidIdentifier(user) }
            chosen = SSHArguments.interactiveIdentity(publicKeyPath: config.sshPublicKeyPath)
        } else {
            user = "nido"
            guard let publicPath = config.sshPublicKeyPath else { throw .keyNotConfigured }
            guard let identity = Self.privateKeyPath(publicKeyPath: publicPath) else {
                throw .keyUnavailable(publicPath)
            }
            var info = stat()
            guard lstat(identity, &info) == 0 else { throw .keyUnavailable(identity) }
            chosen = identity
        }
        // What an error message names when ssh refuses the key.
        let shown = chosen ?? config.sshPublicKeyPath ?? L10n.string("default key")

        let endpoint: SSHEndpoint
        do { endpoint = try resolveSSH(bundle) } catch { throw .unreachable }
        do { try VMControl.prepareKnownHosts(bundle: bundle) } catch { throw .unreachable }
        return (Array(try argv(for: command, endpoint: endpoint, identity: chosen, user: user).dropFirst()), shown)
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private static let ssh = URL(fileURLWithPath: "/usr/bin/ssh")

    /// Runs `command`, feeding `stdin` to it, and returns its stdout. Cancelling the calling task
    /// stops ssh (`.cancelled`).
    public func run(
        _ command: GuestCommand, stdin: Data? = nil, timeout: Duration
    ) async throws(GuestSSHError) -> GuestCommandResult {
        let environment = Self.agentEnvironment(guest: config.guest, environment: callerEnvironment)
        return try await execute(command, timeout: timeout) { runner, arguments, seconds, cancellation in
            try runner.run(
                executable: Self.ssh, arguments: arguments, stdin: stdin, timeout: seconds, maxOutput: 1 << 20,
                cancellation: cancellation, environment: environment, onStdout: nil)
        }
    }

    /// Like `run(_:stdin:timeout:)`, with the command's stdin copied from `stdinFile` in chunks
    /// (never held in memory nor mapped): for the Ollama archive.
    public func run(
        _ command: GuestCommand, stdinFile: FileHandle, timeout: Duration
    ) async throws(GuestSSHError) -> GuestCommandResult {
        try await execute(command, timeout: timeout) { runner, arguments, seconds, cancellation in
            try runner.run(
                executable: Self.ssh, arguments: arguments, stdinFile: stdinFile, timeout: seconds,
                maxOutput: 1 << 20, cancellation: cancellation)
        }
    }

    /// Runs ssh for `command` through `invoke` on a thread of its own (the runner blocks until
    /// the child exits). Cancelling the calling task stops ssh (`.cancelled`).
    private func execute(
        _ command: GuestCommand, timeout: Duration,
        invoke: @escaping @Sendable (ProcessRunner, [String], TimeInterval, ProcessCancellation) throws -> ProcessResult
    ) async throws(GuestSSHError) -> GuestCommandResult {
        let (arguments, identity) = try prepare(command)
        let result = try await launch(arguments: arguments, timeout: timeout, invoke: invoke)
        return try Self.interpret(result, identity: identity)
    }

    /// Runs `invoke` on a thread of its own and returns its result: `.cancelled` when the calling
    /// task was cancelled (ssh is then stopped), `.launchFailed` when ssh could not be started.
    private func launch(
        arguments: [String], timeout: Duration,
        invoke: @escaping @Sendable (ProcessRunner, [String], TimeInterval, ProcessCancellation) throws -> ProcessResult
    ) async throws(GuestSSHError) -> ProcessResult {
        let seconds = Self.seconds(timeout)
        let runner = runner
        let cancellation = ProcessCancellation()
        let result: ProcessResult
        do {
            result = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    Thread {
                        continuation.resume(with: Result { try invoke(runner, arguments, seconds, cancellation) })
                    }.start()
                }
            } onCancel: {
                cancellation.cancel()
            }
        } catch {
            throw .launchFailed(String(describing: error))
        }
        if cancellation.isCancelled { throw .cancelled }
        return result
    }

    /// Adds Nido's key (the bundle's `authorized_key.pub`, validated again) to the macOS guest
    /// account's `authorized_keys`, logging in once with the account's `password`: the one SSH
    /// use of a password, for when the key is not authorized yet. The password reaches ssh only
    /// through a one-shot `AskpassServer` answered by `askpass` (`Askpass.executable()`, the
    /// `nido` binary in askpass mode): ssh's environment holds the socket path, never the
    /// password, and ssh's stdin carries the key. No key and no agent are offered.
    ///
    /// Throws `.macGuestOnly` for a Linux VM, `.passwordRejected` when the guest refuses the
    /// password, `.passwordNotDelivered` when ssh was refused before its askpass got it,
    /// `.commandFailed` with ssh's stderr for any other ssh failure (never `.keyUnavailable`: no
    /// key is used), `.hostKeyChanged`, `.unreachable`, `.timeout` and `.cancelled` as `run` does,
    /// `NidoError.invalidPublicKey` when the bundle has no valid key, and the errors of the
    /// `known_hosts` file, the ssh arguments and the askpass socket as they are.
    public func authorizeNidoKey(password: GuestPassword, askpass: URL) async throws {
        guard config.guest == .macos else { throw GuestSSHError.macGuestOnly }
        guard askpass.isFileURL, askpass.path.hasPrefix("/") else { throw GuestSSHError.passwordNotDelivered }
        guard let stored = try bundle.readAuthorizedKey() else { throw NidoError.invalidPublicKey }
        let key = try CloudInitSeed.validatePublicKey(stored)
        let user = config.sshUser ?? "nido"
        do { try VMConfig.validateSSHUser(user) } catch { throw GuestSSHError.invalidIdentifier(user) }
        let remote = try GuestCommand.authorizeNidoKey.remoteCommand()

        let endpoint: SSHEndpoint
        do { endpoint = try resolveSSH(bundle) } catch { throw GuestSSHError.unreachable }
        try VMControl.prepareKnownHosts(bundle: bundle)
        let arguments = Array(try SSHArguments.passwordOnce(
            endpoint: endpoint, vmID: config.id, knownHosts: bundle.knownHostsURL, remoteCommand: remote,
            user: user).dropFirst())

        let server = try AskpassServer(
            password: password, directory: Askpass.defaultDirectory, peerCheck: askpassPeerCheck)
        defer { server.close() }
        // Added to the runner's minimal environment: no `SSH_AUTH_SOCK`, and the password only
        // behind the socket.
        let environment = [
            "SSH_ASKPASS": askpass.path, "SSH_ASKPASS_REQUIRE": "force",
            Askpass.modeVariable: "1", Askpass.socketVariable: server.socketPath,
        ]
        let stdin = Data((key + "\n").utf8)
        let result = try await launch(arguments: arguments, timeout: .seconds(30)) {
            runner, arguments, seconds, cancellation in
            // The socket answers only the askpass child of this very ssh.
            try runner.run(
                executable: Self.ssh, arguments: arguments, stdin: stdin, timeout: seconds, maxOutput: 1 << 16,
                cancellation: cancellation, environment: environment, onLaunch: { server.expect(ssh: $0) },
                onStdout: nil)
        }
        if !result.timedOut, result.status == 255,
            String(decoding: result.stderr, as: UTF8.self).contains("Permission denied")
        {
            // Refused after the askpass handed the password over: a wrong password. Refused
            // without it: ssh never got the password, which says nothing about it.
            guard server.answered else { throw GuestSSHError.passwordNotDelivered }
            throw GuestSSHError.passwordRejected(user: user, vm: config.name.rawValue)
        }
        do {
            _ = try Self.interpret(result, identity: "")
        } catch .keyUnavailable {
            // `interpret` reads some ssh failures as a refused key; no key is used here.
            let stderr = String(decoding: result.stderr, as: UTF8.self)
            throw GuestSSHError.commandFailed(
                code: result.status, stderrTail: Self.sanitize(stderr, limit: Self.maxStderrTail))
        }
    }

    /// Runs `command` and yields its stdout as it arrives (at most `maxOutput` bytes). The stream
    /// ends with the command's outcome as a `GuestSSHError`; ending the iteration early or
    /// cancelling the consuming task stops ssh.
    public func stream(
        _ command: GuestCommand, stdin: Data? = nil, timeout: Duration, maxOutput: Int = 16 << 20
    ) -> AsyncThrowingStream<Data, Error> {
        let seconds = Self.seconds(timeout)
        let runner = runner
        let environment = Self.agentEnvironment(guest: config.guest, environment: callerEnvironment)
        let cancellation = ProcessCancellation()
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { _ in cancellation.cancel() }
            let prepared: (arguments: [String], identity: String)
            do { prepared = try prepare(command) } catch {
                continuation.finish(throwing: error)
                return
            }
            Thread {
                let outcome = Result {
                    try runner.run(
                        executable: Self.ssh, arguments: prepared.arguments, stdin: stdin,
                        timeout: seconds, maxOutput: maxOutput, cancellation: cancellation,
                        environment: environment, onStdout: { continuation.yield($0) })
                }
                switch outcome {
                case .failure(let error):
                    continuation.finish(throwing: GuestSSHError.launchFailed(String(describing: error)))
                case .success(let result):
                    if cancellation.isCancelled {
                        continuation.finish(throwing: GuestSSHError.cancelled)
                        return
                    }
                    do {
                        _ = try Self.interpret(result, identity: prepared.identity)
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }.start()
        }
    }

    static func interpret(_ result: ProcessResult, identity: String) throws(GuestSSHError) -> GuestCommandResult {
        if result.timedOut { throw .timeout }
        let stdout = String(decoding: result.stdout, as: UTF8.self)
        if result.status == 0 { return GuestCommandResult(stdout: stdout) }
        let stderr = String(decoding: result.stderr, as: UTF8.self)
        if result.status == 255 {
            if stderr.contains("REMOTE HOST IDENTIFICATION HAS CHANGED")
                || stderr.contains("Host key verification failed")
                || stderr.contains("Offending key")
            {
                throw .hostKeyChanged
            }
            if stderr.contains("Permission denied") || stderr.contains("no such identity")
                || stderr.contains("Load key") || stderr.contains("Too many authentication failures")
            {
                throw .keyUnavailable(identity)
            }
            throw .unreachable
        }
        throw .commandFailed(code: result.status, stderrTail: sanitize(stderr, limit: maxStderrTail))
    }

    /// The last `limit` characters of `text` with control characters (also line breaks) turned
    /// into single spaces: safe to show in a sentence or a log.
    static func sanitize(_ text: String, limit: Int) -> String {
        var out = ""
        var lastWasSpace = true
        for scalar in text.unicodeScalars {
            let isControl = scalar.value < 0x20 || scalar.value == 0x7F
                || (scalar.value >= 0x80 && scalar.value < 0xA0)
                || scalar.properties.generalCategory == .format
            if isControl || scalar == " " {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            } else {
                out.unicodeScalars.append(scalar)
                lastWasSpace = false
            }
        }
        out = out.trimmingCharacters(in: .whitespaces)
        return out.count > limit ? String(out.suffix(limit)) : out
    }
}

extension GuestSSH {
    /// The OpenSSH keys (`"<type> <body>"`, comments dropped) listed in a cloud-init `user-data`.
    static func authorizedKeys(inUserData text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            var item = line.trimmingCharacters(in: .whitespaces)
            if item.hasPrefix("- ") { item = String(item.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            item = item.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard item.hasPrefix("ssh-") || item.hasPrefix("ecdsa-") else { return nil }
            return try? CloudInitSeed.validatePublicKey(item)
        }
    }

    /// For a VM created before Nido recorded the key: when `config.sshPublicKeyPath` is empty and
    /// the key at `defaultKey` (`~/.ssh/id_ed25519.pub`) is the one authorized in the bundle's
    /// seed, records its path and returns it. Any other case changes nothing and returns nil
    /// (the app then asks the user to choose the key). Only public files are read.
    @discardableResult
    public static func adoptDefaultKey(bundle: VMBundle, defaultKey: URL) throws -> String? {
        let config = try bundle.readConfig()
        guard config.sshPublicKeyPath == nil else { return config.sshPublicKeyPath }
        guard let key = try? VMControl.readPublicKey(at: defaultKey),
            let userData = try? CloudInitSeed.readFile("user-data", fromISO: bundle.seedURL),
            authorizedKeys(inUserData: userData).contains(key)
        else { return nil }
        try bundle.updateConfig { $0.sshPublicKeyPath = defaultKey.path }
        return defaultKey.path
    }
}
