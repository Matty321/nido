// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The build manifest Debian publishes next to each cloud image (`debian-13-genericcloud-arm64.json`
/// in `latest/`): which build `latest` is (`data.info.version`, "20261103-2651") and the SHA-512
/// of each uploaded format. Debian signs neither the manifest nor `SHA512SUMS`; `ImageStore` uses
/// it only for consistency and against an older build served again (see `ImageStore.acceptBuild`),
/// never as a source of trust of its own.
public enum DebianBuildManifest {
    /// Largest manifest read (about 50 KiB in 2026).
    public static let maxBytes: UInt64 = 1 << 20

    /// A build of Debian's cloud images: its date (yyyymmdd) and its number, ordered.
    public struct Version: Sendable, Equatable, Comparable, CustomStringConvertible {
        public let date: Int
        public let build: Int

        /// "20261103-2651"; nil for anything else.
        public init?(_ text: String) {
            let parts = text.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].count == 8, (1...9).contains(parts[1].count),
                parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
                let date = Int(parts[0]), let build = Int(parts[1])
            else { return nil }
            self.date = date
            self.build = build
        }

        public var description: String { String(format: "%08d-%d", date, build) }

        public static func < (a: Version, b: Version) -> Bool {
            (a.date, a.build) < (b.date, b.build)
        }
    }

    /// The build version and the SHA-512 (lowercase hex) of the upload of `imageFormat` ("raw").
    /// Every upload of that format must name the build's version and the same digest.
    public static func parse(_ data: Data, imageFormat: String) throws -> (version: Version, sha512: String) {
        func invalid(_ why: String) -> NidoError { .downloadFailed(L10n.string("invalid build manifest (\(why))")) }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let items = root["items"] as? [[String: Any]]
        else { throw invalid(L10n.string("not the expected JSON")) }

        let builds = items.filter { $0["kind"] as? String == "Build" }
        guard builds.count == 1,
            let info = (builds[0]["data"] as? [String: Any])?["info"] as? [String: Any],
            let versionText = info["version"] as? String
        else { throw invalid(L10n.string("version missing")) }
        guard let version = Version(versionText) else { throw invalid(L10n.string("version \(String(versionText.prefix(40)))")) }

        var digests = Set<String>()
        for item in items where item["kind"] as? String == "Upload" {
            let metadata = item["metadata"] as? [String: Any]
            let labels = metadata?["labels"] as? [String: String] ?? [:]
            guard labels["upload.cloud.debian.org/image-format"] == imageFormat else { continue }
            guard labels["cloud.debian.org/version"] == versionText else { throw invalid(L10n.string("versions differ")) }
            let annotations = metadata?["annotations"] as? [String: String] ?? [:]
            // Base64 without its padding ("…Qw", 86 characters for 64 bytes).
            guard let digest = annotations["cloud.debian.org/digest"], digest.hasPrefix("sha512:"),
                let bytes = unpaddedBase64(String(digest.dropFirst("sha512:".count))), bytes.count == 64
            else { throw invalid(L10n.string("checksum of the \(imageFormat) format")) }
            digests.insert(bytes.map { String(format: "%02x", $0) }.joined())
        }
        guard digests.count == 1, let sha512 = digests.first else { throw invalid(L10n.string("\(imageFormat) format missing or listed more than once")) }
        return (version, sha512)
    }

    /// Base64 with or without its trailing `=`.
    static func unpaddedBase64(_ text: String) -> Data? {
        guard !text.contains("=") || text.hasSuffix("=") else { return nil }
        let padded = text.count % 4 == 0 ? text : text + String(repeating: "=", count: 4 - text.count % 4)
        return Data(base64Encoded: padded)
    }
}
