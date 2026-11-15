// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Decides which download URLs Nido accepts: HTTPS only, exact host allowlist,
/// no embedded credentials, no non-default port.
public enum DownloadPolicy {
    public static let allowedHosts: Set<String> = ["cloud.debian.org", "cloud-images.ubuntu.com"]

    public static func validate(_ url: URL) throws(NidoError) {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              allowedHosts.contains(host),
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443
        else {
            throw .hostNotAllowed(url.absoluteString)
        }
    }

    /// Redirect targets accepted for the image file only (Debian serves it from mirrors; Ubuntu
    /// serves it directly).
    /// Any host is allowed, but only over HTTPS, without credentials and on the default port.
    /// Integrity comes from the digest in `SHA512SUMS` / `SHA256SUMS`, fetched under `validate(_:)`.
    public static func validateMirrorRedirect(_ url: URL) throws(NidoError) {
        guard url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443
        else {
            throw .hostNotAllowed(url.absoluteString)
        }
    }

    /// The macOS restore image Apple offers (`MacImageCatalog`): the URL and every redirect hop
    /// must be HTTPS on `apple.com` or a host ending in `.apple.com` or `.cdn-apple.com` (a
    /// suffix match on a dot boundary: `evilapple.com` and `apple.com.evil.net` are refused; only
    /// `a-z 0-9 . -` in the host), without credentials, on the default port. Apple publishes no checksum for it: the file is
    /// accepted only once Virtualization loads it and its build is the one offered
    /// (`MacImageDownloader`).
    private static let hostCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")

    public static func validateAppleDownload(_ url: URL) throws(NidoError) {
        guard url.scheme?.lowercased() == "https",
              let host = url.host(percentEncoded: true)?.lowercased(),
              host.unicodeScalars.allSatisfy(Self.hostCharacters.contains),
              !host.hasPrefix("."), !host.contains(".."),
              host == "apple.com" || host.hasSuffix(".apple.com") || host.hasSuffix(".cdn-apple.com"),
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443
        else {
            throw .hostNotAllowed(url.absoluteString)
        }
    }
}
