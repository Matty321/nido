// SPDX-License-Identifier: Apache-2.0
import Foundation
import Observation
import Virtualization

/// Lifecycle state of a `VMSession`.
public enum VMRunState: Equatable, Sendable {
    case stopped, starting, running, pausing, paused, resuming, stopping, error(String)

    /// True when assigning `new` over `old` is an actual change that observers must hear about.
    public static func transition(from old: VMRunState, to new: VMRunState) -> Bool {
        old != new
    }

    /// The state to record when an operation that set `transitional` fails: `.error(message)` only
    /// if nothing else (a delegate callback, a `stop()`) took ownership of the state meanwhile.
    public func afterFailure(of transitional: VMRunState, message: String) -> VMRunState {
        self == transitional ? .error(message) : self
    }

    /// Whether `VMSession.stop` acts from this state. Pausing/resuming are included so a Stop
    /// pressed in that window is not lost.
    public var acceptsStop: Bool {
        switch self {
        case .running, .starting, .paused, .pausing, .resuming: true
        case .stopped, .stopping, .error: false
        }
    }
}

/// Owns a running `VZVirtualMachine` for one bundle. The VM uses the main queue.
@MainActor
@Observable
public final class VMSession: NSObject, VZVirtualMachineDelegate, MachineStateSaving {
    public private(set) var state: VMRunState = .stopped {
        didSet {
            if VMRunState.transition(from: oldValue, to: state) {
                closeSerialConsoleIfGone()
                shutDownAIBridgeIfGone()
                shutDownEgressRelayIfGone()
                onStateChange?(state)
            }
        }
    }

    /// Invoked on the main actor whenever the state actually changes (never for equal assignments).
    @ObservationIgnored public var onStateChange: ((VMRunState) -> Void)?

    @ObservationIgnored private let bundleName: String
    @ObservationIgnored private let vm: VZVirtualMachine
    @ObservationIgnored private let configuration: VZVirtualMachineConfiguration
    /// The image cache shared folders are checked against (see `updateSharedFolders`).
    @ObservationIgnored private let imageCache: URL
    /// The bundle the machine was built from.
    @ObservationIgnored public let bundleURL: URL
    /// Set by the first `start()` or `restoreMachineState`: a saved state is restored only into a
    /// machine that never ran.
    @ObservationIgnored private var hasRun = false
    /// The restore of a saved state in progress: a stop asked meanwhile (the state is still
    /// `.stopped`) is kept and carried out when it ends (ruling R-M3A-22).
    @ObservationIgnored private let restoreWindow = PendingStop()

    /// True once a stop was asked while a saved state was being restored: the restore stopped the
    /// machine instead of leaving it paused, or (after a failed restore) it must not be started.
    public var stopRequestedDuringRestore: Bool { restoreWindow.isRequested }

    /// Whether `stop` acts now (or once the restore in progress ends): false when there is
    /// nothing to stop (not started yet, already stopping or stopped).
    public var acceptsStop: Bool {
        restoreWindow.isActive || state.acceptsStop || errorWithLiveMachine
    }

    /// The hash a state saved from this machine is stored with: `VMConfig.effectiveStateHash` of
    /// the config with the devices actually attached at creation (ruling R-M3A-12), so a shared
    /// folder left out because it was missing on the Mac, or Rosetta left out, counts as absent.
    /// Recomputed by `updateSharedFolders`, so a state saved after a live share change carries
    /// the shares the machine really has.
    @ObservationIgnored public private(set) var attachedStateHash: String
    /// What `attachedStateHash` is computed from: the config the machine was built from (its
    /// shared folders replaced by `updateSharedFolders`) and whether Rosetta is attached.
    @ObservationIgnored private var stateConfig: VMConfig
    @ObservationIgnored private let rosettaAttached: Bool
    /// The guest's serial console: interactive in the app; write-only for the CLI. Tee'd into
    /// console.log (capped, see `ConsoleLog`) and closed once the machine has stopped. Nil for a
    /// macOS guest, which has none.
    @ObservationIgnored public let serialConsole: SerialConsole?

    /// The guest's family, from the config the machine was built from.
    @ObservationIgnored public let guest: GuestOS

