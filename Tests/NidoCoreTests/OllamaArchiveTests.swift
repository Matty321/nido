// SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Foundation
import Testing
@testable import NidoCore

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func releaseJSON(
    version: String = "0.40.10", file: String = "ollama-linux-arm64.tar.zst",
    url: String = "https://github.com/ollama/ollama/releases/download/v0.40.10/ollama-linux-arm64.tar.zst",
    size: String = "1564567595",
    sha: String = "57dca26f51efc050112b733a65dea6f6c8e68da7a2946afd7c1eb8834d9eeb92"
) -> Data {
    Data("""
        {"version": "\(version)", "file": "\(file)", "url": "\(url)", "size": \(size), "sha256": "\(sha)",
         "architecture": "aarch64", "checked": "2026-10-24"}
        """.utf8)
}

@Suite struct OllamaReleaseTests {
    /// The host downloads exactly what the Guest Tools pin (their `ollama/release.json`).
    @Test func pinnedReleaseIsTheGuestToolsOne() throws {
        let pinned = OllamaRelease.pinned
        #expect(pinned.version == "0.40.10")
        #expect(pinned.file == "ollama-linux-arm64.tar.zst")
        #expect(pinned.size == 1_564_567_595)
        #expect(pinned.sha256 == "57dca26f51efc050112b733a65dea6f6c8e68da7a2946afd7c1eb8834d9eeb92")
        #expect(pinned.url.absoluteString
            == "https://github.com/ollama/ollama/releases/download/v0.40.10/ollama-linux-arm64.tar.zst")
        #expect(try OllamaRelease.parse(releaseJSON()) == pinned)
    }

    @Test func doubtfulReleasesAreRefused() {
        let bad: [Data] = [
            releaseJSON(url: "http://github.com/ollama/ollama/releases/download/v0.40.10/x"),
            releaseJSON(url: "https://example.com/ollama/ollama/releases/download/v0.40.10/x"),
            releaseJSON(url: "https://github.com/someone/ollama/releases/download/v0.40.10/x"),
            releaseJSON(url: "https://user@github.com/ollama/ollama/releases/download/v0.40.10/x"),
            releaseJSON(url: "https://github.com:8443/ollama/ollama/releases/download/v0.40.10/x"),
            releaseJSON(file: "../evil"),
            releaseJSON(file: ".hidden"),
            releaseJSON(version: "0.40.10/x"),
            releaseJSON(size: "0"),
            releaseJSON(size: "-1"),
            releaseJSON(size: "17179869185"),
            releaseJSON(sha: "XYZ"),
            releaseJSON(sha: String(repeating: "A", count: 64)),
            Data("not json".utf8),
            Data("{}".utf8),
        ]
        for data in bad {
            #expect(throws: NidoError.self, "\(String(decoding: data, as: UTF8.self))") {
                try OllamaRelease.parse(data)
            }
        }
    }
}

/// The archive store shares `StubURLProtocol` with the image store, so its tests run in that
/// serialized suite.
extension ImageStoreTests {
    func archiveRelease(_ payload: Data, sha: String? = nil) throws -> OllamaRelease {
        try OllamaRelease.parse(releaseJSON(
            version: "9.9.9",
            url: "https://github.com/ollama/ollama/releases/download/v9.9.9/ollama-linux-arm64.tar.zst",
            size: String(payload.count), sha: sha ?? sha256(payload)))
    }

    /// Downloaded on the Mac through GitHub's redirect, checked against the pinned SHA-256 and
    /// size, published 0600 in a 0700 cache; the next call uses the cache without the network.
    @Test func ollamaArchiveIsDownloadedVerifiedAndCached() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let payload = Data(repeating: 0x5A, count: 300_000)
        let release = try archiveRelease(payload)
        let mirror = URL(string: "https://release-assets.githubusercontent.com/x/ollama?sig=1")!
        StubURLProtocol.reset(routes: [
            release.url.absoluteString: .redirect(mirror),
            mirror.absoluteString: .ok(payload),
        ])
        let cache = tmp.appendingPathComponent("ollama")
        let store = OllamaArchiveStore(cacheRoot: cache, session: makeSession())
        let progress = ProgressLog()
        let url = try await store.ensureArchive(release) { progress.append($0) }
        #expect(url.deletingLastPathComponent().standardizedFileURL == cache.standardizedFileURL)
        #expect(try Data(contentsOf: url) == payload)
        #expect(try perms(url) == 0o600)
        #expect(try perms(cache) == 0o700)
        #expect(listing(cache) == [url.lastPathComponent])
        #expect(progress.all.last?.receivedBytes == UInt64(payload.count))
        #expect(StubURLProtocol.requests.count == 2)

