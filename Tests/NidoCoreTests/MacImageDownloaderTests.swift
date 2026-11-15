// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
@testable import NidoCore

/// In-process stand-in for Apple's CDN: serves files with an `ETag`, honours `Range` with
/// `If-Range` (206 with `Content-Range`, or the whole file with 200), redirects, and can stop
/// after part of a file until the request is cancelled. Its own state, separate from
/// `StubURLProtocol`'s: `MacImageDownloaderTests` is serialized on it.
final class AppleCDNStub: URLProtocol {
    struct File: Sendable {
        var body: Data
        var etag: String? = "\"etag-1\""
        var lastModified: String? = nil
        /// false: answers every request with the whole file (200), as a server without ranges.
        var honoursRange = true
        /// Sends this many bytes, then nothing more until the request is cancelled.
        var stopAfter: Int? = nil
        /// Declared `Content-Length` of a 200 instead of the body's.
        var declaredLength: Int? = nil
        /// `Content-Range` of a 206 instead of the right one.
        var contentRange: String? = nil
        /// A 200 without `Content-Length`.
        var omitLength = false
    }

    enum Route: Sendable {
        case file(File)
        case redirect(URL)
        case status(Int)
    }

    struct Request: Sendable, Equatable {
        var url: URL
        var range: String?
        var ifRange: String?
        var method = "GET"
    }

    private struct State {
        var routes: [String: Route] = [:]
        var log: [Request] = []
    }

    private static let state = Mutex(State())
    static let chunk = 64 << 10

    static func reset(routes: [String: Route] = [:]) {
        state.withLock { $0 = State(routes: routes) }
    }

    static var requests: [Request] { state.withLock { $0.log } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let range = request.value(forHTTPHeaderField: "Range")
        let ifRange = request.value(forHTTPHeaderField: "If-Range")
        let method = request.httpMethod ?? "GET"
        let route = Self.state.withLock { s -> Route? in
            s.log.append(Request(url: url, range: range, ifRange: ifRange, method: method))
            return s.routes[url.absoluteString]
        }
        switch route ?? .status(404) {
        case .status(let code):
            let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let target):
            let response = HTTPURLResponse(
                url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
        case .file(let file):
            if method == "HEAD" {
                var headers: [String: String] = [:]
                if !file.omitLength { headers["Content-Length"] = String(file.declaredLength ?? file.body.count) }
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
            } else {
                serve(file, url: url, range: range, ifRange: ifRange)
            }
        }
    }

    private func serve(_ file: File, url: URL, range: String?, ifRange: String?) {
        var headers: [String: String] = [:]
        if let etag = file.etag { headers["ETag"] = etag }
        if let lastModified = file.lastModified { headers["Last-Modified"] = lastModified }
        var status = 200
        var body = file.body
        if file.honoursRange, let range, range.hasPrefix("bytes="), range.hasSuffix("-"),
            let start = Int(range.dropFirst("bytes=".count).dropLast()), start >= file.body.count,
            ifRange == nil || ifRange == file.etag || ifRange == file.lastModified
        {
            headers["Content-Range"] = "bytes */\(file.body.count)"
            let response = HTTPURLResponse(url: url, statusCode: 416, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if file.honoursRange, let range, range.hasPrefix("bytes="), range.hasSuffix("-"),
            let start = Int(range.dropFirst("bytes=".count).dropLast()), start < file.body.count,
            ifRange == nil || ifRange == file.etag || ifRange == file.lastModified
        {
            status = 206
            body = file.body.subdata(in: start..<file.body.count)
            headers["Content-Range"] = file.contentRange ?? "bytes \(start)-\(file.body.count - 1)/\(file.body.count)"
            headers["Content-Length"] = String(body.count)
        } else if !file.omitLength {
            headers["Content-Length"] = String(file.declaredLength ?? body.count)
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let limit = min(body.count, file.stopAfter ?? body.count)
        var offset = 0
        while offset < limit {
            let end = min(offset + Self.chunk, limit)
            client?.urlProtocol(self, didLoad: body.subdata(in: offset..<end))
            offset = end
        }
        if file.stopAfter == nil { client?.urlProtocolDidFinishLoading(self) }
    }

    override func stopLoading() {}
}

/// Returns a restore image with a fixed build (or fails) and records the files it loaded.
final class FakeRestoreImageLoader: MacRestoreImageLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var loaded: [URL] = []
    private var seen: [Bool] = []
    let build: String?
    /// A path whose presence is recorded at each load (the final name: never there yet).
    let watch: URL?

    /// `build` nil: the file is not a restore image Virtualization can load.
    init(build: String?, watch: URL? = nil) {
        self.build = build
        self.watch = watch
    }

    var urls: [URL] { lock.withLock { loaded } }
    var watchedExisted: [Bool] { lock.withLock { seen } }

    func load(_ url: URL) async throws -> LoadedMacRestoreImage {
        let present = watch.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        lock.withLock {
            loaded.append(url)
            seen.append(present)
        }
        guard let build else { throw CocoaError(.fileReadCorruptFile) }
        return LoadedMacRestoreImage(
            buildVersion: build,
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 1),
            isSupported: true,
            configuration: .init(
                hardwareModelSupported: true, hardwareModel: Data([1]), minimumCPUCount: 2,
                minimumMemoryBytes: 4 << 30))
    }
}

/// Writes up to `limit` bytes of the file, then fails with `ENOSPC`, as a full disk does.
final class FullDisk: Sendable {
    let limit: UInt64
    init(limit: UInt64) { self.limit = limit }