    /// What the configuration left out (e.g. a shared folder missing on the Mac), localized.
    /// The VM starts anyway; the CLI prints these, the app shows them in the window's bar.
    @ObservationIgnored public let warnings: [String]

    /// The underlying machine, e.g. for a `VZVirtualMachineView` in the app.
    public var virtualMachine: VZVirtualMachine { vm }

    /// The session's first virtio-socket device (every Linux VM has one), or nil for a machine
    /// without. Plain accessor: connecting and listening are the callers' business, on the main
    /// actor (the VM's queue).
    public var socketDevice: VZVirtioSocketDevice? {
        vm.socketDevices.first as? VZVirtioSocketDevice
    }

    /// The relay of the controlled network (`VMConfig.controlledNetwork`), nil on Apple's NAT.
    /// Shut down once the machine is gone.
    @ObservationIgnored public let egressRelay: EgressRelay?

    /// The remote AI bridge of this session (app sessions only; `nido start` never attaches one).
    /// Kept as long as the session: the listener's delegate is weak.
    @ObservationIgnored public private(set) var aiBridge: AIBridgeHost?

    /// Registers `host` on vsock port 7701 of this session's socket device. False, with nothing
    /// registered, for a macOS guest (the bridge is Linux-only), a machine without a socket
    /// device or when a bridge is already attached.
    @discardableResult
    public func attachAIBridge(_ host: AIBridgeHost) -> Bool {
        guard guest == .linux, aiBridge == nil, let device = socketDevice else { return false }
        host.register(on: device)
        aiBridge = host
        return true
    }

    /// The CLI's session. Reads the bundle's config, verifies its inner files for that guest
    /// (`VMBundle.verifyInnerFiles(for:)`), builds and validates the configuration with the
    /// guest's builder and creates the VM.
    ///
    /// Linux: the guest's console is write-only (the host never sends it anything): its output
    /// goes through a `SerialConsole` into `bundle.consoleLogURL` (0600, capped and rotated) and,
    /// with `mirrorsConsole`, also on `serialConsole.output` for `nido start --console` (which
    /// must sanitise it before printing).
    /// macOS: no serial console (`serialConsole` is nil, `mirrorsConsole` has nothing to mirror:
    /// `nido start --console` refuses a macOS VM before getting here) and no console.log; the
    /// machine has its Mac display, used by nobody (headless).
    ///
    /// A controlled VM's relay reports to `egressEvents` (on its own queue).
    public convenience init(
        bundle: VMBundle, mirrorsConsole: Bool = false, display: DisplaySpec? = nil,
        imageCache: URL = ImageStore.defaultCacheRoot(), egressEvents: EgressRelay.Events? = nil
    ) throws {
        try self.init(
            bundle: bundle, mirrorsConsole: mirrorsConsole, display: display, imageCache: imageCache,
            egress: EgressRelay.Options(events: egressEvents), validate: { try $0.validate() })
    }

    /// The CLI's session (see above), with the relay's options and the configuration's
    /// validation given (tests replace gvproxy and make validation fail). A relay started here is
    /// shut down when validation fails.
    convenience init(
        bundle: VMBundle, mirrorsConsole: Bool, display: DisplaySpec?, imageCache: URL,
        egress: EgressRelay.Options, validate: (VZVirtualMachineConfiguration) throws -> Void
    ) throws {
        let config = try bundle.readConfig()
        try bundle.verifyInnerFiles(for: config.guest)
        guard !config.isTemplate else { throw NidoError.isTemplate(bundle.displayName) }
        let built: GuestConfiguration
        let serial: SerialConsole?
        switch config.guest {
        case .linux:
            let console = try SerialConsole(logURL: bundle.consoleLogURL, deliversOutput: mirrorsConsole)
            do {
                built = try LinuxConfigurationBuilder.make(
                    bundle: bundle, config: config, console: console.guestWriteHandle, display: display,
                    imageCache: imageCache, egress: egress)
            } catch {
                console.close()
                throw error
            }
            do {
                try validate(built.configuration)
            } catch {
                // The relay started for this configuration leads nowhere.
                built.egressRelay?.shutdown()
                console.close()
                throw error
            }
            serial = console
        case .macos:
            built = try MacConfigurationBuilder.make(
                bundle: bundle, config: config, display: display, imageCache: imageCache, egress: egress)
            do {
                try validate(built.configuration)
            } catch {
                built.egressRelay?.shutdown()
                throw error
            }
            serial = nil
        }
        self.init(bundle: bundle, config: config, built: built, serialConsole: serial, imageCache: imageCache)
    }

