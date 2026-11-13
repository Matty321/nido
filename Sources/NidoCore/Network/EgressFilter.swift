// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The uplink side of a controlled VM (gvproxy): the gateway (on the uplink subnet, which also
/// serves DHCP and DNS), the subnet mask, and the guest's Ethernet address.
public struct EgressNetwork: Equatable, Sendable {
    /// IPv4 address of the gateway (host order).
    public let gateway: UInt32
    /// Subnet mask (host order).
    public let mask: UInt32
    public let guestMAC: EgressMAC

    public init(gateway: UInt32, mask: UInt32, guestMAC: EgressMAC) {
        self.gateway = gateway
        self.mask = mask
        self.guestMAC = guestMAC
    }

    var subnet: UInt32 { gateway & mask }
    var subnetBroadcast: UInt32 { subnet | ~mask }
    func contains(_ address: UInt32) -> Bool { address & mask == subnet }
}

/// Why the relay dropped a guest frame.
public enum EgressDenial: Hashable, Sendable {
    /// `EgressDecision.decide` refused a new flow (never `.allow`).
    case verdict(EgressVerdict)
    /// A DNS query for a name the policy does not allow, answered NXDOMAIN.
    case name(String)
    /// A DNS query whose name is not plain letters, digits, hyphens and underscores (or is the
    /// root), answered NXDOMAIN.
    case invalidName
    /// DNS (53) or DNS over TLS (853) to anything else than the relay's resolver.
    case dnsBypass
    /// Traffic to the uplink subnet (the Mac included) other than DHCP, the relay's DNS and the
    /// replies of an SSH connection opened by the Mac.
    case hostSubnet
    /// Multicast or broadcast.
    case broadcast
    case ipv6
    /// A source Ethernet or IPv4 address that is not the VM's own (its lease), or a frame not
    /// addressed to the gateway.
    case spoofed
    /// A frame the relay does not parse: truncated, fragmented, another EtherType, a bad DNS query.
    case malformed
    /// A DNS query for a CNAME alias (`EgressEvent.via`) of the allowed name `parent`, of a type
    /// other than A, AAAA, CNAME and HTTPS: answered NXDOMAIN.
    case aliasQueryType(parent: String, type: UInt16)
    /// Open flows to a domain removed from the list, cut (their next frames are dropped): one
    /// report per domain and removal, with how many flows and their byte totals.
    case cut(domain: String, bytesOut: UInt64, bytesIn: UInt64, count: Int)
}

/// What the relay reports: never the content of a packet. `ip` is the destination (dotted IPv4,
/// or IPv6 text), `port` its port; for a report covering several flows, nil unless they all
/// share it. The start of an allowed flow is not reported: its progress, end or cut are.
public struct EgressEvent: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// An allowed flow still open after `EgressFilter.progressInterval`, with its byte counts
        /// so far (IP packets); repeated every interval, so a long flow is never silent.
        case progress(domain: String, bytesOut: UInt64, bytesIn: UInt64)
        /// `count` allowed flows that ended (closed or idle) within `EgressFilter.endWindow`, to
        /// the same destination when `ip` and `port` are set, with their byte totals (IP
        /// packets). `domain` is nil only when the relay had to merge flows of many domains.
        case ended(domain: String?, bytesOut: UInt64, bytesIn: UInt64, count: Int)
        case denied(EgressDenial)
        /// Reports left out, by pool: denials beyond `EgressFilter.maxEventsPerSecond`, flow
        /// events beyond `EgressFilter.maxFlowEventsPerSecond`, local noise beyond
        /// `EgressFilter.maxNoiseEventsPerSecond` (`noise`, never notified), or events a slow
        /// consumer could not take (`EgressEventPipe`).
        case suppressed(blocks: Int, flows: Int, noise: Int = 0)
        /// The relay lost its uplink (gvproxy exited or its socket died), `reason` an `UplinkLoss` code:
        /// from then on every frame is dropped both ways until the VM stops.
        case uplinkLost(reason: String)
    }

    /// What Nido tells a person when the relay lost its uplink (CLI line, app notification).
    /// `reason` is an `UplinkLoss` code (shown as its text) or, from older logs, free text shown as is.
    public static func uplinkLostMessage(reason: String) -> String {
        let reason = UplinkLoss.text(reason)
        return L10n.string("Controlled network interrupted: \(reason). The VM has no network until it next starts.")
    }

    public var kind: Kind
    public var proto: EgressProto
    public var ip: String?
    public var port: UInt16?
    /// How many identical denials the relay held back (`EgressFilter.reportInterval`) since the
    /// previous report of this one.
    public var repeats = 0
    /// The CNAME target of `domain` the flow or query was reached through (an alias learned
    /// from that domain's DNS), when not the domain itself.
    public var via: String?

    public init(kind: Kind, proto: EgressProto, ip: String?, port: UInt16?) {
        self.kind = kind
        self.proto = proto
        self.ip = ip
        self.port = port
    }

    /// The budget an event uses: denials, local noise, progress reports, and the ends and cuts
    /// of flows, each apart, so neither a flood of denials or noise nor a churn of flows can
    /// push out the others.
    enum Pool {
        case denial, noise, progress, lifecycle
    }

    var pool: Pool {
        switch kind {
        case .progress: .progress
        case .ended, .denied(.cut), .uplinkLost: .lifecycle
        case .denied: isLocalNoise ? .noise : .denial
        case .suppressed: .denial
        }
    }

    /// A denial the app never notifies (ruling, see `EgressNoticeText.isNotified`): boot noise
    /// without a domain that never leaves the link. Multicast or broadcast, IPv6 without an
    /// address or to a multicast (`ff00::/8`) or link-local (`fe80::/10`) one, a malformed frame
    /// without an address, and any denial without a domain to the IPv4 link-local broadcast
    /// 169.254.255.255.
    public var isLocalNoise: Bool {
        guard case .denied(let denial) = kind else { return false }
        switch denial {
        case .name, .aliasQueryType, .cut, .verdict(.denyDomain), .verdict(.allow): return false
        default: break
        }
        // The same address rules as `EgressLogEntry.isLocalNoise` (one place for both).
        if EgressLogEntry.isLinkLocalBroadcast(ip) { return true }
        switch denial {
        case .broadcast: return true
        case .ipv6: return EgressLogEntry.isLocalIPv6(ip)
        case .malformed: return ip == nil
        default: return false
        }
    }
}

/// The relay's frame filter: decides every Ethernet frame between the guest and the uplink (gvproxy). Pure (no
/// I/O, the time is given); not thread-safe: the relay calls it from its one queue.
///
/// Guest → uplink (`outbound`), only these pass; everything else is dropped and reported:
/// - the guest's frames only: source MAC the VM's, source IPv4 its DHCP lease (learned from the
///   gateway's DHCP ACK), unicast IPv4 addressed to the gateway's MAC;
/// - ARP between the guest and the gateway;
/// - DHCP to the gateway or broadcast, for the guest's own hardware address;
/// - DNS (UDP 53) to the gateway: an allowed name is forwarded as is and remembered, any other
///   gets a synthesized NXDOMAIN with a short negative TTL;
/// - the replies of an SSH connection the Mac opened to the guest's port 22;
/// - TCP/UDP to an address outside the uplink subnet that `EgressDecision` allows (learned for an
///   allowed name), except DNS and DNS over TLS; the flow is then remembered until it closes or
///   idles out, or its domain is removed from the list;
/// - for TCP to port 443, the first segment carrying data is read once: a TLS server name (SNI)
///   that the list does not allow cuts the flow (`checkServerName`), whatever the address.
///
/// Uplink → guest (`inbound`): only frames for the guest's MAC (or broadcast DHCP), and of these
/// only DHCP and ARP from the gateway, answers to the DNS queries the relay forwarded (matching
/// transaction id, port and question; their A records are learned and TTLs clamped), SSH from
/// the Mac, and packets of open allowed flows.
final class EgressFilter {
    enum Outbound: Equatable {
        case forward
        case drop
        /// Drop the frame and send this one back to the guest instead.
        case reply([UInt8])
    }