    func write(_ fd: Int32, _ data: Data, _ offset: UInt64) -> Int32? {
        guard offset + UInt64(data.count) > limit else { return MacImageDownloader.writeAll(fd, data, at: offset) }
        let fits = Int(limit - min(limit, offset))
        if fits > 0, let err = MacImageDownloader.writeAll(fd, data.prefix(fits), at: offset) { return err }
        return ENOSPC
    }
}

@Suite(.serialized, .italian) struct MacImageDownloaderTests {
    static let offerURL = URL(string:
        "https://updates.cdn-apple.com/2026FallFCS/fullrestores/093-1/ABC/UniversalMac_27.2.1_26B131_Restore.ipsw")!
    let offer = MacImageOffer(build: "26B131", version: "27.2.1", url: Self.offerURL)
    /// Starts like a ZIP archive (an IPSW is one); 1 MiB + 3 bytes, so it arrives in many chunks.
    let body = Data([0x50, 0x4B, 0x03, 0x04]) + Data((0..<((1 << 20) - 1)).map { UInt8(truncatingIfNeeded: $0 &* 7) })
    static let host = OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 1)
    static let plenty: @Sendable (URL) -> Int64? = { _ in 1 << 40 }

    func makeTemp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-macimg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.resolvingSymlinksInPath()
    }

    func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AppleCDNStub.self]
        return URLSession(configuration: config)
    }

    func downloader(
        _ cache: URL, loader: FakeRestoreImageLoader = FakeRestoreImageLoader(build: "26B131"),
        space: @escaping @Sendable (URL) -> Int64? = MacImageDownloaderTests.plenty,
        write: (@Sendable (Int32, Data, UInt64) -> Int32?)? = nil, backoff: UInt64 = 0
    ) -> MacImageDownloader {
        MacImageDownloader(
            session: makeSession(), cacheRoot: cache, loader: loader, availableSpace: space,
            hostVersion: Self.host, writeChunk: write ?? MacImageDownloader.writeAll, resumeBackoff: backoff)
    }

    func check(_ destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.deletingPathExtension().lastPathComponent).checking.ipsw")
    }

    func listing(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    func part(_ destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).part")
    }

    func record(_ destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).part.json")
    }

    func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    func size(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber).intValue
    }

    func perms(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
    }

    /// Waits (bounded, 30 s) until the partial file of `destination` holds `bytes` bytes. Reads the
    /// file, not the progress reports: URLSession may merge chunks, so reports can skip a size.
    func waitForPartial(_ store: MacImageDownloader, _ destination: URL, _ bytes: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while store.partialBytes(for: destination) < Int64(bytes), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(store.partialBytes(for: destination) == Int64(bytes))
    }

    /// Leaves a `.part` of `bytes` bytes and its sidecar, as a download cancelled midway does.
    func makePartial(_ store: MacImageDownloader, to destination: URL, bytes: Int, file: AppleCDNStub.File? = nil) async throws {
        var stopped = file ?? AppleCDNStub.File(body: body)
        stopped.stopAfter = bytes
        AppleCDNStub.reset(routes: [Self.offerURL.absoluteString: .file(stopped)])
        let offer = offer
        let task = Task { try await store.download(offer, to: destination) { _ in } }
        try await waitForPartial(store, destination, bytes)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    // MARK: - Destination

    @Test func defaultDestinationIsTheCachesMacOSFolder() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let store = downloader(tmp)
        #expect(try store.destination(for: offer, output: nil)
            == tmp.appendingPathComponent("macos/UniversalMac_27.2.1_26B131_Restore.ipsw"))
    }

    @Test func outputMustBeANewFileInAnExistingFolder() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let store = downloader(tmp)
        let fresh = tmp.appendingPathComponent("mine.ipsw")
        #expect(try store.destination(for: offer, output: fresh) == fresh)

        let taken = tmp.appendingPathComponent("taken.ipsw")
        try Data("x".utf8).write(to: taken)
        #expect(throws: NidoError.downloadFailed("\(taken.path) esiste già: rimuovilo o scegli un altro percorso")) {
            try store.destination(for: offer, output: taken)
        }
        #expect(throws: NidoError.downloadFailed("\(tmp.path) esiste già: rimuovilo o scegli un altro percorso")) {
            try store.destination(for: offer, output: tmp)
        }
        let link = tmp.appendingPathComponent("link.ipsw")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tmp.appendingPathComponent("nowhere"))
        #expect(throws: NidoError.unsafePath(link.path)) { try store.destination(for: offer, output: link) }
        let orphan = tmp.appendingPathComponent("missing/x.ipsw")
        #expect(throws: NidoError.notFound(tmp.appendingPathComponent("missing").path)) {
            try store.destination(for: offer, output: orphan)
        }
    }

    @Test func offerWithAnUnsafeFileNameIsRefused() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let hidden = MacImageOffer(build: "1", version: "27.0", url: URL(string: "https://updates.cdn-apple.com/.x.ipsw")!)
        #expect(throws: NidoError.unsafePath(".x.ipsw")) { try downloader(tmp).destination(for: hidden, output: nil) }
    }

    // MARK: - Download

    @Test func freshDownloadIsCheckedAndKeptPrivate() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        AppleCDNStub.reset(routes: [Self.offerURL.absoluteString: .file(.init(body: body))])
        let probe = downloader(tmp)
        let destination = try probe.destination(for: offer, output: nil)
        let loader = FakeRestoreImageLoader(build: "26B131", watch: destination)
        let store = downloader(tmp, loader: loader)
        let progress = ProgressLog()
        let url = try await store.download(offer, to: destination) { progress.append($0) }
        #expect(url == destination)
        #expect(try Data(contentsOf: url) == body)
        #expect(try perms(url) == 0o600)
        #expect(try perms(url.deletingLastPathComponent()) == 0o700)
        #expect(!exists(part(url)) && !exists(record(url)))
        #expect(loader.urls == [check(url)])
        #expect(loader.watchedExisted == [false])
        #expect(listing(url.deletingLastPathComponent()) == [url.lastPathComponent])
        #expect(progress.all.last == DownloadProgress(receivedBytes: UInt64(body.count), expectedBytes: UInt64(body.count)))
        #expect(AppleCDNStub.requests == [.init(url: Self.offerURL, range: nil, ifRange: nil)])
        #expect(store.partialBytes(for: url) == 0)

        // Already there and checked: no second request.
        #expect(try await store.download(offer, to: destination) { _ in } == url)
        #expect(AppleCDNStub.requests.count == 1)
    }

    @Test func cancelKeepsThePartialAndResumeAppendsWithRangeAndIfRange() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let store = downloader(tmp)
        let destination = tmp.appendingPathComponent("mine.ipsw")
        try await makePartial(store, to: destination, bytes: 512 << 10)
        #expect(try size(part(destination)) == 512 << 10)
        #expect(try perms(part(destination)) == 0o600)
        #expect(try perms(record(destination)) == 0o600)
        #expect(!exists(destination))
        #expect(store.partialBytes(for: destination) == 512 << 10)

        AppleCDNStub.reset(routes: [Self.offerURL.absoluteString: .file(.init(body: body))])
        let progress = ProgressLog()
        let url = try await store.download(offer, to: destination) { progress.append($0) }
        #expect(try Data(contentsOf: url) == body)
        #expect(AppleCDNStub.requests == [.init(url: Self.offerURL, range: "bytes=524288-", ifRange: "\"etag-1\"")])
        #expect(progress.all.first?.receivedBytes == 512 << 10)
        #expect(progress.all.last?.receivedBytes == UInt64(body.count))
        #expect(!exists(part(url)) && !exists(record(url)))
    }

    @Test func resumeUsesLastModifiedWithoutAStrongETag() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let store = downloader(tmp)
        let destination = tmp.appendingPathComponent("mine.ipsw")
        let file = AppleCDNStub.File(body: body, etag: "W/\"weak\"", lastModified: "Tue, 10 Nov 2026 10:00:00 GMT")
        try await makePartial(store, to: destination, bytes: 256 << 10, file: file)
        AppleCDNStub.reset(routes: [Self.offerURL.absoluteString: .file(file)])
        _ = try await store.download(offer, to: destination) { _ in }
        #expect(AppleCDNStub.requests.first?.ifRange == "Tue, 10 Nov 2026 10:00:00 GMT")
        #expect(try Data(contentsOf: destination) == body)
    }

    @Test func serverIgnoringRangeStartsOverWithoutConcatenating() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let store = downloader(tmp)
        let destination = tmp.appendingPathComponent("mine.ipsw")
        try await makePartial(store, to: destination, bytes: 512 << 10)
        AppleCDNStub.reset(routes: [Self.offerURL.absoluteString: .file(.init(body: body, honoursRange: false))])
        let progress = ProgressLog()
        let url = try await store.download(offer, to: destination) { progress.append($0) }
        #expect(AppleCDNStub.requests.first?.range == "bytes=524288-")
        #expect(try Data(contentsOf: url) == body)
        #expect(progress.all.first?.receivedBytes == 0)
    }

    @Test func changedETagStartsOver() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let store = downloader(tmp)
        let destination = tmp.appendingPathComponent("mine.ipsw")
        try await makePartial(store, to: destination, bytes: 512 << 10)
        var changed = body
        changed[600_000] ^= 0xFF
        AppleCDNStub.reset(routes: [Self.offerURL.absoluteString: .file(.init(body: changed, etag: "\"etag-2\""))])
        let url = try await store.download(offer, to: destination) { _ in }
        #expect(AppleCDNStub.requests == [.init(url: Self.offerURL, range: "bytes=524288-", ifRange: "\"etag-1\"")])
        #expect(try Data(contentsOf: url) == changed)
    }

    @Test func resumedAtTheWrongPointDropsThePartial() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let store = downloader(tmp)
        let destination = tmp.appendingPathComponent("mine.ipsw")
        try await makePartial(store, to: destination, bytes: 512 << 10)
        AppleCDNStub.reset(routes: [Self.offerURL.absoluteString: .file(.init(
            body: body, contentRange: "bytes 0-\(body.count - 1)/\(body.count)"))])
        await #expect(throws: NidoError.downloadFailed(
            "il server ha ripreso il download dal punto sbagliato: il file parziale è stato eliminato, riprova")
        ) {
            try await store.download(offer, to: destination) { _ in }
        }
        #expect(!exists(part(destination)) && !exists(record(destination)) && !exists(destination))
    }

    // MARK: size (HEAD)

    @Test func headGivesTheSizeAndIsOnlyAskedWhenCalled() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        AppleCDNStub.reset(routes: [Self.offerURL.absoluteString: .file(.init(body: body, declaredLength: 27_487_790_694))])
        let store = downloader(tmp)
        #expect(AppleCDNStub.requests.isEmpty, "Nothing is asked before the call")
        #expect(try await store.remoteSize(of: offer) == 27_487_790_694)
        #expect(AppleCDNStub.requests.map(\.method) == ["HEAD"])
        #expect(ByteSize.format(27_487_790_694) == "25,6 GiB")
    }

    @Test func headThatFailsOrOmitsTheLengthIsUnknown() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let store = downloader(tmp)
        AppleCDNStub.reset(routes: [Self.offerURL.absoluteString: .status(500)])
        #expect(try await store.remoteSize(of: offer) == nil)
        AppleCDNStub.reset(routes: [Self.offerURL.absoluteString: .file(.init(body: body, omitLength: true))])
        #expect(try await store.remoteSize(of: offer) == nil)
    }

    @Test func headRedirectOffApplesHostsIsRefused() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let evil = URL(string: "https://evil.example/UniversalMac.ipsw")!
        AppleCDNStub.reset(routes: [
            Self.offerURL.absoluteString: .redirect(evil),
            evil.absoluteString: .file(.init(body: body)),
        ])
        let store = downloader(tmp)
        await #expect(throws: NidoError.hostNotAllowed(evil.absoluteString)) { _ = try await store.remoteSize(of: offer) }
        #expect(!AppleCDNStub.requests.map(\.url).contains(evil))
    }

    @Test func redirectOffApplesHostsIsRefused() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let evil = URL(string: "https://evil.example/UniversalMac.ipsw")!
        AppleCDNStub.reset(routes: [
            Self.offerURL.absoluteString: .redirect(evil),
            evil.absoluteString: .file(.init(body: body)),
        ])
        let store = downloader(tmp)
        let destination = tmp.appendingPathComponent("mine.ipsw")
        await #expect(throws: NidoError.hostNotAllowed(evil.absoluteString)) {
            try await store.download(offer, to: destination) { _ in }
        }
        #expect(!AppleCDNStub.requests.map(\.url).contains(evil))
        #expect(!exists(part(destination)) && !exists(record(destination)) && !exists(destination))

        // Midway (a partial already there): refused the same way, the partial stays for a resume.
        try await makePartial(store, to: destination, bytes: 256 << 10)
        AppleCDNStub.reset(routes: [
            Self.offerURL.absoluteString: .redirect(evil),
            evil.absoluteString: .file(.init(body: body)),
        ])
        await #expect(throws: NidoError.hostNotAllowed(evil.absoluteString)) {
            try await store.download(offer, to: destination) { _ in }
        }
        #expect(try size(part(destination)) == 256 << 10)
        #expect(exists(record(destination)) && !exists(destination))
    }

    @Test func redirectWithinAppleKeepsTheRange() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let store = downloader(tmp)
        let destination = tmp.appendingPathComponent("mine.ipsw")
        try await makePartial(store, to: destination, bytes: 256 << 10)
        let mirror = URL(string: "https://swcdn.apple.com/content/UniversalMac.ipsw")!
        AppleCDNStub.reset(routes: [
            Self.offerURL.absoluteString: .redirect(mirror),
            mirror.absoluteString: .file(.init(body: body)),
        ])
        _ = try await store.download(offer, to: destination) { _ in }
        #expect(AppleCDNStub.requests.last == .init(url: mirror, range: "bytes=262144-", ifRange: "\"etag-1\""))
        #expect(try Data(contentsOf: destination) == body)
    }

    @Test func nonAppleOfferIsRefusedBeforeAnyRequest() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        AppleCDNStub.reset()
        let url = URL(string: "http://updates.cdn-apple.com/x.ipsw")!
        let bad = MacImageOffer(build: "26B131", version: "27.2.1", url: url)
        await #expect(throws: NidoError.hostNotAllowed(url.absoluteString)) {
            try await downloader(tmp).download(bad, to: tmp.appendingPathComponent("x.ipsw")) { _ in }
        }
        #expect(AppleCDNStub.requests.isEmpty)
    }

    @Test func insufficientSpaceIsRefusedBeforeAnyRequest() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        AppleCDNStub.reset(routes: [Self.offerURL.absoluteString: .file(.init(body: body))])
        let store = downloader(tmp, space: { _ in 100 << 20 })
        let destination = tmp.appendingPathComponent("mine.ipsw")
        await #expect(throws: NidoError.insufficientSpace(needed: 1 << 30, available: 100 << 20)) {
            try await store.download(offer, to: destination) { _ in }
        }
        #expect(AppleCDNStub.requests.isEmpty)
        #expect(!exists(part(destination)) && !exists(record(destination)))
    }

    @Test func resumeNeedsSpaceForTheRestOnly() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let destination = tmp.appendingPathComponent("mine.ipsw")
        try await makePartial(downloader(tmp), to: destination, bytes: 512 << 10)
        let rest = UInt64(body.count - (512 << 10))
        AppleCDNStub.reset(routes: [Self.offerURL.absoluteString: .file(.init(body: body))])
        let short = downloader(tmp, space: { _ in Int64(rest + (1 << 30)) - 1 })
        await #expect(throws: NidoError.insufficientSpace(needed: rest + (1 << 30), available: rest + (1 << 30) - 1)) {
            try await short.download(offer, to: destination) { _ in }
        }
        #expect(AppleCDNStub.requests.isEmpty)
        #expect(try size(part(destination)) == 512 << 10)
        let enough = downloader(tmp, space: { _ in Int64(rest + (1 << 30)) })
        _ = try await enough.download(offer, to: destination) { _ in }
        #expect(try Data(contentsOf: destination) == body)
    }

    @Test func declaredSizeOverTheFreeSpaceIsRefusedBeforeWriting() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        AppleCDNStub.reset(routes: [Self.offerURL.absoluteString: .file(.init(body: body))])
        let available = Int64(1 << 30) + 10
        let store = downloader(tmp, space: { _ in available })
        let destination = tmp.appendingPathComponent("mine.ipsw")
        await #expect(throws: NidoError.insufficientSpace(needed: UInt64(body.count) + (1 << 30), available: UInt64(available))) {
            try await store.download(offer, to: destination) { _ in }
        }
        #expect(AppleCDNStub.requests.count == 1)
        #expect(store.partialBytes(for: destination) == 0)
        #expect(!exists(part(destination)) && !exists(record(destination)) && !exists(destination))
    }

    @Test func imageOverTheCapIsRefused() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        AppleCDNStub.reset(routes: [Self.offerURL.absoluteString: .file(.init(body: body, declaredLength: (40 << 30) + 1))])
        let destination = tmp.appendingPathComponent("mine.ipsw")
        await #expect(throws: NidoError.downloadFailed("immagine oltre il limite di 40 GiB")) {
            try await downloader(tmp).download(offer, to: destination) { _ in }
        }
        #expect(!exists(part(destination)) && !exists(record(destination)) && !exists(destination))
    }

    @Test func diskFullMidwayLeavesAResumablePartial() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        AppleCDNStub.reset(routes: [Self.offerURL.absoluteString: .file(.init(body: body))])
        let full = FullDisk(limit: 300 << 10)
        let store = downloader(tmp, write: { full.write($0, $1, $2) })
        let destination = tmp.appendingPathComponent("mine.ipsw")
        await #expect(throws: POSIXError(.ENOSPC)) { try await store.download(offer, to: destination) { _ in } }
        #expect(try size(part(destination)) == 300 << 10)
        #expect(store.partialBytes(for: destination) == 300 << 10)  // what the CLI words as "paused"
        #expect(exists(record(destination)) && !exists(destination))

        AppleCDNStub.reset(routes: [Self.offerURL.absoluteString: .file(.init(body: body))])
        _ = try await downloader(tmp).download(offer, to: destination) { _ in }
        #expect(AppleCDNStub.requests.first?.range == "bytes=307200-")
        #expect(try Data(contentsOf: destination) == body)
    }

    @Test func shortBodyKeepsThePartial() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        AppleCDNStub.reset(routes: [Self.offerURL.absoluteString: .file(.init(body: body, declaredLength: body.count + 10))])
        let destination = tmp.appendingPathComponent("mine.ipsw")
        let error = await #expect(throws: (any Error).self) {
            try await downloader(tmp).download(offer, to: destination) { _ in }
        }
        #expect(error != nil)
        #expect(!exists(destination))
        #expect(exists(part(destination)) && exists(record(destination)))
    }

    @Test func anotherBuildIsDeletedAndNamed() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        AppleCDNStub.reset(routes: [Self.offerURL.absoluteString: .file(.init(body: body))])
        let destination = tmp.appendingPathComponent("mine.ipsw")
        let loader = FakeRestoreImageLoader(build: "25Z999", watch: destination)
        let store = downloader(tmp, loader: loader)
        await #expect(throws: NidoError.downloadFailed(
            "il file scaricato è la build 25Z999, non la 26B131 indicata dal catalogo di Apple: è stato eliminato")
        ) {
            try await store.download(offer, to: destination) { _ in }
        }
        // Checked under the hidden check name, never under the final one; nothing left.
        #expect(loader.urls == [check(destination)])
        #expect(loader.watchedExisted == [false])
        #expect(listing(tmp).isEmpty)
    }

    @Test func unloadableFileIsDeleted() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        AppleCDNStub.reset(routes: [Self.offerURL.absoluteString: .file(.init(body: body))])
        let store = downloader(tmp, loader: FakeRestoreImageLoader(build: nil))
        let destination = tmp.appendingPathComponent("mine.ipsw")
        await #expect(throws: NidoError.downloadFailed(
            "il file scaricato non è un'immagine di ripristino macOS che Virtualization può caricare: è stato eliminato")
        ) {
            try await store.download(offer, to: destination) { _ in }
        }
        #expect(listing(tmp).isEmpty)
    }

    @Test func httpErrorLeavesNothingBehind() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        AppleCDNStub.reset(routes: [Self.offerURL.absoluteString: .status(403)])
        let destination = tmp.appendingPathComponent("mine.ipsw")
        await #expect(throws: NidoError.downloadFailed("HTTP 403 per \(Self.offerURL.absoluteString)")) {
            try await downloader(tmp).download(offer, to: destination) { _ in }
        }
        #expect(!exists(part(destination)) && !exists(record(destination)))
    }

    @Test func completePartialIsCheckedWithoutARequest() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let store = downloader(tmp)
        let destination = tmp.appendingPathComponent("mine.ipsw")
        // Every byte arrived, but the request never finished (as a crash before the rename).
        try await makePartial(store, to: destination, bytes: body.count)
        AppleCDNStub.reset()
        #expect(try await store.download(offer, to: destination) { _ in } == destination)
        #expect(AppleCDNStub.requests.isEmpty)
        #expect(try Data(contentsOf: destination) == body)
    }

    @Test func existingFileThatIsNotTheOfferIsLeftAlone() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        AppleCDNStub.reset(routes: [Self.offerURL.absoluteString: .file(.init(body: body))])
        let store = downloader(tmp, loader: FakeRestoreImageLoader(build: "25Z999"))
        let destination = try store.destination(for: offer, output: nil)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: destination)
        await #expect(throws: NidoError.downloadFailed("\(destination.path) esiste già: rimuovilo o scegli un altro percorso")) {
            try await store.download(offer, to: destination) { _ in }
        }
        #expect(AppleCDNStub.requests.isEmpty)
        #expect(try Data(contentsOf: destination) == body)
    }

    @Test func secondDownloadOfTheSameFileIsRefusedWhileTheFirstRuns() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        var stopped = AppleCDNStub.File(body: body)
        stopped.stopAfter = 256 << 10
        AppleCDNStub.reset(routes: [Self.offerURL.absoluteString: .file(stopped)])
        let first = downloader(tmp)
        let destination = tmp.appendingPathComponent("mine.ipsw")
        let offer = offer
        let task = Task { try await first.download(offer, to: destination) { _ in } }
        try await waitForPartial(first, destination, 256 << 10)
        await #expect(throws: NidoError.downloadFailed("un altro download sta già scrivendo \(part(destination).path)")) {
            try await downloader(tmp).download(offer, to: destination) { _ in }
        }
        task.cancel()
        _ = await task.result
        #expect(try size(part(destination)) == 256 << 10)
    }

    @Test func contentRangeIsReadStrictly() {
        #expect(MacImageTransfer.parseContentRange("bytes 100-199/200")! == (100, 199, 200))
        #expect(MacImageTransfer.parseContentRange("bytes 100-199/*")! == (100, 199, nil))
        for bad in ["bytes 100-199/150", "bytes 200-100/300", "bytes -1/2", "items 0-1/2", "bytes 0-1", "bytes a-b/c"] {
            #expect(MacImageTransfer.parseContentRange(bad) == nil, "\(bad)")
        }
    }

    // MARK: - Fix round 1

    @Test func leftoverCheckFileBecomesThePartialAgain() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let store = downloader(tmp)
        let destination = tmp.appendingPathComponent("mine.ipsw")
        // A run stopped while checking (Ctrl-C): every byte and the sidecar, under the check name.
        try await makePartial(store, to: destination, bytes: body.count)
        try FileManager.default.moveItem(at: part(destination), to: check(destination))
        AppleCDNStub.reset()
        #expect(try await store.download(offer, to: destination) { _ in } == destination)
        #expect(AppleCDNStub.requests.isEmpty)
        #expect(try Data(contentsOf: destination) == body)
        #expect(listing(tmp) == ["mine.ipsw"])
    }

    @Test func leftoverCheckFileGoesWhenAPartialExists() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let store = downloader(tmp)
        let destination = tmp.appendingPathComponent("mine.ipsw")
        try await makePartial(store, to: destination, bytes: 256 << 10)
        try Data("junk".utf8).write(to: check(destination))
        AppleCDNStub.reset(routes: [Self.offerURL.absoluteString: .file(.init(body: body))])
        _ = try await store.download(offer, to: destination) { _ in }
        #expect(AppleCDNStub.requests.first?.range == "bytes=262144-")
        #expect(try Data(contentsOf: destination) == body)
        #expect(listing(tmp) == ["mine.ipsw"])
    }

    @Test func leftoverJunkCheckFileIsDownloadedAgain() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let destination = tmp.appendingPathComponent("mine.ipsw")
        try Data("junk".utf8).write(to: check(destination))
        AppleCDNStub.reset(routes: [Self.offerURL.absoluteString: .file(.init(body: body))])
        _ = try await downloader(tmp).download(offer, to: destination) { _ in }
        #expect(AppleCDNStub.requests == [.init(url: Self.offerURL, range: nil, ifRange: nil)])
        #expect(try Data(contentsOf: destination) == body)
        #expect(listing(tmp) == ["mine.ipsw"])
    }

    @Test func resumeFetchesTheTailAgain() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let destination = tmp.appendingPathComponent("mine.ipsw")
        try await makePartial(downloader(tmp), to: destination, bytes: 512 << 10)
        // The tail a power loss left unwritten: zeros where the bytes should be.
        let handle = try FileHandle(forWritingTo: part(destination))
        try handle.seek(toOffset: UInt64(400 << 10))
        try handle.write(contentsOf: Data(count: 112 << 10))
        try handle.close()
        AppleCDNStub.reset(routes: [Self.offerURL.absoluteString: .file(.init(body: body))])
        let progress = ProgressLog()
        _ = try await downloader(tmp, backoff: 256 << 10).download(offer, to: destination) { progress.append($0) }
        #expect(AppleCDNStub.requests.first?.range == "bytes=262144-")
        #expect(progress.all.first?.receivedBytes == 256 << 10)
        #expect(try Data(contentsOf: destination) == body)
    }

    @Test func partialShorterThanTheBackoffStartsOver() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let destination = tmp.appendingPathComponent("mine.ipsw")
        try await makePartial(downloader(tmp), to: destination, bytes: 256 << 10)
        AppleCDNStub.reset(routes: [Self.offerURL.absoluteString: .file(.init(body: body))])
        _ = try await downloader(tmp, backoff: 8 << 20).download(offer, to: destination) { _ in }
        #expect(AppleCDNStub.requests == [.init(url: Self.offerURL, range: nil, ifRange: nil)])
        #expect(try Data(contentsOf: destination) == body)
    }

    @Test func failedRequestDoesNotEatIntoThePartial() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let destination = tmp.appendingPathComponent("mine.ipsw")
        try await makePartial(downloader(tmp), to: destination, bytes: 512 << 10)
        AppleCDNStub.reset(routes: [Self.offerURL.absoluteString: .status(503)])
        let store = downloader(tmp, backoff: 256 << 10)
        for _ in 0..<2 {
            await #expect(throws: NidoError.self) { try await store.download(offer, to: destination) { _ in } }
        }
        #expect(try size(part(destination)) == 512 << 10)
    }

    @Test func rangeNotSatisfiableOnACompleteFileFinishesIt() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let store = downloader(tmp)
        let destination = tmp.appendingPathComponent("mine.ipsw")
        // No declared size: the sidecar cannot tell the file is complete; the server's 416 does.
        // 1 MiB exactly: progress reports land on its end.
        let exact = body.prefix(1 << 20)
        try await makePartial(store, to: destination, bytes: exact.count, file: .init(body: exact, omitLength: true))
        AppleCDNStub.reset(routes: [Self.offerURL.absoluteString: .file(.init(body: exact))])
        #expect(try await store.download(offer, to: destination) { _ in } == destination)
        #expect(AppleCDNStub.requests == [.init(url: Self.offerURL, range: "bytes=\(exact.count)-", ifRange: "\"etag-1\"")])
        #expect(try Data(contentsOf: destination) == exact)
    }

    @Test func rangeNotSatisfiableOnAShorterFileStartsOver() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let store = downloader(tmp)
        let destination = tmp.appendingPathComponent("mine.ipsw")
        try await makePartial(store, to: destination, bytes: 512 << 10)
        let shorter = body.prefix(100_000)
        AppleCDNStub.reset(routes: [Self.offerURL.absoluteString: .file(.init(body: shorter))])
        _ = try await store.download(offer, to: destination) { _ in }
        #expect(AppleCDNStub.requests == [
            .init(url: Self.offerURL, range: "bytes=524288-", ifRange: "\"etag-1\""),
            .init(url: Self.offerURL, range: nil, ifRange: nil),
        ])
        #expect(try Data(contentsOf: destination) == shorter)
    }

    @Test func sidecarOverTheCapIsNotResumed() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let destination = tmp.appendingPathComponent("mine.ipsw")
        try await makePartial(downloader(tmp), to: destination, bytes: 256 << 10)
        let forged = #"{"etag":"\"etag-1\"","expectedBytes":18446744073709551615,"url":"\#(Self.offerURL.absoluteString)"}"#
        try FileManager.default.removeItem(at: record(destination))
        try Data(forged.utf8).write(to: record(destination))
        AppleCDNStub.reset(routes: [Self.offerURL.absoluteString: .file(.init(body: body))])
        _ = try await downloader(tmp).download(offer, to: destination) { _ in }
        #expect(AppleCDNStub.requests == [.init(url: Self.offerURL, range: nil, ifRange: nil)])
        #expect(try Data(contentsOf: destination) == body)
    }

    @Test func sidecarForAnotherURLRestartsWithoutRange() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let destination = tmp.appendingPathComponent("mine.ipsw")
        try await makePartial(downloader(tmp), to: destination, bytes: 256 << 10)
        let otherURL = URL(string: "https://updates.cdn-apple.com/2026FallFCS/other/UniversalMac_27.2.1_26B131_Restore.ipsw")!
        let other = MacImageOffer(build: "26B131", version: "27.2.1", url: otherURL)
        AppleCDNStub.reset(routes: [otherURL.absoluteString: .file(.init(body: body))])
        _ = try await downloader(tmp).download(other, to: destination) { _ in }
        #expect(AppleCDNStub.requests == [.init(url: otherURL, range: nil, ifRange: nil)])
        #expect(try Data(contentsOf: destination) == body)
    }

    @Test func symlinkAtThePartialIsRefusedAndLeftAlone() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let destination = tmp.appendingPathComponent("mine.ipsw")
        let target = tmp.appendingPathComponent("precious")
        try Data("precious".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: part(destination), withDestinationURL: target)
        AppleCDNStub.reset(routes: [Self.offerURL.absoluteString: .file(.init(body: body))])
        await #expect(throws: NidoError.unsafePath(part(destination).path)) {
            try await downloader(tmp).download(offer, to: destination) { _ in }
        }
        #expect(AppleCDNStub.requests.isEmpty)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: part(destination).path) == target.path)
        #expect(try Data(contentsOf: target) == Data("precious".utf8))
    }

    @Test func symlinkAtTheSidecarIsNotFollowed() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let destination = tmp.appendingPathComponent("mine.ipsw")
        try await makePartial(downloader(tmp), to: destination, bytes: 256 << 10)
        let target = tmp.appendingPathComponent("precious.json")
        try FileManager.default.moveItem(at: record(destination), to: target)
        let saved = try Data(contentsOf: target)
        try FileManager.default.createSymbolicLink(at: record(destination), withDestinationURL: target)
        AppleCDNStub.reset(routes: [Self.offerURL.absoluteString: .file(.init(body: body))])
        _ = try await downloader(tmp).download(offer, to: destination) { _ in }
        // Not read (no resume), not written through: the target is unchanged.
        #expect(AppleCDNStub.requests == [.init(url: Self.offerURL, range: nil, ifRange: nil)])
        #expect(try Data(contentsOf: target) == saved)
        #expect(try Data(contentsOf: destination) == body)
    }

    @Test func symlinkAtTheDestinationIsRefused() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let destination = tmp.appendingPathComponent("mine.ipsw")
        let target = tmp.appendingPathComponent("precious")
        try Data("precious".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)
        AppleCDNStub.reset(routes: [Self.offerURL.absoluteString: .file(.init(body: body))])
        await #expect(throws: NidoError.unsafePath(destination.path)) {
            try await downloader(tmp).download(offer, to: destination) { _ in }
        }
        #expect(AppleCDNStub.requests.isEmpty)
        #expect(try Data(contentsOf: target) == Data("precious".utf8))
    }

    @Test func redirectToPlainHTTPOnAnAppleHostIsRefused() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let plain = URL(string: "http://updates.cdn-apple.com/UniversalMac.ipsw")!
        AppleCDNStub.reset(routes: [
            Self.offerURL.absoluteString: .redirect(plain),
            plain.absoluteString: .file(.init(body: body)),
        ])
        let destination = tmp.appendingPathComponent("mine.ipsw")
        await #expect(throws: NidoError.hostNotAllowed(plain.absoluteString)) {
            try await downloader(tmp).download(offer, to: destination) { _ in }
        }
        #expect(!AppleCDNStub.requests.map(\.url).contains(plain))
        #expect(listing(tmp).isEmpty)
    }

    @Test func checkURLKeepsTheExtension() {
        let destination = URL(fileURLWithPath: "/x/UniversalMac_27.2.1_26B131_Restore.ipsw")
        #expect(MacImageDownloader.checkURL(destination).path == "/x/.UniversalMac_27.2.1_26B131_Restore.checking.ipsw")
        #expect(MacImageDownloader.checkURL(URL(fileURLWithPath: "/x/image")).path == "/x/.image.checking")
    }

    // MARK: Fix wave

    @Test func offerOfANewerMajorOrOverTheCapIsRefusedBeforeDownloading() throws {
        let newer = MacImageOffer(build: "30A1", version: "30.0", url: Self.offerURL)
        #expect(newer.majorVersion == 30)
        #expect(throws: NidoError.restoreImageUnsupported(version: "30.0", requiredHostMajor: 30)) {
            try MacImageDownloader.checkOffer(newer, size: 1 << 30, hostVersion: Self.host)
        }
        // Same major (a newer minor) and a smaller one pass; so does an unknown size.
        try MacImageDownloader.checkOffer(offer, size: 18 << 30, hostVersion: Self.host)
        try MacImageDownloader.checkOffer(
            MacImageOffer(build: "1", version: "26.6", url: Self.offerURL), size: nil, hostVersion: Self.host)
        #expect(throws: NidoError.downloadFailed("immagine oltre il limite di 40 GiB")) {
            try MacImageDownloader.checkOffer(offer, size: (40 << 30) + 1, hostVersion: Self.host)
        }
        try MacImageDownloader.checkOffer(offer, size: 40 << 30, hostVersion: Self.host)
    }

    @Test func everyFailedCheckSaysTheFileWasDeleted() async throws {
        // The file loads but is for a newer macOS than the host: refused and deleted, and it says so.
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        AppleCDNStub.reset(routes: [Self.offerURL.absoluteString: .file(.init(body: body))])
        let old = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        let store = MacImageDownloader(
            session: makeSession(), cacheRoot: tmp, loader: FakeRestoreImageLoader(build: "26B131"),
            availableSpace: Self.plenty, hostVersion: old, writeChunk: MacImageDownloader.writeAll, resumeBackoff: 0)
        let destination = tmp.appendingPathComponent("mine.ipsw")
        await #expect(throws: NidoError.downloadFailed(
            "il macOS 27.2.1 scaricato non può essere installato su questo Mac: è stato eliminato")
        ) {
            try await store.download(offer, to: destination) { _ in }
        }
        #expect(listing(tmp) == [])
    }

    @Test func resumedAnswerWithAnotherTotalDropsThePartial() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let store = downloader(tmp)
        let destination = tmp.appendingPathComponent("mine.ipsw")
        try await makePartial(store, to: destination, bytes: 512 << 10)
        AppleCDNStub.reset(routes: [Self.offerURL.absoluteString: .file(.init(
            body: body, contentRange: "bytes 524288-\(body.count + 99)/\(body.count + 100)"))])
        await #expect(throws: NidoError.downloadFailed(
            "il server ha ripreso il download dal punto sbagliato: il file parziale è stato eliminato, riprova")
        ) {
            try await store.download(offer, to: destination) { _ in }
        }
        #expect(!exists(part(destination)) && !exists(record(destination)) && !exists(destination))
    }

    @Test func otherCachedFilesAreListedNeverDeleted() async throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let store = downloader(tmp)
        let macos = tmp.appendingPathComponent("macos", isDirectory: true)
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        let destination = macos.appendingPathComponent("mine.ipsw")
        try Data(count: 10).write(to: macos.appendingPathComponent("UniversalMac_26.0_Restore.ipsw"))
        try Data(count: 20).write(to: macos.appendingPathComponent(".Old.ipsw.part"))
        try Data("{}".utf8).write(to: macos.appendingPathComponent(".Old.ipsw.part.json"))
        try Data(count: 5).write(to: part(destination))
        try Data("{}".utf8).write(to: record(destination))
        let files = store.otherCachedFiles(besides: destination)
        #expect(files.map(\.name) == [".Old.ipsw.part", "UniversalMac_26.0_Restore.ipsw"])
        #expect(files.map(\.bytes) == [20, 10])
        #expect(listing(macos).count == 5)
    }

    @Test func outputIsCheckedWithoutAnOffer() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let store = downloader(tmp)
        #expect(try store.outputDestination(tmp.appendingPathComponent("new.ipsw")) == tmp.appendingPathComponent("new.ipsw"))
        try Data().write(to: tmp.appendingPathComponent("there.ipsw"))
        #expect(throws: NidoError.self) { try store.outputDestination(tmp.appendingPathComponent("there.ipsw")) }
        #expect(throws: NidoError.notFound(tmp.appendingPathComponent("nope").path)) {
            try store.outputDestination(tmp.appendingPathComponent("nope/a.ipsw"))
        }
        try FileManager.default.createSymbolicLink(
            at: tmp.appendingPathComponent("link.ipsw"), withDestinationURL: tmp.appendingPathComponent("x"))
        #expect(throws: NidoError.unsafePath(tmp.appendingPathComponent("link.ipsw").path)) {
            try store.outputDestination(tmp.appendingPathComponent("link.ipsw"))
        }
    }
}
