// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCore

/// Fixture leases expire in 2024; checks unrelated to expiry run "at" the Unix epoch.
private let epoch = Date(timeIntervalSince1970: 0)

@Suite struct DHCPLeasesTests {
    /// Builds one lease block in the exact `/var/db/dhcpd_leases` layout.
    private func block(name: String = "debian", ip: String, hw: String, lease: String = "0x6717a1b2") -> String {
        "{\n\tname=\(name)\n\tip_address=\(ip)\n\thw_address=1,\(hw)\n\tidentifier=1,\(hw)\n\tlease=\(lease)\n}\n"
    }

    @Test func findsMACWithLeadingZerosStripped() {
        let text = "{\n\tname=debian\n\tip_address=192.168.64.5\n\thw_address=1,2:a:0:0:0:1\n\tidentifier=1,2:a:0:0:0:1\n\tlease=0x6717a1b2\n}\n"
        #expect(DHCPLeases.ipAddress(forMAC: "02:0a:00:00:00:01", leases: text, now: epoch) == "192.168.64.5")
    }

    @Test func matchesUppercaseQueryMAC() {
        let text = block(ip: "192.168.64.5", hw: "2:a:0:0:0:1")
        #expect(DHCPLeases.ipAddress(forMAC: "02:0A:00:00:00:01", leases: text, now: epoch) == "192.168.64.5")
    }

    @Test func picksMostRecentLeaseForSameMAC() {
        let text = block(ip: "192.168.64.5", hw: "2:a:0:0:0:1", lease: "0x6717a1b2")
            + block(ip: "192.168.64.9", hw: "2:a:0:0:0:1", lease: "0x6717a1ff")
            + block(ip: "192.168.64.7", hw: "2:a:0:0:0:1", lease: "0x6717a100")
        #expect(DHCPLeases.ipAddress(forMAC: "02:0a:00:00:00:01", leases: text, now: epoch) == "192.168.64.9")
    }

    @Test func tieGoesToLaterBlock() {
        let text = block(ip: "192.168.64.5", hw: "2:a:0:0:0:1", lease: "0x10")
            + block(ip: "192.168.64.6", hw: "2:a:0:0:0:1", lease: "0x10")
        #expect(DHCPLeases.ipAddress(forMAC: "02:0a:00:00:00:01", leases: text, now: epoch) == "192.168.64.6")
    }

    @Test func missingOrUnparsableLeaseCountsAsZero() {
        let text = block(ip: "192.168.64.5", hw: "2:a:0:0:0:1", lease: "0x1")
            + "{\n\tip_address=192.168.64.8\n\thw_address=1,2:a:0:0:0:1\n}\n"
            + block(ip: "192.168.64.9", hw: "2:a:0:0:0:1", lease: "0xzz")
        #expect(DHCPLeases.ipAddress(forMAC: "02:0a:00:00:00:01", leases: text, now: epoch) == "192.168.64.5")
    }

    @Test func ignoresOtherMACs() {
        let text = block(ip: "192.168.64.5", hw: "2:a:0:0:0:2")
        #expect(DHCPLeases.ipAddress(forMAC: "02:0a:00:00:00:01", leases: text, now: epoch) == nil)
    }

    @Test func absentMACReturnsNil() {
        let text = block(ip: "192.168.64.5", hw: "2:a:0:0:0:1")
        #expect(DHCPLeases.ipAddress(forMAC: "02:0a:00:00:00:ff", leases: text, now: epoch) == nil)
    }

    @Test func emptyTextReturnsNil() {
        #expect(DHCPLeases.ipAddress(forMAC: "02:0a:00:00:00:01", leases: "", now: epoch) == nil)
    }

    @Test(arguments: ["", "02:0a:00:00:00", "02:0a:00:00:00:01:02", "02:0a:00:00:00:zz", "2:a:0:0:0:1:", "02:0a:000:00:00:01"])
    func invalidQueryMACReturnsNil(_ mac: String) {
        let text = block(ip: "192.168.64.5", hw: "2:a:0:0:0:1")
        #expect(DHCPLeases.ipAddress(forMAC: mac, leases: text, now: epoch) == nil)
    }

