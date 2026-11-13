// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore
import Observation

/// State and actions of the library window (S01).
@MainActor
@Observable
final class LibraryModel {
    /// What a card (or its context menu) can do.
    enum CardAction: Hashable, Sendable {
        case start, open, stop, settings, delete, showInFinder
        /// A stopped (or suspended) VM is copied under a new name: "Clona…" asks for it.
        case clone
        /// A paused VM of this app goes on (`VMWindowModel.resume()`).
        case resume
        /// A suspended VM starts again from its saved state: the same path as Avvia (the start
        /// resumes it).
        case resumeSuspended
        /// A failed start is tried again: the same path as Avvia.
        case retry
        /// The VM's window comes to the front on its error screen, without starting anything.
        case details
        /// A stopped VM becomes a template (after a confirmation).
        case saveAsTemplate
        /// A template: a new VM from it ("Nuova VM…", the name of the new VM first).
        case newFromTemplate
        /// A template becomes a VM that starts again (after a confirmation).
        case editTemplate
    }

    /// A button on a card, as the design shows it: some are present but disabled.
    struct CardButton: Hashable, Sendable {
        let action: CardAction
        let kind: NidoButton.Kind
        let isEnabled: Bool
    }

    /// How often the library rereads the VM root while its window is visible.
    nonisolated static let refreshInterval: Duration = .seconds(2)

    private(set) var items: [VMSummary] = []
    /// False until the first refresh ends: the view shows neither cards nor the empty state.
    private(set) var hasLoaded = false
    /// The message of the last failure, shown above the cards.
    var error: String? {
        didSet { if error == nil { errorFromRefresh = false } }
    }
    /// The VM waiting for the delete confirmation (`NidoConfirmSheet`).
    private(set) var pendingDelete: VMSummary?
    /// The VM waiting for the name of its copy ("Clona…" sheet).
    private(set) var pendingClone: VMSummary?
    /// The name typed in the "Clona…" sheet.
    var cloneName = "" {
        didSet { if cloneName != oldValue { cloneError = nil } }
    }
    /// The "Clona…" sheet is "Nuova VM…" of a template (`createFromTemplate`, not a plain copy).
    private(set) var isCloneFromTemplate = false
    /// A finished clone of a macOS VM: the steps to run in the copy, shown in the sheet until Fine.
    private(set) var cloneDone: CloneNotes?
    /// The VM waiting for the "Salva come modello" confirmation.
    private(set) var pendingSaveTemplate: VMSummary?
    /// The template waiting for the "Modifica modello" confirmation.
    private(set) var pendingEditTemplate: VMSummary?
    /// The space each template takes on the Mac, by name (measured off the main actor).
    private(set) var templateSizes: [String: UInt64] = [:]
    /// The message shown in the "Clone…" sheet (an invalid or taken name, a failed copy).
    private(set) var cloneError: String?
    /// True while the copy runs: the sheet shows its progress and cannot be closed.
    private(set) var isCloning = false
    /// The copy in progress: quitting waits for it ("Esci al termine") or cancels it ("Annulla ed
    /// esci", its `.cloning-*` folder is removed).
    @ObservationIgnored private var cloneTask: Task<[String], any Error>?
    /// Text of the search field: filters the cards by name.
    var query = ""

    /// Opens the VM's window (Avvia, Apri). Set by the view, which owns `openWindow`.
    var openWindow: @MainActor (VMName) -> Void
    /// Shows the VM's window without starting the VM (Dettagli, double click on a live card).
    /// Set by the view, which owns `openWindow`.
    var showWindow: @MainActor (VMName) -> Void
    /// Opens the VM's settings (S08).
    var openSettings: @MainActor (VMName) -> Void
    /// Asks the app's own window to stop a VM it runs (never a signal: it would reach the app).
    /// False when no window of this app runs it (another Nido holds the lock).
    var stopAppVM: @MainActor (VMName) async -> Bool
    /// Resumes a VM paused in a window of this app; false when no window of this app has it.
    var resumeAppVM: @MainActor (VMName) async -> Bool
    /// Drops this app's window model of a deleted VM.
    var forget: @MainActor (VMName) -> Void
    /// Shows the bundle of the named VM in the Finder.
    var revealInFinder: @MainActor (String) -> Void
    /// The state of the VM in a window of this app (`VMSessionStore`), nil when it has none.
    var liveState: @MainActor (String) -> VMRunState?
    /// True while a window model of this app has a machine behind it (starting, running, paused,
    /// stopping, or an error with the machine possibly still running): its lock is this app's.
    var appRunsMachine: @MainActor (String) -> Bool
    /// True while a window of this app runs a snapshot operation on the VM (a live snapshot
    /// pauses it): Riprendi waits for it, so it is disabled meanwhile.
    var isSnapshotting: @MainActor (String) -> Bool
    /// "Ponte AI attivo": the VM runs in this app with its AI bridge attached and on.
    var isBridgeActive: @MainActor (String) -> Bool
    /// "Mostra" on an installing card: the wizard of that installation comes back. Set by the view.
    var showInstallation: @MainActor (MacInstallation) -> Void = { _ in }
    /// The macOS installations of this app: a card each while they run (M3b).
    let installs: MacInstallStore
    /// The installation waiting for the "Annulla…" confirmation of its card; nil as soon as it is
    /// not installing any more (the confirmation never outlives it).
    var pendingCancelInstall: MacInstallation? {
        guard let job = pendingCancelJob, job.isInstalling else { return nil }
        return job
    }
    private var pendingCancelJob: MacInstallation?

