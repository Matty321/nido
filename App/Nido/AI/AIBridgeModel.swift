// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore
import Observation

/// The remote AI bridge of one VM (spec H), owned by its `VMWindowModel`: the VM's policy
/// (`VMConfig.aiBridge`), the Mac's Hugging Face token as present or absent only, the router's
/// catalog to choose the allowed models from, today's usage and the last calls of the log.
///
/// A change is written to the VM's config with `VMBundle.updateConfig` (also while the VM runs):
/// the session's `AIBridgeHost` reads the policy from the config at every request, so it applies
/// to the next one without restarting anything. The first activation for a VM shows the privacy
/// notice (`isShowingPrivacyNotice`); only its acknowledgement turns the bridge on and is
/// recorded (`privacyAcknowledged`).
///
/// The token's value never stays here: `saveToken` hands it to the `TokenStore` (Keychain) and
/// keeps only `hasToken`. Every file and Keychain access runs off the main actor.
@MainActor
@Observable
final class AIBridgeModel {
    /// What the guest's agents set to use the bridge (any API key works: the token stays on the Mac).
    nonisolated static let guestBaseURL = "http://127.0.0.1:11435/v1"
    /// Calls shown under "Recent calls".
    nonisolated static let recentCallsLimit = 50
    nonisolated static let tokensPerDayRange = 1...100_000_000
    nonisolated static let requestsPerMinuteRange = 1...1_000
    nonisolated static let maxTokensPerRequestRange = 1...1_000_000

    nonisolated static var privacyNotice: String {
        String(localized: "With the bridge on, the text that programs in the VM send to the bridge leaves the Mac and reaches Hugging Face and the provider that serves the model, with your token. Nido doesn’t log prompts or answers, only the model, the tokens used and the outcome. Local mode (Ollama in the VM) is always available.")
    }

    /// The privacy sheet's title (S15 "privacy notice").
    nonisolated static func privacyTitle(vmName: String) -> String {
        String(localized: "Turn on the AI bridge for \(vmName)?", comment: "%@ is the VM’s name.")
    }

    /// The numbers are grouped with spaces, as the limit fields show them (`grouped`).
    nonisolated static var privacyLimits: String {
        String(localized: "Default limits, which you can change: 200 000 tokens per day, 20 requests per minute, max_tokens 4 096.",
               comment: "The numbers are grouped with spaces in every language, as the limit fields show them.")
    }

    /// The Remoto column of a VM started with `nido start` (as the Monitor's R19): the bridge
    /// lives in the app's session only.
    nonisolated static func elsewhereNotice(vmName: String) -> String {
        String(localized: "The AI bridge works only for VMs started by Nido: \(vmName) was started from Terminal (nido start).",
               comment: "%@ is the VM’s name.")
    }

    /// A limit as typed ("200 000", "4.096"): digits with spaces, dots or apostrophes between
    /// them; nil for anything else or a number too large.
    nonisolated static func parseLimit(_ text: String) -> Int? {
        let digits = text.filter { !$0.isWhitespace && $0 != "." && $0 != "'" && $0 != "\u{202F}" }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }

