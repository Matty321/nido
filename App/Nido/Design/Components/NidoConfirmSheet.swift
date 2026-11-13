// SPDX-License-Identifier: Apache-2.0
import NidoCore
import SwiftUI

/// Components.swift ConfirmSheet: a question, what it implies, Annulla and the action.
///
/// Its texts are copy (English keys of the app's catalog); `init(verbatim:…)` shows strings as
/// given: runtime text, or text a model already localized (`String(localized:)`).
struct NidoConfirmSheet: View {
    private let title: Text
    private let message: Text
    private let actionLabel: Text
    private let actionKind: NidoButton.Kind
    private let cancelLabel: Text
    private let onCancel: () -> Void
    private let onConfirm: () -> Void

    /// `cancelLabel`: "Continue" when Cancel would read as the action itself ("Cancel Installation").
    init(title: LocalizedStringKey, message: LocalizedStringKey, actionLabel: LocalizedStringKey,
         actionKind: NidoButton.Kind = .primary, cancelLabel: LocalizedStringKey = "Cancel",
         onCancel: @escaping () -> Void, onConfirm: @escaping () -> Void) {
        self.init(title: Text(title), message: Text(message), actionLabel: Text(actionLabel),
                  actionKind: actionKind, cancelLabel: Text(cancelLabel), onCancel: onCancel, onConfirm: onConfirm)
    }

    /// The strings shown as given; `cancelLabel` nil is Cancel.
    init(verbatim title: String, message: String, actionLabel: String,
         actionKind: NidoButton.Kind = .primary, cancelLabel: String? = nil,
         onCancel: @escaping () -> Void, onConfirm: @escaping () -> Void) {
        self.init(title: Text(verbatim: title), message: Text(verbatim: message),
                  actionLabel: Text(verbatim: actionLabel), actionKind: actionKind,
                  cancelLabel: cancelLabel.map { Text(verbatim: $0) } ?? Text("Cancel"),
                  onCancel: onCancel, onConfirm: onConfirm)
    }

    private init(title: Text, message: Text, actionLabel: Text, actionKind: NidoButton.Kind,
                 cancelLabel: Text, onCancel: @escaping () -> Void, onConfirm: @escaping () -> Void) {
        self.title = title
        self.message = message
        self.actionLabel = actionLabel
        self.actionKind = actionKind
        self.cancelLabel = cancelLabel
        self.onCancel = onCancel
        self.onConfirm = onConfirm
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            title
                .font(.nido(Theme.TypeSize.headline, .semibold))
                .foregroundStyle(Theme.Color.textPrimary)
            message
                .font(.nido(Theme.TypeSize.body))
                .foregroundStyle(Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.s) {
                Spacer(minLength: 0)
                NidoButton(label: cancelLabel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("confirm-cancel")
                NidoButton(label: actionLabel, kind: actionKind, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("confirm-action")
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: Theme.Layout.confirmSheetWidth)
        .background(Theme.Color.surfaceRaised)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("confirm-sheet")
    }
}

extension NidoConfirmSheet {
    /// The design's delete confirmation: "Delete debian-13?".
    static func delete(name: String, diskBytes: UInt64?, onCancel: @escaping () -> Void,
                       onConfirm: @escaping () -> Void) -> NidoConfirmSheet {
        let message: LocalizedStringKey = if let diskBytes {
            "The VM and its disk (\(ByteSize.text(diskBytes))) will be deleted from this Mac. This can’t be undone."
        } else {
            "The VM and its disk will be deleted from this Mac. This can’t be undone."
        }
        return NidoConfirmSheet(
            title: "Delete \(name)?", message: message, actionLabel: "Delete", actionKind: .destructive,
            onCancel: onCancel, onConfirm: onConfirm)
    }
}
