// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore

/// Errors specific to the `nido` command line front end.
public enum CLIError: Error, Equatable, Sendable {
    case missingSSHKey
    case fromTemplateConflict
    case imageSourceRequired
    case unknownImage(String)
    case invalidRoot(String)
    case vmFailed(String)
    /// `nido stop --suspend` did not end with a suspended VM (the message says what happened).
    case suspendNotCompleted(String)
    /// `create --ipsw` with an option of the Linux creation (image, template, profile).
    case ipswConflict
    /// `create --ipsw` without `--user`.
    case missingUser
    /// `create --user` without `--ipsw`: a Linux guest's account is always `nido`.
    case userRequiresIPSW
    /// `create --ipsw` interrupted (Ctrl-C): the installer removed what it had created.
    case installCancelled
    /// `start --console` on a macOS VM, which has no serial console.
    case macConsoleUnavailable
    /// `nido ssh` to a macOS guest whose port 22 refuses connections: Remote Login is off.
    case remoteLoginOff
    /// `nido rosetta enable|disable` on a macOS VM.
    case rosettaNotForMac
    /// `nido net allow|reset` without a terminal: Touch ID or the Mac password cannot be asked.
    case notInteractive
    /// Touch ID or the Mac password refused or cancelled: the list did not change.
    case authenticationFailed
    /// `egress.json` of the VM does not load (link, too big, invalid): `nido net reset` is the way out.
    case malformedEgressPolicy(vm: String, path: String)
    /// `nido net reset` not confirmed.
    case netResetCancelled
    /// `nido net allow` of a broad wildcard declined at its warning.
    case netAllowCancelled
    /// `nido net allow` on a list already holding `EgressPolicy.maxPatterns` domains.
    case tooManyDomains
}

extension CLIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .fromTemplateConflict:
            L10n.string("--from-template can’t be combined with --image, --image-file, --cpus, --memory, --disk, --no-packages or --no-guest-tools: the VM takes them from the template")
        case .missingSSHKey:
            L10n.string("missing --ssh-key <path.pub>")
        case .imageSourceRequired:
            L10n.string("specify exactly one of --image or --image-file")
        case .unknownImage(let id):
            L10n.string("unknown image: “\(id)” (available: \(CloudImageCatalog.all.map(\.id).joined(separator: ", ")))")
        case .invalidRoot(let path):
            L10n.string("NIDO_ROOT must be the absolute path of an existing directory: \(path)")
        case .vmFailed(let reason):
            L10n.string("the VM stopped with an error: \(reason)")
        case .suspendNotCompleted(let message):
            message
        case .ipswConflict:
            L10n.string("--ipsw can’t be combined with --image, --image-file, --from-template, --no-packages or --no-guest-tools: macOS is installed from the IPSW")
        case .missingUser:
            L10n.string("missing --user <name>: the short name of the account you’ll create in macOS Setup Assistant, used by nido ssh")
        case .userRequiresIPSW:
            L10n.string("--user works only with --ipsw: in Linux VMs the user is nido")
        case .installCancelled:
            L10n.string("installation canceled: no VM was created")
        case .macConsoleUnavailable:
            L10n.string("macOS VMs have no serial console: use the Nido window or nido ssh")
        case .remoteLoginOff:
            L10n.string("turn on Remote Login in the guest: open the VM in Nido, Terminal Access panel")
        case .rosettaNotForMac:
            L10n.string("Rosetta for Linux doesn’t apply to macOS VMs: in macOS, Rosetta is installed inside the VM")
        case .notInteractive:
            L10n.string("an interactive terminal is needed: Nido asks for Touch ID or the Mac password before widening the domain list")
        case .authenticationFailed:
            L10n.string("authentication failed: the domain list didn’t change")
        case .malformedEgressPolicy(let vm, let path):
            L10n.string("\(ConsoleSanitizer.echoable(path)) is invalid or unsafe (a link, too large, or invalid JSON): Nido doesn’t use it, and a running VM keeps the last valid list. To rewrite it with the base list: nido net reset \(ConsoleSanitizer.echoable(vm))")
        case .netResetCancelled:
            L10n.string("reset canceled: egress.json didn’t change")
        case .netAllowCancelled:
            L10n.string("not added: egress.json didn’t change")
        case .tooManyDomains:
            L10n.string("the list already has \(EgressPolicy.maxPatterns) domains, the maximum: remove some with nido net deny")
        }
    }
}