        _ = try await store.ensureArchive(release)
        #expect(StubURLProtocol.requests.count == 2)

        // A damaged cached copy is a miss: downloaded again.
        try Data("damaged".utf8).write(to: url)
        #expect(try await store.ensureArchive(release) == url)
        #expect(try Data(contentsOf: url) == payload)
        #expect(StubURLProtocol.requests.count == 4)
    }

    @Test func ollamaArchiveWithAnotherChecksumIsNeverPublished() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let payload = Data(repeating: 0x5A, count: 4096)
        let release = try archiveRelease(payload, sha: String(repeating: "0", count: 64))
        StubURLProtocol.reset(routes: [release.url.absoluteString: .ok(payload)])
        let cache = tmp.appendingPathComponent("ollama")
        let store = OllamaArchiveStore(cacheRoot: cache, session: makeSession())
        await #expect(throws: NidoError.checksumMismatch(expected: release.sha256, actual: sha256(payload))) {
            _ = try await store.ensureArchive(release)
        }
        #expect(listing(cache).isEmpty)
    }

    @Test func ollamaArchiveLargerThanPinnedOrRedirectedToHTTPIsRefused() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let payload = Data(repeating: 0x5A, count: 4096)
        let release = try archiveRelease(payload)
        let cache = tmp.appendingPathComponent("ollama")
        let store = OllamaArchiveStore(cacheRoot: cache, session: makeSession())

        StubURLProtocol.reset(routes: [release.url.absoluteString: .ok(payload + Data([0]))])
        await #expect(throws: NidoError.self) { _ = try await store.ensureArchive(release) }
        #expect(listing(cache).isEmpty)

        StubURLProtocol.reset(routes: [release.url.absoluteString: .ok(payload.prefix(100))])
        await #expect(throws: NidoError.self) { _ = try await store.ensureArchive(release) }
        #expect(listing(cache).isEmpty)

        let plain = URL(string: "http://release-assets.githubusercontent.com/x")!
        StubURLProtocol.reset(routes: [release.url.absoluteString: .redirect(plain), plain.absoluteString: .ok(payload)])
        await #expect(throws: NidoError.hostNotAllowed(plain.absoluteString)) { _ = try await store.ensureArchive(release) }
        #expect(listing(cache).isEmpty)
        #expect(!StubURLProtocol.requests.contains(plain))
    }
}

