// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import NidoCore
import Testing

@testable import Nido

/// A VM root with one complete bundle (config, disk, NVRAM, identifier, seed): enough for the
/// snapshot store to clone, restore and delete.
final class SnapshotRoot {
    let paths: NidoPaths
    let bundle: VMBundle

    init(name: String = "debian-13") throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-snapshots-\(UUID().uuidString)", isDirectory: true)
        paths = NidoPaths(root: url)
        let config = VMConfig(
            id: UUID(), name: try VMName(name), guest: .linux, cpuCount: 2,
            memoryBytes: 1 << 30, diskBytes: 1 << 20, macAddress: "52:54:00:12:34:56")
        bundle = try VMBundle.create(config: config, paths: paths)
        try write("disk-v1", to: bundle.diskURL)
        try write("nvram-v1", to: bundle.nvramURL)
        try write("machine-id", to: bundle.machineIdentifierURL)
        try write("seed", to: bundle.seedURL)
    }

    deinit { try? FileManager.default.removeItem(at: paths.root) }

    func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func read(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    var disk: String? { read(bundle.diskURL) }
}

@MainActor
struct SnapshotsModelTests {
    private func models(_ root: SnapshotRoot, _ factory: FakeSessionFactory = FakeSessionFactory())
        -> (VMWindowModel, SnapshotsModel)
    {
        let window = VMWindowModel(name: try! VMName("debian-13"), paths: root.paths, factory: factory)
        return (window, SnapshotsModel(window: window, bundle: root.bundle))
    }

    /// Ripristina only asks: the bundle is untouched until the user confirms the sheet, whose
    /// text names the snapshot's date.
    @Test func restoreAsksConfirmation() async throws {
        let root = try SnapshotRoot()
        let (_, model) = models(root)
        await model.load()
        model.beginCreate()
        await model.confirmCreate()
        #expect(model.snapshots.map(\.name) == ["snapshot-1"])
        try root.write("disk-v2", to: root.bundle.diskURL)

        let snapshot = try #require(model.snapshots.first)
        model.requestRestore(snapshot)
        #expect(model.pendingRestore == snapshot)
        #expect(model.restoreTitle == "Ripristinare snapshot-1?")
        #expect(model.restoreMessage == "La VM tornerà allo stato del "
            + "\(SnapshotsModel.dateText(snapshot.createdAt)); le modifiche successive andranno perse.")
        #expect(root.disk == "disk-v2", "Nessun file toccato prima della conferma")

        model.cancelRestore()
        #expect(model.pendingRestore == nil)
        #expect(root.disk == "disk-v2")

