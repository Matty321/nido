// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore
import Observation

/// S08 Agent: agent access of one macOS VM (an agent on this Mac sees its screen and uses its
/// mouse and keyboard) and the state of Nido Agent, the helper inside the guest.
///
/// - The switch writes `agentAccess` in `config.json` (off the main actor); turning it on while
///   the VM runs only takes effect at the next start (the socket device exists only in a VM
///   started with it). It asks for no Touch ID: it widens nothing the owner has not chosen.
/// - `refresh` reads `config.json` again (`nido agent enable` and `disable` change it too) and
///   the helper's `status`, off the main actor (the pane calls it on appear and every 3 s).
/// - `install` runs `MacAgentSetup` and shows its events as a short log; `cancelInstall` ends
///   the wait (the pane calls it when it goes away).
/// - The account password (macOS 27 guests) lives in the Keychain (`GuestPasswordStore`). When the
///   setup needs it (none stored, or the stored one was refused) the pane asks for it
///   (`needsPassword`, `submitPassword`) and hands it to the setup, which keeps it only once it
///   worked; a stored one is shown, agent access on or off, only after the owner confirmed
///   (`revealPassword`) and is forgotten when the pane goes away (`leave`). Never logged.
/// - "Copy to the VM’s clipboard" (`copyPasswordToVM`) puts the stored password, after the same
///   confirmation, on the guest's clipboard through Nido Agent (the VM shares no clipboard with
///   the Mac, whose own clipboard is never touched); Nido Agent clears it after 60 seconds.
@MainActor
@Observable
final class AgentSettingsModel {
    /// What Nido Agent in the guest is doing, from the point of view of the pane.
    enum HelperState: Equatable {
        /// Agent access is off.
        case off
        /// The VM is stopped (or was started before agent access was turned on: `needsRestart`).
        case notRunning
        /// No helper answers: it is not installed, or nobody is logged in to the guest.
        case notAnswering
        /// Nobody is logged in to the guest (the user has to log in through its window).
        case waitingForLogin
        /// The helper runs and waits for Screen Recording and Accessibility.
        case waitingForPermissions
        /// Both permissions are granted: the helper's version.
        case ready(String)
        /// The helper is older than the one this Nido ships: its version (empty when unknown).
        case outdated(String)
    }

    /// Whether the Keychain holds the account's password (never its value).
    enum PasswordState: Equatable {
        case none
        case stored
    }

    let name: String
    private(set) var agentAccess: Bool
    private(set) var helperState: HelperState
    /// The events of the running (or last) installation, as lines.
    private(set) var log: [String] = []
    private(set) var isInstalling = false
    /// The FileVault advice setup reported, if any.
    private(set) var fileVaultAdvice: String?
    /// Why the last installation or switch failed, localized.
    private(set) var errorMessage: String?
    /// The VM runs without the agent socket (it was started before agent access was turned on):
    /// it needs a restart. Set from the `status` answer, cleared when the socket answers.
    private(set) var needsRestart = false
    /// The setup needs the account's password (none stored, or the stored one was refused).
    private(set) var needsPassword = false
    private(set) var passwordState: PasswordState = .none
    /// The password, shown in place after the owner confirmed, until the pane goes away.
    private(set) var shownPassword: String?
    /// Said after the password went to the VM's clipboard, until the clipboard is cleared.
    private(set) var copyNotice: String?
    private(set) var isCopyingPassword = false

    @ObservationIgnored private let vmID: UUID
    @ObservationIgnored private let passwords: any GuestPasswordStore
    @ObservationIgnored private let authenticator: any OwnerAuthenticator
    @ObservationIgnored private var passwordStateLoaded = false
    @ObservationIgnored private let bundle: VMBundle
    @ObservationIgnored private let isRunning: @MainActor () -> Bool
    @ObservationIgnored private let status: @Sendable () async -> AgentAnswer
    @ObservationIgnored private let setup: Setup
    @ObservationIgnored private let isWindowSettingUp: @MainActor () -> Bool
    @ObservationIgnored private let copyToVM: CopyToVM
    /// Takes `copyNotice` away once the guest's clipboard is cleared.
    @ObservationIgnored private var copyNoticeTask: Task<Void, Never>?
    @ObservationIgnored private let bundledVersion: @Sendable () -> String?
    @ObservationIgnored private let onConfigurationChanged: @MainActor () -> Void
    /// The shipped version, looked up once (it checks the bundle's signature): nil inside means not found.
    @ObservationIgnored private var cachedBundledVersion: String??
    @ObservationIgnored private var installTask: Task<Void, Never>?
    /// Bumped by each write of the switch: a `refresh` that read `config.json` before it keeps
    /// nothing of what it read.
    @ObservationIgnored private var accessWrites = 0

