// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore
import Synchronization
import Testing

@testable import Nido

/// A registry returning whatever the test puts in `rows` (or throwing `failure`).
final class FakeRegistry: VMRegistryProviding {
    private let state = Mutex<(rows: [VMSummary], failure: NidoError?, calls: Int)>(([], nil, 0))

    init(_ rows: [VMSummary] = []) {
        state.withLock { $0.rows = rows }
    }

    var calls: Int { state.withLock { $0.calls } }

    func set(_ rows: [VMSummary]) { state.withLock { $0.rows = rows } }
    func fail(with error: NidoError?) { state.withLock { $0.failure = error } }

    func summaries() async throws -> [VMSummary] {
        try state.withLock { s in
            s.calls += 1
            if let failure = s.failure { throw failure }
            return s.rows
        }
    }
}

/// Records every stop and delete; `stopError`/`deleteError` make the next call throw.
final class FakeControl: VMControlling {
    private let state = Mutex<(stops: [String], deletes: [String], stopError: NidoError?,
                               deleteError: NidoError?)>(([], [], nil, nil))

    var stops: [String] { state.withLock { $0.stops } }
    var deletes: [String] { state.withLock { $0.deletes } }

    func failStop(with error: NidoError) { state.withLock { $0.stopError = error } }
    func failDelete(with error: NidoError) { state.withLock { $0.deleteError = error } }

    func requestStop(_ name: VMName) throws {
        try state.withLock { s in
            if let error = s.stopError { throw error }
            s.stops.append(name.rawValue)
        }
    }

    func delete(_ name: VMName) throws {
        try state.withLock { s in
            if let error = s.deleteError { throw error }
            s.deletes.append(name.rawValue)
        }
    }
}

private func summary(_ name: String, _ status: VMStatus) -> VMSummary {
    if case .unreadable = status {
        return VMSummary(configID: nil, name: name, status: status, cpuCount: nil, memoryBytes: nil,
                         diskBytes: nil)
    }
    return VMSummary(configID: UUID(), name: name, status: status, cpuCount: 4, memoryBytes: 8 << 30,
                     diskBytes: 64 << 30)
}

@MainActor
struct LibraryModelTests {
    @Test func refreshPublishesSummaries() async {
        let rows = [summary("debian-13", .stopped), summary("web", .running(.app))]
        let model = LibraryModel(registry: FakeRegistry(rows), control: FakeControl())
        #expect(model.items.isEmpty)

        await model.refresh()

        #expect(model.items == rows)
        #expect(model.error == nil)
    }

    @Test func deleteRequiresConfirmation() async {
        let registry = FakeRegistry([summary("vecchia-vm", .unreadable(running: nil))])
        let control = FakeControl()
        let model = LibraryModel(registry: registry, control: control)
        await model.refresh()

        await model.delete("vecchia-vm")
        // Asking to delete only opens the confirmation: nothing is removed yet.
        #expect(model.pendingDelete?.name == "vecchia-vm")
        #expect(control.deletes.isEmpty)

        model.cancelDelete()
        #expect(model.pendingDelete == nil)
        #expect(control.deletes.isEmpty)

        await model.delete("vecchia-vm")
        registry.set([])
        await model.confirmDelete()
        #expect(control.deletes == ["vecchia-vm"])
        #expect(model.pendingDelete == nil)
        #expect(model.items.isEmpty)
    }

    @Test func cliRunningVMOffersStopNotStart() async {
        let vm = summary("ci-runner", .running(.cli))
        let control = FakeControl()
        let model = LibraryModel(registry: FakeRegistry([vm]), control: control)
        await model.refresh()

        #expect(model.actions(for: vm) == [.stop, .settings])
        // The design still shows Avvia on this card, disabled.
        let buttons = model.buttons(for: vm)
        #expect(buttons.map(\.action) == [.start, .stop, .settings])
        #expect(buttons.map(\.isEnabled) == [false, true, true])
        #expect(model.cardState(for: vm) == .runningTerminal)

        await model.perform(.stop, on: vm)
        #expect(control.stops == ["ci-runner"])
    }

    @Test func actionsFollowTheStatus() {
        let model = LibraryModel(registry: FakeRegistry(), control: FakeControl())
        #expect(model.actions(for: summary("a", .stopped)) == [.start, .settings, .delete])
        #expect(model.actions(for: summary("a", .running(.app))) == [.open, .stop, .settings])
        #expect(model.actions(for: summary("a", .unreadable(running: nil))) == [.showInFinder, .delete])
        // Elimina of a stopped VM lives in the context menu, not on the card.
        #expect(model.buttons(for: summary("a", .stopped)).map(\.action) == [.start, .settings])
        #expect(model.buttons(for: summary("a", .unreadable(running: nil))).map(\.action) == [.showInFinder, .delete])
    }

    @Test func liveSessionStatesReachTheCards() {
        let live: [String: VMRunState] = [
            "a": .starting, "b": .paused, "c": .error("disco illeggibile"), "d": .stopped, "f": .stopping,
        ]
        let model = LibraryModel(registry: FakeRegistry(), control: FakeControl(), liveState: { live[$0] })
        #expect(model.cardState(for: summary("a", .running(.app))) == .starting)
        #expect(model.cardState(for: summary("b", .running(.app))) == .paused)
        // The lock is gone after a failed start: the registry says stopped, the session knows why.
        #expect(model.cardState(for: summary("c", .stopped)) == .error("disco illeggibile"))
        #expect(model.cardState(for: summary("d", .stopped)) == .stopped)
        // No session in this app (another process): what the registry knows.
        #expect(model.cardState(for: summary("e", .running(.app))) == .running)
        #expect(model.cardState(for: summary("f", .running(.app))) == .running)
    }

    // MARK: - Live states on the card (S01, design decision M3a)

    @Test func startingCardDisablesStart() async {
        let vm = summary("dev-box", .running(.app))
        var stopped: [String] = []
        let model = LibraryModel(registry: FakeRegistry([vm]), control: FakeControl(),
                                 stopAppVM: { stopped.append($0.rawValue); return true },
                                 liveState: { _ in .starting }, appRunsMachine: { _ in true })
        await model.refresh()
        let buttons = model.buttons(for: vm)
        #expect(buttons.map(\.action) == [.start, .stop])
        #expect(buttons.map(\.isEnabled) == [false, true])
        #expect(model.actions(for: vm) == [.stop])
        await model.perform(.stop, on: vm)
        #expect(stopped == ["dev-box"])
    }

    /// The registry may not have seen the lock yet: Arresta still reaches the app's own session.
    @Test func startingCardStopsEvenBeforeTheRegistrySeesTheLock() async {
        let vm = summary("dev-box", .stopped)
        var stopped: [String] = []
        let model = LibraryModel(registry: FakeRegistry([vm]), control: FakeControl(),
                                 stopAppVM: { stopped.append($0.rawValue); return true },
                                 liveState: { _ in .starting }, appRunsMachine: { _ in true })
        await model.refresh()
        #expect(model.cardState(for: vm) == .starting)
        await model.perform(.stop, on: vm)
        #expect(stopped == ["dev-box"])
    }

