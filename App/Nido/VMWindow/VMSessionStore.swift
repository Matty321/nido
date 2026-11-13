// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore
import Observation

/// Every VM window model of the app, keyed by VM name: the library reads live states from it,
/// routes "Arresta" of an app-run VM through it, and quitting finds every running VM here.
@MainActor
@Observable
final class VMSessionStore {
    private var models: [VMName: VMWindowModel] = [:]
    @ObservationIgnored private let paths: NidoPaths
    @ObservationIgnored private let factory: any SessionFactory
    /// The remote AI bridge's shared services, for each window's `AIBridgeModel`.
    @ObservationIgnored private let aiBridge: AIBridgeServices?
    /// Set once the user confirmed quitting: nothing may start any more (a VM started during the
    /// stop window would be killed by the exit).
    @ObservationIgnored private(set) var isQuitting = false

    /// The RAM check before a start; nil uses `MemoryHeadroom.check` (the DEBUG fakes pass one
    /// that never warns).
    @ObservationIgnored private let checkHeadroom: (@Sendable (VMBundle) -> MemoryHeadroom?)?

    init(paths: NidoPaths, factory: any SessionFactory, aiBridge: AIBridgeServices? = nil,
         checkHeadroom: (@Sendable (VMBundle) -> MemoryHeadroom?)? = nil) {
        self.paths = paths
        self.factory = factory
        self.aiBridge = aiBridge
        self.checkHeadroom = checkHeadroom
    }

    /// The one model of `name`, created on first use.
    func model(for name: VMName) -> VMWindowModel {
        if let existing = models[name] { return existing }
        // A fake guest (DEBUG) answers for Ollama; otherwise the window uses the VM's SSH.
        let aiRuntime = factory.aiRuntime(for: name).map { runtime in
            let paths = paths
            return AIRuntimeModel(
                readGuestToolsVersion: { try VMBundle.open(name, paths: paths).readConfig().guestToolsVersion },
                makeRuntime: { runtime })
        }
        let model = VMWindowModel(
            name: name, paths: paths, factory: factory, aiBridgeServices: aiBridge, aiRuntime: aiRuntime,
            checkHeadroom: checkHeadroom)
        model.refusesStart = isQuitting
        models[name] = model
        return model
    }

    /// Opening a VM's window (Avvia, Apri, "Crea e avvia") starts the VM unless it is alive.
    /// The RAM of the running VMs is checked first (the window asks over 75 %), unless the
    /// wizard showed that warning already (`checkMemory` false).
    func open(_ name: VMName, checkMemory: Bool = true) {
        guard !isQuitting else { return }
        let model = model(for: name)
        guard model.state.isSettled else { return }
        Task { checkMemory ? await model.requestStart() : await model.start() }
    }

    /// The Guest Tools actions of `name` (S08 and the Monitor share it: one install at a time).
    @ObservationIgnored private var guestToolsModels: [VMName: GuestToolsModel] = [:]

    /// The window is resolved at each call (a window closed and reopened has a new model).
    func guestTools(for name: VMName, services: any GuestToolsServicing = LiveGuestToolsServices()) -> GuestToolsModel? {
        if let existing = guestToolsModels[name] { return existing }
        let bundle = VMBundle(url: paths.bundleURL(for: name))
        let tools = GuestToolsModel(
            bundle: bundle, name: name.rawValue, services: services,
            isRunning: { [weak self] in
                await GuestToolsModel.runs(bundle, inApp: self?.models[name]?.state == .running)
            })
        tools.onInstalled = { [weak self] in
            guard let window = self?.models[name] else { return }
            window.monitor.guestToolsExpected = true
            Task { await window.aiRuntime.loadConfiguration() }
        }
        guestToolsModels[name] = tools
        return tools
    }

    /// The wizard created `name`: its window shows the provisioning (phase 1, then `plan`).
    func beginProvisioning(_ name: VMName, plan: ProvisioningPlan?) {
        model(for: name).provisioning.begin(plan)
    }

    /// S08 Condivisione of a VM running in this app: its session's folders change at once.
    /// Throws `.notRunning` when no window of this app runs it.
    func applyLiveShares(_ name: VMName, _ folders: [SharedFolder]) throws -> [String] {
        guard let model = models[name] else { throw NidoError.notRunning(name.rawValue) }
        return try model.applyLiveShares(folders)
    }

    /// The state of the VM in this app, or nil when no window of this app has it.
    func liveState(of name: String) -> VMRunState? {
        guard let vmName = try? VMName(name) else { return nil }
        return models[vmName]?.state
    }