        model.requestRestore(snapshot)
        await model.confirmRestore()
        #expect(model.pendingRestore == nil)
        #expect(model.error == nil)
        #expect(root.disk == "disk-v1")
    }

    @Test func dateTextIsItalian() throws {
        var components = DateComponents(year: 2026, month: 10, day: 24, hour: 10, minute: 42)
        components.timeZone = .current
        let date = try #require(Calendar(identifier: .gregorian).date(from: components))
        #expect(SnapshotsModel.dateText(date) == "24 ott 2026, 10:42")
    }

    /// While the VM runs in this app the snapshot goes through its session: paused, state saved
    /// (the snapshot "con stato salvato"), resumed.
    @Test func createWhileRunningUsesSession() async throws {
        let root = try SnapshotRoot()
        let factory = FakeSessionFactory()
        let (window, model) = models(root, factory)
        await window.start()
        #expect(window.state == .running)
        let session = try #require(factory.made.first)

        await model.load()
        model.beginCreate()
        #expect(model.newName == "snapshot-1")
        await model.confirmCreate()

        #expect(model.error == nil)
        #expect(session.events == ["pause", "save", "resume"])
        #expect(window.state == .running)
        let snapshot = try #require(model.snapshots.first)
        #expect(snapshot.hasSavedState)
        await window.stop()
    }

    /// Stopped: the bundle is cloned under the app's lock, without a session.
    @Test func createWhileStoppedClonesTheBundle() async throws {
        let root = try SnapshotRoot()
        let (window, model) = models(root)
        await model.load()
        model.beginCreate()
        await model.confirmCreate()
        #expect(model.snapshots.count == 1)
        #expect(model.snapshots.first?.hasSavedState == false)
        #expect(window.state == .stopped)
        #expect(BundleLock.holder(root.bundle) == nil, "Lock rilasciato")
    }

    @Test func defaultNameSkipsTakenNames() {
        #expect(SnapshotsModel.defaultName(taken: []) == "snapshot-1")
        #expect(SnapshotsModel.defaultName(taken: ["snapshot-1", "Snapshot-2"]) == "snapshot-3")
        #expect(SnapshotsModel.defaultName(taken: ["prima"]) == "snapshot-1")
    }

    /// A live snapshot and a suspend both pause the VM and save its state: they never overlap.
    /// The suspend asked while the snapshot is saving waits for it, then suspends.
    @Test func liveSnapshotAndSuspendAreSerialised() async throws {
        let root = try SnapshotRoot()
        let factory = FakeSessionFactory()
        factory.configure = { $0.holdsSave = true }
        let (window, model) = models(root, factory)
        await window.start()
        let session = try #require(factory.made.first)
        await model.load()
        model.beginCreate()

        let create = Task { await model.confirmCreate() }
        for _ in 0..<500 where !session.isSaving { try await Task.sleep(for: .milliseconds(5)) }
        #expect(session.isSaving)
        #expect(window.isSnapshotting)

        let suspend = Task { await window.suspend() }
        for _ in 0..<20 { await Task.yield() }
        #expect(session.suspendCount == 0, "La sospensione aspetta lo snapshot")
        #expect(session.events == ["pause", "save"])

        session.finishSave()
        await create.value
        #expect(await suspend.value)
        #expect(session.events == ["pause", "save", "resume", "suspend"])
        #expect(model.snapshots.count == 1)
        #expect(window.state == .stopped)
        #expect(window.isSuspended)
    }

    /// A VM running in this app is never restored or deleted: refused with an Italian message,
    /// nothing touched.
    @Test func restoreRefusedWhileRunning() async throws {
        let root = try SnapshotRoot()
        let factory = FakeSessionFactory()
        let (window, model) = models(root, factory)
        await model.load()
        model.beginCreate()
        await model.confirmCreate()
        try root.write("disk-v2", to: root.bundle.diskURL)
        await window.start()
        #expect(!model.canRestore)

        let snapshot = try #require(model.snapshots.first)
        model.requestRestore(snapshot)
        await model.confirmRestore()
        #expect(model.error == "Per ripristinare uno snapshot arresta prima debian-13.")
        #expect(root.disk == "disk-v2")
        await window.stop()
    }

    /// A restored snapshot with its saved state makes the VM "Sospesa" (Riprendi resumes it).
    @Test func restoringSavedStateMakesTheVMSuspended() async throws {
        let root = try SnapshotRoot()
        let factory = FakeSessionFactory()
        let (window, model) = models(root, factory)
        await window.start()
        await model.load()
        model.beginCreate()
        await model.confirmCreate()
        await window.stop()
        #expect(!window.isSuspended)

        let snapshot = try #require(model.snapshots.first)
        #expect(snapshot.hasSavedState)
        model.requestRestore(snapshot)
        await model.confirmRestore()
        #expect(model.error == nil)
        #expect(window.isSuspended)
        #expect(window.stoppedTitle == "debian-13 è sospesa")
    }

    @Test func deleteAsksConfirmation() async throws {
        let root = try SnapshotRoot()
        let (_, model) = models(root)
        await model.load()
        model.beginCreate()
        await model.confirmCreate()
        let snapshot = try #require(model.snapshots.first)

        model.requestDelete(snapshot)
        #expect(model.deleteTitle == "Eliminare snapshot-1?")
        #expect(model.snapshots.count == 1)
        await model.confirmDelete()
        #expect(model.snapshots.isEmpty)
        #expect(model.pendingDelete == nil)
    }

    @Test func deleteRefusedWhileRunning() async throws {
        let root = try SnapshotRoot()
        let (window, model) = models(root)
        await model.load()
        model.beginCreate()
        await model.confirmCreate()
        await window.start()
        #expect(!model.canDelete)
        #expect(model.deleteLockedNote == "Per eliminare uno snapshot arresta prima debian-13.")
        #expect(model.lockedNote == "Per ripristinare uno snapshot arresta prima debian-13.")

        let snapshot = try #require(model.snapshots.first)
        model.requestDelete(snapshot)
        await model.confirmDelete()
        #expect(model.error == "Per eliminare uno snapshot arresta prima debian-13.")
        #expect(model.snapshots.count == 1)
        await window.stop()
    }

    /// Arresta during a live snapshot: honoured once the snapshot is done (it resumes the VM).
    @Test func stopDuringLiveSnapshotWaitsForIt() async throws {
        let root = try SnapshotRoot()
        let factory = FakeSessionFactory()
        factory.configure = { $0.holdsSave = true }
        let (window, model) = models(root, factory)
        await window.start()
        let session = try #require(factory.made.first)
        await model.load()
        model.beginCreate()
        let create = Task { await model.confirmCreate() }
        for _ in 0..<500 where !session.isSaving { try await Task.sleep(for: .milliseconds(5)) }

        let stop = Task { await window.stop() }
        for _ in 0..<20 { await Task.yield() }
        #expect(session.state == .paused, "L'arresto aspetta lo snapshot")

        session.finishSave()
        await create.value
        await stop.value
        #expect(session.events == ["pause", "save", "resume"])
        #expect(window.state == .stopped)
        #expect(model.snapshots.count == 1)
    }

    /// Avvia while a stopped VM's snapshot holds the bundle: the start waits, then runs.
    @Test func startWaitsForStoppedSnapshotWork() async throws {
        let root = try SnapshotRoot()
        let factory = FakeSessionFactory()
        let (window, _) = models(root, factory)
        let gate = Gate()
        let work = Task { try await window.exclusive { await gate.wait() } }
        for _ in 0..<20 { await Task.yield() }
        #expect(window.isSnapshotting)

        let start = Task { await window.start() }
        for _ in 0..<20 { await Task.yield() }
        #expect(window.state == .stopped, "L'avvio aspetta lo snapshot")
        #expect(factory.made.isEmpty)

        gate.open()
        try await work.value
        await start.value
        #expect(window.state == .running)
        await window.stop()
    }

    /// Quitting waits for snapshot work on a stopped VM (not a "live" model), and refuses new work.
    @Test func quitWaitsForSnapshotWork() async throws {
        let root = try SnapshotRoot()
        let sessions = VMSessionStore(paths: root.paths, factory: FakeSessionFactory())
        let window = sessions.model(for: try VMName("debian-13"))
        let gate = Gate()
        let work = Task { try await window.exclusive { await gate.wait() } }
        for _ in 0..<20 { await Task.yield() }
        #expect(sessions.liveModels.isEmpty)
        #expect(sessions.snapshotBusyNames == ["debian-13"])

        sessions.beginQuit()
        var waited = false
        let wait = Task {
            await sessions.waitForSnapshots()
            waited = true
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(!waited, "L'uscita aspetta lo snapshot")
        await #expect(throws: VMWindowModel.QuittingError.self) {
            _ = try await window.createSnapshot(named: "dopo")
        }

        gate.open()
        try await work.value
        await wait.value
        #expect(waited)
        #expect(sessions.snapshotBusyNames.isEmpty)
    }

    /// The snapshots window keeps the VM's model: closing the VM window and opening it again
    /// gives the same model, so a live snapshot from S09 goes through the running session.
    @Test func snapshotsWindowFollowsTheVMModel() async throws {
        let root = try SnapshotRoot()
        let factory = FakeSessionFactory()
        let sessions = VMSessionStore(paths: root.paths, factory: factory)
        let name = try VMName("debian-13")
        let window = sessions.snapshotsWindowOpened(name)
        let model = SnapshotsModel(window: window, bundle: root.bundle)

        sessions.windowClosed(name)  // the VM window of a stopped VM closes
        #expect(sessions.model(for: name) === window)
        await sessions.model(for: name).start()
        #expect(model.runsInApp)

        await model.load()
        model.beginCreate()
        await model.confirmCreate()
        #expect(model.error == nil)
        #expect(model.snapshots.first?.hasSavedState == true)
        #expect(factory.made.first?.events == ["pause", "save", "resume"])
        await window.stop()

        sessions.snapshotsWindowClosed(name)
        sessions.windowClosed(name)
        #expect(sessions.model(for: name) !== window)
    }

    /// Another process holds the VM: the subtitle says which.
    @Test func holderOwnerNamesTheOtherProcess() async throws {
        let root = try SnapshotRoot()
        let (_, model) = models(root)
        let cli = try BundleLock.acquire(root.bundle, owner: .cli)
        await model.load()
        #expect(model.runsElsewhere)
        #expect(model.subtitle == "Nessuno snapshot · debian-13 in esecuzione nel Terminale")
        cli.release()
        let app = try BundleLock.acquire(root.bundle, owner: .app)
        model.refreshHolder()
        #expect(model.subtitle == "Nessuno snapshot · debian-13 aperta in un'altra copia di Nido")
        app.release()
        let operation = try BundleLock.acquire(root.bundle, owner: .cliOperation)
        model.refreshHolder()
        #expect(model.subtitle == "Nessuno snapshot · debian-13 occupata da un comando nido nel Terminale")
        operation.release()
        model.refreshHolder()
        #expect(!model.runsElsewhere)
    }

    /// A restore clears the error screen of a failed start: the VM is now the snapshot's.
    @Test func restoreClearsTheErrorScreen() async throws {
        let root = try SnapshotRoot()
        let factory = FakeSessionFactory()
        let (window, model) = models(root, factory)
        await model.load()
        model.beginCreate()
        await model.confirmCreate()
        factory.error = .notRunning("disco")
        await window.start()
        guard case .error = window.state else {
            Issue.record("atteso errore, stato \(window.state)")
            return
        }
        let snapshot = try #require(model.snapshots.first)
        model.requestRestore(snapshot)
        await model.confirmRestore()
        #expect(model.error == nil)
        #expect(window.state == .stopped)
        #expect(window.errorDetail == nil)
        #expect(!window.isSuspended)
    }

    @Test func errorsAreItalian() {
        func text(_ error: NidoError, _ operation: SnapshotsModel.Operation) -> String {
            SnapshotsModel.message(for: error, vm: "debian-13", operation: operation)
        }
        #expect(text(.insufficientSpace(needed: 10 << 30, available: 4 << 30), .create)
            == "Spazio insufficiente: servono 10 GiB, disponibili 4 GiB. Libera spazio sul Mac e riprova.")
        #expect(text(.snapshotUnsupported("dispositivo non salvabile"), .create)
            == "Snapshot a VM accesa non supportato: dispositivo non salvabile. Arresta debian-13 e riprova.")
        #expect(text(.vmMustBeStopped("debian-13"), .restore)
            == "Per ripristinare uno snapshot arresta prima debian-13.")
        #expect(text(.vmMustBeStopped("debian-13"), .delete)
            == "Per eliminare uno snapshot arresta prima debian-13.")
        #expect(text(.runningInAnotherProcess, .restore)
            == "debian-13 è in esecuzione nel Terminale (nido start): arrestala prima.")
        let kept = "/tmp/vm/.disk.img.restore-1.old"
        #expect(text(.restoreIncomplete(kept), .restore).contains(kept))
        #expect(text(.restoreIncomplete(kept), .restore).hasPrefix("Ripristino non riuscito"))
        #expect(text(.restoreLeftovers(["/a/.x.restore-1.old", "/a/.restore-1.commit"]), .create)
            .contains("/a/.x.restore-1.old, /a/.restore-1.commit"))
        #expect(text(.snapshotNameTaken("prima"), .create) == "Esiste già uno snapshot chiamato prima.")
        #expect(text(.invalidSnapshotName("a b"), .create).hasPrefix("Nome di snapshot non valido"))
        #expect(text(.snapshotResumeFailed(snapshot: "s", reason: "x"), .create)
            == "Snapshot s creato, ma la VM non è ripartita: x.")
    }
}

