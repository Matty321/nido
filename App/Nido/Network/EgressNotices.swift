// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore

/// One block of a VM's controlled network as the app tells it: a notification, a row of the VM's
/// log, a line of the counter. Every text taken from the log is echoed without controls, bidi or
/// line separators (`ConsoleSanitizer.echoable`).
struct EgressBlockNotice: Equatable, Sendable {
    let vm: String
    /// The domain, else the address, with the port; "-" when the frame had neither.
    let destination: String
    let reason: String
    /// The exact pattern "Allow" adds: only when the block names a host name (refused or
    /// learned name, or the alias the guest asked for), never for a bare address.
    let allowDomain: String?
    /// Blocks this notice stands for (repeats and merged ones included).
    var count: Int
    /// Notices of the same VM, destination and port replace each other.
    let key: String
    /// What the notice is about when it is not a block (the title after the VM's name).
    var subject = String(localized: "blocked connection", comment: "A notification’s title, after the VM’s name.")
    /// The whole body, for a notice that is not about a destination (the loss of the uplink).
    var message: String?

    var title: String {
        String(localized: "\(vm): \(subject)", comment: "A notification’s title: the VM’s name, then what happened.")
    }

    var body: String {
        if let message { return message }
        let block = count > 1
            ? String(localized: "\(destination) (\(count) times): \(reason).",
                     comment: "A block notice: the destination, how many times, why it was blocked.")
            : String(localized: "\(destination): \(reason).", comment: "A block notice: the destination, why it was blocked.")
        guard let allowDomain else { return block }
        let allow = String(localized: "Allow adds exactly \(allowDomain) to the allowed domains.",
                           comment: "Allow is the notification’s button; %@ is a domain.")
        return block + " " + allow
    }
}

/// Texts of the egress log for people (localized), shared by notifications, the VM's log view and
/// its settings.
enum EgressNoticeText {
    /// Whether a log line is notified (and counted while notifications are off). Every block is,
    /// except:
    /// - a cut: the person removed that domain (from the app or `nido net deny`) and was told;
    /// - a summary (`summaryNotice` tells those);
    /// - the loss of the uplink (`uplinkLostNotice` tells it, outside the batching);
    /// - boot noise without a domain (ruling): multicast or broadcast, IPv6 without an address or
    ///   to a multicast (`ff00::/8`) or link-local (`fe80::/10`) one, a malformed frame without an
    ///   address (`EgressLogEntry.isLocalNoise`). They stay in the VM's log.
    static func isNotified(_ entry: EgressLogEntry) -> Bool {
        let verdict = entry.verdict
        guard verdict.isBlock, verdict != .cut, verdict != .suppressed, verdict != .uplinkLost else { return false }
        return !entry.isLocalNoise
    }

    /// The notice of a block line of `vm`'s log; nil for any other line.
    static func notice(for entry: EgressLogEntry, vm: String) -> EgressBlockNotice? {
        guard isNotified(entry) else { return nil }
        let destination = self.destination(entry)
        return EgressBlockNotice(
            vm: ConsoleSanitizer.echoable(vm), destination: destination, reason: reason(entry.verdict),
            allowDomain: allowDomain(for: entry), count: 1 + max(0, entry.repeats ?? 0),
            key: "\(vm)|\(destination)")
    }

    /// The notice of a summary line (`suppressed`): blocks the relay counted but did not report
    /// one by one. Nil when it left out only flow lines.
    static func summaryNotice(for entry: EgressLogEntry, vm: String) -> EgressBlockNotice? {
        guard entry.verdict == .suppressed, let lost = entry.lostBlocks, lost > 0 else { return nil }
        return EgressBlockNotice(
            vm: ConsoleSanitizer.echoable(vm), destination: String(localized: "other blocks", comment: "Stands for a destination in a notice."),
            reason: String(localized: "the relay counted \(lost) without reporting them one by one: they’re in the log as a summary",
                           comment: "Why a notice stands for many blocks; it follows a colon."),
            allowDomain: nil, count: lost, key: "\(vm)|riepilogo")
    }

    /// The notice of the line that says the relay lost gvproxy: posted at once, never merged
    /// with blocks. Nil for any other line.
    static func uplinkLostNotice(for entry: EgressLogEntry, vm: String) -> EgressBlockNotice? {
        guard entry.verdict == .uplinkLost else { return nil }
        let name = ConsoleSanitizer.echoable(vm)
        var notice = EgressBlockNotice(
            vm: name, destination: "-", reason: uplinkLostReason(entry), allowDomain: nil, count: 1,
            key: "\(vm)|rete-interrotta")
        notice.subject = String(localized: "controlled network interrupted", comment: "A notification’s title, after the VM’s name.")
        notice.message = EgressEvent.uplinkLostMessage(reason: uplinkLostReason(entry))
        return notice
    }

