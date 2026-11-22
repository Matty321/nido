// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoAgentKit
import Testing
@testable import NidoCLI
@_spi(Testing) @testable import NidoCore

/// A stand-in for `VMSession` in `nido start`: records the calls, runs and stops at once.
@MainActor
final class FakeStartSession: StartRunSession {
    let bundleURL: URL
    let attachedStateHash: String
    var state: VMRunState = .stopped {
        didSet { if oldValue != state { onStateChange?(state) } }
    }
    var onStateChange: ((VMRunState) -> Void)?
    /// What `startOrResume` answers (`.stoppedWhileResuming` leaves the machine stopped).
    var outcome: SuspendedState.BootOutcome = .resumed
    /// Thrown by `startOrResume`, which leaves the machine in `.error`.
    var startError: (any Error)?
    var calls: [String] = []
    /// `pause` waits for `releasePause()`: an agent's checkpoint in progress.
    var holdPause = false
    private var pauseWaiter: CheckedContinuation<Void, Never>?

    init(bundle: VMBundle, hash: String = "fake-hash") {
        bundleURL = bundle.url
        attachedStateHash = hash
    }

    func startOrResume() async throws -> SuspendedState.BootOutcome {
        calls.append("start")
        if let startError {
            state = .error("start failed")
            throw startError
        }
        state = outcome == .stoppedWhileResuming ? .stopped : .running
        return outcome
    }

    func stop(gracePeriod: Duration) async {
        calls.append(gracePeriod == .zero ? "force stop" : "stop")
        switch state {
        case .stopped: return
        default: state = .stopped
        }
    }

    func validateSaveRestoreSupport() throws {}

    var isHoldingPause: Bool { pauseWaiter != nil }

    func releasePause() {
        pauseWaiter?.resume()
        pauseWaiter = nil
    }

    func pause() async throws {
        calls.append("pause")
        state = .paused
        if holdPause { await withCheckedContinuation { pauseWaiter = $0 } }
    }

    func resume() async throws {
        calls.append("resume")
        state = .running
    }

    func saveMachineState(to url: URL) async throws {
        calls.append("save")
        try Data("saved-state".utf8).write(to: url)
    }
}

/// A stand-in for `nido start`'s wiring: makes fake sessions and records what it does with them.
@MainActor
final class FakeStartWiring: StartRunWiring {
    let bundle: VMBundle
    var sessions: [FakeStartSession] = []
    var log: [String] = []
    var lines: [String] = []
    /// The checkpoint handling each `serve` was given.
    var served: [(any AgentCheckpointHandling)?] = []
    /// What the next session made answers to `startOrResume`.
    var nextOutcome: SuspendedState.BootOutcome = .resumed
    var nextStartError: (any Error)?
    /// Runs inside `detach`: a signal arriving between the two sessions.
    var onDetach: (() -> Void)?

    init(bundle: VMBundle) {
        self.bundle = bundle
    }

    /// The first session, already running (as `nido start` hands it over).
    func runningSession() -> FakeStartSession {
        let session = FakeStartSession(bundle: bundle)
        session.state = .running
        sessions.append(session)
        return session
    }

    private func index(_ session: FakeStartSession) -> Int {
        sessions.firstIndex { $0 === session } ?? -1
    }

    func makeSession() throws -> FakeStartSession {
        let session = FakeStartSession(bundle: bundle)
        session.outcome = nextOutcome
        session.startError = nextStartError
        sessions.append(session)
        log.append("make \(index(session))")
        return session
    }

    func attach(_ session: FakeStartSession) { log.append("attach \(index(session))") }

    func serve(_ session: FakeStartSession, checkpoints: (any AgentCheckpointHandling)?) {
        log.append("serve \(index(session))")
        served.append(checkpoints)
    }

    func detach(_ session: FakeStartSession) async {
        log.append("detach \(index(session))")
        onDetach?()
    }

    func report(_ line: String) { lines.append(line) }
}

@Suite(.italian) @MainActor struct StartRunTests {
    struct Injected: Error {}

    /// A macOS VM with agent access on, its files written, its lock held by this process.
    struct Env {
        let tmp: URL
        let bundle: VMBundle
        let lock: BundleLock