    @Test func pausedCardOffersResume() async {
        let vm = summary("sandbox", .running(.app))
        var resumed: [String] = []
        let model = LibraryModel(registry: FakeRegistry([vm]), control: FakeControl(),
                                 resumeAppVM: { resumed.append($0.rawValue); return true },
                                 liveState: { _ in .paused }, appRunsMachine: { _ in true })
        await model.refresh()
        let buttons = model.buttons(for: vm)
        #expect(buttons.map(\.action) == [.resume, .stop])
        #expect(buttons.map(\.kind) == [.primary, .secondary])
        #expect(model.actions(for: vm) == [.resume, .stop])
        #expect(LibraryModel.label(for: .resume) == "Riprendi")

        await model.perform(.resume, on: vm)
        #expect(resumed == ["sandbox"])
    }

    /// APP m3: during a live snapshot (the VM paused by it) Riprendi is disabled.
    @Test func snapshottingCardDisablesResume() async {
        let vm = summary("sandbox", .running(.app))
        var resumed: [String] = []
        let model = LibraryModel(registry: FakeRegistry([vm]), control: FakeControl(),
                                 resumeAppVM: { resumed.append($0.rawValue); return true },
                                 liveState: { _ in .paused }, appRunsMachine: { _ in true },
                                 isSnapshotting: { _ in true })
        await model.refresh()
        #expect(model.buttons(for: vm).map(\.isEnabled) == [false, true])
        await model.perform(.resume, on: vm)
        #expect(resumed.isEmpty)
    }

    /// R-M3A-3: while the pause is being taken, Riprendi is shown but disabled.
    @Test func pausingCardDisablesResume() async {
        let vm = summary("sandbox", .running(.app))
        var resumed: [String] = []
        let model = LibraryModel(registry: FakeRegistry([vm]), control: FakeControl(),
                                 resumeAppVM: { resumed.append($0.rawValue); return true },
                                 liveState: { _ in .pausing }, appRunsMachine: { _ in true })
        await model.refresh()
        #expect(model.cardState(for: vm) == .paused)
        let buttons = model.buttons(for: vm)
        #expect(buttons.map(\.action) == [.resume, .stop])
        #expect(buttons.map(\.isEnabled) == [false, true])
        await model.perform(.resume, on: vm)
        #expect(resumed.isEmpty)
    }

    @Test func errorCardOffersRetryAndDetails() async {
        let vm = summary("test-arm", .stopped)
        var opened: [String] = []
        var shown: [String] = []
        let model = LibraryModel(registry: FakeRegistry([vm]), control: FakeControl(),
                                 openWindow: { opened.append($0.rawValue) },
                                 liveState: { _ in .error("Avvio non riuscito: il disco della VM non è leggibile.") })
        model.showWindow = { shown.append($0.rawValue) }
        await model.refresh()
        let buttons = model.buttons(for: vm)
        #expect(buttons.map(\.action) == [.retry, .details])
        #expect(buttons.map(\.kind) == [.primary, .secondary])
        #expect(LibraryModel.label(for: .retry) == "Riprova")
        #expect(LibraryModel.label(for: .details) == "Dettagli")

        // Riprova starts again, like Avvia; Dettagli only shows the window (no new start).
        await model.perform(.retry, on: vm)
        #expect(opened == ["test-arm"])
        await model.perform(.details, on: vm)
        #expect(shown == ["test-arm"])
        #expect(opened == ["test-arm"])
    }

    /// R-M3A-1: an error while the machine may still run keeps Arresta (Riprova could not start it).
    @Test func errorCardWithALiveMachineOffersStop() async {
        let vm = summary("test-arm", .running(.app))
        var stopped: [String] = []
        let model = LibraryModel(registry: FakeRegistry([vm]), control: FakeControl(),
                                 stopAppVM: { stopped.append($0.rawValue); return true },
                                 liveState: { _ in .error("arresto forzato non riuscito") },
                                 appRunsMachine: { _ in true })
        await model.refresh()
        #expect(model.cardState(for: vm) == .error("arresto forzato non riuscito"))
        #expect(model.buttons(for: vm).map(\.action) == [.stop, .details])
        await model.perform(.stop, on: vm)
        #expect(stopped == ["test-arm"])
    }

    /// A double click on a starting, paused or failed card brings its window to the front.
    @Test func doubleClickShowsTheWindowOfALiveCard() async {
        var opened: [String] = []
        var shown: [String] = []
        let live: [String: VMRunState] = ["a": .starting, "b": .paused, "c": .error("x")]
        let model = LibraryModel(registry: FakeRegistry(), control: FakeControl(),
                                 openWindow: { opened.append($0.rawValue) },
                                 liveState: { live[$0] }, appRunsMachine: { $0 != "c" })
        model.showWindow = { shown.append($0.rawValue) }
        await model.doubleClick(summary("a", .running(.app)))
        await model.doubleClick(summary("b", .running(.app)))
        await model.doubleClick(summary("c", .stopped))
        #expect(shown == ["a", "b", "c"])
        #expect(opened.isEmpty)
    }

    @Test func refusedOpenDoesNotHideARunningVM() {
        // Apri refused because another process holds the lock: the card keeps "In esecuzione".
        let model = LibraryModel(registry: FakeRegistry(), control: FakeControl(),
                                 liveState: { _ in .error("già in esecuzione") })
        #expect(model.cardState(for: summary("web", .running(.app))) == .running)
        #expect(model.cardState(for: summary("ci", .running(.cli))) == .runningTerminal)
        #expect(model.cardState(for: summary("old", .stopped)) == .error("già in esecuzione"))
    }

    @Test func doubleClickOpensOrStarts() async {
        var opened: [String] = []
        let model = LibraryModel(registry: FakeRegistry(), control: FakeControl(),
                                 openWindow: { opened.append($0.rawValue) })
        await model.doubleClick(summary("ferma", .stopped))
        await model.doubleClick(summary("app", .running(.app)))
        await model.doubleClick(summary("cli", .running(.cli)))
        await model.doubleClick(summary("rotta", .unreadable(running: nil)))
        #expect(opened == ["ferma", "app"])
    }

    @Test func startAndOpenUseTheInjectedWindowOpener() async {
        var opened: [String] = []
        let model = LibraryModel(registry: FakeRegistry(), control: FakeControl(),
                                 openWindow: { opened.append($0.rawValue) })
        await model.perform(.start, on: summary("debian-13", .stopped))
        await model.perform(.open, on: summary("web", .running(.app)))
        #expect(opened == ["debian-13", "web"])
    }

    @Test func stopOfAnAppVMGoesThroughTheApp() async {
        var stopped: [String] = []
        let control = FakeControl()
        let model = LibraryModel(registry: FakeRegistry([summary("web", .running(.app))]), control: control,
                                 stopAppVM: { stopped.append($0.rawValue); return true })
        await model.refresh()
        await model.perform(.stop, on: summary("web", .running(.app)))
        #expect(stopped == ["web"])
        #expect(model.error == nil)
        // Never a signal to our own process.
        #expect(control.stops.isEmpty)
    }

