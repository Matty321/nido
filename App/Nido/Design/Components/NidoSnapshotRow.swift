// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// Components.swift SnapshotRow: a snapshot (name, date, "with saved state"), the VM's current
/// state ("Current state", with Create Snapshot…) or a snapshot being created. Name, date, note
/// and help come from the model, shown as given.
struct NidoSnapshotRow: View {
    enum Kind {
        case normal(date: String, savedState: Bool)
        case current(status: NidoStatusBadge.Status, note: String)
        case creating
    }

    let name: String
    let kind: Kind
    var canRestore = true
    var canDelete = true
    /// Why Delete is off (help tag).
    var deleteHelp: String?
    var canCreate = true
    var onRestore: () -> Void = {}
    var onDelete: () -> Void = {}
    var onCreate: () -> Void = {}

    private var isCurrent: Bool {
        if case .current = kind { true } else { false }
    }

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(verbatim: name)
                    .font(.nido(Theme.TypeSize.body, .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                details
                    .frame(height: Theme.Layout.snapshotDetailsHeight)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .padding(.vertical, Theme.Space.m)
        .padding(.horizontal, Theme.Space.l)
        .background(Theme.Color.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.m)
                .strokeBorder(isCurrent ? Theme.Color.accent : Theme.Color.border,
                              lineWidth: isCurrent ? Theme.Layout.selectedStroke : Theme.Layout.hairline)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var details: some View {
        HStack(spacing: Theme.Space.s) {
            switch kind {
            case .normal(let date, let savedState):
                caption(Text(verbatim: date)).monospacedDigit()
                if savedState {
                    Text("with saved state")
                        .font(.nido(Theme.TypeSize.caption, .semibold))
                        .foregroundStyle(Theme.Color.accent)
                        .padding(.horizontal, Theme.Space.s)
                        .frame(height: Theme.Layout.snapshotPillHeight)
                        .background(Theme.Color.background, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.Color.border, lineWidth: Theme.Layout.hairline))
                        .accessibilityIdentifier("snapshot-saved-state")
                }
            case .current(let status, let note):
                NidoStatusBadge(status: status)
                caption(Text(verbatim: note))
            case .creating:
                caption(Text("Creating…"))
            }
        }
    }

    private func caption(_ text: Text) -> some View {
        text
            .font(.nido(Theme.TypeSize.caption))
            .foregroundStyle(Theme.Color.textSecondary)
            .lineLimit(1)
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: Theme.Space.s) {
            switch kind {
            case .current:
                NidoButton("Create Snapshot…", kind: .primary, action: onCreate)
                    .disabled(!canCreate)
                    .accessibilityIdentifier("snapshot-create")
            case .creating:
                NidoButton("Restore") {}.disabled(true)
                NidoButton("Delete") {}.disabled(true)
            case .normal:
                NidoButton("Restore", action: onRestore)
                    .disabled(!canRestore)
                    .accessibilityIdentifier("snapshot-restore-\(name)")
                NidoButton("Delete", action: onDelete)
                    .disabled(!canDelete)
                    .help(Text(verbatim: deleteHelp ?? ""))
                    .accessibilityIdentifier("snapshot-delete-\(name)")
            }
        }
    }
}
