// SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import NidoCore

/// In-process HTTP stub: a static, lock-protected routing table and request log.
final class StubURLProtocol: URLProtocol {
    enum Route: Sendable {
        case ok(Data)
        /// 200 with an explicit `Content-Length` header (may differ from the body).
        case okDeclaring(Data, contentLength: Int)
        /// 200 without `Content-Length`, body delivered in several chunks.
        case chunks([Data])
        /// 200 with `Content-Length` and the body in several chunks.
        case chunksDeclaring([Data], contentLength: Int)
        /// Holds the request (no response at all) until `release()`; `stopLoading` (cancel) drops it.
        case held(Data)
        case status(Int)
        case redirect(URL)
    }

    /// Lets a test release a held request from outside the protocol instance.
    private final class Pending: @unchecked Sendable {
        let proto: StubURLProtocol
        let data: Data
        init(_ proto: StubURLProtocol, _ data: Data) { self.proto = proto; self.data = data }
    }

    private struct State {
        var routes: [String: Route] = [:]
        var log: [URL] = []
        var pending: [Pending] = []
        var held = 0
        var heldWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private static let state = Mutex(State())

    static func reset(routes: [String: Route] = [:]) {
        state.withLock { $0 = State(routes: routes, log: []) }
    }

    /// Suspends until a request on a `.held` route has arrived.
    static func waitUntilHeld() async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { s -> Bool in
                if s.held > 0 { return true }
                s.heldWaiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    /// Answers every held request with 200 and its body.
    static func release() {
        let items = state.withLock { s -> [Pending] in
            defer { s.pending = [] }
            return s.pending
        }
        for item in items {
            let url = item.proto.request.url!
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": String(item.data.count)])!
            item.proto.client?.urlProtocol(item.proto, didReceive: response, cacheStoragePolicy: .notAllowed)
            item.proto.client?.urlProtocol(item.proto, didLoad: item.data)
            item.proto.client?.urlProtocolDidFinishLoading(item.proto)
        }
    }

    static var requests: [URL] { state.withLock { $0.log } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let route = Self.state.withLock { s -> Route? in
            s.log.append(url)
            return s.routes[url.absoluteString]
        }
        switch route ?? .status(404) {
        case .ok(let data):
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .okDeclaring(let data, let length):
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": String(length)])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .chunks(let parts):
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for part in parts { client?.urlProtocol(self, didLoad: part) }
            client?.urlProtocolDidFinishLoading(self)
        case .chunksDeclaring(let parts, let length):
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": String(length)])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for part in parts { client?.urlProtocol(self, didLoad: part) }
            client?.urlProtocolDidFinishLoading(self)
        case .held(let data):
            let waiters = Self.state.withLock { s -> [CheckedContinuation<Void, Never>] in
                s.pending.append(Pending(self, data))
                s.held += 1
                defer { s.heldWaiters = [] }
                return s.heldWaiters
            }
            for waiter in waiters { waiter.resume() }
        case .status(let code):
            let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let target):
            let response = HTTPURLResponse(
                url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        Self.state.withLock { s in s.pending.removeAll { $0.proto === self } }
    }
}

final class ProgressLog: Sendable {
    private let values = Mutex<[DownloadProgress]>([])
    func append(_ p: DownloadProgress) { values.withLock { $0.append(p) } }
    var all: [DownloadProgress] { values.withLock { $0 } }
}

/// Holds a hash in progress until `open()`; tells the test when one has started.
final class HashGate: Sendable {
    private let state = Mutex((entered: 0, open: false))

    func enterAndWait() {
        state.withLock { $0.entered += 1 }
        while !state.withLock({ $0.open }) { usleep(1_000) }
    }

    /// Waits (bounded) until `count` hashes are in progress.
    func waitUntilEntered(_ count: Int = 1) async throws {
        for _ in 0..<5_000 where state.withLock({ $0.entered }) < count {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(state.withLock { $0.entered } >= count)
    }

    func open() { state.withLock { $0.open = true } }
}

final class CallCounter: Sendable {
    private let count = Mutex(0)
    func increment() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}

@Suite(.serialized, .italian) struct ImageStoreTests {
    /// The catalog's Debian image without its build manifest: the download itself (the manifest
    /// has its own tests, `DebianManifestStoreTests`).
    let image = CloudImage(
        id: CloudImageCatalog.debian13.id, fileName: CloudImageCatalog.debian13.fileName,
        url: CloudImageCatalog.debian13.url, checksumsURL: CloudImageCatalog.debian13.checksumsURL,
        maxBytes: CloudImageCatalog.debian13.maxBytes)
    let payload = Data("nido fake raw image\n".utf8)

    func makeTemp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-imgtest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    func hex(_ data: Data) -> String {
        SHA512.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func sums(_ digest: String, name: String) -> Data {
        Data("\(digest)  \(name)\n".utf8)
    }

    func perms(_ url: URL) throws -> Int {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        return (a[.posixPermissions] as! NSNumber).intValue
    }

    func listing(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    func validRoutes() -> [String: StubURLProtocol.Route] {
        [
            image.checksumsURL.absoluteString: .ok(sums(hex(payload), name: image.fileName)),
            image.url.absoluteString: .ok(payload),
        ]
    }

    @Test func declinedConfirmMakesNoRequests() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        StubURLProtocol.reset(routes: validRoutes())
        let cache = tmp.appendingPathComponent("images")
        let store = ImageStore(cacheRoot: cache, session: makeSession())
        let calls = CallCounter()
        await #expect(throws: NidoError.downloadDeclined) {
            _ = try await store.ensureImage(image) { _ in calls.increment(); return false }
        }
        #expect(calls.value == 1)
        #expect(StubURLProtocol.requests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    @Test func verifiedDownloadIsCachedWithStrictPermissions() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        StubURLProtocol.reset(routes: validRoutes())
        let cache = tmp.appendingPathComponent("Caches/Nido/images")
        let store = ImageStore(cacheRoot: cache, session: makeSession())
        let url = try await store.ensureImage(image) { _ in true }
        #expect(url.standardizedFileURL == cache.appendingPathComponent(image.fileName).standardizedFileURL)
        #expect(try Data(contentsOf: url) == payload)
        #expect(try perms(url) == 0o600)
        #expect(try perms(cache.appendingPathComponent(image.fileName + ".sha512")) == 0o600)
        #expect(try perms(cache) == 0o700)
        #expect(try perms(tmp.appendingPathComponent("Caches/Nido")) == 0o700)
        #expect(try perms(tmp.appendingPathComponent("Caches")) == 0o700)
        #expect(listing(cache) == [image.fileName, image.fileName + ".sha512"].sorted())
        #expect(StubURLProtocol.requests == [image.checksumsURL, image.url])
    }

    @Test func checksumMismatchLeavesNoFiles() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let wrong = hex(Data("something else".utf8))
        StubURLProtocol.reset(routes: [
            image.checksumsURL.absoluteString: .ok(sums(wrong, name: image.fileName)),
            image.url.absoluteString: .ok(payload),
        ])
        let cache = tmp.appendingPathComponent("images")
        let store = ImageStore(cacheRoot: cache, session: makeSession())
        await #expect(throws: NidoError.checksumMismatch(expected: wrong, actual: hex(payload))) {
            _ = try await store.ensureImage(image) { _ in true }
        }
        #expect(listing(cache).isEmpty)
    }

    @Test func imageRedirectToHTTPSMirrorIsAcceptedAndVerified() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let mirror = URL(string: "https://mirror.example/debian/x.raw")!
        var routes = validRoutes()
        routes[image.url.absoluteString] = .redirect(mirror)
        routes[mirror.absoluteString] = .ok(payload)
        StubURLProtocol.reset(routes: routes)
        let cache = tmp.appendingPathComponent("images")
        let store = ImageStore(cacheRoot: cache, session: makeSession())
        let url = try await store.ensureImage(image) { _ in true }
        #expect(try Data(contentsOf: url) == payload)
        #expect(StubURLProtocol.requests == [image.checksumsURL, image.url, mirror])
        #expect(listing(cache) == [image.fileName, image.fileName + ".sha512"].sorted())
    }

