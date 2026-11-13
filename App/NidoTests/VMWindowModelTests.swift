// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import NidoCore
import Testing
import Synchronization
import Virtualization

@testable import Nido

/// A session without a VM: every transition happens at once, as the test asks. It also saves a
/// fake machine state, for the live snapshots of `SnapshotStore` (`stateSaver`).
@MainActor
final class FakeSession: VMSessionHandle, MachineStateSaving {
    var state: VMRunState = .stopped {
        didSet {
            if state == .running { everRan = true }
            if oldValue != state { onStateChange?(state) }
        }
    }
    var onStateChange: ((VMRunState) -> Void)?
    /// The guest's console, when the test gives the session one.
    var console: (any GuestConsole)?
    /// The guest's monitor channel, when the test gives the session one.
    var guestChannel: (any GuestChannel)?
    /// Whether the session got its AI bridge (nil: none for this kind of session).
    var aiBridgeAttached: Bool?

    var machineIsGone = true
    /// What the configuration left out (shown in the window's bar).
    var warnings: [String] = []
    var startError: NidoError?
    /// When true, `start()` leaves the session in `.starting` (a boot that never ends).
    var hangsInStart = false
    /// When true, `stop` stays in `.stopping` until `finishStop()` (a guest taking its time).
    var holdsStop = false
    /// When set, `stop` ends in `.error` with the machine possibly still running (failed forced stop).
    var stopFailure: String?
    private(set) var stopGracePeriods: [Duration] = []
    private var stopGate: CheckedContinuation<Void, Never>?

    func start() async throws {
        state = .starting
        if let startError {
            state = .error(startError.localizedDescription)
            throw startError
        }
        if !hangsInStart { state = .running }
    }

    /// When set, `pause` fails and leaves the session in `.error` with the machine still running.
    var pauseFailure: String?

    /// pause, resume, save and suspend, in the order they ran.
    private(set) var events: [String] = []

    func pause() async throws {
        guard state == .running else { throw NidoError.notRunning("fake") }
        events.append("pause")
        if let pauseFailure {
            machineIsGone = false
            state = .error(pauseFailure)
            throw NidoError.notRunning(pauseFailure)
        }
        state = .paused
    }

    /// When set, `resume` fails and leaves the session in `.error` with the machine still there.
    var resumeFailure: String?

    func resume() async throws {
        guard state == .paused else { throw NidoError.notRunning("fake") }
        events.append("resume")
        if let resumeFailure {
            machineIsGone = false
            state = .error(resumeFailure)
            throw NidoError.notRunning(resumeFailure)
        }
        state = .running
    }

    func stop(gracePeriod: Duration) async {
        if isRestoring {
            stopRequestedDuringRestore = true
            await withCheckedContinuation { restoreStopWaiters.append($0) }
        }
        // Like `VMSession`: also from `.error` while the machine may still run.
        let errorWithMachine: Bool = if case .error = state { !machineIsGone } else { false }
        guard state.acceptsStop || errorWithMachine else { return }
        stopGracePeriods.append(gracePeriod)
        state = .stopping
        if holdsStop {
            await withCheckedContinuation { stopGate = $0 }
        } else {
            await Task.yield()
        }
        if let stopFailure {
            machineIsGone = false
            state = .error(stopFailure)
        } else {
            machineIsGone = true
            state = .stopped
        }
    }

    /// What `startOrResume` reports after booting (a discarded state, a resume).
    var bootOutcome: SuspendedState.BootOutcome = .coldStart
    /// When set, the configuration cannot be saved (`validateSaveRestoreSupport` throws).
    var suspendUnsupported: String?
    /// When set, `suspend` fails after pausing and the VM goes on running.
    var suspendFailure: String?
    private(set) var suspendCount = 0

    func startOrResume() async throws -> SuspendedState.BootOutcome {
        // `SuspendedState.boot` failing before the machine runs (config unreadable or unwritable).
        if let resumeError { throw resumeError }
        if holdsResume {
            // Like `SuspendedState.boot` over `VMSession`: the state stays `.stopped` while the
            // saved state is restored; a stop asked meanwhile is carried out when it ends.
            isRestoring = true
            await withCheckedContinuation { resumeGate = $0 }
            isRestoring = false
            let waiters = restoreStopWaiters
            restoreStopWaiters = []
            defer { waiters.forEach { $0.resume() } }
            if stopRequestedDuringRestore {
                state = .paused
                state = .stopping
                state = .stopped
                return .stoppedWhileResuming
            }
            state = .paused
            state = .running
            return .resumed
        }
        try await start()
        return bootOutcome
    }

    /// When set, `startOrResume` throws it with the machine never started (state `.stopped`).
    var resumeError: NidoError?
    /// When true, `startOrResume` restores a saved state and waits for `finishResume()`.
    var holdsResume = false
    private(set) var isRestoring = false
    private(set) var stopRequestedDuringRestore = false
    private var resumeGate: CheckedContinuation<Void, Never>?
    private var restoreStopWaiters: [CheckedContinuation<Void, Never>] = []
    /// True once the state was `.running` (the guest ran).
    private(set) var everRan = false

    /// Like `VMSession.acceptsStop`: also while a saved state is being restored.
    var acceptsStop: Bool {
        let errorWithMachine: Bool = if case .error = state { !machineIsGone } else { false }
        return isRestoring || state.acceptsStop || errorWithMachine
    }

    func finishResume() {
        resumeGate?.resume()
        resumeGate = nil
    }

    func validateSaveRestoreSupport() throws {
        if let suspendUnsupported { throw NidoError.snapshotUnsupported(suspendUnsupported) }
    }

    /// Like `SuspendedState.suspend`: paused, saved, stopped.
    func suspend() async throws {
        guard state == .running || state == .paused else { throw NidoError.notRunning("fake") }
        events.append("suspend")
        if let suspendUnsupported { throw NidoError.suspendFailed(suspendUnsupported) }
        state = .paused
        await Task.yield()
        if let suspendFailure {
            state = .running
            throw NidoError.suspendFailed(suspendFailure)
        }
        suspendCount += 1
        state = .stopping
        machineIsGone = true
        state = .stopped
    }

    // MARK: MachineStateSaving (live snapshots)

    var bundleURL = URL(fileURLWithPath: "/nonexistent")
    let attachedStateHash = "fake-hash"
    var stateSaver: (any MachineStateSaving)? { self }
    /// When true, `saveMachineState` waits for `finishSave()` (a large memory being written).
    var holdsSave = false
    private(set) var isSaving = false
    private var saveGate: CheckedContinuation<Void, Never>?

    func saveMachineState(to url: URL) async throws {
        guard state == .paused else { throw NidoError.notRunning("fake") }
        events.append("save")
        isSaving = true
        if holdsSave { await withCheckedContinuation { saveGate = $0 } }
        isSaving = false
        try Data("saved-state".utf8).write(to: url)
    }

    func finishSave() {
        saveGate?.resume()
        saveGate = nil
    }

    /// Lets a held `stop` finish.
    func finishStop() {
        stopGate?.resume()
        stopGate = nil
    }

    /// The guest powered itself off (`poweroff` inside the VM).
    func guestStops() {
        machineIsGone = true
        state = .stopped
    }
}

/// A guest console the test drives: `emit` is guest output, `sent` what the host typed.
final class TestConsole: GuestConsole {
    let output: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let received = Mutex(Data())

    init() {
        (output, continuation) = AsyncStream.makeStream(of: Data.self)
    }

    var sent: Data { received.withLock { $0 } }
    func emit(_ text: String) { continuation.yield(Data(text.utf8)) }
    func send(_ data: Data) { received.withLock { $0.append(data) } }
    func finish() { continuation.finish() }
}

/// Hands out `FakeSession`s and remembers them; `error` makes the next creation throw.
@MainActor
final class FakeSessionFactory: SessionFactory {
    private(set) var made: [FakeSession] = []
    private(set) var bundles: [URL] = []
    var error: NidoError?
    var configure: (FakeSession) -> Void = { _ in }

    func makeSession(bundle: VMBundle) async throws -> any VMSessionHandle {
        if let error { throw error }
        let session = FakeSession()
        session.bundleURL = bundle.url
        configure(session)
        made.append(session)
        bundles.append(bundle.url)
        return session
    }
}

/// A temporary VM root with empty `<name>.nidovm` bundles: enough for `VMBundle.open` and the lock.
final class TempRoot {
    let paths: NidoPaths

    init(vms: [String] = ["debian-13"]) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-window-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        for vm in vms {
            try FileManager.default.createDirectory(
                at: url.appendingPathComponent("\(vm).nidovm", isDirectory: true),
                withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        paths = NidoPaths(root: url)
    }

    deinit { try? FileManager.default.removeItem(at: paths.root) }

    func bundle(_ name: String) throws -> VMBundle { try VMBundle.open(VMName(name), paths: paths) }
    func holder(_ name: String) throws -> LockHolder? { BundleLock.holder(try bundle(name)) }
}

@MainActor
struct VMWindowModelTests {
    private func model(_ root: TempRoot, _ factory: FakeSessionFactory,
                       name: String = "debian-13") throws -> VMWindowModel {
        VMWindowModel(name: try VMName(name), paths: root.paths, factory: factory)
    }

    @Test func startTakesAppLock() async throws {
        let root = try TempRoot()
        let factory = FakeSessionFactory()
        let model = try model(root, factory)
        #expect(try root.holder("debian-13") == nil)

        await model.start()

        #expect(model.state == .running)
        #expect(try root.holder("debian-13") == LockHolder(pid: getpid(), owner: .app))
        #expect(factory.made.count == 1)
        #expect(factory.bundles.first?.lastPathComponent == "debian-13.nidovm")
    }

