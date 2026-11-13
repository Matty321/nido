// SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Foundation
import Security

/// An OpenPGP v4 RSA public key (RFC 4880 §5.5.2), built in: Nido never imports keys at run time.
public struct OpenPGPPublicKey: Sendable, Equatable {
    /// Modulus and public exponent, big-endian without leading zeros.
    let modulus: [UInt8]
    let exponent: [UInt8]
    /// The v4 fingerprint, 40 uppercase hex digits.
    public let fingerprint: String

    /// `body` is the public-key packet body: version 4, creation time, algorithm 1 (RSA), MPI n, MPI e.
    public init(packetBody body: [UInt8]) throws {
        guard body.count > 6, body.count <= 0xFFFF, body[0] == 4, body[5] == 1 else {
            throw NidoError.downloadFailed(L10n.string("unsupported OpenPGP key"))
        }
        var reader = OpenPGP.Reader(body, from: 6)
        modulus = try reader.mpi()
        exponent = try reader.mpi()
        guard reader.isAtEnd, modulus.count >= 256 else {  // RSA 2048 at least
            throw NidoError.downloadFailed(L10n.string("unsupported OpenPGP key"))
        }
        let prefix: [UInt8] = [0x99, UInt8(body.count >> 8), UInt8(body.count & 0xFF)]
        fingerprint = Insecure.SHA1.hash(data: prefix + body).map { String(format: "%02X", $0) }.joined()
    }
}

/// Detached OpenPGP signatures over a checksum list (Ubuntu's `SHA256SUMS.gpg`), verified without
/// `gpg`: RFC 4880 v4 signatures of a binary document (type 0x00) by an RSA key with SHA-256 or
/// SHA-512, PKCS#1 v1.5 through Security.framework. Anything else is refused: other packet
/// versions, algorithms or signature types, unknown critical subpackets, an expired signature,
/// an issuer fingerprint other than the key's.
public enum OpenPGPSignature {
    /// Largest signature file read.
    public static let maxBytes: UInt64 = 64 << 10

    /// Succeeds when one signature packet of `signature` is a valid signature of `data` by `key`;
    /// returns that signature's creation time (`ImageStore` refuses a list signed before the last
    /// one it accepted). A signature by another key says so: the signer may have changed key, and
    /// only a Nido with the new key built in can verify it.
    @discardableResult
    public static func verify(_ signature: Data, of data: Data, key: OpenPGPPublicKey, now: Date = Date()) throws -> Date {
        try verify(signature, of: data, keys: [key], now: now)
    }

    /// As `verify(_:of:key:now:)`, by any of `keys` (a signer's current key and its announced
    /// successor, so a key change needs no new Nido on the day): a packet naming its issuer is
    /// checked only with the key of that fingerprint, one without an issuer with each key.
    @discardableResult
    public static func verify(_ signature: Data, of data: Data, keys: [OpenPGPPublicKey], now: Date = Date()) throws -> Date {
        let bytes = try OpenPGP.dearmor(signature)
        var offset = 0
        var checked = 0
        var otherIssuer: String?
        while offset < bytes.count {
            let (tag, body, next) = try OpenPGP.packet(bytes, at: offset)
            offset = next
            guard tag == 2 else { continue }
            checked += 1
            // The issuer is a full fingerprint (subpacket 33) or a key ID, its last 16 digits (16).
            let issuer = OpenPGP.issuer(of: body)
            let candidates = issuer.map { issuer in keys.filter { $0.fingerprint.hasSuffix(issuer) } } ?? keys
            for key in candidates {
                if let created = try? verifyPacket(body, data: data, key: key, now: now) {
                    return Date(timeIntervalSince1970: TimeInterval(created))
                }
            }
            if otherIssuer == nil, let issuer, candidates.isEmpty {
                otherIssuer = issuer
            }
        }
        if let otherIssuer {
            throw NidoError.downloadFailed(L10n.string(
                "checksum list signed with a key Nido doesn’t know (\(otherIssuer)): the signing key may have changed, and a newer version of Nido is needed"))
        }
        throw NidoError.downloadFailed(checked == 0
            ? L10n.string("checksum list signature missing")
            : L10n.string("invalid checksum list signature"))
    }

