// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore
import Observation
import Synchronization
import Virtualization

/// What the VM window needs from a running VM: `VMSession` in the app, a fake in the unit tests.
@MainActor
protocol VMSessionHandle: AnyObject {
    var state: VMRunState { get }
    var onStateChange: ((VMRunState) -> Void)? { get set }
    /// True after a start that sent the guest its account (`VMSession.sentProvisioning`); the
    /// fakes say false.
    var sentProvisioning: Bool { get }
    var console: (any GuestConsole)? { get }
    /// False while the machine might still be running (e.g. a failed forced stop): the lock stays.
    var machineIsGone: Bool { get }
    func start() async throws
    func pause() async throws
    func resume() async throws
    func stop(gracePeriod: Duration) async
    /// Whether `stop` acts now: running, starting, paused…, an error with the machine possibly
    /// alive, and also while a suspended state is being restored (`VMSession.acceptsStop`).
    var acceptsStop: Bool { get }
    /// What the configuration left out (a shared folder missing on the Mac…): the VM runs anyway.
    var warnings: [String] { get }
    /// Starts a session that never ran, resuming its suspended state when it belongs to this
    /// machine (`VMSession.startOrResume`). Runs under the bundle lock.
    func startOrResume() async throws -> SuspendedState.BootOutcome
    /// Saves the machine state into the bundle and stops (`VMSession.suspend`).
    func suspend() async throws
    /// Throws when this configuration's state cannot be saved (`.snapshotUnsupported(<reason>)`).
    func validateSaveRestoreSupport() throws
    /// The machine for a live snapshot (`SnapshotStore.create` with a session); nil when the
    /// session cannot save its state (a session without a VM).
    var stateSaver: (any MachineStateSaving)? { get }
    /// The guest's vsock, for the monitor (`GuestMonitorClient`); nil for a session without one.
    var guestChannel: (any GuestChannel)? { get }
    /// Whether the session got its remote AI bridge; nil for a session kind without one.
    var aiBridgeAttached: Bool? { get }
    /// Replaces the folders the running guest sees, at once (`VMSession.updateSharedFolders`);
    /// returns the localized warnings of the folders left out.
    func updateSharedFolders(_ folders: [SharedFolder]) throws -> [String]
    /// The machine whose screen the window shows (a macOS guest); nil for a headless session.
    var displayMachine: VZVirtualMachine? { get }
    /// Serves the agent control socket for a macOS VM with agent access on (`AgentHost`); nil for
    /// every other session, including the fakes of the UI tests. `onActivity` is true while the
    /// agent's command runs (`AgentHost.startIfEnabled`); it is called from any thread.
    func startAgentHost(
        bundle: VMBundle, config: VMConfig, onWarning: (String) -> Void,
        onActivity: @escaping @Sendable (Bool) -> Void
    ) -> AgentControlServer?
    /// Puts `text` on the guest's clipboard through Nido Agent, over this session's own vsock
    /// (`AgentHost.setClipboard`); `notRunning` for every other session, including the fakes.
    func setGuestClipboard(_ text: String, clearAfter: Int) async -> AgentAnswer
}

extension VMSessionHandle {
    var sentProvisioning: Bool { false }
    var acceptsStop: Bool {
        let errorWithMachine: Bool = if case .error = state { !machineIsGone } else { false }
        return state.acceptsStop || errorWithMachine
    }
    var warnings: [String] { [] }
    var stateSaver: (any MachineStateSaving)? { nil }
    var guestChannel: (any GuestChannel)? { nil }
    var aiBridgeAttached: Bool? { nil }
    var displayMachine: VZVirtualMachine? { nil }
    func startAgentHost(
        bundle: VMBundle, config: VMConfig, onWarning: (String) -> Void,
        onActivity: @escaping @Sendable (Bool) -> Void
    ) -> AgentControlServer? { nil }
    func setGuestClipboard(_ text: String, clearAfter: Int) async -> AgentAnswer { .failure(.notRunning, "") }
    func updateSharedFolders(_ folders: [SharedFolder]) throws -> [String] {
        throw NidoError.notFound(String(localized: "shared folder device", comment: "What wasn’t found: completes NidoCore’s “not found: %@”."))
    }
}

extension VMSession: VMSessionHandle {
    var console: (any GuestConsole)? { serialConsole }
    var stateSaver: (any MachineStateSaving)? { self }
    /// A machine without a socket device answers `MonitorError.unavailable` (pre-M3c VM). None
    /// for a macOS guest: the monitor is Linux-only in M3b.
    var guestChannel: (any GuestChannel)? { guest == .linux ? VsockGuestChannel(session: self) : nil }
    /// Nil for a macOS guest: a session kind without the bridge (Linux-only in M3b).
    var aiBridgeAttached: Bool? { guest == .linux ? aiBridge != nil : nil }
    /// A macOS guest has a Mac display, shown in the window (`MacDisplayView`).
    var displayMachine: VZVirtualMachine? { guest == .macos ? virtualMachine : nil }

    func startAgentHost(
        bundle: VMBundle, config: VMConfig, onWarning: (String) -> Void,
        onActivity: @escaping @Sendable (Bool) -> Void
    ) -> AgentControlServer? {
        AgentHost.startIfEnabled(
            session: self, bundle: bundle, config: config, onWarning: onWarning, onActivity: onActivity)
    }

    func setGuestClipboard(_ text: String, clearAfter: Int) async -> AgentAnswer {
        guard guest == .macos else { return .failure(.notRunning, "") }
        return await AgentHost.setClipboard(text, clearAfter: clearAfter, session: self)
    }

    var machineIsGone: Bool {
        switch virtualMachine.state {
        case .stopped, .error: true
        default: false
        }
    }
}

/// Creates the session of a bundle whose lock the caller already holds.
@MainActor
protocol SessionFactory: AnyObject {
    /// Async: what may block (gvproxy's start for a controlled network, up to 10 s) runs off the
    /// main actor.
    func makeSession(bundle: VMBundle) async throws -> any VMSessionHandle
    /// The guest's Ollama for the VM `name`; nil for the real one over SSH (`AIRuntime`).
    func aiRuntime(for name: VMName) -> (any AIRuntimeControlling)?
}

extension SessionFactory {
    func aiRuntime(for name: VMName) -> (any AIRuntimeControlling)? { nil }
}

/// The real thing: a headless `VMSession` (the Debian cloud kernel has no graphics driver) whose
/// interactive serial console is shown in the window and tee'd into console.log.
///
/// A macOS guest's session has no serial console and no AI bridge (Linux-only in M3b).
///
/// Every Linux session gets the remote AI bridge (`AIBridgeHost` on vsock 7701): the guest's shim
/// reaches the proxy, which answers 403 while the VM's policy has the bridge off. The policy is
/// read from the VM's config at each request, so a change in the app applies to the next one.
@MainActor
final class LiveSessionFactory: SessionFactory {
    /// The app's image cache: a shared folder inside it is refused at start.
    private let imageCache: URL
    /// Router, token store, catalog and per-VM limiters of the bridge; nil = no bridge.
    private let aiBridge: AIBridgeServices?
    /// Starts the relay of a controlled VM (`VMConfig.controlledNetwork`); never on the main
    /// actor (`startRelayOffMain`).
    private let startRelay: @Sendable (VMBundle, String) async throws -> EgressRelay
    /// The account passwords each session reads for the first-boot provisioning
    /// (`AppEnvironment.guestPasswords`): never the Keychain default of `VMSession`.
    let passwords: any GuestPasswordStore

