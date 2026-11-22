// SPDX-License-Identifier: Apache-2.0
import AppKit
import NidoCore
import SwiftUI
import UniformTypeIdentifiers

/// The creation wizard (S02–S06), Debian, Ubuntu Server or macOS, shown as a sheet over the library.
struct WizardView: View {
    @Bindable var model: WizardModel
    @State private var showsPassword = false

    var body: some View {
        NidoWizardStep(
            step: model.stepNumber, stepCount: model.stepTotal,
            verbatim: model.title, subtitle: model.subtitle, message: footerMessage,
            showsBack: model.step != .system && model.phase != .installing, backEnabled: model.canGoBack,
            cancelEnabled: model.canCancel,
            nextLabel: model.nextLabel, nextEnabled: model.isNextEnabled,
            onBack: { model.back() },
            // During a macOS installation Cancel asks first.
            onCancel: { model.requestCancel() },
            onNext: { Task { await model.next() } }
        ) {
            switch model.step {
            case .system: systemPage
            case .download: downloadPage
            case .resources: resourcesPage
            case .access: accessPage
            case .summary: summaryPage
            }
        }
        .task { await model.load() }
        .sheet(isPresented: Binding(get: { model.confirmingMacOffer != nil },
                                    set: { if !$0 { model.declineMacDownload() } })) {
            NidoConfirmSheet(
                verbatim: model.macDownloadQuestion, message: model.macDownloadMessage,
                actionLabel: String(localized: "Download"),
                onCancel: { model.declineMacDownload() },
                onConfirm: { Task { await model.confirmMacDownload() } })
        }
        .sheet(isPresented: $model.isConfirmingCancel) {
            NidoConfirmSheet(
                verbatim: model.cancelQuestion,
                message: String(localized: "Nido stops the installation and deletes the files created so far. The IPSW stays where it is."),
                actionLabel: String(localized: "Cancel Installation"), actionKind: .destructive,
                cancelLabel: String(localized: "Continue"),
                onCancel: { model.keepInstalling() },
                onConfirm: { Task { await model.confirmCancelInstall() } })
        }
    }

    /// Why Next is disabled, when the page itself does not say it already (the resource rows and
    /// the key field show their own errors).
    private var footerMessage: String? {
        switch model.step {
        case .summary: model.isBusy ? nil : model.nextBlocker
        case .access where model.isMac: model.keyError == nil && model.sshUserError == nil ? model.nextBlocker : nil
        case .access: model.keyError == nil && model.modelError == nil ? model.nextBlocker : nil
        case .system: model.isFromTemplate ? model.nextBlocker : nil
        default: nil
        }
    }

    // MARK: - S02

