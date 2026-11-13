// SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Foundation
import NidoCore
import Synchronization
import Testing

@testable import Nido

/// Answers the image requests of the wizard tests without any network: `ok` with a body,
/// `held` never answers (until the request is cancelled). Every request is logged.
final class WizardStubProtocol: URLProtocol {
    enum Route: Sendable {
        case ok(Data)
        case held
    }

    private struct State {
        var routes: [String: Route] = [:]
        var log: [URL] = []
        var heldWaiters: [CheckedContinuation<Void, Never>] = []
        var held = 0
    }

    private static let state = Mutex(State())

    static func reset(_ routes: [String: Route]) {
        state.withLock { $0 = State(routes: routes) }
    }

    static var requests: [URL] { state.withLock { $0.log } }

    /// Suspends until a request on a `held` route has arrived.
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

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let (route, waiters) = Self.state.withLock { s -> (Route?, [CheckedContinuation<Void, Never>]) in
            s.log.append(url)
            let route = s.routes[url.absoluteString]
            guard case .held = route else { return (route, []) }
            s.held += 1
            defer { s.heldWaiters = [] }
            return (route, s.heldWaiters)
        }
        switch route {
        case .ok(let data):
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": String(data.count)])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .held:
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "1000000"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(repeating: 1, count: 1000))
            waiters.forEach { $0.resume() }
        case nil:
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

/// Records the creation requests; `failure` makes them throw.
final class FakeCreator: VMCreating {
    struct TemplateRequest: Equatable {
        let template: String
        let name: String
        let sshKeyPath: URL?
    }

    private let state = Mutex<(requests: [LinuxVMRequest], templates: [TemplateRequest], failure: NidoError?)>(
        ([], [], nil))

    var requests: [LinuxVMRequest] { state.withLock { $0.requests } }
    var templateRequests: [TemplateRequest] { state.withLock { $0.templates } }
    func fail(with error: NidoError?) { state.withLock { $0.failure = error } }

    func createFromTemplate(_ template: VMName, as name: VMName, sshKeyPath: URL?) async throws {
        try state.withLock { s in
            if let failure = s.failure { throw failure }
            s.templates.append(TemplateRequest(template: template.rawValue, name: name.rawValue, sshKeyPath: sshKeyPath))
        }
    }

    func create(_ request: LinuxVMRequest) async throws {
        try state.withLock { s in
            if let failure = s.failure { throw failure }
            s.requests.append(request)
        }
    }
}

let validPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOO97YvP4YWGQwUFq+UeOnyDKkD29RZ8VdmeuGgPzeS6 me@mac"

/// The stub routes share global state: the tests that use them run one at a time.
@MainActor
@Suite(.serialized)
final class WizardModelTests {
    let tmp: URL
    let image = CloudImageCatalog.debian13
    let payload = Data(repeating: 7, count: 4096)

