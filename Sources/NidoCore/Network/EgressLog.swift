// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation

/// One line of a VM's `egress.log`: a connection of the controlled network, allowed or blocked.
/// Never packet contents: only what is below.
public struct EgressLogEntry: Codable, Sendable, Equatable {
    public enum Verdict: String, Codable, Sendable, CaseIterable {
        /// Allowed flows that ended (closed or idle) within `EgressFilter.endWindow`: `count`
        /// of them (1 when absent), the byte counts their totals.
        case allowed
        /// An allowed flow still open (written every `EgressFilter.progressInterval`); the byte
        /// counts are its totals so far.
        case open
        /// Allowed flows (`count`, 1 when absent) cut because their domain was removed.
        case cut
        /// A new flow to an address never resolved for an allowed domain.
        case denyUnknown
        /// A new flow to an address resolved only for domains not on the list.
        case denyDomain
        /// Neither TCP nor UDP (ICMP, others).
        case denyProto
        /// A DNS query for a name not on the list (answered NXDOMAIN).
        case name
        /// A DNS query with a name that is not a plain host name.
        case invalidName
        /// A DNS query for an alias (`via`) of `domain` of a type other than A, AAAA, CNAME, HTTPS.
        case aliasQueryType
        case dnsBypass
        case hostSubnet
        case broadcast
        case ipv6
        case spoofed
        case malformed
        /// Reports left out by the relay's limits (`lostBlocks`, `lostFlows`, `lostNoise`).
        case suppressed
        /// The relay lost gvproxy (`reason`): the VM has no network until it stops.
        case uplinkLost

        /// Everything but an allowed flow's own lines.
        public var isBlock: Bool { self != .allowed && self != .open }
    }

    /// When the line was written (wall clock).
    public var time: Date
    /// The domain the flow was allowed for, the refused name, or the domain an address was
    /// learned for; nil when the relay knows none.
    public var domain: String?
    /// Destination address (dotted IPv4 or IPv6 text), when the frame had one.
    public var ip: String?
    public var port: UInt16?
    public var proto: EgressProto
    /// IP bytes guest → Internet and back (0 for a block).
    public var bytesOut: UInt64
    public var bytesIn: UInt64
    public var verdict: Verdict
    /// For `.suppressed` only: how many denials and flow events were left out.
    public var lostBlocks: Int?
    public var lostFlows: Int?
    /// For `.suppressed` only: how many local noise denials (multicast, broadcast, local IPv6;
    /// never notified) were left out; absent when none.
    public var lostNoise: Int?
    /// For `.allowed` and `.cut`: how many flows the line covers, when more than one.
    public var count: Int?
    /// For a block: how many identical blocks the relay held back before this one.
    public var repeats: Int?
    /// The CNAME target of `domain` (learned from its DNS) the flow or query went through.
    public var via: String?
    /// For `.uplinkLost` only: why the relay lost gvproxy, an `UplinkLoss` code (lines written by
    /// older versions: Italian free text). Show it through `UplinkLoss.text(_:)`.
    public var reason: String?

    public init(
        time: Date, domain: String?, ip: String?, port: UInt16?, proto: EgressProto, bytesOut: UInt64 = 0,
        bytesIn: UInt64 = 0, verdict: Verdict, lostBlocks: Int? = nil, lostFlows: Int? = nil, count: Int? = nil,
        repeats: Int? = nil, via: String? = nil, lostNoise: Int? = nil, reason: String? = nil
    ) {
        self.time = time
        self.domain = domain
        self.ip = ip
        self.port = port
        self.proto = proto
        self.bytesOut = bytesOut
        self.bytesIn = bytesIn
        self.verdict = verdict
        self.lostBlocks = lostBlocks
        self.lostFlows = lostFlows
        self.lostNoise = lostNoise
        self.count = count
        self.repeats = repeats
        self.via = via
        self.reason = reason
    }

    /// The line for a relay event.
    public init?(event: EgressEvent, time: Date) {
        var domain: String?
        var bytes: (out: UInt64, in: UInt64) = (0, 0)
        var lost: (blocks: Int, flows: Int, noise: Int)?
        var flows = 1
        var reason: String?
        let verdict: Verdict
        switch event.kind {
        case .uplinkLost(let why):
            (verdict, reason) = (.uplinkLost, why)
        case .progress(let name, let out, let into):
            (verdict, domain, bytes) = (.open, name, (out, into))
        case .ended(let name, let out, let into, let count):
            (verdict, domain, bytes, flows) = (.allowed, name, (out, into), count)
        case .suppressed(let blocks, let flows, let noise):
            (verdict, lost) = (.suppressed, (blocks, flows, noise))
        case .denied(let denial):
            switch denial {
            case .cut(let name, let out, let into, let count): (verdict, domain, bytes, flows) = (.cut, name, (out, into), count)
            case .verdict(.allow): return nil
            case .verdict(.denyUnknown): verdict = .denyUnknown
            case .verdict(.denyDomain(let name)): (verdict, domain) = (.denyDomain, name)
            case .verdict(.denyProto): verdict = .denyProto
            case .name(let name): (verdict, domain) = (.name, name)
            case .invalidName: verdict = .invalidName
            case .aliasQueryType(let parent, _): (verdict, domain) = (.aliasQueryType, parent)
            case .dnsBypass: verdict = .dnsBypass
            case .hostSubnet: verdict = .hostSubnet
            case .broadcast: verdict = .broadcast
            case .ipv6: verdict = .ipv6
            case .spoofed: verdict = .spoofed
            case .malformed: verdict = .malformed
            }
        }
        self.init(
            time: time, domain: domain, ip: event.ip, port: event.port, proto: event.proto, bytesOut: bytes.out,
            bytesIn: bytes.in, verdict: verdict, lostBlocks: lost?.blocks, lostFlows: lost?.flows,
            count: flows > 1 ? flows : nil, repeats: event.repeats > 0 ? event.repeats : nil, via: event.via,
            lostNoise: (lost?.noise ?? 0) > 0 ? lost?.noise : nil, reason: reason)
    }
}