extension ImageStoreTests {
    /// GitHub's redirect may only lead to GitHub's own download hosts (HTTPS): never to another
    /// host, even with the right checksum.
    @Test func ollamaArchiveRedirectOutsideGitHubIsRefused() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let payload = Data(repeating: 0x5A, count: 4096)
        let release = try archiveRelease(payload)
        let cache = tmp.appendingPathComponent("ollama")
        let store = OllamaArchiveStore(cacheRoot: cache, session: makeSession())
        for target in ["https://example.com/ollama.tar.zst", "https://githubusercontent.com.example.com/x",
                       "https://user@objects.githubusercontent.com/x", "https://objects.githubusercontent.com:8443/x"] {
            let other = URL(string: target)!
            StubURLProtocol.reset(routes: [release.url.absoluteString: .redirect(other), other.absoluteString: .ok(payload)])
            await #expect(throws: NidoError.hostNotAllowed(other.absoluteString)) {
                _ = try await store.ensureArchive(release)
            }
            #expect(!StubURLProtocol.requests.contains(other))
            #expect(listing(cache).isEmpty)
        }
        #expect(throws: Never.self) {
            try OllamaArchiveStore.validateRedirect(URL(string: "https://github.com/ollama/x")!)
            try OllamaArchiveStore.validateRedirect(URL(string: "https://objects.githubusercontent.com/x")!)
            try OllamaArchiveStore.validateRedirect(URL(string: "https://RELEASE-ASSETS.githubusercontent.com:443/x")!)
        }
    }

    /// Parts left by an interrupted download (another run, a crash) are removed when the store is
    /// used again: only regular files named like the store's own parts and not written for a
    /// while. A link with that name, a fresh part (maybe another process downloading now) and
    /// other files stay.
    @Test func staleOllamaPartsAreSwept() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let payload = Data(repeating: 0x5A, count: 4096)
        let release = try archiveRelease(payload)
        let cache = tmp.appendingPathComponent("ollama")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let old = Date(timeIntervalSinceNow: -2 * OllamaArchiveStore.stalePartAge)
        func part(_ version: String) -> URL {
            cache.appendingPathComponent(".\(version)-ollama-linux-arm64.tar.zst.\(UUID().uuidString).part")
        }
        let stale = [part("9.9.9"), part("0.1.0")]
        for url in stale {
            try Data("partial".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
        let fresh = part("9.9.9")
        try Data("in corso".utf8).write(to: fresh)
        let target = tmp.appendingPathComponent("target")
        try Data("keep".utf8).write(to: target)
        let link = part("9.9.9")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let other = cache.appendingPathComponent("notes.part")
        try Data("x".utf8).write(to: other)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: other.path)

        StubURLProtocol.reset(routes: [release.url.absoluteString: .ok(payload)])
        let store = OllamaArchiveStore(cacheRoot: cache, session: makeSession())
        let url = try await store.ensureArchive(release)
        let names = Set(listing(cache))
        for url in stale { #expect(!names.contains(url.lastPathComponent)) }
        #expect(names == [url.lastPathComponent, fresh.lastPathComponent, link.lastPathComponent, other.lastPathComponent])
        #expect(try Data(contentsOf: target) == Data("keep".utf8))
    }

    /// Two installs at once (two VMs) share one download; both get the file and its progress.
    @Test func concurrentOllamaArchivesShareOneDownload() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let payload = Data(repeating: 0x5A, count: 50_000)
        let release = try archiveRelease(payload)
        StubURLProtocol.reset(routes: [release.url.absoluteString: .held(payload)])
        let cache = tmp.appendingPathComponent("ollama")
        let store = OllamaArchiveStore(cacheRoot: cache, session: makeSession())
        let firstLog = ProgressLog()
        let secondLog = ProgressLog()
        async let first = store.ensureArchive(release) { firstLog.append($0) }
        await StubURLProtocol.waitUntilHeld()
        async let second = store.ensureArchive(release) { secondLog.append($0) }
        for _ in 0..<10_000 where await store.waiterCount(release) < 2 {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await store.waiterCount(release) == 2)
        StubURLProtocol.release()
        let (a, b) = try await (first, second)
        #expect(a == b)
        #expect(try Data(contentsOf: a) == payload)
        #expect(StubURLProtocol.requests.filter { $0 == release.url }.count == 1)
        #expect(firstLog.all.last?.receivedBytes == UInt64(payload.count))
        #expect(secondLog.all.last?.receivedBytes == UInt64(payload.count))
        #expect(await store.waiterCount(release) == 0)
    }

    /// One caller cancelling leaves the other's download running; the last one cancelling stops
    /// it and removes its part.
    @Test func cancellingOneOllamaWaiterKeepsTheSharedDownload() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let payload = Data(repeating: 0x5A, count: 50_000)
        let release = try archiveRelease(payload)
        StubURLProtocol.reset(routes: [release.url.absoluteString: .held(payload)])
        let cache = tmp.appendingPathComponent("ollama")
        let store = OllamaArchiveStore(cacheRoot: cache, session: makeSession())
        let first = Task { try await store.ensureArchive(release) }
        await StubURLProtocol.waitUntilHeld()
        let second = Task { try await store.ensureArchive(release) }
        for _ in 0..<10_000 where await store.waiterCount(release) < 2 {
            try await Task.sleep(for: .milliseconds(1))
        }
        first.cancel()
        await #expect(throws: CancellationError.self) { _ = try await first.value }
        StubURLProtocol.release()
        #expect(try Data(contentsOf: try await second.value) == payload)

        StubURLProtocol.reset(routes: [release.url.absoluteString: .held(payload)])
        try FileManager.default.removeItem(at: cache)
        let only = Task { try await store.ensureArchive(release) }
        await StubURLProtocol.waitUntilHeld()
        only.cancel()
        await #expect(throws: CancellationError.self) { _ = try await only.value }
        #expect(listing(cache).isEmpty)
    }
}
