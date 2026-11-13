// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// Screens.swift searchField: the library's search field.
struct NidoSearchField: View {
    private let prompt: Text
    @Binding var text: String

    init(prompt: LocalizedStringKey, text: Binding<String>) {
        self.prompt = Text(prompt)
        self._text = text
    }

    init(verbatim prompt: String, text: Binding<String>) {
        self.prompt = Text(verbatim: prompt)
        self._text = text
    }

    var body: some View {
        TextField(text: $text, prompt: prompt.foregroundStyle(Theme.Color.textSecondary)) { EmptyView() }
            .textFieldStyle(.plain)
            // The design draws only the border: no focus ring.
            .focusEffectDisabled()
            .font(.nido(Theme.TypeSize.body))
            .foregroundStyle(Theme.Color.textPrimary)
            .padding(.horizontal, Theme.Space.s)
            .frame(width: Theme.Layout.searchFieldWidth, height: Theme.Layout.buttonHeight)
            .background(Theme.Color.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.s)
                .strokeBorder(Theme.Color.border, lineWidth: Theme.Layout.hairline))
            .accessibilityLabel(prompt)
            .accessibilityIdentifier("search")
    }
}
