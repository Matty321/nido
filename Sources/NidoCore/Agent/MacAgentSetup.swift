// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoAgentKit

/// A step of `MacAgentSetup`, for the CLI to print and the app to show.
public enum MacAgentSetupEvent: Equatable, Sendable {
    /// FileVault is on in the guest: the advice text (nobody to log in headless).
    case fileVaultAdvice(String)
    /// Nido Agent was copied into the guest (the version installed).
    case installed(version: String)
    /// The guest has a newer Nido Agent than this Nido's: kept.
    case keptNewer(version: String)
    /// The guest already has this Nido's version.
    case alreadyCurrent(version: String)
    /// The user has to allow Nido Agent in Screen Recording and Accessibility, in the guest.
    case grantPermissions
    /// The user has to log in to the guest through its window.
    case logIn
    /// The helper stopped answering and is opened again.
    case reopening
    /// A problem told in words (the line `nido agent setup` prints on stderr): the helper's error,
    /// an SSH error while opening it again, a version mismatch, the timeout.
    case error(String)
    /// Nido's key was authorized in the guest with the account's password.
    case keyAuthorized
    /// Both permissions are granted: the agent works.
    case ready

    /// The line `nido agent setup` prints for the event in VM `vm`.
    public func line(vm: String) -> String {
        switch self {
        case .fileVaultAdvice(let advice): advice
        case .installed(let version): L10n.string("Nido Agent \(version) installed in \(vm).")
        case .keptNewer: L10n.string("The Nido Agent in \(vm) is newer than the one in this Nido: keeping it.")
        case .alreadyCurrent: L10n.string("Nido Agent is already installed in \(vm).")
        case .grantPermissions: MacAgentInstaller.WaitEvent.grantPermissions.line(vm: vm)
        case .logIn: MacAgentInstaller.WaitEvent.logIn.line(vm: vm)
        case .reopening: MacAgentInstaller.WaitEvent.reopening.line(vm: vm)
        case .error(let message): message
        case .keyAuthorized: L10n.string("Nido’s key is now authorized in \(vm).")
        case .ready: MacAgentInstaller.WaitEvent.ready.line(vm: vm)
        }
    }
}

/// Why `MacAgentSetup` stopped. `errorDescription` is what `nido agent setup` prints;
/// `message(on: .app)` is the same for the app's Agent pane, where the way on is a button.
public enum MacAgentSetupError: Error, Equatable, Sendable, LocalizedError {
    /// The VM is not a macOS guest.
    case notForLinux
    /// The VM's owner serves no agent socket (the message says why).
    case notServed(String)
    /// Nobody is logged in (FileVault keeps sshd and the helper down): the VM name.
    case loginWindow(String)
    /// The guest answers but refuses SSH.
    case remoteLoginOff
    /// The helper could not be opened because nobody is logged in to the guest: the VM name.
    case guestLoginNeeded(String)
    /// Agent access was turned off while waiting: the VM name.
    case accessOff(String)
    /// Nido's key is not authorized and there is no password to authorize it with: the VM name.
    case passwordNeeded(String)
    /// The nido tool that answers ssh's password prompt is missing from this Nido.
    case askpassMissing

    public var errorDescription: String? { message(on: .cli) }

    /// The message for `surface`: the CLI names the command to run, the app the control to use.
    public func message(on surface: MacAgentSetup.Surface) -> String {
        switch (self, surface) {
        case (.notForLinux, _): L10n.string("Agent access is for macOS VMs.")
        case (.notServed(let message), _): message
        case (.loginWindow(let vm), .cli):
            L10n.string("\(vm) may be waiting at its login window (FileVault): log in through its window, then run nido agent setup again.")
        case (.loginWindow(let vm), .app):
            L10n.string("\(vm) may be waiting at its login window (FileVault): log in through its window, then click Install Nido Agent again.")
        case (.remoteLoginOff, _):
            L10n.string("turn on Remote Login in the guest: open the VM in Nido, Terminal Access panel")
        case (.guestLoginNeeded(let vm), _): L10n.string("Log in to \(vm) in its window.")
        case (.accessOff(let vm), .cli):
            L10n.string("Agent access is off for \(vm): turn it on with nido agent enable \(vm)")
        case (.accessOff(let vm), .app):
            L10n.string("Agent access is off for \(vm): turn on Agent access above.")
        case (.passwordNeeded(let vm), .cli):
            L10n.string("Nido’s key isn’t authorized in \(vm) yet: run `nido agent setup \(vm)` in a terminal to enter the password of its account once")
        case (.passwordNeeded(let vm), .app):
            L10n.string("Enter the password of the account in \(vm) once so Nido can authorize its key")
        case (.askpassMissing, _):
            L10n.string("This Nido can’t pass a password to ssh (the nido tool is missing from the app)")
        }
    }
}

