// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import Virtualization

/// What Nido needs from a macOS restore image (IPSW) that this Mac can install.
public struct MacImageInfo: Sendable, Equatable {
    public var buildVersion: String
    /// "26.1", or "26.0.1" when the patch version is not zero.
    public var version: String
    /// `minimumSupportedCPUCount` of the most featureful configuration this Mac supports.
    public var minimumCPUCount: Int
    /// `minimumSupportedMemorySize` (bytes) of that configuration.
    public var minimumMemoryBytes: UInt64
    /// `VZMacHardwareModel.dataRepresentation` of that configuration.
    public var hardwareModel: Data

    public init(
        buildVersion: String, version: String, minimumCPUCount: Int, minimumMemoryBytes: UInt64,
        hardwareModel: Data
    ) {
        self.buildVersion = buildVersion
        self.version = version
        self.minimumCPUCount = minimumCPUCount
        self.minimumMemoryBytes = minimumMemoryBytes
        self.hardwareModel = hardwareModel
    }
}

/// The values read from a `VZMacOSRestoreImage`, before Nido's checks.
public struct LoadedMacRestoreImage: Sendable {
    /// `mostFeaturefulSupportedConfiguration`.
    public struct Requirements: Sendable, Equatable {
        /// `hardwareModel.isSupported`.
        public var hardwareModelSupported: Bool
        /// `hardwareModel.dataRepresentation`.
        public var hardwareModel: Data
        public var minimumCPUCount: Int
        public var minimumMemoryBytes: UInt64

        public init(hardwareModelSupported: Bool, hardwareModel: Data, minimumCPUCount: Int, minimumMemoryBytes: UInt64) {
            self.hardwareModelSupported = hardwareModelSupported
            self.hardwareModel = hardwareModel
            self.minimumCPUCount = minimumCPUCount
            self.minimumMemoryBytes = minimumMemoryBytes
        }
    }

    public var buildVersion: String
    public var operatingSystemVersion: OperatingSystemVersion
    /// `VZMacOSRestoreImage.isSupported`.
    public var isSupported: Bool
    /// nil when no hardware model of the image is supported on this Mac.
    public var configuration: Requirements?

    public init(
        buildVersion: String, operatingSystemVersion: OperatingSystemVersion, isSupported: Bool,
        configuration: Requirements?
    ) {
        self.buildVersion = buildVersion
        self.operatingSystemVersion = operatingSystemVersion
        self.isSupported = isSupported
        self.configuration = configuration
    }
}

/// Loads a restore image file; replaced by a fake in tests.
public protocol MacRestoreImageLoading: Sendable {
    /// Loads the image at `url` (a local file URL) or throws.
    func load(_ url: URL) async throws -> LoadedMacRestoreImage
}

/// `VZMacOSRestoreImage.load(from:completionHandler:)`. Needs the
/// `com.apple.security.virtualization` entitlement. Reads the file only.
public struct LiveRestoreImageLoader: MacRestoreImageLoading {
    public init() {}

    public func load(_ url: URL) async throws -> LoadedMacRestoreImage {
        // A non-file URL raises an Objective-C exception in Virtualization: never pass one.
        guard url.isFileURL else { throw NidoError.notARestoreImage(url.absoluteString) }
        return try await withCheckedThrowingContinuation { continuation in
            VZMacOSRestoreImage.load(from: url) { result in
                // Called on an arbitrary thread: copy the values out of the image here.
                switch result {
                case .success(let image):
                    let requirements = image.mostFeaturefulSupportedConfiguration.map {
                        LoadedMacRestoreImage.Requirements(
                            hardwareModelSupported: $0.hardwareModel.isSupported,
                            hardwareModel: $0.hardwareModel.dataRepresentation,
                            minimumCPUCount: $0.minimumSupportedCPUCount,
                            minimumMemoryBytes: $0.minimumSupportedMemorySize)
                    }
                    continuation.resume(returning: LoadedMacRestoreImage(
                        buildVersion: image.buildVersion,
                        operatingSystemVersion: image.operatingSystemVersion,
                        isSupported: image.isSupported,
                        configuration: requirements))
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// Checks a macOS restore image (IPSW) the user chose, before anything is created in the root.
/// Nido only reads the file: it never downloads, modifies, moves or copies it.
public enum MacRestoreImage {
    /// An IPSW is a ZIP archive: it starts with a local file header.
    private static let zipMagic: [UInt8] = [0x50, 0x4B, 0x03, 0x04]

    /// Returns what a VM installed from `url` needs, or throws:
    /// - `.notFound(path)`: no file there;
    /// - `.unsafePath(path)`: the last component is a symlink;
    /// - `.notARestoreImage(path)`: not a readable regular file starting like a ZIP archive, or
    ///   Virtualization.framework cannot load it;
    /// - `.restoreImageUnsupported`: the image's major version is newer than `hostVersion`'s
    ///   (`requiredHostMajor` set: always refused, whatever Virtualization reports), or the image,
    ///   its most featureful configuration or that configuration's hardware model is not
    ///   supported on this Mac.
    public static func inspect(
        _ url: URL,
        loader: any MacRestoreImageLoading = LiveRestoreImageLoader(),
        hostVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) async throws(NidoError) -> MacImageInfo {
        let path = url.path
        guard url.isFileURL else { throw .notARestoreImage(url.absoluteString) }
        try checkFile(path)

        let loaded: LoadedMacRestoreImage
        do {
            loaded = try await loader.load(url)
        } catch let error as NidoError {
            throw error
        } catch {
            throw .notARestoreImage(path)
        }

        let osVersion = loaded.operatingSystemVersion
        let version = versionString(osVersion)
        if osVersion.majorVersion > hostVersion.majorVersion {
            throw .restoreImageUnsupported(version: version, requiredHostMajor: osVersion.majorVersion)
        }
        guard loaded.isSupported, let configuration = loaded.configuration, configuration.hardwareModelSupported
        else { throw .restoreImageUnsupported(version: version) }
        return MacImageInfo(
            buildVersion: loaded.buildVersion, version: version,
            minimumCPUCount: configuration.minimumCPUCount,
            minimumMemoryBytes: configuration.minimumMemoryBytes,
            hardwareModel: configuration.hardwareModel)
    }

    /// "26.1"; "26.0.1" when the patch version is not zero.
    static func versionString(_ v: OperatingSystemVersion) -> String {
        let base = "\(v.majorVersion).\(v.minorVersion)"
        return v.patchVersion == 0 ? base : "\(base).\(v.patchVersion)"
    }

    /// Opens `path` read-only without following a symlink (O_NOFOLLOW) or blocking on a FIFO
    /// (O_NONBLOCK) and checks that it is a regular file starting with the ZIP magic.
    private static func checkFile(_ path: String) throws(NidoError) {
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            switch errno {
            case ELOOP: throw .unsafePath(path)
            case ENOENT, ENOTDIR: throw .notFound(path)
            default: throw .notARestoreImage(path)
            }
        }
        defer { _ = Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
            info.st_size >= off_t(zipMagic.count)
        else { throw .notARestoreImage(path) }
        var head = [UInt8](repeating: 0, count: zipMagic.count)
        let count = head.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
        guard count == zipMagic.count, head == zipMagic else { throw .notARestoreImage(path) }
    }
}
