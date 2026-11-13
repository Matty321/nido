// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import NidoCore
import Synchronization
import Testing

@testable import Nido

final class MemoryTokenStore: TokenStore {
    private let token = Mutex<HFToken?>(nil)
    func read() throws -> HFToken? { token.withLock { $0 } }
    func save(_ token: HFToken) throws { self.token.withLock { $0 = token } }
    func delete() throws { token.withLock { $0 = nil } }
}

/// A Keychain that refuses everything.
final class FailingTokenStore: TokenStore {
    func read() throws -> HFToken? { throw TokenStoreError.keychain(-25_300) }
    func save(_ token: HFToken) throws { throw TokenStoreError.keychain(-25_300) }
    func delete() throws { throw TokenStoreError.keychain(-25_300) }
}

/// The router: a catalog with two models for `GET /models`, a short answer for the chat.
final class CannedRouter: RouterClient {
    private let calls = Mutex<[RouterEndpoint]>([])
    var endpoints: [RouterEndpoint] { calls.withLock { $0 } }

    static let catalog = #"{"object":"list","data":[{"id":"openai/gpt-oss-20b","owned_by":"openai","providers":[{"provider":"groq","status":"live","context_length":131072,"pricing":{"input":0.1,"output":0.5}}]},{"id":"Qwen/Qwen3-8B","providers":[{"provider":"nscale"}]}]}"#
    static let chat = #"{"id":"x","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"ciao"}}],"usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5}}"#

    func send(_ endpoint: RouterEndpoint, body: Data?, accept: String, token: HFToken?) async throws -> RouterResponse {
        calls.withLock { $0.append(endpoint) }
        let text = endpoint == .models ? Self.catalog : Self.chat
        let stream = AsyncThrowingStream<Data, any Error> { continuation in
            continuation.yield(Data(text.utf8))
            continuation.finish()
        }
        return RouterResponse(status: 200, contentType: "application/json", provider: "groq", body: stream)
    }
}

/// One guest connection in memory: the request goes in, the proxy's answer is collected.
final class GuestConnection: ByteStream {
    private let state: Mutex<(input: Data, output: Data)>
    init(_ request: String) { state = Mutex((Data(request.utf8), Data())) }
    var answer: String { String(decoding: state.withLock { $0.output }, as: UTF8.self) }
    var statusCode: Int? {
        answer.split(separator: "\r\n").first.flatMap { $0.split(separator: " ").dropFirst().first }.flatMap { Int($0) }
    }

    func read(upTo maxCount: Int, deadline: ContinuousClock.Instant) async throws -> Data {
        state.withLock { s in
            let chunk = Data(s.input.prefix(maxCount))
            s.input = Data(s.input.dropFirst(chunk.count))
            return chunk
        }
    }

    func write(_ data: Data) async throws { state.withLock { $0.output.append(data) } }
    func close() async {}
}

@MainActor
struct AIBridgeModelTests {
    private func makeBundle() throws -> (VMBundle, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-bridge-\(UUID().uuidString)", isDirectory: true)
        let config = VMConfig(
            id: UUID(), name: try VMName("debian-13"), guest: .linux, cpuCount: 2,
            memoryBytes: UInt64(4) << 30, diskBytes: UInt64(32) << 30, macAddress: "52:54:00:12:34:56")
        return (try VMBundle.create(config: config, paths: NidoPaths(root: root)), root)
    }

    private func makeModel(
        _ bundle: VMBundle, tokenStore: MemoryTokenStore = MemoryTokenStore(), router: CannedRouter = CannedRouter()
    ) -> AIBridgeModel {
        AIBridgeModel(
            openBundle: { bundle }, tokenStore: tokenStore,
            catalog: ModelCatalog(router: router, tokenStore: tokenStore), limiter: nil)
    }

