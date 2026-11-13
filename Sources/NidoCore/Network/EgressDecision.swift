// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization

/// The transport of a guest packet, as the relay and the egress log name it.
public enum EgressProto: String, Codable, Sendable {
    case tcp, udp, icmp, other

    /// From the IPv4 header's protocol number.
    public init(ipProtocol: UInt8) {
        switch ipProtocol {
        case 6: self = .tcp
        case 17: self = .udp
        case 1: self = .icmp
        default: self = .other
        }
    }
}

/// What the controlled network does with a new guest flow.
public enum EgressVerdict: Hashable, Sendable {
    /// The address was learned for `domain`, which the policy allows.
    case allow(domain: String)
    /// Nothing allowed is known about the address (never learned, expired or invalid).
    case denyUnknown(ip: String)
    /// A protocol other than TCP/UDP: always denied, whatever the address.
    case denyProto(ip: String, proto: EgressProto)
    /// The address is known only under names the policy does not allow (the newest one given).
    case denyDomain(String)
}

/// The current policy plus the DNS learner, deciding guest flows. Thread-safe: the relay
/// decides on its queue while a reload applies a new policy.
public final class EgressDecision: Sendable {
    public let learner: DNSLearner
    private let current: Mutex<EgressPolicy>

    public init(policy: EgressPolicy, learner: DNSLearner = DNSLearner()) {
        self.learner = learner
        current = Mutex(policy)
    }

    public var policy: EgressPolicy { current.withLock { $0 } }

    /// Replaces the policy and forgets every learned name it no longer allows, so a removed
    /// domain's addresses are unknown from now on.
    public func apply(_ policy: EgressPolicy) {
        current.withLock { $0 = policy }
        learner.forget { !policy.allows($0) }
    }

    /// Learns `name` → `addresses` (see `DNSLearner.learn`) only when the current policy allows
    /// `name`; a name it does not allow is dropped.
    ///
    /// Contract for the relay:
    /// - learn only from upstream answers to queries the relay itself forwarded, matching the
    ///   transaction id, the source port and the question of that query;
    /// - learn the A records under the queried name (not under CNAME targets or other owners);
    /// - never learn from frames the guest sends;
    /// - clamp the TTLs of the answers forwarded to the guest to at most `DNSLearner.maxTTL`, so
    ///   the guest never caches an address longer than it is learned here.
    public func learn(name: String, addresses: [String], ttl: UInt32, now: Date) {
        guard policy.allows(name) else { return }
        learner.learn(name: name, addresses: addresses, ttl: ttl, now: now)
    }

    /// True when the policy allows a DNS query for `name` (to forward and learn it).
    public func allows(name: String) -> Bool {
        policy.allows(name)
    }

    /// The verdict for a new flow to `dstIP` (dotted IPv4). Only TCP and UDP to an address
    /// learned for an allowed name, and not yet expired, pass; any other protocol is
    /// `denyProto`. `port` is not restricted: any port of an allowed name is allowed.
    public func decide(dstIP: String, port: UInt16, proto: EgressProto, now: Date) -> EgressVerdict {
        guard proto == .tcp || proto == .udp else { return .denyProto(ip: dstIP, proto: proto) }
        let names = learner.domains(for: dstIP, now: now)
        guard let newest = names.first else { return .denyUnknown(ip: dstIP) }
        let policy = self.policy
        if let allowed = names.first(where: { policy.allows($0) }) { return .allow(domain: allowed) }
        return .denyDomain(newest)
    }
}
