// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
@testable import NidoCore

/// The token every bridge test stores; it must never reach the guest or a file.
let testSecret = "hf_TESTsecret0123456789abcdefXYZ"

/// A settable wall clock.
final class TestClock: Sendable {
    private let current: Mutex<Date>
    init(_ date: Date) { current = Mutex(date) }
    func now() -> Date { current.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { current.withLock { $0 = $0.addingTimeInterval(seconds) } }
    func set(_ date: Date) { current.withLock { $0 = date } }
}

/// Calendar of the tests: local days in Rome.
func romeCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Rome")!
    return calendar
}

func romeDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
    romeCalendar().date(from: DateComponents(
        year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
}

final class FakeTokenStore: TokenStore {
    private let token: Mutex<HFToken?>
    let failsReading: Bool
    init(_ raw: String?, failsReading: Bool = false) {
        token = Mutex(raw.flatMap(HFToken.init))
        self.failsReading = failsReading
    }
    func read() throws -> HFToken? {
        if failsReading { throw TokenStoreError.keychain(-25308) }
        return token.withLock { $0 }
    }
    func save(_ token: HFToken) throws { self.token.withLock { $0 = token } }
    func delete() throws { token.withLock { $0 = nil } }
}

/// A router that answers from a closure and records every call.
final class FakeRouter: RouterClient {
    struct Call: Sendable {
        let endpoint: RouterEndpoint
        let body: Data?
        let accept: String
        let token: HFToken?
    }

    typealias Responder = @Sendable (RouterEndpoint, Data?) async throws -> RouterResponse
    private let recorded = Mutex<[Call]>([])
    private let responder: Responder

    init(_ responder: @escaping Responder) { self.responder = responder }

    /// A router that must not be called: it records the call and fails.
    static func unreachable() -> FakeRouter {
        FakeRouter { _, _ in
            Issue.record("the router was called")
            throw URLError(.notConnectedToInternet)
        }
    }

    /// Always answers `status` with `chunks` as the body.
    static func answering(
        status: Int = 200, contentType: String? = "application/json", provider: String? = nil,
        chunks: [String], failAtEnd: Bool = false
    ) -> FakeRouter {
        FakeRouter { _, _ in
            routerResponse(status: status, contentType: contentType, provider: provider,
                           chunks: chunks.map { Data($0.utf8) }, failAtEnd: failAtEnd)
        }
    }

    var calls: [Call] { recorded.withLock { $0 } }

    func send(_ endpoint: RouterEndpoint, body: Data?, accept: String, token: HFToken?) async throws -> RouterResponse {
        recorded.withLock { $0.append(Call(endpoint: endpoint, body: body, accept: accept, token: token)) }
        return try await responder(endpoint, body)
    }
}

struct UpstreamFailure: Error {}

func routerResponse(
    status: Int, contentType: String?, provider: String? = nil, chunks: [Data], failAtEnd: Bool = false
) -> RouterResponse {
    let body = AsyncThrowingStream<Data, any Error> { continuation in
        for chunk in chunks { continuation.yield(chunk) }
        continuation.finish(throwing: failAtEnd ? UpstreamFailure() : nil)
    }
    return RouterResponse(status: status, contentType: contentType, provider: provider, body: body)
}

/// An in-memory connection: the guest's request is read in small chunks, the answer collected.
final class MemoryByteStream: ByteStream {
    private struct State {
        var input: Data
        var output = Data()
        var closed = false
    }

    private let state: Mutex<State>
    private let chunkSize: Int
    private let endOfInput: Bool
    private let failsWrites: Bool

    /// `failsWrites`: the guest is gone once its request is in (every write throws).
    init(_ input: Data, chunkSize: Int = 7, endOfInput: Bool = true, failsWrites: Bool = false) {
        state = Mutex(State(input: input))
        self.chunkSize = chunkSize
        self.endOfInput = endOfInput
        self.failsWrites = failsWrites
    }

    var output: Data { state.withLock { $0.output } }
    var isClosed: Bool { state.withLock { $0.closed } }

    func read(upTo maxCount: Int, deadline: ContinuousClock.Instant) async throws -> Data {
        let chunk: Data = state.withLock { s in
            let n = min(maxCount, chunkSize, s.input.count)
            let chunk = Data(s.input.prefix(n))
            s.input = Data(s.input.dropFirst(n))
            return chunk
        }
        if !chunk.isEmpty || endOfInput { return chunk }
        try await ContinuousClock().sleep(until: deadline)
        throw ByteStreamError.timeout
    }

    func write(_ data: Data) async throws {
        if failsWrites { throw ByteStreamError.io(EPIPE) }
        state.withLock { $0.output.append(data) }
    }

    func close() async {
        state.withLock { $0.closed = true }
    }
}

/// Opens once; every `wait` before that suspends.
final class Gate: Sendable {
    private let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))
    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { s -> Bool in
                if s.open { return true }
                s.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
    func open() {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.open = true
            defer { s.waiters = [] }
            return s.waiters
        }
        waiters.forEach { $0.resume() }
    }
}

