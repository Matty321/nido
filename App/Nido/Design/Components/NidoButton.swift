// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// Components.swift NidoButton: primary · secondary · destructive, and the disabled look for any
/// kind when the button is disabled.
///
/// The title is copy: `NidoButton("Cancel")` looks the English literal up in the app's catalog.
/// `NidoButton(verbatim:)` shows a string as given (a name, or text a model already localized).
struct NidoButton: View {
    enum Kind: Hashable, Sendable {
        case primary, secondary, destructive
    }

    private let label: Text
    var kind: Kind = .secondary
    let action: () -> Void

    init(_ title: LocalizedStringKey, kind: Kind = .secondary, action: @escaping () -> Void) {
        self.init(label: Text(title), kind: kind, action: action)
    }

    init(verbatim title: String, kind: Kind = .secondary, action: @escaping () -> Void) {
        self.init(label: Text(verbatim: title), kind: kind, action: action)
    }

    /// For components that hold their copy as `Text` already.
    init(label: Text, kind: Kind = .secondary, action: @escaping () -> Void) {
        self.label = label
        self.kind = kind
        self.action = action
    }

    var body: some View {
        Button(action: action) { label }
            .buttonStyle(NidoButtonStyle(kind: kind))
    }
}

struct NidoButtonStyle: ButtonStyle {
    let kind: NidoButton.Kind
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.nido(Theme.TypeSize.body, .semibold))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, Theme.Space.m)
            .frame(height: Theme.Layout.buttonHeight)
            .background(fill, in: shape)
            .overlay {
                if hasBorder { shape.strokeBorder(Theme.Color.border, lineWidth: Theme.Layout.hairline) }
            }
            .contentShape(shape)
            .opacity(isEnabled ? (configuration.isPressed ? Theme.Layout.pressedOpacity : 1) : Theme.Layout.disabledOpacity)
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Theme.Radius.s) }

    private var hasBorder: Bool { !isEnabled || kind == .secondary }

    private var fill: Color {
        guard isEnabled else { return Theme.Color.surfaceRaised }
        switch kind {
        case .primary: return Theme.Color.accent
        case .secondary: return Theme.Color.surfaceRaised
        case .destructive: return Theme.Color.statusError
        }
    }

    private var foreground: Color {
        guard isEnabled else { return Theme.Color.textSecondary }
        return kind == .secondary ? Theme.Color.textPrimary : Theme.Color.accentText
    }
}

extension Font {
    /// The design's type: the system font at a `Theme.TypeSize`.
    static func nido(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}
