// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCore

@Suite struct EgressLogTests {
    private func temporaryDirectory() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("nido-egresslog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func entry(_ index: Int) -> EgressLogEntry {
        EgressLogEntry(
            time: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)), domain: "deb.debian.org",
            ip: "151.101.2.132", port: 443, proto: .tcp, bytesOut: UInt64(index), bytesIn: UInt64(2 * index),
            verdict: .allowed)
    }

    @Test func logRotatesAt1MiBAndStaysPrivate() throws {
        let tmp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Allowed flows go to the flow file.
        let url = tmp.appendingPathComponent("egress-flows.log")
        let rotated = tmp.appendingPathComponent("egress-flows.log.1")
        #expect(EgressLog.cap == 1 << 20)

        let log = try EgressLog(bundle: VMBundle(url: tmp))
        let lineSize = try EgressLog.line(for: entry(1)).count
        let count = (1 << 20) / lineSize + 10
        for i in 0..<count { log.append(entry(i)) }
        log.close()

        #expect(try Data(contentsOf: url).count <= 1 << 20)
        let previous = try Data(contentsOf: rotated)
        #expect(previous.count <= 1 << 20)
        #expect(previous.count > (1 << 20) - 2 * lineSize)
        for url in [url, rotated] {
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            #expect(mode == 0o600)
        }
        let entries = EgressLog.readEntries(at: url)
        #expect(entries.count == count)
        #expect(entries.first == entry(0))
        #expect(entries.last == entry(count - 1))
    }

    @Test func lineHoldsOnlyTheFlowMetadata() throws {
        let line = String(decoding: try EgressLog.line(for: entry(3)), as: UTF8.self)
        #expect(line.hasSuffix("\n"))
        #expect(line.filter { $0 == "\n" }.count == 1)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(Set(object.keys) == ["time", "domain", "ip", "port", "proto", "bytesOut", "bytesIn", "verdict"])
        #expect(object["time"] as? String == "2027-01-15T08:00:03Z")
        #expect(object["verdict"] as? String == "allowed")
        // A summary names what was lost, and nothing else.
        let summary = try #require(EgressLogEntry(
            event: EgressEvent(kind: .suppressed(blocks: 4, flows: 2), proto: .other, ip: nil, port: nil),
            time: Date(timeIntervalSince1970: 1_800_000_000)))
        let summaryObject = try #require(try JSONSerialization.jsonObject(
            with: try EgressLog.line(for: summary)) as? [String: Any])
        #expect(Set(summaryObject.keys) == ["time", "proto", "bytesOut", "bytesIn", "verdict", "lostBlocks", "lostFlows"])
    }

    @Test func refusesASymlinkedLog() throws {
        let tmp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let url = tmp.appendingPathComponent("egress.log")
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: tmp.appendingPathComponent("elsewhere"))
        #expect(throws: NidoError.self) { _ = try EgressLog(bundle: VMBundle(url: tmp)) }
        #expect(EgressLog.readEntries(at: url).isEmpty)
    }

    @Test func eventsBecomeEntries() throws {
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        func entry(_ kind: EgressEvent.Kind, _ proto: EgressProto = .tcp, ip: String? = "151.101.2.132",
                   port: UInt16? = 443) -> EgressLogEntry?
        {
            EgressLogEntry(event: EgressEvent(kind: kind, proto: proto, ip: ip, port: port), time: time)
        }
        let ended = try #require(entry(.ended(domain: "deb.debian.org", bytesOut: 10, bytesIn: 20, count: 3)))
        #expect(ended.verdict == .allowed && ended.domain == "deb.debian.org" && ended.bytesIn == 20)
        #expect(ended.count == 3)
        #expect(entry(.ended(domain: "deb.debian.org", bytesOut: 10, bytesIn: 20, count: 1))?.count == nil)
        #expect(!ended.verdict.isBlock)
        #expect(entry(.progress(domain: "deb.debian.org", bytesOut: 1, bytesIn: 2))?.verdict == .open)
        let cut = try #require(entry(.denied(.cut(domain: "deb.debian.org", bytesOut: 5, bytesIn: 6, count: 1))))
        #expect(cut.verdict == .cut && cut.verdict.isBlock && cut.bytesOut == 5 && cut.domain == "deb.debian.org")
        let name = try #require(entry(.denied(.name("example.com")), .udp, ip: "192.168.64.1", port: 53))
        #expect(name.verdict == .name && name.domain == "example.com" && name.port == 53)
        let unknown = try #require(entry(.denied(.verdict(.denyUnknown(ip: "93.184.215.14"))), ip: "93.184.215.14"))
        #expect(unknown.verdict == .denyUnknown && unknown.domain == nil && unknown.verdict.isBlock)
        #expect(entry(.denied(.verdict(.denyDomain("other.org"))))?.domain == "other.org")
        #expect(entry(.denied(.verdict(.denyProto(ip: "1.1.1.1", proto: .icmp))), .icmp)?.verdict == .denyProto)
        let malformed = try #require(entry(.denied(.malformed), .other, ip: nil, port: nil))
        #expect(malformed.verdict == .malformed && malformed.ip == nil && malformed.port == nil)
        var repeated = EgressEvent(kind: .denied(.dnsBypass), proto: .udp, ip: "8.8.8.8", port: 53)
        repeated.repeats = 6
        #expect(EgressLogEntry(event: repeated, time: time)?.repeats == 6)
        #expect(entry(.denied(.dnsBypass), .udp)?.repeats == nil)
        let lost = try #require(entry(.suppressed(blocks: 3, flows: 0), .other, ip: nil, port: nil))
        #expect(lost.verdict == .suppressed && lost.lostBlocks == 3 && lost.lostFlows == 0 && lost.verdict.isBlock)
        #expect(lost.lostNoise == nil)
        let noise = try #require(entry(.suppressed(blocks: 0, flows: 0, noise: 9), .other, ip: nil, port: nil))
        #expect(noise.lostBlocks == 0 && noise.lostNoise == 9)
    }

    /// Blocks (with cuts and summaries) and flow lines rotate in separate files, so flow churn
    /// cannot evict blocks; reading merges both by time.
    @Test func blocksAndFlowsAreKeptApart() throws {
        let tmp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bundle = VMBundle(url: tmp)
        let log = try EgressLog(bundle: bundle, cap: 4096)
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        log.append(EgressLogEntry(time: t, domain: nil, ip: "93.184.215.14", port: 443, proto: .tcp, verdict: .denyUnknown))
        for i in 0..<500 { log.append(entry(i)) }
        log.append(EgressLogEntry(time: t + 1000, domain: "deb.debian.org", ip: "151.101.2.132", port: 443, proto: .tcp,
                                  verdict: .cut))
        log.close()
        #expect(EgressLog.readEntries(at: bundle.egressLogURL).map(\.verdict) == [.denyUnknown, .cut])
        #expect(EgressLog.readEntries(at: bundle.egressFlowLogURL).allSatisfy { $0.verdict == .allowed })
        for url in [bundle.egressLogURL, bundle.egressFlowLogURL] {
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            #expect(mode == 0o600)
        }
        let merged = EgressLog.readEntries(bundle: bundle)
        #expect(merged.first?.verdict == .denyUnknown)
        #expect(merged.last?.verdict == .cut)
        #expect(merged.map(\.time) == merged.map(\.time).sorted())
    }

    @Test func undecodableLinesAreSkipped() throws {
        let tmp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let url = tmp.appendingPathComponent("egress-flows.log")
        let log = try EgressLog(bundle: VMBundle(url: tmp))
        log.append(entry(1))
        log.close()
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"garbage\":true}\nnot json\n".utf8))
        try handle.close()
        #expect(EgressLog.readEntries(at: url) == [entry(1)])
    }
}

