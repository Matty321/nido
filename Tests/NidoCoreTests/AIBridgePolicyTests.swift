// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCore

@Suite struct AIBridgePolicyTests {
    @Test func policyDefaultsOff() throws {
        let policy = AIBridgePolicy()
        #expect(!policy.enabled)
        #expect(policy.allowedModels.isEmpty)
        #expect(policy.tokensPerDay == 200_000)
        #expect(policy.requestsPerMinute == 20)
        #expect(policy.maxTokensPerRequest == 4_096)
        #expect(!policy.privacyAcknowledged)
        #expect(AIBridgePolicy.maxConcurrentRequests == 2)

        // A VM without the field has the bridge off, and the field is not written.
        var config = VMConfig(
            id: UUID(), name: try VMName("vm"), guest: .linux, cpuCount: 2, memoryBytes: 1 << 30,
            diskBytes: 1 << 30, macAddress: "02:00:00:00:00:01")
        #expect(config.aiBridge == nil)
        let object = try JSONSerialization.jsonObject(with: config.encoded()) as? [String: Any]
        #expect(object?["aiBridge"] == nil)

        config.aiBridge = AIBridgePolicy(enabled: true, allowedModels: ["org/m"], tokensPerDay: 1000)
        #expect(try VMConfig.decode(config.encoded()) == config)

        // A partial policy takes the defaults for what is missing.
        let partial = try JSONDecoder().decode(AIBridgePolicy.self, from: Data(#"{"enabled":true}"#.utf8))
        #expect(partial.enabled)
        #expect(partial.tokensPerDay == 200_000)
        #expect(partial.allowedModels.isEmpty)
    }

    @Test func schema2ConfigHasNoBridge() throws {
        let json = #"""
            {"schemaVersion":2,"id":"8D3F1B9E-2E4A-4C11-9A55-0B8E5B1D2C3F","name":"vecchia","guest":"linux",
             "cpuCount":2,"memoryBytes":2147483648,"diskBytes":4294967296,"macAddress":"02:00:00:00:00:02"}
            """#
        #expect(try VMConfig.decode(Data(json.utf8)).aiBridge == nil)
    }

    @Test func allowedModelSuffixes() {
        let policy = AIBridgePolicy(enabled: true, allowedModels: ["org/m"])
        for model in ["org/m", "org/m:cheapest", "org/m:fastest", "org/m:preferred", "org/m:groq",
                      "org/m:fireworks-ai", "org/m:" + String(repeating: "a", count: 40)] {
            #expect(policy.isAllowed(model: model), "\(model)")
        }
        for model in ["org/other", "org/m:../x", "org/m:A B", "org/m:", "org/m:Groq", "org/mx", "ORG/m",
                      "org/m:groq:cheapest", "", ":groq", "org/m:" + String(repeating: "a", count: 41),
                      "org/m:groq\n", "org/m:gr/oq"] {
            #expect(!policy.isAllowed(model: model), "\(model)")
        }
        #expect(!AIBridgePolicy().isAllowed(model: "org/m"))
    }
}