        init() throws {
            tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("nido-tests-start-run-\(UUID().uuidString)", isDirectory: true)
            let paths = NidoPaths(root: tmp.appendingPathComponent("VMs", isDirectory: true))
            let config = VMConfig(
                id: UUID(), name: try VMName("vm"), guest: .macos, cpuCount: 2,
                memoryBytes: 1 << 30, diskBytes: 1 << 20, macAddress: "02:00:00:00:00:01", agentAccess: true)
            bundle = try VMBundle.create(config: config, paths: paths)
            try Self.write("disk-v1", to: bundle.diskURL)
            try Self.write("machine-id", to: bundle.machineIdentifierURL)
            try Self.write("aux-v1", to: bundle.auxiliaryStorageURL)
            try Self.write("hardware-model", to: bundle.hardwareModelURL)
            lock = try BundleLock.acquire(bundle, owner: .cli)
        }

        static func write(_ text: String, to url: URL) throws {
            try Data(text.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }

        func read(_ url: URL) -> String? {
            (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
        }

        func store(capacity: UInt64 = 1 << 50) -> SnapshotStore {
            var environment = SnapshotStore.Environment()
            environment.availableCapacity = { _ in capacity }
            environment.supportsCloning = { _ in true }
            return SnapshotStore(bundle: bundle, environment: environment)
        }

        /// An agent checkpoint `name` of `session`'s machine (memory included).
        @discardableResult
        func checkpoint(_ name: String, of session: FakeStartSession) async throws -> Snapshot {
            try await store().create(name: name, owner: .cliOperation, session: session, createdBy: Snapshot.agentCreator)
        }

        func cleanup() {
            lock.release()
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    /// A run of `env`'s VM whose first session runs, watched for its end, without grace.
    func makeRun(_ env: Env, wiring: FakeStartWiring, store: SnapshotStore? = nil) -> StartRun<FakeStartWiring> {
        let run = StartRun(
            session: wiring.runningSession(), wiring: wiring, bundle: env.bundle, lock: env.lock, vm: "vm", pid: "42",
            checkpoints: true, store: store ?? env.store(), rollbackGrace: .zero)
        run.beginWatching()
        return run
    }

    /// Asks the coordinator for a rollback to the newest checkpoint and waits for it to end.
    func rollBack(_ run: StartRun<FakeStartWiring>) async throws -> AgentAnswer {
        let coordinator = try #require(run.coordinator)
        let answer = await coordinator.rollback(name: nil)
        await coordinator.rollbackTask?.value
        return answer
    }

    /// The rollback force-stops the session (no suspend), restores the checkpoint under the lock
    /// still held, makes a session that resumes from the checkpoint's memory, serves the agent
    /// socket again with the same coordinator, and says so.
    @Test func rollbackRestartsFromTheCheckpoint() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let wiring = FakeStartWiring(bundle: env.bundle)
        let run = makeRun(env, wiring: wiring)
        let first = wiring.sessions[0]
        try await env.checkpoint("before", of: first)
        first.calls.removeAll()
        try Env.write("disk-v2", to: env.bundle.diskURL)

        let answer = try await rollBack(run)

        #expect(answer.ok)
        #expect(first.calls == ["force stop"])
        #expect(wiring.log == ["detach 0", "make 1", "attach 1", "serve 1"])
        #expect(wiring.served.count == 1 && wiring.served[0] != nil)
        #expect(wiring.sessions[1].calls == ["start"])
        #expect(run.session === wiring.sessions[1])
        #expect(env.read(env.bundle.diskURL) == "disk-v1")
        // The checkpoint's memory is in place for the new session to resume from.
        #expect(env.read(env.bundle.stateURL) == "saved-state")
        #expect(try env.bundle.readConfig().suspendedConfigHash == first.attachedStateHash)
        #expect(env.lock.holds(env.bundle))
        #expect(wiring.lines == ["VM vm è tornata al checkpoint before (pid 42)."])
        #expect(run.liveStateSaver === wiring.sessions[1])
        #expect(run.coordinator?.isBusy == false)

        // The process goes on with the new session: its stop ends the run as usual.
        wiring.sessions[1].state = .stopped
        #expect(await run.waitForEnd() == .ended(.stopped))
    }

    /// Two rollbacks in a row: each restarts the VM, the same coordinator serves both sessions.
    @Test func secondRollbackRunsOnTheNewSession() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let wiring = FakeStartWiring(bundle: env.bundle)
        let run = makeRun(env, wiring: wiring)
        try await env.checkpoint("before", of: wiring.sessions[0])
        #expect(try await rollBack(run).ok)
        #expect(try await rollBack(run).ok)
        #expect(wiring.log == ["detach 0", "make 1", "attach 1", "serve 1", "detach 1", "make 2", "attach 2", "serve 2"])
        #expect(wiring.sessions[1].calls == ["start", "force stop"])
        #expect(wiring.lines.count == 2)
        wiring.sessions[2].state = .stopped
        #expect(await run.waitForEnd() == .ended(.stopped))
    }

    /// A restore that fails: no new session, the VM stays stopped, the run ends with the error.
    @Test func failedRestoreEndsTheRunWithTheVMStopped() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let wiring = FakeStartWiring(bundle: env.bundle)
        // No room for the restore's copies: refused before anything in the bundle changes.
        let run = makeRun(env, wiring: wiring, store: env.store(capacity: 0))
        try await env.checkpoint("before", of: wiring.sessions[0])
        try Env.write("disk-v2", to: env.bundle.diskURL)

        #expect(try await rollBack(run).ok)

        #expect(wiring.log == ["detach 0"])
        #expect(wiring.sessions.count == 1)
        #expect(wiring.sessions[0].state == .stopped)
        #expect(env.read(env.bundle.diskURL) == "disk-v2")
        #expect(wiring.lines.isEmpty)
        let end = await run.waitForEnd()
        guard case .rollbackFailed(let checkpoint, let reason) = end else {
            Issue.record("unexpected end: \(end)")
            return
        }
        #expect(checkpoint == "before")
        let error = CLIError.rollbackFailed(checkpoint: checkpoint, reason: reason)
        #expect(error.localizedDescription.hasPrefix("impossibile tornare al checkpoint before: "))
        #expect(error.localizedDescription.hasSuffix("; la VM è ferma"))
    }