    init(
        imageCache: URL = ImageStore.defaultCacheRoot(), aiBridge: AIBridgeServices? = nil,
        passwords: any GuestPasswordStore,
        startRelay: @escaping @Sendable (VMBundle, String) async throws -> EgressRelay = LiveSessionFactory.startRelayOffMain
    ) {
        self.passwords = passwords
        self.imageCache = imageCache
        self.aiBridge = aiBridge
        self.startRelay = startRelay
    }

    /// `EgressRelay` for `bundle`'s guest MAC on a detached task: gvproxy's start blocks for up to
    /// 10 s and must never hold the main actor (the VM windows, the library). Traps if it ever
    /// runs on the main thread.
    nonisolated static func startRelayOffMain(bundle: VMBundle, guestMAC: String) async throws -> EgressRelay {
        try await Task.detached(priority: .userInitiated) {
            dispatchPrecondition(condition: .notOnQueue(.main))
            return try EgressRelay(bundle: bundle, guestMAC: guestMAC)
        }.value
    }

    func makeSession(bundle: VMBundle) async throws -> any VMSessionHandle {
        let config = try bundle.readConfig()
        // The caller holds the bundle lock: the config cannot change until the session exists.
        let relay = config.controlledNetwork == true ? try await startRelay(bundle, config.macAddress) : nil
        // A macOS guest has no serial console and never gets the AI bridge (Linux-only in M3b).
        guard config.guest == .linux else {
            // The session owns the relay from here, also when it throws.
            let session = try VMSession(
                bundle: bundle, serialConsole: nil, display: nil, imageCache: imageCache, egressRelay: relay)
            session.guestPasswords = passwords
            return session
        }
        let console: SerialConsole
        do {
            console = try SerialConsole(logURL: bundle.consoleLogURL)
        } catch {
            relay?.shutdown()
            throw error
        }
        let session: VMSession
        do {
            // The session owns the relay from here, also when it throws.
            session = try VMSession(
                bundle: bundle, serialConsole: console, display: nil, imageCache: imageCache, egressRelay: relay)
        } catch {
            console.close()
            throw error
        }
        session.guestPasswords = passwords
        // A bundle whose bridge log cannot be opened runs without the bridge: the guest's shim
        // then answers 502 (never a bridge without its log). The window says so
        // (`VMSessionHandle.aiBridgeAttached`, `AIBridgeModel.attachWarning`).
        if let aiBridge, let host = try? aiBridge.makeHost(for: bundle) {
            session.attachAIBridge(host)
        }
        return session
    }
}

extension VMRunState {
    /// No VM behind the state: the lock can be (and is) released.
    var isSettled: Bool {
        switch self {
        case .stopped, .error: true
        default: false
        }
    }
}

/// State and actions of the window of one VM (S07, S11). Owned by `VMSessionStore`, one per VM.
///
/// Lock lifecycle: `start()` takes `BundleLock(owner: .app)` before creating the session, and the
/// lock is released as soon as the state settles in `.stopped` or `.error` (also when creating or
/// starting the session throws), unless the machine may still be running after a failed forced
/// stop: then it stays held until the machine reports stopped.
@MainActor
@Observable
final class VMWindowModel {
    /// How long the guest has to power off before the forced stop.
    nonisolated static let gracePeriod: Duration = .seconds(30)

    let name: VMName
    /// The VM's system, read from its config when the model is made and again at each start
    /// (a config unreadable at first is not taken for Linux for good). A macOS guest shows its
    /// screen, has no Monitor and AI views (R4) and offers "Accesso da terminale".
    private(set) var guest: GuestOS
    /// "Accesso da terminale" (macOS only).
    private(set) var terminalAccess: TerminalAccessModel?
    private(set) var state: VMRunState = .stopped
    /// The live session, for the display; nil when the state is settled.
    private(set) var session: (any VMSessionHandle)?
    /// The agent control socket of the live session (a macOS VM with agent access on); stopped
    /// wherever the session is let go.
    private var agentServer: AgentControlServer?
    /// True while an agent command runs and for `agentBannerHold` after the last one: the window
    /// shows "An agent is using this VM". False at once when the session ends.
    private(set) var agentActive = false
    /// Nido Agent's first-run setup after a start that sent the guest its account (macOS 27
    /// guest with agent access on): what the thin strip over the screen shows; nil otherwise.
    enum FirstRunSetup: Equatable {
        case working(String)
        case done
        case failed(String)
    }
    private(set) var firstRunSetup: FirstRunSetup?
    /// True while the first-run setup works: Settings › Agent starts no second setup, and the
    /// Terminal Access panel does not open by itself (the setup authorizes Nido's key).
    var isSettingUpAgent: Bool {
        if case .working = firstRunSetup { return true }
        return false
    }
    /// A non-fatal notice of the first-run setup (the password worked but could not be kept in the
    /// Keychain): the strip says it instead of "set up".
    private(set) var firstRunNotice: String?
    /// The first-run setup failed for want of the account's password (none stored, or refused):
    /// Settings › Agent shows its password field at once, also after the strip is gone.
    private(set) var firstRunAsksForPassword = false
    @ObservationIgnored private var firstRunTask: Task<Void, Never>?
    @ObservationIgnored private let firstRunSetupRunner:
        @Sendable (VMBundle, VMConfig, @escaping @Sendable (MacAgentSetupEvent) -> Void) async throws -> Bool
    /// Whether the live session's VM has agent access on (a macOS guest): its display then keeps
    /// the guest's resolution instead of following the window, so the agent's screenshots and
    /// coordinates stay valid while the user resizes the window.
    private(set) var freezesGuestDisplay = false
    /// How long the banner stays after the last command.
    nonisolated static let agentBannerHold: Duration = .seconds(3)
    /// The newest activity value applied; an older one that hops late is dropped.
    @ObservationIgnored private var agentSequence = 0
    /// Which session's activity callback counts: bumped at each agent start and when the session
    /// ends, so a late call of an old session cannot flip a new one.
    @ObservationIgnored private var agentGeneration = 0
    /// The pending end of the banner hold; replaced by each new command.
    @ObservationIgnored private var agentHoldTask: Task<Void, Never>?
    /// Waits out the banner hold; injected so tests do not sleep.
    @ObservationIgnored private let agentHoldSleep: @Sendable (Duration) async -> Void
    /// True while the close confirmation ("Arrestare debian-13?") is shown.
    private(set) var isConfirmingClose = false
    /// When the VM last stopped in this app (the stopped screen says so).
    private(set) var lastStop: Date?
    /// The technical message behind `.error`, for "Dettagli".
    private(set) var errorDetail: String?
    /// Heading of the error screen: the start failed, or the running VM stopped with an error.
    private(set) var errorTitle = String(localized: "Start failed")
    /// The serial console of the live session (nil without a session or for a session without
    /// a console). Created with the session, so nothing the guest prints early is lost.
    private(set) var terminal: TerminalModel?
    /// What the live session's configuration left out (e.g. a shared folder missing on the Mac),
    /// a suspended state discarded at start or a failed suspend, shown in the window's bar while
    /// the session lives.
    private(set) var warnings: [String] = []
    /// True while "Sospendi" saves the state and stops the VM.
    private(set) var isSuspending = false
    /// True while the stopped VM's bundle holds a valid suspended state (suspended from this window,
    /// earlier or elsewhere, or restored to a snapshot with its saved state; until the next start):
    /// the stopped screen says "sospesa" and offers Riprendi.
    private(set) var isSuspended = false
    /// True while a snapshot is created, restored or deleted (S09): suspend, stop and start wait
    /// for it (a live snapshot pauses the VM and saves its state, as a suspend does); pause and
    /// resume are refused meanwhile (their buttons, in the window and the library, are disabled).
    private(set) var isSnapshotting = false