    /// TTL and SOA minimum of a synthesized NXDOMAIN (s): the guest caches a refusal only this
    /// long, so a domain allowed meanwhile works within a few seconds (measured live: the relay
    /// applies the new list at once, the guest's cache is the only wait).
    static let negativeTTL: UInt32 = 3
    /// Longest TTL of an answer as the guest gets it (s); the relay learns the server's own TTL
    /// (`DNSLearner` keeps it 600 s – 1 h, never shorter than this). So the guest asks again
    /// soon: an address it cached for a domain removed and allowed again is learned anew within
    /// this time, and the guest never holds an address longer than the relay knows it.
    static let forwardedMaxTTL: UInt32 = 60
    /// Shortest life of a CNAME target the guest may ask for (s). Kept short, unlike learned
    /// addresses (`DNSLearner.minTTL`): only the guest's resolver asks for an alias, and it caches
    /// the CNAME for at most the chain's TTL, which this never undercuts.
    static let aliasMinTTL: TimeInterval = 30
    /// Most denials reported per second; the rest are counted and reported as one `.suppressed`
    /// summary at the start of the next second (or by the sweep).
    static let maxEventsPerSecond = 20
    /// Most local noise reports per second (`EgressEvent.isLocalNoise`), in a pool of their own:
    /// a flood of distinct multicast or broadcast never uses up the denials' budget. The rest
    /// are counted apart in the same summary (`noise`).
    static let maxNoiseEventsPerSecond = 10
    /// Most progress reports per second, in a pool of their own: denials never use it up. The
    /// rest are counted in the same summary.
    static let maxFlowEventsPerSecond = 200
    /// Most end and cut reports per second, in a pool reserved to them. Ends and cuts over this
    /// budget are never dropped: they wait (merged) for the next second.
    static let maxLifecycleEventsPerSecond = 100
    /// Ends of flows to the same domain, address, port and protocol within this window (s) are
    /// one report, with their count and byte totals.
    static let endWindow: TimeInterval = 10
    /// Destinations whose ends are being merged; beyond that, ends merge per domain (at most
    /// `maxMergedDomains` more), then all together, so the table stays bounded and no end is lost.
    static let maxPendingEnds = 1024
    static let maxMergedDomains = 256
    /// A held-back repeat count waits this long (s) for the next report of its denial.
    static let repeatMemory: TimeInterval = 3600
    /// Record types a query for an alias may ask: A, AAAA, CNAME, HTTPS.
    static let aliasQueryTypes: Set<UInt16> = [1, 28, 5, 65]
    /// Addresses remembered as learned through an alias (for the `via` of their flows).
    static let maxViaAddresses = 4096
    /// CNAME targets learned per answer, allowed names an alias may belong to, and aliases in all.
    static let maxAliasesPerAnswer = 8
    static let maxParentsPerAlias = 4
    static let maxAliases = 1024
    /// An open allowed flow is reported (`.progress`) at least this often (s), so the log has a
    /// line for it before it ends.
    static let progressInterval: TimeInterval = 60
    /// Largest EDNS UDP payload size a forwarded query may advertise: bigger answers would be
    /// fragmented, and fragments are dropped.
    static let maxEDNSSize: UInt16 = 1232
    /// The same denial (kind, protocol, destination, port) is reported at most once per interval (s).
    static let reportInterval: TimeInterval = 10
    static let maxReportKeys = 4096
    /// TCP port whose first data segment is read for the TLS server name.
    static let tlsPort: UInt16 = 443
    /// Most flows held; the least recently seen goes first.
    static let maxFlows = 16384
    static let tcpIdleTimeout: TimeInterval = 3600
    static let udpIdleTimeout: TimeInterval = 180
    /// Life of a TCP flow after a FIN or RST, counted from its last frame.
    static let closingTimeout: TimeInterval = 10
    /// How long a TCP flow cut by a policy change is remembered (s): a segment the guest sends on
    /// it meanwhile (a retransmission backs off for about two minutes) gets a reset.
    static let cutMemory: TimeInterval = 120
    /// Life of a forwarded DNS query waiting for its answer.
    static let queryTimeout: TimeInterval = 10
    static let maxPendingQueries = 256
    static let maxHostFlows = 64

    let network: EgressNetwork
    let decision: EgressDecision
    private let events: (EgressEvent) -> Void

    /// The guest's IPv4 address, from the gateway's DHCP ACK (or seeded by the relay from the
    /// DHCP lease database); nil until then, and only DHCP passes.
    private(set) var lease: UInt32?
    /// The gateway's Ethernet address, from its ARP (or seeded by the relay from the uplink);
    /// unicast IPv4 must go to it.
    private(set) var gatewayMAC: EgressMAC?

    private struct FlowKey: Hashable {
        let proto: UInt8
        let guestPort: UInt16
        let remote: UInt32
        let remotePort: UInt16
    }

    /// The TLS server name check of a flow (`checkServerName`).
    private enum TLSCheck {
        /// Nothing to read: another port or protocol, or the first data segment was read.
        case none
        /// TCP to port 443 waiting for its first segment carrying data.
        case pending
        /// Its server name is not allowed: cut, nothing more passes either way, and it goes
        /// without a report once idle for `closingTimeout`. Until then a new connection that
        /// reuses the same 4-tuple (within about 10 s) is still this flow, so it is dropped
        /// silently, with no reset and no new log line, until the mark expires.
        case refused
    }

    private struct Flow {
        let domain: String
        /// The alias the address was learned through, if any.
        var via: String?
        var tls = TLSCheck.none
        var bytesOut: UInt64 = 0
        var bytesIn: UInt64 = 0
        var lastSeen: Date
        /// Start of the flow, or its last `.progress` report.
        var lastReported: Date
        var closing = false
        /// TCP: the sequence number following the furthest server byte passed to the guest, the
        /// one a reset must carry for the guest to take it (RFC 5961 3.2).
        var guestReceiveNext: UInt32?
    }

    /// A TCP flow cut by a policy change, remembered for `cutMemory`.
    private struct CutMark {
        let domain: String
        let since: Date
    }

    private struct HostFlow {
        var lastSeen: Date
        /// Sequence number of the Mac's SYN: the guest's SYN+ACK must acknowledge it.
        let hostSequence: UInt32
        /// The Mac acknowledged the guest's SYN+ACK.
        var established = false
        var closing = false
    }

    private struct PendingKey: Hashable {
        let port: UInt16
        let id: UInt16
    }

    private struct Pending {
        let question: EgressWire.Question
        /// The allowed name the answer is learned under: the question's own, or the allowed
        /// name the question is an alias of.
        let learnAs: String
        /// The question's name when it is an alias of `learnAs`.
        let via: String?
        let sent: Date
    }

    /// An address learned through an alias of `parent`, until `expiry`.
    private struct Via {
        let alias: String
        let parent: String
        let expiry: Date
    }

    /// An allowed name a CNAME target was reached from, until `expiry`.
    private struct AliasParent {
        let name: String
        let expiry: Date
    }

    private var flows: [FlowKey: Flow] = [:]
    /// TCP flows cut by a policy change: the guest's segments on them get a reset.
    private var cutFlows: [FlowKey: CutMark] = [:]
    /// SSH connections opened by the Mac, by the Mac's port.
    private var hostFlows: [UInt16: HostFlow] = [:]
    private var pending: [PendingKey: Pending] = [:]
    /// CNAME targets of allowed names, learned only from answers to forwarded queries: while
    /// live, the guest may ask them directly (its resolver does when it keeps a CNAME longer
    /// than the address it leads to). Forgotten when they expire or their name is removed.
    private var aliases: [String: [AliasParent]] = [:]
    private var viaByAddress: [UInt32: Via] = [:]
    private struct ReportMark {
        var last: Date
        var repeats = 0
    }

    /// Flows merged into one end or cut report. Protocol, address and port stay set while
    /// every merged flow shares them.
    private struct Totals {
        var count = 0
        var bytesOut: UInt64 = 0
        var bytesIn: UInt64 = 0
        let since: Date
        var proto: UInt8?
        var remote: UInt32?
        var remotePort: UInt16?
        var via: String?
        private var first = true

