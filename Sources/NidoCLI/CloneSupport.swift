// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore

/// `nido clone`: the logic, testable without ArgumentParser.
extension CLISupport {
    /// Clones the stopped VM `source` as `target` (bundle lock with owner `.cli`). Returns the
    /// stdout text: what was copied and what was not (suspended state, snapshots); for macOS also
    /// the steps to run once in the clone (`VMCloner.cloneNotes`).
    public static func cloneVM(
        source: String, target: String, paths: NidoPaths, runner: ProcessRunner = SystemProcessRunner()
    ) async throws -> String {
        let sourceName = try VMName(source)
        let targetName = try VMName(target)
        // Read only, before the clone: what the copy leaves behind (the source keeps it all).
        let bundle = try VMBundle.open(sourceName, paths: paths)
        let config = try? bundle.readConfig()
        let suspended = config.map(bundle.hasSuspendedState) ?? false
        let snapshots = (try? SnapshotStore(bundle: bundle).list().count) ?? 0

        let result = try await VMCloner(paths: paths, runner: runner)
            .cloneReportingNotes(sourceName, as: targetName, owner: .cliOperation)
        let clone = result.bundle
        var lines: [String]
        let (copy, source) = (clone.displayName, bundle.displayName)
        if result.guest == .macos {
            lines = [L10n.string("VM \(copy) created as a copy of \(source): new network address and new machine identifier.")]
        } else {
            lines = [L10n.string("VM \(copy) created as a copy of \(source): new network address and new identity; at first boot its host name becomes \(copy).")]
        }
        if suspended {
            lines.append(L10n.string("The suspended state of \(source) wasn’t copied: the copy will cold-boot."))
        }
        if snapshots > 0 {
            lines.append(L10n.string("\(source)’s \(snapshots) snapshots weren’t copied."))
        }
        if !result.cloneNotes.isEmpty {
            lines.append(L10n.string("Run these once in the copy, in the guest’s Terminal:"))
            lines += result.cloneNotes.map { "  " + $0 }
        }
        return lines.joined(separator: "\n")
    }
}