    /// A shared folder missing on the Mac: the VM starts, the bar says so until it stops.
    @Test func sessionWarningsShowWhileTheVMRuns() async throws {
        let root = try TempRoot()
        let factory = FakeSessionFactory()
        factory.configure = { $0.warnings = ["Cartella condivisa x non trovata sul Mac"] }
        let model = try model(root, factory)
        #expect(model.warnings.isEmpty)
        await model.start()
        #expect(model.state == .running)
        #expect(model.warnings == ["Cartella condivisa x non trovata sul Mac"])
        await model.stop()
        #expect(model.state == .stopped)
        #expect(model.warnings.isEmpty)
    }

    // MARK: - Serial console

    /// Waits (briefly) until `condition` holds: the terminal is fed by a task.
    private func eventually(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func consoleOutputReachesTheTerminal() async throws {
        let root = try TempRoot()
        let factory = FakeSessionFactory()
        let console = TestConsole()
        factory.configure = { $0.console = console }
        let model = try model(root, factory)
        // Output printed before the window looks is not lost: the model reads from session creation.
        console.emit("Debian GNU/Linux 13 debian-13 hvc0\r\n\r\n")
        await model.start()
        console.emit("debian-13 login: ")

        await eventually { model.terminal?.buffer.lines[2] == "debian-13 login:" }
        #expect(model.terminal?.buffer.lines[0] == "Debian GNU/Linux 13 debian-13 hvc0")
        #expect(model.terminal?.buffer.lines[2] == "debian-13 login:")
    }

    @Test func typingReachesTheGuestOnlyWhileRunning() async throws {
        let root = try TempRoot()
        let factory = FakeSessionFactory()
        let console = TestConsole()
        factory.configure = { $0.console = console }
        let model = try model(root, factory)
        model.sendInput(Data("x".utf8))  // no session yet
        await model.start()

        model.sendInput(Data("root\r".utf8))
        #expect(console.sent == Data("root\r".utf8))

        await model.pause()
        model.sendInput(Data("lost".utf8))
        #expect(console.sent == Data("root\r".utf8), "Una VM in pausa non riceve tasti")
        await model.resume()
        model.sendInput(Data([0x7F]))
        #expect(console.sent == Data("root\r".utf8) + Data([0x7F]))
    }

    @Test func cursorReportsGoToTheGuestOnlyWhileRunning() async throws {
        let root = try TempRoot()
        let factory = FakeSessionFactory()
        let console = TestConsole()
        factory.configure = { $0.console = console }
        let model = try model(root, factory)
        await model.start()

        console.emit("ab\u{1B}[6n")
        await eventually { console.sent == Data("\u{1B}[1;3R".utf8) }
        #expect(console.sent == Data("\u{1B}[1;3R".utf8))

        await model.pause()
        console.emit("\u{1B}[5n\u{1B}[6n")
        try await Task.sleep(for: .milliseconds(200))
        #expect(console.sent == Data("\u{1B}[1;3R".utf8), "Una VM in pausa non riceve risposte")
        // Queries the guest made while paused are not answered later either.
        await model.resume()
        console.emit("\u{1B}[5n")
        await eventually { console.sent.count > 6 }
        #expect(console.sent == Data("\u{1B}[1;3R\u{1B}[0n".utf8))
    }

    @Test func terminalGoesWithTheSessionAndIsFreshOnRestart() async throws {
        let root = try TempRoot()
        let factory = FakeSessionFactory()
        let consoles = [TestConsole(), TestConsole()]
        var next = 0
        factory.configure = { session in
            session.console = consoles[next]
            next += 1
        }
        let model = try model(root, factory)
        await model.start()
        consoles[0].emit("first boot")
        await eventually { model.terminal?.buffer.lines[0] == "first boot" }
        #expect(model.terminal != nil)

        await model.stop()
        #expect(model.terminal == nil)

        await model.start()
        consoles[1].emit("second")
        await eventually { model.terminal?.buffer.lines[0] == "second" }
        #expect(model.terminal?.buffer.lines[0] == "second")
    }

    @Test func lockIsTakenBeforeTheSessionIsCreated() async throws {
        let root = try TempRoot()
        let factory = FakeSessionFactory()
        var heldDuringCreation: LockHolder?
        factory.configure = { _ in heldDuringCreation = try? root.holder("debian-13") }
        let model = try model(root, factory)

        await model.start()

        #expect(heldDuringCreation?.owner == .app)
    }

    @Test func lockReleasedAfterStop() async throws {
        let root = try TempRoot()
        let factory = FakeSessionFactory()
        let model = try model(root, factory)
        await model.start()

        await model.stop()

        #expect(model.state == .stopped)
        #expect(try root.holder("debian-13") == nil)
        // Graceful first: the guest gets 30 s before the forced stop.
        #expect(factory.made.first?.stopGracePeriods == [.seconds(30)])
    }

    @Test func lockReleasedWhenTheGuestPowersOff() async throws {
        let root = try TempRoot()
        let factory = FakeSessionFactory()
        let model = try model(root, factory)
        await model.start()

        factory.made.first?.guestStops()

        #expect(model.state == .stopped)
        #expect(try root.holder("debian-13") == nil)
    }

    @Test func lockReleasedWhenTheSessionCannotBeCreated() async throws {
        let root = try TempRoot()
        let factory = FakeSessionFactory()
        factory.error = .notFound("disk.img")
        let model = try model(root, factory)

        await model.start()

        guard case .error(let message) = model.state else {
            Issue.record("stato atteso .error, ottenuto \(model.state)")
            return
        }
        #expect(message.contains("disk.img"))
        #expect(try root.holder("debian-13") == nil)
    }

    @Test func lockReleasedWhenStartFails() async throws {
        let root = try TempRoot()
        let factory = FakeSessionFactory()
        factory.configure = { $0.startError = .invalidResources("memoria") }
        let model = try model(root, factory)

        await model.start()

        #expect(model.state.isSettled)
        if case .error = model.state {} else { Issue.record("stato atteso .error, ottenuto \(model.state)") }
        #expect(try root.holder("debian-13") == nil)
    }

    @Test func secondWindowSameVMIsRefused() async throws {
        let root = try TempRoot()
        let first = try model(root, FakeSessionFactory())
        await first.start()

        // Another holder of the lock (here a second model, as another process would be).
        let otherFactory = FakeSessionFactory()
        let second = try model(root, otherFactory)
        await second.start()

        guard case .error(let message) = second.state else {
            Issue.record("stato atteso .error, ottenuto \(second.state)")
            return
        }
        // The holder is this very process: reported as an operation in Nido (APP m1); another
        // process gets "già in esecuzione" (`ownLockIsAnOperationInNido`).
        #expect(message.contains("in corso un'operazione su debian-13 in Nido"))
        #expect(otherFactory.made.isEmpty, "Nessuna sessione senza il lock")
        // The first VM keeps running and keeps its lock.
        #expect(first.state == .running)
        #expect(try root.holder("debian-13")?.owner == .app)
    }

    @Test func storeHandsOutOneModelPerVM() throws {
        let root = try TempRoot(vms: ["debian-13", "web"])
        let store = VMSessionStore(paths: root.paths, factory: FakeSessionFactory())
        let name = try VMName("debian-13")

        #expect(store.model(for: name) === store.model(for: name))
        #expect(store.model(for: name) !== store.model(for: try VMName("web")))
    }

    @Test func closeWhileRunningAsksConfirmation() async throws {
        let root = try TempRoot()
        let factory = FakeSessionFactory()
        let model = try model(root, factory)

        // Stopped: the window closes at once.
        #expect(model.confirmClose())
        #expect(!model.isConfirmingClose)

        await model.start()
        #expect(!model.confirmClose(), "Una VM accesa non si chiude senza conferma")
        #expect(model.isConfirmingClose)
        #expect(model.closeQuestion == "Arrestare debian-13?")

        // Annulla keeps the VM running.
        model.cancelClose()
        #expect(!model.isConfirmingClose)
        #expect(model.state == .running)

        // Confirmed: graceful stop, lock released, then the window may close.
        #expect(!model.confirmClose())
        let mayClose = await model.closeConfirmed()
        #expect(mayClose)
        #expect(model.state == .stopped)
        #expect(try root.holder("debian-13") == nil)
        #expect(factory.made.first?.stopGracePeriods == [.seconds(30)])
    }

    @Test func pauseAndResumeFollowTheSession() async throws {
        let root = try TempRoot()
        let model = try model(root, FakeSessionFactory())
        await model.start()

        await model.pause()
        #expect(model.state == .paused)
        #expect(try root.holder("debian-13")?.owner == .app, "In pausa la VM tiene il lock")

        await model.resume()
        #expect(model.state == .running)
    }

    @Test func startIsIgnoredWhileTheVMIsAlive() async throws {
        let root = try TempRoot()
        let factory = FakeSessionFactory()
        factory.configure = { $0.hangsInStart = true }
        let model = try model(root, factory)

        await model.start()
        #expect(model.state == .starting)
        await model.start()

        #expect(factory.made.count == 1)
    }

    @Test func restartAfterStopTakesTheLockAgain() async throws {
        let root = try TempRoot()
        let factory = FakeSessionFactory()
        let model = try model(root, factory)
        await model.start()
        await model.stop()

        await model.start()

        #expect(model.state == .running)
        #expect(factory.made.count == 2)
        #expect(try root.holder("debian-13")?.owner == .app)
    }

    @Test func storeStopsAllRunningVMsInParallel() async throws {
        let root = try TempRoot(vms: ["a", "b", "c"])
        let factory = FakeSessionFactory()
        let store = VMSessionStore(paths: root.paths, factory: factory)
        await store.model(for: try VMName("a")).start()
        await store.model(for: try VMName("b")).start()
        _ = store.model(for: try VMName("c"))  // window open, VM stopped

        #expect(store.liveModels.map(\.name.rawValue).sorted() == ["a", "b"])
        #expect(store.liveState(of: "a") == .running)
        #expect(store.liveState(of: "c") == .stopped)
        #expect(store.liveState(of: "missing") == nil)

        await store.stopAll()

        #expect(store.liveModels.isEmpty)
        #expect(try root.holder("a") == nil)
        #expect(try root.holder("b") == nil)
        #expect(factory.made.allSatisfy { $0.stopGracePeriods == [.seconds(30)] })
    }

    @Test func storeRoutesAppStopToTheRightModel() async throws {
        let root = try TempRoot(vms: ["a", "b"])
        let store = VMSessionStore(paths: root.paths, factory: FakeSessionFactory())
        await store.model(for: try VMName("a")).start()
        await store.model(for: try VMName("b")).start()

        await store.stop(try VMName("b"))

        #expect(store.liveState(of: "a") == .running)
        #expect(store.liveState(of: "b") == .stopped)
    }

    /// Riprendi on a library card: the store resumes the VM in its window model.
    @Test func storeResumesAPausedVM() async throws {
        let root = try TempRoot(vms: ["a"])
        let store = VMSessionStore(paths: root.paths, factory: FakeSessionFactory())
        let name = try VMName("a")
        #expect(!(await store.resume(name)), "Nessun modello: niente da riprendere")
        let model = store.model(for: name)
        await model.start()
        await model.pause()
        #expect(store.liveState(of: "a") == .paused)

        #expect(await store.resume(name))
        #expect(store.liveState(of: "a") == .running)
    }

    /// The library tells "error with a machine that may still run" (Arresta) from a failed start
    /// (Riprova) through the store.
    @Test func storeKnowsWhichVMsHaveAMachine() async throws {
        let root = try TempRoot(vms: ["a", "b"])
        let factory = FakeSessionFactory()
        let store = VMSessionStore(paths: root.paths, factory: factory)
        #expect(!store.runsMachine("a"))
        await store.model(for: try VMName("a")).start()
        #expect(store.runsMachine("a"))
        factory.error = .notFound("disk.img")
        await store.model(for: try VMName("b")).start()
        #expect(store.liveState(of: "b") != nil)
        #expect(!store.runsMachine("b"), "Avvio fallito: nessuna macchina dietro l'errore")
        #expect(!store.runsMachine("not a name/"))
    }

    @Test func storeForgetsOnlySettledModels() async throws {
        let root = try TempRoot(vms: ["a"])
        let store = VMSessionStore(paths: root.paths, factory: FakeSessionFactory())
        let name = try VMName("a")
        let running = store.model(for: name)
        await running.start()

        store.windowClosed(name)
        #expect(store.model(for: name) === running, "Una VM accesa resta nel registro")

        await running.stop()
        store.windowClosed(name)
        #expect(store.liveState(of: "a") == nil)
    }

    @Test func narrowToolbarKeepsTheRunControls() {
        let running = VMWindowModel.toolbarButtons(for: .running)
        let split = VMWindowModel.compactSplit(running)
        #expect(split.visible.map(\.action) == [.pause, .stop])
        #expect(split.more.map(\.action) == [.suspend, .snapshots, .settings, .fullScreen])
        // The order and the enabled state are kept; a stopped VM keeps Avvia as a button.
        let stopped = VMWindowModel.compactSplit(VMWindowModel.toolbarButtons(for: .stopped))
        #expect(stopped.visible.map(\.action) == [.start])
        #expect(stopped.more.map(\.action) == [.snapshots, .settings])
        let error = VMWindowModel.compactSplit(VMWindowModel.toolbarButtons(for: .error("x")))
        #expect(error.more.isEmpty)
    }

    @Test func toolbarButtonsFollowTheDesign() {
        typealias B = VMWindowModel.ToolbarButton
        func labels(_ state: VMRunState, fullScreen: Bool = false) -> [String] {
            VMWindowModel.toolbarButtons(for: state).map {
                "\(VMWindowModel.label(for: $0.action, isFullScreen: fullScreen))\($0.isEnabled ? "" : " (off)")"
            }
        }
        #expect(labels(.starting) == ["Pausa (off)", "Arresta"])
        #expect(labels(.running) == ["Pausa", "Sospendi", "Arresta", "Snapshot", "Impostazioni", "Schermo intero"])
        #expect(labels(.running, fullScreen: true)
            == ["Pausa", "Sospendi", "Arresta", "Snapshot", "Impostazioni", "Esci da schermo intero"])
        #expect(labels(.paused) == ["Riprendi", "Arresta"])
        #expect(labels(.stopped) == ["Avvia", "Snapshot", "Impostazioni"])
        #expect(labels(.error("x")) == ["Riprova", "Dettagli"])
        // An error with the machine possibly still running: Arresta, never a silent Riprova.
        #expect(VMWindowModel.toolbarButtons(for: .error("x"), machineMayRun: true)
            .map { VMWindowModel.label(for: $0.action, isFullScreen: false) } == ["Arresta", "Dettagli"])
        #expect(labels(.stopping) == ["Pausa (off)", "Arresta (off)"])
        #expect(VMWindowModel.toolbarButtons(for: .paused).first?.kind == .primary)
        #expect(VMWindowModel.toolbarButtons(for: .running).allSatisfy { $0.kind == .secondary })
    }

