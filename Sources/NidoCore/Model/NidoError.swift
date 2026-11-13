// SPDX-License-Identifier: Apache-2.0

/// Errors raised by NidoCore.
public enum NidoError: Error, Equatable, Sendable {
    case invalidName(String)
    case invalidResources(String)
    case unsupportedSchema(Int)
    case alreadyExists(String)
    case notFound(String)
    case unsafePath(String)
    case alreadyRunning(pid: Int32)
    case notRunning(String)
    case downloadDeclined
    case hostNotAllowed(String)
    case checksumMismatch(expected: String, actual: String)
    case invalidPublicKey
    case processFailed(executable: String, status: Int32)
    case invalidSize(String)
    case downloadFailed(String)
    case privateKeyRejected
    case keyFileTooLarge
    case keyFileUnreadable(String)
    case keyPathNotPub(String)
    case leasesUnreadable(String)
    case notOnNetwork(String)
    case pidUnknown
    case ownedByApp(String)
    /// `nido share add|remove` on a VM that runs in the app: only the app can change its folders live.
    case vmRunningInApp(String)
    /// `nido stop` on a VM whose lock a maintenance command holds (snapshot, clone, share,
    /// rosetta, delete): it is not signalled (ruling R-M3A-24).
    case operationInProgress(String, pid: Int32)
    /// An operation that paused the VM failed (the first reason), and so did the resume after
    /// it (the second): the VM is left paused.
    case failedAndNotResumed(String, resumeError: String)
    case invalidShareName(String)
    case shareNameTaken(String)
    case shareNotFound(String)
    case sharedFolderRefused(String)
    case sharedFolderMissing(String)
    case vmMustBeStopped(String)
    /// Rosetta for Linux cannot run on this Mac (`RosettaState.unsupported`).
    case rosettaUnavailable
    /// Rosetta for Linux is supported but not installed (`RosettaState.notInstalled`).
    case rosettaNotInstalled
    /// A snapshot of a running VM is not possible (`validateSaveRestoreSupport` or the save failed).
    case snapshotUnsupported(String)
    /// The volume of the bundle has less free space than the operation needs (bytes).
    case insufficientSpace(needed: UInt64, available: UInt64)
    /// The VM runs in another process (another `nido`, or the app): only that process can act on it.
    case runningInAnotherProcess
    case invalidSnapshotName(String)
    case snapshotNameTaken(String)
    case snapshotNotFound(String)
    /// Virtualization.framework refused a saved state (`VMSession.restoreMachineState`): the
    /// caller discards it and starts the VM from cold.
    case restoreFailed(String)
    /// A snapshot restore failed and one of the VM's original files could not be put back: it is
    /// kept at this path (the next operation under the lock retries).
    case restoreIncomplete(String)
    /// The snapshot was created but the VM, paused for it, could not be resumed.
    case snapshotResumeFailed(snapshot: String, reason: String)
    /// A restore failed after its commit marker was written, and the marker could not be removed:
    /// the VM keeps the snapshot's files without a saved state to resume (the next start is cold).
    case restoreMarkerKept(String)
    /// An interrupted snapshot restore left files Nido could not put back or remove (paths): the
    /// VM is not started, nor snapshotted or restored, until someone looks at them.
    case restoreLeftovers([String])
    /// The VM could not be suspended (the reason); its state is not kept.
    case suspendFailed(String)
    /// The app runs from a disk image or a translocated path: a link to it would soon dangle.
    case commandTargetUnusable
    /// The `nido` command path is a link to another program (the path): never touched.
    case commandLinkForeign(String)
    /// The `nido` command path is a regular file and the user did not agree to replace it.
    case commandLinkIsFile(String)
    /// The `nido` command path is a directory or another special item (the path): never touched.
    case commandLinkNotAFile(String)
    /// Creating or removing the `nido` command link failed (the reason).
    case commandLinkFailed(String)
    /// The VM to clone is running (here or in another process): only a stopped VM is cloned.
    case cloneNeedsStoppedVM(String)
    /// The cloud-init seed (`seed.iso`, path) is not an ISO Nido can read, or lacks a file.
    case seedUnreadable(String)
    /// The VM is a template (name): it is not started nor cloned, only used by `create --from-template`.
    case isTemplate(String)
    /// The VM (name) is not a template.
    case notATemplate(String)
    /// The VM (name) has a suspended state: it cannot become a template until it is resumed and stopped.
    case templateHasSuspendedState(String)
    /// The key of the template (path, possibly empty) no longer exists and none was given.
    case templateKeyMissing(String)
    /// The guest account name for `nido ssh` does not match `^[a-z_][a-z0-9_-]{0,31}$`.
    case invalidSSHUser(String)
    /// The file (path) is not a macOS restore image Virtualization.framework can load.
    case notARestoreImage(String)
    /// Virtualization.framework cannot install this macOS version (e.g. "27.0") on this Mac.
    /// `requiredHostMajor` is set when the image's major version is newer than the host's: the
    /// user needs a Mac running at least that major version.
    case restoreImageUnsupported(version: String, requiredHostMajor: Int? = nil)
    /// A Linux session was asked without the serial console it needs (a programming error).
    case serialConsoleRequired
    /// `nido template save` (or the app) on a macOS VM: templates are Linux-only in M3b.
    case macTemplatesUnavailable
    /// The text is not a domain the controlled network can allow: an exact name or `*.suffix`,
    /// at least two labels, no IP literal (see `DomainPattern`).
    case invalidDomain(String)
    /// An `egress.json` that cannot be written as is (the reason, localized).
    case invalidEgressPolicy(String)
    /// gvproxy did not start (or is not the expected binary) for a controlled VM (the reason,
    /// localized): the VM has no network.
    case controlledNetworkUnavailable(String)
    /// SSH to a controlled-network VM whose `gvproxy` is gone (`ssh-forward.json` names a PID that
    /// is dead or not a `gvproxy`): the VM has no network until it is restarted.
    case controlledNetworkInterrupted
    /// A base disk image Nido cannot turn into a raw disk (the reason, localized): a qcow2 with a
    /// backing file, encryption, an unsupported feature, or a damaged table.
    case unsupportedDiskImage(String)
}
