// SPDX-License-Identifier: Apache-2.0
import NidoCore
import SwiftUI

/// S15: the AI view of a VM window, its two modes side by side: Local (Ollama in the VM, the
/// texts stay on the Mac) and Remote (the AI bridge to Hugging Face, the texts leave the Mac).
struct AISectionView: View {
    let model: VMWindowModel
    /// The VM runs in another process (`nido start`); nil while unknown.
    let runsElsewhere: Bool?
    let onOpenTerminal: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.l) {
            AIRuntimeView(
                runtime: model.aiRuntime, vmName: model.name.rawValue, runsElsewhere: runsElsewhere,
                onOpenTerminal: onOpenTerminal)
            AIBridgeView(bridge: model.aiBridge, vmName: model.name.rawValue, runsElsewhere: runsElsewhere)
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.Color.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vm-ai")
        .task(id: model.aiRuntime.isVMRunning) {
            await model.aiRuntime.loadConfiguration()
            if model.aiRuntime.isVMRunning { await model.aiRuntime.refresh() }
        }
    }
}

/// ScreensAI.swift `aiColumn`: one mode, a full-height panel with its title, what it means for
/// privacy and an accessory (a badge, a switch); the content scrolls.
struct AIColumn<Accessory: View, Content: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let identifier: String
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(title)
                        .font(.nido(Theme.TypeSize.title, .semibold))
                        .foregroundStyle(Theme.Color.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text(subtitle)
                        .font(.nido(Theme.TypeSize.caption))
                        .foregroundStyle(Theme.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                accessory()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) { content() }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Color.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.l))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.l)
            .strokeBorder(Theme.Color.border, lineWidth: Theme.Layout.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

/// ScreensAI.swift `listRow`: text on the left, controls on the right, a hairline under it.
struct AIListRow<Trailing: View>: View {
    let title: String
    var detail: String?
    var last = false
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(title)
                    .font(.nido(Theme.TypeSize.body, .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                    .textSelection(.enabled)
                if let detail {
                    Text(detail)
                        .font(.nido(Theme.TypeSize.caption))
                        .foregroundStyle(Theme.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.vertical, Theme.Space.s)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(Theme.Color.border).frame(height: Theme.Layout.hairline) }
        }
    }
}

/// A small caption heading for a group of rows (ScreensAI.swift `groupLabel`): copy (an English
/// key).
struct AIGroupLabel: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(.nido(Theme.TypeSize.caption, .semibold))
            .foregroundStyle(Theme.Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The Local mode (ScreensAI.swift `localeMode`): Ollama's state and actions, the models with
/// their size, a download with its progress, removal, and the local chat.
struct AIRuntimeView: View {
    let runtime: AIRuntimeModel
    let vmName: String
    let runsElsewhere: Bool?
    let onOpenTerminal: () -> Void

    private enum Mode: CaseIterable {
        case models, chat

        var title: LocalizedStringKey {
            switch self {
            case .models: "Models"
            case .chat: "Chat"
            }
        }
    }

    @State private var mode = Mode.models
    @State private var pullName = ""

    var body: some View {
        AIColumn(
            title: "Local", subtitle: "Ollama inside \(vmName): the text doesn’t leave the Mac.", identifier: "ai-locale",
            accessory: { badge }
        ) {
            content
        }
        .sheet(isPresented: confirming) { confirmationSheet }
    }

    // MARK: - State

    private var status: AIRuntimeStatus? { runtime.runtimeStatus }

    @ViewBuilder private var badge: some View {
        if !runtime.isVMRunning {
            NidoStatusBadge(status: .stopped, label: "VM not started")
        } else if let status {
            if !status.installed {
                NidoStatusBadge(status: .stopped, verbatim: String(localized: "Not installed",
                                                                    comment: "Badge: Ollama’s state (Ollama: masculine in it, es, fr)."))
            } else if status.running {
                NidoStatusBadge(status: .running, verbatim: String(localized: "Active",
                                                                   comment: "Badge: Ollama’s state (Ollama: masculine in it, es, fr)."))
            } else {
                NidoStatusBadge(status: .paused, verbatim: String(localized: "Stopped (service)", defaultValue: "Stopped",
                                                                   comment: "Badge: Ollama’s service is stopped (not the VM)."))
            }
        }
    }

    @ViewBuilder private var content: some View {
        if !runtime.isVMRunning {
            stoppedMessage
        } else if runtime.phase1 == .notInstalled {
            NidoNotice(
                kind: .warning, title: "Guest Tools not installed",
                detail: "Ollama is managed through Nido’s Guest Tools: install them from the Monitor view or the VM’s settings.",
                identifier: "ai-locale-no-guest-tools")
        } else if let status {
            messages
            if status.installed { installed(status) } else { notInstalled }
        } else if let refreshError = runtime.refreshError {
            NidoNotice(
                kind: .error, verbatim: String(localized: "Ollama’s status not available"), detail: refreshError,
                actionLabel: String(localized: "Try Again"), action: { Task { await runtime.refresh() } }, identifier: "ai-locale-refresh-error")
        } else {
            HStack(spacing: Theme.Space.s) {
                ProgressView().controlSize(.small)
                Text("Reading Ollama’s status…")
                    .font(.nido(Theme.TypeSize.caption))
                    .foregroundStyle(Theme.Color.textSecondary)
            }
        }
    }

    @ViewBuilder private var stoppedMessage: some View {
        if runsElsewhere == true {
            NidoNotice(
                kind: .info,
                title: "Ollama and the chat are managed here only for VMs started by Nido: \(vmName) was started from Terminal (nido start).",
                identifier: "ai-locale-elsewhere")
        } else {
            Text("Start \(vmName) to manage Ollama, the models and the chat.")
                .font(.nido(Theme.TypeSize.body))
                .foregroundStyle(Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The last action's outcome, an error or a note.
    @ViewBuilder private var messages: some View {
        if let error = runtime.error {
            NidoNotice(
                kind: .error, verbatim: error.message,
                actionLabel: error.offersTerminal ? String(localized: "Open Terminal") : String(localized: "Close"),
                action: error.offersTerminal ? onOpenTerminal : { runtime.dismissError() },
                identifier: "ai-locale-error")
        }
        if let note = runtime.note {
            NidoNotice(kind: .info, verbatim: note, identifier: "ai-locale-note")
        }
        if let activity = runtime.activity, !isPull(activity.action) {
            HStack(spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(Self.activityLabel(activity.action))
                        .font(.nido(Theme.TypeSize.caption))
                        .foregroundStyle(Theme.Color.textSecondary)
                    if let progress = macDownload(activity) {
                        // The Ollama archive downloaded on the Mac before the guest step.
                        NidoMeter(fraction: Double(progress.completedBytes) / Double(progress.totalBytes))
                        Text(verbatim: [String(localized: "On the Mac", comment: "Where Ollama’s archive is being downloaded."),
                                        AIRuntimeModel.progressText(progress)].joined(separator: " · "))
                            .font(.nido(Theme.TypeSize.caption))
                            .foregroundStyle(Theme.Color.textSecondary)
                            .monospacedDigit()
                            .accessibilityIdentifier("ai-locale-download")
                    } else {
                        NidoIndeterminateBar()
                    }
                }
                NidoButton(macDownload(activity) == nil ? "Stop Waiting" : "Cancel Download") { runtime.cancel() }
                    .accessibilityIdentifier("ai-locale-stop-waiting")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("ai-locale-activity")
        }
    }

    private var notInstalled: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Nido installs Ollama from the official sources, in the version Nido has verified, and runs it as a service of the VM on 127.0.0.1:11434.")
                .font(.nido(Theme.TypeSize.body))
                .foregroundStyle(Theme.Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Ollama uses the VM’s CPU: Virtualization offers no GPU to Linux guests, so a small model is best. It takes a few minutes; you can use the VM in the meantime.")
                .font(.nido(Theme.TypeSize.caption))
                .foregroundStyle(Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            NidoButton("Install Ollama", kind: .primary) { Task { await runtime.request(.install) } }
                .disabled(!runtime.canStartAction)
                .accessibilityIdentifier("ai-install-ollama")
        }
    }

    @ViewBuilder private func installed(_ status: AIRuntimeStatus) -> some View {
        // Every button on one line when the language lets them fit; otherwise Uninstall… gets a
        // line of its own (German runs long), never truncated.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.s) {
                serviceButtons(status)
                Spacer(minLength: 0)
                uninstallButton
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.s) { serviceButtons(status) }
                uninstallButton
            }
        }
        Picker("View", selection: $mode) {
            ForEach(Mode.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        // The brand's green for the selected segment (the design), not the system accent.
        .tint(Theme.Color.accent)
        .accessibilityIdentifier("ai-locale-mode")
        switch mode {
        case .models: models(status)
        case .chat: ChatView(chat: runtime.chat, vmName: vmName)
        }
    }

    /// The identifiers keep the Italian labels the UI tests know (`ai-action-Disinstalla…`).
    @ViewBuilder private func serviceButtons(_ status: AIRuntimeStatus) -> some View {
        actionButton("Verify", id: "Verifica", .verify)
        actionButton("Restart", id: "Riavvia", .restart)
        if status.running {
            actionButton(Text("Stop (service)", comment: "Stops Ollama’s service (not the VM)."), id: "Ferma", .stop)
        } else {
            actionButton("Start", id: "Avvia", .start)
        }
        actionButton("Update", id: "Aggiorna", .update)
    }

    private var uninstallButton: some View {
        actionButton("Uninstall…", id: "Disinstalla…", .uninstall(removeModels: false))
    }

    private func actionButton(_ label: LocalizedStringKey, id: String, _ action: AIRuntimeModel.Action) -> some View {
        actionButton(Text(label), id: id, action)
    }

    private func actionButton(_ label: Text, id: String, _ action: AIRuntimeModel.Action) -> some View {
        NidoButton(label: label) { Task { await runtime.request(action) } }
            .disabled(!runtime.canStartAction)
            .accessibilityIdentifier("ai-action-\(id)")
    }

    @ViewBuilder private func models(_ status: AIRuntimeStatus) -> some View {
        let pulling = pullingModel
        VStack(alignment: .leading, spacing: 0) {
            if status.models.isEmpty, pulling == nil {
                Text("No models in the VM.")
                    .font(.nido(Theme.TypeSize.caption))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .padding(.vertical, Theme.Space.s)
            }
            ForEach(Array(status.models.enumerated()), id: \.element.name) { index, model in
                AIListRow(
                    title: model.name, detail: ByteSize.text(model.sizeBytes),
                    last: index == status.models.count - 1 && pulling == nil
                ) {
                    NidoButton("Remove…") { Task { await runtime.request(.remove(model: model.name)) } }
                        .disabled(!runtime.canStartAction)
                        .accessibilityIdentifier("ai-remove-\(model.name)")
                }
            }
            if let pulling { pullRow(pulling) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ai-models")
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            AIGroupLabel("Download a model")
            HStack(spacing: Theme.Space.s) {
                TextField("name:variant, for example llama3.2:1b", text: $pullName)
                    .textFieldStyle(.roundedBorder)
                    .font(.nido(Theme.TypeSize.body))
                    .onSubmit(pull)
                    .accessibilityIdentifier("ai-pull-name")
                NidoButton(label: Text("Download (model)", comment: "Downloads the model typed in the field: a verb."),
                           kind: .primary, action: pull)
                    .disabled(!runtime.canStartAction || pullName.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("ai-pull")
            }
            Text(verbatim: runtime.activity == nil
                 ? Self.pullHint : String(localized: "One operation at a time: wait for the current one to finish."))
                .font(.nido(Theme.TypeSize.caption))
                .foregroundStyle(Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static var pullHint: String {
        let names = AIRuntime.suggestedModels.map(\.name).joined(separator: ", ")
        return String(localized: "From the Ollama library. For a small VM, choose a light model, for example \(names).",
                      comment: "%@ lists model names, separated by commas.")
    }

    private var pullingModel: String? {
        if case .pull(let model, _) = runtime.activity?.action { return model }
        return nil
    }

    /// The model being downloaded: its name, the guest's progress, "Stop Waiting".
    private func pullRow(_ name: String) -> some View {
        HStack(spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(name)
                    .font(.nido(Theme.TypeSize.body, .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                if let progress = runtime.activity?.progress, progress.totalBytes > 0 {
                    NidoMeter(fraction: Double(progress.completedBytes) / Double(progress.totalBytes))
                    Text(AIRuntimeModel.progressText(progress))
                        .font(.nido(Theme.TypeSize.caption))
                        .foregroundStyle(Theme.Color.textSecondary)
                        .monospacedDigit()
                    if let warning = progress.warning {
                        Text(verbatim: AIRuntimeModel.warningText(warning))
                            .font(.nido(Theme.TypeSize.caption, .semibold))
                            .foregroundStyle(Theme.Color.statusPaused)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    NidoIndeterminateBar()
                    Text("Preparing the download…")
                        .font(.nido(Theme.TypeSize.caption))
                        .foregroundStyle(Theme.Color.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            NidoButton("Stop Waiting") { runtime.cancel() }
                .accessibilityIdentifier("ai-pull-stop-waiting")
        }
        .padding(.vertical, Theme.Space.s)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ai-pull-progress")
    }

    private func pull() {
        let name = pullName
        Task {
            await runtime.requestPull(name)
            if runtime.error == nil { pullName = "" }
        }
    }

    /// The Mac's download of the Ollama archive while it runs (install, update).
    private func macDownload(_ activity: AIRuntimeModel.Activity) -> PullProgress? {
        guard let progress = activity.progress, progress.message == AIRuntimeModel.macDownloadMessage,
            progress.totalBytes > 0, progress.completedBytes < progress.totalBytes
        else { return nil }
        return progress
    }

    private func isPull(_ action: AIRuntimeModel.Action) -> Bool {
        if case .pull = action { return true }
        return false
    }

    nonisolated static func activityLabel(_ action: AIRuntimeModel.Action) -> String {
        switch action {
        case .install: String(localized: "Installing Ollama…")
        case .verify: String(localized: "Verifying Ollama…")
        case .start: String(localized: "Starting Ollama…")
        case .stop: String(localized: "Stopping Ollama…")
        case .restart: String(localized: "Restarting Ollama…")
        case .update: String(localized: "Updating Ollama…")
        case .uninstall: String(localized: "Uninstalling Ollama…")
        case .pull(let model, _): String(localized: "Downloading \(model)…", comment: "%@ is a model’s name.")
        case .remove(let model): String(localized: "Removing \(model)…", comment: "%@ is a model’s name.")
        }
    }

    // MARK: - Confirmations

    private var removeModels: Binding<Bool> {
        Binding(get: { runtime.removeModelsOnUninstall }, set: { runtime.removeModelsOnUninstall = $0 })
    }

    private var confirming: Binding<Bool> {
        Binding(get: { runtime.pendingConfirmation != nil }, set: { if !$0 { runtime.cancelConfirmation() } })
    }

    @ViewBuilder private var confirmationSheet: some View {
        if let copy = runtime.confirmationCopy(vmName: vmName) {
            if let detail = copy.removeModelsDetail {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    Text(copy.title)
                        .font(.nido(Theme.TypeSize.headline, .semibold))
                        .foregroundStyle(Theme.Color.textPrimary)
                    Text(copy.message)
                        .font(.nido(Theme.TypeSize.body))
                        .foregroundStyle(Theme.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    NidoToggleRow(verbatim: String(localized: "Also delete the models"), explanation: detail, isOn: removeModels)
                    HStack(spacing: Theme.Space.s) {
                        Spacer(minLength: 0)
                        NidoButton("Cancel") { runtime.cancelConfirmation() }
                            .keyboardShortcut(.cancelAction)
                            .accessibilityIdentifier("confirm-cancel")
                        NidoButton(verbatim: copy.action, kind: .destructive) {
                            let remove = runtime.removeModelsOnUninstall
                            Task { await runtime.confirm(removeModels: remove) }
                        }
                        .accessibilityIdentifier("confirm-action")
                    }
                }
                .padding(Theme.Space.xl)
                .frame(width: Theme.Layout.confirmSheetWidth)
                .background(Theme.Color.surfaceRaised)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("confirm-sheet")
            } else {
                NidoConfirmSheet(
                    verbatim: copy.title, message: copy.message, actionLabel: copy.action,
                    actionKind: copy.isDestructive ? .destructive : .primary,
                    onCancel: { runtime.cancelConfirmation() },
                    onConfirm: { Task { await runtime.confirm() } })
            }
        }
    }
}