    @Test func stoppedAndErrorScreensTellWhatHappened() async throws {
        let root = try TempRoot()
        let factory = FakeSessionFactory()
        let model = try model(root, factory)
        #expect(model.stoppedMessage(now: Date()).hasPrefix("Avvia la VM dalla barra"))

        await model.start()
        await model.stop()
        let message = model.stoppedMessage(now: Date())
        #expect(message.hasPrefix("Ultimo arresto oggi alle "), "\(message)")

        factory.configure = { $0.startError = .notFound("disk.img") }
        await model.start()
        #expect(model.errorTitle == "Avvio non riuscito")

        factory.configure = { _ in }
        await model.start()
        factory.made.last?.state = .error("guasto")
        #expect(model.errorTitle == "La VM si è fermata per un errore")
    }

    /// The lock is taken without blocking the main actor (`acquireAsync`): an Arresta that comes
    /// while the start still waits for it makes the start give up, with no session and no lock.
    @Test func stopWhileTakingTheLockCancelsTheStart() async throws {
        let root = try TempRoot()
        let factory = FakeSessionFactory()
        let model = try model(root, factory)
        // A brief shared lock (like a `holder` probe): the first attempts fail.
        let lockURL = try root.bundle("debian-13").lockURL
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        try #require(fd >= 0)
        try #require(flock(fd, LOCK_SH | LOCK_NB) == 0)
        let start = Task { await model.start() }
        await until { model.state == .starting }
        let stop = Task { await model.stop() }
        for _ in 0..<20 { await Task.yield() }
        _ = flock(fd, LOCK_UN)
        close(fd)
        await start.value
        await stop.value
        #expect(model.state == .stopped)
        #expect(factory.made.isEmpty)
        #expect(model.isGone)
        #expect(try root.holder("debian-13") == nil)
    }

    /// A failed Pausa or Riprendi is not a VM that "stopped for an error": the machine did not
    /// answer the command.
    @Test func pauseFailureTitle() async throws {
        let root = try TempRoot()
        let factory = FakeSessionFactory()
        factory.configure = { $0.pauseFailure = "pausa non riuscita" }
        let model = try model(root, factory)
        await model.start()
        await model.pause()
        #expect(model.errorTitle == "La VM non risponde ai comandi")
        await model.stop()

        factory.configure = { $0.resumeFailure = "ripresa non riuscita" }
        await model.start()
        await model.pause()
        #expect(model.state == .paused)
        await model.resume()
        #expect(model.errorTitle == "La VM non risponde ai comandi")
        await model.stop()

        // A later failure of the running VM has its own title again.
        factory.configure = { _ in }
        await model.start()
        factory.made.last?.state = .error("guasto")
        #expect(model.errorTitle == "La VM si è fermata per un errore")
    }

    /// Yields to the main actor until `condition` holds (fails after many turns).
    private func until(_ condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() { await Task.yield() }
        #expect(condition())
    }

    @Test func stopAllWaitsForAnInFlightStop() async throws {
        let root = try TempRoot()
        let factory = FakeSessionFactory()
        factory.configure = { $0.holdsStop = true }
        let store = VMSessionStore(paths: root.paths, factory: factory)
        let model = store.model(for: try VMName("debian-13"))
        await model.start()
        let first = Task { await model.stop() }
        await until { model.state == .stopping }

        var quitDone = false
        let quit = Task {
            await store.stopAll()
            quitDone = true
        }
        for _ in 0..<50 { await Task.yield() }
        #expect(!quitDone, "L'uscita non deve finire mentre la VM si sta ancora arrestando")
        #expect(try root.holder("debian-13")?.owner == .app)

        factory.made.first?.finishStop()
        await quit.value
        await first.value
        #expect(model.state == .stopped)
        #expect(try root.holder("debian-13") == nil)
        #expect(factory.made.first?.stopGracePeriods.count == 1, "Un solo arresto, non due")
    }

    @Test func closeConfirmedDuringStoppingWaitsAndCloses() async throws {
        let root = try TempRoot()
        let factory = FakeSessionFactory()
        factory.configure = { $0.holdsStop = true }
        let model = try model(root, factory)
        await model.start()
        let stopping = Task { await model.stop() }
        await until { model.state == .stopping }

        #expect(!model.confirmClose())
        var closed: Bool?
        let close = Task { closed = await model.closeConfirmed() }
        for _ in 0..<50 { await Task.yield() }
        #expect(closed == nil, "La finestra resta aperta finché la VM non è arrestata")

        factory.made.first?.finishStop()
        await close.value
        await stopping.value
        #expect(closed == true)
        #expect(model.state == .stopped)
    }

