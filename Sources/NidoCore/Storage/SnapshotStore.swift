// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import Synchronization

/// What `SnapshotStore` needs from a running VM to snapshot it with its memory (`VMSession`;
/// a fake in the tests).
@MainActor
public protocol MachineStateSaving: AnyObject, Sendable {
    /// The bundle the machine was built from: a session of another VM is refused.
    var bundleURL: URL { get }
    var state: VMRunState { get }
    /// See `VMSession.attachedStateHash`.
    var attachedStateHash: String { get }
    /// Throws `.snapshotUnsupported(<reason>)` when the machine's state cannot be saved.
    func validateSaveRestoreSupport() throws
    func pause() async throws
    func resume() async throws
    func saveMachineState(to url: URL) async throws
}

/// Points of `SnapshotStore` where the tests inject a failure (or a simulated crash, see
/// `SnapshotStore.SimulatedCrash`).
public enum SnapshotStep: Sendable, Equatable {
    /// create: the saved state is written in the partial directory.
    case stateSaved
    /// create: `disk.img` is cloned in the partial directory.
    case diskCloned
    /// create: `nvram.efi` is cloned in the partial directory (Linux).
    case nvramCloned
    /// create: `auxiliary-storage.img` is cloned in the partial directory (macOS).
    case auxiliaryStorageCloned
    /// create: `meta.json` is written, the partial directory is about to be renamed.
    case metaWritten
    /// restore: the snapshot's files are cloned next to the bundle's (`.new`), nothing replaced yet.
    case restorePrepared
    /// restore: `suspendedConfigHash` is cleared and the bundle's saved state set aside.
    case restoreInvalidated
    /// restore: `disk.img` is replaced, `nvram.efi` (or `auxiliary-storage.img`) and the saved
    /// state not yet.
    case restoreDiskReplaced
    /// restore: every file is replaced, the commit marker not yet written.
    case restoreReplaced
    /// restore: the commit marker is written, `config.json` (the new hash) not yet.
    case restoreCommitting
    /// restore rollback: about to put one original back (a failure here is a failed undo).
    case restoreUndo
    /// restore rollback: about to remove the commit marker (a failure here keeps it).
    case restoreMarkerRemoval
}

/// What `SnapshotStore.recoverInterruptedOperations` could not clean up.
public struct RecoveryOutcome: Sendable, Equatable {
    /// `.restore-*` entries still in the bundle (an original that could not be put back, a copy or
    /// a marker that could not be removed): someone must look at them before the VM is used.
    public let leftovers: [URL]
}

/// The snapshots of one VM, in `<bundle>/snapshots/<uuid>/` (see `docs/BUNDLE-FORMAT.md`).
///
/// - A snapshot is built in `snapshots/.<uuid>.partial/` (0700, files 0600) and renamed to
///   `snapshots/<uuid>/` only when complete; on any failure the partial directory is removed.
/// - The machine files (`machineFileNames(for:)`: disk and NVRAM for Linux, disk and auxiliary
///   storage for macOS) are flushed (`fsync`) and then `clonefile(2)`d (copy-on-write on APFS; a
///   sparse copy only on a volume that cannot clone). The free space is checked first. A macOS
///   bundle's hardware model and machine identifier never change: they stay the bundle's.
/// - Every operation takes the bundle lock (`owner` is the caller's kind), so it never runs on a
///   VM that is running, except a snapshot of a VM running in this process, taken through its
///   session: pause, save the state, clone, resume.
/// - A restore is crash safe: see `restore` and `recoverInterruptedOperations`.
public struct SnapshotStore: Sendable {
    public let bundle: VMBundle
    private let environment: Environment

    /// Free space kept on the volume on top of what a snapshot or a restore needs.
    public static let spaceMargin: UInt64 = 2 << 30

    /// What the store asks the system, replaceable in the tests.
    struct Environment: Sendable {
        var availableCapacity: @Sendable (URL) throws -> UInt64 = SnapshotStore.volumeAvailableCapacity
        var supportsCloning: @Sendable (URL) -> Bool = SnapshotStore.volumeSupportsCloning
        /// Skip `clonefile` and use the copy fallback (tests of the fallback).
        var forceCopy = false
        var faultInjection: (@Sendable (SnapshotStep) throws -> Void)?
        /// Replaces `fsync` of a directory (tests record or fail it; `syncDirectoryNow` is the real one).
        var syncDirectory: (@Sendable (URL) throws -> Void)?
    }

