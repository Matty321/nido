// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore

/// A session `StartRun` runs: `VMSession` in `nido start`, a fake in the tests.
@MainActor
public protocol StartRunSession: MachineStateSaving {
    /// Invoked on the main actor whenever the state changes.
    var onStateChange: ((VMRunState) -> Void)? { get set }
    func startOrResume() async throws -> SuspendedState.BootOutcome
    func stop(gracePeriod: Duration) async
}

extension VMSession: StartRunSession {}

/// What `StartRun` needs from `nido start` for each session of the VM: making it and wiring it to
/// the terminal and the agent socket, then unwiring it.
@MainActor
public protocol StartRunWiring: AnyObject {
    associatedtype Session: StartRunSession
    /// A new session of the bundle, not started.
    func makeSession() throws -> Session
    /// Before `session` starts: its warnings and its signal handling (Ctrl-C, `nido stop
    /// --suspend`), which replaces the previous session's.
    func attach(_ session: Session)
    /// Once `session` runs: the agent control socket (the previous one stopped first), with the
    /// run's checkpoint handling.
    func serve(_ session: Session, checkpoints: (any AgentCheckpointHandling)?)
    /// After `session` stopped for a rollback: what was attached for it ends (the setup task, the
    /// agent socket, the network relay, the console). Calling it again changes nothing.
    func detach(_ session: Session) async
    /// One line for the user (stderr).
    func report(_ line: String)
}

/// What the terminal asks of a `nido start` run: a stop (Ctrl-C, SIGTERM, SIGHUP, `nido stop`) or
/// a suspend (`nido stop --suspend`).
public enum TerminalRequest: Equatable, Sendable {
    case stop
    case suspend
}

/// How a `nido start` run ends.
public enum StartRunEnd: Equatable, Sendable {
    /// The session reached a final state (stopped, also after a suspend, or failed): the process
    /// ends as it always did.
    case ended(VMRunState)
    /// An agent's rollback to `checkpoint` failed (`reason`, localized): the VM is stopped and the
    /// process exits with the error.
    case rollbackFailed(checkpoint: String, reason: String)
}

/// The run of `nido start` from its first session to its end, and the VM's owner for an agent's
/// rollback (`AgentRollbackOwner`): the rollback stops the session (forced, no suspend), restores
/// the checkpoint under the bundle lock the process keeps, and starts a new session, which resumes
/// from the checkpoint's memory; the process goes on with it. One coordinator serves every session
/// of the run, so a checkpoint or rollback in progress spans the restart.
///
/// A stop asked from the terminal wins over a rollback: once noted (`noteStop`), no rollback
/// starts; asked between the two sessions (`takeStopBetweenSessions`), nothing more is restored
/// or started and the run ends with the VM stopped. A suspend (`nido stop --suspend`) wins too:
/// while it runs (`noteSuspend`), no checkpoint or rollback starts. A stop or a suspend asked
/// while an agent takes a checkpoint waits for it (`holdForCheckpoint`).
@MainActor
public final class StartRun<Wiring: StartRunWiring>: AgentRollbackOwner {
    public let bundle: VMBundle
    /// The session that runs, or ran last.
    public private(set) var session: Wiring.Session
    /// The agent checkpoints of this run: only for a macOS VM with agent access on.
    public private(set) var coordinator: AgentCheckpointCoordinator?
    /// `coordinator` as the agent socket of every session takes it.
    public private(set) var checkpointHandling: (any AgentCheckpointHandling)?

    private let wiring: Wiring
    private let lock: BundleLock
    private let vm: String
    private let pid: String
    private let store: SnapshotStore

    private var end: StartRunEnd?
    private var waiter: CheckedContinuation<StartRunEnd, Never>?
    /// The session whose final state ends the run.
    private var watched: ObjectIdentifier?
    /// A rollback stopped the session and no new one runs yet.
    private var rollingBack = false
    /// The old session is being stopped or is gone, the new one not attached yet: a stop signal
    /// has no session to stop.
    private var betweenSessions = false
    private var stopRequested = false
    /// A suspend is in progress: it pauses the VM and saves its state, which a checkpoint or a
    /// rollback's forced stop would race with.
    private var suspending = false
    /// Stops and suspends held for an agent's checkpoint and not carried out yet: meanwhile no
    /// checkpoint or rollback starts.
    private var heldForCheckpoint = 0