    @Test func lockKeptWhileTheMachineMayStillRun() async throws {
        let root = try TempRoot()
        let factory = FakeSessionFactory()
        factory.configure = { $0.stopFailure = "arresto forzato non riuscito" }
        let model = try model(root, factory)
        await model.start()

        await model.stop()

        if case .error = model.state {} else { Issue.record("stato atteso .error, ottenuto \(model.state)") }
        #expect(try root.holder("debian-13")?.owner == .app, "La VM potrebbe essere ancora accesa: il lock resta")
        await model.start()
        #expect(factory.made.count == 1, "Nessun nuovo avvio sopra una VM forse ancora accesa")

        // The machine reports stopped later: now the lock goes.
        factory.made.first?.guestStops()
        #expect(model.state == .stopped)
        #expect(try root.holder("debian-13") == nil)
    }

    @Test func closingTheWindowKeepsTheLockWhileTheMachineMayStillRun() async throws {
        let root = try TempRoot()
        let factory = FakeSessionFactory()
        factory.configure = { $0.stopFailure = "arresto forzato non riuscito" }
        let store = VMSessionStore(paths: root.paths, factory: factory)
        let name = try VMName("debian-13")
        weak var weakModel: VMWindowModel?
        do {
            let model = store.model(for: name)
            weakModel = model
            await model.start()
            await model.stop()
            #expect(!model.isGone)
            #expect(!model.confirmClose(), "Una VM forse ancora accesa non si chiude senza conferma")
            model.cancelClose()
        }

        store.windowClosed(name)

        #expect(weakModel != nil, "Il modello resta nel registro finché la macchina non è ferma")
        #expect(store.model(for: name) === weakModel)
        #expect(store.liveModels.map(\.name) == [name])
        #expect(try root.holder("debian-13")?.owner == .app)

        // The machine stops later: now the window may go and the model with it.
        factory.made.first?.guestStops()
        #expect(weakModel?.isGone == true)
        store.windowClosed(name)
        #expect(store.liveState(of: "debian-13") == nil)
        #expect(try root.holder("debian-13") == nil)
    }

    /// A failed pause leaves `.error` with the machine running: Arresta forces it off, the lock
    /// goes afterwards, and quitting waits for that stop.
    @Test func errorWithALiveMachineCanBeStopped() async throws {
        let root = try TempRoot()
        let factory = FakeSessionFactory()
        factory.configure = { $0.pauseFailure = "pausa non riuscita" }
        let store = VMSessionStore(paths: root.paths, factory: factory)
        let name = try VMName("debian-13")
        let model = store.model(for: name)
        await model.start()
        await model.pause()
        if case .error = model.state {} else { Issue.record("stato atteso .error, ottenuto \(model.state)") }
        #expect(!model.isGone)
        #expect(store.liveModels.map(\.name) == [name], "L'uscita conta la VM forse ancora accesa")
        #expect(try root.holder("debian-13")?.owner == .app)

        factory.made.first?.holdsStop = true
        var quitDone = false
        let quit = Task {
            await store.stopAll()
            quitDone = true
        }
        await until { model.state == .stopping }
        for _ in 0..<50 { await Task.yield() }
        #expect(!quitDone, "L'uscita aspetta l'arresto")
        factory.made.first?.finishStop()
        await quit.value
        #expect(model.state == .stopped)
        #expect(model.isGone)
        #expect(try root.holder("debian-13") == nil)
    }

    /// The "may still be running" note is added once, however often the state settles.
    @Test func mayStillRunNoteIsNotRepeated() async throws {
        let root = try TempRoot()
        let factory = FakeSessionFactory()
        factory.configure = { $0.stopFailure = "arresto forzato non riuscito" }
        let model = try model(root, factory)
        await model.start()
        await model.stop()
        await model.stop()
        factory.made.first?.state = .error("ancora")
        let detail = model.errorDetail ?? ""
        #expect(detail.components(separatedBy: "La VM potrebbe essere ancora accesa").count == 2, "\(detail)")
    }

    /// After "Arresta ed esci" nothing may start: a VM started in the 30 s window would be killed.
    @Test func storeRefusesToStartWhileQuitting() async throws {
        let root = try TempRoot(vms: ["a", "b"])
        let factory = FakeSessionFactory()
        let store = VMSessionStore(paths: root.paths, factory: factory)
        let a = store.model(for: try VMName("a"))
        store.beginQuit()
        store.open(try VMName("a"))
        store.open(try VMName("b"))
        await a.start()
        await store.model(for: try VMName("b")).start()
        for _ in 0..<20 { await Task.yield() }
        #expect(factory.made.isEmpty)
        #expect(try root.holder("a") == nil)
        #expect(try root.holder("b") == nil)
    }

    /// ⌘W while the VM is already stopping: no second confirmation.
    @Test func closeDuringStoppingDoesNotAskAgain() async throws {
        let root = try TempRoot()
        let factory = FakeSessionFactory()
        factory.configure = { $0.holdsStop = true }
        let model = try model(root, factory)
        await model.start()
        let stopping = Task { await model.stop() }
        await until { model.state == .stopping }
        #expect(!model.confirmClose())
        #expect(!model.isConfirmingClose)
        factory.made.first?.finishStop()
        await stopping.value
        #expect(model.confirmClose())
    }

    @Test func quitQuestionCountsTheVMs() {
        #expect(VMSessionStore.quitQuestion(names: ["debian-13"]) == "Uscire con debian-13 accesa?")
        #expect(VMSessionStore.quitQuestion(names: ["a", "b", "c"]) == "Uscire con 3 macchine virtuali accese?")
    }
}

// MARK: - Suspend

@MainActor
struct SuspendModelTests {
    private func model(_ root: TempRoot, _ factory: FakeSessionFactory,
                       name: String = "debian-13") throws -> VMWindowModel {
        VMWindowModel(name: try VMName(name), paths: root.paths, factory: factory)
    }

    @Test func suspendStopsWithStateAndOffersRiprendi() async throws {
        let root = try TempRoot()
        let factory = FakeSessionFactory()
        let model = try model(root, factory)
        await model.start()
        #expect(model.toolbarButtons.map(\.action) == [.pause, .suspend, .stop, .snapshots, .settings, .fullScreen])
        #expect(VMWindowModel.label(for: .suspend, isFullScreen: false) == "Sospendi")

        #expect(await model.suspend())

        #expect(model.state == .stopped)
        #expect(model.isSuspended)
        #expect(factory.made.first?.suspendCount == 1)
        #expect(try root.holder("debian-13") == nil, "Sospesa: il lock è rilasciato")
        #expect(model.toolbarButtons.map(\.action) == [.resumeSaved, .snapshots, .settings])
        #expect(VMWindowModel.label(for: .resumeSaved, isFullScreen: false) == "Riprendi")
        #expect(model.stoppedTitle == "debian-13 è sospesa")

        await model.start()
        #expect(model.state == .running)
        #expect(!model.isSuspended)
    }

    @Test func failedSuspendKeepsTheVMRunningAndSaysWhy() async throws {
        let root = try TempRoot()
        let factory = FakeSessionFactory()
        factory.configure = { $0.suspendFailure = "disco pieno" }
        let model = try model(root, factory)
        await model.start()
        #expect(!(await model.suspend()))
        #expect(model.lastSuspendFailure == NidoError.suspendFailed("disco pieno").localizedDescription)
        // Quitting reports this suspend's own reason, whatever else the bar shows.
        #expect(await model.suspendOrStop()?.contains("disco pieno") == true)
        await model.start()
        #expect(!(await model.suspend()))
        #expect(model.state == .running)
        #expect(!model.isSuspended)
        #expect(model.warnings.contains { $0.contains("disco pieno") })
        #expect(try root.holder("debian-13")?.owner == .app)
    }

    @Test func discardedStateIsShownInTheBar() async throws {
        let root = try TempRoot()
        let factory = FakeSessionFactory()
        factory.configure = { $0.bootOutcome = .discarded(SuspendedState.configChangedWarning) }
        let model = try model(root, factory)
        await model.start()
        #expect(model.state == .running)
        #expect(model.warnings == [SuspendedState.configChangedWarning])
    }

    /// R-M3A-14: the start recovers an interrupted restore first and refuses what it left.
    @Test func startRefusesRestoreLeftovers() async throws {
        let root = try TempRoot()
        let factory = FakeSessionFactory()
        let bundle = try root.bundle("debian-13")
        let old = bundle.url.appendingPathComponent(".disk.img.restore-\(UUID().uuidString).old")
        try Data("disk".utf8).write(to: old)
        // The original cannot be put back: disk.img is a non-empty directory.
        try FileManager.default.createDirectory(at: bundle.diskURL, withIntermediateDirectories: false)
        try Data().write(to: bundle.diskURL.appendingPathComponent("x"))
        let model = try model(root, factory)
        await model.start()
        guard case .error(let message) = model.state else {
            Issue.record("atteso errore, stato \(model.state)")
            return
        }
        #expect(message.contains(old.lastPathComponent))
        #expect(factory.made.isEmpty)
        #expect(try root.holder("debian-13") == nil)
    }