    init() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-wizard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: tmp) }

    var cache: URL { tmp.appendingPathComponent("images", isDirectory: true) }

    func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WizardStubProtocol.self]
        return URLSession(configuration: config)
    }

    /// Debian's list: the image and its build manifest (`manifest(for:version:)`).
    func sums(for data: Data, version: String = "20261103-2651") -> Data {
        let digest = SHA512.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let manifestDigest = SHA512.hash(data: manifest(for: data, version: version)).map { String(format: "%02x", $0) }.joined()
        return Data("\(digest)  \(image.fileName)\n\(manifestDigest)  \(image.manifest!.fileName)\n".utf8)
    }

    /// Debian's build manifest giving `data` as the raw image of build `version`.
    func manifest(for data: Data, version: String = "20261103-2651") -> Data {
        let digest = Data(SHA512.hash(data: data)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return Data("""
            {"items": [
              {"kind": "Build", "data": {"info": {"version": "\(version)"}}},
              {"kind": "Upload", "metadata": {
                "annotations": {"cloud.debian.org/digest": "sha512:\(digest)"},
                "labels": {"cloud.debian.org/version": "\(version)", "upload.cloud.debian.org/image-format": "raw"}}}
            ]}
            """.utf8)
    }

    func writeKey(_ text: String, name: String = "id_ed25519.pub") throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    func makeModel(registry: FakeRegistry = FakeRegistry(), creator: FakeCreator = FakeCreator(),
                   keyURL: URL? = nil, physicalMemory: UInt64 = 32 << 30, hostCores: Int = 8,
                   checkHeadroom: (@Sendable (UInt64) async -> MemoryHeadroom?)? = nil) -> WizardModel {
        let store = ImageStore(cacheRoot: cache, session: session())
        return WizardModel(
            registry: registry, images: .catalog(image, store: store, cacheRoot: cache), creator: creator,
            defaultKeyURL: keyURL, physicalMemory: physicalMemory, hostCores: hostCores,
            checkHeadroom: checkHeadroom)
    }

    @Test func smallerMemoryDefaultOn16GiBMacs() {
        let small = makeModel(physicalMemory: 16 << 30)
        #expect(small.memoryGiB == 2)
        #expect(small.memoryDetail.hasPrefix("Consigliati 2 GiB"))
        let large = makeModel(physicalMemory: 32 << 30)
        #expect(large.memoryGiB == 4)
        #expect(large.memoryDetail.hasPrefix("Consigliati 4 GiB"))
        // Always editable.
        small.stepMemory(by: 2)
        #expect(small.memoryGiB == 4)
    }

    func listing(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    // MARK: - Tests

    @Test func defaultsAreValid() async throws {
        WizardStubProtocol.reset([
            image.checksumsURL.absoluteString: .ok(sums(for: payload)),
            image.manifest!.url.absoluteString: .ok(manifest(for: payload)),
            image.url.absoluteString: .ok(payload),
        ])
        let key = try writeKey(validPublicKey)
        let model = makeModel(keyURL: key)
        await model.load()

        #expect(model.step == .system)
        #expect(model.name == "debian-13")
        #expect(model.cpuCount == 2)
        #expect(model.memoryGiB == 4)
        #expect(model.diskGiB == 16)
        #expect(model.publicKeyURL == key)
        #expect(model.nextBlocker == nil)

        await model.next()  // Sistema → Download (asks first)
        #expect(model.step == .download)
        #expect(model.phase == .confirmingDownload)
        #expect(WizardStubProtocol.requests.isEmpty, "Nessuna richiesta prima di Scarica")
        await model.next()  // Scarica → Risorse
        #expect(model.step == .resources)
        #expect(model.nextBlocker == nil)
        await model.next()
        #expect(model.step == .access)
        #expect(model.nextBlocker == nil)
        await model.next()
        #expect(model.step == .summary)
        #expect(model.nextBlocker == nil)
    }

    @Test func confirmationShowsHostAndUpperBoundBeforeAnyRequest() async throws {
        WizardStubProtocol.reset([:])
        let model = makeModel()
        await model.next()
        let rows = model.downloadRows
        #expect(rows.first { $0.label == "Origine" }?.value == "cloud.debian.org")
        #expect(rows.first { $0.label == "File" }?.value == image.fileName)
        #expect(rows.first { $0.label == "Dimensione" }?.value == "fino a 8 GiB da scaricare")
        #expect(model.nextLabel == "Scarica")
        #expect(WizardStubProtocol.requests.isEmpty)
    }

    @Test func nameCollisionSuggestsSuffix() async {
        let rows = ["debian-13", "Debian-13-2", "web"].map {
            VMSummary(configID: UUID(), name: $0, status: .stopped, cpuCount: 2, memoryBytes: 4 << 30,
                      diskBytes: 16 << 30)
        }
        let model = makeModel(registry: FakeRegistry(rows))
        await model.load()
        #expect(model.name == "debian-13-3")
        #expect(WizardModel.suggestedName(existing: []) == "debian-13")
        #expect(WizardModel.suggestedName(existing: ["DEBIAN-13"]) == "debian-13-2")

        // A taken name typed by hand blocks the summary step.
        model.name = "WEB"
        model.step = .summary
        #expect(model.nextBlocker == "Esiste già una VM chiamata WEB.")
        model.name = "nome non valido"
        #expect(model.nextBlocker?.hasPrefix("Nome VM non valido") == true)
    }

    @Test func outOfLimitResourcesDisableNext() async throws {
        let model = makeModel(keyURL: try writeKey(validPublicKey))
        model.step = .resources
        #expect(model.nextBlocker == nil)

        model.cpuCount = ResourceLimits.cpuCountRange.upperBound + 1
        #expect(model.cpuError != nil)
        #expect(model.nextBlocker != nil)
        model.cpuCount = 2

        let maxGiB = Int(ResourceLimits.memoryRange.upperBound >> 30)
        model.memoryGiB = maxGiB + 1
        #expect(model.memoryError == "Oltre il limite: su questo Mac al massimo \(maxGiB) GiB.")
        #expect(model.nextBlocker != nil)
        await model.next()
        #expect(model.step == .resources, "Avanti non deve proseguire")
        model.memoryGiB = 4

        // The disk is a clone of the image: never smaller than it (the CLI and VMFactory rule).
        model.imageBytes = 3 << 30
        model.diskGiB = 2
        #expect(model.diskError == "Il disco deve contenere l'immagine: almeno 3 GiB.")
        #expect(model.nextBlocker != nil)
        model.diskGiB = 16
        #expect(model.nextBlocker == nil)

        #expect(model.cpuDetail.hasSuffix("al massimo \(ResourceLimits.maxCPUCount()) (core di questo Mac)"))
        model.cpuCount = ResourceLimits.cpuCountRange.upperBound + 1
        #expect(model.cpuError == "Oltre il limite: al massimo \(ResourceLimits.maxCPUCount()) (core di questo Mac).")
        model.cpuCount = 2
    }

    @Test func hugeDiskIsRejectedNotWrapped() async throws {
        let model = makeModel(keyURL: try writeKey(validPublicKey))
        model.step = .resources
        // The number is grouped the way the locale groups digits (the tests run in it_IT).
        #expect(WizardModel.maxDiskGiB == 17_179_869_183)
        let tooBig = "Dimensione del disco troppo grande: al massimo 17.179.869.183 GiB."
        // 2^34 GiB is 2^64 bytes: it used to wrap to 0; 2^34 + 16 used to become a 16 GiB request.
        for gib in [1 << 34, (1 << 34) + 16, Int.max] {
            model.diskGiB = gib
            #expect(model.diskBytes == nil)
            #expect(model.diskError == tooBig)
            #expect(model.nextBlocker == tooBig)
        }
        // The steppers saturate instead of trapping.
        model.stepDisk(by: 1)
        #expect(model.diskGiB == WizardModel.maxDiskGiB)
        #expect(model.diskBytes == UInt64(WizardModel.maxDiskGiB) << 30)
        model.cpuCount = .max
        model.stepCPU(by: 1)
        #expect(model.cpuCount == ResourceLimits.cpuCountRange.upperBound)
        model.diskGiB = WizardModel.maxDiskGiB + 1
        #expect(model.diskError == tooBig)
    }

    @Test func privateKeyIsRejected() async throws {
        let privateKey = try writeKey("-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----\n",
                                      name: "id_ed25519_private.pub")
        // Never preselected…
        let model = makeModel(keyURL: privateKey)
        #expect(model.publicKeyURL == nil)
        model.step = .access
        #expect(model.nextBlocker == "Scegli una chiave SSH pubblica.")

        // …and refused when chosen, with the Italian reason under the field.
        model.choosePublicKey(privateKey)
        #expect(model.publicKeyURL == nil)
        #expect(model.keyError == "Questo file sembra una chiave privata: scegli il file .pub.")
        #expect(model.nextBlocker != nil)

        let good = try writeKey(validPublicKey)
        model.choosePublicKey(good)
        #expect(model.publicKeyURL == good)
        #expect(model.keyError == nil)
        #expect(model.keySummary == "\(good.path) · ssh-ed25519")
        #expect(model.nextBlocker == nil)
    }

    @Test func declinedDownloadReturnsToSystemStep() async throws {
        WizardStubProtocol.reset([
            image.checksumsURL.absoluteString: .ok(sums(for: payload)),
            image.manifest!.url.absoluteString: .ok(manifest(for: payload)),
            image.url.absoluteString: .ok(payload),
        ])
        let model = makeModel()
        await model.next()
        #expect(model.phase == .confirmingDownload)

        model.back()  // "Indietro" on the confirmation: the download is declined

        #expect(model.step == .system)
        #expect(model.phase == .idle)
        #expect(WizardStubProtocol.requests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    @Test func checksumFailureShowsRetry() async throws {
        WizardStubProtocol.reset([
            image.checksumsURL.absoluteString: .ok(sums(for: Data("altro".utf8))),
            image.manifest!.url.absoluteString: .ok(manifest(for: Data("altro".utf8))),
            image.url.absoluteString: .ok(payload),
        ])
        let model = makeModel()
        await model.next()
        await model.next()  // Scarica

        #expect(model.step == .download)
        guard case .failed(let message) = model.phase else {
            Issue.record("phase \(model.phase)")
            return
        }
        #expect(message.hasPrefix("Il checksum SHA-512 non corrisponde"))
        #expect(model.nextLabel == "Riprova")
        #expect(model.nextBlocker == nil)
        #expect(listing(cache).filter { $0.hasSuffix(".part") }.isEmpty)

        // Riprova downloads again, from scratch (a new build: the same build with another
        // digest is refused, `ImageStore.acceptBuild`).
        WizardStubProtocol.reset([
            image.checksumsURL.absoluteString: .ok(sums(for: payload, version: "20261110-2700")),
            image.manifest!.url.absoluteString: .ok(manifest(for: payload, version: "20261110-2700")),
            image.url.absoluteString: .ok(payload),
        ])
        await model.next()
        #expect(model.step == .resources)
        #expect(model.imageBytes == UInt64(payload.count))
        #expect(WizardStubProtocol.requests == [image.checksumsURL, image.manifest!.url, image.url])
    }

    @Test func cancelDuringDownloadStopsItAndLeavesNoPartFile() async throws {
        WizardStubProtocol.reset([
            image.checksumsURL.absoluteString: .ok(sums(for: payload)),
            image.manifest!.url.absoluteString: .ok(manifest(for: payload)),
            image.url.absoluteString: .held,
        ])
        var closed = false
        let model = makeModel()
        model.onClose = { closed = true }
        await model.next()
        let running = Task { await model.next() }
        await WizardStubProtocol.waitUntilHeld()
        #expect(model.phase == .downloading)

        model.cancel()
        await running.value
        await model.waitForCleanup()

        #expect(closed)
        #expect(model.step == .download)
        #expect(listing(cache).filter { $0.hasSuffix(".part") }.isEmpty)
        #expect(!listing(cache).contains(image.fileName))
    }

    /// "Indietro" during the download: the same cancellation as Annulla (no request left, no
    /// `.part`), then back to the System step with the wizard still open.
    @Test func backDuringDownloadCancelsAndReturns() async throws {
        WizardStubProtocol.reset([
            image.checksumsURL.absoluteString: .ok(sums(for: payload)),
            image.manifest!.url.absoluteString: .ok(manifest(for: payload)),
            image.url.absoluteString: .held,
        ])
        var closed = false
        let model = makeModel()
        model.onClose = { closed = true }
        await model.next()
        let running = Task { await model.next() }
        await WizardStubProtocol.waitUntilHeld()
        #expect(model.phase == .downloading)
        #expect(model.canGoBack, "Indietro è attivo durante il download")

        model.back()
        #expect(model.step == .system)
        #expect(model.phase == .idle)
        await running.value
        await model.waitForCleanup()

        #expect(!closed, "Indietro non chiude la procedura")
        #expect(model.step == .system)
        #expect(model.phase == .idle)
        #expect(model.progress == nil)
        #expect(model.remainingTime == nil)
        #expect(listing(cache).filter { $0.hasSuffix(".part") }.isEmpty)
        #expect(!listing(cache).contains(image.fileName))

        // Avanti again asks before downloading: nothing is fetched by itself.
        let before = WizardStubProtocol.requests.count
        await model.next()
        #expect(model.step == .download)
        #expect(model.phase == .confirmingDownload)
        #expect(WizardStubProtocol.requests.count == before)
    }

    /// Indietro during a download, then Scarica again and Annulla while the new Scarica waits for
    /// the old cleanup: nothing is downloaded after the wizard closed.
    @Test func cancelAfterBackStartsNoDownload() async throws {
        WizardStubProtocol.reset([
            image.checksumsURL.absoluteString: .ok(sums(for: payload)),
            image.manifest!.url.absoluteString: .ok(manifest(for: payload)),
            image.url.absoluteString: .held,
        ])
        var closed = false
        let model = makeModel()
        model.onClose = { closed = true }
        await model.next()  // Download step
        let first = Task { await model.next() }  // Scarica
        await WizardStubProtocol.waitUntilHeld()

        model.back()
        await model.next()  // Download step again: asks before downloading
        #expect(model.phase == .confirmingDownload)
        let second = Task { await model.next() }  // Scarica again: waits for the old cleanup
        while model.phase != .downloading { await Task.yield() }
        let requestsAtCancel = WizardStubProtocol.requests.count

        model.cancel()  // Annulla while the second Scarica waits
        await first.value
        await second.value
        await model.waitForCleanup()

        #expect(closed)
        #expect(model.isClosed)
        #expect(WizardStubProtocol.requests.count == requestsAtCancel, "\(WizardStubProtocol.requests)")
        #expect(listing(cache).filter { $0.hasSuffix(".part") }.isEmpty)
        #expect(!listing(cache).contains(image.fileName))
        // A late Avanti does nothing either.
        await model.next()
        #expect(WizardStubProtocol.requests.count == requestsAtCancel)
    }

    /// The checksum comparison can be left with Indietro too (not the creation).
    @Test func backIsEnabledWhileVerifyingButNotWhileCreating() {
        let model = makeModel()
        model.apply(.downloadVerify)
        #expect(model.canGoBack)
        model.back()
        #expect(model.step == .system)
        #expect(model.phase == .idle)
        model.apply(.creating)
        #expect(!model.canGoBack)
    }

    @Test func createAndStartOpensTheVMWindow() async throws {
        let key = try writeKey(validPublicKey)
        let creator = FakeCreator()
        var opened: [String] = []
        let local = tmp.appendingPathComponent("base.raw")
        try Data(repeating: 0, count: 1 << 20).write(to: local)
        let model = WizardModel(registry: FakeRegistry(), images: .localFile(local), creator: creator,
                                defaultKeyURL: key, physicalMemory: 32 << 30)
        model.onCreated = { opened.append($0.rawValue) }
        await model.load()
        for _ in 0..<5 { await model.next() }  // Avanti, Scarica, Avanti, Avanti, Crea e avvia

        #expect(model.phase == .done(try VMName("debian-13")))
        #expect(opened == ["debian-13"])
        let request = try #require(creator.requests.first)
        #expect(request.name.rawValue == "debian-13")
        #expect(request.baseImage == local)
        #expect(request.cpuCount == 2)
        #expect(request.memoryBytes == 4 << 30)
        #expect(request.diskBytes == 16 << 30)
        #expect(request.publicKey == validPublicKey.split(separator: " ").prefix(2).joined(separator: " "))
    }

    @Test func creationFailureShowsRetry() async throws {
        let creator = FakeCreator()
        creator.fail(with: .processFailed(executable: "hdiutil", status: 1))
        let local = tmp.appendingPathComponent("base.raw")
        try Data(repeating: 0, count: 1 << 20).write(to: local)
        let model = WizardModel(registry: FakeRegistry(), images: .localFile(local), creator: creator,
                                defaultKeyURL: try writeKey(validPublicKey))
        await model.load()
        for _ in 0..<5 { await model.next() }
        #expect(model.phase == .failed("Hdiutil è terminato con stato 1."))
        #expect(model.step == .summary)
        #expect(model.nextLabel == "Riprova")

        creator.fail(with: nil)
        await model.next()
        #expect(model.phase == .done(try VMName("debian-13")))
    }

    @Test func nameTakenAtCreationReturnsToTheEditableName() async throws {
        // Another VM called debian-13 appeared after the wizard opened (e.g. `nido create`).
        let creator = FakeCreator()
        creator.fail(with: .alreadyExists("debian-13"))
        let local = tmp.appendingPathComponent("base.raw")
        try Data(repeating: 0, count: 1 << 20).write(to: local)
        let model = WizardModel(registry: FakeRegistry(), images: .localFile(local), creator: creator,
                                defaultKeyURL: try writeKey(validPublicKey))
        await model.load()
        for _ in 0..<5 { await model.next() }

        #expect(model.step == .summary)
        #expect(model.phase == .idle, "Il campo del nome deve tornare modificabile")
        #expect(model.nextLabel == "Crea e avvia")
        #expect(model.nextBlocker == "Esiste già una VM chiamata debian-13.")
        #expect(!model.isNextEnabled)

        creator.fail(with: nil)
        model.name = "debian-13-2"
        #expect(model.isNextEnabled)
        await model.next()
        #expect(model.phase == .done(try VMName("debian-13-2")))
        #expect(creator.requests.map(\.name.rawValue) == ["debian-13-2"])
    }

    @Test func doubleClickStartsOneRun() async throws {
        let creator = FakeCreator()
        let local = tmp.appendingPathComponent("base.raw")
        try Data(repeating: 0, count: 1 << 20).write(to: local)
        let model = WizardModel(registry: FakeRegistry(), images: .localFile(local), creator: creator,
                                defaultKeyURL: try writeKey(validPublicKey))
        await model.load()
        await model.next()  // → Download

        // Two Scarica clicks queued back to back: one download, one step forward.
        let downloads = [Task { await model.next() }, Task { await model.next() }]
        for task in downloads { await task.value }
        #expect(model.step == .resources)

        await model.next()
        await model.next()  // → Riepilogo
        #expect(model.step == .summary)
        let creations = [Task { await model.next() }, Task { await model.next() }]
        for task in creations { await task.value }
        #expect(creator.requests.count == 1)
        #expect(model.phase == .done(try VMName("debian-13")))
    }

    @Test func imageFileArgumentIsDebugOnly() throws {
        let args = ["Nido", "-NidoImageFile", "/tmp/base.raw"]
        #expect(try AppEnvironment.resolveImageFile(arguments: args, isDebug: true)?.path == "/tmp/base.raw")
        #expect(try AppEnvironment.resolveImageFile(arguments: args, isDebug: false) == nil)
        #expect(try AppEnvironment.resolveImageFile(arguments: ["Nido"], isDebug: true) == nil)
        #expect(throws: AppEnvironment.LaunchError.relativePath("base.raw")) {
            try AppEnvironment.resolveImageFile(arguments: ["Nido", "-NidoImageFile", "base.raw"], isDebug: true)
        }
        #expect(throws: AppEnvironment.LaunchError.missingValue("-NidoImageFile")) {
            try AppEnvironment.resolveImageFile(arguments: ["Nido", "-NidoImageFile"], isDebug: true)
        }
    }

    // MARK: - Screenshot fixtures (DEBUG)

    @Test func fixturesSetTheDesignStates() throws {
        let key = try writeKey("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOO97YvP4YWGQwUFq+UeOnyDKkD29RZ8VdmeuGgPzeS6 test\n")
        let model = makeModel(keyURL: key)

        model.apply(.downloadProgress)
        #expect(model.step == .download)
        #expect(model.phase == .downloading)
        #expect(model.progressDetail.hasSuffix(" · 409,6 MiB di 1,2 GiB · circa 2 min"), "\(model.progressDetail)")
        #expect(abs((model.progressFraction ?? 0) - 1.0 / 3.0) < 0.001)
        #expect(!model.isNextEnabled)

        model.apply(.downloadChecksumError)
        #expect(model.nextLabel == "Riprova")

        model.apply(.resourcesOverLimit)
        #expect(model.step == .resources)
        #expect(model.memoryError != nil)
        #expect(model.cpuError == nil)

        model.apply(.summary)
        #expect(model.step == .summary)
        #expect(model.isNextEnabled, "Riepilogo: \(model.nextBlocker ?? "")")
        #expect(model.nextLabel == "Crea e avvia")

        model.apply(.creating)
        #expect(model.isBusy)
        #expect(!model.canCancel)
    }

    @Test func fixtureNamesAreTheLaunchValues() {
        #expect(WizardModel.Fixture(rawValue: "download-checksum-error") == .downloadChecksumError)
        #expect(WizardModel.Fixture(rawValue: "boh") == nil)
    }

    // MARK: - Progress and phase texts

    /// Progress never goes back: a late, smaller update is ignored, and the verification phase
    /// never returns to the download.
    @Test func progressIsMonotonic() throws {
        let model = makeModel()
        model.apply(.downloadProgress)  // 409,6 MiB of 1,2 GiB, attempt 0
        let total: UInt64 = 1_288_490_189
        model.receive(DownloadProgress(receivedBytes: 100 << 20, expectedBytes: total), attempt: 0)
        #expect(model.progress?.receivedBytes == 429_496_730)
        model.receive(DownloadProgress(receivedBytes: total, expectedBytes: total), attempt: 0)
        #expect(model.phase == .verifying)
        model.receive(DownloadProgress(receivedBytes: 500 << 20, expectedBytes: total), attempt: 0)
        #expect(model.phase == .verifying)
        #expect(model.progress?.receivedBytes == total)
        // An update of an older attempt is ignored too.
        model.receive(DownloadProgress(receivedBytes: total, expectedBytes: total), attempt: 7)
        #expect(model.phase == .verifying)
    }

    /// The time left comes from the average speed of the last 5 s; unknown speed hides it.
    @Test func remainingTimeFromMovingAverage() throws {
        let model = makeModel()
        model.apply(.downloadProgress)
        let mib: UInt64 = 1 << 20
        let total: UInt64 = 2 << 30
        // The fixture shows the render's "circa 2 min" (7 MiB/s, 0,8 GiB left).
        #expect(model.progressDetail.hasSuffix(" · circa 2 min"), "\(model.progressDetail)")
        let start = ContinuousClock.now + .seconds(60)
        var clock = start
        model.now = { clock }
        model.receive(DownloadProgress(receivedBytes: 410 * mib, expectedBytes: total), attempt: 0, at: start)
        // A fast burst long ago (outside the 5 s window): it must not count.
        let t = start + .seconds(30)
        model.receive(DownloadProgress(receivedBytes: 900 * mib, expectedBytes: total), attempt: 0,
                      at: start + .seconds(1))
        // Then a constant 10 MiB/s, ending with exactly 1 GiB left.
        for k in stride(from: 8, through: 0, by: -1) {
            let received = (1 << 30) - UInt64(k) * 10 * mib
            model.receive(DownloadProgress(receivedBytes: received, expectedBytes: total), attempt: 0,
                          at: t - .seconds(k))
        }
        clock = t
        let left = try #require(model.remainingTime)
        // 1 GiB at 10 MiB/s = 102.4 s.
        #expect(abs(left / .seconds(1) - 102.4) < 1, "\(left)")
        #expect(model.progressDetail.hasSuffix(" · circa 2 min"), "\(model.progressDetail)")

        // A full stall: no update at all, the clock goes on. Within the window the estimate stays,
        // once the last sample is older than 5 s it goes.
        clock = t + .seconds(4)
        #expect(model.remainingTime != nil)
        clock = t + .seconds(6)
        #expect(model.remainingTime == nil)
        #expect(!model.progressDetail.contains("circa"), "\(model.progressDetail)")

        // No bytes in the last 5 s: speed zero, no estimate.
        let now = t + .seconds(200)
        clock = now + .seconds(2)
        model.receive(DownloadProgress(receivedBytes: 1 << 30, expectedBytes: total), attempt: 0, at: now)
        model.receive(DownloadProgress(receivedBytes: 1 << 30, expectedBytes: total), attempt: 0,
                      at: now + .seconds(2))
        #expect(model.remainingTime == nil)
        #expect(!model.progressDetail.contains("circa"), "\(model.progressDetail)")
    }

    @Test func remainingTimeWording() {
        #expect(WizardModel.remainingText(.seconds(102)) == "circa 2 min")
        #expect(WizardModel.remainingText(.seconds(59)) == "meno di un minuto")
        #expect(WizardModel.remainingText(.seconds(60)) == "circa 1 min")
        #expect(WizardModel.remainingText(.seconds(3600)) == "circa 60 min")
    }

    /// The SHA-512 is computed while the image streams in: what is left is the comparison.
    @Test func verificationPhaseSaysWhatHappens() {
        let model = makeModel()
        model.apply(.downloadVerify)
        #expect(model.progressDetail.hasPrefix("Verifica del checksum SHA-512"), "\(model.progressDetail)")
    }

    /// The cached image size is read when the wizard loads or the Download step is entered,
    /// never while the view draws.
    @Test func cachedImageSizeIsReadOnStepEntryOnly() async throws {
        let model = makeModel()
        await model.load()
        #expect(model.systemDetail(for: .debian13) == "arm64 · immagine cloud")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try payload.write(to: cache.appendingPathComponent(image.fileName))
        try Data("x\n".utf8).write(to: cache.appendingPathComponent(image.fileName + ".sha512"))
        #expect(model.systemDetail(for: .debian13) == "arm64 · immagine cloud", "Nessuna lettura dal disco nel body")
        await model.next()  // enters Download
        #expect(model.systemDetail(for: .debian13) == "arm64 · nella cache")
        #expect(model.downloadRows.first { $0.label == "Dimensione" }?.value.hasPrefix("4 KiB nella cache") == true)
    }

    /// "Cerca una nuova build": only on click, only the checksum list; a new build makes Scarica
    /// replace the cached copy.
    @Test func newBuildOfTheCachedImage() async throws {
        let model = makeModel()
        await model.load()
        WizardStubProtocol.reset([
            image.checksumsURL.absoluteString: .ok(sums(for: payload)),
            image.manifest!.url.absoluteString: .ok(manifest(for: payload)),
            image.url.absoluteString: .ok(payload),
        ])
        await model.next()  // Download: nothing cached, no notice
        #expect(model.buildNotice == nil)
        await model.next()  // Scarica
        #expect(model.step == .resources)
        #expect(model.buildNotice == nil, "Image already used in this session")

        // A fresh wizard finds it in the cache: the check is offered, nothing requested yet.
        WizardStubProtocol.reset([:])
        let fresh = makeModel()
        await fresh.load()
        await fresh.next()
        #expect(fresh.buildNotice?.actionLabel == "Cerca una nuova build")
        #expect(WizardStubProtocol.requests.isEmpty)

        // Same build published.
        WizardStubProtocol.reset([
            image.checksumsURL.absoluteString: .ok(sums(for: payload)),
            image.manifest!.url.absoluteString: .ok(manifest(for: payload)),
        ])
        await fresh.checkForNewBuild()
        #expect(fresh.buildCheck == .current)
        #expect(fresh.buildNotice?.title == "La copia nella cache è la build attuale.")
        #expect(WizardStubProtocol.requests == [image.checksumsURL, image.manifest!.url])

        // A new build: the notice says so and Scarica downloads it.
        let newBuild = Data(repeating: 9, count: 4096)
        let other = makeModel()
        await other.load()
        await other.next()
        WizardStubProtocol.reset([
            image.checksumsURL.absoluteString: .ok(sums(for: newBuild, version: "20261110-2700")),
            image.manifest!.url.absoluteString: .ok(manifest(for: newBuild, version: "20261110-2700")),
            image.url.absoluteString: .ok(newBuild),
        ])
        await other.checkForNewBuild()
        #expect(other.buildCheck == .updateAvailable)
        // Indietro and Avanti keep the result: Scarica still replaces the cached copy.
        other.back()
        await other.next()
        #expect(other.step == .download)
        #expect(other.buildCheck == .updateAvailable)
        #expect(other.downloadRows.first { $0.label == "Dimensione" }?.value.hasSuffix("· nuova build") == true)
        await other.next()  // Scarica
        #expect(other.step == .resources)
        #expect(try Data(contentsOf: cache.appendingPathComponent(image.fileName)) == newBuild)
        #expect(other.buildCheck == .idle)

        // Another distribution is another image: the result does not carry over.
        other.selectDistribution(.ubuntu2404)
        #expect(other.buildCheck == .idle)

        // A failed check can be retried.
        let failing = makeModel()
        await failing.load()
        await failing.next()
        WizardStubProtocol.reset([:])
        await failing.checkForNewBuild()
        #expect(failing.buildNotice?.isError == true)
        #expect(failing.buildNotice?.actionLabel == "Riprova")
    }

    // MARK: - Profiles and provisioning (M3c)

    /// Debian Base and Debian AI Starter propose CPU and memory within this Mac: the cores, the
    /// limits of Virtualization.framework and half of the RAM.
    @Test func profilesClampToHost() {
        let tiny = makeModel(physicalMemory: 6 << 30, hostCores: 2)
        tiny.selectProfile(.aiStarter)
        #expect(tiny.profile == .aiStarter)
        #expect(tiny.cpuCount == 2, "4 vCPU clamped to the 2 cores")
        #expect(tiny.memoryGiB == 3, "4 GiB clamped to half of 6 GiB")
        #expect(tiny.memoryError == nil)

        let large = makeModel(physicalMemory: 64 << 30, hostCores: 12)
        large.selectProfile(.aiStarter)
        #expect(large.cpuCount == 4)
        #expect(large.memoryGiB == 8)
        #expect(large.diskGiB == WizardModel.aiStarterDiskGiB)
        #expect(large.memoryGiB <= WizardModel.maxMemoryGiB)
        large.selectProfile(.debianBase)
        #expect(large.cpuCount == 2)
        #expect(large.memoryGiB == 4)
        #expect(large.diskGiB == 16)
    }

    /// Phase 1 (packages, Guest Tools) on, Ollama off, for every profile; the request says so.
    @Test func ollamaOffByDefault() async throws {
        let key = try writeKey(validPublicKey)
        let creator = FakeCreator()
        let local = tmp.appendingPathComponent("base.raw")
        try Data(repeating: 0, count: 1 << 20).write(to: local)
        let model = WizardModel(registry: FakeRegistry(), images: .localFile(local), creator: creator,
                                defaultKeyURL: key, physicalMemory: 32 << 30)
        for profile in [WizardModel.Profile.debianBase, .aiStarter] {
            model.selectProfile(profile)
            #expect(!model.installOllama)
            #expect(model.installEssentialPackages)
            #expect(model.installGuestTools)
            #expect(model.phaseTwoPlan == nil)
        }
        model.selectProfile(.debianBase)
        await model.load()
        for _ in 0..<5 { await model.next() }
        let request = try #require(creator.requests.first)
        #expect(request.profile == .standard)
        #expect(request.sshPublicKeyPath == key.path)
        #expect(model.phaseTwoPlan == nil)
        #expect(!model.summaryRows.contains { $0.label == "Dopo il primo avvio" })
        // A new Debian VM is on the controlled network with the base list (VMFactory), never NAT.
        let network = try #require(model.summaryRows.first { $0.label == "Rete" })
        #expect(network.value == "Controllata · lista di base")
        #expect(network.note?.contains("inoltro IP") == false)
        // Long host names wrap only after a dot (a zero-width space there), never mid-label.
        let note = try #require(network.note)
        let plain = note.replacingOccurrences(of: "\u{200B}", with: "")
        #expect(plain.contains("deb.debian.org"))
        #expect(plain.contains("registry.ollama.ai"))
        #expect(note.contains("r2.\u{200B}cloudflarestorage.\u{200B}com"))
        #expect(!note.contains("\u{200B}\u{200B}") && !note.contains("\u{200B} ") && !note.contains("\u{200B},"))
    }

    /// The model is only part of the plan with Ollama on; Ollama needs the Guest Tools; a model
    /// name is validated like the guest does.
    @Test func modelOnlyWithOllama() {
        let model = makeModel()
        model.ollamaModel = "llama3.2:1b"
        #expect(model.phaseTwoPlan == nil)
        #expect(!model.isModelEditable)
        model.installOllama = true
        #expect(model.isModelEditable)
        #expect(model.phaseTwoPlan == ProvisioningPlan(model: "llama3.2:1b"))
        model.ollamaModel = "  "
        #expect(model.phaseTwoPlan == ProvisioningPlan(model: nil))
        model.ollamaModel = "bad name; rm"
        #expect(model.modelError != nil)
        model.step = .access
        #expect(model.nextBlocker != nil)
        model.ollamaModel = "qwen3:0.6b"
        #expect(model.modelError == nil)
        // Without Guest Tools there is no nido-provision in the guest: Ollama goes off.
        model.installGuestTools = false
        #expect(!model.installOllama)
        #expect(!model.canInstallOllama)
        #expect(model.phaseTwoPlan == nil)
        model.installOllama = true
        #expect(!model.installOllama)
    }

    /// "Da modello": choose the template, then the summary (2 steps); no download, no phase 1
    /// options, no phase 2: the template has everything already.
    @Test func fromTemplateSkipsPhaseOne() async throws {
        WizardStubProtocol.reset([:])
        let registry = FakeRegistry([
            VMSummary(configID: UUID(), name: "debian-ai-base", status: .stopped, cpuCount: 4,
                      memoryBytes: 8 << 30, diskBytes: 64 << 30, isTemplate: true),
            VMSummary(configID: UUID(), name: "debian-13", status: .stopped, cpuCount: 2,
                      memoryBytes: 4 << 30, diskBytes: 16 << 30),
            VMSummary(configID: UUID(), name: "debian-base", status: .stopped, cpuCount: 2,
                      memoryBytes: 2 << 30, diskBytes: 32 << 30, isTemplate: true),
        ])
        let creator = FakeCreator()
        let model = makeModel(registry: registry, creator: creator)
        await model.load()
        #expect(model.templates.map(\.name) == ["debian-ai-base", "debian-base"])
        model.installOllama = true
        model.selectProfile(.fromTemplate)
        #expect(model.stepLabel == "Passo 1 di 2")
        #expect(model.nextBlocker != nil, "a template must be chosen")
        model.selectTemplate("debian-ai-base")
        #expect(model.nextBlocker == nil)
        await model.next()
        #expect(model.step == .summary)
        #expect(model.stepLabel == "Passo 2 di 2")
        #expect(WizardStubProtocol.requests.isEmpty)
        #expect(model.phaseTwoPlan == nil)
        #expect(!model.summaryRows.contains { $0.label == "Primo avvio" })
        #expect(model.summaryRows.contains { $0.label == "Modello" && $0.value.hasPrefix("debian-ai-base") })
        model.name = "ricerca-02"
        await model.next()
        #expect(creator.requests.isEmpty)
        #expect(creator.templateRequests == [.init(template: "debian-ai-base", name: "ricerca-02", sshKeyPath: nil)])
        #expect(model.phase == .done(try VMName("ricerca-02")))
        model.back()
    }

    /// S04: the RAM warning of the other VMs, non-blocking (Avanti stays enabled).
    @Test func memoryHeadroomWarningOnResources() async {
        let model = makeModel(checkHeadroom: { bytes in
            MemoryHeadroom(physicalMemory: 16 << 30, nidoBytes: 8 << 30, foreignBytes: 2 << 30, startingBytes: bytes)
        })
        model.step = .resources
        model.imageBytes = 1 << 30
        model.memoryGiB = 2
        await model.refreshHeadroom()
        #expect(model.headroomWarning == nil)
        model.memoryGiB = 8
        await model.refreshHeadroom()
        #expect(model.headroomWarning?.hasPrefix("La memoria delle VM accese supera il 75 %") == true)
        #expect(model.headroomDetail?.contains("18 GiB su 16 GiB") == true)
        #expect(model.isNextEnabled)
    }
}