/// A one-shot gate a test opens: `wait` returns once `open` is called.
@MainActor
final class Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

/// R-M3A-21: S09 of a VM suspended before this launch (no session in this app).
@MainActor
struct SnapshotsSuspendedTests {
    /// The bundle as a suspend leaves it.
    private func suspend(_ root: SnapshotRoot) throws {
        try root.write("suspended-state", to: root.bundle.stateURL)
        var config = try root.bundle.readConfig()
        config.suspendedConfigHash = "suspended-hash"
        try root.bundle.writeConfig(config)
    }

    @Test func suspendedBundleShowsSospesa() async throws {
        let root = try SnapshotRoot()
        try suspend(root)
        let window = VMWindowModel(name: try VMName("debian-13"), paths: root.paths, factory: FakeSessionFactory())
        #expect(window.isSuspended)
        let model = SnapshotsModel(window: window, bundle: root.bundle)
        await model.load()
        #expect(model.status == .suspended)
        #expect(model.subtitle.hasSuffix("debian-13 sospesa"))
    }

    /// S09 opened after the VM was suspended elsewhere (the model already existed).
    @Test func loadRereadsTheSuspendedState() async throws {
        let root = try SnapshotRoot()
        let window = VMWindowModel(name: try VMName("debian-13"), paths: root.paths, factory: FakeSessionFactory())
        #expect(!window.isSuspended)
        try suspend(root)
        let model = SnapshotsModel(window: window, bundle: root.bundle)
        await model.load()
        #expect(window.isSuspended)
        #expect(model.status == .suspended)
    }

