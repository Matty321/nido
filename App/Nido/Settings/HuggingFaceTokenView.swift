// SPDX-License-Identifier: Apache-2.0
import NidoCore
import Observation
import SwiftUI

/// S10 Hugging Face: the Mac's one token for the AI bridge (spec H). It goes to the Keychain
/// (`TokenStore`, off the main actor) and the field is emptied right after: the value is never
/// shown again, only whether it is there. "Sostituisci…" opens an empty field.
@MainActor
@Observable
final class HuggingFaceTokenModel {
    /// The text typed in the secure field (only until it is handed to the Keychain).
    var field = "" {
        didSet { if field != oldValue, error == HuggingFaceTokenModel.invalidMessage { error = nil } }
    }
    /// The Keychain has a token; nil while unknown (not read yet, or the Keychain failed).
    private(set) var hasToken: Bool?
    /// "Sostituisci…": the field is shown over a saved token.
    private(set) var isReplacing = false
    private(set) var isBusy = false
    /// Localized, inline under the field (an invalid token, a Keychain failure).
    private(set) var error: String?

    nonisolated static var invalidMessage: String {
        String(localized: "The token isn’t valid: paste it without spaces or special characters inside.")
    }

    @ObservationIgnored private let tokenStore: (any TokenStore)?

    nonisolated static var unavailableMessage: String {
        String(localized: "The Keychain isn’t available in this session of Nido: the token can’t be saved.")
    }

    init(tokenStore: (any TokenStore)?) {
        self.tokenStore = tokenStore
        if tokenStore == nil { error = Self.unavailableMessage }
    }

    var showsField: Bool { hasToken != true || isReplacing }
    /// The field is usable only with a Keychain behind it.
    var isAvailable: Bool { tokenStore != nil }
    var canSave: Bool {
        isAvailable && !isBusy && !field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The section goes away (another section, Settings closed): a typed but unsaved token is
    /// dropped, never kept for the next visit.
    func leave() {
        field = ""
        isReplacing = false
        if error == Self.invalidMessage { error = nil }
    }

    /// Whether a token is saved (never its value).
    func load() async {
        guard let tokenStore else { return }
        let result = await Task.detached { () -> Bool? in
            do { return try tokenStore.read() != nil } catch { return nil }
        }.value
        hasToken = result
        error = result == nil ? String(localized: "The Keychain doesn’t respond: try again.") : nil
    }

    func beginReplace() {
        field = ""
        error = nil
        isReplacing = true
    }

    func cancelReplace() {
        field = ""
        error = nil
        isReplacing = false
    }

    /// "Salva": a valid token goes to the Keychain and the field is emptied, whatever the
    /// Keychain answers (the text is never kept once handed over).
    func save() async {
        guard let tokenStore, canSave else { return }
        guard let token = HFToken(field) else {
            error = Self.invalidMessage
            return
        }
        field = ""
        isBusy = true
        defer { isBusy = false }
        let saved = await Task.detached { () -> Bool in
            do {
                try tokenStore.save(token)
                return true
            } catch {
                return false
            }
        }.value
        if saved {
            hasToken = true
            isReplacing = false
            error = nil
        } else {
            error = String(localized: "The Keychain didn’t save the token: try again.")
        }
    }

    /// "Rimuovi": the bridges of the VMs answer 401 from now on, and nothing leaves the Mac.
    func remove() async {
        guard let tokenStore, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let removed = await Task.detached { () -> Bool in
            do {
                try tokenStore.delete()
                return true
            } catch {
                return false
            }
        }.value
        if removed {
            hasToken = false
            isReplacing = false
            field = ""
            error = nil
        } else {
            error = String(localized: "The Keychain didn’t remove the token: try again.")
        }
    }
}

/// The section's content in the settings shell (ScreensAI.swift `s10HuggingFace`).
struct HuggingFaceTokenView: View {
    @Bindable var model: HuggingFaceTokenModel
    /// The VMs whose bridge is active now (names), for "VM con il ponte AI attivo".
    let activeBridgeVMs: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if model.showsField { entry } else { saved }
            }
            .padding(.vertical, Theme.Space.m)
            .padding(.horizontal, Theme.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Color.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m)
                .strokeBorder(Theme.Color.border, lineWidth: Theme.Layout.hairline))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("hf-token")
            if model.hasToken == true, !model.isReplacing {
                NidoInfoRow(
                    "VMs with the AI bridge on",
                    activeBridgeVMs.isEmpty ? String(localized: "None (VMs)", defaultValue: "None", comment: "No VMs.") : activeBridgeVMs.formatted(.list(type: .and)),
                    note: "If you remove the token, the bridge answers 401 in the VMs and nothing leaves the Mac.")
            }
        }
        .task { await model.load() }
        .onDisappear { model.leave() }
    }

    private var saved: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("Access token")
                        .font(.nido(Theme.TypeSize.body, .semibold))
                        .foregroundStyle(Theme.Color.textPrimary)
                    Text("Saved in the Keychain. It can’t be shown again: to change it, paste a new one.")
                        .font(.nido(Theme.TypeSize.caption))
                        .foregroundStyle(Theme.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                NidoButton("Replace…") { model.beginReplace() }
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("hf-token-replace")
                // Deletes the token from the Keychain: es/fr say "delete", not the list's "remove".
                NidoButton(verbatim: String(localized: "Remove (token)", defaultValue: "Remove",
                                            comment: "Deletes the saved token from the Keychain.")) {
                    Task { await model.remove() }
                }
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("hf-token-remove")
            }
            errorText
        }
    }

    private var entry: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Access token")
                .font(.nido(Theme.TypeSize.body, .semibold))
                .foregroundStyle(Theme.Color.textPrimary)
            HStack(spacing: Theme.Space.s) {
                SecureField(text: $model.field, prompt: Text(verbatim: "hf_…")) { Text("Access token") }
                    .textFieldStyle(.roundedBorder)
                    .font(.nido(Theme.TypeSize.body))
                    .onSubmit { Task { await model.save() } }
                    .disabled(!model.isAvailable)
                    .accessibilityIdentifier("hf-token-field")
                if model.isReplacing {
                    NidoButton("Cancel") { model.cancelReplace() }
                        .accessibilityIdentifier("hf-token-cancel")
                }
                NidoButton("Save", kind: .primary) { Task { await model.save() } }
                    .disabled(!model.canSave)
                    .accessibilityIdentifier("hf-token-save")
            }
            errorText
            Text("On huggingface.co, create a fine-grained token with only the “Make calls to Inference Providers” permission.")
                .font(.nido(Theme.TypeSize.caption))
                .foregroundStyle(Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var errorText: some View {
        if let error = model.error {
            Text(verbatim: error)
                .font(.nido(Theme.TypeSize.caption, .semibold))
                .foregroundStyle(Theme.Color.statusError)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("hf-token-error")
        }
    }
}