    /// When the live session started the VM's first boot (a Linux VM with no console.log yet: it
    /// never booted on this Mac), nil otherwise. Quitting in the first `firstBootQuitWindow` of it
    /// asks first: cloud-init may be replacing the SSH host keys (M3b).
    @ObservationIgnored private(set) var firstBootStartedAt: Date?

    /// How long after the start of a first boot quitting asks first.
    nonisolated static let firstBootQuitWindow: TimeInterval = 60

    /// True while the VM is alive and its first boot started less than `firstBootQuitWindow` ago.
    func isInFirstBoot(now: Date) -> Bool {
        guard !isGone, let started = firstBootStartedAt else { return false }
        return now.timeIntervalSince(started) < Self.firstBootQuitWindow
    }

    /// A Linux VM that never booted on this Mac: neither console.log nor its rotated generation
    /// `console.log.1` in its bundle (the latter covers a crash during the rotation, or a
    /// console.log deleted by hand). Every Linux session writes console.log from its first start;
    /// a new VM, a clone (also of a template) has neither.
    nonisolated static func isFirstBoot(_ bundle: VMBundle) -> Bool {
        guard (try? bundle.readConfig())?.guest == .linux else { return false }
        let rotated = bundle.url.appendingPathComponent(bundle.consoleLogURL.lastPathComponent + ".1")
        return [bundle.consoleLogURL, rotated].allSatisfy { url in
            var info = stat()
            return lstat(url.path, &info) != 0 && errno == ENOENT
        }
    }

    /// The guest monitor of this VM (spec B): polls only while the VM runs and the panel is visible.
    let monitor: MonitorModel
    /// Provisioning phases and Ollama of this VM (spec C, D).
    let aiRuntime: AIRuntimeModel
    /// The remote AI bridge of this VM (spec H).
    let aiBridge: AIBridgeModel
    /// The progress of a VM just created by the wizard (S14): phase 1, then the chosen phase 2.
    let provisioning: ProvisioningModel
    /// "Avvia" with the RAM of the running VMs over 75 % of the Mac's: the window asks first
    /// ("Avvia comunque" / "Annulla"); nil otherwise.
    private(set) var pendingHeadroom: MemoryHeadroom?

    /// Set by the store when the app is quitting: `start()` does nothing.
    @ObservationIgnored var refusesStart = false
    @ObservationIgnored let paths: NidoPaths
    @ObservationIgnored private let factory: any SessionFactory
    @ObservationIgnored private let gracePeriod: Duration
    @ObservationIgnored private var lock: BundleLock?
    /// The stop in progress: a second stop (quit, close, Arresta) waits for it instead of returning.
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    /// Callers waiting for the state to settle in `.stopped` or `.error`.
    @ObservationIgnored private var settleWaiters: [CheckedContinuation<Void, Never>] = []
    /// A stop asked while `start()` waits for the lock (no session yet): the start gives up.
    @ObservationIgnored private var stopBeforeSession = false
    /// True while Pausa or Riprendi waits for the session: an error then means the VM did not
    /// answer the command, not that it stopped by itself.
    @ObservationIgnored private var commandInFlight = false
    /// The suspend in progress: a stop or a second suspend waits for it.
    @ObservationIgnored private var suspendTask: Task<Bool, Never>?
    /// Why the last suspend failed (localized), nil after a successful one.
    @ObservationIgnored private(set) var lastSuspendFailure: String?
    /// The snapshot operation in progress (S09): the other operations on the machine wait for it.
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    /// The RAM check before a start (`MemoryHeadroom.check`), run off the main actor; nil when
    /// the VM's config cannot be read or it is a template (the start then says why).
    @ObservationIgnored private let checkHeadroom: @Sendable (VMBundle) -> MemoryHeadroom?

    init(
        name: VMName, paths: NidoPaths, factory: any SessionFactory, passwords: any GuestPasswordStore,
        gracePeriod: Duration = VMWindowModel.gracePeriod,
        aiBridgeServices: AIBridgeServices? = nil, monitor: MonitorModel = MonitorModel(),
        aiRuntime: AIRuntimeModel? = nil, checkHeadroom: (@Sendable (VMBundle) -> MemoryHeadroom?)? = nil,
        agentHoldSleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        firstRunSetup: (@Sendable (
            VMBundle, VMConfig, @escaping @Sendable (MacAgentSetupEvent) -> Void
        ) async throws -> Bool)? = nil
    ) {
        self.agentHoldSleep = agentHoldSleep
        self.firstRunSetupRunner = firstRunSetup ?? { bundle, config, onEvent in
            try await VMWindowModel.liveFirstRunSetup(
                bundle: bundle, config: config, passwords: passwords, onEvent: onEvent)
        }
        self.name = name
        self.paths = paths
        let guest = (try? VMBundle.open(name, paths: paths).readConfig())?.guest ?? .linux
        self.guest = guest
        terminalAccess = guest == .macos ? TerminalAccessModel(name: name, paths: paths) : nil
        self.factory = factory
        self.gracePeriod = gracePeriod
        self.monitor = monitor
        let aiRuntime = aiRuntime ?? AIRuntimeModel(name: name, paths: paths)
        self.aiRuntime = aiRuntime
        self.aiBridge = AIBridgeModel(name: name, paths: paths, services: aiBridgeServices)
        let provisioning = ProvisioningModel(
            name: name.rawValue, aiRuntime: aiRuntime, monitor: monitor,
            clearPending: {
                // The phase-2 record goes once verified or given up ("Non installare").
                _ = await Task.detached {
                    try? VMBundle.open(name, paths: paths).updateConfig { $0.pendingProvisioning = nil }
                }.value
            })
        self.provisioning = provisioning
        self.checkHeadroom = checkHeadroom ?? { bundle in
            guard let config = try? bundle.readConfig(), !config.isTemplate else { return nil }
            return MemoryHeadroom.check(starting: bundle, memoryBytes: config.memoryBytes, paths: paths)
        }
        monitor.onSample = { [weak aiRuntime, weak provisioning] status in
            aiRuntime?.guestResponds = true
            aiRuntime?.monitorSteps = status.provisioning?.steps ?? [:]
            guard let provisioning else { return }
            Task { await provisioning.guestAnswered() }
        }
        monitor.onStateChange = { [weak provisioning] state in
            if state == .guestToolsMissing { provisioning?.guestNeverAnswered() }
        }
        syncSuspendedState()
    }

    /// Reads from the bundle whether the VM is suspended (also one suspended before this launch
    /// or by `nido stop --suspend`), so the window and S09 say "sospesa" like the library.
    /// Only while no machine is behind the model and no snapshot operation runs.
    func syncSuspendedState() {
        guard isGone, !isSnapshotting, let bundle = try? VMBundle.open(name, paths: paths) else { return }
        let config = try? bundle.readConfig()
        let suspended = config.map { bundle.hasSuspendedState($0) } ?? false
        if suspended != isSuspended { isSuspended = suspended }
        let stale = suspended && !(config.map { SuspendedState.nextStartResumes(bundle: bundle, config: $0) } ?? true)
        if stale != suspendedStateIsStale { suspendedStateIsStale = stale }
    }

    /// True while the saved state of the suspended VM will be discarded by the next start (its
    /// settings changed since the suspend): the stopped screen no longer promises a resume.
    private(set) var suspendedStateIsStale = false

    // MARK: - Start with the RAM check