    @Test func snapshotOfTheSuspendedVMKeepsItsStateAndSaysSo() async throws {
        let root = try SnapshotRoot()
        try suspend(root)
        let window = VMWindowModel(name: try VMName("debian-13"), paths: root.paths, factory: FakeSessionFactory())
        let model = SnapshotsModel(window: window, bundle: root.bundle)
        await model.load()
        model.beginCreate()
        #expect(model.createMessage.contains("stato sospeso"))
        await model.confirmCreate()
        #expect(model.error == nil)
        #expect(model.snapshots.first?.hasSavedState == true)
    }
}

/// R-M3A-25: the cheap minors of S09.
@MainActor
struct SnapshotsMinorTests {
    /// APP m5: Return with an empty name does nothing (the Crea button is disabled).
    @Test func emptyNameIsNotSubmitted() async throws {
        let root = try SnapshotRoot()
        let window = VMWindowModel(name: try VMName("debian-13"), paths: root.paths, factory: FakeSessionFactory())
        let model = SnapshotsModel(window: window, bundle: root.bundle)
        await model.load()
        model.beginCreate()
        model.newName = "   "
        #expect(!model.canConfirmCreate)
        await model.confirmCreate()
        #expect(model.isNaming)
        #expect(model.error == nil)
        #expect(model.snapshots.isEmpty)
    }

