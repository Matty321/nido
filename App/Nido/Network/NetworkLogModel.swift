// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore
import Observation

/// The Network view of a VM window: the connection log (`EgressLog`, both files) newest first, with
/// "Allow" on the blocks that name a domain, and what the network of the VM is. Read off the
/// main actor every few seconds while shown (`watch`).
@MainActor
@Observable
final class NetworkLogModel {
    struct Row: Identifiable, Equatable {
        /// From the line's content (time, protocol, destination, outcome, and which of identical
        /// lines it is, counted from the oldest), never its position: a row keeps its identity
        /// when new lines arrive or the log rotates.
        let id: String
        let time: String
        let outcome: String
        let proto: String
        let destination: String
        let detail: String
        let isBlock: Bool
        let allowDomain: String?
    }

    enum Network: Equatable {
        case unknown
        /// Apple's NAT (`controlledNetwork` off).
        case nat
        case controlled(domains: Int)
        /// Controlled, but its `gvproxy` is gone while the VM runs: no network until a restart
        /// (`VMControl.isControlledNetworkInterrupted`).
        case interrupted(domains: Int)
        /// `egress.json` does not load.
        case malformed
    }

    let name: String
    private(set) var rows: [Row] = []
    /// Lines of local noise (IPv6 multicast and link-local, broadcast) left out of `rows`, among
    /// those the filter would show: said under the log, so nothing is hidden without a word.
    private(set) var hiddenNoise = 0
    private(set) var network = Network.unknown
    /// Only blocks, cuts and summaries (the default: what a person looks for).
    var blockedOnly = true {
        didSet { if blockedOnly != oldValue { rebuild() } }
    }
    /// The outcome of the last "Allow".
    private(set) var message: String?
    private(set) var messageIsError = false
    private(set) var isAllowing = false

    static let maxRows = 500

    @ObservationIgnored private let bundle: VMBundle
    @ObservationIgnored private let authenticator: any OwnerAuthenticator
    @ObservationIgnored private let readEntries: @Sendable (VMBundle) -> [EgressLogEntry]
    @ObservationIgnored private let networkLost: @Sendable (VMBundle) -> Bool
    @ObservationIgnored private var entries: [EgressLogEntry] = []
    @ObservationIgnored private let timeZone: TimeZone
    /// Counts the reads started: a read that ends after a newer one started is dropped, so a slow
    /// read never puts back an older log (the watch loop and "Allow" both refresh).
    @ObservationIgnored private var refreshGeneration = 0

    init(
        name: VMName, paths: NidoPaths, authenticator: any OwnerAuthenticator,
        readEntries: @escaping @Sendable (VMBundle) -> [EgressLogEntry] = { EgressLog.readEntries(bundle: $0) },
        networkLost: @escaping @Sendable (VMBundle) -> Bool = { VMControl.isControlledNetworkInterrupted(bundle: $0) },
        timeZone: TimeZone = .current
    ) {
        self.name = name.rawValue
        bundle = VMBundle(url: paths.bundleURL(for: name))
        self.authenticator = authenticator
        self.readEntries = readEntries
        self.networkLost = networkLost
        self.timeZone = timeZone
    }