// MARK: - Ubuntu Server

extension WizardModelTests {
    func sha256Sums(for data: Data, name: String) -> Data {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return Data("\(digest) *\(name)\n".utf8)
    }

    /// The real catalog image is signed: a list without Ubuntu's signature stops Scarica.
    @Test func ubuntuListWithoutSignatureStopsTheDownload() async throws {
        let ubuntu = CloudImageCatalog.ubuntu2604
        WizardStubProtocol.reset([
            ubuntu.checksumsURL.absoluteString: .ok(sha256Sums(for: payload, name: ubuntu.fileName)),
            ubuntu.url.absoluteString: .ok(payload),
        ])
        let model = makeModel(keyURL: try writeKey(validPublicKey))
        await model.load()
        model.selectDistribution(.ubuntu2604)
        await model.next()  // Sistema → Download
        #expect(model.downloadRows.first { $0.label == "Verifica" }?.value == "checksum SHA-256 · firma di Ubuntu")
        await model.next()  // Scarica
        #expect(model.step == .download)
        guard case .failed(let message) = model.phase else {
            Issue.record("expected a failure, got \(model.phase)")
            return
        }
        #expect(message.lowercased().contains("firma"), "\(message)")
        #expect(!WizardStubProtocol.requests.contains(ubuntu.url))
    }