    /// Thrown by a test's fault injection to simulate a crash: the store stops where it is,
    /// without rollback or cleanup, as if the process had died there.
    struct SimulatedCrash: Error {}

    public init(bundle: VMBundle) {
        self.init(bundle: bundle, environment: Environment())
    }

    init(bundle: VMBundle, environment: Environment) {
        self.bundle = bundle
        self.environment = environment
    }

    private static let diskName = "disk.img"
    private static let nvramName = "nvram.efi"
    private static let auxiliaryStorageName = "auxiliary-storage.img"
    private static let stateName = "state.vzvmsave"
    private static let metaName = "meta.json"
    /// Bundle files a restore replaces (and only these are ever renamed back by a recovery).
    private static let restorableNames: Set<String> = [diskName, nvramName, auxiliaryStorageName, stateName]

    /// The machine files a snapshot copies and a restore replaces, disk first: Linux `disk.img`
    /// and `nvram.efi`; macOS `disk.img` and `auxiliary-storage.img` (a disk without the
    /// auxiliary storage it was written with does not boot).
    static func machineFileNames(for guest: GuestOS) -> [String] {
        switch guest {
        case .linux: [diskName, nvramName]
        case .macos: [diskName, auxiliaryStorageName]
        }
    }

    /// Live creates running in this process, by bundle path and lowercased name: two creates
    /// of the same name never both pass the uniqueness check.
    private static let inFlight = Mutex<Set<String>>([])

    // MARK: - list

    /// The complete snapshots, oldest first. Partial or deleting directories, symlinks, entries not
    /// named by a UUID and directories whose `meta.json` is unreadable, names another id or has an
    /// invalid name are skipped. Reads only: no lock.
    public func list() throws -> [Snapshot] {
        guard isRealDirectory(bundle.snapshotsURL) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(atPath: bundle.snapshotsURL.path)
        var result: [Snapshot] = []
        for entry in entries {
            guard let id = UUID(uuidString: entry), id.uuidString == entry,
                let snapshot = try? readMeta(directory(for: id)), snapshot.id == id
            else { continue }
            result.append(snapshot)
        }
        return result.sorted {
            ($0.createdAt, $0.name.lowercased()) < ($1.createdAt, $1.name.lowercased())
        }
    }

    /// The snapshot with this id (a UUID string) or name (ignoring case), else `.snapshotNotFound`.
    public func find(_ reference: String) throws -> Snapshot {
        let snapshots = try list()
        if let id = UUID(uuidString: reference), let match = snapshots.first(where: { $0.id == id }) {
            return match
        }
        guard let match = snapshots.first(where: { $0.name.lowercased() == reference.lowercased() })
        else { throw NidoError.snapshotNotFound(reference) }
        return match
    }

    // MARK: - create

    /// Takes a snapshot named `name`.
    ///
    /// Without a running `session` the VM must be stopped: the bundle lock is taken with `owner`
    /// (a VM running in another process is refused with `.runningInAnotherProcess`, one running in
    /// this process with `.vmMustBeStopped`: pass its session). With a `session` of this bundle
    /// that is running or paused (the VM runs in this process, which holds its lock), the state is
    /// saved too: refused with `.snapshotUnsupported` if the configuration cannot be saved; a
    /// running VM is paused, saved, cloned and resumed (also after a failure). If only the resume
    /// fails, the snapshot exists and `.snapshotResumeFailed` says so.
    @discardableResult
    public func create(
        name: String, owner: LockOwner, session: (any MachineStateSaving)?
    ) async throws -> Snapshot {
        try await createReportingWarnings(name: name, owner: owner, session: session).snapshot
    }

