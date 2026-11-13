// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation

/// What suspending and resuming need from a machine: `VMSession`, a fake in the tests.
@MainActor
public protocol SuspendableMachine: MachineStateSaving {
    func start() async throws
    /// See `VMSession.restoreMachineState(from:)`: `.restoreFailed` leaves the machine startable.
    /// A stop asked while it runs is kept and carried out when it ends: on success the machine is
    /// stopped instead of paused; on failure `stopRequestedDuringRestore` is true.
    func restoreMachineState(from url: URL) async throws
    /// True once a stop was asked during `restoreMachineState`: the machine must not be started.
    var stopRequestedDuringRestore: Bool { get }
    func stop(gracePeriod: Duration) async
}

extension VMSession: SuspendableMachine {}

/// Suspend (save the machine state into `state.vzvmsave` and stop) and the start that resumes it.
/// See `docs/BUNDLE-FORMAT.md`.
///
/// Both run in the process that holds the bundle lock (the session's): nothing else touches the
/// bundle meanwhile. A saved state is resumed only while `suspendedConfigHash` equals the
/// `attachedStateHash` of the machine about to start (ruling R-M3A-12); every other case discards
/// it and starts from cold with a warning. The hash is always cleared before the state is used or
/// removed, so no crash can leave a saved state that would be resumed over a disk that has
/// changed since.
public enum SuspendedState {
    /// Review Focus #3.
    public static var configChangedWarning: String {
        L10n.string("The suspended state was discarded because the configuration changed")
    }

    /// How a start went.
    public enum BootOutcome: Equatable, Sendable {
        /// No saved state: a normal boot.
        case coldStart
        /// The saved state was restored and the machine resumed.
        case resumed
        /// A saved state (or its hash) was discarded and the machine booted from cold (localized).
        case discarded(String)
        /// A stop asked while the saved state was being restored was carried out: the machine is
        /// stopped and never ran; the saved state is gone (it was consumed by the restore).
        case stoppedWhileResuming
    }

    // MARK: - Start

    /// Starts `machine` (a session that never ran), resuming the saved state of `bundle` when it
    /// belongs to this machine; otherwise discards it and boots from cold. Errors other than a
    /// refused state (`.restoreFailed`, which discards) are thrown.
    @MainActor
    public static func boot(_ machine: some SuspendableMachine, bundle: VMBundle) async throws -> BootOutcome {
        try await boot(machine, bundle: bundle, syncDirectory: SnapshotStore.syncDirectoryNow)
    }

    /// `boot` with the directory sync injectable (tests record it).
    @MainActor
    static func boot(
        _ machine: some SuspendableMachine, bundle: VMBundle, syncDirectory: (URL) throws -> Void
    ) async throws -> BootOutcome {
        let config = try bundle.readConfig()
        let hasState = entryExists(bundle.stateURL)
        switch (hasState, config.suspendedConfigHash) {
        case (false, nil):
            try await machine.start()
            return .coldStart
        case (true, let saved?) where saved == machine.attachedStateHash && !bundle.stateFileLooksValid():
            // Not a file a suspend writes (empty, a link, another owner…): never handed to the framework.
            try discard(bundle)
            try await machine.start()
            return .discarded(L10n.string("The suspended state was discarded because its file isn’t valid"))
        case (true, let saved?) where saved == machine.attachedStateHash:
            // Invalidate first, durably: whatever happens from here on (a crash included), this
            // state is never resumed again.
            try clearHash(bundle)
            try syncDirectory(bundle.url)
            do {
                try await machine.restoreMachineState(from: bundle.stateURL)
            } catch NidoError.restoreFailed(let reason) {
                removeState(bundle)
                // A stop asked meanwhile (R-M3A-22): no cold start.
                if machine.stopRequestedDuringRestore { return .stoppedWhileResuming }
                try await machine.start()
                return .discarded(L10n.string("The suspended state was discarded because it can’t be restored (\(reason))"))
            }
            // Consumed: the guest is about to write to its disk again.
            removeState(bundle)
            // A stop asked during the restore was carried out instead of the resume (R-M3A-22).
            guard machine.state == .paused, !machine.stopRequestedDuringRestore else {
                // Normally already stopped by the machine; never left paused behind.
                if machine.state.acceptsStop { await machine.stop(gracePeriod: .zero) }
                return .stoppedWhileResuming
            }
            try await machine.resume()
            return .resumed
        case (true, .some):
            try discard(bundle)
            try await machine.start()
            return .discarded(configChangedWarning)
        case (true, nil):
            try discard(bundle)
            try await machine.start()
            return .discarded(L10n.string("The saved state was discarded because it doesn’t belong to a valid suspend"))
        case (false, .some):
            try clearHash(bundle)
            try await machine.start()
            return .discarded(L10n.string("The suspended state was discarded because its file is gone"))
        }
    }

    // MARK: - Suspend