    /// Quitting in the first 60 s of a Linux VM's first boot (no console.log yet: it never booted
    /// on this Mac) asks first: cloud-init may be replacing the SSH host keys.
    @Test func quitDuringFirstBootAsks() async throws {
        let root = try TempRoot(vms: ["nuova", "vecchia", "mac"])
        for (name, guest) in [("nuova", GuestOS.linux), ("vecchia", .linux), ("mac", .macos)] {
            try root.bundle(name).writeConfig(VMConfig(
                id: UUID(), name: try VMName(name), guest: guest, cpuCount: 2, memoryBytes: 2 << 30,
                diskBytes: 8 << 30, macAddress: "7a:80:2e:82:30:a5"))
        }
        // "vecchia" booted before: its console.log exists.
        FileManager.default.createFile(atPath: try root.bundle("vecchia").consoleLogURL.path, contents: Data())
        let factory = FakeSessionFactory()
        let store = VMSessionStore(paths: root.paths, factory: factory)
        #expect(store.firstBootNames(now: Date()).isEmpty)
        for name in ["nuova", "vecchia", "mac"] {
            await store.model(for: try VMName(name)).start()
        }
        #expect(store.liveModels.count == 3)

        #expect(store.firstBootNames(now: Date()) == ["nuova"])
        #expect(store.firstBootNames(now: Date().addingTimeInterval(59)) == ["nuova"])
        #expect(store.firstBootNames(now: Date().addingTimeInterval(61)).isEmpty)

        let prompt = VMSessionStore.firstBootQuitPrompt(names: ["nuova"])
        #expect(prompt.question == "nuova sta completando il primo avvio: uscire ora può lasciarla senza accesso SSH")
        #expect(prompt.buttons == ["Annulla", "Esci comunque"])
        #expect(VMSessionStore.firstBootQuitPrompt(names: ["a", "b"]).question
            == "a e b stanno completando il primo avvio: uscire ora può lasciarle senza accesso SSH")

        // Once stopped it is no longer in its first boot.
        await store.model(for: try VMName("nuova")).stop()
        #expect(store.firstBootNames(now: Date()).isEmpty)
    }

    /// "Sospendi ed esci" saves the guest's state, so a first boot is cut short only by a stop:
    /// "Arresta ed esci", or a VM that cannot be suspended (stopped instead).
    @Test func firstBootQuestionOnlyWhenStopping() async throws {
        let root = try TempRoot(vms: ["a", "b"])
        for name in ["a", "b"] {
            try root.bundle(name).writeConfig(VMConfig(
                id: UUID(), name: try VMName(name), guest: .linux, cpuCount: 2, memoryBytes: 2 << 30,
                diskBytes: 8 << 30, macAddress: "7a:80:2e:82:30:a5"))
        }
        let factory = FakeSessionFactory()
        factory.configure = { session in
            if session.bundleURL.lastPathComponent == "b.nidovm" { session.suspendUnsupported = "dispositivo non salvabile" }
        }
        let store = VMSessionStore(paths: root.paths, factory: factory)
        for name in ["a", "b"] { await store.model(for: try VMName(name)).start() }
        #expect(store.unsuspendableNames() == ["b"])
        #expect(store.firstBootNames(stoppedBy: .stop, now: Date()) == ["a", "b"])
        #expect(store.firstBootNames(stoppedBy: .suspend, now: Date()) == ["b"])
        #expect(store.firstBootNames(stoppedBy: .stop, now: Date().addingTimeInterval(61)).isEmpty)
    }

    /// A rotated console log (`console.log.1`) also means the VM booted before, even when
    /// console.log itself is gone (a crash during the rotation, or deleted by hand).
    @Test func rotatedConsoleLogMeansAlreadyBooted() throws {
        let root = try TempRoot(vms: ["r"])
        let bundle = try root.bundle("r")
        try bundle.writeConfig(VMConfig(
            id: UUID(), name: try VMName("r"), guest: .linux, cpuCount: 2, memoryBytes: 2 << 30,
            diskBytes: 8 << 30, macAddress: "7a:80:2e:82:30:a5"))
        #expect(VMWindowModel.isFirstBoot(bundle))
        let rotated = bundle.url.appendingPathComponent("console.log.1")
        FileManager.default.createFile(atPath: rotated.path, contents: Data())
        #expect(!VMWindowModel.isFirstBoot(bundle))
    }

    @Test func quitOffersSuspend() {
        let prompt = VMSessionStore.quitPrompt(names: ["debian-13"], unsuspendable: [])
        #expect(prompt.question == "Uscire con debian-13 accesa?")
        #expect(prompt.buttons == ["Sospendi ed esci", "Arresta ed esci", "Annulla"])
        let many = VMSessionStore.quitPrompt(names: ["a", "b", "c"], unsuspendable: ["b"])
        #expect(many.question == "Uscire con 3 macchine virtuali accese?")
        #expect(many.message.contains("b"))
        #expect(VMSessionStore.QuitChoice(buttonIndex: 0) == .suspend)
        #expect(VMSessionStore.QuitChoice(buttonIndex: 1) == .stop)
        #expect(VMSessionStore.QuitChoice(buttonIndex: 2) == nil)
    }

    @Test func quitSuspendsAllAndStopsWhatCannotBeSaved() async throws {
        let root = try TempRoot(vms: ["a", "b"])
        let factory = FakeSessionFactory()
        let store = VMSessionStore(paths: root.paths, factory: factory)
        await store.model(for: try VMName("a")).start()
        factory.configure = { $0.suspendUnsupported = "dispositivo non salvabile" }
        await store.model(for: try VMName("b")).start()
        #expect(store.unsuspendableNames() == ["b"])

        let warnings = await store.suspendAll()

        #expect(store.liveModels.isEmpty)
        #expect(factory.made[0].suspendCount == 1)
        #expect(factory.made[1].suspendCount == 0)
        #expect(factory.made[1].stopGracePeriods == [.seconds(30)])
        #expect(warnings.count == 1)
        #expect(warnings[0].contains("b"))
        #expect(warnings[0].contains("dispositivo non salvabile"))
        #expect(try root.holder("a") == nil)
        #expect(try root.holder("b") == nil)
    }
}

/// R-M3A-22: Arresta, closing or quitting while a suspended VM is being resumed.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct VMWindowModelResumeStopTests {
    private func eventually(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func stopDuringResumeStopsTheVMAndReturns() async throws {
        let root = try TempRoot()
        let factory = FakeSessionFactory()
        factory.configure = { $0.holdsResume = true }
        let model = VMWindowModel(name: try VMName("debian-13"), paths: root.paths, factory: factory)
        let start = Task { await model.start() }
        await eventually { factory.made.first?.isRestoring == true }
        let session = try #require(factory.made.first)
        #expect(model.state == .starting)

        let stop = Task { await model.stop() }
        await eventually { session.stopRequestedDuringRestore }
        #expect(session.stopRequestedDuringRestore)
        session.finishResume()
        await stop.value
        await start.value

        #expect(model.state == .stopped)
        #expect(model.isGone)
        #expect(!session.everRan)
        #expect(try root.holder("debian-13") == nil)
    }

    /// Quitting ("Sospendi ed esci" falls back to a stop) does not hang during a resume.
    @Test func suspendOrStopDuringResumeReturns() async throws {
        let root = try TempRoot()
        let factory = FakeSessionFactory()
        factory.configure = { $0.holdsResume = true }
        let model = VMWindowModel(name: try VMName("debian-13"), paths: root.paths, factory: factory)
        let start = Task { await model.start() }
        await eventually { factory.made.first?.isRestoring == true }
        let session = try #require(factory.made.first)

        let quit = Task { await model.suspendOrStop() }
        await eventually { session.stopRequestedDuringRestore }
        session.finishResume()
        _ = await quit.value
        await start.value

        #expect(model.isGone)
        #expect(!session.everRan)
    }
}

/// A resume that fails before the machine ever ran is an error, not a stop (SWIFT I2).
@MainActor
struct VMWindowModelFailedResumeTests {
    @Test func failureBeforeTheMachineRunsIsShownAsAnError() async throws {
        let root = try TempRoot()
        let factory = FakeSessionFactory()
        factory.configure = { $0.resumeError = .unsafePath("config.json") }
        let model = VMWindowModel(name: try VMName("debian-13"), paths: root.paths, factory: factory)
        await model.start()
        guard case .error = model.state else {
            Issue.record("atteso .error, ottenuto \(model.state)")
            return
        }
        #expect(model.errorTitle == "Avvio non riuscito")
        #expect(model.errorDetail == NidoError.unsafePath("config.json").localizedDescription)
        #expect(model.isGone)
        #expect(try root.holder("debian-13") == nil)
    }

    // MARK: - M3c

    /// A failed Pausa leaves `.error` with the machine still running: the monitor does not treat
    /// it as a stop (no "ultimo campione", the bridge session stays).
    @Test func failedPauseIsNotAStopForTheMonitor() async throws {
        let root = try TempRoot()
        let factory = FakeSessionFactory()
        let channel = ScriptedGuestChannel(.answer(guestDocument(hostname: "alfa")))
        factory.configure = {
            $0.pauseFailure = "la VM non risponde"
            $0.guestChannel = channel
            $0.aiBridgeAttached = true
        }
        let window = VMWindowModel(
            name: try VMName("debian-13"), paths: root.paths, factory: factory,
            monitor: MonitorModel(interval: .milliseconds(20)))
        await window.start()
        window.monitor.setVisible(true)
        #expect(await waitUntil { window.monitor.status != nil })
        await window.pause()
        guard case .error = window.state else {
            Issue.record("\(window.state)")
            return
        }
        if case .lastKnown = window.monitor.state { Issue.record("treated as a stop") }
        #expect(window.monitor.state != .vmStopped)
        #expect(!window.monitor.isPolling)
        #expect(window.aiBridge.sessionRunning)
        await window.stop()
        #expect(window.monitor.state == .vmStopped)
    }