    @Test func bridgeEnableRequiresPrivacyAck() async throws {
        let (bundle, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(bundle)
        await model.load()
        #expect(model.policy == AIBridgePolicy())
        #expect(!model.policy.enabled)

        await model.setEnabled(true)
        #expect(model.isShowingPrivacyNotice)
        #expect(try bundle.readConfig().aiBridge == nil)
        #expect(!model.policy.enabled)

        model.declinePrivacyNotice()
        #expect(!model.isShowingPrivacyNotice)
        #expect(try bundle.readConfig().aiBridge == nil)

        await model.setEnabled(true)
        await model.acknowledgePrivacy()
        let saved = try #require(try bundle.readConfig().aiBridge)
        #expect(saved.enabled)
        #expect(saved.privacyAcknowledged)
        #expect(saved.tokensPerDay == 200_000)
        #expect(saved.requestsPerMinute == 20)
        #expect(saved.maxTokensPerRequest == 4_096)
        #expect(model.policy == saved)

        // Acknowledged once for this VM: switching off and on again asks no more.
        await model.setEnabled(false)
        #expect(try bundle.readConfig().aiBridge?.enabled == false)
        await model.setEnabled(true)
        #expect(!model.isShowingPrivacyNotice)
        #expect(try bundle.readConfig().aiBridge?.enabled == true)
    }

    @Test func bridgeWithoutTokenExplains() async throws {
        let (bundle, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try bundle.updateConfig { $0.aiBridge = AIBridgePolicy(enabled: true, privacyAcknowledged: true) }
        let tokens = MemoryTokenStore()
        let model = makeModel(bundle, tokenStore: tokens)
        await model.load()
        #expect(model.hasToken == false)
        #expect(model.notice?.contains("token di Hugging Face") == true)

        #expect(await model.saveToken("  hf_secretvalue123  "))
        #expect(model.hasToken == true)
        #expect(model.notice == nil)
        #expect(try tokens.read() == HFToken("hf_secretvalue123"))
        // The model keeps only "present": its value is nowhere in it.
        var dumped = ""
        dump(model, to: &dumped)
        #expect(!dumped.contains("hf_secretvalue123"))

        #expect(await model.saveToken("non valido con spazi") == false)
        #expect(model.tokenError != nil)
        await model.removeToken()
        #expect(model.hasToken == false)
        #expect(try tokens.read() == nil)
    }

    /// The model writes the VM's config; the session's bridge reads it at its next request
    /// (`AIBridgeServices.configPolicy`, the provider `makeHost` gives the host): no restart.
    @Test func bridgePolicyChangeReachesSession() async throws {
        let (bundle, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let tokens = MemoryTokenStore()
        try tokens.save(try #require(HFToken("hf_test_token")))
        let router = CannedRouter()
        let proxy = AIBridgeProxy(
            router: router, tokenStore: tokens, limiter: AIBridgeLimiter(usageURL: bundle.aiBridgeUsageURL),
            log: try AIBridgeLog(url: bundle.aiBridgeLogURL), catalog: nil)
        let provider = AIBridgeServices.configPolicy(of: bundle)
        let body = #"{"model":"openai/gpt-oss-20b","messages":[{"role":"user","content":"ciao"}]}"#
        let request = "POST /v1/chat/completions HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n"
            + body

        let off = GuestConnection(request)
        await proxy.serve(connection: off, policy: provider)
        #expect(off.statusCode == 403)

        let model = makeModel(bundle, tokenStore: tokens, router: router)
        await model.load()
        await model.loadCatalog()
        #expect(model.catalogModels.map(\.id) == ["openai/gpt-oss-20b", "Qwen/Qwen3-8B"])
        await model.setEnabled(true)
        await model.acknowledgePrivacy()
        await model.setAllowed("openai/gpt-oss-20b", true)
        // Not in the catalog: refused.
        await model.setAllowed("evil/model", true)
        #expect(model.policy.allowedModels == ["openai/gpt-oss-20b"])

        let on = GuestConnection(request)
        await proxy.serve(connection: on, policy: provider)
        #expect(on.statusCode == 200)
        #expect(router.endpoints.contains(.chatCompletions))

        await model.setLimits(tokensPerDay: 1000, requestsPerMinute: 5, maxTokensPerRequest: 256)
        #expect(provider()?.tokensPerDay == 1000)
        #expect(provider()?.requestsPerMinute == 5)
        #expect(provider()?.maxTokensPerRequest == 256)
        await model.setLimits(tokensPerDay: 0, requestsPerMinute: 5, maxTokensPerRequest: 256)
        #expect(model.limitsError != nil)
        #expect(provider()?.tokensPerDay == 1000)

        await model.setAllowed("openai/gpt-oss-20b", false)
        let removed = GuestConnection(request)
        await proxy.serve(connection: removed, policy: provider)
        #expect(removed.statusCode == 403)
    }

    @Test func bridgeUsageFromLog() async throws {
        let (bundle, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = try AIBridgeLog(url: bundle.aiBridgeLogURL)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<3 {
            log.append(AIBridgeLogEntry(
                time: base.addingTimeInterval(Double(i)), model: "m\(i)", provider: i == 0 ? nil : "groq",
                inputTokens: 10 * i, outputTokens: i, estimated: i == 2, status: 200, durationMs: 100))
        }
        log.close()
        // Today's usage as the limiter keeps it in ai-bridge-usage.json.
        let c = Calendar.autoupdatingCurrent.dateComponents([.year, .month, .day], from: Date())
        let today = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        let fd = Darwin.open(bundle.aiBridgeUsageURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        #expect(fd >= 0)
        let usage = Array(#"{"day":"\#(today)","tokens":1234}"#.utf8)
        _ = usage.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        Darwin.close(fd)

        let model = makeModel(bundle)
        await model.load()
        #expect(model.tokensUsedToday == 1234)
        #expect(model.recentCalls.map(\.model) == ["m2", "m1", "m0"])
        #expect(model.recentCalls.first?.estimated == true)
    }

    @Test func bridgeIndicatorAndAttachWarning() async throws {
        let (bundle, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try bundle.updateConfig { $0.aiBridge = AIBridgePolicy(enabled: true, privacyAcknowledged: true) }
        let model = makeModel(bundle)
        await model.load()
        #expect(!model.isActive)
        model.sessionStarted(bridgeAttached: true)
        #expect(model.isActive)
        #expect(model.attachWarning == nil)
        model.sessionEnded()
        #expect(!model.isActive)

        model.sessionStarted(bridgeAttached: false)
        #expect(!model.isActive)
        #expect(model.attachWarning?.hasPrefix("Il ponte AI non è disponibile") == true)
        model.sessionEnded()
        #expect(model.attachWarning == nil)
    }

    /// "Ponte attivo" in the library: only while the VM runs in this app with its bridge on.
    @Test func bridgeIndicatorInLibrary() async throws {
        let (bundle, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try bundle.updateConfig { $0.aiBridge = AIBridgePolicy(enabled: true, privacyAcknowledged: true) }
        let factory = FakeSessionFactory()
        factory.configure = { $0.aiBridgeAttached = true }
        let store = VMSessionStore(paths: NidoPaths(root: root), factory: factory)
        #expect(!store.isAIBridgeActive("debian-13"))
        let window = store.model(for: try VMName("debian-13"))
        await window.start()
        #expect(await waitUntil { store.isAIBridgeActive("debian-13") })
        await window.stop()
        #expect(!store.isAIBridgeActive("debian-13"))
    }

    // MARK: - Settings section: attach warning

    /// The attach warning only for a bridge the user switched on, and it does not guess the cause.
    @Test func attachWarningOnlyWhenEnabled() async throws {
        let (bundle, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(bundle)
        await model.load()
        model.sessionStarted(bridgeAttached: false)
        #expect(model.attachWarning == nil)
        _ = try bundle.updateConfig { $0.aiBridge = AIBridgePolicy(enabled: true, privacyAcknowledged: true) }
        await model.reloadPolicy()
        let warning = try #require(model.attachWarning)
        #expect(!warning.contains("vsock"))
    }

    /// Enabling re-reads the acknowledgement in the config being written: a config where it is
    /// missing (e.g. edited meanwhile) shows the notice and stays off.
    @Test func enableRechecksAcknowledgementOnDisk() async throws {
        let (bundle, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try bundle.updateConfig { $0.aiBridge = AIBridgePolicy(enabled: false, privacyAcknowledged: true) }
        let model = makeModel(bundle)
        await model.load()
        _ = try bundle.updateConfig { $0.aiBridge = AIBridgePolicy(enabled: false, privacyAcknowledged: false) }
        await model.setEnabled(true)
        #expect(try bundle.readConfig().aiBridge?.enabled == false)
        #expect(model.isShowingPrivacyNotice)
        #expect(!model.policy.enabled)
    }

    // MARK: - AI section in Settings

    /// The first "Attiva il ponte…" shows the privacy sheet with its copy; nothing is written
    /// before "Attiva il ponte".
    @Test func bridgeFirstEnableShowsPrivacyWarning() async throws {
        let (bundle, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(bundle)
        await model.load()
        await model.setEnabled(true)
        #expect(model.isShowingPrivacyNotice)
        #expect(try bundle.readConfig().aiBridge == nil)
        #expect(AIBridgeModel.privacyTitle(vmName: "debian-13") == "Attivare il ponte AI per debian-13?")
        #expect(AIBridgeModel.privacyNotice.hasPrefix("Con il ponte attivo, i testi che i programmi della VM"))
        #expect(AIBridgeModel.privacyLimits
            == "Limiti predefiniti, modificabili: 200 000 token al giorno, 20 richieste al minuto, max_tokens 4 096.")
        await model.acknowledgePrivacy()
        #expect(try bundle.readConfig().aiBridge?.enabled == true)
        #expect(!model.isShowingPrivacyNotice)
    }

    /// "Ponte AI attivo" in the window strip and on the library card: only while this app runs
    /// the VM with its bridge attached and on; never for a VM started with `nido start`.
    @Test func bridgeIndicatorVisibleWhenEnabled() async throws {
        let (bundle, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(bundle)
        await model.load()
        model.sessionStarted(bridgeAttached: true)
        #expect(!model.isActive)
        await model.setEnabled(true)
        await model.acknowledgePrivacy()
        #expect(model.isActive)
        await model.setEnabled(false)
        #expect(!model.isActive)

        let running = VMSummary(configID: UUID(), name: "debian-13", status: .running(.app), cpuCount: 2,
                                memoryBytes: 1 << 30, diskBytes: 1 << 30)
        let library = LibraryModel(
            registry: FakeRegistry([running]), control: FakeControl(), isBridgeActive: { _ in true })
        #expect(library.showsBridgePill(for: running))
        let terminal = VMSummary(configID: UUID(), name: "debian-13", status: .running(.cli), cpuCount: 2,
                                 memoryBytes: 1 << 30, diskBytes: 1 << 30)
        #expect(!library.showsBridgePill(for: terminal))
        let off = LibraryModel(registry: FakeRegistry([running]), control: FakeControl())
        #expect(!off.showsBridgePill(for: running))
        // The Remoto column of a VM started by `nido start`.
        #expect(AIBridgeModel.elsewhereNotice(vmName: "debian-13")
            == "Il ponte AI funziona solo per le VM avviate da Nido: debian-13 è in esecuzione dal Terminale (nido start).")
    }

    /// The limits as the user types them ("200 000") and as the fields show them.
    @Test func limitsFieldsParseAndFormat() {
        #expect(AIBridgeModel.parseLimit("200 000") == 200_000)
        #expect(AIBridgeModel.parseLimit("4.096") == 4_096)
        #expect(AIBridgeModel.parseLimit("20") == 20)
        #expect(AIBridgeModel.parseLimit("") == nil)
        #expect(AIBridgeModel.parseLimit("dieci") == nil)
        #expect(AIBridgeModel.parseLimit("99999999999999999999999") == nil)
        #expect(AIBridgeModel.grouped(200_000) == "200 000")
        #expect(AIBridgeModel.grouped(4_096) == "4 096")
        #expect(AIBridgeModel.grouped(20) == "20")
        #expect(AIBridgeModel.outcome(200) == "Riuscita")
        #expect(AIBridgeModel.outcome(429) == "Oltre il limite")
        #expect(AIBridgeModel.outcome(401) == "Token rifiutato")
        #expect(AIBridgeModel.outcome(502) == "Errore 502")
        #expect(AIBridgeModel.durationText(1_900) == "1,9 s")
    }

    /// S10 Hugging Face: the token goes to the Keychain and the field is emptied at once; the
    /// value is never shown again (only "Salvato nel Portachiavi").
    @Test func tokenFieldNeverRedisplaysValue() async throws {
        let tokens = MemoryTokenStore()
        let model = HuggingFaceTokenModel(tokenStore: tokens)
        await model.load()
        #expect(model.hasToken == false)
        #expect(model.showsField)
        #expect(!model.canSave)

        model.field = "  hf_secretvalue123  "
        #expect(model.canSave)
        await model.save()
        #expect(model.field.isEmpty)
        #expect(model.hasToken == true)
        #expect(!model.showsField)
        #expect(model.error == nil)
        #expect(try tokens.read() == HFToken("hf_secretvalue123"))
        var dumped = ""
        dump(model, to: &dumped)
        #expect(!dumped.contains("hf_secretvalue123"))

        // Sostituisci: an empty field, never the saved value.
        model.beginReplace()
        #expect(model.showsField)
        #expect(model.field.isEmpty)
        model.cancelReplace()
        #expect(!model.showsField)

        // An invalid token is not saved and says why (the typed text stays to be corrected).
        model.beginReplace()
        model.field = "non valido con spazi"
        await model.save()
        #expect(model.error == "Il token non è valido: incollalo senza spazi interni né caratteri speciali.")
        #expect(try tokens.read() == HFToken("hf_secretvalue123"))

        // The Keychain refuses: the error is shown inline.
        let failing = HuggingFaceTokenModel(tokenStore: FailingTokenStore())
        await failing.load()
        #expect(failing.hasToken == nil)
        #expect(failing.error == "Il Portachiavi non risponde: riprova.")
        failing.field = "hf_secretvalue123"
        await failing.save()
        #expect(failing.error == "Il Portachiavi non ha salvato il token: riprova.")
        #expect(failing.field.isEmpty)

        await model.remove()
        #expect(model.hasToken == false)
        #expect(try tokens.read() == nil)
        #expect(model.showsField)
    }

    // MARK: - Review fixes

    /// A typed but unsaved token is dropped when the section goes away (another section, the
    /// Settings window closed): it never comes back masked in the field.
    @Test func typedTokenIsClearedOnLeave() async throws {
        let tokens = MemoryTokenStore()
        let model = HuggingFaceTokenModel(tokenStore: tokens)
        await model.load()
        model.field = "hf_typednotsaved123"
        model.leave()
        #expect(model.field.isEmpty)
        #expect(try tokens.read() == nil)

        try? tokens.save(HFToken("hf_secretvalue123")!)
        await model.load()
        model.beginReplace()
        model.field = "hf_othervalue456"
        model.leave()
        #expect(model.field.isEmpty)
        #expect(!model.isReplacing)
        #expect(!model.showsField)
        var dumped = ""
        dump(model, to: &dumped)
        #expect(!dumped.contains("hf_othervalue456"))
    }

    /// No Keychain behind the model: the field cannot save and says why.
    @Test func tokenFieldWithoutKeychainIsDisabled() async {
        let model = HuggingFaceTokenModel(tokenStore: nil)
        await model.load()
        #expect(!model.isAvailable)
        model.field = "hf_secretvalue123"
        #expect(!model.canSave)
        #expect(model.error == "Il Portachiavi non è disponibile in questa sessione di Nido: il token non si può salvare.")
        await model.save()
        #expect(model.hasToken == nil)
    }
}