    @Test func ubuntuIsDownloadedFromItsCatalogImageAndRecorded() async throws {
        // The catalog's 26.04 without its signature (a fake list cannot carry Ubuntu's): the
        // source's own image is used when its distribution is the selected one.
        let catalog = CloudImageCatalog.ubuntu2604
        let ubuntu = CloudImage(
            id: catalog.id, fileName: catalog.fileName, url: catalog.url, checksumsURL: catalog.checksumsURL,
            maxBytes: catalog.maxBytes, checksum: .sha256, distribution: .ubuntu2604)
        WizardStubProtocol.reset([
            ubuntu.checksumsURL.absoluteString: .ok(sha256Sums(for: payload, name: ubuntu.fileName)),
            ubuntu.url.absoluteString: .ok(payload),
        ])
        let creator = FakeCreator()
        let model = WizardModel(
            registry: FakeRegistry(), images: .catalog(ubuntu, store: ImageStore(cacheRoot: cache, session: session()), cacheRoot: cache),
            creator: creator, defaultKeyURL: try writeKey(validPublicKey), physicalMemory: 32 << 30, hostCores: 8,
            checkHeadroom: nil)
        await model.load()
        model.selectDistribution(.ubuntu2604)
        #expect(model.name == "ubuntu-26.04")
        #expect(model.profile.title(for: model.distribution) == "Ubuntu Base")

        await model.next()  // Sistema → Download
        let rows = model.downloadRows
        #expect(rows.first { $0.label == "Origine" }?.value == "cloud-images.ubuntu.com")
        #expect(rows.first { $0.label == "File" }?.value == ubuntu.fileName)
        #expect(rows.first { $0.label == "Dimensione" }?.value == "fino a 4 GiB da scaricare")
        #expect(rows.first { $0.label == "Verifica" }?.value == "checksum SHA-256")
        #expect(model.downloadRows.count == 4)
        await model.next()  // Scarica → Risorse
        #expect(model.step == .resources)
        #expect(WizardStubProtocol.requests == [ubuntu.checksumsURL, ubuntu.url])
        await model.next()
        await model.next()
        #expect(model.step == .summary)
        #expect(model.summaryRows.first?.value == "Ubuntu 26.04 LTS · arm64 · Ubuntu Base")
        await model.next()  // Crea e avvia
        #expect(creator.requests.first?.distribution == .ubuntu2604)
    }