    /// Avvia with the RAM of the running VMs over 75 %: the window asks first (non-blocking:
    /// "Avvia comunque" starts); within the limit it starts at once.
    @Test func startWarnsAboutMemoryHeadroom() async throws {
        let root = try TempRoot()
        let factory = FakeSessionFactory()
        let over = MemoryHeadroom(physicalMemory: 16 << 30, nidoBytes: 10 << 30, foreignBytes: 0, startingBytes: 4 << 30)
        let answer = Mutex<MemoryHeadroom?>(over)
        let window = VMWindowModel(
            name: try VMName("debian-13"), paths: root.paths, factory: factory,
            checkHeadroom: { _ in answer.withLock { $0 } })
        await window.requestStart()
        #expect(window.state == .stopped)
        #expect(factory.made.isEmpty)
        #expect(window.pendingHeadroom == over)
        #expect(window.headroomTitle == "La memoria delle VM accese supera il 75 % della RAM del Mac: rischio di crash del guest; riduci la memoria o chiudi altre VM/Docker.")
        window.cancelHeadroomStart()
        #expect(window.pendingHeadroom == nil)
        #expect(factory.made.isEmpty)
        await window.requestStart()
        await window.startAnyway()
        #expect(window.state == .running)
        #expect(window.pendingHeadroom == nil)
        await window.stop()

        answer.withLock { $0 = MemoryHeadroom(physicalMemory: 16 << 30, nidoBytes: 0, foreignBytes: 0, startingBytes: 4 << 30) }
        await window.requestStart()
        #expect(window.state == .running)
        await window.stop()
    }

    /// A VM made by the wizard with Ollama: when the guest first answers, phase 2 runs.
    @Test func provisioningPlanStartsWhenGuestAnswers() async throws {
        let root = try TempRoot()
        let factory = FakeSessionFactory()
        let channel = ScriptedGuestChannel(.refuse)
        factory.configure = { $0.guestChannel = channel }
        let runtime = FakeAIRuntime(status: runtimeStatus(installed: false, running: false))
        let window = VMWindowModel(
            name: try VMName("debian-13"), paths: root.paths, factory: factory,
            monitor: MonitorModel(interval: .milliseconds(20)),
            aiRuntime: AIRuntimeModel(readGuestToolsVersion: { "1.0.0" }, makeRuntime: { runtime }))
        window.provisioning.begin(ProvisioningPlan(model: "qwen3:0.6b"))
        await window.start()
        // The Monitor tab is hidden: the provisioning keeps the guest polled.
        #expect(window.monitor.isPolling)
        try await Task.sleep(for: .milliseconds(80))
        #expect(runtime.actions.isEmpty)
        channel.set(.answer(guestDocument(hostname: "alfa")))
        #expect(await waitUntil { window.provisioning.isComplete })
        #expect(runtime.actions == ["install", "pull qwen3:0.6b force=false", "verify"])
        #expect(!window.monitor.isPolling)
        await window.stop()
    }

    /// The wizard's phase-2 choice is in the config: a new window model (app restarted, window
    /// reopened) picks it up, runs it when the guest answers and clears it once verified.
    @Test func pendingProvisioningSurvivesANewWindow() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-pending-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let paths = NidoPaths(root: base)
        let bundle = try VMBundle.create(
            config: VMConfig(
                id: UUID(), name: try VMName("debian-ai"), guest: .linux, cpuCount: 2, memoryBytes: 4 << 30,
                diskBytes: 16 << 30, macAddress: "52:54:00:12:34:56", guestToolsVersion: "1.0.0",
                pendingProvisioning: PendingProvisioning(ollama: true, model: "qwen3:0.6b")),
            paths: paths)
        let channel = ScriptedGuestChannel(.answer(guestDocument(hostname: "debian-ai")))
        let factory = FakeSessionFactory()
        factory.configure = { $0.guestChannel = channel }
        let runtime = FakeAIRuntime(status: runtimeStatus(installed: false, running: false))
        let window = VMWindowModel(
            name: try VMName("debian-ai"), paths: paths, factory: factory,
            monitor: MonitorModel(interval: .milliseconds(20)),
            aiRuntime: AIRuntimeModel(readGuestToolsVersion: { "1.0.0" }, makeRuntime: { runtime }),
            checkHeadroom: { _ in nil })
        #expect(!window.provisioning.isBegun)
        await window.start()
        #expect(await waitUntil { window.provisioning.isComplete })
        #expect(window.provisioning.plan == ProvisioningPlan(model: "qwen3:0.6b"))
        #expect(runtime.actions == ["install", "pull qwen3:0.6b force=false", "verify"])
        #expect(await waitUntil { (try? bundle.readConfig().pendingProvisioning) == nil })
        await window.stop()
    }

    /// One Guest Tools model per VM, shared by its window and its settings: two installs cannot run at once.
    @Test func oneGuestToolsModelPerVM() throws {
        let root = try TempRoot()
        let store = VMSessionStore(paths: root.paths, factory: FakeSessionFactory())
        let name = try VMName("debian-13")
        let first = try #require(store.guestTools(for: name))
        #expect(store.guestTools(for: name) === first)
    }

    /// The manual installer fits one paste in Nido's console.
    @Test func manualInstallerFitsTheConsolePaste() throws {
        #expect(try GuestToolsInstaller.manualInstallCommand().utf8.count < TerminalInput.maxPaste)
        #expect(GuestToolsInstaller.manualCommandLimit <= TerminalInput.maxPaste)
    }

    /// The Guest Tools model outlives a window: closed and reopened, then started, the VM is seen
    /// running and the install reaches the new window's monitor and AI runtime.
    @Test func guestToolsFollowTheReopenedWindow() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-gt-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let paths = NidoPaths(root: base)
        _ = try VMBundle.create(
            config: VMConfig(
                id: UUID(), name: try VMName("debian-13"), guest: .linux, cpuCount: 2, memoryBytes: 4 << 30,
                diskBytes: 16 << 30, macAddress: "52:54:00:12:34:56", sshPublicKeyPath: "/Users/x/.ssh/id_ed25519.pub"),
            paths: paths)
        let store = VMSessionStore(paths: paths, factory: FakeSessionFactory(), checkHeadroom: { _ in nil })
        let name = try VMName("debian-13")
        let services = FakeGuestToolsServices()
        let tools = try #require(store.guestTools(for: name, services: services))
        // A window opened and closed while the VM is stopped: its model goes.
        let first = store.model(for: name)
        store.windowClosed(name)
        #expect(store.model(for: name) !== first)

        let window = store.model(for: name)
        await window.start()
        #expect(window.state == .running)
        window.monitor.guestToolsExpected = false
        await tools.load()
        await tools.install()
        #expect(services.calls == ["install"])
        #expect(tools.failure == nil)
        #expect(window.monitor.guestToolsExpected)
        await window.stop()

        // A VM deleted (forgotten): its Guest Tools model goes too.
        store.forget(name)
        #expect(store.guestTools(for: name) !== tools)
    }

    /// A lock held by this app (a window's session) counts as running for the Guest Tools.
    @Test func appLockCountsAsRunning() async throws {
        let root = try TempRoot()
        let bundle = try root.bundle("debian-13")
        #expect(!(await GuestToolsModel.runs(bundle, inApp: false)))
        let lock = try BundleLock.acquire(bundle, owner: .app)
        defer { lock.release() }
        #expect(await GuestToolsModel.runs(bundle, inApp: false))
    }
}

// MARK: - macOS window (M3b)

private let macKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHk2Lw9QeXbT4mZr7Vd1cN8sJpFa3uYoG6tRqE0iWzK5 tu@mac"

/// A temporary root with one macOS VM `macos-agenti` (account `agente`) and its public key.
@MainActor
private func macRoot(key: String? = macKey, sshSucceeded: Bool? = nil) throws -> TempRoot {
    let root = try TempRoot(vms: [])
    let config = VMConfig(
        id: UUID(), name: try VMName("macos-agenti"), guest: .macos, cpuCount: 4, memoryBytes: 8 << 30,
        diskBytes: 64 << 30, macAddress: "52:54:00:12:34:58", sshUser: "agente", osVersion: "26.6",
        sshSucceeded: sshSucceeded)
    let bundle = try VMBundle.create(config: config, paths: root.paths)
    if let key { try Data((key + "\n").utf8).write(to: bundle.authorizedKeyURL) }
    return root
}

/// The US layout, for the parts of it the authorize command needs: (key code, shift) → character.
struct USLayout: KeyboardLayout {
    static let table: [UInt16: (String, String)] = {
        let rows: [(UInt16, String, String)] = [
            (0, "a", "A"), (1, "s", "S"), (2, "d", "D"), (3, "f", "F"), (4, "h", "H"), (5, "g", "G"),
            (6, "z", "Z"), (7, "x", "X"), (8, "c", "C"), (9, "v", "V"), (11, "b", "B"), (12, "q", "Q"),
            (13, "w", "W"), (14, "e", "E"), (15, "r", "R"), (16, "y", "Y"), (17, "t", "T"), (18, "1", "!"),
            (19, "2", "@"), (20, "3", "#"), (21, "4", "$"), (22, "6", "^"), (23, "5", "%"), (24, "=", "+"),
            (25, "9", "("), (26, "7", "&"), (27, "-", "_"), (28, "8", "*"), (29, "0", ")"), (31, "o", "O"),
            (32, "u", "U"), (34, "i", "I"), (35, "p", "P"), (37, "l", "L"), (38, "j", "J"), (39, "'", "\""),
            (40, "k", "K"), (41, ";", ":"), (43, ",", "<"), (44, "/", "?"), (45, "n", "N"), (46, "m", "M"),
            (47, ".", ">"), (49, " ", " "), (50, "`", "~"),
        ]
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.0, ($0.1, $0.2)) })
    }()

    func character(keyCode: UInt16, shift: Bool, option: Bool) -> String? {
        guard !option, let pair = Self.table[keyCode] else { return nil }
        return shift ? pair.1 : pair.0
    }
}

