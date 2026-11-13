// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
@testable import NidoCore

private let simpleChat = #"{"model":"org/m","messages":[{"role":"user","content":"ciao"}]}"#

/// The answer headers the guest may see, and nothing else.
private let allowedAnswerHeaders: Set<String> = ["content-type", "content-length", "connection"]

@Suite struct AIBridgeProxyTests {
    @Test func disabledReturns403WithoutNetwork() async throws {
        let env = try ProxyEnv(router: .unreachable())
        defer { env.cleanup() }
        for policy in [nil, AIBridgePolicy(), AIBridgePolicy(enabled: false, allowedModels: ["org/m"])] {
            let chat = await env.send(chatRequest(simpleChat), policy: policy)
            #expect(chat.status == 403)
            #expect(chat.errorCode == "bridge_disabled")
            let models = await env.send(rawRequest("GET", "/v1/models"), policy: policy)
            #expect(models.status == 403)
            #expect(models.errorCode == "bridge_disabled")
        }
        // Off wins over a missing token.
        let noToken = try ProxyEnv(router: .unreachable(), token: nil)
        defer { noToken.cleanup() }
        #expect(await noToken.send(chatRequest(simpleChat), policy: nil).errorCode == "bridge_disabled")
        #expect(env.router.calls.isEmpty)
    }

    @Test func missingTokenReturns401() async throws {
        for env in [try ProxyEnv(router: .unreachable(), token: nil),
                    try ProxyEnv(router: .unreachable(), failsReadingToken: true)] {
            defer { env.cleanup() }
            let chat = await env.send(chatRequest(simpleChat))
            #expect(chat.status == 401)
            #expect(chat.errorCode == "token_missing")
            #expect(chat.errorType == "authentication_error")
            #expect(await env.send(rawRequest("GET", "/v1/models")).status == 401)
            #expect(env.router.calls.isEmpty)
        }
    }

