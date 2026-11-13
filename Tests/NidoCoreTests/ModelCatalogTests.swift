// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCore

@Suite struct ModelCatalogTests {
    private static let sample = #"""
        {"object":"list","data":[
          {"id":"meta-llama/Llama-3.3-70B-Instruct","object":"model","created":1700000000,"owned_by":"meta-llama",
           "architecture":{"input_modalities":["text"]},
           "providers":[
             {"provider":"groq","status":"live","context_length":131072,
              "pricing":{"input":0.59,"output":0.79},"supports_tools":true,"supports_structured_output":false},
             {"provider":"together","status":"staging"},
             {"status":"live"},
             {"provider":"novita","context_length":"lots","pricing":{"input":"0.2"}}
           ]},
          {"id":"org/no-providers"},
          {"owned_by":"nobody"},
          {"id":42},
          "garbage"
        ]}
        """#

    @Test func catalogParsesPartialProviders() throws {
        let models = try ModelCatalog.parse(Data(Self.sample.utf8))
        #expect(models.map(\.id) == ["meta-llama/Llama-3.3-70B-Instruct", "org/no-providers"])
        let llama = models[0]
        #expect(llama.ownedBy == "meta-llama")
        #expect(llama.providers.map(\.provider) == ["groq", "together", "novita"])
        let groq = llama.providers[0]
        #expect(groq.status == "live")
        #expect(groq.contextLength == 131072)
        #expect(groq.inputPrice == 0.59)
        #expect(groq.outputPrice == 0.79)
        #expect(groq.supportsTools == true)
        let together = llama.providers[1]
        #expect(together.status == "staging")
        #expect(together.contextLength == nil)
        #expect(together.inputPrice == nil)
        #expect(together.supportsTools == nil)
        let novita = llama.providers[2]
        #expect(novita.contextLength == nil)
        #expect(novita.inputPrice == 0.2)
        #expect(novita.outputPrice == nil)
        #expect(models[1].ownedBy == nil)
        #expect(models[1].providers.isEmpty)

        #expect(throws: ModelCatalogError.invalidResponse) { try ModelCatalog.parse(Data("[]".utf8)) }
        #expect(throws: ModelCatalogError.invalidResponse) { try ModelCatalog.parse(Data("{}".utf8)) }
        #expect(throws: ModelCatalogError.invalidResponse) { try ModelCatalog.parse(Data("nope".utf8)) }
    }

    @Test func catalogIsCachedForAnHour() async throws {
        let router = FakeRouter.answering(chunks: [Self.sample])
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let catalog = ModelCatalog(router: router, tokenStore: FakeTokenStore(nil), now: { clock.now() })
        #expect(try await catalog.models().count == 2)
        clock.advance(3599)
        #expect(try await catalog.models().count == 2)
        #expect(router.calls.count == 1)
        #expect(router.calls.first?.endpoint == .models)
        #expect(router.calls.first?.token == nil)
        clock.advance(2)
        _ = try await catalog.models()
        #expect(router.calls.count == 2)
        _ = try await catalog.models(forceRefresh: true)
        #expect(router.calls.count == 3)
    }

    @Test func catalogErrors() async throws {
        let failing = ModelCatalog(router: FakeRouter.answering(status: 500, chunks: ["oops"]), tokenStore: nil)
        await #expect(throws: ModelCatalogError.httpStatus(500)) { _ = try await failing.models() }
        let huge = String(repeating: " ", count: ModelCatalog.maxResponseBytes + 1)
        let tooLarge = ModelCatalog(router: FakeRouter.answering(chunks: [huge]), tokenStore: nil)
        await #expect(throws: ModelCatalogError.responseTooLarge) { _ = try await tooLarge.models() }
    }
}
