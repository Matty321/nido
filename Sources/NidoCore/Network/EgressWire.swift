// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation

/// A 48-bit Ethernet address.
public struct EgressMAC: Hashable, Sendable, CustomStringConvertible {
    public let value: UInt64

    public static let broadcast = EgressMAC(value: 0xFFFF_FFFF_FFFF)

    init(value: UInt64) { self.value = value & 0xFFFF_FFFF_FFFF }

    public init(bytes: [UInt8]) {
        precondition(bytes.count == 6, "EgressMAC: six bytes")
        self.init(value: bytes.reduce(0) { $0 << 8 | UInt64($1) })
    }

    /// `aa:bb:cc:dd:ee:ff` (one or two hex digits per octet, any case), or nil.
    public init?(_ text: String) {
        let octets = text.split(separator: ":", omittingEmptySubsequences: false)
        guard octets.count == 6 else { return nil }
        var value: UInt64 = 0
        for octet in octets {
            guard (1...2).contains(octet.utf8.count), let byte = UInt8(octet, radix: 16) else { return nil }
            value = value << 8 | UInt64(byte)
        }
        self.init(value: value)
    }

    /// The group bit: multicast and broadcast destinations.
    var isGroup: Bool { value >> 40 & 1 == 1 }

    public var description: String {
        (0..<6).map { String(format: "%02x", UInt8(truncatingIfNeeded: value >> UInt64(40 - 8 * $0))) }
            .joined(separator: ":")
    }
}

/// A bounds-checked window on a frame buffer. Every access is checked in every build, so a
/// parsing bug never reads or writes outside the frame: it traps instead, which ends the whole
/// process (`nido start`, or the app with every VM it runs). The parsers check lengths before
/// every access, so a trap is a bug, never a guest-chosen outcome.
struct ByteView {
    private let raw: UnsafeMutableRawBufferPointer
    private let start: Int
    let count: Int

    init(_ raw: UnsafeMutableRawBufferPointer) {
        self.raw = raw
        start = 0
        count = raw.count
    }

    private init(raw: UnsafeMutableRawBufferPointer, start: Int, count: Int) {
        precondition(start >= 0 && count >= 0 && start + count <= raw.count, "ByteView: window")
        self.raw = raw
        self.start = start
        self.count = count
    }

    /// The `length` bytes at `offset` (which must be inside this view).
    func slice(_ offset: Int, _ length: Int) -> ByteView {
        precondition(offset >= 0 && length >= 0 && offset + length <= count, "ByteView: slice")
        return ByteView(raw: raw, start: start + offset, count: length)
    }

    subscript(_ i: Int) -> UInt8 {
        get {
            precondition(i >= 0 && i < count, "ByteView: index")
            return raw[start + i]
        }
        nonmutating set {
            precondition(i >= 0 && i < count, "ByteView: index")
            raw[start + i] = newValue
        }
    }

    func u16(_ i: Int) -> UInt16 { UInt16(self[i]) << 8 | UInt16(self[i + 1]) }
    func u32(_ i: Int) -> UInt32 { UInt32(u16(i)) << 16 | UInt32(u16(i + 2)) }
    func mac(_ i: Int) -> EgressMAC {
        precondition(i >= 0 && i + 6 <= count, "ByteView: mac")
        var value: UInt64 = 0
        for k in 0..<6 { value = value << 8 | UInt64(raw[start + i + k]) }
        return EgressMAC(value: value)
    }

    func set16(_ i: Int, _ value: UInt16) {
        self[i] = UInt8(value >> 8)
        self[i + 1] = UInt8(value & 0xFF)
    }

    func set32(_ i: Int, _ value: UInt32) {
        set16(i, UInt16(value >> 16))
        set16(i + 2, UInt16(value & 0xFFFF))
    }

    /// One's complement sum of the bytes `[offset, offset + length)` added to `initial`
    /// (not folded).
    func sum(_ offset: Int, _ length: Int, initial: UInt32 = 0) -> UInt32 {
        precondition(offset >= 0 && length >= 0 && offset + length <= count, "ByteView: sum")
        var total = UInt64(initial)
        var i = start + offset
        let end = i + length
        while i + 1 < end {
            total += UInt64(raw[i]) << 8 | UInt64(raw[i + 1])
            i += 2
        }
        if i < end { total += UInt64(raw[i]) << 8 }
        while total >> 16 != 0 { total = (total & 0xFFFF) + (total >> 16) }
        return UInt32(total)
    }