    /// "Avvia", "Riprendi", "Riprova" (window and library): checks the memory of the running VMs
    /// off the main actor first; over 75 % of the Mac's RAM the window asks
    /// (`pendingHeadroom`), otherwise the VM starts at once. Never blocks a start for good.
    func requestStart() async {
        guard state.isSettled, session == nil, !refusesStart, pendingHeadroom == nil else { return }
        let check = checkHeadroom
        let (name, paths) = (name, paths)
        let headroom = await Task.detached { () -> MemoryHeadroom? in
            guard let bundle = try? VMBundle.open(name, paths: paths) else { return nil }
            return check(bundle)
        }.value
        if let headroom, headroom.exceedsThreshold {
            pendingHeadroom = headroom
            return
        }
        await start()
    }

    /// "Avvia comunque".
    func startAnyway() async {
        guard pendingHeadroom != nil else { return }
        pendingHeadroom = nil
        await start()
    }

    /// "Annulla": nothing starts.
    func cancelHeadroomStart() {
        pendingHeadroom = nil
    }

    /// `MemoryHeadroom.warningText` as a sentence (the CLI prints it after "Attenzione: ").
    var headroomTitle: String? {
        guard let text = pendingHeadroom?.warning else { return nil }
        return Self.headroomSentence(text)
    }

    var headroomDetail: String? {
        pendingHeadroom.map { String(localized: "\($0.detail). Nido starts the VM anyway if you choose to.") }
    }

    nonisolated static func headroomSentence(_ text: String) -> String {
        (text.prefix(1).uppercased() + text.dropFirst()) + (text.hasSuffix(".") ? "" : ".")
    }

    /// Settings › Agent: `text` to the clipboard of the guest running here, for `clearAfter`
    /// seconds; `notRunning` unless the VM runs (not paused, not stopping) in this window.
    func copyToGuestClipboard(_ text: String, clearAfter: Int) async -> AgentAnswer {
        guard let session, state == .running else { return .failure(.notRunning, "") }
        return await session.setGuestClipboard(text, clearAfter: clearAfter)
    }

    /// S08 Condivisione with the VM running here: the session's folders become `folders` at once.
    /// Throws `.notRunning` when no machine of this window runs.
    func applyLiveShares(_ folders: [SharedFolder]) throws -> [String] {
        guard let session, !state.isSettled else { throw NidoError.notRunning(name.rawValue) }
        return try session.updateSharedFolders(folders)
    }

    /// Starts the VM when nothing runs it; ignored while it is alive (starting, running, paused…).
    /// A lock held by another process (`nido start`, another Nido) ends in `.error`, without a session.
    func start() async {
        // A snapshot holds the bundle lock (stopped) or the machine (live): start after it.
        await waitForSnapshot()
        guard state.isSettled, session == nil, !refusesStart else { return }
        errorDetail = nil
        warnings = []
        freezesGuestDisplay = false
        isSuspended = false
        stopBeforeSession = false
        state = .starting
        firstBootStartedAt = nil
        let created: any VMSessionHandle
        let firstBoot: Bool
        var agentTarget: (bundle: VMBundle, config: VMConfig)?
        do {
            let bundle = try VMBundle.open(name, paths: paths)
            // Retries a brief contention without blocking the main actor.
            lock = try await BundleLock.acquireAsync(bundle, owner: .app)
            if stopBeforeSession || refusesStart {
                // Arresta, closing the window or quitting while the lock was being taken.
                lock?.release()
                lock = nil
                apply(.stopped)
                return
            }
            // An interrupted snapshot restore is finished or undone first; refused (with the
            // files to inspect) when it left anything behind.
            try SnapshotStore(bundle: bundle).recoverBeforeUse()
            // The config the session is built from decides the guest (the factory reads it too).
            if let config = try? bundle.readConfig() {
                resolveGuest(config.guest)
                agentTarget = (bundle, config)
            }
            // Read before the session creates console.log.
            firstBoot = Self.isFirstBoot(bundle)
            created = try await factory.makeSession(bundle: bundle)
        } catch {
            fail(error)
            return
        }
        created.onStateChange = { [weak self, weak created] new in
            guard let self, let created, self.session === created else { return }
            self.apply(new)
        }
        session = created
        if firstBoot { firstBootStartedAt = Date() }
        warnings = created.warnings
        if let agentTarget {
            freezesGuestDisplay = guest == .macos && agentTarget.config.agentAccess == true
            agentGeneration += 1
            agentSequence = 0
            let generation = agentGeneration
            // Commands counted and numbered where the callback runs, in program order; only the
            // resulting busy value hops to the main actor, and a stale hop is dropped.
            let counter = Mutex((running: 0, sequence: 0))
            agentServer = created.startAgentHost(
                bundle: agentTarget.bundle, config: agentTarget.config,
                onWarning: { [weak self] in self?.warnings.append($0) },
                onActivity: { [weak self] running in
                    // From the connection's thread; a late call of an old session is dropped.
                    let (busy, sequence) = counter.withLock { state in
                        state.running = max(0, state.running + (running ? 1 : -1))
                        state.sequence += 1
                        return (state.running > 0, state.sequence)
                    }
                    Task { @MainActor in
                        guard let self, self.agentGeneration == generation else { return }
                        self.agentActivityChanged(busy: busy, sequence: sequence)
                    }
                })
        }
        startPanels(for: created)
        // A macOS guest shows its screen: no serial terminal, even if the session had one.
        terminal = guest == .macos ? nil : created.console.map { console in
            TerminalModel(console: console, isRunning: { [weak self] in self?.state == .running })
        }
        do {
            if case .discarded(let warning) = try await created.startOrResume(), session === created {
                warnings.append(warning)
            }
        } catch {
            // `VMSession` already moved to `.error` (or a stop took over); make sure we settle.
            if session === created, !created.state.isSettled, created.state != .stopping {
                fail(error)
                return
            }
            // The resume failed before the machine ever ran (its config could not be read or
            // written): an error, not a stop. A stop asked meanwhile owns the outcome.
            if session === created, created.state == .stopped, stopTask == nil {
                fail(error)
                return
            }
        }
        if session === created, created.sentProvisioning, let config = agentTarget?.config,
           config.agentAccess == true, let bundle = agentTarget?.bundle
        {
            beginFirstRunSetup(bundle: bundle, config: config)
        }
        if session === created { apply(created.state) }
    }

    // MARK: - First-run setup

    /// How long Remote Login may take on a provisioned first boot (as `nido start`).
    nonisolated static let firstRunWait: Duration = .seconds(600)
    /// How long "done" stays in the strip.
    static let firstRunDoneHold: Duration = .seconds(5)
    /// How long a failure (or a notice) stays in the strip: it points to Settings › Agent.
    static let firstRunFailedHold: Duration = .seconds(30)

    /// Settings › Agent opened: the failure strip points there, so it goes.
    func agentSettingsOpened() {
        if case .failed = firstRunSetup { firstRunSetup = nil }
    }

    /// The helper is ready (any path), or Settings › Agent ran its own setup.
    func firstRunPasswordHandled() { firstRunAsksForPassword = false }

