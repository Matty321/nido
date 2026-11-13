// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import Virtualization

/// Parameters for installing a macOS VM from an IPSW the user provides.
public struct MacVMRequest: Sendable {
    public var name: VMName
    /// The restore image: only read, never modified, moved or copied.
    public var ipsw: URL
    public var cpuCount: Int
    public var memoryBytes: UInt64
    public var diskBytes: UInt64
    /// The account the user will create in Setup Assistant (`VMConfig.validateSSHUser`).
    public var sshUser: String
    /// The SSH public key the user will authorize in the guest (saved in `authorized_key.pub`).
    public var publicKey: String
    /// Path of the `.pub` file `publicKey` was read from, recorded in the config for `nido ssh`.
    public var sshPublicKeyPath: String?

    public init(
        name: VMName, ipsw: URL, cpuCount: Int, memoryBytes: UInt64, diskBytes: UInt64,
        sshUser: String, publicKey: String, sshPublicKeyPath: String? = nil
    ) {
        self.name = name
        self.ipsw = ipsw
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes
        self.sshUser = sshUser
        self.publicKey = publicKey
        self.sshPublicKeyPath = sshPublicKeyPath
    }
}

/// Installs macOS from a restore image onto the machine of a bundle; replaced by a fake in tests.
public protocol MacOSInstalling: Sendable {
    /// Installs macOS from `ipsw` onto the VM built from `bundle` and `config` (complete except
    /// for the installed system), reporting the completed fraction (0...1) through `progress`.
    /// Cancelling the calling task stops the installation: the call returns only once the
    /// installation has stopped (no file of the bundle is in use any more) and then throws
    /// `CancellationError`.
    func install(
        bundle: VMBundle, config: VMConfig, ipsw: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws
}

/// Creates complete macOS VM bundles from an IPSW (see `docs/BUNDLE-FORMAT.md`).
///
/// - Before any file is created in the root: the user name, the key and the resources are
///   checked, the IPSW is inspected again (`MacRestoreImage.inspect`), the resources are checked
///   against the image's minimums, the name must be free (ignoring case) and the volume must have
///   `diskBytes` plus `SnapshotStore.spaceMargin` free.
/// - The VM is built in `<root>/.creating-<uuid>/` (0700, invisible to the library, its `.lock`
///   held for the whole installation) and renamed to `<name>.nidovm` (`RENAME_EXCL`) only once
///   macOS is installed: until then no bundle exists. On any failure, and when the task is
///   cancelled, the folder is removed; a folder left by a crash is swept by
///   `VMBundle.sweepOrphanTombstones` once its lock is free and it is old.
/// - The VM gets a new MAC address and `VZMacMachineIdentifier`; the M3c features
///   (provisioning, Guest Tools, AI bridge, templates) stay off: they are Linux-only.
/// - The VM is on the controlled network (`VMConfig.controlledNetwork`) with the macOS base list
///   (`EgressPolicy.macOSBase`: activation, software update, time) as its `egress.json`; App
///   Store, iCloud and every other site stay blocked until domains are added.
public struct MacInstaller: Sendable {
    /// What the installer asks the system, replaceable in the tests.
    struct Environment: Sendable {
        var loader: any MacRestoreImageLoading = LiveRestoreImageLoader()
        var hostVersion = ProcessInfo.processInfo.operatingSystemVersion
        var availableCapacity: @Sendable (URL) throws -> UInt64 = SnapshotStore.volumeAvailableCapacity
        var installer: any MacOSInstalling = LiveMacOSInstaller()
    }

    /// Largest accepted disk: `diskBytes + SnapshotStore.spaceMargin` must still fit in an `off_t`.
    static let maxDiskBytes = UInt64(Int64.max) - SnapshotStore.spaceMargin

    /// Prefix of the staging directory of an installation: `.creating-<uuid>`.
    static let creatingPrefix = ".creating-"

    private let paths: NidoPaths
    private let environment: Environment

    public init(paths: NidoPaths) {
        self.init(paths: paths, environment: Environment())
    }

    init(paths: NidoPaths, environment: Environment) {
        self.paths = paths
        self.environment = environment
    }