/// A parsed HTTP answer of the proxy.
struct HTTPResult {
    let status: Int
    let headers: [String: String]
    let body: Data

    init(_ raw: Data) {
        guard let end = raw.range(of: Data("\r\n\r\n".utf8)) else {
            status = 0
            headers = [:]
            body = Data()
            return
        }
        let head = String(decoding: raw[raw.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst().split(separator: " ")
        status = statusLine.count > 1 ? Int(statusLine[1]) ?? 0 : 0
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        self.headers = headers
        body = Data(raw[end.upperBound...])
    }

    var text: String { String(decoding: body, as: UTF8.self) }
    var json: [String: Any]? { try? JSONSerialization.jsonObject(with: body) as? [String: Any] }
    var errorCode: String? { (json?["error"] as? [String: Any])?["code"] as? String }
    var errorType: String? { (json?["error"] as? [String: Any])?["type"] as? String }
}

/// A raw HTTP/1.1 request with `Content-Length` set unless `contentLength` is false.
func rawRequest(
    _ method: String, _ path: String, body: String? = nil, headers: [String] = [], contentLength: Bool = true
) -> Data {
    var lines = ["\(method) \(path) HTTP/1.1", "Host: 127.0.0.1:11435"] + headers
    if let body, contentLength { lines.append("Content-Length: \(Data(body.utf8).count)") }
    return Data((lines.joined(separator: "\r\n") + "\r\n\r\n" + (body ?? "")).utf8)
}

func chatRequest(_ json: String, headers: [String] = []) -> Data {
    rawRequest("POST", "/v1/chat/completions", body: json, headers: ["Content-Type: application/json"] + headers)
}

let allowedPolicy = AIBridgePolicy(enabled: true, allowedModels: ["org/m"], privacyAcknowledged: true)

/// A proxy over fakes, with its limiter and log in a temporary bundle directory.
struct ProxyEnv {
    let tmp: URL
    let clock: TestClock
    let store: FakeTokenStore
    let router: FakeRouter
    let limiter: AIBridgeLimiter
    let log: AIBridgeLog
    let proxy: AIBridgeProxy

    init(router: FakeRouter, token: String? = testSecret, catalog: ModelCatalog? = nil,
         failsReadingToken: Bool = false) throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("nido-ai-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let clock = TestClock(romeDate(2026, 10, 24, 10, 0))
        self.clock = clock
        store = FakeTokenStore(token, failsReading: failsReadingToken)
        self.router = router
        let limiter = AIBridgeLimiter(
            usageURL: tmp.appendingPathComponent("ai-bridge-usage.json"), calendar: romeCalendar(),
            now: { clock.now() })
        let log = try AIBridgeLog(url: tmp.appendingPathComponent("ai-bridge.log"))
        self.limiter = limiter
        self.log = log
        proxy = AIBridgeProxy(
            router: router, tokenStore: store, limiter: limiter, log: log, catalog: catalog,
            now: { clock.now() })
    }

    var usageURL: URL { tmp.appendingPathComponent("ai-bridge-usage.json") }
    var logURL: URL { tmp.appendingPathComponent("ai-bridge.log") }

    func send(_ raw: Data, policy: AIBridgePolicy? = allowedPolicy) async -> HTTPResult {
        let connection = MemoryByteStream(raw)
        await proxy.serve(connection: connection, policy: { policy })
        #expect(connection.isClosed)
        return HTTPResult(connection.output)
    }

    func logText() -> String {
        (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
    }

    func logEntries() -> [[String: Any]] {
        logText().split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    func cleanup() { try? FileManager.default.removeItem(at: tmp) }
}

/// A complete non-streaming answer with usage.
func completionJSON(content: String = "ciao", prompt: Int = 5, completion: Int = 7) -> String {
    #"{"id":"x","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"\#(content)"}}],"usage":{"prompt_tokens":\#(prompt),"completion_tokens":\#(completion),"total_tokens":\#(prompt + completion)}}"#
}

/// The JSON body the router received in its only call.
func forwardedBody(_ router: FakeRouter) -> [String: Any]? {
    guard let body = router.calls.last?.body else { return nil }
    return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
}