    /// A new session that fails to start: force-stopped, the run ends with the error.
    @Test func failedStartEndsTheRunWithTheVMStopped() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let wiring = FakeStartWiring(bundle: env.bundle)
        let run = makeRun(env, wiring: wiring)
        try await env.checkpoint("before", of: wiring.sessions[0])
        wiring.nextStartError = Injected()

        #expect(try await rollBack(run).ok)

        #expect(wiring.log == ["detach 0", "make 1", "attach 1"])
        let end = await run.waitForEnd()
        guard case .rollbackFailed(let checkpoint, _) = end else {
            Issue.record("unexpected end: \(end)")
            return
        }
        #expect(checkpoint == "before")
        #expect(wiring.sessions[1].calls == ["start", "force stop"])
        #expect(wiring.sessions[1].state == .stopped)
        #expect(wiring.lines.isEmpty)
    }

    /// Ctrl-C between the two sessions: taken by the run, nothing is restored or started, the run
    /// ends with the VM stopped as a stop does.
    @Test func stopDuringRollbackEndsTheRunStopped() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let wiring = FakeStartWiring(bundle: env.bundle)
        let run = makeRun(env, wiring: wiring)
        try await env.checkpoint("before", of: wiring.sessions[0])
        try Env.write("disk-v2", to: env.bundle.diskURL)
        var taken: Bool?
        wiring.onDetach = { taken = run.takeStopBetweenSessions() }

        #expect(try await rollBack(run).ok)