    /// Installs a new macOS VM and returns its bundle; see the type's documentation. `owner` is the
    /// owner written in the staging folder's lock (`.cliOperation` for `nido create`, `.app`).
    /// Runs off the caller's actor.
    @concurrent
    public func install(
        _ r: MacVMRequest, owner: LockOwner = .cliOperation,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> VMBundle {
        try VMConfig.validateSSHUser(r.sshUser)
        let key = try CloudInitSeed.validatePublicKey(r.publicKey)
        try ResourceLimits.validate(cpuCount: r.cpuCount, memoryBytes: r.memoryBytes)
        guard r.diskBytes > 0 else { throw NidoError.invalidResources(L10n.string("disk: size is zero")) }
        // `ftruncate` takes an `off_t` and the free-space check adds the margin: neither may overflow.
        guard r.diskBytes <= Self.maxDiskBytes else {
            throw NidoError.invalidResources(L10n.string("disk: size too large (\(String(r.diskBytes)) bytes)"))
        }

        let info = try await MacRestoreImage.inspect(
            r.ipsw, loader: environment.loader, hostVersion: environment.hostVersion)
        guard r.cpuCount >= info.minimumCPUCount else {
            throw NidoError.invalidResources(
                L10n.string("CPU: macOS \(info.version) needs at least \(info.minimumCPUCount) CPUs"))
        }
        guard r.memoryBytes >= info.minimumMemoryBytes else {
            throw NidoError.invalidResources(
                L10n.string("memory: macOS \(info.version) needs at least \(ByteSize.format(info.minimumMemoryBytes))"))
        }
        guard let hardwareModel = VZMacHardwareModel(dataRepresentation: info.hardwareModel),
            hardwareModel.isSupported
        else { throw NidoError.restoreImageUnsupported(version: info.version) }

        try paths.ensureRoot()
        try checkNameIsFree(r.name)
        let needed = r.diskBytes + SnapshotStore.spaceMargin
        let available = try environment.availableCapacity(paths.root)
        guard available >= needed else { throw NidoError.insufficientSpace(needed: needed, available: available) }

        let config = VMConfig(
            id: UUID(), name: r.name, guest: .macos, cpuCount: r.cpuCount, memoryBytes: r.memoryBytes,
            diskBytes: r.diskBytes, macAddress: VZMACAddress.randomLocallyAdministered().string,
            clipboardSharing: false, sshPublicKeyPath: r.sshPublicKeyPath, sshUser: r.sshUser,
            osVersion: info.version, minimumCPUCount: info.minimumCPUCount,
            minimumMemoryBytes: info.minimumMemoryBytes, controlledNetwork: true)

        try Task.checkCancellation()
        let staging = paths.root.appendingPathComponent(
            "\(Self.creatingPrefix)\(UUID().uuidString)", isDirectory: true)
        guard mkdir(staging.path, 0o700) == 0 else { throw posixError() }
        do {
            let bundle = VMBundle(url: staging)
            let lock = try BundleLock.acquire(bundle, owner: owner)
            defer { lock.release() }

            try createDisk(bundle.diskURL, size: r.diskBytes)
            _ = try VZMacAuxiliaryStorage(
                creatingStorageAt: bundle.auxiliaryStorageURL, hardwareModel: hardwareModel, options: [])
            try MachineFileCopy.protect(bundle.auxiliaryStorageURL)
            try MachineFileCopy.writeNewFile(bundle.hardwareModelURL, data: info.hardwareModel)
            try MachineFileCopy.writeNewFile(
                bundle.machineIdentifierURL, data: VZMacMachineIdentifier().dataRepresentation)
            try MachineFileCopy.writeNewFile(bundle.authorizedKeyURL, data: Data((key + "\n").utf8))
            try bundle.writeConfigUnlocked(config)
            // Controlled with the macOS base list: activation, software update and time only.
            try EgressPolicyStore.save(EgressPolicy.macOSBase, bundle: bundle)
            try Task.checkCancellation()
            // The image may have been moved or replaced since `inspect`: `VZMacOSInstaller` raises an
            // exception (not an error) for a URL that is not a file on disk.
            try Self.checkImageStillThere(r.ipsw)

            do {
                try await environment.installer.install(
                    bundle: bundle, config: config, ipsw: r.ipsw, progress: progress)
            } catch {
                throw Self.translate(error, version: info.version, cancelled: Task.isCancelled)
            }
            // Kept on purpose: a cancel that arrives after the installer finished still discards the
            // VM (the user asked to cancel; the folder is removed below, nothing reaches the library).
            try Task.checkCancellation()

            // The machine files are complete: make them durable before the VM appears.
            try Self.fullSync(bundle.diskURL)
            try Self.fullSync(bundle.auxiliaryStorageURL)
            try SnapshotStore.syncDirectoryNow(staging)
            try checkNameIsFree(r.name)
            let destination = paths.bundleURL(for: r.name)
            guard renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST { throw NidoError.alreadyExists(r.name.rawValue) }
                throw posixError()
            }
            // The VM exists from here on: a failed sync of the root is not a failed install.
            try? SnapshotStore.syncDirectoryNow(paths.root)
            return VMBundle(url: destination)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// `CancellationError` when the task was cancelled (whatever the installer reported);
    /// `VZError.installationRequiresUpdate` as `.restoreImageUnsupported` (this Mac's
    /// Virtualization cannot install that image); anything else unchanged.
    static func translate(_ error: any Error, version: String, cancelled: Bool) -> any Error {
        if cancelled || error is CancellationError { return CancellationError() }
        let ns = error as NSError
        if ns.domain == VZErrorDomain, ns.code == VZError.Code.installationRequiresUpdate.rawValue {
            return NidoError.restoreImageUnsupported(version: version)
        }
        return error
    }

    /// `.notARestoreImage(path)` unless `url` is still a regular file (`lstat`: a symlink, a
    /// directory or a missing file are refused). Run just before `VZMacOSInstaller` is created.
    static func checkImageStillThere(_ url: URL) throws {
        var info = stat()
        guard url.isFileURL, lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw NidoError.notARestoreImage(url.path)
        }
    }

    /// `fcntl(F_FULLFSYNC)` of a private file of the bundle (`PrivateFile`): its data reaches the
    /// disk, not only the drive's cache.
    static func fullSync(_ url: URL) throws {
        let fd = try PrivateFile.open(url, flags: O_RDONLY, label: url.lastPathComponent)
        defer { _ = Darwin.close(fd) }
        guard fcntl(fd, F_FULLFSYNC) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// `.alreadyExists(name)` when a VM of that name exists, ignoring case.
    private func checkNameIsFree(_ name: VMName) throws {
        let wanted = (name.rawValue + ".nidovm").lowercased()
        let entries = try FileManager.default.contentsOfDirectory(atPath: paths.root.path)
        if entries.contains(where: { $0.lowercased() == wanted }) {
            throw NidoError.alreadyExists(name.rawValue)
        }
    }

    /// A new, empty (sparse) disk image of `size` bytes, 0600.
    private func createDisk(_ url: URL, size: UInt64) throws {
        let fd = try PrivateFile.open(url, flags: O_WRONLY | O_CREAT | O_EXCL, label: url.lastPathComponent)
        defer { _ = Darwin.close(fd) }
        guard ftruncate(fd, off_t(size)) == 0, fsync(fd) == 0 else { throw posixError() }
    }

    private func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

/// `VZMacOSInstaller` on a VM built by `MacConfigurationBuilder` (no window: the default display).
/// Needs the `com.apple.security.virtualization` entitlement. Cancellation cancels the installer's
/// `progress` (the documented way: `VZMacOSInstaller` has no cancel method, and pausing or stopping
/// the VM during the installation is undefined behaviour); the VM is stopped only after the
/// installer has finished.
public struct LiveMacOSInstaller: MacOSInstalling {
    public init() {}

    public func install(
        bundle: VMBundle, config: VMConfig, ipsw: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        // A controlled VM installs on its relay too (never Apple's NAT); the installer does not
        // need the guest's network, and the relay ends with the installation. The relay has the
        // default `EgressRelay.Options()`: no events handler, so a block during the installation
        // goes only to the staging bundle's `egress.log` (no stderr line, no app notice).
        let built = try MacConfigurationBuilder.make(bundle: bundle, config: config)
        // Waits: the staging bundle's egress.log is complete before the installation returns.
        defer { built.egressRelay?.shutdownAndWait() }
        try built.configuration.validate()
        let run = InstallRun(configuration: built.configuration, ipsw: ipsw, progress: progress)
        try await withTaskCancellationHandler {
            try await run.run()
        } onCancel: {
            run.cancel()
        }
    }
}

/// One installation. Every property is used only on `queue`, the VM's serial queue.
private final class InstallRun: @unchecked Sendable {
    private let queue = DispatchQueue(label: "nido.mac-install")
    private let configuration: VZVirtualMachineConfiguration
    private let ipsw: URL
    private let progress: @Sendable (Double) -> Void
    private var vm: VZVirtualMachine?
    private var installer: VZMacOSInstaller?
    private var observation: NSKeyValueObservation?
    private var cancelled = false

    init(configuration: VZVirtualMachineConfiguration, ipsw: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.configuration = configuration
        self.ipsw = ipsw
        self.progress = progress
    }

    func run() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { self.start(continuation) }
        }
    }

    /// Cancels the installation once it has started (cancelling `progress` before `install` raises
    /// an exception); before that, `start` sees `cancelled` and does not start it.
    func cancel() {
        queue.async {
            self.cancelled = true
            self.installer?.progress.cancel()
        }
    }

    private func start(_ continuation: CheckedContinuation<Void, any Error>) {
        guard !cancelled else { return continuation.resume(throwing: CancellationError()) }
        // `VZMacOSInstaller.init` raises an exception for a URL that is not a file on disk.
        do {
            try MacInstaller.checkImageStillThere(ipsw)
        } catch {
            return continuation.resume(throwing: error)
        }
        let vm = VZVirtualMachine(configuration: configuration, queue: queue)
        let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipsw)
        let progress = self.progress
        observation = installer.progress.observe(\.fractionCompleted, options: [.initial, .new]) { p, _ in
            progress(p.fractionCompleted)
        }
        self.vm = vm
        self.installer = installer
        installer.install { result in
            // On `queue`. The installer is done: the VM may be stopped now.
            self.finish(result, continuation)
        }
    }

    private func finish(_ result: Result<Void, any Error>, _ continuation: CheckedContinuation<Void, any Error>) {
        observation?.invalidate()
        observation = nil
        let done: @Sendable () -> Void = {
            self.installer = nil
            self.vm = nil
            continuation.resume(with: result)
        }
        if let vm, vm.canStop {
            vm.stop { _ in done() }
        } else {
            done()
        }
    }
}
