// SPDX-License-Identifier: Apache-2.0
import Foundation

/// One provider serving a catalog model. Only `provider` is required; the router does not always
/// send the rest.
public struct CatalogProvider: Codable, Sendable, Equatable {
    public var provider: String
    /// e.g. `live`, `staging`.
    public var status: String?
    public var contextLength: Int?
    /// Price per million input tokens (USD), informative only.
    public var inputPrice: Double?
    /// Price per million output tokens (USD), informative only.
    public var outputPrice: Double?
    public var supportsTools: Bool?
}

/// A model of the router's catalog.
public struct CatalogModel: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var ownedBy: String?
    public var providers: [CatalogProvider]
}

public enum ModelCatalogError: Error, Equatable, Sendable {
    /// The router answered with this status.
    case httpStatus(Int)
    /// Not `{"data": [...]}`.
    case invalidResponse
    /// Larger than `ModelCatalog.maxResponseBytes`.
    case responseTooLarge
}

/// The router's `GET /v1/models`, asked from the Mac (with the token when there is one) and kept
/// in memory for an hour (a failure for a minute; concurrent misses share one request). Parsing is tolerant: entries without a string `id` (or providers
/// without a string `provider`) are skipped, other missing or mistyped fields are nil.
public actor ModelCatalog {
    public static let cacheLifetime: TimeInterval = 3600
    /// A failed fetch is remembered this long: callers get the same error without a new request.
    public static let failureLifetime: TimeInterval = 60
    public static let maxResponseBytes = 16 << 20

    private let router: any RouterClient
    private let tokenStore: (any TokenStore)?
    private let now: @Sendable () -> Date
    private var cached: (models: [CatalogModel], at: Date)?
    private var failed: (error: any Error, at: Date)?
    private var inFlight: Task<[CatalogModel], any Error>?

    public init(router: any RouterClient, tokenStore: (any TokenStore)?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.router = router
        self.tokenStore = tokenStore
        self.now = now
    }

    /// The catalog, from the cache when younger than an hour; a failure younger than a minute is
    /// thrown again without asking (both unless `forceRefresh`). Concurrent callers share one
    /// request to the router.
    public func models(forceRefresh: Bool = false) async throws -> [CatalogModel] {
        let current = now()
        if !forceRefresh {
            if let cached, current >= cached.at, current.timeIntervalSince(cached.at) < Self.cacheLifetime {
                return cached.models
            }
            if let failed, current >= failed.at, current.timeIntervalSince(failed.at) < Self.failureLifetime {
                throw failed.error
            }
        }
        if let inFlight { return try await inFlight.value }
        let router = router
        let tokenStore = tokenStore
        let task = Task { try await Self.fetch(router: router, tokenStore: tokenStore) }
        inFlight = task
        do {
            let models = try await task.value
            inFlight = nil
            cached = (models, current)
            failed = nil
            return models
        } catch {
            inFlight = nil
            failed = (error, now())
            throw error
        }
    }

    private static func fetch(router: any RouterClient, tokenStore: (any TokenStore)?) async throws -> [CatalogModel] {
        // A Keychain failure only means asking without the token.
        let token = (try? tokenStore?.read()) ?? nil
        let response = try await router.send(.models, body: nil, accept: "application/json", token: token)
        guard response.status == 200 else { throw ModelCatalogError.httpStatus(response.status) }
        var data = Data()
        for try await chunk in response.body {
            data.append(chunk)
            if data.count > maxResponseBytes { throw ModelCatalogError.responseTooLarge }
        }
        return try parse(data)
    }

    /// Not strict UTF-8 (or with BOM/NUL) or nested deeper than `JSONDepth.limit` is
    /// `invalidResponse` (checked before parsing).
    public static func parse(_ data: Data) throws(ModelCatalogError) -> [CatalogModel] {
        guard JSONDepth.isSafe(data), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let list = root["data"] as? [Any]
        else { throw .invalidResponse }
        return list.compactMap { item -> CatalogModel? in
            guard let object = item as? [String: Any], let id = object["id"] as? String, !id.isEmpty else { return nil }
            let providers = (object["providers"] as? [Any] ?? []).compactMap { entry -> CatalogProvider? in
                guard let p = entry as? [String: Any], let name = p["provider"] as? String, !name.isEmpty else {
                    return nil
                }
                let pricing = p["pricing"] as? [String: Any]
                return CatalogProvider(
                    provider: name, status: p["status"] as? String, contextLength: integer(p["context_length"]),
                    inputPrice: number(pricing?["input"]), outputPrice: number(pricing?["output"]),
                    supportsTools: boolean(p["supports_tools"]))
            }
            return CatalogModel(id: id, ownedBy: object["owned_by"] as? String, providers: providers)
        }
    }

    /// The OpenAI-style list the guest gets: the allowed ids (policy order, no duplicates) that
    /// are in `catalog`, or all of them when the catalog is unavailable (nil).
    static func guestList(catalog: [CatalogModel]?, allowed: [String]) -> Data {
        var seen = Set<String>()
        let byID = Dictionary((catalog ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var data: [[String: Any]] = []
        for id in allowed where seen.insert(id).inserted {
            let model = byID[id]
            if catalog != nil, model == nil { continue }
            let owner = model?.ownedBy ?? id.split(separator: "/").first.map(String.init) ?? "huggingface"
            data.append(["id": id, "object": "model", "created": 0, "owned_by": owner])
        }
        let object: [String: Any] = ["object": "list", "data": data]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data(#"{"data":[],"object":"list"}"#.utf8)
    }

    // MARK: - Tolerant values

    private static func isBool(_ n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }

    private static func integer(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, !isBool(n) else { return nil }
        let d = n.doubleValue
        guard d.isFinite, d.rounded() == d, abs(d) < 1e15 else { return nil }
        return Int(d)
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber, !isBool(n), n.doubleValue.isFinite { return n.doubleValue }
        if let s = value as? String, let d = Double(s), d.isFinite { return d }
        return nil
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let n = value as? NSNumber, isBool(n) else { return nil }
        return n.boolValue
    }
}