    @Test func switchingDistributionForgetsTheDownloadedImage() async throws {
        WizardStubProtocol.reset([
            image.checksumsURL.absoluteString: .ok(sums(for: payload)),
            image.manifest!.url.absoluteString: .ok(manifest(for: payload)),
            image.url.absoluteString: .ok(payload),
        ])
        let model = makeModel(keyURL: try writeKey(validPublicKey))
        await model.load()
        await model.next()
        await model.next()  // Debian downloaded
        #expect(model.step == .resources)
        model.back()
        model.back()
        #expect(model.step == .system)
        model.selectDistribution(.ubuntu2404)
        #expect(model.name == "ubuntu-24.04")
        await model.next()
        #expect(model.phase == .confirmingDownload, "Ubuntu non è ancora stata scaricata")
        #expect(model.downloadRows.first { $0.label == "File" }?.value == CloudImageCatalog.ubuntu2404.fileName)
    }

    @Test func typedNameDoesNotFollowTheDistribution() async {
        let model = makeModel()
        await model.load()
        model.name = "server"
        model.selectDistribution(.ubuntu2604)
        #expect(model.name == "server")
    }
}

// MARK: - macOS path (M3b)

/// The wizard's installer of macOS VMs: `inspect` answers `info` (or throws `inspectError`);
/// `install` records the request and waits until the test ends it (`finish`), or until it is
/// cancelled (then it reports the cleanup done, as `MacInstaller` removes its `.creating-*`).
final class FakeMacInstaller: MacVMInstalling {
    private struct State {
        var info = MacInstallFixtures.info
        var inspectError: NidoError?
        var inspected: [URL] = []
        var requests: [MacVMRequest] = []
        var progress: (@Sendable (Double) -> Void)?
        var continuation: CheckedContinuation<Void, any Error>?
        var cancelled = false
        var cleanedUp = false
        /// An installer whose cancel never ends the installation (a real `VZMacOSInstaller` whose
        /// completion handler never fires after `progress.cancel()`).
        var ignoresCancel = false
    }

    private let state = Mutex(State())

    var inspected: [URL] { state.withLock { $0.inspected } }
    var requests: [MacVMRequest] { state.withLock { $0.requests } }
    var isInstalling: Bool { state.withLock { $0.continuation != nil } }
    var wasCancelled: Bool { state.withLock { $0.cancelled } }
    var cleanedUp: Bool { state.withLock { $0.cleanedUp } }

    func answer(_ info: MacImageInfo) { state.withLock { $0.info = info; $0.inspectError = nil } }
    func ignoreCancel() { state.withLock { $0.ignoresCancel = true } }
    func refuse(with error: NidoError) { state.withLock { $0.inspectError = error } }

    func inspect(_ ipsw: URL) async throws -> MacImageInfo {
        try state.withLock { s in
            s.inspected.append(ipsw)
            if let error = s.inspectError { throw error }
            return s.info
        }
    }