    /// The signature's creation time when valid.
    static func verifyPacket(_ body: [UInt8], data: Data, key: OpenPGPPublicKey, now: Date) throws -> UInt32 {
        func invalid() -> NidoError { .downloadFailed(L10n.string("invalid checksum list signature")) }
        var reader = OpenPGP.Reader(body, from: 0)
        guard try reader.byte() == 4, try reader.byte() == 0x00, try reader.byte() == 1 else { throw invalid() }
        let hashAlgorithm = try reader.byte()
        guard hashAlgorithm == 8 || hashAlgorithm == 10 else { throw invalid() }
        let hashedLength = Int(try reader.uint16())
        let hashed = try reader.bytes(hashedLength)
        let hashedEnd = reader.offset
        let unhashed = try reader.bytes(Int(try reader.uint16()))
        let left16 = try reader.bytes(2)
        var signatureValue = try reader.mpi()
        guard reader.isAtEnd else { throw invalid() }

        // Subpackets: creation time required; an expiry, an issuer, the issuer fingerprint and
        // non-critical others are understood; an unknown critical one makes the signature invalid.
        var created: UInt32?
        var expires: UInt32?
        for (type, critical, value) in try OpenPGP.subpackets(hashed) {
            switch type {
            case 2, 3:
                guard value.count == 4 else { throw invalid() }
                if type == 2 { created = OpenPGP.be32(value) } else { expires = OpenPGP.be32(value) }
            case 33:
                guard value.count == 21, value[0] == 4,
                    value[1...].map({ String(format: "%02X", $0) }).joined() == key.fingerprint
                else { throw invalid() }
            case 16: break
            default: if critical { throw invalid() }
            }
        }
        _ = try OpenPGP.subpackets(unhashed)  // well-formed, otherwise ignored (not signed)
        guard let created else { throw invalid() }
        if let expires, expires > 0, UInt64(created) + UInt64(expires) < UInt64(max(0, now.timeIntervalSince1970)) {
            throw invalid()
        }

        // RFC 4880 §5.2.4: data, the hashed part from the version on, then 0x04 0xFF and its length.
        let prefix = Array(body[0..<hashedEnd])
        let trailer: [UInt8] = [0x04, 0xFF] + withUnsafeBytes(of: UInt32(prefix.count).bigEndian, Array.init)
        let digest: [UInt8]
        let algorithm: SecKeyAlgorithm
        if hashAlgorithm == 10 {
            var hash = SHA512()
            hash.update(data: data); hash.update(data: prefix); hash.update(data: trailer)
            digest = Array(hash.finalize())
            algorithm = .rsaSignatureDigestPKCS1v15SHA512
        } else {
            var hash = SHA256()
            hash.update(data: data); hash.update(data: prefix); hash.update(data: trailer)
            digest = Array(hash.finalize())
            algorithm = .rsaSignatureDigestPKCS1v15SHA256
        }
        guard Array(digest.prefix(2)) == left16 else { throw invalid() }

        // The MPI drops leading zeros: PKCS#1 wants the signature as long as the modulus.
        guard signatureValue.count <= key.modulus.count else { throw invalid() }
        signatureValue = [UInt8](repeating: 0, count: key.modulus.count - signatureValue.count) + signatureValue
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        guard let secKey = SecKeyCreateWithData(Data(OpenPGP.rsaPublicKeyDER(key)) as CFData, attributes as CFDictionary, nil),
            SecKeyVerifySignature(secKey, algorithm, Data(digest) as CFData, Data(signatureValue) as CFData, nil)
        else { throw invalid() }
        return created
    }
}

/// Just enough OpenPGP framing for the two types above.
enum OpenPGP {
    struct Reader {
        let bytes: [UInt8]
        var offset: Int
        init(_ bytes: [UInt8], from offset: Int) { self.bytes = bytes; self.offset = offset }
        var isAtEnd: Bool { offset == bytes.count }

        mutating func byte() throws -> UInt8 { try bytes(1)[0] }
        mutating func uint16() throws -> UInt16 { let b = try bytes(2); return UInt16(b[0]) << 8 | UInt16(b[1]) }
        mutating func bytes(_ count: Int) throws -> [UInt8] {
            guard count >= 0, count <= bytes.count - offset else {
                throw NidoError.downloadFailed(L10n.string("truncated OpenPGP data"))
            }
            defer { offset += count }
            return Array(bytes[offset..<(offset + count)])
        }
        /// An MPI: bit count, then the bytes (leading zeros dropped).
        mutating func mpi() throws -> [UInt8] {
            let bits = Int(try uint16())
            let value = Array(try bytes((bits + 7) / 8).drop { $0 == 0 })
            guard !value.isEmpty else { throw NidoError.downloadFailed(L10n.string("invalid OpenPGP data")) }
            return value
        }
    }

