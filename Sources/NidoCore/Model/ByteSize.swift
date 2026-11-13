// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Parses and formats human-friendly byte sizes such as `4G` or `512M` (base 1024).
public enum ByteSize {
    /// Binary units: `4 GiB`, `512 MiB`, `1.5 GiB`, `1023 B`; the decimal separator follows the UI
    /// language (`1,5 GiB` in Italian, German, Spanish and French).
    public static func format(_ bytes: UInt64) -> String {
        format(bytes, locale: L10n.locale)
    }

    /// `format(_:)` with the decimal separator of `locale`; the units are the same in every language.
    public static func format(_ bytes: UInt64, locale: Locale) -> String {
        let units: [(String, UInt64)] = [("TiB", 1 << 40), ("GiB", 1 << 30), ("MiB", 1 << 20), ("KiB", 1 << 10)]
        for (suffix, size) in units where bytes >= size {
            if bytes % size == 0 { return "\(bytes / size) \(suffix)" }
            return String(format: "%.1f %@", locale: locale, Double(bytes) / Double(size), suffix)
        }
        return "\(bytes) B"
    }

    /// Parses a non-negative integer with an optional `K`, `M`, `G` or `T` suffix.
    /// A value without suffix is a plain byte count.
    public static func parse(_ s: String) throws(NidoError) -> UInt64 {
        var digits = Substring(s)
        var multiplier: UInt64 = 1
        if let last = digits.last, let m = unit(last) {
            multiplier = m
            digits = digits.dropLast()
        }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = UInt64(digits)
        else { throw .invalidSize(s) }
        let (result, overflow) = value.multipliedReportingOverflow(by: multiplier)
        guard !overflow else { throw .invalidSize(s) }
        return result
    }

    private static func unit(_ c: Character) -> UInt64? {
        switch c {
        case "K", "k": 1 << 10
        case "M", "m": 1 << 20
        case "G", "g": 1 << 30
        case "T", "t": 1 << 40
        default: nil
        }
    }
}
