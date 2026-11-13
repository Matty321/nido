// SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Foundation

public enum Checksums {
    /// Parses a `SHA512SUMS` file into `[fileName: lowercase hex digest]`.
    /// Lines must be 128 hex chars, a space, then either a space (text mode) or `*` (binary mode), then the name.
    /// Blank or malformed lines are skipped.
    public static func parseSHA512SUMS(_ text: String) -> [String: String] {
        parseSums(text, algorithm: .sha512)
    }

    /// Parses a `SHA512SUMS` or `SHA256SUMS` file (same layout, digests of `algorithm.hexLength`
    /// hex chars; Ubuntu's are in binary mode, `*name`).
    public static func parseSums(_ text: String, algorithm: ChecksumAlgorithm) -> [String: String] {
        let hexLength = algorithm.hexLength
        var result: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = Array(rawLine.utf8)
            guard line.count > hexLength + 2,
                  line[..<hexLength].allSatisfy(isHexDigit),
                  line[hexLength] == UInt8(ascii: " "),
                  line[hexLength + 1] == UInt8(ascii: " ") || line[hexLength + 1] == UInt8(ascii: "*")
            else { continue }
            let name = String(decoding: line[(hexLength + 2)...], as: UTF8.self)
            guard !name.isEmpty else { continue }
            result[name] = String(decoding: line[..<hexLength], as: UTF8.self).lowercased()
        }
        return result
    }

    /// Streams the file and returns its digest (`algorithm`) as lowercase hex.
    public static func digest(of file: URL, algorithm: ChecksumAlgorithm) throws -> String {
        switch algorithm {
        case .sha512: try sha512(of: file)
        case .sha256: try sha256(of: file)
        }
    }

    /// Streams the file in 1 MiB chunks and returns its SHA-256 as lowercase hex.
    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Streams the file in 1 MiB chunks and returns its SHA-512 as lowercase hex.
    public static func sha512(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA512()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func isHexDigit(_ c: UInt8) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66)
    }
}
