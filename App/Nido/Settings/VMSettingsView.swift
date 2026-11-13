// SPDX-License-Identifier: Apache-2.0
import AppKit
import NidoCore
import SwiftUI

/// The window id of the VM settings (`WindowGroup(for: String.self)`, the value is the VM name).
enum VMSettingsWindow {
    static let id = "vm-settings"
}

/// Resolves the window's value (the VM name) to a model. The bundle lookup runs once in `.task`.
struct VMSettingsRoot: View {
    let name: String?
    let environment: AppEnvironment?

    @State private var model: VMSettingsModel?
    @State private var network: NetworkSettingsModel?
    @State private var failure: String?

    var body: some View {
        Group {
            if let model {
                VMSettingsView(model: model, network: network, onStop: stop)
            } else if let failure {
                StartupErrorView(message: failure)
            } else {
                Theme.Color.background
            }
        }
        .navigationTitle(Text("\(name ?? "") Settings", comment: "The VM settings window’s title; %@ is the VM’s name."))
        .task(id: name) { resolve() }
    }

    private func resolve() {
        guard let environment, let name else {
            failure = String(localized: "Invalid virtual machine name.")
            return
        }
        do {
            let vmName = try VMName(name)
            let bundle = try VMBundle.open(vmName, paths: environment.paths)
            let sessions = environment.sessions
            model = try VMSettingsModel(
                bundle: bundle,
                isOpenInApp: { !(sessions.liveState(of: name)?.isSettled ?? true) },
                stopAppVM: { await sessions.stop($0) },
                imageCache: environment.imageCacheRoot,
                onConfigurationChanged: { sessions.configurationChanged(vmName) },
                applyLiveShares: { try sessions.applyLiveShares(vmName, $0) },
                guestTools: sessions.guestTools(for: vmName))
            let settings = model
            network = NetworkSettingsModel(
                bundle: bundle, config: try bundle.readConfig(), authenticator: environment.egress.authenticator,
                isRunning: { settings?.isLocked ?? true },
                onConfigurationChanged: { sessions.configurationChanged(vmName) })
        } catch {
            failure = String(localized: "Can’t open the settings of \(name): \(error.localizedDescription)")
        }
    }

    /// "Arresta" (`VMSettingsModel.stop`).
    private func stop() async {
        await model?.stop()
    }
}

/// S08: the settings of one VM. CPU and memory are editable while the VM is stopped.
struct VMSettingsView: View {
    @Bindable var model: VMSettingsModel
    /// Rete (M3d); nil when it could not be built (the section stays disabled).
    var network: NetworkSettingsModel?
    let onStop: () async -> Void

    @Environment(\.openWindow) private var openWindow
    @State private var section = "Hardware"
    @State private var confirmingRosettaInstall = false

