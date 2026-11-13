// SPDX-License-Identifier: Apache-2.0
import AppKit
import SwiftUI

/// "Clone…" from a card's context menu: the name of the copy (default `<name>-copy`), what is
/// and is not copied, then Cancel and Clone. While the copy runs the sheet shows its progress
/// and cannot be closed; a failure stays in the sheet with its reason. The same sheet is "New
/// VM…" of a template (`model.isCloneFromTemplate`): a new VM from it (`--from-template`).
///
/// A macOS VM (ScreensMac.swift, "Clona macOS"): a warning that the guest's identity is copied
/// too and, once done, the commands to run in the copy (`VMCloner.cloneNotes`) with "Copy
/// Commands" and Done.
struct CloneSheet: View {
    @Bindable var model: LibraryModel
    let source: String

    var body: some View {
        Group {
            if let done = model.cloneDone {
                notes(done)
            } else {
                form
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: Theme.Layout.confirmSheetWidth)
        .background(Theme.Color.surfaceRaised)
        .interactiveDismissDisabled(model.isCloning)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clone-sheet")
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(verbatim: model.cloneTitle)
                .font(.nido(Theme.TypeSize.headline, .semibold))
                .foregroundStyle(Theme.Color.textPrimary)
            Text(verbatim: model.cloneMessage)
                .font(.nido(Theme.TypeSize.body))
                .foregroundStyle(Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let warning = model.macCloneWarning {
                NidoNotice(kind: .warning, verbatim: warning.title, detail: warning.detail, identifier: "clone-mac-warning")
            }
            NidoInfoRow(label: "Name") {
                TextField("Name", text: $model.cloneName)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .font(.nido(Theme.TypeSize.body))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .disabled(model.isCloning)
                    .onSubmit(confirm)
                    .accessibilityIdentifier("clone-name")
            }
            if model.isCloning {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    (fromTemplate ? Text("Creating…") : Text("Copying…"))
                        .font(.nido(Theme.TypeSize.caption))
                        .foregroundStyle(Theme.Color.textSecondary)
                    NidoIndeterminateBar()
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("clone-progress")
            }
            if let error = model.cloneError {
                Text(verbatim: error)
                    .font(.nido(Theme.TypeSize.caption, .semibold))
                    .foregroundStyle(Theme.Color.statusError)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("clone-error")
            }
            HStack(spacing: Theme.Space.s) {
                Spacer(minLength: 0)
                NidoButton("Cancel") { model.cancelClone() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isCloning)
                    .accessibilityIdentifier("clone-cancel")
                NidoButton(fromTemplate ? LocalizedStringKey("Create") : LocalizedStringKey("Clone"), kind: .primary,
                           action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isCloning)
                    .accessibilityIdentifier("clone-confirm")
            }
        }
    }

    /// "macos-base-copy is ready": the commands by group, then "Copy Commands" and Done.
    private func notes(_ done: LibraryModel.CloneNotes) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(verbatim: done.title)
                .font(.nido(Theme.TypeSize.headline, .semibold))
                .foregroundStyle(Theme.Color.textPrimary)
            Text(verbatim: done.message)
                .font(.nido(Theme.TypeSize.body))
                .foregroundStyle(Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(done.groups, id: \.id) { group in
                Text(verbatim: group.title)
                    .font(.nido(Theme.TypeSize.caption, .semibold))
                    .foregroundStyle(Theme.Color.textSecondary)
                NidoCommandBlock(command: group.commands.joined(separator: "\n"),
                                 identifier: "clone-notes-\(group.id)")
            }
            HStack(spacing: Theme.Space.s) {
                Spacer(minLength: 0)
                NidoButton("Copy Commands") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(done.commandsText, forType: .string)
                }
                .accessibilityIdentifier("clone-copy-notes")
                NidoButton("Done", kind: .primary) { model.finishClone() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("clone-done")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clone-notes")
    }

    private var fromTemplate: Bool { model.isCloneFromTemplate }

    private func confirm() {
        Task { await model.confirmClone() }
    }
}
