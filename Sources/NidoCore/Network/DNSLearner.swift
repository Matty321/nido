// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import Synchronization

/// What the relay learned from the DNS answers it forwarded: IPv4 address → the names it was
/// returned for, each until its (clamped) TTL runs out. The relay only calls `learn` for names
/// the policy allows; `EgressDecision` checks the policy again on every lookup.
///
/// Hardened against the guest, which chooses the names it asks for:
/// - only public unicast IPv4 addresses are learned (no private, loopback, link-local, CGNAT,
///   multicast, documentation or reserved ranges), so an allowed name that resolves into the
///   Mac's or the LAN's addresses opens nothing;
/// - the table is bounded (`maxAddresses`, `maxNamesPerAddress`, `maxAddressesPerAnswer`): the
///   entries closest to expiry make room for new ones.
///
/// Thread-safe: every method takes one lock.
public final class DNSLearner: Sendable {
    /// Shortest life of a learned entry, whatever the answer's TTL (s): 10 minutes. Programs such
    /// as apt resolve once and reconnect to the same addresses for their whole run, long after a
    /// CDN's TTL of seconds (seen live: a first-boot `apt-get update` refused after 33 s with a
    /// 30 s minimum). Widens nothing: a removed name is forgotten at once, and every lookup
    /// checks the policy again. The guest still caches at most `EgressFilter.forwardedMaxTTL`.
    public static let minTTL: TimeInterval = 600
    /// Longest life of a learned entry (s). The relay should not let the guest cache an answer
    /// for longer than this, or its connections after this time meet an unknown address.
    public static let maxTTL: TimeInterval = 3600
    /// Most addresses held at once.
    public static let maxAddresses = 4096
    /// Most names held for one address (shared CDN addresses); the oldest goes first.
    public static let maxNamesPerAddress = 8
    /// Most addresses taken from one answer.
    public static let maxAddressesPerAnswer = 32

    private struct Learned {
        var learnedAt: Date
        var expiry: Date
    }

    /// Address (host order) → name → when it was last learned and until when it holds.
    private let table = Mutex<[UInt32: [String: Learned]]>([:])

    public init() {}

    /// Records that `name` resolved to `addresses` with `ttl` seconds, clamped to
    /// `[minTTL, maxTTL]`. Learning an entry again extends it, never shortens it. Invalid names,
    /// non-IPv4 and non-public addresses are ignored.
    public func learn(name: String, addresses: [String], ttl: UInt32, now: Date) {
        guard let name = DomainPattern.normalizedQueryName(name) else { return }
        let life = min(max(TimeInterval(ttl), Self.minTTL), Self.maxTTL)
        let expiry = now.addingTimeInterval(life)
        let parsed = addresses.lazy.compactMap(Self.ipv4).filter(Self.isPublicUnicast).prefix(Self.maxAddressesPerAnswer)
        table.withLock { table in
            for address in parsed {
                var names = table[address] ?? [:]
                let previous = names[name]?.expiry ?? .distantPast
                names[name] = Learned(learnedAt: now, expiry: max(previous, expiry))
                if names.count > Self.maxNamesPerAddress,
                    let oldest = names.min(by: { $0.value.learnedAt < $1.value.learnedAt })?.key
                {
                    names[oldest] = nil
                }
                table[address] = names
            }
            if table.count > Self.maxAddresses { Self.makeRoom(&table, now: now) }
        }
    }

    /// The most recently learned name still valid for `ip` (dotted IPv4), or nil.
    public func domain(for ip: String, now: Date) -> String? {
        domains(for: ip, now: now).first
    }

    /// Every name still valid for `ip`, the most recently learned first.
    public func domains(for ip: String, now: Date) -> [String] {
        guard let address = Self.ipv4(ip) else { return [] }
        return table.withLock { table in
            (table[address] ?? [:]).filter { $0.value.expiry > now }
                .sorted { ($0.value.learnedAt, $1.key) > ($1.value.learnedAt, $0.key) }
                .map(\.key)
        }
    }

    /// Forgets every name `pattern` covers (a domain removed from the list).
    public func forget(matching pattern: DomainPattern) {
        forget { pattern.matches($0) }
    }

    /// Forgets every name for which `shouldForget` is true.
    func forget(where shouldForget: (String) -> Bool) {
        table.withLock { table in
            for (address, names) in table {
                let kept = names.filter { !shouldForget($0.key) }
                table[address] = kept.isEmpty ? nil : kept
            }
        }
    }

    /// Drops every expired entry.
    public func purge(now: Date) {
        table.withLock { Self.purge(&$0, now: now) }
    }

    /// Addresses with at least one valid name.
    public func count(now: Date) -> Int {
        table.withLock { table in table.values.filter { $0.values.contains { $0.expiry > now } }.count }
    }

    private static func purge(_ table: inout [UInt32: [String: Learned]], now: Date) {
        for (address, names) in table {
            let kept = names.filter { $0.value.expiry > now }
            if kept.count != names.count { table[address] = kept.isEmpty ? nil : kept }
        }
    }

    /// Purges, then (still over `maxAddresses`) drops the addresses closest to expiry down to
    /// seven eighths of the cap, so a flood does not pay a full scan on every answer.
    private static func makeRoom(_ table: inout [UInt32: [String: Learned]], now: Date) {
        purge(&table, now: now)
        guard table.count > maxAddresses else { return }
        let target = maxAddresses - maxAddresses / 8
        let byExpiry = table.map { (address: $0.key, expiry: $0.value.values.map(\.expiry).max() ?? .distantPast) }
            .sorted { $0.expiry < $1.expiry }
        for entry in byExpiry.prefix(table.count - target) { table[entry.address] = nil }
    }

    // MARK: - Addresses

    /// `text` as a dotted-quad IPv4 address in host order, or nil. Only the canonical spelling
    /// is accepted (four decimal parts, no leading zeros), so one address has one key.
    static func ipv4(_ text: String) -> UInt32? {
        var address = in_addr()
        guard text.utf8.count <= 15, inet_pton(AF_INET, text, &address) == 1 else { return nil }
        let value = UInt32(bigEndian: address.s_addr)
        return dotted(value) == text ? value : nil
    }

    /// The canonical dotted quad of `address` (host order).
    public static func dotted(_ address: UInt32) -> String {
        "\(address >> 24).\(address >> 16 & 0xFF).\(address >> 8 & 0xFF).\(address & 0xFF)"
    }

    /// Public unicast: not in 0/8, 10/8, 100.64/10, 127/8, 169.254/16, 172.16/12, 192.0.0/24,
    /// 192.0.2/24, 192.88.99/24 (6to4 relay), 192.168/16, 198.18/15, 198.51.100/24, 203.0.113/24,
    /// 224/4 (multicast) or
    /// 240/4 (reserved, broadcast).
    static func isPublicUnicast(_ address: UInt32) -> Bool {
        let blocked: [(UInt32, Int)] = [
            (0x0000_0000, 8), (0x0A00_0000, 8), (0x6440_0000, 10), (0x7F00_0000, 8), (0xA9FE_0000, 16),
            (0xAC10_0000, 12), (0xC000_0000, 24), (0xC000_0200, 24), (0xC0A8_0000, 16), (0xC612_0000, 15),
            (0xC633_6400, 24), (0xCB00_7100, 24), (0xC058_6300, 24), (0xE000_0000, 4), (0xF000_0000, 4),
        ]
        return !blocked.contains { network, prefix in
            let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << UInt32(32 - prefix)
            return address & mask == network
        }
    }
}
