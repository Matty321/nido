// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// Components.swift ToggleRow: an option with its explanation and a switch: attiva · disattivata ·
/// bloccata (the switch dimmed, the explanation says why, e.g. "Si può cambiare solo a VM arrestata.").
///
/// Title and explanation are copy (English keys); `init(verbatim:…)` shows strings as given.
struct NidoToggleRow: View {
    private let title: Text
    private let explanation: Text
    @Binding var isOn: Bool
    var isLocked = false

    init(title: LocalizedStringKey, explanation: LocalizedStringKey, isOn: Binding<Bool>, isLocked: Bool = false) {
        self.init(title: Text(title), explanation: Text(explanation), isOn: isOn, isLocked: isLocked)
    }

    init(verbatim title: String, explanation: String, isOn: Binding<Bool>, isLocked: Bool = false) {
        self.init(title: Text(verbatim: title), explanation: Text(verbatim: explanation), isOn: isOn, isLocked: isLocked)
    }

    private init(title: Text, explanation: Text, isOn: Binding<Bool>, isLocked: Bool) {
        self.title = title
        self.explanation = explanation
        self._isOn = isOn
        self.isLocked = isLocked
    }

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                title
                    .font(.nido(Theme.TypeSize.body, .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                explanation
                    .font(.nido(Theme.TypeSize.caption))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { isOn.toggle() } label: { track }
                .buttonStyle(.plain)
                .disabled(isLocked)
                .opacity(isLocked ? Theme.Layout.disabledOpacity : 1)
        }
        .nidoRow()
        .accessibilityRepresentation {
            Toggle(isOn: $isOn) { title }.disabled(isLocked)
        }
        .accessibilityHint(explanation)
    }

    private var track: some View {
        Circle()
            .fill(isOn ? Theme.Color.accentText : Theme.Color.textSecondary)
            .frame(width: Theme.Layout.toggleKnob, height: Theme.Layout.toggleKnob)
            .padding(.horizontal, Theme.Space.xs)
            .frame(width: Theme.Layout.toggleTrackWidth, height: Theme.Layout.toggleTrackHeight,
                   alignment: isOn ? .trailing : .leading)
            .background(isOn ? Theme.Color.accent : Theme.Color.border,
                        in: RoundedRectangle(cornerRadius: Theme.Layout.toggleTrackHeight / 2))
            .contentShape(Rectangle())
    }
}
