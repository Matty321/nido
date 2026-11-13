// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore
import Observation

/// State and actions of the snapshots window of one VM (S09). Every operation goes through the
/// VM's `VMWindowModel`, which runs it off the main actor and one at a time with suspend, pause,
/// stop and start (`VMWindowModel.createSnapshot` and siblings).
///
/// Create: live through the VM's session while it runs in this app (the snapshot keeps the
/// memory: "with saved state"), otherwise from the stopped VM's files. Restore and delete: only
/// while no machine runs (refused with a message otherwise), each after a confirmation sheet.
@MainActor
@Observable
final class SnapshotsModel {
    enum Operation: Sendable {
        case create, restore, delete
    }

    let vmName: String
    /// The snapshots, newest first.
    private(set) var snapshots: [Snapshot] = []
    private(set) var hasLoaded = false
    /// The name typed in the "Crea snapshot…" sheet.
    var newName = "snapshot-1"
    /// True while the "Crea snapshot…" sheet is shown.
    private(set) var isNaming = false
    /// The snapshot being created (the ProgressPanel and the "in creazione" row).
    private(set) var creatingName: String?
    /// The snapshot whose restore or deletion waits for the confirmation sheet.
    private(set) var pendingRestore: Snapshot?
    private(set) var pendingDelete: Snapshot?
    /// The last failure, shown in the ProgressPanel "errore" until Close.
    private(set) var error: String?
    /// What the last operation that failed was, for Try Again.
    private(set) var failedOperation: Operation?
    /// Warnings of the last create (the snapshot exists, e.g. it could not be synced to disk).
    private(set) var warnings: [String] = []
    /// Who runs the VM in another process (`nido start`: `.cli`; a `nido` maintenance command:
    /// `.cliOperation`; another Nido: `.app`), nil when
    /// no other process holds it: then nothing can be done here.
    private(set) var elsewhereOwner: LockOwner?
    var runsElsewhere: Bool { elsewhereOwner != nil }
    /// False once the VM's bundle is gone (deleted): the window closes.
    private(set) var bundleExists = true

    @ObservationIgnored let window: VMWindowModel
    @ObservationIgnored private let bundle: VMBundle

    init(window: VMWindowModel, bundle: VMBundle) {
        self.window = window
        self.bundle = bundle
        vmName = window.name.rawValue
    }

    // MARK: - State

    /// Rereads the list and who holds the VM.
    func load() async {
        refreshHolder()
        guard bundleExists else { return }
        window.syncSuspendedState()
        do {
            let newest: [Snapshot] = try await window.listSnapshots().reversed()
            if newest != snapshots { snapshots = newest }
        } catch {
            show(error, .create)
        }
        hasLoaded = true
    }

    /// `nido start` or another Nido runs the VM (its lock is held and not by this window).
    func refreshHolder() {
        bundleExists = FileManager.default.fileExists(atPath: bundle.configURL.path)
        guard window.isGone, !window.isSnapshotting, let holder = BundleLock.holder(bundle) else {
            elsewhereOwner = nil
            return
        }
        elsewhereOwner = holder.owner
    }

    var isWorking: Bool { window.isSnapshotting || creatingName != nil }

    /// The VM runs in this app (or is starting, stopping…): a snapshot keeps its memory.
    var runsInApp: Bool { !window.isGone }

    var canCreate: Bool { !isWorking && !runsElsewhere && (window.isGone || isLive) }
    var canRestore: Bool { !isWorking && !runsElsewhere && window.isGone }
    var canDelete: Bool { canRestore }

    private var isLive: Bool { window.state == .running || window.state == .paused }

    /// The badge of the "Stato attuale" row.
    var status: NidoStatusBadge.Status {
        if runsElsewhere { return .running }
        switch window.state {
        case .running: return .running
        case .paused, .pausing: return .paused
        case .starting, .resuming, .stopping: return .starting
        case .error: return .error
        case .stopped: return window.isSuspended ? .suspended : .stopped
        }
    }

    /// "3 snapshots · debian-13 is running".
    var subtitle: String {
        let count = snapshots.isEmpty ? String(localized: "No snapshots")
            : String(localized: "\(snapshots.count) snapshots", comment: "The snapshots window's subtitle.")
        return "\(count) · \(stateText)"
    }