    /// - Parameters:
    ///   - status: asks the helper for its `status` (a failure is a failed answer).
    ///   - setup: runs `MacAgentSetup`, reporting its events; true when the agent is ready.
    ///   - bundledVersion: the version of the Nido Agent this Nido ships (nil when not found).
    ///   - passwords: where the account's password is kept (the app passes the Keychain's).
    ///   - authenticator: confirms the owner before the password is shown.
    /// Runs `MacAgentSetup` with the password the user just typed (nil: none), reporting its
    /// events; true when the agent is ready.
    typealias Setup = @Sendable (GuestPassword?, @escaping @Sendable (MacAgentSetupEvent) -> Void) async throws -> Bool
    /// Puts the text on the clipboard of the VM running in this app for the given seconds
    /// (`AgentHost.setClipboard` through the VM's owner); a failure is a failed answer.
    typealias CopyToVM = @Sendable (String, Int) async -> AgentAnswer

    init(
        bundle: VMBundle, config: VMConfig,
        isRunning: @escaping @MainActor () -> Bool,
        status: @escaping @Sendable () async -> AgentAnswer,
        setup: @escaping Setup,
        bundledVersion: @escaping @Sendable () -> String? = AgentSettingsModel.shippedVersion,
        passwords: any GuestPasswordStore = MemoryGuestPasswordStore(),
        authenticator: any OwnerAuthenticator = LocalOwnerAuthenticator(),
        isWindowSettingUp: @escaping @MainActor () -> Bool = { false },
        copyToVM: @escaping CopyToVM = { _, _ in .failure(.notRunning, "") },
        onConfigurationChanged: @escaping @MainActor () -> Void = {}
    ) {
        self.isWindowSettingUp = isWindowSettingUp
        self.copyToVM = copyToVM
        self.bundle = bundle
        vmID = config.id
        self.passwords = passwords
        self.authenticator = authenticator
        name = config.name.rawValue
        agentAccess = config.agentAccess == true
        helperState = config.agentAccess == true ? .notRunning : .off
        self.isRunning = isRunning
        self.status = status
        self.setup = setup
        self.bundledVersion = bundledVersion
        self.onConfigurationChanged = onConfigurationChanged
    }

    // MARK: - Texts

    /// The sentence under the switch.
    var toggleExplanation: String {
        String(localized: "An agent on this Mac can see this VM’s screen and use its mouse and keyboard.")
    }

    /// Said while the running VM has no agent socket yet.
    var restartNote: String? {
        needsRestart ? String(localized: "Takes effect at the next start.") : nil
    }

    /// The line about the helper; nil while agent access is off.
    var helperLine: String? {
        switch helperState {
        case .off: nil
        case .notRunning:
            needsRestart
                ? String(localized: "Restart the VM to set up Nido Agent.")
                : String(localized: "Start the VM to set up Nido Agent.")
        case .notAnswering: String(localized: "Nido Agent doesn’t answer: log in to the VM in its window, or install it.")
        case .waitingForLogin: String(localized: "Log in to the VM in its window to go on.")
        case .waitingForPermissions:
            String(localized: "Allow Nido Agent in Screen Recording and Accessibility in the VM’s System Settings.")
        case .ready(let version): String(localized: "Nido Agent \(version) is ready.")
        case .outdated(let version):
            version.isEmpty
                ? String(localized: "Nido Agent in the VM is out of date.")
                : String(localized: "Nido Agent \(version) in the VM is out of date.")
        }
    }

    /// "Show password" is offered whenever a password is stored, agent access on or off (the
    /// wizard and `nido create` say Settings › Agent shows it).
    var showsStoredPassword: Bool { passwordState == .stored }

    /// "Copy to the VM’s clipboard" needs the VM running and a stored password.
    var canCopyPasswordToVM: Bool { isRunning() && passwordState == .stored && !isCopyingPassword }

    /// The VM's window is setting Nido Agent up after a provisioned start: the pane starts no
    /// second setup meanwhile.
    var windowSetupNote: String? {
        isWindowSettingUp() ? String(localized: "Nido is setting up Nido Agent from the VM’s window.") : nil
    }

    /// The installation needs the VM to run and agent access on, and no other setup running.
    var canInstall: Bool {
        agentAccess && isRunning() && !isInstalling && helperState != .notRunning && !isWindowSettingUp()
    }

