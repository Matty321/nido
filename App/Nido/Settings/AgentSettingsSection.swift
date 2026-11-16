// SPDX-License-Identifier: Apache-2.0
import AppKit
import NidoCore
import SwiftUI

/// S08 Agent: the switch of agent access, the state of Nido Agent in the guest, its installation
/// and the command that connects an agent to the VM.
struct AgentSettingsSection: View {
    @Bindable var model: AgentSettingsModel
    /// The typed password: handed to the setup at once and emptied, never kept.
    @State private var typedPassword = ""

    var body: some View {
        Group {
            NidoToggleRow(
                verbatim: String(localized: "Agent access"),
                explanation: model.toggleExplanation,
                isOn: Binding(get: { model.agentAccess }, set: { on in Task { await model.setAgentAccess(on) } }))
                .accessibilityIdentifier("agent-toggle")
            if let note = model.restartNote {
                NidoNotice(kind: .info, verbatim: note, identifier: "agent-restart-note")
            }
            if let error = model.errorMessage {
                NidoNotice(kind: .error, verbatim: error, identifier: "agent-error")
            }
            // The key works, only the Keychain refused the password: not a failed setup.
            if let notice = model.passwordNotSavedNotice {
                NidoNotice(kind: .warning, verbatim: notice, identifier: "agent-password-not-saved")
            }
            if model.agentAccess { helper }
            // The stored password is shown with agent access off too.
            passwordRows
        }
        // The shown password and the typed one go with the pane.
        .onDisappear {
            typedPassword = ""
            model.leave()
        }
        .task {
            model.opened()
            // The helper changes state in the guest (a permission allowed, a login): look again
            // every 3 seconds while the pane is visible.
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    @ViewBuilder private var helper: some View {
        if let line = model.helperLine {
            NidoInfoRow(verbatim: String(localized: "Nido Agent"), note: line) {
                if model.isInstalling {
                    NidoButton("Cancel") { model.cancelInstall() }
                        .accessibilityIdentifier("agent-cancel")
                } else {
                    NidoButton(verbatim: model.installLabel, kind: model.helperNeedsInstall ? .primary : .secondary) {
                        Task { await model.install() }
                    }
                    .disabled(!model.canInstall)
                    .accessibilityIdentifier("agent-install")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("agent-helper")
        }
        if let note = model.windowSetupNote {
            NidoNotice(kind: .info, verbatim: note, identifier: "agent-window-setup")
        }
        if let advice = model.fileVaultAdvice {
            NidoNotice(kind: .warning, verbatim: advice, identifier: "agent-filevault")
        }
        if !model.log.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line)
                        .font(.nido(Theme.TypeSize.caption))
                        .foregroundStyle(Theme.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("agent-log")
        }
        NidoInfoRow(
            verbatim: String(localized: "Connect an agent"),
            note: String(localized: "Run this in a terminal to give Claude Code this VM. The skill that teaches it how to use the VM installs with nido skill install.")
                + "\n" + model.mcpCommand) {
            NidoButton("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.mcpCommand, forType: .string)
            }
            .accessibilityIdentifier("agent-copy-mcp")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-mcp")
    }
}

extension AgentSettingsSection {
    /// The account's password: a field when the setup asks for it, and "Show password" (after
    /// Touch ID) when one is stored, agent access on or off.
    @ViewBuilder fileprivate var passwordRows: some View {
        if model.needsPassword {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Account password")
                    .font(.nido(Theme.TypeSize.body, .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                HStack(spacing: Theme.Space.s) {
                    SecureField(text: $typedPassword) { Text("Password") }
                        .textFieldStyle(.roundedBorder)
                        .font(.nido(Theme.TypeSize.body))
                        .onSubmit(submit)
                        .accessibilityIdentifier("agent-password-field")
                    NidoButton("Authorize", kind: .primary, action: submit)
                        .disabled(typedPassword.isEmpty || !model.canSubmitPassword)
                        .accessibilityIdentifier("agent-password-authorize")
                }
                Text("Nido needs the password of the account in the VM once, to authorize its key. It is kept in your Mac’s Keychain once it worked.")
                    .font(.nido(Theme.TypeSize.caption))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("agent-password")
        }
        if model.showsStoredPassword {
            NidoInfoRow(
                verbatim: String(localized: "Account password"),
                note: String(localized: "Kept in your Mac’s Keychain. You need it to confirm the two permissions in the VM’s System Settings.")) {
                HStack(spacing: Theme.Space.s) {
                    if model.shownPassword == nil {
                        NidoButton("Show password") { Task { _ = await model.revealPassword() } }
                            .accessibilityIdentifier("agent-password-show")
                    } else {
                        NidoButton("Hide password") { model.hidePassword() }
                            .accessibilityIdentifier("agent-password-hide")
                    }
                    // The VM shares no clipboard with the Mac: Nido Agent puts it on the VM's own.
                    NidoButton("Copy to the VM’s clipboard") { Task { await model.copyPasswordToVM() } }
                        .disabled(!model.canCopyPasswordToVM)
                        .accessibilityIdentifier("agent-password-copy-to-vm")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("agent-password-stored")
            if let shown = model.shownPassword {
                Text(verbatim: shown)
                    .font(.system(size: Theme.TypeSize.body, design: .monospaced))
                    .foregroundStyle(Theme.Color.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("agent-password-value")
            }
            if let reason = model.copyDisabledReason {
                Text(verbatim: reason)
                    .font(.nido(Theme.TypeSize.caption))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("agent-password-copy-reason")
            }
            if let notice = model.copyNotice {
                NidoNotice(kind: .info, verbatim: notice, identifier: "agent-password-copied")
            }
        }
        // The Keychain could not say whether a password is stored: why, on its own line.
        if let note = model.passwordStateNote {
            NidoNotice(kind: .error, verbatim: note, identifier: "agent-password-state")
        }
    }

    private func submit() {
        let text = typedPassword
        guard !text.isEmpty else { return }
        // A setup runs: the text stays in the field, the pane says to wait.
        guard model.canSubmitPassword else {
            model.noteSetupBusy()
            return
        }
        typedPassword = ""
        Task { await model.submitPassword(text) }
    }
}