    /// The app's session. Linux: the guest's serial console is `serialConsole` (interactive, tee'd
    /// into console.log), required (`.serialConsoleRequired` when nil). The session closes it once
    /// the machine has stopped; a session is not restarted after that (the app makes a new one per
    /// boot). macOS: no serial console; pass nil (one given anyway is left to the caller, unused).
    /// `imageCache`: the cache the app uses (shared folders inside it are refused at start).
    /// A controlled VM's relay reports to `egressEvents` (on its own queue). `egressRelay`: that
    /// relay already started by the caller (the app starts it off the main actor, since gvproxy may
    /// block for seconds); nil starts it here. The session owns it from now on, also when this
    /// init throws after taking it (it is shut down).
    public convenience init(
        bundle: VMBundle, serialConsole: SerialConsole?, display: DisplaySpec? = nil,
        imageCache: URL = ImageStore.defaultCacheRoot(), egressEvents: EgressRelay.Events? = nil,
        egressRelay: EgressRelay? = nil
    ) throws {
        let config: VMConfig
        let built: GuestConfiguration
        let serial: SerialConsole?
        do {
            (config, built, serial) = try Self.buildForApp(
                bundle: bundle, serialConsole: serialConsole, display: display, imageCache: imageCache,
                egressEvents: egressEvents, egressRelay: egressRelay)
        } catch {
            // Every failure, also before the configuration is built (config unreadable, inner
            // files refused, a template): the relay leads nowhere. Shutdown is idempotent.
            egressRelay?.shutdown()
            throw error
        }
        self.init(bundle: bundle, config: config, built: built, serialConsole: serial, imageCache: imageCache)
    }

    /// The app's configuration (see the init above); throws without shutting `egressRelay` down.
    private static func buildForApp(
        bundle: VMBundle, serialConsole: SerialConsole?, display: DisplaySpec?, imageCache: URL,
        egressEvents: EgressRelay.Events?, egressRelay: EgressRelay?
    ) throws -> (VMConfig, GuestConfiguration, SerialConsole?) {
        let config = try bundle.readConfig()
        try bundle.verifyInnerFiles(for: config.guest)
        guard !config.isTemplate else { throw NidoError.isTemplate(bundle.displayName) }
        switch config.guest {
        case .linux:
            guard let serialConsole else { throw NidoError.serialConsoleRequired }
            let built = try LinuxConfigurationBuilder.make(
                bundle: bundle, config: config, serialConsole: serialConsole, display: display,
                imageCache: imageCache, egress: EgressRelay.Options(events: egressEvents), relay: egressRelay)
            try built.configuration.validate()
            return (config, built, serialConsole)
        case .macos:
            let built = try MacConfigurationBuilder.make(
                bundle: bundle, config: config, display: display, imageCache: imageCache,
                egress: EgressRelay.Options(events: egressEvents), relay: egressRelay)
            try built.configuration.validate()
            return (config, built, nil)
        }
    }

    private init(
        bundle: VMBundle, config: VMConfig, built: GuestConfiguration, serialConsole: SerialConsole?,
        imageCache: URL
    ) {
        let configuration = built.configuration
        self.guest = config.guest
        self.warnings = built.warnings
        self.serialConsole = serialConsole
        self.bundleName = bundle.url.deletingPathExtension().lastPathComponent
        self.configuration = configuration
        self.imageCache = imageCache
        self.bundleURL = bundle.url
        self.attachedStateHash = built.stateHash(for: config)
        self.stateConfig = config
        self.rosettaAttached = built.rosettaAttached
        self.egressRelay = built.egressRelay
        self.vm = VZVirtualMachine(configuration: configuration)
        super.init()
        vm.delegate = self
    }

    public func start() async throws {
        hasRun = true
        state = .starting
        do {
            try await vm.start()
            // A stop() issued while starting owns the state from then on.
            if state == .starting { state = .running }
        } catch {
            if state == .starting { state = .error(error.localizedDescription) }
            throw error
        }
    }