    /// `create`, also returning what went wrong after the snapshot was committed (localized):
    /// e.g. the `snapshots/` directory could not be synced after the final rename, so the snapshot
    /// exists but a power loss right now might lose it.
    public func createReportingWarnings(
        name: String, owner: LockOwner, session: (any MachineStateSaving)?
    ) async throws -> (snapshot: Snapshot, warnings: [String]) {
        try Self.validateName(name)
        var liveSession: (any MachineStateSaving)?
        if let session {
            let state = await session.state
            if state == .running || state == .paused { liveSession = session }
        }
        var lock: BundleLock?
        if let liveSession {
            guard Self.samePath(await liveSession.bundleURL, bundle.url) else {
                throw NidoError.notRunning(bundle.displayName)
            }
            guard let holder = BundleLock.holder(bundle) else {
                throw NidoError.notRunning(bundle.displayName)
            }
            guard holder.pid == getpid() else { throw NidoError.runningInAnotherProcess }
            try await liveSession.validateSaveRestoreSupport()
        } else {
            lock = try acquireLock(owner)
            try recoverBeforeUse()
        }
        defer { lock?.release() }

        let key = Self.standardPath(bundle.url) + "\n" + name.lowercased()
        guard Self.inFlight.withLock({ $0.insert(key).inserted }) else {
            throw NidoError.snapshotNameTaken(name)
        }
        defer { _ = Self.inFlight.withLock { $0.remove(key) } }

        let config = try bundle.readConfig()
        try bundle.verifyInnerFiles(for: config.guest)
        try checkNameIsFree(name)
        // A suspended VM (stopped, valid saved state): the snapshot keeps that state, so a restore
        // gives back the saved state, not a crash-consistent disk (ruling R-M3A-21).
        let suspendedHash = liveSession == nil && bundle.hasSuspendedState(config)
            ? config.suspendedConfigHash : nil
        let sources = Self.machineFileNames(for: config.guest).map { bundle.url.appendingPathComponent($0) }
            + (suspendedHash != nil ? [bundle.stateURL] : [])
        let stateEstimate = liveSession == nil ? 0 : config.memoryBytes
        try checkSpace(copying: sources, extra: stateEstimate)

        try ensureSnapshotsDirectory()
        let id = UUID()
        let partial = bundle.snapshotsURL.appendingPathComponent(".\(id.uuidString).partial", isDirectory: true)
        guard mkdir(partial.path, 0o700) == 0 else { throw posixError() }
        do {
            if let liveSession {
                return try await createLive(
                    id: id, name: name, partial: partial, guest: config.guest, session: liveSession)
            }
            try cloneMachineFiles(of: config.guest, into: partial)
            if suspendedHash != nil {
                try clone(bundle.stateURL, to: partial.appendingPathComponent(Self.stateName))
                try fault(.stateSaved)
            }
            let snapshot = Snapshot(
                id: id, name: name, createdAt: Date(), hasSavedState: suspendedHash != nil,
                configHash: suspendedHash ?? config.stateHash())
            let warnings = try commit(snapshot, partial: partial)
            return (snapshot, warnings)
        } catch is SimulatedCrash {
            throw SimulatedCrash()
        } catch let error as NidoError {
            if case .snapshotResumeFailed = error { throw error }  // committed: keep it
            try? FileManager.default.removeItem(at: partial)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    /// Pause (unless already paused), save, clone, commit, resume. The VM is resumed whatever
    /// happens if this call paused it; a failed resume after the commit is `.snapshotResumeFailed`.
    private func createLive(
        id: UUID, name: String, partial: URL, guest: GuestOS, session: any MachineStateSaving
    ) async throws -> (snapshot: Snapshot, warnings: [String]) {
        let pausedHere = await session.state == .running
        if pausedHere { try await session.pause() }
        // The guest may have powered off meanwhile: then its lock may go at any moment, nothing
        // is cloned (and nothing resumed).
        guard await session.state == .paused else { throw NidoError.notRunning(bundle.displayName) }
        let snapshot: Snapshot
        let warnings: [String]
        do {
            let stateURL = partial.appendingPathComponent(Self.stateName)
            try await session.saveMachineState(to: stateURL)
            try protect(stateURL)
            try fault(.stateSaved)
            try cloneMachineFiles(of: guest, into: partial)
            snapshot = Snapshot(
                id: id, name: name, createdAt: Date(), hasSavedState: true,
                configHash: await session.attachedStateHash)
            warnings = try commit(snapshot, partial: partial)
        } catch {
            if pausedHere {
                do {
                    try await session.resume()
                } catch let resumeError {
                    throw NidoError.failedAndNotResumed(
                        SuspendedState.message(for: error), resumeError: SuspendedState.message(for: resumeError))
                }
            }
            throw error
        }
        if pausedHere {
            do {
                try await session.resume()
            } catch {
                throw NidoError.snapshotResumeFailed(snapshot: name, reason: error.localizedDescription)
            }
        }
        return (snapshot, warnings)
    }

    private func cloneMachineFiles(of guest: GuestOS, into directory: URL) throws {
        for name in Self.machineFileNames(for: guest) {
            try clone(bundle.url.appendingPathComponent(name), to: directory.appendingPathComponent(name))
            switch name {
            case Self.diskName: try fault(.diskCloned)
            case Self.nvramName: try fault(.nvramCloned)
            default: try fault(.auxiliaryStorageCloned)
            }
        }
    }

    /// Writes `meta.json` (0600, exclusive), checks the name is still free and renames the
    /// partial directory into place. Once renamed, the snapshot exists: a failed sync of
    /// `snapshots/` is returned as a warning, not thrown (the caller would otherwise report a
    /// failure for a snapshot that is there).
    private func commit(_ snapshot: Snapshot, partial: URL) throws -> [String] {
        try writeNewFile(partial.appendingPathComponent(Self.metaName), data: snapshot.encoded())
        try fsyncDirectory(partial)
        try fault(.metaWritten)
        try checkNameIsFree(snapshot.name)
        guard renamex_np(partial.path, directory(for: snapshot.id).path, UInt32(RENAME_EXCL)) == 0 else {
            throw posixError()
        }
        do {
            try fsyncDirectory(bundle.snapshotsURL)
        } catch {
            return [L10n.string("snapshot \(snapshot.name) created, but the snapshots folder wasn’t synced to disk (\(error.localizedDescription)): a power failure now could make it disappear")]
        }
        return []
    }

    private func checkNameIsFree(_ name: String) throws {
        if try list().contains(where: { $0.name.lowercased() == name.lowercased() }) {
            throw NidoError.snapshotNameTaken(name)
        }
    }

    // MARK: - restore

    /// Puts the VM back to snapshot `id`: only while it is stopped (the bundle lock is taken with
    /// `owner`; otherwise `.vmMustBeStopped` or `.runningInAnotherProcess`, nothing touched).
    ///
    /// Invalidate first, commit last:
    /// 1. the snapshot's files are cloned next to the bundle's (`.<file>.restore-<tag>.new`);
    /// 2. `suspendedConfigHash` is cleared and the bundle's `state.vzvmsave` set aside
    ///    (`.state.vzvmsave.restore-<tag>.old`): from here on no saved state can be resumed;
    /// 3. each machine file (`disk.img`, then `nvram.efi` for Linux or `auxiliary-storage.img` for
    ///    macOS) is moved aside (`.old`) and its copy moved in, then the snapshot's saved state, if any;
    /// 4. the commit marker `.restore-<tag>.commit` is written;
    /// 5. `config.json` gets the snapshot's hash (nil without a saved state);
    /// 6. the originals (`.old`) and the marker are removed.
    ///
    /// A thrown error before the marker is removed puts every original back (and the original
    /// config). If putting an original back fails, nothing more is removed and
    /// `.restoreIncomplete(<path>)` names a file kept: `recoverInterruptedOperations` (run by
    /// the next operation under the lock) retries. A crash at any point leaves no saved state
    /// that could be resumed over the wrong disk: `recoverInterruptedOperations` rolls an
    /// uncommitted restore back and finishes a committed one.
    public func restore(_ id: UUID, owner: LockOwner) throws {
        let lock = try acquireLock(owner)
        defer { lock.release() }
        try restoreLocked(id)
    }

    /// `restore` for the app: the lock is taken with `BundleLock.acquireAsync` (a brief
    /// contention is retried without blocking a thread) and the work runs off the caller's actor.
    @concurrent
    public func restoreAsync(_ id: UUID, owner: LockOwner) async throws {
        let lock = try await acquireLockAsync(owner)
        defer { lock.release() }
        try restoreLocked(id)
    }

    private func restoreLocked(_ id: UUID) throws {
        try recoverBeforeUse()
        let directory = directory(for: id)
        guard isRealDirectory(directory), let snapshot = try? readMeta(directory), snapshot.id == id
        else { throw NidoError.snapshotNotFound(id.uuidString) }
        let original = try bundle.readConfig()
        // The snapshot must hold every machine file of this guest (a macOS one its auxiliary
        // storage too): checked before anything in the bundle changes.
        let machineNames = Self.machineFileNames(for: original.guest)
        let sourceNames = machineNames + (snapshot.hasSavedState ? [Self.stateName] : [])
        let sources = sourceNames.map { directory.appendingPathComponent($0) }
        for url in sources { try MachineFileCopy.verifyPrivateFile(url) }
        try bundle.verifyInnerFiles(for: original.guest)
        try checkSpace(copying: sources, extra: 0)

        let tag = UUID().uuidString
        func copy(_ name: String) -> URL { bundle.url.appendingPathComponent(".\(name).restore-\(tag).new") }
        func aside(_ name: String) -> URL { bundle.url.appendingPathComponent(".\(name).restore-\(tag).old") }
        let marker = bundle.url.appendingPathComponent(".restore-\(tag).commit")

        // 1. Copies: only snapshot data, always safe to remove.
        var copies: [URL] = []
        do {
            for name in sourceNames {
                let url = copy(name)
                copies.append(url)
                try clone(directory.appendingPathComponent(name), to: url)
            }
            try fault(.restorePrepared)
        } catch is SimulatedCrash {
            throw SimulatedCrash()
        } catch {
            for url in copies { try? FileManager.default.removeItem(at: url) }
            throw error
        }

        // What was moved: undone in reverse order.
        enum Move { case aside(original: URL, saved: URL), installed(URL) }
        var moves: [Move] = []
        var configChanged = false
        do {
            // 2. Invalidate.
            if original.suspendedConfigHash != nil {
                try bundle.updateConfig { $0.suspendedConfigHash = nil }
                configChanged = true
            }
            if exists(bundle.stateURL) {
                try rename(bundle.stateURL, to: aside(Self.stateName))
                moves.append(.aside(original: bundle.stateURL, saved: aside(Self.stateName)))
            }
            try fsyncDirectory(bundle.url)
            try fault(.restoreInvalidated)
            // 3. Replace.
            for name in machineNames {
                let target = bundle.url.appendingPathComponent(name)
                try rename(target, to: aside(name))
                moves.append(.aside(original: target, saved: aside(name)))
                try rename(copy(name), to: target)
                moves.append(.installed(target))
                if name == Self.diskName { try fault(.restoreDiskReplaced) }
            }
            if snapshot.hasSavedState {
                try rename(copy(Self.stateName), to: bundle.stateURL)
                moves.append(.installed(bundle.stateURL))
            }
            try fsyncDirectory(bundle.url)
            try fault(.restoreReplaced)
            // 4. Commit marker, 5. the new hash.
            try writeNewFile(marker, data: Data())
            try fsyncDirectory(bundle.url)
            try fault(.restoreCommitting)
            let restoredHash = snapshot.hasSavedState ? snapshot.configHash : nil
            try bundle.updateConfig { $0.suspendedConfigHash = restoredHash }
            configChanged = true
        } catch is SimulatedCrash {
            throw SimulatedCrash()
        } catch {
            try rollback(
                moves: moves.reversed().map { move in
                    switch move {
                    case .aside(let original, let saved): return (saved, original)
                    case .installed(let url): return (nil, url)
                    }
                },
                marker: marker, original: configChanged ? original : nil, copies: copies, error: error)
        }

        // 6. Done: the originals and the marker go.
        for name in sourceNames + [Self.stateName] { try? FileManager.default.removeItem(at: aside(name)) }
        try? FileManager.default.removeItem(at: marker)
        try? fsyncDirectory(bundle.url)
    }

    /// Undoes `steps` (saved original → its place; nil saved: remove the installed copy), then
    /// writes `original` back. Always throws: `error`; `.restoreMarkerKept` when the commit
    /// marker cannot be removed (nothing is undone: the restore stays committed); or
    /// `.restoreIncomplete` when an original could not be put back (then nothing else is removed).
    private func rollback(
        moves steps: [(saved: URL?, target: URL)], marker: URL, original: VMConfig?, copies: [URL],
        error: any Error
    ) throws -> Never {
        if exists(marker),
            (try? fault(.restoreMarkerRemoval)) == nil || (try? FileManager.default.removeItem(at: marker)) == nil {
            // Committed and the marker stays: nothing is undone, the bundle keeps the snapshot's
            // files with the hash still cleared (no saved state is resumed), and the next
            // recovery finishes the restore.
            throw NidoError.restoreMarkerKept(marker.path)
        }
        // The marker's removal must be durable before any original comes back: a crash must
        // never leave the marker (which finishes the restore) next to the originals.
        try? fsyncDirectory(bundle.url)
        var kept: URL?
        do {
            for (saved, target) in steps {
                if let saved {
                    // Moves over the restored copy, if any: atomic, the original wins.
                    if (try? fault(.restoreUndo)) == nil || Darwin.rename(saved.path, target.path) != 0 {
                        kept = saved
                        break
                    }
                }
                // An installed copy whose original was not moved aside (the saved state): it is
                // snapshot data, its config hash is already cleared.
                else if !steps.contains(where: { $0.saved != nil && $0.target == target }) {
                    try? FileManager.default.removeItem(at: target)
                }
            }
        }
        if let kept {
            throw NidoError.restoreIncomplete(kept.path)
        }
        for url in copies { try? FileManager.default.removeItem(at: url) }
        // The originals must be durable in place before the original hash may come back: a crash
        // must never leave that hash next to the snapshot's files.
        try? fsyncDirectory(bundle.url)
        // Only the hash was changed by the restore: other fields keep what other writers set.
        if let original {
            _ = try? bundle.updateConfig { $0.suspendedConfigHash = original.suspendedConfigHash }
        }
        try? fsyncDirectory(bundle.url)
        throw error
    }

    // MARK: - delete

    /// Removes snapshot `id`: only while the VM is stopped (bundle lock with `owner`). The
    /// directory is renamed to `snapshots/.<uuid>.deleting` first, so an interrupted delete never
    /// leaves a half snapshot that `list` would show.
    public func delete(_ id: UUID, owner: LockOwner) throws {
        let lock = try acquireLock(owner)
        defer { lock.release() }
        try deleteLocked(id)
    }

    /// `delete` for the app: see `restoreAsync`.
    @concurrent
    public func deleteAsync(_ id: UUID, owner: LockOwner) async throws {
        let lock = try await acquireLockAsync(owner)
        defer { lock.release() }
        try deleteLocked(id)
    }

    private func deleteLocked(_ id: UUID) throws {
        let directory = directory(for: id)
        guard isRealDirectory(directory) else { throw NidoError.snapshotNotFound(id.uuidString) }
        let tombstone = bundle.snapshotsURL.appendingPathComponent(".\(id.uuidString).deleting", isDirectory: true)
        try? FileManager.default.removeItem(at: tombstone)
        guard Darwin.rename(directory.path, tombstone.path) == 0 else { throw posixError() }
        try? fsyncDirectory(bundle.snapshotsURL)
        try FileManager.default.removeItem(at: tombstone)
    }

    // MARK: - Recovery

    /// `recoverInterruptedOperations`, then refuses (`.restoreLeftovers` with their paths) when
    /// anything of an interrupted restore is still in the bundle. The caller holds the bundle
    /// lock: `create`, `restore` and every start of a VM (CLI and app) run this first.
    public func recoverBeforeUse() throws {
        let leftovers = recoverInterruptedOperations().leftovers
        guard leftovers.isEmpty else { throw NidoError.restoreLeftovers(leftovers.map(\.path)) }
    }

    /// Cleans up after a create, delete or restore interrupted by a crash. The caller must hold
    /// the bundle lock (nothing else is then working on the bundle); see `recoverBeforeUse`.
    /// Best effort: never throws, and returns the `.restore-*` entries it could not clean up.
    ///
    /// - `snapshots/.<uuid>.partial` and `.deleting` directories are removed.
    /// - A restore with its commit marker is finished: its `.old` and `.new` files and the marker
    ///   are removed (the config keeps whatever hash it has: nil if step 5 did not happen).
    /// - A restore without its marker is rolled back: each `.old` original is renamed back over
    ///   its file, the `.new` copies are removed. The suspended state the VM had before that
    ///   restore stays unusable (its hash was cleared first), so the next start is cold.
    ///   An original that cannot be put back is kept.
    @discardableResult
    public func recoverInterruptedOperations() -> RecoveryOutcome {
        let fm = FileManager.default
        if isRealDirectory(bundle.snapshotsURL),
            let entries = try? fm.contentsOfDirectory(atPath: bundle.snapshotsURL.path) {
            for entry in entries where entry.hasPrefix(".")
                && (entry.hasSuffix(".partial") || entry.hasSuffix(".deleting")) {
                try? fm.removeItem(at: bundle.snapshotsURL.appendingPathComponent(entry))
            }
        }
        guard let entries = try? fm.contentsOfDirectory(atPath: bundle.url.path) else {
            return RecoveryOutcome(leftovers: [])
        }
        var markers = Set<String>()
        var files: [(name: String, tag: String, kind: String, entry: String)] = []
        for entry in entries where entry.hasPrefix(".") {
            if let tag = Self.markerTag(entry) {
                markers.insert(tag)
            } else if let parsed = Self.restoreFile(entry) {
                files.append((parsed.name, parsed.tag, parsed.kind, entry))
            }
        }
        for file in files where file.kind == "new" {
            try? fm.removeItem(at: bundle.url.appendingPathComponent(file.entry))
        }
        for file in files where file.kind == "old" {
            let url = bundle.url.appendingPathComponent(file.entry)
            if markers.contains(file.tag) {
                try? fm.removeItem(at: url)
            } else {
                _ = Darwin.rename(url.path, bundle.url.appendingPathComponent(file.name).path)
            }
        }
        for tag in markers {
            try? fm.removeItem(at: bundle.url.appendingPathComponent(".restore-\(tag).commit"))
        }
        try? fsyncDirectory(bundle.url)
        let remaining = ((try? fm.contentsOfDirectory(atPath: bundle.url.path)) ?? [])
            .filter { Self.markerTag($0) != nil || Self.restoreFile($0) != nil }
            .sorted()
        return RecoveryOutcome(leftovers: remaining.map { bundle.url.appendingPathComponent($0) })
    }

    /// `.restore-<uuid>.commit` → the tag.
    private static func markerTag(_ entry: String) -> String? {
        guard entry.hasPrefix(".restore-"), entry.hasSuffix(".commit") else { return nil }
        let tag = String(entry.dropFirst(".restore-".count).dropLast(".commit".count))
        return UUID(uuidString: tag) != nil ? tag : nil
    }

    /// `.<name>.restore-<uuid>.<new|old>` with `name` one of the restorable files.
    private static func restoreFile(_ entry: String) -> (name: String, tag: String, kind: String)? {
        guard let marker = entry.range(of: ".restore-", options: .backwards) else { return nil }
        let name = String(entry[entry.index(after: entry.startIndex)..<marker.lowerBound])
        let rest = entry[marker.upperBound...]
        guard restorableNames.contains(name), let dot = rest.lastIndex(of: ".") else { return nil }
        let tag = String(rest[..<dot])
        let kind = String(rest[rest.index(after: dot)...])
        guard UUID(uuidString: tag) != nil, kind == "new" || kind == "old" else { return nil }
        return (name, tag, kind)
    }

    // MARK: - Locking

    /// The error for a lock held by `holder`: a VM running in another process can only be
    /// handled there; one running in this process must be stopped (or snapshotted through its session).
    static func refusal(holder: LockHolder, name: String, ownPID: Int32) -> NidoError {
        holder.pid == ownPID ? .vmMustBeStopped(name) : .runningInAnotherProcess
    }

    private func acquireLock(_ owner: LockOwner) throws -> BundleLock {
        do {
            return try BundleLock.acquire(bundle, owner: owner)
        } catch NidoError.alreadyRunning(let pid) {
            throw refusal(pid: pid)
        }
    }

    private func acquireLockAsync(_ owner: LockOwner) async throws -> BundleLock {
        do {
            return try await BundleLock.acquireAsync(bundle, owner: owner)
        } catch NidoError.alreadyRunning(let pid) {
            throw refusal(pid: pid)
        }
    }

    private func refusal(pid: Int32) -> NidoError {
        let holder = BundleLock.holder(bundle) ?? LockHolder(pid: pid, owner: .cli)
        return Self.refusal(holder: holder, name: bundle.displayName, ownPID: getpid())
    }

    // MARK: - Names and space

    /// Same rules as a VM name.
    static func validateName(_ name: String) throws {
        do {
            _ = try VMName(name)
        } catch {
            throw NidoError.invalidSnapshotName(name)
        }
    }

    /// Free space for cloning `sources` plus `extra` bytes (a saved state) plus `spaceMargin`.
    /// A clone takes no space up front, so on a volume that clones only the margin and `extra`
    /// count; otherwise the sources' allocated size (`st_blocks`: the copy is sparse) as well.
    private func checkSpace(copying sources: [URL], extra: UInt64) throws {
        var needed = Self.spaceMargin + extra
        if environment.forceCopy || !environment.supportsCloning(bundle.url) {
            for url in sources { needed += try allocatedSize(url) }
        }
        let available = try environment.availableCapacity(bundle.url)
        guard available >= needed else { throw NidoError.insufficientSpace(needed: needed, available: available) }
    }

    /// `volumeAvailableCapacityForImportantUsage` of the volume holding `url` (falls back to
    /// `volumeAvailableCapacity` where the former is not reported).
    public static func volumeAvailableCapacity(_ url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ])
        if let important = values.volumeAvailableCapacityForImportantUsage { return UInt64(max(0, important)) }
        return UInt64(max(0, values.volumeAvailableCapacity ?? 0))
    }

