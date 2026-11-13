// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore

/// `nido template save|edit` and `nido create --from-template`: the logic, testable without
/// ArgumentParser. Maintenance operations: the bundle lock is held with owner `.cliOperation`.
extension CLISupport {
    /// Makes the stopped VM `vm` a template. Refused when it runs (`.vmMustBeStopped`) or has a
    /// suspended state (`.templateHasSuspendedState`); snapshots are kept.
    public static func saveTemplate(vm: String, paths: NidoPaths) throws -> String {
        let bundle = try VMBundle.open(try VMName(vm), paths: paths)
        try VMTemplates.save(bundle, owner: .cliOperation)
        return L10n.string("VM \(bundle.displayName) saved as a template: it no longer starts; make copies with nido create <name> --from-template \(bundle.displayName).")
    }

    /// Makes the template `vm` startable again (`isTemplate = false`).
    public static func editTemplate(vm: String, paths: NidoPaths) throws -> String {
        let bundle = try VMBundle.open(try VMName(vm), paths: paths)
        try VMTemplates.edit(bundle, owner: .cliOperation)
        return L10n.string("The template \(bundle.displayName) can be started now: after your changes, save it again with nido template save \(bundle.displayName).")
    }

    /// Creates `target` from the template `template` (a clone with a new identity, no extra disk
    /// space). `sshKey` nil: the template's own key. CPU, memory and disk are the template's.
    public static func createFromTemplate(
        template: String, target: String, sshKey: String?, paths: NidoPaths,
        runner: ProcessRunner = SystemProcessRunner()
    ) async throws -> String {
        let templateName = try VMName(template)
        let targetName = try VMName(target)
        let keyURL = sshKey.map { URL(fileURLWithPath: $0) }
        let created = try await VMCloner(paths: paths, runner: runner)
            .createFromTemplate(templateName, as: targetName, sshKeyPath: keyURL, owner: .cliOperation)
        return L10n.string("VM \(created.displayName) created from the template \(templateName.rawValue): new identity, no shared folders; CPU, memory and disk are the template’s.")
    }
}