@Suite(.italian) struct EgressNoticeMergerTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func blocked(_ ip: String, _ port: UInt16) -> EgressEvent {
        EgressEvent(kind: .denied(.verdict(.denyUnknown(ip: ip))), proto: .tcp, ip: ip, port: port)
    }

    private func name(_ name: String) -> EgressEvent {
        EgressEvent(kind: .denied(.name(name)), proto: .udp, ip: "192.168.64.1", port: 53)
    }

    @Test func repeatsArePrintedOncePerTenSecondsAndCounted() {
        let merger = EgressNoticeMerger()
        #expect(EgressNoticeMerger.window == 10)
        #expect(merger.lines(for: blocked("93.184.215.14", 443), now: t0).count == 1)
        // Same destination and port, even by another kind: merged.
        #expect(merger.lines(for: blocked("93.184.215.14", 443), now: t0 + 1).isEmpty)
        #expect(merger.lines(for: EgressEvent(kind: .denied(.dnsBypass), proto: .udp, ip: "93.184.215.14", port: 443),
                             now: t0 + 2).isEmpty)
        // Another port or address: its own line.
        #expect(merger.lines(for: blocked("93.184.215.14", 80), now: t0 + 2).count == 1)
        #expect(merger.lines(for: blocked("93.184.215.15", 443), now: t0 + 2).count == 1)
        // Nothing is hidden: once the window is over, the merged repeats are counted.
        let flushed = merger.flush(now: t0 + 10)
        #expect(flushed == ["bloccato ancora 2 volte verso 93.184.215.14:443 negli ultimi 10 s"])
        #expect(merger.flush(now: t0 + 30).isEmpty)
        #expect(merger.lines(for: blocked("93.184.215.14", 443), now: t0 + 31).count == 1)
    }

    @Test func aDomainMergesItsAddresses() {
        let merger = EgressNoticeMerger()
        #expect(merger.lines(for: name("example.com"), now: t0).count == 1)
        #expect(merger.lines(for: name("example.com"), now: t0 + 1).isEmpty)
        let otherAddress = EgressEvent(kind: .denied(.name("example.com")), proto: .udp, ip: "192.168.64.9", port: 53)
        #expect(merger.lines(for: otherAddress, now: t0 + 2).isEmpty)
        #expect(merger.lines(for: name("example.org"), now: t0 + 2).count == 1)
        // A repeat after the window prints again, with what the window merged.
        let again = merger.lines(for: name("example.com"), now: t0 + 11)
        #expect(again == [
            "bloccato ancora 2 volte verso example.com:53 negli ultimi 10 s",
            "bloccato il nome example.com: non è tra i domini permessi",
        ])
    }

    @Test func flowsAreNotNoticesAndSummariesAlwaysAre() {
        let merger = EgressNoticeMerger()
        #expect(merger.lines(for: EgressEvent(kind: .progress(domain: "a.org", bytesOut: 1, bytesIn: 1), proto: .tcp,
                                              ip: "1.1.1.1", port: 443), now: t0).isEmpty)
        #expect(merger.lines(for: EgressEvent(kind: .ended(domain: "a.org", bytesOut: 1, bytesIn: 1, count: 1), proto: .tcp,
                                              ip: "1.1.1.1", port: 443), now: t0).isEmpty)
        // Cuts always print, never merged.
        let cut = EgressEvent(kind: .denied(.cut(domain: "a.org", bytesOut: 1, bytesIn: 1, count: 1)), proto: .tcp,
                              ip: "1.1.1.1", port: 443)
        #expect(merger.lines(for: cut, now: t0).count == 1)
        #expect(merger.lines(for: cut, now: t0 + 1).count == 1)
        let summary = EgressEvent(kind: .suppressed(blocks: 5, flows: 0), proto: .other, ip: nil, port: nil)
        #expect(merger.lines(for: summary, now: t0) == ["altri 5 blocchi non mostrati"])
        #expect(merger.lines(for: summary, now: t0 + 1) == ["altri 5 blocchi non mostrati"])
    }

    /// Repeats the relay's own limiter held back count too.
    @Test func relayRepeatsAreCounted() {
        let merger = EgressNoticeMerger()
        #expect(merger.lines(for: blocked("93.184.215.14", 443), now: t0).count == 1)
        var again = blocked("93.184.215.14", 443)
        again.repeats = 3
        // Inside the window: added to the count.
        #expect(merger.lines(for: again, now: t0 + 5).isEmpty)
        #expect(merger.flush(now: t0 + 10) == ["bloccato ancora 4 volte verso 93.184.215.14:443 negli ultimi 10 s"])
        // A destination the merger has forgotten: its repeats are a line of their own.
        let lines = merger.lines(for: again, now: t0 + 40)
        #expect(lines.count == 2)
        #expect(lines[0] == "bloccato ancora 3 volte verso 93.184.215.14:443 negli ultimi 10 s")
    }

    @Test func tableStaysBounded() {
        let merger = EgressNoticeMerger()
        for port in 0..<(EgressNoticeMerger.maxKeys + 100) {
            _ = merger.lines(for: blocked("93.184.215.14", UInt16(port)), now: t0)
        }
        #expect(merger.count <= EgressNoticeMerger.maxKeys)
    }
}