    /// The lock says "app" but no window of this app runs the VM: another Nido has it.
    @Test func stopOfAVMOfAnotherNidoExplainsItself() async {
        let control = FakeControl()
        let model = LibraryModel(registry: FakeRegistry([summary("web", .running(.app))]), control: control,
                                 stopAppVM: { _ in false })
        await model.refresh()
        await model.perform(.stop, on: summary("web", .running(.app)))
        #expect(model.error == "Impossibile arrestare web: è aperta in un'altra istanza di Nido, arrestala da lì.")
        #expect(control.stops.isEmpty)
    }

    /// A deleted VM's window model goes too: a VM created again with that name starts fresh.
    @Test func deleteForgetsTheAppModel() async {
        var forgotten: [String] = []
        let control = FakeControl()
        let model = LibraryModel(registry: FakeRegistry([summary("a", .stopped)]), control: control,
                                 forget: { forgotten.append($0.rawValue) })
        await model.refresh()
        await model.delete("a")
        await model.confirmDelete()
        #expect(forgotten == ["a"])

        control.failDelete(with: .alreadyRunning(pid: 1))
        await model.delete("a")
        await model.confirmDelete()
        #expect(forgotten == ["a"], "Un'eliminazione fallita non tocca il modello")
    }

    @Test func refreshFailureShowsItalianErrorAndRecovers() async {
        let registry = FakeRegistry()
        registry.fail(with: .unsafePath("/x"))
        let model = LibraryModel(registry: registry, control: FakeControl())

        await model.refresh()
        #expect(model.error?.hasPrefix("Impossibile leggere le VM") == true)

        registry.fail(with: nil)
        await model.refresh()
        #expect(model.error == nil)
    }

    @Test func stopFailureIsShownAndKeptAcrossRefresh() async {
        let vm = summary("ci-runner", .running(.cli))
        let control = FakeControl()
        control.failStop(with: .pidUnknown)
        let model = LibraryModel(registry: FakeRegistry([vm]), control: control)
        await model.refresh()

        await model.stop("ci-runner")
        #expect(model.error == "Impossibile arrestare ci-runner: VM in esecuzione ma PID sconosciuto")
        await model.refresh()
        #expect(model.error != nil)
        model.dismissError()
        #expect(model.error == nil)
    }

    /// R-M3A-24: Arresta while a `nido` maintenance command holds the lock is refused with why.
    @Test func stopOfAVMBusyWithAnOperationSaysSo() async {
        let vm = summary("ci-runner", .running(.cliOperation))
        let control = FakeControl()
        control.failStop(with: .operationInProgress("ci-runner", pid: 42))
        let model = LibraryModel(registry: FakeRegistry([vm]), control: control)
        await model.refresh()
        await model.stop("ci-runner")
        #expect(model.error == "Impossibile arrestare ci-runner: è in corso un'operazione su ci-runner (pid 42): riprova al termine")
    }

    @Test func deleteFailureIsShown() async {
        let control = FakeControl()
        control.failDelete(with: .alreadyRunning(pid: 42))
        let model = LibraryModel(registry: FakeRegistry([summary("a", .stopped)]), control: control)
        await model.refresh()
        await model.delete("a")
        await model.confirmDelete()
        #expect(model.error == "Impossibile eliminare a: VM già in esecuzione (pid 42)")
    }

    @Test func textsMatchTheDesign() {
        let model = LibraryModel(registry: FakeRegistry(), control: FakeControl())
        #expect(model.subtitle == "Nessuna macchina virtuale")
        #expect(LibraryModel.resources(of: summary("a", .stopped)) == "4 CPU · 8 GiB di memoria · disco 64 GiB")
        // The wizard's template choice and summary use the design's short form (S02/S06 da modello).
        #expect(WizardModel.templateDetail(summary("a", .stopped)) == "4 CPU · 8 GiB · disco 64 GiB")
        #expect(LibraryModel.resources(of: summary("a", .unreadable(running: nil))) == "CPU, memoria e disco sconosciuti")
        #expect(LibraryModel.subtitle(count: 1, running: 0) == "1 macchina virtuale")
        #expect(LibraryModel.subtitle(count: 0, templates: 1, running: 0) == "Nessuna macchina virtuale · 1 modello")
        #expect(LibraryModel.subtitle(count: 7, running: 2) == "7 macchine virtuali · 2 in esecuzione")
        #expect(model.cardState(for: summary("a", .unreadable(running: nil)))
                == .unreadable("config.json danneggiato: la VM non si può aprire."))
    }

    /// A VM whose config.json is broken but whose lock is held still runs: the card says so,
    /// offers Arresta for a Terminal VM, never Elimina, and the subtitle counts it.
    @Test func unreadableRunningVMIsShownRunning() async {
        let control = FakeControl()
        let vm = summary("rotta", .unreadable(running: .cli))
        let model = LibraryModel(registry: FakeRegistry([vm]), control: control)
        await model.refresh()
        #expect(model.cardState(for: vm)
                == .unreadable("config.json danneggiato, ma la VM è in esecuzione: arrestala prima di eliminarla."))
        #expect(model.actions(for: vm) == [.showInFinder, .stop])
        #expect(model.subtitle == "1 macchina virtuale · 1 in esecuzione")
        await model.perform(.stop, on: vm)
        #expect(control.stops == ["rotta"])
        let other = summary("rotta", .unreadable(running: .app))
        #expect(model.actions(for: other) == [.showInFinder, .stop])
    }

    @Test func searchFiltersByName() async {
        let model = LibraryModel(
            registry: FakeRegistry([summary("debian-13", .stopped), summary("web", .stopped)]),
            control: FakeControl())
        await model.refresh()
        model.query = "DEB"
        #expect(model.visibleItems.map(\.name) == ["debian-13"])
    }

    /// R-M3A-2: a stopped VM with a saved state is "Sospesa", with Riprendi (= start, which
    /// resumes) and Impostazioni.
    @Test func suspendedCardOffersRiprendi() async throws {
        let vm = VMSummary(configID: UUID(), name: "sospesa", status: .stopped, cpuCount: 2,
                           memoryBytes: 4 << 30, diskBytes: 32 << 30, isSuspended: true)
        var opened: [String] = []
        let model = LibraryModel(registry: FakeRegistry([vm]), control: FakeControl(),
                                 openWindow: { opened.append($0.rawValue) })
        await model.refresh()
        #expect(model.cardState(for: vm) == .suspended)
        #expect(NidoVMCardState.suspended.badge == .suspended)
        #expect(String(localized: NidoStatusBadge.Status.suspended.label) == "Sospesa")
        #expect(model.buttons(for: vm).map(\.action) == [.resumeSuspended, .settings])
        #expect(model.buttons(for: vm).first?.kind == .primary)
        #expect(LibraryModel.label(for: .resumeSuspended) == "Riprendi")
        await model.perform(.resumeSuspended, on: vm)
        #expect(opened == ["sospesa"])
        await model.doubleClick(vm)
        #expect(opened == ["sospesa", "sospesa"])
        // Starting it in this app: the live state wins.
        model.liveState = { _ in .starting }
        #expect(model.cardState(for: vm) == .starting)
    }
}