        init(since: Date, key: FlowKey) {
            self.since = since
            proto = key.proto
            remote = key.remote
            remotePort = key.remotePort
        }

        mutating func add(_ flow: Flow, _ key: FlowKey) {
            if first { via = flow.via }
            first = false
            if via != flow.via { via = nil }
            count += 1
            bytesOut += flow.bytesOut
            bytesIn += flow.bytesIn
            if proto != key.proto { proto = nil }
            if remote != key.remote { remote = nil }
            if remotePort != key.remotePort { remotePort = nil }
        }
    }

    /// Exact (domain, protocol, address, port), then per domain, then everything (all nil).
    private struct EndKey: Hashable {
        let domain: String?
        let proto: UInt8?
        let remote: UInt32?
        let remotePort: UInt16?
    }

    private var lastReport: [EgressEvent: ReportMark] = [:]
    private var pendingEnds: [EndKey: Totals] = [:]
    private var pendingCuts: [String: Totals] = [:]
    private var budgetWindow = Date.distantPast
    private var budgetUsed = 0
    private var flowBudgetUsed = 0
    private var lifecycleBudgetUsed = 0
    private var budgetSuppressed = 0
    private var flowBudgetSuppressed = 0
    private var noiseBudgetUsed = 0
    private var noiseBudgetSuppressed = 0

    var flowCount: Int { flows.count }
    var aliasCount: Int { aliases.count }

    init(network: EgressNetwork, decision: EgressDecision, events: @escaping (EgressEvent) -> Void) {
        self.network = network
        self.decision = decision
        self.events = events
    }

    /// Sets the guest's address when it is a usable address of the subnet (the relay seeds it
    /// from the DHCP lease database after a restore); ignored otherwise.
    func seedLease(_ address: UInt32) {
        if isUsableLease(address) { lease = address }
    }

    /// Sets the gateway's Ethernet address before its first ARP (the relay seeds the one the uplink
    /// knows, gvproxy's fixed MAC), so a resumed guest's unicast is not dropped until it ARPs again.
    /// A later ARP from the gateway replaces it. Ignored for a broadcast or multicast address.
    func seedGatewayMAC(_ mac: EgressMAC) {
        if !mac.isGroup { gatewayMAC = mac }
    }

    // MARK: - Guest → uplink

    /// The bytes of a forwarded frame to write: an IPv4 frame ends with its packet (Ethernet
    /// padding and anything after the packet are not sent), an ARP frame after its 28 bytes.
    static func forwardedLength(_ f: ByteView) -> Int {
        guard f.count >= 14 else { return f.count }
        switch f.u16(12) {
        case 0x0806: return min(f.count, 42)
        case 0x0800:
            guard f.count >= 18 else { return f.count }
            return min(f.count, 14 + Int(f.u16(16)))
        default: return f.count
        }
    }

    func outbound(_ frame: inout [UInt8], now: Date) -> Outbound {
        frame.withUnsafeMutableBytes { outbound(ByteView($0), now: now) }
    }

    func outbound(_ f: ByteView, now: Date) -> Outbound {
        guard f.count >= 14 else { return deny(.malformed, now: now) }
        guard f.mac(6) == network.guestMAC else { return deny(.spoofed, now: now) }
        switch f.u16(12) {
        case 0x0806: return arpOut(f, now: now)
        case 0x0800: return ipv4Out(f, now: now)
        case 0x86DD:
            let destination = f.count >= 54 ? EgressWire.ipv6Text(f, at: 38) : nil
            let proto = f.count >= 54 ? EgressProto(ipProtocol: f[20]) : .other
            return deny(.ipv6, proto: proto, ip: destination, now: now)
        default: return deny(.malformed, now: now)
        }
    }

    private func arpOut(_ f: ByteView, now: Date) -> Outbound {
        guard f.count >= 42, f.u16(14) == 1, f.u16(16) == 0x0800, f[18] == 6, f[19] == 4 else {
            return deny(.malformed, now: now)
        }
        let op = f.u16(20)
        let sender = f.u32(28)
        let target = f.u32(38)
        let destination = f.mac(0)
        guard op == 1 || op == 2, f.mac(22) == network.guestMAC,
            destination == .broadcast || destination == gatewayMAC
        else { return deny(.spoofed, now: now) }
        guard let lease else { return deny(.spoofed, now: now) }
        let fromLease = sender == lease && (target == network.gateway || target == lease)
        let probe = sender == 0 && op == 1 && target == lease
        guard fromLease || probe else {
            return deny(sender == lease ? .hostSubnet : .spoofed, proto: .other, ip: DNSLearner.dotted(target), now: now)
        }
        return .forward
    }

    private func ipv4Out(_ f: ByteView, now: Date) -> Outbound {
        // No IP options, DHCP included: nothing the guest needs uses them.
        guard let ip = IPv4(f), ip.udpLengthMatches(f), !ip.hasOptions else { return deny(.malformed, now: now) }
        let proto = EgressProto(ipProtocol: ip.proto)
        if ip.proto == 17, ip.l4Length >= 8, f.u16(ip.l4) == 68, f.u16(ip.l4 + 2) == 67 {
            return dhcpOut(f, ip: ip, now: now)
        }
        // The destination as text only on the paths that report or decide: never for a frame of
        // an open flow (the hot path).
        let ports = ip.ports(f)
        guard let lease, ip.src == lease else {
            return deny(.spoofed, proto: proto, ip: DNSLearner.dotted(ip.dst), port: ports?.dst, now: now)
        }
        if ip.dst >> 28 == 0xE || ip.dst == 0xFFFF_FFFF || ip.dst == network.subnetBroadcast || f.mac(0).isGroup {
            return deny(.broadcast, proto: proto, ip: DNSLearner.dotted(ip.dst), port: ports?.dst, now: now)
        }
        guard f.mac(0) == gatewayMAC else { return deny(.spoofed, now: now) }
        if ip.dst == network.gateway {
            if ip.proto == 17, let ports, ports.dst == 53 { return dnsQuery(f, ip: ip, sport: ports.src, now: now) }
            if ip.proto == 6, let ports, ports.src == 22, ip.l4Length >= 20, sshReply(f, ip: ip, hostPort: ports.dst, now: now) {
                return .forward
            }
            return deny(.hostSubnet, proto: proto, ip: DNSLearner.dotted(ip.dst), port: ports?.dst, now: now)
        }
        if network.contains(ip.dst) {
            return deny(.hostSubnet, proto: proto, ip: DNSLearner.dotted(ip.dst), port: ports?.dst, now: now)
        }
        guard ip.proto == 6 || ip.proto == 17 else {
            let dottedDst = DNSLearner.dotted(ip.dst)
            let verdict = decision.decide(dstIP: dottedDst, port: 0, proto: proto, now: now)
            return deny(.verdict(verdict), proto: proto, ip: dottedDst, now: now)
        }
        guard let ports else { return deny(.malformed, now: now) }
        // An open flow first (one lookup, updated in place): flows never go to DNS or DNS over
        // TLS, so the check below cannot refuse one.
        let key = FlowKey(proto: ip.proto, guestPort: ports.src, remote: ip.dst, remotePort: ports.dst)
        if let index = flows.index(forKey: key) {
            switch flows.values[index].tls {
            case .refused:
                return .drop
            case .pending:
                // The first segment carrying data of a TLS flow: read once (not the hot path).
                var flow = flows.values[index]
                let refusal = checkServerName(f, ip: ip, flow: &flow, now: now)
                flows.values[index] = flow
                if let refusal { return refusal }
            case .none:
                break
            }
            Self.record(&flows.values[index], out: ip, f, now: now)
            return .forward
        }
        // A flow cut by a policy change: the guest learns at once that it is over (its own reset
        // needs no answer). Not reported again: the cut was.
        if ip.proto == 6, cutFlows[key] != nil {
            guard ip.tcpFlags(f) & 0x04 == 0 else { return .drop }
            let header = Int(f[ip.l4 + 12] >> 4) * 4
            guard header >= 20, header <= ip.l4Length else { return .drop }
            return .reply(resetFrame(f, ip: ip, payload: ip.l4Length - header))
        }
        if ports.dst == 53 || ports.dst == 853 {
            return deny(.dnsBypass, proto: proto, ip: DNSLearner.dotted(ip.dst), port: ports.dst, now: now)
        }
        let dottedDst = DNSLearner.dotted(ip.dst)
        let verdict = decision.decide(dstIP: dottedDst, port: ports.dst, proto: proto, now: now)
        guard case .allow(let domain) = verdict else {
            return deny(.verdict(verdict), proto: proto, ip: dottedDst, port: ports.dst, now: now)
        }
        if flows.count >= Self.maxFlows { makeRoom(now: now) }
        var flow = Flow(domain: domain, via: via(of: ip.dst, domain: domain, now: now),
                        tls: ip.proto == 6 && ports.dst == Self.tlsPort ? .pending : .none,
                        bytesOut: UInt64(ip.totalLength), lastSeen: now, lastReported: now)
        if let refusal = checkServerName(f, ip: ip, flow: &flow, now: now) {
            flows[key] = flow
            return refusal
        }
        if ip.proto == 6, ip.tcpFlags(f) & 0x05 != 0 { flow.closing = true }
        flows[key] = flow
        return .forward
    }