    /// True while a model of this app has a machine behind `name` (alive, or an error with the
    /// machine possibly still running): the library offers Arresta, not Riprova, for its error.
    func runsMachine(_ name: String) -> Bool {
        guard let vmName = try? VMName(name), let model = models[vmName] else { return false }
        return !model.isGone
    }

    /// "Ponte attivo" for the library: the VM runs in this app with its AI bridge on.
    func isAIBridgeActive(_ name: String) -> Bool {
        guard let vmName = try? VMName(name) else { return false }
        return models[vmName]?.aiBridge.isActive ?? false
    }

    /// The VMs whose bridge is active now, by name (S10 Hugging Face).
    var activeBridgeNames: [String] {
        models.values.filter(\.aiBridge.isActive).map(\.name.rawValue).sorted()
    }

    /// True while the VM's window runs a snapshot operation (S09).
    func isSnapshotting(_ name: String) -> Bool {
        guard let vmName = try? VMName(name) else { return false }
        return models[vmName]?.isSnapshotting ?? false
    }

    /// The VM's settings changed (S08): its window rereads whether a suspended state will resume.
    func configurationChanged(_ name: VMName) {
        models[name]?.syncSuspendedState()
    }

    /// "Riprendi" from the library for a VM paused in this app. False when no model of this app
    /// has a machine for `name`.
    @discardableResult
    func resume(_ name: VMName) async -> Bool {
        guard let model = models[name], !model.isGone else { return false }
        await model.resume()
        return true
    }

    /// Models with a machine behind them (`!isGone`: alive, or possibly still running after a
    /// failed forced stop), sorted by name.
    var liveModels: [VMWindowModel] {
        models.values.filter { !$0.isGone }.sorted { $0.name.rawValue < $1.name.rawValue }
    }

    /// "Arresta" from the library or the settings for a VM this app runs. False when no model of
    /// this app has a machine for `name` (another Nido holds the lock).
    @discardableResult
    func stop(_ name: VMName) async -> Bool {
        guard let model = models[name], !model.isGone else { return false }
        await model.stop()
        return true
    }

    /// The quit was confirmed: from now on no VM starts.
    func beginQuit() {
        isQuitting = true
        for model in models.values { model.refusesStart = true }
    }

    /// The VM was deleted: its model goes (a new VM with that name starts from a fresh one).
    func forget(_ name: VMName) {
        // A VM made later with this name must not see this one's key, failure or installer.
        if guestToolsModels[name]?.isBusy != true { guestToolsModels[name] = nil }
        guard let model = models[name], model.isGone, !model.isSnapshotting else { return }
        models[name] = nil
        snapshotWindows[name] = nil
    }

    // MARK: - Snapshots windows (S09)

    /// Open snapshots windows per VM: their model is never dropped while one is open, so the VM
    /// window and the snapshots window always share one model (and its serialisation).
    @ObservationIgnored private var snapshotWindows: [VMName: Int] = [:]

    /// A snapshots window of `name` opened: its model, kept until `snapshotsWindowClosed`.
    func snapshotsWindowOpened(_ name: VMName) -> VMWindowModel {
        snapshotWindows[name, default: 0] += 1
        return model(for: name)
    }

    func snapshotsWindowClosed(_ name: VMName) {
        guard let count = snapshotWindows[name] else { return }
        // The model stays: a VM window may still show it (a gone model costs nothing and is
        // reused by the next window of this VM).
        snapshotWindows[name] = count > 1 ? count - 1 : nil
    }

    /// VMs with a snapshot operation running (create, restore, delete), also on a stopped VM.
    var snapshotBusyNames: [String] {
        models.values.filter(\.isSnapshotting).map(\.name.rawValue).sorted()
    }

    /// Quitting: waits for every snapshot operation in progress (never a half-copied snapshot or
    /// a restore cut short by the exit).
    func waitForSnapshots() async {
        for model in models.values where model.isSnapshotting {
            await model.waitForSnapshotWork()
        }
    }

    /// Stops every live VM at the same time (each graceful, then forced after 30 s).
    func stopAll() async {
        await withTaskGroup(of: Void.self) { group in
            for model in liveModels {
                group.addTask { await model.stop() }
            }
        }
    }

    /// "Sospendi ed esci": suspends every live VM at the same time; a VM that cannot be suspended
    /// (its configuration, or the save failed) is stopped instead (graceful, then forced after
    /// 30 s). Returns one localized warning per VM stopped instead of suspended.
    func suspendAll() async -> [String] {
        await withTaskGroup(of: String?.self) { group in
            for model in liveModels {
                group.addTask { await model.suspendOrStop() }
            }
            var warnings: [String] = []
            for await warning in group {
                if let warning { warnings.append(warning) }
            }
            return warnings.sorted()
        }
    }

