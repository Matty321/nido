// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoAgentKit
import Testing
@_spi(Testing) @testable import NidoCore

/// A stand-in for the VM's owner (the app's window, `nido start`): records the rollback's steps.
@MainActor
final class FakeRollbackOwner: AgentRollbackOwner {
    let bundle: VMBundle
    var liveStateSaver: (any MachineStateSaving)?
    var calls: [String] = []
    /// Thrown by `restoreForRollback`.
    var restoreError: (any Error)?
    /// The errors `rollbackDidEnd` was given, described (nil for a rollback that ended well).
    var endings: [(target: String, error: String?)] = []
    /// The activity log's last op when `rollbackDidEnd` ran: the rollback's end is on disk before
    /// the owner hears of it (`nido start` may exit right after).
    var loggedAtEnd: [String?] = []
    /// When true, `stopForRollback` waits for `releaseStop()`: a rollback in progress.
    var holdStop = false
    private var stopWaiter: CheckedContinuation<Void, Never>?

    init(bundle: VMBundle, saver: (any MachineStateSaving)?) {
        self.bundle = bundle
        liveStateSaver = saver
    }

    var isHoldingStop: Bool { stopWaiter != nil }

    func releaseStop() {
        stopWaiter?.resume()
        stopWaiter = nil
    }

    func stopForRollback() async throws {
        calls.append("stop")
        if holdStop { await withCheckedContinuation { stopWaiter = $0 } }
    }

    func restoreForRollback(_ id: UUID) async throws {
        calls.append("restore \(id.uuidString)")
        if let restoreError { throw restoreError }
    }

    func startAfterRollback() async throws {
        calls.append("start")
    }

    func rollbackDidEnd(target: String, error: (any Error)?) {
        calls.append("end")
        endings.append((target, error.map { "\($0)" }))
        loggedAtEnd.append((try? AgentActivityLog.read(in: bundle, limit: nil).last)?.op)
    }
}

/// A saver whose machine can stop right after the coordinator's check, or hold a checkpoint in
/// its pause.
@MainActor
final class ScriptedSaver: MachineStateSaving {
    let bundleURL: URL
    let attachedStateHash = "scripted"
    /// Reads `.running` once, then `.stopped`: the VM stops right after the coordinator's check.
    var stopsAfterFirstRead = false
    /// `pause` waits for `releasePause()`: a checkpoint in progress.
    var holdPause = false
    var calls: [String] = []
    private var current: VMRunState = .running
    private var reads = 0
    private var pauseWaiter: CheckedContinuation<Void, Never>?

    init(bundle: VMBundle) {
        bundleURL = bundle.url
    }

    var state: VMRunState {
        reads += 1
        return stopsAfterFirstRead && reads > 1 ? .stopped : current
    }

    var isHoldingPause: Bool { pauseWaiter != nil }

    func releasePause() {
        pauseWaiter?.resume()
        pauseWaiter = nil
    }

    func validateSaveRestoreSupport() throws {}

    func pause() async throws {
        calls.append("pause")
        if holdPause { await withCheckedContinuation { pauseWaiter = $0 } }
        current = .paused
    }

    func resume() async throws {
        calls.append("resume")
        current = .running
    }

    func saveMachineState(to url: URL) async throws {
        calls.append("save")
        try Data("saved-state".utf8).write(to: url)
    }
}

@Suite @MainActor struct AgentCheckpointCoordinatorTests {
    typealias Env = SnapshotStoreTests.Env

    /// 2026-11-17 14:30:05, local time.
    static let fixedDate: Date = {
        var components = DateComponents()
        (components.year, components.month, components.day) = (2026, 11, 17)
        (components.hour, components.minute, components.second) = (14, 30, 5)
        return Calendar(identifier: .gregorian).date(from: components)!
    }()

    /// A running VM of this process: its lock held, a live session, a coordinator without grace.
    struct Fixture {
        let env: Env
        let lock: BundleLock
        let session: FakeStateSession
        let owner: FakeRollbackOwner
        let coordinator: AgentCheckpointCoordinator

        @MainActor init(env: Env? = nil, store: SnapshotStore? = nil) throws {
            let env = try env ?? Env()
            self.env = env
            lock = try BundleLock.acquire(env.bundle, owner: .app)
            session = FakeStateSession(bundle: env.bundle)
            owner = FakeRollbackOwner(bundle: env.bundle, saver: session)
            coordinator = AgentCheckpointCoordinator(
                owner: owner, now: { AgentCheckpointCoordinatorTests.fixedDate }, rollbackGrace: .zero,
                store: store ?? env.store())
        }

