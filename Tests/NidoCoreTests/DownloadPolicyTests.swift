// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCore

@Suite struct DownloadPolicyTests {
    @Test(arguments: [
        "http://cloud.debian.org/x",
        "https://evil.example/x",
        "https://cloud.debian.org@evil.example/x",
        "https://user:pw@cloud.debian.org/x",
        "https://user@cloud.debian.org/x",
        "https://cloud.debian.org:8443/x",
        "https://cloud.debian.org.evil.example/x",
        "https://sub.cloud.debian.org/x",
        "file:///etc/passwd",
    ])
    func rejectsUnsafeURLs(_ raw: String) throws {
        let url = try #require(URL(string: raw))
        #expect(throws: NidoError.hostNotAllowed(url.absoluteString)) {
            try DownloadPolicy.validate(url)
        }
    }

    @Test func acceptsCatalogURLs() throws {
        try DownloadPolicy.validate(CloudImageCatalog.debian13.url)
        try DownloadPolicy.validate(CloudImageCatalog.debian13.checksumsURL)
    }

    @Test func acceptsExplicit443AndMixedCase() throws {
        try DownloadPolicy.validate(try #require(URL(string: "HTTPS://Cloud.Debian.ORG:443/x")))
    }

    @Test(arguments: [
        "https://laotzu.ftp.acc.umu.se/images/cloud/x.raw",
        "https://Mirror.Example:443/x",
        "https://cloud.debian.org/x",
    ])
    func mirrorRedirectAcceptsHTTPSHosts(_ raw: String) throws {
        try DownloadPolicy.validateMirrorRedirect(try #require(URL(string: raw)))
    }

    @Test(arguments: [
        "http://mirror.example/x",
        "https://user@mirror.example/x",
        "https://user:pw@mirror.example/x",
        "https://mirror.example:8443/x",
        "file:///etc/passwd",
        "ftp://mirror.example/x",
    ])
    func mirrorRedirectRejectsUnsafeURLs(_ raw: String) throws {
        let url = try #require(URL(string: raw))
        #expect(throws: NidoError.hostNotAllowed(url.absoluteString)) {
            try DownloadPolicy.validateMirrorRedirect(url)
        }
    }

    @Test(arguments: [
        "https://updates.cdn-apple.com/2026FallFCS/x/UniversalMac_27.2.1_26B131_Restore.ipsw",
        "https://swcdn.apple.com/content/downloads/x/UniversalMac.ipsw",
        "https://apple.com/x",
        "HTTPS://Updates.CDN-Apple.COM:443/x",
        "https://a.b.apple.com/x",
    ])
    func appleDownloadAcceptsApplesHosts(_ raw: String) throws {
        try DownloadPolicy.validateAppleDownload(try #require(URL(string: raw)))
    }

    @Test(arguments: [
        "http://updates.cdn-apple.com/x",
        "https://evilapple.com/x",
        "https://evilcdn-apple.com/x",
        "https://apple.com.evil.net/x",
        "https://updates.cdn-apple.com.evil/x",
        "https://cdn-apple.com.evil/x",
        "https://cdn-apple.com/x",
        "https://user:pw@updates.cdn-apple.com/x",
        "https://user@updates.cdn-apple.com/x",
        "https://updates.cdn-apple.com@evil.example/x",
        "https://updates.cdn-apple.com:8443/x",
        "https://updates.cdn-apple.com./x",
        "https://.apple.com/x",
        "https://a..apple.com/x",
        "ftp://updates.cdn-apple.com/x",
        "file:///etc/passwd",
        "https://updates_cdn.apple.com/x",
        "https://xn--pple-43d.com.apple.com%00/x",
        "https://upd%41tes.apple.com/x",
    ])
    func appleDownloadRefusesEverythingElse(_ raw: String) throws {
        let url = try #require(URL(string: raw))
        #expect(throws: NidoError.hostNotAllowed(url.absoluteString)) {
            try DownloadPolicy.validateAppleDownload(url)
        }
    }

    @Test func catalogLookup() {
        #expect(CloudImageCatalog.image(id: "debian-13", architecture: .arm64) == CloudImageCatalog.debian13)
        #expect(CloudImageCatalog.image(id: "nope", architecture: .arm64) == nil)
        #expect(CloudImageCatalog.debian13.fileName == "debian-13-genericcloud-arm64.raw")
    }
}
