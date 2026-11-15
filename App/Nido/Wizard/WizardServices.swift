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

/// Asks Apple for the macOS image and downloads it (`LiveMacImageDownloader` in the app, a fake in
/// the tests and, in DEBUG, `DebugFakeMacImageDownloader`). Nothing here runs before the user
/// presses "Download from Apple".
protocol MacImageDownloading: Sendable {
    /// The restore image Apple offers this Mac. Goes online.
    func latestOffer() async throws -> MacImageOffer
    /// The size of `offer`'s file (a HEAD request, part of the same ask as the offer), nil when
    /// Apple does not say or the request fails.
    func size(of offer: MacImageOffer) async -> UInt64?
    /// Bytes of `offer` already in the cache from an interrupted download (0 when none): the
    /// download resumes from there.
    func partialBytes(for offer: MacImageOffer) -> Int64
    /// Downloads `offer` into the cache (resuming a partial file) and returns the checked file.
    /// Cancelling the task keeps the partial file and throws `CancellationError`.
    func download(_ offer: MacImageOffer, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL
}

/// `MacImageDownloading` on top of NidoCore: the default destination, in the image cache.
struct LiveMacImageDownloader: MacImageDownloading {
    let catalog: any MacImageCataloging
    let downloader: MacImageDownloader

    init(cacheRoot: URL, catalog: any MacImageCataloging = LiveMacImageCatalog()) {
        self.catalog = catalog
        self.downloader = MacImageDownloader(cacheRoot: cacheRoot)
    }

    func latestOffer() async throws -> MacImageOffer {
        try await catalog.latestSupported()
    }

    func size(of offer: MacImageOffer) async -> UInt64? {
        try? await downloader.remoteSize(of: offer)
    }

    func partialBytes(for offer: MacImageOffer) -> Int64 {
        guard let destination = try? downloader.destination(for: offer, output: nil) else { return 0 }
        return downloader.partialBytes(for: destination)
    }

    func download(_ offer: MacImageOffer, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        let destination = try downloader.destination(for: offer, output: nil)
        return try await downloader.download(offer, to: destination, progress: progress)
    }
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

    /// DEBUG `-NidoFakeMacInstaller` (UI tests): Apple offers macOS 26.6; the download reaches 42 %
    /// of 1 GiB and waits there until it is cancelled. Nothing goes online nor is written.
    struct DebugFakeMacImageDownloader: MacImageDownloading {
        static let offer = MacImageOffer(
            build: "25G62", version: "26.6",
            url: URL(string: "https://updates.cdn-apple.com/UniversalMac_26.6_25G62_Restore.ipsw")!)

        func latestOffer() async throws -> MacImageOffer { Self.offer }

        func size(of offer: MacImageOffer) async -> UInt64? { 1 << 30 }

        func partialBytes(for offer: MacImageOffer) -> Int64 { 0 }

        func download(_ offer: MacImageOffer, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
            for step in 0...42 {
                try await Task.sleep(for: .milliseconds(20))
                progress(DownloadProgress(receivedBytes: UInt64(step) * (1 << 30) / 100, expectedBytes: 1 << 30))
            }
            while true { try await Task.sleep(for: .seconds(3600)) }
        }
    }
#endif