    /// The binary packets of `data`: as they are, or decoded from ASCII armor (RFC 4880 §6.2:
    /// `-----BEGIN PGP SIGNATURE-----`, headers, a blank line, base64, the `=` CRC24 line, the
    /// END line). The CRC is not checked: the signature itself is.
    static func dearmor(_ data: Data) throws -> [UInt8] {
        let begin = "-----BEGIN PGP SIGNATURE-----"
        guard data.starts(with: Data(begin.utf8)) else { return [UInt8](data) }
        // Split on the bytes: as a String, "\r\n" is one Character and would not split on "\n".
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespaces.union(.init(charactersIn: "\r"))) }
        guard let blank = lines.firstIndex(of: ""),
            let end = lines.firstIndex(where: { $0.hasPrefix("-----END PGP SIGNATURE-----") }), blank < end
        else { throw NidoError.downloadFailed(L10n.string("unreadable OpenPGP signature")) }
        let body = lines[(blank + 1)..<end].prefix { !$0.hasPrefix("=") }.joined()
        guard let decoded = Data(base64Encoded: body), !decoded.isEmpty else {
            throw NidoError.downloadFailed(L10n.string("unreadable OpenPGP signature"))
        }
        return [UInt8](decoded)
    }

    /// The packet at `offset`: tag, body, offset of the next one. Old and new formats with a
    /// definite length (no partial lengths: a detached signature never needs them).
    static func packet(_ bytes: [UInt8], at offset: Int) throws -> (tag: UInt8, body: [UInt8], next: Int) {
        var reader = Reader(bytes, from: offset)
        let ctb = try reader.byte()
        guard ctb & 0x80 != 0 else { throw NidoError.downloadFailed(L10n.string("invalid OpenPGP data")) }
        let tag: UInt8
        let length: Int
        if ctb & 0x40 != 0 {
            tag = ctb & 0x3F
            let first = Int(try reader.byte())
            switch first {
            case ..<192: length = first
            case ..<224: length = ((first - 192) << 8) + Int(try reader.byte()) + 192
            case 255: length = Int(be32(try reader.bytes(4)))
            default: throw NidoError.downloadFailed(L10n.string("unsupported OpenPGP data"))
            }
        } else {
            tag = (ctb >> 2) & 0x0F
            switch ctb & 3 {
            case 0: length = Int(try reader.byte())
            case 1: length = Int(try reader.uint16())
            case 2: length = Int(be32(try reader.bytes(4)))
            default: throw NidoError.downloadFailed(L10n.string("unsupported OpenPGP data"))
            }
        }
        let body = try reader.bytes(length)
        return (tag, body, reader.offset)
    }

    /// Signature subpackets (RFC 4880 §5.2.3.1): type without the critical bit, critical, value.
    static func subpackets(_ bytes: [UInt8]) throws -> [(type: UInt8, critical: Bool, value: [UInt8])] {
        var reader = Reader(bytes, from: 0)
        var result: [(UInt8, Bool, [UInt8])] = []
        while !reader.isAtEnd {
            let first = Int(try reader.byte())
            let length: Int
            switch first {
            case ..<192: length = first
            case ..<255: length = ((first - 192) << 8) + Int(try reader.byte()) + 192
            default: length = Int(be32(try reader.bytes(4)))
            }
            guard length >= 1 else { throw NidoError.downloadFailed(L10n.string("invalid OpenPGP data")) }
            let type = try reader.byte()
            result.append((type & 0x7F, type & 0x80 != 0, try reader.bytes(length - 1)))
        }
        return result
    }

    /// The issuer a v4 signature packet names, hashed or not (only for the error message: never
    /// trusted): the fingerprint of subpacket 33 (40 hex digits) or else the key ID of 16 (16).
    static func issuer(of body: [UInt8]) -> String? {
        var reader = Reader(body, from: 0)
        guard (try? reader.byte()) == 4, (try? reader.bytes(3)) != nil,
            let hashedLength = try? reader.uint16(), let hashed = try? reader.bytes(Int(hashedLength)),
            let unhashedLength = try? reader.uint16(), let unhashed = try? reader.bytes(Int(unhashedLength)),
            let packets = try? subpackets(hashed) + subpackets(unhashed)
        else { return nil }
        func hex(_ bytes: ArraySlice<UInt8>) -> String { bytes.map { String(format: "%02X", $0) }.joined() }
        if let full = packets.first(where: { $0.type == 33 && $0.value.count == 21 && $0.value[0] == 4 }) {
            return hex(full.value[1...])
        }
        if let id = packets.first(where: { $0.type == 16 && $0.value.count == 8 }) { return hex(id.value[...]) }
        return nil
    }

    static func be32(_ b: [UInt8]) -> UInt32 {
        b.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// PKCS#1 `RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }` (DER).
    static func rsaPublicKeyDER(_ key: OpenPGPPublicKey) -> [UInt8] {
        func length(_ count: Int) -> [UInt8] {
            if count < 0x80 { return [UInt8(count)] }
            let bytes = withUnsafeBytes(of: UInt32(count).bigEndian, Array.init).drop { $0 == 0 }
            return [0x80 | UInt8(bytes.count)] + bytes
        }
        func integer(_ value: [UInt8]) -> [UInt8] {
            let content = (value.first ?? 0) & 0x80 != 0 ? [0] + value : value
            return [0x02] + length(content.count) + content
        }
        let content = integer(key.modulus) + integer(key.exponent)
        return [0x30] + length(content.count) + content
    }
}