    @Test func guestAuthorizationHeaderDropped() async throws {
        let router = FakeRouter.answering(chunks: [completionJSON()])
        let env = try ProxyEnv(router: router)
        defer { env.cleanup() }
        let answer = await env.send(chatRequest(simpleChat, headers: [
            "Authorization: Bearer guest-key-XYZ", "X-Api-Key: other-key", "Cookie: session=abc",
            "X-HF-Bill-To: someone-else",
        ]))
        #expect(answer.status == 200)
        let call = try #require(router.calls.first)
        #expect(call.token == HFToken(testSecret))
        #expect(call.endpoint == .chatCompletions)
        let forwarded = String(decoding: call.body ?? Data(), as: UTF8.self)
        for leaked in ["guest-key-XYZ", "other-key", "session=abc", "someone-else"] {
            #expect(!forwarded.contains(leaked))
        }
        #expect(Set(answer.headers.keys).isSubset(of: allowedAnswerHeaders))

        // The real client sends exactly our headers, to the fixed URL.
        let request = URLSessionRouterClient.makeRequest(
            .chatCompletions, body: Data("{}".utf8), accept: "application/json", token: HFToken(testSecret))
        #expect(request.url?.absoluteString == "https://router.huggingface.co/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.allHTTPHeaderFields == [
            "Authorization": "Bearer \(testSecret)", "Content-Type": "application/json",
            "Accept": "application/json",
        ])
        #expect(request.timeoutInterval == 120)
        let models = URLSessionRouterClient.makeRequest(.models, body: nil, accept: "application/json", token: nil)
        #expect(models.url?.absoluteString == "https://router.huggingface.co/v1/models")
        #expect(models.httpMethod == "GET")
        #expect(models.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func upstreamHeadersAreNotForwarded() async throws {
        // Only the content type (and the provider for the log) come back from the router.
        let router = FakeRouter.answering(contentType: "application/json; charset=utf-8", provider: "groq",
                                          chunks: [completionJSON()])
        let env = try ProxyEnv(router: router)
        defer { env.cleanup() }
        let answer = await env.send(chatRequest(simpleChat))
        #expect(answer.headers["content-type"] == "application/json; charset=utf-8")
        #expect(Set(answer.headers.keys).isSubset(of: allowedAnswerHeaders))
        #expect(answer.headers["connection"] == "close")
    }

    @Test func tokenNeverInResponseOrLog() async throws {
        let echoing: [(FakeRouter, Int, String)] = [
            (.answering(chunks: [completionJSON(content: testSecret)]), 502, "upstream_error"),
            (.answering(status: 401, chunks: [#"{"error":"bad token \#(testSecret)"}"#]), 401, "upstream_unauthorized"),
            (FakeRouter { _, _ in throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: testSecret]) },
             502, "upstream_error"),
        ]
        for (router, status, code) in echoing {
            let env = try ProxyEnv(router: router)
            defer { env.cleanup() }
            let answer = await env.send(chatRequest(simpleChat))
            #expect(answer.status == status)
            #expect(answer.errorCode == code)
            #expect(!answer.text.contains(testSecret))
            #expect(!env.logText().contains(testSecret))
            #expect(env.logEntries().last?["status"] as? Int == status)
        }

        // Streaming, with the token split across chunks: the guest never gets it whole.
        let half = testSecret.count / 2
        let sse = FakeRouter.answering(contentType: "text/event-stream", chunks: [
            "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\"\(testSecret.prefix(half))",
            "\(testSecret.dropFirst(half))\"}}]}\n\n",
            "data: [DONE]\n\n",
        ])
        let env = try ProxyEnv(router: sse)
        defer { env.cleanup() }
        let answer = await env.send(chatRequest(#"{"model":"org/m","stream":true,"messages":[]}"#))
        #expect(answer.status == 200)
        #expect(answer.text.contains("\"ok\""))
        #expect(!answer.text.contains(testSecret))
        #expect(!answer.text.contains("[DONE]"))
        #expect(!env.logText().contains(testSecret))
        #expect(!(try String(contentsOf: env.usageURL, encoding: .utf8)).contains(testSecret))
    }

    @Test func maxTokensClamped() async throws {
        let router = FakeRouter.answering(chunks: [completionJSON()])
        let env = try ProxyEnv(router: router)
        defer { env.cleanup() }

        _ = await env.send(chatRequest(#"{"model":"org/m","max_tokens":100000,"temperature":0.7,"messages":[{"role":"user","content":"x"}],"seed":12345678901234567890}"#))
        var body = try #require(forwardedBody(router))
        #expect(body["max_tokens"] as? Int == 4096)
        #expect(body["max_completion_tokens"] == nil)
        let raw = String(decoding: router.calls.last?.body ?? Data(), as: UTF8.self)
        #expect(raw.contains("0.7"))
        #expect(!raw.contains("0.69999"))
        #expect(raw.contains("12345678901234567890"))
        #expect((body["messages"] as? [[String: String]])?.first?["content"] == "x")

        _ = await env.send(chatRequest(#"{"model":"org/m","max_completion_tokens":9999}"#))
        body = try #require(forwardedBody(router))
        #expect(body["max_completion_tokens"] as? Int == 4096)
        #expect(body["max_tokens"] == nil)

        _ = await env.send(chatRequest(#"{"model":"org/m"}"#))
        #expect(forwardedBody(router)?["max_tokens"] as? Int == 4096)

        _ = await env.send(chatRequest(#"{"model":"org/m","max_tokens":50,"max_completion_tokens":60000}"#))
        body = try #require(forwardedBody(router))
        #expect(body["max_tokens"] as? Int == 50)
        #expect(body["max_completion_tokens"] as? Int == 4096)

        let small = AIBridgePolicy(enabled: true, allowedModels: ["org/m"], maxTokensPerRequest: 256)
        _ = await env.send(chatRequest(#"{"model":"org/m","max_tokens":1000}"#), policy: small)
        #expect(forwardedBody(router)?["max_tokens"] as? Int == 256)

        // Not an integer: refused, not forwarded.
        let calls = router.calls.count
        let bad = await env.send(chatRequest(#"{"model":"org/m","max_tokens":"lots"}"#))
        #expect(bad.status == 400)
        #expect(router.calls.count == calls)
    }

    @Test func streamGetsIncludeUsage() async throws {
        let router = FakeRouter.answering(contentType: "text/event-stream", chunks: ["data: [DONE]\n\n"])
        let env = try ProxyEnv(router: router)
        defer { env.cleanup() }

        _ = await env.send(chatRequest(#"{"model":"org/m","stream":true,"stream_options":{"foo":1,"include_usage":false}}"#))
        var body = try #require(forwardedBody(router))
        let options = try #require(body["stream_options"] as? [String: Any])
        #expect(options["include_usage"] as? Bool == true)
        #expect(options["foo"] as? Int == 1)
        #expect(router.calls.last?.accept == "text/event-stream")

        _ = await env.send(chatRequest(#"{"model":"org/m","stream":true}"#))
        body = try #require(forwardedBody(router))
        #expect((body["stream_options"] as? [String: Any])?["include_usage"] as? Bool == true)
        #expect(body["stream"] as? Bool == true)

        _ = await env.send(chatRequest(#"{"model":"org/m","stream":false}"#))
        body = try #require(forwardedBody(router))
        #expect(body["stream_options"] == nil)
        #expect(router.calls.last?.accept == "application/json")

        let bad = await env.send(chatRequest(#"{"model":"org/m","stream":true,"stream_options":"yes"}"#))
        #expect(bad.status == 400)
    }

    @Test func usageCommittedFromSSE() async throws {
        let chunks = [
            "data: {\"choices\":[{\"delta\":{\"content\":\"ciao\"}}]}\n\n",
            "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":11,\"completion_tokens\":22,\"total_tokens\":33}}\n\n",
            "data: [DONE]\n\n",
        ]
        let router = FakeRouter.answering(contentType: "text/event-stream", provider: "groq", chunks: chunks)
        let env = try ProxyEnv(router: router)
        defer { env.cleanup() }
        let answer = await env.send(chatRequest(#"{"model":"org/m:groq","stream":true,"messages":[]}"#))
        #expect(answer.status == 200)
        #expect(answer.headers["content-type"] == "text/event-stream")
        #expect(answer.headers["content-length"] == nil)
        #expect(answer.text == chunks.joined())
        #expect(await env.limiter.tokensUsedToday() == 33)

        let entry = try #require(env.logEntries().last)
        #expect(entry["model"] as? String == "org/m:groq")
        #expect(entry["provider"] as? String == "groq")
        #expect(entry["inputTokens"] as? Int == 11)
        #expect(entry["outputTokens"] as? Int == 22)
        #expect(entry["estimated"] as? Bool == false)
        #expect(entry["status"] as? Int == 200)

        // Usage of a non-streaming answer.
        let plain = FakeRouter.answering(chunks: [completionJSON(prompt: 3, completion: 4)])
        let env2 = try ProxyEnv(router: plain)
        defer { env2.cleanup() }
        let ok = await env2.send(chatRequest(simpleChat))
        #expect(ok.status == 200)
        #expect(ok.headers["content-length"] == "\(ok.body.count)")
        #expect(ok.text == completionJSON(prompt: 3, completion: 4))
        #expect(await env2.limiter.tokensUsedToday() == 7)
    }

    @Test func missingUsageChargesEstimate() async throws {
        func estimate(_ router: FakeRouter, maxTokens: Int = 4096) -> Int {
            let bytes = router.calls.last?.body?.count ?? 0
            return (bytes + 3) / 4 + maxTokens
        }
        // A stream without usage.
        let sse = FakeRouter.answering(contentType: "text/event-stream", chunks: [
            "data: {\"choices\":[{\"delta\":{\"content\":\"ciao\"}}]}\n\n", "data: [DONE]\n\n",
        ])
        let env = try ProxyEnv(router: sse)
        defer { env.cleanup() }
        _ = await env.send(chatRequest(#"{"model":"org/m","stream":true,"messages":[]}"#))
        #expect(await env.limiter.tokensUsedToday() == estimate(sse))
        let entry = try #require(env.logEntries().last)
        #expect(entry["estimated"] as? Bool == true)
        #expect((entry["inputTokens"] as? Int ?? 0) + (entry["outputTokens"] as? Int ?? 0) == estimate(sse))

        // A JSON answer without usage, `n` choices.
        let plain = FakeRouter.answering(chunks: [#"{"choices":[]}"#])
        let env2 = try ProxyEnv(router: plain)
        defer { env2.cleanup() }
        _ = await env2.send(chatRequest(#"{"model":"org/m","max_tokens":100,"n":3}"#))
        #expect(await env2.limiter.tokensUsedToday() == estimate(plain, maxTokens: 300))

        // A stream cut after some bytes reached the guest: the estimate.
        let cut = FakeRouter.answering(contentType: "text/event-stream",
                                       chunks: ["data: {\"choices\":[]}\n\n"], failAtEnd: true)
        let env3 = try ProxyEnv(router: cut)
        defer { env3.cleanup() }
        _ = await env3.send(chatRequest(#"{"model":"org/m","stream":true}"#))
        #expect(await env3.limiter.tokensUsedToday() == estimate(cut))

        // Failed before any byte: nothing charged.
        let down = FakeRouter { _, _ in throw URLError(.timedOut) }
        let env4 = try ProxyEnv(router: down)
        defer { env4.cleanup() }
        #expect(await env4.send(chatRequest(simpleChat)).status == 502)
        #expect(await env4.limiter.tokensUsedToday() == 0)
        // An error answer of the router keeps its status, says nothing of its own, charges nothing.
        let refused = FakeRouter.answering(status: 422, chunks: [#"{"error":{"message":"bad"}}"#])
        let env5 = try ProxyEnv(router: refused)
        defer { env5.cleanup() }
        let answer = await env5.send(chatRequest(simpleChat))
        #expect(answer.status == 422)
        #expect(answer.errorCode == "upstream_invalid_request")
        #expect(!answer.text.contains("bad"))
        #expect(await env5.limiter.tokensUsedToday() == 0)
    }

    /// What the router says when it refuses a call may name the account behind the token (user,
    /// organisation, credits, billing): the guest gets the status and a fixed explanation only.
    @Test func routerErrorsNeverTellTheGuestAboutTheAccount() async throws {
        let account = #"{"error":"Org acme-corp (user mario.rossi) has used 97% of its $2.00 PRO credits"}"#
        let expected: [(Int, String)] = [
            (400, "upstream_invalid_request"), (401, "upstream_unauthorized"), (402, "upstream_payment_required"),
            (403, "upstream_unauthorized"), (404, "upstream_not_found"), (408, "upstream_timeout"),
            (422, "upstream_invalid_request"), (429, "upstream_rate_limited"), (500, "upstream_unavailable"),
            (503, "upstream_unavailable"), (504, "upstream_timeout"),
        ]
        for (status, code) in expected {
            let env = try ProxyEnv(router: .answering(status: status, chunks: [account]))
            defer { env.cleanup() }
            let answer = await env.send(chatRequest(simpleChat))
            #expect(answer.status == status)
            #expect(answer.errorCode == code, "\(status)")
            #expect(answer.headers["content-type"] == "application/json")
            for leak in ["acme", "mario", "97%", "$2.00"] {
                #expect(!answer.text.contains(leak), "\(status): \(leak)")
            }
            #expect(!env.logText().contains("acme"))
            #expect(await env.limiter.tokensUsedToday() == 0)
        }
    }

    @Test func rateLimitPerMinute() async throws {
        let router = FakeRouter.answering(chunks: [completionJSON()])
        let env = try ProxyEnv(router: router)
        defer { env.cleanup() }
        let policy = AIBridgePolicy(enabled: true, allowedModels: ["org/m"], requestsPerMinute: 2)
        #expect(await env.send(chatRequest(simpleChat), policy: policy).status == 200)
        #expect(await env.send(chatRequest(simpleChat), policy: policy).status == 200)
        let third = await env.send(chatRequest(simpleChat), policy: policy)
        #expect(third.status == 429)
        #expect(third.errorCode == "rate_limited")
        #expect(router.calls.count == 2)
        #expect(env.logEntries().last?["status"] as? Int == 429)
        env.clock.advance(61)
        #expect(await env.send(chatRequest(simpleChat), policy: policy).status == 200)
    }

    @Test func dailyBudgetExhausted429() async throws {
        let router = FakeRouter.answering(chunks: [completionJSON()])
        let env = try ProxyEnv(router: router)
        defer { env.cleanup() }
        let policy = AIBridgePolicy(enabled: true, allowedModels: ["org/m"], tokensPerDay: 1000)
        let answer = await env.send(chatRequest(#"{"model":"org/m","max_tokens":2000}"#), policy: policy)
        #expect(answer.status == 429)
        #expect(answer.errorCode == "daily_budget_exhausted")
        #expect(router.calls.isEmpty)
        // A huge `n` cannot slip a request past the budget.
        let many = await env.send(chatRequest(#"{"model":"org/m","max_tokens":10,"n":1000000000000}"#), policy: policy)
        #expect(many.errorCode == "daily_budget_exhausted")
        #expect(await env.send(chatRequest(#"{"model":"org/m","max_tokens":10}"#), policy: policy).status == 200)
    }

    @Test func concurrencyCapTwo() async throws {
        let gate = Gate()
        let router = FakeRouter { _, _ in
            await gate.wait()
            return routerResponse(status: 200, contentType: "application/json", chunks: [Data(completionJSON().utf8)])
        }
        let env = try ProxyEnv(router: router)
        defer { env.cleanup() }
        let first = Task { await env.send(chatRequest(simpleChat)) }
        let second = Task { await env.send(chatRequest(simpleChat)) }
        let deadline = ContinuousClock.now + .seconds(5)
        while router.calls.count < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(router.calls.count == 2)

        let third = await env.send(chatRequest(simpleChat))
        #expect(third.status == 429)
        #expect(third.errorCode == "rate_limited")
        gate.open()
        #expect(await first.value.status == 200)
        #expect(await second.value.status == 200)
        #expect(await env.send(chatRequest(simpleChat)).status == 200)
    }

    @Test func unknownPath404() async throws {
        let env = try ProxyEnv(router: .unreachable())
        defer { env.cleanup() }
        for raw in [
            rawRequest("GET", "/v1/chat/completions"),
            rawRequest("POST", "/v1/completions", body: simpleChat),
            rawRequest("POST", "/v1/embeddings", body: simpleChat),
            rawRequest("GET", "/v1/models/../../api/status"),
            rawRequest("GET", "/v1/models/org/m"),
            rawRequest("POST", "/v1/models", body: "{}"),
            rawRequest("GET", "/"),
            rawRequest("DELETE", "/v1/models"),
        ] {
            let answer = await env.send(raw)
            #expect(answer.status == 404, "\(String(decoding: raw, as: UTF8.self))")
            #expect(answer.errorCode == "not_found")
        }
        // Before the bridge state: an unknown path is unknown even when off.
        #expect(await env.send(rawRequest("GET", "/x"), policy: nil).status == 404)
    }

    @Test func invalidJSON400() async throws {
        let env = try ProxyEnv(router: .unreachable())
        defer { env.cleanup() }
        for body in ["not json", "[1,2]", "\"model\"", "{}", #"{"model":5}"#, #"{"model":"org/m""#, ""] {
            let answer = await env.send(chatRequest(body))
            #expect(answer.status == 400, "\(body)")
            #expect(answer.errorCode == "invalid_request", "\(body)")
            #expect(answer.errorType == "invalid_request_error")
        }
    }

    @Test func modelNotAllowed403() async throws {
        let env = try ProxyEnv(router: .unreachable())
        defer { env.cleanup() }
        for model in ["org/other", "org/m:../x", "org/m:A B"] {
            let answer = await env.send(chatRequest(#"{"model":"\#(model)"}"#))
            #expect(answer.status == 403)
            #expect(answer.errorCode == "model_not_allowed")
        }
    }

    @Test func redirectRefused() async throws {
        // The session refuses every redirect...
        let delegate = RedirectRefusingDelegate()
        let session = URLSession(configuration: URLSessionRouterClient.makeConfiguration())
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://router.huggingface.co/v1/models")!)
        let redirect = HTTPURLResponse(url: URL(string: "https://router.huggingface.co/v1/models")!,
                                       statusCode: 302, httpVersion: "HTTP/1.1",
                                       headerFields: ["Location": "https://evil.example/steal"])!
        let next = await delegate.urlSession(
            session, task: task, willPerformHTTPRedirection: redirect,
            newRequest: URLRequest(url: URL(string: "https://evil.example/steal")!))
        #expect(next == nil)
        task.cancel()

        // ...with no cache, cookies or stored credentials, and the fixed timeout.
        let configuration = URLSessionRouterClient.makeConfiguration()
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.timeoutIntervalForRequest == 120)

        // ...and an unfollowed redirect reaching the proxy is an upstream error without Location.
        let router = FakeRouter.answering(status: 302, contentType: "text/html", chunks: ["moved"])
        let env = try ProxyEnv(router: router)
        defer { env.cleanup() }
        let answer = await env.send(chatRequest(simpleChat))
        #expect(answer.status == 502)
        #expect(answer.errorCode == "upstream_error")
        #expect(answer.headers["location"] == nil)
        #expect(await env.limiter.tokensUsedToday() == 0)
    }

    @Test func catalogFilteredForGuest() async throws {
        let catalogJSON = #"""
            {"object":"list","data":[
              {"id":"org/a","owned_by":"org","providers":[{"provider":"groq","status":"live"}]},
              {"id":"org/b","owned_by":"org","providers":[]},
              {"id":"org/c","owned_by":"orgc"}]}
            """#
        let router = FakeRouter.answering(chunks: [catalogJSON])
        let clock = TestClock(Date())
        let catalog = ModelCatalog(router: router, tokenStore: FakeTokenStore(testSecret), now: { clock.now() })
        let env = try ProxyEnv(router: router, catalog: catalog)
        defer { env.cleanup() }
        let policy = AIBridgePolicy(enabled: true, allowedModels: ["org/c", "org/a", "org/gone"])
        let answer = await env.send(rawRequest("GET", "/v1/models"), policy: policy)
        #expect(answer.status == 200)
        #expect(answer.json?["object"] as? String == "list")
        let data = try #require(answer.json?["data"] as? [[String: Any]])
        #expect(data.compactMap { $0["id"] as? String } == ["org/c", "org/a"])
        #expect(data.first?["object"] as? String == "model")
        #expect(data.first?["owned_by"] as? String == "orgc")
        #expect(!answer.text.contains("org/b"))
        #expect(router.calls.first?.token == HFToken(testSecret))

        // Catalog unavailable: the allowed ids still reach the guest.
        let offline = try ProxyEnv(router: FakeRouter { _, _ in throw URLError(.notConnectedToInternet) },
                                   catalog: ModelCatalog(router: FakeRouter { _, _ in throw URLError(.timedOut) },
                                                         tokenStore: nil))
        defer { offline.cleanup() }
        let fallback = await offline.send(rawRequest("GET", "/v1/models"), policy: policy)
        #expect(fallback.status == 200)
        let ids = (fallback.json?["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
        #expect(ids == ["org/c", "org/a", "org/gone"])
    }

    @Test func logHasNoContent() async throws {
        let prompt = "PROMPT-SEGRETO-42"
        let reply = "RISPOSTA-SEGRETA-43"
        let router = FakeRouter.answering(provider: "together", chunks: [completionJSON(content: reply)])
        let env = try ProxyEnv(router: router)
        defer { env.cleanup() }
        let answer = await env.send(chatRequest(
            #"{"model":"org/m","messages":[{"role":"user","content":"\#(prompt)"}]}"#,
            headers: ["Authorization: Bearer guest-header-value"]))
        #expect(answer.text.contains(reply))
        let text = env.logText()
        for secret in [prompt, reply, "guest-header-value", testSecret, "messages", "Authorization"] {
            #expect(!text.contains(secret))
        }
        let entry = try #require(env.logEntries().last)
        #expect(Set(entry.keys) == ["time", "model", "provider", "inputTokens", "outputTokens", "estimated",
                                    "status", "durationMs"])
        let mode = try FileManager.default.attributesOfItem(atPath: env.logURL.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func slowGuestGetsTimeout() async throws {
        let env = try ProxyEnv(router: .unreachable())
        defer { env.cleanup() }
        let proxy = AIBridgeProxy(router: env.router, tokenStore: env.store, limiter: env.limiter, log: nil,
                                  catalog: nil, readTimeout: .milliseconds(100))
        let connection = MemoryByteStream(Data("POST /v1/chat".utf8), endOfInput: false)
        await proxy.serve(connection: connection, policy: { allowedPolicy })
        let answer = HTTPResult(connection.output)
        #expect(answer.status == 408)
        #expect(connection.isClosed)
    }
}