    func bytes(_ offset: Int, _ length: Int) -> [UInt8] {
        precondition(offset >= 0 && length >= 0 && offset + length <= count, "ByteView: bytes")
        return Array(UnsafeRawBufferPointer(rebasing: raw[(start + offset)..<(start + offset + length)]))
    }
}

/// Wire formats the relay reads and writes: checksums, DNS and DHCP. Pure functions over a frame.
enum EgressWire {
    static func fold(_ value: UInt32) -> UInt16 {
        var total = value
        while total >> 16 != 0 { total = (total & 0xFFFF) + (total >> 16) }
        return UInt16(total)
    }

    /// Sum of the UDP/TCP pseudo-header.
    static func pseudoHeaderSum(src: UInt32, dst: UInt32, proto: UInt8, length: Int) -> UInt32 {
        (src >> 16) + (src & 0xFFFF) + (dst >> 16) + (dst & 0xFFFF) + UInt32(proto) + UInt32(length)
    }

    /// Writes a fresh UDP checksum for the segment of `length` bytes at `l4`.
    static func setUDPChecksum(_ frame: ByteView, l4: Int, length: Int, src: UInt32, dst: UInt32) {
        frame.set16(l4 + 6, 0)
        var checksum = ~fold(frame.sum(l4, length, initial: pseudoHeaderSum(src: src, dst: dst, proto: 17, length: length)))
        if checksum == 0 { checksum = 0xFFFF }
        frame.set16(l4 + 6, checksum)
    }

    /// Writes a fresh IPv4 header checksum for the header of `length` bytes at `ip`.
    static func setIPv4Checksum(_ frame: ByteView, ip: Int, length: Int) {
        frame.set16(ip + 10, 0)
        frame.set16(ip + 10, ~fold(frame.sum(ip, length)))
    }