    /// Whether the volume holding `url` supports `clonefile` (false when unknown).
    public static func volumeSupportsCloning(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeSupportsFileCloningKey]))?.volumeSupportsFileCloning ?? false
    }

    // MARK: - Files

    private func fault(_ step: SnapshotStep) throws {
        try environment.faultInjection?(step)
    }

    private func directory(for id: UUID) -> URL {
        bundle.snapshotsURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private static func standardPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func samePath(_ a: URL, _ b: URL) -> Bool {
        standardPath(a) == standardPath(b)
    }

    /// Creates `snapshots/` (0700) or checks the existing one is a real directory of this user.
    private func ensureSnapshotsDirectory() throws {
        let url = bundle.snapshotsURL
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT, mkdir(url.path, 0o700) == 0 || errno == EEXIST else { throw posixError() }
            guard lstat(url.path, &info) == 0 else { throw posixError() }
            try fsyncDirectory(bundle.url)
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else {
            throw NidoError.unsafePath(url.path)
        }
        guard chmod(url.path, 0o700) == 0 else { throw posixError() }
    }

    private func isRealDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == getuid()
    }

    private func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private func allocatedSize(_ url: URL) throws -> UInt64 {
        try MachineFileCopy.allocatedSize(url)
    }

    /// `MachineFileCopy.flushAndClone` (the copy fallback forced by the test environment).
    private func clone(_ source: URL, to dest: URL) throws {
        try MachineFileCopy.flushAndClone(source, to: dest, forceCopy: environment.forceCopy)
    }

    private func protect(_ url: URL) throws {
        try MachineFileCopy.protect(url)
    }

    /// `rename(2)` that never replaces an existing entry.
    private func rename(_ from: URL, to: URL) throws {
        guard renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 else { throw posixError() }
    }

    /// Makes the renames and creations in `directory` durable.
    private func fsyncDirectory(_ directory: URL) throws {
        if let override = environment.syncDirectory {
            try override(directory)
        } else {
            try Self.syncDirectoryNow(directory)
        }
    }

    /// `fsync(2)` of a directory.
    static func syncDirectoryNow(_ directory: URL) throws {
        let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func writeNewFile(_ url: URL, data: Data) throws {
        try MachineFileCopy.writeNewFile(url, data: data)
    }

    /// `meta.json` of a snapshot directory, read without following symlinks (at most 64 KiB);
    /// a name that breaks the naming rules (e.g. control characters) is refused.
    private func readMeta(_ directory: URL) throws -> Snapshot {
        guard isRealDirectory(directory) else { throw NidoError.unsafePath(directory.path) }
        let path = directory.appendingPathComponent(Self.metaName).path
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= Snapshot.maxMetaSize
        else { throw NidoError.unsafePath(path) }
        let data = try handle.read(upToCount: Snapshot.maxMetaSize + 1) ?? Data()
        guard data.count <= Snapshot.maxMetaSize else { throw NidoError.unsafePath(path) }
        let snapshot = try Snapshot.decode(data)
        try Self.validateName(snapshot.name)
        return snapshot
    }

    private func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
