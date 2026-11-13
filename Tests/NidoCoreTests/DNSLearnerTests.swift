// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCore

@Suite struct DNSLearnerTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func ttlBoundsAreFixed() {
        #expect(DNSLearner.minTTL == 600)
        #expect(DNSLearner.maxTTL == 3600)
    }

    @Test func entryLivesForItsTTL() {
        let learner = DNSLearner()
        learner.learn(name: "deb.debian.org", addresses: ["151.101.2.132", "151.101.66.132"], ttl: 1200, now: t0)
        #expect(learner.domain(for: "151.101.2.132", now: t0) == "deb.debian.org")
        #expect(learner.domain(for: "151.101.66.132", now: t0 + 1199) == "deb.debian.org")
        #expect(learner.domain(for: "151.101.2.132", now: t0 + 1200) == nil)
        #expect(learner.domain(for: "151.101.130.132", now: t0) == nil)
    }

    @Test func shortTTLIsRaisedToTheMinimum() {
        let learner = DNSLearner()
        learner.learn(name: "deb.debian.org", addresses: ["151.101.2.132"], ttl: 0, now: t0)
        // Ten minutes: apt keeps the addresses it resolved for its whole run and reconnects to
        // them long after a CDN's TTL of seconds.
        #expect(learner.domain(for: "151.101.2.132", now: t0 + 599) == "deb.debian.org")
        #expect(learner.domain(for: "151.101.2.132", now: t0 + 600) == nil)
    }

    @Test func longTTLIsLoweredToTheMaximum() {
        let learner = DNSLearner()
        learner.learn(name: "deb.debian.org", addresses: ["151.101.2.132"], ttl: .max, now: t0)
        #expect(learner.domain(for: "151.101.2.132", now: t0 + 3599) == "deb.debian.org")
        #expect(learner.domain(for: "151.101.2.132", now: t0 + 3600) == nil)
    }

    @Test func relearningExtendsButNeverShortens() {
        let learner = DNSLearner()
        learner.learn(name: "deb.debian.org", addresses: ["151.101.2.132"], ttl: 600, now: t0)
        learner.learn(name: "deb.debian.org", addresses: ["151.101.2.132"], ttl: 30, now: t0 + 10)
        #expect(learner.domain(for: "151.101.2.132", now: t0 + 599) == "deb.debian.org")
        learner.learn(name: "deb.debian.org", addresses: ["151.101.2.132"], ttl: 600, now: t0 + 500)
        #expect(learner.domain(for: "151.101.2.132", now: t0 + 1099) == "deb.debian.org")
        #expect(learner.domain(for: "151.101.2.132", now: t0 + 1100) == nil)
    }

    @Test func namesAreNormalized() {
        let learner = DNSLearner()
        learner.learn(name: "Deb.Debian.ORG.", addresses: ["151.101.2.132"], ttl: 60, now: t0)
        #expect(learner.domain(for: "151.101.2.132", now: t0) == "deb.debian.org")
    }

    @Test func theNewestNameWinsForASharedAddress() {
        let learner = DNSLearner()
        learner.learn(name: "a.example.com", addresses: ["151.101.2.132"], ttl: 900, now: t0)
        learner.learn(name: "b.example.com", addresses: ["151.101.2.132"], ttl: 900, now: t0 + 1)
        #expect(learner.domain(for: "151.101.2.132", now: t0 + 2) == "b.example.com")
        #expect(learner.domains(for: "151.101.2.132", now: t0 + 2) == ["b.example.com", "a.example.com"])
        // The older name expires first; the newer one remains.
        #expect(learner.domains(for: "151.101.2.132", now: t0 + 900) == ["b.example.com"])
    }

    @Test func forgetRemovesWhatThePatternCovers() throws {
        let learner = DNSLearner()
        learner.learn(name: "deb.debian.org", addresses: ["151.101.2.132"], ttl: 600, now: t0)
        learner.learn(name: "security.debian.org", addresses: ["151.101.66.132"], ttl: 600, now: t0)
        learner.learn(name: "debian.org", addresses: ["130.89.148.77"], ttl: 600, now: t0)
        learner.learn(name: "ollama.com", addresses: ["34.36.133.15", "151.101.66.132"], ttl: 600, now: t0)

        learner.forget(matching: try DomainPattern("deb.debian.org"))
        #expect(learner.domain(for: "151.101.2.132", now: t0) == nil)
        #expect(Set(learner.domains(for: "151.101.66.132", now: t0)) == ["security.debian.org", "ollama.com"])

        learner.forget(matching: try DomainPattern("*.debian.org"))
        #expect(learner.domain(for: "130.89.148.77", now: t0) == nil)
        // The address shared with an allowed name keeps that name only.
        #expect(learner.domains(for: "151.101.66.132", now: t0) == ["ollama.com"])
        #expect(learner.domain(for: "34.36.133.15", now: t0) == "ollama.com")
    }

    @Test(arguments: [
        "0.0.0.0", "0.1.2.3", "10.1.2.3", "100.64.0.1", "127.0.0.1", "169.254.169.254", "172.16.0.1",
        "172.31.255.255", "192.0.0.8", "192.0.2.1", "192.168.64.1", "198.18.0.1", "198.51.100.1",
        "203.0.113.1", "192.88.99.1", "224.0.0.251", "239.255.255.250", "240.0.0.1", "255.255.255.255",
        "::1", "2606:4700::1", "fe80::1", "1.2.3", "01.2.3.4", "1.2.3.4 ", "", "deb.debian.org",
    ])
    func nonPublicOrInvalidAddressesAreNeverLearned(_ address: String) {
        let learner = DNSLearner()
        learner.learn(name: "deb.debian.org", addresses: [address], ttl: 600, now: t0)
        #expect(learner.domain(for: address, now: t0) == nil)
        #expect(learner.count(now: t0) == 0)
    }

    @Test func publicNeighboursOfReservedRangesAreLearned() {
        let learner = DNSLearner()
        let addresses = ["11.0.0.1", "100.128.0.1", "172.32.0.1", "192.169.0.1", "198.20.0.1", "192.88.100.1", "223.255.255.254"]
        learner.learn(name: "deb.debian.org", addresses: addresses, ttl: 600, now: t0)
        for address in addresses { #expect(learner.domain(for: address, now: t0) == "deb.debian.org") }
    }

    @Test func invalidNamesAreNeverLearned() {
        let learner = DNSLearner()
        for name in [
            "", ".", "a..b", "exa mple.com", String(repeating: "a", count: 300), "\u{212A}de.org", "bücher.de",
            "deb.debian.org\u{0}",
        ] {
            learner.learn(name: name, addresses: ["151.101.2.132"], ttl: 600, now: t0)
        }
        #expect(learner.count(now: t0) == 0)
    }

    @Test func sizeIsBounded() {
        let learner = DNSLearner()
        // One name per address, far more addresses than the cap.
        for i in 0..<(DNSLearner.maxAddresses + 500) {
            let address = "8.\(i / 65536 % 256).\(i / 256 % 256).\(i % 256)"
            learner.learn(name: "h\(i).example.com", addresses: [address], ttl: 600, now: t0 + Double(i) / 1000)
        }
        #expect(learner.count(now: t0 + 10) <= DNSLearner.maxAddresses)
        // The newest entry is kept.
        let last = DNSLearner.maxAddresses + 499
        #expect(
            learner.domain(for: "8.\(last / 65536 % 256).\(last / 256 % 256).\(last % 256)", now: t0 + 10)
                == "h\(last).example.com")

        // Many names on one address.
        for i in 0..<100 {
            learner.learn(name: "n\(i).example.com", addresses: ["9.9.9.9"], ttl: 600, now: t0 + Double(i))
        }
        let names = learner.domains(for: "9.9.9.9", now: t0 + 100)
        #expect(names.count == DNSLearner.maxNamesPerAddress)
        #expect(names.first == "n99.example.com")
    }

    @Test func oneAnswerCannotFloodTheTable() {
        let learner = DNSLearner()
        let addresses = (0..<1000).map { "8.8.\($0 / 256).\($0 % 256)" }
        learner.learn(name: "deb.debian.org", addresses: addresses, ttl: 600, now: t0)
        #expect(learner.count(now: t0) == DNSLearner.maxAddressesPerAnswer)
    }

    @Test func expiredEntriesArePurged() {
        let learner = DNSLearner()
        learner.learn(name: "deb.debian.org", addresses: ["151.101.2.132"], ttl: 60, now: t0)
        learner.learn(name: "ollama.com", addresses: ["34.36.133.15"], ttl: 900, now: t0)
        #expect(learner.count(now: t0) == 2)
        learner.purge(now: t0 + DNSLearner.minTTL)
        #expect(learner.count(now: t0 + DNSLearner.minTTL) == 1)
    }

    @Test func concurrentUseIsSafe() async {
        let learner = DNSLearner()
        let t0 = self.t0
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    for i in 0..<500 {
                        let address = "8.\(worker).\(i / 256).\(i % 256)"
                        learner.learn(name: "w\(worker).example.com", addresses: [address], ttl: 600, now: t0)
                        _ = learner.domain(for: address, now: t0)
                        if i % 50 == 0 { learner.forget(matching: try! DomainPattern("w\(worker).example.com")) }
                    }
                }
            }
        }
        #expect(learner.count(now: t0) <= 8 * 500)
    }
}