    /// The VM's state after the count: "debian-13 is running".
    private var stateText: String {
        let vm = vmName
        if let elsewhereOwner {
            return switch elsewhereOwner {
            case .cli:
                String(localized: "\(vm) is running in Terminal",
                       comment: "The snapshots window's subtitle, after the count; %@ is the VM's name.")
            case .cliOperation:
                String(localized: "\(vm) is busy with a nido command in Terminal",
                       comment: "The snapshots window's subtitle, after the count; %@ is the VM's name.")
            case .app:
                String(localized: "\(vm) is open in another instance of Nido",
                       comment: "The snapshots window's subtitle, after the count; %@ is the VM's name.")
            }
        }
        return switch status {
        case .running:
            String(localized: "\(vm) is running", comment: "The snapshots window's subtitle, after the count; %@ is the VM's name.")
        case .paused:
            String(localized: "\(vm) is paused", comment: "The snapshots window's subtitle, after the count; %@ is the VM's name.")
        case .suspended:
            String(localized: "\(vm) is suspended", comment: "The snapshots window's subtitle, after the count; %@ is the VM's name.")
        case .error:
            String(localized: "\(vm) has an error", comment: "The snapshots window's subtitle, after the count; %@ is the VM's name.")
        case .starting:
            String(localized: "\(vm) is changing state",
                   comment: "The snapshots window's subtitle, after the count; %@ is the VM's name.")
        default:
            String(localized: "\(vm) is stopped", comment: "The snapshots window's subtitle, after the count; %@ is the VM's name.")
        }
    }

    /// Under the list while the VM runs: why Restore is off (the render's wording).
    var lockedNote: String? {
        guard !window.isGone || runsElsewhere else { return nil }
        return Self.restoreLocked(vmName)
    }

    /// Why Delete is off (its help tag), nil when it is on.
    var deleteLockedNote: String? {
        guard !window.isGone || runsElsewhere else { return nil }
        return Self.deleteLocked(vmName)
    }

    nonisolated private static func restoreLocked(_ vm: String) -> String {
        String(localized: "To restore a snapshot, stop \(vm) first.", comment: "%@ is the VM's name.")
    }

    nonisolated private static func deleteLocked(_ vm: String) -> String {
        String(localized: "To delete a snapshot, stop \(vm) first.", comment: "%@ is the VM's name.")
    }

    // MARK: - Create

    /// The text of the "Create Snapshot…" sheet: what the snapshot will hold.
    var createMessage: String {
        let vm = vmName
        if runsInApp {
            return String(localized: "\(vm) is running: Nido pauses it for a few seconds and saves its memory too.",
                          comment: "%@ is the VM's name.")
        }
        if window.isSuspended {
            return String(localized: "\(vm) is suspended: Nido saves its disk, settings and suspended state, which resumes where you left off after a restore.",
                          comment: "%@ is the VM's name.")
        }
        return String(localized: "Nido saves the disk and settings of \(vm) as they are now.", comment: "%@ is the VM's name.")
    }

    /// The detail of the progress panel while a snapshot is created.
    var creatingDetail: String {
        let vm = vmName
        if runsInApp {
            return String(localized: "\(vm) stays paused for a few seconds while Nido saves its memory and disk.",
                          comment: "%@ is the VM's name.")
        }
        if window.isSuspended {
            return String(localized: "Nido is copying the disk, settings and suspended state of \(vm).", comment: "%@ is the VM's name.")
        }
        return String(localized: "Nido is copying the disk and settings of \(vm).", comment: "%@ is the VM's name.")
    }

    var canConfirmCreate: Bool { !newName.trimmingCharacters(in: .whitespaces).isEmpty }

    func beginCreate() {
        guard !isWorking else { return }
        error = nil
        newName = Self.defaultName(taken: snapshots.map(\.name))
        isNaming = true
    }

    func cancelCreate() {
        isNaming = false
    }

    /// "Create" in the sheet.
    func confirmCreate() async {
        // Return in the name field submits even while Crea is disabled.
        guard canConfirmCreate else { return }
        isNaming = false
        let name = newName.trimmingCharacters(in: .whitespaces)
        error = nil
        warnings = []
        creatingName = name
        defer { creatingName = nil }
        do {
            warnings = try await window.createSnapshot(named: name)
            failedOperation = nil
        } catch {
            show(error, .create)
        }
        await load()
    }

    func dismissError() {
        error = nil
        failedOperation = nil
    }

    // MARK: - Restore

    func requestRestore(_ snapshot: Snapshot) {
        error = nil
        pendingRestore = snapshot
    }

    func cancelRestore() {
        pendingRestore = nil
    }

    var restoreTitle: String {
        let name = pendingRestore?.name ?? ""
        return String(localized: "Restore \(name)?", comment: "%@ is the snapshot's name.")
    }

    /// "The VM will go back to its state as of Oct 24, 2026 at 10:42 AM; later changes will be lost."
    var restoreMessage: String {
        let date = pendingRestore.map { Self.dateText($0.createdAt) } ?? ""
        if window.isSuspended {
            let vm = vmName
            return String(localized: "The VM will go back to its state as of \(date); later changes and the saved state of \(vm) will be lost.",
                          comment: "%1$@: the snapshot's date and time; %2$@: the VM's name.")
        }
        return String(localized: "The VM will go back to its state as of \(date); later changes will be lost.",
                      comment: "%@ is the snapshot's date and time.")
    }