/// Installs Nido Agent in a running macOS guest over SSH and waits until the user has allowed it:
/// what `nido agent setup` does, shared with the app. It never prints: it reports
/// `MacAgentSetupEvent`s. The caller checks first that the guest is macOS, agent access is on and
/// the VM runs.
///
/// The order: the helper is asked first (a guest at its FileVault login window has no network, no
/// SSH and no helper, which is what the user needs to hear), then the SSH probe and `gate`, the
/// FileVault/login state, the install decision, `open`, and `MacAgentInstaller.awaitReady`
/// (reopening, the 10 minute limit). Cancelling the calling task ends the wait at once and throws
/// `CancellationError`.
public struct MacAgentSetup: Sendable {
    /// Who runs the setup, for the words that say what to do next: `nido agent setup` names
    /// commands, the app's Agent pane its own controls.
    public enum Surface: Sendable {
        case cli
        case app
    }

    /// How the guest's SSH answered the probe.
    public enum SSHReach: Equatable, Sendable {
        /// The connection was accepted.
        case open
        /// Refused: the guest's network is up (a FileVault pre-login screen has none), so Remote
        /// Login is off.
        case refused
        /// No answer within the probe's timeout.
        case noAnswer
        /// The VM has no address yet (`NidoError.notOnNetwork`, kept to be thrown when the helper
        /// does not explain it).
        case noAddress(NidoError)
    }

    /// The probe of setup: `resolve` the SSH endpoint, then `probe` it. No address yet
    /// (`.notOnNetwork`) is `.noAddress`; any other error of `resolve` (gvproxy gone, not
    /// running…) is thrown with its own message.
    public static func sshReach(
        resolve: () throws -> SSHEndpoint, probe: (SSHEndpoint) -> PortProbe.Result
    ) throws -> SSHReach {
        let endpoint: SSHEndpoint
        do {
            endpoint = try resolve()
        } catch let error as NidoError {
            guard case .notOnNetwork = error else { throw error }
            return .noAddress(error)
        }
        switch probe(endpoint) {
        case .open: return .open
        case .refused: return .refused
        case .noAnswer: return .noAnswer
        }
    }

    /// What setup does before it uses SSH.
    public enum Gate: Equatable, Sendable {
        /// Go on over SSH (a guest without an address: its `.notOnNetwork`; one that does not
        /// answer: ssh's own error).
        case proceed
        /// The VM's owner serves no agent socket: stop with the message of the answer.
        case notServed(String)
        /// Nobody is logged in (FileVault keeps sshd and the helper down until a login through the
        /// VM's window).
        case loginWindow
        /// The guest answers but refuses SSH.
        case remoteLoginOff
    }

    /// The decision from the helper's `status` answer, asked first, and the SSH probe. A refused
    /// connection always means Remote Login is off: the guest's network is up, which a FileVault
    /// pre-login screen does not have. The login-window hint is only for a helper not ready
    /// (`notReady`, also the state of a guest without the helper yet) whose guest gives no SSH
    /// answer or has no address yet: with FileVault on, the guest's network and sshd start only
    /// after a login, so the FileVault advice (read over SSH) cannot show.
    public static func gate(helper: AgentAnswer, ssh: SSHReach) -> Gate {
        if helper.error == .notRunning { return .notServed(helper.message ?? "") }
        let notReady = !helper.ok && helper.error == .notReady
        switch ssh {
        case .open: return .proceed
        case .refused: return .remoteLoginOff
        case .noAnswer, .noAddress: return notReady ? .loginWindow : .proceed
        }
    }

    /// `.loginWindow(vm)` when the first SSH command fails with the key refused
    /// (`GuestSSHError.keyUnavailable`) while the helper is not ready: with FileVault on and
    /// nobody logged in, sshd answers but cannot read the user's home, so the key is fine and the
    /// user needs to log in. Nil for any other error, or a helper that answers.
    public static func loginHint(for error: any Error, helper: AgentAnswer, vm: String) -> MacAgentSetupError? {
        guard case GuestSSHError.keyUnavailable = error, !helper.ok, helper.error == .notReady else { return nil }
        return .loginWindow(vm)
    }

