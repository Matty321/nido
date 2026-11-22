// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoAgentKit
import os

/// How the control socket's gate answers `checkpoint`, `checkpoints` and `rollback`: the owner's
/// own work, never sent to Nido Agent. `MainActorCheckpointHandler` is the owners' one.
public protocol AgentCheckpointHandling: Sendable {
    func checkpoint(name: String?) async -> AgentAnswer
    func checkpoints() async -> AgentAnswer
    func rollback(name: String?) async -> AgentAnswer
}

/// An owner's `AgentCheckpointCoordinator` for the gate, which calls it from its own actor: each
/// call hops to the main actor.
public struct MainActorCheckpointHandler: AgentCheckpointHandling {
    private let coordinator: AgentCheckpointCoordinator

    public init(_ coordinator: AgentCheckpointCoordinator) {
        self.coordinator = coordinator
    }

    public func checkpoint(name: String?) async -> AgentAnswer { await coordinator.checkpoint(name: name) }
    public func checkpoints() async -> AgentAnswer { await coordinator.checkpoints() }
    public func rollback(name: String?) async -> AgentAnswer { await coordinator.rollback(name: name) }
}

/// What `AgentCheckpointCoordinator` needs from the process that runs a VM (the app's window,
/// `nido start`): its bundle, its live session, and the three steps of a rollback.
@MainActor
public protocol AgentRollbackOwner: AnyObject {
    var bundle: VMBundle { get }
    /// The running session, which can pause, save and resume the machine; nil when none runs.
    var liveStateSaver: (any MachineStateSaving)? { get }
    /// Stops the VM at once (force, no suspend), keeping what a restore needs (`nido start` its
    /// bundle lock). The agent's control server goes with the session.
    func stopForRollback() async throws
    /// Puts the stopped VM back to snapshot `id` (`SnapshotStore.restore`, or `restore(_:holding:)`).
    func restoreForRollback(_ id: UUID) async throws
    /// Starts the VM again: it resumes from the checkpoint's saved memory.
    func startAfterRollback() async throws
    /// Called once when a rollback ends: `error` is nil when the VM runs again from `target`.
    func rollbackDidEnd(target: String, error: (any Error)?)
}

/// The agent checkpoints of one VM's owner (one per owner, not per session: a rollback spans the
/// restart). A checkpoint is a live snapshot (`SnapshotStore.createLive`) marked
/// `Snapshot.agentCreator`; an agent lists, restores and (through the limit) deletes only those.
///
/// - `checkpoint`: named `name` or `agent-<yyyyMMdd-HHmmss>` (local time); at most
///   `maxCheckpoints` are kept, the oldest agent checkpoint deleted only after the new one is
///   committed.
/// - `rollback`: answers at once, then stops the VM, restores the checkpoint and starts it again
///   in a task of its own, and records the end in the activity log (`rollbackEnd`).
/// - While a checkpoint or a rollback runs, another one is refused (`notReady`).
///
/// The store's blocking work runs off the main actor.
@MainActor
public final class AgentCheckpointCoordinator {
    /// The most agent checkpoints kept per VM.
    public nonisolated static let maxCheckpoints = 3

    /// A checkpoint or a rollback is in progress.
    public private(set) var isBusy = false
    /// A checkpoint is being taken (not a rollback): the VM is paused, its memory saved, then it
    /// resumes. A stop or a suspend of the owner waits for it (`checkpointEnded`).
    public private(set) var isTakingCheckpoint = false
    /// Who waits for the checkpoint in progress to end.
    private var checkpointWaiters: [CheckedContinuation<Void, Never>] = []

    private weak var owner: (any AgentRollbackOwner)?
    /// The VM's name when the owner made this coordinator: for a refusal after the owner went.
    private let vmName: String
    private let now: () -> Date
    /// How long a rollback waits before it stops the VM: the accepted answer must reach the
    /// client before the owner stops the session and its control server.
    private let rollbackGrace: Duration
    /// The store to use, else one of the owner's bundle (tests inject a store with its environment).
    private let injectedStore: SnapshotStore?
    /// The rollback in progress, or the last one (tests await it).
    private(set) var rollbackTask: Task<Void, Never>?

    public convenience init(owner: any AgentRollbackOwner, now: @escaping () -> Date = Date.init,
                            rollbackGrace: Duration = .milliseconds(500)) {
        self.init(owner: owner, now: now, rollbackGrace: rollbackGrace, store: nil)
    }

    init(owner: any AgentRollbackOwner, now: @escaping () -> Date, rollbackGrace: Duration, store: SnapshotStore?) {
        self.owner = owner
        vmName = owner.bundle.displayName
        self.now = now
        self.rollbackGrace = rollbackGrace
        injectedStore = store
    }

    // MARK: - checkpoint

