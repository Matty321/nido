// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
@testable import NidoCore

private let simpleChat = #"{"model":"org/m","messages":[{"role":"user","content":"ciao"}]}"#

private func nestedArrays(_ depth: Int) -> String {
    String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
}

private func nestedObjects(_ depth: Int) -> String {
    String(repeating: #"{"a":"#, count: depth) + "1" + String(repeating: "}", count: depth)
}

/// Waits (up to 3 s) for `condition`.
private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// `env.send` without `#expect` (for detached tasks, outside the test's task).
private func rawSend(_ env: ProxyEnv, _ raw: Data) async -> HTTPResult {
    let connection = MemoryByteStream(raw)
    await env.proxy.serve(connection: connection, policy: { allowedPolicy })
    return HTTPResult(connection.output)
}

/// Review fixes: hostile nesting, token limits, charging after the router accepted,
/// listing limits, stream bounds.
@Suite struct AIBridgeHardeningTests {
    @Test func deeplyNestedRequestIsRefusedWithoutCrashing() async throws {
        let env = try ProxyEnv(router: .unreachable())
        defer { env.cleanup() }
        // On a cooperative-pool thread (small stack), where the crash happened.
        let statuses = await Task.detached {
            var statuses: [Int] = []
            for nested in [nestedArrays(300), nestedArrays(10_000), nestedObjects(200), nestedObjects(10_000)] {
                let answer = await rawSend(env, chatRequest(#"{"model":"org/m","x":"# + nested + "}"))
                statuses.append(answer.status)
                if answer.errorCode != "invalid_request" { statuses.append(-1) }
                // The rewriter alone, too.
                do {
                    _ = try ChatRewrite(Data(nested.utf8), maxTokens: 10)
                    statuses.append(-2)
                } catch let error as AIBridgeFailure {
                    statuses.append(error.status)
                } catch {
                    statuses.append(-3)
                }
            }
            return statuses
        }.value
        #expect(statuses == Array(repeating: 400, count: 8))
        #expect(env.router.calls.isEmpty)

        // Moderate nesting is fine.
        let ok = FakeRouter.answering(chunks: [completionJSON()])
        let env2 = try ProxyEnv(router: ok)
        defer { env2.cleanup() }
        #expect(await env2.send(chatRequest(#"{"model":"org/m","x":"# + nestedArrays(20) + "}")).status == 200)
    }

    @Test func jsonDepthIgnoresBracketsInStrings() {
        #expect(!JSONDepth.exceeds(Data(#"{"a":"[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[["}"#.utf8)))
        #expect(!JSONDepth.exceeds(Data(#"{"a":"\"[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[\\"}"#.utf8)))
        #expect(JSONDepth.exceeds(Data((#"{"a":"\\"}"# + nestedArrays(33)).utf8)))
        #expect(!JSONDepth.exceeds(Data(nestedArrays(32).utf8)))
        #expect(JSONDepth.exceeds(Data(nestedArrays(33).utf8)))
    }

    @Test func deeplyNestedUpstreamDataDoesNotCrash() async throws {
        let deep = nestedArrays(10_000)
        let outcome = await Task.detached { () -> (Usage?, Bool) in
            var scanner = SSEUsageScanner()
            scanner.feed(Data(("data: {\"usage\":" + deep + "}\n\n").utf8))
            scanner.feed(Data("data: {\"x\":\(deep)}\n\n".utf8))
            let catalogRefused = (try? ModelCatalog.parse(Data((#"{"data":"# + deep + "}").utf8))) == nil
            return (scanner.usage, catalogRefused)
        }.value
        #expect(outcome.0 == nil)
        #expect(outcome.1)

        // A deep JSON answer: passed on, charged with the estimate (its usage is not parsed).
        let router = FakeRouter.answering(chunks: [#"{"usage":"# + deep + "}"])
        let env = try ProxyEnv(router: router)
        defer { env.cleanup() }
        let answer = await Task.detached { await rawSend(env, chatRequest(simpleChat)) }.value
        #expect(answer.status == 200)
        #expect(await env.limiter.tokensUsedToday() > 4096)
        #expect(env.logEntries().last?["estimated"] as? Bool == true)
    }

    @Test func tokenLimitsMustBePositiveIntegers() async throws {
        let router = FakeRouter.answering(chunks: [completionJSON()])
        let env = try ProxyEnv(router: router)
        defer { env.cleanup() }
        for body in [
            #"{"model":"org/m","max_tokens":-1}"#,
            #"{"model":"org/m","max_tokens":0}"#,
            #"{"model":"org/m","max_tokens":1,"max_completion_tokens":0}"#,
            #"{"model":"org/m","max_tokens":"100"}"#,
            #"{"model":"org/m","max_tokens":1.5}"#,
            #"{"model":"org/m","max_completion_tokens":true}"#,
            #"{"model":"org/m","max_completion_tokens":-5}"#,
        ] {
            let answer = await env.send(chatRequest(body))
            #expect(answer.status == 400, "\(body)")
            #expect(answer.errorCode == "invalid_request", "\(body)")
        }
        #expect(router.calls.isEmpty)
        #expect(await env.send(chatRequest(#"{"model":"org/m","max_tokens":1}"#)).status == 200)
        #expect(forwardedBody(router)?["max_tokens"] as? Int == 1)
        #expect(await env.send(chatRequest(#"{"model":"org/m","max_tokens":100.0}"#)).status == 200)
        #expect(forwardedBody(router)?["max_tokens"] as? Int == 100)
    }

    @Test func guestLeavingBeforeTheFirstChunkIsCharged() async throws {
        let ended = Mutex(false)
        // The router accepted (2xx head) but sends nothing yet.
        let router = FakeRouter { _, _ in
            let body = AsyncThrowingStream<Data, any Error> { continuation in
                continuation.onTermination = { _ in ended.withLock { $0 = true } }
            }
            return RouterResponse(status: 200, contentType: "text/event-stream", provider: nil, body: body)
        }
        let env = try ProxyEnv(router: router)
        defer { env.cleanup() }
        let connection = MemoryByteStream(chatRequest(#"{"model":"org/m","stream":true}"#), failsWrites: true)
        await env.proxy.serve(connection: connection, policy: { allowedPolicy })
        #expect(connection.isClosed)

        let bytes = router.calls.last?.body?.count ?? 0
        let estimate = (bytes + 3) / 4 + 4096
        let limiter = env.limiter
        #expect(await eventually { await limiter.tokensUsedToday() == estimate })
        #expect(await eventually { await limiter.requestsInFlight == 0 })
        #expect(ended.withLock { $0 })
        #expect(env.logEntries().last?["estimated"] as? Bool == true)
    }

    @Test func acceptedCallsAreChargedEvenWhenTheAnswerBreaks() async throws {
        // Non-streaming 2xx whose body breaks: the provider has the prompt.
        let broken = FakeRouter.answering(chunks: [#"{"choi"#], failAtEnd: true)
        let env = try ProxyEnv(router: broken)
        defer { env.cleanup() }
        #expect(await env.send(chatRequest(simpleChat)).status == 502)
        #expect(await env.limiter.tokensUsedToday() > 0)
        // An answer holding the token: refused to the guest, still charged.
        let leaking = FakeRouter.answering(chunks: [completionJSON(content: testSecret, prompt: 2, completion: 3)])
        let env2 = try ProxyEnv(router: leaking)
        defer { env2.cleanup() }
        #expect(await env2.send(chatRequest(simpleChat)).status == 502)
        #expect(await env2.limiter.tokensUsedToday() > 0)
    }

    @Test func promptOnlyUsageEstimatesTheOutput() async throws {
        let router = FakeRouter.answering(contentType: "text/event-stream", chunks: [
            "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":11}}\n\n", "data: [DONE]\n\n",
        ])
        let env = try ProxyEnv(router: router)
        defer { env.cleanup() }
        _ = await env.send(chatRequest(#"{"model":"org/m","stream":true,"max_tokens":100}"#))
        #expect(await env.limiter.tokensUsedToday() == 111)
        let entry = try #require(env.logEntries().last)
        #expect(entry["inputTokens"] as? Int == 11)
        #expect(entry["outputTokens"] as? Int == 100)
        #expect(entry["estimated"] as? Bool == true)
    }

    @Test func modelsCountAgainstRequestsPerMinute() async throws {
        let router = FakeRouter.answering(chunks: [#"{"data":[{"id":"org/m"}]}"#])
        let catalog = ModelCatalog(router: router, tokenStore: nil)
        let env = try ProxyEnv(router: router, catalog: catalog)
        defer { env.cleanup() }
        let policy = AIBridgePolicy(enabled: true, allowedModels: ["org/m"], requestsPerMinute: 2)
        #expect(await env.send(rawRequest("GET", "/v1/models"), policy: policy).status == 200)
        #expect(await env.send(rawRequest("GET", "/v1/models"), policy: policy).status == 200)
        let third = await env.send(rawRequest("GET", "/v1/models"), policy: policy)
        #expect(third.status == 429)
        #expect(third.errorCode == "rate_limited")
        // Same window as chat requests, and no tokens charged.
        #expect(await env.send(chatRequest(simpleChat), policy: policy).status == 429)
        #expect(await env.limiter.tokensUsedToday() == 0)
        env.clock.advance(61)
        #expect(await env.send(rawRequest("GET", "/v1/models"), policy: policy).status == 200)
        // Catalog cached: one request to the router for all of them.
        #expect(router.calls.count == 1)
    }

    @Test func catalogFailureCachedAndFetchesShared() async throws {
        let failing = FakeRouter { _, _ in throw URLError(.notConnectedToInternet) }
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let catalog = ModelCatalog(router: failing, tokenStore: nil, now: { clock.now() })
        for _ in 0..<3 { _ = try? await catalog.models() }
        #expect(failing.calls.count == 1)
        clock.advance(59)
        _ = try? await catalog.models()
        #expect(failing.calls.count == 1)
        clock.advance(2)
        _ = try? await catalog.models()
        #expect(failing.calls.count == 2)
        _ = try? await catalog.models(forceRefresh: true)
        #expect(failing.calls.count == 3)

        // Concurrent misses: one request.
        let gate = Gate()
        let slow = FakeRouter { _, _ in
            await gate.wait()
            return routerResponse(status: 200, contentType: "application/json",
                                  chunks: [Data(#"{"data":[{"id":"org/m"}]}"#.utf8)])
        }
        let shared = ModelCatalog(router: slow, tokenStore: nil)
        let callers = (0..<5).map { _ in Task { try await shared.models().count } }
        #expect(await eventually { slow.calls.count == 1 })
        try await Task.sleep(for: .milliseconds(50))
        gate.open()
        for caller in callers { #expect(try await caller.value == 1) }
        #expect(slow.calls.count == 1)
    }

    @Test func streamIsReadAtTheGuestsPace() async throws {
        let pulled = Mutex(0)
        let router = FakeRouter { _, _ in
            let body = AsyncThrowingStream<Data, any Error>(unfolding: {
                let n = pulled.withLock { p -> Int in
                    p += 1
                    return p
                }
                return n > 1000 ? nil : Data("data: {\"n\":\(n)}\n\n".utf8)
            })
            return RouterResponse(status: 200, contentType: "text/event-stream", provider: nil, body: body)
        }
        let env = try ProxyEnv(router: router)
        defer { env.cleanup() }
        let request = AIBridgeRequest(
            method: "POST", path: "/v1/chat/completions", body: Data(#"{"model":"org/m","stream":true}"#.utf8))
        let response = await env.proxy.handle(request: request, policy: allowedPolicy)
        var iterator = response.body.makeAsyncIterator()
        #expect(try await iterator.next() != nil)
        try await Task.sleep(for: .milliseconds(200))
        // Only a few chunks wait for the guest; the rest stay with the router.
        #expect(pulled.withLock { $0 } <= ChunkChannel.capacity + 3)
        response.body.cancel()
        let limiter = env.limiter
        #expect(await eventually { await limiter.requestsInFlight == 0 })
        #expect(await limiter.tokensUsedToday() > 0)
    }

    @Test func streamEndsAfterTenMinutes() async throws {
        #expect(AIBridgeProxy.maxStreamDuration == 600)
        let clockBox = Mutex<TestClock?>(nil)
        let router = FakeRouter { _, _ in
            let body = AsyncThrowingStream<Data, any Error> { continuation in
                Task {
                    continuation.yield(Data("data: {\"a\":1}\n\n".utf8))
                    try? await Task.sleep(for: .milliseconds(50))
                    clockBox.withLock { $0?.advance(601) }
                    continuation.yield(Data("data: {\"b\":2}\n\n".utf8))
                    continuation.finish()
                }
            }
            return RouterResponse(status: 200, contentType: "text/event-stream", provider: nil, body: body)
        }
        let env = try ProxyEnv(router: router)
        defer { env.cleanup() }
        clockBox.withLock { $0 = env.clock }
        let answer = await env.send(chatRequest(#"{"model":"org/m","stream":true}"#))
        #expect(answer.text == "data: {\"a\":1}\n\n")
        #expect(env.logEntries().last?["status"] as? Int == 504)
        #expect(await env.limiter.tokensUsedToday() > 0)
    }

    @Test func nonUTF8BodiesCannotHideTheirNesting() async throws {
        let env = try ProxyEnv(router: .unreachable())
        defer { env.cleanup() }
        let outcomes = await Task.detached { () -> [String] in
            var outcomes: [String] = []
            for depth in [300, 10_000] {
                // The escaped quote shifts the UTF-8 scan's string state on UTF-16/32 bytes.
                let text = #"{"model":"\"","x":"# + nestedArrays(depth) + "}"
                for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian] {
                    let body = text.data(using: encoding)!
                    var raw = Data("POST /v1/chat/completions HTTP/1.1\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
                    raw.append(body)
                    let answer = await rawSend(env, raw)
                    outcomes.append("\(answer.status) \(answer.errorCode ?? "-")")
                }
            }
            // UTF-8 with a byte-order mark.
            let bom = Data([0xEF, 0xBB, 0xBF]) + Data(#"{"model":"org/m"}"#.utf8)
            var raw = Data("POST /v1/chat/completions HTTP/1.1\r\nContent-Length: \(bom.count)\r\n\r\n".utf8)
            raw.append(bom)
            let answer = await rawSend(env, raw)
            outcomes.append("\(answer.status) \(answer.errorCode ?? "-")")
            return outcomes
        }.value
        #expect(outcomes == Array(repeating: "400 invalid_request", count: 7))
        #expect(env.router.calls.isEmpty)
        #expect(JSONDepth.check(Data([0x7B, 0x00, 0x7D])) == .notUTF8)
        #expect(JSONDepth.check(Data([0x7B, 0xFF, 0x7D])) == .notUTF8)
        #expect(JSONDepth.check(Data(#"{"a":"è"}"#.utf8)) == nil)
    }

    @Test func jsonValueBoundsItsOwnDepth() async throws {
        // Layer two, without the pre-check: UTF-16 decoded directly, a deep value encoded.
        let results = await Task.detached { () -> [Bool] in
            let text = #"{"x":"# + nestedArrays(10_000) + "}"
            let decodedUTF16 = (try? JSONDecoder().decode(
                JSONValue.self, from: text.data(using: .utf16LittleEndian)!)) != nil
            let decoded300 = (try? JSONDecoder().decode(JSONValue.self, from: Data(nestedArrays(300).utf8))) != nil
            // Built by hand (decoding can no longer make one this deep); 100 is past the bound
            // while small enough for the value's own release to stay shallow.
            var deep = JSONValue.null
            for _ in 0..<100 { deep = .array([deep]) }
            let encoded = (try? JSONEncoder().encode(deep)) != nil
            var shallow = JSONValue.null
            for _ in 0..<20 { shallow = .array([shallow]) }
            let shallowRoundTrip = (try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(shallow))) == shallow
            return [decodedUTF16, decoded300, encoded, shallowRoundTrip]
        }.value
        #expect(results == [false, false, false, true])
    }

    @Test func nonUTF8UpstreamDataIsNotParsed() async throws {
        let deep = #"{"a":"\"","usage":"# + nestedArrays(10_000) + "}"
        let outcome = await Task.detached { () -> (Usage?, Bool) in
            var scanner = SSEUsageScanner()
            var event = Data("data: ".utf8)
            event.append(deep.data(using: .utf16LittleEndian)!)
            event.append(Data("\n\n".utf8))
            scanner.feed(event)
            let catalog = #"{"data":[{"id":"\"","x":"# + nestedArrays(10_000) + "}]}"
            let refused = (try? ModelCatalog.parse(catalog.data(using: .utf16BigEndian)!)) == nil
            return (scanner.usage, refused)
        }.value
        #expect(outcome.0 == nil)
        #expect(outcome.1)
    }

    @Test func routerBodyIsReadOnlyWhenPulled() async throws {
        let counter = ByteCounter()
        let dropped = Mutex(false)
        var stream: AsyncThrowingStream<Data, any Error>? = URLSessionRouterClient.chunks(
            of: CountingBytes(counter: counter, total: 100_000), onDrop: { dropped.withLock { $0 = true } })
        var iterator = stream!.makeAsyncIterator()
        let first = try await iterator.next()
        #expect(first == Data("aaaaaaaaa\n".utf8))
        try await Task.sleep(for: .milliseconds(100))
        // Nothing read ahead of the consumer.
        #expect(counter.value == 10)
        let second = try await iterator.next()
        #expect(second?.count == 10)
        #expect(counter.value == 20)
        stream = nil
        iterator = AsyncThrowingStream<Data, any Error> { $0.finish() }.makeAsyncIterator()
        #expect(dropped.withLock { $0 })
        _ = iterator
    }

    /// The bridge stops reading the router (the guest left, the VM stopped): the URLSession task is
    /// cancelled at once, even if the byte sequence itself would ignore the cancellation.
    @Test func cancellingTheReaderCancelsTheRequestAtOnce() async throws {
        let gate = OpenOnceGate()
        let dropped = Mutex(false)
        let stream = URLSessionRouterClient.chunks(of: SilentBytes(gate: gate), onDrop: {
            dropped.withLock { $0 = true }
            gate.open()
        })
        let reader = Task { for try await _ in stream {} }
        try await Task.sleep(for: .milliseconds(100))
        reader.cancel()
        let deadline = ContinuousClock.now + .seconds(2)
        while !dropped.withLock({ $0 }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(dropped.withLock { $0 })
        gate.open()
        _ = await reader.result
    }
}

/// Opens once; `wait()` returns when it is open (never because its task was cancelled).
final class OpenOnceGate: Sendable {
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
        for waiter in waiters { waiter.resume() }
    }
}

/// A body that sends nothing until `gate` opens, whatever happens to its task.
struct SilentBytes: AsyncSequence, Sendable {
    typealias Element = UInt8
    let gate: OpenOnceGate
    struct AsyncIterator: AsyncIteratorProtocol {
        let gate: OpenOnceGate
        mutating func next() async throws -> UInt8? {
            await gate.wait()
            return nil
        }
    }
    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(gate: gate) }
}

final class ByteCounter: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    func next() -> Int { count.withLock { c in c += 1; return c } }
}

/// `total` bytes: nine `a` then a newline, repeated; counts what is pulled.
struct CountingBytes: AsyncSequence, Sendable {
    typealias Element = UInt8
    let counter: ByteCounter
    let total: Int

    struct AsyncIterator: AsyncIteratorProtocol {
        let counter: ByteCounter
        let total: Int
        mutating func next() async throws -> UInt8? {
            if counter.value >= total { return nil }
            return counter.next() % 10 == 0 ? 0x0A : 0x61
        }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(counter: counter, total: total) }
}