extension EgressLogEntry {
    /// Boot noise without a domain that never leaves the link (ruling): multicast or broadcast,
    /// IPv6 without an address or to a multicast (`ff00::/8`) or link-local (`fe80::/10`) one, a
    /// malformed frame without an address, and any block without a domain to the IPv4 link-local
    /// broadcast 169.254.255.255. Never notified, not printed by `nido start`; `nido net log`
    /// and the app's log hide it unless asked (`--all`). It stays in `egress.log`.
    public var isLocalNoise: Bool {
        guard verdict.isBlock, verdict != .cut, verdict != .suppressed, verdict != .uplinkLost, domain == nil
        else { return false }
        // Link-local unicast (e.g. 169.254.169.254) stays a real destination.
        if Self.isLinkLocalBroadcast(ip) { return true }
        switch verdict {
        case .broadcast: return true
        case .ipv6: return Self.isLocalIPv6(ip)
        case .malformed: return ip == nil
        default: return false
        }
    }

    /// No address, or an IPv6 multicast (`ff00::/8`) or link-local (`fe80::/10`) one, parsed
    /// with `inet_pton`. An address that does not parse counts as local only when it is absent.
    static func isLocalIPv6(_ text: String?) -> Bool {
        guard let text else { return true }
        var address = in6_addr()
        guard inet_pton(AF_INET6, text, &address) == 1 else { return false }
        let first = address.__u6_addr.__u6_addr8.0
        let second = address.__u6_addr.__u6_addr8.1
        return first == 0xFF || (first == 0xFE && (second & 0xC0) == 0x80)
    }

    /// The IPv4 link-local broadcast 169.254.255.255, parsed with `inet_pton`.
    static func isLinkLocalBroadcast(_ text: String?) -> Bool {
        guard let text else { return false }
        var address = in_addr()
        guard inet_pton(AF_INET, text, &address) == 1 else { return false }
        return UInt32(bigEndian: address.s_addr) == 0xA9FE_FFFF
    }
}

/// The content-free connection log of a controlled VM, as `AIBridgeLog`: one JSON object per
/// line, 0600 via `PrivateFile`, each file rotated at 1 MiB into `<name>.1`. Blocks, cuts and
/// summaries go to `egress.log`; the lines of allowed flows (ends, merged per destination for
/// `EgressFilter.endWindow`, and progress every `EgressFilter.progressInterval`) to
/// `egress-flows.log`, so a churn of flows can never evict a block. So at most 4 MiB on disk.
/// Domains of the VM are written nowhere else. Writing is best effort: a failure never touches
/// the network.
public final class EgressLog: Sendable {
    public static let cap = 1 << 20

    private let blocks: ConsoleLog
    private let flows: ConsoleLog

    /// Opens (or creates) both files of `bundle`; refuses an unsafe file (`NidoError.unsafePath`).
    public init(bundle: VMBundle, cap: Int = EgressLog.cap) throws {
        blocks = try ConsoleLog(url: bundle.egressLogURL, cap: cap)
        flows = try ConsoleLog(url: bundle.egressFlowLogURL, cap: cap)
    }

    public func append(_ entry: EgressLogEntry) {
        guard let line = try? Self.line(for: entry) else { return }
        (entry.verdict.isBlock ? blocks : flows).write(line)
    }

    /// Writes the line of `event`, if it has one (`EgressLogEntry(event:time:)`).
    public func record(_ event: EgressEvent, time: Date = Date()) {
        if let entry = EgressLogEntry(event: event, time: time) { append(entry) }
    }

    public func close() {
        blocks.close()
        flows.close()
    }

    /// The JSON line (keys sorted, time in ISO 8601 UTC, nil fields left out) ending in a newline.
    static func line(for entry: EgressLogEntry) throws -> Data {
        var data = try encoder.encode(entry)
        data.append(0x0A)
        return data
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Every entry of `bundle` (blocks and flows, both generations), oldest first.
    public static func readEntries(bundle: VMBundle) -> [EgressLogEntry] {
        let all = readEntries(at: bundle.egressLogURL) + readEntries(at: bundle.egressFlowLogURL)
        // Stable: lines written in the same second keep their file order.
        return all.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
    }

    /// Entries of `<url>.1` then `url` (oldest first), skipping lines that do not decode. Files
    /// are opened without following symlinks.
    public static func readEntries(at url: URL) -> [EgressLogEntry] {
        let rotated = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".1")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var entries: [EgressLogEntry] = []
        for file in [rotated, url] {
            guard let fd = try? PrivateFile.open(file, flags: O_RDONLY, label: file.lastPathComponent) else { continue }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            // A generation is at most `cap` bytes; read a little more in case the cap changed.
            guard let data = try? handle.read(upToCount: 4 * cap) else { continue }
            for line in data.split(separator: 0x0A) {
                if let entry = try? decoder.decode(EgressLogEntry.self, from: Data(line)) { entries.append(entry) }
            }
        }
        return entries
    }
}