    @Test func imageFromMirrorWithWrongContentFailsVerification() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let mirror = URL(string: "https://mirror.example/debian/x.raw")!
        let tampered = Data("tampered".utf8)
        var routes = validRoutes()
        routes[image.url.absoluteString] = .redirect(mirror)
        routes[mirror.absoluteString] = .ok(tampered)
        StubURLProtocol.reset(routes: routes)
        let cache = tmp.appendingPathComponent("images")
        let store = ImageStore(cacheRoot: cache, session: makeSession())
        await #expect(throws: NidoError.checksumMismatch(expected: hex(payload), actual: hex(tampered))) {
            _ = try await store.ensureImage(image) { _ in true }
        }
        #expect(listing(cache).isEmpty)
    }

    @Test(arguments: [
        "http://mirror.example/x.raw",
        "https://user@mirror.example/x.raw",
        "https://user:pw@mirror.example/x.raw",
        "https://mirror.example:8443/x.raw",
    ])
    func unsafeImageRedirectIsRejected(_ raw: String) async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let target = try #require(URL(string: raw))
        var routes = validRoutes()
        routes[image.url.absoluteString] = .redirect(target)
        routes[target.absoluteString] = .ok(payload)
        StubURLProtocol.reset(routes: routes)
        let cache = tmp.appendingPathComponent("images")
        let store = ImageStore(cacheRoot: cache, session: makeSession())
        await #expect(throws: NidoError.hostNotAllowed(target.absoluteString)) {
            _ = try await store.ensureImage(image) { _ in true }
        }
        #expect(!StubURLProtocol.requests.contains(target))
        #expect(listing(cache).isEmpty)
    }

    @Test func downloadSessionHasNoDiskCache() {
        let config = ImageStore.makeDownloadSession().configuration
        #expect(config.urlCache == nil)
        #expect(config.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(config.timeoutIntervalForRequest == 60)
        #expect(config.timeoutIntervalForResource == 6 * 60 * 60)
    }

    @Test func redirectOnChecksumsToForeignHostIsRejected() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let evil = URL(string: "https://evil.example/SHA512SUMS")!
        var routes = validRoutes()
        routes[image.checksumsURL.absoluteString] = .redirect(evil)
        StubURLProtocol.reset(routes: routes)
        let cache = tmp.appendingPathComponent("images")
        let store = ImageStore(cacheRoot: cache, session: makeSession())
        await #expect(throws: NidoError.hostNotAllowed(evil.absoluteString)) {
            _ = try await store.ensureImage(image) { _ in true }
        }
        #expect(StubURLProtocol.requests == [image.checksumsURL])
        #expect(listing(cache).isEmpty)
    }

    @Test func validCacheHitMakesNoRequestsAndSkipsConfirm() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        StubURLProtocol.reset(routes: validRoutes())
        let cache = tmp.appendingPathComponent("images")
        let store = ImageStore(cacheRoot: cache, session: makeSession())
        let first = try await store.ensureImage(image) { _ in true }
        StubURLProtocol.reset(routes: validRoutes())
        let calls = CallCounter()
        let second = try await store.ensureImage(image) { _ in calls.increment(); return true }
        #expect(first == second)
        #expect(calls.value == 0)
        #expect(StubURLProtocol.requests.isEmpty)
    }

    // MARK: - New builds

    @Test func checkForUpdateComparesOnlyTheChecksumList() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let cache = tmp.appendingPathComponent("images")
        let store = ImageStore(cacheRoot: cache, session: makeSession())

        // Nothing cached: no request at all.
        StubURLProtocol.reset(routes: validRoutes())
        #expect(try await store.checkForUpdate(image) == .notCached)
        #expect(!(await store.isCached(image)))
        #expect(StubURLProtocol.requests.isEmpty)

        _ = try await store.ensureImage(image) { _ in true }
        #expect(await store.isCached(image))

        // Same build published: only the list is fetched, never the image.
        StubURLProtocol.reset(routes: validRoutes())
        #expect(try await store.checkForUpdate(image) == .current)
        #expect(StubURLProtocol.requests == [image.checksumsURL])

        // A new build: another digest in the list.
        let newBuild = Data("nido fake raw image, new build\n".utf8)
        let newRoutes: [String: StubURLProtocol.Route] = [
            image.checksumsURL.absoluteString: .ok(sums(hex(newBuild), name: image.fileName)),
            image.url.absoluteString: .ok(newBuild),
        ]
        StubURLProtocol.reset(routes: newRoutes)
        #expect(try await store.checkForUpdate(image) == .updateAvailable)

        // Without `refresh` the cached build is kept; with it the new one replaces it.
        StubURLProtocol.reset(routes: newRoutes)
        let kept = try await store.ensureImage(image) { _ in true }
        #expect(try Data(contentsOf: kept) == payload)
        #expect(StubURLProtocol.requests.isEmpty)
        let calls = CallCounter()
        let updated = try await store.ensureImage(image, refresh: true) { _ in calls.increment(); return true }
        #expect(calls.value == 1)
        #expect(try Data(contentsOf: updated) == newBuild)
        StubURLProtocol.reset(routes: newRoutes)
        #expect(try await store.checkForUpdate(image) == .current)

        // A declined refresh keeps the cached copy.
        StubURLProtocol.reset(routes: validRoutes())
        await #expect(throws: NidoError.downloadDeclined) {
            _ = try await store.ensureImage(image, refresh: true) { _ in false }
        }
        #expect(try Data(contentsOf: updated) == newBuild)
    }

    /// A cache check that read the old image while a refresh published the new one checks again
    /// instead of downloading a second time.
    @Test func checkOverlappingAPublicationRechecksInsteadOfDownloadingAgain() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let cache = tmp.appendingPathComponent("images")
        StubURLProtocol.reset(routes: validRoutes())
        _ = try await ImageStore(cacheRoot: cache, session: makeSession()).ensureImage(image) { _ in true }

        let newBuild = Data("nido fake raw image, new build\n".utf8)
        StubURLProtocol.reset(routes: [
            image.checksumsURL.absoluteString: .ok(sums(hex(newBuild), name: image.fileName)),
            image.url.absoluteString: .ok(newBuild),
        ])
        let gate = HashGate()
        let hashes = CallCounter()
        let oldDigest = hex(payload)
        let reads = CallCounter()
        // First check: the sidecar is read after the publication (new digest), the image was
        // hashed before it (old digest).
        let store = ImageStore(cacheRoot: cache, session: makeSession(), hashFile: { url in
            hashes.increment()
            return hashes.value > 1 ? try Checksums.sha512(of: url) : oldDigest
        }, readDigest: { url in
            reads.increment()
            if reads.value == 1 { gate.enterAndWait() }
            return try String(contentsOf: url, encoding: .utf8)
        })
        let image = self.image
        let checking = Task { try await store.ensureImage(image) { _ in true } }
        try await gate.waitUntilEntered()
        _ = try await store.ensureImage(image, refresh: true) { _ in true }
        gate.open()
        let url = try await checking.value
        #expect(try Data(contentsOf: url) == newBuild)
        #expect(StubURLProtocol.requests == [image.checksumsURL, image.url], "Un solo download")
        #expect(hashes.value == 2, "\(hashes.value)")
    }

    /// Ubuntu: the checksum list is read only after its OpenPGP signature verified with the
    /// built-in key (real `SHA256SUMS` and `SHA256SUMS.gpg` of 26.04).
    @Test func ubuntuListIsUsedOnlyWithAValidSignature() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let cache = tmp.appendingPathComponent("images")
        let ubuntu = CloudImageCatalog.ubuntu2604
        let signatureURL = try #require(ubuntu.signature?.url)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: cache.appendingPathComponent(ubuntu.fileName))
        try Data((String(repeating: "0", count: 64) + "\n").utf8).write(to: cache.appendingPathComponent(ubuntu.sidecarName))
        let store = ImageStore(cacheRoot: cache, session: makeSession())

        StubURLProtocol.reset(routes: [
            ubuntu.checksumsURL.absoluteString: .ok(OpenPGPSignatureTests.sums),
            signatureURL.absoluteString: .ok(OpenPGPSignatureTests.signature),
        ])
        #expect(try await store.checkForUpdate(ubuntu) == .updateAvailable)
        #expect(StubURLProtocol.requests == [ubuntu.checksumsURL, signatureURL])

        // A list changed in transit, a missing signature: refused, nothing compared.
        var tampered = OpenPGPSignatureTests.sums
        tampered[200] ^= 0x01
        StubURLProtocol.reset(routes: [
            ubuntu.checksumsURL.absoluteString: .ok(tampered),
            signatureURL.absoluteString: .ok(OpenPGPSignatureTests.signature),
        ])
        await #expect(throws: NidoError.downloadFailed("firma della lista dei checksum non valida")) {
            _ = try await store.checkForUpdate(ubuntu)
        }
        StubURLProtocol.reset(routes: [ubuntu.checksumsURL.absoluteString: .ok(OpenPGPSignatureTests.sums)])
        await #expect(throws: (any Error).self) { _ = try await store.checkForUpdate(ubuntu) }

        // A download stops before the image: nothing is fetched after a bad signature.
        StubURLProtocol.reset(routes: [
            ubuntu.checksumsURL.absoluteString: .ok(tampered),
            signatureURL.absoluteString: .ok(OpenPGPSignatureTests.signature),
            ubuntu.url.absoluteString: .ok(payload),
        ])
        await #expect(throws: NidoError.downloadFailed("firma della lista dei checksum non valida")) {
            _ = try await store.ensureImage(ubuntu, refresh: true) { _ in true }
        }
        #expect(!StubURLProtocol.requests.contains(ubuntu.url))
    }

    @Test func olderSignedListIsRefusedAsAReplay() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let cache = tmp.appendingPathComponent("images")
        let ubuntu = CloudImageCatalog.ubuntu2604
        let signatureURL = try #require(ubuntu.signature?.url)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: cache.appendingPathComponent(ubuntu.fileName))
        try Data((String(repeating: "0", count: 64) + "\n").utf8).write(to: cache.appendingPathComponent(ubuntu.sidecarName))
        let record = cache.appendingPathComponent(ubuntu.fileName + ".signed")
        let created = Int64(try OpenPGPSignature.verify(
            OpenPGPSignatureTests.signature, of: OpenPGPSignatureTests.sums, key: UbuntuCloudImageKey.key
        ).timeIntervalSince1970)
        let store = ImageStore(cacheRoot: cache, session: makeSession())
        let routes: [String: StubURLProtocol.Route] = [
            ubuntu.checksumsURL.absoluteString: .ok(OpenPGPSignatureTests.sums),
            signatureURL.absoluteString: .ok(OpenPGPSignatureTests.signature),
        ]

        // First time: accepted and recorded; the same list again is still fine.
        StubURLProtocol.reset(routes: routes)
        #expect(try await store.checkForUpdate(ubuntu) == .updateAvailable)
        #expect(try String(contentsOf: record, encoding: .utf8) == "\(created)\n")
        StubURLProtocol.reset(routes: routes)
        #expect(try await store.checkForUpdate(ubuntu) == .updateAvailable)

        // A list signed before the last one accepted: refused, before the image, record kept.
        try Data("\(created + 86_400)\n".utf8).write(to: record)
        StubURLProtocol.reset(routes: routes.merging([ubuntu.url.absoluteString: .ok(payload)]) { $1 })
        await #expect(throws: NidoError.self) { _ = try await store.checkForUpdate(ubuntu) }
        do {
            _ = try await store.ensureImage(ubuntu, refresh: true) { _ in true }
            Issue.record("an older list must be refused")
        } catch NidoError.downloadFailed(let reason) {
            #expect(reason.hasPrefix("lista dei checksum firmata il "))
            #expect(reason.contains("può essere una copia vecchia riproposta"))
        }
        #expect(!StubURLProtocol.requests.contains(ubuntu.url))
        #expect(try String(contentsOf: record, encoding: .utf8) == "\(created + 86_400)\n")

        // A newer one moves the record forward; an unreadable record counts as a first time.
        try Data("\(created - 86_400)\n".utf8).write(to: record)
        StubURLProtocol.reset(routes: routes)
        #expect(try await store.checkForUpdate(ubuntu) == .updateAvailable)
        #expect(try String(contentsOf: record, encoding: .utf8) == "\(created)\n")
        try Data("garbage".utf8).write(to: record)
        StubURLProtocol.reset(routes: routes)
        #expect(try await store.checkForUpdate(ubuntu) == .updateAvailable)
        #expect(try String(contentsOf: record, encoding: .utf8) == "\(created)\n")
    }

    @Test func checkForUpdateFailsWithoutAnEntryOrOnHTTPError() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let cache = tmp.appendingPathComponent("images")
        let store = ImageStore(cacheRoot: cache, session: makeSession())
        StubURLProtocol.reset(routes: validRoutes())
        _ = try await store.ensureImage(image) { _ in true }

        StubURLProtocol.reset(routes: [image.checksumsURL.absoluteString: .ok(sums(hex(payload), name: "other.raw"))])
        await #expect(throws: NidoError.downloadFailed("checksum mancante per \(image.fileName)")) {
            _ = try await store.checkForUpdate(image)
        }
        StubURLProtocol.reset(routes: [image.checksumsURL.absoluteString: .status(500)])
        await #expect(throws: (any Error).self) { _ = try await store.checkForUpdate(image) }

        // A malformed sidecar counts as not cached.
        try Data("not a digest".utf8).write(to: cache.appendingPathComponent(image.sidecarName))
        #expect(try await store.checkForUpdate(image) == .notCached)
    }

    @Test func corruptedCacheIsRedownloaded() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        StubURLProtocol.reset(routes: validRoutes())
        let cache = tmp.appendingPathComponent("images")
        let store = ImageStore(cacheRoot: cache, session: makeSession())
        let url = try await store.ensureImage(image) { _ in true }
        try Data("tampered".utf8).write(to: url)
        StubURLProtocol.reset(routes: validRoutes())
        let calls = CallCounter()
        let again = try await store.ensureImage(image) { _ in calls.increment(); return true }
        #expect(calls.value == 1)
        #expect(try Data(contentsOf: again) == payload)
        #expect(StubURLProtocol.requests == [image.checksumsURL, image.url])
    }

    @Test func disallowedImageURLMakesNoRequests() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        StubURLProtocol.reset(routes: validRoutes())
        let bad = CloudImage(
            id: "bad", fileName: "bad.raw",
            url: URL(string: "http://cloud.debian.org/bad.raw")!,
            checksumsURL: image.checksumsURL, maxBytes: 1 << 20)
        let store = ImageStore(cacheRoot: tmp.appendingPathComponent("images"), session: makeSession())
        await #expect(throws: NidoError.hostNotAllowed("http://cloud.debian.org/bad.raw")) {
            _ = try await store.ensureImage(bad) { _ in true }
        }
        #expect(StubURLProtocol.requests.isEmpty)
    }

    @Test func httpErrorStatusFails() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        var routes = validRoutes()
        routes[image.url.absoluteString] = .status(404)
        StubURLProtocol.reset(routes: routes)
        let cache = tmp.appendingPathComponent("images")
        let store = ImageStore(cacheRoot: cache, session: makeSession())
        await #expect(throws: NidoError.downloadFailed("HTTP 404 per \(image.url.absoluteString)")) {
            _ = try await store.ensureImage(image) { _ in true }
        }
        #expect(listing(cache).isEmpty)
    }

    @Test func missingChecksumEntryFails() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        var routes = validRoutes()
        routes[image.checksumsURL.absoluteString] = .ok(sums(hex(payload), name: "other.raw"))
        StubURLProtocol.reset(routes: routes)
        let cache = tmp.appendingPathComponent("images")
        let store = ImageStore(cacheRoot: cache, session: makeSession())
        await #expect(throws: NidoError.downloadFailed("checksum mancante per \(image.fileName)")) {
            _ = try await store.ensureImage(image) { _ in true }
        }
        #expect(StubURLProtocol.requests == [image.checksumsURL])
        #expect(listing(cache).isEmpty)
    }

    @Test func defaultCacheRootIsUnderCaches() {
        let root = ImageStore.defaultCacheRoot()
        #expect(root.path.hasSuffix("Library/Caches/Nido/images"))
    }

    // MARK: - Size caps and streaming

    @Test func catalogImageHasEightGiBCap() {
        #expect(CloudImageCatalog.debian13.maxBytes == 8 << 30)
    }

    /// Same file name and URLs as the catalog image, with a tiny cap.
    func capped(_ maxBytes: UInt64) -> CloudImage {
        CloudImage(
            id: image.id, fileName: image.fileName, url: image.url,
            checksumsURL: image.checksumsURL, maxBytes: maxBytes)
    }

    @Test func declaredContentLengthOverCapIsRejectedBeforeWriting() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        var routes = validRoutes()
        // The body itself is under the cap: only the declared length can trigger the rejection.
        routes[image.url.absoluteString] = .okDeclaring(payload, contentLength: 2 << 20)
        StubURLProtocol.reset(routes: routes)
        let cache = tmp.appendingPathComponent("images")
        let store = ImageStore(cacheRoot: cache, session: makeSession())
        await #expect(throws: NidoError.downloadFailed("immagine oltre il limite di 1 MiB")) {
            _ = try await store.ensureImage(capped(1 << 20)) { _ in true }
        }
        #expect(StubURLProtocol.requests == [image.checksumsURL, image.url])
        #expect(listing(cache).isEmpty)
    }

    @Test func streamExceedingCapIsAbortedAndPartRemoved() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        var routes = validRoutes()
        routes[image.url.absoluteString] = .chunks([Data(repeating: 0x41, count: 600), Data(repeating: 0x42, count: 600)])
        StubURLProtocol.reset(routes: routes)
        let cache = tmp.appendingPathComponent("images")
        let store = ImageStore(cacheRoot: cache, session: makeSession())
        await #expect(throws: NidoError.downloadFailed("immagine oltre il limite di 1000 B")) {
            _ = try await store.ensureImage(capped(1000)) { _ in true }
        }
        #expect(listing(cache).isEmpty)
    }

    @Test func imageExactlyAtCapIsAccepted() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let half = payload.count / 2
        var routes = validRoutes()
        routes[image.url.absoluteString] = .chunks([payload.prefix(half), payload.dropFirst(half)])
        StubURLProtocol.reset(routes: routes)
        let cache = tmp.appendingPathComponent("images")
        let store = ImageStore(cacheRoot: cache, session: makeSession())
        let url = try await store.ensureImage(capped(UInt64(payload.count))) { _ in true }
        #expect(try Data(contentsOf: url) == payload)
        #expect(try perms(url) == 0o600)
        #expect(listing(cache) == [image.fileName, image.fileName + ".sha512"].sorted())
    }

    @Test func oversizedChecksumsFileIsRejected() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        var routes = validRoutes()
        var big = sums(hex(payload), name: image.fileName)
        big.append(Data(repeating: 0x0a, count: 1 << 20))
        routes[image.checksumsURL.absoluteString] = .chunks([big.prefix(1000), big.dropFirst(1000)])
        StubURLProtocol.reset(routes: routes)
        let cache = tmp.appendingPathComponent("images")
        let store = ImageStore(cacheRoot: cache, session: makeSession())
        await #expect(throws: NidoError.downloadFailed("lista dei checksum oltre il limite di 1 MiB")) {
            _ = try await store.ensureImage(image) { _ in true }
        }
        #expect(StubURLProtocol.requests == [image.checksumsURL])
        #expect(listing(cache).isEmpty)
    }

    @Test func multiHopRedirectToHTTPMirrorIsRejected() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let mirrorA = URL(string: "https://mirror-a.example/debian/x.raw")!
        let mirrorB = URL(string: "http://mirror-b.example/debian/x.raw")!
        var routes = validRoutes()
        routes[image.url.absoluteString] = .redirect(mirrorA)
        routes[mirrorA.absoluteString] = .redirect(mirrorB)
        routes[mirrorB.absoluteString] = .ok(payload)
        StubURLProtocol.reset(routes: routes)
        let cache = tmp.appendingPathComponent("images")
        let store = ImageStore(cacheRoot: cache, session: makeSession())
        await #expect(throws: NidoError.hostNotAllowed(mirrorB.absoluteString)) {
            _ = try await store.ensureImage(image) { _ in true }
        }
        #expect(StubURLProtocol.requests == [image.checksumsURL, image.url, mirrorA])
        #expect(listing(cache).isEmpty)
    }

    // MARK: - Progress, shared downloads, cancellation

    /// Waits (bounded) until `count` callers are waiting for `image`.
    func waitForWaiters(_ count: Int, store: ImageStore) async throws {
        for _ in 0..<10_000 {
            if await store.waiterCount(imageID: image.id) == count { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("timed out waiting for \(count) waiters")
    }

    @Test func progressIsReportedAndEndsAtTotal() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let chunk = Data(repeating: 0x5A, count: 100 << 10)
        let chunks = Array(repeating: chunk, count: 6)
        let body = chunks.reduce(into: Data()) { $0.append($1) }
        StubURLProtocol.reset(routes: [
            image.checksumsURL.absoluteString: .ok(sums(hex(body), name: image.fileName)),
            image.url.absoluteString: .chunksDeclaring(chunks, contentLength: body.count),
        ])
        let store = ImageStore(cacheRoot: tmp.appendingPathComponent("images"), session: makeSession())
        let log = ProgressLog()
        _ = try await store.ensureImage(image, confirm: { _ in true }, progress: { log.append($0) })
        let total = UInt64(body.count)
        // URLSession may coalesce chunks: assert the contract, not the exact delivery.
        let reports = log.all
        #expect(reports.last == DownloadProgress(receivedBytes: total, expectedBytes: total))
        #expect(reports.allSatisfy { $0.expectedBytes == total })
        var previous: UInt64 = 0
        for report in reports.dropLast() {
            #expect(report.receivedBytes - previous >= 256 << 10)
            previous = report.receivedBytes
        }
        #expect(reports.count <= 3)
    }

    @Test func progressWithoutContentLengthHasNoExpectedBytes() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        StubURLProtocol.reset(routes: validRoutes())
        let store = ImageStore(cacheRoot: tmp.appendingPathComponent("images"), session: makeSession())
        let log = ProgressLog()
        _ = try await store.ensureImage(image, confirm: { _ in true }, progress: { log.append($0) })
        #expect(log.all == [DownloadProgress(receivedBytes: UInt64(payload.count), expectedBytes: nil)])
    }

    @Test func concurrentEnsureSharesOneDownload() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        var routes = validRoutes()
        routes[image.url.absoluteString] = .held(payload)
        StubURLProtocol.reset(routes: routes)
        let cache = tmp.appendingPathComponent("images")
        let store = ImageStore(cacheRoot: cache, session: makeSession())
        let confirms = CallCounter()
        let secondConfirms = CallCounter()
        let firstLog = ProgressLog()
        let secondLog = ProgressLog()
        let image = self.image

        async let first = store.ensureImage(
            image, confirm: { _ in confirms.increment(); return true }, progress: { firstLog.append($0) })
        await StubURLProtocol.waitUntilHeld()
        async let second = store.ensureImage(
            image, confirm: { _ in secondConfirms.increment(); return true }, progress: { secondLog.append($0) })
        try await waitForWaiters(2, store: store)
        StubURLProtocol.release()

        let (a, b) = try await (first, second)
        #expect(a == b)
        #expect(confirms.value == 1)
        #expect(secondConfirms.value == 0)
        #expect(StubURLProtocol.requests.filter { $0 == image.url }.count == 1)
        let end = DownloadProgress(receivedBytes: UInt64(payload.count), expectedBytes: UInt64(payload.count))
        #expect(firstLog.all.last == end)
        #expect(secondLog.all.last == end)
        #expect(try Data(contentsOf: a) == payload)
        #expect(await store.waiterCount(imageID: image.id) == 0)
    }

    @Test func failedDownloadIsForgottenAndRetriedWithConfirm() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        var routes = validRoutes()
        routes[image.url.absoluteString] = .status(500)
        StubURLProtocol.reset(routes: routes)
        let store = ImageStore(cacheRoot: tmp.appendingPathComponent("images"), session: makeSession())
        let confirms = CallCounter()
        await #expect(throws: NidoError.downloadFailed("HTTP 500 per \(image.url.absoluteString)")) {
            _ = try await store.ensureImage(image, confirm: { _ in confirms.increment(); return true })
        }
        StubURLProtocol.reset(routes: validRoutes())
        let url = try await store.ensureImage(image, confirm: { _ in confirms.increment(); return true })
        #expect(confirms.value == 2)
        #expect(try Data(contentsOf: url) == payload)
    }

    @Test func cancellationRemovesPartFile() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        var routes = validRoutes()
        routes[image.url.absoluteString] = .held(payload)
        StubURLProtocol.reset(routes: routes)
        let cache = tmp.appendingPathComponent("images")
        let store = ImageStore(cacheRoot: cache, session: makeSession())
        let image = self.image
        let task = Task { try await store.ensureImage(image, confirm: { _ in true }) }
        await StubURLProtocol.waitUntilHeld()
        // The private .part file exists while the transfer is in flight.
        #expect(listing(cache).count == 1)
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(listing(cache).isEmpty)
        #expect(await store.waiterCount(imageID: image.id) == 0)
    }

    @Test func cancelledCallerLeavesDownloadToOtherWaiters() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        var routes = validRoutes()
        routes[image.url.absoluteString] = .held(payload)
        StubURLProtocol.reset(routes: routes)
        let cache = tmp.appendingPathComponent("images")
        let store = ImageStore(cacheRoot: cache, session: makeSession())
        let image = self.image
        let first = Task { try await store.ensureImage(image, confirm: { _ in true }) }
        await StubURLProtocol.waitUntilHeld()
        let second = Task { try await store.ensureImage(image, confirm: { _ in true }) }
        try await waitForWaiters(2, store: store)
        first.cancel()
        await #expect(throws: CancellationError.self) { _ = try await first.value }
        #expect(try await waitForWaiters(1, store: store) == ())
        StubURLProtocol.release()
        let url = try await second.value
        #expect(try Data(contentsOf: url) == payload)
        #expect(listing(cache) == [image.fileName, image.fileName + ".sha512"].sorted())
    }

    @Test func alreadyCancelledCallerThrowsWithoutDownloading() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        var routes = validRoutes()
        routes[image.url.absoluteString] = .held(payload)
        StubURLProtocol.reset(routes: routes)
        let store = ImageStore(cacheRoot: tmp.appendingPathComponent("images"), session: makeSession())
        let image = self.image
        let confirms = CallCounter()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.ensureImage(image, confirm: { _ in confirms.increment(); return true })
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        StubURLProtocol.release()
        #expect(confirms.value == 0)
        #expect(StubURLProtocol.requests.isEmpty)
        #expect(await store.inFlightCount == 0)
    }

    @Test func cancelDuringConfirmMakesNoRequest() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        StubURLProtocol.reset(routes: validRoutes())
        let store = ImageStore(cacheRoot: tmp.appendingPathComponent("images"), session: makeSession())
        let image = self.image
        let (entered, enteredCont) = AsyncStream<Void>.makeStream()
        let (gate, gateCont) = AsyncStream<Void>.makeStream()
        let task = Task {
            try await store.ensureImage(image, confirm: { _ in
                enteredCont.yield()
                for await _ in gate { break }
                return true
            })
        }
        for await _ in entered { break }
        task.cancel()
        // cancelWaiter has run (and cancelled the download) once nothing is tracked any more.
        for _ in 0..<10_000 where await store.inFlightCount != 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        gateCont.yield()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(StubURLProtocol.requests.isEmpty)
        #expect(await store.inFlightCount == 0)
    }

    /// Publication order: the sidecar first, then the image (both by rename), so an image present
    /// in the cache always has its sidecar. Shown by an image name that cannot be replaced: the
    /// sidecar is already in place, the image is not, and the call fails.
    @Test func failedImageRenameRemovesTheNewSidecar() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        var routes = validRoutes()
        routes[image.url.absoluteString] = .held(payload)
        StubURLProtocol.reset(routes: routes)
        let cache = tmp.appendingPathComponent("images")
        let store = ImageStore(cacheRoot: cache, session: makeSession())
        let image = self.image
        let task = Task { try await store.ensureImage(image, confirm: { _ in true }) }
        await StubURLProtocol.waitUntilHeld()
        let blocker = cache.appendingPathComponent(image.fileName)
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: false)
        try Data("x".utf8).write(to: blocker.appendingPathComponent("x"))
        StubURLProtocol.release()
        await #expect(throws: (any Error).self) { _ = try await task.value }
        // The sidecar was published first, then removed when the image could not follow: the
        // old entry is not reported as the new build (`checkForUpdate`), and nothing else is left.
        #expect(listing(cache) == [image.fileName])
        #expect(try await store.checkForUpdate(image) == .notCached)
    }

    /// The validator never deletes what it finds invalid or incomplete: another process may be
    /// publishing that very entry. A miss just downloads again, and the new files replace the old
    /// ones atomically.
    @Test(arguments: [false, true])
    func invalidEntryIsAMissButIsNotDeleted(withSidecar: Bool) async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        var routes = validRoutes()
        routes[image.url.absoluteString] = .held(payload)
        StubURLProtocol.reset(routes: routes)
        let cache = tmp.appendingPathComponent("images")
        try PrivateDirectory.ensure(cache)
        let file = cache.appendingPathComponent(image.fileName)
        try Data("half published".utf8).write(to: file)
        if withSidecar {
            try Data((hex(payload) + "\n").utf8).write(to: cache.appendingPathComponent(image.fileName + ".sha512"))
        }
        let store = ImageStore(cacheRoot: cache, session: makeSession())
        let image = self.image
        let task = Task { try await store.ensureImage(image, confirm: { _ in true }) }
        await StubURLProtocol.waitUntilHeld()
        // Validation is over (the download is running): the entry is still there.
        #expect(try Data(contentsOf: file) == Data("half published".utf8))
        StubURLProtocol.release()
        let url = try await task.value
        #expect(url == file)
        #expect(try Data(contentsOf: url) == payload)
        #expect(listing(cache) == [image.fileName, image.fileName + ".sha512"].sorted())
    }

    @Test func failedSidecarLeavesNoImageBehind() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        var routes = validRoutes()
        routes[image.url.absoluteString] = .held(payload)
        StubURLProtocol.reset(routes: routes)
        let cache = tmp.appendingPathComponent("images")
        let store = ImageStore(cacheRoot: cache, session: makeSession())
        let image = self.image
        let task = Task { try await store.ensureImage(image, confirm: { _ in true }) }
        await StubURLProtocol.waitUntilHeld()
        // A non-empty directory squats on the sidecar name: writing the sidecar must fail.
        let blocker = cache.appendingPathComponent(image.fileName + ".sha512")
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: false)
        try Data("x".utf8).write(to: blocker.appendingPathComponent("x"))
        StubURLProtocol.release()
        await #expect(throws: NidoError.self) { _ = try await task.value }
        #expect(listing(cache) == [image.fileName + ".sha512"])
    }

    // MARK: - Cache read errors

    func populatedCache(_ cache: URL) throws {
        try PrivateDirectory.ensure(cache)
        try payload.write(to: cache.appendingPathComponent(image.fileName))
        try Data((hex(payload) + "\n").utf8).write(to: cache.appendingPathComponent(image.fileName + ".sha512"))
    }

    @Test(arguments: [POSIXErrorCode.EINTR, .EAGAIN])
    func transientCacheReadErrorIsPropagatedWithoutRedownload(_ code: POSIXErrorCode) async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        StubURLProtocol.reset(routes: validRoutes())
        let cache = tmp.appendingPathComponent("images")
        try populatedCache(cache)
        let store = ImageStore(
            cacheRoot: cache, session: makeSession(), hashFile: { _ in throw POSIXError(code) })
        let calls = CallCounter()
        await #expect(throws: POSIXError.self) {
            _ = try await store.ensureImage(image) { _ in calls.increment(); return true }
        }
        #expect(calls.value == 0)
        #expect(StubURLProtocol.requests.isEmpty)
        #expect(listing(cache) == [image.fileName, image.fileName + ".sha512"].sorted())
    }

    @Test func nonTransientCacheReadErrorTriggersRedownload() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        StubURLProtocol.reset(routes: validRoutes())
        let cache = tmp.appendingPathComponent("images")
        try populatedCache(cache)
        let store = ImageStore(
            cacheRoot: cache, session: makeSession(), hashFile: { _ in throw POSIXError(.EIO) })
        let url = try await store.ensureImage(image) { _ in true }
        #expect(StubURLProtocol.requests == [image.checksumsURL, image.url])
        #expect(try Data(contentsOf: url) == payload)
    }

    /// The full-image hash of the cache check runs off the actor: while it runs, the store still
    /// answers other calls (here `inFlightCount`), and the valid entry is then returned without
    /// any request.
    @Test func cacheHashDoesNotBlockActor() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        StubURLProtocol.reset(routes: validRoutes())
        let cache = tmp.appendingPathComponent("images")
        try populatedCache(cache)
        let gate = HashGate()
        let store = ImageStore(cacheRoot: cache, session: makeSession(), hashFile: { url in
            gate.enterAndWait()
            return try Checksums.sha512(of: url)
        })
        let image = self.image
        let first = Task { try await store.ensureImage(image) { _ in true } }
        try await gate.waitUntilEntered()
        // The actor is free while the hash runs.
        let answered = Task { await store.inFlightCount }
        let count = try await withThrowingTaskGroup(of: Int?.self) { group in
            group.addTask { await answered.value }
            group.addTask {
                // A blocked actor would never answer: unblock it so the test ends (and fails).
                try? await Task.sleep(for: .seconds(2))
                gate.open()
                return nil
            }
            let value = try await group.next() ?? nil
            group.cancelAll()
            return value
        }
        gate.open()
        #expect(count == 0, "L'actor è rimasto bloccato durante l'hash")
        let url = try await first.value
        #expect(try Data(contentsOf: url) == payload)
        #expect(StubURLProtocol.requests.isEmpty)
    }

    /// Two callers both find a stale entry while hashing off the actor: after the hash, the
    /// second one joins the download the first one started (one request, one confirmation).
    @Test(.timeLimit(.minutes(1)))
    func callersHashingTogetherShareOneDownload() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        var routes = validRoutes()
        routes[image.url.absoluteString] = .held(payload)
        StubURLProtocol.reset(routes: routes)
        let cache = tmp.appendingPathComponent("images")
        try populatedCache(cache)
        try Data("stale".utf8).write(to: cache.appendingPathComponent(image.fileName))
        let gate = HashGate()
        let store = ImageStore(cacheRoot: cache, session: makeSession(), hashFile: { url in
            gate.enterAndWait()
            return try Checksums.sha512(of: url)
        })
        let confirms = CallCounter()
        let image = self.image
        let first = Task { try await store.ensureImage(image) { _ in confirms.increment(); return true } }
        let second = Task { try await store.ensureImage(image) { _ in confirms.increment(); return true } }
        try await gate.waitUntilEntered(2)
        gate.open()
        await StubURLProtocol.waitUntilHeld()
        try await waitForWaiters(2, store: store)
        StubURLProtocol.release()
        let (a, b) = try await (first.value, second.value)
        #expect(a == b)
        #expect(confirms.value == 1)
        #expect(StubURLProtocol.requests.filter { $0 == image.url }.count == 1)
        #expect(try Data(contentsOf: a) == payload)
    }

    @Test func transientErrorClassification() {
        #expect(ImageStore.isTransientIO(POSIXError(.EINTR)))
        #expect(ImageStore.isTransientIO(NSError(domain: NSPOSIXErrorDomain, code: Int(EAGAIN))))
        let wrapped = NSError(
            domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EINTR))])
        #expect(ImageStore.isTransientIO(wrapped))
        #expect(!ImageStore.isTransientIO(POSIXError(.EIO)))
        #expect(!ImageStore.isTransientIO(CocoaError(.fileReadNoSuchFile)))
    }

    @Test func transientErrorReadingSidecarOrFileTypeIsPropagated() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        StubURLProtocol.reset(routes: validRoutes())
        let cache = tmp.appendingPathComponent("images")
        try populatedCache(cache)
        let hash: @Sendable (URL) throws -> String = { try Checksums.sha512(of: $0) }
        let sidecarFails = ImageStore(
            cacheRoot: cache, session: makeSession(), hashFile: hash,
            readDigest: { _ in throw POSIXError(.EINTR) })
        await #expect(throws: POSIXError.self) {
            _ = try await sidecarFails.ensureImage(image) { _ in true }
        }
        let typeFails = ImageStore(
            cacheRoot: cache, session: makeSession(), hashFile: hash,
            fileType: { _ in throw POSIXError(.EAGAIN) })
        await #expect(throws: POSIXError.self) {
            _ = try await typeFails.ensureImage(image) { _ in true }
        }
        #expect(StubURLProtocol.requests.isEmpty)
        #expect(listing(cache) == [image.fileName, image.fileName + ".sha512"].sorted())
        // A missing sidecar is a plain cache miss.
        try FileManager.default.removeItem(at: cache.appendingPathComponent(image.fileName + ".sha512"))
        let store = ImageStore(cacheRoot: cache, session: makeSession(), hashFile: hash)
        _ = try await store.ensureImage(image) { _ in true }
        #expect(StubURLProtocol.requests == [image.checksumsURL, image.url])
    }
}