/// The US layout where `~` and `'` sit elsewhere (option+5 and option+shift+Q), like many
/// European layouts: the mapping follows the layout it is given.
struct OtherLayout: KeyboardLayout {
    func character(keyCode: UInt16, shift: Bool, option: Bool) -> String? {
        if keyCode == 23, option, !shift { return "~" }
        if keyCode == 12, option, shift { return "'" }
        if keyCode == 50 || keyCode == 39 { return nil }
        if option { return nil }
        return USLayout().character(keyCode: keyCode, shift: shift, option: false)
    }
}

/// Records what would be typed into the guest.
@MainActor
final class RecordingSink: KeystrokeSink {
    private(set) var typed: [Keystroke] = []
    var failure: (any Error)?
    func type(_ strokes: [Keystroke]) async throws {
        if let failure { throw failure }
        typed += strokes
    }
    var text: String { typed.map(\.character).joined() }
}

@MainActor
struct MacWindowTests {
    private func model(_ root: TempRoot, _ factory: FakeSessionFactory) throws -> VMWindowModel {
        VMWindowModel(name: try VMName("macos-agenti"), paths: root.paths, factory: factory)
    }

    /// R4: the guest's screen, no serial terminal, no Monitor/AI views, no M3c panels;
    /// "Accesso da terminale" in the bar while the VM runs.
    @Test func macWindowUsesDisplayNotTerminal() async throws {
        let root = try macRoot()
        let factory = FakeSessionFactory()
        factory.configure = { $0.console = TestConsole() }
        let model = try model(root, factory)
        #expect(model.guest == .macos)
        #expect(model.showsDisplay)
        #expect(!model.showsViewTabs)
        #expect(model.terminalAccess != nil)
        await model.start()
        #expect(model.state == .running)
        #expect(model.terminal == nil)
        #expect(model.monitor.state != .guestToolsMissing)
        #expect(!model.provisioning.isShown)
        #expect(model.toolbarButtons.map(\.action) == [.pause, .suspend, .stop, .snapshots, .settings, .terminalAccess, .fullScreen])
        #expect(VMWindowModel.label(for: .terminalAccess, isFullScreen: false) == "Accesso da terminale")

        // Linux keeps its console, its views and its bar.
        let linuxRoot = try TempRoot()
        let linux = VMWindowModel(name: try VMName("debian-13"), paths: linuxRoot.paths, factory: factory)
        #expect(linux.guest == .linux && !linux.showsDisplay && linux.showsViewTabs && linux.terminalAccess == nil)
        await linux.start()
        #expect(linux.terminal != nil)
        #expect(!linux.toolbarButtons.map(\.action).contains(.terminalAccess))
        await linux.stop()
        await model.stop()
    }

    /// Review Focus #5: closing the window of a running macOS VM neither asks nor stops it; the
    /// store keeps its model, so the reopened window shows the same session.
    @Test func closingWindowKeepsMacVMRunning() async throws {
        let root = try macRoot()
        let factory = FakeSessionFactory()
        let store = VMSessionStore(paths: root.paths, factory: factory, checkHeadroom: { _ in nil })
        let name = try VMName("macos-agenti")
        let model = store.model(for: name)
        await model.start()
        let session = try #require(model.session as? FakeSession)

        #expect(model.confirmClose())
        #expect(!model.isConfirmingClose)
        store.windowClosed(name)
        #expect(model.state == .running)
        #expect(session.stopGracePeriods.isEmpty)
        #expect(store.liveModels.map(\.name) == [name])

        let reopened = store.model(for: name)
        #expect(reopened === model)
        #expect(reopened.session === session)
        store.open(name)
        #expect(factory.made.count == 1)
        await model.stop()
    }

    /// The panel (S07 macOS): four steps, the command with the key from authorized_key.pub,
    /// `nido ssh <nome>` to copy.
    @Test func terminalPanelShowsKeyAndSteps() async throws {
        let root = try macRoot()
        let model = try model(root, FakeSessionFactory())
        let panel = try #require(model.terminalAccess)
        panel.reload()
        #expect(panel.title == "Accesso da terminale")
        #expect(panel.intro == "Per usare macos-agenti con nido ssh, una volta sola dopo l'assistente iniziale. Nido non chiede né salva password.")
        #expect(panel.steps.map(\.title) == [
            "Completa l'assistente iniziale", "Attiva Login remoto", "Autorizza la tua chiave", "Collegati dal Mac"])
        #expect(panel.steps.map(\.detail) == [
            "Crea l'account agente: è il nome che usa nido ssh. Puoi cambiarlo nelle impostazioni della VM.",
            "Nella VM: Impostazioni di Sistema › Generali › Condivisione › Login remoto.",
            "Apri il Terminale nella VM, poi Digita nella VM: Nido scrive il comando con la tua chiave pubblica. Puoi anche digitarlo a mano.",
            "Nel Terminale del Mac:"])
        #expect(panel.publicKey == macKey)
        #expect(panel.authorizeCommand == "mkdir -p \"$HOME/.ssh\" && chmod 700 \"$HOME/.ssh\" && echo '\(macKey)' >> \"$HOME/.ssh/authorized_keys\" && chmod 600 \"$HOME/.ssh/authorized_keys\"")
        #expect(panel.sshCommand == "nido ssh macos-agenti")
        #expect(panel.footnote == "Il pannello si apre da solo finché nido ssh non è riuscito almeno una volta; poi dalla barra, Accesso da terminale.")
        // Caps Lock on in the guest would invert the key's letters.
        #expect(panel.layoutNote == "Nido usa la disposizione della tastiera di questo Mac: se nella VM è diversa, digita il comando a mano. Tieni spento Blocco maiuscole nella VM.")
        #expect(panel.canType)
        #expect(panel.keyProblem == nil)

        // A key Nido would not type (or none): no Digita nella VM, and the panel says why.
        let bad = try macRoot(key: "ssh-ed25519 AAAA x'; id #")
        let badPanel = try #require(try self.model(bad, FakeSessionFactory()).terminalAccess)
        badPanel.reload()
        #expect(!badPanel.canType)
        #expect(badPanel.keyProblem != nil)
        let none = try macRoot(key: nil)
        let nonePanel = try #require(try self.model(none, FakeSessionFactory()).terminalAccess)
        nonePanel.reload()
        #expect(!nonePanel.canType)
        #expect(nonePanel.keyProblem != nil)
        #expect(nonePanel.authorizeCommand.contains("<chiave>"))
    }

    /// A key file that is a symlink, or a key over the length bound: never read or typed.
    @Test func panelRefusesSymlinkAndOverLongKeys() async throws {
        let linked = try macRoot(key: nil)
        let bundle = try linked.bundle("macos-agenti")
        let outside = linked.paths.root.appendingPathComponent("other.pub")
        try Data((macKey + "\n").utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: bundle.authorizedKeyURL, withDestinationURL: outside)
        let linkedPanel = try #require(try model(linked, FakeSessionFactory()).terminalAccess)
        linkedPanel.reload()
        #expect(linkedPanel.publicKey == nil)
        #expect(!linkedPanel.canType)
        #expect(linkedPanel.keyProblem != nil)

        let long = try macRoot(key: "ssh-rsa " + String(repeating: "A", count: 9000))
        let longPanel = try #require(try model(long, FakeSessionFactory()).terminalAccess)
        longPanel.reload()
        #expect(!longPanel.canType)
        let sink = RecordingSink()
        await longPanel.typeCommand(into: sink, layout: USLayout())
        #expect(sink.typed.isEmpty)
        #expect(longPanel.typingError == KeystrokeError.invalidKey.localizedDescription)
    }

    /// A model made while the config could not be read resolves the guest again at start.
    @Test func guestResolvedAgainAtStart() async throws {
        let root = try TempRoot(vms: ["macos-agenti"])
        let model = try model(root, FakeSessionFactory())
        #expect(model.terminalAccess == nil)
        let config = VMConfig(
            id: UUID(), name: try VMName("macos-agenti"), guest: .macos, cpuCount: 4, memoryBytes: 8 << 30,
            diskBytes: 64 << 30, macAddress: "52:54:00:12:34:59", sshUser: "agente")
        try root.bundle("macos-agenti").writeConfig(config)
        await model.start()
        #expect(model.guest == .macos)
        #expect(model.showsDisplay)
        #expect(model.terminalAccess != nil)
        #expect(model.terminal == nil)
        await model.stop()
    }

    /// The panel opens by itself while the VM runs, until `nido ssh` reached the guest once
    /// (`VMConfig.sshSucceeded`, recorded by the CLI); Chiudi hides it until the window reopens.
    @Test func terminalPanelAutoShownUntilFirstSSH() async throws {
        let root = try macRoot()
        let model = try model(root, FakeSessionFactory())
        let panel = try #require(model.terminalAccess)
        #expect(!panel.isShown)
        await model.start()
        #expect(panel.isShown)
        panel.dismiss()
        #expect(!panel.isShown)
        model.windowAppeared()
        #expect(panel.isShown)
        panel.dismiss()

        // From the bar, always.
        panel.show()
        #expect(panel.isShown)
        panel.dismiss()

        // `nido ssh` reached the guest: never again by itself.
        _ = try root.bundle("macos-agenti").updateConfig { $0.sshSucceeded = true }
        await model.stop()
        await model.start()
        #expect(!panel.isShown)
        model.windowAppeared()
        #expect(!panel.isShown)
        await model.stop()

        // A stopped VM: nothing opens.
        let stopped = try self.model(try macRoot(), FakeSessionFactory())
        stopped.windowAppeared()
        #expect(stopped.terminalAccess?.isShown == false)
    }

    /// "Digita nella VM": the command, mapped to keys with the layout, goes to the guest's view.
    @Test func typingSendsTheCommandAsKeys() async throws {
        let root = try macRoot()
        let model = try model(root, FakeSessionFactory())
        let panel = try #require(model.terminalAccess)
        panel.reload()
        let sink = RecordingSink()
        await panel.typeCommand(into: sink, layout: USLayout())
        #expect(sink.text == panel.authorizeCommand)
        #expect(panel.typingError == nil)
        #expect(panel.typingMessage == "Comando scritto nella VM: premi Invio nel Terminale della VM.")
        #expect(!panel.isTyping)

        // A character the layout cannot type: nothing is sent.
        let partial = RecordingSink()
        struct NoDollar: KeyboardLayout {
            func character(keyCode: UInt16, shift: Bool, option: Bool) -> String? {
                keyCode == 21 && shift ? nil : USLayout().character(keyCode: keyCode, shift: shift, option: option)
            }
        }
        await panel.typeCommand(into: partial, layout: NoDollar())
        #expect(partial.typed.isEmpty)
        #expect(panel.typingError == "Il carattere $ non si può digitare con la tastiera di questo Mac: scrivi il comando a mano nella VM.")

        // The VM stopped while typing: said, never "Comando scritto".
        let stopped = RecordingSink()
        stopped.failure = KeystrokeError.vmNotRunning
        await panel.typeCommand(into: stopped, layout: USLayout())
        #expect(panel.typingMessage == nil)
        #expect(panel.typingError == "La VM non è più in esecuzione: il comando potrebbe essere scritto solo in parte. Cancella la riga nel Terminale della VM prima di riprovare.")

        // The view went away (window closed): said, not thrown.
        let gone = RecordingSink()
        gone.failure = KeystrokeError.noDisplay
        await panel.typeCommand(into: gone, layout: USLayout())
        #expect(panel.typingError == KeystrokeError.noDisplay.localizedDescription)
    }
}