/// Records every clone; `failure` makes the next one throw. `gate` holds a clone until opened.
/// With `stagingRoot`, a gated clone works in `.<target>.cloning-<uuid>` there, like `VMCloner`:
/// cancelled while held, it removes that folder and throws `CancellationError`.
final class FakeCloner: VMCloning {
    private let state = Mutex<(clones: [String], failure: NidoError?)>(([], nil))
    /// What the next clones report to run in the copy (`VMCloner.cloneNotes`).
    private let reportedNotes = Mutex<[String]>([])
    func report(notes: [String]) { reportedNotes.withLock { $0 = notes } }
    let gate = AsyncStream<Void>.makeStream()
    let gated: Bool
    let stagingRoot: URL?

    init(gated: Bool = false, stagingRoot: URL? = nil) {
        self.gated = gated
        self.stagingRoot = stagingRoot
    }

    var clones: [String] { state.withLock { $0.clones } }
    func fail(with error: NidoError?) { state.withLock { $0.failure = error } }

    func clone(_ source: VMName, as target: VMName) async throws -> [String] {
        let staging = stagingRoot?.appendingPathComponent(".\(target.rawValue).cloning-\(UUID().uuidString)")
        if let staging { try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false) }
        defer { if let staging { try? FileManager.default.removeItem(at: staging) } }
        // The stream ends when the task is cancelled.
        if gated { for await _ in gate.stream { break } }
        try Task.checkCancellation()
        try state.withLock { s in
            if let error = s.failure { throw error }
            s.clones.append("\(source.rawValue)>\(target.rawValue)")
        }
        return reportedNotes.withLock { $0 }
    }

    func createFromTemplate(_ template: VMName, as target: VMName) async throws {
        try state.withLock { s in
            if let error = s.failure { throw error }
            s.clones.append("modello \(template.rawValue)>\(target.rawValue)")
        }
    }
}

/// Records every template save and edit; `failure` makes the next one throw.
final class FakeTemplates: VMTemplating {
    private let state = Mutex<(calls: [String], failure: NidoError?)>(([], nil))
    var calls: [String] { state.withLock { $0.calls } }
    func fail(with error: NidoError?) { state.withLock { $0.failure = error } }

    func save(_ name: VMName) async throws { try record("save \(name.rawValue)") }
    func edit(_ name: VMName) async throws { try record("edit \(name.rawValue)") }

    private func record(_ call: String) throws {
        try state.withLock { s in
            if let error = s.failure { throw error }
            s.calls.append(call)
        }
    }
}

private func template(_ name: String) -> VMSummary {
    VMSummary(configID: UUID(), name: name, status: .stopped, cpuCount: 4, memoryBytes: 8 << 30,
              diskBytes: 64 << 30, isTemplate: true)
}

@MainActor
struct LibraryTemplateTests {
    /// A template card: Nuova VM… and Modifica modello, never Avvia, Clona or Impostazioni.
    @Test func templateCardOffersCreateNotStart() async {
        let base = template("debian-ai-base")
        var opened: [String] = []
        let model = LibraryModel(
            registry: FakeRegistry([summary("debian", .stopped), base]), control: FakeControl(),
            cloner: FakeCloner(), templates: FakeTemplates(), openWindow: { opened.append($0.rawValue) })
        await model.refresh()
        #expect(model.vmItems.map(\.name) == ["debian"])
        #expect(model.templateItems.map(\.name) == ["debian-ai-base"])
        #expect(model.showsTemplates)
        #expect(model.buttons(for: base).map(\.action) == [.newFromTemplate, .editTemplate])
        #expect(model.buttons(for: base).map(\.kind) == [.primary, .secondary])
        #expect(LibraryModel.label(for: .newFromTemplate) == "Nuova VM…")
        #expect(LibraryModel.label(for: .editTemplate) == "Modifica modello")
        let actions = model.actions(for: base)
        for refused in [LibraryModel.CardAction.start, .open, .clone, .settings, .saveAsTemplate] {
            #expect(!actions.contains(refused))
        }
        #expect(model.menuActions(for: base) == [.delete])
        await model.perform(.start, on: base)
        await model.doubleClick(base)
        #expect(opened.isEmpty)
        #expect(model.subtitle == "1 macchina virtuale · 1 modello")
        #expect(LibraryModel.subtitle(count: 3, templates: 2, running: 1)
            == "3 macchine virtuali · 2 modelli · 1 in esecuzione")