    /// "Authorize" runs the setup with the typed password: not while a setup runs.
    var canSubmitPassword: Bool { !isInstalling && !isWindowSettingUp() }

    /// The guest has no helper or an old one: the button is the main action.
    var helperNeedsInstall: Bool {
        switch helperState {
        case .notAnswering, .outdated: true
        default: false
        }
    }

    /// "Install Nido Agent", or "Update" when the guest has an old one.
    var installLabel: String {
        if case .outdated = helperState { return String(localized: "Update Nido Agent") }
        return String(localized: "Install Nido Agent")
    }

    /// What an agent runs to use this VM (Claude Code).
    var mcpCommand: String { "claude mcp add nido-\(name) -- nido mcp \(name)" }

    // MARK: - Actions

    /// Writes `agentAccess` in `config.json` (the VM may run: the owner reads it before every
    /// command), off the main actor.
    func setAgentAccess(_ on: Bool) async {
        errorMessage = nil
        accessWrites += 1
        let bundle = bundle
        do {
            _ = try await Task.detached { try bundle.updateConfig { $0.agentAccess = on } }.value
        } catch {
            errorMessage = String(localized: "Couldn’t save: \(error.localizedDescription)", comment: "%@ is the error.")
            return
        }
        agentAccess = on
        // Whether the running VM serves the socket is for `status` to say (`refresh`).
        needsRestart = false
        if !on {
            cancelInstall()
            needsPassword = false
            helperState = .off
        } else {
            helperState = .notRunning
        }
        onConfigurationChanged()
        if on { await refresh() }
    }

    /// Reads `agentAccess` from `config.json` again (the CLI may have changed it), then the
    /// helper's state. Does nothing during an installation (its events say it).
    func refresh() async {
        guard !isInstalling else { return }
        await loadPasswordStateOnce()
        let writes = accessWrites
        let bundle = bundle
        let config = await Task.detached { try? bundle.readConfig() }.value
        // The switch was written while reading: what it wrote stands.
        if let config, writes == accessWrites, !isInstalling {
            agentAccess = config.agentAccess == true
        }
        guard agentAccess else {
            helperState = .off
            needsRestart = false
            return
        }
        guard isRunning() else {
            helperState = .notRunning
            needsRestart = false
            return
        }
        let answer = await status()
        let bundled: String?
        if let cached = cachedBundledVersion {
            bundled = cached
        } else {
            bundled = await Task.detached { [bundledVersion] in bundledVersion() }.value
            cachedBundledVersion = .some(bundled)
        }
        // The switch may have been turned off, or an installation started, while asking.
        guard agentAccess, !isInstalling, writes == accessWrites else { return }
        if let restart = Self.needsRestart(after: answer, running: isRunning()) { needsRestart = restart }
        if let state = Self.state(for: answer, bundledVersion: bundled) { helperState = state }
    }

    /// Installs Nido Agent in the guest and waits until it is allowed (`MacAgentSetup`).
    func install() async {
        await install(typed: nil)
    }

    /// The setup with `typed` (the password just typed, or nil). Nothing while another setup runs
    /// (this pane's, or the window's first-run setup).
    private func install(typed: GuestPassword?) async {
        guard !isInstalling, !isWindowSettingUp() else { return }
        isInstalling = true
        log = []
        errorMessage = nil
        fileVaultAdvice = nil
        needsPassword = false
        let task = Task { await runSetup(typed: typed) }
        installTask = task
        await task.value
        installTask = nil
        isInstalling = false
        // The setup may have saved the typed password (only once it worked).
        if typed != nil { await reloadPasswordState() }
        await refresh()
    }

    // MARK: - The account password

    /// Reads whether a password is stored, once (a Keychain read may ask the owner to allow it:
    /// not every 3 seconds).
    private func loadPasswordStateOnce() async {
        guard !passwordStateLoaded else { return }
        passwordStateLoaded = true
        await reloadPasswordState()
    }

    /// Whether an item exists, asked without its data (`contains`): no Keychain prompt.
    private func reloadPasswordState() async {
        let (passwords, vmID) = (passwords, vmID)
        let stored = await Task.detached { (try? passwords.contains(vm: vmID)) == true }.value
        passwordStateLoaded = true
        passwordState = stored ? .stored : .none
    }

