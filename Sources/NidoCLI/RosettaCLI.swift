// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore

/// `nido rosetta status|install|enable|disable`: the logic, testable without ArgumentParser.
extension CLISupport {
    /// One line on what this Mac has.
    public static func rosettaStatus(_ state: RosettaState) -> String {
        switch state {
        case .installed:
            L10n.string("Rosetta for Linux is installed: VMs with Rosetta turned on run x86_64 binaries.")
        case .notInstalled:
            L10n.string("Rosetta for Linux isn’t installed on this Mac. Install it with “nido rosetta install”.")
        case .unsupported:
            L10n.string("Rosetta for Linux isn’t available on this Mac.")
        }
    }

    /// Text of the question asked before the system install.
    public static var rosettaInstallQuestion: String {
        L10n.string("macOS will download and install Rosetta for Linux (a system component; it may ask you to confirm). Continue? [y/N] ")
    }

    /// Installs Rosetta only when it is missing and the user said yes (`confirm`, or `assumeYes`
    /// for `--yes`). `install` is the system install (`RosettaSupport.install`), never run
    /// otherwise. Returns the text for stdout.
    public static func installRosetta(
        state: RosettaState, assumeYes: Bool,
        confirm: (String) -> Bool,
        install: () async throws -> Void
    ) async throws -> String {
        switch state {
        case .installed:
            return L10n.string("Rosetta for Linux is already installed.")
        case .unsupported:
            throw NidoError.rosettaUnavailable
        case .notInstalled:
            guard assumeYes || confirm(rosettaInstallQuestion) else {
                return L10n.string("Installation canceled.")
            }
            try await install()
            return L10n.string("Rosetta for Linux installed.")
        }
    }

    /// Turns Rosetta on or off for a stopped VM (bundle lock with owner `.cli`). Turning it on is
    /// refused, with the reason the app shows (`RosettaState.error`), unless Rosetta is installed
    /// on this Mac; turning it off always works. A template is refused (`.isTemplate`), as in the
    /// app, and so is a macOS VM, either way (`.rosettaNotForMac`: Rosetta for Linux does not
    /// concern it). Returns the text for stdout.
    @discardableResult
    public static func setRosetta(
        vm: String, enabled: Bool, paths: NidoPaths, state: RosettaState = .current
    ) throws -> String {
        let bundle = try VMBundle.open(try VMName(vm), paths: paths)
        // Checked before Rosetta's state on this Mac, which says nothing about a macOS guest.
        guard try bundle.readConfig().guest == .linux else { throw CLIError.rosettaNotForMac }
        if enabled, let error = state.error { throw error }
        let config = try VMControl.editConfig(bundle, owner: .cliOperation) { config in
            guard config.guest == .linux else { throw CLIError.rosettaNotForMac }
            guard !config.isTemplate else { throw NidoError.isTemplate(config.name.rawValue) }
            config.rosetta = enabled
        }
        let warning = suspendedWarning(bundle, config, rosettaState: state)
        guard enabled else {
            return ([L10n.string("Rosetta turned off for \(config.name.rawValue). Takes effect at its next start.")] + warning)
                .joined(separator: "\n")
        }
        let name = config.name.rawValue
        var lines = [L10n.string("Rosetta turned on for \(name): x86_64 binaries run in the VM. Takes effect at the next start of \(name).")]
            + warning
        if !config.guestRegistersRosetta {
            lines += ["",
                      L10n.string("VM created with an earlier version of Nido: run this once in the VM"),
                      "  \(RosettaSupport.legacyGuestCommand)"]
        }
        return lines.joined(separator: "\n")
    }
}