    /// `session` is the first session, which `nido start` starts itself. `store` is the bundle's
    /// (tests inject one); `rollbackGrace` is the coordinator's.
    public init(
        session: Wiring.Session, wiring: Wiring, bundle: VMBundle, lock: BundleLock, vm: String, pid: String,
        checkpoints: Bool, store: SnapshotStore? = nil, rollbackGrace: Duration = .milliseconds(500)
    ) {
        self.session = session
        self.wiring = wiring
        self.bundle = bundle
        self.lock = lock
        self.vm = vm
        self.pid = pid
        self.store = store ?? SnapshotStore(bundle: bundle)
        if checkpoints {
            let coordinator = AgentCheckpointCoordinator(owner: self, rollbackGrace: rollbackGrace)
            self.coordinator = coordinator
            checkpointHandling = MainActorCheckpointHandler(coordinator)
        }
    }

    /// Whether a VM of `config` gets agent checkpoints in `nido start`: a macOS guest with agent
    /// access on (the only one with an agent socket).
    public nonisolated static func offersCheckpoints(_ config: VMConfig?) -> Bool {
        config?.guest == .macos && config?.agentAccess == true
    }

    // MARK: - Run

    /// From here on a final state of the session ends the run: called once the first session has
    /// started (a state it passes through while starting does not count).
    public func beginWatching() {
        guard !rollingBack else { return }
        watch(session)
    }

    /// Waits for the run's end. After a failed rollback the session is stopped (forced) first.
    public func waitForEnd() async -> StartRunEnd {
        beginWatching()
        let end = await withCheckedContinuation { continuation in
            if let end {
                continuation.resume(returning: end)
            } else {
                waiter = continuation
            }
        }
        if case .rollbackFailed = end { await session.stop(gracePeriod: .zero) }
        return end
    }

    /// A stop asked from the terminal (Ctrl-C, SIGTERM, SIGHUP) that the session carries out: no
    /// rollback starts after it.
    public func noteStop() {
        stopRequested = true
    }

    /// A suspend accepted (true), or one that failed with the VM still there (false): while one
    /// runs, no checkpoint or rollback starts.
    public func noteSuspend(_ inProgress: Bool) {
        suspending = inProgress
    }

    /// A stop asked from the terminal while a rollback has no session running: taken (true), the
    /// rollback goes no further and the run ends with the VM stopped. False outside that window:
    /// the session's own stop applies.
    public func takeStopBetweenSessions() -> Bool {
        guard betweenSessions else { return false }
        stopRequested = true
        return true
    }

    /// An agent's checkpoint is being taken (not a rollback): the VM is paused and its memory saved.
    public var isTakingCheckpoint: Bool {
        coordinator?.isTakingCheckpoint == true
    }

    /// A stop or a suspend asked from the terminal while an agent takes a checkpoint: a stop now
    /// would power the paused VM off at once (no graceful shutdown) and fail the checkpoint, a
    /// suspend would save its state alongside the checkpoint's. Held (true): one line says so,
    /// `carryOut` runs once the checkpoint ended, and no checkpoint or rollback starts in between.
    /// False when no checkpoint is being taken: the caller carries it out at once.
    public func holdForCheckpoint(_ request: TerminalRequest, then carryOut: @escaping @MainActor () -> Void) -> Bool {
        guard let coordinator, coordinator.isTakingCheckpoint else { return false }
        heldForCheckpoint += 1
        let line = switch request {
        case .stop: L10n.string("Stop requested: the VM stops after the agent’s checkpoint.")
        case .suspend: L10n.string("Suspend requested: the VM is suspended after the agent’s checkpoint.")
        }
        wiring.report(line)
        Task {
            await coordinator.checkpointEnded()
            // In the same step as the release: no checkpoint or rollback slips in between.
            heldForCheckpoint -= 1
            carryOut()
        }
        return true
    }

    private func watch(_ session: Wiring.Session) {
        let id = ObjectIdentifier(session)
        guard watched != id else { return }
        watched = id
        if StartSupport.isFinal(session.state) {
            finish(.ended(session.state))
            return
        }
        session.onStateChange = { [weak self, weak session] state in
            guard StartSupport.isFinal(state), let self, let session, self.session === session else { return }
            session.onStateChange = nil
            self.finish(.ended(state))
        }
    }

    private func finish(_ outcome: StartRunEnd) {
        guard end == nil else { return }
        end = outcome
        waiter?.resume(returning: outcome)
        waiter = nil
    }

