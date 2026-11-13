// SPDX-License-Identifier: Apache-2.0
import NidoCore
import SwiftUI

/// The library's section heading with its caption (ScreensAI.swift `librarySection`).
struct LibrarySectionHeading: View {
    /// Copy (an English key); the caption is the model's text, shown as given.
    let title: LocalizedStringKey
    let caption: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(title)
                .font(.nido(Theme.TypeSize.headline, .semibold))
                .foregroundStyle(Theme.Color.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: caption)
                .font(.nido(Theme.TypeSize.caption))
                .foregroundStyle(Theme.Color.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The library's Modelli section (spec E): one card per template, which never starts. Hidden by
/// the library when there are no templates.
struct TemplatesSection: View {
    let model: LibraryModel
    let columns: [GridItem]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            LibrarySectionHeading(title: "Templates", caption: model.templatesCaption)
                .accessibilityIdentifier("library-templates-heading")
            LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Space.l) {
                ForEach(model.templateItems) { vm in card(vm) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library-templates")
    }

    private func card(_ vm: VMSummary) -> some View {
        NidoTemplateCard(
            name: vm.name, system: LibraryModel.system(of: vm), resources: LibraryModel.resources(of: vm),
            space: model.spaceText(for: vm)
        ) {
            ForEach(model.buttons(for: vm), id: \.action) { button in
                NidoButton(verbatim: LibraryModel.label(for: button.action), kind: button.kind) {
                    Task { await model.perform(button.action, on: vm) }
                }
                .disabled(!button.isEnabled)
                .accessibilityIdentifier("action-\(button.action)")
            }
        }
        .contextMenu {
            ForEach(model.menuActions(for: vm), id: \.self) { action in
                Button(LibraryModel.menuLabel(for: action), role: action == .delete ? .destructive : nil) {
                    Task { await model.perform(action, on: vm) }
                }
            }
        }
    }
}

/// ScreensAI.swift TemplateCard: a template in the library, with the "Template" pill instead of a
/// state, its space on the Mac, and New VM… / Edit Template (never Start). Name, system,
/// resources and space are the model's text, shown as given.
struct NidoTemplateCard<Actions: View>: View {
    let name: String
    let system: String
    let resources: String
    /// "Uses 9.8 GiB on the Mac".
    let space: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .center, spacing: Theme.Space.m) {
                Text(verbatim: "D")
                    .font(.nido(Theme.TypeSize.headline, .bold))
                    .foregroundStyle(Theme.Color.accent)
                    .frame(width: Theme.Layout.cardGlyph, height: Theme.Layout.cardGlyph)
                    .background(Theme.Color.background, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.s)
                        .strokeBorder(Theme.Color.border, lineWidth: Theme.Layout.hairline))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(verbatim: name)
                        .font(.nido(Theme.TypeSize.headline, .semibold))
                        .foregroundStyle(Theme.Color.textPrimary)
                        .lineLimit(1)
                    Text(verbatim: system)
                        .font(.nido(Theme.TypeSize.caption))
                        .foregroundStyle(Theme.Color.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("Template")
                    .font(.nido(Theme.TypeSize.caption, .semibold))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .padding(.horizontal, Theme.Space.s)
                    .frame(height: Theme.Layout.pillHeight)
                    .background(Theme.Color.background, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m)
                        .strokeBorder(Theme.Color.border, lineWidth: Theme.Layout.hairline))
                    .accessibilityIdentifier("template-pill")
            }
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(verbatim: resources)
                Text(verbatim: space).accessibilityIdentifier("template-space")
            }
            .font(.nido(Theme.TypeSize.caption))
            .foregroundStyle(Theme.Color.textSecondary)
            HStack(spacing: Theme.Space.s) { actions() }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m)
            .strokeBorder(Theme.Color.border, lineWidth: Theme.Layout.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(name)
        .accessibilityLabel(Text(verbatim: name))
    }
}

/// S01 "salva come modello": what becomes of the VM, and that new VMs start without shared
/// folders and with the AI bridge off.
struct SaveTemplateSheet: View {
    let name: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Save \(name) as a template?")
                .font(.nido(Theme.TypeSize.headline, .semibold))
                .foregroundStyle(Theme.Color.textPrimary)
            Text("\(name) becomes a template: it no longer starts and is used to create new VMs with an instant copy of its disk. To update it, choose Edit Template, then save it again.")
                .font(.nido(Theme.TypeSize.body))
                .foregroundStyle(Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            NidoNotice(
                kind: .info,
                title: "VMs created from the template start without shared folders and with the AI bridge off.",
                detail: "Each one has a new identity: MAC address, host name and SSH host keys.",
                identifier: "save-template-notice")
            HStack(spacing: Theme.Space.s) {
                Spacer(minLength: 0)
                NidoButton("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("confirm-cancel")
                NidoButton("Save as Template", kind: .primary, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("confirm-action")
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: Theme.Layout.confirmSheetWidth)
        .background(Theme.Color.surfaceRaised)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("save-template-sheet")
    }
}
