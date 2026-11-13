// SPDX-License-Identifier: Apache-2.0
import NidoCore
import SwiftUI

/// The snapshots window of one VM (S09), keyed by its name like the VM window and the settings:
/// opened by "Snapshots" in the VM window's bar and by "Manage Snapshots…" in S08 General.
enum SnapshotsWindow {
    static let id = "vm-snapshots"
}

/// Resolves the window's value (the VM name) to a model on the VM's window model, once.
struct SnapshotsRoot: View {
    let name: String?
    let environment: AppEnvironment?

    @State private var model: SnapshotsModel?
    @State private var failure: String?
    /// The VM whose model this window keeps (`VMSessionStore.snapshotsWindowOpened`).
    @State private var opened: VMName?

    var body: some View {
        Group {
            if let model {
                SnapshotsView(model: model)
            } else if let failure {
                StartupErrorView(message: failure)
            } else {
                Theme.Color.background
            }
        }
        .navigationTitle(Text("Snapshots of \(name ?? "")", comment: "The snapshots window's title; %@ is the VM's name."))
        .task(id: name) { resolve() }
        .onDisappear {
            if let opened { environment?.sessions.snapshotsWindowClosed(opened) }
            opened = nil
        }
    }

    private func resolve() {
        guard let environment, let name, let vmName = try? VMName(name) else {
            failure = String(localized: "Invalid virtual machine name.")
            return
        }
        do {
            let bundle = try VMBundle.open(vmName, paths: environment.paths)
            if let opened { environment.sessions.snapshotsWindowClosed(opened) }
            // The store keeps this model while the window is open: the VM window, opened or
            // reopened meanwhile, shares it (one serialisation of snapshot, suspend and stop).
            let window = environment.sessions.snapshotsWindowOpened(vmName)
            opened = vmName
            model = SnapshotsModel(window: window, bundle: bundle)
        } catch {
            let reason = error.localizedDescription
            failure = String(localized: "Can’t open the snapshots of \(name): \(reason)", comment: "%1$@: the VM's name; %2$@: why.")
        }
    }
}