    /// Reads the first segment carrying data of a TCP flow to port 443 (only that one: later
    /// segments are never read or held). A TLS ClientHello whose server name no allowed pattern
    /// covers, nor a live CNAME alias of an allowed name, cuts the flow: the segment is dropped,
    /// the guest gets a reset, the name is reported as `denyDomain`. A ClientHello without a
    /// name in this segment, or data that is not TLS, passes: the learned domain applies.
    /// Nil when the segment may go on.
    private func checkServerName(_ f: ByteView, ip: IPv4, flow: inout Flow, now: Date) -> Outbound? {
        guard flow.tls == .pending else { return nil }
        let header = Int(f[ip.l4 + 12] >> 4) * 4
        guard header >= 20, header < ip.l4Length else { return nil }
        flow.tls = .none
        guard case .sni(let name) = EgressWire.serverName(f.slice(ip.l4 + header, ip.l4Length - header)),
            allowedName(for: name, now: now) == nil
        else { return nil }
        flow.tls = .refused
        flow.closing = true
        flow.lastSeen = now
        report(.verdict(.denyDomain(Self.shownServerName(name))), proto: .tcp, ip: DNSLearner.dotted(ip.dst),
               port: Self.tlsPort, now: now)
        return .reply(resetFrame(f, ip: ip, payload: ip.l4Length - header))
    }

    /// A refused server name as reported: lowercase without the trailing dot when it is a
    /// well-formed name, else as parsed (printable ASCII only), at most 253 characters.
    private static func shownServerName(_ name: String) -> String {
        let shown = DomainPattern.normalizedQueryName(name) ?? name
        guard shown.utf8.count > DomainPattern.maxNameLength else { return shown }
        return String(shown.prefix(DomainPattern.maxNameLength)) + "…"
    }

    /// A TCP reset to the guest for its segment in `f`, from the server's address and port
    /// (RFC 9293 3.10.7.1): at the segment's acknowledgment number when it has one, else an
    /// RST+ACK acknowledging it.
    private func resetFrame(_ f: ByteView, ip: IPv4, payload: Int) -> [UInt8] {
        let flags = ip.tcpFlags(f)
        let acknowledges = flags & 0x10 != 0
        let acknowledged = f.u32(ip.l4 + 4) &+ UInt32(payload) &+ UInt32(flags & 0x01) &+ UInt32(flags >> 1 & 0x01)
        return resetFrame(
            from: f.mac(0), remote: ip.dst, remotePort: f.u16(ip.l4 + 2), guest: ip.src, guestPort: f.u16(ip.l4),
            sequence: acknowledges ? f.u32(ip.l4 + 8) : 0, acknowledging: acknowledges ? nil : acknowledged)
    }

    /// A TCP reset from `remote`:`remotePort` (sent from Ethernet address `from`) to the guest at
    /// `sequence`: a plain RST, or an RST+ACK when `acknowledging` is given.
    private func resetFrame(from: EgressMAC, remote: UInt32, remotePort: UInt16, guest: UInt32, guestPort: UInt16,
                            sequence: UInt32, acknowledging: UInt32?) -> [UInt8] {
        // 14 + 20 + 20 bytes, padded to the Ethernet minimum.
        var frame = [UInt8](repeating: 0, count: 60)
        frame.withUnsafeMutableBytes { raw in
            let out = ByteView(raw)
            let guestMAC = network.guestMAC.value
            let fromMAC = from.value
            for k in 0..<6 {
                out[k] = UInt8(truncatingIfNeeded: guestMAC >> UInt64(40 - 8 * k))
                out[6 + k] = UInt8(truncatingIfNeeded: fromMAC >> UInt64(40 - 8 * k))
            }
            out.set16(12, 0x0800)
            out[14] = 0x45
            out.set16(16, 40)
            out.set16(20, 0x4000)
            out[22] = 64
            out[23] = 6
            out.set32(26, remote)
            out.set32(30, guest)
            EgressWire.setIPv4Checksum(out, ip: 14, length: 20)
            out.set16(34, remotePort)
            out.set16(36, guestPort)
            out.set32(38, sequence)
            out.set32(42, acknowledging ?? 0)
            out[46] = 0x50
            out[47] = acknowledging == nil ? 0x04 : 0x14
            EgressWire.setTCPChecksum(out, l4: 34, length: 20, src: remote, dst: guest)
        }
        return frame
    }

    private func dhcpOut(_ f: ByteView, ip: IPv4, now: Date) -> Outbound {
        let bootp = ip.l4 + 8
        guard ip.l4Length >= 8 + EgressWire.bootpMinimum, f[bootp] == 1, f[bootp + 1] == 1, f[bootp + 2] == 6,
            f.mac(bootp + EgressWire.bootpChaddr) == network.guestMAC
        else { return deny(.spoofed, now: now) }
        guard ip.src == 0 || ip.src == lease else { return deny(.spoofed, now: now) }
        // No relay agent, and the client address is none or the lease.
        let clientAddress = f.u32(bootp + 12)
        guard f.u32(bootp + 24) == 0, clientAddress == 0 || clientAddress == lease else {
            return deny(.spoofed, now: now)
        }
        guard ip.dst == 0xFFFF_FFFF || ip.dst == network.gateway else {
            return deny(.hostSubnet, proto: .udp, ip: DNSLearner.dotted(ip.dst), port: 67, now: now)
        }
        if ip.dst == 0xFFFF_FFFF, !f.mac(0).isGroup { return deny(.spoofed, now: now) }
        if ip.dst == network.gateway, f.mac(0) != gatewayMAC { return deny(.spoofed, now: now) }
        return .forward
    }

    /// A guest segment from port 22 to the Mac: passes only for a connection the Mac opened.
    /// Never a SYN alone; a SYN+ACK only while the Mac's SYN is unanswered, acknowledging it.
    /// A closing connection is not kept alive by the guest.
    private func sshReply(_ f: ByteView, ip: IPv4, hostPort: UInt16, now: Date) -> Bool {
        let flags = ip.tcpFlags(f)
        guard var flow = hostFlows[hostPort], flags & 0x02 == 0 || flags & 0x10 != 0 else { return false }
        if flags & 0x02 != 0 {
            guard !flow.established, f.u32(ip.l4 + 8) == flow.hostSequence &+ 1 else { return false }
        }
        if !flow.closing { flow.lastSeen = now }
        if flags & 0x05 != 0 { flow.closing = true }
        hostFlows[hostPort] = flow
        return true
    }

