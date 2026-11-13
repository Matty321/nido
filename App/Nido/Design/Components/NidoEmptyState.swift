// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// Components.swift EmptyState: the empty library, with the button that creates the first VM.
/// The VM window reuses it, without the button, for "debian-13 is stopped" and "Couldn’t start".
///
/// Its texts are copy (English keys); `init(verbatim:…)` shows strings as given.
struct NidoEmptyState: View {
    private let title: Text
    private let message: Text
    /// The egg in the nest: accent, or `statusError` on the error screen.
    private let eggColor: Color
    private let identifier: String
    /// The button's label: "Create VM" in the library, "Create Snapshot…" in S09.
    private let buttonLabel: Text
    private let buttonIdentifier: String
    /// The button's action; nil hides the button (the VM window has its actions in the toolbar).
    private let onCreate: (() -> Void)?

    init(title: LocalizedStringKey = "The nest is empty",
         message: LocalizedStringKey = "Create your first virtual machine: Nido downloads Debian 13 or Ubuntu Server, verifies the image and sets up the VM in a few minutes.",
         eggColor: Color = Theme.Color.accent, identifier: String = "empty-state",
         buttonLabel: LocalizedStringKey = "Create VM", buttonIdentifier: String = "create-vm",
         onCreate: (() -> Void)?) {
        self.init(title: Text(title), message: Text(message), eggColor: eggColor, identifier: identifier,
                  buttonLabel: Text(buttonLabel), buttonIdentifier: buttonIdentifier, onCreate: onCreate)
    }

    /// `buttonLabel` nil is Create VM.
    init(verbatim title: String, message: String, eggColor: Color = Theme.Color.accent,
         identifier: String = "empty-state", buttonLabel: String? = nil, buttonIdentifier: String = "create-vm",
         onCreate: (() -> Void)?) {
        self.init(title: Text(verbatim: title), message: Text(verbatim: message), eggColor: eggColor,
                  identifier: identifier, buttonLabel: buttonLabel.map { Text(verbatim: $0) } ?? Text("Create VM"),
                  buttonIdentifier: buttonIdentifier, onCreate: onCreate)
    }

    private init(title: Text, message: Text, eggColor: Color, identifier: String, buttonLabel: Text,
                 buttonIdentifier: String, onCreate: (() -> Void)?) {
        self.title = title
        self.message = message
        self.eggColor = eggColor
        self.identifier = identifier
        self.buttonLabel = buttonLabel
        self.buttonIdentifier = buttonIdentifier
        self.onCreate = onCreate
    }

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Circle()
                .fill(Theme.Color.background)
                .overlay(Circle().strokeBorder(Theme.Color.border, lineWidth: Theme.Layout.emptyStateNestStroke))
                .overlay(Circle().fill(eggColor)
                    .frame(width: Theme.Layout.emptyStateEgg, height: Theme.Layout.emptyStateEgg))
                .frame(width: Theme.Layout.emptyStateNest, height: Theme.Layout.emptyStateNest)
                .accessibilityHidden(true)
            title
                .font(.nido(Theme.TypeSize.title, .semibold))
                .foregroundStyle(Theme.Color.textPrimary)
            message
                .font(.nido(Theme.TypeSize.body))
                .foregroundStyle(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let onCreate {
                NidoButton(label: buttonLabel, kind: .primary, action: onCreate)
                    .accessibilityIdentifier(buttonIdentifier)
            }
        }
        .padding(Theme.Space.xxl)
        .frame(width: Theme.Layout.emptyStateWidth)
        .background(Theme.Color.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.l))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}