// MARK: - SHA-256 (Ubuntu)

extension ImageStoreTests {
    /// Same URLs and name as the catalog image, listed in a `SHA256SUMS` in binary mode.
    var ubuntuLike: CloudImage {
        CloudImage(
            id: "ubuntu-test", fileName: "ubuntu-test.img", url: image.url, checksumsURL: image.checksumsURL,
            maxBytes: 1 << 20, checksum: .sha256, distribution: .ubuntu2604)
    }

    func hex256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test func sha256ImageIsVerifiedAndCachedWithItsSidecar() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let image = ubuntuLike
        StubURLProtocol.reset(routes: [
            image.checksumsURL.absoluteString: .ok(Data("\(hex256(payload)) *\(image.fileName)\n".utf8)),
            image.url.absoluteString: .ok(payload),
        ])
        let cache = tmp.appendingPathComponent("images")
        let store = ImageStore(cacheRoot: cache, session: makeSession())
        let url = try await store.ensureImage(image) { _ in true }
        #expect(try Data(contentsOf: url) == payload)
        #expect(listing(cache) == [image.fileName, image.fileName + ".sha256"].sorted())
        let stored = try String(contentsOf: cache.appendingPathComponent(image.sidecarName), encoding: .utf8)
        #expect(stored == hex256(payload) + "\n")