    /// CORE m6: restoring a suspended VM loses its saved state too: the sheet says so.
    @Test func restoreMessageOfASuspendedVMMentionsTheSession() async throws {
        let root = try SnapshotRoot()
        let window = VMWindowModel(name: try VMName("debian-13"), paths: root.paths, factory: FakeSessionFactory())
        let model = SnapshotsModel(window: window, bundle: root.bundle)
        await model.load()
        model.beginCreate()
        await model.confirmCreate()
        let snapshot = try #require(model.snapshots.first)
        model.requestRestore(snapshot)
        #expect(!model.restoreMessage.contains("sospesa"))
        try root.write("state", to: root.bundle.stateURL)
        var config = try root.bundle.readConfig()
        config.suspendedConfigHash = "h"
        try root.bundle.writeConfig(config)
        await model.load()
        #expect(model.restoreMessage.hasSuffix("; le modifiche successive e la sessione sospesa di debian-13 andranno perse."))
    }

    /// APP m1: a lock held by this very app (a clone, a snapshot) is not "another process".
    @Test func ownLockIsAnOperationInNido() throws {
        let name = try VMName("debian-13")
        #expect(VMWindowModel.message(for: NidoError.alreadyRunning(pid: getpid()), name: name)
            == "È in corso un'operazione su debian-13 in Nido (clonazione o snapshot): riprova al termine.")
        #expect(VMWindowModel.message(for: NidoError.alreadyRunning(pid: 4242), name: name)
            == "debian-13 è già in esecuzione da un altro processo (pid 4242): arrestala lì prima di aprirla in questa finestra.")
    }
}
