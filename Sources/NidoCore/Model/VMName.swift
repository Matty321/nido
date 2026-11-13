// SPDX-License-Identifier: Apache-2.0

/// A validated virtual machine name.
///
/// Valid names match `^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$` and never contain `..`.
/// Equality and hashing are case-insensitive.
public struct VMName: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    /// Longest valid name (bytes; valid names are ASCII).
    public static let maxLength = 63

    public init(_ raw: String) throws(NidoError) {
        guard VMName.isValid(raw) else { throw NidoError.invalidName(raw) }
        self.rawValue = raw
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    public static func == (lhs: VMName, rhs: VMName) -> Bool {
        lhs.rawValue.lowercased() == rhs.rawValue.lowercased()
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue.lowercased())
    }

    private static func isValid(_ raw: String) -> Bool {
        let bytes = Array(raw.utf8)
        guard (1...maxLength).contains(bytes.count) else { return false }
        func isAlnum(_ b: UInt8) -> Bool {
            (0x30...0x39).contains(b) || (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b)
        }
        guard isAlnum(bytes[0]) else { return false }
        for (i, b) in bytes.enumerated() {
            guard isAlnum(b) || b == 0x2E || b == 0x5F || b == 0x2D else { return false }
            if b == 0x2E, i > 0, bytes[i - 1] == 0x2E { return false }
        }
        return true
    }
}
