// SPDX-License-Identifier: Apache-2.0
#if DEBUG
    import Foundation
    import Synchronization

    /// DEBUG only (app launch flag `-NidoFakeAIRouter`, real proofs): a router that never touches
    /// the network. `GET /models` answers a small fixed catalog; `POST /chat/completions` answers
    /// "Ciao dal router finto di Nido." with usage, as SSE when the request asks to stream.
    public final class DebugFakeRouter: RouterClient {
        public static let catalogJSON = #"""
            {"object":"list","data":[
            {"id":"openai/gpt-oss-120b","owned_by":"openai","providers":[{"provider":"cerebras","status":"live","context_length":131072,"pricing":{"input":0.25,"output":0.69}}]},
            {"id":"meta-llama/Llama-3.3-70B-Instruct","owned_by":"meta-llama","providers":[{"provider":"groq","status":"live"}]},
            {"id":"Qwen/Qwen3-8B","owned_by":"Qwen","providers":[{"provider":"featherless-ai","status":"live"}]}
            ]}
            """#

        private let calls = Mutex(0)

        public init() {}

        /// Calls received so far.
        public var callCount: Int { calls.withLock { $0 } }

        public func send(_ endpoint: RouterEndpoint, body: Data?, accept: String, token: HFToken?) async throws
            -> RouterResponse
        {
            calls.withLock { $0 += 1 }
            switch endpoint {
            case .models:
                return Self.response(contentType: "application/json", [Data(Self.catalogJSON.utf8)])
            case .chatCompletions:
                let request = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                let model = request["model"] as? String ?? "unknown"
                let words = ["Ciao", " dal", " router", " finto", " di", " Nido."]
                guard request["stream"] as? Bool == true else {
                    let answer: [String: Any] = [
                        "id": "fake-1", "object": "chat.completion", "created": 0, "model": model,
                        "choices": [["index": 0, "finish_reason": "stop",
                                     "message": ["role": "assistant", "content": words.joined()]]],
                        "usage": ["prompt_tokens": 9, "completion_tokens": words.count, "total_tokens": 9 + words.count],
                    ]
                    return Self.response(contentType: "application/json", [try JSONSerialization.data(withJSONObject: answer)])
                }
                var events: [Data] = []
                for word in words {
                    let chunk: [String: Any] = [
                        "id": "fake-1", "object": "chat.completion.chunk", "created": 0, "model": model,
                        "choices": [["index": 0, "delta": ["content": word]]],
                    ]
                    events.append(Self.event(try JSONSerialization.data(withJSONObject: chunk)))
                }
                let usage: [String: Any] = [
                    "id": "fake-1", "object": "chat.completion.chunk", "created": 0, "model": model,
                    "choices": [] as [Any],
                    "usage": ["prompt_tokens": 9, "completion_tokens": words.count, "total_tokens": 9 + words.count],
                ]
                events.append(Self.event(try JSONSerialization.data(withJSONObject: usage)))
                events.append(Data("data: [DONE]\n\n".utf8))
                return Self.response(contentType: "text/event-stream", events)
            }
        }

        private static func event(_ json: Data) -> Data {
            Data("data: ".utf8) + json + Data("\n\n".utf8)
        }

        private static func response(contentType: String, _ chunks: [Data]) -> RouterResponse {
            let body = AsyncThrowingStream<Data, any Error> { continuation in
                for chunk in chunks { continuation.yield(chunk) }
                continuation.finish()
            }
            return RouterResponse(status: 200, contentType: contentType, provider: "nido-fake", body: body)
        }
    }

    /// DEBUG only: a token store in memory holding a dummy token, so a proof with
    /// `DebugFakeRouter` never reads or writes the user's Keychain.
    public final class DebugMemoryTokenStore: TokenStore {
        private let token: Mutex<HFToken?>

        public init(_ raw: String? = "hf_NidoDebugFakeToken") {
            token = Mutex(raw.flatMap(HFToken.init))
        }

        public func read() throws -> HFToken? { token.withLock { $0 } }
        public func save(_ token: HFToken) throws { self.token.withLock { $0 = token } }
        public func delete() throws { token.withLock { $0 = nil } }
    }
#endif