    @Test func garbageInputNeverCrashesAndDoesNotMatch() {
        let fixed = [
            "{{{{", "}}}}", "=====", "{\n=\n}\n", "{\n}\n}\n{", "\u{0}\u{1}\u{7f}",
            "{\n\tip_address=\n\thw_address=\n}\n", "{\n\tip_address=1.2.3.4\n\thw_address=1,\n}\n",
            "lease=0x\nname", "\n\n\n\t\t\t",
        ]
        for text in fixed {
            #expect(DHCPLeases.ipAddress(forMAC: "02:0a:00:00:00:01", leases: text, now: epoch) == nil)
        }

        // Deterministic pseudo-random printable and control bytes (LCG) must never crash.
        var seed: UInt64 = 0x9E3779B97F4A7C15
        let alphabet = Array("{}=\n\t 0123456789abcdefx,:ip_addressw_hl".unicodeScalars)
        for _ in 0..<500 {
            var s = ""
            for _ in 0..<200 {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let pick = Int((seed >> 33) % UInt64(alphabet.count + 4))
                s.unicodeScalars.append(pick < alphabet.count ? alphabet[pick] : Unicode.Scalar(UInt8(pick)))
            }
            _ = DHCPLeases.ipAddress(forMAC: "02:0a:00:00:00:01", leases: s, now: epoch)
        }
    }

    @Test func overflowingLeaseCountsAsZero() {
        let text = block(ip: "192.168.64.5", hw: "2:a:0:0:0:1", lease: "0x1")
            + block(ip: "192.168.64.6", hw: "2:a:0:0:0:1", lease: "0xFFFFFFFFFFFFFFFFFFFF")
        #expect(DHCPLeases.ipAddress(forMAC: "02:0a:00:00:00:01", leases: text, now: epoch) == "192.168.64.5")
    }

    @Test func truncatedBlockIsIgnored() {
        let complete = block(ip: "192.168.64.5", hw: "2:a:0:0:0:1")
        let truncated = "{\n\tname=broken\n\tip_address=192.168.64.99\n\thw_address=1,2:a:0:0:0:1\n\tlease=0xffffffff\n"
        #expect(DHCPLeases.ipAddress(forMAC: "02:0a:00:00:00:01", leases: complete, now: epoch) == "192.168.64.5")
        #expect(DHCPLeases.ipAddress(forMAC: "02:0a:00:00:00:01", leases: truncated, now: epoch) == nil)
        #expect(DHCPLeases.ipAddress(forMAC: "02:0a:00:00:00:01", leases: complete + truncated, now: epoch) == "192.168.64.5")
    }

    @Test func blockMissingRequiredKeysIsIgnored() {
        let text = "{\n\tname=x\n\thw_address=1,2:a:0:0:0:1\n\tlease=0xff\n}\n"
            + "{\n\tname=y\n\tip_address=192.168.64.4\n\tlease=0xff\n}\n"
        #expect(DHCPLeases.ipAddress(forMAC: "02:0a:00:00:00:01", leases: text, now: epoch) == nil)
    }

    // MARK: - Expiry and address validation

    @Test func expiredLeaseIsIgnored() {
        let text = block(ip: "192.168.64.5", hw: "2:a:0:0:0:1", lease: "0x100")
        #expect(DHCPLeases.ipAddress(forMAC: "02:0a:00:00:00:01", leases: text, now: Date(timeIntervalSince1970: 0x101)) == nil)
        #expect(DHCPLeases.ipAddress(forMAC: "02:0a:00:00:00:01", leases: text, now: Date(timeIntervalSince1970: 0x100)) == "192.168.64.5")
    }

    @Test func missingLeaseIsExpiredAtRealTime() {
        let text = "{\n\tip_address=192.168.64.8\n\thw_address=1,2:a:0:0:0:1\n}\n"
        #expect(DHCPLeases.ipAddress(forMAC: "02:0a:00:00:00:01", leases: text) == nil)
    }

    @Test func liveLeaseIsFoundWithDefaultClock() {
        let future = String(UInt64(Date().timeIntervalSince1970) + 3600, radix: 16)
        let text = block(ip: "192.168.64.5", hw: "2:a:0:0:0:1", lease: "0x1")
            + block(ip: "192.168.64.6", hw: "2:a:0:0:0:1", lease: "0x\(future)")
        #expect(DHCPLeases.ipAddress(forMAC: "02:0a:00:00:00:01", leases: text) == "192.168.64.6")
    }

    @Test(arguments: ["::1", "fe80::1", "192.168.64.300", "1.2.3", "-oProxyCommand=x", "host.example", "1.2.3.4x", "01.2.3.4"])
    func nonIPv4AddressIsIgnored(_ address: String) {
        let text = block(ip: "192.168.64.5", hw: "2:a:0:0:0:1", lease: "0x10")
            + block(ip: address, hw: "2:a:0:0:0:1", lease: "0x20")
        #expect(DHCPLeases.ipAddress(forMAC: "02:0a:00:00:00:01", leases: text, now: epoch) == "192.168.64.5")
    }
}
