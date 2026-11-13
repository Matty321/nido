// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCore

private func serverName(_ bytes: [UInt8]) -> EgressWire.ServerName {
    var copy = bytes
    return copy.withUnsafeMutableBytes { EgressWire.serverName(ByteView($0)) }
}

/// A small deterministic generator (SplitMix64), so a fuzz failure can be replayed. Shared by the
/// fuzz tests of the SNI parser and of the filter.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Parsing of the server name in the first segment of a TLS connection.
@Suite struct EgressSNITests {
    private static let grease = Wire.tlsExtension(0x0A0A, [])
    private static let groups = Wire.tlsExtension(10, Wire.be16(4) + Wire.be16(29) + Wire.be16(23))
    private static let alpn = Wire.tlsExtension(16, Wire.be16(3) + [2] + Array("h2".utf8))

    @Test func validClientHelloGivesItsServerName() {
        #expect(serverName(Wire.clientHello(sni: "deb.debian.org")) == .sni("deb.debian.org"))
        #expect(serverName(Wire.clientHello(sni: "deb.debian.org", recordVersion: 0x0303)) == .sni("deb.debian.org"))
        #expect(serverName(Wire.clientHello(sni: "deb.debian.org", sessionID: 0, cipherSuites: 1))
                    == .sni("deb.debian.org"))
    }

    @Test func serverNameAmongOtherExtensions() {
        let hello = Wire.clientHello(sni: "example.org", before: [Self.grease, Self.groups, Self.alpn],
                                     after: [Self.alpn, Self.grease])
        #expect(serverName(hello) == .sni("example.org"))
    }

    @Test func noServerNameIsAbsent() {
        #expect(serverName(Wire.clientHello(sni: nil)) == .absent)
        #expect(serverName(Wire.clientHello(sni: nil, before: [Self.grease, Self.groups, Self.alpn])) == .absent)
        // No extensions at all (the list's length field missing): a valid old-style ClientHello.
        var bare = Wire.clientHello(sni: nil)
        bare.removeLast(2)
        bare[4] -= 2
        bare[8] -= 2
        #expect(serverName(bare) == .absent)
    }

    /// The first `host_name` entry of the list is the name; other name types are skipped.
    @Test func firstHostNameEntryWins() {
        let list = Wire.serverNameExtension([(7, Array("ignored".utf8)), (0, Array("first.example".utf8)),
                                             (0, Array("second.example".utf8))])
        let hello = Wire.clientHello(sni: nil, before: [Self.groups, list])
        #expect(serverName(hello) == .sni("first.example"))
        let onlyOther = Wire.clientHello(sni: nil, before: [Wire.serverNameExtension([(7, [1, 2, 3])])])
        #expect(serverName(onlyOther) == .absent)
    }

    /// Bytes outside printable ASCII are shown as "?": such a name never matches a pattern.
    @Test func unprintableBytesNeverSurvive() {
        let list = Wire.serverNameExtension([(0, Array("deb.debian.org".utf8) + [0x00, 0x1B, 0xE2, 0x84, 0xAA])])
        let hello = Wire.clientHello(sni: nil, before: [list])
        #expect(serverName(hello) == .sni("deb.debian.org?????"))
    }

    @Test func notTLSIsRecognized() {
        #expect(serverName([]) == .notTLS)
        #expect(serverName(Array("GET / HTTP/1.1\r\nHost: deb.debian.org\r\n\r\n".utf8)) == .notTLS)
        var appData = Wire.clientHello(sni: "deb.debian.org")
        appData[0] = 23
        #expect(serverName(appData) == .notTLS)
        var serverHello = Wire.clientHello(sni: "deb.debian.org")
        serverHello[5] = 2
        #expect(serverName(serverHello) == .notTLS)
        var badVersion = Wire.clientHello(sni: "deb.debian.org")
        badVersion[1] = 2
        #expect(serverName(badVersion) == .notTLS)
        // SSLv2-style hello.
        #expect(serverName([0x80, 0x2E, 0x01, 0x03, 0x01]) == .notTLS)
    }

    /// Every cut of a valid ClientHello: never a crash, never another name; the name only once
    /// it is whole in the segment, and "absent" before.
    @Test func everyTruncationIsAbsentUntilTheNameIsWhole() {
        let hello = Wire.clientHello(sni: "deb.debian.org", before: [Self.grease, Self.groups], after: [Self.alpn])
        let nameEnd = hello.count - Self.alpn.count
        for length in 1..<hello.count {
            let result = serverName(Array(hello.prefix(length)))
            if length >= nameEnd {
                #expect(result == .sni("deb.debian.org"), "length \(length)")
            } else {
                #expect(result == .absent, "length \(length)")
            }
        }
    }

    /// Lengths beyond their container (record, handshake, extension list, extension, name list)
    /// never pass for a name and never trap.
    @Test func oversizedLengthsAreRefusedOrAbsent() {
        let hello = Wire.clientHello(sni: "deb.debian.org")
        // Record and handshake longer than the segment: the name is still read from what is there.
        var longRecord = hello
        longRecord[3] = 0xFF
        longRecord[4] = 0xFF
        #expect(serverName(longRecord) == .sni("deb.debian.org"))
        var longHandshake = hello
        longHandshake[6] = 0xFF
        #expect(serverName(longHandshake) == .sni("deb.debian.org"))

        // A session id over 32 bytes is no ClientHello.
        var longSession = hello
        longSession[43] = 0xFF
        #expect(serverName(longSession) == .notTLS)

        // The name's own length past the end of its list: not TLS.
        let nameLengthAt = hello.count - 16
        var longName = hello
        longName[nameLengthAt] = 0x7F
        #expect(serverName(longName) == .notTLS)

        // The extension list longer than the handshake, or the extension longer than the list:
        // not TLS.
        var longList = hello
        longList[hello.count - 25] = 0x7F
        #expect(serverName(longList) == .notTLS)
        var longExtension = hello
        longExtension[hello.count - 21] = 0x7F
        #expect(serverName(longExtension) == .notTLS)
        // The name list longer than its extension: not TLS.
        var longNameList = hello
        longNameList[hello.count - 19] = 0x7F
        #expect(serverName(longNameList) == .notTLS)

        // A record shorter than the handshake: the rest would be in the next record (absent).
        var shortRecord = hello
        shortRecord[3] = 0
        shortRecord[4] = 20
        #expect(serverName(shortRecord) == .absent)

        // A huge name is returned whole (the policy refuses it), bounded by the segment.
        let huge = String(repeating: "a", count: 300) + ".deb.debian.org"
        #expect(serverName(Wire.clientHello(sni: huge)) == .sni(huge))
        // An empty host name is no valid ClientHello.
        let empty = Wire.clientHello(sni: nil, before: [Wire.serverNameExtension([(0, [])])])
        #expect(serverName(empty) == .notTLS)
    }

    @Test func randomBytesAndMutationsNeverTrap() {
        var generator = SplitMix(state: 0x5EED_0007)
        for _ in 0..<20000 {
            let length = Int.random(in: 0...600, using: &generator)
            var bytes = (0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }
            if !bytes.isEmpty, Bool.random(using: &generator) { bytes[0] = 22 }
            if bytes.count > 5, Bool.random(using: &generator) { bytes[5] = 1 }
            _ = serverName(bytes)
        }
        let hello = Wire.clientHello(sni: "deb.debian.org", before: [Self.grease, Self.groups], after: [Self.alpn])
        for _ in 0..<20000 {
            var bytes = hello
            for _ in 0..<Int.random(in: 1...4, using: &generator) {
                bytes[Int.random(in: 0..<bytes.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
            }
            bytes = Array(bytes.prefix(Int.random(in: 0...bytes.count, using: &generator)))
            _ = serverName(bytes)
        }
    }
}
