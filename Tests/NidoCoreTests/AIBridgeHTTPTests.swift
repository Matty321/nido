// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import Testing
@testable import NidoCore

@Suite struct AIBridgeHTTPTests {
    private func read(_ raw: Data, endOfInput: Bool = true, timeout: Duration = .seconds(10))
        async -> Result<AIBridgeRequest, AIBridgeFailure>
    {
        do {
            return .success(try await AIBridgeHTTP.readRequest(
                from: MemoryByteStream(raw, endOfInput: endOfInput), timeout: timeout))
        } catch {
            return .failure(error)
        }
    }

    @Test func parsesARequest() async throws {
        let body = #"{"model":"org/m"}"#
        let result = await read(chatRequest(body, headers: ["Authorization: Bearer x", "X-Thing:  a b "]))
        let request = try result.get()
        #expect(request.method == "POST")
        #expect(request.path == "/v1/chat/completions")
        #expect(request.body == Data(body.utf8))
        #expect(request.headers["content-type"] == "application/json")
        #expect(request.headers["x-thing"] == "a b")
    }

    @Test func queryIsNotPartOfThePath() async throws {
        let request = try await read(rawRequest("GET", "/v1/models?limit=1")).get()
        #expect(request.path == "/v1/models")
        #expect(request.body.isEmpty)
    }

    @Test func bodyTooLarge413() async throws {
        // Refused from the declared length, before reading the body.
        let raw = rawRequest("POST", "/v1/chat/completions",
                             headers: ["Content-Length: \(AIBridgeHTTP.maxBodyBytes + 1)"])
        #expect(await read(raw, endOfInput: false) == .failure(.requestTooLarge))
        // Exactly the limit is read.
        let body = "{" + String(repeating: " ", count: AIBridgeHTTP.maxBodyBytes - 2) + "}"
        let full = await read(rawRequest("POST", "/v1/chat/completions", body: body))
        #expect(try full.get().body.count == AIBridgeHTTP.maxBodyBytes)
        // Headers beyond 16 KiB.
        let big = rawRequest("GET", "/v1/models", headers: ["X-Big: " + String(repeating: "a", count: 16 * 1024)])
        #expect(await read(big) == .failure(.requestTooLarge))

        let env = try ProxyEnv(router: .unreachable())
        defer { env.cleanup() }
        let answer = await env.send(raw)
        #expect(answer.status == 413)
        #expect(answer.errorCode == "request_too_large")
    }

    @Test func chunkedRequest411() async throws {
        let chunked = rawRequest("POST", "/v1/chat/completions", body: "5\r\nhello\r\n0\r\n\r\n",
                                 headers: ["Transfer-Encoding: chunked"], contentLength: false)
        #expect(await read(chunked) == .failure(.lengthRequired))
        // Both headers: still refused (no request smuggling).
        let both = rawRequest("POST", "/v1/chat/completions", body: "{}",
                              headers: ["Transfer-Encoding: chunked"])
        #expect(await read(both) == .failure(.lengthRequired))
        let noLength = rawRequest("POST", "/v1/chat/completions", body: "{}", contentLength: false)
        #expect(await read(noLength) == .failure(.lengthRequired))

        let env = try ProxyEnv(router: .unreachable())
        defer { env.cleanup() }
        let answer = await env.send(chunked)
        #expect(answer.status == 411)
        #expect(answer.errorCode == "length_required")
        #expect(answer.errorType == "invalid_request_error")
    }

    @Test func malformedRequestsAre400() async {
        for raw in [
            "GARBAGE\r\n\r\n",
            "POST /v1/chat/completions HTTP/2.0\r\nContent-Length: 2\r\n\r\n{}",
            "POST v1/chat/completions HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}",
            "POST /v1/chat/completions HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\n{}",
            "POST /v1/chat/completions HTTP/1.1\r\nContent-Length: -1\r\n\r\n{}",
            "POST /v1/chat/completions HTTP/1.1\r\nContent-Length: 2\r\n folded\r\n\r\n{}",
            "POST /v1/chat/completions HTTP/1.1\r\nBad Header: x\r\nContent-Length: 2\r\n\r\n{}",
            // Bare CR or LF inside a header line or the request line.
            "POST /v1/chat/completions HTTP/1.1\r\nX-A: a\rb\r\nContent-Length: 2\r\n\r\n{}",
            "POST /v1/chat/completions HTTP/1.1\r\nX-A: a\nX-B: b\r\nContent-Length: 2\r\n\r\n{}",
            "POST /v1/chat/completions\r HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}",
            // Shorter than declared.
            "POST /v1/chat/completions HTTP/1.1\r\nContent-Length: 10\r\n\r\n{}",
        ] {
            let result = await read(Data(raw.utf8))
            guard case .failure(let failure) = result else {
                Issue.record("accepted: \(raw)")
                continue
            }
            #expect(failure.status == 400, "\(raw)")
            #expect(failure.code == "invalid_request", "\(raw)")
        }
    }

