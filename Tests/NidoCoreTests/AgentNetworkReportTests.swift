// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
@testable import NidoCore

/// A log that the test grows (or rotates) between two reads.
private final class FakeLog: Sendable {
    private let state: Mutex<[EgressLogEntry]>
    init(_ entries: [EgressLogEntry] = []) { state = Mutex(entries) }
    func set(_ entries: [EgressLogEntry]) { state.withLock { $0 = entries } }
    func read(_ url: URL) -> [EgressLogEntry] { state.withLock { $0 } }
}

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func block(
    _ verdict: EgressLogEntry.Verdict, _ domain: String?, ip: String? = nil, at time: Date = t0
) -> EgressLogEntry {
    EgressLogEntry(time: time, domain: domain, ip: ip, port: 53, proto: .udp, verdict: verdict)
}

private let hint = "If the task needs one, stop and ask the user to run: nido net allow agent-27 <domain>"

private func blocked(_ names: String) -> String {
    "Network: blocked \(names) (not on the allowed domains; nothing was sent to them). \(hint)"
}

@Suite struct AgentNetworkReportTests {
    private func temporaryBundle() throws -> VMBundle {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("nido-netreport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return VMBundle(url: tmp)
    }

    private func report(
        _ log: FakeLog, bundle: VMBundle = VMBundle(url: URL(fileURLWithPath: "/nonexistent-nido-bundle")),
        policy: EgressPolicy? = .empty
    ) -> AgentNetworkReport {
        AgentNetworkReport(
            bundle: bundle, hintVM: "agent-27", now: t0, readEntries: { log.read($0) }, loadPolicy: { _ in policy })
    }

    private func controlled(_ bundle: VMBundle, _ value: Bool?) throws {
        let config = VMConfig(
            id: UUID(), name: try VMName("agent-27"), guest: .macos, cpuCount: 2,
            memoryBytes: 2 << 30, diskBytes: 8 << 30, macAddress: "02:00:00:00:00:01", controlledNetwork: value)
        try bundle.writeConfig(config)
    }

    @Test func listsRefusedNames() {
        let line = AgentNetworkReport.blocksLine(
            [block(.name, "example.com"), block(.name, "cdn.example.com")], hintVM: "agent-27")
        #expect(line == blocked("example.com, cdn.example.com"))
    }

    @Test func eachNameOnce() {
        let line = AgentNetworkReport.blocksLine(
            Array(repeating: block(.name, "example.com"), count: 3), hintVM: "agent-27")
        #expect(line == blocked("example.com"))
    }

    @Test func onlyReportedVerdicts() {
        let others = [
            block(.cut, "a.example.com"), block(.aliasQueryType, "b.example.com"), block(.invalidName, "c.example.com"),
            block(.denyUnknown, nil, ip: "151.101.2.132"), block(.suppressed, "d.example.com"),
            block(.uplinkLost, "e.example.com"), block(.broadcast, "f.example.com"),
        ]
        #expect(AgentNetworkReport.blocksLine(others, hintVM: "agent-27") == nil)
        let line = AgentNetworkReport.blocksLine(others + [block(.denyDomain, "example.org")], hintVM: "agent-27")
        #expect(line == blocked("example.org"))
    }

    @Test func onlyPlainNamesAreListed() {
        let names = ["Example.COM", "x y.com", "é.com", String(repeating: "a", count: 254), "a\u{202E}b.com"]
        let line = AgentNetworkReport.blocksLine(names.map { block(.name, $0) }, hintVM: "agent-27")
        #expect(line == blocked("example.com"))
    }

    @Test func onlyNamesNidoCanAllowAreListed() {
        let names = ["1.2.3.4", "...", "-", "_x.example.com", "example.com.", "*.example.com", "localhost"]
        #expect(AgentNetworkReport.blocksLine(names.map { block(.name, $0) }, hintVM: "agent-27") == nil)
        let line = AgentNetworkReport.blocksLine(
            (names + ["example.com"]).map { block(.denyDomain, $0) }, hintVM: "agent-27")
        #expect(line == blocked("example.com"))
    }

    @Test func dnsResolverDiscoveryIsBackground() {
        let entries = ["_dns.resolver.arpa", "1.0.0.0.ip6.arpa", "example.com"].map { block(.name, $0) }
        #expect(AgentNetworkReport.blocksLine(entries, hintVM: "agent-27")
            == blocked("example.com") + ". Also 2 blocks of macOS background services (usually not needed).")
        #expect(AgentNetworkReport.blocksLine([block(.name, "_dns.resolver.arpa")], hintVM: "agent-27") == nil)
    }

