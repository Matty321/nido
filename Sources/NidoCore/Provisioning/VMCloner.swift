// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import Virtualization

/// Points of `VMCloner.clone` where the tests inject a failure.
public enum CloneStep: Sendable, Equatable {
    /// The source lock is held and its leftovers checked; nothing is created yet.
    case locked
    /// `disk.img` is cloned into the temporary directory.
    case diskCloned
    /// `nvram.efi` is cloned (Linux).
    case nvramCloned
    /// `auxiliary-storage.img` and `hardware-model.bin` are cloned (macOS).
    case auxiliaryStorageCloned
    /// `config.json` and `machine-id.bin` of the clone are written.
    case identityWritten
    /// `seed.iso` of the clone is built (Linux).
    case seedBuilt
    /// Everything is in the temporary directory, about to be renamed into place.
    case readyToRename
}

/// Copies a stopped VM into a new VM with its own identity (see `docs/BUNDLE-FORMAT.md`,
/// "Clonazione").
///
/// - The source must be stopped: its bundle lock is held (with the caller's `owner`) for the whole
///   copy; an interrupted snapshot restore is recovered first, and leftovers refuse the clone.
/// - The clone is built in `<root>/.<target>.cloning-<uuid>/` (0700, invisible to the library)
///   and renamed to `<target>.nidovm` only when complete; on any failure it is removed. A
///   directory left by a crash is swept like a delete tombstone (`VMBundle.sweepOrphanTombstones`).
/// - `disk.img` and `nvram.efi` are flushed and cloned (`MachineFileCopy`); the clone gets a new
///   id, MAC address and machine identifier, and a new cloud-init seed: the source's `user-data`
///   (same key, same guest units) plus a once-per-instance new `/etc/machine-id`
///   (`CloudInitSeed.userDataForClone`), a new `instance-id` and the new name as hostname (cloud-init
///   then runs its per-instance modules again, e.g. new SSH host keys), DHCP on the new MAC.
/// - Copied as they are: CPU, memory, disk size, Rosetta and the guest flags. Shared folders are
///   NOT inherited (the clone, a template's too, starts with none: access is explicit, per VM).
///   The AI bridge policy is not inherited either (the clone starts with the bridge off).
///   Not copied: snapshots, the suspended state (the clone boots cold), `known_hosts`, `console.log`.
/// - The controlled network follows the clone: `controlledNetwork` as in the source and its
///   `egress.json` as the source's policy reads now (`copyEgressPolicy`). The egress logs stay
///   behind (the clone starts with a clean log), and so do `.egress.lock` and any
///   `.egress.json.*.tmp`: only the parsed policy is written, never a file copied by name.
/// - macOS (M3b): no seed (nothing in the guest runs on first boot). `disk.img`,
///   `auxiliary-storage.img` and `hardware-model.bin` are cloned, `authorized_key.pub` copied when
///   present; the clone gets a new `VZMacMachineIdentifier` and MAC. `sshUser` and `osVersion` are
///   kept. What the guest itself must change (SSH host keys, computer and host names) is listed in
///   `cloneNotes(guest:name:)`, for the user to run once in the clone.
public struct VMCloner: Sendable {
    private let paths: NidoPaths
    private let runner: ProcessRunner
    private let environment: Environment

    /// What the cloner asks the system, replaceable in the tests.
    struct Environment: Sendable {
        var availableCapacity: @Sendable (URL) throws -> UInt64 = SnapshotStore.volumeAvailableCapacity
        var supportsCloning: @Sendable (URL) -> Bool = SnapshotStore.volumeSupportsCloning
        /// Skip `clonefile` and use the copy fallback (tests of the fallback).
        var forceCopy = false
        var faultInjection: (@Sendable (CloneStep) throws -> Void)?
    }

    public init(paths: NidoPaths, runner: ProcessRunner) {
        self.init(paths: paths, runner: runner, environment: Environment())
    }

    init(paths: NidoPaths, runner: ProcessRunner, environment: Environment) {
        self.paths = paths
        self.runner = runner
        self.environment = environment
    }