    @Test func slowRequestTimesOut() async throws {
        let partial = Data("POST /v1/chat/completions HTTP/1.1\r\nContent-Le".utf8)
        let started = ContinuousClock.now
        let result = await read(partial, endOfInput: false, timeout: .milliseconds(200))
        #expect(result == .failure(.requestTimeout))
        // Loose for a loaded machine, yet below `readTimeout` (10 s): the 200 ms timeout given here
        // is the one that fired.
        #expect(ContinuousClock.now - started < .seconds(8))
        #expect(AIBridgeHTTP.readTimeout == .seconds(10))
    }

    @Test func errorBodiesHaveTheOpenAIShape() throws {
        let raw = AIBridgeHTTP.errorResponse(.modelNotAllowed)
        let answer = HTTPResult(raw)
        #expect(answer.status == 403)
        #expect(answer.headers["connection"] == "close")
        #expect(answer.headers["content-type"] == "application/json")
        #expect(answer.headers["content-length"] == "\(answer.body.count)")
        let error = try #require(answer.json?["error"] as? [String: Any])
        #expect(error["code"] as? String == "model_not_allowed")
        #expect(error["type"] as? String == "permission_error")
        #expect((error["message"] as? String)?.isEmpty == false)

        let expected: [(AIBridgeFailure, Int, String)] = [
            (.bridgeDisabled, 403, "bridge_disabled"), (.tokenMissing, 401, "token_missing"),
            (.modelNotAllowed, 403, "model_not_allowed"), (.rateLimited, 429, "rate_limited"),
            (.dailyBudgetExhausted, 429, "daily_budget_exhausted"), (.requestTooLarge, 413, "request_too_large"),
            (.lengthRequired, 411, "length_required"), (.notFound, 404, "not_found"),
            (.invalidRequest("x"), 400, "invalid_request"), (.upstreamError, 502, "upstream_error"),
        ]
        for (failure, status, code) in expected {
            #expect(failure.status == status)
            #expect(failure.code == code)
        }
    }

    @Test func fileDescriptorStreamOverASocketPair() async throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let host = FileDescriptorByteStream(fileHandle: FileHandle(fileDescriptor: fds[0], closeOnDealloc: true))
        let guest = FileDescriptorByteStream(fileHandle: FileHandle(fileDescriptor: fds[1], closeOnDealloc: true))

        try await guest.write(Data("hello".utf8))
        let got = try await host.read(upTo: 100, deadline: .now + .seconds(2))
        #expect(got == Data("hello".utf8))

        // Nothing to read: the deadline passes.
        await #expect(throws: ByteStreamError.timeout) {
            _ = try await host.read(upTo: 100, deadline: .now + .milliseconds(100))
        }

        await guest.close()
        #expect(try await host.read(upTo: 100, deadline: .now + .seconds(2)).isEmpty)
        // Writing to a closed peer is an error, not a SIGPIPE.
        await #expect(throws: (any Error).self) {
            for _ in 0..<64 { try await host.write(Data(repeating: 0, count: 65536)) }
        }
        await host.close()
    }

    /// Waiting for the guest holds no thread: many idle reads on Swift's cooperative pool leave it
    /// free, a cancelled read ends at once, and closing the stream ends a read waiting on it.
    @Test func waitingReadsHoldNoThread() async throws {
        let width = ProcessInfo.processInfo.activeProcessorCount
        var pairs: [(FileDescriptorByteStream, FileDescriptorByteStream)] = []
        for _ in 0..<(width * 4) {
            var fds: [Int32] = [0, 0]
            #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
            pairs.append((FileDescriptorByteStream(fileHandle: FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)),
                          FileDescriptorByteStream(fileHandle: FileHandle(fileDescriptor: fds[1], closeOnDealloc: true))))
        }
        let readers = pairs.map { pair in
            Task { try await pair.0.read(upTo: 16, deadline: .now + .seconds(30)) }
        }
        try await Task.sleep(for: .milliseconds(200))
        let started = ContinuousClock.now
        await withTaskGroup(of: Int.self) { group in
            for i in 0..<(width * 2) { group.addTask { i } }
        }
        #expect(ContinuousClock.now - started < .milliseconds(500))

        // Cancelled: ends at once with CancellationError.
        let cancelStart = ContinuousClock.now
        readers[0].cancel()
        await #expect(throws: CancellationError.self) { _ = try await readers[0].value }
        // "At once", not after the 30 s deadline; generous for a loaded machine.
        #expect(ContinuousClock.now - cancelStart < .milliseconds(500))

        // Closed while waiting: ends with `.closed`.
        await pairs[1].0.close()
        await #expect(throws: ByteStreamError.closed) { _ = try await readers[1].value }

        // A byte arrives: the waiting read gets it.
        try await pairs[2].1.write(Data("x".utf8))
        #expect(try await readers[2].value == Data("x".utf8))

        for reader in readers.dropFirst(3) { reader.cancel() }
        for reader in readers.dropFirst(3) { _ = try? await reader.value }
        for pair in pairs {
            await pair.0.close()
            await pair.1.close()
        }
    }
}