    var body: some View {
        NidoSettingsShell(
            verbatim: String(localized: "\(model.name) Settings", comment: "The VM settings window’s title; %@ is the VM’s name."),
            // Accesso is a feature of a later version; Rete needs its model.
            sections: model.sectionNames.map { .init(verbatim: VMSettingsModel.sectionTitle($0), id: $0) }
                + [.init(verbatim: VMSettingsModel.sectionTitle("Accesso"), id: "Accesso", isEnabled: false),
                   .init(verbatim: VMSettingsModel.sectionTitle("Rete"), id: "Rete", isEnabled: network != nil)],
            selection: $section,
            heading: VMSettingsModel.sectionTitle(section),
            intro: intro
        ) {
            switch section {
            case "Generale": general
            case "Condivisione": sharing
            case "Guest Tools" where model.showsGuestTools: guestToolsSection
            case "Rete" where network != nil: networkSection
            default: hardware
            }
        }
        .sheet(isPresented: $confirmingRosettaInstall) {
            NidoConfirmSheet(
                verbatim: String(localized: "Install Rosetta?"),
                message: model.rosettaInstallMessage,
                actionLabel: String(localized: "Install"),
                onCancel: { confirmingRosettaInstall = false },
                onConfirm: {
                    confirmingRosettaInstall = false
                    Task { await model.installRosetta() }
                })
        }
        .task { if model.showsGuestTools { await model.guestTools.load() } }
        .task {
            // The lock changes when the VM starts or stops somewhere else.
            while !Task.isCancelled {
                model.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var intro: String {
        switch section {
        case "Hardware": model.introText
        case "Condivisione": model.sharesIntro
        case "Guest Tools":
            String(localized: "Nido’s software inside the VM: the monitor, the Ollama setup and the AI bridge. Nido installs it over SSH with the VM’s key; packages, files and models stay as they are.")
        case "Rete":
            String(localized: "With the controlled network, every connection of the VM goes through Nido: only connections to the allowed domains get through; everything else is blocked, logged without its content and reported.")
        default: model.showsSSHUser
            ? String(localized: "The virtual machine’s details, its snapshots and the account nido ssh logs in to macOS with.")
            : String(localized: "The virtual machine’s details, read only, and its snapshots.")
        }
    }

    private var general: some View {
        Group {
            NidoInfoRow("Name", model.name, note: "The name is chosen when the VM is created.")
            NidoInfoRow("MAC address", model.macAddress, note: "Assigned when the VM was created.")
            // The way to S09 from the settings (the VM window has a Snapshot button too).
            NidoPickerRow(label: "Snapshots", path: model.snapshotSummary, buttonLabel: "Manage Snapshots…") {
                openWindow(id: SnapshotsWindow.id, value: model.name)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings-snapshots")
            if model.showsSSHUser { sshUserRows }
        }
    }

    /// macOS: the account `nido ssh` logs in as, saved with its own button (also while it runs).
    @ViewBuilder private var sshUserRows: some View {
        NidoTextFieldRow(
            verbatim: model.sshUserLabel, note: model.sshUserNote, placeholder: String(localized: "name"), text: $model.sshUser,
            isInvalid: model.sshUserError != nil, identifier: "settings-ssh-user")
            .onSubmit { Task { await model.saveSSHUser() } }
        HStack(spacing: Theme.Space.m) {
            if let error = model.sshUserError {
                Text(verbatim: error)
                    .font(.nido(Theme.TypeSize.caption, .semibold))
                    .foregroundStyle(Theme.Color.statusError)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-ssh-user-error")
            } else if let error = model.sshUserSaveError {
                Text(verbatim: error)
                    .font(.nido(Theme.TypeSize.caption, .semibold))
                    .foregroundStyle(Theme.Color.statusError)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-ssh-user-save-error")
            } else if model.didSaveSSHUser {
                Text("Saved. nido ssh now uses this account.")
                    .font(.nido(Theme.TypeSize.caption))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .accessibilityIdentifier("settings-ssh-user-saved")
            }
            Spacer(minLength: 0)
            NidoButton("Save", kind: .primary) { Task { await model.saveSSHUser() } }
                .disabled(!model.canSaveSSHUser)
                .accessibilityIdentifier("settings-ssh-user-save")
        }
    }

    @ViewBuilder private var hardware: some View {
        if model.isLocked { notice(model.lockedNotice) }
        if let note = model.suspendedNote { suspendedNotice(note) }
        Group {
            NidoResourceStepper(verbatim: "CPU", detail: model.cpuDetail, error: model.isLocked ? nil : model.cpuError,
                                value: $model.cpuCount,
                                onDecrement: { model.stepCPU(by: -1) }, onIncrement: { model.stepCPU(by: 1) })
            NidoResourceStepper(label: "Memory", id: "Memoria", detail: model.memoryDetail,
                                error: model.isLocked ? nil : model.memoryError,
                                value: $model.memoryGiB, unit: "GiB",
                                onDecrement: { model.stepMemory(by: -1) }, onIncrement: { model.stepMemory(by: 1) })
        }
        .disabled(model.isLocked)
        .opacity(model.isLocked ? Theme.Layout.disabledOpacity : 1)
        NidoInfoRow("Disk", ByteSize.text(model.diskBytes), note: "The disk size is chosen when the VM is created.")
        saveBar
    }

    /// A suspended VM: what a change does to its saved state (no action, only information).
    private func suspendedNotice(_ text: String) -> some View {
        HStack(spacing: Theme.Space.m) {
            NidoStatusBadge(status: .suspended)
            Text(verbatim: text)
                .font(.nido(Theme.TypeSize.body))
                .foregroundStyle(Theme.Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Theme.Space.m)
        .padding(.horizontal, Theme.Space.l)
        .background(Theme.Color.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.m)
                .strokeBorder(Theme.Color.statusPaused, lineWidth: Theme.Layout.hairline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings-suspended-notice")
    }

    private func notice(_ text: String) -> some View {
        HStack(spacing: Theme.Space.m) {
            NidoStatusBadge(status: .running)
            Text(verbatim: text)
                .font(.nido(Theme.TypeSize.body))
                .foregroundStyle(Theme.Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("settings-locked-notice")
            NidoButton("Stop") { Task { await onStop() } }
                .accessibilityIdentifier("settings-stop")
        }
        .padding(.vertical, Theme.Space.m)
        .padding(.horizontal, Theme.Space.l)
        .background(Theme.Color.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.m)
                .strokeBorder(Theme.Color.statusPaused, lineWidth: Theme.Layout.hairline)
        }
    }

    // MARK: - Rete

    @ViewBuilder private var networkSection: some View {
        if let network {
            if model.isLocked { notice(model.networkLockedNotice) }
            NetworkSettingsSection(model: network)
        }
    }

    // MARK: - Condivisione

    @ViewBuilder private var sharing: some View {
        if model.isLocked { notice(model.sharesLockedNotice) }
        if let note = model.suspendedNote { suspendedNotice(note) }
        if let live = model.liveNotice {
            NidoNotice(kind: .info, verbatim: live, identifier: "share-live-notice")
        }
        if model.sharedFolders.isEmpty {
            NidoInfoRow(label: "No shared folders",
                        note: "The VM can’t see any files on the Mac. Add a folder to make it visible in \(model.guestMountPoint).") {
                EmptyView()
            }
            .accessibilityIdentifier("share-empty")
        }
        ForEach(model.sharedFolders, id: \.name) { folder in
            shareRows(folder)
        }
        if let command = model.legacyGuestCommand { legacyHint(command) }
        shareBar
        if model.showsRosetta { rosettaRows }
    }

    // MARK: - Rosetta

    @ViewBuilder private var rosettaRows: some View {
        NidoToggleRow(
            verbatim: String(localized: "Rosetta (x86_64 binaries)"),
            explanation: model.rosettaExplanation,
            isOn: Binding(
                get: { model.rosetta },
                set: { value in Task { await model.setRosetta(value) } }),
            isLocked: model.isRosettaLocked)
            .accessibilityIdentifier("rosetta-toggle")
        if model.canInstallRosetta || model.isInstallingRosetta {
            NidoInfoRow(label: "Rosetta isn’t installed on this Mac",
                        note: "It’s a macOS system component; installing it needs your confirmation.") {
                NidoButton(model.isInstallingRosetta ? "Installing…" : "Install Rosetta…") {
                    confirmingRosettaInstall = true
                }
                .disabled(!model.canInstallRosetta)
                .accessibilityIdentifier("rosetta-install")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("rosetta-install-row")
        }
        if let command = model.rosettaLegacyCommand {
            guestCommandHint(
                label: String(localized: "Rosetta: VM created with an earlier version of Nido"),
                note: String(localized: "To use Rosetta, run this once in the VM:\n\(command)"), command: command,
                copyID: "rosetta-copy-command", rowID: "rosetta-legacy-command")
        }
    }

    private func shareRows(_ folder: SharedFolder) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            NidoInfoRow(verbatim: folder.name, note: shareNote(folder)) {
                NidoButton("Remove") { Task { await model.removeSharedFolder(folder.name) } }
                    .disabled(!model.canEditShares)
                    .accessibilityIdentifier("share-remove-\(folder.name)")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("share-row-\(folder.name)")
            NidoToggleRow(
                verbatim: String(localized: "Read only"),
                explanation: readOnlyExplanation(folder),
                isOn: Binding(
                    get: { folder.readOnly },
                    set: { value in Task { await model.setReadOnly(value, for: folder.name) } }),
                isLocked: !model.canEditShares)
                .accessibilityIdentifier("share-readonly-\(folder.name)")
        }
    }

    private func shareNote(_ folder: SharedFolder) -> String {
        let place = "\(folder.hostPath) → \(folder.guestPath(for: model.guest))"
        return model.problem(for: folder).map { "\(place)\n\($0)" } ?? place
    }

    private func readOnlyExplanation(_ folder: SharedFolder) -> String {
        if model.isLocked, !model.canEditSharesLive { return String(localized: "Can be changed only with the VM stopped.") }
        return folder.readOnly
            ? String(localized: "The VM reads the files but can’t change or delete them.")
            : String(localized: "The VM can change and delete the files in this folder on the Mac: turn this on only if you need it.")
    }

    private func legacyHint(_ command: String) -> some View {
        guestCommandHint(
            label: String(localized: "Shared folders: VM created with an earlier version of Nido"),
            note: String(localized: "To see the folders in \(SharedFolder.guestMountPoint), run this once in the VM:\n\(command)"),
            command: command, copyID: "share-copy-command", rowID: "share-legacy-command")
    }

    /// A one-time command for a VM created by an older Nido, with a Copia button.
    private func guestCommandHint(
        label: String, note: String, command: String, copyID: String, rowID: String
    ) -> some View {
        NidoInfoRow(verbatim: label, note: note) {
            NidoButton("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
            .accessibilityIdentifier(copyID)
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(rowID)
    }

    private var shareBar: some View {
        HStack(spacing: Theme.Space.m) {
            if let error = model.shareError {
                Text(verbatim: error)
                    .font(.nido(Theme.TypeSize.caption, .semibold))
                    .foregroundStyle(Theme.Color.statusError)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("share-error")
            }
            Spacer(minLength: 0)
            NidoButton("Add Folder…", kind: .primary, action: chooseFolder)
                .disabled(!model.canEditShares)
                .accessibilityIdentifier("share-add")
        }
    }

    /// NSOpenPanel for one folder; the choice is checked and shared read-only by the model.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Share")
        panel.message = String(localized: "Choose a folder on the Mac to show in \(model.guestMountPoint) (read only).")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.addSharedFolder(path: url.path) }
    }

    // MARK: - Guest Tools

    @ViewBuilder private var guestToolsSection: some View {
        let tools = model.guestTools
        if let failure = tools.failure, failure.offersManual {
            NidoNotice(kind: .error, verbatim: failure.title, detail: failure.detail, actionLabel: String(localized: "Try Again"),
                       action: { Task { await tools.install() } }, identifier: "guest-tools-failure")
            NidoInfoRow(verbatim: String(localized: "Manual installation"),
                        note: [String(localized: "To install them yourself you need access to the VM: an SSH session that works (even from another Mac) or a password you set earlier for the user nido (VMs created by Nido have none). Paste the commands in that session: they fit in a single paste, even in Nido’s console. From Terminal, nido ssh \(model.name) uses the same key as the VM."),
                               tools.manualCommandPreview ?? ""].joined(separator: "\n")) {
                NidoButton("Copy Commands") {
                    guard let command = tools.manualCommand else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
                .accessibilityIdentifier("guest-tools-copy-manual")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("guest-tools-manual")
        } else if let failure = tools.failure {
            NidoNotice(kind: .error, verbatim: failure.title, detail: failure.detail,
                       actionLabel: failure.offersTerminal ? String(localized: "Open Terminal") : nil,
                       action: failure.offersTerminal ? { openTerminal() } : nil,
                       identifier: "guest-tools-failure")
        }
        if let message = tools.message {
            NidoNotice(kind: .info, verbatim: message, identifier: "guest-tools-message")
        }
        if tools.needsKey {
            NidoPickerRow(label: "SSH key of \(model.name)",
                          path: tools.keyError ?? String(localized: "Choose the public key (.pub) the VM was created with."),
                          onChoose: {
                              guard let url = WizardView.pickPublicKey() else { return }
                              Task { await tools.chooseKey(url) }
                          })
                .accessibilityIdentifier("guest-tools-key")
        }
        NidoInfoRow(verbatim: guestToolsLabel(tools), note: guestToolsNote(tools)) {
            NidoButton(tools.busy == .install ? "Installing…"
                       : tools.installedVersion == nil ? "Install Guest Tools" : "Reinstall Guest Tools") {
                Task { await tools.install() }
            }
            .disabled(tools.isBusy)
            .accessibilityIdentifier("guest-tools-install")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("guest-tools-row")
        NidoInfoRow(label: "Hang protection settings",
                    note: "If the kernel panics, the message appears in the console log and the VM restarts after 10 seconds instead of hanging. They apply from the next restart.") {
            NidoButton(tools.busy == .panic ? "Applying…" : "Apply") {
                Task { await tools.applyPanicSettings() }
            }
            .disabled(tools.isBusy)
            .accessibilityIdentifier("guest-tools-panic")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("guest-tools-panic-row")
        NidoInfoRow(verbatim: String(localized: "Background requests"), note: tools.quietNote) {
            NidoButton(tools.busy == .quiet ? "Applying…" : "Turn Off") {
                Task { await tools.quietBackground() }
            }
            .disabled(tools.isBusy)
            .accessibilityIdentifier("guest-tools-quiet")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("guest-tools-quiet-row")
        Text("This needs \(model.name) running and its SSH key. Nido never changes a VM by itself.")
            .font(.nido(Theme.TypeSize.caption))
            .foregroundStyle(Theme.Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func guestToolsLabel(_ tools: GuestToolsModel) -> String {
        guard let version = tools.installedVersion else { return String(localized: "Guest Tools not installed") }
        return "Guest Tools \(version)"
    }

    private func guestToolsNote(_ tools: GuestToolsModel) -> String {
        guard let version = tools.installedVersion else {
            return String(localized: "\(model.name) was created without Guest Tools or with an earlier version of Nido. The monitor starts responding after the next restart.")
        }
        return version == GuestToolsPayload.version
            ? String(localized: "Installed and up to date: the monitor and the AI bridge use them.")
            : String(localized: "This version of Nido comes with Guest Tools \(GuestToolsPayload.version): reinstall them to update them.")
    }

    private func openTerminal() {
        guard let vmName = try? VMName(model.name) else { return }
        TerminalLauncher.openSSH(to: vmName)
    }

    private var saveBar: some View {
        HStack(spacing: Theme.Space.m) {
            if let error = model.error {
                Text(verbatim: error)
                    .font(.nido(Theme.TypeSize.caption, .semibold))
                    .foregroundStyle(Theme.Color.statusError)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-error")
            } else if model.didSave {
                Text("Saved. The changes apply from the next start.")
                    .font(.nido(Theme.TypeSize.caption))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .accessibilityIdentifier("settings-saved")
            }
            Spacer(minLength: 0)
            NidoButton("Save", kind: .primary) { Task { await model.save() } }
                .disabled(!model.canSave)
                .accessibilityIdentifier("settings-save")
        }
    }
}