        // A second call is a cache hit (no request), validated with SHA-256.
        StubURLProtocol.reset(routes: [:])
        let fresh = ImageStore(cacheRoot: cache, session: makeSession())
        _ = try await fresh.ensureImage(image) { _ in Issue.record("asked again"); return false }
        #expect(StubURLProtocol.requests.isEmpty)
    }

    @Test func sha256MismatchIsRefused() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let image = ubuntuLike
        let wrong = String(repeating: "0", count: 64)
        StubURLProtocol.reset(routes: [
            image.checksumsURL.absoluteString: .ok(Data("\(wrong) *\(image.fileName)\n".utf8)),
            image.url.absoluteString: .ok(payload),
        ])
        let cache = tmp.appendingPathComponent("images")
        let store = ImageStore(cacheRoot: cache, session: makeSession())
        await #expect(throws: NidoError.checksumMismatch(expected: wrong, actual: hex256(payload))) {
            _ = try await store.ensureImage(image) { _ in true }
        }
        #expect(listing(cache).isEmpty)
    }
}

// MARK: - Debian build manifest

/// Debian's unsigned list: the build manifest must agree with it and never go back to an older build.
/// In `ImageStoreTests` (serialized): `StubURLProtocol` is shared.
extension ImageStoreTests {
    var debian: CloudImage { CloudImageCatalog.debian13 }

