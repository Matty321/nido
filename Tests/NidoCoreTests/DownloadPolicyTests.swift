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

    @Test func catalogLookup() {
        #expect(CloudImageCatalog.image(id: "debian-13") == CloudImageCatalog.debian13)
        #expect(CloudImageCatalog.image(id: "nope") == nil)
        #expect(CloudImageCatalog.debian13.fileName == "debian-13-genericcloud-arm64.raw")
    }
}