    /// What `nido start` does after a provisioned start: sets Nido Agent up while the VM runs.
    /// It never blocks the window; the strip tells how it goes.
    private func beginFirstRunSetup(bundle: VMBundle, config: VMConfig) {
        firstRunTask?.cancel()
        let vm = config.name.rawValue
        firstRunSetup = .working(String(localized: "Setting up Nido Agent in \(vm)…"))
        firstRunNotice = nil
        firstRunAsksForPassword = false
        // The VM reported running before the setup began: a panel that opened by itself goes.
        terminalAccess?.withdrawAutoShow()
        let runner = firstRunSetupRunner
        let (stream, continuation) = AsyncStream.makeStream(of: MacAgentSetupEvent.self)
        let consumer = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self, case .working = self.firstRunSetup else { continue }
                if case .passwordNotSaved = event { self.firstRunNotice = event.line(vm: vm) }
                self.firstRunSetup = .working(event.line(vm: vm))
            }
        }
        firstRunTask = Task { [weak self, agentHoldSleep] in
            let outcome: FirstRunSetup
            var failure: (any Error)?
            do {
                let ready = try await runner(bundle, config) { continuation.yield($0) }
                outcome = ready ? .done : .failed(String(localized: "Nido Agent isn’t ready yet: see Settings › Agent."))
            } catch is CancellationError {
                continuation.finish()
                await consumer.value
                return
            } catch {
                failure = error
                outcome = .failed(Self.firstRunFailure(for: error, vm: vm))
            }
            continuation.finish()
            await consumer.value
            guard !Task.isCancelled, let self else { return }
            self.firstRunSetup = outcome
            if case .failed = outcome, Self.asksForPassword(error: failure) { self.firstRunAsksForPassword = true }
            // Opens only if Nido's key never reached the guest (the setup records when it did):
            // after a failure, the panel is the other way to authorize it.
            if self.state == .running { self.terminalAccess?.autoShow() }
            // A clean "done" goes after 5 s; a failure or a notice stays 30 s (or until Settings ›
            // Agent opens), as it points there.
            let hold = outcome == .done && self.firstRunNotice == nil ? Self.firstRunDoneHold : Self.firstRunFailedHold
            await agentHoldSleep(hold)
            guard !Task.isCancelled, self.firstRunSetup == outcome else { return }
            self.firstRunSetup = nil
            self.firstRunNotice = nil
        }
    }

    /// Whether the failure is the one Settings › Agent's password field answers.
    nonisolated static func asksForPassword(error: (any Error)?) -> Bool {
        guard let error else { return false }
        return AgentSettingsModel.asksForPassword(error)
    }

    /// The strip's words for a failed first-run setup: a password that is missing, refused or
    /// unusable points to Settings › Agent, where it can be typed; anything else as the pane says it.
    nonisolated static func firstRunFailure(for error: any Error, vm: String) -> String {
        if case MacAgentSetupError.passwordNeeded = error {
            return String(localized: "Nido needs the password of the account in \(vm) to authorize its key: enter it in Settings › Agent.")
        }
        if case GuestSSHError.passwordRejected = error {
            return String(localized: "\(vm) refused the stored password of its account: enter the current one in Settings › Agent.")
        }
        if case GuestPasswordStoreError.unusableItem = error {
            return String(localized: "The password stored for this VM can’t be used: enter it in Settings › Agent.")
        }
        return AgentSettingsModel.message(for: error)
    }

    /// The session ended: the setup stops and its strip goes.
    private func endFirstRunSetup() {
        firstRunTask?.cancel()
        firstRunTask = nil
        firstRunSetup = nil
        firstRunNotice = nil
        firstRunAsksForPassword = false
    }

    /// `MacAgentSetup.live` for `bundle`, waiting for Remote Login (a first boot takes minutes).
    nonisolated static func liveFirstRunSetup(
        bundle: VMBundle, config: VMConfig, passwords: any GuestPasswordStore,
        onEvent: @escaping @Sendable (MacAgentSetupEvent) -> Void
    ) async throws -> Bool {
        let setup = try MacAgentSetup.live(
            bundle: bundle, config: config, surface: .app,
            describe: { ($0 as? AgentFailure)?.message ?? $0.localizedDescription },
            passwords: passwords, waitForRemoteLogin: firstRunWait)
        return try await setup.run(onEvent: onEvent)
    }

    // MARK: - macOS guest (M3b)

    /// Sets the guest from the VM's config; the panel exists only for macOS.
    private func resolveGuest(_ resolved: GuestOS) {
        if guest != resolved { guest = resolved }
        if resolved == .macos, terminalAccess == nil {
            terminalAccess = TerminalAccessModel(name: name, paths: paths)
        } else if resolved == .linux, terminalAccess != nil {
            terminalAccess = nil
        }
    }

    /// The guest's screen instead of the serial console (macOS).
    var showsDisplay: Bool { guest == .macos }
    /// Schermo · Monitor · AI: Linux only (R4).
    var showsViewTabs: Bool { guest == .linux }
    /// The machine for `MacDisplayView` while a session lives.
    var displayMachine: VZVirtualMachine? { session?.displayMachine }

    /// The window (re)appeared: "Accesso da terminale" opens again by itself while the VM runs,
    /// until `nido ssh` reached the guest once.
    func windowAppeared() {
        terminalAccess?.windowAppeared(vmRuns: state == .running && !isSettingUpAgent)
    }

    /// Keys and pastes from the window, for the guest: only while it runs.
    func sendInput(_ data: Data) {
        guard state == .running, let terminal else { return }
        terminal.send(data)
    }

    func pause() async {
        guard let session, session.state == .running, !isSuspending, !isSnapshotting else { return }
        commandInFlight = true
        defer { commandInFlight = false }
        do { try await session.pause() } catch { errorDetail = error.localizedDescription }
        if self.session === session { apply(session.state) }
    }

    func resume() async {
        guard let session, session.state == .paused, !isSuspending, !isSnapshotting else { return }
        commandInFlight = true
        defer { commandInFlight = false }
        do { try await session.resume() } catch { errorDetail = error.localizedDescription }
        if self.session === session { apply(session.state) }
    }

    /// Asks the guest to power off; forced after `gracePeriod` (at once when paused). Returns once
    /// the VM is gone: a stop already in progress is awaited, never cut short, so quitting or
    /// closing the window during "Arresto in corso" still waits for the guest. Also stops a
    /// machine left running behind an `.error` (failed pause, resume or forced stop).
    func stop() async {
        // A snapshot or a suspend in progress ends first (a live snapshot resumes the VM when it
        // is done; a suspend stops it itself or leaves it running), also one that starts meanwhile.
        while true {
            if let task = snapshotTask {
                await task.value
                if snapshotTask == task { await Task.yield() }
            } else if let task = suspendTask {
                _ = await task.value
                if suspendTask == task { await Task.yield() }
            } else {
                break
            }
        }
        if let stopTask {
            await stopTask.value
            return
        }
        guard let session else {
            if state == .starting {
                // `start()` is still taking the lock: it gives up once it has it.
                stopBeforeSession = true
                await waitUntilSettled()
            }
            return
        }
        // Also while a suspended state is being restored: the session carries the stop out when
        // the restore ends, instead of resuming (R-M3A-22).
        if session.acceptsStop {
            let task = Task {
                await session.stop(gracePeriod: gracePeriod)
                if self.session === session { self.apply(session.state) }
                self.stopTask = nil
            }
            stopTask = task
            await task.value
        } else if !state.isSettled {
            // Stopping without a task of ours (not expected): wait for the session to settle.
            await waitUntilSettled()
        }
    }

    // MARK: - Suspend

    /// "Sospendi": saves the VM's state into its bundle and stops it; the next start resumes it.
    /// True when the VM is suspended. A failure leaves the VM running and says why in the bar.
    @discardableResult
    func suspend() async -> Bool {
        // A live snapshot pauses and saves the machine too: the suspend waits for it.
        await waitForSnapshot()
        if let suspendTask { return await suspendTask.value }
        guard let session, session.state == .running || session.state == .paused, stopTask == nil else {
            return false
        }
        // The task clears `suspendTask` itself, before anyone awaiting it resumes (see `exclusive`).
        let task = Task {
            let suspended = await performSuspend(session)
            self.suspendTask = nil
            return suspended
        }
        suspendTask = task
        return await task.value
    }

    private func performSuspend(_ session: any VMSessionHandle) async -> Bool {
        lastSuspendFailure = nil
        isSuspending = true
        clearAgentActivity()
        commandInFlight = true
        defer {
            isSuspending = false
            commandInFlight = false
        }
        do {
            try await session.suspend()
        } catch {
            let text = error.localizedDescription
            lastSuspendFailure = text
            // NidoCore's own suspend error already says it failed: capitalised, not repeated.
            let message: String
            if case NidoError.suspendFailed = error {
                message = text.prefix(1).uppercased() + text.dropFirst()
            } else {
                message = String(localized: "Suspend failed: \(text)")
            }
            if self.session === session { apply(session.state) }
            if self.session === session {
                if !warnings.contains(message) { warnings.append(message) }
            } else {
                errorDetail = message
            }
            return false
        }
        isSuspended = true
        if self.session === session { apply(session.state) }
        return true
    }

    // MARK: - Snapshots (S09)

    /// Waits for the snapshot operation in progress, if any (and for one started meanwhile).
    /// The task clears `snapshotTask` itself; the yield is a guard so that a finished task still
    /// set can never make this loop spin on the main actor.
    private func waitForSnapshot() async {
        while let task = snapshotTask {
            await task.value
            if snapshotTask == task { await Task.yield() }
        }
    }

    /// Runs one snapshot operation at a time, never while a suspend or a stop runs: they are
    /// awaited first, and while `body` runs pause, resume, suspend, stop and start wait (and
    /// quitting waits, `VMSessionStore.waitForSnapshots`). Refused once the app is quitting.
    func exclusive<T: Sendable>(_ body: @escaping @MainActor () async throws -> T) async throws -> T {
        guard !refusesStart else { throw QuittingError() }
        while true {
            if let task = snapshotTask {
                await task.value
                if snapshotTask == task { await Task.yield() }
            } else if let task = suspendTask {
                _ = await task.value
                if suspendTask == task { await Task.yield() }
            } else if let task = stopTask {
                await task.value
                if stopTask == task { await Task.yield() }
            } else {
                break
            }
        }
        guard !refusesStart else { throw QuittingError() }
        let work = Task { () -> Result<T, any Error> in
            do { return .success(try await body()) } catch { return .failure(error) }
        }
        // The task clears `snapshotTask` itself, on the main actor, before it finishes: whoever
        // awaits it resumes with the field already cleared. When the caller of `exclusive` was
        // the one to clear it, a waiter of higher priority could resume first, find the finished
        // task still set and spin on the main actor forever (the caller never ran again).
        // Clearing without an identity check is safe: nothing sets a new `snapshotTask` before
        // this one is cleared (the loop above waits for it).
        let task = Task {
            _ = await work.value
            self.isSnapshotting = false
            self.snapshotTask = nil
        }
        snapshotTask = task
        isSnapshotting = true
        await task.value
        return try await work.value.get()
    }

    /// The snapshots of this VM, oldest first (`SnapshotStore.list`, read off the main actor).
    func listSnapshots() async throws -> [Snapshot] {
        let bundle = try VMBundle.open(name, paths: paths)
        return try await Task.detached { try SnapshotStore(bundle: bundle).list() }.value
    }

    /// "Crea": through the live session while the VM runs in this window (paused, state saved,
    /// cloned, resumed); otherwise the stopped VM's files are cloned under the bundle lock (owner
    /// `.app`; a VM run by `nido start` is refused). Returns the store's warnings (localized).
    func createSnapshot(named snapshotName: String) async throws -> [String] {
        try await exclusive { [self] in
            let bundle = try VMBundle.open(name, paths: paths)
            let store = SnapshotStore(bundle: bundle)
            if let session {
                switch session.state {
                case .running, .paused:
                    guard let saver = session.stateSaver else {
                        throw NidoError.snapshotUnsupported(String(localized: "this session can’t save the VM’s state"))
                    }
                    let result = try await Task.detached {
                        try await store.createReportingWarnings(name: snapshotName, owner: .app, session: saver)
                    }.value
                    if self.session === session { apply(session.state) }
                    return result.warnings
                case .stopped:
                    break
                default:
                    // Starting, stopping, an error with the machine possibly alive.
                    throw NidoError.vmMustBeStopped(name.rawValue)
                }
            }
            return try await Task.detached {
                try await store.createReportingWarnings(name: snapshotName, owner: .app, session: nil).warnings
            }.value
        }
    }

    /// "Ripristina" (confirmed): only with no machine behind this window; the store refuses a VM
    /// run elsewhere. A snapshot with its saved state leaves the VM suspended.
    func restoreSnapshot(_ id: UUID) async throws {
        try await exclusive { [self] in
            guard isGone else { throw NidoError.vmMustBeStopped(name.rawValue) }
            let bundle = try VMBundle.open(name, paths: paths)
            // A template is restored only after "Modifica modello" (its disk is the one
            // new VMs are copied from).
            if (try? bundle.readConfig())?.isTemplate == true { throw TemplateLockedError(name: name.rawValue) }
            try await SnapshotStore(bundle: bundle).restoreAsync(id, owner: .app)
            refreshSuspendedState(bundle)
        }
    }

    /// "Elimina" (confirmed): only with no machine behind this window (the store takes the bundle
    /// lock, which a VM running in this app holds).
    func deleteSnapshot(_ id: UUID) async throws {
        try await exclusive { [self] in
            guard isGone else { throw NidoError.vmMustBeStopped(name.rawValue) }
            let bundle = try VMBundle.open(name, paths: paths)
            try await SnapshotStore(bundle: bundle).deleteAsync(id, owner: .app)
        }
    }

    /// A snapshot restore on a template (it changes the disk new VMs are copied from).
    struct TemplateLockedError: LocalizedError {
        let name: String
        var errorDescription: String? {
            String(localized: "\(name) is a template: choose Edit Template in the library before restoring a snapshot")
        }
    }

    /// Nido is quitting: no snapshot operation starts any more.
    struct QuittingError: LocalizedError {
        var errorDescription: String? { String(localized: "Nido is quitting: no new snapshot operations") }
    }

    /// The operation in progress, for quitting (`VMSessionStore.waitForSnapshots`).
    func waitForSnapshotWork() async {
        await waitForSnapshot()
    }

    /// After a restore: "sospesa" when the bundle now holds a saved state, "arrestata" otherwise.
    /// An error screen of a failed start no longer applies to the restored VM: it goes too.
    private func refreshSuspendedState(_ bundle: VMBundle) {
        guard isGone else { return }
        let config = try? bundle.readConfig()
        isSuspended = config.map { bundle.hasSuspendedState($0) } ?? false
        suspendedStateIsStale = isSuspended
            && !(config.map { SuspendedState.nextStartResumes(bundle: bundle, config: $0) } ?? true)
        errorDetail = nil
        if case .error = state { state = .stopped }
    }

    /// Why this VM cannot be suspended (its configuration), nil when it can or has no machine.
    func suspendBlocker() -> String? {
        guard let session else { return nil }
        do {
            try session.validateSaveRestoreSupport()
            return nil
        } catch NidoError.snapshotUnsupported(let reason) {
            return reason
        } catch {
            return error.localizedDescription
        }
    }

    /// Quitting with "Sospendi ed esci": suspends the VM, or stops it when it cannot be suspended
    /// (its configuration, or the suspend failed). Returns the warning in that case.
    func suspendOrStop() async -> String? {
        guard let session, session.state == .running || session.state == .paused else {
            await stop()
            return nil
        }
        var reason = suspendBlocker()
        if reason == nil {
            if await suspend() { return nil }
            reason = lastSuspendFailure ?? String(localized: "suspend failed", comment: "A reason, in parentheses in “%@ wasn’t suspended (%@): it was stopped.”")
        }
        await stop()
        return String(localized: "\(name.rawValue) wasn’t suspended (\(reason ?? "")): it was stopped.")
    }

    private func waitUntilSettled() async {
        guard !state.isSettled else { return }
        await withCheckedContinuation { settleWaiters.append($0) }
    }

    /// True when no machine is behind the model: the state is settled and no session is kept.
    /// False while starting, running or stopping, and also after a failed forced stop while the
    /// machine might still run (state `.error`, session and lock kept): the window must still ask
    /// before closing, the store must keep the model (its lock), and quitting counts it.
    var isGone: Bool { state.isSettled && session == nil }

    // MARK: - Closing the window

    /// The window is being closed. True when it may close now (no VM alive); otherwise the
    /// confirmation is shown (`isConfirmingClose`) and the window stays open.
    /// While the VM is already stopping, the close is ignored (no second confirmation).
    func confirmClose() -> Bool {
        guard !isGone else { return true }
        // A macOS VM keeps running without its window (Review Focus #5): its model stays in the
        // store, and the reopened window shows the same session.
        if guest == .macos { return true }
        guard state != .stopping, !isSuspending else { return false }
        isConfirmingClose = true
        return false
    }

    /// "Arrestare debian-13?"
    var closeQuestion: String { String(localized: "Stop \(name.rawValue)?") }

    func cancelClose() {
        isConfirmingClose = false
    }

    /// The close was confirmed: stops the VM (graceful, then forced) and tells whether the window
    /// may now close (always true once the VM is gone).
    func closeConfirmed() async -> Bool {
        isConfirmingClose = false
        await stop()
        // A machine that may still run keeps its lock in the model, which the store keeps too:
        // the window itself may go.
        return state.isSettled
    }

    // MARK: - Toolbar (Components.swift VMToolbar)

    enum ToolbarAction: Hashable, Sendable {
        case pause, resume, stop, start, settings, fullScreen, retry, details
        /// Opens the snapshots window (S09).
        case snapshots
        /// Saves the state and stops (running VM).
        case suspend
        /// Starts a VM suspended from this window: the start resumes it.
        case resumeSaved
        /// Opens "Accesso da terminale" (macOS).
        case terminalAccess
    }

    struct ToolbarButton: Hashable, Sendable {
        let action: ToolbarAction
        let kind: NidoButton.Kind
        let isEnabled: Bool
    }

    /// The buttons for the model's state; an error with the machine possibly still running offers
    /// Arresta (Riprova could not start anything while the session is kept).
    nonisolated static func toolbarButtons(for state: VMRunState, machineMayRun: Bool) -> [ToolbarButton] {
        if case .error = state, machineMayRun {
            return [.init(action: .stop, kind: .primary, isEnabled: true),
                    .init(action: .details, kind: .secondary, isEnabled: true)]
        }
        return toolbarButtons(for: state)
    }

    var toolbarButtons: [ToolbarButton] {
        if isSuspending || isSnapshotting {
            // Nothing else while the state is saved: the suspend stops the VM itself; a live
            // snapshot resumes it when done.
            return Self.toolbarButtons(for: state, machineMayRun: !isGone)
                .map { ToolbarButton(action: $0.action, kind: $0.kind, isEnabled: false) }
        }
        if state == .stopped, isSuspended {
            return [.init(action: .resumeSaved, kind: .primary, isEnabled: true),
                    .init(action: .snapshots, kind: .secondary, isEnabled: true),
                    .init(action: .settings, kind: .secondary, isEnabled: true)]
        }
        var buttons = Self.toolbarButtons(for: state, machineMayRun: !isGone)
        if guest == .macos, state == .running, let index = buttons.firstIndex(where: { $0.action == .fullScreen }) {
            // S07 macOS: "Accesso da terminale" before Schermo intero.
            buttons.insert(.init(action: .terminalAccess, kind: .secondary, isEnabled: true), at: index)
        }
        return buttons
    }

    /// The toolbar of a window too narrow for every button (7 for a running macOS VM): the run
    /// controls stay buttons, the rest goes in the "Altro" menu, in the same order.
    nonisolated static func compactSplit(_ buttons: [ToolbarButton]) -> (visible: [ToolbarButton], more: [ToolbarButton]) {
        let inMenu: Set<ToolbarAction> = [.suspend, .snapshots, .settings, .terminalAccess, .fullScreen]
        return (buttons.filter { !inMenu.contains($0.action) }, buttons.filter { inMenu.contains($0.action) })
    }

    /// The buttons of the VMToolbar in each state, as in the design.
    nonisolated static func toolbarButtons(for state: VMRunState) -> [ToolbarButton] {
        switch state {
        case .starting, .pausing:
            [.init(action: .pause, kind: .secondary, isEnabled: false),
             .init(action: .stop, kind: .secondary, isEnabled: true)]
        case .running:
            [.init(action: .pause, kind: .secondary, isEnabled: true),
             .init(action: .suspend, kind: .secondary, isEnabled: true),
             .init(action: .stop, kind: .secondary, isEnabled: true),
             .init(action: .snapshots, kind: .secondary, isEnabled: true),
             // Hardware locked while running; the guest actions (Spegni, Guest Tools) need it on.
             .init(action: .settings, kind: .secondary, isEnabled: true),
             .init(action: .fullScreen, kind: .secondary, isEnabled: true)]
        case .paused:
            [.init(action: .resume, kind: .primary, isEnabled: true),
             .init(action: .stop, kind: .secondary, isEnabled: true)]
        case .resuming:
            [.init(action: .resume, kind: .primary, isEnabled: false),
             .init(action: .stop, kind: .secondary, isEnabled: true)]
        case .stopping:
            [.init(action: .pause, kind: .secondary, isEnabled: false),
             .init(action: .stop, kind: .secondary, isEnabled: false)]
        case .stopped:
            [.init(action: .start, kind: .primary, isEnabled: true),
             .init(action: .snapshots, kind: .secondary, isEnabled: true),
             .init(action: .settings, kind: .secondary, isEnabled: true)]
        case .error:
            [.init(action: .retry, kind: .primary, isEnabled: true),
             .init(action: .details, kind: .secondary, isEnabled: true)]
        }
    }

    nonisolated static func label(for action: ToolbarAction, isFullScreen: Bool) -> String {
        switch action {
        case .pause: String(localized: "Pause")
        case .resume, .resumeSaved: String(localized: "Resume")
        case .suspend: String(localized: "Suspend")
        case .stop: String(localized: "Stop")
        case .start: String(localized: "Start")
        case .settings: String(localized: "Settings")
        case .snapshots: String(localized: "Snapshots")
        case .fullScreen: isFullScreen ? String(localized: "Exit Full Screen") : String(localized: "Enter Full Screen")
        case .retry: String(localized: "Try Again")
        case .details: String(localized: "Details")
        case .terminalAccess: String(localized: "Terminal Access")
        }
    }

    /// Heading of the stopped screen: "debian-13 è arrestata", or "è sospesa".
    var stoppedTitle: String {
        // Own keys: the library's "%@ is suspended" is a badge-like phrase, not this heading.
        isSuspended
            ? String(localized: "%@ is suspended (heading)", defaultValue: "\(name.rawValue) is suspended",
                     comment: "Heading of a suspended VM’s window; %@ is the VM’s name.")
            : String(localized: "%@ is stopped (heading)", defaultValue: "\(name.rawValue) is stopped",
                     comment: "Heading of a stopped VM’s window; %@ is the VM’s name.")
    }

    /// Body of the stopped screen: "Ultimo arresto oggi alle 10:42. Avvia la VM dalla barra: …".
    func stoppedMessage(now: Date) -> String {
        if isSuspended, suspendedStateIsStale {
            return String(localized: "The settings changed after the suspend: the next start discards the saved state and the VM starts from scratch.")
        }
        if isSuspended {
            return String(localized: "The VM’s state is saved on the Mac: Resume to continue where you left off.")
        }
        let tail = String(localized: "Start the VM from the toolbar: the disk and the settings stay as you left them.")
        guard let lastStop else { return tail }
        let time = lastStop.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(.current))
        if Calendar.current.isDate(lastStop, inSameDayAs: now) {
            return String(localized: "Last stopped today at \(time). \(tail)")
        }
        let day = lastStop.formatted(Date.FormatStyle(date: .numeric, time: .omitted).locale(.current))
        return String(localized: "Last stopped on \(day) at \(time). \(tail)")
    }

    // MARK: - State

    /// "Il disco della VM … non è leggibile": the user-facing text of a failure.
    static func message(for error: any Error, name: VMName) -> String {
        if case NidoError.alreadyRunning(let pid) = error, pid == getpid() {
            // This very app holds the lock: a clone or a snapshot of the stopped VM is running.
            return String(localized: "Nido is working on \(name.rawValue) (a clone or a snapshot): try again when it’s done.")
        }
        if case NidoError.alreadyRunning(let pid) = error {
            if pid > 0 {
                return String(localized: "\(name.rawValue) is already running in another process (pid \(Int(pid))): stop it there before you open it in this window.",
                              comment: "%lld is a process ID. [not a count]")
            }
            return String(localized: "\(name.rawValue) is already running in another process: stop it there before you open it in this window.")
        }
        return error.localizedDescription
    }

    private func fail(_ error: any Error) {
        errorDetail = error.localizedDescription
        apply(.error(Self.message(for: error, name: name)))
    }

    private func apply(_ new: VMRunState) {
        if case .error = new, state != new {
            errorTitle = if state == .starting {
                String(localized: "Start failed")
            } else if commandInFlight || state == .pausing || state == .resuming {
                String(localized: "The VM doesn’t respond to commands")
            } else {
                String(localized: "The VM stopped because of an error")
            }
        }
        let old = state
        if state != new { state = new }
        if old != new { syncPanels(from: old, to: new) }
        if old != new, new == .running, !isSettingUpAgent { terminalAccess?.autoShow() }
        if new == .stopping || new.isSettled { clearAgentActivity(); endFirstRunSetup() }
        guard new.isSettled else { return }
        terminalAccess?.vmStopped()
        let waiters = settleWaiters
        settleWaiters = []
        for waiter in waiters { waiter.resume() }
        if case .stopped = new { lastStop = Date() }
        if case .error(let message) = new, errorDetail == nil { errorDetail = message }
        if let session, !session.machineIsGone {
            // A failed forced stop may leave the machine running in this process. Keep the lock
            // (and the session, whose callback reports the real stop later) so neither this app
            // nor `nido start` boots the same disk twice; it is released once the machine stops.
            let note = String(localized: "The VM may still be running: Nido keeps its lock until it stops. Stop it from the toolbar.")
            if !(errorDetail ?? "").contains(note) {
                errorDetail = [errorDetail, note].compactMap(\.self).joined(separator: "\n\n")
            }
            return
        }
        session?.onStateChange = nil
        session = nil
        // The machine is gone: no command may reach the guest through a socket nobody serves.
        agentServer?.stop()
        agentServer = nil
        clearAgentActivity()
        freezesGuestDisplay = false
        warnings = []
        terminal?.stop()
        terminal = nil
        lock?.release()
        lock = nil
    }

    // MARK: - Agent activity

    /// The agent is busy or idle (`sequence` orders the values the callback made): the banner
    /// shows while busy and stays `agentBannerHold` after the last command. A value older than
    /// one already applied is dropped.
    func agentActivityChanged(busy: Bool, sequence: Int) {
        guard sequence > agentSequence else { return }
        agentSequence = sequence
        agentHoldTask?.cancel()
        agentHoldTask = nil
        if busy {
            agentActive = true
            return
        }
        agentHoldTask = Task { [weak self, agentHoldSleep] in
            await agentHoldSleep(Self.agentBannerHold)
            guard !Task.isCancelled else { return }
            self?.agentActive = false
        }
    }

    /// The session ends: the banner goes at once, nothing is left to hold.
    private func clearAgentActivity() {
        agentGeneration += 1
        agentHoldTask?.cancel()
        agentHoldTask = nil
        agentSequence = 0
        agentActive = false
    }

    // MARK: - Monitor and AI (M3c)

    /// A session was created: the monitor waits for the guest, the AI models learn about it.
    private func startPanels(for session: any VMSessionHandle) {
        // Monitor, provisioning, Ollama and the AI bridge are Linux-only (R4): a macOS session
        // leaves them as they are (no "Guest Tools mancanti").
        guard guest == .linux else { return }
        monitor.vmStarting(
            source: session.guestChannel.map { GuestMonitorClient(channel: $0) }, guestToolsExpected: true,
            firstBoot: provisioning.isBegun && !provisioning.guestReady)
        provisioning.sessionStarted()
        aiRuntime.guestResponds = false
        aiRuntime.monitorSteps = [:]
        aiBridge.sessionStarted(bridgeAttached: session.aiBridgeAttached)
        let (name, paths) = (name, paths)
        Task { [monitor, aiRuntime, aiBridge, provisioning] in
            // The config says whether Guest Tools are expected (a silent guest is then "in attesa").
            await aiRuntime.loadConfiguration()
            monitor.guestToolsExpected = aiRuntime.guestToolsVersion != nil
            // A phase 2 chosen at creation and not yet verified (the app restarted, the window was
            // reopened): followed again from the config.
            let pending = await Task.detached {
                (try? VMBundle.open(name, paths: paths).readConfig())?.pendingProvisioning
            }.value
            if let pending, pending.ollama {
                provisioning.resume(ProvisioningPlan(model: pending.model))
                monitor.useFirstBootGrace()
            }
            await aiBridge.reloadPolicy()
        }
    }

    /// The VM's state changed: the monitor polls only while it runs; a stop nobody asked for
    /// keeps the last sample ("ultimo campione").
    private func syncPanels(from old: VMRunState, to new: VMRunState) {
        guard guest == .linux else { return }
        aiRuntime.isVMRunning = new == .running
        switch new {
        case .running:
            monitor.vmRunning()
        case .paused, .pausing, .stopping:
            monitor.vmPaused()
        case .error where session.map({ !$0.machineIsGone }) ?? false:
            // A failed pause, resume or forced stop: the machine may still run. Not a stop: the
            // monitor waits (like a pause) and the bridge's session stays.
            monitor.vmPaused()
        case .stopped, .error:
            let asked = stopTask != nil || suspendTask != nil || isSuspending || stopBeforeSession
            monitor.vmStopped(unexpectedly: !asked && old != .starting)
            aiBridge.sessionEnded()
        case .starting, .resuming:
            break
        }
    }
}