        // Nuova VM…: the name of the new VM, then a copy of the template (not a plain clone).
        await model.perform(.newFromTemplate, on: base)
        #expect(model.pendingClone?.name == "debian-ai-base")
        #expect(model.isCloneFromTemplate)
        #expect(model.cloneName == "debian-ai-base-1")
        model.cloneName = "lavoro"
        let cloner = FakeCloner()
        let creating = LibraryModel(
            registry: FakeRegistry([base]), control: FakeControl(), cloner: cloner, templates: FakeTemplates())
        await creating.refresh()
        await creating.perform(.newFromTemplate, on: base)
        creating.cloneName = "lavoro"
        await creating.confirmClone()
        #expect(cloner.clones == ["modello debian-ai-base>lavoro"])
        #expect(creating.pendingClone == nil)
    }

    /// No templates: the Modelli section is not shown at all.
    @Test func emptyTemplatesSectionIsHidden() async {
        let model = LibraryModel(registry: FakeRegistry([summary("debian", .stopped)]), control: FakeControl())
        await model.refresh()
        #expect(!model.showsTemplates)
        #expect(model.templateItems.isEmpty)
        #expect(model.subtitle == "1 macchina virtuale")
    }

    /// The space a template takes on the Mac, measured off the main actor after a refresh.
    @Test func templateSpaceIsMeasured() async {
        let model = LibraryModel(
            registry: FakeRegistry([template("a"), template("b")]), control: FakeControl(),
            measureTemplate: { name in name == "a" ? 10_522_669_875 : nil })
        await model.refresh()
        await model.measureTemplates()
        #expect(model.spaceText(for: template("a")) == "Occupa 9,8 GiB sul Mac")
        #expect(model.spaceText(for: template("b")) == "Spazio occupato non disponibile")
        #expect(model.templatesCaption == "2 · 9,8 GiB sul Mac · non si avviano: servono a creare nuove VM")
    }

    /// "Salva come modello…" on a stopped VM, after a confirmation; refused with the core's
    /// message for a VM that holds a suspended state; never offered on a running VM.
    @Test func saveAsTemplateRequiresStopped() async {
        let templates = FakeTemplates()
        let registry = FakeRegistry([summary("ricerca-01", .stopped)])
        let model = LibraryModel(registry: registry, control: FakeControl(), cloner: FakeCloner(), templates: templates)
        await model.refresh()
        let stopped = summary("ricerca-01", .stopped)
        #expect(model.menuActions(for: stopped) == [.clone, .saveAsTemplate, .delete])
        #expect(LibraryModel.label(for: .saveAsTemplate) == "Salva come modello")
        #expect(model.menuActions(for: summary("ricerca-01", .running(.app))).isEmpty)
        #expect(model.menuActions(for: summary("ricerca-01", .running(.cli))).isEmpty)

        await model.perform(.saveAsTemplate, on: stopped)
        #expect(model.pendingSaveTemplate?.name == "ricerca-01")
        #expect(templates.calls.isEmpty)
        model.cancelSaveTemplate()
        #expect(model.pendingSaveTemplate == nil)
        #expect(templates.calls.isEmpty)

        await model.perform(.saveAsTemplate, on: stopped)
        await model.confirmSaveTemplate()
        #expect(templates.calls == ["save ricerca-01"])
        #expect(model.error == nil)

        templates.fail(with: .templateHasSuspendedState("ricerca-01"))
        await model.perform(.saveAsTemplate, on: stopped)
        await model.confirmSaveTemplate()
        #expect(model.error == "Impossibile salvare ricerca-01 come modello: la VM ricerca-01 ha uno stato sospeso: riprendila con nido start e arrestala, poi salvala come modello.")
        templates.fail(with: .vmMustBeStopped("ricerca-01"))
        await model.perform(.saveAsTemplate, on: stopped)
        await model.confirmSaveTemplate()
        #expect(model.error == "Impossibile salvare ricerca-01 come modello: la VM ricerca-01 è in esecuzione: arrestala prima di modificarla.")

        // A window of this app is starting it: not offered.
        let starting = LibraryModel(
            registry: registry, control: FakeControl(), templates: templates, appRunsMachine: { _ in true })
        #expect(!starting.menuActions(for: stopped).contains(.saveAsTemplate))
    }

    /// "Modifica modello" asks first, then makes the template startable again.
    @Test func editTemplateAsks() async {
        let templates = FakeTemplates()
        let base = template("debian-ai-base")
        let model = LibraryModel(registry: FakeRegistry([base]), control: FakeControl(), templates: templates)
        await model.refresh()
        await model.perform(.editTemplate, on: base)
        #expect(model.pendingEditTemplate?.name == "debian-ai-base")
        #expect(templates.calls.isEmpty)
        model.cancelEditTemplate()
        await model.perform(.editTemplate, on: base)
        await model.confirmEditTemplate()
        #expect(templates.calls == ["edit debian-ai-base"])
        #expect(model.pendingEditTemplate == nil)
    }

    /// A VM made from a template whose source had the bridge on starts with the bridge off
    /// (real bundles: save as template, Nuova VM… through the live services, then the AI model).
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/hdiutil")))
    func fromTemplateBridgeOff() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("nido-fromtemplate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = NidoPaths(root: tmp.appendingPathComponent("VMs"))
        let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOO97YvP4YWGQwUFq+UeOnyDKkD29RZ8VdmeuGgPzeS6"
        let keyURL = tmp.appendingPathComponent("id_test.pub")
        try (key + "\n").write(to: keyURL, atomically: true, encoding: .utf8)
        let image = tmp.appendingPathComponent("base.img")
        try Data(repeating: 0xAB, count: 1 << 20).write(to: image)
        let source = try VMFactory(paths: paths, runner: SystemProcessRunner()).createLinux(
            LinuxVMRequest(
                name: try VMName("debian-ai"), baseImage: image, cpuCount: 2, memoryBytes: 2048 << 20,
                diskBytes: 4 << 20, publicKey: key, profile: .init(essentialPackages: true, guestTools: true),
                sshPublicKeyPath: keyURL.path))
        _ = try source.updateConfig { $0.aiBridge = AIBridgePolicy(enabled: true, privacyAcknowledged: true) }

        let model = LibraryModel(
            registry: VMRegistry(paths: paths), control: LiveVMControl(paths: paths),
            cloner: LiveVMCloner(paths: paths), templates: LiveVMTemplates(paths: paths))
        await model.refresh()
        let vm = try #require(model.items.first { $0.name == "debian-ai" })
        await model.perform(.saveAsTemplate, on: vm)
        await model.confirmSaveTemplate()
        #expect(model.error == nil)
        let saved = try #require(model.templateItems.first)
        #expect(saved.name == "debian-ai")

        await model.perform(.newFromTemplate, on: saved)
        model.cloneName = "dal-modello"
        await model.confirmClone()
        #expect(model.cloneError == nil)
        #expect(model.vmItems.map(\.name) == ["dal-modello"])

        let bridge = AIBridgeModel(name: try VMName("dal-modello"), paths: paths, services: nil)
        await bridge.load()
        #expect(!bridge.policy.enabled)
        #expect(!bridge.policy.privacyAcknowledged)
        bridge.sessionStarted(bridgeAttached: true)
        #expect(!bridge.isActive)
        // The template keeps its own policy.
        #expect(try source.readConfig().aiBridge?.enabled == true)
    }

    /// A template held by something (a `nido create --from-template`, this app) keeps its two
    /// template buttons, disabled; never the buttons of a VM.
    @Test func busyTemplateKeepsTemplateButtonsDisabled() async {
        let busy = VMSummary(configID: UUID(), name: "debian-ai-base", status: .running(.cliOperation), cpuCount: 4,
                             memoryBytes: 8 << 30, diskBytes: 64 << 30, isTemplate: true)
        let model = LibraryModel(
            registry: FakeRegistry([busy]), control: FakeControl(), cloner: FakeCloner(), templates: FakeTemplates())
        await model.refresh()
        #expect(model.buttons(for: busy).map(\.action) == [.newFromTemplate, .editTemplate])
        #expect(model.buttons(for: busy).map(\.isEnabled) == [false, false])
        #expect(model.actions(for: busy).isEmpty)
        let held = LibraryModel(
            registry: FakeRegistry([template("t")]), control: FakeControl(), cloner: FakeCloner(),
            templates: FakeTemplates(), appRunsMachine: { _ in true })
        #expect(held.buttons(for: template("t")).map(\.isEnabled) == [false, false])
    }

}

@MainActor
struct LibraryCloneTests {
    @Test func cloneIsOfferedForStoppedAndSuspendedVMsOnly() async {
        let suspended = VMSummary(
            configID: UUID(), name: "s", status: .stopped, cpuCount: 1, memoryBytes: 1 << 30,
            diskBytes: 1 << 30, isSuspended: true)
        let model = LibraryModel(registry: FakeRegistry(), control: FakeControl(), cloner: FakeCloner())
        #expect(model.menuActions(for: summary("a", .stopped)) == [.clone, .delete])
        #expect(model.menuActions(for: suspended) == [.clone, .delete])
        #expect(model.menuActions(for: summary("a", .running(.cli))).isEmpty)
        #expect(model.menuActions(for: summary("a", .running(.app))).isEmpty)
        #expect(LibraryModel.label(for: .clone) == "Clona")
        // A window of this app is starting it.
        let starting = LibraryModel(
            registry: FakeRegistry(), control: FakeControl(), cloner: FakeCloner(), appRunsMachine: { _ in true })
        #expect(starting.menuActions(for: summary("a", .stopped)).isEmpty)
    }

