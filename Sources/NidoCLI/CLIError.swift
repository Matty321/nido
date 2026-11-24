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
    /// `nido start`: an agent's rollback to `checkpoint` failed (`reason`, localized); the VM is stopped.
    case rollbackFailed(checkpoint: String, reason: String)
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
    /// `nido act` or `nido mcp` on a VM whose agent access is off (the value is the VM name).
    case agentAccessOff(String)
    /// `nido mcp --fresh` on a base VM with a saved state (the value is the VM name): its copy
    /// would start from a disk in the middle of a session.
    case freshBaseSuspended(String)
    /// `nido mcp --fresh` on a base that is itself a fresh Mac of a session (the value is the VM
    /// name): its own session or a sweep would delete it under this one.
    case freshBaseIsFresh(String)
    /// `nido agent setup`: Nido's key is not authorized and there is no password to do it with.
    case agentPasswordNeeded(String)
    /// `nido agent setup`: the nido tool that answers ssh's password prompt is missing.
    case agentAskpassMissing
    /// `nido agent enable` on a Linux VM: Nido Agent is a macOS guest helper.
    case agentNotForLinux
    /// `nido agent setup`: the helper could not be opened because nobody is logged in to the guest
    /// (the value is the VM name).
    case guestLoginNeeded(String)
    /// `nido agent setup`: the helper is not ready and the guest's SSH does not answer, so the VM
    /// (name) is most likely at its login window (FileVault).
    case agentLoginWindow(String)
    /// `nido agent setup`: the running VM's owner serves no agent socket (the message says why).
    case agentNotServed(String)
    /// `nido act` with an action name that does not exist.
    case unknownAgentAction(String)
    /// `nido act` with a missing argument or an option it does not take; the value is the syntax.
    case agentUsage(String)
    /// `nido agent log --clear` without `--yes` and without a terminal to ask.
    case agentLogClearNeedsConfirmation
    /// `nido agent log --limit` with something other than a whole number of at least 1.
    case agentLogLimitInvalid
    /// `nido agent log --clear` together with `--limit` or `--json`.
    case agentLogClearConflict
    /// `nido agent log --yes` without `--clear`.
    case agentLogYesWithoutClear
    /// `nido act` with a value that is not a number (the name of the argument).
    case agentNotANumber(String)
    /// `nido act` with an integer outside its range (name, lowest, highest).
    case agentOutOfRange(String, Int, Int)
    /// `nido act screenshot --output` onto a file that exists.
    case outputExists(String)
    /// `nido act screenshot --output` with an answer that names no file to copy.
    case noScreenshotFile
    /// `nido act put-file` with a local file over `AgentProtocol.maxTransferBytes`.
    case agentFileTooLarge
    /// `nido act put-file` with a local path that is a link, a folder or anything but a regular file.
    case notARegularFile(String)
    /// `nido act put-file` with a local file that can't be opened (missing, no permission); the
    /// values are the path and the system's reason.
    case localFileUnreadable(String, String)
    /// `nido act get-file` without `--force` onto a path that exists (a file, a link).
    case localFileExists(String)
    /// `nido image macos --output` or `--yes` without `--download` (the value is the option).
    case macImageOptionNeedsDownload(String)
    /// `create --account` on a Mac older than macOS 27.
    case accountNeedsHost27
    /// `create --account` with an empty or blank full name.
    case accountNameEmpty
    /// `create --account` with an image older than macOS 27.
    case accountNeedsImage27
    /// `--password-stdin` or `--choose-password` without `--account`.
    case passwordOptionNeedsAccount
    /// `--password-stdin` together with `--choose-password`.
    case passwordOptionsConflict
    /// `--account`, `--password-stdin`, `--choose-password` or `--agent` without `--ipsw`.
    case accountRequiresIPSW
    case passwordsDontMatch
    case passwordEmpty
    case noTerminalForPassword
    /// A password with a line break or longer than `GuestPassword.maxBytes`.
    case passwordUnusable
    /// `nido agent password` for a VM with no stored password.
    case noStoredPassword(String)
    /// `nido agent password` without the Mac owner's confirmation.
    case passwordAuthenticationFailed
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
        case .rollbackFailed(let checkpoint, let reason):
            L10n.string("couldn’t go back to checkpoint \(checkpoint): \(reason); the VM is stopped")
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
        case .agentAccessOff(let vm):
            L10n.string("Agent access is off for \(vm): turn it on with nido agent enable \(vm)")
        case .freshBaseSuspended(let vm):
            L10n.string("\(vm) is suspended: start it with nido start \(vm) and shut it down, then try again")
        case .freshBaseIsFresh(let vm):
            L10n.string("\(vm) is a fresh Mac of another session: use the VM it was copied from")
        case .agentPasswordNeeded(let vm):
            L10n.string("Nido’s key isn’t authorized in \(vm) yet: run `nido agent setup \(vm)` in a terminal to enter the password of its account once")
        case .agentAskpassMissing:
            L10n.string("This Nido can’t pass a password to ssh (the nido tool is missing from the app)")
        case .agentNotForLinux:
            L10n.string("Agent access is for macOS VMs.")
        case .guestLoginNeeded(let vm):
            L10n.string("Log in to \(vm) in its window.")
        case .agentLoginWindow(let vm):
            L10n.string("\(vm) may be waiting at its login window (FileVault): log in through its window, then run nido agent setup again.")
        case .agentNotServed(let message):
            message
        case .unknownAgentAction(let name):
            L10n.string("unknown action “\(ConsoleSanitizer.echoable(name))”: use status, screenshot, zoom, ui-tree, ocr, click, drag, scroll, type, key, wait, checkpoint, rollback, checkpoints, put-file, get-file, files, clipboard or clipboard-set")
        case .agentUsage(let syntax):
            L10n.string("usage: nido act <vm> \(syntax)")
        case .agentLogClearNeedsConfirmation:
            L10n.string("the log was not cleared: there is no terminal to ask, use --yes")
        case .agentLogLimitInvalid:
            L10n.string("--limit must be a whole number, at least 1")
        case .agentLogClearConflict:
            L10n.string("--clear can’t be combined with --limit or --json")
        case .agentLogYesWithoutClear:
            L10n.string("--yes only goes with --clear")
        case .agentNotANumber(let name):
            L10n.string("\(name) must be a number")
        case .agentOutOfRange(let name, let low, let high):
            L10n.string("\(name) must be a whole number from \(String(low)) to \(String(high))")
        case .outputExists(let path):
            L10n.string("\(ConsoleSanitizer.echoable(path)) already exists: nido doesn’t overwrite it")
        case .noScreenshotFile:
            L10n.string("the answer names no screenshot file to copy")
        case .agentFileTooLarge:
            L10n.string("the file is larger than 16 MiB")
        case .notARegularFile(let path):
            L10n.string("\(ConsoleSanitizer.echoable(path)) is not a regular file")
        case .localFileUnreadable(let path, let reason):
            L10n.string("can’t read \(ConsoleSanitizer.echoable(path)): \(reason)")
        case .localFileExists(let path):
            L10n.string("\(ConsoleSanitizer.echoable(path)) already exists: add --force to replace it")
        case .macImageOptionNeedsDownload(let option):
            L10n.string("\(option) works only with --download")
        case .accountNeedsHost27:
            L10n.string("guest provisioning needs macOS 27 on this Mac")
        case .accountNameEmpty:
            L10n.string("--account needs the full name of the account")
        case .accountNeedsImage27:
            L10n.string("guest provisioning needs a macOS 27 or later image")
        case .passwordOptionNeedsAccount:
            L10n.string("--password-stdin and --choose-password need --account")
        case .passwordOptionsConflict:
            L10n.string("--password-stdin can’t be combined with --choose-password")
        case .accountRequiresIPSW:
            L10n.string("--account, --password-stdin, --choose-password and --agent work only with --ipsw")
        case .passwordsDontMatch:
            L10n.string("the passwords don’t match")
        case .passwordEmpty:
            L10n.string("the password can’t be empty")
        case .noTerminalForPassword:
            L10n.string("no terminal to ask the password: use --password-stdin")
        case .passwordUnusable:
            L10n.string("That password can’t be used: it has a line break or is longer than 1023 bytes.")
        case .noStoredPassword(let vm):
            L10n.string("No password is stored for \(vm): the account was not created by Nido, or its password was entered elsewhere.")
        case .passwordAuthenticationFailed:
            L10n.string("authentication failed: the password was not shown")
        }
    }
}