    private let registry: any VMRegistryProviding
    /// Nil: "Salva come modello" and "Modifica modello" are not offered.
    private let templates: (any VMTemplating)?
    /// The space a template takes on the Mac (run off the main actor); nil: unknown.
    private let measureTemplate: (@Sendable (String) -> UInt64?)?
    private let control: any VMControlling
    /// Nil: "Clona…" is not offered.
    private let cloner: (any VMCloning)?
    /// The current `error` came from `refresh()`: the next successful refresh clears it, while an
    /// error from an action stays until dismissed.
    private var errorFromRefresh = false

    init(
        registry: any VMRegistryProviding, control: any VMControlling,
        cloner: (any VMCloning)? = nil,
        templates: (any VMTemplating)? = nil,
        openWindow: @escaping @MainActor (VMName) -> Void = { _ in },
        openSettings: @escaping @MainActor (VMName) -> Void = { _ in },
        stopAppVM: @escaping @MainActor (VMName) async -> Bool = { _ in true },
        resumeAppVM: @escaping @MainActor (VMName) async -> Bool = { _ in true },
        forget: @escaping @MainActor (VMName) -> Void = { _ in },
        revealInFinder: @escaping @MainActor (String) -> Void = { _ in },
        liveState: @escaping @MainActor (String) -> VMRunState? = { _ in nil },
        appRunsMachine: @escaping @MainActor (String) -> Bool = { _ in false },
        isSnapshotting: @escaping @MainActor (String) -> Bool = { _ in false },
        isBridgeActive: @escaping @MainActor (String) -> Bool = { _ in false },
        measureTemplate: (@Sendable (String) -> UInt64?)? = nil,
        installs: MacInstallStore? = nil
    ) {
        self.installs = installs ?? MacInstallStore()
        self.registry = registry
        self.templates = templates
        self.isBridgeActive = isBridgeActive
        self.measureTemplate = measureTemplate
        self.control = control
        self.cloner = cloner
        self.openWindow = openWindow
        self.showWindow = { _ in }
        self.openSettings = openSettings
        self.stopAppVM = stopAppVM
        self.resumeAppVM = resumeAppVM
        self.forget = forget
        self.revealInFinder = revealInFinder
        self.liveState = liveState
        self.appRunsMachine = appRunsMachine
        self.isSnapshotting = isSnapshotting
    }

    // MARK: - Data