    private func dnsQuery(_ f: ByteView, ip: IPv4, sport: UInt16, now: Date) -> Outbound {
        let length = Int(f.u16(ip.l4 + 4))
        guard length >= 8, length <= ip.l4Length else { return deny(.malformed, now: now) }
        let dns = f.slice(ip.l4 + 8, length - 8)
        switch EgressWire.parseQuery(dns) {
        case .malformed:
            return deny(.malformed, proto: .udp, ip: DNSLearner.dotted(ip.dst), port: 53, now: now)
        case .invalidName(_, let end, let opt):
            report(.invalidName, proto: .udp, ip: DNSLearner.dotted(ip.dst), port: 53, now: now)
            return .reply(nxdomainFrame(f, ip: ip, dns: dns, questionEnd: end, opt: opt, sport: sport))
        case .query(let id, let question, let end, let opt):
            guard let learnAs = allowedName(for: question.name, now: now) else {
                report(.name(question.name), proto: .udp, ip: DNSLearner.dotted(ip.dst), port: 53, now: now)
                return .reply(nxdomainFrame(f, ip: ip, dns: dns, questionEnd: end, opt: opt, sport: sport))
            }
            let via = learnAs == question.name ? nil : question.name
            if let via, !Self.aliasQueryTypes.contains(question.type) {
                report(.aliasQueryType(parent: learnAs, type: question.type), proto: .udp, ip: DNSLearner.dotted(ip.dst),
                       port: 53, via: via, now: now)
                return .reply(nxdomainFrame(f, ip: ip, dns: dns, questionEnd: end, opt: opt, sport: sport))
            }
            if pending.count >= Self.maxPendingQueries {
                expirePending(now: now)
                if pending.count >= Self.maxPendingQueries,
                    let oldest = pending.min(by: { $0.value.sent < $1.value.sent })?.key
                {
                    pending[oldest] = nil
                }
            }
            pending[PendingKey(port: sport, id: id)] = Pending(question: question, learnAs: learnAs, via: via, sent: now)
            // A large EDNS size would invite answers that only fit in fragments, which are dropped.
            if let opt, dns.u16(opt + 3) > Self.maxEDNSSize {
                dns.set16(opt + 3, Self.maxEDNSSize)
                EgressWire.setUDPChecksum(f, l4: ip.l4, length: length, src: ip.src, dst: ip.dst)
            }
            return .forward
        }
    }

    private func nxdomainFrame(_ f: ByteView, ip: IPv4, dns: ByteView, questionEnd: Int, opt: Int?, sport: UInt16)
        -> [UInt8]
    {
        let payload = EgressWire.nxdomain(query: dns, questionEnd: questionEnd, opt: opt, negativeTTL: Self.negativeTTL)
        let udpLength = 8 + payload.count
        let total = 20 + udpLength
        var frame = [UInt8](repeating: 0, count: 14 + total)
        frame.withUnsafeMutableBytes { raw in
            let out = ByteView(raw)
            let guest = network.guestMAC.value
            let from = f.mac(0).value
            for k in 0..<6 {
                out[k] = UInt8(truncatingIfNeeded: guest >> UInt64(40 - 8 * k))
                out[6 + k] = UInt8(truncatingIfNeeded: from >> UInt64(40 - 8 * k))
            }
            out.set16(12, 0x0800)
            out[14] = 0x45
            out.set16(16, UInt16(total))
            out.set16(20, 0x4000)
            out[22] = 64
            out[23] = 17
            out.set32(26, network.gateway)
            out.set32(30, ip.src)
            EgressWire.setIPv4Checksum(out, ip: 14, length: 20)
            out.set16(34, 53)
            out.set16(36, sport)
            out.set16(38, UInt16(udpLength))
            for (i, byte) in payload.enumerated() { out[42 + i] = byte }
            EgressWire.setUDPChecksum(out, l4: 34, length: udpLength, src: network.gateway, dst: ip.src)
        }
        return frame
    }

    // MARK: - Uplink → guest

    /// True when the frame may reach the guest. A DNS answer is changed in place (TTLs clamped,
    /// checksum updated).
    func inbound(_ frame: inout [UInt8], now: Date) -> Bool {
        frame.withUnsafeMutableBytes { inbound(ByteView($0), now: now) }
    }

    func inbound(_ f: ByteView, now: Date) -> Bool {
        guard f.count >= 14 else { return false }
        let destination = f.mac(0)
        guard destination == network.guestMAC || destination == .broadcast else { return false }
        switch f.u16(12) {
        case 0x0806: return arpIn(f)
        case 0x0800: return ipv4In(f, broadcast: destination == .broadcast, now: now)
        default: return false
        }
    }

    private func arpIn(_ f: ByteView) -> Bool {
        guard f.count >= 42, f.u16(14) == 1, f.u16(16) == 0x0800, f[18] == 6, f[19] == 4 else { return false }
        let op = f.u16(20)
        let sender = f.u32(28)
        let target = f.u32(38)
        guard op == 1 || op == 2, sender == network.gateway, f.mac(22) == f.mac(6) else { return false }
        guard target == network.gateway || (lease != nil && target == lease) else { return false }
        gatewayMAC = f.mac(22)
        return true
    }

    private func ipv4In(_ f: ByteView, broadcast: Bool, now: Date) -> Bool {
        guard let ip = IPv4(f), ip.udpLengthMatches(f), !ip.hasOptions else { return false }
        if ip.proto == 17, ip.src == network.gateway, ip.l4Length >= 8, f.u16(ip.l4) == 67, f.u16(ip.l4 + 2) == 68 {
            return dhcpIn(f, ip: ip)
        }
        guard !broadcast, let lease, ip.dst == lease else { return false }
        guard let ports = ip.ports(f) else { return false }
        if ip.src == network.gateway {
            if ip.proto == 17, ports.src == 53 { return dnsAnswer(f, ip: ip, guestPort: ports.dst, now: now) }
            if ip.proto == 6, ports.dst == 22, ip.l4Length >= 20 { return sshFromHost(f, ip: ip, hostPort: ports.src, now: now) }
            return false
        }
        guard !network.contains(ip.src) else { return false }
        let key = FlowKey(proto: ip.proto, guestPort: ports.dst, remote: ip.src, remotePort: ports.src)
        // One lookup, updated in place (the hot path).
        guard let index = flows.index(forKey: key), flows.values[index].tls != .refused else { return false }
        Self.record(&flows.values[index], in: ip, f, now: now)
        return true
    }

    /// Counts a forwarded packet of an open flow (guest → Internet with `out`, back with `in`):
    /// its bytes, the time, and a FIN or RST that starts the flow's close.
    private static func record(_ flow: inout Flow, out ip: IPv4, _ f: ByteView, now: Date) {
        flow.bytesOut += UInt64(ip.totalLength)
        touch(&flow, ip, f, now: now)
    }

    private static func record(_ flow: inout Flow, in ip: IPv4, _ f: ByteView, now: Date) {
        flow.bytesIn += UInt64(ip.totalLength)
        touch(&flow, ip, f, now: now)
        guard ip.proto == 6, ip.l4Length >= 20 else { return }
        let header = Int(f[ip.l4 + 12] >> 4) * 4
        guard header >= 20, header <= ip.l4Length else { return }
        let flags = ip.tcpFlags(f)
        let next = f.u32(ip.l4 + 4) &+ UInt32(ip.l4Length - header) &+ UInt32(flags & 0x01)
            &+ UInt32(flags >> 1 & 0x01)
        // Serial arithmetic (RFC 1982): an older retransmission does not move it back.
        if let known = flow.guestReceiveNext, Int32(bitPattern: next &- known) <= 0 { return }
        flow.guestReceiveNext = next
    }

    private static func touch(_ flow: inout Flow, _ ip: IPv4, _ f: ByteView, now: Date) {
        flow.lastSeen = now
        if ip.proto == 6, ip.tcpFlags(f) & 0x05 != 0 { flow.closing = true }
    }

    private func dhcpIn(_ f: ByteView, ip: IPv4) -> Bool {
        let bootp = ip.l4 + 8
        guard ip.l4Length >= 8 + EgressWire.bootpMinimum, f[bootp] == 2,
            f.mac(bootp + EgressWire.bootpChaddr) == network.guestMAC
        else { return false }
        let message = f.slice(bootp, ip.l4Length - 8)
        if EgressWire.dhcpMessageType(message) == 5 {
            let offered = f.u32(bootp + 16)
            guard isUsableLease(offered) else { return false }
            lease = offered
        }
        return true
    }

    private func isUsableLease(_ address: UInt32) -> Bool {
        network.contains(address) && address != network.gateway && address != network.subnet
            && address != network.subnetBroadcast
    }