/// S09: the current state (or the progress of a new snapshot, or its error), then the snapshots,
/// newest first; Create, Restore and Delete ask first in a sheet.
struct SnapshotsView: View {
    @Bindable var model: SnapshotsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            content
        }
        .background(Theme.Color.background)
        .task {
            await model.load()
            // `nido start` may start or stop the VM meanwhile, and `nido snapshot` change the list.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await model.load()
                // The VM was deleted: its snapshots went with it.
                if !model.bundleExists { dismiss() }
            }
        }
        .background {
            Color.clear.sheet(isPresented: naming) { NameSheet(model: model) }
        }
        .background {
            Color.clear.sheet(item: pendingRestore) { _ in
                NidoConfirmSheet(
                    verbatim: model.restoreTitle, message: model.restoreMessage, actionLabel: String(localized: "Restore"),
                    actionKind: .destructive, onCancel: { model.cancelRestore() },
                    onConfirm: { Task { await model.confirmRestore() } })
            }
        }
        .sheet(item: pendingDelete) { _ in
            NidoConfirmSheet(
                verbatim: model.deleteTitle, message: model.deleteMessage, actionLabel: String(localized: "Delete"),
                actionKind: .destructive, onCancel: { model.cancelDelete() },
                onConfirm: { Task { await model.confirmDelete() } })
        }
    }

    private var naming: Binding<Bool> {
        Binding(get: { model.isNaming }, set: { if !$0 { model.cancelCreate() } })
    }

    private var pendingRestore: Binding<Snapshot?> {
        Binding(get: { model.pendingRestore }, set: { if $0 == nil { model.cancelRestore() } })
    }

    private var pendingDelete: Binding<Snapshot?> {
        Binding(get: { model.pendingDelete }, set: { if $0 == nil { model.cancelDelete() } })
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: Theme.Space.l) {
            // The window's own close, minimise and zoom buttons sit here.
            Color.clear.frame(width: Theme.Layout.trafficLightsWidth, height: Theme.Layout.hairline)
            VStack(alignment: .leading, spacing: 0) {
                Text("Snapshots of \(model.vmName)", comment: "The snapshots window's title; %@ is the VM's name.")
                    .font(.nido(Theme.TypeSize.headline, .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(verbatim: model.subtitle)
                    .font(.nido(Theme.TypeSize.caption))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .accessibilityIdentifier("snapshots-subtitle")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.l)
        .frame(height: Theme.Layout.toolbarHeight)
        .background(Theme.Color.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Color.border).frame(height: Theme.Layout.hairline)
        }
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if !model.hasLoaded {
            Color.clear
        } else if model.snapshots.isEmpty, model.creatingName == nil, model.error == nil {
            NidoEmptyState(
                title: "No snapshots",
                message: "A snapshot keeps the disk of \(model.vmName) as it is now, and its memory too if the VM is running. You can go back to it anytime.",
                identifier: "snapshots-empty", buttonLabel: "Create Snapshot…", buttonIdentifier: "snapshot-create",
                onCreate: model.canCreate ? { model.beginCreate() } : nil)
                .padding(Theme.Space.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("A snapshot keeps the VM’s disk and settings; taken while the VM is running, its memory too (with saved state). Restoring it takes \(model.vmName) back to that moment.")
                        .font(.nido(Theme.TypeSize.body))
                        .foregroundStyle(Theme.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    top
                        .padding(.vertical, Theme.Space.s)
                    listHeading
                        .font(.nido(Theme.TypeSize.caption, .semibold))
                        .foregroundStyle(Theme.Color.textSecondary)
                    if let creating = model.creatingName {
                        NidoSnapshotRow(name: creating, kind: .creating)
                    }
                    ForEach(model.snapshots) { snapshot in
                        NidoSnapshotRow(
                            name: snapshot.name,
                            kind: .normal(date: SnapshotsModel.dateText(snapshot.createdAt),
                                          savedState: snapshot.hasSavedState),
                            canRestore: model.canRestore, canDelete: model.canDelete,
                            deleteHelp: model.deleteLockedNote,
                            onRestore: { model.requestRestore(snapshot) },
                            onDelete: { model.requestDelete(snapshot) })
                            .accessibilityIdentifier("snapshot-row-\(snapshot.name)")
                    }
                    if let note = model.lockedNote {
                        Text(verbatim: note)
                            .font(.nido(Theme.TypeSize.caption))
                            .foregroundStyle(Theme.Color.textSecondary)
                            .accessibilityIdentifier("snapshots-locked-note")
                    }
                }
                .frame(width: Theme.Layout.snapshotsColumnWidth, alignment: .leading)
                .padding(Theme.Space.xl)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var listHeading: Text {
        let count = model.snapshots.count + (model.creatingName == nil ? 0 : 1)
        return model.creatingName == nil
            ? Text("Snapshots (\(count)), newest first", comment: "The heading of the list with its number of snapshots. [not a count]")
            : Text("Snapshots (\(count))", comment: "The heading of the list with its number of snapshots. [not a count]")
    }

    /// "Current state", or the ProgressPanel of a snapshot being created, or its error.
    @ViewBuilder private var top: some View {
        if let creating = model.creatingName {
            NidoProgressPanel(
                verbatim: String(localized: "Creating \(creating)", comment: "%@ is a VM's or a snapshot's name."),
                detail: model.creatingDetail)
        } else if let error = model.error {
            NidoProgressPanel(
                verbatim: model.errorTitle, detail: error, isError: true,
                onClose: { model.dismissError() }, onRetry: { Task { await model.retry() } })
                .accessibilityIdentifier("snapshots-error")
        } else {
            NidoSnapshotRow(
                name: String(localized: "Current state", comment: "The VM as it is now, above its snapshots."),
                kind: .current(status: model.status, note: String(localized: "Changes since the last snapshot exist only here.")),
                canCreate: model.canCreate, onCreate: { model.beginCreate() })
                .accessibilityIdentifier("snapshots-current")
        }
        if !model.warnings.isEmpty {
            Text(verbatim: model.warnings.joined(separator: "\n"))
                .font(.nido(Theme.TypeSize.caption, .semibold))
                .foregroundStyle(Theme.Color.statusPaused)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "Create Snapshot…": the name (default "snapshot-1"), Cancel and Create.
private struct NameSheet: View {
    @Bindable var model: SnapshotsModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Create a Snapshot of \(model.vmName)", comment: "Sheet title; %@ is the VM's name.")
                .font(.nido(Theme.TypeSize.headline, .semibold))
                .foregroundStyle(Theme.Color.textPrimary)
            Text(verbatim: model.createMessage)
                .font(.nido(Theme.TypeSize.body))
                .foregroundStyle(Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                NidoInfoRow(label: "Name") {
                    TextField("Name", text: $model.newName)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .font(.nido(Theme.TypeSize.body))
                        .foregroundStyle(Theme.Color.textSecondary)
                        .onSubmit(confirm)
                        .accessibilityIdentifier("snapshot-name")
                }
                Text("Letters, numbers, periods, hyphens and underscores; different from the other snapshots of \(model.vmName).",
                     comment: "What a snapshot's name may hold; %@ is the VM's name.")
                    .font(.nido(Theme.TypeSize.caption))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Theme.Space.s) {
                Spacer(minLength: 0)
                NidoButton("Cancel") { model.cancelCreate() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("snapshot-name-cancel")
                NidoButton("Create", kind: .primary, action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canConfirmCreate)
                    .accessibilityIdentifier("snapshot-name-confirm")
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: Theme.Layout.confirmSheetWidth)
        .background(Theme.Color.surfaceRaised)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("snapshot-name-sheet")
    }

    private func confirm() {
        Task { await model.confirmCreate() }
    }
}
