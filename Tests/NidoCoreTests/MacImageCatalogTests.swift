// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCore

/// A catalog that answers with a fixed offer and counts its calls (what the CLI and app tests use).
private final class FakeCatalog: MacImageCataloging, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let offer: MacImageOffer

    init(offer: MacImageOffer) { self.offer = offer }

    var calls: Int { lock.withLock { count } }

    func latestSupported() async throws(NidoError) -> MacImageOffer {
        lock.withLock { count += 1 }
        return offer
    }
}

private struct FetchFailure: Error, LocalizedError {
    var errorDescription: String? { "offline" }
}

@Suite(.italian) struct MacImageCatalogTests {
    static let appleURL = URL(string:
        "https://updates.cdn-apple.com/2026FallFCS/fullrestores/093-12345/ABCDEF/UniversalMac_27.2.1_26B131_Restore.ipsw")!

    static func fetched(_ url: URL = appleURL) -> LiveMacImageCatalog.Fetched {
        LiveMacImageCatalog.Fetched(
            buildVersion: "26B131",
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 1),
            url: url)
    }

    @Test func offerFileNameIsTheURLsLastComponent() {
        let offer = MacImageOffer(build: "26B131", version: "27.2.1", url: Self.appleURL)
        #expect(offer.fileName == "UniversalMac_27.2.1_26B131_Restore.ipsw")
    }

    @Test func fakeCatalogAnswersItsOffer() async throws {
        let offer = MacImageOffer(build: "26B131", version: "27.2.1", url: Self.appleURL)
        let catalog = FakeCatalog(offer: offer)
        #expect(try await catalog.latestSupported() == offer)
        #expect(catalog.calls == 1)
    }

    @Test func liveCatalogTurnsVirtualizationsAnswerIntoAnOffer() async throws {
        let catalog = LiveMacImageCatalog(fetch: { Self.fetched() })
        let offer = try await catalog.latestSupported()
        #expect(offer == MacImageOffer(build: "26B131", version: "27.2.1", url: Self.appleURL))
    }

    @Test func liveCatalogWritesAZeroPatchVersionShort() async throws {
        let catalog = LiveMacImageCatalog(fetch: {
            LiveMacImageCatalog.Fetched(
                buildVersion: "26A100",
                operatingSystemVersion: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0),
                url: Self.appleURL)
        })
        #expect(try await catalog.latestSupported().version == "27.0")
    }

    @Test(arguments: [
        "https://evil.example/UniversalMac_27.2.1_26B131_Restore.ipsw",
        "http://updates.cdn-apple.com/UniversalMac_27.2.1_26B131_Restore.ipsw",
        "https://updates.cdn-apple.com.evil.net/UniversalMac_27.2.1_26B131_Restore.ipsw",
    ])
    func liveCatalogRefusesANonAppleURL(_ raw: String) async throws {
        let url = try #require(URL(string: raw))
        let catalog = LiveMacImageCatalog(fetch: { Self.fetched(url) })
        await #expect(throws: NidoError.hostNotAllowed(url.absoluteString)) {
            try await catalog.latestSupported()
        }
    }

    @Test func liveCatalogFailureIsADownloadFailure() async throws {
        let catalog = LiveMacImageCatalog(fetch: { throw FetchFailure() })
        let error = await #expect(throws: NidoError.self) { try await catalog.latestSupported() }
        #expect(error == .downloadFailed("non è stato possibile chiedere ad Apple quale macOS supporta questo Mac (offline)"))
    }
}