    /// How long one `status` question may take (the wait is bounded in time, not in questions).
    public static let statusTimeout: Duration = .seconds(5)

    private let vm: String
    private let ssh: GuestSSH
    private let client: any AgentActions
    private let bundledApp: URL
    private let reach: @Sendable () throws -> SSHReach
    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleep: @Sendable (Duration) async throws -> Void
    private let describe: @Sendable (any Error) -> String
    private let timeout: Duration
    private let surface: Surface
    private let passwords: any GuestPasswordStore
    private let vmID: UUID
    private let askpass: URL?
    private let askPassword: (@Sendable () async -> GuestPassword?)?
    private let typedPassword: GuestPassword?
    private let waitForRemoteLogin: Duration?
    private let recordKeyLogin: @Sendable () -> Void
    private let authorize: @Sendable (GuestPassword, URL) async throws -> Void

    /// - Parameters:
    ///   - reach: resolves the guest's SSH endpoint and probes it (`NidoError.notOnNetwork` is
    ///     `.noAddress`; other errors are thrown with their own message).
    ///   - now, sleep: the clock and the pause between two polls (2 s); injected for tests.
    ///   - describe: an error in words, for the `.error` event of a failed reopen.
    ///   - surface: who runs it, for the words of the timeout's `.error` event.
    ///   - passwords, vmID: the stored password of the guest's account, used to authorize Nido's key
    ///     when ssh refuses it.
    ///   - askpass: the `nido` binary in askpass mode (`Askpass.executable()`); nil when missing.
    ///   - askPassword: asks the user for the password when none is stored, or once when the
    ///     stored one is refused; nil never asks.
    ///   - typedPassword: a password the user just typed (Settings › Agent): tried before the
    ///     stored one, and saved only once it worked.
    ///   - waitForRemoteLogin: how long a guest that is not answering SSH yet (a provisioned first
    ///     boot) is waited for; nil is one probe.
    ///   - authorize: the key authorization (a seam for tests); nil is `GuestSSH.authorizeNidoKey`.
    public init(
        bundle: VMBundle, config: VMConfig, ssh: GuestSSH, client: any AgentActions, bundledApp: URL,
        reach: @escaping @Sendable () throws -> SSHReach,
        timeout: Duration = MacAgentInstaller.waitLimit,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        describe: @escaping @Sendable (any Error) -> String = { $0.localizedDescription },
        surface: Surface = .cli,
        passwords: any GuestPasswordStore = MemoryGuestPasswordStore(),
        vmID: UUID? = nil,
        askpass: URL? = nil,
        askPassword: (@Sendable () async -> GuestPassword?)? = nil,
        typedPassword: GuestPassword? = nil,
        waitForRemoteLogin: Duration? = nil,
        authorize: (@Sendable (GuestPassword, URL) async throws -> Void)? = nil
    ) {
        self.passwords = passwords
        self.vmID = vmID ?? config.id
        self.askpass = askpass
        self.askPassword = askPassword
        self.typedPassword = typedPassword
        self.waitForRemoteLogin = waitForRemoteLogin
        // As `nido ssh` does (`VMConfig.sshSucceeded`): the Terminal Access panel stops opening by
        // itself. Never fails the setup: a config that cannot be written only keeps the panel.
        self.recordKeyLogin = {
            guard (try? bundle.readConfig())?.sshSucceeded != true else { return }
            _ = try? bundle.updateConfig { $0.sshSucceeded = true }
        }
        self.authorize = authorize ?? { password, askpass in
            try await ssh.authorizeNidoKey(password: password, askpass: askpass)
        }
        self.vm = config.name.rawValue
        self.ssh = ssh
        self.client = client
        self.bundledApp = bundledApp
        self.reach = reach
        self.timeout = timeout
        self.now = now
        self.sleep = sleep
        self.describe = describe
        self.surface = surface
    }