    /// Takes a checkpoint of the running VM: the answer names it and says how long it took.
    public func checkpoint(name: String?) async -> AgentAnswer {
        let target: (owner: any AgentRollbackOwner, saver: any MachineStateSaving)
        switch ready() {
        case .refused(let answer): return answer
        case .ready(let owner, let saver): target = (owner, saver)
        }
        let name = name ?? Self.defaultName(at: now())
        let store = store(for: target.owner)
        let saver = target.saver
        isBusy = true
        isTakingCheckpoint = true
        defer {
            isBusy = false
            isTakingCheckpoint = false
            let waiters = checkpointWaiters
            checkpointWaiters = []
            for waiter in waiters { waiter.resume() }
        }
        let started = now()
        let snapshot: Snapshot
        do {
            // `.cliOperation`: used only if the session stopped meanwhile (a stopped VM's
            // snapshot, under a lock of a kind `nido stop` never signals), and then undone below.
            snapshot = try await Task.detached {
                let created = try await store.create(
                    name: name, owner: .cliOperation, session: saver, createdBy: Snapshot.agentCreator)
                // As `meta.json` keeps it (whole seconds), so it matches what `checkpoints` lists.
                return (try? store.find(created.id.uuidString)) ?? created
            }.value
        } catch {
            return .failure(Self.code(for: error), Self.message(for: error))
        }
        // The VM stopped between the check and the store's own: the store took a cold snapshot.
        // An agent checkpoint is always live (memory included): it goes, nothing is pruned.
        guard snapshot.hasSavedState else {
            await removeCold(snapshot, store: store)
            return .failure(.notRunning, NidoError.notRunning(Self.vmName(of: target.owner)).localizedDescription)
        }
        await prune(store, keeping: snapshot.id)
        let seconds = Int(max(0, now().timeIntervalSince(started)).rounded())
        return AgentAnswer(ok: true, message: L10n.string("checkpoint \(name) saved in \(String(seconds)) s"),
                           checkpoint: AgentCheckpointInfo(name: snapshot.name, createdAt: snapshot.createdAt))
    }

    /// Returns once no checkpoint is being taken: at once when none is.
    public func checkpointEnded() async {
        guard isTakingCheckpoint else { return }
        await withCheckedContinuation { checkpointWaiters.append($0) }
    }

    /// Deletes a cold snapshot `checkpoint` took by mistake: as a live VM's (`deleteLive`), else
    /// under the bundle lock (the VM stopped and released it). A failure is logged.
    private func removeCold(_ snapshot: Snapshot, store: SnapshotStore) async {
        let id = snapshot.id
        let failed = await Task.detached { () -> (any Error)? in
            do {
                do {
                    try store.deleteLive(id)
                } catch {
                    try store.delete(id, owner: .cliOperation)
                }
                return nil
            } catch {
                return error
            }
        }.value
        if let failed {
            Self.logger.error("could not delete a cold agent checkpoint: \(String(describing: failed), privacy: .public)")
        }
    }

    /// Deletes the oldest agent checkpoints beyond `maxCheckpoints`, never `newID` (the one just
    /// taken, whatever its time: the clock may have gone back, or the others share its second and
    /// sort after it by name). A failure is logged and leaves one more checkpoint than the limit:
    /// the new one is taken all the same.
    private func prune(_ store: SnapshotStore, keeping newID: UUID) async {
        let keep = Self.maxCheckpoints
        let result = await Task.detached { () -> (any Error)? in
            do {
                let others = try store.list().filter { $0.isAgentCheckpoint && $0.id != newID }
                for snapshot in others.dropLast(keep - 1) {
                    try store.deleteLive(snapshot.id)
                }
                return nil
            } catch {
                return error
            }
        }.value
        if let result {
            Self.logger.error("could not delete an old agent checkpoint: \(String(describing: result), privacy: .public)")
        }
    }

    // MARK: - checkpoints

    /// The agent checkpoints, newest first; an empty list when there is none.
    public func checkpoints() async -> AgentAnswer {
        guard let owner else { return .failure(.notRunning, NidoError.notRunning(vmName).localizedDescription) }
        do {
            let list = try await agentCheckpoints(store(for: owner))
            return AgentAnswer(ok: true, checkpoints: list.reversed().map {
                AgentCheckpointInfo(name: $0.name, createdAt: $0.createdAt)
            })
        } catch {
            return .failure(Self.code(for: error), Self.message(for: error))
        }
    }

    // MARK: - rollback