        #expect(taken == true)
        #expect(wiring.log == ["detach 0"])
        #expect(env.read(env.bundle.diskURL) == "disk-v2")
        #expect(wiring.lines.isEmpty)
        #expect(await run.waitForEnd() == .ended(.stopped))
    }

    /// Ctrl-C while the new session resumes: the session carries it out (as today), the run ends
    /// stopped and says the saved state was not resumed, not that the VM went back.
    @Test func stopWhileTheNewSessionResumesEndsTheRunStopped() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let wiring = FakeStartWiring(bundle: env.bundle)
        let run = makeRun(env, wiring: wiring)
        try await env.checkpoint("before", of: wiring.sessions[0])
        wiring.nextOutcome = .stoppedWhileResuming

        #expect(try await rollBack(run).ok)

        #expect(wiring.lines == [StartSupport.stoppedWhileResumingLine(vm: "vm")])
        #expect(await run.waitForEnd() == .ended(.stopped))
    }

    /// Outside a rollback a stop is the session's: the run does not take it, and a stop already
    /// asked refuses a rollback, which changes nothing.
    @Test func stopBeforeARollbackRefusesIt() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let wiring = FakeStartWiring(bundle: env.bundle)
        let run = makeRun(env, wiring: wiring)
        try await env.checkpoint("before", of: wiring.sessions[0])
        #expect(!run.takeStopBetweenSessions())
        run.noteStop()

        #expect(try await rollBack(run).ok)

        #expect(wiring.log.isEmpty)
        #expect(wiring.sessions[0].calls.contains("force stop") == false)
        // The session's own stop ends the run.
        wiring.sessions[0].state = .stopped
        #expect(await run.waitForEnd() == .ended(.stopped))
    }

    /// A suspend in progress (`nido stop --suspend`) wins: no checkpoint or rollback starts, and
    /// a rollback already accepted (in its grace) touches nothing. Once the suspend failed and the
    /// VM runs on, a rollback works again.
    @Test func suspendInProgressRefusesRollbackAndCheckpoint() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let wiring = FakeStartWiring(bundle: env.bundle)
        let run = makeRun(env, wiring: wiring)
        let coordinator = try #require(run.coordinator)
        try await env.checkpoint("before", of: wiring.sessions[0])
        try Env.write("disk-v2", to: env.bundle.diskURL)

        // Accepted, then the suspend starts before the rollback's task runs.
        #expect(await coordinator.rollback(name: nil).ok)
        run.noteSuspend(true)
        await coordinator.rollbackTask?.value
        #expect(wiring.log.isEmpty)
        #expect(!wiring.sessions[0].calls.contains("force stop"))
        #expect(env.read(env.bundle.diskURL) == "disk-v2")
        #expect(run.liveStateSaver == nil)
        // Refused at once while the suspend runs.
        #expect(await coordinator.rollback(name: nil).error == .notRunning)
        #expect(await coordinator.checkpoint(name: "during").error == .notRunning)

        // The suspend failed, the VM keeps running: a rollback goes through.
        run.noteSuspend(false)
        #expect(try await rollBack(run).ok)
        #expect(wiring.log == ["detach 0", "make 1", "attach 1", "serve 1"])
        #expect(env.read(env.bundle.diskURL) == "disk-v1")
    }

    /// Starts a checkpoint of `run`'s session that stays paused until the session's
    /// `releasePause()`.
    func heldCheckpoint(_ run: StartRun<FakeStartWiring>, _ session: FakeStartSession) async throws -> Task<AgentAnswer, Never> {
        let coordinator = try #require(run.coordinator)
        session.holdPause = true
        let pending = Task { await coordinator.checkpoint(name: "during") }
        while !session.isHoldingPause { await Task.yield() }
        session.holdPause = false
        return pending
    }

    /// Ctrl-C or `nido stop` while an agent takes a checkpoint (the VM paused): held, one line
    /// says so, no checkpoint or rollback starts meanwhile, and the stop is carried out once the
    /// checkpoint ended (the VM running again: a graceful stop, not a power-off).
    @Test func stopDuringACheckpointWaitsForIt() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let wiring = FakeStartWiring(bundle: env.bundle)
        let run = makeRun(env, wiring: wiring)
        let session = wiring.sessions[0]
        let pending = try await heldCheckpoint(run, session)
        #expect(run.isTakingCheckpoint)

        var carried: [String] = []
        #expect(run.holdForCheckpoint(.stop) { carried.append("stop \(session.state)") })

        #expect(wiring.lines == ["Arresto richiesto: la VM si arresta dopo il checkpoint dell’agente."])
        #expect(L10n.string("Stop requested: the VM stops after the agent’s checkpoint.", language: "en")
            == "Stop requested: the VM stops after the agent’s checkpoint.")
        #expect(run.liveStateSaver == nil)
        #expect(carried.isEmpty)

        session.releasePause()
        #expect(await pending.value.ok)
        while carried.isEmpty { await Task.yield() }
        #expect(carried == ["stop running"])
        #expect(session.calls == ["pause", "save", "resume"])
        #expect(!run.isTakingCheckpoint)
        #expect(run.liveStateSaver === session)
    }

    /// `nido stop --suspend` while an agent takes a checkpoint: held as a stop is, so the
    /// suspend's save never runs alongside the checkpoint's; once it was handed over, checkpoints
    /// are no longer held back by it.
    @Test func suspendDuringACheckpointWaitsForIt() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let wiring = FakeStartWiring(bundle: env.bundle)
        let run = makeRun(env, wiring: wiring)
        let session = wiring.sessions[0]
        let pending = try await heldCheckpoint(run, session)

        var carried: [String] = []
        #expect(run.holdForCheckpoint(.suspend) { carried.append("suspend after \(session.calls)") })

        #expect(wiring.lines == ["Sospensione richiesta: la VM viene sospesa dopo il checkpoint dell’agente."])
        #expect(L10n.string("Suspend requested: the VM is suspended after the agent’s checkpoint.", language: "en")
            == "Suspend requested: the VM is suspended after the agent’s checkpoint.")
        #expect(run.liveStateSaver == nil)

        session.releasePause()
        #expect(await pending.value.ok)
        while carried.isEmpty { await Task.yield() }
        #expect(carried == ["suspend after [\"pause\", \"save\", \"resume\"]"])
        #expect(run.liveStateSaver === session)
        #expect(await run.coordinator?.checkpoint(name: "after").ok == true)
    }

    /// No checkpoint being taken: a stop or a suspend is not held, nothing is said, and it is the
    /// caller's to carry out at once. A rollback is no checkpoint: between its two sessions the
    /// stop is the run's (`takeStopBetweenSessions`), not held.
    @Test func stopOrSuspendIsHeldOnlyDuringACheckpoint() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let wiring = FakeStartWiring(bundle: env.bundle)
        let run = makeRun(env, wiring: wiring)
        var carried = 0
        #expect(!run.isTakingCheckpoint)
        #expect(!run.holdForCheckpoint(.stop) { carried += 1 })
        #expect(!run.holdForCheckpoint(.suspend) { carried += 1 })

        try await env.checkpoint("before", of: wiring.sessions[0])
        var heldDuringRollback: Bool?
        wiring.onDetach = { heldDuringRollback = run.holdForCheckpoint(.stop) { carried += 1 } }
        #expect(try await rollBack(run).ok)
        #expect(heldDuringRollback == false)
        for _ in 0..<10 { await Task.yield() }
        #expect(carried == 0)
        #expect(wiring.lines == ["VM vm è tornata al checkpoint before (pid 42)."])
    }

    /// A normal stop ends the run with the session's final state; the run unwires nothing itself.
    @Test func normalStopEndsTheRun() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let wiring = FakeStartWiring(bundle: env.bundle)
        let run = makeRun(env, wiring: wiring)
        wiring.sessions[0].state = .error("boom")
        #expect(await run.waitForEnd() == .ended(.error("boom")))
        #expect(wiring.log.isEmpty)
    }

    /// Only a macOS VM with agent access on gets checkpoints.
    @Test func checkpointsOnlyForAMacOSVMWithAgentAccess() throws {
        func config(_ guest: GuestOS, _ access: Bool?) throws -> VMConfig {
            VMConfig(
                id: UUID(), name: try VMName("vm"), guest: guest, cpuCount: 2, memoryBytes: 1 << 30,
                diskBytes: 1 << 20, macAddress: "02:00:00:00:00:01", agentAccess: access)
        }
        #expect(StartRun<FakeStartWiring>.offersCheckpoints(try config(.macos, true)))
        #expect(!StartRun<FakeStartWiring>.offersCheckpoints(try config(.macos, false)))
        #expect(!StartRun<FakeStartWiring>.offersCheckpoints(try config(.macos, nil)))
        #expect(!StartRun<FakeStartWiring>.offersCheckpoints(try config(.linux, true)))
        #expect(!StartRun<FakeStartWiring>.offersCheckpoints(nil))

        let env = try Env()
        defer { env.cleanup() }
        let wiring = FakeStartWiring(bundle: env.bundle)
        let run = StartRun(
            session: wiring.runningSession(), wiring: wiring, bundle: env.bundle, lock: env.lock, vm: "vm", pid: "42",
            checkpoints: false)
        #expect(run.coordinator == nil)
        #expect(run.checkpointHandling == nil)
    }

    /// The line after a rollback and the error of a failed one, in the five languages.
    @Test func rollbackLinesAreLocalized() {
        let (vm, checkpoint, pid, reason) = ("vm", "before", "42", "boom")
        func line(_ language: String) -> String {
            L10n.string("VM \(vm) went back to checkpoint \(checkpoint) (pid \(pid)).", language: language)
        }
        func failure(_ language: String) -> String {
            L10n.string("couldn’t go back to checkpoint \(checkpoint): \(reason); the VM is stopped", language: language)
        }
        #expect(line("en") == "VM vm went back to checkpoint before (pid 42).")
        #expect(line("it") == "VM vm è tornata al checkpoint before (pid 42).")
        #expect(failure("en") == "couldn’t go back to checkpoint before: boom; the VM is stopped")
        #expect(failure("it") == "impossibile tornare al checkpoint before: boom; la VM è ferma")
        for language in ["de", "es", "fr"] {
            #expect(line(language) != line("en") && line(language).contains("before") && line(language).contains("42"))
            #expect(failure(language) != failure("en") && failure(language).contains("boom"))
        }
    }
}
