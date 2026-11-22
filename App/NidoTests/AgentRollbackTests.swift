// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore
import Testing

@testable import Nido

/// A macOS VM with agent access on and the files a snapshot clones and restores (disk, auxiliary
/// storage, hardware model, identifier).
final class AgentMacRoot {
    let paths: NidoPaths
    let bundle: VMBundle

    init() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-rollback-\(UUID().uuidString)", isDirectory: true)
        paths = NidoPaths(root: url)
        let config = VMConfig(
            id: UUID(), name: try VMName("mac"), guest: .macos, cpuCount: 2, memoryBytes: 1 << 30,
            diskBytes: 1 << 20, macAddress: "02:00:00:00:00:01", agentAccess: true)
        bundle = try VMBundle.create(config: config, paths: paths)
        try write("disk-v1", to: bundle.diskURL)
        try write("machine-id", to: bundle.machineIdentifierURL)
        try write("aux-v1", to: bundle.auxiliaryStorageURL)
        try write("hardware-model", to: bundle.hardwareModelURL)
    }

    deinit { try? FileManager.default.removeItem(at: paths.root) }

    func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    var disk: String? { (try? Data(contentsOf: bundle.diskURL)).map { String(decoding: $0, as: UTF8.self) } }

    /// The activity log's last entry (the rollback's end once it is over).
    var lastActivity: AgentActivityEntry? { (try? AgentActivityLog.read(in: bundle, limit: nil))?.last }
}