    @Test func oneBackgroundBlockIsSingular() {
        let one = [block(.name, "mesu.apple.com")]
        #expect(AgentNetworkReport.blocksLine(one, hintVM: "agent-27") == nil)
        #expect(AgentNetworkReport.blocksLine(one + [block(.name, "example.com")], hintVM: "agent-27")
            == blocked("example.com") + ". Also 1 block of macOS background services (usually not needed).")
    }

    @Test func atMostTenNames() {
        let names = (1...13).map { "host\($0).example.com" }
        let line = AgentNetworkReport.blocksLine(names.map { block(.name, $0) }, hintVM: "agent-27")
        #expect(line == blocked(names.prefix(10).joined(separator: ", ") + ", and 3 more"))
    }

    @Test func backgroundIsCounted() {
        let entries = ["mesu.apple.com", "token.safebrowsing.apple", "2.127.168.192.in-addr.arpa", "example.com"]
            .map { block(.name, $0) }
        let line = AgentNetworkReport.blocksLine(entries, hintVM: "agent-27")
        #expect(line == blocked("example.com") + ". Also 3 blocks of macOS background services (usually not needed).")
        #expect(AgentNetworkReport.blocksLine([block(.name, "notapple.com")], hintVM: "agent-27")
            == blocked("notapple.com"))
    }

    @Test func backgroundOnly() {
        let line = AgentNetworkReport.blocksLine(
            Array(repeating: block(.name, "gateway.icloud.com"), count: 2), hintVM: "agent-27")
        #expect(line == nil)
    }

    @Test func akamaiAppleCDNIsBackgroundButOtherAkadnsIsNamed() {
        let entries = ["mesu-cdn.origin-apple.com.akadns.net", "www.example.com.akadns.net"].map { block(.name, $0) }
        #expect(AgentNetworkReport.blocksLine(entries, hintVM: "agent-27")
            == blocked("www.example.com.akadns.net")
            + ". Also 1 block of macOS background services (usually not needed).")
    }

    @Test func startsAtTheEnd() {
        let old = block(.name, "old.example.com", at: t0.addingTimeInterval(-10))
        let log = FakeLog([old])
        let report = report(log)
        #expect(report.newBlocksLine() == nil)
        log.set([old, block(.name, "new.example.com", at: t0.addingTimeInterval(5))])
        #expect(report.newBlocksLine() == blocked("new.example.com"))
        #expect(report.newBlocksLine() == nil)
    }

    @Test func rotationReportsEachBlockOnce() {
        let a = block(.name, "a.example.com", at: t0)
        let b = block(.name, "b.example.com", at: t0.addingTimeInterval(1))
        let c = block(.name, "c.example.com", at: t0.addingTimeInterval(2))
        let d = block(.name, "d.example.com", at: t0.addingTimeInterval(3))
        let log = FakeLog([a, b])
        let report = report(log)
        log.set([a, b, c])
        #expect(report.newBlocksLine() == blocked("c.example.com"))
        // Rotated: `egress.log.1` keeps b and c, the new `egress.log` holds d.
        log.set([b, c, d])
        #expect(report.newBlocksLine() == blocked("d.example.com"))
        #expect(report.newBlocksLine() == nil)
    }

    @Test func missingLogIsSilent() {
        let report = report(FakeLog())
        #expect(report.newBlocksLine() == nil)
        #expect(report.newBlocksLine() == nil)
    }

    @Test func statusLineControlled() throws {
        let bundle = try temporaryBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        try controlled(bundle, true)
        let two = EgressPolicy(v: 1, allow: [try DomainPattern("example.com"), try DomainPattern("*.debian.org")])
        #expect(report(FakeLog(), bundle: bundle, policy: two).statusLine()
            == "Network: controlled; allowed domains: example.com, *.debian.org")
        let names = (1...23).map { "host\($0).example.com" }
        let many = EgressPolicy(v: 1, allow: try names.map { try DomainPattern($0) })
        #expect(report(FakeLog(), bundle: bundle, policy: many).statusLine()
            == "Network: controlled; allowed domains: " + names.prefix(20).joined(separator: ", ") + ", and 3 more")
        #expect(report(FakeLog(), bundle: bundle, policy: .empty).statusLine() == "Network: controlled; no allowed domains")
    }

    @Test func statusLineNAT() throws {
        let bundle = try temporaryBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        for value in [false, nil] as [Bool?] {
            try controlled(bundle, value)
            #expect(report(FakeLog(), bundle: bundle).statusLine() == "Network: Apple's NAT, not filtered by Nido")
        }
    }

    @Test func statusLineUnreadable() throws {
        let bundle = try temporaryBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        try controlled(bundle, true)
        #expect(report(FakeLog(), bundle: bundle, policy: nil).statusLine()
            == "Network: controlled; the allowed domains can't be read")
    }
}
