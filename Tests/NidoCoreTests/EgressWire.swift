// SPDX-License-Identifier: Apache-2.0
import Foundation
@testable import NidoCore

/// Builders of synthetic Ethernet frames for the relay's filter tests: IPv4/UDP/TCP with valid
/// checksums, ARP, DHCP and DNS messages.
enum Wire {
    static let guestMAC: [UInt8] = [0x52, 0x54, 0x00, 0xAA, 0xBB, 0xCC]
    static let gatewayMAC: [UInt8] = [0x5E, 0x00, 0x00, 0x00, 0x00, 0x01]
    static let otherMAC: [UInt8] = [0x52, 0x54, 0x00, 0x11, 0x22, 0x33]
    static let broadcastMAC: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]

    static func ip(_ text: String) -> UInt32 {
        var address = in_addr()
        precondition(inet_pton(AF_INET, text, &address) == 1, text)
        return UInt32(bigEndian: address.s_addr)
    }

    static func be16(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xFF)] }
    static func be32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }
    static func u16(_ bytes: [UInt8], _ i: Int) -> UInt16 { UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]) }
    static func u32(_ bytes: [UInt8], _ i: Int) -> UInt32 {
        UInt32(u16(bytes, i)) << 16 | UInt32(u16(bytes, i + 2))
    }

    static func sum(_ bytes: [UInt8], initial: UInt32 = 0) -> UInt32 {
        var total = initial
        var i = 0
        while i + 1 < bytes.count {
            total += UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1])
            i += 2
        }
        if i < bytes.count { total += UInt32(bytes[i]) << 8 }
        return total
    }

    static func fold(_ value: UInt32) -> UInt16 {
        var total = value
        while total >> 16 != 0 { total = (total & 0xFFFF) + (total >> 16) }
        return UInt16(total)
    }

    // MARK: - Layers

    static func eth(dst: [UInt8], src: [UInt8], type: UInt16, _ payload: [UInt8]) -> [UInt8] {
        dst + src + be16(type) + payload
    }

    /// An IPv4 packet with a valid header checksum. `fragment` is the flags/offset word (DF set).
    static func ipv4(src: UInt32, dst: UInt32, proto: UInt8, _ payload: [UInt8], fragment: UInt16 = 0x4000,
                     options: [UInt8] = []) -> [UInt8]
    {
        precondition(options.count % 4 == 0)
        let headerLength = 20 + options.count
        var header: [UInt8] = [0x40 | UInt8(headerLength / 4), 0x00] + be16(UInt16(headerLength + payload.count))
            + [0x12, 0x34] + be16(fragment) + [64, proto, 0, 0] + be32(src) + be32(dst) + options
        let checksum = ~fold(sum(header))
        header[10] = UInt8(checksum >> 8)
        header[11] = UInt8(checksum & 0xFF)
        return header + payload
    }

    static func pseudoSum(src: UInt32, dst: UInt32, proto: UInt8, length: Int) -> UInt32 {
        sum(be32(src) + be32(dst) + [0, proto] + be16(UInt16(length)))
    }

    static func udp(src: UInt32, dst: UInt32, sport: UInt16, dport: UInt16, _ payload: [UInt8],
                    options: [UInt8] = []) -> [UInt8] {
        var segment = be16(sport) + be16(dport) + be16(UInt16(8 + payload.count)) + [0, 0] + payload
        var checksum = ~fold(sum(segment, initial: pseudoSum(src: src, dst: dst, proto: 17, length: segment.count)))
        if checksum == 0 { checksum = 0xFFFF }
        segment[6] = UInt8(checksum >> 8)
        segment[7] = UInt8(checksum & 0xFF)
        return ipv4(src: src, dst: dst, proto: 17, segment, options: options)
    }

    static let fin: UInt8 = 0x01, syn: UInt8 = 0x02, rst: UInt8 = 0x04, ack: UInt8 = 0x10

    static func tcp(src: UInt32, dst: UInt32, sport: UInt16, dport: UInt16, flags: UInt8, _ payload: [UInt8] = [],
                    seq: UInt32 = 1, ack: UInt32 = 0, options: [UInt8] = []) -> [UInt8]
    {
        let segment = be16(sport) + be16(dport) + be32(seq) + be32(ack) + [0x50, flags] + be16(65535) + [0, 0, 0, 0]
            + payload
        return ipv4(src: src, dst: dst, proto: 6, segment, options: options)
    }

    static func icmpEcho(src: UInt32, dst: UInt32) -> [UInt8] {
        ipv4(src: src, dst: dst, proto: 1, [8, 0, 0, 0, 0, 1, 0, 1])
    }

    static func arp(op: UInt16, senderMAC: [UInt8], senderIP: UInt32, targetMAC: [UInt8] = [0, 0, 0, 0, 0, 0],
                    targetIP: UInt32) -> [UInt8]
    {
        be16(1) + be16(0x0800) + [6, 4] + be16(op) + senderMAC + be32(senderIP) + targetMAC + be32(targetIP)
    }

    /// A BOOTP/DHCP message: op 1 (request) or 2 (reply), DHCP message type `type` (1 discover,
    /// 3 request, 5 ACK, 6 NAK).
    static func dhcp(op: UInt8, chaddr: [UInt8], yiaddr: UInt32 = 0, type: UInt8, ciaddr: UInt32 = 0,
                     giaddr: UInt32 = 0) -> [UInt8] {
        var message: [UInt8] = [op, 1, 6, 0] + be32(0xCAFE) + [0, 0, 0x80, 0] + be32(ciaddr) + be32(yiaddr)
            + be32(0) + be32(giaddr)
        message += chaddr + [UInt8](repeating: 0, count: 10)
        message += [UInt8](repeating: 0, count: 192)
        message += be32(0x6382_5363)
        message += [53, 1, type, 255]
        return message
    }

    // MARK: - DNS

    /// The wire form of a dotted name (labels taken as raw bytes).
    static func name(_ text: String) -> [UInt8] {
        var bytes: [UInt8] = []
        for label in text.split(separator: ".") {
            bytes.append(UInt8(label.utf8.count))
            bytes += Array(label.utf8)
        }
        return bytes + [0]
    }

    static func dnsQuery(id: UInt16, name: [UInt8], type: UInt16 = 1, flags: UInt16 = 0x0100,
                         additional: [[UInt8]] = []) -> [UInt8]
    {
        be16(id) + be16(flags) + be16(1) + be16(0) + be16(0) + be16(UInt16(additional.count)) + name + be16(type)
            + be16(1) + additional.flatMap { $0 }
    }

    static func rr(owner: [UInt8], type: UInt16, ttl: UInt32, _ rdata: [UInt8], klass: UInt16 = 1) -> [UInt8] {
        owner + be16(type) + be16(klass) + be32(ttl) + be16(UInt16(rdata.count)) + rdata
    }

    static func a(_ owner: [UInt8], _ address: String, ttl: UInt32 = 300) -> [UInt8] {
        rr(owner: owner, type: 1, ttl: ttl, be32(ip(address)))
    }

    /// EDNS OPT pseudo-record: its TTL field holds flags, never a TTL.
    static let opt: [UInt8] = [0] + be16(41) + be16(1232) + be32(0x0000_8000) + be16(0)

    /// An OPT record advertising `size` bytes of UDP payload.
    static func opt(size: UInt16) -> [UInt8] { [0] + be16(41) + be16(size) + be32(0) + be16(0) }

    /// Pointer to the question name (offset 12).
    static let questionPointer: [UInt8] = [0xC0, 0x0C]

    static func dnsAnswer(id: UInt16, name: [UInt8], type: UInt16 = 1, answers: [[UInt8]],
                          authority: [[UInt8]] = [], additional: [[UInt8]] = [], rcode: UInt16 = 0) -> [UInt8]
    {
        be16(id) + be16(0x8180 | rcode) + be16(1) + be16(UInt16(answers.count)) + be16(UInt16(authority.count))
            + be16(UInt16(additional.count)) + name + be16(type) + be16(1)
            + (answers + authority + additional).flatMap { $0 }
    }

    // MARK: - TLS

    /// One TLS extension: type, length, data.
    static func tlsExtension(_ type: UInt16, _ data: [UInt8]) -> [UInt8] {
        be16(type) + be16(UInt16(data.count)) + data
    }

    /// A `server_name` extension holding `entries` (name type, name bytes) in its list.
    static func serverNameExtension(_ entries: [(type: UInt8, name: [UInt8])]) -> [UInt8] {
        let list = entries.flatMap { [$0.type] + be16(UInt16($0.name.count)) + $0.name }
        return tlsExtension(0, be16(UInt16(list.count)) + list)
    }

    /// A TLS record holding a ClientHello: `before` and `after` are extensions around the
    /// `server_name` one (none when `sni` is nil).
    static func clientHello(sni: String?, before: [[UInt8]] = [], after: [[UInt8]] = [], sessionID: Int = 32,
                            cipherSuites: Int = 16, recordVersion: UInt16 = 0x0301) -> [UInt8]
    {
        let server = sni.map { [serverNameExtension([(0, Array($0.utf8))])] } ?? []
        let extensions = (before + server + after).flatMap { $0 }
        var body = be16(0x0303) + [UInt8](repeating: 0xA5, count: 32)
        body += [UInt8(sessionID)] + [UInt8](repeating: 0x5A, count: sessionID)
        body += be16(UInt16(cipherSuites * 2)) + (0..<cipherSuites).flatMap { be16(0x1301 + UInt16($0)) }
        body += [1, 0]
        body += be16(UInt16(extensions.count)) + extensions
        let handshake = [1] + be32(UInt32(body.count)).dropFirst() + body
        return [22] + be16(recordVersion) + be16(UInt16(handshake.count)) + handshake
    }

    // MARK: - Checks

    /// True when the TCP checksum of `frame` is valid.
    static func tcpChecksumValid(_ frame: [UInt8]) -> Bool {
        let ihl = Int(frame[14] & 0x0F) * 4
        let l4 = 14 + ihl
        let length = Int(u16(frame, 16)) - ihl
        let segment = Array(frame[l4..<(l4 + length)])
        let pseudo = pseudoSum(src: u32(frame, 26), dst: u32(frame, 30), proto: 6, length: length)
        return fold(sum(segment, initial: pseudo)) == 0xFFFF
    }

    /// True when the IPv4 header checksum of `frame` is valid.
    static func ipChecksumValid(_ frame: [UInt8]) -> Bool {
        let ihl = Int(frame[14] & 0x0F) * 4
        return fold(sum(Array(frame[14..<(14 + ihl)]))) == 0xFFFF
    }

    /// True when the UDP checksum of `frame` is valid (or absent).
    static func udpChecksumValid(_ frame: [UInt8]) -> Bool {
        let ihl = Int(frame[14] & 0x0F) * 4
        let l4 = 14 + ihl
        let length = Int(u16(frame, l4 + 4))
        if u16(frame, l4 + 6) == 0 { return true }
        let segment = Array(frame[l4..<(l4 + length)])
        let pseudo = pseudoSum(src: u32(frame, 26), dst: u32(frame, 30), proto: 17, length: length)
        return fold(sum(segment, initial: pseudo)) == 0xFFFF
    }
}