        func cleanup() {
            lock.release()
            env.cleanup()
        }

        /// The agent checkpoints on disk, oldest first.
        func agentNames() throws -> [String] {
            try env.store().list().filter(\.isAgentCheckpoint).map(\.name)
        }

        @discardableResult
        func checkpoint(_ name: String?) async -> AgentAnswer {
            await coordinator.checkpoint(name: name)
        }

        /// Rewrites snapshot `name`'s `meta.json` with `createdAt` (the store stamps whole seconds:
        /// snapshots taken in one test would otherwise share their time).
        func setCreatedAt(_ name: String, _ date: Date) throws {
            let old = try env.store().find(name)
            let new = Snapshot(id: old.id, name: old.name, createdAt: date, hasSavedState: old.hasSavedState,
                               configHash: old.configHash, createdBy: old.createdBy)
            let url = env.bundle.snapshotsURL.appendingPathComponent(old.id.uuidString)
                .appendingPathComponent("meta.json")
            try new.encoded().write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    /// `hours` after 2020-09-13 12:26:40 UTC: long before any snapshot the tests take now.
    static func past(hours: Int) -> Date {
        Date(timeIntervalSince1970: 1_600_000_000 + Double(hours) * 3600)
    }

    // MARK: - checkpoint

    @Test func checkpointMarksAndNames() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let answer = await f.checkpoint(nil)
        let name = "agent-20261117-143005"
        #expect(answer.ok)
        #expect(answer.message == L10n.string("checkpoint \(name) saved in \(String(0)) s"))
        #expect(L10n.string("checkpoint \(name) saved in \(String(0)) s", language: "en")
            == "checkpoint agent-20261117-143005 saved in 0 s")
        let snapshot = try #require(try f.env.store().list().first)
        #expect(snapshot.name == name)
        #expect(snapshot.createdBy == "agent")
        #expect(snapshot.hasSavedState)
        #expect(answer.checkpoint == AgentCheckpointInfo(name: name, createdAt: snapshot.createdAt))
        #expect(f.session.calls == ["pause", "save", "resume"])
        #expect(!f.coordinator.isBusy)
    }