/// The key mapping and the check of the key, with fixed layouts.
struct GuestKeystrokesTests {
    /// Held modifiers are released when typing stops midway: a guest must never keep Shift down.
    @MainActor @Test func heldModifiersAreReleasedWhenTypingStops() async throws {
        struct Boom: Error {}
        let strokes = [Keystroke(keyCode: 0, shift: true, option: true, character: "A")]

        // A complete run: six events, no extra release.
        var all: [MacDisplayController.KeyEvent] = []
        var extra = 0
        try await MacDisplayController.run(strokes, emit: { all.append($0) }, release: { _ in extra += 1 })
        #expect(all.count == 6)
        #expect(extra == 0)

        // Failing at every event: the modifier state the guest ends with is "none held".
        for (failAt, delivered) in (0..<all.count).flatMap({ [($0, false), ($0, true)] }) {
            var seen = 0
            var flags: NSEvent.ModifierFlags = []  // what the guest believes is held
            await #expect(throws: Boom.self) {
                try await MacDisplayController.run(strokes, emit: { event in
                    // `delivered`: the event reaches the guest and then the call throws (as `send`
                    // does when its pause is cancelled).
                    if seen == failAt && !delivered { throw Boom() }
                    seen += 1
                    if event.type == .flagsChanged { flags = event.flags }
                    if seen == failAt + 1 { throw Boom() }
                }, release: { event in
                    #expect(event.type == .flagsChanged)
                    flags = event.flags
                })
            }
            #expect(flags.isEmpty, "a modifier stays down when typing fails at event \(failAt), delivered: \(delivered)")
        }

        // Cancellation counts as a failure: Option comes up first, then Shift.
        var released: [UInt16] = []
        var n = 0
        await #expect(throws: CancellationError.self) {
            try await MacDisplayController.run(strokes, emit: { _ in
                n += 1
                if n == 3 { throw CancellationError() }
            }, release: { released.append($0.keyCode) })
        }
        #expect(released == [58, 56])

        // Cancelled right after the Shift-down was delivered: Shift is still released.
        var shiftOnly: [UInt16] = []
        await #expect(throws: CancellationError.self) {
            try await MacDisplayController.run([Keystroke(keyCode: 0, shift: true, option: false, character: "A")],
                                               emit: { _ in throw CancellationError() },
                                               release: { shiftOnly.append($0.keyCode) })
        }
        #expect(shiftOnly == [56])
    }

    /// Shift and Option carry the left key's device bit (NX_DEVICELSHIFTKEYMASK 0x02,
    /// NX_DEVICELALTKEYMASK 0x20) as a real key does: without it the guest never sees them held
    /// (seen live: "$HOME" typed as "4home" on a German layout).
    @MainActor @Test func modifierEventsCarryTheLeftKeyDeviceBits() throws {
        func raw(_ type: NSEvent.EventType, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) throws -> UInt {
            let event = MacDisplayController.KeyEvent(type: type, keyCode: keyCode, flags: flags, characters: "")
            return try #require(MacDisplayController.nsEvent(event, windowNumber: 0)).modifierFlags.rawValue
        }
        #expect(try raw(.flagsChanged, 56, [.shift]) & 0x02 != 0)
        #expect(try raw(.flagsChanged, 58, [.shift, .option]) & 0x22 == 0x22)
        #expect(try raw(.keyDown, 21, [.shift]) & 0x02 != 0)
        // Released: no bit left.
        #expect(try raw(.flagsChanged, 56, []) & 0x22 == 0)
        #expect(try raw(.flagsChanged, 58, [.shift]) & 0x20 == 0)
    }

    /// The "no screen" text, like "VM stopped", warns that part of the command may be on the line.
    @Test func noDisplayTextWarnsAboutAPartialCommand() {
        #expect(KeystrokeError.noDisplay.localizedDescription.contains("solo in parte"))
        #expect(KeystrokeError.vmNotRunning.localizedDescription.contains("solo in parte"))
    }

    @Test func publicKeyValidation() throws {
        let good = [
            macKey,
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHk2Lw9QeXbT4mZr7Vd1cN8sJpFa3uYoG6tRqE0iWzK5",
            "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQ== user@host.example",
            "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTY= a_b-c",
        ]
        for key in good { #expect(GuestKeystrokes.isTypablePublicKey(key), "\(key)") }
        let bad = [
            "", "ssh-ed25519", "ssh-ed25519 AAAA\nssh-rsa BBBB", "ssh-ed25519 AAAA x'y", "ssh-ed25519 AAAA $(id)",
            "ssh-ed25519 AAAA a;b", "ssh-ed25519 AAAA è", "-----BEGIN OPENSSH PRIVATE KEY-----", "AAAA ssh-ed25519",
            "ssh-ed25519 AAAA\t#", "ssh-ed25519 AAAA `id`",
        ]
        for key in bad { #expect(!GuestKeystrokes.isTypablePublicKey(key), "\(key)") }
        // At most 8192 bytes.
        let body = String(repeating: "A", count: 8192 - "ssh-rsa ".count)
        #expect(GuestKeystrokes.isTypablePublicKey("ssh-rsa " + body))
        #expect(!GuestKeystrokes.isTypablePublicKey("ssh-rsa " + body + "A"))
        // The command typed is always the constant one around a valid key.
        #expect(throws: KeystrokeError.invalidKey) { try GuestKeystrokes.authorizeCommand(publicKey: "x'; id") }
        #expect(try GuestKeystrokes.authorizeCommand(publicKey: macKey)
            == "mkdir -p \"$HOME/.ssh\" && chmod 700 \"$HOME/.ssh\" && echo '\(macKey)' >> \"$HOME/.ssh/authorized_keys\" && chmod 600 \"$HOME/.ssh/authorized_keys\"")
        // No character that some layouts only give through a dead key (Italian: ~ is Option-5 then
        // a key; ^ ` ´ ¨ likewise): the command must be typable on those Macs too.
        let command = GuestKeystrokes.command(around: macKey)
        #expect(!command.contains { "~^`´¨".contains($0) })
    }

    @Test func mappingFollowsTheLayout() throws {
        let us = try GuestKeystrokes.keystrokes(for: "aA~&' >+=@_9", layout: USLayout())
        #expect(us.map(\.keyCode) == [0, 0, 50, 26, 39, 49, 47, 24, 24, 19, 27, 25])
        #expect(us.map(\.shift) == [false, true, true, true, false, false, true, true, false, true, true, false])
        #expect(us.allSatisfy { !$0.option })
        #expect(us.map(\.character).joined() == "aA~&' >+=@_9")

        let other = try GuestKeystrokes.keystrokes(for: "~'a", layout: OtherLayout())
        #expect(other.map(\.keyCode) == [23, 12, 0])
        #expect(other.map(\.option) == [true, true, false])
        #expect(other.map(\.shift) == [false, true, false])

        #expect(throws: KeystrokeError.unmappable("é")) { try GuestKeystrokes.keystrokes(for: "aé", layout: USLayout()) }
        // Return (36) and Enter (76) are never typed, whatever the layout says they give.
        struct ReturnGivesLetters: KeyboardLayout {
            func character(keyCode: UInt16, shift: Bool, option: Bool) -> String? {
                switch keyCode {
                case 36: "a"
                case 76: "b"
                default: nil
                }
            }
        }
        #expect(throws: KeystrokeError.unmappable("a")) { try GuestKeystrokes.keystrokes(for: "a", layout: ReturnGivesLetters()) }
        #expect(throws: KeystrokeError.unmappable("b")) { try GuestKeystrokes.keystrokes(for: "b", layout: ReturnGivesLetters()) }

        // The whole command maps on the US layout.
        let command = try GuestKeystrokes.authorizeCommand(publicKey: macKey)
        #expect(try GuestKeystrokes.keystrokes(for: command, layout: USLayout()).count == command.count)
        let all = try GuestKeystrokes.keystrokes(for: command, layout: USLayout())
        #expect(!all.contains { $0.keyCode == 36 || $0.keyCode == 76 })
    }
}