    func install(_ request: MacVMRequest, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                state.withLock { s in
                    s.requests.append(request)
                    s.progress = progress
                    if s.cancelled {
                        s.cleanedUp = true
                        c.resume(throwing: CancellationError())
                    } else {
                        s.continuation = c
                    }
                }
            }
        } onCancel: {
            state.withLock { s in
                s.cancelled = true
                if !s.ignoresCancel, let c = s.continuation {
                    s.continuation = nil
                    s.cleanedUp = true
                    c.resume(throwing: CancellationError())
                }
            }
        }
    }

    /// A progress update from the installer's queue.
    func report(_ fraction: Double) { state.withLock { $0.progress }?(fraction) }

    /// Ends the running installation (nil: success).
    func finish(_ error: NidoError? = nil) {
        let c = state.withLock { s -> CheckedContinuation<Void, any Error>? in
            defer { s.continuation = nil }
            return s.continuation
        }
        if let error { c?.resume(throwing: error) } else { c?.resume() }
    }

    /// Ends the running installation as cancelled (late, after `ignoreCancel`), cleaning up.
    func finishCancelled() {
        let c = state.withLock { s -> CheckedContinuation<Void, any Error>? in
            defer { s.continuation = nil }
            if s.continuation != nil { s.cleanedUp = true }
            return s.continuation
        }
        c?.resume(throwing: CancellationError())
    }

    /// Waits (up to 2 s) until `install` has been called and is waiting.
    func waitUntilInstalling() async {
        for _ in 0..<400 where !isInstalling { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

enum MacInstallFixtures {
    static let info = MacImageInfo(
        buildVersion: "25G62", version: "26.6", minimumCPUCount: 2, minimumMemoryBytes: 4 << 30,
        hardwareModel: Data([1, 2, 3]))
}

/// Waits (up to 2 s) until `condition` holds: main-actor hops of the installer's callbacks.
@MainActor
func eventually(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
}

@MainActor
@Suite(.serialized)
final class MacWizardTests {
    let tmp: URL

    init() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-mac-wizard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: tmp) }

    /// A stand-in IPSW: the fake installer never reads it, the wizard only shows its name and size.
    func ipsw(_ name: String = "UniversalMac_26.6_Restore.ipsw") throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try Data([0x50, 0x4B, 0x03, 0x04] + [UInt8](repeating: 0, count: 1020)).write(to: url)
        return url
    }

    func makeModel(installer: FakeMacInstaller = FakeMacInstaller(), store: MacInstallStore = MacInstallStore(),
                   physicalMemory: UInt64 = 32 << 30, hostCores: Int = 8,
                   sshUser: String = "agente") throws -> WizardModel {
        let key = tmp.appendingPathComponent("id_ed25519.pub")
        try Data(validPublicKey.utf8).write(to: key)
        let local = tmp.appendingPathComponent("base.raw")
        return WizardModel(
            registry: FakeRegistry(), images: .localFile(local), creator: FakeCreator(), defaultKeyURL: key,
            physicalMemory: physicalMemory, hostCores: hostCores, macInstaller: installer, installs: store,
            defaultSSHUser: sshUser)
    }

    /// Sistema (macOS) → Immagine macOS → Risorse → Accesso → Riepilogo, with the IPSW checked.
    @Test func macPathSteps() async throws {
        let installer = FakeMacInstaller()
        let model = try makeModel(installer: installer)
        await model.load()
        model.selectSystem(.macos)
        #expect(model.system == .macos)
        #expect(model.title == "Sistema")
        #expect(model.subtitle == "Scegli il sistema della nuova macchina virtuale.")
        #expect(model.name == "macos")

        await model.next()
        #expect(model.step == .download)
        #expect(model.title == "Immagine macOS")
        #expect(model.stepLabel == "Passo 2 di 5")
        #expect(model.ipswSummary == "Nessun file scelto")
        #expect(!model.isNextEnabled, "Senza IPSW Avanti è disattivato")

        let file = try ipsw()
        await model.chooseIPSW(file)
        #expect(installer.inspected == [file])
        #expect(model.macImage == MacInstallFixtures.info)
        #expect(model.ipswSummary.hasSuffix("UniversalMac_26.6_Restore.ipsw · 1 KiB"), "\(model.ipswSummary)")
        #expect(model.ipswRows.map(\.label) == ["Versione", "Questo Mac", "Requisiti minimi", "Installazione"])
        #expect(model.ipswRows[0].value == "macOS 26.6 (25G62)")
        #expect(model.ipswRows[1].value == "Compatibile")
        #expect(model.ipswRows[2].value == "2 CPU · 4 GiB di memoria")
        #expect(model.ipswRows[3].value == "da 4 a 20 minuti, secondo il Mac e il disco")
        #expect(model.isNextEnabled)

        await model.next()
        #expect(model.step == .resources)
        #expect(model.cpuCount == 4)
        #expect(model.memoryGiB == 8)
        #expect(model.diskGiB == 64)
        #expect(model.cpuDetail == "Almeno 2 per macOS 26.6 · al massimo \(ResourceLimits.cpuCountRange.upperBound) (core di questo Mac)")
        #expect(model.memoryDetail == "Almeno 4 GiB per macOS 26.6 · al massimo \(WizardModel.maxMemoryGiB) GiB")
        #expect(model.diskDetail.hasPrefix("Consigliati almeno 40 GiB"))
        #expect(model.nextBlocker == nil)

        // Indietro keeps the checked image.
        model.back()
        #expect(model.step == .download)
        #expect(model.macImage != nil)
        await model.next()
        #expect(model.step == .resources)

        await model.next()
        #expect(model.step == .access)
        #expect(model.title == "Accesso")
        #expect(model.subtitle == "Accedi a macos da terminale con nido ssh e la tua chiave, senza password.")
        #expect(model.sshUser == "agente")
        #expect(model.nextBlocker == nil)

        await model.next()
        #expect(model.step == .summary)
        #expect(model.nextLabel == "Crea e installa")
        #expect(model.subtitle == "Controlla le scelte: Nido installa macOS in macos e la avvia per l'assistente iniziale.")
        let rows = Dictionary(uniqueKeysWithValues: model.summaryRows.map { ($0.label, $0.value) })
        #expect(rows["Sistema"] == "macOS 26.6 · da UniversalMac_26.6_Restore.ipsw")
        #expect(rows["Risorse"] == "4 CPU · 8 GiB · disco 64 GiB")
        #expect(rows["Accesso"] == "nido ssh come agente · id_ed25519.pub")
        // On the controlled network with the macOS base list (MacInstaller).
        #expect(rows["Rete e cartelle"] == "Controllata, lista di base per macOS · nessuna cartella condivisa")
        let network = try #require(model.summaryRows.first { $0.label == "Rete e cartelle" })
        #expect(network.note?.contains("inoltro IP") == false)
        #expect(network.note?.contains("App Store") == true)
        #expect(rows["Installazione"] == "da 4 a 20 minuti, secondo il Mac e il disco")
        #expect(model.nextBlocker == nil)

        // Chosen from the macOS tile (S02): straight to Immagine macOS, where the check shows.
        model.back(); model.back(); model.back(); model.back()
        #expect(model.step == .system)
        await model.chooseIPSW(file)
        #expect(model.step == .download)
        #expect(model.macImage != nil)
        await model.next(); await model.next(); await model.next()
        #expect(model.step == .summary)

        // Back to Debian: the Linux path and its profile again.
        model.back(); model.back(); model.back(); model.back()
        #expect(model.step == .system)
        model.selectSystem(.linux)
        #expect(model.name == "debian-13")
        #expect(model.cpuCount == 2)
    }

    /// An image this Mac cannot install: the design's message, Avanti stays off, no file is made.
    @Test func unsupportedImageBlocksNext() async throws {
        let installer = FakeMacInstaller()
        installer.refuse(with: .restoreImageUnsupported(version: "27.0", requiredHostMajor: 27))
        let model = try makeModel(installer: installer)
        model.selectSystem(.macos)
        await model.next()
        await model.chooseIPSW(try ipsw("UniversalMac_27.0_Restore.ipsw"))
        #expect(model.macImage == nil)
        #expect(model.macImageError
            == "macOS 27.0 non si può installare in una VM su questo Mac: serve un Mac con macOS 27 o successivo.")
        #expect(model.macImageErrorDetail?.hasSuffix("Nido non ha creato alcun file.") == true)
        #expect(!model.isNextEnabled)
        await model.next()
        #expect(model.step == .download)

        // Not an IPSW at all.
        installer.refuse(with: .notARestoreImage("/tmp/x.ipsw"))
        await model.chooseIPSW(try ipsw("x.ipsw"))
        #expect(model.macImageError == "/tmp/x.ipsw non è un'immagine di ripristino macOS (IPSW) valida.")
        #expect(!model.isNextEnabled)

        // A good one afterwards clears the error.
        installer.answer(MacInstallFixtures.info)
        await model.chooseIPSW(try ipsw())
        #expect(model.macImageError == nil)
        #expect(model.isNextEnabled)
    }

    /// Below the image's minimums: "macOS <v> richiede almeno N CPU/GiB", Avanti off.
    @Test func resourcesBelowImageMinimumBlocked() async throws {
        let installer = FakeMacInstaller()
        installer.answer(MacImageInfo(buildVersion: "25G62", version: "26.6", minimumCPUCount: 2,
                                      minimumMemoryBytes: 6 << 30, hardwareModel: Data([1])))
        // An 8 GiB Mac with 2 cores: 4 CPU and 8 GiB are reduced to its limits (its cores, half
        // its memory: 4 GiB), then raised to the image's minimums (6 GiB).
        let model = try makeModel(installer: installer, physicalMemory: 8 << 30, hostCores: 2)
        model.selectSystem(.macos)
        await model.next()
        await model.chooseIPSW(try ipsw())
        await model.next()
        #expect(model.step == .resources)
        #expect(model.cpuCount == max(2, min(4, ResourceLimits.cpuCountRange(hostCores: 2).upperBound)))
        #expect(model.memoryGiB == 6)

        // The same Mac with an image needing 4 GiB: half of its memory, 4 GiB.
        installer.answer(MacInstallFixtures.info)
        let small = try makeModel(installer: installer, physicalMemory: 8 << 30, hostCores: 2)
        small.selectSystem(.macos)
        await small.chooseIPSW(try ipsw())
        #expect(small.memoryGiB == 4)
        // A 32 GiB Mac gets the 8 GiB default.
        let large = try makeModel(installer: installer, physicalMemory: 32 << 30, hostCores: 8)
        large.selectSystem(.macos)
        await large.chooseIPSW(try ipsw())
        #expect(large.memoryGiB == min(8, WizardModel.maxMemoryGiB))

        model.memoryGiB = 4
        #expect(model.memoryError == "macOS 26.6 richiede almeno 6 GiB di memoria.")
        #expect(!model.isNextEnabled)
        await model.next()
        #expect(model.step == .resources)
        model.stepMemory(by: -1)
        #expect(model.memoryGiB == 6, "Il passo non scende sotto il minimo dell'immagine")
        #expect(model.memoryError == nil)

        model.cpuCount = 1
        #expect(model.cpuError == "macOS 26.6 richiede almeno 2 CPU.")
        #expect(!model.isNextEnabled)
        model.stepCPU(by: -1)
        #expect(model.cpuCount == 2)
        #expect(model.isNextEnabled)
    }

    /// The account name for `nido ssh` is required and must be a valid short name.
    @Test func sshUserRequiredForMac() async throws {
        let model = try makeModel(sshUser: "")
        model.selectSystem(.macos)
        await model.next()
        await model.chooseIPSW(try ipsw())
        await model.next()
        await model.next()
        #expect(model.step == .access)
        #expect(model.sshUserError == "Scrivi il nome breve dell'account che creerai in macOS.")
        #expect(!model.isNextEnabled)

        model.sshUser = "Agente Nido"
        #expect(model.sshUserError?.hasPrefix("Nome utente non valido") == true)
        #expect(!model.isNextEnabled)

        model.sshUser = "agente"
        #expect(model.sshUserError == nil)
        #expect(model.isNextEnabled)
        await model.next()
        #expect(model.step == .summary)
        model.sshUser = ""
        #expect(!model.isNextEnabled, "Il riepilogo controlla di nuovo il nome utente")

        // The Linux path does not ask for it.
        let linux = try makeModel(sshUser: "")
        linux.step = .access
        #expect(linux.sshUserError == nil)
    }

    /// The model drives a whole installation to its end.
    func runToSummary(_ model: WizardModel) async throws {
        model.selectSystem(.macos)
        await model.next()
        await model.chooseIPSW(try ipsw())
        await model.next(); await model.next(); await model.next()
        #expect(model.step == .summary)
    }

    /// Crea e installa: the installation lives in the store (it outlives the wizard), with its
    /// progress and the time left from the moving average; at the end the VM opens.
    @Test func installProgressAndETA() async throws {
        let installer = FakeMacInstaller()
        let store = MacInstallStore()
        let model = try makeModel(installer: installer, store: store)
        var created: [String] = []
        var closed = 0
        model.onCreated = { created.append($0.rawValue) }
        model.onClose = { closed += 1 }
        try await runToSummary(model)

        let run = Task { await model.next() }  // Crea e installa
        await installer.waitUntilInstalling()
        #expect(model.phase == .installing)
        #expect(model.title == "Installazione")
        #expect(model.subtitle == "Nido installa macOS 26.6 in macos. Puoi chiudere la procedura: l'avanzamento resta nella libreria.")
        #expect(model.nextLabel == "Continua nella libreria")
        #expect(model.isNextEnabled)
        #expect(!model.canGoBack)
        #expect(!model.isBusy, "Un'installazione non trattiene la procedura: si può chiudere")
        let job = try #require(store.installations.first)
        #expect(model.installation === job)
        #expect(job.name.rawValue == "macos")
        let request = try #require(installer.requests.first)
        #expect(request.sshUser == "agente")
        #expect(request.cpuCount == 4)
        #expect(request.memoryBytes == 8 << 30)
        #expect(request.diskBytes == 64 << 30)
        #expect(request.publicKey == validPublicKey.split(separator: " ").prefix(2).joined(separator: " "))
        #expect(request.sshPublicKeyPath?.hasSuffix("id_ed25519.pub") == true)

        // Progress from the installer's queue reaches the main actor.
        installer.report(0.05)
        await eventually { job.fraction == 0.05 }
        #expect(job.fraction == 0.05)

        // 10 % a minute over the window: 80 % left is 8 minutes.
        let start = ContinuousClock.now + .seconds(600)
        var clock = start + .seconds(60)
        job.now = { clock }
        job.receive(0.10, at: start)
        job.receive(0.20, at: start + .seconds(60))
        let left = try #require(job.remainingTime)
        #expect(abs(left / .seconds(1) - 480) < 1, "\(left)")
        #expect(model.installDetail == "20 % · circa 8 min rimanenti")
        #expect(job.cardText == "Installazione di macOS 26.6 · 20 % · circa 8 min")
        #expect(model.installFraction == 0.20)
        // A late, smaller update is ignored.
        job.receive(0.15, at: start + .seconds(61))
        #expect(job.fraction == 0.20)
        // No progress for a whole window: the estimate goes, the percentage stays.
        clock = start + .seconds(60) + MacInstallation.rateWindow + .seconds(1)
        #expect(job.remainingTime == nil)
        #expect(model.installDetail == "20 %")

        installer.finish()
        await run.value
        await eventually { model.phase == .done(try! VMName("macos")) }
        // The card stays (finished) until the library lists the new bundle: no gap without a card.
        #expect(job.state == .finished)
        #expect(!store.isInstalling)
        #expect(store.quitPrompt == nil)
        #expect(model.phase == .done(try VMName("macos")))
        #expect(created == ["macos"])
        #expect(closed == 1)
    }

    /// A failed installation goes back to the summary with the reason and Riprova.
    @Test func installFailureShowsRetry() async throws {
        let installer = FakeMacInstaller()
        let store = MacInstallStore()
        let model = try makeModel(installer: installer, store: store)
        try await runToSummary(model)
        let run = Task { await model.next() }
        await installer.waitUntilInstalling()
        installer.finish(.insufficientSpace(needed: 66 << 30, available: 41 << 30))
        await run.value
        await eventually { store.installations.isEmpty }
        guard case .failed(let message) = model.phase else {
            Issue.record("fase \(model.phase)")
            return
        }
        #expect(message.hasPrefix("Spazio insufficiente: servono 66 GiB, disponibili 41 GiB."), "\(message)")
        #expect(message.hasSuffix("Nido ha cancellato i file creati; l'IPSW resta dov'è."))
        #expect(model.title == "Riepilogo")
        #expect(model.nextLabel == "Riprova")
        #expect(store.installations.isEmpty)

        let retry = Task { await model.next() }
        await installer.waitUntilInstalling()
        #expect(model.phase == .installing)
        #expect(installer.requests.count == 2)
        installer.finish()
        await retry.value
    }

    /// Annulla asks first; "Continua" keeps installing, "Annulla l'installazione" stops it, the
    /// installer cleans up and the wizard closes. "Continua nella libreria" only closes the wizard.
    @Test func cancelInstallAsksAndCleans() async throws {
        let installer = FakeMacInstaller()
        let store = MacInstallStore()
        let model = try makeModel(installer: installer, store: store)
        var closed = 0
        model.onClose = { closed += 1 }
        try await runToSummary(model)
        let run = Task { await model.next() }
        await installer.waitUntilInstalling()

        // Continua nella libreria: the wizard goes, the installation stays.
        await model.next()
        #expect(closed == 1)
        model.sheetClosed()
        #expect(!installer.wasCancelled)
        #expect(store.installations.count == 1)
        // Mostra: the same wizard again.
        model.reopen()

        model.requestCancel()
        #expect(model.isConfirmingCancel)
        #expect(model.cancelQuestion == "Annullare l'installazione di macos?")
        #expect(!installer.wasCancelled, "Annulla chiede prima di fermare")
        model.keepInstalling()
        #expect(!model.isConfirmingCancel)
        #expect(model.phase == .installing)

        model.requestCancel()
        await model.confirmCancelInstall()
        #expect(installer.wasCancelled)
        #expect(installer.cleanedUp)
        #expect(store.installations.isEmpty)
        #expect(closed == 2)
        await run.value
        #expect(model.phase != .installing)
    }

    /// Quitting during an installation asks "Annulla l'installazione ed esci?"; the answer cancels
    /// it and waits for the cleanup.
    @Test func quitDuringInstallAsks() async throws {
        let installer = FakeMacInstaller()
        let store = MacInstallStore()
        #expect(store.quitPrompt == nil)
        let model = try makeModel(installer: installer, store: store)
        try await runToSummary(model)
        let run = Task { await model.next() }
        await installer.waitUntilInstalling()

        let prompt = try #require(store.quitPrompt)
        #expect(prompt.question == "Annulla l'installazione ed esci?")
        #expect(prompt.message == "Nido ferma l'installazione di macos e cancella i file creati finora. L'IPSW resta dov'è.")
        #expect(prompt.buttons == ["Continua l'installazione", "Annulla l'installazione ed esci"])
        #expect(MacInstallStore.cancelsAtQuit(buttonIndex: 1))
        #expect(!MacInstallStore.cancelsAtQuit(buttonIndex: 0))

        await store.cancelAllForQuit()
        #expect(installer.wasCancelled)
        #expect(installer.cleanedUp)
        #expect(store.installations.isEmpty)
        #expect(store.quitPrompt == nil)
        await run.value
    }

    /// Several installations in the quit alert: a list of the UI's language, not a comma join.
    @Test func quitPromptListsNamesInTheLanguage() {
        #expect(MacInstallStore.nameList(["macos"]) == "macos")
        #expect(MacInstallStore.nameList(["a", "b"]) == "a e b")
        #expect(MacInstallStore.nameList(["a", "b", "c"]) == "a, b e c")
        #expect(MacInstallStore.nameList(["a", "b"], locale: Locale(identifier: "en_US")) == "a and b")
        #expect(MacInstallStore.nameList(["a", "b"], locale: Locale(identifier: "de_DE")) == "a und b")
    }

    /// An installer that never ends after the cancel: the quit-time wait gives up after its limit
    /// (the quit goes on; the `.creating-*` folder is swept later) and names the installation.
    @Test func quitWaitIsBounded() async throws {
        let installer = FakeMacInstaller()
        installer.ignoreCancel()
        let store = MacInstallStore()
        let model = try makeModel(installer: installer, store: store)
        try await runToSummary(model)
        let run = Task { await model.next() }
        await installer.waitUntilInstalling()
        #expect(MacInstallStore.quitCancelLimit == .seconds(30))

        let start = ContinuousClock.now
        let late = await store.cancelAllForQuit(limit: .milliseconds(200))
        let elapsed = ContinuousClock.now - start
        #expect(installer.wasCancelled)
        #expect(!installer.cleanedUp)
        #expect(late.map(\.rawValue) == ["macos"])
        #expect(elapsed >= .milliseconds(200) && elapsed < .seconds(5), "\(elapsed)")
        let job = try #require(store.installations.first)
        #expect(job.isCancelling)

        // The installer ends late: the installation is gone as usual.
        installer.finishCancelled()
        await run.value
        await eventually { store.installations.isEmpty }
        #expect(store.installations.isEmpty)
    }

    /// An installation that ends in time: nothing is left over.
    @Test func quitWaitReturnsWhenCleanedUp() async throws {
        let installer = FakeMacInstaller()
        let store = MacInstallStore()
        let model = try makeModel(installer: installer, store: store)
        try await runToSummary(model)
        let run = Task { await model.next() }
        await installer.waitUntilInstalling()
        let start = ContinuousClock.now
        let late = await store.cancelAllForQuit(limit: .seconds(30))
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(late.isEmpty)
        #expect(installer.cleanedUp)
        await run.value
    }

    /// The wizard's "Annulla l'installazione" may wait for a slow installer, but the wizard says it
    /// is cancelling and does not ask again.
    @Test func wizardShowsCancelling() async throws {
        let installer = FakeMacInstaller()
        installer.ignoreCancel()
        let store = MacInstallStore()
        let model = try makeModel(installer: installer, store: store)
        try await runToSummary(model)
        let run = Task { await model.next() }
        await installer.waitUntilInstalling()
        model.requestCancel()
        let cancel = Task { await model.confirmCancelInstall() }
        await eventually { installer.wasCancelled }
        let job = try #require(store.installations.first)
        #expect(job.isCancelling)
        #expect(model.installDetail == "Annullamento in corso…")
        model.requestCancel()
        #expect(!model.isConfirmingCancel, "Già in annullamento: non chiede di nuovo")
        installer.finishCancelled()
        await cancel.value
        await run.value
        #expect(store.installations.isEmpty)
    }

    /// Real proof (M3b): the wizard's model with the live installer installs macOS from
    /// `NIDO_TEST_IPSW` into a temporary root (4–20 minutes). Skipped without the variable; run with
    /// `TEST_RUNNER_NIDO_TEST_IPSW=<path> xcodebuild test … -only-testing:NidoTests/MacWizardTests/realMacInstallThroughWizard`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NIDO_TEST_IPSW"] != nil), .timeLimit(.minutes(45)))
    func realMacInstallThroughWizard() async throws {
        let ipsw = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NIDO_TEST_IPSW"]))
        let paths = NidoPaths(root: tmp.appendingPathComponent("VMs", isDirectory: true))
        try paths.ensureRoot()
        let key = tmp.appendingPathComponent("id_ed25519.pub")
        try Data(validPublicKey.utf8).write(to: key)
        let store = MacInstallStore()
        let model = WizardModel(
            registry: VMRegistry(paths: paths), images: .localFile(tmp.appendingPathComponent("unused.raw")),
            creator: FakeCreator(), defaultKeyURL: key, macInstaller: LiveMacVMInstaller(paths: paths),
            installs: store, defaultSSHUser: "agente")
        var created: [String] = []
        model.onCreated = { created.append($0.rawValue) }
        await model.load()
        model.selectSystem(.macos)
        await model.chooseIPSW(ipsw)  // from the macOS tile: Immagine macOS, checked
        #expect(model.step == .download)
        let info = try #require(model.macImage, "\(model.macImageError ?? "")")
        print("prova reale: \(model.ipswRows.map { "\($0.label): \($0.value)" })")
        await model.next(); await model.next(); await model.next()
        #expect(model.step == .summary)
        print("prova reale: \(model.summaryRows.map { "\($0.label): \($0.value)" })")
        await model.next()  // Crea e installa
        #expect(model.phase == .installing)
        let job = try #require(store.installations.first)
        let start = ContinuousClock.now
        var lastLog = start
        while store.isInstalling {
            try await Task.sleep(for: .seconds(2))
            if ContinuousClock.now - lastLog >= .seconds(60) {
                lastLog = .now
                print("prova reale: \(job.cardText) · \(model.installDetail)")
            }
        }
        print("prova reale: fine dopo \(ContinuousClock.now - start), fase \(model.phase)")
        #expect(model.phase == .done(try VMName("macos")))
        #expect(created == ["macos"])
        let bundle = paths.bundleURL(for: try VMName("macos"))
        let config = try VMBundle(url: bundle).readConfig()
        #expect(config.guest == .macos)
        #expect(config.osVersion == info.version)
        #expect(config.sshUser == "agente")
        let summary = try #require(try await VMRegistry(paths: paths).summaries().first)
        #expect(LibraryModel.system(of: summary) == "macOS \(info.version)")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: paths.root.path)
            .filter { $0.hasPrefix(".creating-") }
        #expect(leftovers.isEmpty)
        try FileManager.default.removeItem(at: paths.root)
    }

    /// Real proof (M3b final fix): a live installation from `NIDO_TEST_IPSW` in a temporary root,
    /// cancelled at about 5 % through `MacInstallStore` (the card's and the quit's path). Prints how
    /// long the cancel took; nothing may be left (no `.creating-*` folder, no bundle). Skipped
    /// without the variable; run with `TEST_RUNNER_NIDO_TEST_IPSW=<path> xcodebuild test …
    /// -only-testing:NidoTests/MacWizardTests/realMacInstallCancel`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NIDO_TEST_IPSW"] != nil), .timeLimit(.minutes(30)))
    func realMacInstallCancel() async throws {
        let ipsw = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NIDO_TEST_IPSW"]))
        let paths = NidoPaths(root: tmp.appendingPathComponent("VMs", isDirectory: true))
        try paths.ensureRoot()
        let installer = LiveMacVMInstaller(paths: paths)
        let info = try await installer.inspect(ipsw)
        let store = MacInstallStore()
        let request = MacVMRequest(
            name: try VMName("annulla"), ipsw: ipsw, cpuCount: max(4, info.minimumCPUCount),
            memoryBytes: max(8 << 30, info.minimumMemoryBytes), diskBytes: 64 << 30, sshUser: "agente",
            publicKey: validPublicKey)
        let job = store.start(request, version: info.version, installer: installer)
        let start = ContinuousClock.now
        while job.isInstalling, job.fraction < 0.05 {
            try await Task.sleep(for: .milliseconds(250))
        }
        print("prova reale: \(job.percentText) dopo \(ContinuousClock.now - start)")
        #expect(job.isInstalling, "\(job.state)")
        let creating = try FileManager.default.contentsOfDirectory(atPath: paths.root.path)
        print("prova reale: prima dell'annullamento \(creating)")
        let cancelStart = ContinuousClock.now
        let late = await store.cancelAllForQuit(limit: .seconds(120))
        let took = ContinuousClock.now - cancelStart
        print("prova reale: annullamento in \(took), in ritardo \(late), stato \(job.state)")
        #expect(late.isEmpty)
        #expect(job.state == .cancelled)
        #expect(took < MacInstallStore.quitCancelLimit)
        let left = try FileManager.default.contentsOfDirectory(atPath: paths.root.path)
        print("prova reale: dopo l'annullamento \(left)")
        #expect(left.filter { $0.hasPrefix(".creating-") }.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: paths.bundleURL(for: request.name).path))
        try FileManager.default.removeItem(at: paths.root)
    }

    /// A name taken by an installation in progress (no bundle yet): a second wizard proposes
    /// "macos-2" and refuses "macos".
    @Test func nameOfRunningInstallIsTaken() async throws {
        let installer = FakeMacInstaller()
        let store = MacInstallStore()
        let first = try makeModel(installer: installer, store: store)
        try await runToSummary(first)
        await first.next()
        await installer.waitUntilInstalling()
        #expect(store.installations.map(\.name.rawValue) == ["macos"])

        let second = try makeModel(installer: installer, store: store)
        await second.load()
        second.selectSystem(.macos)
        #expect(second.name == "macos-2")
        second.name = "macos"
        second.step = .summary
        #expect(second.nameError == "Esiste già una VM chiamata macos.")
        await store.cancelAllForQuit()
    }

    @Test func ipswFileArgumentIsDebugOnly() throws {
        let args = ["Nido", "-NidoIPSWFile", "/tmp/x.ipsw"]
        #expect(try AppEnvironment.resolveIPSWFile(arguments: args, isDebug: true)?.path == "/tmp/x.ipsw")
        #expect(try AppEnvironment.resolveIPSWFile(arguments: args, isDebug: false) == nil)
        #expect(throws: AppEnvironment.LaunchError.relativePath("x.ipsw")) {
            try AppEnvironment.resolveIPSWFile(arguments: ["Nido", "-NidoIPSWFile", "x.ipsw"], isDebug: true)
        }
    }

    @Test func macFixturesSetTheDesignStates() throws {
        let store = MacInstallStore()
        let model = try makeModel(store: store)
        model.apply(.systemMac)
        #expect(model.system == .macos)
        #expect(model.step == .system)

        model.apply(.imageMacUnsupported)
        #expect(model.step == .download)
        #expect(model.macImageError?.hasPrefix("macOS 27.0 non si può installare") == true)

        model.apply(.resourcesMacBelowMinimum)
        #expect(model.step == .resources)
        #expect(model.memoryError == "macOS 26.6 richiede almeno 4 GiB di memoria.")

        model.apply(.installMac)
        #expect(model.phase == .installing)
        #expect(model.installDetail == "42 % · circa 9 min rimanenti")
        #expect(store.installations.count == 1)

        model.apply(.installMacCancel)
        #expect(model.isConfirmingCancel)
        #expect(store.installations.count == 1)

        model.apply(.installMacError)
        guard case .failed = model.phase else {
            Issue.record("fase \(model.phase)")
            return
        }
        #expect(WizardModel.Fixture(rawValue: "library-mac-installing") == .libraryMacInstalling)
    }
}