    static func sha512(_ data: Data) -> String {
        SHA512.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Debian's layout, the digest in base64 without padding as Debian writes it.
    static func manifest(version: String, raw: String, uploadVersion: String? = nil) -> Data {
        var bytes = [UInt8]()
        var index = raw.startIndex
        while index < raw.endIndex {
            let next = raw.index(index, offsetBy: 2)
            bytes.append(UInt8(raw[index..<next], radix: 16)!)
            index = next
        }
        let digest = "sha512:" + Data(bytes).base64EncodedString().replacingOccurrences(of: "=", with: "")
        func upload(_ format: String, _ digest: String) -> String {
            """
            {"apiVersion": "cloud.debian.org/v1alpha1", "kind": "Upload",
             "data": {"provider": "cloud.debian.org", "ref": "trixie/\(version)/x.\(format)"},
             "metadata": {"annotations": {"cloud.debian.org/digest": "\(digest)"},
                          "labels": {"cloud.debian.org/version": "\(uploadVersion ?? version)",
                                     "upload.cloud.debian.org/image-format": "\(format)",
                                     "upload.cloud.debian.org/type": "release"}}}
            """
        }
        let other = "sha512:" + Data(repeating: 7, count: 64).base64EncodedString()
        return Data("""
            {"apiVersion": "v1", "items": [
              {"apiVersion": "cloud.debian.org/v1alpha1", "kind": "Build",
               "data": {"info": {"arch": "arm64", "release": "trixie", "version": "\(version)"},
                        "packages": [{"name": "apt", "version": "3.0.3"}]},
               "metadata": {"labels": {"cloud.debian.org/version": "\(version)"}}},
              \(upload("qcow2", other)),
              \(upload("raw", digest))
            ]}
            """.utf8)
    }

    func debianRoutes(manifest: Data, listedManifest: Data? = nil, image digest: String? = nil) -> [String: StubURLProtocol.Route] {
        let list = "\(digest ?? Self.sha512(payload))  \(debian.fileName)\n"
            + "\(Self.sha512(listedManifest ?? manifest))  \(debian.manifest!.fileName)\n"
        return [
            debian.checksumsURL.absoluteString: .ok(Data(list.utf8)),
            debian.manifest!.url.absoluteString: .ok(manifest),
            debian.url.absoluteString: .ok(payload),
        ]
    }

    func debianStore() throws -> (ImageStore, URL, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-debmanifest-\(UUID().uuidString)", isDirectory: true)
        let cache = tmp.appendingPathComponent("images")
        return (ImageStore(cacheRoot: cache, session: makeSession()), tmp,
                cache.appendingPathComponent(debian.fileName + ".build"))
    }

    @Test func catalogDebianHasItsManifest() throws {
        let manifest = try #require(debian.manifest)
        #expect(manifest.fileName == "debian-13-genericcloud-arm64.json")
        #expect(manifest.url.deletingLastPathComponent() == debian.checksumsURL.deletingLastPathComponent())
        #expect(manifest.imageFormat == "raw")
        try DownloadPolicy.validate(manifest.url)
        #expect(CloudImageCatalog.ubuntu2604.manifest == nil && CloudImageCatalog.ubuntu2404.manifest == nil)
    }

    @Test func consistentManifestIsAcceptedAndRecorded() async throws {
        let (store, tmp, record) = try debianStore(); defer { try? FileManager.default.removeItem(at: tmp) }
        let digest = Self.sha512(payload)
        StubURLProtocol.reset(routes: debianRoutes(manifest: Self.manifest(version: "20261103-2651", raw: digest)))
        _ = try await store.ensureImage(debian) { _ in true }
        #expect(StubURLProtocol.requests == [debian.checksumsURL, debian.manifest!.url, debian.url])
        #expect(try String(contentsOf: record, encoding: .utf8) == "20261103-2651 \(digest)\n")
        #expect(try FileManager.default.attributesOfItem(atPath: record.path)[.posixPermissions] as? Int == 0o600)
    }

    @Test func inconsistentManifestStopsBeforeTheImage() async throws {
        let (store, tmp, record) = try debianStore(); defer { try? FileManager.default.removeItem(at: tmp) }
        let digest = Self.sha512(payload)
        let good = Self.manifest(version: "20261103-2651", raw: digest)
        let cases: [([String: StubURLProtocol.Route], String)] = [
            // The manifest is not the one the list names.
            (debianRoutes(manifest: good, listedManifest: Data("other".utf8)), "manifesto della build diverso da quello della lista dei checksum"),
            // It gives the image another digest than the list.
            (debianRoutes(manifest: Self.manifest(version: "20261103-2651", raw: String(repeating: "a", count: 128))),
             "il manifesto della build 20261103-2651 indica per \(debian.fileName) un checksum diverso dalla lista"),
            // The raw upload of another build.
            (debianRoutes(manifest: Self.manifest(version: "20261103-2651", raw: digest, uploadVersion: "20261020-2600")),
             "manifesto della build non valido (versioni diverse)"),
            (debianRoutes(manifest: Self.manifest(version: "latest", raw: digest)), "manifesto della build non valido (versione latest)"),
            (debianRoutes(manifest: Data("<html>404</html>".utf8)), "manifesto della build non valido (non è il JSON atteso)"),
        ]
        for (routes, reason) in cases {
            StubURLProtocol.reset(routes: routes)
            await #expect(throws: NidoError.downloadFailed(reason)) {
                _ = try await store.ensureImage(debian, refresh: true) { _ in true }
            }
            #expect(!StubURLProtocol.requests.contains(debian.url))
        }
        // Not listed at all.
        let list = "\(digest)  \(debian.fileName)\n"
        StubURLProtocol.reset(routes: [debian.checksumsURL.absoluteString: .ok(Data(list.utf8))])
        await #expect(throws: NidoError.downloadFailed("manifesto della build mancante nella lista dei checksum")) {
            _ = try await store.ensureImage(debian, refresh: true) { _ in true }
        }
        #expect(StubURLProtocol.requests == [debian.checksumsURL])
        #expect(!FileManager.default.fileExists(atPath: record.path))
    }

    @Test func olderBuildIsRefusedAsAReplay() async throws {
        let (store, tmp, record) = try debianStore(); defer { try? FileManager.default.removeItem(at: tmp) }
        let digest = Self.sha512(payload)
        let current = debianRoutes(manifest: Self.manifest(version: "20261103-2651", raw: digest))
        StubURLProtocol.reset(routes: current)
        _ = try await store.ensureImage(debian) { _ in true }

        // An older build: refused before the image, the record kept.
        try Data("20261110-2700 \(digest)\n".utf8).write(to: record)
        StubURLProtocol.reset(routes: current)
        do {
            _ = try await store.ensureImage(debian, refresh: true) { _ in true }
            Issue.record("an older build must be refused")
        } catch NidoError.downloadFailed(let reason) {
            #expect(reason.hasPrefix("build 20261103-2651 più vecchia di quella già accettata (20261110-2700): "))
            #expect(reason.hasSuffix("(se succede sempre: nido image reset debian-13)"))
        }
        #expect(!StubURLProtocol.requests.contains(debian.url))
        // Build numbers compare as numbers: 2651 is newer than 999 on the same day.
        try Data("20261103-999 \(digest)\n".utf8).write(to: record)
        StubURLProtocol.reset(routes: current)
        #expect(try await store.checkForUpdate(debian) == .current)
        #expect(try String(contentsOf: record, encoding: .utf8) == "20261103-2651 \(digest)\n")

        // The same build with other files: refused.
        let other = String(repeating: "b", count: 128)
        try Data("20261103-2651 \(other)\n".utf8).write(to: record)
        StubURLProtocol.reset(routes: current)
        do {
            _ = try await store.checkForUpdate(debian)
            Issue.record("the same build with another digest must be refused")
        } catch NidoError.downloadFailed(let reason) {
            #expect(reason.hasPrefix("build 20261103-2651 già accettata con un altro checksum"))
        }

        // Unreadable: a first time.
        try Data("garbage".utf8).write(to: record)
        StubURLProtocol.reset(routes: current)
        #expect(try await store.checkForUpdate(debian) == .current)
        #expect(try String(contentsOf: record, encoding: .utf8) == "20261103-2651 \(digest)\n")
    }

    /// `nido image check` shows the accepted build; `nido image reset` forgets it (and the
    /// signature time), after which an older build is accepted as a first time. The image stays.
    @Test func acceptedBuildIsShownAndCanBeForgotten() async throws {
        let (store, tmp, record) = try debianStore(); defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(await store.acceptedBuild(debian) == nil)
        #expect(try await store.forgetAccepted(debian).isEmpty)

        let digest = Self.sha512(payload)
        StubURLProtocol.reset(routes: debianRoutes(manifest: Self.manifest(version: "20261103-2651", raw: digest)))
        let image = try await store.ensureImage(debian) { _ in true }
        #expect(await store.acceptedBuild(debian) == "20261103-2651")

        // A newer build recorded (a mirror now stuck on the older one): refused until reset.
        try Data("20261110-2700 \(digest)\n".utf8).write(to: record)
        #expect(await store.acceptedBuild(debian) == "20261110-2700")
        let signed = record.deletingLastPathComponent().appendingPathComponent(debian.fileName + ".signed")
        try Data("1\n".utf8).write(to: signed)
        let removed = try await store.forgetAccepted(debian)
        #expect(Set(removed.map(\.lastPathComponent)) == [record.lastPathComponent, signed.lastPathComponent])
        #expect(!FileManager.default.fileExists(atPath: record.path))
        #expect(!FileManager.default.fileExists(atPath: signed.path))
        #expect(FileManager.default.fileExists(atPath: image.path))
        StubURLProtocol.reset(routes: debianRoutes(manifest: Self.manifest(version: "20261103-2651", raw: digest)))
        #expect(try await store.checkForUpdate(debian) == .current)
        #expect(await store.acceptedBuild(debian) == "20261103-2651")

        // A malformed record shows nothing.
        try Data("garbage".utf8).write(to: record)
        #expect(await store.acceptedBuild(debian) == nil)
    }
}