    /// Reads the log, the list and the config again.
    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        let bundle = bundle
        let readEntries = readEntries
        let networkLost = networkLost
        let (entries, network) = await Task.detached { () -> ([EgressLogEntry], Network) in
            let entries = readEntries(bundle)
            guard let config = try? bundle.readConfig() else { return (entries, .unknown) }
            guard config.controlledNetwork == true else { return (entries, .nat) }
            guard let policy = EgressPolicyStore.load(bundle: bundle) else { return (entries, .malformed) }
            if networkLost(bundle) { return (entries, .interrupted(domains: policy.allow.count)) }
            return (entries, .controlled(domains: policy.allow.count))
        }.value
        guard generation == refreshGeneration else { return }
        if network != self.network { self.network = network }
        if entries != self.entries {
            self.entries = entries
            rebuild()
        }
    }

    /// Refreshes every `interval` until the task is cancelled (the view goes away).
    func watch(interval: Duration = .seconds(2), onRefresh: @escaping () -> Void = {}) async {
        while !Task.isCancelled {
            await refresh()
            onRefresh()
            try? await Task.sleep(for: interval)
        }
    }

    var networkSummary: String {
        switch network {
        case .unknown: String(localized: "The VM’s configuration can’t be read.")
        case .nat:
            String(localized: "Apple network (NAT): the VM connects to the internet unchecked and no connection is logged. You can turn on the controlled network in the settings, with the VM stopped.")
        case .controlled(let count):
            String(localized: "Controlled network: \(count) allowed domains. Everything else is blocked and logged here, without the traffic’s content.")
        case .interrupted:
            String(localized: "gvproxy isn’t running anymore: the VM has no network and nothing gets out by any other route. Stop and start the VM again to restore the network.")
        case .malformed:
            String(localized: "egress.json isn’t valid or isn’t safe: the running VM stays on the last valid list, and at the next start it has no network. Reset to the base list from the settings (Network) or with nido net reset \(name).",
                   comment: "%@ is the VM’s name.")
        }
    }

    var emptyText: String {
        blockedOnly ? String(localized: "No blocks logged.") : String(localized: "No connections logged.")
    }

    /// The line under the log while local noise is hidden (as `nido net log` says it).
    var hiddenNoiseText: String? {
        guard hiddenNoise > 0 else { return nil }
        return String(localized: "\(hiddenNoise) local-noise blocks hidden: IPv6 multicast and link-local, broadcast. They don’t leave the VM; to see them: nido net log \(name) --all.",
                      comment: "A count, then the VM’s name.")
    }

    private func rebuild() {
        let formatter = Self.timeFormatter(timeZone: timeZone)
        let ids = Self.rowIDs(entries)
        var out: [Row] = []
        var noise = 0
        for (index, entry) in entries.enumerated().reversed() {
            if blockedOnly, !entry.verdict.isBlock { continue }
            // Local noise (IPv6 multicast, broadcast) stays in egress.log: `nido net log --all`.
            if entry.isLocalNoise {
                noise += 1
                continue
            }
            guard out.count < Self.maxRows else { continue }
            out.append(Self.row(entry, id: ids[index], time: formatter.string(from: entry.time)))
        }
        rows = out
        if noise != hiddenNoise { hiddenNoise = noise }
    }

    /// The id of each line (see `Row.id`), in the order of `entries` (oldest first).
    static func rowIDs(_ entries: [EgressLogEntry]) -> [String] {
        var seen: [String: Int] = [:]
        return entries.map { entry in
            let destination = entry.verdict == .suppressed || entry.verdict == .uplinkLost
                ? "-" : EgressNoticeText.destination(entry)
            let key = "\(entry.time.timeIntervalSince1970)|\(entry.proto.rawValue)|\(destination)|\(entry.verdict.rawValue)"
            let occurrence = seen[key, default: 0]
            seen[key] = occurrence + 1
            return "\(key)#\(occurrence)"
        }
    }

    /// The time column's format: day, month and time in the order and with the separators of the
    /// app's language.
    static func timeFormatter(timeZone: TimeZone = .current) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("ddMMjjmmss")
        return formatter
    }

    /// Times as wide as any the log can show (two-digit day, month and hour, morning and
    /// afternoon), so the time column keeps one width whatever the rows' times.
    static let timeSamples: [String] = {
        // 27 Dec 2026, 23:59:58 and 11:59:58 UTC.
        let formatter = timeFormatter(timeZone: TimeZone(identifier: "UTC") ?? .current)
        return Set([Date(timeIntervalSince1970: 1_798_415_998), Date(timeIntervalSince1970: 1_798_372_798)]
            .map(formatter.string(from:))).sorted()
    }()

    static func row(_ entry: EgressLogEntry, id: String, time: String) -> Row {
        let detail: String
        switch entry.verdict {
        case .suppressed:
            // Counts joined by commas: "3 blocks, 5 flows, 2 local packets".
            var counts = [
                String(localized: "\(entry.lostBlocks ?? 0) blocks", comment: "A count in a list joined by commas."),
                String(localized: "\(entry.lostFlows ?? 0) flows", comment: "A count in a list joined by commas."),
            ]
            if let noise = entry.lostNoise {
                counts.append(String(localized: "\(noise) local packets", comment: "A count in a list joined by commas."))
            }
            detail = String(localized: "not logged one by one: \(counts.joined(separator: ", "))",
                            comment: "%@ lists counts of blocks, flows and packets.")
        case .uplinkLost:
            detail = EgressEvent.uplinkLostMessage(reason: EgressNoticeText.uplinkLostReason(entry))
        case .allowed, .open, .cut:
            let traffic = String(localized: "sent \(ByteSize.text(entry.bytesOut)), received \(ByteSize.text(entry.bytesIn))",
                                 comment: "Bytes a connection sent and received: two sizes.")
            let flows = entry.count ?? 1
            detail = flows > 1
                ? [String(localized: "\(flows) flows", comment: "A count in a list joined by commas."), traffic].joined(separator: ", ")
                : traffic
        default:
            let reason = EgressNoticeText.reason(entry.verdict)
            let repeats = entry.repeats ?? 0
            detail = repeats > 0
                ? String(localized: "\(reason) (and \(repeats) more times before)", comment: "Why it was blocked, then a count.")
                : reason
        }
        return Row(
            id: id, time: time, outcome: EgressNoticeText.outcome(entry.verdict), proto: entry.proto.rawValue,
            destination: entry.verdict == .suppressed || entry.verdict == .uplinkLost
                ? "-" : EgressNoticeText.destination(entry), detail: detail,
            isBlock: entry.verdict.isBlock, allowDomain: EgressNoticeText.allowDomain(for: entry))
    }

    /// "Allow" on a row: the owner confirms, then `egress.json` changes.
    func allow(_ domain: String) async {
        guard !isAllowing else { return }
        isAllowing = true
        defer { isAllowing = false }
        let outcome = await EgressPolicyEdits.allow(domain, vm: name, bundle: bundle, authenticator: authenticator)
        message = EgressMonitor.allowMessage(outcome, vm: name) + "."
        switch outcome {
        case .added, .alreadyListed: messageIsError = false
        default: messageIsError = true
        }
        await refresh()
    }

    func dismissMessage() { message = nil }
}