    /// "Authorize": runs the setup again with the typed password, which `MacAgentSetup` tries
    /// before the stored one and keeps in the Keychain only once it worked. An invalid password
    /// (empty, line breaks) runs nothing and says so.
    func submitPassword(_ text: String) async {
        guard canSubmitPassword else { return }
        guard let password = GuestPassword(text) else {
            errorMessage = String(localized: "The password isn’t valid: it can’t be empty or contain line breaks.")
            return
        }
        shownPassword = nil
        await install(typed: password)
    }

    /// "Show password": the stored password, only after the owner confirmed (Touch ID or the
    /// Mac's password); nil when refused or none is stored (a Keychain error is shown in
    /// `errorMessage`). It is kept in `shownPassword` until `hidePassword` or `leave`.
    func revealPassword() async -> String? {
        let reason = String(localized: "show the password of the account in \(name)", comment: "Completes the Touch ID prompt; %@ is the VM’s name.")
        guard await authenticator.authenticate(reason: reason) else { return nil }
        let (passwords, vmID) = (passwords, vmID)
        let value: String?
        do {
            value = try await Task.detached { try passwords.read(vm: vmID)?.value }.value
        } catch {
            errorMessage = String(localized: "Couldn’t read the password: \(error.localizedDescription)", comment: "%@ is the error.")
            return nil
        }
        errorMessage = nil
        shownPassword = value
        return value
    }

    func hidePassword() { shownPassword = nil }

