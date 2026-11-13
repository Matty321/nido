// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The Linux distributions of Nido's catalog. Recorded in `VMConfig.distribution` (nil there
/// means Debian 13: every Linux VM created before Ubuntu was in the catalog).
public enum LinuxDistribution: String, Codable, Sendable, CaseIterable {
    case debian13 = "debian-13"
    case ubuntu2604 = "ubuntu-26.04"
    case ubuntu2404 = "ubuntu-24.04"

    /// "Debian 13", "Ubuntu 26.04 LTS": the library card, `nido list` and the wizard.
    public var displayName: String {
        switch self {
        case .debian13: "Debian 13"
        case .ubuntu2604: "Ubuntu 26.04 LTS"
        case .ubuntu2404: "Ubuntu 24.04 LTS"
        }
    }

    public var isUbuntu: Bool { self != .debian13 }

    /// The guest's NTP client, which the seed pins to `GuestTimeSync.server`.
    public var timeClient: GuestTimeSync.Client { self == .ubuntu2604 ? .chrony : .timesyncd }

    /// The catalog image of this distribution.
    public var image: CloudImage {
        switch self {
        case .debian13: CloudImageCatalog.debian13
        case .ubuntu2604: CloudImageCatalog.ubuntu2604
        case .ubuntu2404: CloudImageCatalog.ubuntu2404
        }
    }
}

/// How the checksum list of an image is written and hashed.
public enum ChecksumAlgorithm: String, Sendable, Equatable {
    /// `SHA512SUMS` (Debian).
    case sha512
    /// `SHA256SUMS` (Ubuntu).
    case sha256

    /// Length of a digest in lowercase hex.
    public var hexLength: Int { self == .sha512 ? 128 : 64 }
}

/// A downloadable cloud image together with the URL of its checksum list.
public struct CloudImage: Sendable, Equatable {
    public let id: String
    public let fileName: String
    public let url: URL
    public let checksumsURL: URL
    /// Largest accepted download: a larger declared `Content-Length` is refused before
    /// writing, and the transfer is aborted as soon as more bytes than this arrive.
    public let maxBytes: UInt64
    /// The hash `checksumsURL` lists (and the cache sidecar stores).
    public let checksum: ChecksumAlgorithm
    public let distribution: LinuxDistribution
    /// Detached OpenPGP signature of `checksumsURL` and the built-in keys it must verify with,
    /// any of them (`OpenPGPSignature`): Ubuntu signs its lists, Debian's cloud images publish none.
    public let signature: Signature?
    /// Debian's build manifest (`DebianBuildManifest`), next to the image and listed in
    /// `checksumsURL`: checked against the list and the image's digest, and against an older
    /// build served again. Nil for Ubuntu (its signed list has its own protection).
    public let manifest: Manifest?

    public struct Manifest: Sendable, Equatable {
        public let url: URL
        /// The `upload.cloud.debian.org/image-format` of `fileName` ("raw").
        public let imageFormat: String
        public init(url: URL, imageFormat: String) { self.url = url; self.imageFormat = imageFormat }
        /// The manifest's name in the checksum list.
        public var fileName: String { url.lastPathComponent }
    }

    public struct Signature: Sendable, Equatable {
        public let url: URL
        public let keys: [OpenPGPPublicKey]
        public init(url: URL, keys: [OpenPGPPublicKey]) { self.url = url; self.keys = keys }
    }

    public init(
        id: String, fileName: String, url: URL, checksumsURL: URL, maxBytes: UInt64,
        checksum: ChecksumAlgorithm = .sha512, distribution: LinuxDistribution = .debian13,
        signature: Signature? = nil, manifest: Manifest? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.url = url
        self.checksumsURL = checksumsURL
        self.maxBytes = maxBytes
        self.checksum = checksum
        self.distribution = distribution
        self.signature = signature
        self.manifest = manifest
    }

    /// Cache sidecar holding the verified digest: `<fileName>.sha512` or `<fileName>.sha256`.
    public var sidecarName: String { fileName + "." + checksum.rawValue }
}

/// Built-in catalog of supported cloud images. Debian publishes a raw disk; Ubuntu only a qcow2
/// (`.img`), which `VMFactory` turns into the VM's raw disk with `Qcow2Image`.
public enum CloudImageCatalog {
    public static let debian13 = CloudImage(
        id: "debian-13",
        fileName: "debian-13-genericcloud-arm64.raw",
        url: URL(string: "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-arm64.raw")!,
        checksumsURL: URL(string: "https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS")!,
        maxBytes: 8 << 30,
        manifest: .init(
            url: URL(string: "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-arm64.json")!,
            imageFormat: "raw")
    )

    /// Ubuntu Server 26.04 LTS (Resolute Raccoon), the latest release of its cloud image.
    public static let ubuntu2604 = CloudImage(
        id: "ubuntu-26.04",
        fileName: "ubuntu-26.04-server-cloudimg-arm64.img",
        url: URL(string: "https://cloud-images.ubuntu.com/releases/resolute/release/ubuntu-26.04-server-cloudimg-arm64.img")!,
        checksumsURL: URL(string: "https://cloud-images.ubuntu.com/releases/resolute/release/SHA256SUMS")!,
        maxBytes: 4 << 30, checksum: .sha256, distribution: .ubuntu2604,
        signature: .init(
            url: URL(string: "https://cloud-images.ubuntu.com/releases/resolute/release/SHA256SUMS.gpg")!,
            keys: UbuntuCloudImageKey.keys)
    )

    /// Ubuntu Server 24.04 LTS (Noble Numbat), the latest release of its cloud image.
    public static let ubuntu2404 = CloudImage(
        id: "ubuntu-24.04",
        fileName: "ubuntu-24.04-server-cloudimg-arm64.img",
        url: URL(string: "https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-arm64.img")!,
        checksumsURL: URL(string: "https://cloud-images.ubuntu.com/releases/noble/release/SHA256SUMS")!,
        maxBytes: 4 << 30, checksum: .sha256, distribution: .ubuntu2404,
        signature: .init(
            url: URL(string: "https://cloud-images.ubuntu.com/releases/noble/release/SHA256SUMS.gpg")!,
            keys: UbuntuCloudImageKey.keys)
    )

    /// Every catalog image, in the order the wizard and `nido create` show them.
    public static let all = [debian13, ubuntu2604, ubuntu2404]

    public static func image(id: String) -> CloudImage? {
        all.first { $0.id == id }
    }
}