    /// The reason recorded with an `uplinkLost` line, in words and echoable: a stable code of
    /// `UplinkLoss` becomes its text in the UI language; the free text of older lines (Italian) is
    /// shown as it is.
    static func uplinkLostReason(_ entry: EgressLogEntry) -> String {
        guard let reason = entry.reason else { return String(localized: "unknown reason") }
        return ConsoleSanitizer.echoable(UplinkLoss.text(reason))
    }

    /// "deb.debian.org:443", "deb.debian.org via debian.map.fastly.net:443", "1.2.3.4:443", "-".
    static func destination(_ entry: EgressLogEntry) -> String {
        let name = entry.domain.map { domain in entry.via.map { "\(domain) via \($0)" } ?? domain }
        let target = name ?? entry.ip
        let port = entry.port.map { ":\($0)" } ?? ""
        guard let target else {
            return port.isEmpty ? "-" : String(localized: "port \(String(port.dropFirst()))", comment: "%@ is a port number.")
        }
        return ConsoleSanitizer.echoable(target + port)
    }

    /// The pattern "Allow" would add for `entry`: the refused name (`name`), the domain an
    /// address was learned for (`denyDomain`) or the alias asked with another type
    /// (`aliasQueryType`, its `via`). Only an exact name that `DomainPattern` accepts: nil for a
    /// bare address, a name with underscores (`_https._tcp…`) or anything else.
    static func allowDomain(for entry: EgressLogEntry) -> String? {
        let candidate: String?
        switch entry.verdict {
        case .name, .denyDomain: candidate = entry.domain
        case .aliasQueryType: candidate = entry.via
        default: candidate = nil
        }
        guard let candidate, let pattern = try? DomainPattern(candidate), !pattern.isWildcard else { return nil }
        let shown = ConsoleSanitizer.echoable(pattern.description)
        return shown == pattern.description ? shown : nil
    }

    static func reason(_ verdict: EgressLogEntry.Verdict) -> String {
        switch verdict {
        case .denyUnknown: String(localized: "address never resolved for an allowed domain", comment: "Why a connection was blocked.")
        case .denyDomain: String(localized: "domain not allowed", comment: "Why a connection was blocked.")
        case .denyProto: String(localized: "only TCP and UDP can go out", comment: "Why a connection was blocked.")
        case .name: String(localized: "name not allowed", comment: "Why a DNS query was blocked.")
        case .invalidName: String(localized: "invalid name", comment: "Why a DNS query was blocked.")
        case .aliasQueryType: String(localized: "for an alias, only A, AAAA, CNAME and HTTPS queries",
                                     comment: "Why a DNS query was blocked.")
        case .dnsBypass: String(localized: "DNS other than Nido’s", comment: "Why a connection was blocked.")
        case .hostSubnet: String(localized: "only DHCP, DNS and SSH can reach the Mac", comment: "Why a connection was blocked.")
        case .broadcast: String(localized: "multicast or broadcast", comment: "Why a packet was blocked.")
        case .ipv6: String(localized: "IPv6 doesn’t go out", comment: "Why a packet was blocked.")
        case .spoofed: String(localized: "source address isn’t the VM’s", comment: "Why a packet was blocked.")
        case .malformed: String(localized: "unrecognized packet", comment: "Why a packet was blocked.")
        case .cut: String(localized: "domain removed from the list: connection cut", comment: "Why a connection was closed.")
        case .suppressed: String(localized: "relay summary", comment: "A log line that sums up blocks.")
        case .uplinkLost: String(localized: "controlled network interrupted: the VM has no network until it next starts")
        case .allowed: String(localized: "allowed", comment: "A connection’s outcome, in the network log.")
        case .open: String(localized: "open", comment: "A connection’s outcome, in the network log.")
        }
    }

    /// The outcome column of the log view.
    static func outcome(_ verdict: EgressLogEntry.Verdict) -> String {
        switch verdict {
        case .allowed: String(localized: "allowed", comment: "A connection’s outcome, in the network log.")
        case .open: String(localized: "open", comment: "A connection’s outcome, in the network log.")
        case .cut: String(localized: "cut", comment: "A connection’s outcome, in the network log: closed because its domain was removed.")
        case .suppressed: String(localized: "summary", comment: "A line’s outcome, in the network log: a summary of the relay.")
        case .uplinkLost: String(localized: "interrupted", comment: "The network log: the controlled network was interrupted.")
        default: String(localized: "blocked", comment: "A connection’s outcome, in the network log.")
        }
    }
}