    /// "Copy to the VM’s clipboard": after the owner confirmed (Touch ID or the Mac's password),
    /// the stored password goes to the clipboard of the VM running in this app, which Nido Agent
    /// clears after `AgentHost.clipboardClearSeconds`; the user presses ⌘V in the guest (its
    /// keyboard layout plays no part). The password is never shown on the way, nor put in a
    /// message. Failures (the VM not running here, Nido Agent not answering or too old, the
    /// Keychain) go to `errorMessage`.
    func copyPasswordToVM() async {
        guard !isCopyingPassword else { return }
        isCopyingPassword = true
        defer { isCopyingPassword = false }
        let reason = String(localized: "copy the password of the account in \(name) to its clipboard",
                            comment: "Completes the Touch ID prompt; %@ is the VM’s name.")
        guard await authenticator.authenticate(reason: reason) else { return }
        let (passwords, vmID) = (passwords, vmID)
        let password: GuestPassword?
        do {
            password = try await Task.detached { try passwords.read(vm: vmID) }.value
        } catch {
            errorMessage = String(localized: "Couldn’t read the password: \(error.localizedDescription)", comment: "%@ is the error.")
            return
        }
        guard let password else {
            passwordState = .none
            return
        }
        let seconds = AgentHost.clipboardClearSeconds
        let answer = await copyToVM(password.value, seconds)
        guard answer.ok else {
            copyNotice = nil
            errorMessage = Self.copyFailure(answer)
            return
        }
        errorMessage = nil
        copyNotice = String(localized: "In the VM, press ⌘V. The VM’s clipboard is cleared in 60 seconds.")
        copyNoticeTask?.cancel()
        copyNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.copyNotice = nil
        }
    }

    /// Why the password did not reach the VM's clipboard, in the pane's words. An older Nido Agent
    /// does not know the request and answers `badRequest`.
    nonisolated static func copyFailure(_ answer: AgentAnswer) -> String {
        switch answer.error {
        case .badRequest, .versionMismatch:
            String(localized: "Update Nido Agent to use this.")
        case .notRunning:
            String(localized: "The VM must run in this app to receive the password.")
        case .notReady:
            String(localized: "Nido Agent doesn’t answer: log in to the VM in its window, or install it.")
        default:
            String(localized: "Couldn’t copy the password to the VM: \(answer.message ?? answer.error?.rawValue ?? "")",
                   comment: "%@ is the error.")
        }
    }

    /// The pane goes away: the shown password, the copy notice and any wait are dropped.
    func leave() {
        shownPassword = nil
        copyNotice = nil
        copyNoticeTask?.cancel()
        cancelInstall()
    }

    /// Ends the wait of a running installation (Cancel, or the pane going away).
    func cancelInstall() {
        installTask?.cancel()
    }

    private func runSetup(typed: GuestPassword?) async {
        let (stream, continuation) = AsyncStream.makeStream(of: MacAgentSetupEvent.self)
        let consumer = Task { @MainActor in
            for await event in stream { handle(event) }
        }
        let setup = setup
        var failure: String?
        var ready = false
        var cancelled = false
        do {
            ready = try await setup(typed) { continuation.yield($0) }
        } catch is CancellationError {
            cancelled = true
        } catch GuestSSHError.cancelled {
            cancelled = true
        } catch {
            failure = Self.message(for: error)
            if Self.asksForPassword(error) { needsPassword = true }
        }
        continuation.finish()
        // The events come first, then how it ended.
        await consumer.value
        if cancelled {
            log.append(String(localized: "Cancelled."))
        } else if let failure {
            errorMessage = failure
        } else if !ready, !Task.isCancelled {
            errorMessage = String(localized: "Nido Agent isn’t ready. See the messages below.")
        }
    }

    /// A failure of the setup in the pane's words (`MacAgentSetupError` names the pane's controls).
    nonisolated static func message(for error: any Error) -> String {
        if let error = error as? MacAgentSetupError { return error.message(on: .app) }
        return (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// The failure the password field answers: none stored, or the stored one refused.
    nonisolated static func asksForPassword(_ error: any Error) -> Bool {
        if case MacAgentSetupError.passwordNeeded = error { return true }
        if case GuestSSHError.passwordRejected = error { return true }
        return false
    }

    private func handle(_ event: MacAgentSetupEvent) {
        // The FileVault advice has its own notice: not again in the log.
        if case .fileVaultAdvice = event {} else { log.append(event.line(vm: name)) }
        switch event {
        case .fileVaultAdvice(let advice): fileVaultAdvice = advice
        case .logIn: helperState = .waitingForLogin
        case .grantPermissions: helperState = .waitingForPermissions
        case .installed, .alreadyCurrent, .keptNewer, .reopening, .error, .keyAuthorized, .ready: break
        }
    }

    // MARK: - Mapping

    /// Whether a running VM needs a restart, from its `status` answer: `notRunning` from a VM
    /// that runs means no agent socket (started before agent access was turned on); any answer of
    /// the socket means it serves. Nil when the answer says nothing (a timeout, an internal
    /// error), or the VM stopped while asking.
    nonisolated static func needsRestart(after answer: AgentAnswer, running: Bool) -> Bool? {
        guard running else { return nil }
        if answer.ok { return false }
        switch answer.error {
        case .notRunning: return true
        case .timeout, .internalError, nil: return nil
        default: return false
        }
    }

    /// The helper's state for a `status` answer; nil when the answer says nothing (a timeout or
    /// an internal error: the state stays as it was).
    nonisolated static func state(for answer: AgentAnswer, bundledVersion: String?) -> HelperState? {
        if answer.ok, let status = answer.status {
            let version = status.helperVersion
            if let bundledVersion, MacAgentInstaller.compareVersions(version, bundledVersion) < 0 {
                return .outdated(version)
            }
            return status.screenRecording && status.accessibility ? .ready(version) : .waitingForPermissions
        }
        switch answer.error {
        case .notRunning: return .notRunning
        case .agentAccessOff: return .off
        case .notReady: return .notAnswering
        case .permissionMissing: return .waitingForPermissions
        case .versionMismatch: return .outdated("")
        default: return nil
        }
    }

    /// The version of the Nido Agent this Nido ships, nil when it is not found or not signed.
    nonisolated static func shippedVersion() -> String? {
        guard let app = try? MacAgentBundle.locate() else { return nil }
        return try? MacAgentBundle.bundledVersion(app)
    }

    // MARK: - The real thing

    /// The question of `refresh` for `bundle`: the helper's `status`, asked on a dispatch queue (it
    /// blocks); a failure is a failed answer.
    nonisolated static func liveStatus(bundle: VMBundle, config: VMConfig) -> @Sendable () async -> AgentAnswer {
        let client = AgentControlClient.forVM(bundle: bundle, config: config)
        return {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try client.send(.status, timeout: .seconds(3)))
                    } catch let failure as AgentFailure {
                        continuation.resume(returning: .failure(failure.code, failure.message))
                    } catch {
                        continuation.resume(returning: .failure(.internalError, error.localizedDescription))
                    }
                }
            }
        }
    }

    /// What `nido agent setup` does, for `bundle`, in the pane's words (`MacAgentSetup.live`):
    /// the same checks first (macOS guest, agent access on, the VM running), then the setup.
    nonisolated static func liveSetup(
        bundle: VMBundle, passwords: any GuestPasswordStore = KeychainGuestPasswordStore()
    ) -> Setup {
        { typed, onEvent in
            let setup = try MacAgentSetup.live(
                bundle: bundle, config: try bundle.readConfig(), surface: .app,
                describe: { ($0 as? AgentFailure)?.message ?? $0.localizedDescription }, passwords: passwords,
                typedPassword: typed)
            return try await setup.run(onEvent: onEvent)
        }
    }
}