    private func sshFromHost(_ f: ByteView, ip: IPv4, hostPort: UInt16, now: Date) -> Bool {
        let flags = ip.tcpFlags(f)
        if flags & 0x02 != 0, flags & 0x10 == 0 {
            if hostFlows[hostPort] == nil, hostFlows.count >= Self.maxHostFlows,
                let oldest = hostFlows.min(by: { $0.value.lastSeen < $1.value.lastSeen })?.key
            {
                hostFlows[oldest] = nil
            }
            hostFlows[hostPort] = HostFlow(lastSeen: now, hostSequence: f.u32(ip.l4 + 4))
            return true
        }
        guard var flow = hostFlows[hostPort] else { return false }
        if flags & 0x10 != 0 { flow.established = true }
        if !flow.closing { flow.lastSeen = now }
        if flags & 0x05 != 0 { flow.closing = true }
        hostFlows[hostPort] = flow
        return true
    }

    private func dnsAnswer(_ f: ByteView, ip: IPv4, guestPort: UInt16, now: Date) -> Bool {
        let length = Int(f.u16(ip.l4 + 4))
        guard length >= 20, length <= ip.l4Length else { return false }
        let dns = f.slice(ip.l4 + 8, length - 8)
        let key = PendingKey(port: guestPort, id: dns.u16(0))
        guard let query = pending[key], now.timeIntervalSince(query.sent) < Self.queryTimeout else { return false }
        guard let answer = EgressWire.readAnswer(dns, question: query.question, maxTTL: Self.forwardedMaxTTL)
        else { return false }
        pending[key] = nil
        // The name (or the one it is an alias of) may have been removed since the query left.
        guard decision.allows(name: query.learnAs) else { return false }
        if !answer.addresses.isEmpty {
            decision.learn(name: query.learnAs, addresses: answer.addresses.map(DNSLearner.dotted),
                           ttl: answer.ttl, now: now)
            if let alias = query.via { rememberVia(answer.addresses, alias: alias, parent: query.learnAs, ttl: answer.ttl, now: now) }
        }
        learnAliases(answer.aliases.prefix(Self.maxAliasesPerAnswer), of: query.learnAs, ttl: answer.aliasTTL,
                     now: now)
        EgressWire.setUDPChecksum(f, l4: ip.l4, length: length, src: ip.src, dst: ip.dst)
        return true
    }

    // MARK: - Policy and housekeeping

    /// Applies a new policy: names it no longer allows are forgotten (`EgressDecision.apply`) and
    /// their open flows are cut, so their next frames, both ways, are dropped: one cut report per
    /// domain. A flow already closing (FIN or RST seen) just ends.
    ///
    /// The guest is told: for each cut TCP flow that has had data from the server, a reset at the
    /// next sequence number the guest expects is returned, for the caller to send to the guest;
    /// and for `cutMemory` any segment the guest sends on a cut flow is answered with a reset.
    /// Without them a program waiting for data would hang until its own TCP timeout.
    @discardableResult
    func apply(_ policy: EgressPolicy, now: Date) -> [[UInt8]] {
        decision.apply(policy)
        forgetAliases { !policy.allows($0.name) }
        cutFlows = cutFlows.filter { !policy.allows($0.value.domain) }
        var resets: [[UInt8]] = []
        for (key, flow) in flows where !policy.allows(flow.domain) {
            flows[key] = nil
            if flow.tls == .refused { continue }
            // A closing flow is reported as ended, not cut; a TCP one is still reset below: one
            // side's FIN does not stop the other from sending (a half-closed download).
            if flow.closing {
                end(key, flow, now: now)
            } else {
                pendingCuts[flow.domain, default: Totals(since: now, key: key)].add(flow, key)
            }
            guard key.proto == 6 else { continue }
            if cutFlows.count < Self.maxFlows { cutFlows[key] = CutMark(domain: flow.domain, since: now) }
            if let sequence = flow.guestReceiveNext, let gatewayMAC, let lease {
                resets.append(resetFrame(
                    from: gatewayMAC, remote: key.remote, remotePort: key.remotePort, guest: lease,
                    guestPort: key.guestPort, sequence: sequence, acknowledging: nil))
            }
        }
        flushLifecycle(now: now)
        return resets
    }

    /// Ends idle and closed flows (reporting them), reports the progress of long ones, and drops
    /// expired queries, report marks and learned entries.
    func sweep(now: Date) {
        for (key, flow) in flows {
            if isExpired(flow, proto: key.proto, now: now) {
                flows[key] = nil
                end(key, flow, now: now)
            } else if flow.tls != .refused, now.timeIntervalSince(flow.lastReported) >= Self.progressInterval {
                flows[key]?.lastReported = now
                var event = EgressEvent(
                    kind: .progress(domain: flow.domain, bytesOut: flow.bytesOut, bytesIn: flow.bytesIn),
                    proto: EgressProto(ipProtocol: key.proto), ip: DNSLearner.dotted(key.remote), port: key.remotePort)
                event.via = flow.via
                emit(event, now: now)
            }
        }
        flushLifecycle(now: now)
        if now.timeIntervalSince(budgetWindow) >= 1 { flushSuppressed() }
        hostFlows = hostFlows.filter { _, flow in
            now.timeIntervalSince(flow.lastSeen) < (flow.closing ? Self.closingTimeout : Self.tcpIdleTimeout)
        }
        expirePending(now: now)
        cutFlows = cutFlows.filter { now.timeIntervalSince($0.value.since) < Self.cutMemory }
        forgetAliases { now >= $0.expiry }
        viaByAddress = viaByAddress.filter { now < $0.value.expiry }
        lastReport = lastReport.filter { keepsMark($0.value, now: now) }
        decision.learner.purge(now: now)
    }

    private func isExpired(_ flow: Flow, proto: UInt8, now: Date) -> Bool {
        let idle = now.timeIntervalSince(flow.lastSeen)
        if flow.closing { return idle >= Self.closingTimeout }
        return idle >= (proto == 6 ? Self.tcpIdleTimeout : Self.udpIdleTimeout)
    }

    /// Merges the end of `flow` into the pending ends (reported by `flushLifecycle` once their
    /// window is over): per destination while the table has room, then per domain, then all.
    private func end(_ key: FlowKey, _ flow: Flow, now: Date) {
        // A flow refused for its server name was reported then; it never was an allowed flow.
        guard flow.tls != .refused else { return }
        let exact = EndKey(domain: flow.domain, proto: key.proto, remote: key.remote, remotePort: key.remotePort)
        let perDomain = EndKey(domain: flow.domain, proto: nil, remote: nil, remotePort: nil)
        let target: EndKey
        if pendingEnds[exact] != nil || pendingEnds.count < Self.maxPendingEnds {
            target = exact
        } else if pendingEnds[perDomain] != nil || pendingEnds.count < Self.maxPendingEnds + Self.maxMergedDomains {
            target = perDomain
        } else {
            target = EndKey(domain: nil, proto: nil, remote: nil, remotePort: nil)
        }
        pendingEnds[target, default: Totals(since: now, key: key)].add(flow, key)
    }

    /// Reports pending cuts at once and pending ends whose window is over, within
    /// `maxLifecycleEventsPerSecond`; what does not fit waits for the next call (the sweep).
    private func flushLifecycle(now: Date) {
        rollBudget(now: now)
        for (domain, totals) in pendingCuts {
            guard lifecycleBudgetUsed < Self.maxLifecycleEventsPerSecond else { return }
            pendingCuts[domain] = nil
            lifecycleBudgetUsed += 1
            events(Self.event(.denied(.cut(domain: domain, bytesOut: totals.bytesOut, bytesIn: totals.bytesIn,
                                            count: totals.count)), totals))
        }
        for (key, totals) in pendingEnds where now.timeIntervalSince(totals.since) >= Self.endWindow {
            guard lifecycleBudgetUsed < Self.maxLifecycleEventsPerSecond else { return }
            pendingEnds[key] = nil
            lifecycleBudgetUsed += 1
            events(Self.event(.ended(domain: key.domain, bytesOut: totals.bytesOut, bytesIn: totals.bytesIn,
                                     count: totals.count), totals))
        }
    }