    /// Pauses a running VM. Only valid from `.running`; otherwise throws `NidoError.notRunning`.
    /// A failure leaves the session in `.error` (unless a stop or delegate callback already moved it on).
    public func pause() async throws {
        guard state == .running else { throw NidoError.notRunning(bundleName) }
        state = .pausing
        do {
            try await vm.pause()
            if state == .pausing { state = .paused }
        } catch {
            state = state.afterFailure(of: .pausing, message: error.localizedDescription)
            throw error
        }
    }

    /// Resumes a paused VM. Only valid from `.paused`; otherwise throws `NidoError.notRunning`.
    /// A failure leaves the session in `.error` (unless a stop or delegate callback already moved it on).
    public func resume() async throws {
        guard state == .paused else { throw NidoError.notRunning(bundleName) }
        state = .resuming
        do {
            try await vm.resume()
            if state == .resuming { state = .running }
        } catch {
            state = state.afterFailure(of: .resuming, message: error.localizedDescription)
            throw error
        }
    }

    // MARK: - Shared folders

    /// Replaces the folders the running guest sees: `share` of this session's shared-folder device
    /// (tag `nido` on Linux, `MacConfigurationBuilder.sharedFolderTag` on macOS)
    /// becomes exactly `folders` (validated again as at start: a folder that fails is left out
    /// and reported). An empty list shares nothing. Takes effect at once, also while the VM runs.
    /// Returns the warnings (localized), one per folder left out. Throws `.notFound` for a machine
    /// without the device.
    @discardableResult
    public func updateSharedFolders(_ folders: [SharedFolder]) throws -> [String] {
        let tag = switch guest {
        case .linux: SharedFolder.tag
        case .macos: MacConfigurationBuilder.sharedFolderTag
        }
        guard let device = vm.directorySharingDevices
            .compactMap({ $0 as? VZVirtioFileSystemDevice }).first(where: { $0.tag == tag })
        else { throw NidoError.notFound(L10n.string("shared folders device")) }
        let shared = LinuxConfigurationBuilder.sharedDirectories(
            folders, paths: NidoPaths(root: bundleURL.deletingLastPathComponent()), imageCache: imageCache)
        device.share = VZMultipleDirectoryShare(directories: shared.directories)
        stateConfig.sharedFolders = folders
        attachedStateHash = stateConfig.effectiveStateHash(
            attachedShareNames: shared.directories.keys.sorted(), rosettaAttached: rosettaAttached)
        return shared.warnings
    }

    // MARK: - Saved state

    /// Throws `.snapshotUnsupported(<reason>)` when Virtualization.framework cannot save (or
    /// restore) a machine with this configuration.
    public func validateSaveRestoreSupport() throws {
        do {
            try configuration.validateSaveRestoreSupport()
        } catch {
            throw NidoError.snapshotUnsupported(error.localizedDescription)
        }
    }

    /// Writes the machine state to `url` (a file that must not exist yet). The VM must be paused
    /// (`.paused`, otherwise `.notRunning`) and stays paused. The file is protected by a key tied
    /// to this Mac: it can only be restored here.
    public func saveMachineState(to url: URL) async throws {
        guard state == .paused else { throw NidoError.notRunning(bundleName) }
        try await vm.saveMachineStateTo(url: url)
    }

    /// Restores a state written by `saveMachineState(to:)` instead of booting: only into a session
    /// that has never started or restored (otherwise `.vmMustBeStopped`); after a failed restore
    /// the same session may still `start()` from cold. On success the VM is `.paused` (call
    /// `resume()`). Any Virtualization.framework error (unreadable file, another host, a
    /// configuration that does not match, a newer format) leaves the session `.stopped` (its
    /// console open, ready for `start()`) and is
    /// thrown as `.restoreFailed(<reason>)`: the caller discards the state and starts from cold.
    /// A `stop` called while the restore runs waits for it and is carried out then: a restored
    /// machine is force-stopped instead of left paused (the guest never runs); after a failure
    /// `stopRequestedDuringRestore` tells the caller not to start it (the console is closed).
    public func restoreMachineState(from url: URL) async throws {
        guard !hasRun, state == .stopped, vm.state == .stopped, !restoreWindow.isActive else {
            throw NidoError.vmMustBeStopped(bundleName)
        }
        // No transitional state: going back to `.stopped` after a failure would close the serial
        // console, and the same session must still be able to `start()` from cold.
        restoreWindow.begin()
        do {
            try await vm.restoreMachineStateFrom(url: url)
        } catch {
            restoreWindow.end()
            if restoreWindow.isRequested { serialConsole?.close() }
            throw NidoError.restoreFailed(error.localizedDescription)
        }
        hasRun = true
        if state == .stopped { state = .paused }
        if restoreWindow.isRequested, state == .paused {
            // Paused: the stop is forced at once, nothing of the guest runs.
            await performStop(gracePeriod: .zero)
        }
        restoreWindow.end()
    }