    private var systemPage: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if !model.isFromTemplate {
                HStack(spacing: Theme.Space.l) {
                    tile(glyph: "D", name: "Debian 13", detail: model.systemDetail(for: .debian13),
                         isSelected: !model.isMac && !model.distribution.isUbuntu) {
                        model.selectDistribution(.debian13)
                    }
                    // Ubuntu Server: 26.04 LTS unless 24.04 was chosen below.
                    tile(glyph: "U", name: "Ubuntu Server",
                         detail: model.systemDetail(for: model.distribution.isUbuntu ? model.distribution : .ubuntu2604),
                         isSelected: !model.isMac && model.distribution.isUbuntu) {
                        if !model.distribution.isUbuntu || model.isMac {
                            model.selectDistribution(model.distribution.isUbuntu ? model.distribution : .ubuntu2604)
                        }
                    }
                    // Choosing macOS goes to the image page with Next: Choose… or Download from
                    // Apple, nothing goes online before that button. (DEBUG `-NidoIPSWFile` takes
                    // its file at once.)
                    if model.supportsMacGuests {
                        tile(glyph: "M", name: "macOS",
                             detail: String(localized: "from an IPSW file or from Apple", comment: "Detail under the macOS tile of the wizard."),
                             isSelected: model.isMac) {
                            model.selectSystem(.macos)
                            if model.ipswURL == nil, model.presetIPSW != nil { chooseIPSW() }
                        }
                    } else {
                        // Intel Macs run Linux VMs only: a tile like Windows, not a button.
                        NidoOSTile(glyph: "M", name: "macOS", detail: "Needs Apple silicon", state: .disabled)
                    }
                    NidoOSTile(glyph: "W", name: "Windows 11", detail: "Coming soon", state: .disabled)
                }
                // Every tile as tall as the tallest, tops aligned: a wrapped name or detail no
                // longer shifts its tile.
                .fixedSize(horizontal: false, vertical: true)
                systemNote
                    .font(.nido(Theme.TypeSize.caption))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.isMac {
                // Ruling R4: the M3c features are Linux-only.
                NidoNotice(kind: .info,
                           title: "Monitor, Guest Tools, Ollama, AI bridge and VM templates are Linux-only for now.",
                           detail: "A macOS VM supports the screen, snapshots, suspend, clones, shared folders and nido ssh.",
                           identifier: "mac-linux-only")
            } else {
                if model.distribution.isUbuntu, !model.isFromTemplate { ubuntuVersionSection }
                profileSection
            }
        }
    }

    /// Where the chosen system comes from, under the tiles.
    private var systemNote: Text {
        if model.isMac {
            Text("macOS installs from an IPSW file, betas included: one you choose, or one Nido downloads from Apple when you ask. Installing takes 4 to 20 minutes, depending on the Mac and the disk; you complete macOS Setup Assistant in the VM’s window.")
        } else if model.distribution.isUbuntu {
            Text("Official Ubuntu Server cloud image from cloud-images.ubuntu.com, verified with SHA-256 before use. Windows is coming in a future version.")
        } else {
            Text("Official Debian cloud image from cloud.debian.org, verified with SHA-512 before use. Windows is coming in a future version.")
        }
    }

    /// Ubuntu Server: the LTS release.
    private var ubuntuVersionSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Version")
                .font(.nido(Theme.TypeSize.caption, .semibold))
                .foregroundStyle(Theme.Color.textSecondary)
                .padding(.top, Theme.Space.s)
            HStack(spacing: Theme.Space.m) {
                ForEach([LinuxDistribution.ubuntu2604, .ubuntu2404], id: \.self) { release in
                    NidoProfileTile(verbatim: release.displayName,
                                    detail: release == .ubuntu2604
                                        ? String(localized: "Latest · supported until 2031", comment: "Detail of the Ubuntu 26.04 LTS tile.")
                                        : String(localized: "Supported until 2029", comment: "Detail of the Ubuntu 24.04 LTS tile."),
                                    isSelected: model.distribution == release) { model.selectDistribution(release) }
                        .disabled(model.isBusy)
                }
            }
        }
    }

    /// An OS tile that chooses its system.
    private func tile(glyph: String, name: String, detail: String, isSelected: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            NidoOSTile(glyph: glyph, name: name, verbatim: detail, state: isSelected ? .selected : .normal)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy || model.phase == .installing)
        .accessibilityIdentifier("os-\(glyph)")
    }

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            // The profile (spec E), after the system: what the first boot prepares, or a template.
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Profile")
                    .font(.nido(Theme.TypeSize.caption, .semibold))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .padding(.top, Theme.Space.s)
                HStack(spacing: Theme.Space.m) {
                    ForEach(WizardModel.Profile.allCases, id: \.self) { profile in
                        NidoProfileTile(verbatim: profile.title(for: model.distribution),
                                        id: profile.identifier(for: model.distribution), detail: model.profileDetail(profile),
                                        isSelected: model.profile == profile) { model.selectProfile(profile) }
                    }
                }
            }
            if model.isFromTemplate { templateList }
        }
    }

    /// "From Template": the library's templates.
    @ViewBuilder private var templateList: some View {
        if model.templates.isEmpty {
            NidoInfoRow(label: "No templates",
                        note: "Save a stopped VM as a template from the library, then create new ones from here.") {
                EmptyView()
            }
        }
        ForEach(model.templates) { template in
            NidoChoiceRow(verbatim: template.name, detail: WizardModel.templateDetail(template),
                          isSelected: model.selectedTemplate == template.name) {
                model.selectTemplate(template.name)
            }
        }
        Text("The new VM is an instant copy of the template: no extra space until the disks change. It has a new identity and starts without shared folders and with the AI bridge off.")
            .font(.nido(Theme.TypeSize.caption))
            .foregroundStyle(Theme.Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - S03

    @ViewBuilder private var downloadPage: some View {
        if model.isMac {
            imagePage
        } else {
            debianDownloadPage
        }
    }

    @ViewBuilder private var debianDownloadPage: some View {
        switch model.phase {
        case .downloading, .verifying:
            // Redrawn every second: the time left goes away on a stall, without new progress.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                NidoProgressPanel(verbatim: model.progressTitle, detail: model.progressDetail,
                                  fraction: model.progressFraction)
            }
        case .failed(let message):
            NidoProgressPanel(verbatim: String(localized: "Download failed"), detail: message, isError: true)
        default:
            ForEach(model.downloadRows, id: \.self) { row in
                NidoInfoRow(verbatim: row.label, row.value)
            }
            if let notice = model.buildNotice {
                NidoNotice(kind: notice.isError ? .warning : .info, verbatim: notice.title, detail: notice.detail,
                           actionLabel: notice.actionLabel,
                           action: notice.actionLabel == nil ? nil : { Task { await model.checkForNewBuild() } },
                           identifier: "build-check")
            }
        }
    }

    // MARK: - S03 Immagine macOS

    @ViewBuilder private var imagePage: some View {
        NidoPickerRow(label: "IPSW file", path: model.ipswSummary,
                      buttonLabel: model.ipswURL == nil ? LocalizedStringKey("Choose…") : LocalizedStringKey("Change…"),
                      onChoose: chooseIPSW)
            .disabled(model.macDownload != .idle)
        NidoInfoRow(label: "From Apple", note: "Nido asks Apple which macOS this Mac supports when you press the button, and downloads it only after you confirm.") {
            NidoButton("Download from Apple") { Task { await model.downloadMacFromApple() } }
                .disabled(!model.canDownloadMacFromApple)
                .accessibilityIdentifier("ipsw-download-apple")
        }
        if model.macDownload == .askingApple {
            NidoProgressPanel(title: "Asking Apple", detail: "Which macOS image does Apple offer this Mac?", showsBar: false)
            HStack {
                Spacer(minLength: 0)
                NidoButton("Cancel") { model.cancelMacDownload() }
            }
        } else if model.isDownloadingMac, model.macChecking {
            // Every byte is there: only the check is left, nothing to cancel.
            NidoProgressPanel(title: "Checking the image",
                              detail: "Nido reads the IPSW and checks that this Mac can install it: usually a few seconds.",
                              showsBar: false)
        } else if model.isDownloadingMac {
            // Redrawn every second: the time left goes away on a stall, without new progress.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                NidoProgressPanel(verbatim: model.macDownloadTitle, detail: model.macDownloadDetail,
                                  fraction: model.macDownloadFraction)
            }
            HStack {
                Spacer(minLength: 0)
                NidoButton("Cancel Download") { model.cancelMacDownload() }
                    .accessibilityIdentifier("ipsw-download-cancel")
            }
        } else {
            // A failed download or a pause sits beside the rows of an image already chosen.
            if let error = model.macDownloadError {
                NidoNotice(kind: .error, verbatim: error, detail: model.macDownloadErrorDetail,
                           identifier: "ipsw-download-error")
            } else if let notice = model.macDownloadNotice {
                NidoNotice(kind: .info, verbatim: notice, identifier: "ipsw-download-paused")
            }
            if model.isInspectingImage {
                NidoProgressPanel(title: "Checking the image",
                                  detail: "Nido reads the IPSW and checks that this Mac can install it: usually a few seconds.",
                                  showsBar: false)
            } else if let error = model.macImageError {
                NidoNotice(kind: .error, verbatim: error, detail: model.macImageErrorDetail, identifier: "ipsw-error")
            } else if model.macImage != nil {
                ForEach(model.ipswRows, id: \.self) { row in
                    NidoInfoRow(verbatim: row.label, row.value, note: row.note)
                }
            } else if model.macDownloadError == nil, model.macDownloadNotice == nil {
                NidoNotice(kind: .info, title: "Choose an IPSW file, or download macOS from Apple; a beta works too.",
                           detail: "Nido downloads macOS from Apple only when you ask. It never copies, moves or changes a file you choose.",
                           identifier: "ipsw-hint")
            }
        }
    }

    /// An open panel limited to `.ipsw` files, starting in ~/Downloads (DEBUG `-NidoIPSWFile`:
    /// that file, no panel).
    private func chooseIPSW() {
        if let preset = model.presetIPSW {
            Task { await model.chooseIPSW(preset) }
            return
        }
        // Only `.ipsw` files: never widened to any file if the type cannot be made.
        guard let ipswType = UTType(filenameExtension: "ipsw") else {
            model.ipswPanelUnavailable()
            return
        }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose the macOS IPSW file", comment: "Title of the open panel.")
        panel.prompt = String(localized: "Choose", comment: "The open panel's button.")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [ipswType]
        panel.directoryURL = WizardModel.homeDirectory().appendingPathComponent("Downloads", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.chooseIPSW(url) }
    }

    // MARK: - S04

    private var resourcesPage: some View {
        Group {
            NidoResourceStepper(verbatim: "CPU", detail: model.cpuDetail, error: model.cpuError,
                                value: $model.cpuCount,
                                onDecrement: { model.stepCPU(by: -1) }, onIncrement: { model.stepCPU(by: 1) })
            NidoResourceStepper(label: "Memory", id: "Memoria", detail: model.memoryDetail, error: model.memoryError,
                                value: $model.memoryGiB, unit: "GiB",
                                onDecrement: { model.stepMemory(by: -1) }, onIncrement: { model.stepMemory(by: 1) })
            NidoResourceStepper(label: "Disk", id: "Disco", detail: model.diskDetail, error: model.diskError,
                                value: $model.diskGiB, unit: "GiB",
                                onDecrement: { model.stepDisk(by: -1) }, onIncrement: { model.stepDisk(by: 1) })
            if let warning = model.headroomWarning {
                // MemoryHeadroom: only a warning, Next stays enabled (starting is the user's choice).
                NidoNotice(kind: .warning, verbatim: warning, detail: model.headroomDetail, identifier: "headroom-warning")
            }
        }
        // Read off the main actor, again whenever the memory changes.
        .task(id: model.memoryGiB) { await model.refreshHeadroom() }
    }

    // MARK: - S05

    @ViewBuilder private var accessPage: some View {
        if model.isMac {
            macAccessPage
        } else {
            debianAccessPage
        }
    }

    /// S05 macOS: the key and the account name for `nido ssh`; no software to prepare.
    private var macAccessPage: some View {
        Group {
            NidoPickerRow(label: "SSH public key", path: model.keySummary, onChoose: chooseKey)
            if let error = model.keyError { errorLine(error, identifier: "key-error") }
            NidoTextFieldRow(
                label: "macOS user name",
                note: "The short name of the account you’ll create in Setup Assistant. Only nido ssh uses it, and you can change it later.",
                placeholder: "name", text: $model.sshUser, isInvalid: model.sshUserError != nil,
                identifier: "ssh-user")
            if let error = model.sshUserError { errorLine(error, identifier: "ssh-user-error") }
            if model.offersAccount {
                macAccountSection
            } else {
                NidoNotice(kind: .info, title: "Nido keeps no password unless you later let it authorize its key with the account password (Settings › Agent).",
                           detail: "After Setup Assistant, turn on Remote Login in macOS: the Terminal Access panel in the VM’s window guides you.",
                           identifier: "mac-password-notice")
            }
        }
    }

    /// macOS 27 creates the account at the first start: full name, a generated password by default
    /// (masked, Show, Regenerate) or two fields for one's own, and the agent switch.
    @ViewBuilder private var macAccountSection: some View {
        NidoToggleRow(title: "Create the account for me",
                      explanation: "macOS 27 creates it at the first start, so Setup Assistant doesn’t ask.",
                      isOn: $model.createsAccount, identifier: "mac-account-create")
        if model.createsAccount {
            NidoTextFieldRow(
                label: "Full name", note: "The name macOS shows for the account.",
                placeholder: "Full name", text: $model.accountFullName,
                isInvalid: model.accountError != nil && model.accountFullName.isEmpty,
                identifier: "mac-account-name")
            if model.choosesOwnPassword {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    SecureField(text: $model.accountPassword) { Text("Password") }
                        .accessibilityIdentifier("mac-account-password")
                    SecureField(text: $model.accountPasswordAgain) { Text("Password again") }
                        .accessibilityIdentifier("mac-account-password-again")
                }
                .textFieldStyle(.roundedBorder)
                .font(.nido(Theme.TypeSize.body))
                .nidoRow()
            } else {
                HStack(spacing: Theme.Space.s) {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text("Generated password")
                            .font(.nido(Theme.TypeSize.body, .semibold))
                            .foregroundStyle(Theme.Color.textPrimary)
                        Text(verbatim: showsPassword ? model.generatedPassword : String(repeating: "•", count: 20))
                            .font(.system(size: Theme.TypeSize.body, design: .monospaced))
                            .foregroundStyle(Theme.Color.textSecondary)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("mac-account-generated")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    NidoButton(showsPassword ? "Hide" : "Show") { showsPassword.toggle() }
                        .accessibilityIdentifier("mac-account-show")
                    NidoButton("Regenerate") { model.regeneratePassword() }
                        .accessibilityIdentifier("mac-account-regenerate")
                }
                .nidoRow()
            }
            NidoToggleRow(title: "Choose my own password",
                          explanation: "Instead of the generated one.",
                          isOn: $model.choosesOwnPassword, identifier: "mac-account-choose-own")
            if let error = model.accountError { errorLine(error, identifier: "mac-account-error") }
        }
        NidoToggleRow(title: "Let an agent use this Mac (Nido Agent)",
                      explanation: "Lets an AI agent control this VM through Nido’s MCP tools.",
                      isOn: $model.agentAccess, identifier: "mac-agent-access")
        if model.createsAccount {
            NidoNotice(kind: .info, title: "About the password",
                       detail: "Nido keeps this password in your Mac’s Keychain to set up the VM and authorize its key; you can see it in the VM’s Settings › Agent. macOS in the VM asks for it in System Settings.",
                       identifier: "mac-password-notice")
        } else {
            NidoNotice(kind: .info, title: "Nido keeps no password unless you later let it authorize its key with the account password (Settings › Agent).",
                       detail: "After Setup Assistant, turn on Remote Login in macOS: the Terminal Access panel in the VM’s window guides you.",
                       identifier: "mac-password-notice")
        }
    }

    private func errorLine(_ text: String, identifier: String) -> some View {
        Text(verbatim: text)
            .font(.nido(Theme.TypeSize.caption, .semibold))
            .foregroundStyle(Theme.Color.statusError)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(identifier)
    }

    private var debianAccessPage: some View {
        Group {
            NidoPickerRow(label: "SSH public key", path: model.keySummary, onChoose: chooseKey)
            if let error = model.keyError {
                Text(verbatim: error)
                    .font(.nido(Theme.TypeSize.caption, .semibold))
                    .foregroundStyle(Theme.Color.statusError)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("key-error")
            }
            NidoToggleRow(
                title: "Essential packages",
                explanation: "curl, git, python3, openssh-server, jq and other basic tools. No full system upgrade.",
                isOn: $model.installEssentialPackages)
                .accessibilityIdentifier("option-packages")
            // The product's name is never translated.
            NidoToggleRow(
                verbatim: "Nido Guest Tools",
                explanation: String(localized: "CPU, memory and disk monitoring over vsock, without the network. Ollama and the AI bridge need them.",
                                    comment: "Explanation of the Nido Guest Tools option."),
                isOn: $model.installGuestTools)
                .accessibilityIdentifier("option-guest-tools")
            NidoToggleRow(
                title: "Install Ollama after first boot",
                explanation: model.canInstallOllama
                    ? LocalizedStringKey("Nido installs it from the official sources once the VM is ready: you can already use the VM while it downloads.")
                    : LocalizedStringKey("Ollama needs the Nido Guest Tools: turn them on to choose Ollama."),
                isOn: $model.installOllama, isLocked: !model.canInstallOllama)
                .accessibilityIdentifier("option-ollama")
            if model.isModelEditable {
                NidoInfoRow(verbatim: String(localized: "Model (optional)", comment: "The Ollama model to download (an AI model)."),
                            note: model.modelError ?? model.modelNote) {
                    // An example model name, shown as given.
                    TextField(text: $model.ollamaModel) { Text(verbatim: "llama3.2:1b") }
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .font(.nido(Theme.TypeSize.body))
                        .foregroundStyle(Theme.Color.textPrimary)
                        .frame(width: Theme.Layout.modelFieldWidth)
                        .accessibilityIdentifier("option-model")
                }
            }
        }
    }

    /// An open panel limited to `.pub` files, starting in `~/.ssh`.
    private func chooseKey() {
        // Only `.pub` files: never widened to any file if the type cannot be made.
        guard let pubType = UTType(filenameExtension: "pub") else {
            model.keyPanelUnavailable()
            return
        }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose the SSH public key", comment: "Title of the open panel.")
        panel.prompt = String(localized: "Choose", comment: "The open panel's button.")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.allowedContentTypes = [pubType]
        panel.directoryURL = WizardModel.homeDirectory().appendingPathComponent(".ssh", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.choosePublicKey(url)
    }

    // MARK: - S06

    @ViewBuilder private var summaryPage: some View {
        if model.isMac {
            macSummaryPage
        } else {
            debianSummaryPage
        }
    }

    /// S06 macOS: the summary, then the installation (the wizard may close: the card keeps it).
    @ViewBuilder private var macSummaryPage: some View {
        switch model.phase {
        case .installing, .done:
            // Redrawn every second: the time left goes away on a stall.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                NidoProgressPanel(verbatim: model.installTitle, detail: model.installDetail,
                                  fraction: model.installFraction)
            }
            NidoNotice(kind: .warning, title: "Quitting Nido cancels the installation.",
                       detail: "Nido asks before quitting; the files it created are deleted and the IPSW stays where it is.",
                       identifier: "install-quit-notice")
        case .failed(let message):
            NidoProgressPanel(verbatim: String(localized: "Installation failed"), detail: message, isError: true)
        default:
            nameRow
            NidoColorRow(selection: $model.tint,
                         note: "Tells this VM apart in the library. You can change it later in its settings.")
            ForEach(model.summaryRows, id: \.self) { row in
                NidoInfoRow(verbatim: row.label, row.value, note: row.note)
            }
        }
    }

    private var nameRow: some View {
        NidoInfoRow(label: "Name") {
            TextField("Name", text: $model.name)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.nido(Theme.TypeSize.body))
                .foregroundStyle(Theme.Color.textSecondary)
                .accessibilityIdentifier("wizard-name")
        }
    }

    @ViewBuilder private var debianSummaryPage: some View {
        switch model.phase {
        case .creating, .done:
            NidoProgressPanel(verbatim: model.creationTitle, detail: model.creationDetail)
        case .failed(let message):
            NidoProgressPanel(verbatim: String(localized: "Creation failed"), detail: message, isError: true)
        default:
            nameRow
            NidoColorRow(selection: $model.tint,
                         note: "Tells this VM apart in the library. You can change it later in its settings.")
            ForEach(model.summaryRows, id: \.self) { row in
                NidoInfoRow(verbatim: row.label, row.value, note: row.note)
            }
            if model.isFromTemplate {
                NidoPickerRow(label: "SSH public key", path: model.templateKeySummary, onChoose: chooseTemplateKey)
                if let error = model.keyError {
                    Text(verbatim: error)
                        .font(.nido(Theme.TypeSize.caption, .semibold))
                        .foregroundStyle(Theme.Color.statusError)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// "From Template": another `.pub` than the template's (the same panel as Access).
    private func chooseTemplateKey() {
        guard let url = Self.pickPublicKey() else { return }
        Task { await model.chooseTemplateKey(url) }
    }

    /// An open panel limited to `.pub` files, starting in `~/.ssh`; nil when cancelled or when
    /// the type cannot be made.
    static func pickPublicKey() -> URL? {
        guard let pubType = UTType(filenameExtension: "pub") else { return nil }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose the SSH public key", comment: "Title of the open panel.")
        panel.prompt = String(localized: "Choose", comment: "The open panel's button.")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.allowedContentTypes = [pubType]
        panel.directoryURL = WizardModel.homeDirectory().appendingPathComponent(".ssh", isDirectory: true)
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