    /// Prefix and infix of the temporary directory of a clone: `.<target>.cloning-<uuid>`.
    static let cloningInfix = ".cloning-"

    /// A finished clone: the new bundle and the steps to run in its guest (`cloneNotes`).
    public struct CloneResult: Sendable {
        public let bundle: VMBundle
        /// The guest of the clone (the source's).
        public let guest: GuestOS
        /// What the user still has to do inside the clone (localized; empty for Linux, where
        /// cloud-init does it all).
        public let cloneNotes: [String]
    }

    /// `cloneReportingNotes`, returning only the new bundle (the notes are `cloneNotes(guest:name:)`).
    @concurrent
    public func clone(_ source: VMName, as target: VMName, owner: LockOwner) async throws -> VMBundle {
        try await cloneReportingNotes(source, as: target, owner: owner).bundle
    }

    /// Clones the stopped VM `source` as the new VM `target`; returns the new bundle and the steps
    /// to run in its guest.
    ///
    /// Refused before any work: `target` already taken (ignoring case, the source's own name too:
    /// `.alreadyExists`), `source` running here or in another process (`.cloneNeedsStoppedVM`),
    /// leftovers of an interrupted restore (`.restoreLeftovers`), not enough free space
    /// (`.insufficientSpace`: the margin, plus the allocated size of disk and NVRAM on a volume
    /// that cannot clone). Runs off the caller's actor; the lock is taken without blocking a
    /// thread (`BundleLock.acquireAsync`).
    @concurrent
    public func cloneReportingNotes(_ source: VMName, as target: VMName, owner: LockOwner) async throws
        -> CloneResult
    {
        let (bundle, guest) = try await perform(source, as: target, owner: owner, mode: .plainClone)
        return CloneResult(bundle: bundle, guest: guest, cloneNotes: Self.cloneNotes(guest: guest, name: target))
    }