    /// The setup of `bundle` as `nido agent setup` and the app's Agent pane run it. First the
    /// checks: a macOS guest (`.notForLinux`), agent access on (`.accessOff`), the VM running
    /// (`NidoError.notRunning`); then `locateApp` (the Nido Agent this Nido ships), the client of
    /// the VM's control socket, ssh with the VM's key, and the probe of `nido ssh`: one TCP
    /// connection with a 2 s limit that, on the controlled network (gvproxy accepts every
    /// connection for the guest), also waits for the SSH banner.
    public static func live(
        bundle: VMBundle, config: VMConfig, surface: Surface,
        locateApp: () throws -> URL = { try MacAgentBundle.locate() },
        describe: @escaping @Sendable (any Error) -> String = { $0.localizedDescription },
        passwords: any GuestPasswordStore = KeychainGuestPasswordStore(),
        askPassword: (@Sendable () async -> GuestPassword?)? = nil,
        typedPassword: GuestPassword? = nil,
        waitForRemoteLogin: Duration? = nil
    ) throws -> MacAgentSetup {
        let name = config.name.rawValue
        guard config.guest == .macos else { throw MacAgentSetupError.notForLinux }
        guard config.agentAccess == true else { throw MacAgentSetupError.accessOff(name) }
        guard BundleLock.holder(bundle) != nil else { throw NidoError.notRunning(name) }
        let app = try locateApp()
        let probe = PortProbe.remoteLogin(controlledNetwork: config.controlledNetwork == true)
        return MacAgentSetup(
            bundle: bundle, config: config,
            ssh: GuestSSH(bundle: bundle, config: config, runner: SystemProcessRunner()),
            client: AgentControlClient.forVM(bundle: bundle, config: config), bundledApp: app,
            // As `nido ssh`: a guest that refuses SSH has Remote Login off. Errors other than
            // "no address yet" are thrown with their own message.
            reach: {
                try sshReach(
                    resolve: { try VMControl.resolveSSH(bundle: bundle, leasesURL: DHCPLeases.defaultURL) },
                    probe: probe)
            },
            describe: describe, surface: surface, passwords: passwords, vmID: config.id,
            askpass: Askpass.executable(), askPassword: askPassword, typedPassword: typedPassword,
            waitForRemoteLogin: waitForRemoteLogin)
    }

    /// The key was refused: authorize it with the account's password. A password the user just
    /// typed comes first; then the stored one, and when the guest refuses it the user is asked once
    /// (`askPassword`); with none stored, the user is asked. A password the user gave is saved
    /// only once it worked; a refused one leaves the stored password as it was. A password refused
    /// by a FileVault-locked guest is the login hint.
    private func authorizeKey(
        refused: any Error, helper: AgentAnswer, onEvent: @Sendable (MacAgentSetupEvent) -> Void
    ) async throws {
        if let typedPassword {
            try await authorize(with: typedPassword, refused: refused, helper: helper)
            try passwords.save(typedPassword, vm: vmID)
            onEvent(.keyAuthorized)
            return
        }
        if let stored = try passwords.read(vm: vmID) {
            do {
                try await authorize(with: stored, refused: refused, helper: helper)
                onEvent(.keyAuthorized)
                return
            } catch let rejected as GuestSSHError {
                guard case .passwordRejected = rejected, let asked = await askPassword?() else { throw rejected }
                try await authorize(with: asked, refused: refused, helper: helper)
                try passwords.save(asked, vm: vmID)
                onEvent(.keyAuthorized)
                return
            }
        }
        guard let asked = await askPassword?() else {
            throw Self.loginHint(for: refused, helper: helper, vm: vm) ?? MacAgentSetupError.passwordNeeded(vm)
        }
        try await authorize(with: asked, refused: refused, helper: helper)
        try passwords.save(asked, vm: vmID)
        onEvent(.keyAuthorized)
    }

    /// One authorization with `password`: a refusal by a FileVault-locked guest is the login
    /// hint, any other refusal `GuestSSHError.passwordRejected`.
    private func authorize(with password: GuestPassword, refused: any Error, helper: AgentAnswer) async throws {
        guard let askpass else { throw MacAgentSetupError.askpassMissing }
        do {
            try await authorize(password, askpass)
        } catch GuestSSHError.passwordRejected(let user, let name) {
            throw Self.loginHint(for: refused, helper: helper, vm: vm)
                ?? GuestSSHError.passwordRejected(user: user, vm: name)
        }
    }

