// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore

/// Where the wizard's "Scarica" gets the base image from.
enum WizardImageSource: Sendable {
    /// The catalog image, through the shared `ImageStore` (confirmed download, SHA-512 check).
    /// `cacheRoot` is the store's cache: it tells whether the image is already there.
    case catalog(CloudImage, store: ImageStore, cacheRoot: URL)
    /// DEBUG `-NidoImageFile`: a local raw image, no network and no checksum (UI tests).
    case localFile(URL)
}

/// Creates the VM bundle (`LiveVMCreator` in the app, a fake in the tests).
protocol VMCreating: Sendable {
    func create(_ request: LinuxVMRequest) async throws
    /// "Da modello": a new VM from the template (`VMCloner.createFromTemplate`); `sshKeyPath` nil
    /// keeps the template's key.
    func createFromTemplate(_ template: VMName, as name: VMName, sshKeyPath: URL?) async throws
}

/// `VMCreating` on top of `VMFactory`: the clone and the seed ISO run off the main actor, and
/// any failure removes the partial bundle (`VMFactory.createLinux`).
struct LiveVMCreator: VMCreating {
    let paths: NidoPaths

    func create(_ request: LinuxVMRequest) async throws {
        _ = try await VMFactory(paths: paths, runner: SystemProcessRunner()).createLinuxAsync(request)
    }

    func createFromTemplate(_ template: VMName, as name: VMName, sshKeyPath: URL?) async throws {
        _ = try await VMCloner(paths: paths, runner: SystemProcessRunner())
            .createFromTemplate(template, as: name, sshKeyPath: sshKeyPath, owner: .app)
    }

    /// S04: the RAM of the running VMs with the new one (`MemoryHeadroom`), off the main actor.
    func headroom(memoryBytes: UInt64) async -> MemoryHeadroom {
        let paths = paths
        return await Task.detached { MemoryHeadroom.check(starting: nil, memoryBytes: memoryBytes, paths: paths) }.value
    }
}

/// Checks an IPSW and installs a macOS VM from it (`LiveMacVMInstaller` in the app, a fake in the
/// tests and, in DEBUG, `DebugFakeMacInstaller` for the UI tests).
protocol MacVMInstalling: Sendable {
    /// `MacRestoreImage.inspect`: what the image needs, or why this Mac cannot install it. Only
    /// reads the file.
    func inspect(_ ipsw: URL) async throws -> MacImageInfo
    /// `MacInstaller.install` (owner `.app`): nothing reaches the library until macOS is installed;
    /// cancelling the task stops it, removes the `.creating-*` folder and throws `CancellationError`.
    func install(_ request: MacVMRequest, progress: @escaping @Sendable (Double) -> Void) async throws
}

/// `MacVMInstalling` on top of NidoCore: both run off the main actor.
struct LiveMacVMInstaller: MacVMInstalling {
    let paths: NidoPaths

    func inspect(_ ipsw: URL) async throws -> MacImageInfo {
        try await MacRestoreImage.inspect(ipsw)
    }

    func install(_ request: MacVMRequest, progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await MacInstaller(paths: paths).install(request, owner: .app, progress: progress)
    }
}

#if DEBUG
    /// DEBUG `-NidoFakeMacInstaller` (UI tests, with `-NidoRoot`): any file is "macOS 26.6
    /// (25G62)", needing 2 CPU and 4 GiB; the installation reaches 42 % and waits there until it is
    /// cancelled. Nothing is written in the root.
    struct DebugFakeMacInstaller: MacVMInstalling {
        static let info = MacImageInfo(
            buildVersion: "25G62", version: "26.6", minimumCPUCount: 2, minimumMemoryBytes: 4 << 30,
            hardwareModel: Data())

        func inspect(_ ipsw: URL) async throws -> MacImageInfo {
            guard FileManager.default.fileExists(atPath: ipsw.path) else { throw NidoError.notFound(ipsw.path) }
            return Self.info
        }

        func install(_ request: MacVMRequest, progress: @escaping @Sendable (Double) -> Void) async throws {
            for step in 0...42 {
                try await Task.sleep(for: .milliseconds(20))
                progress(Double(step) / 100)
            }
            // Until Annulla: `Task.sleep` throws `CancellationError` when the task is cancelled.
            while true { try await Task.sleep(for: .seconds(3600)) }
        }
    }
#endif
