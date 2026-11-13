// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Virtualization

/// Parameters for creating a Linux VM from a base disk image.
public struct LinuxVMRequest: Sendable {
    public var name: VMName
    public var baseImage: URL
    public var cpuCount: Int
    public var memoryBytes: UInt64
    public var diskBytes: UInt64
    public var publicKey: String
    /// What cloud-init sets up on the first boot; `.empty` keeps the user-data of Nido before M3c.
    public var profile: ProvisioningProfile
    /// Path of the `.pub` file `publicKey` was read from, recorded in the config for later SSH use.
    public var sshPublicKeyPath: String?
    /// Phase 2 chosen in the app's wizard, recorded in the config (never in the seed).
    public var pendingProvisioning: PendingProvisioning?
    /// The catalog distribution `baseImage` is (a file of the user's own: Debian 13, as before
    /// Ubuntu). Chooses the time client of the seed and the base list of the controlled network.
    public var distribution: LinuxDistribution

    public init(
        name: VMName, baseImage: URL, cpuCount: Int, memoryBytes: UInt64, diskBytes: UInt64,
        publicKey: String, profile: ProvisioningProfile = .empty, sshPublicKeyPath: String? = nil,
        pendingProvisioning: PendingProvisioning? = nil, distribution: LinuxDistribution = .debian13
    ) {
        self.name = name
        self.baseImage = baseImage
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes
        self.publicKey = publicKey
        self.profile = profile
        self.sshPublicKeyPath = sshPublicKeyPath
        self.pendingProvisioning = pendingProvisioning
        self.distribution = distribution
    }
}

/// Creates complete Linux VM bundles; on any failure the partial bundle is removed. A new VM is
/// on the controlled network (`VMConfig.controlledNetwork`) with its distribution's base list
/// (`EgressPolicy.base(for:)`) as its `egress.json`. The base image is a raw disk (cloned) or a qcow2
/// (Ubuntu's cloud images: converted with `Qcow2Image`, sparse); either way the VM's disk is
/// then grown to `diskBytes`.
public struct VMFactory: Sendable {
    private let paths: NidoPaths
    private let runner: ProcessRunner

    public init(paths: NidoPaths, runner: ProcessRunner) {
        self.paths = paths
        self.runner = runner
    }

    /// `isCancelled` stops the qcow2 conversion (the longest part); the bundle is then removed.
    public func createLinux(
        _ r: LinuxVMRequest, isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> VMBundle {
        try ResourceLimits.validate(cpuCount: r.cpuCount, memoryBytes: r.memoryBytes)
        let key = try CloudInitSeed.validatePublicKey(r.publicKey)

        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: r.baseImage.path),  // lstat
            (attrs[.type] as? FileAttributeType) == .typeRegular,
            let fileSize = (attrs[.size] as? NSNumber)?.uint64Value
        else { throw NidoError.notFound(r.baseImage.path) }
        let isQcow2 = Qcow2Image.isQcow2(r.baseImage)
        let imageSize = isQcow2 ? try Qcow2Image.virtualSize(of: r.baseImage) : fileSize
        try ResourceLimits.validateDisk(diskBytes: r.diskBytes, imageBytes: imageSize)

        let config = VMConfig(
            id: UUID(), name: r.name, guest: .linux, cpuCount: r.cpuCount,
            memoryBytes: r.memoryBytes, diskBytes: r.diskBytes,
            macAddress: VZMACAddress.randomLocallyAdministered().string, clipboardSharing: false,
            guestMountsSharedFolders: true, guestRegistersRosetta: true,
            provisioning: r.profile == .empty ? nil : r.profile,
            guestToolsVersion: r.profile.guestTools ? GuestToolsPayload.version : nil,
            sshPublicKeyPath: r.sshPublicKeyPath, pendingProvisioning: r.pendingProvisioning,
            controlledNetwork: true, distribution: r.distribution,
            // The seed below turns them off (`aptQuiet`, `quietUbuntu`).
            backgroundRequestsOff: true)
        let bundle = try VMBundle.create(config: config, paths: paths)
        do {
            // Before the first boot: cloud-init's packages come through the relay.
            try EgressPolicyStore.save(EgressPolicy.base(for: r.distribution), bundle: bundle)
            if isQcow2 {
                try Qcow2Image.convert(r.baseImage, toRaw: bundle.diskURL, isCancelled: isCancelled)
                try growDisk(bundle.diskURL, to: r.diskBytes)
            } else {
                try cloneDisk(from: r.baseImage, to: bundle.diskURL, size: r.diskBytes)
            }

            _ = try VZEFIVariableStore(creatingVariableStoreAt: bundle.nvramURL)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bundle.nvramURL.path)

            try VZGenericMachineIdentifier().dataRepresentation.write(
                to: bundle.machineIdentifierURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bundle.machineIdentifierURL.path)

            try CloudInitSeed.buildISO(
                at: bundle.seedURL,
                userData: CloudInitSeed.userData(
                    username: "nido", publicKey: key, profile: r.profile, pinnedTimeServer: true,
                    timeClient: r.distribution.timeClient, quietUbuntu: r.distribution.isUbuntu,
                    aptQuiet: true),
                metaData: CloudInitSeed.metaData(instanceID: config.id, hostname: r.name),
                networkConfig: CloudInitSeed.networkConfig(macAddress: config.macAddress),
                runner: runner)
        } catch {
            try? bundle.remove()
            throw error
        }
        return bundle
    }

    /// Same as `createLinux`, run off the caller's actor (cloning and the ISO build can take a while).
    @concurrent
    /// Cancelling the calling task stops a qcow2 conversion between batches of clusters.
    public func createLinuxAsync(_ r: LinuxVMRequest) async throws -> VMBundle {
        let cancelled = CancelFlag()
        return try await withTaskCancellationHandler {
            try createLinux(r, isCancelled: { cancelled.isSet })
        } onCancel: {
            cancelled.set()
        }
    }

    private func cloneDisk(from source: URL, to dest: URL, size: UInt64) throws {
        let fm = FileManager.default
        if clonefile(source.path, dest.path, 0) != 0 {
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: source, to: dest)
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
        try growDisk(dest, to: size)
    }

    private func growDisk(_ disk: URL, to size: UInt64) throws {
        let handle = try FileHandle(forWritingTo: disk)
        defer { try? handle.close() }
        try handle.truncate(atOffset: size)
    }
}

/// Set once from a task's cancellation handler, read from the conversion's worker threads.
private final class CancelFlag: Sendable {
    private let value = Mutex(false)
    var isSet: Bool { value.withLock { $0 } }
    func set() { value.withLock { $0 = true } }
}
