// SPDX-License-Identifier: Apache-2.0
import Foundation

/// What a VM may do with the remote AI bridge (`VMConfig.aiBridge`; absent = bridge off).
///
/// The bridge forwards the guest's OpenAI-style calls to the Hugging Face router with the token
/// of the Mac; this policy is enforced by `AIBridgeProxy` and `AIBridgeLimiter` on the host,
/// never in the guest. A field missing from the file takes its default.
public struct AIBridgePolicy: Codable, Sendable, Equatable {
    public static let defaultTokensPerDay = 200_000
    public static let defaultRequestsPerMinute = 20
    public static let defaultMaxTokensPerRequest = 4_096
    /// Requests of one VM forwarded at the same time (not configurable).
    public static let maxConcurrentRequests = 2

    /// The bridge answers this VM (off by default).
    public var enabled: Bool
    /// Model ids chosen from the catalog; policy and provider suffixes are accepted on them
    /// (see `isAllowed(model:)`).
    public var allowedModels: [String]
    /// Input plus output tokens per local calendar day.
    public var tokensPerDay: Int
    /// Requests accepted in any 60 s window.
    public var requestsPerMinute: Int
    /// Upper bound imposed on `max_tokens` / `max_completion_tokens` of each request.
    public var maxTokensPerRequest: Int
    /// The user saw the privacy notice for this VM (texts leave the Mac).
    public var privacyAcknowledged: Bool

    public init(
        enabled: Bool = false,
        allowedModels: [String] = [],
        tokensPerDay: Int = AIBridgePolicy.defaultTokensPerDay,
        requestsPerMinute: Int = AIBridgePolicy.defaultRequestsPerMinute,
        maxTokensPerRequest: Int = AIBridgePolicy.defaultMaxTokensPerRequest,
        privacyAcknowledged: Bool = false
    ) {
        self.enabled = enabled
        self.allowedModels = allowedModels
        self.tokensPerDay = tokensPerDay
        self.requestsPerMinute = requestsPerMinute
        self.maxTokensPerRequest = maxTokensPerRequest
        self.privacyAcknowledged = privacyAcknowledged
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, allowedModels, tokensPerDay, requestsPerMinute, maxTokensPerRequest, privacyAcknowledged
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        allowedModels = try c.decodeIfPresent([String].self, forKey: .allowedModels) ?? []
        tokensPerDay = try c.decodeIfPresent(Int.self, forKey: .tokensPerDay) ?? Self.defaultTokensPerDay
        requestsPerMinute = try c.decodeIfPresent(Int.self, forKey: .requestsPerMinute) ?? Self.defaultRequestsPerMinute
        maxTokensPerRequest =
            try c.decodeIfPresent(Int.self, forKey: .maxTokensPerRequest) ?? Self.defaultMaxTokensPerRequest
        privacyAcknowledged = try c.decodeIfPresent(Bool.self, forKey: .privacyAcknowledged) ?? false
    }

    /// Policy suffixes of the router (`<model>:<policy>`); no suffix means `:fastest`.
    public static let policySuffixes: Set<String> = ["fastest", "cheapest", "preferred"]

    /// True for an id in `allowedModels`, or one of them followed by `:fastest`, `:cheapest`,
    /// `:preferred` or `:<provider>` (provider `[a-z0-9-]{1,40}`). Nothing else: no other
    /// characters, no second suffix, no case folding.
    public func isAllowed(model: String) -> Bool {
        if allowedModels.contains(model) { return true }
        guard let colon = model.lastIndex(of: ":") else { return false }
        let base = String(model[..<colon])
        let suffix = model[model.index(after: colon)...]
        guard !base.isEmpty, allowedModels.contains(base) else { return false }
        if Self.policySuffixes.contains(String(suffix)) { return true }
        return Self.isProviderName(suffix)
    }

    /// `[a-z0-9-]{1,40}`.
    static func isProviderName(_ name: Substring) -> Bool {
        (1...40).contains(name.utf8.count)
            && name.utf8.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2D }
    }
}