    /// "200 000": thousands separated by a space, as in the design.
    nonisolated static func grouped(_ value: Int) -> String {
        let digits = Array(String(abs(value)))
        var out = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { out.append(" ") }
            out.append(digit)
        }
        return (value < 0 ? "-" : "") + out
    }

    /// The outcome of a logged call, in words.
    nonisolated static func outcome(_ status: Int) -> String {
        switch status {
        case 200..<300: String(localized: "Succeeded", comment: "The outcome of an AI bridge call, in a log column.")
        case 429: String(localized: "Over the limit", comment: "The outcome of an AI bridge call, in a log column.")
        case 401: String(localized: "Token rejected", comment: "The outcome of an AI bridge call, in a log column.")
        case 403: String(localized: "Not allowed", comment: "The outcome of an AI bridge call, in a log column.")
        default: String(localized: "Error \(status)", comment: "The outcome of an AI bridge call: an HTTP status. [not a count]")
        }
    }

    /// A catalog model's providers, context and prices: "nebius, novita · context 131 072 ·
    /// $0.02 / $0.06" (the first provider that gives each value; prices informative only).
    nonisolated static func catalogDetail(_ model: CatalogModel) -> String {
        var parts = [model.providers.map(\.provider).joined(separator: ", ")].filter { !$0.isEmpty }
        if let context = model.providers.compactMap(\.contextLength).first {
            parts.append(String(localized: "context \(grouped(context))",
                                comment: "%@ is a model’s context length in tokens (131 072), one of the facts joined by ·."))
        }
        if let priced = model.providers.first(where: { $0.inputPrice != nil && $0.outputPrice != nil }),
           let input = priced.inputPrice, let output = priced.outputPrice {
            parts.append(String(localized: "$\(price(input)) / $\(price(output))",
                                comment: "Input and output price in US dollars per million tokens."))
        } else {
            parts.append(String(localized: "price not given", comment: "One of the facts joined by ·."))
        }
        return parts.joined(separator: " · ")
    }

    private nonisolated static func price(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2...4)).locale(.current).grouping(.never))
    }

    /// "1.9 s" ("1,9 s" in Italian): `s` is the SI symbol, the same in every language.
    nonisolated static func durationText(_ milliseconds: Int) -> String {
        (Double(max(0, milliseconds)) / 1000).formatted(
            .number.precision(.fractionLength(1)).locale(.current).grouping(.never)) + " s"
    }

    /// The VM's policy as last read or written (defaults while the config has none).
    private(set) var policy = AIBridgePolicy()
    private(set) var isLoaded = false
    /// The Mac has a Hugging Face token; nil while unknown (not read yet, or the Keychain failed).
    private(set) var hasToken: Bool?
    private(set) var tokenError: String?
    /// The first activation for this VM waits for the user to read the notice.
    private(set) var isShowingPrivacyNotice = false
    private(set) var catalogModels: [CatalogModel] = []
    private(set) var catalogError: String?
    private(set) var isLoadingCatalog = false
    /// Tokens charged today (from the limiter, i.e. `ai-bridge-usage.json`).
    private(set) var tokensUsedToday = 0
    /// The last calls of `ai-bridge.log`, newest first.
    private(set) var recentCalls: [AIBridgeLogEntry] = []
    /// The policy could not be written (localized).
    private(set) var saveError: String?
    /// The limits typed are out of range (localized); nothing was written.
    private(set) var limitsError: String?
    /// A session of this VM runs in this app.
    private(set) var sessionRunning = false
    /// Whether that session got its bridge (nil: a session kind without one, e.g. DEBUG fakes).
    private(set) var bridgeAttached: Bool?

    @ObservationIgnored private let openBundle: @Sendable () throws -> VMBundle
    @ObservationIgnored private let tokenStore: (any TokenStore)?
    @ObservationIgnored private let catalog: ModelCatalog?
    @ObservationIgnored private let limiter: (@MainActor (VMBundle) -> AIBridgeLimiter?)?

    /// `limiter`: the app's limiter of the VM if a session made it already
    /// (`AIBridgeServices.existingLimiter(for:)`), whose count is the one the bridge enforces;
    /// otherwise `ai-bridge-usage.json` is read with a fresh limiter off the main actor.
    init(
        openBundle: @escaping @Sendable () throws -> VMBundle, tokenStore: (any TokenStore)?,
        catalog: ModelCatalog?, limiter: (@MainActor (VMBundle) -> AIBridgeLimiter?)?
    ) {
        self.openBundle = openBundle
        self.tokenStore = tokenStore
        self.catalog = catalog
        self.limiter = limiter
    }

    convenience init(name: VMName, paths: NidoPaths, services: AIBridgeServices?) {
        var limiter: (@MainActor (VMBundle) -> AIBridgeLimiter?)?
        if let services {
            // Never creates one here: creating reads the usage file (main actor).
            limiter = { bundle in services.existingLimiter(for: bundle) }
        }
        self.init(
            openBundle: { try VMBundle.open(name, paths: paths) }, tokenStore: services?.tokenStore,
            catalog: services?.catalog, limiter: limiter)
    }

    // MARK: - State for the views

    /// "AI bridge active" in the window and the library: the VM runs here with its bridge, switched on.
    var isActive: Bool { sessionRunning && bridgeAttached == true && policy.enabled }

    /// The bridge is on for this VM but its session could not attach it: the guest's calls fail
    /// until the next start. The cause is not known here (the session factory keeps it).
    var attachWarning: String? {
        guard sessionRunning, bridgeAttached == false, policy.enabled else { return nil }
        return String(localized: "The AI bridge isn’t available in this session: the VM’s requests don’t reach Hugging Face. Restart the VM to try again.")
    }

    /// Why the bridge, though on, cannot answer: the Mac has no token.
    var notice: String? {
        guard policy.enabled, hasToken == false else { return nil }
        return String(localized: "The Hugging Face token is missing: add it in Nido Settings. Until then, the VM’s requests get a 401 error and nothing leaves the Mac.")
    }

    // MARK: - Session (from the window)

    func sessionStarted(bridgeAttached: Bool?) {
        sessionRunning = true
        self.bridgeAttached = bridgeAttached
    }

    func sessionEnded() {
        sessionRunning = false
        bridgeAttached = nil
    }

    // MARK: - Loading

    private struct Snapshot: Sendable {
        var policy: AIBridgePolicy?
        var hasToken: Bool?
        var calls: [AIBridgeLogEntry]
        var bundle: VMBundle?
    }

    /// Reads the policy, whether the token exists, today's usage and the last calls.
    func load() async {
        let openBundle = openBundle
        let tokenStore = tokenStore
        let snapshot = await Task.detached { () -> Snapshot in
            let bundle = try? openBundle()
            var hasToken: Bool?
            if let tokenStore {
                do { hasToken = try tokenStore.read() != nil } catch { hasToken = nil }
            }
            return Snapshot(
                policy: (try? bundle?.readConfig())?.aiBridge ?? AIBridgePolicy(), hasToken: hasToken,
                calls: bundle.map { Self.recent(in: $0) } ?? [], bundle: bundle)
        }.value
        policy = snapshot.policy ?? AIBridgePolicy()
        hasToken = snapshot.hasToken
        recentCalls = snapshot.calls
        if let bundle = snapshot.bundle { tokensUsedToday = await usage(of: bundle) }
        isLoaded = true
    }

    /// Only the VM's policy (for "AI bridge active" when a session starts): no Keychain access.
    func reloadPolicy() async {
        let openBundle = openBundle
        policy = await Task.detached { (try? openBundle().readConfig())?.aiBridge }.value ?? AIBridgePolicy()
    }

    /// Usage and last calls again (the view refreshes them while shown).
    func refreshUsage() async {
        let openBundle = openBundle
        guard let bundle = await Task.detached(operation: { try? openBundle() }).value else { return }
        recentCalls = await Task.detached { Self.recent(in: bundle) }.value
        tokensUsedToday = await usage(of: bundle)
    }

    private nonisolated static func recent(in bundle: VMBundle) -> [AIBridgeLogEntry] {
        Array(AIBridgeLog.readEntries(at: bundle.aiBridgeLogURL).suffix(recentCallsLimit).reversed())
    }

    private func usage(of bundle: VMBundle) async -> Int {
        if let existing = limiter?(bundle) {
            return await existing.tokensUsedToday()
        }
        // The limiter reads `ai-bridge-usage.json` when created (counting only today's day).
        return await Task.detached { await AIBridgeLimiter(usageURL: bundle.aiBridgeUsageURL).tokensUsedToday() }.value
    }

    /// The router's catalog (cached for an hour by `ModelCatalog`).
    func loadCatalog(forceRefresh: Bool = false) async {
        guard let catalog, !isLoadingCatalog else { return }
        isLoadingCatalog = true
        defer { isLoadingCatalog = false }
        do {
            catalogModels = try await catalog.models(forceRefresh: forceRefresh)
            catalogError = nil
        } catch {
            catalogError = Self.catalogMessage(for: error)
        }
    }

    nonisolated static func catalogMessage(for error: any Error) -> String {
        switch error as? ModelCatalogError {
        case .httpStatus(401), .httpStatus(403):
            String(localized: "Hugging Face rejected the token: check it in Nido Settings.")
        case .httpStatus(let code):
            String(localized: "The model catalog isn’t available (Hugging Face answered \(code)): try again later.",
                   comment: "%lld is an HTTP status. [not a count]")
        case .invalidResponse, .responseTooLarge:
            String(localized: "The model catalog Hugging Face sent isn’t valid: try again later.")
        case nil:
            String(localized: "The model catalog can’t be reached: check the Mac’s connection and try again.")
        }
    }

    // MARK: - Policy

    /// "Turn On the Bridge…": the first time for this VM the privacy notice is shown instead, and nothing is
    /// written until it is acknowledged.
    func setEnabled(_ enabled: Bool) async {
        if enabled, !policy.privacyAcknowledged {
            isShowingPrivacyNotice = true
            return
        }
        // The acknowledgement is checked again in the config being written (it may have changed
        // since it was read): without it the bridge stays off and the notice is shown.
        await update { policy in
            if !enabled || policy.privacyAcknowledged { policy.enabled = enabled }
        }
        if enabled, !policy.enabled, !policy.privacyAcknowledged { isShowingPrivacyNotice = true }
    }

    /// The notice was read and accepted: recorded for this VM, and the bridge goes on.
    func acknowledgePrivacy() async {
        guard isShowingPrivacyNotice else { return }
        isShowingPrivacyNotice = false
        await update {
            $0.privacyAcknowledged = true
            $0.enabled = true
        }
    }

    func declinePrivacyNotice() {
        isShowingPrivacyNotice = false
    }

    /// Allows or disallows a model; only ids of the loaded catalog can be allowed.
    func setAllowed(_ id: String, _ allowed: Bool) async {
        if allowed {
            guard catalogModels.contains(where: { $0.id == id }), !policy.allowedModels.contains(id) else { return }
            await update { if !$0.allowedModels.contains(id) { $0.allowedModels.append(id) } }
        } else {
            guard policy.allowedModels.contains(id) else { return }
            await update { $0.allowedModels.removeAll { $0 == id } }
        }
    }

    /// The three limits; out of range → `limitsError` and nothing written.
    func setLimits(tokensPerDay: Int, requestsPerMinute: Int, maxTokensPerRequest: Int) async {
        guard Self.tokensPerDayRange.contains(tokensPerDay) else {
            limitsError = String(localized: "Tokens per day must be between 1 and 100 000 000.",
                                 comment: "The number is grouped with spaces, as the limit fields show it.")
            return
        }
        guard Self.requestsPerMinuteRange.contains(requestsPerMinute) else {
            limitsError = String(localized: "Requests per minute must be between 1 and 1 000.",
                                 comment: "The number is grouped with spaces, as the limit fields show it.")
            return
        }
        guard Self.maxTokensPerRequestRange.contains(maxTokensPerRequest) else {
            limitsError = String(localized: "The maximum tokens per request must be between 1 and 1 000 000.",
                                 comment: "The number is grouped with spaces, as the limit fields show it.")
            return
        }
        limitsError = nil
        await update {
            $0.tokensPerDay = tokensPerDay
            $0.requestsPerMinute = requestsPerMinute
            $0.maxTokensPerRequest = maxTokensPerRequest
        }
    }

    /// Edits the policy in the VM's config (fresh read, single write) and keeps what was written.
    private func update(_ edit: @escaping @Sendable (inout AIBridgePolicy) -> Void) async {
        let openBundle = openBundle
        let result = await Task.detached { () -> Result<AIBridgePolicy, any Error> in
            do {
                let config = try openBundle().updateConfig { config in
                    var policy = config.aiBridge ?? AIBridgePolicy()
                    edit(&policy)
                    config.aiBridge = policy
                }
                return .success(config.aiBridge ?? AIBridgePolicy())
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success(let written):
            policy = written
            saveError = nil
        case .failure(let error):
            saveError = String(localized: "Couldn’t save the bridge settings: \(error.localizedDescription)",
                               comment: "%@ is the error’s description.")
        }
    }

    // MARK: - Token (the Mac's, shared by every VM)

    /// Stores the token typed by the user in the Keychain; the text is not kept. False when it is
    /// not a valid token or the Keychain refused it (`tokenError`).
    @discardableResult
    func saveToken(_ text: String) async -> Bool {
        guard let tokenStore else { return false }
        guard let token = HFToken(text) else {
            tokenError = String(localized: "The token isn’t valid: paste it without spaces or special characters inside.")
            return false
        }
        let failed = await Task.detached { () -> Bool in
            do {
                try tokenStore.save(token)
                return false
            } catch {
                return true
            }
        }.value
        if failed {
            tokenError = String(localized: "The Keychain didn’t save the token: try again.")
            return false
        }
        tokenError = nil
        hasToken = true
        return true
    }

    func removeToken() async {
        guard let tokenStore else { return }
        let failed = await Task.detached { () -> Bool in
            do {
                try tokenStore.delete()
                return false
            } catch {
                return true
            }
        }.value
        if failed {
            tokenError = String(localized: "The Keychain didn’t remove the token: try again.")
        } else {
            tokenError = nil
            hasToken = false
        }
    }
}