/// Where the app stopped reading a VM's `egress.log`: the time of the last line read and how
/// many lines with exactly that time it read (the log's times are whole seconds). Lines are
/// appended in order, so the lines after the cursor are the new ones.
struct EgressLogCursor: Codable, Equatable, Sendable {
    var time: Date
    var seen: Int

    /// The lines of `entries` (oldest first, as `EgressLog.readEntries`) after `cursor`, and the
    /// cursor after them. Without a cursor, only lines from the second of `since` on are new (the
    /// app was not watching this VM before; the log's times are whole seconds, so a block of
    /// that very second is not skipped).
    static func newEntries(
        _ entries: [EgressLogEntry], after cursor: EgressLogCursor?, since: Date
    ) -> (entries: [EgressLogEntry], cursor: EgressLogCursor?) {
        let start = cursor ?? EgressLogCursor(
            time: Date(timeIntervalSince1970: floor(since.timeIntervalSince1970)), seen: 0)
        var atStart = 0
        var fresh: [EgressLogEntry] = []
        for entry in entries {
            if entry.time < start.time { continue }
            if entry.time == start.time {
                atStart += 1
                if atStart <= start.seen { continue }
            }
            fresh.append(entry)
        }
        guard let last = entries.last else { return ([], cursor) }
        let seen = entries.reversed().prefix { $0.time == last.time }.count
        // A log that went back in time (rotation lost, clock changed) starts over from its end.
        if last.time < start.time { return ([], EgressLogCursor(time: last.time, seen: seen)) }
        return (fresh, EgressLogCursor(time: last.time, seen: seen))
    }
}

/// Merges notices for a person: per VM, destination and port, at most one notification every
/// `window` seconds; the blocks in between are counted and posted when the window is over
/// (`flush`), so a block never goes without a notice and is never counted twice. A VM gets
/// notices of its own for at most `maxDestinationsPerVM` destinations every `vmWindow` seconds,
/// and at most `maxPerBatch` per batch: the rest go into one merged "other destinations" notice (a destination
/// of its own, merged like the others).
struct EgressNoticeBatcher {
    static let window: TimeInterval = 10
    static let maxPerBatch = 4
    static let maxDestinationsPerVM = 10
    static let vmWindow: TimeInterval = 60
    /// Most destinations remembered; beyond that, every pending count is posted and the table
    /// starts over.
    static let maxKeys = 2048

    private struct Mark {
        var posted: Date
        var pending: EgressBlockNotice?
        /// For the merged "altre" notice: the distinct destinations its pending count covers.
        var destinations: Set<String> = []
    }

    private struct VMWindow {
        var start: Date
        var keys: Set<String> = []
    }

    private var marks: [String: Mark] = [:]
    private var vms: [String: VMWindow] = [:]

    var markCount: Int { marks.count }