    var visibleItems: [VMSummary] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return items }
        return items.filter { $0.name.localizedCaseInsensitiveContains(needle) }
    }

    /// The VM cards (templates have their own section).
    var vmItems: [VMSummary] { visibleItems.filter { !$0.isTemplate } }

    /// A card of the VM grid: a VM, or a macOS VM being installed (no bundle yet).
    enum Entry: Identifiable {
        case vm(VMSummary)
        case installing(MacInstallation)

        var name: String {
            switch self {
            case .vm(let vm): vm.name
            case .installing(let job): job.name.rawValue
            }
        }

        var id: String {
            switch self {
            case .vm(let vm): "vm-\(vm.name)"
            case .installing(let job): "install-\(job.id.uuidString)"
            }
        }
    }

    /// The VM grid by name: the VMs and the installations (filtered by the search too).
    var entries: [Entry] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let jobs = cardJobs
            .filter { needle.isEmpty || $0.name.rawValue.localizedCaseInsensitiveContains(needle) }
        let all = vmItems.map(Entry.vm) + jobs.map(Entry.installing)
        return all.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// The installations with a card: running, or finished and not yet in `items` (any case).
    private var cardJobs: [MacInstallation] {
        let listed = Set(items.map { $0.name.lowercased() })
        return installs.installations.filter {
            $0.isInstalling || ($0.hasCard && !listed.contains($0.name.rawValue.lowercased()))
        }
    }

    /// Installations in progress ("in installazione" in the subtitle).
    private var installingCount: Int { installs.installations.count(where: \.isInstalling) }

    /// The message above the cards: an action's error first, else a failed installation's.
    var banner: String? { error ?? installs.lastFailure }
    /// The template cards (section Modelli, hidden when empty).
    var templateItems: [VMSummary] { visibleItems.filter(\.isTemplate) }
    /// The Modelli section is shown only when there are templates.
    var showsTemplates: Bool { items.contains(where: \.isTemplate) }

    /// Toolbar subtitle: "7 virtual machines · 2 templates · 2 running".
    var subtitle: String {
        Self.subtitle(
            count: items.count { !$0.isTemplate } + cardJobs.count, templates: items.count(where: \.isTemplate),
            running: items.count { $0.status.runningOwner != nil }, installing: installingCount)
    }

    nonisolated static func subtitle(count: Int, templates: Int = 0, running: Int, installing: Int = 0) -> String {
        let none = String(localized: "No virtual machines")
        guard count > 0 || templates > 0 else { return none }
        var parts = [count == 0 ? none : String(localized: "\(count) virtual machines", comment: "The library's subtitle.")]
        if templates > 0 { parts.append(String(localized: "\(templates) templates", comment: "The library's subtitle.")) }
        if running > 0 { parts.append(String(localized: "\(running) running", comment: "The library's subtitle: VMs running.")) }
        if installing > 0 {
            parts.append(String(localized: "\(installing) installing",
                                comment: "The library's subtitle: macOS VMs being installed."))
        }
        return parts.joined(separator: " · ")
    }

    /// The caption of the Templates section: "2 · 12.2 GiB on the Mac · they don’t start: they’re
    /// for creating new VMs".
    var templatesCaption: String {
        let names = items.filter(\.isTemplate).map(\.name)
        let known = names.compactMap { templateSizes[$0] }
        var parts = ["\(names.count)"]
        if !known.isEmpty {
            // A saturating sum: an overflow would trap the app.
            let total = known.reduce(UInt64(0)) { $0.addingReportingOverflow($1).overflow ? .max : $0 + $1 }
            let size = ByteSize.text(total)
            parts.append(String(localized: "\(size) on the Mac", comment: "%@ is a size: the templates' space."))
        }
        parts.append(String(localized: "they don’t start: they’re for creating new VMs",
                            comment: "The caption of the Templates section."))
        return parts.joined(separator: " · ")
    }

    /// "Uses 9.8 GiB on the Mac" on a template card.
    func spaceText(for vm: VMSummary) -> String {
        guard let bytes = templateSizes[vm.name] else { return String(localized: "Space used not available") }
        let size = ByteSize.text(bytes)
        return String(localized: "Uses \(size) on the Mac", comment: "%@ is a size: a template's space.")
    }

    /// Measures the templates' space off the main actor.
    func measureTemplates() async {
        guard let measureTemplate else { return }
        let names = items.filter(\.isTemplate).map(\.name)
        let sizes = await Task.detached { () -> [String: UInt64] in
            var sizes: [String: UInt64] = [:]
            for name in names { sizes[name] = measureTemplate(name) }
            return sizes
        }.value
        templateSizes = sizes
    }

    /// "Ponte AI attivo" under the name of a running card.
    func showsBridgePill(for vm: VMSummary) -> Bool {
        cardState(for: vm) == .running && isBridgeActive(vm.name)
    }

    /// "4 CPUs · 8 GiB of memory · 64 GiB disk".
    nonisolated static func resources(of vm: VMSummary) -> String {
        guard let cpu = vm.cpuCount, let memory = vm.memoryBytes, let disk = vm.diskBytes else {
            return String(localized: "CPU, memory and disk unknown")
        }
        return resources(cpu: cpu, memory: memory, disk: disk)
    }

    nonisolated private static func resources(cpu: Int, memory: UInt64, disk: UInt64) -> String {
        let memory = ByteSize.text(memory)
        let disk = ByteSize.text(disk)
        return String(localized: "\(cpu) CPUs · \(memory) of memory · \(disk) disk",
                      comment: "A VM card's resources: CPUs, memory (8 GiB), disk (64 GiB).")
    }

    /// "macOS 26.6" for a macOS VM (ruling R4), "Debian 13 · arm64" or "Ubuntu 26.04 LTS · arm64"
    /// for Linux, "Unknown system" when the config cannot be read.
    nonisolated static func system(of vm: VMSummary) -> String {
        if case .unreadable = vm.status { return String(localized: "Unknown system") }
        if vm.guest == .macos { return vm.osVersion.map { "macOS \($0)" } ?? "macOS" }
        return "\((vm.distribution ?? .debian13).displayName) · arm64"
    }

    /// The letter of the system tile: "M", "D", "U" (Ubuntu), or "?".
    nonisolated static func glyph(of vm: VMSummary) -> String {
        if case .unreadable = vm.status { return "?" }
        if vm.guest == .macos { return "M" }
        return vm.distribution?.isUbuntu == true ? "U" : "D"
    }

    /// The resources of a VM being installed.
    static func resources(of job: MacInstallation) -> String {
        resources(cpu: job.cpuCount, memory: job.memoryBytes, disk: job.diskBytes)
    }

    // MARK: - Installations (M3b)

    /// "Mostra": the installation's wizard again.
    func showInstall(_ job: MacInstallation) {
        guard job.isInstalling else { return }
        showInstallation(job)
    }

    /// "Annulla…": asks first.
    func requestCancelInstall(_ job: MacInstallation) {
        guard job.canBeCancelled else { return }
        pendingCancelJob = job
    }

    /// "Continua" in the confirmation.
    func keepInstall() {
        pendingCancelJob = nil
    }

    /// "Annulla l'installazione": stops it; returns once the installer has removed its files.
    func confirmCancelInstall() async {
        guard let job = pendingCancelInstall else { return }
        pendingCancelJob = nil
        await job.cancel()
        await refresh()
    }

    /// Rereads the VM root.
    func refresh() async {
        defer { hasLoaded = true }
        do {
            items = try await registry.summaries()
            // A finished installation's card gives way to the VM's own.
            installs.prune(listed: items.map(\.name))
            if errorFromRefresh { error = nil }
        } catch {
            let reason = error.localizedDescription
            show(String(localized: "Can’t read the VMs: \(reason)", comment: "%@ is why."), fromRefresh: true)
        }
    }

    /// Refreshes every `refreshInterval` until the calling task is cancelled (the view's `.task`,
    /// cancelled when the library window goes away).
    func refreshWhileVisible() async {
        while !Task.isCancelled {
            await refresh()
            await measureTemplates()
            try? await Task.sleep(for: Self.refreshInterval)
        }
    }

    // MARK: - Cards

    /// The VM this app is cloning (the source; a template too), nil when no copy runs.
    var cloningSource: String? { isCloning ? pendingClone?.name : nil }

    /// Why this app holds the lock of a stopped VM: its clone, or a snapshot operation with no
    /// machine behind it (create, restore or delete). Nil otherwise (a live snapshot keeps the
    /// card of the live VM).
    func busyReason(for vm: VMSummary) -> String? {
        if cloningSource == vm.name { return String(localized: "Cloning in progress") }
        if isSnapshotting(vm.name), !appRunsMachine(vm.name) { return String(localized: "Snapshot in progress") }
        return nil
    }

    /// The card state: busy comes from this app's own work on a stopped VM; starting, paused and
    /// error from a live session of this app; the rest is what the registry knows (the lock of a
    /// busy VM would read "Running").
    func cardState(for vm: VMSummary) -> NidoVMCardState {
        if let reason = busyReason(for: vm) { return .busy(reason) }
        switch liveState(vm.name) {
        case .starting: return .starting
        case .paused, .pausing: return .paused
        case .error(let message):
            // Only for a VM nobody runs, or whose machine this app may still run (a failed pause
            // or forced stop): an Apri refused because another process holds the lock must not
            // hide that the VM is running.
            if vm.status == .stopped || appRunsMachine(vm.name) { return .error(message) }
        case .running, .resuming, .stopping, .stopped, nil: break
        }
        return switch vm.status {
        case .stopped: vm.isSuspended ? .suspended : .stopped
        case .running(.app): .running
        case .running(.cli), .running(.cliOperation): .runningTerminal
        case .unreadable(running: nil): .unreadable(String(localized: "config.json is damaged: the VM can’t be opened."))
        case .unreadable(running: .some):
            .unreadable(String(localized: "config.json is damaged, but the VM is running: stop it before deleting it."))
        }
    }

    /// The buttons on the card, in the design's order (S01 and Components.swift VMCard `details`).
    func buttons(for vm: VMSummary) -> [CardButton] {
        // A template never starts: a new VM from it, or back to a VM (spec E).
        // Disabled while something holds it (a `nido create --from-template`, this app).
        if vm.isTemplate {
            let free = vm.status == .stopped && !appRunsMachine(vm.name) && busyReason(for: vm) == nil
            return [.init(action: .newFromTemplate, kind: .primary, isEnabled: free && cloner != nil),
                    .init(action: .editTemplate, kind: .secondary, isEnabled: free && templates != nil)]
        }
        return switch cardState(for: vm) {
        case .stopped:
            [.init(action: .start, kind: .primary, isEnabled: true),
             .init(action: .settings, kind: .secondary, isEnabled: true)]
        case .starting:
            // Already starting: Avvia is shown, disabled.
            [.init(action: .start, kind: .primary, isEnabled: false),
             .init(action: .stop, kind: .secondary, isEnabled: true)]
        case .running:
            // Impostazioni while running: the hardware is locked there, but the guest actions
            // (Guest Tools, "Richieste di sfondo · Spegni") need the VM on.
            [.init(action: .open, kind: .primary, isEnabled: true),
             .init(action: .stop, kind: .secondary, isEnabled: true),
             .init(action: .settings, kind: .secondary, isEnabled: true)]
        case .runningTerminal:
            // Run by `nido start` in a Terminal: the app can stop it but not open it.
            [.init(action: .start, kind: .primary, isEnabled: false),
             .init(action: .stop, kind: .secondary, isEnabled: true),
             .init(action: .settings, kind: .secondary, isEnabled: true)]
        case .suspended:
            [.init(action: .resumeSuspended, kind: .primary, isEnabled: true),
             .init(action: .settings, kind: .secondary, isEnabled: true)]
        case .paused:
            // While pausing, Riprendi waits for the pause to complete (as in the VM window); during
            // a live snapshot (which pauses the VM itself) it is off until the snapshot resumes it.
            [.init(action: .resume, kind: .primary,
                   isEnabled: liveState(vm.name) == .paused && !isSnapshotting(vm.name)),
             .init(action: .stop, kind: .secondary, isEnabled: true)]
        case .error where appRunsMachine(vm.name):
            // The machine may still run (its session and lock are kept): Riprova could not start
            // anything, Arresta stops it (R-M3A-1).
            [.init(action: .stop, kind: .primary, isEnabled: true),
             .init(action: .details, kind: .secondary, isEnabled: true)]
        case .error:
            [.init(action: .retry, kind: .primary, isEnabled: true),
             .init(action: .details, kind: .secondary, isEnabled: true)]
        case .busy:
            // "Occupata": everything waits for the snapshot or the clone, except Dettagli.
            [.init(action: .start, kind: .primary, isEnabled: false),
             .init(action: .details, kind: .secondary, isEnabled: true)]
        case .unreadable where vm.status.runningOwner != nil:
            // Still running (its lock is held): it can be stopped, not deleted.
            [.init(action: .showInFinder, kind: .secondary, isEnabled: true),
             .init(action: .stop, kind: .secondary, isEnabled: true)]
        case .unreadable:
            [.init(action: .showInFinder, kind: .secondary, isEnabled: true),
             .init(action: .delete, kind: .destructive, isEnabled: true)]
        case .installing:
            // Installations have cards of their own (`entries`), never a VM's state.
            []
        }
    }

    /// Actions offered from the card's context menu besides its buttons.
    func menuActions(for vm: VMSummary) -> [CardAction] {
        // Not while a window of this app is starting it (the registry may not have seen the lock yet).
        guard vm.status == .stopped, !appRunsMachine(vm.name), busyReason(for: vm) == nil else { return [] }
        if vm.isTemplate { return [.delete] }
        var actions: [CardAction] = []
        if cloner != nil { actions.append(.clone) }
        // VM templates are Linux-only (M3b, ruling R4).
        if templates != nil, vm.guest != .macos { actions.append(.saveAsTemplate) }
        return actions + [.delete]
    }

    /// Every action available for the VM right now.
    func actions(for vm: VMSummary) -> [CardAction] {
        buttons(for: vm).filter(\.isEnabled).map(\.action) + menuActions(for: vm)
    }

    nonisolated static func label(for action: CardAction) -> String {
        switch action {
        case .start: String(localized: "Start", comment: "Starts the VM.")
        case .open: String(localized: "Open", comment: "Opens the VM's window.")
        case .stop: String(localized: "Stop", comment: "Shuts the VM down.")
        case .settings: String(localized: "Settings", comment: "Opens the VM's settings.")
        case .delete: String(localized: "Delete")
        case .showInFinder: String(localized: "Show in Finder")
        case .resume, .resumeSuspended: String(localized: "Resume")
        case .retry: String(localized: "Try Again")
        case .details: String(localized: "Details")
        case .clone: String(localized: "Clone")
        case .saveAsTemplate: String(localized: "Save as Template")
        case .newFromTemplate: String(localized: "New VM…", comment: "A new VM from this template.")
        case .editTemplate: String(localized: "Edit Template")
        }
    }

    /// The card's context menu: the actions that ask first end with "…".
    nonisolated static func menuLabel(for action: CardAction) -> String {
        switch action {
        case .clone: String(localized: "Clone…")
        case .saveAsTemplate: String(localized: "Save as Template…")
        case .delete: String(localized: "Delete…")
        default: label(for: action)
        }
    }

    func perform(_ action: CardAction, on vm: VMSummary) async {
        guard actions(for: vm).contains(action) else { return }
        switch action {
        case .start, .open, .retry, .resumeSuspended:
            if let name = validName(vm.name, for: .open) { openWindow(name) }
        case .details:
            if let name = validName(vm.name, for: .open) { showWindow(name) }
        case .resume:
            guard let name = validName(vm.name, for: .resume) else { return }
            if !(await resumeAppVM(name)) {
                show(String(localized: "Can’t resume \(vm.name): it’s open in another instance of Nido; resume it there."))
            }
            await refresh()
        case .settings:
            if let name = validName(vm.name, for: .open) { openSettings(name) }
        case .stop:
            await stop(vm.name)
        case .delete:
            await delete(vm.name)
        case .clone:
            beginClone(vm.name)
        case .newFromTemplate:
            beginClone(vm.name, fromTemplate: true)
        case .saveAsTemplate:
            pendingSaveTemplate = vm
        case .editTemplate:
            pendingEditTemplate = vm
        case .showInFinder:
            revealInFinder(vm.name)
        }
    }

    /// Double click on a card: opens the VM's window (starting it when stopped); a starting, paused
    /// or failed VM only gets its window to the front. Cards that cannot be opened here (run by the
    /// Terminal, unreadable) ignore it.
    func doubleClick(_ vm: VMSummary) async {
        // A template is not opened: its actions are on the card.
        guard !vm.isTemplate else { return }
        switch cardState(for: vm) {
        case .starting, .paused, .error, .busy:
            if let name = validName(vm.name, for: .open) { showWindow(name) }
            return
        default:
            break
        }
        let enabled = buttons(for: vm).filter(\.isEnabled).map(\.action)
        if enabled.contains(.open) {
            await perform(.open, on: vm)
        } else if enabled.contains(.start) {
            await perform(.start, on: vm)
        } else if enabled.contains(.resumeSuspended) {
            await perform(.resumeSuspended, on: vm)
        }
    }

    // MARK: - Stop and delete

    /// A CLI-run VM gets SIGTERM through `VMControl.requestStop`; an app-run VM is asked to stop by
    /// the app itself. A machine of this app's own windows is the app's even before a refresh sees
    /// its lock (a card "Starting" right after Start).
    func stop(_ name: String) async {
        let owner: LockOwner
        if appRunsMachine(name) {
            owner = .app
        } else if let registered = items.first(where: { $0.name == name })?.status.runningOwner {
            owner = registered
        } else {
            return
        }
        guard let vmName = validName(name, for: .stop) else { return }
        switch owner {
        case .app:
            if !(await stopAppVM(vmName)) {
                show(Self.otherInstanceStopMessage(name))
            }
        case .cli, .cliOperation:
            // A maintenance command (snapshot, clone…) is refused with its own message.
            let control = control
            do {
                try await Task.detached { try control.requestStop(vmName) }.value
            } catch {
                show(Self.failure(.stop, name, error))
            }
        }
        await refresh()
    }

    /// Arresta on a VM that another Nido runs: only that instance can stop it (a signal would
    /// close every VM it runs). Shown by the library and by the settings.
    nonisolated static func otherInstanceStopMessage(_ name: String) -> String {
        String(localized: "Can’t stop \(name): it’s open in another instance of Nido; stop it there.")
    }

    /// Asks for confirmation: the VM is removed only by `confirmDelete()`.
    func delete(_ name: String) async {
        pendingDelete = items.first { $0.name == name }
    }

    func cancelDelete() {
        pendingDelete = nil
    }

    func confirmDelete() async {
        guard let vm = pendingDelete else { return }
        pendingDelete = nil
        guard let vmName = validName(vm.name, for: .delete) else { return }
        let control = control
        do {
            try await control.delete(vmName)
            forget(vmName)
        } catch {
            show(Self.failure(.delete, vm.name, error))
        }
        await refresh()
    }

    // MARK: - Clone

    /// Opens the "Clona…" sheet with a free default name (`defaultCloneName`); for a template,
    /// "Nuova VM…" with `defaultNewVMName`.
    func beginClone(_ name: String, fromTemplate: Bool = false) {
        guard !isCloning, let vm = items.first(where: { $0.name == name }), vm.isTemplate == fromTemplate else { return }
        pendingClone = vm
        isCloneFromTemplate = fromTemplate
        let taken = items.map(\.name)
        cloneName = fromTemplate ? Self.defaultNewVMName(from: vm.name, taken: taken)
            : Self.defaultCloneName(for: vm.name, taken: taken)
        cloneError = nil
    }

    /// "<modello>-1", then "-2"… until no VM has it (ignoring case), at most 63 characters.
    nonisolated static func defaultNewVMName(from template: String, taken: [String]) -> String {
        let used = Set(taken.map { $0.lowercased() })
        var index = 1
        while true {
            let suffix = "-\(index)"
            let candidate = String(template.prefix(VMName.maxLength - suffix.count)) + suffix
            if !used.contains(candidate.lowercased()) { return candidate }
            index += 1
        }
    }

    /// The "Clona…" sheet of a macOS VM: its message and the warning about the guest's identity.
    var isMacClone: Bool { pendingClone?.guest == .macos && !isCloneFromTemplate }

    var cloneTitle: String {
        guard let source = pendingClone?.name else { return "" }
        return isCloneFromTemplate ? String(localized: "New VM from \(source)", comment: "%@ is the template's name.")
            : String(localized: "Clone \(source)?")
    }

    var cloneMessage: String {
        if isCloneFromTemplate {
            return String(localized: "The new VM is an instant copy of the template: no extra space until the disks change. It has a new identity and starts without shared folders and with the AI bridge off.")
        }
        if isMacClone {
            return String(localized: "The copy gets a new network address and a new machine identifier. Shared folders, snapshots and the suspended state aren’t copied.")
        }
        return String(localized: "The copy gets a new network address and a new identity; at first boot it takes the new name as its host name. Rosetta is copied; shared folders, snapshots and the suspended state aren’t: the copy starts without shared folders. The AI bridge stays off.")
    }

    /// The warning notice of a macOS clone (ScreensMac.swift, "Clona macOS").
    var macCloneWarning: (title: String, detail: String)? {
        guard isMacClone, let source = pendingClone?.name else { return nil }
        return (String(localized: "Inside macOS the copy stays identical to \(source)", comment: "%@ is the VM being cloned."),
                String(localized: "Same computer name, same account with its authorized keys, same SSH host keys. After cloning, Nido shows you the commands to change them in the copy."))
    }

    /// The steps to run in a fresh macOS clone, grouped as in the design ("Clona macOS completata").
    struct CloneNotes: Equatable, Sendable {
        struct Group: Equatable, Sendable {
            /// The group's identifier for the UI tests (`clone-notes-<id>`), whatever the language.
            let id: String
            let title: String
            let commands: [String]
        }

        let name: String
        let groups: [Group]

        var title: String { String(localized: "\(name) is ready", comment: "%@ is the new VM's name.") }
        var message: String {
            String(localized: "Start it and change its identity inside macOS, with nido ssh \(name) or in the VM’s Terminal.",
                   comment: "%@ is the new VM's name.")
        }
        /// "Copia i comandi": every command, one per line.
        var commandsText: String { groups.flatMap(\.commands).joined(separator: "\n") }

        /// `VMCloner.cloneNotes` ("<what>: <command>") as commands: the SSH host keys first, then
        /// the names (`scutil`), then anything else.
        init(name: String, notes: [String]) {
            self.name = name
            let commands = notes.map { note in
                note.range(of: ": ").map { String(note[$0.upperBound...]) } ?? note
            }
            let keys = commands.filter { $0.contains("ssh-keygen") }
            let names = commands.filter { $0.contains("scutil") }
            let other = commands.filter { !keys.contains($0) && !names.contains($0) }
            groups = [Group(id: "Nuove chiavi host SSH", title: String(localized: "New SSH host keys"), commands: keys),
                      Group(id: "Nuovo nome del computer", title: String(localized: "New computer name"), commands: names),
                      Group(id: "Altri passi", title: String(localized: "Other steps"), commands: other)]
                .filter { !$0.commands.isEmpty }
        }
    }

    /// Fine in the sheet of a finished macOS clone.
    func finishClone() {
        cloneDone = nil
        pendingClone = nil
        isCloneFromTemplate = false
        cloneError = nil
    }

    /// Annulla (not while the copy runs).
    func cancelClone() {
        guard !isCloning else { return }
        cloneDone = nil
        pendingClone = nil
        isCloneFromTemplate = false
        cloneError = nil
    }

    /// Clona in the sheet: checks the name, then copies the VM off the main actor. The sheet
    /// closes on success; on failure it stays open with the reason.
    func confirmClone() async {
        guard let vm = pendingClone, !isCloning, let cloner else { return }
        let typed = cloneName.trimmingCharacters(in: .whitespacesAndNewlines)
        let target: VMName
        let source: VMName
        do {
            target = try VMName(typed)
            source = try VMName(vm.name)
        } catch {
            cloneError = Self.sentence(error.localizedDescription)
            return
        }
        if items.contains(where: { $0.name.lowercased() == typed.lowercased() }) {
            cloneError = String(localized: "A VM named \(typed) already exists.")
            return
        }
        isCloning = true
        cloneError = nil
        let fromTemplate = isCloneFromTemplate
        // A task of its own, so quitting can cancel it (`cancelCloneForQuit`).
        let task = Task { () -> [String] in
            if fromTemplate {
                // The new VM starts with no shared folders and the AI bridge off (spec E, H).
                try await cloner.createFromTemplate(source, as: target)
                return []
            }
            return try await cloner.clone(source, as: target)
        }
        cloneTask = task
        let result = await task.result
        cloneTask = nil
        isCloning = false
        switch result {
        case .success(let notes) where !notes.isEmpty && !task.isCancelled:
            // A macOS copy: the sheet stays with the steps to run in it, until Fine.
            cloneDone = CloneNotes(name: target.rawValue, notes: notes)
        case .success:
            pendingClone = nil
            isCloneFromTemplate = false
        case .failure where task.isCancelled:
            // "Annulla ed esci": the copy and its folder are gone; the app is quitting.
            pendingClone = nil
            isCloneFromTemplate = false
        case .failure(let error):
            let reason = error.localizedDescription
            cloneError = fromTemplate
                ? String(localized: "Can’t create \(typed) from \(vm.name): \(reason).",
                         comment: "%1$@: the new VM; %2$@: the template; %3$@: why.")
                : String(localized: "Can’t clone \(vm.name): \(reason).", comment: "%1$@: the VM's name; %2$@: why.")
        }
        await refresh()
    }

    // MARK: - Quitting during a clone

    /// What quitting does about the copy in progress.
    enum CloneAtQuit: Equatable, Sendable {
        /// "Esci al termine": wait for the copy (never a half-made VM), then quit.
        case wait
        /// "Annulla ed esci": cancel the copy (its `.cloning-*` folder is removed), then quit.
        case cancel

        /// The alert's button index (0 = first): nil for Annulla.
        init?(buttonIndex: Int) {
            switch buttonIndex {
            case 0: self = .wait
            case 1: self = .cancel
            default: return nil
            }
        }
    }

    /// The quit alert while a copy runs: "Quit When Done" (the default), "Cancel and Quit",
    /// "Cancel".
    nonisolated static var quitPromptDuringClone: VMSessionStore.QuitPrompt {
        VMSessionStore.QuitPrompt(
            question: String(localized: "Cloning in progress"),
            message: String(localized: "You can quit when the copy is done, or stop it: the partial copy is removed."),
            buttons: [String(localized: "Quit When Done"), String(localized: "Cancel and Quit"), String(localized: "Cancel")])
    }

    /// The quit alert for the copy in progress, nil when none runs.
    var cloneQuitPrompt: VMSessionStore.QuitPrompt? {
        cloningSource == nil ? nil : Self.quitPromptDuringClone
    }

    /// "Quit When Done": returns once the copy in progress has ended (at once when none runs).
    func waitForClone() async {
        _ = await cloneTask?.result
    }

    /// "Cancel and Quit": cancels the copy in progress and returns once it has stopped and removed
    /// its `.cloning-*` folder. A copy already renamed into place is a whole VM and stays.
    func cancelCloneForQuit() async {
        cloneTask?.cancel()
        await waitForClone()
    }

    // MARK: - Templates (spec E)

    func cancelSaveTemplate() {
        pendingSaveTemplate = nil
    }

    /// "Salva come modello" confirmed: refused (with the core's reason) for a VM that runs or
    /// holds a suspended state.
    func confirmSaveTemplate() async {
        guard let vm = pendingSaveTemplate else { return }
        pendingSaveTemplate = nil
        guard let templates, let name = validName(vm.name, for: .save) else { return }
        do {
            try await templates.save(name)
        } catch {
            let reason = error.localizedDescription
            show(String(localized: "Can’t save \(vm.name) as a template: \(reason).", comment: "%1$@: the VM's name; %2$@: why."))
        }
        await refresh()
        await measureTemplates()
    }

    func cancelEditTemplate() {
        pendingEditTemplate = nil
    }

    /// "Modifica modello" confirmed: the template becomes a VM that starts again.
    func confirmEditTemplate() async {
        guard let vm = pendingEditTemplate else { return }
        pendingEditTemplate = nil
        guard let templates, let name = validName(vm.name, for: .edit) else { return }
        do {
            try await templates.edit(name)
        } catch {
            let reason = error.localizedDescription
            show(String(localized: "Can’t edit the template \(vm.name): \(reason).",
                        comment: "%1$@: the template's name; %2$@: why."))
        }
        await refresh()
    }

    /// "<name>-copy", then "<name>-copy-2", "-3"… ("-copia" in Italian) until no VM has it (ignoring
    /// case); the source part is shortened so the result stays a valid VM name (at most 63
    /// characters).
    nonisolated static func defaultCloneName(for source: String, taken: [String]) -> String {
        let used = Set(taken.map { $0.lowercased() })
        let copy = String(localized: "copy",
                          comment: "The end of a clone's suggested name (debian-13-copy): lowercase letters only, it becomes part of a VM name.")
        var index = 1
        while true {
            let suffix = index == 1 ? "-\(copy)" : "-\(copy)-\(index)"
            let candidate = String(source.prefix(VMName.maxLength - suffix.count)) + suffix
            if !used.contains(candidate.lowercased()) { return candidate }
            index += 1
        }
    }

    /// An error message from NidoCore (lowercase, no final stop) as a sentence.
    nonisolated private static func sentence(_ message: String) -> String {
        message.prefix(1).uppercased() + message.dropFirst() + "."
    }

    /// Chiudi on the banner: the action's error, else the installation's failure.
    func dismissError() {
        if error != nil {
            error = nil
        } else {
            installs.lastFailure = nil
        }
    }

    // MARK: - Helpers

    /// What the library was doing when a VM's name was refused (one sentence each).
    enum Attempt {
        case open, resume, stop, delete, save, edit
    }

    private func validName(_ name: String, for attempt: Attempt) -> VMName? {
        do {
            return try VMName(name)
        } catch {
            show(Self.failure(attempt, name, error))
            return nil
        }
    }

    /// "Can’t stop debian-13: …", the reason from NidoCore after the colon.
    nonisolated static func failure(_ attempt: Attempt, _ name: String, _ error: any Error) -> String {
        let reason = error.localizedDescription
        return switch attempt {
        case .open: String(localized: "Can’t open \(name): \(reason)", comment: "%1$@: the VM's name; %2$@: why.")
        case .resume: String(localized: "Can’t resume \(name): \(reason)", comment: "%1$@: the VM's name; %2$@: why.")
        case .stop: String(localized: "Can’t stop \(name): \(reason)", comment: "%1$@: the VM's name; %2$@: why.")
        case .delete: String(localized: "Can’t delete \(name): \(reason)", comment: "%1$@: the VM's name; %2$@: why.")
        case .save: String(localized: "Can’t save \(name): \(reason)", comment: "%1$@: the VM's name; %2$@: why.")
        case .edit: String(localized: "Can’t edit \(name): \(reason)", comment: "%1$@: the VM's name; %2$@: why.")
        }
    }

    private func show(_ message: String, fromRefresh: Bool = false) {
        // A refresh never hides the message of a failed action.
        if fromRefresh, error != nil, !errorFromRefresh { return }
        error = message
        errorFromRefresh = fromRefresh
    }
}

extension VMStatus {
    /// Who runs the VM, also when its config.json is unreadable; nil when it is stopped.
    var runningOwner: LockOwner? {
        switch self {
        case .stopped: nil
        case .running(let owner): owner
        case .unreadable(let running): running
        }
    }
}
