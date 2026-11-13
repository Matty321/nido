// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore

/// `nido snapshot list|create|restore|delete`: the logic, testable without ArgumentParser.
/// The CLI never snapshots a running VM: a VM running in another process (another `nido`, or
/// the app) is refused with `.runningInAnotherProcess`; only the app snapshots a running VM,
/// through its session.
extension CLISupport {
    /// The VM's snapshots as a table (`NAME CREATED STATE ID`), oldest first. Reads only.
    public static func listSnapshots(vm: String, paths: NidoPaths) throws -> String {
        let bundle = try VMBundle.open(try VMName(vm), paths: paths)
        let snapshots = try SnapshotStore(bundle: bundle).list()
        guard !snapshots.isEmpty else { return L10n.string("No snapshots.") }
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let rows = snapshots.map { snapshot in
            [snapshot.name, formatter.string(from: snapshot.createdAt),
             snapshot.hasSavedState ? L10n.string("with saved state") : L10n.string("disk only"), snapshot.id.uuidString]
        }
        let header = [L10n.string("NAME"), L10n.string("CREATED"), L10n.string("STATE"), "ID"]
        return formatTable([header] + rows)
    }

    /// Snapshot of a stopped VM (bundle lock with owner `.cli`). Returns the stdout text.
    public static func createSnapshot(vm: String, name: String, paths: NidoPaths) async throws -> String {
        let bundle = try VMBundle.open(try VMName(vm), paths: paths)
        let (snapshot, warnings) = try await SnapshotStore(bundle: bundle)
            .createReportingWarnings(name: name, owner: .cliOperation, session: nil)
        let lines = [L10n.string("Snapshot \(snapshot.name) of \(bundle.displayName) created (\(snapshot.id.uuidString)).")]
            // A period ends the sentence alike in the five languages.
            + warnings.map { L10n.string("Warning: \($0 + ".")") }
        return lines.joined(separator: "\n")
    }

    /// The snapshot `reference` (name or id) of `vm`: `.snapshotNotFound` otherwise.
    public static func findSnapshot(vm: String, reference: String, paths: NidoPaths) throws -> (VMBundle, Snapshot) {
        let bundle = try VMBundle.open(try VMName(vm), paths: paths)
        return (bundle, try SnapshotStore(bundle: bundle).find(reference))
    }

    /// Puts a stopped VM back to the snapshot `reference`. A template is refused (`.isTemplate`),
    /// as in the app: a restored saved state would make it a suspended template. Returns the
    /// stdout text.
    public static func restoreSnapshot(vm: String, reference: String, paths: NidoPaths) throws -> String {
        let (bundle, snapshot) = try findSnapshot(vm: vm, reference: reference, paths: paths)
        let current = try bundle.readConfig()
        guard !current.isTemplate else { throw NidoError.isTemplate(current.name.rawValue) }
        try SnapshotStore(bundle: bundle).restore(snapshot.id, owner: .cliOperation)
        let next: String
        if !snapshot.hasSavedState {
            next = L10n.string("At its next start, the VM boots from the snapshot’s disk.")
        } else if let config = try? bundle.readConfig(), SuspendedState.nextStartResumes(bundle: bundle, config: config) {
            next = L10n.string("At its next start, the VM resumes from the saved state.")
        } else {
            // The state was saved with other settings (CPU, memory, folders, Rosetta).
            next = L10n.string("The settings changed after the snapshot: at the next start, the saved state will be discarded and the VM will cold-boot.")
        }
        return L10n.string("VM \(bundle.displayName) restored to snapshot \(snapshot.name). \(next)")
    }

    /// The question asked before a restore: what it loses (the disk's later changes, and the
    /// saved state of a suspended VM).
    public static func restoreQuestion(vm: String, snapshot: String, suspended: Bool) -> String {
        let lost = suspended
            ? L10n.string("Later changes to the disk and the saved state of \(vm) will be lost.")
            : L10n.string("Later changes to the disk will be lost.")
        return L10n.string("Restore \(vm) to snapshot \(snapshot)? \(lost) [y/N] ")
    }

    /// Deletes the snapshot `reference` of a stopped VM. Returns the stdout text.
    public static func deleteSnapshot(vm: String, reference: String, paths: NidoPaths) throws -> String {
        let (bundle, snapshot) = try findSnapshot(vm: vm, reference: reference, paths: paths)
        try SnapshotStore(bundle: bundle).delete(snapshot.id, owner: .cliOperation)
        return L10n.string("Snapshot \(snapshot.name) deleted.")
    }
}