    /// The notices to post now for `notices` (a batch of one VM, in log order).
    mutating func add(_ notices: [EgressBlockNotice], now: Date) -> [EgressBlockNotice] {
        var merged: [EgressBlockNotice] = []
        for notice in notices {
            if let index = merged.firstIndex(where: { $0.key == notice.key }) {
                merged[index].count += notice.count
            } else {
                merged.append(notice)
            }
        }
        var out: [EgressBlockNotice] = []
        var others: [String: (notice: EgressBlockNotice, destinations: Set<String>)] = [:]
        var individual = 0
        for notice in merged {
            // Inside its window: counted, posted when the window ends.
            if hold(notice, now: now) { continue }
            var notice = notice
            // Counts held from a window that is over ride on this notice (and leave the mark).
            if let earlier = marks.removeValue(forKey: notice.key)?.pending { notice.count += earlier.count }
            var vm = vms[notice.vm].flatMap { now.timeIntervalSince($0.start) < Self.vmWindow ? $0 : nil }
                ?? VMWindow(start: now)
            let known = vm.keys.contains(notice.key)
            let batchFull = merged.count > Self.maxPerBatch && individual >= Self.maxPerBatch - 1
            if !known && (vm.keys.count >= Self.maxDestinationsPerVM || batchFull) {
                var other = others[notice.vm] ?? (EgressBlockNotice(
                    vm: notice.vm, destination: String(localized: "other destinations", comment: "Stands for a destination in a notice."),
                    reason: String(localized: "the details are in the VM’s log", comment: "It follows a colon."),
                    allowDomain: nil, count: 0,
                    key: "\(notice.vm)|altre"), [])
                other.notice.count += notice.count
                other.destinations.insert(notice.key)
                others[notice.vm] = other
                vms[notice.vm] = vm
                continue
            }
            vm.keys.insert(notice.key)
            vms[notice.vm] = vm
            marks[notice.key] = Mark(posted: now)
            individual += 1
            out.append(notice)
        }
        for name in others.keys.sorted() {
            guard let (merged, destinations) = others[name] else { continue }
            if hold(merged, now: now, destinations: destinations) { continue }
            var other = merged
            var covered = destinations
            if let earlier = marks.removeValue(forKey: other.key) {
                other.count += earlier.pending?.count ?? 0
                covered.formUnion(earlier.destinations)
            }
            marks[other.key] = Mark(posted: now)
            out.append(Self.others(other, destinations: covered.count))
        }
        if marks.count > Self.maxKeys {
            // Evict everything: what is still held is posted now, nothing stays stranded.
            out += marks.keys.sorted().compactMap { key in
                marks[key].flatMap { mark in mark.pending.map { Self.others($0, destinations: mark.destinations.count) } }
            }
            marks.removeAll()
        }
        return out
    }

    /// Adds `notice` (and, for "altre", the destinations it covers) to the open window of its
    /// destination; false when there is none.
    private mutating func hold(_ notice: EgressBlockNotice, now: Date, destinations: Set<String> = []) -> Bool {
        guard var mark = marks[notice.key], now.timeIntervalSince(mark.posted) < Self.window else { return false }
        if var pending = mark.pending {
            pending.count += notice.count
            mark.pending = pending
        } else {
            mark.pending = notice
        }
        mark.destinations.formUnion(destinations)
        marks[notice.key] = mark
        return true
    }

    /// The merged notice with its text: how many distinct destinations it covers.
    private static func others(_ notice: EgressBlockNotice, destinations: Int) -> EgressBlockNotice {
        guard notice.key.hasSuffix("|altre") else { return notice }
        return EgressBlockNotice(
            vm: notice.vm,
            destination: String(localized: "\(destinations) other destinations", comment: "Stands for a destination in a notice."),
            reason: notice.reason, allowDomain: nil, count: notice.count, key: notice.key)
    }

    /// The counts of the windows that are over, as notices (and forgets idle destinations).
    mutating func flush(now: Date) -> [EgressBlockNotice] {
        var out: [EgressBlockNotice] = []
        for (key, mark) in marks where now.timeIntervalSince(mark.posted) >= Self.window {
            if let pending = mark.pending {
                out.append(Self.others(pending, destinations: mark.destinations.count))
                marks[key] = Mark(posted: now)
            } else {
                marks[key] = nil
            }
        }
        return out.sorted { $0.key < $1.key }
    }
}

/// Every change of a VM's `egress.json` from the app: through `EgressPolicyStore` under its lock,
/// off the main actor. Adding (or a reset that widens) asks the owner first (Touch ID or the Mac
/// password); when that is refused or cancelled, nothing is written. Removing asks nothing.
enum EgressPolicyEdits {
    enum AllowOutcome: Equatable, Sendable {
        case added(String)
        case alreadyListed(String)
        case cancelled
        case malformed
        case full
        case invalid(String)
        case failed(String)
    }

    /// The list of `bundle`; nil when `egress.json` does not load (fail closed: the relay keeps
    /// its last good list).
    @concurrent
    static func load(_ bundle: VMBundle) async -> EgressPolicy? {
        EgressPolicyStore.load(bundle: bundle)
    }