/// The key that signs Ubuntu's cloud image checksum lists: "UEC Image Automatic Signing Key
/// <cdimage@ubuntu.com>", RSA 4096, created 2009-09-15, no expiry. Taken on 2026-11-09 from
/// keyserver.ubuntu.com and checked against the fingerprint Ubuntu publishes; a test recomputes
/// the fingerprint from these bytes.
///
/// `keys` is what the catalog verifies with. When Canonical announces a new signing key, a
/// release adds it next to this one (both accepted), so the lists signed with the new key verify
/// from the day of the switch; a later release removes the old one (docs/SECURITY.md).
public enum UbuntuCloudImageKey {
    public static let fingerprint = "D2EB44626FDDC30B513D5BB71A5D6C4C7DB87C81"

    static let packetBody = """
        BEqwKTUBEAC8V01JGfeYVVlwlcr0dmwF8n+We/lbxwArjR/gZlH7/MJEZnALQHUrDTpD3SkfbsjQgeNt8eS3Jyzoc2r3t2no\
        s4rXPH4kIzAvtqslz6Ns4ZYjoHVkVC2oV8vYbxER+3/lDjTWVII7omtDVvqH33QlqYZ8+bQbs21lZb2ROJIQCiH0YzaqYR0I\
        2SEykBL873V0ygdyW/mCMwniXTLUyGAUV4/28NOzw/6LGvJElJe4UqwQxl/aXtPIJjPka8LA8+nDi5/u6WEgDWgBhLEHvQG1\
        BNdttm3WCjbu4zS3mNfNBidTamZfOaMJUZVYxhOB5kNQqyR4eYqFK/U+305eLrZ05ocadsmcQWkHQVbgt+g4yyFNl56N5Air\
        kFjVtfArkUJfINGgJ7gkSeyqTJK24f33vsIpPwRQ5eFn7H4PwGc0Piym73YLJnlR94LNEG0ceOJ7u1r+WuaesIj+lKIZsG/r\
        RLf7besaMCCtPcimVgEAmBoIdpTpdP3aa54w/dvfSwW47mGY14G5PBk/0MDy2Y5HOeXat3RXpGZZFh7zbwSQ93RhYH3bNPNd\
        5lMu3ZRkYX19FWxoLCi5lx4K3flYhiolZ5i4KxJCoGRobsKjm74Xv2QlvCXYyAk5BnAQCsu5hKZ1sOhQADCcKz1Zbg8JRc3v\
        melaJ/VFvHTzs4hJTUvOowARAQAB
        """

    /// The key; a build whose bytes do not match `fingerprint` stops here (and in the tests).
    public static let key: OpenPGPPublicKey = {
        guard let data = Data(base64Encoded: packetBody), let key = try? OpenPGPPublicKey(packetBody: [UInt8](data)),
            key.fingerprint == fingerprint
        else { preconditionFailure("embedded Ubuntu key is invalid") }
        return key
    }()

    /// The keys a list may be signed with: today only `key`.
    public static let keys: [OpenPGPPublicKey] = [key]
}
