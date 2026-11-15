// SPDX-License-Identifier: Apache-2.0
import Foundation
import Virtualization

/// The macOS restore image (IPSW) Apple offers for this Mac: what `nido image macos` shows and
/// `MacImageDownloader` fetches.
public struct MacImageOffer: Equatable, Sendable {
    /// Apple's build, e.g. "26B131": the downloaded file must have this one.
    public let build: String
    /// "27.2", or "27.2.1" when the patch version is not zero.
    public let version: String
    /// Where Apple serves the image (always passes `DownloadPolicy.validateAppleDownload`).
    public let url: URL

    public init(build: String, version: String, url: URL) {
        self.build = build
        self.version = version
        self.url = url
    }

    /// The last component of `url`, e.g. "UniversalMac_27.2.1_26B131_Restore.ipsw".
    public var fileName: String { url.lastPathComponent }

    /// The major version of `version` ("27" for "27.2.1"), nil when it does not start with a number.
    public var majorVersion: Int? {
        version.split(separator: ".", maxSplits: 1).first.flatMap { Int($0) }
    }
}

/// Asks which macOS restore image this Mac supports; replaced by a fake in tests.
public protocol MacImageCataloging: Sendable {
    /// The latest restore image this Mac supports. Goes online: call it only when the user asks.
    func latestSupported() async throws(NidoError) -> MacImageOffer
}

/// `VZMacOSRestoreImage.fetchLatestSupported`: one request to Apple, made only when the user
/// asks (`nido image macos`, the wizard's "Download from Apple"); nothing is downloaded here.
/// The answer is refused unless its URL passes `DownloadPolicy.validateAppleDownload`.
public struct LiveMacImageCatalog: MacImageCataloging {
    /// The values read from Virtualization's answer.
    struct Fetched: Sendable {
        var buildVersion: String
        var operatingSystemVersion: OperatingSystemVersion
        var url: URL
    }

    private let fetch: @Sendable () async throws -> Fetched

    public init() {
        self.init(fetch: Self.fetchFromVirtualization)
    }

    /// Test seam: `fetch` stands for Virtualization's answer.
    init(fetch: @escaping @Sendable () async throws -> Fetched) {
        self.fetch = fetch
    }

    /// Throws `.hostNotAllowed(url)` for an answer outside Apple's hosts, `.downloadFailed` when
    /// Apple cannot be asked (offline, refused).
    public func latestSupported() async throws(NidoError) -> MacImageOffer {
        let fetched: Fetched
        do {
            fetched = try await fetch()
        } catch let error as NidoError {
            throw error
        } catch {
            throw .downloadFailed(L10n.string(
                "can’t ask Apple which macOS this Mac supports (\(error.localizedDescription))"))
        }
        try DownloadPolicy.validateAppleDownload(fetched.url)
        return MacImageOffer(
            build: fetched.buildVersion,
            version: MacRestoreImage.versionString(fetched.operatingSystemVersion),
            url: fetched.url)
    }

    private static func fetchFromVirtualization() async throws -> Fetched {
        try await withCheckedThrowingContinuation { continuation in
            VZMacOSRestoreImage.fetchLatestSupported { result in
                // Called on an arbitrary thread: copy the values out of the image here.
                switch result {
                case .success(let image):
                    continuation.resume(returning: Fetched(
                        buildVersion: image.buildVersion,
                        operatingSystemVersion: image.operatingSystemVersion,
                        url: image.url))
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