/// Nido.app as the owner of an agent's checkpoints (`VMWindowModel` as `AgentRollbackOwner`): a
/// rollback stops the VM (forced), restores the checkpoint and starts it again in the same window.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AgentRollbackTests {
    private func running(_ root: AgentMacRoot, _ factory: FakeSessionFactory = FakeSessionFactory())
        async throws -> (VMWindowModel, FakeSession, any AgentCheckpointHandling)
    {
        let model = VMWindowModel(
            name: try VMName("mac"), paths: root.paths, factory: factory, passwords: MemoryGuestPasswordStore(),
            agentHoldSleep: { _ in }, firstRunSetup: { _, _, _ in true }, rollbackGrace: .zero)
        await model.start()
        #expect(model.state == .running)
        let session = try #require(factory.made.first)
        let handler = try #require(session.checkpointHandling, "a macOS VM with agent access gets checkpoints")
        return (model, session, handler)
    }

    /// Polls `condition` on the main actor (the store's work runs off it).
    private func waitUntil(_ what: String, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<2000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out waiting for \(what)")
    }

    /// The agent goes back to its checkpoint: the session stops (forced, no suspend), the disk is
    /// the checkpoint's again, and a new session runs, served with the same checkpoint handling.
    @Test func rollbackRestoresTheCheckpointAndRunsAgain() async throws {
        let root = try AgentMacRoot()
        let factory = FakeSessionFactory()
        let (model, first, handler) = try await running(root, factory)
        let taken = await handler.checkpoint(name: "before")
        #expect(taken.ok, "\(taken.message ?? "")")
        #expect(first.events == ["pause", "save", "resume"])
        try root.write("disk-v2", to: root.bundle.diskURL)

        first.holdsStop = true
        let answer = await handler.rollback(name: nil)
        #expect(answer.ok, "\(answer.message ?? "")")
        #expect(answer.checkpoint?.name == "before")
        #expect(model.rollbackBanner == String(localized: "The agent is going back to \("before")…"))
        #expect(model.agentActive, "an agent is using this VM while it goes back")

        try await waitUntil("the forced stop") { first.state == .stopping }
        #expect(model.state == .stopping)
        #expect(first.stopGracePeriods == [.zero], "forced: the guest is not asked to shut down")
        #expect(first.suspendCount == 0)
        #expect(model.rollbackBanner != nil)
        first.finishStop()

        try await waitUntil("the rollback's end") { model.rollbackBanner == nil }
        #expect(root.disk == "disk-v1", "the checkpoint's disk is back")
        #expect(model.state == .running)
        #expect(model.errorDetail == nil)
        #expect(factory.made.count == 2)
        let second = try #require(factory.made.last)
        #expect(second.state == .running)
        #expect((second.checkpointHandling as AnyObject?) === (handler as AnyObject),
                "one coordinator per window: the new session's agent socket gets the same handling")
        #expect(!model.agentActive)
        let end = try #require(root.lastActivity)
        #expect(end.op == "rollbackEnd")
        #expect(end.ok)
        await model.stop()
    }

    /// The restore fails: the VM stays stopped and the window shows why; no new session.
    @Test func failedRollbackLeavesTheVMStoppedWithTheError() async throws {
        let root = try AgentMacRoot()
        let factory = FakeSessionFactory()
        let (model, first, handler) = try await running(root, factory)
        let taken = await handler.checkpoint(name: "before")
        #expect(taken.ok, "\(taken.message ?? "")")
        let snapshot = try #require(try SnapshotStore(bundle: root.bundle).list().first)
        try root.write("disk-v2", to: root.bundle.diskURL)

        first.holdsStop = true
        #expect(await handler.rollback(name: "before").ok)
        try await waitUntil("the forced stop") { first.state == .stopping }
        // The checkpoint goes while the VM stops: the restore cannot find it.
        try FileManager.default.removeItem(
            at: root.bundle.snapshotsURL.appendingPathComponent(snapshot.id.uuidString))
        first.finishStop()

        try await waitUntil("the rollback's end") { model.rollbackBanner == nil }
        #expect(model.isGone, "the VM is stopped")
        guard case .error(let text) = model.state else {
            Issue.record("expected the error screen, got \(model.state)")
            return
        }
        #expect(!text.isEmpty)
        #expect(model.errorTitle == String(localized: "The agent couldn’t go back to \("before")"))
        #expect(model.errorDetail != nil)
        #expect(factory.made.count == 1, "nothing started again")
        #expect(root.disk == "disk-v2")
        #expect(BundleLock.holder(root.bundle) == nil)
        let end = try #require(root.lastActivity)
        #expect(end.op == "rollbackEnd")
        #expect(!end.ok)
    }

    /// A user's Suspend wins: while it runs no checkpoint is taken and no rollback starts.
    @Test func aUserSuspendWinsOverTheAgent() async throws {
        let root = try AgentMacRoot()
        let factory = FakeSessionFactory()
        let (model, first, handler) = try await running(root, factory)
        #expect(model.liveStateSaver != nil)
        #expect(await handler.checkpoint(name: "before").ok)

        first.holdsSuspend = true
        let suspending = Task { await model.suspend() }
        try await waitUntil("the suspend") { model.isSuspending }
        #expect(model.liveStateSaver == nil)
        await #expect(throws: (any Error).self) { try await model.stopForRollback() }
        let rollback = await handler.rollback(name: nil)
        #expect(!rollback.ok)
        #expect(rollback.error == .notRunning)
        #expect(model.rollbackBanner == nil)
        let checkpoint = Task { await handler.checkpoint(name: "during") }

        first.finishSuspend()
        #expect(await suspending.value)
        let late = await checkpoint.value
        #expect(!late.ok, "the VM was suspended meanwhile")
        #expect(model.state == .stopped)
        #expect(model.isSuspended)
        #expect(first.stopGracePeriods.isEmpty, "the rollback never stopped it")
        #expect(try SnapshotStore(bundle: root.bundle).list().map(\.name) == ["before"])
    }

    /// A user's Stop during a rollback wins: nothing is restored or started after it.
    @Test func aUserStopDuringARollbackWins() async throws {
        let root = try AgentMacRoot()
        let factory = FakeSessionFactory()
        let (model, first, handler) = try await running(root, factory)
        #expect(await handler.checkpoint(name: "before").ok)
        try root.write("disk-v2", to: root.bundle.diskURL)

        first.holdsStop = true
        #expect(await handler.rollback(name: nil).ok)
        try await waitUntil("the forced stop") { first.state == .stopping }
        let stopping = Task { await model.stop() }
        await Task.yield()
        first.finishStop()
        await stopping.value

        try await waitUntil("the rollback's end") { model.rollbackBanner == nil }
        #expect(model.state == .stopped)
        #expect(model.errorDetail == nil, "the user's stop is no failure")
        #expect(factory.made.count == 1)
        #expect(root.disk == "disk-v2", "nothing restored after the user's stop")
    }

    /// While a checkpoint is being taken the window says an agent is using the VM; another
    /// checkpoint or a rollback meanwhile is refused as busy.
    @Test func checkpointShowsTheAgentAndRefusesASecond() async throws {
        let root = try AgentMacRoot()
        let factory = FakeSessionFactory()
        let (model, first, handler) = try await running(root, factory)
        first.holdsSave = true
        let taking = Task { await handler.checkpoint(name: "before") }
        try await waitUntil("the save") { first.isSaving }
        #expect(model.agentActive)
        let second = await handler.checkpoint(name: "again")
        #expect(second.error == .notReady)
        let rollback = await handler.rollback(name: nil)
        #expect(rollback.error == .notReady)
        first.finishSave()
        #expect(await taking.value.ok)
        #expect(!model.agentActive)
        await model.stop()
    }

    /// The user's Start between the rollback's stop and its restart (the VM looks stopped): it
    /// waits for the rollback, which starts the VM itself. Neither a VM booted without the
    /// checkpoint (its restore would fail) nor a second start racing the rollback's.
    @Test func aUserStartDuringARollbackWaitsForIt() async throws {
        let root = try AgentMacRoot()
        let factory = FakeSessionFactory()
        let (model, first, handler) = try await running(root, factory)
        #expect(await handler.checkpoint(name: "before").ok)
        let checkpoint = try #require(try SnapshotStore(bundle: root.bundle).list().first)
        try root.write("disk-v2", to: root.bundle.diskURL)

        // The owner's steps one by one, the user's Start in each gap.
        try await model.stopForRollback()
        #expect(first.stopGracePeriods == [.zero])
        #expect(model.isGone)
        let beforeRestore = Task { await model.start() }
        for _ in 0..<20 { await Task.yield() }
        #expect(factory.made.count == 1, "nothing boots before the restore")
        #expect(model.state == .stopped)

        try await model.restoreForRollback(checkpoint.id)
        #expect(root.disk == "disk-v1")
        let afterRestore = Task { await model.start() }
        for _ in 0..<20 { await Task.yield() }
        #expect(factory.made.count == 1, "the rollback starts the VM itself")

        try await model.startAfterRollback()
        #expect(model.state == .running)
        #expect(factory.made.count == 2)
        model.rollbackDidEnd(target: "before", error: nil)
        await beforeRestore.value
        await afterRestore.value
        #expect(factory.made.count == 2, "the user's Starts found the VM running")
        #expect(model.state == .running)
        #expect(model.errorDetail == nil)
        #expect(root.disk == "disk-v1")
        await model.stop()
    }

    /// The rollback fails after the user's Start in its gap: the window shows why (its Retry
    /// starts the VM), the waiting Start boots nothing over it.
    @Test func aUserStartDuringAFailedRollbackLeavesTheError() async throws {
        let root = try AgentMacRoot()
        let factory = FakeSessionFactory()
        let (model, _, handler) = try await running(root, factory)
        #expect(await handler.checkpoint(name: "before").ok)

        try await model.stopForRollback()
        let starting = Task { await model.start() }
        for _ in 0..<20 { await Task.yield() }
        #expect(factory.made.count == 1)
        let failure = await #expect(throws: (any Error).self) { try await model.restoreForRollback(UUID()) }
        model.rollbackDidEnd(target: "before", error: failure ?? NidoError.notRunning("mac"))
        await starting.value
        #expect(factory.made.count == 1, "nothing started over the failed rollback")
        guard case .error = model.state else {
            Issue.record("expected the error screen, got \(model.state)")
            return
        }
        #expect(model.errorTitle == String(localized: "The agent couldn’t go back to \("before")"))
    }

    /// The user stopped the VM during the rollback, then asked to start it: the rollback goes no
    /// further, and once it ended the VM starts as asked last. A Stop after the Start wins.
    @Test func theUsersLastWordDuringARollbackCounts() async throws {
        let root = try AgentMacRoot()
        let factory = FakeSessionFactory()
        let (model, _, handler) = try await running(root, factory)
        #expect(await handler.checkpoint(name: "before").ok)
        let checkpoint = try #require(try SnapshotStore(bundle: root.bundle).list().first)

        // Stop, then Start.
        try await model.stopForRollback()
        await model.stop()
        let starting = Task { await model.start() }
        for _ in 0..<20 { await Task.yield() }
        await #expect(throws: (any Error).self) { try await model.restoreForRollback(checkpoint.id) }
        model.rollbackDidEnd(target: "before", error: NidoError.notRunning("mac"))
        await starting.value
        #expect(factory.made.count == 2, "started as the user asked last")
        #expect(model.state == .running)

        // Start, then Stop.
        try await model.stopForRollback()
        let ignored = Task { await model.start() }
        for _ in 0..<20 { await Task.yield() }
        await model.stop()
        model.rollbackDidEnd(target: "before", error: NidoError.notRunning("mac"))
        await ignored.value
        #expect(factory.made.count == 2, "the later Stop wins")
        #expect(model.state == .stopped)
    }

    /// Between the rollback's stop and its restart the VM is gone, but the window's model must
    /// stay in the store: closing the window (or the VM's deletion) then forgets nothing.
    @Test func theStoreKeepsAModelThatRollsBack() async throws {
        let root = try AgentMacRoot()
        let store = VMSessionStore(paths: root.paths, factory: FakeSessionFactory(), passwords: MemoryGuestPasswordStore())
        let name = try VMName("mac")
        let model = store.model(for: name)
        await model.start()
        try await model.stopForRollback()
        #expect(model.isGone)
        store.windowClosed(name)
        store.forget(name)
        #expect(store.model(for: name) === model, "the rollback starts the VM again in this model")
        model.rollbackDidEnd(target: "before", error: nil)
        store.windowClosed(name)
        #expect(store.model(for: name) !== model)
    }

    /// The snapshots window marks the agent's checkpoints ("Agent"); the user's are unmarked.
    @Test func snapshotsListMarksAgentCheckpoints() async throws {
        let root = try AgentMacRoot()
        let factory = FakeSessionFactory()
        let (model, _, handler) = try await running(root, factory)
        _ = try await model.createSnapshot(named: "mine")
        #expect(await handler.checkpoint(name: "agent-one").ok)
        let snapshots = SnapshotsModel(window: model, bundle: root.bundle)
        await snapshots.load()
        let marks = Dictionary(uniqueKeysWithValues: snapshots.snapshots.map { ($0.name, snapshots.isAgent($0)) })
        #expect(marks == ["mine": false, "agent-one": true])
        await model.stop()
    }
}