    /// "Restore" in the sheet.
    func confirmRestore() async {
        guard let snapshot = pendingRestore else { return }
        pendingRestore = nil
        do {
            try await window.restoreSnapshot(snapshot.id)
            failedOperation = nil
        } catch {
            show(error, .restore, keeping: snapshot)
        }
        await load()
    }

    // MARK: - Delete

    func requestDelete(_ snapshot: Snapshot) {
        error = nil
        pendingDelete = snapshot
    }

    func cancelDelete() {
        pendingDelete = nil
    }

    var deleteTitle: String {
        let name = pendingDelete?.name ?? ""
        return String(localized: "Delete \(name)?")
    }

    var deleteMessage: String {
        let vm = vmName
        if pendingDelete?.hasSavedState == true {
            return String(localized: "The snapshot and the memory saved with it will be deleted from this Mac; \(vm) stays as it is. This can’t be undone.",
                          comment: "%@ is the VM's name.")
        }
        return String(localized: "The snapshot will be deleted from this Mac; \(vm) stays as it is. This can’t be undone.",
                      comment: "%@ is the VM's name.")
    }

    func confirmDelete() async {
        guard let snapshot = pendingDelete else { return }
        pendingDelete = nil
        do {
            try await window.deleteSnapshot(snapshot.id)
            failedOperation = nil
        } catch {
            show(error, .delete, keeping: snapshot)
        }
        await load()
    }

    // MARK: - Errors

    /// The snapshot of a failed restore or delete, for Try Again.
    @ObservationIgnored private var retryTarget: Snapshot?

    private func show(_ error: any Error, _ operation: Operation, keeping snapshot: Snapshot? = nil) {
        self.error = Self.message(for: error, vm: vmName, operation: operation)
        failedOperation = operation
        retryTarget = snapshot
    }

    /// The title of the error panel.
    var errorTitle: String {
        switch failedOperation {
        case .restore: String(localized: "Restore failed")
        case .delete: String(localized: "Delete failed")
        default: String(localized: "Snapshot failed")
        }
    }

    /// Try Again of the error panel: a create runs again; a failed restore or delete asks for the
    /// confirmation again.
    func retry() async {
        switch failedOperation {
        case .create:
            error = nil
            await confirmCreate()
        case .restore:
            error = nil
            if let retryTarget { requestRestore(retryTarget) }
        case .delete:
            error = nil
            if let retryTarget { requestDelete(retryTarget) }
        case nil:
            break
        }
    }

    /// The sentence for a failure, with what to do next.
    nonisolated static func message(for error: any Error, vm: String, operation: Operation) -> String {
        guard let error = error as? NidoError else {
            let reason = error.localizedDescription
            return sentence(String(localized: "The operation failed: \(reason)", comment: "%@ is why."))
        }
        switch error {
        case .insufficientSpace:
            let reason = sentence(error.localizedDescription)
            return String(localized: "\(reason) Free up space on the Mac and try again.",
                          comment: "%@ says that there isn't enough space, a sentence.")
        case .snapshotUnsupported(let reason):
            return String(localized: "Snapshots of a running VM aren’t supported: \(reason). Stop \(vm) and try again.",
                          comment: "%1$@: why; %2$@: the VM's name.")
        case .vmMustBeStopped:
            switch operation {
            case .restore: return restoreLocked(vm)
            case .delete: return deleteLocked(vm)
            case .create:
                return String(localized: "Wait for \(vm) to finish starting or stopping, then try again.", comment: "%@ is the VM's name.")
            }
        case .runningInAnotherProcess, .alreadyRunning:
            return String(localized: "\(vm) is running in Terminal (nido start): stop it first.", comment: "%@ is the VM's name.")
        case .restoreIncomplete(let path):
            return String(localized: "The restore failed and was only partly undone: the original file is kept at \(path). Try again: Nido puts the files back in place before every operation.",
                          comment: "%@ is a file's path.")
        default:
            return sentence(error.localizedDescription)
        }
    }

    /// Capital first letter, final full stop.
    nonisolated private static func sentence(_ text: String) -> String {
        guard let first = text.first else { return text }
        let capital = first.uppercased() + text.dropFirst()
        return capital.hasSuffix(".") ? capital : capital + "."
    }

    // MARK: - Formatting

    /// "24 ott 2026, 10:42" in Italian, "Oct 24, 2026 at 10:42 AM" in US English: the UI's locale.
    nonisolated static func dateText(_ date: Date, locale: Locale = .current) -> String {
        date.formatted(Date.FormatStyle(locale: locale).day().month(.abbreviated).year().hour().minute())
    }

    /// "snapshot-1", or the first "snapshot-N" not taken (names compare without regard to case).
    nonisolated static func defaultName(taken: [String]) -> String {
        let used = Set(taken.map { $0.lowercased() })
        var index = 1
        while used.contains("snapshot-\(index)") { index += 1 }
        return "snapshot-\(index)"
    }
}