    /// Runs the setup, reporting each step to `onEvent`. Returns true when the agent is ready;
    /// false when the wait ended without it (timeout, a helper that cannot speak this Nido's
    /// protocol; both were reported as `.error`). Throws `MacAgentSetupError`, `NidoError.notRunning`
    /// (the VM stopped), the SSH errors, and `CancellationError` when the task is cancelled.
    public func run(onEvent: @escaping @Sendable (MacAgentSetupEvent) -> Void) async throws -> Bool {
        let name = vm
        let bundled = try MacAgentBundle.bundledVersion(bundledApp)
        let client = self.client
        let describe = self.describe
        let surface = self.surface
        // A failing question is a failed answer, so the wait goes on (and tells the error once).
        let ask: @Sendable () -> AgentAnswer = {
            do {
                return try client.send(.status, timeout: Self.statusTimeout)
            } catch let failure as AgentFailure {
                return .failure(failure.code, failure.message)
            } catch {
                return .failure(.internalError, describe(error))
            }
        }
        var helper = ask()
        var probe = try reach()
        // A provisioned first boot can take minutes before sshd answers: poll until the limit.
        let deadline = waitForRemoteLogin.map { now().advanced(by: $0) }
        var gate = Self.gate(helper: helper, ssh: probe)
        while let deadline, gate == .remoteLoginOff || gate == .loginWindow, now() < deadline {
            try await sleep(.seconds(2))
            try Task.checkCancellation()
            helper = ask()
            probe = try reach()
            gate = Self.gate(helper: helper, ssh: probe)
        }
        switch gate {
        case .notServed(let message): throw MacAgentSetupError.notServed(message)
        case .loginWindow: throw MacAgentSetupError.loginWindow(name)
        case .remoteLoginOff: throw MacAgentSetupError.remoteLoginOff
        case .proceed: if case .noAddress(let error) = probe { throw error }
        }
        try Task.checkCancellation()

        var loginOutput: String
        do {
            loginOutput = try await ssh.run(.readMacLoginState, timeout: .seconds(30)).stdout
        } catch GuestSSHError.keyUnavailable(let detail) {
            let refused = GuestSSHError.keyUnavailable(detail)
            try await authorizeKey(refused: refused, helper: helper, onEvent: onEvent)
            loginOutput = try await ssh.run(.readMacLoginState, timeout: .seconds(30)).stdout
        } catch {
            throw error
        }
        // A command with Nido's key worked.
        recordKeyLogin()
        if let advice = MacAgentInstaller.parseLoginState(loginOutput).advice { onEvent(.fileVaultAdvice(advice)) }

        switch MacAgentInstaller.installDecision(helper: helper, bundledVersion: bundled) {
        case .install:
            let payload = try MacAgentInstaller.payload(app: bundledApp)
            let installed = try await ssh.run(.installMacAgent, stdin: payload, timeout: .seconds(120))
            onEvent(.installed(version: MacAgentInstaller.installedVersion(installed.stdout)))
        case .current:
            onEvent(.alreadyCurrent(version: bundled))
        case .newer:
            onEvent(.keptNewer(version: helper.status?.helperVersion ?? ""))
        }
        try Task.checkCancellation()

        do {
            _ = try await ssh.run(.openMacAgent, timeout: .seconds(30))
        } catch GuestSSHError.commandFailed {
            // `open` needs a session of the user: nobody is logged in to the guest.
            throw MacAgentSetupError.guestLoginNeeded(name)
        }

        // As for the first `open`: a refused `open` means nobody is logged in (false, the wait
        // reports the login hint); any other failure (SSH) is reported once, in its own words, and
        // the wait goes on.
        let ssh = self.ssh
        let saidReopenError = ReopenErrorFlag()
        let sleep = self.sleep
        let outcome = await MacAgentInstaller.awaitReadyEvents(
            timeout: timeout, now: now, status: ask,
            reopen: {
                do {
                    _ = try await ssh.run(.openMacAgent, timeout: .seconds(30))
                    return true
                } catch GuestSSHError.commandFailed {
                    return false
                } catch {
                    if !Task.isCancelled, saidReopenError.first() {
                        onEvent(.error(L10n.string("Error: \(describe(error))")))
                    }
                    return true
                }
            },
            sleep: { try? await sleep(.seconds(2)) },
            emit: { event in
                switch event {
                case .ready: onEvent(.ready)
                case .grantPermissions: onEvent(.grantPermissions)
                case .reopening: onEvent(.reopening)
                case .logIn: onEvent(.logIn)
                case .helperError, .timedOut: onEvent(.error(event.line(vm: name, on: surface)))
                }
            })
        switch outcome {
        case .ready: return true
        case .stopped: throw NidoError.notRunning(name)
        case .accessOff: throw MacAgentSetupError.accessOff(name)
        case .timedOut, .versionMismatch: return false
        case .cancelled: throw CancellationError()
        }
    }
}

/// True once, for the first caller: the error of a failed reopen is reported a single time.
private final class ReopenErrorFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var said = false

    func first() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if said { return false }
        said = true
        return true
    }
}