    static func ipv6Text(_ frame: ByteView, at offset: Int) -> String {
        var address = in6_addr()
        let bytes = frame.bytes(offset, 16)
        withUnsafeMutableBytes(of: &address) { $0.copyBytes(from: bytes) }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { return "?" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Writes a fresh TCP checksum for the segment of `length` bytes at `l4`.
    static func setTCPChecksum(_ frame: ByteView, l4: Int, length: Int, src: UInt32, dst: UInt32) {
        frame.set16(l4 + 16, 0)
        frame.set16(l4 + 16, ~fold(frame.sum(l4, length, initial: pseudoHeaderSum(src: src, dst: dst, proto: 6, length: length))))
    }

    // MARK: - TLS

    /// What the first segment of a TLS connection says about the server name.
    enum ServerName: Equatable {
        /// The first `host_name` of the ClientHello's `server_name` extension. Every byte outside
        /// printable ASCII (`!`–`~`) is shown as `?`, so such a name never matches a pattern and
        /// never carries control characters; it is never shortened (a cut name could match).
        case sni(String)
        /// A ClientHello, or a prefix of one, without a server name in the segment: no
        /// extension, none of type `server_name`, or the segment (or the record) ends before it.
        case absent
        /// Not a TLS handshake record holding a ClientHello, or one whose lengths contradict
        /// each other.
        case notTLS
    }

    /// The server name in `payload`, the data of the first segment a guest sends on a TCP
    /// connection: a TLS record (type 22, version 3.x) starting a ClientHello (handshake type 1).
    /// Pure and bounded: it walks the lengths of the ClientHello, each checked against its
    /// container (record, handshake, extension list, extension, name list) and against the
    /// segment; it reads only the first record and stops at the first `host_name` entry.
    static func serverName(_ payload: ByteView) -> ServerName {
        guard payload.count >= 1, payload[0] == 22 else { return .notTLS }
        if payload.count >= 2, payload[1] != 3 { return .notTLS }
        guard payload.count >= 5 else { return .absent }
        // What is readable: the segment, or the record when it ends first (a ClientHello spread
        // over several records keeps the rest in the next ones).
        let available = min(payload.count, 5 + Int(payload.u16(3)))
        guard available >= 6 else { return .absent }
        guard payload[5] == 1 else { return .notTLS }
        guard available >= 9 else { return .absent }
        let handshakeEnd = 9 + (Int(payload[6]) << 16 | Int(payload.u16(7)))

        // Version and random.
        var position = 9
        guard position + 34 <= handshakeEnd else { return .notTLS }
        guard position + 34 <= available else { return .absent }
        guard payload[position] == 3 else { return .notTLS }
        position += 34
        // Session id: at most 32 bytes.
        guard position + 1 <= handshakeEnd else { return .notTLS }
        guard position + 1 <= available else { return .absent }
        let sessionID = Int(payload[position])
        guard sessionID <= 32 else { return .notTLS }
        position += 1 + sessionID
        // Cipher suites: a non-empty list of two-byte values.
        guard position + 2 <= handshakeEnd else { return .notTLS }
        guard position + 2 <= available else { return .absent }
        let suites = Int(payload.u16(position))
        guard suites >= 2, suites % 2 == 0 else { return .notTLS }
        position += 2 + suites
        // Compression methods: at least one.
        guard position + 1 <= handshakeEnd else { return .notTLS }
        guard position + 1 <= available else { return .absent }
        let methods = Int(payload[position])
        guard methods >= 1 else { return .notTLS }
        position += 1 + methods
        guard position <= handshakeEnd else { return .notTLS }
        // No extensions at all.
        if position == handshakeEnd { return .absent }

        guard position + 2 <= handshakeEnd else { return .notTLS }
        guard position + 2 <= available else { return .absent }
        let extensionsEnd = position + 2 + Int(payload.u16(position))
        guard extensionsEnd <= handshakeEnd else { return .notTLS }
        position += 2
        while position < extensionsEnd {
            guard position + 4 <= extensionsEnd else { return .notTLS }
            guard position + 4 <= available else { return .absent }
            let type = payload.u16(position)
            let extensionEnd = position + 4 + Int(payload.u16(position + 2))
            guard extensionEnd <= extensionsEnd else { return .notTLS }
            position += 4
            guard type == 0 else {
                position = extensionEnd
                continue
            }
            // server_name: a list of (name type, length, name).
            guard position + 2 <= extensionEnd else { return .notTLS }
            guard position + 2 <= available else { return .absent }
            let listEnd = position + 2 + Int(payload.u16(position))
            guard listEnd <= extensionEnd else { return .notTLS }
            position += 2
            while position < listEnd {
                guard position + 3 <= listEnd else { return .notTLS }
                guard position + 3 <= available else { return .absent }
                let nameType = payload[position]
                let length = Int(payload.u16(position + 1))
                let nameEnd = position + 3 + length
                guard nameEnd <= listEnd else { return .notTLS }
                if nameType == 0 {
                    guard length > 0 else { return .notTLS }
                    guard nameEnd <= available else { return .absent }
                    let shown = (0..<length).map { k -> UInt8 in
                        let byte = payload[position + 3 + k]
                        return (0x21...0x7E).contains(byte) ? byte : UInt8(ascii: "?")
                    }
                    return .sni(String(decoding: shown, as: UTF8.self))
                }
                position = nameEnd
            }
            return .absent
        }
        return .absent
    }

    // MARK: - DNS

    /// A DNS question, its name lowercase.
    struct Question: Hashable {
        let name: String
        let type: UInt16
        let klass: UInt16
    }

    enum Query {
        /// A standard query for one well-formed name. `end` is the offset after the question,
        /// `opt` the offset of its EDNS OPT record, if any.
        case query(id: UInt16, question: Question, end: Int, opt: Int?)
        /// A standard query whose name holds bytes that are not letters, digits, hyphens or
        /// underscores (or is the root): refused with NXDOMAIN. `opt` as for `query`.
        case invalidName(id: UInt16, end: Int, opt: Int?)
        case malformed
    }

    /// True for the bytes a label may hold: `A`–`Z`, `a`–`z`, `0`–`9`, `-`, `_`.
    static func isLabelByte(_ byte: UInt8) -> Bool {
        (0x61...0x7A).contains(byte) || (0x41...0x5A).contains(byte) || (0x30...0x39).contains(byte)
            || byte == 0x2D || byte == 0x5F
    }

    /// The name at `offset` of the DNS message `dns`: lowercase and dotted, or nil inside the
    /// result when a label holds any other byte than `isLabelByte` (any byte >= 0x80 included) or
    /// the name is the root. `end` is the offset after the name where it is written (after its
    /// first pointer). Nil when the name is broken: out of bounds, over 255 bytes, a reserved
    /// label type, a pointer when `allowPointers` is false, or a pointer that does not go back
    /// before every position visited (so it never loops).
    static func readName(_ dns: ByteView, at offset: Int, allowPointers: Bool) -> (name: String?, end: Int)? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(64)
        var position = offset
        var end: Int?
        var lowest = offset
        var wireLength = 0
        var valid = true
        var jumps = 0
        while true {
            guard position >= 0, position < dns.count else { return nil }
            let length = Int(dns[position])
            if length == 0 {
                wireLength += 1
                guard wireLength <= 255 else { return nil }
                break
            }
            switch length & 0xC0 {
            case 0xC0:
                guard allowPointers, position + 1 < dns.count, jumps < 64 else { return nil }
                let target = (length & 0x3F) << 8 | Int(dns[position + 1])
                guard target < lowest else { return nil }
                if end == nil { end = position + 2 }
                lowest = target
                position = target
                jumps += 1
            case 0x00:
                guard position + 1 + length <= dns.count else { return nil }
                wireLength += 1 + length
                guard wireLength <= 255 else { return nil }
                if !bytes.isEmpty { bytes.append(0x2E) }
                for i in 1...length {
                    let byte = dns[position + i]
                    if isLabelByte(byte) {
                        bytes.append((0x41...0x5A).contains(byte) ? byte | 0x20 : byte)
                    } else {
                        valid = false
                    }
                }
                position += 1 + length
                lowest = min(lowest, position)
            default:
                return nil
            }
        }
        let name = valid && !bytes.isEmpty ? String(decoding: bytes, as: UTF8.self) : nil
        return (name, end ?? position + 1)
    }

    /// Parses a query the guest sends: header with QR 0 and opcode 0, exactly one question, no
    /// answer or authority records, class IN, a name without compression, and nothing after the
    /// question but at most one EDNS OPT record (root owner, no options: its data length is 0, so
    /// a query carries nothing beyond its question and the EDNS header).
    static func parseQuery(_ dns: ByteView) -> Query {
        guard dns.count >= 17 else { return .malformed }
        let flags = dns.u16(2)
        guard flags & 0x8000 == 0, flags >> 11 & 0xF == 0 else { return .malformed }
        guard dns.u16(4) == 1, dns.u16(6) == 0, dns.u16(8) == 0, dns.u16(10) <= 1 else { return .malformed }
        guard let (name, nameEnd) = readName(dns, at: 12, allowPointers: false), nameEnd + 4 <= dns.count else {
            return .malformed
        }
        let id = dns.u16(0)
        let end = nameEnd + 4
        guard dns.u16(nameEnd + 2) == 1 else { return .malformed }
        var opt: Int?
        if dns.u16(10) == 1 {
            guard end + 11 == dns.count, dns[end] == 0, dns.u16(end + 1) == 41, dns.u16(end + 9) == 0
            else { return .malformed }
            opt = end
        } else {
            guard end == dns.count else { return .malformed }
        }
        guard let name else { return .invalidName(id: id, end: end, opt: opt) }
        return .query(id: id, question: Question(name: name, type: dns.u16(nameEnd), klass: 1), end: end, opt: opt)
    }

    /// Reads an answer to `question`: every TTL above `maxTTL` (answer, authority and additional
    /// records, but not the flags an EDNS OPT record keeps there) is lowered to it in place, and
    /// the answer records are lowered further to the smallest TTL on the path to the learned A
    /// records, so the guest never caches one longer than it is learned.
    /// Returns the A records of the answer section owned by the queried name or by a name its
    /// CNAME chain reaches, with the smallest TTL on that path as the server gave it (before
    /// lowering), and the names of the chain (CNAME targets, in the order reached) with the
    /// smallest CNAME TTL of the chain; nil when the message is not a well-formed response to
    /// exactly that question.
    static func readAnswer(_ dns: ByteView, question: Question, maxTTL: UInt32) -> Answer? {
        guard dns.count >= 12 else { return nil }
        let flags = dns.u16(2)
        guard flags & 0x8000 != 0, flags >> 11 & 0xF == 0, dns.u16(4) == 1 else { return nil }
        let answers = Int(dns.u16(6))
        let total = answers + Int(dns.u16(8)) + Int(dns.u16(10))
        guard let (name, nameEnd) = readName(dns, at: 12, allowPointers: true), nameEnd + 4 <= dns.count,
            name == question.name, dns.u16(nameEnd) == question.type, dns.u16(nameEnd + 2) == question.klass
        else { return nil }
        var offset = nameEnd + 4
        var cnames: [(owner: String, target: String, ttl: UInt32)] = []
        var records: [(owner: String, address: UInt32, ttl: UInt32)] = []
        var answerTTLOffsets: [Int] = []
        for index in 0..<total {
            guard let (owner, ownerEnd) = readName(dns, at: offset, allowPointers: true), ownerEnd + 10 <= dns.count
            else { return nil }
            let type = dns.u16(ownerEnd)
            let klass = dns.u16(ownerEnd + 2)
            let ttl = dns.u32(ownerEnd + 4)
            let length = Int(dns.u16(ownerEnd + 8))
            let data = ownerEnd + 10
            guard data + length <= dns.count else { return nil }
            if type != 41, ttl > maxTTL { dns.set32(ownerEnd + 4, maxTTL) }
            if index < answers { answerTTLOffsets.append(ownerEnd + 4) }
            if index < answers, klass == 1, let owner {
                if type == 1, length == 4 {
                    records.append((owner, dns.u32(data), ttl))
                } else if type == 5 {
                    guard let (target, _) = readName(dns.slice(0, data + length), at: data, allowPointers: true) else {
                        return nil
                    }
                    if let target { cnames.append((owner, target, ttl)) }
                }
            }
            offset = data + length
        }
        var chain: Set<String> = [question.name]
        var targets: [String] = []
        var ttl = UInt32.max
        var changed = true
        while changed {
            changed = false
            for cname in cnames where chain.contains(cname.owner) && !chain.contains(cname.target) {
                chain.insert(cname.target)
                targets.append(cname.target)
                ttl = min(ttl, cname.ttl)
                changed = true
            }
        }
        let used = records.filter { chain.contains($0.owner) }
        guard !used.isEmpty else { return Answer(addresses: [], ttl: 0, aliases: targets, aliasTTL: ttl) }
        let pathTTL = min(ttl, used.map(\.ttl).min() ?? 0)
        for offset in answerTTLOffsets where dns.u32(offset) > pathTTL { dns.set32(offset, pathTTL) }
        return Answer(addresses: used.map(\.address), ttl: pathTTL, aliases: targets, aliasTTL: ttl)
    }

    /// What `readAnswer` takes from an answer.
    struct Answer {
        /// A records on the chain, and the smallest TTL on the path to them.
        let addresses: [UInt32]
        let ttl: UInt32
        /// CNAME targets of the chain, in the order reached, and the chain's smallest CNAME TTL
        /// (`UInt32.max` without CNAMEs).
        let aliases: [String]
        let aliasTTL: UInt32
    }

    /// The DNS payload of an NXDOMAIN answer to the query whose header and question are
    /// `query[0..<questionEnd]`: same id and question, RD copied, RA set, and an SOA under the
    /// root whose TTL and minimum are `negativeTTL`, so the guest caches the refusal only that long;
    /// plus one OPT record when the query had one (at offset `opt`).
    static func nxdomain(query: ByteView, questionEnd: Int, opt: Int? = nil, negativeTTL: UInt32) -> [UInt8] {
        var dns: [UInt8] = []
        dns.reserveCapacity(questionEnd + 44)
        let flags: UInt16 = 0x8000 | (query.u16(2) & 0x0100) | 0x0080 | 3
        let additional: UInt8 = opt == nil ? 0 : 1
        dns += [query[0], query[1], UInt8(flags >> 8), UInt8(flags & 0xFF), 0, 1, 0, 0, 0, 1, 0, additional]
        dns += query.bytes(12, questionEnd - 12)
        func be32(_ value: UInt32) -> [UInt8] {
            [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
        }
        dns += [0, 0, 6, 0, 1] + be32(negativeTTL) + [0, 22]
        dns += [0, 0] + be32(1) + be32(3600) + be32(600) + be32(86400) + be32(negativeTTL)
        // A query that spoke EDNS gets an EDNS answer (else resolvers such as systemd-resolved
        // decide the server lacks EDNS and degrade): one OPT, UDP size 1232, extended rcode and
        // version 0, the DO bit copied, no options.
        if let opt {
            let doBit = query[opt + 7] & 0x80
            dns += [0, 0, 41, 0x04, 0xD0, 0, 0, doBit, 0, 0, 0]
        }
        return dns
    }

    // MARK: - DHCP

    /// Offset of the hardware address in a BOOTP message, and the smallest message read.
    static let bootpChaddr = 28
    static let bootpMinimum = 240

    /// The DHCP message type (option 53) of the BOOTP message `bootp`, or nil.
    static func dhcpMessageType(_ bootp: ByteView) -> UInt8? {
        guard bootp.count >= bootpMinimum, bootp.u32(236) == 0x6382_5363 else { return nil }
        var offset = bootpMinimum
        while offset < bootp.count {
            let code = bootp[offset]
            if code == 0 {
                offset += 1
                continue
            }
            if code == 255 { return nil }
            guard offset + 1 < bootp.count else { return nil }
            let length = Int(bootp[offset + 1])
            guard offset + 2 + length <= bootp.count else { return nil }
            if code == 53, length >= 1 { return bootp[offset + 2] }
            offset += 2 + length
        }
        return nil
    }
}
