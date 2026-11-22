// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCore

/// The cloud image catalog per architecture: arm64 as before, amd64 for Intel Macs.
@Suite struct CloudImageCatalogTests {
    @Test func arm64CatalogUnchanged() {
        let images = CloudImageCatalog.all(for: .arm64)
        #expect(images.map(\.fileName) == [
            "debian-13-genericcloud-arm64.raw",
            "ubuntu-26.04-server-cloudimg-arm64.img",
            "ubuntu-24.04-server-cloudimg-arm64.img",
        ])
        #expect(images.map(\.url.absoluteString) == [
            "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-arm64.raw",
            "https://cloud-images.ubuntu.com/releases/resolute/release/ubuntu-26.04-server-cloudimg-arm64.img",
            "https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-arm64.img",
        ])
        #expect(images == CloudImageCatalog.all)
        for distribution in LinuxDistribution.allCases {
            #expect(distribution.image(for: .arm64)
                == CloudImageCatalog.image(id: distribution.rawValue, architecture: .arm64))
        }
    }

    @Test func amd64FileNames() {
        #expect(CloudImageCatalog.all(for: .x86_64).map(\.fileName) == [
            "debian-13-genericcloud-amd64.raw",
            "ubuntu-26.04-server-cloudimg-amd64.img",
            "ubuntu-24.04-server-cloudimg-amd64.img",
        ])
    }

    @Test func amd64UrlsMirrorArm64() {
        let arm = CloudImageCatalog.all(for: .arm64), amd = CloudImageCatalog.all(for: .x86_64)
        for (a, b) in zip(arm, amd) {
            #expect(b.url.absoluteString == a.url.absoluteString.replacingOccurrences(of: "arm64", with: "amd64"))
            #expect(b.url.lastPathComponent == b.fileName)
            #expect(b.checksumsURL == a.checksumsURL)
            #expect(b.checksum == a.checksum)
            #expect(b.maxBytes == a.maxBytes)
            #expect(b.signature == a.signature)
            #expect(b.distribution == a.distribution)
        }
    }

    @Test func sameIdsBothArchitectures() {
        #expect(CloudImageCatalog.all(for: .x86_64).map(\.id) == CloudImageCatalog.all(for: .arm64).map(\.id))
        for distribution in LinuxDistribution.allCases {
            #expect(CloudImageCatalog.image(id: distribution.rawValue, architecture: .x86_64)?.id == distribution.rawValue)
            #expect(distribution.image(for: .x86_64).fileName != distribution.image(for: .arm64).fileName)
        }
        #expect(CloudImageCatalog.image(id: "nope", architecture: .x86_64) == nil)
    }

    @Test func debianAmd64HasManifest() throws {
        let debian = try #require(CloudImageCatalog.image(id: "debian-13", architecture: .x86_64))
        let manifest = try #require(debian.manifest)
        #expect(manifest.fileName == "debian-13-genericcloud-amd64.json")
        #expect(manifest.url.absoluteString
            == "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.json")
        #expect(manifest.imageFormat == "raw")
        #expect(CloudImageCatalog.image(id: "ubuntu-24.04", architecture: .x86_64)?.manifest == nil)
    }

    @Test func defaultArchitectureIsTheHost() {
        #expect(CloudImageCatalog.image(id: "debian-13")?.fileName
            == CloudImageCatalog.image(id: "debian-13", architecture: HostPlatform.current.architecture)?.fileName)
        #expect(LinuxDistribution.debian13.image == LinuxDistribution.debian13.image(for: HostPlatform.current.architecture))
    }
}