    /// Live VMs whose configuration cannot be saved: quitting with "Sospendi ed esci" stops them.
    func unsuspendableNames() -> [String] {
        liveModels.filter { $0.suspendBlocker() != nil }.map(\.name.rawValue)
    }

    /// The window of `name` went away: its model is dropped once the VM is gone. A model whose
    /// machine may still run stays, since dropping it would release the lock it holds.
    func windowClosed(_ name: VMName) {
        guard let model = models[name], model.isGone, !model.isSnapshotting, snapshotWindows[name] == nil else {
            return
        }
        models[name] = nil
    }

    /// Live VMs in the first `VMWindowModel.firstBootQuitWindow` of their first boot, by name.
    func firstBootNames(now: Date) -> [String] {
        liveModels.filter { $0.isInFirstBoot(now: now) }.map(\.name.rawValue)
    }

    /// The live VMs in their first boot that quitting with `choice` would stop: all of them for
    /// "Arresta ed esci"; for "Sospendi ed esci" only those that cannot be suspended (a suspend
    /// saves the guest's state, so the first boot goes on at the next start).
    func firstBootNames(stoppedBy choice: QuitChoice, now: Date) -> [String] {
        let names = firstBootNames(now: now)
        switch choice {
        case .stop: return names
        case .suspend:
            let unsuspendable = Set(unsuspendableNames())
            return names.filter(unsuspendable.contains)
        }
    }

    /// The alert before quitting during a first boot: "Annulla" first (the default), then "Esci
    /// comunque".
    nonisolated static func firstBootQuitPrompt(names: [String]) -> QuitPrompt {
        // One VM or several: two sentences (the verb and the pronoun agree with the VMs).
        let question = names.count == 1
            ? String(localized: "\(names[0]) is finishing its first boot: quitting now may leave it without SSH access")
            : String(localized: "\(MacInstallStore.nameList(names)) are finishing their first boot: quitting now may leave them without SSH access",
                     comment: "%@ is a list of two or more VM names (“a and b”, “a, b and c”).")
        return QuitPrompt(
            question: question,
            message: String(localized: "The first boot takes about a minute: wait for it to finish, then quit."),
            buttons: [String(localized: "Cancel"), String(localized: "Quit Anyway")])
    }

    /// The quit alert: "Uscire con debian-13 accesa?" or "Uscire con 3 macchine virtuali accese?".
    nonisolated static func quitQuestion(names: [String]) -> String {
        names.count == 1 ? String(localized: "Quit with \(names[0]) running?")
            : String(localized: "Quit with \(names.count) virtual machines running?")
    }

    /// What the user chose in the quit alert.
    enum QuitChoice: Equatable, Sendable {
        case suspend, stop

        /// The alert's button index (0 = first): nil for Annulla.
        init?(buttonIndex: Int) {
            switch buttonIndex {
            case 0: self = .suspend
            case 1: self = .stop
            default: return nil
            }
        }
    }

    /// The quit alert with VMs on: the question, the explanation and the buttons, "Sospendi ed
    /// esci" first (the default).
    struct QuitPrompt: Equatable, Sendable {
        let question: String
        let message: String
        let buttons: [String]
    }

    /// `unsuspendable`: the live VMs whose configuration cannot be saved (they are stopped).
    nonisolated static func quitPrompt(names: [String], unsuspendable: [String]) -> QuitPrompt {
        let message = names.count == 1
            ? String(localized: "Suspend and Quit saves the state of \(names[0]) on the Mac: the next start continues where you left off. Stop and Quit asks it to shut down cleanly and, if it’s still running after 30 seconds, forces it to stop.")
            : String(localized: "Suspend and Quit saves the state of each virtual machine on the Mac: the next start continues each one where you left off. Stop and Quit asks each one to shut down cleanly and forces those still running after 30 seconds to stop.")
        // The VMs that are stopped instead: their own sentence, after the explanation.
        let stopped: String? = switch unsuspendable.count {
        case 0: nil
        case 1: String(localized: "\(unsuspendable[0]) can’t be suspended in its current configuration: it will be stopped.")
        default: String(localized: "\(MacInstallStore.nameList(unsuspendable)) can’t be suspended in their current configuration: they will be stopped.",
                        comment: "%@ is a list of two or more VM names (“a and b”, “a, b and c”).")
        }
        return QuitPrompt(
            question: quitQuestion(names: names), message: [message, stopped].compactMap(\.self).joined(separator: " "),
            buttons: [String(localized: "Suspend and Quit"), String(localized: "Stop and Quit"), String(localized: "Cancel")])
    }
}