    // MARK: - AgentRollbackOwner

    public var liveStateSaver: (any MachineStateSaving)? {
        end == nil && !rollingBack && !suspending && heldForCheckpoint == 0 ? session : nil
    }

    /// Refused once the run ended, a stop was asked, a suspend runs, or the session does not run
    /// (stopping): nothing is touched then.
    public func stopForRollback() async throws {
        guard end == nil, !stopRequested, !suspending, session.state == .running || session.state == .paused else {
            throw NidoError.notRunning(vm)
        }
        rollingBack = true
        betweenSessions = true
        // Its stop does not end the run: the next session takes over.
        session.onStateChange = nil
        watched = nil
        await session.stop(gracePeriod: .zero)
        await wiring.detach(session)
        if case .error(let reason) = session.state { throw CLIError.vmFailed(reason) }
    }

    public func restoreForRollback(_ id: UUID) async throws {
        guard end == nil, !stopRequested else { throw NidoError.notRunning(vm) }
        let (store, lock) = (self.store, self.lock)
        try await Task.detached { try store.restore(id, holding: lock) }.value
    }

    public func startAfterRollback() async throws {
        guard end == nil, !stopRequested else { throw NidoError.notRunning(vm) }
        let next = try wiring.makeSession()
        session = next
        wiring.attach(next)
        betweenSessions = false
        let outcome = try await next.startOrResume()
        for line in StartSupport.rollbackStartLines(outcome, vm: vm) { wiring.report(line) }
        if !StartSupport.isFinal(next.state) { wiring.serve(next, checkpoints: checkpointHandling) }
        rollingBack = false
        watch(next)
    }

    public func rollbackDidEnd(target: String, error: (any Error)?) {
        // Whether the rollback stopped the session: if not, nothing changed and the run goes on.
        let stoppedTheSession = rollingBack || betweenSessions
        rollingBack = false
        betweenSessions = false
        guard end == nil else { return }
        guard let error else {
            wiring.report(L10n.string("VM \(vm) went back to checkpoint \(target) (pid \(pid))."))
            return
        }
        guard stoppedTheSession else { return }
        if stopRequested, StartSupport.isFinal(session.state) {
            // The user's stop came in the middle: the run ends as a stop does.
            finish(.ended(session.state))
        } else {
            finish(.rollbackFailed(checkpoint: target, reason: CLISupport.message(for: error)))
        }
    }
}

/// `nido start`'s lines and states.
public enum StartSupport {
    /// The states that end a session.
    public static func isFinal(_ state: VMRunState) -> Bool {
        switch state {
        case .stopped, .error: true
        case .starting, .running, .pausing, .paused, .resuming, .stopping: false
        }
    }

    /// What `nido start` says once its first session started (`pid` the process's).
    public static func startLines(_ outcome: SuspendedState.BootOutcome, vm: String, pid: String) -> [String] {
        switch outcome {
        case .coldStart:
            [L10n.string("VM \(vm) started (pid \(pid)). Press Ctrl-C to stop it.")]
        case .resumed:
            [L10n.string("VM \(vm) resumed from its saved state (pid \(pid)). Press Ctrl-C to stop it.")]
        case .discarded(let warning):
            [discardedWarning(warning), L10n.string("VM \(vm) started from a cold boot (pid \(pid)). Press Ctrl-C to stop it.")]
        case .stoppedWhileResuming:
            [stoppedWhileResumingLine(vm: vm)]
        }
    }

    /// What the session after a rollback says before the rollback's own line: only what went
    /// differently (its saved state discarded, a stop while resuming).
    static func rollbackStartLines(_ outcome: SuspendedState.BootOutcome, vm: String) -> [String] {
        switch outcome {
        case .coldStart, .resumed: []
        case .discarded(let warning): [discardedWarning(warning)]
        case .stoppedWhileResuming: [stoppedWhileResumingLine(vm: vm)]
        }
    }

    static func stoppedWhileResumingLine(vm: String) -> String {
        L10n.string("Stop requested while resuming: the VM \(vm) wasn’t resumed and its saved state was discarded.")
    }

    /// May carry Virtualization.framework's reason: printed without control characters. A period
    /// ends the sentence alike in the five languages.
    private static func discardedWarning(_ warning: String) -> String {
        L10n.string("Warning: \(ConsoleSanitizer.escapingControls(warning) + ".")")
    }
}
