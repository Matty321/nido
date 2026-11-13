// SPDX-License-Identifier: Apache-2.0
import NidoCore
import SwiftUI

/// S08 Network: the switch of the controlled network, the allowed domains and the reset.
struct NetworkSettingsSection: View {
    @Bindable var model: NetworkSettingsModel

    var body: some View {
        Group {
            NidoToggleRow(
                verbatim: String(localized: "Controlled network"),
                explanation: model.toggleExplanation,
                isOn: Binding(get: { model.controlled }, set: { model.requestToggle($0) }),
                isLocked: model.isLocked)
                .accessibilityIdentifier("network-toggle")
            if let message = model.message {
                NidoNotice(kind: model.messageIsError ? .error : .info, verbatim: message, identifier: "network-settings-message")
            }
            list
        }
        .task { await model.load() }
        .sheet(isPresented: Binding(get: { model.pendingToggle != nil }, set: { if !$0 { model.cancelToggle() } })) {
            let sheet = model.toggleSheet
            NidoConfirmSheet(
                verbatim: sheet.title, message: sheet.message, actionLabel: sheet.action,
                actionKind: model.pendingToggle == false ? .destructive : .primary,
                onCancel: { model.cancelToggle() },
                onConfirm: { Task { await model.confirmToggle() } })
        }
        .sheet(isPresented: Binding(get: { model.pendingBroad != nil }, set: { if !$0 { model.cancelBroad() } })) {
            if let pattern = model.pendingBroad {
                NidoConfirmSheet(
                    verbatim: String(localized: "Add \(pattern.description)?", comment: "%@ is a domain or a wildcard."),
                    message: model.broadWarning(pattern),
                    actionLabel: String(localized: "Add Anyway"), actionKind: .destructive,
                    onCancel: { model.cancelBroad() },
                    onConfirm: { Task { await model.confirmBroad() } })
            }
        }
        .sheet(isPresented: Binding(get: { model.pendingReset }, set: { if !$0 { model.cancelReset() } })) {
            NidoConfirmSheet(
                verbatim: model.resetTitle, message: model.resetMessage,
                actionLabel: String(localized: "Reset", comment: "Resets a list to its base list."),
                onCancel: { model.cancelReset() },
                onConfirm: { Task { await model.confirmReset() } })
        }
    }

    @ViewBuilder private var list: some View {
        if model.isMalformed {
            NidoNotice(kind: .error, verbatim: String(localized: "Invalid domain list"), detail: model.malformedHint,
                       identifier: "network-settings-malformed")
        } else if model.patterns.isEmpty {
            NidoInfoRow(label: "No allowed domains", note: "The VM can’t reach any site. \(model.listIntro)") {
                EmptyView()
            }
            .accessibilityIdentifier("network-domains-empty")
        } else {
            ForEach(model.patterns, id: \.self) { pattern in
                NidoInfoRow(verbatim: pattern.description, note: note(pattern)) {
                    NidoButton(label: Text("Remove (domain)", comment: "Takes a domain off the list.")) {
                        Task { await model.remove(pattern) }
                    }
                        .disabled(model.isBusy)
                        .accessibilityIdentifier("network-remove-\(pattern.description)")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("network-domain-\(pattern.description)")
            }
        }
        NidoTextFieldRow(
            label: "Add a domain",
            note: "\(model.listIntro) Adding asks for Touch ID or the Mac password; removing doesn’t.",
            placeholder: "example.com", text: $model.newDomain, identifier: "network-new-domain")
            .onSubmit { Task { await model.addDomain() } }
        HStack(spacing: Theme.Space.m) {
            NidoButton(verbatim: model.resetLabel) { model.requestReset() }
                .disabled(model.isBusy)
                .accessibilityIdentifier("network-reset")
            Spacer(minLength: 0)
            NidoButton("Add…", kind: .primary) { Task { await model.addDomain() } }
                .disabled(model.isBusy || model.newDomain.trimmingCharacters(in: .whitespaces).isEmpty || model.isMalformed)
                .accessibilityIdentifier("network-add")
        }
    }

    private func note(_ pattern: DomainPattern) -> String {
        if pattern.isWildcard {
            return String(localized: "\(pattern.name) and every subdomain of it.", comment: "%@ is a domain.")
        }
        return EgressPolicy.base.allow.contains(pattern)
            ? String(localized: "On the base list.") : String(localized: "Only this name.")
    }
}