    /// Adds `text` (a host name or `*.suffix`) to the list of `vm` after the owner's
    /// confirmation, asked only when the pattern is valid, the list loads, has room and lacks it.
    static func allow(
        _ text: String, vm: String, bundle: VMBundle, authenticator: any OwnerAuthenticator
    ) async -> AllowOutcome {
        let pattern: DomainPattern
        do {
            pattern = try DomainPattern(text)
        } catch {
            return .invalid(sentence(error))
        }
        let shown = ConsoleSanitizer.echoable(pattern.description)
        guard let current = await load(bundle) else { return .malformed }
        if current.allow.contains(pattern) { return .alreadyListed(shown) }
        guard current.allow.count < EgressPolicy.maxPatterns else { return .full }
        guard await authenticator.authenticate(
            reason: String(localized: "add \(shown) to the allowed domains of the VM \(ConsoleSanitizer.echoable(vm))",
                           comment: "The end of the system’s Touch ID sentence “Nido is trying to …”: a domain, then the VM’s name."))
        else { return .cancelled }
        do {
            try await write(bundle) { policy in
                guard !policy.allow.contains(pattern) else { return }
                guard policy.allow.count < EgressPolicy.maxPatterns else { throw ListFull() }
                policy.allow.append(pattern)
            }
        } catch is ListFull {
            return .full
        } catch NidoError.invalidEgressPolicy {
            return .malformed
        } catch {
            return .failed(sentence(error))
        }
        return .added(shown)
    }

    private struct ListFull: Error {}

    /// Removes exactly `pattern` (no confirmation: the list only narrows; an exact name never
    /// removes a wildcard). Returns the list as written.
    @discardableResult
    static func remove(_ pattern: DomainPattern, bundle: VMBundle) async throws -> EgressPolicy {
        try await write(bundle) { policy in
            policy.allow.removeAll { $0 == pattern }
        }
    }

    /// Whether writing `base` (`EgressPolicy.base(for:)`, or `EgressPolicy.macOSBase`) over
    /// `current` widens the list: always for a file
    /// that does not load (nobody knows what the relay keeps), else when the base list allows a
    /// name the current one does not.
    static func resetWidens(_ current: EgressPolicy?, to base: EgressPolicy = .base) -> Bool {
        guard let current else { return true }
        return base.allow.contains { pattern in
            !current.allow.contains(pattern) && (pattern.isWildcard || !current.allows(pattern.name))
        }
    }

    enum ResetOutcome: Equatable, Sendable {
        case reset
        case cancelled
        case failed(String)
    }

    /// Writes `base` (the base list of the VM's guest) over `egress.json` (also a
    /// damaged one, `EgressPolicyStore.replace`).
    /// The owner confirms first only when it widens the current list (`resetWidens`). "Widens" is
    /// decided again under the lock: if the list changed meanwhile and the write would now widen
    /// it without a confirmation, nothing is written and the owner is asked before trying again.
    /// `beforeWrite` is a test seam (runs between the first check and the write).
    static func resetToBase(
        vm: String, bundle: VMBundle, authenticator: any OwnerAuthenticator, base: EgressPolicy = .base,
        beforeWrite: @Sendable () -> Void = {}
    ) async -> ResetOutcome {
        let reason = String(localized: "rewrite the list of allowed domains of the VM \(ConsoleSanitizer.echoable(vm))",
                            comment: "The end of the system’s Touch ID sentence “Nido is trying to …”: %@ is the VM’s name.")
        var confirmed = false
        if resetWidens(await load(bundle), to: base) {
            guard await authenticator.authenticate(reason: reason) else { return .cancelled }
            confirmed = true
        }
        beforeWrite()
        do {
            if try await replace(bundle, with: base, confirmed: confirmed) { return .reset }
            // Widening now, without a confirmation: ask, then write whatever is there.
            guard await authenticator.authenticate(reason: reason) else { return .cancelled }
            _ = try await replace(bundle, with: base, confirmed: true)
            return .reset
        } catch {
            return .failed(sentence(error))
        }
    }

    /// False, with nothing written, when the write would widen the list on disk and the owner
    /// did not confirm.
    @concurrent
    private static func replace(_ bundle: VMBundle, with base: EgressPolicy, confirmed: Bool) async throws -> Bool {
        try EgressPolicyStore.replace(bundle: bundle, with: base, unless: { !confirmed && resetWidens($0, to: base) })
    }

    /// `EgressPolicyStore.update` off the main actor (it takes a file lock and writes).
    @concurrent
    @discardableResult
    static func write(
        _ bundle: VMBundle, _ edit: @escaping @Sendable (inout EgressPolicy) throws -> Void
    ) async throws -> EgressPolicy {
        try EgressPolicyStore.update(bundle: bundle, edit)
    }

    /// A wildcard so wide that it needs a warning and an extra confirmation
    /// (`DomainPattern.isBroadWildcard`, shared with `nido net allow`).
    static func isBroadWildcard(_ pattern: DomainPattern) -> Bool {
        pattern.isBroadWildcard
    }

    /// The localized sentence of an error.
    static func sentence(_ error: any Error) -> String {
        let text = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}