    private static func event(_ kind: EgressEvent.Kind, _ totals: Totals) -> EgressEvent {
        var event = EgressEvent(kind: kind, proto: totals.proto.map(EgressProto.init(ipProtocol:)) ?? .other,
                                ip: totals.remote.map(DNSLearner.dotted), port: totals.remotePort)
        event.via = totals.via
        return event
    }

    /// Reports everything still held, for the relay's shutdown: every open flow ends, merged
    /// ends and cuts go out whatever their window and the budget, held repeats are reported
    /// (one report standing for them all: itself plus `repeats`), and the pending summary.
    func flushAll(now: Date) {
        for (key, flow) in flows {
            flows[key] = nil
            end(key, flow, now: now)
        }
        for (domain, totals) in pendingCuts {
            events(Self.event(.denied(.cut(domain: domain, bytesOut: totals.bytesOut, bytesIn: totals.bytesIn,
                                            count: totals.count)), totals))
        }
        pendingCuts = [:]
        for (key, totals) in pendingEnds {
            events(Self.event(.ended(domain: key.domain, bytesOut: totals.bytesOut, bytesIn: totals.bytesIn,
                                     count: totals.count), totals))
        }
        pendingEnds = [:]
        for (event, mark) in lastReport where mark.repeats > 0 {
            var held = event
            held.repeats = mark.repeats - 1
            events(held)
        }
        lastReport = [:]
        flushSuppressed()
    }

    /// Full table: expired flows go, then (still full) the least recently seen eighth.
    private func makeRoom(now: Date) {
        sweep(now: now)
        guard flows.count >= Self.maxFlows else { return }
        let victims = flows.sorted { $0.value.lastSeen < $1.value.lastSeen }.prefix(Self.maxFlows / 8)
        for (key, flow) in victims {
            flows[key] = nil
            end(key, flow, now: now)
        }
    }

    // MARK: - CNAME aliases

    /// The allowed name a query for `name` is learned under: `name` itself when the policy
    /// allows it, else an allowed name it is a live alias of; nil when refused.
    private func allowedName(for name: String, now: Date) -> String? {
        if decision.allows(name: name) { return name }
        guard let key = DomainPattern.normalizedQueryName(name) else { return nil }
        return aliases[key]?.first { now < $0.expiry && decision.allows(name: $0.name) }?.name
    }

    /// Records each target as an alias of `parent` for the chain's TTL, clamped to
    /// `aliasMinTTL`...`DNSLearner.maxTTL`. Only called for answers to forwarded queries.
    private func learnAliases(_ targets: ArraySlice<String>, of parent: String, ttl: UInt32, now: Date) {
        guard !targets.isEmpty else { return }
        let life = min(max(TimeInterval(ttl), Self.aliasMinTTL), DNSLearner.maxTTL)
        let expiry = now.addingTimeInterval(life)
        for target in targets {
            guard let key = DomainPattern.normalizedQueryName(target), key != parent else { continue }
            if aliases[key] == nil, aliases.count >= Self.maxAliases {
                forgetAliases { now >= $0.expiry }
                if aliases.count >= Self.maxAliases,
                    let soonest = aliases.min(by: { latest($0.value) < latest($1.value) })?.key
                {
                    aliases[soonest] = nil
                }
            }
            var parents = aliases[key, default: []].filter { $0.name != parent && now < $0.expiry }
            parents.insert(AliasParent(name: parent, expiry: expiry), at: 0)
            aliases[key] = Array(parents.prefix(Self.maxParentsPerAlias))
        }
    }

    /// Remembers that `addresses` were learned through `alias` of `parent` (bounded; only for
    /// naming flows, never for deciding).
    private func rememberVia(_ addresses: [UInt32], alias: String, parent: String, ttl: UInt32, now: Date) {
        let life = min(max(TimeInterval(ttl), DNSLearner.minTTL), DNSLearner.maxTTL)
        for address in addresses {
            if viaByAddress[address] == nil, viaByAddress.count >= Self.maxViaAddresses {
                viaByAddress = viaByAddress.filter { now < $0.value.expiry }
                if viaByAddress.count >= Self.maxViaAddresses { viaByAddress.removeAll() }
            }
            viaByAddress[address] = Via(alias: alias, parent: parent, expiry: now.addingTimeInterval(life))
        }
    }

    /// The alias `address` was learned through for `domain`, if live.
    private func via(of address: UInt32, domain: String, now: Date) -> String? {
        guard let via = viaByAddress[address], via.parent == domain, now < via.expiry else { return nil }
        return via.alias
    }

    private func latest(_ parents: [AliasParent]) -> Date {
        parents.map(\.expiry).max() ?? .distantPast
    }

    private func forgetAliases(where drop: (AliasParent) -> Bool) {
        for (key, parents) in aliases {
            let kept = parents.filter { !drop($0) }
            aliases[key] = kept.isEmpty ? nil : kept
        }
    }

    private func expirePending(now: Date) {
        pending = pending.filter { now.timeIntervalSince($0.value.sent) < Self.queryTimeout }
    }

    // MARK: - Reports

    /// Drops the frame and reports `denial` (at most once per `reportInterval` for the same
    /// kind, protocol, destination and port).
    private func deny(_ denial: EgressDenial, proto: EgressProto = .other, ip: String? = nil, port: UInt16? = nil,
                      now: Date) -> Outbound
    {
        report(denial, proto: proto, ip: ip, port: port, now: now)
        return .drop
    }

    /// Reports `denial` at most once per `reportInterval` for the same kind, protocol,
    /// destination and port; the repeats in between are counted and ride on the next report.
    private func report(_ denial: EgressDenial, proto: EgressProto, ip: String?, port: UInt16?, via: String? = nil,
                        now: Date)
    {
        var event = EgressEvent(kind: .denied(denial), proto: proto, ip: ip, port: port)
        event.via = via
        if let mark = lastReport[event], now.timeIntervalSince(mark.last) < Self.reportInterval {
            lastReport[event]?.repeats += 1
            return
        }
        let held = lastReport[event]?.repeats ?? 0
        if lastReport[event] == nil, lastReport.count >= Self.maxReportKeys {
            lastReport = lastReport.filter { now.timeIntervalSince($0.value.last) < Self.reportInterval }
            if lastReport.count >= Self.maxReportKeys { lastReport.removeAll() }
        }
        lastReport[event] = ReportMark(last: now)
        var reported = event
        reported.repeats = held
        emit(reported, now: now)
    }

    /// A mark stays for its interval, and longer while it holds repeats for the next report.
    private func keepsMark(_ mark: ReportMark, now: Date) -> Bool {
        let age = now.timeIntervalSince(mark.last)
        return age < Self.reportInterval || (mark.repeats > 0 && age < Self.repeatMemory)
    }

    /// A new second: reports what the last one left out and renews every budget.
    private func rollBudget(now: Date) {
        guard now.timeIntervalSince(budgetWindow) >= 1 else { return }
        flushSuppressed()
        budgetWindow = now
        budgetUsed = 0
        flowBudgetUsed = 0
        lifecycleBudgetUsed = 0
        noiseBudgetUsed = 0
    }

    /// Hands a denial or a progress report on within its pool's budget (`maxEventsPerSecond`,
    /// `maxFlowEventsPerSecond`); beyond it, only counts it. Ends and cuts never come here
    /// (`flushLifecycle`).
    private func emit(_ event: EgressEvent, now: Date) {
        rollBudget(now: now)
        switch event.pool {
        case .progress:
            guard flowBudgetUsed < Self.maxFlowEventsPerSecond else {
                flowBudgetSuppressed += 1
                return
            }
            flowBudgetUsed += 1
        case .noise:
            guard noiseBudgetUsed < Self.maxNoiseEventsPerSecond else {
                noiseBudgetSuppressed += 1
                return
            }
            noiseBudgetUsed += 1
        case .denial, .lifecycle:
            guard budgetUsed < Self.maxEventsPerSecond else {
                budgetSuppressed += 1
                return
            }
            budgetUsed += 1
        }
        events(event)
    }