    @Test func defaultNameAvoidsTakenNames() {
        #expect(LibraryModel.defaultCloneName(for: "debian", taken: ["debian"]) == "debian-copia")
        #expect(LibraryModel.defaultCloneName(for: "debian", taken: ["debian", "Debian-Copia"]) == "debian-copia-2")
        #expect(LibraryModel.defaultCloneName(
            for: "debian", taken: ["debian", "debian-copia", "debian-copia-2"]) == "debian-copia-3")
        // Never longer than a VM name may be.
        let long = String(repeating: "a", count: 63)
        let name = LibraryModel.defaultCloneName(for: long, taken: [long])
        #expect(name.count == 63)
        #expect(name.hasSuffix("-copia"))
        #expect((try? VMName(name)) != nil)
        let second = LibraryModel.defaultCloneName(for: long, taken: [long, name])
        #expect(second.count == 63)
        #expect(second.hasSuffix("-copia-2"))
    }

    @Test func cloneAsksForANameThenClones() async {
        let registry = FakeRegistry([summary("debian", .stopped)])
        let cloner = FakeCloner()
        let model = LibraryModel(registry: registry, control: FakeControl(), cloner: cloner)
        await model.refresh()

        await model.perform(.clone, on: summary("debian", .stopped))
        #expect(model.pendingClone?.name == "debian")
        #expect(model.cloneName == "debian-copia")
        #expect(cloner.clones.isEmpty)

        model.cloneName = "  mia-copia "
        registry.set([summary("debian", .stopped), summary("mia-copia", .stopped)])
        await model.confirmClone()
        #expect(cloner.clones == ["debian>mia-copia"])
        #expect(model.pendingClone == nil)
        #expect(model.cloneError == nil)
        #expect(model.items.map(\.name) == ["debian", "mia-copia"])
    }

    /// A macOS VM: the sheet warns that the copy keeps the guest's identity and, once done,
    /// shows the commands to run in the copy (`VMCloner.cloneNotes`), grouped as in the design,
    /// with "Copia i comandi"; Fine closes it. A Linux clone still closes at once.
    @Test func macCloneShowsNotes() async throws {
        let mac = VMSummary(configID: UUID(), name: "macos-base", status: .stopped, cpuCount: 4,
                            memoryBytes: 8 << 30, diskBytes: 64 << 30, guest: .macos, osVersion: "26.6")
        let cloner = FakeCloner()
        cloner.report(notes: VMCloner.cloneNotes(guest: .macos, name: try VMName("macos-base-copia")))
        let model = LibraryModel(registry: FakeRegistry([mac, summary("debian", .stopped)]), control: FakeControl(),
                                 cloner: cloner)
        await model.refresh()

        await model.perform(.clone, on: mac)
        #expect(model.isMacClone)
        #expect(model.cloneTitle == "Clonare macos-base?")
        #expect(model.cloneMessage == "La copia avrà un nuovo indirizzo di rete e un nuovo identificatore della macchina. Cartelle condivise, snapshot e stato sospeso non vengono copiati.")
        #expect(model.macCloneWarning?.title == "Dentro macOS la copia resta uguale a macos-base")
        #expect(model.macCloneWarning?.detail == "Stesso nome del computer, stesso account con le sue chiavi autorizzate, stesse chiavi host SSH. Dopo la clonazione Nido ti mostra i comandi per cambiarli nella copia.")
        #expect(model.cloneName == "macos-base-copia")
        await model.confirmClone()
        #expect(cloner.clones == ["macos-base>macos-base-copia"])

        let done = try #require(model.cloneDone)
        #expect(done.title == "macos-base-copia è pronta")
        #expect(done.message == "Avviala e cambia la sua identità dentro macOS, con nido ssh macos-base-copia o nel Terminale della VM.")
        #expect(done.groups.map(\.title) == ["Nuove chiavi host SSH", "Nuovo nome del computer"])
        #expect(done.groups.map(\.commands) == [
            ["sudo rm /etc/ssh/ssh_host_* && sudo ssh-keygen -A"],
            ["sudo scutil --set ComputerName macos-base-copia",
             "sudo scutil --set LocalHostName macos-base-copia",
             "sudo scutil --set HostName macos-base-copia"]])
        #expect(done.commandsText == """
            sudo rm /etc/ssh/ssh_host_* && sudo ssh-keygen -A
            sudo scutil --set ComputerName macos-base-copia
            sudo scutil --set LocalHostName macos-base-copia
            sudo scutil --set HostName macos-base-copia
            """)
        #expect(model.pendingClone != nil)
        model.finishClone()
        #expect(model.cloneDone == nil)
        #expect(model.pendingClone == nil)

        // Linux: no notes, no warning; the sheet closes as before.
        cloner.report(notes: [])
        await model.perform(.clone, on: summary("debian", .stopped))
        #expect(!model.isMacClone)
        #expect(model.macCloneWarning == nil)
        await model.confirmClone()
        #expect(model.cloneDone == nil)
        #expect(model.pendingClone == nil)
    }

    @Test func invalidOrTakenNameStaysInTheSheet() async {
        let cloner = FakeCloner()
        let model = LibraryModel(
            registry: FakeRegistry([summary("debian", .stopped), summary("altra", .stopped)]),
            control: FakeControl(), cloner: cloner)
        await model.refresh()
        await model.perform(.clone, on: summary("debian", .stopped))

        model.cloneName = "../x"
        await model.confirmClone()
        #expect(model.cloneError?.hasPrefix("Nome VM non valido") == true)
        #expect(model.pendingClone != nil)

        model.cloneName = "ALTRA"
        await model.confirmClone()
        #expect(model.cloneError == "Esiste già una VM chiamata ALTRA.")
        #expect(cloner.clones.isEmpty)

        // Editing the name clears the message.
        model.cloneName = "nuova"
        #expect(model.cloneError == nil)
    }

    @Test func failedCloneShowsItsReasonAndKeepsTheSheet() async {
        let cloner = FakeCloner()
        cloner.fail(with: .cloneNeedsStoppedVM("debian"))
        let model = LibraryModel(
            registry: FakeRegistry([summary("debian", .stopped)]), control: FakeControl(), cloner: cloner)
        await model.refresh()
        await model.perform(.clone, on: summary("debian", .stopped))
        await model.confirmClone()
        #expect(model.cloneError == "Impossibile clonare debian: la VM debian è in esecuzione: arrestala prima di clonarla.")
        #expect(model.pendingClone?.name == "debian")
        #expect(!model.isCloning)
    }

    /// A snapshot of a stopped VM holds its lock in this app: the card is "Occupata" with the
    /// reason, only Dettagli is offered (not "In esecuzione" from the lock).
    @Test func busyCardDuringStoppedSnapshot() async {
        let held = summary("debian", .running(.app))
        var opened: [String] = []
        let control = FakeControl()
        let model = LibraryModel(
            registry: FakeRegistry([held]), control: control, cloner: FakeCloner(),
            templates: FakeTemplates(), openWindow: { opened.append($0.rawValue) },
            isSnapshotting: { $0 == "debian" })
        await model.refresh()
        #expect(model.cardState(for: held) == .busy("Snapshot in corso"))
        #expect(NidoVMCardState.busy("Snapshot in corso").badge == .busy)
        #expect(String(localized: NidoStatusBadge.Status.busy.label) == "Occupata")
        #expect(model.buttons(for: held).map(\.action) == [.start, .details])
        #expect(model.buttons(for: held).map(\.isEnabled) == [false, true])
        #expect(model.actions(for: held) == [.details])
        // Before a refresh sees the lock: still busy, nothing in the context menu.
        let stopped = summary("debian", .stopped)
        #expect(model.cardState(for: stopped) == .busy("Snapshot in corso"))
        #expect(model.menuActions(for: stopped).isEmpty)
        // Avvia is disabled: performing it does nothing.
        await model.perform(.start, on: stopped)
        #expect(opened.isEmpty)
        #expect(control.stops.isEmpty)
        #expect(control.deletes.isEmpty)
        // A live snapshot (the machine runs in this app) keeps the card of the live VM.
        let live = LibraryModel(
            registry: FakeRegistry([held]), control: FakeControl(), liveState: { _ in .paused },
            appRunsMachine: { _ in true }, isSnapshotting: { _ in true })
        #expect(live.cardState(for: held) == .paused)
    }

    /// While this app clones a VM its card is "Occupata" ("Clonazione in corso"), Dettagli only.
    @Test func busyCardDuringClone() async {
        let cloner = FakeCloner(gated: true)
        let model = LibraryModel(
            registry: FakeRegistry([summary("debian", .stopped), summary("altra", .stopped)]),
            control: FakeControl(), cloner: cloner, templates: FakeTemplates())
        await model.refresh()
        await model.perform(.clone, on: summary("debian", .stopped))
        let task = Task { await model.confirmClone() }
        while !model.isCloning { await Task.yield() }

        #expect(model.cloningSource == "debian")
        #expect(model.cardState(for: summary("debian", .stopped)) == .busy("Clonazione in corso"))
        #expect(model.cardState(for: summary("debian", .running(.app))) == .busy("Clonazione in corso"))
        #expect(model.actions(for: summary("debian", .stopped)) == [.details])
        #expect(model.cardState(for: summary("altra", .stopped)) == .stopped)

        cloner.gate.continuation.yield()
        await task.value
        #expect(model.cloningSource == nil)
        #expect(model.cardState(for: summary("debian", .stopped)) == .stopped)
    }

    /// "Esci al termine": quitting waits for the copy, which ends normally.
    @Test func quitWaitsForClone() async {
        let prompt = LibraryModel.quitPromptDuringClone
        #expect(prompt.question == "Clonazione in corso")
        #expect(prompt.message == "Puoi uscire al termine della copia, oppure interromperla: la copia parziale viene rimossa.")
        #expect(prompt.buttons == ["Esci al termine", "Annulla ed esci", "Annulla"])
        #expect(LibraryModel.CloneAtQuit(buttonIndex: 0) == .wait)
        #expect(LibraryModel.CloneAtQuit(buttonIndex: 1) == .cancel)
        #expect(LibraryModel.CloneAtQuit(buttonIndex: 2) == nil)

        let cloner = FakeCloner(gated: true)
        let model = LibraryModel(
            registry: FakeRegistry([summary("debian", .stopped)]), control: FakeControl(), cloner: cloner)
        await model.refresh()
        await model.perform(.clone, on: summary("debian", .stopped))
        let task = Task { await model.confirmClone() }
        while !model.isCloning { await Task.yield() }

        #expect(model.cloneQuitPrompt == LibraryModel.quitPromptDuringClone)
        let waiting = Task { await model.waitForClone() }
        for _ in 0..<20 { await Task.yield() }
        #expect(cloner.clones.isEmpty)
        cloner.gate.continuation.yield()
        await waiting.value
        #expect(cloner.clones == ["debian>debian-copia"])
        await task.value
        #expect(!model.isCloning)
        #expect(model.cloneError == nil)
        #expect(model.cloneQuitPrompt == nil)
        // Nothing to wait for any more.
        await model.waitForClone()
    }

    /// "Annulla ed esci": the clone is cancelled, its `.cloning-*` folder removed, no new VM and
    /// no error left in the sheet.
    @Test func quitCancelsCloneCleanly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nido-quit-clone-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let cloner = FakeCloner(gated: true, stagingRoot: root)
        let model = LibraryModel(
            registry: FakeRegistry([summary("debian", .stopped)]), control: FakeControl(), cloner: cloner)
        await model.refresh()
        await model.perform(.clone, on: summary("debian", .stopped))
        let task = Task { await model.confirmClone() }
        while !model.isCloning { await Task.yield() }
        while try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty { await Task.yield() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).first?.contains(".cloning-") == true)

        await model.cancelCloneForQuit()
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        #expect(cloner.clones.isEmpty)
        await task.value
        #expect(!model.isCloning)
        #expect(model.cloneError == nil)
        #expect(model.pendingClone == nil)
        #expect(model.cloneQuitPrompt == nil)
        // Without a clone in progress it does nothing.
        await model.cancelCloneForQuit()
    }

    @Test func sheetCannotBeClosedWhileCloning() async {
        let cloner = FakeCloner(gated: true)
        let model = LibraryModel(
            registry: FakeRegistry([summary("debian", .stopped)]), control: FakeControl(), cloner: cloner)
        await model.refresh()
        await model.perform(.clone, on: summary("debian", .stopped))
        let task = Task { await model.confirmClone() }
        while !model.isCloning { await Task.yield() }

        model.cancelClone()
        #expect(model.pendingClone != nil)
        await model.confirmClone()  // a second click does nothing
        cloner.gate.continuation.yield()
        await task.value
        #expect(cloner.clones == ["debian>debian-copia"])
        #expect(model.pendingClone == nil)
        #expect(!model.isCloning)
    }

    // MARK: - macOS (M3b)

    /// A macOS VM shows "macOS <version>" and the glyph M (ruling R4) and never offers "Salva come
    /// modello" (templates are Linux-only).
    @Test func macCardShowsVersionAndNoTemplateAction() async {
        let mac = VMSummary(configID: UUID(), name: "macos-agenti", status: .stopped, cpuCount: 4,
                            memoryBytes: 8 << 30, diskBytes: 64 << 30, guest: .macos, osVersion: "26.6")
        let linux = summary("debian-13", .stopped)
        let model = LibraryModel(registry: FakeRegistry([linux, mac]), control: FakeControl(), cloner: FakeCloner(),
                                 templates: FakeTemplates())
        await model.refresh()
        #expect(LibraryModel.system(of: mac) == "macOS 26.6")
        #expect(LibraryModel.glyph(of: mac) == "M")
        #expect(LibraryModel.system(of: linux) == "Debian 13 · arm64")
        #expect(LibraryModel.glyph(of: linux) == "D")
        #expect(LibraryModel.system(of: summary("rotta", .unreadable(running: nil))) == "Sistema sconosciuto")
        #expect(model.menuActions(for: mac) == [.clone, .delete])
        #expect(model.menuActions(for: linux) == [.clone, .saveAsTemplate, .delete])
        await model.perform(.saveAsTemplate, on: mac)
        #expect(model.pendingSaveTemplate == nil)
    }

    /// An installation has its card while the wizard is closed: progress, Mostra and Annulla…
    /// (asks, then cancels and cleans up), in the name order of the VMs.
    @Test func installingCardShowsProgressAndCancels() async throws {
        let installer = FakeMacInstaller()
        let store = MacInstallStore()
        let model = LibraryModel(registry: FakeRegistry([summary("archivio", .stopped), summary("zeta", .running(.app))]),
                                 control: FakeControl(), installs: store)
        var shown: [String] = []
        model.showInstallation = { shown.append($0.name.rawValue) }
        await model.refresh()
        #expect(model.subtitle == "2 macchine virtuali · 1 in esecuzione")

        let request = MacVMRequest(
            name: try VMName("macos-beta"), ipsw: URL(fileURLWithPath: "/tmp/UniversalMac_26.6_Restore.ipsw"),
            cpuCount: 4, memoryBytes: 8 << 30, diskBytes: 64 << 30, sshUser: "agente", publicKey: validPublicKey)
        let job = store.start(request, version: "26.6", installer: installer)
        await installer.waitUntilInstalling()
        #expect(model.subtitle == "3 macchine virtuali · 1 in esecuzione · 1 in installazione")
        #expect(model.entries.map(\.name) == ["archivio", "macos-beta", "zeta"])
        #expect(LibraryModel.resources(of: job) == "4 CPU · 8 GiB di memoria · disco 64 GiB")
        job.receive(0.42)
        #expect(job.cardText.hasPrefix("Installazione di macOS 26.6 · 42 %"))
        // The search filters installations too.
        model.query = "beta"
        #expect(model.entries.map(\.name) == ["macos-beta"])
        model.query = ""

        model.showInstall(job)
        #expect(shown == ["macos-beta"])

        model.requestCancelInstall(job)
        #expect(model.pendingCancelInstall === job)
        #expect(!installer.wasCancelled)
        model.keepInstall()
        #expect(model.pendingCancelInstall == nil)
        #expect(!installer.wasCancelled)

        model.requestCancelInstall(job)
        await model.confirmCancelInstall()
        #expect(installer.wasCancelled)
        #expect(installer.cleanedUp)
        #expect(store.installations.isEmpty)
        #expect(model.entries.map(\.name) == ["archivio", "zeta"])
        #expect(model.subtitle == "2 macchine virtuali · 1 in esecuzione")
    }

    /// An installation that fails with the wizard closed and no library alive: the store keeps the
    /// failure, a library made later shows it, and dismissing it clears it.
    @Test func backgroundInstallFailureReachesTheLibrary() async throws {
        let installer = FakeMacInstaller()
        let store = MacInstallStore()
        let request = MacVMRequest(
            name: try VMName("macos-beta"), ipsw: URL(fileURLWithPath: "/tmp/x.ipsw"),
            cpuCount: 4, memoryBytes: 8 << 30, diskBytes: 64 << 30, sshUser: "agente", publicKey: validPublicKey)
        _ = store.start(request, version: "26.6", installer: installer)
        await installer.waitUntilInstalling()
        installer.finish(.insufficientSpace(needed: 66 << 30, available: 41 << 30))
        await eventually { store.lastFailure != nil }
        #expect(store.lastFailure == "Installazione di macos-beta non riuscita. Spazio insufficiente: servono 66 GiB, "
            + "disponibili 41 GiB. Nido ha cancellato i file creati; l'IPSW resta dov'è.")
        #expect(store.installations.isEmpty)

        // A throwaway model (a re-created LibraryView) does not take the message away.
        _ = LibraryModel(registry: FakeRegistry(), control: FakeControl(), installs: store)
        let model = LibraryModel(registry: FakeRegistry(), control: FakeControl(), installs: store)
        #expect(model.banner == store.lastFailure)
        model.dismissError()
        #expect(store.lastFailure == nil)
        #expect(model.banner == nil)

        // An action's error is shown first; dismissing it leaves the installation's.
        store.lastFailure = "Installazione di x non riuscita."
        model.error = "Impossibile arrestare y."
        #expect(model.banner == "Impossibile arrestare y.")
        model.dismissError()
        #expect(model.banner == "Installazione di x non riuscita.")
    }

    /// "Annulla l'installazione" on the card with a slow installer: the card says it is cancelling,
    /// its buttons are off, and the app is not held (the wait runs in its own task).
    @Test func cardShowsCancellingWhileWaiting() async throws {
        let installer = FakeMacInstaller()
        installer.ignoreCancel()
        let store = MacInstallStore()
        let model = LibraryModel(registry: FakeRegistry(), control: FakeControl(), installs: store)
        let request = MacVMRequest(
            name: try VMName("macos-beta"), ipsw: URL(fileURLWithPath: "/tmp/x.ipsw"),
            cpuCount: 4, memoryBytes: 8 << 30, diskBytes: 64 << 30, sshUser: "agente", publicKey: validPublicKey)
        let job = store.start(request, version: "26.6", installer: installer)
        await installer.waitUntilInstalling()
        model.requestCancelInstall(job)
        let cancel = Task { await model.confirmCancelInstall() }
        await eventually { installer.wasCancelled }
        #expect(job.isCancelling)
        #expect(job.cardText == "Annullamento dell'installazione di macOS 26.6…")
        #expect(!job.canBeCancelled)
        #expect(model.pendingCancelInstall == nil)
        model.requestCancelInstall(job)
        #expect(model.pendingCancelInstall == nil, "Già in annullamento: niente seconda conferma")
        installer.finishCancelled()
        await cancel.value
        #expect(store.installations.isEmpty)
    }

    /// The "Annullare l'installazione…?" confirmation goes when the installation ends by itself.
    @Test func cancelConfirmationEndsWithTheInstall() async throws {
        let installer = FakeMacInstaller()
        let store = MacInstallStore()
        let model = LibraryModel(registry: FakeRegistry(), control: FakeControl(), installs: store)
        let request = MacVMRequest(
            name: try VMName("macos-beta"), ipsw: URL(fileURLWithPath: "/tmp/x.ipsw"),
            cpuCount: 4, memoryBytes: 8 << 30, diskBytes: 64 << 30, sshUser: "agente", publicKey: validPublicKey)
        let job = store.start(request, version: "26.6", installer: installer)
        await installer.waitUntilInstalling()
        model.requestCancelInstall(job)
        #expect(model.pendingCancelInstall === job)
        installer.finish()
        await eventually { model.pendingCancelInstall == nil }
        #expect(model.pendingCancelInstall == nil)
        #expect(!installer.wasCancelled)
    }

    /// A finished installation keeps its card until the library lists the new VM: never a moment
    /// with neither card.
    @Test func finishedInstallKeepsItsCardUntilListed() async throws {
        let installer = FakeMacInstaller()
        let store = MacInstallStore()
        let registry = FakeRegistry()
        let model = LibraryModel(registry: registry, control: FakeControl(), installs: store)
        await model.refresh()
        let request = MacVMRequest(
            name: try VMName("macos-beta"), ipsw: URL(fileURLWithPath: "/tmp/x.ipsw"),
            cpuCount: 4, memoryBytes: 8 << 30, diskBytes: 64 << 30, sshUser: "agente", publicKey: validPublicKey)
        let job = store.start(request, version: "26.6", installer: installer)
        await installer.waitUntilInstalling()
        installer.finish()
        await eventually { job.state == .finished }
        #expect(model.entries.map(\.name) == ["macos-beta"])
        #expect(model.subtitle == "1 macchina virtuale")
        // A refresh that does not list it yet keeps the card.
        await model.refresh()
        #expect(model.entries.map(\.name) == ["macos-beta"])
        registry.set([VMSummary(configID: UUID(), name: "macos-beta", status: .stopped, cpuCount: 4,
                                memoryBytes: 8 << 30, diskBytes: 64 << 30, guest: .macos, osVersion: "26.6")])
        await model.refresh()
        #expect(store.installations.isEmpty)
        guard case .vm = model.entries.first, model.entries.count == 1 else {
            Issue.record("\(model.entries.map(\.id))")
            return
        }
    }
}
