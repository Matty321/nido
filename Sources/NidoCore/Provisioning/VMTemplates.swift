// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Marks a stopped VM as a template (`VMConfig.isTemplate`) and back. A template is not started
/// (`VMSession` refuses it) nor plainly cloned; new VMs come from `VMCloner.createFromTemplate`.
/// Both operations are maintenance: the caller passes its lock owner (`.cliOperation` for the CLI).
public enum VMTemplates {
    /// Saves `bundle` as a template. Refused when it runs (`.vmMustBeStopped`) or has a suspended
    /// state (`.templateHasSuspendedState`: resume and stop it first). Snapshots are kept.
    /// Templates are Linux-only in M3b: a macOS VM is refused (`.macTemplatesUnavailable`).
    public static func save(_ bundle: VMBundle, owner: LockOwner) throws {
        try VMControl.editConfig(bundle, owner: owner) { config in
            guard config.guest == .linux else { throw NidoError.macTemplatesUnavailable }
            guard config.suspendedConfigHash == nil, !bundle.hasSuspendedState(config) else {
                throw NidoError.templateHasSuspendedState(bundle.displayName)
            }
            config.isTemplate = true
        }
    }

    /// Makes the template startable again (`.notATemplate` for a VM that is not one).
    public static func edit(_ bundle: VMBundle, owner: LockOwner) throws {
        try VMControl.editConfig(bundle, owner: owner) { config in
            guard config.isTemplate else { throw NidoError.notATemplate(bundle.displayName) }
            config.isTemplate = false
        }
    }
}