    /// Goes back to the agent checkpoint named `name` (ignoring case, as the store does), or the
    /// newest. Answers at once; the stop, the restore and the start run afterwards, and
    /// `AgentRollbackOwner.rollbackDidEnd` is called once at the end, after the end is in the
    /// activity log.
    public func rollback(name: String?) async -> AgentAnswer {
        let owner: any AgentRollbackOwner
        switch ready() {
        case .refused(let answer): return answer
        case .ready(let readyOwner, _): owner = readyOwner
        }
        let list: [Snapshot]
        do {
            list = try await agentCheckpoints(store(for: owner))
        } catch {
            return .failure(Self.code(for: error), Self.message(for: error))
        }
        guard let newest = list.last else {
            return .failure(.badRequest, L10n.string("no agent checkpoint: take one with checkpoint first"))
        }
        let target: Snapshot
        if let name {
            guard let match = list.first(where: { $0.name.lowercased() == name.lowercased() }) else {
                return .failure(.badRequest, L10n.string("no agent checkpoint named \(name)"))
            }
            target = match
        } else {
            target = newest
        }
        // Checked again here: the list was read off the main actor.
        guard !isBusy else { return Self.busy }
        isBusy = true
        let bundle = owner.bundle
        let grace = rollbackGrace
        let started = now()
        rollbackTask = Task { [self] in
            if grace > .zero { try? await Task.sleep(for: grace) }
            var failure: (any Error)?
            do {
                try await owner.stopForRollback()
                try await owner.restoreForRollback(target.id)
                try await owner.startAfterRollback()
            } catch {
                failure = error
            }
            // Logged before the owner hears of the end: `nido start` may exit right after it.
            let ms = Int(max(0, now().timeIntervalSince(started)) * 1000)
            await Self.recordEnd(target: target.name, error: failure, ms: ms, time: now(), in: bundle)
            isBusy = false
            owner.rollbackDidEnd(target: target.name, error: failure)
        }
        // `checkpoint` names the target: the activity log records where the agent went back to.
        return AgentAnswer(ok: true, message: L10n.string(
            "going back to \(target.name): the VM restarts from that moment; wait about 20 seconds, then take a screenshot"),
            checkpoint: AgentCheckpointInfo(name: target.name, createdAt: target.createdAt))
    }

    /// Appends the rollback's end to the activity log (`rollbackEnd`, client `nido`). A failure to
    /// write it is logged and changes nothing.
    private static func recordEnd(target: String, error: (any Error)?, ms: Int, time: Date, in bundle: VMBundle) async {
        let entry = AgentActivityEntry(
            v: AgentActivityEntry.version, time: time, session: UUID().uuidString.lowercased(),
            client: AgentCommand.Client.nido, op: "rollbackEnd", detail: ["name": target], ok: error == nil,
            error: error.map { code(for: $0).rawValue },
            message: error.map { GuestSSH.sanitize(message(for: $0), limit: AgentAnswer.maxMessageCharacters) },
            ms: ms, thumb: nil)
        let failed = await Task.detached { () -> (any Error)? in
            do {
                try AgentActivityLog.append(entry, thumbnailPNG: nil, in: bundle)
                return nil
            } catch {
                return error
            }
        }.value
        if let failed {
            logger.error("could not record the rollback's end: \(String(describing: failed), privacy: .public)")
        }
    }

    // MARK: - Checks

    private enum Readiness {
        case ready(any AgentRollbackOwner, any MachineStateSaving)
        case refused(AgentAnswer)
    }

    /// Not busy, an owner whose VM is no template and runs in a live session.
    private func ready() -> Readiness {
        guard !isBusy else { return .refused(Self.busy) }
        guard let owner else {
            return .refused(.failure(.notRunning, NidoError.notRunning(self.vmName).localizedDescription))
        }
        let config = try? owner.bundle.readConfig()
        let vmName = Self.vmName(of: owner, config: config)
        if config?.isTemplate == true {
            return .refused(.failure(.badRequest, L10n.string("\(vmName) is a template: checkpoints are not available")))
        }
        guard let saver = owner.liveStateSaver, saver.state == .running || saver.state == .paused else {
            return .refused(.failure(.notRunning, NidoError.notRunning(vmName).localizedDescription))
        }
        return .ready(owner, saver)
    }

    /// The VM's name as `config.json` gives it, else the bundle's.
    private static func vmName(of owner: any AgentRollbackOwner, config: VMConfig? = nil) -> String {
        (config ?? (try? owner.bundle.readConfig()))?.name.rawValue ?? owner.bundle.displayName
    }

    private static var busy: AgentAnswer {
        .failure(.notReady, L10n.string("a checkpoint or rollback is in progress"))
    }

    private func store(for owner: any AgentRollbackOwner) -> SnapshotStore {
        injectedStore ?? SnapshotStore(bundle: owner.bundle)
    }

    /// The agent checkpoints, oldest first (read off the main actor).
    private func agentCheckpoints(_ store: SnapshotStore) async throws -> [Snapshot] {
        try await Task.detached { try store.list().filter(\.isAgentCheckpoint) }.value
    }

    // MARK: - Names and errors

    /// `agent-<yyyyMMdd-HHmmss>` of `date` in local time.
    static func defaultName(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "agent-" + formatter.string(from: date)
    }

    /// The answer's code for a failed store or owner step: a request the store refuses
    /// (`badRequest`), a VM that stopped meanwhile (`notRunning`), anything else `internalError`.
    static func code(for error: any Error) -> AgentErrorCode {
        guard let error = error as? NidoError else { return .internalError }
        switch error {
        case .invalidSnapshotName, .snapshotNameTaken, .snapshotUnsupported, .snapshotNotFound:
            return .badRequest
        case .notRunning, .vmMustBeStopped, .runningInAnotherProcess:
            return .notRunning
        default:
            return .internalError
        }
    }

    static func message(for error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private static let logger = Logger(subsystem: "io.gitlab.pichierri.Nido", category: "agent-checkpoints")
}
