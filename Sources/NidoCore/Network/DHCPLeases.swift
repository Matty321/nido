// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Resolves a VM's IP address from macOS's DHCP lease database (`/var/db/dhcpd_leases`).
///
/// Pure parsing: no file I/O, no network, no privileges. The caller reads the text.
public enum DHCPLeases {
    public static let defaultURL = URL(fileURLWithPath: "/var/db/dhcpd_leases")

    /// Returns the IP of the lease for `mac` with the highest `lease` expiry; ties go to the later block.
    /// Blocks whose `ip_address` is not an IPv4 literal (`inet_pton(AF_INET)`) and leases that
    /// expired before `now` (a missing expiry counts as expired) are skipped.
    /// Returns `nil` if `mac` is not six hex octets or no valid block matches.
    public static func ipAddress(forMAC mac: String, leases text: String, now: Date = Date()) -> String? {
        guard let target = normalize(mac: mac, octetPrefix: nil) else { return nil }
        let nowSeconds = UInt64(max(0, now.timeIntervalSince1970.rounded(.down)))

        var best: (ip: String, lease: UInt64)?
        var current: [String: String]?

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "{" {
                current = [:]
            } else if line == "}" {
                if let fields = current, let candidate = lease(from: fields, target: target),
                   candidate.lease >= nowSeconds,
                   best.map({ candidate.lease >= $0.lease }) ?? true {
                    best = candidate
                }
                current = nil
            } else if let separator = line.firstIndex(of: "=") {
                let key = line[..<separator].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
                current?[key] = value
            }
        }
        return best?.ip
    }

    /// Builds a candidate from one parsed block, or `nil` if the block is malformed or another MAC.
    private static func lease(from fields: [String: String], target: String) -> (ip: String, lease: UInt64)? {
        guard let ip = fields["ip_address"], isIPv4Literal(ip),
              let hardware = fields["hw_address"],
              let mac = normalize(mac: hardware, octetPrefix: "1,"),
              mac == target
        else { return nil }
        return (ip, expiry(fields["lease"]))
    }

    /// True only for a dotted-quad IPv4 address accepted by `inet_pton(AF_INET, …)` and written
    /// in canonical form (no leading zeros, which other parsers may read as octal).
    static func isIPv4Literal(_ text: String) -> Bool {
        var address = in_addr()
        guard text.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else { return false }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil else { return false }
        let canonical = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: canonical, as: UTF8.self) == text
    }

    /// Parses a hexadecimal `lease` value (`0x...`); missing or unparsable values count as 0.
    private static func expiry(_ value: String?) -> UInt64 {
        guard let raw = value else { return 0 }
        var digits = Substring(raw)
        if digits.hasPrefix("0x") || digits.hasPrefix("0X") {
            digits = digits.dropFirst(2)
        }
        return UInt64(digits, radix: 16) ?? 0
    }

    /// Lowercases a MAC, optionally strips a leading `prefix` (such as `1,`), requires six hex
    /// octets of one or two digits, and removes leading zeros per octet (an all-zero octet becomes `0`).
    private static func normalize(mac: String, octetPrefix: String?) -> String? {
        var body = Substring(mac.lowercased())
        if let prefix = octetPrefix {
            guard body.hasPrefix(prefix) else { return nil }
            body = body.dropFirst(prefix.count)
        }
        let octets = body.split(separator: ":", omittingEmptySubsequences: false)
        guard octets.count == 6 else { return nil }

        var normalized: [String] = []
        normalized.reserveCapacity(6)
        for octet in octets {
            guard (1...2).contains(octet.count), octet.allSatisfy(\.isHexDigit) else { return nil }
            let trimmed = octet.drop(while: { $0 == "0" })
            normalized.append(trimmed.isEmpty ? "0" : String(trimmed))
        }
        return normalized.joined(separator: ":")
    }
}
