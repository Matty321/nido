// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// Screens.swift `settingsWindow`: the bar with the title, a sidebar of sections and a form column
/// with a heading and an intro. Shared by the VM settings (S08) and the preferences (S10).
///
/// Title, heading and intro are copy (English keys); `init(verbatim:…)` shows strings as given.
struct NidoSettingsShell<Content: View>: View {
    /// A sidebar row. A disabled one is a feature of a later version: it says "Coming soon".
    /// `id` is the selection's value and names the row for the UI tests (`settings-section-<id>`).
    struct Section: Identifiable {
        let id: String
        let title: Text
        var isEnabled = true

        init(_ title: LocalizedStringKey, id: String, isEnabled: Bool = true) {
            self.id = id
            self.title = Text(title)
            self.isEnabled = isEnabled
        }

        /// The name shown as given; the row's id is `id`, or the name itself.
        init(verbatim name: String, id: String? = nil, isEnabled: Bool = true) {
            self.id = id ?? name
            self.title = Text(verbatim: name)
            self.isEnabled = isEnabled
        }
    }

    private let title: Text
    private let sections: [Section]
    @Binding var selection: String
    private let heading: Text
    private let intro: Text
    @ViewBuilder private let content: () -> Content

    init(title: LocalizedStringKey, sections: [Section], selection: Binding<String>,
         heading: LocalizedStringKey, intro: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: Text(title), sections: sections, selection: selection, heading: Text(heading),
                  intro: Text(intro), content: content)
    }

    init(verbatim title: String, sections: [Section], selection: Binding<String>,
         heading: String, intro: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: Text(verbatim: title), sections: sections, selection: selection,
                  heading: Text(verbatim: heading), intro: Text(verbatim: intro), content: content)
    }

    private init(title: Text, sections: [Section], selection: Binding<String>, heading: Text, intro: Text,
                 content: @escaping () -> Content) {
        self.title = title
        self.sections = sections
        self._selection = selection
        self.heading = heading
        self.intro = intro
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar.zIndex(1)
            HStack(spacing: 0) {
                sidebar
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            heading
                                .font(.nido(Theme.TypeSize.title, .semibold))
                                .foregroundStyle(Theme.Color.textPrimary)
                                .accessibilityAddTraits(.isHeader)
                            intro
                                .font(.nido(Theme.TypeSize.body))
                                .foregroundStyle(Theme.Color.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.bottom, Theme.Space.s)
                        content()
                    }
                    .frame(width: Theme.Layout.settingsFormWidth, alignment: .leading)
                    .padding(Theme.Space.xl)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Theme.Color.background)
            }
        }
        .background(Theme.Color.background)
    }

    private var titleBar: some View {
        HStack(spacing: Theme.Space.l) {
            // The window's own close, minimise and zoom buttons sit here.
            Color.clear.frame(width: Theme.Layout.trafficLightsWidth, height: Theme.Layout.hairline)
            title
                .padding(.leading, Theme.Space.s)
                .font(.nido(Theme.TypeSize.headline, .semibold))
                .foregroundStyle(Theme.Color.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.l)
        .frame(height: Theme.Layout.toolbarHeight)
        .background(Theme.Color.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Color.border).frame(height: Theme.Layout.hairline)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            ForEach(sections) { section in
                let isSelected = section.id == selection
                Button { selection = section.id } label: {
                    HStack {
                        section.title
                            .font(.nido(Theme.TypeSize.body, isSelected ? .semibold : .regular))
                        Spacer(minLength: 0)
                        if !section.isEnabled {
                            Text("Coming soon").font(.nido(Theme.TypeSize.caption))
                        }
                    }
                    .foregroundStyle(isSelected ? Theme.Color.accentText
                        : section.isEnabled ? Theme.Color.textPrimary : Theme.Color.textSecondary)
                    .padding(.horizontal, Theme.Space.s)
                    .frame(maxWidth: .infinity, minHeight: Theme.Layout.settingsSidebarRowHeight, alignment: .leading)
                    .background(isSelected ? Theme.Color.accent : Color.clear, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
                    .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.s))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .disabled(!section.isEnabled)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("settings-section-\(section.id)")
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Space.m)
        .padding(.horizontal, Theme.Space.s)
        .frame(width: Theme.Layout.settingsSidebarWidth)
        .frame(maxHeight: .infinity)
        .background(Theme.Color.surface)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.Color.border).frame(width: Theme.Layout.hairline)
        }
    }
}