    /// What the user runs once in a fresh clone of a `guest` VM named `name` (localized). Linux:
    /// nothing (cloud-init renames the host and regenerates its SSH keys). macOS: new SSH host keys
    /// (the clone has the source's, which `nido ssh` would otherwise see under two names) and the
    /// computer, local host and host names (`scutil`; the last two accept only letters, digits and
    /// hyphens, so `.` and `_` become `-`).
    public static func cloneNotes(guest: GuestOS, name: VMName) -> [String] {
        guard guest == .macos else { return [] }
        var label = String(name.rawValue.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
        while label.hasSuffix("-") { label.removeLast() }
        let hostKeys = "sudo rm /etc/ssh/ssh_host_* && sudo ssh-keygen -A"
        let computerName = "sudo scutil --set ComputerName \(name.rawValue)"
        let localHostName = "sudo scutil --set LocalHostName \(label)"
        let hostName = "sudo scutil --set HostName \(label)"
        return [
            L10n.string("new SSH host keys (the copy has the original’s): \(hostKeys)"),
            L10n.string("computer name: \(computerName)"),
            L10n.string("local network name: \(localHostName)"),
            L10n.string("host name: \(hostName)"),
        ]
    }

    /// Creates the new VM `target` from the template `template`: the clone of the template's disk
    /// with a new identity and an identity-only cloud-init seed (`userDataForTemplateClone`: the
    /// user, the key, new SSH host keys and `/etc/machine-id`; nothing is installed again).
    /// `sshKeyPath` nil uses the template's own key; if that file is gone, `.templateKeyMissing`.
    /// The new VM is not a template, has no shared folders and no AI bridge, and keeps the
    /// template's CPU, memory, disk, `provisioning` and `guestToolsVersion`. A source that is not a
    /// template is refused with `.notATemplate`.
    @concurrent
    public func createFromTemplate(
        _ template: VMName, as target: VMName, sshKeyPath: URL?, owner: LockOwner
    ) async throws -> VMBundle {
        try await perform(template, as: target, owner: owner, mode: .fromTemplate(sshKeyPath: sshKeyPath)).bundle
    }

    private enum Mode: Sendable {
        case plainClone
        case fromTemplate(sshKeyPath: URL?)
    }

    /// Guest user of the VMs Nido creates (`VMFactory`).
    static let guestUsername = "nido"

    /// The new bundle and its guest (the source's, read under the lock).
    private func perform(_ source: VMName, as target: VMName, owner: LockOwner, mode: Mode) async throws
        -> (bundle: VMBundle, guest: GuestOS)
    {
        try paths.ensureRoot()
        try checkNameIsFree(target)
        let bundle = try VMBundle.open(source, paths: paths)
        let lock: BundleLock
        do {
            lock = try await BundleLock.acquireAsync(bundle, owner: owner)
        } catch NidoError.alreadyRunning {
            throw NidoError.cloneNeedsStoppedVM(bundle.displayName)
        }
        defer { lock.release() }

        try SnapshotStore(bundle: bundle).recoverBeforeUse()
        let sourceConfig = try bundle.readConfig()
        let guest = sourceConfig.guest
        try bundle.verifyInnerFiles(for: guest)
        // Linux: the clone's cloud-init user-data; nil for macOS (no seed).
        let userData: String?
        var keyPath = sourceConfig.sshPublicKeyPath
        switch mode {
        case .plainClone:
            // A template is only used through `createFromTemplate` (or made startable again).
            guard !sourceConfig.isTemplate else { throw NidoError.isTemplate(bundle.displayName) }
            userData = guest == .linux
                ? CloudInitSeed.userDataForClone(try CloudInitSeed.readFile("user-data", fromISO: bundle.seedURL))
                : nil
        case .fromTemplate(let explicit):
            // Ruling R4: templates are Linux-only; a macOS bundle marked by hand is never used.
            guard sourceConfig.guest == .linux else { throw NidoError.macTemplatesUnavailable }
            guard sourceConfig.isTemplate else { throw NidoError.notATemplate(bundle.displayName) }
            let key: URL
            if let explicit {
                key = explicit
            } else if let saved = sourceConfig.sshPublicKeyPath,
                FileManager.default.fileExists(atPath: saved) {
                key = URL(fileURLWithPath: saved)
            } else {
                throw NidoError.templateKeyMissing(sourceConfig.sshPublicKeyPath ?? "")
            }
            keyPath = key.path
            userData = CloudInitSeed.userDataForTemplateClone(
                username: Self.guestUsername, publicKey: try VMControl.readPublicKey(at: key))
        }
        try checkSpace(for: bundle, guest: guest)
        try fault(.locked)

        let temporary = paths.root.appendingPathComponent(
            ".\(target.rawValue)\(Self.cloningInfix)\(UUID().uuidString)", isDirectory: true)
        guard mkdir(temporary.path, 0o700) == 0 else { throw posixError() }
        do {
            let clone = VMBundle(url: temporary)
            try MachineFileCopy.flushAndClone(bundle.diskURL, to: clone.diskURL, forceCopy: environment.forceCopy)
            try fault(.diskCloned)
            switch guest {
            case .linux:
                try MachineFileCopy.flushAndClone(bundle.nvramURL, to: clone.nvramURL, forceCopy: environment.forceCopy)
                try fault(.nvramCloned)
            case .macos:
                try MachineFileCopy.flushAndClone(
                    bundle.auxiliaryStorageURL, to: clone.auxiliaryStorageURL, forceCopy: environment.forceCopy)
                try MachineFileCopy.flushAndClone(
                    bundle.hardwareModelURL, to: clone.hardwareModelURL, forceCopy: environment.forceCopy)
                // The key to authorize in the guest (shown by the app); the guest already has it
                // if the source's user authorized it. Missing in the source: nothing to copy.
                // `flushAndClone` refuses a symlink, a hard link or a file of someone else.
                if Self.entryExists(bundle.authorizedKeyURL) {
                    try MachineFileCopy.flushAndClone(
                        bundle.authorizedKeyURL, to: clone.authorizedKeyURL, forceCopy: environment.forceCopy)
                }
                try fault(.auxiliaryStorageCloned)
            }

            var config = sourceConfig
            config.schemaVersion = VMConfig.currentSchemaVersion
            config.id = UUID()
            config.name = target
            config.macAddress = VZMACAddress.randomLocallyAdministered().string
            config.suspendedConfigHash = nil
            config.sharedFolders = []
            config.aiBridge = nil
            config.pendingProvisioning = nil
            config.isTemplate = false
            config.sshPublicKeyPath = keyPath
            // A macOS clone still needs its own SSH host keys (clone notes): its "Accesso da
            // terminale" panel opens again until `nido ssh` reaches it.
            config.sshSucceeded = nil
            try clone.writeConfig(config)
            try Self.copyEgressPolicy(from: bundle, to: clone)
            let identifier = switch guest {
            case .linux: VZGenericMachineIdentifier().dataRepresentation
            case .macos: VZMacMachineIdentifier().dataRepresentation
            }
            try MachineFileCopy.writeNewFile(clone.machineIdentifierURL, data: identifier)
            try fault(.identityWritten)

            if let userData {
                try CloudInitSeed.buildISO(
                    at: clone.seedURL, userData: userData,
                    metaData: CloudInitSeed.metaData(instanceID: config.id, hostname: target),
                    networkConfig: CloudInitSeed.networkConfig(macAddress: config.macAddress),
                    runner: runner)
                try MachineFileCopy.protect(clone.seedURL)
                try fault(.seedBuilt)
            }

            try SnapshotStore.syncDirectoryNow(temporary)
            try fault(.readyToRename)
            try checkNameIsFree(target)
            let destination = paths.bundleURL(for: target)
            guard renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST { throw NidoError.alreadyExists(target.rawValue) }
                throw posixError()
            }
            // The clone exists from here on: a failed sync of the root is not a failed clone.
            try? SnapshotStore.syncDirectoryNow(paths.root)
            return (VMBundle(url: destination), guest)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// Writes the egress policy of `source` into `clone` (a bundle nobody else sees yet). No
    /// `egress.json` in the source: none in the clone either (both read as the empty list). A
    /// file that does not load (`EgressPolicyStore.load` nil: damaged, a link, too big) gives the
    /// clone the empty list, never something wider than what the source's relay could apply.
    static func copyEgressPolicy(from source: VMBundle, to clone: VMBundle) throws {
        guard entryExists(source.egressPolicyURL) else { return }
        let policy = EgressPolicyStore.load(bundle: source) ?? .empty
        try EgressPolicyStore.save(policy, bundle: clone)
    }

    /// `.alreadyExists(target)` when a VM of that name exists, ignoring case.
    private func checkNameIsFree(_ target: VMName) throws {
        let wanted = (target.rawValue + ".nidovm").lowercased()
        let entries = try FileManager.default.contentsOfDirectory(atPath: paths.root.path)
        if entries.contains(where: { $0.lowercased() == wanted }) {
            throw NidoError.alreadyExists(target.rawValue)
        }
    }

    /// Ruling R-M3A-13: a clone takes no space up front, so on a volume that clones only the margin
    /// counts; otherwise the allocated size of the machine files (the copy is sparse) as well.
    private func checkSpace(for bundle: VMBundle, guest: GuestOS) throws {
        var needed = SnapshotStore.spaceMargin
        if environment.forceCopy || !environment.supportsCloning(paths.root) {
            for name in SnapshotStore.machineFileNames(for: guest) {
                needed += try MachineFileCopy.allocatedSize(bundle.url.appendingPathComponent(name))
            }
        }
        let available = try environment.availableCapacity(paths.root)
        guard available >= needed else { throw NidoError.insufficientSpace(needed: needed, available: available) }
    }

    private static func entryExists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// A step is done: a cancelled task (the app quitting with "Annulla ed esci") stops here with
    /// `CancellationError`, which removes the `.cloning-*` folder like any failure. Past the
    /// rename nothing is checked: a finished clone is a whole VM and stays.
    private func fault(_ step: CloneStep) throws {
        try Task.checkCancellation()
        try environment.faultInjection?(step)
    }

    private func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