@Suite(.italian) struct DebianBuildManifestTests {
    /// The raw digest of build 20261103-2651, as Debian's manifest writes it (no padding), and as
    /// its SHA512SUMS lists it (seen 2026-11-10).
    @Test func unpaddedDigestOfARealBuild() throws {
        let raw = "8bbf6f652c94721da5b462d7648385e1b096adc388ce01a8d3b92ffc7da9301dfb24c84b011588e3f09212ad00a0ed80f5a61278f18f0f6a3d75fce42a58f543"
        let data = ImageStoreTests.manifest(version: "20261103-2651", raw: raw)
        #expect(String(decoding: data, as: UTF8.self).contains(
            "sha512:i79vZSyUch2ltGLXZIOF4bCWrcOIzgGo07kv/H2pMB37JMhLARWI4/CSEq0AoO2A9aYSePGPD2o9dfzkKlj1Qw\""))
        let build = try DebianBuildManifest.parse(data, imageFormat: "raw")
        #expect(build.version.description == "20261103-2651")
        #expect(build.sha512 == raw)
        #expect(throws: NidoError.downloadFailed("manifesto della build non valido (formato tar assente o doppio)")) {
            try DebianBuildManifest.parse(data, imageFormat: "tar")
        }
    }

    @Test func versionsParseAndOrder() throws {
        let a = try #require(DebianBuildManifest.Version("20261103-2651"))
        #expect(a.date == 20_261_103 && a.build == 2651)
        #expect(try #require(DebianBuildManifest.Version("20261103-999")) < a)
        #expect(a < (try #require(DebianBuildManifest.Version("20261104-1"))))
        for bad in ["", "latest", "2026110-1", "20261103", "20261103-", "20261103-1-2", "2026-1103-1",
                    "20261103-1234567890", "20261103-+1", "２0261103-1", "20261103 -1"] {
            #expect(DebianBuildManifest.Version(bad) == nil, "\(bad)")
        }
        #expect(DebianBuildManifest.unpaddedBase64("QQ") == Data("A".utf8))
        #expect(DebianBuildManifest.unpaddedBase64("QQ==") == Data("A".utf8))
        #expect(DebianBuildManifest.unpaddedBase64("Q=Q") == nil)
    }
}