    @Test func givenNameFollowsTheSnapshotRules() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let bad = await f.checkpoint("../x")
        #expect(bad.ok == false)
        #expect(bad.error == .badRequest)
        #expect(bad.message == NidoError.invalidSnapshotName("../x").localizedDescription)
        #expect(await f.checkpoint("before-install").ok)
        let taken = await f.checkpoint("BEFORE-install")
        #expect(taken.error == .badRequest)
        #expect(taken.message == NidoError.snapshotNameTaken("BEFORE-install").localizedDescription)
        #expect(try f.agentNames() == ["before-install"])
    }

    @Test func fourthCheckpointPrunesOldestAgentOnly() async throws {
        let env = try Env()
        // The user's own snapshot, older than every checkpoint, with a name an agent might use.
        let user = try await env.store().create(name: "agent-old", owner: .cli, session: nil)
        let f = try Fixture(env: env)
        defer { f.cleanup() }
        try f.setCreatedAt("agent-old", Self.past(hours: 0))
        // Taken an hour apart, names in no time order: the oldest is "m-first", first by name "b-second".
        let taken = ["m-first", "b-second", "x-third"]
        for (hour, name) in taken.enumerated() {
            #expect(await f.checkpoint(name).ok)
            try f.setCreatedAt(name, Self.past(hours: hour + 1))
        }
        #expect(try f.agentNames() == taken)
        #expect(AgentCheckpointCoordinator.maxCheckpoints == 3)
        // Taken now, the newest by far, and first by name.
        #expect(await f.checkpoint("a-fourth").ok)
        #expect(try f.agentNames() == ["b-second", "x-third", "a-fourth"])
        #expect(try env.store().list().contains { $0.id == user.id && $0.createdBy == nil })
    }

    /// The clock went back (or the checkpoints share a second) and the new one's name sorts first:
    /// it still is the one kept, with the two newest others; the oldest other goes.
    @Test func pruneKeepsTheNewCheckpointWhateverItsTime() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        // An hour ahead of the store's clock: the three look newer than the one taken now.
        let ahead = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) + 3600)
        for name in ["b1", "c2", "d3"] {
            #expect(await f.checkpoint(name).ok)
            try f.setCreatedAt(name, ahead)
        }
        let answer = await f.checkpoint("a-new")
        #expect(answer.ok)
        let names = try f.agentNames()
        #expect(names.count == 3)
        #expect(names.contains("a-new"))
        #expect(names.sorted() == ["a-new", "c2", "d3"])
    }

    @Test func failedCheckpointPrunesNothing() async throws {
        let env = try Env()
        do {
            let f = try Fixture(env: env)
            for name in ["a1", "a2", "a3"] { #expect(await f.checkpoint(name).ok) }
            f.lock.release()
        }
        // No room for the VM's memory: the space check refuses the fourth.
        let f = try Fixture(env: env, store: env.store(capacity: 1 << 20))
        defer { f.cleanup() }
        let answer = await f.checkpoint("a4")
        #expect(answer.ok == false)
        #expect(answer.error == .internalError)
        #expect(answer.message?.isEmpty == false)
        #expect(try f.agentNames() == ["a1", "a2", "a3"])
        #expect(!env.entries(env.bundle.snapshotsURL).contains { $0.hasSuffix(".partial") })
        #expect(f.session.calls.isEmpty)
        #expect(!f.coordinator.isBusy)
    }

    /// The VM stops between the coordinator's check and the store's: the store takes a cold
    /// snapshot (no memory), which is no checkpoint. It goes, and nothing is pruned.
    @Test func coldCheckpointIsUndone() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        for name in ["a1", "a2", "a3"] { #expect(await f.checkpoint(name).ok) }
        let saver = ScriptedSaver(bundle: f.env.bundle)
        saver.stopsAfterFirstRead = true
        f.owner.liveStateSaver = saver
        // Stopped in the app: its lock is released.
        f.lock.release()
        let answer = await f.checkpoint("cold")
        #expect(answer.ok == false)
        #expect(answer.error == .notRunning)
        #expect(answer.message == NidoError.notRunning("vm").localizedDescription)
        #expect(answer.checkpoint == nil)
        #expect(saver.calls.isEmpty)
        #expect(try f.agentNames() == ["a1", "a2", "a3"])
        #expect(try f.env.store().list().count == 3)
        #expect(!f.env.entries(f.env.bundle.snapshotsURL).contains { $0.hasPrefix(".") })
        #expect(BundleLock.holder(f.env.bundle) == nil)
        #expect(!f.coordinator.isBusy)
    }

    // MARK: - checkpoints

    @Test func listShowsAgentOnlyNewestFirst() async throws {
        let env = try Env()
        _ = try await env.store().create(name: "user", owner: .cli, session: nil)
        let f = try Fixture(env: env)
        defer { f.cleanup() }
        #expect(await f.checkpoint("a1").ok)
        #expect(await f.checkpoint("a2").ok)
        let answer = await f.coordinator.checkpoints()
        #expect(answer.ok)
        let snapshots = try env.store().list()
        let expected = snapshots.filter(\.isAgentCheckpoint).reversed()
            .map { AgentCheckpointInfo(name: $0.name, createdAt: $0.createdAt) }
        #expect(answer.checkpoints == expected)
        #expect(answer.checkpoints?.map(\.name) == ["a2", "a1"])
        // None yet: an empty list, not a failure.
        let empty = try Fixture()
        defer { empty.cleanup() }
        #expect(await empty.coordinator.checkpoints().checkpoints == [])
    }

    /// The gate's view of the coordinator: the same answers, reached from any actor.
    @Test func handlerForwardsToTheCoordinator() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let handler: any AgentCheckpointHandling = MainActorCheckpointHandler(f.coordinator)
        let taken = await Task.detached { await handler.checkpoint(name: "h1") }.value
        #expect(taken.ok)
        #expect(taken.checkpoint?.name == "h1")
        let listed = await Task.detached { await handler.checkpoints() }.value
        #expect(listed.checkpoints?.map(\.name) == ["h1"])
        let refused = await Task.detached { await handler.rollback(name: "nope") }.value
        #expect(refused.error == .badRequest)
    }

    // MARK: - rollback

    @Test func rollbackToNewestByDefault() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        // The newest by time is neither the last taken nor the last by name.
        #expect(await f.checkpoint("a-newest").ok)
        #expect(await f.checkpoint("z-oldest").ok)
        try f.setCreatedAt("a-newest", Self.past(hours: 2))
        try f.setCreatedAt("z-oldest", Self.past(hours: 1))
        let newest = try f.env.store().find("a-newest")
        let answer = await f.coordinator.rollback(name: nil)
        #expect(answer.ok)
        #expect(answer.message == L10n.string(
            "going back to \("a-newest"): the VM restarts from that moment; wait about 20 seconds, then take a screenshot"))
        #expect(L10n.string(
            "going back to \("a-newest"): the VM restarts from that moment; wait about 20 seconds, then take a screenshot",
            language: "en")
            == "going back to a-newest: the VM restarts from that moment; wait about 20 seconds, then take a screenshot")
        // The answer names the target (the activity log records it).
        #expect(answer.checkpoint == AgentCheckpointInfo(name: "a-newest", createdAt: newest.createdAt))
        #expect(f.coordinator.isBusy)
        await f.coordinator.rollbackTask?.value
        #expect(f.owner.calls == ["stop", "restore \(newest.id.uuidString)", "start", "end"])
        #expect(f.owner.endings.count == 1)
        #expect(f.owner.endings.first?.target == "a-newest")
        #expect(f.owner.endings.first?.error == nil)
        #expect(f.owner.loggedAtEnd == ["rollbackEnd"])
        #expect(!f.coordinator.isBusy)
        let entry = try #require(try AgentActivityLog.read(in: f.env.bundle, limit: nil).last)
        #expect(entry.op == "rollbackEnd")
        #expect(entry.detail == ["name": "a-newest"])
        #expect(entry.ok)
        #expect(entry.error == nil)
        #expect(entry.client == "nido")
    }

    @Test func rollbackToANamedCheckpoint() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        #expect(await f.checkpoint("a1").ok)
        #expect(await f.checkpoint("a2").ok)
        let first = try f.env.store().find("a1")
        #expect(await f.coordinator.rollback(name: "A1").ok)
        await f.coordinator.rollbackTask?.value
        #expect(f.owner.calls == ["stop", "restore \(first.id.uuidString)", "start", "end"])
        #expect(f.owner.endings.first?.target == "a1")
    }

    @Test func rollbackUnknownName() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        #expect(await f.checkpoint("a1").ok)
        let answer = await f.coordinator.rollback(name: "nope")
        #expect(answer.ok == false)
        #expect(answer.error == .badRequest)
        #expect(answer.message == L10n.string("no agent checkpoint named \("nope")"))
        #expect(L10n.string("no agent checkpoint named \("nope")", language: "en") == "no agent checkpoint named nope")
        #expect(f.coordinator.rollbackTask == nil)
        #expect(f.owner.calls.isEmpty)
        #expect(!f.coordinator.isBusy)
    }

    @Test func rollbackWithoutCheckpoints() async throws {
        let env = try Env()
        _ = try await env.store().create(name: "user", owner: .cli, session: nil)
        let f = try Fixture(env: env)
        defer { f.cleanup() }
        for name in [nil, "user"] as [String?] {
            let answer = await f.coordinator.rollback(name: name)
            #expect(answer.ok == false)
            #expect(answer.error == .badRequest)
            #expect(answer.message == L10n.string("no agent checkpoint: take one with checkpoint first"))
        }
        #expect(L10n.string("no agent checkpoint: take one with checkpoint first", language: "en")
            == "no agent checkpoint: take one with checkpoint first")
        #expect(f.owner.calls.isEmpty)
    }

    @Test func rollbackRefusesUserSnapshot() async throws {
        let env = try Env()
        let user = try await env.store().create(name: "user", owner: .cli, session: nil)
        let f = try Fixture(env: env)
        defer { f.cleanup() }
        #expect(await f.checkpoint("a1").ok)
        // A user's snapshot by name or id, and an agent checkpoint by id: only names are matched.
        let agentID = try env.store().find("a1").id.uuidString
        for reference in ["user", user.id.uuidString, agentID] {
            let answer = await f.coordinator.rollback(name: reference)
            #expect(answer.error == .badRequest)
            #expect(answer.message == L10n.string("no agent checkpoint named \(reference)"))
        }
        #expect(f.owner.calls.isEmpty)
    }

    @Test func busyRefusesSecond() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        #expect(await f.checkpoint("a1").ok)
        f.owner.holdStop = true
        #expect(await f.coordinator.rollback(name: nil).ok)
        while !f.owner.isHoldingStop { await Task.yield() }
        let busy = L10n.string("a checkpoint or rollback is in progress")
        #expect(L10n.string("a checkpoint or rollback is in progress", language: "en")
            == "a checkpoint or rollback is in progress")
        for answer in [await f.checkpoint("a2"), await f.coordinator.rollback(name: nil)] {
            #expect(answer.ok == false)
            #expect(answer.error == .notReady)
            #expect(answer.message == busy)
        }
        // Listing is not an operation: it answers meanwhile.
        #expect(await f.coordinator.checkpoints().ok)
        f.owner.releaseStop()
        await f.coordinator.rollbackTask?.value
        #expect(!f.coordinator.isBusy)
        #expect(await f.checkpoint("a2").ok)
        f.owner.holdStop = false
        #expect(await f.coordinator.rollback(name: nil).ok)
        await f.coordinator.rollbackTask?.value
        #expect(f.owner.endings.map(\.target) == ["a1", "a2"])
    }

    @Test func rollbackRefusedWhileACheckpointRuns() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        #expect(await f.checkpoint("a1").ok)
        let saver = ScriptedSaver(bundle: f.env.bundle)
        saver.holdPause = true
        f.owner.liveStateSaver = saver
        let coordinator = f.coordinator
        let pending = Task { await coordinator.checkpoint(name: "a2") }
        while !saver.isHoldingPause { await Task.yield() }
        #expect(coordinator.isBusy)
        let answer = await coordinator.rollback(name: nil)
        #expect(answer.ok == false)
        #expect(answer.error == .notReady)
        #expect(answer.message == L10n.string("a checkpoint or rollback is in progress"))
        #expect(coordinator.rollbackTask == nil)
        #expect(f.owner.calls.isEmpty)
        saver.releasePause()
        #expect(await pending.value.ok)
        #expect(saver.calls == ["pause", "save", "resume"])
        #expect(!coordinator.isBusy)
        #expect(try f.agentNames().sorted() == ["a1", "a2"])
    }

    @Test func rollbackRestoreFails() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        #expect(await f.checkpoint("a1").ok)
        let id = try f.env.store().find("a1").id
        f.owner.restoreError = NidoError.restoreFailed("disk")
        #expect(await f.coordinator.rollback(name: nil).ok)
        await f.coordinator.rollbackTask?.value
        #expect(f.owner.calls == ["stop", "restore \(id.uuidString)", "end"])
        #expect(f.owner.endings.first?.error == "\(NidoError.restoreFailed("disk"))")
        #expect(f.owner.loggedAtEnd == ["rollbackEnd"])
        #expect(!f.coordinator.isBusy)
        let entry = try #require(try AgentActivityLog.read(in: f.env.bundle, limit: nil).last)
        #expect(entry.op == "rollbackEnd")
        #expect(entry.detail == ["name": "a1"])
        #expect(entry.ok == false)
        #expect(entry.error == AgentErrorCode.internalError.rawValue)
        #expect(entry.message == NidoError.restoreFailed("disk").localizedDescription)
    }

    // MARK: - Refusals

    @Test func templateRefused() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        #expect(await f.checkpoint("a1").ok)
        _ = try f.env.bundle.updateConfig { $0.isTemplate = true }
        let text = L10n.string("\("vm") is a template: checkpoints are not available")
        #expect(L10n.string("\("vm") is a template: checkpoints are not available", language: "en")
            == "vm is a template: checkpoints are not available")
        for answer in [await f.checkpoint("a2"), await f.coordinator.rollback(name: nil)] {
            #expect(answer.ok == false)
            #expect(answer.error == .badRequest)
            #expect(answer.message == text)
        }
        #expect(try f.agentNames() == ["a1"])
        #expect(f.owner.calls.isEmpty)
    }

    @Test func noLiveSessionRefused() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        #expect(await f.checkpoint("a1").ok)
        f.owner.liveStateSaver = nil
        let text = NidoError.notRunning("vm").localizedDescription
        for answer in [await f.checkpoint("a2"), await f.coordinator.rollback(name: nil)] {
            #expect(answer.ok == false)
            #expect(answer.error == .notRunning)
            #expect(answer.message == text)
        }
        // A session that is no longer running is no live session either.
        f.owner.liveStateSaver = f.session
        f.session.state = .stopped
        #expect(await f.checkpoint("a2").error == .notRunning)
        #expect(try f.agentNames() == ["a1"])
        #expect(f.owner.calls.isEmpty)
    }

    @Test func unsupportedConfigurationAnswersTheStoresMessage() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        f.session.unsupportedReason = "a device that can’t be saved"
        let answer = await f.checkpoint("a1")
        #expect(answer.ok == false)
        #expect(answer.error == .badRequest)
        #expect(answer.message == NidoError.snapshotUnsupported("a device that can’t be saved").localizedDescription)
        #expect(try f.agentNames().isEmpty)
    }

    @Test func answersCarryCheckpointsOnlyWhenSet() throws {
        let info = AgentCheckpointInfo(name: "a1", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let answer = AgentAnswer(ok: true, checkpoints: [info], checkpoint: info)
        let data = try JSONEncoder().encode(answer)
        #expect(try JSONDecoder().decode(AgentAnswer.self, from: data) == answer)
        let plain = String(decoding: try JSONEncoder().encode(AgentAnswer(ok: true)), as: UTF8.self)
        #expect(!plain.contains("checkpoint"))
    }
}