    /// Pauses `machine` (unless already paused), saves its state to `bundle.stateURL` (0600),
    /// records `suspendedConfigHash` = `machine.attachedStateHash`, then stops it. Refused with
    /// `.notRunning` unless running or paused, with `.snapshotUnsupported` when the configuration
    /// cannot be saved (`.suspendFailed`, nothing paused). A failure before the hash is written removes the state and
    /// resumes a machine this call paused; a stop that fails after it clears the hash and removes
    /// the state again (the machine may go on), then throws `.suspendFailed`.
    @MainActor
    public static func suspend(_ machine: some SuspendableMachine, bundle: VMBundle) async throws {
        guard machine.state == .running || machine.state == .paused else {
            throw NidoError.notRunning(bundle.displayName)
        }
        do {
            try machine.validateSaveRestoreSupport()
        } catch NidoError.snapshotUnsupported(let reason) {
            throw NidoError.suspendFailed(unsupportedReason(reason))
        }
        try removeStaleState(bundle)
        let pausedHere = machine.state == .running
        if pausedHere { try await machine.pause() }
        do {
            try await machine.saveMachineState(to: bundle.stateURL)
            try protect(bundle.stateURL)
            try SnapshotStore.syncDirectoryNow(bundle.url)
            let hash = machine.attachedStateHash
            try bundle.updateConfig { $0.suspendedConfigHash = hash }
        } catch {
            removeState(bundle)
            if pausedHere {
                do {
                    try await machine.resume()
                } catch let resumeError {
                    throw NidoError.failedAndNotResumed(
                        message(for: error), resumeError: message(for: resumeError))
                }
            }
            throw error
        }
        // Paused: the stop is forced at once, the guest never runs past the saved state.
        await machine.stop(gracePeriod: .zero)
        guard machine.state == .stopped else {
            try? clearHash(bundle)
            removeState(bundle)
            throw NidoError.suspendFailed(L10n.string("the VM didn’t stop after its state was saved"))
        }
    }

    /// The localized text of an error (`NidoError`'s own description).
    static func message(for error: any Error) -> String {
        (error as? NidoError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - What the next start does

    /// Whether the next start of `bundle` with `config` would resume its saved state: the bundle
    /// holds a valid suspended state and its hash equals the one of the machine that would start
    /// now (the shared folders that pass the start's checks, Rosetta if installed and the guest is
    /// Linux: a macOS machine never has the Rosetta device), as `boot` decides. False means the
    /// state will be discarded (e.g. the settings changed since).
    public static func nextStartResumes(
        bundle: VMBundle, config: VMConfig, imageCache: URL = ImageStore.defaultCacheRoot(),
        rosettaState: RosettaState = .current
    ) -> Bool {
        guard bundle.hasSuspendedState(config), let saved = config.suspendedConfigHash else { return false }
        let shares = LinuxConfigurationBuilder.sharedDirectories(
            config.sharedFolders, paths: NidoPaths(root: bundle.url.deletingLastPathComponent()),
            imageCache: imageCache).directories.keys.sorted()
        return saved == config.effectiveStateHash(
            attachedShareNames: shares,
            rosettaAttached: config.guest == .linux && config.rosetta && rosettaState == .installed)
    }

    /// "this configuration can’t save the VM’s state (<reason>)", localized.
    public static func unsupportedReason(_ reason: String) -> String {
        L10n.string("this configuration can’t save the VM’s state (\(reason))")
    }

    // MARK: - Files

    /// Clears the hash, then removes the state file. The hash must go (it alone decides a resume);
    /// a state file left behind without it is discarded by the next start.
    public static func discard(_ bundle: VMBundle) throws {
        try clearHash(bundle)
        removeState(bundle)
    }

    private static func clearHash(_ bundle: VMBundle) throws {
        guard try bundle.readConfig().suspendedConfigHash != nil else { return }
        try bundle.updateConfig { $0.suspendedConfigHash = nil }
    }

    /// `unlink(2)`: never follows a symlink. Best effort.
    private static func removeState(_ bundle: VMBundle) {
        _ = unlink(bundle.stateURL.path)
    }

    /// A state file left from before (a regular file) is removed; anything else at its path is
    /// refused (`.unsafePath`).
    private static func removeStaleState(_ bundle: VMBundle) throws {
        var info = stat()
        guard lstat(bundle.stateURL.path, &info) == 0 else { return }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() else {
            throw NidoError.unsafePath(bundle.stateURL.path)
        }
        guard unlink(bundle.stateURL.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// The saved state is a private file: `PrivateFile` checks it (regular, one link, this user),
    /// makes it 0600, and it is flushed before the hash that makes it resumable is written.
    private static func protect(_ url: URL) throws {
        let fd = try PrivateFile.open(url, flags: O_RDONLY, label: url.lastPathComponent)
        defer { _ = Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func entryExists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }
}

extension VMSession {
    /// Suspends this session's VM into its bundle: see `SuspendedState.suspend`.
    public func suspend() async throws {
        try await SuspendedState.suspend(self, bundle: VMBundle(url: bundleURL))
    }

    /// Starts this session's VM, resuming its suspended state when it belongs to this machine:
    /// see `SuspendedState.boot`. Run under the bundle lock, after `SnapshotStore.recoverBeforeUse`.
    public func startOrResume() async throws -> SuspendedState.BootOutcome {
        try await SuspendedState.boot(self, bundle: VMBundle(url: bundleURL))
    }
}
