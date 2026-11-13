// SPDX-License-Identifier: Apache-2.0
import Foundation

extension NidoError: LocalizedError {
    /// The description in the resolved UI language (`L10n.language`). Reasons carried by a case
    /// were localized where the error was thrown.
    public var errorDescription: String? {
        localizedDescription(language: L10n.language)
    }

    /// The description in `language` (one of `en it de es fr`; anything else is English), without
    /// touching the process-wide language: what tests use for languages other than the pinned one.
    func localizedDescription(language: String) -> String {
        switch self {
        case .invalidName(let name):
            L10n.string("invalid VM name: “\(name)” (letters, digits, '.', '_', '-'; up to 63 characters)", language: language)
        case .invalidResources(let reason):
            L10n.string("invalid resources: \(reason)", language: language)
        case .unsupportedSchema(let version):
            L10n.string("unsupported configuration version: \(String(version))", language: language)
        case .alreadyExists(let name):
            L10n.string("a VM named \(name) already exists", language: language)
        case .notFound(let what):
            L10n.string("not found: \(what)", language: language)
        case .unsafePath(let what):
            L10n.string("unsafe path: \(what)", language: language)
        case .alreadyRunning(let pid):
            pid > 0
                ? L10n.string("VM already running (pid \(String(pid)))", language: language)
                : L10n.string("VM already running (unknown pid)", language: language)
        case .notRunning(let name):
            L10n.string("the VM \(name) isn’t running", language: language)
        case .downloadDeclined:
            L10n.string("download canceled", language: language)
        case .hostNotAllowed(let host):
            L10n.string("host not allowed: \(host)", language: language)
        case .checksumMismatch:
            L10n.string("SHA-512 check failed: the downloaded file doesn’t match the published checksum", language: language)
        case .invalidPublicKey:
            L10n.string("invalid SSH public key", language: language)
        case .processFailed(let executable, let status):
            L10n.string("\(executable) exited with status \(String(status))", language: language)
        case .invalidSize(let value):
            L10n.string("invalid size: “\(value)” (for example 4G, 512M)", language: language)
        case .downloadFailed(let reason):
            L10n.string("download failed: \(reason)", language: language)
        case .keyFileTooLarge:
            L10n.string("the SSH key file is larger than 16 KiB", language: language)
        case .privateKeyRejected:
            L10n.string("this file looks like a private key: choose the .pub file", language: language)
        case .keyFileUnreadable(let path):
            L10n.string("can’t read the SSH public key: \(path)", language: language)
        case .keyPathNotPub(let path):
            L10n.string("the SSH key must be a .pub file: \(path)", language: language)
        case .leasesUnreadable(let path):
            L10n.string("can’t read the DHCP database (\(path))", language: language)
        case .notOnNetwork:
            L10n.string("VM not on the network yet", language: language)
        case .pidUnknown:
            L10n.string("VM running, but its PID is unknown", language: language)
        case .ownedByApp(let name):
            L10n.string("the VM \(name) is open in the Nido app: stop it from the app", language: language)
        case .vmRunningInApp:
            L10n.string("the VM is running in Nido: change its folders in the app, or stop it first", language: language)
        case .operationInProgress(let name, let pid):
            L10n.string("an operation on \(name) is in progress (pid \(String(pid))): try again when it’s done", language: language)
        case .failedAndNotResumed(let reason, let resumeError):
            L10n.string("\(reason); also, the VM didn’t resume (\(resumeError)): it’s paused", language: language)
        case .invalidShareName(let name):
            L10n.string("invalid shared folder name: “\(name)” (letters, digits, '.', '_', '-'; starts with a letter or digit; up to 63 characters)", language: language)
        case .shareNameTaken(let name):
            L10n.string("a shared folder named \(name) already exists", language: language)
        case .shareNotFound(let name):
            L10n.string("no shared folder named \(name)", language: language)
        case .sharedFolderRefused(let reason):
            L10n.string("this folder can’t be shared: \(reason)", language: language)
        case .sharedFolderMissing(let path):
            L10n.string("folder not found on the Mac: \(path)", language: language)
        case .vmMustBeStopped(let name):
            L10n.string("the VM \(name) is running: stop it before changing it", language: language)
        case .rosettaUnavailable:
            L10n.string("Rosetta isn’t available on this Mac", language: language)
        case .rosettaNotInstalled:
            L10n.string("Rosetta isn’t installed on this Mac", language: language)
        case .snapshotUnsupported(let reason):
            L10n.string("can’t take a snapshot while the VM is running: \(reason); stop the VM and try again", language: language)
        case .insufficientSpace(let needed, let available):
            insufficientSpace(needed: needed, available: available, language: language)
        case .runningInAnotherProcess:
            L10n.string("the VM is running in another process: use the app, or stop it", language: language)
        case .invalidSnapshotName(let name):
            L10n.string("invalid snapshot name: “\(name)” (letters, digits, '.', '_', '-'; starts with a letter or digit; up to 63 characters)", language: language)
        case .snapshotNameTaken(let name):
            L10n.string("a snapshot named \(name) already exists", language: language)
        case .snapshotNotFound(let what):
            L10n.string("snapshot not found: \(what)", language: language)
        case .restoreFailed(let reason):
            L10n.string("can’t restore the saved state: \(reason)", language: language)
        case .restoreIncomplete(let path):
            L10n.string("the restore failed and was only partly undone: the original file is kept in \(path); try the operation again", language: language)
        case .snapshotResumeFailed(let name, let reason):
            L10n.string("snapshot \(name) created, but the VM didn’t resume: \(reason)", language: language)
        case .restoreMarkerKept(let path):
            L10n.string("the snapshot restore stopped after it was confirmed: can’t remove \(path); the VM stays at the snapshot and does a cold boot the next time it starts", language: language)
        case .restoreLeftovers(let paths):
            restoreLeftovers(paths.joined(separator: ", "), language: language)
        case .suspendFailed(let reason):
            L10n.string("suspend failed: \(reason)", language: language)
        case .cloneNeedsStoppedVM(let name):
            L10n.string("the VM \(name) is running: stop it before cloning it", language: language)
        case .seedUnreadable(let path):
            L10n.string("can’t read the VM’s cloud-init configuration (\(path))", language: language)
        case .isTemplate(let name):
            L10n.string("\(name) is a template: use nido create --from-template or nido template edit", language: language)
        case .notATemplate(let name):
            L10n.string("\(name) isn’t a template: save it first with nido template save", language: language)
        case .templateHasSuspendedState(let name):
            L10n.string("the VM \(name) has a suspended state: resume it with nido start and stop it, then save it as a template", language: language)
        case .templateKeyMissing(let path):
            path.isEmpty
                ? L10n.string("the template’s SSH key no longer exists: choose a key with --ssh-key", language: language)
                : L10n.string("the template’s SSH key no longer exists (\(path)): choose a key with --ssh-key", language: language)
        case .invalidSSHUser(let user):
            L10n.string("invalid user name: “\(user)” (lowercase letters, digits, '_' and '-'; starts with a lowercase letter or '_'; up to 32 characters)", language: language)
        case .notARestoreImage(let path):
            L10n.string("\(path) isn’t a valid macOS restore image (IPSW)", language: language)
        case .restoreImageUnsupported(let version, let requiredHostMajor?):
            L10n.string("macOS \(version) can’t be installed in a VM on this Mac: it needs a Mac with macOS \(String(requiredHostMajor)) or later", language: language)
        case .restoreImageUnsupported(let version, nil):
            L10n.string("macOS \(version) isn’t supported by Virtualization on this Mac", language: language)
        case .serialConsoleRequired:
            L10n.string("the Linux VM has no serial console", language: language)
        case .macTemplatesUnavailable:
            L10n.string("macOS VM templates aren’t available yet", language: language)
        case .invalidDomain(let text):
            L10n.string("invalid domain: “\(text)” (a name like deb.debian.org, or *.debian.org for the domain and its subdomains; no IP addresses)", language: language)
        case .invalidEgressPolicy(let reason):
            L10n.string("invalid domain list: \(reason)", language: language)
        case .controlledNetworkUnavailable(let reason):
            L10n.string("controlled network unavailable: \(reason)", language: language)
        case .controlledNetworkInterrupted:
            L10n.string("controlled network interrupted: restart the VM", language: language)
        case .unsupportedDiskImage(let reason):
            L10n.string("unsupported disk image: \(reason)", language: language)
        case .commandTargetUnusable:
            L10n.string("Move Nido to Applications before installing the nido command.", language: language)
        case .commandLinkForeign(let path):
            L10n.string("\(path) is a link to another program: Nido leaves it alone.", language: language)
        case .commandLinkIsFile(let path):
            L10n.string("\(path) is a regular file, not a Nido link.", language: language)
        case .commandLinkNotAFile(let path):
            L10n.string("\(path) is a folder or a special item: Nido leaves it alone.", language: language)
        case .commandLinkFailed(let reason):
            L10n.string("nido command: \(reason)", language: language)
        }
    }

    private func insufficientSpace(needed: UInt64, available: UInt64, language: String) -> String {
        let locale = L10n.locale(for: language)
        let needed = ByteSize.format(needed, locale: locale)
        let available = ByteSize.format(available, locale: locale)
        return L10n.string("not enough space: \(needed) needed, \(available) available", language: language)
    }

    private func restoreLeftovers(_ paths: String, language: String) -> String {
        L10n.string("an interrupted snapshot restore left files Nido couldn’t sort out: \(paths). Check them (they may be the VM’s original disk), put them back or delete them, then try again", language: language)
    }
}