    /// Asks the guest to power off; forces a stop if it is still running after `gracePeriod`.
    /// A paused VM cannot take a graceful request, so it is force-stopped immediately (also when
    /// called mid-pause/resume: the wait ends as soon as the VM reports paused).
    /// The graceful request is sent once, as soon as the VM accepts it (also mid-start).
    /// If the calling task is cancelled, the grace period ends immediately and the VM is
    /// force-stopped (the polling sleep would otherwise return at once and spin).
    /// Also acts from `.error` while the machine may still run (a failed pause, resume or forced
    /// stop): the only way to power such a machine off.
    /// Called while a saved state is being restored (`restoreMachineState`), it waits for the
    /// restore, which carries the stop out (ruling R-M3A-22).
    public func stop(gracePeriod: Duration) async {
        if restoreWindow.isActive {
            await restoreWindow.requestAndWait()
        }
        await performStop(gracePeriod: gracePeriod)
    }

    private func performStop(gracePeriod: Duration) async {
        guard state.acceptsStop || errorWithLiveMachine else { return }
        state = .stopping
        var requested = false
        var requestError: (any Error)?
        let deadline = ContinuousClock.now.advanced(by: gracePeriod)
        while vm.state != .paused, vm.state != .stopped, vm.state != .error, ContinuousClock.now < deadline {
            if !requested, vm.canRequestStop {
                requested = true
                do { try vm.requestStop() } catch { requestError = error }
            }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
        }
        do {
            if vm.state != .stopped, vm.canStop {
                try await vm.stop()
            }
        } catch {
            state = .error(error.localizedDescription)
            return
        }
        if case .error = state { return }
        if vm.state == .stopped {
            if state != .stopped { state = .stopped }
        } else {
            let reason = requestError?.localizedDescription ?? L10n.string("the VM didn’t stop")
            state = .error(reason)
        }
    }

    /// `.error` while the machine has not stopped or failed (it may still be running).
    private var errorWithLiveMachine: Bool {
        guard case .error = state else { return false }
        return vm.state != .stopped && vm.state != .error
    }

    /// Once the machine is gone (stopped, or failed), nothing uses the console's pipes any more.
    private func closeSerialConsoleIfGone() {
        guard let serialConsole else { return }
        switch state {
        case .stopped, .error:
            if vm.state == .stopped || vm.state == .error { serialConsole.close() }
        default:
            break
        }
    }

    /// Once the machine is gone (stopped, also after a suspension saved its state, or failed), the
    /// bridge stops listening and cancels the calls it still serves: nothing runs, or is charged,
    /// for a guest that is not there. A restored machine gets a new session and a new bridge.
    private func shutDownAIBridgeIfGone() {
        guard let aiBridge else { return }
        switch state {
        case .stopped, .error:
            if vm.state == .stopped || vm.state == .error { aiBridge.shutdown() }
        default:
            break
        }
    }

    /// Once the machine is gone, gvproxy and the relay stop: the guest's network end leads nowhere.
    private func shutDownEgressRelayIfGone() {
        guard let egressRelay else { return }
        switch state {
        case .stopped, .error:
            if vm.state == .stopped || vm.state == .error { egressRelay.shutdown() }
        default:
            break
        }
    }

    nonisolated public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        MainActor.assumeIsolated {
            state = .stopped
            // Also when the state was already `.stopped`/`.error` (no transition): the machine is gone.
            shutDownAIBridgeIfGone()
            shutDownEgressRelayIfGone()
        }
    }

    nonisolated public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        let message = error.localizedDescription
        MainActor.assumeIsolated {
            state = .error(message)
            shutDownAIBridgeIfGone()
            shutDownEgressRelayIfGone()
        }
    }
}