    private func flushSuppressed() {
        guard budgetSuppressed > 0 || flowBudgetSuppressed > 0 || noiseBudgetSuppressed > 0 else { return }
        events(EgressEvent(
            kind: .suppressed(blocks: budgetSuppressed, flows: flowBudgetSuppressed, noise: noiseBudgetSuppressed),
            proto: .other, ip: nil, port: nil))
        budgetSuppressed = 0
        flowBudgetSuppressed = 0
        noiseBudgetSuppressed = 0
    }
}

/// The parts of a well-formed, unfragmented IPv4 packet in an Ethernet frame.
private struct IPv4 {
    let proto: UInt8
    let src: UInt32
    let dst: UInt32
    let totalLength: Int
    /// Offset of the transport header in the frame, and its length (up to the packet's end, not
    /// the frame's: Ethernet padding is ignored).
    let l4: Int
    let l4Length: Int
    /// The header holds options (longer than 20 bytes).
    var hasOptions: Bool { l4 - 14 > 20 }

    /// Nil unless version 4, header length 20–60 within the packet, total length within the
    /// frame, and neither "more fragments" nor a fragment offset.
    init?(_ f: ByteView) {
        guard f.count >= 34 else { return nil }
        let versionAndLength = f[14]
        let headerLength = Int(versionAndLength & 0x0F) * 4
        let total = Int(f.u16(16))
        guard versionAndLength >> 4 == 4, headerLength >= 20, total >= headerLength, 14 + total <= f.count,
            f.u16(20) & 0x3FFF == 0
        else { return nil }
        proto = f[23]
        src = f.u32(26)
        dst = f.u32(30)
        totalLength = total
        l4 = 14 + headerLength
        l4Length = total - headerLength
    }

    /// False for UDP whose own length is not exactly the rest of the packet (true otherwise).
    func udpLengthMatches(_ f: ByteView) -> Bool {
        proto != 17 || l4Length < 8 || Int(f.u16(l4 + 4)) == l4Length
    }

    /// Source and destination ports of a TCP (full 20-byte header) or UDP (8-byte header) packet.
    func ports(_ f: ByteView) -> (src: UInt16, dst: UInt16)? {
        switch proto {
        case 6: guard l4Length >= 20 else { return nil }
        case 17: guard l4Length >= 8 else { return nil }
        default: return nil
        }
        return (f.u16(l4), f.u16(l4 + 2))
    }

    /// The TCP flags byte (FIN 0x01, SYN 0x02, RST 0x04, ACK 0x10); call only for TCP.
    func tcpFlags(_ f: ByteView) -> UInt8 {
        l4Length >= 20 ? f[l4 + 13] : 0
    }
}

extension EgressEvent {
    /// One line for a block in the UI language (`nido start` prints it on stderr) or a summary of
    /// what was left out, nil for an allowed flow, its progress or its end. Names and addresses come from validated parsing (letters, digits, `-`, `_`,
    /// dots, IP text): no control characters. Exception: a server name refused by the TLS check
    /// may carry any printable ASCII (0x21–0x7E), every other byte shown as `?`.
    public var blockDescription: String? {
        if case .uplinkLost(let reason) = kind { return Self.uplinkLostMessage(reason: reason) }
        if case .suppressed(let blocks, let flows, let noise) = kind {
            return Self.suppressedDescription(blocks: blocks, flows: flows, noise: noise)
        }
        guard case .denied(let denial) = kind else { return nil }
        let destination = [ip, port.map(String.init)].compactMap { $0 }.joined(separator: ":")
        let line = description(denial, transport: proto.rawValue, destination: destination)
        guard let line, repeats > 0 else { return line }
        return L10n.string("\(line) (seen \(repeats) more times before)")
    }

    /// "5 more blocks not shown", or the counts listed ("2 more blocks and 3 more flows not shown";
    /// "left out: 1 more block and 3 more flows" when the first count is 1, so that languages
    /// agreeing with the first item stay right); blocks are named when nothing else is.
    private static func suppressedDescription(blocks: Int, flows: Int, noise: Int) -> String {
        let showBlocks = blocks > 0 || (flows == 0 && noise == 0)
        switch (showBlocks, flows > 0, noise > 0) {
        case (true, false, false): return L10n.string("\(blocks) more blocks not shown")
        case (false, true, false): return L10n.string("\(flows) more flows not shown")
        case (false, false, true): return L10n.string("\(noise) more local packets (multicast, broadcast) not shown")
        default:
            var parts: [String] = []
            let first = showBlocks ? blocks : flows
            if showBlocks { parts.append(L10n.string("\(blocks) more blocks")) }
            if flows > 0 { parts.append(L10n.string("\(flows) more flows")) }
            if noise > 0 { parts.append(L10n.string("\(noise) more local packets (multicast, broadcast)")) }
            let listed = parts.formatted(.list(type: .and).locale(L10n.locale))
            if first == 1 { return L10n.string("left out: \(listed)") }
            return L10n.string("\(listed) not shown")
        }
    }

    private func description(_ denial: EgressDenial, transport: String, destination: String) -> String? {
        let to = destination.isEmpty ? nil : destination
        switch denial {
        case .verdict(.denyDomain(let domain)):
            if let to { return L10n.string("blocked \(transport) to \(to): \(domain) isn’t an allowed domain") }
            return L10n.string("blocked \(transport): \(domain) isn’t an allowed domain")
        case .verdict(.denyProto):
            if let to { return L10n.string("blocked \(transport) to \(to): only TCP and UDP can go out") }
            return L10n.string("blocked \(transport): only TCP and UDP can go out")
        case .verdict:
            if let to { return L10n.string("blocked \(transport) to \(to): address never resolved for an allowed domain") }
            return L10n.string("blocked \(transport): address never resolved for an allowed domain")
        case .name(let name):
            return L10n.string("blocked the name \(name): it isn’t an allowed domain")
        case .invalidName:
            return L10n.string("blocked a DNS query with an invalid name")
        case .aliasQueryType(let parent, let type):
            let type = String(type)
            if let via {
                return L10n.string("blocked a DNS query of type \(type) for \(via) (an alias of \(parent)): an alias gets only A, AAAA, CNAME and HTTPS")
            }
            return L10n.string("blocked a DNS query of type \(type) for an alias of \(parent): an alias gets only A, AAAA, CNAME and HTTPS")
        case .dnsBypass:
            if let to { return L10n.string("blocked DNS to \(to): only Nido’s DNS is allowed") }
            return L10n.string("blocked DNS: only Nido’s DNS is allowed")
        case .hostSubnet:
            if let to { return L10n.string("blocked \(transport) to \(to): only DHCP, DNS and SSH can reach the Mac") }
            return L10n.string("blocked \(transport): only DHCP, DNS and SSH can reach the Mac")
        case .broadcast:
            if let to { return L10n.string("blocked multicast or broadcast to \(to)") }
            return L10n.string("blocked multicast or broadcast")
        case .ipv6:
            if let to { return L10n.string("blocked IPv6 to \(to)") }
            return L10n.string("blocked IPv6")
        case .spoofed:
            if let to { return L10n.string("blocked a packet to \(to) with a source address other than the VM’s") }
            return L10n.string("blocked a packet with a source address other than the VM’s")
        case .malformed:
            return L10n.string("blocked an unrecognized packet")
        case .cut(let domain, _, _, let count) where count > 1:
            switch (proto == .other ? nil : transport, to) {
            case (let shown?, let to?):
                return L10n.string("stopped \(count) \(shown) flows to \(domain) at \(to): \(domain) was removed from the allowed domains")
            case (let shown?, nil):
                return L10n.string("stopped \(count) \(shown) flows to \(domain): \(domain) was removed from the allowed domains")
            case (nil, let to?):
                return L10n.string("stopped \(count) flows to \(domain) at \(to): \(domain) was removed from the allowed domains")
            case (nil, nil):
                return L10n.string("stopped \(count) flows to \(domain): \(domain) was removed from the allowed domains")
            }
        case .cut(let domain, _, _, _):
            if let to { return L10n.string("stopped \(transport) to \(to): \(domain) was removed from the allowed domains") }
            return L10n.string("stopped \(transport): \(domain) was removed from the allowed domains")
        }
    }
}
