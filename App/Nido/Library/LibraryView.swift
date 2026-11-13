// SPDX-License-Identifier: Apache-2.0
import AppKit
import NidoCore
import SwiftUI

/// The library window (S01): the toolbar, then the empty state or one card per VM.
struct LibraryView: View {
    @State private var model: LibraryModel
    /// The creation wizard while its sheet is shown.
    @State private var wizard: WizardModel?
    @Environment(\.openWindow) private var openWindow
    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        let paths = environment.paths
        _model = State(initialValue: LibraryModel(
            registry: environment.registry, control: LiveVMControl(paths: paths),
            cloner: LiveVMCloner(paths: paths), templates: LiveVMTemplates(paths: paths),
            stopAppVM: { name in await environment.sessions.stop(name) },
            resumeAppVM: { name in await environment.sessions.resume(name) },
            forget: { name in environment.sessions.forget(name) },
            revealInFinder: { name in Self.reveal(name, in: paths) },
            liveState: { name in environment.sessions.liveState(of: name) },
            appRunsMachine: { name in environment.sessions.runsMachine(name) },
            isSnapshotting: { name in environment.sessions.isSnapshotting(name) },
            isBridgeActive: { name in environment.sessions.isAIBridgeActive(name) },
            measureTemplate: { name in LiveVMTemplates.allocatedBytes(of: name, paths: paths) },
            installs: environment.macInstalls))
        self.environment = environment
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            // An action's error, else an installation that failed with its wizard closed.
            if let banner = model.banner { errorBanner(banner) }
            content
        }
        .background(Theme.Color.background)
        .task {
            // Quitting finds the clone in progress here (a library reopened during a copy leaves
            // the model that runs it in place).
            if environment.library?.isCloning != true { environment.library = model }
            // Avvia, Apri and "Crea e avvia": the VM starts unless it is alive, and its one window
            // opens (or comes to the front).
            let sessions = environment.sessions
            model.openWindow = { name in
                sessions.open(name)
                openWindow(id: VMWindow.id, value: name.rawValue)
            }
            // Dettagli and a double click on a live card: the window only, nothing starts.
            model.showWindow = { name in
                openWindow(id: VMWindow.id, value: name.rawValue)
            }
            model.openSettings = { name in
                openWindow(id: VMSettingsWindow.id, value: name.rawValue)
            }
            // Block notices of every VM (M3d): "Apri il registro" opens the VM's window.
            environment.egress.openWindow = { name in
                openWindow(id: VMWindow.id, value: name.rawValue)
            }
            environment.egress.start()
            // "Mostra" on an installing card: the same wizard, showing the installation.
            model.showInstallation = { job in
                guard wizard == nil, let installing = job.wizard else { return }
                installing.reopen()
                configure(installing)
                wizard = installing
                environment.activeWizard = installing
            }
            if environment.showsReleaseNotes, ReleaseNotesSeen(defaults: .standard).shouldShow() {
                openWindow(id: ReleaseNotesWindow.id)
            }
            #if DEBUG
                // DEBUG `-NidoWizardFixture`: the wizard opens in a fixed state (screenshot tests).
                if let fixture = environment.wizardFixture, wizard == nil {
                    startWizard()
                    wizard?.apply(fixture)
                }
                // DEBUG `-NidoOpenVM`: that VM's window, as Avvia would open it.
                if let name = environment.takeOpenAtLaunch() { model.openWindow(name) }
            #endif
            // `.task` is cancelled when the window goes away: no refresh while it is not shown.
            await model.refreshWhileVisible()
        }
        .background {
            // A second sheet on its own view: one `.sheet` per view is the reliable form.
            Color.clear.sheet(item: $wizard) { wizard in
                WizardView(model: wizard)
                    .interactiveDismissDisabled(wizard.isBusy)
                    // Closed by any path (Annulla, Esc): a running download stops and cleans up; a
                    // macOS installation goes on (its card shows it).
                    .onDisappear { wizard.sheetClosed() }
            }
        }
        .background {
            // "Clona…": a third sheet, on its own view as well.
            Color.clear.sheet(item: pendingClone) { vm in
                CloneSheet(model: model, source: vm.name)
            }
        }
        .background {
            // "Cancel…" on an installing card: asks first.
            Color.clear.sheet(item: pendingCancelInstall) { job in
                NidoConfirmSheet(
                    title: "Cancel installing \(job.name.rawValue)?",
                    message: "Nido stops the installation and deletes the files created so far. The IPSW stays where it is.",
                    actionLabel: "Cancel Installation", actionKind: .destructive, cancelLabel: "Continue",
                    onCancel: { model.keepInstall() },
                    onConfirm: { Task { await model.confirmCancelInstall() } })
            }
        }
        .background {
            // "Salva come modello…" (spec E).
            Color.clear.sheet(item: pendingSaveTemplate) { vm in
                SaveTemplateSheet(
                    name: vm.name, onCancel: { model.cancelSaveTemplate() },
                    onConfirm: { Task { await model.confirmSaveTemplate() } })
            }
        }
        .background {
            // "Edit Template": a short confirmation.
            Color.clear.sheet(item: pendingEditTemplate) { vm in
                NidoConfirmSheet(
                    title: "Edit \(vm.name)?",
                    message: "The template becomes a VM again that you can start and update. When you’re done, save it as a template again. VMs already created from the template don’t change.",
                    actionLabel: "Edit Template",
                    onCancel: { model.cancelEditTemplate() },
                    onConfirm: { Task { await model.confirmEditTemplate() } })
            }
        }
        .sheet(item: pendingDelete) { vm in
            NidoConfirmSheet.delete(
                name: vm.name, diskBytes: vm.diskBytes,
                onCancel: { model.cancelDelete() },
                onConfirm: { Task { await model.confirmDelete() } })
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: Theme.Space.l) {
            // The window's own close, minimise and zoom buttons sit here.
            Color.clear.frame(width: Theme.Layout.trafficLightsWidth, height: Theme.Layout.hairline)
            VStack(alignment: .leading, spacing: 0) {
                Text("Library")
                    .font(.nido(Theme.TypeSize.headline, .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(verbatim: model.subtitle)
                    .font(.nido(Theme.TypeSize.caption))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .accessibilityIdentifier("library-subtitle")
            }
            Spacer(minLength: 0)
            NidoSearchField(prompt: "Search VMs", text: $model.query)
            NidoButton("New VM", action: startWizard)
                .accessibilityIdentifier("new-vm")
        }
        .padding(.horizontal, Theme.Space.l)
        .frame(height: Theme.Layout.toolbarHeight)
        .background(Theme.Color.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Color.border).frame(height: Theme.Layout.hairline)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: Theme.Space.m) {
            Text(verbatim: message)
                .font(.nido(Theme.TypeSize.caption, .semibold))
                .foregroundStyle(Theme.Color.statusError)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("library-error")
            NidoButton("Close") { model.dismissError() }
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.s)
        .background(Theme.Color.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Color.border).frame(height: Theme.Layout.hairline)
        }
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if !model.hasLoaded {
            Color.clear
        } else if model.items.isEmpty, !model.installs.isInstalling {
            NidoEmptyState(onCreate: startWizard)
                .padding(Theme.Space.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                if model.showsTemplates {
                    // Two sections (S01 "modelli e ponte attivo"): the VMs, then the templates.
                    VStack(alignment: .leading, spacing: Theme.Space.l) {
                        LibrarySectionHeading(title: "Virtual Machines", caption: "\(model.entries.count)")
                        vmGrid
                        TemplatesSection(model: model, columns: columns)
                            .padding(.top, Theme.Space.s)
                    }
                    .padding(Theme.Space.xl)
                } else {
                    vmGrid.padding(Theme.Space.xl)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var vmGrid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Space.l) {
            ForEach(model.entries) { entry in
                switch entry {
                case .vm(let vm): card(vm)
                case .installing(let job): installCard(job)
                }
            }
        }
    }

    /// Three columns fill the 1100 pt window: (1100 − 2 × 24 − 2 × 16) / 3 = 340, as in the design;
    /// a narrower window gets fewer, wider columns instead of truncated cards.
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Theme.Layout.cardMinWidth), spacing: Theme.Space.l, alignment: .top)]
    }

    /// A macOS VM being installed: progress, Show and Cancel… (the wizard may be closed).
    private func installCard(_ job: MacInstallation) -> some View {
        // Redrawn every second: the time left goes away on a stall.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            NidoVMCard(
                name: job.name.rawValue, system: "macOS \(job.version)", glyph: "M",
                resources: LibraryModel.resources(of: job), state: .installing(job.cardText, job.fraction)
            ) {
                // Finished, until the library lists the VM: nothing left to show or cancel.
                NidoButton("Show") { model.showInstall(job) }
                    .disabled(!job.isInstalling)
                    .accessibilityIdentifier("action-show-install")
                NidoButton("Cancel…") { model.requestCancelInstall(job) }
                    .disabled(!job.canBeCancelled)
                    .accessibilityIdentifier("action-cancel-install")
            }
        }
    }

    private func card(_ vm: VMSummary) -> some View {
        NidoVMCard(
            name: vm.name,
            system: LibraryModel.system(of: vm),
            glyph: LibraryModel.glyph(of: vm),
            resources: LibraryModel.resources(of: vm),
            state: model.cardState(for: vm),
            bridgeActive: model.showsBridgePill(for: vm),
            // Opens the VM's window (or brings it to the front); the model ignores cards that
            // cannot be opened here. Only the card's text reacts, not its buttons.
            onDoubleClick: { Task { await model.doubleClick(vm) } }
        ) {
            ForEach(model.buttons(for: vm), id: \.action) { button in
                NidoButton(verbatim: LibraryModel.label(for: button.action), kind: button.kind) {
                    Task { await model.perform(button.action, on: vm) }
                }
                .disabled(!button.isEnabled)
                .accessibilityIdentifier("action-\(button.action)")
            }
        }
        .contextMenu {
            ForEach(model.menuActions(for: vm), id: \.self) { action in
                Button(LibraryModel.menuLabel(for: action), role: action == .delete ? .destructive : nil) {
                    Task { await model.perform(action, on: vm) }
                }
                .accessibilityIdentifier("menu-\(action)")
            }
        }
    }

    private var pendingClone: Binding<VMSummary?> {
        Binding(get: { model.pendingClone }, set: { if $0 == nil { model.cancelClone() } })
    }

    private var pendingSaveTemplate: Binding<VMSummary?> {
        Binding(get: { model.pendingSaveTemplate }, set: { if $0 == nil { model.cancelSaveTemplate() } })
    }

    private var pendingEditTemplate: Binding<VMSummary?> {
        Binding(get: { model.pendingEditTemplate }, set: { if $0 == nil { model.cancelEditTemplate() } })
    }

    private var pendingCancelInstall: Binding<MacInstallation?> {
        Binding(get: { model.pendingCancelInstall }, set: { if $0 == nil { model.keepInstall() } })
    }

    private var pendingDelete: Binding<VMSummary?> {
        Binding(get: { model.pendingDelete }, set: { if $0 == nil { model.cancelDelete() } })
    }

    // MARK: - Wizard

    /// "Nuova VM" and "Crea VM": the creation wizard (S02–S06), Debian or macOS.
    private func startWizard() {
        guard wizard == nil else { return }
        let images: WizardImageSource = environment.imageFile.map { .localFile($0) }
            ?? .catalog(CloudImageCatalog.debian13, store: environment.imageStore,
                        cacheRoot: environment.imageCacheRoot)
        let creator = LiveVMCreator(paths: environment.paths)
        var checkHeadroom: (@Sendable (UInt64) async -> MemoryHeadroom?)?
        if environment.checksMemoryHeadroom {
            checkHeadroom = { bytes in await creator.headroom(memoryBytes: bytes) }
        }
        let wizard = WizardModel(
            registry: environment.registry, images: images, creator: creator,
            freeDiskBytes: Self.freeSpace(at: environment.paths.root), checkHeadroom: checkHeadroom,
            macInstaller: environment.macInstaller, installs: environment.macInstalls,
            presetIPSW: environment.ipswFile)
        configure(wizard)
        self.wizard = wizard
        environment.activeWizard = wizard
    }

    /// What the wizard does when the VM is ready and when it closes (again for "Mostra": this
    /// library may not be the one that started it).
    private func configure(_ wizard: WizardModel) {
        let library = model
        let sessions = environment.sessions
        wizard.onCreated = { [weak wizard] (name: VMName) in
            // "Crea e avvia": the window follows the first boot (phase 1, then the chosen phase 2)
            // and the VM starts; the RAM warning was shown at Risorse already. A macOS VM opens for
            // Setup Assistant once installed (its RAM is checked then: the installation took time).
            if let wizard, !wizard.isMac, !wizard.isFromTemplate, wizard.installGuestTools {
                sessions.beginProvisioning(name, plan: wizard.phaseTwoPlan)
            }
            sessions.open(name, checkMemory: wizard.map { $0.isFromTemplate || $0.isMac } ?? true)
            library.showWindow(name)
            Task { await library.refresh() }
        }
        wizard.onClose = { self.wizard = nil }
    }

    private static func freeSpace(at url: URL) -> UInt64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) }
    }

    // MARK: - Finder

    /// Selects the VM's bundle in a Finder window (the root when the name is not a valid VM name).
    private static func reveal(_ name: String, in paths: NidoPaths) {
        let url = (try? VMName(name)).map(paths.bundleURL(for:)) ?? paths.root
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
