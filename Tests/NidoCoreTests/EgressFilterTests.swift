// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// One filter on the vmnet subnet 192.168.66.0/24 (gateway .1) with the guest's lease .2.
private final class Rig {
    var events: [EgressEvent] = []
    let decision: EgressDecision
    var filter: EgressFilter!
    var now = t0
    let gateway: UInt32
    let lease: UInt32
    private var nextID: UInt16 = 0x100

    init(allow: [String], gateway: String = "192.168.66.1", lease: String = "192.168.66.2",
         mask: String = "255.255.255.0") throws
    {
        decision = EgressDecision(policy: EgressPolicy(v: 1, allow: try allow.map(DomainPattern.init)))
        self.gateway = Wire.ip(gateway)
        self.lease = Wire.ip(lease)
        let network = EgressNetwork(
            gateway: self.gateway, mask: Wire.ip(mask), guestMAC: EgressMAC(bytes: Wire.guestMAC))
        filter = EgressFilter(network: network, decision: decision) { [unowned self] in self.events.append($0) }
    }

    var denials: [EgressDenial] {
        events.compactMap { if case .denied(let denial) = $0.kind { denial } else { nil } }
    }

    func out(_ frame: [UInt8]) -> EgressFilter.Outbound {
        var copy = frame
        return filter.outbound(&copy, now: now)
    }

    /// The frame as delivered to the guest, or nil when dropped.
    func inbound(_ frame: [UInt8]) -> [UInt8]? {
        var copy = frame
        return filter.inbound(&copy, now: now) ? copy : nil
    }

    // Frames of the guest (from its MAC, to the gateway's MAC).
    func guestIP(dst: String, _ packet: [UInt8], ethDst: [UInt8] = Wire.gatewayMAC) -> [UInt8] {
        Wire.eth(dst: ethDst, src: Wire.guestMAC, type: 0x0800, packet)
    }

    func guestTCP(_ dst: String, _ dport: UInt16, sport: UInt16 = 40000, flags: UInt8 = Wire.syn) -> [UInt8] {
        guestIP(dst: dst, Wire.tcp(src: lease, dst: Wire.ip(dst), sport: sport, dport: dport, flags: flags))
    }

    func guestUDP(_ dst: String, _ dport: UInt16, sport: UInt16 = 40000, _ payload: [UInt8] = [1, 2, 3]) -> [UInt8] {
        guestIP(dst: dst, Wire.udp(src: lease, dst: Wire.ip(dst), sport: sport, dport: dport, payload))
    }

    func remoteTCP(_ src: String, _ sport: UInt16, dport: UInt16 = 40000, flags: UInt8 = Wire.syn | Wire.ack)
        -> [UInt8]
    {
        Wire.eth(dst: Wire.guestMAC, src: Wire.gatewayMAC, type: 0x0800,
                 Wire.tcp(src: Wire.ip(src), dst: lease, sport: sport, dport: dport, flags: flags))
    }

    func query(_ name: [UInt8], id: UInt16, sport: UInt16 = 5353, type: UInt16 = 1) -> [UInt8] {
        guestIP(dst: DottedIP(gateway), Wire.udp(
            src: lease, dst: gateway, sport: sport, dport: 53, Wire.dnsQuery(id: id, name: name, type: type)))
    }

    func answer(_ dns: [UInt8], dport: UInt16 = 5353, src: UInt32? = nil) -> [UInt8] {
        Wire.eth(dst: Wire.guestMAC, src: Wire.gatewayMAC, type: 0x0800,
                 Wire.udp(src: src ?? gateway, dst: lease, sport: 53, dport: dport, dns))
    }

    /// The guest's DHCP lease and the gateway's ARP, as after a boot.
    func establish() {
        let ack = Wire.eth(dst: Wire.broadcastMAC, src: Wire.gatewayMAC, type: 0x0800, Wire.udp(
            src: gateway, dst: 0xFFFF_FFFF, sport: 67, dport: 68,
            Wire.dhcp(op: 2, chaddr: Wire.guestMAC, yiaddr: lease, type: 5)))
        precondition(inbound(ack) != nil)
        let arp = Wire.eth(dst: Wire.guestMAC, src: Wire.gatewayMAC, type: 0x0806, Wire.arp(
            op: 2, senderMAC: Wire.gatewayMAC, senderIP: gateway, targetMAC: Wire.guestMAC, targetIP: lease))
        precondition(inbound(arp) != nil)
    }

    /// Asks `name` and answers it with `answers` (A records under the question name by default).
    @discardableResult
    func resolve(_ name: String, to addresses: [String], ttl: UInt32 = 300) -> [UInt8]? {
        nextID &+= 1
        let wire = Wire.name(name)
        guard out(query(wire, id: nextID)) == .forward else { return nil }
        let records = addresses.map { Wire.a(Wire.questionPointer, $0, ttl: ttl) }
        return inbound(answer(Wire.dnsAnswer(id: nextID, name: wire, answers: records)))
    }
}

private func DottedIP(_ address: UInt32) -> String { DNSLearner.dotted(address) }

@Suite(.italian) struct EgressFilterTests {
    // MARK: - DHCP and lease

    @Test func seededGatewayMACLetsUnicastThroughAtOnce() throws {
        let rig = try Rig(allow: ["example.com"])
        rig.filter.seedLease(rig.lease)
        // Without the gateway's MAC (no ARP seen yet) unicast to it is refused.
        #expect(rig.out(rig.query(Wire.name("example.com"), id: 1)) != .forward)
        rig.filter.seedGatewayMAC(EgressMAC(bytes: Wire.gatewayMAC))
        #expect(rig.filter.gatewayMAC == EgressMAC(bytes: Wire.gatewayMAC))
        #expect(rig.out(rig.query(Wire.name("example.com"), id: 2)) == .forward)
    }

    @Test func dhcpPassesAndTheAckSetsTheLease() throws {
        let rig = try Rig(allow: [])
        let discover = Wire.eth(dst: Wire.broadcastMAC, src: Wire.guestMAC, type: 0x0800, Wire.udp(
            src: 0, dst: 0xFFFF_FFFF, sport: 68, dport: 67, Wire.dhcp(op: 1, chaddr: Wire.guestMAC, type: 1)))
        #expect(rig.out(discover) == .forward)
        #expect(rig.filter.lease == nil)
        rig.establish()
        #expect(rig.filter.lease == rig.lease)
        // Renewal, unicast to the gateway from the lease.
        let renew = rig.guestIP(dst: "192.168.66.1", Wire.udp(
            src: rig.lease, dst: rig.gateway, sport: 68, dport: 67, Wire.dhcp(op: 1, chaddr: Wire.guestMAC, type: 3)))
        #expect(rig.out(renew) == .forward)
    }

    @Test func dhcpForAnotherHardwareAddressIsRefused() throws {
        let rig = try Rig(allow: [])
        let discover = Wire.eth(dst: Wire.broadcastMAC, src: Wire.guestMAC, type: 0x0800, Wire.udp(
            src: 0, dst: 0xFFFF_FFFF, sport: 68, dport: 67, Wire.dhcp(op: 1, chaddr: Wire.otherMAC, type: 1)))
        #expect(rig.out(discover) == .drop)
        let foreignAck = Wire.eth(dst: Wire.broadcastMAC, src: Wire.gatewayMAC, type: 0x0800, Wire.udp(
            src: rig.gateway, dst: 0xFFFF_FFFF, sport: 67, dport: 68,
            Wire.dhcp(op: 2, chaddr: Wire.otherMAC, yiaddr: Wire.ip("192.168.66.9"), type: 5)))
        #expect(rig.inbound(foreignAck) == nil)
        #expect(rig.filter.lease == nil)
        // An ACK not from the gateway, or for an address outside the subnet, sets nothing.
        let rogue = Wire.eth(dst: Wire.broadcastMAC, src: Wire.otherMAC, type: 0x0800, Wire.udp(
            src: Wire.ip("192.168.66.7"), dst: 0xFFFF_FFFF, sport: 67, dport: 68,
            Wire.dhcp(op: 2, chaddr: Wire.guestMAC, yiaddr: Wire.ip("192.168.66.9"), type: 5)))
        #expect(rig.inbound(rogue) == nil)
        let outside = Wire.eth(dst: Wire.broadcastMAC, src: Wire.gatewayMAC, type: 0x0800, Wire.udp(
            src: rig.gateway, dst: 0xFFFF_FFFF, sport: 67, dport: 68,
            Wire.dhcp(op: 2, chaddr: Wire.guestMAC, yiaddr: Wire.ip("10.0.0.9"), type: 5)))
        _ = rig.inbound(outside)
        #expect(rig.filter.lease == nil)
    }

    @Test func nothingButDHCPPassesBeforeTheLease() throws {
        let rig = try Rig(allow: [])
        #expect(rig.out(rig.guestUDP("192.168.66.1", 53)) == .drop)
        #expect(rig.denials.contains(.spoofed))
    }

    // MARK: - Spoofing

    @Test func foreignSourceMACOrIPIsDropped() throws {
        let rig = try Rig(allow: ["deb.debian.org"])
        rig.establish()
        rig.resolve("deb.debian.org", to: ["151.101.2.132"])
        let ok = rig.guestTCP("151.101.2.132", 443)
        #expect(rig.out(ok) == .forward)
        var otherMAC = ok
        otherMAC.replaceSubrange(6..<12, with: Wire.otherMAC)
        #expect(rig.out(otherMAC) == .drop)
        let otherIP = rig.guestIP(dst: "151.101.2.132", Wire.tcp(
            src: Wire.ip("192.168.66.3"), dst: Wire.ip("151.101.2.132"), sport: 40001, dport: 443, flags: Wire.syn))
        #expect(rig.out(otherIP) == .drop)
        #expect(rig.denials.filter { $0 == .spoofed }.count == 2)
    }

    @Test func unicastNotToTheGatewayMACIsDropped() throws {
        let rig = try Rig(allow: ["deb.debian.org"])
        rig.establish()
        rig.resolve("deb.debian.org", to: ["151.101.2.132"])
        let frame = rig.guestIP(dst: "151.101.2.132", Wire.tcp(
            src: rig.lease, dst: Wire.ip("151.101.2.132"), sport: 40000, dport: 443, flags: Wire.syn),
            ethDst: Wire.otherMAC)
        #expect(rig.out(frame) == .drop)
    }

    // MARK: - ARP

    @Test func arpOnlyForTheGatewayAndTheLease() throws {
        let rig = try Rig(allow: [])
        rig.establish()
        func arp(_ op: UInt16, sender: UInt32, target: String, mac: [UInt8] = Wire.guestMAC) -> [UInt8] {
            Wire.eth(dst: Wire.broadcastMAC, src: Wire.guestMAC, type: 0x0806, Wire.arp(
                op: op, senderMAC: mac, senderIP: sender, targetIP: Wire.ip(target)))
        }
        #expect(rig.out(arp(1, sender: rig.lease, target: "192.168.66.1")) == .forward)
        #expect(rig.out(arp(1, sender: rig.lease, target: "192.168.66.2")) == .forward)  // announcement
        #expect(rig.out(arp(1, sender: 0, target: "192.168.66.2")) == .forward)  // probe
        #expect(rig.out(arp(1, sender: rig.lease, target: "192.168.66.7")) == .drop)
        #expect(rig.out(arp(1, sender: Wire.ip("192.168.66.9"), target: "192.168.66.1")) == .drop)
        #expect(rig.out(arp(1, sender: rig.lease, target: "192.168.66.1", mac: Wire.otherMAC)) == .drop)
        // Inbound: only the gateway's.
        let foreign = Wire.eth(dst: Wire.broadcastMAC, src: Wire.otherMAC, type: 0x0806, Wire.arp(
            op: 1, senderMAC: Wire.otherMAC, senderIP: Wire.ip("192.168.66.7"), targetIP: rig.lease))
        #expect(rig.inbound(foreign) == nil)
    }

    // MARK: - DNS

    @Test func refusedNameGetsAShortNXDOMAIN() throws {
        let rig = try Rig(allow: ["deb.debian.org"])
        rig.establish()
        let query = rig.query(Wire.name("example.com"), id: 0x4242, sport: 5353)
        guard case .reply(let reply) = rig.out(query) else {
            Issue.record("no reply")
            return
        }
        #expect(Array(reply[0..<6]) == Wire.guestMAC)
        #expect(Array(reply[6..<12]) == Wire.gatewayMAC)
        #expect(Wire.u32(reply, 26) == rig.gateway)
        #expect(Wire.u32(reply, 30) == rig.lease)
        #expect(Wire.ipChecksumValid(reply))
        #expect(Wire.udpChecksumValid(reply))
        let l4 = 34
        #expect(Wire.u16(reply, l4) == 53)
        #expect(Wire.u16(reply, l4 + 2) == 5353)
        let dns = Array(reply[(l4 + 8)...])
        #expect(Wire.u16(dns, 0) == 0x4242)
        #expect(Wire.u16(dns, 2) & 0x800F == 0x8003)  // response, NXDOMAIN
        #expect(Wire.u16(dns, 2) & 0x0100 == 0x0100)  // RD copied
        #expect(Wire.u16(dns, 4) == 1)
        #expect(Wire.u16(dns, 6) == 0)
        #expect(Wire.u16(dns, 8) == 1)
        let question = Wire.name("example.com") + Wire.be16(1) + Wire.be16(1)
        #expect(Array(dns[12..<(12 + question.count)]) == question)
        // SOA under the root: TTL and minimum both the short negative TTL.
        let soa = 12 + question.count
        #expect(dns[soa] == 0)
        #expect(Wire.u16(dns, soa + 1) == 6)
        #expect(Wire.u32(dns, soa + 5) == EgressFilter.negativeTTL)
        #expect(Wire.u32(dns, dns.count - 4) == EgressFilter.negativeTTL)
        #expect(EgressFilter.negativeTTL == 3)
        #expect(rig.denials == [.name("example.com")])
    }

    @Test func allowedNameIsForwardedUnchangedAndItsAnswerLearned() throws {
        let rig = try Rig(allow: ["deb.debian.org"])
        rig.establish()
        let query = rig.query(Wire.name("DEB.Debian.org"), id: 7)
        var forwarded = query
        #expect(rig.filter.outbound(&forwarded, now: rig.now) == .forward)
        #expect(forwarded == query)
        let response = rig.answer(Wire.dnsAnswer(
            id: 7, name: Wire.name("DEB.Debian.org"),
            answers: [Wire.a(Wire.questionPointer, "151.101.2.132", ttl: 86400)]))
        let delivered = try #require(rig.inbound(response))
        // TTL lowered for the guest (never above the learner's), checksum still valid; the relay
        // learns the server's TTL (capped by the learner).
        let ttlOffset = 34 + 8 + 12 + Wire.name("deb.debian.org").count + 4 + 2 + 4
        #expect(Wire.u32(delivered, ttlOffset) == EgressFilter.forwardedMaxTTL)
        #expect(EgressFilter.forwardedMaxTTL <= UInt32(DNSLearner.maxTTL))
        #expect(rig.decision.learner.domain(for: "151.101.2.132", now: rig.now + DNSLearner.maxTTL - 1) != nil)
        #expect(Wire.udpChecksumValid(delivered))
        #expect(rig.decision.learner.domain(for: "151.101.2.132", now: rig.now) == "deb.debian.org")
        #expect(rig.out(rig.guestTCP("151.101.2.132", 443)) == .forward)
        // A flow's start is not an event: only its progress, end or cut are.
        #expect(rig.events.isEmpty)
        #expect(rig.inbound(rig.remoteTCP("151.101.2.132", 443)) != nil)
    }

    @Test func optRecordFlagsAreNotTreatedAsATTL() throws {
        let rig = try Rig(allow: ["deb.debian.org"])
        rig.establish()
        let wire = Wire.name("deb.debian.org")
        #expect(rig.out(rig.query(wire, id: 9)) == .forward)
        let dns = Wire.dnsAnswer(id: 9, name: wire, answers: [Wire.a(Wire.questionPointer, "151.101.2.132")],
                                 additional: [Wire.opt])
        let delivered = try #require(rig.inbound(rig.answer(dns)))
        #expect(Array(delivered.suffix(Wire.opt.count)) == Wire.opt)
    }

    @Test func answersNotMatchingAForwardedQueryAreDroppedAndNeverLearned() throws {
        let rig = try Rig(allow: ["deb.debian.org", "*.example.org"])
        rig.establish()
        let wire = Wire.name("deb.debian.org")
        let records = [Wire.a(Wire.questionPointer, "151.101.2.132")]
        // Never asked.
        #expect(rig.inbound(rig.answer(Wire.dnsAnswer(id: 1, name: wire, answers: records))) == nil)
        #expect(rig.out(rig.query(wire, id: 2, sport: 6000)) == .forward)
        // Wrong id, wrong port, other question, not from the gateway.
        #expect(rig.inbound(rig.answer(Wire.dnsAnswer(id: 3, name: wire, answers: records), dport: 6000)) == nil)
        #expect(rig.inbound(rig.answer(Wire.dnsAnswer(id: 2, name: wire, answers: records), dport: 6001)) == nil)
        let other = Wire.name("www.example.org")
        #expect(rig.inbound(rig.answer(Wire.dnsAnswer(
            id: 2, name: other, answers: [Wire.a(Wire.questionPointer, "151.101.2.132")]), dport: 6000)) == nil)
        #expect(rig.inbound(rig.answer(Wire.dnsAnswer(id: 2, name: wire, answers: records), dport: 6000,
                                       src: Wire.ip("192.168.66.7"))) == nil)
        #expect(rig.decision.learner.count(now: rig.now) == 0)
        // The right one is accepted once.
        #expect(rig.inbound(rig.answer(Wire.dnsAnswer(id: 2, name: wire, answers: records), dport: 6000)) != nil)
        #expect(rig.inbound(rig.answer(Wire.dnsAnswer(id: 2, name: wire, answers: records), dport: 6000)) == nil)
    }

    @Test func guestFramesNeverTeachAnything() throws {
        let rig = try Rig(allow: ["deb.debian.org"])
        rig.establish()
        let wire = Wire.name("deb.debian.org")
        // A response sent by the guest to the resolver, and one sent to itself.
        let fake = Wire.dnsAnswer(id: 5, name: wire, answers: [Wire.a(Wire.questionPointer, "151.101.2.132")])
        #expect(rig.out(rig.guestIP(dst: "192.168.66.1", Wire.udp(
            src: rig.lease, dst: rig.gateway, sport: 53, dport: 53, fake))) == .drop)
        #expect(rig.out(rig.guestIP(dst: "192.168.66.2", Wire.udp(
            src: rig.lease, dst: rig.lease, sport: 53, dport: 5353, fake))) == .drop)
        #expect(rig.decision.learner.count(now: rig.now) == 0)
        #expect(rig.out(rig.guestTCP("151.101.2.132", 443)) == .drop)
    }

    @Test func cnameChainCountsAsTheQueriedName() throws {
        let rig = try Rig(allow: ["deb.debian.org"])
        rig.establish()
        let wire = Wire.name("deb.debian.org")
        #expect(rig.out(rig.query(wire, id: 11)) == .forward)
        let cdn = Wire.name("debian.map.fastly.net")
        let dns = Wire.dnsAnswer(id: 11, name: wire, answers: [
            Wire.rr(owner: Wire.questionPointer, type: 5, ttl: 600, cdn),
            Wire.a(cdn, "151.101.2.132", ttl: 59),
            // Not on the chain: never learned.
            Wire.a(Wire.name("evil.example.com"), "93.184.215.14"),
        ])
        #expect(rig.inbound(rig.answer(dns)) != nil)
        #expect(rig.decision.learner.domains(for: "151.101.2.132", now: rig.now) == ["deb.debian.org"])
        #expect(rig.decision.learner.domain(for: "93.184.215.14", now: rig.now) == nil)
        // Learned for the learner's minimum (the path TTL of 59 s is shorter).
        #expect(rig.decision.learner.domain(for: "151.101.2.132", now: rig.now + DNSLearner.minTTL - 1) != nil)
        #expect(rig.decision.learner.domain(for: "151.101.2.132", now: rig.now + DNSLearner.minTTL) == nil)
    }

    /// apt resolves once and keeps the addresses for its whole run: a new connection five minutes
    /// after the answer (a CDN TTL of 30 s) still passes while the name is allowed, and is
    /// refused at once when it is removed.
    @Test func learnedAddressOutlivesAShortTTLButNotARemoval() throws {
        let rig = try Rig(allow: ["deb.debian.org"])
        rig.establish()
        let wire = Wire.name("deb.debian.org")
        #expect(rig.out(rig.query(wire, id: 13)) == .forward)
        let dns = Wire.dnsAnswer(id: 13, name: wire, answers: [
            Wire.a(Wire.questionPointer, "151.101.66.132", ttl: 30),
        ])
        let delivered = try #require(rig.inbound(rig.answer(dns)))
        #expect(Wire.u32(delivered, 34 + 8 + 12 + wire.count + 4 + 2 + 4) == 30)  // the guest's TTL
        rig.now += 300
        #expect(rig.out(rig.guestTCP("151.101.66.132", 443, sport: 41000)) == .forward)
        rig.filter.apply(.empty, now: rig.now)
        #expect(rig.out(rig.guestTCP("151.101.66.132", 443, sport: 41001)) == .drop)
    }

    @Test func nonLDHLabelsAreRefusedBeforeThePolicy() throws {
        let rig = try Rig(allow: ["*.debian.org"])
        rig.establish()
        // "deb\u{80}.debian.org" and "de b.debian.org" (raw bytes on the wire).
        var high = Wire.name("debx.debian.org")
        high[4] = 0x80
        var space = Wire.name("debx.debian.org")
        space[3] = 0x20
        for wire in [high, space] {
            guard case .reply(let reply) = rig.out(rig.query(wire, id: 3)) else {
                Issue.record("not refused")
                continue
            }
            #expect(Wire.u16(reply, 34 + 8 + 2) & 0x000F == 3)
        }
        // The same refusal is reported once per interval.
        #expect(rig.denials == [.invalidName])
        // Underscores and hyphens are fine.
        #expect(rig.out(rig.query(Wire.name("_dmarc.debian.org"), id: 4)) == .forward)
        #expect(rig.out(rig.query(Wire.name("deb-x.debian.org"), id: 5)) == .forward)
    }

    @Test func malformedQueriesAreDropped() throws {
        let rig = try Rig(allow: ["deb.debian.org"])
        rig.establish()
        let wire = Wire.name("deb.debian.org")
        func send(_ dns: [UInt8]) -> EgressFilter.Outbound {
            rig.out(rig.guestIP(dst: "192.168.66.1", Wire.udp(src: rig.lease, dst: rig.gateway, sport: 5353, dport: 53, dns)))
        }
        var twoQuestions = Wire.dnsQuery(id: 1, name: wire)
        twoQuestions[5] = 2
        #expect(send(twoQuestions) == .drop)
        #expect(send(Array(Wire.dnsQuery(id: 1, name: wire).prefix(20))) == .drop)
        #expect(send(Wire.dnsQuery(id: 1, name: [0xC0, 0x0C])) == .drop)  // pointer in a query
        #expect(send(Wire.dnsQuery(id: 1, name: wire, flags: 0x2900)) == .drop)  // opcode 5 (update)
        #expect(send([1, 2, 3]) == .drop)
        #expect(rig.denials.allSatisfy { $0 == .malformed })
    }

    @Test func compressionLoopsAndTruncatedAnswersDoNotCrash() throws {
        let rig = try Rig(allow: ["deb.debian.org"])
        rig.establish()
        let wire = Wire.name("deb.debian.org")
        #expect(rig.out(rig.query(wire, id: 21)) == .forward)
        // An answer whose owner points at itself.
        let selfPointer = 12 + wire.count + 4
        let looping = Wire.dnsAnswer(id: 21, name: wire, answers: [
            Wire.rr(owner: [0xC0, UInt8(selfPointer)], type: 1, ttl: 60, Wire.be32(Wire.ip("151.101.2.132")))])
        #expect(rig.inbound(rig.answer(looping)) == nil)
        #expect(rig.out(rig.query(wire, id: 22)) == .forward)
        let full = Wire.dnsAnswer(id: 22, name: wire, answers: [Wire.a(Wire.questionPointer, "151.101.2.132")])
        #expect(rig.inbound(rig.answer(Array(full.dropLast(2)))) == nil)
        #expect(rig.decision.learner.count(now: rig.now) == 0)
    }

    @Test func answerForANameRemovedMeanwhileIsDropped() throws {
        let rig = try Rig(allow: ["deb.debian.org"])
        rig.establish()
        let wire = Wire.name("deb.debian.org")
        #expect(rig.out(rig.query(wire, id: 31)) == .forward)
        rig.filter.apply(.empty, now: rig.now)
        let dns = Wire.dnsAnswer(id: 31, name: wire, answers: [Wire.a(Wire.questionPointer, "151.101.2.132")])
        #expect(rig.inbound(rig.answer(dns)) == nil)
        #expect(rig.decision.learner.count(now: rig.now) == 0)
    }

    // MARK: - Verdicts

    @Test func unknownAddressIsDeniedAndReportedOncePerInterval() throws {
        let rig = try Rig(allow: [])
        rig.establish()
        for _ in 0..<3 { #expect(rig.out(rig.guestTCP("93.184.215.14", 443)) == .drop) }
        #expect(rig.denials == [.verdict(.denyUnknown(ip: "93.184.215.14"))])
        rig.now += EgressFilter.reportInterval + 1
        #expect(rig.out(rig.guestTCP("93.184.215.14", 443)) == .drop)
        #expect(rig.denials.count == 2)
        // Another port is another report.
        #expect(rig.out(rig.guestTCP("93.184.215.14", 80)) == .drop)
        #expect(rig.denials.count == 3)
        #expect(rig.events.last?.port == 80)
        #expect(rig.events.last?.proto == .tcp)
    }

    @Test func icmpAndOtherProtocolsAreDenied() throws {
        let rig = try Rig(allow: ["deb.debian.org"])
        rig.establish()
        rig.resolve("deb.debian.org", to: ["151.101.2.132"])
        let ping = rig.guestIP(dst: "151.101.2.132", Wire.icmpEcho(src: rig.lease, dst: Wire.ip("151.101.2.132")))
        #expect(rig.out(ping) == .drop)
        #expect(rig.denials == [.verdict(.denyProto(ip: "151.101.2.132", proto: .icmp))])
        let gre = rig.guestIP(dst: "151.101.2.132", Wire.ipv4(src: rig.lease, dst: Wire.ip("151.101.2.132"), proto: 47, [0, 0, 0, 0]))
        #expect(rig.out(gre) == .drop)
        // Inbound ICMP is never delivered.
        let reply = Wire.eth(dst: Wire.guestMAC, src: Wire.gatewayMAC, type: 0x0800,
                             Wire.icmpEcho(src: Wire.ip("151.101.2.132"), dst: rig.lease))
        #expect(rig.inbound(reply) == nil)
    }

    @Test func ipv6IsDroppedBothWays() throws {
        let rig = try Rig(allow: [])
        rig.establish()
        let header: [UInt8] = [0x60, 0, 0, 0, 0, 8, 17, 64] + [UInt8](repeating: 0xFE, count: 16)
            + [0x26, 0x06, 0x47, 0x00] + [UInt8](repeating: 0, count: 11) + [1]
        let frame = Wire.eth(dst: Wire.gatewayMAC, src: Wire.guestMAC, type: 0x86DD, header + [0, 1, 0, 2, 0, 8, 0, 0])
        #expect(rig.out(frame) == .drop)
        #expect(rig.denials == [.ipv6])
        #expect(rig.events.first?.ip == "2606:4700::1")
        let advert = Wire.eth(dst: Wire.guestMAC, src: Wire.gatewayMAC, type: 0x86DD, header)
        #expect(rig.inbound(advert) == nil)
    }

    @Test func multicastAndBroadcastAreDropped() throws {
        let rig = try Rig(allow: [])
        rig.establish()
        let mdns = rig.guestIP(dst: "224.0.0.251", Wire.udp(
            src: rig.lease, dst: Wire.ip("224.0.0.251"), sport: 5353, dport: 5353, [0]),
            ethDst: [0x01, 0x00, 0x5E, 0, 0, 0xFB])
        #expect(rig.out(mdns) == .drop)
        let broadcast = rig.guestIP(dst: "255.255.255.255", Wire.udp(
            src: rig.lease, dst: 0xFFFF_FFFF, sport: 9, dport: 9, [0]), ethDst: Wire.broadcastMAC)
        #expect(rig.out(broadcast) == .drop)
        let subnetBroadcast = rig.guestUDP("192.168.66.255", 9)
        #expect(rig.out(subnetBroadcast) == .drop)
        #expect(rig.denials == [.broadcast, .broadcast, .broadcast])
    }

    @Test func dnsAndDoTToAnyOtherServerAreDropped() throws {
        let rig = try Rig(allow: ["dns.google"])
        rig.establish()
        rig.resolve("dns.google", to: ["8.8.8.8"])
        #expect(rig.out(rig.guestUDP("8.8.8.8", 53)) == .drop)
        #expect(rig.out(rig.guestTCP("8.8.8.8", 53)) == .drop)
        #expect(rig.out(rig.guestTCP("8.8.8.8", 853)) == .drop)
        #expect(rig.out(rig.guestUDP("8.8.8.8", 853)) == .drop)
        #expect(rig.denials.count == 4)
        #expect(rig.denials.allSatisfy { $0 == .dnsBypass })
        // DNS over TCP to the relay's own resolver is not answered either.
        #expect(rig.out(rig.guestTCP("192.168.66.1", 53)) == .drop)
    }

    // MARK: - Host subnet

    @Test func hostSubnetIsClosedExceptDHCPDNSAndSSH() throws {
        let rig = try Rig(allow: [])
        rig.establish()
        #expect(rig.out(rig.guestTCP("192.168.66.1", 80)) == .drop)
        #expect(rig.out(rig.guestTCP("192.168.66.1", 22)) == .drop)
        #expect(rig.out(rig.guestUDP("192.168.66.1", 5353)) == .drop)
        #expect(rig.out(rig.guestTCP("192.168.66.7", 22)) == .drop)
        #expect(rig.denials.allSatisfy { $0 == .hostSubnet })
        #expect(rig.denials.count == 4)
        // Inbound from another host of the subnet.
        let peer = Wire.eth(dst: Wire.guestMAC, src: Wire.otherMAC, type: 0x0800, Wire.tcp(
            src: Wire.ip("192.168.66.7"), dst: rig.lease, sport: 50000, dport: 22, flags: Wire.syn))
        #expect(rig.inbound(peer) == nil)
    }

    /// gvproxy's network (spike): gateway .1 serves DHCP, DNS and an unauthenticated
    /// HTTP API on port 80; .254 is NATed to the Mac's 127.0.0.1. Only DHCP and DNS may reach it.
    @Test func gvproxyNetworkIsClosedExceptDHCPAndDNS() throws {
        let rig = try Rig(allow: ["deb.debian.org"], gateway: "192.168.127.1", lease: "192.168.127.2")
        let discover = Wire.eth(dst: Wire.broadcastMAC, src: Wire.guestMAC, type: 0x0800, Wire.udp(
            src: 0, dst: 0xFFFF_FFFF, sport: 68, dport: 67, Wire.dhcp(op: 1, chaddr: Wire.guestMAC, type: 1)))
        #expect(rig.out(discover) == .forward)
        rig.establish()
        #expect(rig.filter.lease == Wire.ip("192.168.127.2"))
        let renew = rig.guestIP(dst: "192.168.127.1", Wire.udp(
            src: rig.lease, dst: rig.gateway, sport: 68, dport: 67, Wire.dhcp(op: 1, chaddr: Wire.guestMAC, type: 3)))
        #expect(rig.out(renew) == .forward)
        #expect(rig.out(rig.query(Wire.name("deb.debian.org"), id: 7)) == .forward)

        // The gateway's API (expose/unexpose forwards on the Mac).
        #expect(rig.out(rig.guestTCP("192.168.127.1", 80)) == .drop)
        #expect(rig.out(rig.guestTCP("192.168.127.1", 80, flags: Wire.ack)) == .drop)
        // The Mac's loopback through gvproxy's NAT, on any port and protocol.
        for port: UInt16 in [22, 53, 80, 443, 42022] {
            #expect(rig.out(rig.guestTCP("192.168.127.254", port)) == .drop)
            #expect(rig.out(rig.guestUDP("192.168.127.254", port)) == .drop)
        }
        // Any other address of the subnet.
        for host in ["192.168.127.3", "192.168.127.100", "192.168.127.253"] {
            #expect(rig.out(rig.guestTCP(host, 443)) == .drop)
            #expect(rig.out(rig.guestUDP(host, 53)) == .drop)
        }
        #expect(!rig.denials.isEmpty)
        #expect(rig.denials.allSatisfy { $0 == .hostSubnet })
        // ARP for .254 (or any host but the gateway) never leaves either.
        let arp254 = Wire.eth(dst: Wire.broadcastMAC, src: Wire.guestMAC, type: 0x0806, Wire.arp(
            op: 1, senderMAC: Wire.guestMAC, senderIP: rig.lease, targetIP: Wire.ip("192.168.127.254")))
        #expect(rig.out(arp254) == .drop)
    }

    /// The forward of gvproxy reaches the VM from the gateway address (spike): port 22
    /// opens, anything else on the VM from the gateway is dropped.
    @Test func gvproxySSHForwardReachesPort22Only() throws {
        let rig = try Rig(allow: [], gateway: "192.168.127.1", lease: "192.168.127.2")
        rig.establish()
        func fromGateway(_ dport: UInt16, sport: UInt16 = 51000) -> [UInt8] {
            Wire.eth(dst: Wire.guestMAC, src: Wire.gatewayMAC, type: 0x0800, Wire.tcp(
                src: rig.gateway, dst: rig.lease, sport: sport, dport: dport, flags: Wire.syn))
        }
        #expect(rig.inbound(fromGateway(22)) != nil)
        let synAck = rig.guestIP(dst: "192.168.127.1", Wire.tcp(
            src: rig.lease, dst: rig.gateway, sport: 22, dport: 51000, flags: Wire.syn | Wire.ack, ack: 2))
        #expect(rig.out(synAck) == .forward)
        #expect(rig.inbound(fromGateway(80)) == nil)
        #expect(rig.inbound(fromGateway(8080, sport: 51002)) == nil)
    }

    @Test func publicNumberedHostSubnetIsClosedToo() throws {
        // The subnet is public-numbered: an allowed name resolving into it still opens nothing.
        let rig = try Rig(allow: ["lan.example.com"], gateway: "81.2.3.1", lease: "81.2.3.2")
        rig.establish()
        rig.resolve("lan.example.com", to: ["81.2.3.9"])
        #expect(rig.decision.learner.domain(for: "81.2.3.9", now: rig.now) == "lan.example.com")
        #expect(rig.out(rig.guestTCP("81.2.3.9", 443)) == .drop)
        #expect(rig.out(rig.guestTCP("81.2.3.1", 443)) == .drop)
        #expect(rig.denials == [.hostSubnet, .hostSubnet])
    }

    @Test func sshFromTheHostAndItsRepliesPass() throws {
        let rig = try Rig(allow: [])
        rig.establish()
        func fromHost(_ flags: UInt8, sport: UInt16 = 51000) -> [UInt8] {
            Wire.eth(dst: Wire.guestMAC, src: Wire.gatewayMAC, type: 0x0800, Wire.tcp(
                src: rig.gateway, dst: rig.lease, sport: sport, dport: 22, flags: flags))
        }
        func fromGuest(_ flags: UInt8, dport: UInt16 = 51000) -> [UInt8] {
            rig.guestIP(dst: "192.168.66.1", Wire.tcp(
                src: rig.lease, dst: rig.gateway, sport: 22, dport: dport, flags: flags, ack: 2))
        }
        // The guest cannot start a connection from port 22, nor answer one that does not exist.
        #expect(rig.out(fromGuest(Wire.syn)) == .drop)
        #expect(rig.out(fromGuest(Wire.syn | Wire.ack)) == .drop)
        #expect(rig.inbound(fromHost(Wire.syn)) != nil)
        #expect(rig.out(fromGuest(Wire.syn | Wire.ack)) == .forward)
        #expect(rig.inbound(fromHost(Wire.ack)) != nil)
        #expect(rig.out(fromGuest(Wire.ack)) == .forward)
        #expect(rig.out(fromGuest(Wire.syn)) == .drop)
        #expect(rig.out(fromGuest(Wire.ack, dport: 51001)) == .drop)
        // Mid-stream packets of a connection the relay never saw open are not delivered.
        #expect(rig.inbound(fromHost(Wire.ack, sport: 52000)) == nil)
        // Closed: gone after the closing grace period.
        #expect(rig.inbound(fromHost(Wire.rst)) != nil)
        rig.now += EgressFilter.closingTimeout + 1
        rig.filter.sweep(now: rig.now)
        #expect(rig.out(fromGuest(Wire.ack)) == .drop)
    }

    @Test func unsolicitedInboundIsDropped() throws {
        let rig = try Rig(allow: [])
        rig.establish()
        #expect(rig.inbound(rig.remoteTCP("93.184.215.14", 443, dport: 22, flags: Wire.syn)) == nil)
        let udp = Wire.eth(dst: Wire.guestMAC, src: Wire.gatewayMAC, type: 0x0800, Wire.udp(
            src: Wire.ip("93.184.215.14"), dst: rig.lease, sport: 53, dport: 5353, [0]))
        #expect(rig.inbound(udp) == nil)
        // Not for this guest.
        let other = Wire.eth(dst: Wire.otherMAC, src: Wire.gatewayMAC, type: 0x0806, Wire.arp(
            op: 1, senderMAC: Wire.gatewayMAC, senderIP: rig.gateway, targetIP: rig.lease))
        #expect(rig.inbound(other) == nil)
    }

    // MARK: - Malformed frames

    @Test func fragmentsAndBrokenHeadersAreDropped() throws {
        let rig = try Rig(allow: ["deb.debian.org"])
        rig.establish()
        rig.resolve("deb.debian.org", to: ["151.101.2.132"])
        let dst = Wire.ip("151.101.2.132")
        let segment = Wire.be16(40000) + Wire.be16(443) + [UInt8](repeating: 0, count: 16)
        let moreFragments = rig.guestIP(dst: "151.101.2.132", Wire.ipv4(src: rig.lease, dst: dst, proto: 6, segment, fragment: 0x2000))
        let offset = rig.guestIP(dst: "151.101.2.132", Wire.ipv4(src: rig.lease, dst: dst, proto: 6, segment, fragment: 0x0010))
        #expect(rig.out(moreFragments) == .drop)
        #expect(rig.out(offset) == .drop)
        var badLength = rig.guestTCP("151.101.2.132", 443)
        badLength[16] = 0xFF
        #expect(rig.out(badLength) == .drop)
        var badIHL = rig.guestTCP("151.101.2.132", 443)
        badIHL[14] = 0x44
        #expect(rig.out(badIHL) == .drop)
        #expect(rig.out(Array(rig.guestTCP("151.101.2.132", 443).prefix(40))) == .drop)
        let vlan = Wire.eth(dst: Wire.gatewayMAC, src: Wire.guestMAC, type: 0x8100, [0, 1, 0x08, 0x00])
        #expect(rig.out(vlan) == .drop)
        #expect(rig.out([1, 2, 3]) == .drop)
        #expect(rig.denials.allSatisfy { $0 == .malformed })
    }

    @Test func randomFramesNeverCrashOrPass() throws {
        let rig = try Rig(allow: ["deb.debian.org"])
        rig.establish()
        var generator = SystemRandomNumberGenerator()
        for round in 0..<4000 {
            let length = Int.random(in: 0...200, using: &generator)
            var frame = (0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }
            // Half of them look like the guest's IPv4 to reach the deeper parsers.
            if round % 2 == 0, frame.count >= 34 {
                frame.replaceSubrange(0..<14, with: Wire.gatewayMAC + Wire.guestMAC + [0x08, 0x00])
                frame[14] = 0x45
            }
            if case .forward = rig.out(frame) {
                // Only something that parses as allowed may pass: never an unknown TCP/UDP flow.
                #expect(frame.count >= 14)
            }
            _ = rig.inbound(frame)
        }
    }

    // MARK: - Live policy changes

    @Test func removingANameCutsItsFlowsBothWays() throws {
        let rig = try Rig(allow: ["deb.debian.org", "example.com"])
        rig.establish()
        rig.resolve("deb.debian.org", to: ["151.101.2.132"])
        rig.resolve("example.com", to: ["93.184.215.14"])
        #expect(rig.out(rig.guestTCP("151.101.2.132", 443)) == .forward)
        #expect(rig.out(rig.guestTCP("93.184.215.14", 443, sport: 40001)) == .forward)
        #expect(rig.inbound(rig.remoteTCP("93.184.215.14", 443, dport: 40001)) != nil)

        rig.filter.apply(EgressPolicy(v: 1, allow: [try DomainPattern("deb.debian.org")]), now: rig.now)
        #expect(rig.events.contains { if case .denied(.cut(domain: "example.com", _, _, 1)) = $0.kind { true } else { false } })
        // The guest's next segment of the cut flow is answered with a reset, never forwarded.
        guard case .reply = rig.out(rig.guestTCP("93.184.215.14", 443, sport: 40001, flags: Wire.ack)) else {
            Issue.record("cut flow not reset")
            return
        }
        #expect(rig.inbound(rig.remoteTCP("93.184.215.14", 443, dport: 40001, flags: Wire.ack)) == nil)
        #expect(rig.out(rig.guestTCP("151.101.2.132", 443, flags: Wire.ack)) == .forward)
        // The name is now refused.
        guard case .reply = rig.out(rig.query(Wire.name("example.com"), id: 77)) else {
            Issue.record("not refused")
            return
        }
    }

    /// A frame from the server to the guest for flow 40001 ⇄ 93.184.215.14:443.
    private func serverSegment(_ rig: Rig, seq: UInt32, flags: UInt8 = Wire.ack, _ payload: [UInt8] = []) -> [UInt8] {
        Wire.eth(dst: Wire.guestMAC, src: Wire.gatewayMAC, type: 0x0800, Wire.tcp(
            src: Wire.ip("93.184.215.14"), dst: rig.lease, sport: 443, dport: 40001, flags: flags, payload, seq: seq))
    }

    /// A download in progress when its name is removed: the guest gets a reset at once, at the
    /// next sequence number it expects, so a program waiting for data fails instead of hanging
    /// until its own TCP timeout.
    @Test func cutFlowResetsTheGuestAtOnce() throws {
        let rig = try Rig(allow: ["example.com"])
        rig.establish()
        rig.resolve("example.com", to: ["93.184.215.14"])
        #expect(rig.out(rig.guestTCP("93.184.215.14", 443, sport: 40001)) == .forward)
        #expect(rig.inbound(serverSegment(rig, seq: 1000, flags: Wire.syn | Wire.ack)) != nil)
        #expect(rig.inbound(serverSegment(rig, seq: 1001, [UInt8](repeating: 7, count: 100))) != nil)
        // An older retransmission does not move the point back.
        #expect(rig.inbound(serverSegment(rig, seq: 1001, [UInt8](repeating: 7, count: 10))) != nil)

        let resets = rig.filter.apply(.empty, now: rig.now)
        let reset = try #require(resets.first)
        #expect(resets.count == 1)
        #expect(Array(reset[0..<6]) == Wire.guestMAC)
        #expect(Array(reset[6..<12]) == Wire.gatewayMAC)
        #expect(Wire.u32(reset, 26) == Wire.ip("93.184.215.14"))
        #expect(Wire.u32(reset, 30) == rig.lease)
        #expect(Wire.u16(reset, 34) == 443)
        #expect(Wire.u16(reset, 36) == 40001)
        #expect(Wire.u32(reset, 38) == 1101)
        #expect(reset[47] == Wire.rst)
        #expect(rig.events.contains { if case .denied(.cut(domain: "example.com", _, _, 1)) = $0.kind { true } else { false } })
    }

    /// A segment the guest sends on a cut flow gets a reset at its acknowledgment number; the
    /// guest's own reset gets nothing; the mark goes with the sweep.
    @Test func cutFlowAnswersTheGuestWithAReset() throws {
        let rig = try Rig(allow: ["example.com"])
        rig.establish()
        rig.resolve("example.com", to: ["93.184.215.14"])
        #expect(rig.out(rig.guestTCP("93.184.215.14", 443, sport: 40001)) == .forward)
        rig.filter.apply(.empty, now: rig.now)
        let segment = rig.guestIP(dst: "93.184.215.14", Wire.tcp(
            src: rig.lease, dst: Wire.ip("93.184.215.14"), sport: 40001, dport: 443, flags: Wire.ack, [1, 2, 3],
            seq: 500, ack: 2222))
        guard case .reply(let reset) = rig.out(segment) else {
            Issue.record("cut flow not reset")
            return
        }
        #expect(Wire.u32(reset, 38) == 2222)
        #expect(reset[47] == Wire.rst)
        #expect(rig.out(rig.guestTCP("93.184.215.14", 443, sport: 40001, flags: Wire.rst)) == .drop)
        // Not a new flow, and no report per segment.
        #expect(rig.filter.flowCount == 0)
        #expect(rig.denials.filter { if case .cut = $0 { false } else { true } }.isEmpty)
        rig.now += EgressFilter.cutMemory
        rig.filter.sweep(now: rig.now)
        #expect(rig.out(rig.guestTCP("93.184.215.14", 443, sport: 40001, flags: Wire.ack)) == .drop)
    }

    /// A half-closed download (the guest sent its FIN, the server still sends) ends without a cut
    /// report, as a closing flow does, but the guest is still reset: otherwise it would hang.
    @Test func halfClosedFlowIsResetToo() throws {
        let rig = try Rig(allow: ["example.com"])
        rig.establish()
        rig.resolve("example.com", to: ["93.184.215.14"])
        #expect(rig.out(rig.guestTCP("93.184.215.14", 443, sport: 40001)) == .forward)
        #expect(rig.inbound(serverSegment(rig, seq: 1000, flags: Wire.syn | Wire.ack)) != nil)
        #expect(rig.out(rig.guestTCP("93.184.215.14", 443, sport: 40001, flags: Wire.fin | Wire.ack)) == .forward)
        #expect(rig.inbound(serverSegment(rig, seq: 1001, [UInt8](repeating: 7, count: 100))) != nil)

        let resets = rig.filter.apply(.empty, now: rig.now)
        #expect(resets.count == 1)
        #expect(resets.first.map { Wire.u32($0, 38) } == 1101)
        #expect(rig.denials.isEmpty)
        guard case .reply = rig.out(rig.guestTCP("93.184.215.14", 443, sport: 40001, flags: Wire.ack)) else {
            Issue.record("half-closed cut flow not reset")
            return
        }
    }

    /// Allowed again: a new connection on the same ports is a new flow, not reset.
    @Test func cutMarkDoesNotOutliveANewAllow() throws {
        let rig = try Rig(allow: ["example.com"])
        rig.establish()
        rig.resolve("example.com", to: ["93.184.215.14"])
        #expect(rig.out(rig.guestTCP("93.184.215.14", 443, sport: 40001)) == .forward)
        rig.filter.apply(.empty, now: rig.now)
        rig.filter.apply(EgressPolicy(v: 1, allow: [try DomainPattern("example.com")]), now: rig.now)
        rig.resolve("example.com", to: ["93.184.215.14"])
        #expect(rig.out(rig.guestTCP("93.184.215.14", 443, sport: 40001)) == .forward)
        #expect(rig.out(rig.guestTCP("93.184.215.14", 443, sport: 40001, flags: Wire.ack)) == .forward)
    }

    @Test func closedFlowOfARemovedNameEndsWithoutACutReport() throws {
        let rig = try Rig(allow: ["example.com"])
        rig.establish()
        rig.resolve("example.com", to: ["93.184.215.14"])
        #expect(rig.out(rig.guestTCP("93.184.215.14", 443)) == .forward)
        #expect(rig.out(rig.guestTCP("93.184.215.14", 443, flags: Wire.fin | Wire.ack)) == .forward)
        rig.filter.apply(.empty, now: rig.now)
        #expect(rig.denials.isEmpty)
        rig.now += EgressFilter.endWindow
        rig.filter.sweep(now: rig.now)
        #expect(rig.events.contains { if case .ended(domain: "example.com", _, _, 1) = $0.kind { true } else { false } })
        #expect(rig.filter.flowCount == 0)
    }

    @Test func addingANameAllowsItsNextQuery() throws {
        let rig = try Rig(allow: [])
        rig.establish()
        guard case .reply = rig.out(rig.query(Wire.name("example.com"), id: 1)) else {
            Issue.record("not refused")
            return
        }
        rig.filter.apply(EgressPolicy(v: 1, allow: [try DomainPattern("example.com")]), now: rig.now)
        #expect(rig.resolve("example.com", to: ["93.184.215.14"]) != nil)
        #expect(rig.out(rig.guestTCP("93.184.215.14", 443)) == .forward)
    }

    @Test func establishedFlowOutlivesItsDNSEntryButNotItsIdleTimeout() throws {
        let rig = try Rig(allow: ["deb.debian.org"])
        rig.establish()
        rig.resolve("deb.debian.org", to: ["151.101.2.132"], ttl: 30)
        #expect(rig.out(rig.guestUDP("151.101.2.132", 443, sport: 41000, [1, 2, 3, 4])) == .forward)
        rig.now += 60
        rig.filter.sweep(now: rig.now)
        #expect(rig.out(rig.guestUDP("151.101.2.132", 443, sport: 41000)) == .forward)
        rig.now += EgressFilter.udpIdleTimeout + 1
        rig.filter.sweep(now: rig.now)
        rig.now += EgressFilter.endWindow
        rig.filter.sweep(now: rig.now)
        #expect(rig.events.contains { if case .ended(domain: "deb.debian.org", let out, _, 1) = $0.kind { out > 0 } else { false } })
        rig.now = max(rig.now, t0 + DNSLearner.minTTL)
        // Learned entry expired too: a new packet is unknown.
        #expect(rig.out(rig.guestUDP("151.101.2.132", 443, sport: 41000)) == .drop)
    }

    @Test func blocksHaveAnItalianLineAndAllowedFlowsNone() {
        let unknown = EgressEvent(kind: .denied(.verdict(.denyUnknown(ip: "93.184.215.14"))), proto: .tcp,
                                  ip: "93.184.215.14", port: 443)
        #expect(unknown.blockDescription == "bloccato tcp verso 93.184.215.14:443: indirizzo mai risolto per un dominio permesso")
        #expect(EgressEvent(kind: .denied(.name("example.com")), proto: .udp, ip: "192.168.66.1", port: 53)
            .blockDescription == "bloccato il nome example.com: non è tra i domini permessi")
        #expect(EgressEvent(kind: .ended(domain: "deb.debian.org", bytesOut: 1, bytesIn: 2, count: 1), proto: .tcp,
                            ip: "151.101.2.132", port: 443).blockDescription == nil)
        #expect(EgressEvent(kind: .denied(.malformed), proto: .other, ip: nil, port: nil)
            .blockDescription == "bloccato un pacchetto non riconosciuto")
    }

    // MARK: - Fix round 1

    @Test func ipOptionsAreRefusedEvenInDHCP() throws {
        let rig = try Rig(allow: ["deb.debian.org"])
        rig.establish()
        rig.resolve("deb.debian.org", to: ["151.101.2.132"])
        let dst = Wire.ip("151.101.2.132")
        let withOptions = rig.guestIP(dst: "151.101.2.132", Wire.tcp(
            src: rig.lease, dst: dst, sport: 40000, dport: 443, flags: Wire.syn, options: [1, 1, 1, 0]))
        #expect(rig.out(withOptions) == .drop)
        #expect(rig.denials == [.malformed])
        #expect(rig.out(rig.guestTCP("151.101.2.132", 443)) == .forward)
        let inboundOptions = Wire.eth(dst: Wire.guestMAC, src: Wire.gatewayMAC, type: 0x0800, Wire.tcp(
            src: dst, dst: rig.lease, sport: 443, dport: 40000, flags: Wire.ack, options: [1, 1, 1, 0]))
        #expect(rig.inbound(inboundOptions) == nil)
        // DHCP with options is refused too, both ways; without them it passes.
        let discover = Wire.eth(dst: Wire.broadcastMAC, src: Wire.guestMAC, type: 0x0800, Wire.udp(
            src: 0, dst: 0xFFFF_FFFF, sport: 68, dport: 67, Wire.dhcp(op: 1, chaddr: Wire.guestMAC, type: 1),
            options: [0x94, 0x04, 0, 0]))
        #expect(rig.out(discover) == .drop)
        #expect(rig.denials.last == .malformed)
        let plain = Wire.eth(dst: Wire.broadcastMAC, src: Wire.guestMAC, type: 0x0800, Wire.udp(
            src: 0, dst: 0xFFFF_FFFF, sport: 68, dport: 67, Wire.dhcp(op: 1, chaddr: Wire.guestMAC, type: 1)))
        #expect(rig.out(plain) == .forward)
        let ack = Wire.eth(dst: Wire.broadcastMAC, src: Wire.gatewayMAC, type: 0x0800, Wire.udp(
            src: rig.gateway, dst: 0xFFFF_FFFF, sport: 67, dport: 68,
            Wire.dhcp(op: 2, chaddr: Wire.guestMAC, yiaddr: rig.lease, type: 5), options: [0x94, 0x04, 0, 0]))
        #expect(rig.inbound(ack) == nil)
    }

    @Test func optRecordMustCarryNoData() throws {
        let rig = try Rig(allow: ["deb.debian.org"])
        rig.establish()
        let wire = Wire.name("deb.debian.org")
        func send(_ dns: [UInt8]) -> EgressFilter.Outbound {
            rig.out(rig.guestIP(dst: "192.168.66.1", Wire.udp(src: rig.lease, dst: rig.gateway, sport: 5353, dport: 53, dns)))
        }
        #expect(send(Wire.dnsQuery(id: 1, name: wire, additional: [Wire.opt])) == .forward)
        // Any option (here a cookie, code 10, 8 bytes) is a place to smuggle bytes: refused.
        let cookie: [UInt8] = [0, 10, 0, 8, 1, 2, 3, 4, 5, 6, 7, 8]
        let withData = [0, 0, 41, 0x04, 0xD0, 0, 0, 0, 0, 0, UInt8(cookie.count)] + cookie
        #expect(send(Wire.dnsQuery(id: 2, name: wire, additional: [withData])) == .drop)
        #expect(rig.denials.last == .malformed)
    }

    @Test func forwardedLengthEndsWithThePacket() throws {
        let rig = try Rig(allow: ["deb.debian.org"])
        rig.establish()
        rig.resolve("deb.debian.org", to: ["151.101.2.132"])
        let frame = rig.guestTCP("151.101.2.132", 443)
        var padded = frame + [UInt8](repeating: 0xEE, count: 20)
        #expect(rig.filter.outbound(&padded, now: rig.now) == .forward)
        let length = padded.withUnsafeMutableBytes { EgressFilter.forwardedLength(ByteView($0)) }
        #expect(length == frame.count)
        var arp = Wire.eth(dst: Wire.broadcastMAC, src: Wire.guestMAC, type: 0x0806, Wire.arp(
            op: 1, senderMAC: Wire.guestMAC, senderIP: rig.lease, targetIP: rig.gateway)) + [0, 0, 0, 0]
        #expect(arp.withUnsafeMutableBytes { EgressFilter.forwardedLength(ByteView($0)) } == 42)
        // A UDP length that does not end with the packet is refused.
        var udp = rig.guestUDP("151.101.2.132", 443, [1, 2, 3, 4])
        udp[34 + 5] -= 2
        #expect(rig.out(udp) == .drop)
    }

    @Test func dnsQueryWithTrailingBytesIsRefused() throws {
        let rig = try Rig(allow: ["deb.debian.org"])
        rig.establish()
        let wire = Wire.name("deb.debian.org")
        func send(_ dns: [UInt8]) -> EgressFilter.Outbound {
            rig.out(rig.guestIP(dst: "192.168.66.1", Wire.udp(src: rig.lease, dst: rig.gateway, sport: 5353, dport: 53, dns)))
        }
        #expect(send(Wire.dnsQuery(id: 1, name: wire) + [0xAA]) == .drop)
        #expect(send(Wire.dnsQuery(id: 2, name: wire, additional: [Wire.opt])) == .forward)
        #expect(send(Wire.dnsQuery(id: 3, name: wire, additional: [Wire.opt]) + [0xAA, 0xBB]) == .drop)
        // The additional record must be OPT.
        #expect(send(Wire.dnsQuery(id: 4, name: wire, additional: [Wire.a([0], "1.2.3.4")])) == .drop)
    }

    @Test func ednsSizeIsLoweredTo1232() throws {
        let rig = try Rig(allow: ["deb.debian.org"])
        rig.establish()
        var frame = rig.guestIP(dst: "192.168.66.1", Wire.udp(
            src: rig.lease, dst: rig.gateway, sport: 5353, dport: 53,
            Wire.dnsQuery(id: 9, name: Wire.name("deb.debian.org"), additional: [Wire.opt(size: 4096)])))
        #expect(rig.filter.outbound(&frame, now: rig.now) == .forward)
        #expect(Wire.u16(frame, frame.count - 11 + 3) == 1232)
        #expect(Wire.udpChecksumValid(frame))
        var small = rig.guestIP(dst: "192.168.66.1", Wire.udp(
            src: rig.lease, dst: rig.gateway, sport: 5353, dport: 53,
            Wire.dnsQuery(id: 10, name: Wire.name("deb.debian.org"), additional: [Wire.opt(size: 512)])))
        let before = small
        #expect(rig.filter.outbound(&small, now: rig.now) == .forward)
        #expect(small == before)
    }

    @Test func dhcpFieldsMustBeTheGuestsOwn() throws {
        let rig = try Rig(allow: [])
        rig.establish()
        func request(ethDst: [UInt8] = Wire.broadcastMAC, src: UInt32 = 0, dst: UInt32 = 0xFFFF_FFFF,
                     ciaddr: UInt32 = 0, giaddr: UInt32 = 0) -> [UInt8] {
            Wire.eth(dst: ethDst, src: Wire.guestMAC, type: 0x0800, Wire.udp(
                src: src, dst: dst, sport: 68, dport: 67,
                Wire.dhcp(op: 1, chaddr: Wire.guestMAC, type: 3, ciaddr: ciaddr, giaddr: giaddr)))
        }
        #expect(rig.out(request()) == .forward)
        #expect(rig.out(request(ciaddr: rig.lease)) == .forward)
        #expect(rig.out(request(ethDst: Wire.gatewayMAC, src: rig.lease, dst: rig.gateway, ciaddr: rig.lease)) == .forward)
        // Broadcast IP to a unicast MAC, a relay agent address, someone else's client address.
        #expect(rig.out(request(ethDst: Wire.otherMAC)) == .drop)
        #expect(rig.out(request(giaddr: Wire.ip("192.168.66.9"))) == .drop)
        #expect(rig.out(request(ciaddr: Wire.ip("192.168.66.9"))) == .drop)
    }

    @Test func sshSynAckMustAnswerTheMacsSyn() throws {
        let rig = try Rig(allow: [])
        rig.establish()
        func fromHost(_ flags: UInt8, seq: UInt32 = 1000) -> [UInt8] {
            Wire.eth(dst: Wire.guestMAC, src: Wire.gatewayMAC, type: 0x0800, Wire.tcp(
                src: rig.gateway, dst: rig.lease, sport: 51000, dport: 22, flags: flags, seq: seq))
        }
        func fromGuest(_ flags: UInt8, ack: UInt32) -> [UInt8] {
            rig.guestIP(dst: "192.168.66.1", Wire.tcp(
                src: rig.lease, dst: rig.gateway, sport: 22, dport: 51000, flags: flags, ack: ack))
        }
        #expect(rig.inbound(fromHost(Wire.syn, seq: 1000)) != nil)
        #expect(rig.out(fromGuest(Wire.syn | Wire.ack, ack: 5000)) == .drop)
        #expect(rig.out(fromGuest(Wire.syn | Wire.ack, ack: 1001)) == .forward)
        #expect(rig.inbound(fromHost(Wire.ack, seq: 1001)) != nil)
        #expect(rig.out(fromGuest(Wire.ack, ack: 1001)) == .forward)
        // Established: a SYN+ACK from the guest is no longer an answer to anything.
        #expect(rig.out(fromGuest(Wire.syn | Wire.ack, ack: 1001)) == .drop)
    }

    @Test func closingSSHFlowIsNotKeptAliveByTheGuest() throws {
        let rig = try Rig(allow: [])
        rig.establish()
        let fromHost = { (flags: UInt8) in
            Wire.eth(dst: Wire.guestMAC, src: Wire.gatewayMAC, type: 0x0800, Wire.tcp(
                src: rig.gateway, dst: rig.lease, sport: 51000, dport: 22, flags: flags))
        }
        let fromGuest = rig.guestIP(dst: "192.168.66.1", Wire.tcp(
            src: rig.lease, dst: rig.gateway, sport: 22, dport: 51000, flags: Wire.ack, ack: 2))
        #expect(rig.inbound(fromHost(Wire.syn)) != nil)
        #expect(rig.inbound(fromHost(Wire.ack)) != nil)
        #expect(rig.inbound(fromHost(Wire.fin | Wire.ack)) != nil)
        for _ in 0..<3 {
            rig.now += EgressFilter.closingTimeout / 3
            _ = rig.out(fromGuest)
        }
        rig.now += 1
        rig.filter.sweep(now: rig.now)
        #expect(rig.out(fromGuest) == .drop)
    }

    @Test func reportsAreCappedPerSecondWithASummary() throws {
        let rig = try Rig(allow: [])
        rig.establish()
        for port in 0..<100 { _ = rig.out(rig.guestTCP("93.184.215.14", UInt16(1000 + port))) }
        #expect(rig.events.count == EgressFilter.maxEventsPerSecond)
        #expect(EgressFilter.maxEventsPerSecond == 20)
        rig.now += 1
        _ = rig.out(rig.guestTCP("93.184.215.15", 443))
        #expect(rig.events.contains(EgressEvent(kind: .suppressed(blocks: 80, flows: 0), proto: .other, ip: nil, port: nil)))
        #expect(rig.events.last?.ip == "93.184.215.15")
        // A summary still pending is given by the sweep.
        for port in 0..<30 { _ = rig.out(rig.guestTCP("93.184.215.16", UInt16(2000 + port))) }
        rig.now += 1
        rig.filter.sweep(now: rig.now)
        #expect(rig.events.last == EgressEvent(kind: .suppressed(blocks: 11, flows: 0), proto: .other, ip: nil, port: nil))
        #expect(rig.events.last?.blockDescription == "altri 11 blocchi non mostrati")
    }

    @Test func guestTTLNeverOutlivesTheLearnedEntry() throws {
        let rig = try Rig(allow: ["deb.debian.org"])
        rig.establish()
        let wire = Wire.name("deb.debian.org")
        #expect(rig.out(rig.query(wire, id: 12)) == .forward)
        let cdn = Wire.name("debian.map.fastly.net")
        let dns = Wire.dnsAnswer(id: 12, name: wire, answers: [
            Wire.rr(owner: Wire.questionPointer, type: 5, ttl: 10, cdn),
            Wire.a(cdn, "151.101.2.132", ttl: 300),
        ])
        let delivered = try #require(rig.inbound(rig.answer(dns)))
        let first = 34 + 8 + 12 + wire.count + 4
        let cnameTTL = Wire.u32(delivered, first + 2 + 4)
        let aTTL = Wire.u32(delivered, first + 2 + 10 + cdn.count + cdn.count + 4)
        #expect(cnameTTL == 10 && aTTL == 10)
        // Learned for at least the learner's minimum, so far longer than the guest caches it.
        #expect(DNSLearner.minTTL >= TimeInterval(EgressFilter.forwardedMaxTTL))
        #expect(rig.decision.learner.domain(for: "151.101.2.132", now: rig.now + DNSLearner.minTTL - 1) != nil)
    }

    @Test func flowTableStaysBounded() throws {
        let rig = try Rig(allow: ["deb.debian.org"])
        rig.establish()
        rig.resolve("deb.debian.org", to: ["151.101.2.132"])
        for port in 0..<(EgressFilter.maxFlows + 50) {
            _ = rig.out(rig.guestUDP("151.101.2.132", 443, sport: UInt16(1024 + port)))
        }
        #expect(rig.filter.flowCount <= EgressFilter.maxFlows)
    }

    // MARK: - Event pools

    /// A denial flood never swallows a flow's lifecycle: cuts and ends have their own budget.
    @Test func cutsAreNeverLostInADenialFlood() throws {
        let rig = try Rig(allow: ["deb.debian.org"])
        rig.establish()
        rig.resolve("deb.debian.org", to: ["151.101.2.132"])
        #expect(rig.out(rig.guestTCP("151.101.2.132", 443)) == .forward)
        for port in 0..<100 { _ = rig.out(rig.guestTCP("93.184.215.14", UInt16(1000 + port))) }
        rig.filter.apply(.empty, now: rig.now)
        #expect(rig.events.contains {
            if case .denied(.cut(domain: "deb.debian.org", _, _, 1)) = $0.kind { true } else { false }
        })
        rig.now += 1
        rig.filter.sweep(now: rig.now)
        // The summary counts only denials.
        #expect(rig.events.last == EgressEvent(kind: .suppressed(blocks: 80, flows: 0), proto: .other, ip: nil, port: nil))
    }

    /// Noise that is never notified (multicast, broadcast, local IPv6, 169.254.255.255, malformed
    /// without an address) has a budget of its own: a flood of it never turns a real, notifiable
    /// denial into a summary.
    @Test func noiseFloodNeverSuppressesARealDenial() throws {
        let rig = try Rig(allow: [])
        rig.establish()
        #expect(EgressFilter.maxNoiseEventsPerSecond == 10)
        for port in 0..<100 { _ = rig.out(rig.guestUDP("224.0.0.251", UInt16(1000 + port))) }
        for port in 0..<5 { _ = rig.out(rig.guestUDP("169.254.255.255", UInt16(2000 + port))) }
        #expect(rig.events.count == EgressFilter.maxNoiseEventsPerSecond)
        _ = rig.out(rig.guestTCP("93.184.215.14", 443))
        let real = try #require(rig.events.last)
        #expect(real.kind == .denied(.verdict(.denyUnknown(ip: "93.184.215.14"))))
        #expect(real.ip == "93.184.215.14" && real.port == 443)
        rig.now += 1
        rig.filter.sweep(now: rig.now)
        // The noise left out is counted apart: no lost block to notify.
        #expect(rig.events.last == EgressEvent(
            kind: .suppressed(blocks: 0, flows: 0, noise: 105 - EgressFilter.maxNoiseEventsPerSecond),
            proto: .other, ip: nil, port: nil))
        #expect(rig.events.last?.blockDescription == "altri 95 pacchetti locali (multicast, broadcast) non mostrati")
    }

    @Test func noiseIsTheNeverNotifiedDenials() {
        func event(_ denial: EgressDenial, _ ip: String?) -> EgressEvent {
            EgressEvent(kind: .denied(denial), proto: .udp, ip: ip, port: 5353)
        }
        #expect(event(.broadcast, "224.0.0.251").pool == .noise)
        #expect(event(.ipv6, nil).pool == .noise)
        #expect(event(.ipv6, "ff02::fb").pool == .noise)
        #expect(event(.ipv6, "fe80::1").pool == .noise)
        #expect(event(.ipv6, "2001:db8::1").pool == .denial)
        #expect(event(.malformed, nil).pool == .noise)
        #expect(event(.malformed, "8.8.8.8").pool == .denial)
        #expect(event(.verdict(.denyUnknown(ip: "169.254.255.255")), "169.254.255.255").pool == .noise)
        #expect(event(.verdict(.denyUnknown(ip: "169.254.255.254")), "169.254.255.254").pool == .denial)
        #expect(event(.verdict(.denyUnknown(ip: "169.254.169.254")), "169.254.169.254").pool == .denial)
        #expect(event(.name("x.example"), nil).pool == .denial)
    }

    /// Progress reports have a bounded pool of their own; what does not fit is counted.
    @Test func progressHasItsOwnBoundedPool() throws {
        let rig = try Rig(allow: ["deb.debian.org"])
        rig.establish()
        rig.resolve("deb.debian.org", to: ["151.101.2.132"])
        #expect(EgressFilter.maxFlowEventsPerSecond == 200)
        let extra = 30
        for port in 0..<(EgressFilter.maxFlowEventsPerSecond + extra) {
            _ = rig.out(rig.guestUDP("151.101.2.132", 443, sport: UInt16(1024 + port)))
        }
        #expect(rig.events.isEmpty)
        rig.now += EgressFilter.progressInterval
        rig.filter.sweep(now: rig.now)
        let progress = rig.events.filter { if case .progress = $0.kind { true } else { false } }
        #expect(progress.count == EgressFilter.maxFlowEventsPerSecond)
        // A denial in the same second still gets through: its pool is untouched.
        _ = rig.out(rig.guestTCP("93.184.215.14", 443))
        #expect(rig.denials.count == 1)
        rig.now += 1
        rig.filter.sweep(now: rig.now)
        let summary = EgressEvent(kind: .suppressed(blocks: 0, flows: extra), proto: .other, ip: nil, port: nil)
        #expect(rig.events.last == summary)
        #expect(summary.blockDescription == "altri \(extra) flussi non mostrati")
        #expect(EgressEvent(kind: .suppressed(blocks: 2, flows: 3), proto: .other, ip: nil, port: nil).blockDescription
            == "altri 2 blocchi e 3 flussi non mostrati")
    }

    /// Ends to the same destination are one report per window, with the count and byte totals.
    @Test func endsAreCoalescedPerDestination() throws {
        let rig = try Rig(allow: ["deb.debian.org"])
        rig.establish()
        rig.resolve("deb.debian.org", to: ["151.101.2.132"])
        #expect(EgressFilter.endWindow == 10)
        for sport in UInt16(40000)..<40005 {
            #expect(rig.out(rig.guestTCP("151.101.2.132", 443, sport: sport)) == .forward)
            #expect(rig.out(rig.guestTCP("151.101.2.132", 443, sport: sport, flags: Wire.fin | Wire.ack)) == .forward)
        }
        #expect(rig.out(rig.guestTCP("151.101.2.132", 80, sport: 41000, flags: Wire.fin | Wire.ack)) == .forward)
        rig.now += EgressFilter.closingTimeout
        rig.filter.sweep(now: rig.now)
        #expect(rig.events.isEmpty)
        rig.now += EgressFilter.endWindow
        rig.filter.sweep(now: rig.now)
        let ends = rig.events.compactMap { event -> (UInt16?, UInt64, Int)? in
            if case .ended(domain: "deb.debian.org", let out, _, let count) = event.kind { (event.port, out, count) } else { nil }
        }
        #expect(ends.count == 2)
        #expect(ends.contains { $0.0 == 443 && $0.1 == 400 && $0.2 == 5 })
        #expect(ends.contains { $0.0 == 80 && $0.1 == 40 && $0.2 == 1 })
        #expect(rig.events.allSatisfy { $0.ip == "151.101.2.132" && $0.proto == .tcp })
    }

    /// A removal cuts many flows of a domain in one report: count and byte totals.
    @Test func bulkCutIsOneReportPerDomain() throws {
        let rig = try Rig(allow: ["deb.debian.org", "example.com"])
        rig.establish()
        rig.resolve("deb.debian.org", to: ["151.101.2.132"])
        rig.resolve("example.com", to: ["93.184.215.14"])
        for sport in UInt16(40000)..<40050 {
            #expect(rig.out(rig.guestTCP("151.101.2.132", 443, sport: sport)) == .forward)
        }
        #expect(rig.out(rig.guestTCP("93.184.215.14", 443, sport: 41000)) == .forward)
        rig.filter.apply(.empty, now: rig.now)
        let cuts = rig.events.compactMap { event -> (String, Int, UInt64, String?)? in
            if case .denied(.cut(let domain, let out, _, let count)) = event.kind { (domain, count, out, event.ip) } else { nil }
        }
        #expect(cuts.count == 2)
        #expect(cuts.contains { $0.0 == "deb.debian.org" && $0.1 == 50 && $0.2 == 2000 && $0.3 == "151.101.2.132" })
        #expect(cuts.contains { $0.0 == "example.com" && $0.1 == 1 && $0.3 == "93.184.215.14" })
        let many = try #require(rig.events.first { if case .denied(.cut(_, _, _, 50)) = $0.kind { true } else { false } })
        #expect(many.blockDescription == "interrotti 50 flussi tcp verso deb.debian.org (151.101.2.132:443): deb.debian.org è stato tolto dai domini permessi")
    }

    /// More than 200 short flows a second to an allowed address never lose a real cut or end:
    /// every end is in some report's count, and the cut of a long flow is reported.
    @Test func shortFlowChurnNeverLosesACutOrAnEnd() throws {
        let rig = try Rig(allow: ["deb.debian.org", "example.com"])
        rig.establish()
        rig.resolve("deb.debian.org", to: ["151.101.2.132"])
        rig.resolve("example.com", to: ["93.184.215.14"])
        #expect(rig.out(rig.guestTCP("93.184.215.14", 443, sport: 1000)) == .forward)
        let perSecond = 600
        let seconds = 5
        var sport: UInt16 = 2000
        for _ in 0..<seconds {
            for index in 0..<perSecond {
                // Distinct remote ports too: the coalescing table overflows and degrades, never drops.
                let dport = UInt16(10000 + index)
                _ = rig.out(rig.guestTCP("151.101.2.132", dport, sport: sport))
                _ = rig.out(rig.guestTCP("151.101.2.132", dport, sport: sport, flags: Wire.rst))
                sport &+= 1
            }
            if rig.now == t0 + 2 {
                rig.filter.apply(EgressPolicy(v: 1, allow: [try DomainPattern("deb.debian.org")]), now: rig.now)
            }
            rig.now += 1
            rig.filter.sweep(now: rig.now)
        }
        for _ in 0..<60 {
            rig.now += 1
            rig.filter.sweep(now: rig.now)
        }
        #expect(rig.events.contains { if case .denied(.cut(domain: "example.com", _, _, 1)) = $0.kind { true } else { false } })
        let ended = rig.events.reduce(0) { total, event in
            if case .ended(_, _, _, let count) = event.kind { return total + count }
            return total
        }
        #expect(ended == perSecond * seconds)
        #expect(!rig.events.contains { if case .suppressed(_, let flows, _) = $0.kind { flows > 0 } else { false } })
    }

    /// The churn of 70 s of short flows never evicts the block lines written before it: blocks
    /// and flows rotate in separate files.
    @Test func churnDoesNotEvictEarlierBlocks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nido-churn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = VMBundle(url: dir)
        let log = try EgressLog(bundle: bundle, cap: 64 << 10)
        let rig = try Rig(allow: ["deb.debian.org"])
        rig.establish()
        rig.resolve("deb.debian.org", to: ["151.101.2.132"])
        for port in 0..<5 { _ = rig.out(rig.guestTCP("93.184.215.14", UInt16(7000 + port))) }
        var sport: UInt16 = 2000
        for _ in 0..<70 {
            for index in 0..<300 {
                let dport = UInt16(10000 + index)
                _ = rig.out(rig.guestTCP("151.101.2.132", dport, sport: sport))
                _ = rig.out(rig.guestTCP("151.101.2.132", dport, sport: sport, flags: Wire.rst))
                sport &+= 1
            }
            rig.now += 1
            rig.filter.sweep(now: rig.now)
        }
        for event in rig.events { log.record(event, time: Date()) }
        // Flow lines beyond what the flow file holds, written after the blocks.
        let filler = EgressLogEntry(time: Date(), domain: "deb.debian.org", ip: "151.101.2.132", port: 443,
                                    proto: .tcp, bytesOut: 1, bytesIn: 1, verdict: .allowed, count: 1)
        for _ in 0..<5000 { log.append(filler) }
        log.close()
        let entries = EgressLog.readEntries(bundle: bundle)
        let early = entries.filter { $0.verdict == .denyUnknown && $0.ip == "93.184.215.14" }
        #expect(early.count == 5)
        #expect(entries.contains { $0.verdict == .allowed })
        #expect(try Data(contentsOf: bundle.egressLogURL).count < 64 << 10)
    }

    // MARK: - Fix round 1

    /// A refusal answers the EDNS the query spoke: one OPT (size 1232, DO copied, no data), so
    /// the guest's resolver never decides the server lacks EDNS.
    @Test func nxdomainCarriesOPTWhenTheQueryDid() throws {
        let rig = try Rig(allow: [])
        rig.establish()
        func refusal(_ dns: [UInt8]) -> [UInt8]? {
            let frame = rig.guestIP(dst: "192.168.66.1", Wire.udp(src: rig.lease, dst: rig.gateway, sport: 5353, dport: 53, dns))
            guard case .reply(let reply) = rig.out(frame) else { return nil }
            #expect(Wire.udpChecksumValid(reply) && Wire.ipChecksumValid(reply))
            return Array(reply[42...])
        }
        let withDO: [UInt8] = [0] + Wire.be16(41) + Wire.be16(4096) + [0, 0, 0x80, 0] + Wire.be16(0)
        let dns = try #require(refusal(Wire.dnsQuery(id: 1, name: Wire.name("example.com"), additional: [withDO])))
        #expect(Wire.u16(dns, 2) & 0x000F == 3)
        #expect(Wire.u16(dns, 10) == 1)
        #expect(Array(dns.suffix(11)) == [0, 0, 41, 0x04, 0xD0, 0, 0, 0x80, 0, 0, 0])
        let noDO = try #require(refusal(Wire.dnsQuery(id: 2, name: Wire.name("example.org"), additional: [Wire.opt(size: 512)])))
        #expect(Array(noDO.suffix(11)) == [0, 0, 41, 0x04, 0xD0, 0, 0, 0, 0, 0, 0])
        // An invalid name with OPT too.
        var invalid = Wire.name("debx.debian.org")
        invalid[4] = 0x80
        let bad = try #require(refusal(Wire.dnsQuery(id: 3, name: invalid, additional: [withDO])))
        #expect(Wire.u16(bad, 10) == 1)
        #expect(Array(bad.suffix(11)) == [0, 0, 41, 0x04, 0xD0, 0, 0, 0x80, 0, 0, 0])
        // Without OPT: none.
        let plain = try #require(refusal(Wire.dnsQuery(id: 4, name: Wire.name("example.net"))))
        #expect(Wire.u16(plain, 10) == 0)
        #expect(Wire.u32(plain, plain.count - 4) == EgressFilter.negativeTTL)
    }

    /// Repeats the limiter held back are counted and carried by the next report of the same block.
    @Test func limiterRepeatsRideOnTheNextReport() throws {
        let rig = try Rig(allow: [])
        rig.establish()
        for _ in 0..<5 { _ = rig.out(rig.guestTCP("93.184.215.14", 443)) }
        #expect(rig.events.count == 1 && rig.events[0].repeats == 0)
        rig.now += EgressFilter.reportInterval
        rig.filter.sweep(now: rig.now)
        rig.now += 20
        rig.filter.sweep(now: rig.now)
        _ = rig.out(rig.guestTCP("93.184.215.14", 443))
        #expect(rig.events.count == 2)
        #expect(rig.events[1].repeats == 4)
        #expect(rig.events[1].blockDescription?.hasSuffix("(e altre 4 volte prima)") == true)
    }

    /// A long flow is not silent until it ends: the sweep reports its totals so far.
    @Test func longFlowsReportProgress() throws {
        let rig = try Rig(allow: ["deb.debian.org"])
        rig.establish()
        rig.resolve("deb.debian.org", to: ["151.101.2.132"])
        #expect(EgressFilter.progressInterval == 60)
        #expect(rig.out(rig.guestTCP("151.101.2.132", 443)) == .forward)
        func progress() -> [EgressEvent] {
            rig.events.filter { if case .progress = $0.kind { true } else { false } }
        }
        rig.now += 30
        #expect(rig.inbound(rig.remoteTCP("151.101.2.132", 443, flags: Wire.ack)) != nil)
        rig.filter.sweep(now: rig.now)
        #expect(progress().isEmpty)
        rig.now += 31
        #expect(rig.out(rig.guestTCP("151.101.2.132", 443, flags: Wire.ack)) == .forward)
        rig.filter.sweep(now: rig.now)
        let first = try #require(progress().first)
        guard case .progress(domain: "deb.debian.org", let out, let into) = first.kind else {
            Issue.record("unexpected \(first)")
            return
        }
        #expect(out == 80 && into == 40)
        #expect(first.ip == "151.101.2.132" && first.port == 443 && first.proto == .tcp)
        #expect(first.blockDescription == nil)
        // Not again before another interval.
        rig.now += 10
        rig.filter.sweep(now: rig.now)
        #expect(progress().count == 1)
    }

    // MARK: - CNAME targets (fix round 1)

    /// Answers `name` (type `type`) with a CNAME to `target` (ttl `cnameTTL`) and, for an A
    /// query, an A record under the target.
    private func answerWithCNAME(_ rig: Rig, id: UInt16, name: String, target: String, cnameTTL: UInt32 = 40,
                                 type: UInt16 = 1, address: String = "151.101.2.132") -> [UInt8]?
    {
        let wire = Wire.name(name)
        let cdn = Wire.name(target)
        var answers = [Wire.rr(owner: Wire.questionPointer, type: 5, ttl: cnameTTL, cdn)]
        if type == 1 { answers.append(Wire.a(cdn, address, ttl: 300)) }
        return rig.inbound(rig.answer(Wire.dnsAnswer(id: id, name: wire, type: type, answers: answers)))
    }

    private func isRefusal(_ outbound: EgressFilter.Outbound) -> Bool {
        if case .reply = outbound { true } else { false }
    }

    /// A CNAME target of an allowed name, learned from a forwarded answer, may be asked directly
    /// while it is live (the guest's resolver does so when its cache keeps the CNAME longer than
    /// the address); what it resolves to is learned under the allowed name.
    @Test func cnameTargetIsAskableWhileLive() throws {
        let rig = try Rig(allow: ["deb.debian.org", "example.com"])
        rig.establish()
        let cdn = Wire.name("debian.map.fastly.net")
        #expect(isRefusal(rig.out(rig.query(cdn, id: 1))))
        #expect(rig.out(rig.query(Wire.name("deb.debian.org"), id: 2)) == .forward)
        #expect(answerWithCNAME(rig, id: 2, name: "deb.debian.org", target: "debian.map.fastly.net") != nil)

        // Asked directly: forwarded, and its answer learned under deb.debian.org.
        #expect(rig.out(rig.query(cdn, id: 3)) == .forward)
        let direct = Wire.dnsAnswer(id: 3, name: cdn, answers: [Wire.a(Wire.questionPointer, "151.101.2.200")])
        #expect(rig.inbound(rig.answer(direct)) != nil)
        #expect(rig.decision.learner.domains(for: "151.101.2.200", now: rig.now) == ["deb.debian.org"])
        #expect(rig.out(rig.guestTCP("151.101.2.200", 443)) == .forward)
        #expect(rig.denials.count == 1)  // only the refusal before the alias existed

        // Expired with the chain's TTL (40 s): refused again.
        rig.now += 41
        rig.filter.sweep(now: rig.now)
        #expect(isRefusal(rig.out(rig.query(cdn, id: 4))))

        // Learned again, then its domain is removed: refused at once.
        #expect(rig.out(rig.query(Wire.name("deb.debian.org"), id: 5)) == .forward)
        #expect(answerWithCNAME(rig, id: 5, name: "deb.debian.org", target: "debian.map.fastly.net") != nil)
        #expect(rig.out(rig.query(cdn, id: 6)) == .forward)
        rig.filter.apply(EgressPolicy(v: 1, allow: [try DomainPattern("example.com")]), now: rig.now)
        #expect(rig.filter.aliasCount == 0)
        #expect(isRefusal(rig.out(rig.query(cdn, id: 7))))
        // An answer to the query forwarded before the removal teaches nothing.
        let late = Wire.dnsAnswer(id: 6, name: cdn, answers: [Wire.a(Wire.questionPointer, "151.101.2.201")])
        #expect(rig.inbound(rig.answer(late)) == nil)
        #expect(rig.decision.learner.domain(for: "151.101.2.201", now: rig.now) == nil)
    }

    /// The guest asks AAAA as well: a CNAME in that answer is an alias too, and so is the next
    /// link of a chain reached through an alias.
    @Test func cnameTargetsFromAnyAnswerAndChainsAreAliases() throws {
        let rig = try Rig(allow: ["deb.debian.org"])
        rig.establish()
        #expect(rig.out(rig.query(Wire.name("deb.debian.org"), id: 1, type: 28)) == .forward)
        #expect(answerWithCNAME(rig, id: 1, name: "deb.debian.org", target: "debian.map.fastly.net", type: 28) != nil)
        let cdn = Wire.name("debian.map.fastly.net")
        #expect(rig.out(rig.query(cdn, id: 2)) == .forward)
        #expect(answerWithCNAME(rig, id: 2, name: "debian.map.fastly.net", target: "edge.fastly.net") != nil)
        #expect(rig.out(rig.query(Wire.name("edge.fastly.net"), id: 3)) == .forward)
        #expect(rig.decision.learner.domains(for: "151.101.2.132", now: rig.now) == ["deb.debian.org"])
    }

    /// Only answers to queries the relay forwarded teach aliases: an unsolicited or mismatched
    /// answer, or a frame from the guest, does not.
    @Test func forgedAnswersAddNoAlias() throws {
        let rig = try Rig(allow: ["deb.debian.org"])
        rig.establish()
        // Never asked.
        #expect(answerWithCNAME(rig, id: 9, name: "deb.debian.org", target: "evil.example.net") == nil)
        // Asked, but another transaction id.
        #expect(rig.out(rig.query(Wire.name("deb.debian.org"), id: 10)) == .forward)
        #expect(answerWithCNAME(rig, id: 11, name: "deb.debian.org", target: "evil.example.net") == nil)
        // From the guest.
        let fake = Wire.dnsAnswer(id: 10, name: Wire.name("deb.debian.org"), answers: [
            Wire.rr(owner: Wire.questionPointer, type: 5, ttl: 300, Wire.name("evil.example.net"))])
        #expect(rig.out(rig.guestIP(dst: "192.168.66.1", Wire.udp(
            src: rig.lease, dst: rig.gateway, sport: 53, dport: 53, fake))) == .drop)
        #expect(rig.filter.aliasCount == 0)
        #expect(isRefusal(rig.out(rig.query(Wire.name("evil.example.net"), id: 12))))
    }

    @Test func aliasesAreBounded() throws {
        let rig = try Rig(allow: ["deb.debian.org"])
        rig.establish()
        // A long chain in one answer: only the first links count.
        #expect(rig.out(rig.query(Wire.name("deb.debian.org"), id: 1)) == .forward)
        var answers: [[UInt8]] = []
        var owner = Wire.questionPointer
        for link in 0..<20 {
            let target = Wire.name("c\(link).cdn.example.net")
            answers.append(Wire.rr(owner: owner, type: 5, ttl: 300, target))
            owner = target
        }
        answers.append(Wire.a(owner, "151.101.2.132"))
        #expect(rig.inbound(rig.answer(Wire.dnsAnswer(id: 1, name: Wire.name("deb.debian.org"), answers: answers))) != nil)
        #expect(rig.filter.aliasCount == EgressFilter.maxAliasesPerAnswer)
        // Many answers: the table never passes its cap.
        for index in 0..<(EgressFilter.maxAliases + 50) {
            let id = UInt16(100 + index)
            _ = rig.out(rig.query(Wire.name("deb.debian.org"), id: id))
            _ = answerWithCNAME(rig, id: id, name: "deb.debian.org", target: "t\(index).cdn.example.net")
        }
        #expect(rig.filter.aliasCount <= EgressFilter.maxAliases)
    }

    // MARK: - Last round

    /// `flushAll` (the relay's shutdown) reports everything held: open flows end, merged ends
    /// and cuts go out whatever their window and budget, held repeats are reported.
    @Test func flushAllReportsEverythingHeld() throws {
        let rig = try Rig(allow: ["deb.debian.org"])
        rig.establish()
        rig.resolve("deb.debian.org", to: ["151.101.2.132"])
        #expect(rig.out(rig.guestTCP("151.101.2.132", 443, sport: 40000)) == .forward)
        #expect(rig.out(rig.guestTCP("151.101.2.132", 443, sport: 40001)) == .forward)
        #expect(rig.out(rig.guestTCP("151.101.2.132", 443, sport: 40001, flags: Wire.rst)) == .forward)
        rig.now += EgressFilter.closingTimeout
        rig.filter.sweep(now: rig.now)  // 40001 ended, still inside its merge window
        for _ in 0..<4 { _ = rig.out(rig.guestTCP("93.184.215.14", 443)) }
        let before = rig.events.count
        rig.filter.flushAll(now: rig.now)
        let flushed = Array(rig.events[before...])
        let ends = flushed.compactMap { event -> Int? in
            if case .ended(domain: "deb.debian.org", _, _, let count) = event.kind { count } else { nil }
        }
        #expect(ends.reduce(0, +) == 2)
        let held = flushed.filter { if case .denied(.verdict(.denyUnknown)) = $0.kind { true } else { false } }
        #expect(held.count == 1 && held[0].repeats == 2)
        #expect(rig.filter.flowCount == 0)
    }

    /// An alias may be asked only for A, AAAA, CNAME and HTTPS records; any other type gets the
    /// NXDOMAIN (with OPT when asked with it) and is reported.
    @Test func aliasQueriesAreLimitedToAddressTypes() throws {
        let rig = try Rig(allow: ["deb.debian.org"])
        rig.establish()
        #expect(rig.out(rig.query(Wire.name("deb.debian.org"), id: 1)) == .forward)
        #expect(answerWithCNAME(rig, id: 1, name: "deb.debian.org", target: "debian.map.fastly.net") != nil)
        let cdn = Wire.name("debian.map.fastly.net")
        for (index, type) in [UInt16(1), 28, 5, 65].enumerated() {
            #expect(rig.out(rig.query(cdn, id: UInt16(10 + index), type: type)) == .forward)
        }
        let withOPT = rig.guestIP(dst: "192.168.66.1", Wire.udp(src: rig.lease, dst: rig.gateway, sport: 5353, dport: 53,
            Wire.dnsQuery(id: 20, name: cdn, type: 16, additional: [Wire.opt])))
        guard case .reply(let reply) = rig.out(withOPT) else {
            Issue.record("TXT on an alias forwarded")
            return
        }
        #expect(Wire.u16(reply, 42 + 2) & 0x000F == 3)
        #expect(Wire.u16(reply, 42 + 10) == 1)
        let refusal = try #require(rig.events.last)
        #expect(refusal.kind == .denied(.aliasQueryType(parent: "deb.debian.org", type: 16)))
        #expect(refusal.via == "debian.map.fastly.net")
        #expect(refusal.blockDescription == "bloccata una richiesta DNS di tipo 16 per debian.map.fastly.net (alias di deb.debian.org): per un alias solo A, AAAA, CNAME e HTTPS")
        // The allowed name itself keeps every type.
        #expect(rig.out(rig.query(Wire.name("deb.debian.org"), id: 21, type: 16)) == .forward)
    }

    /// A flow to an address learned through an alias is reported as "parent via target".
    @Test func flowsThroughAnAliasNameIt() throws {
        let rig = try Rig(allow: ["deb.debian.org"])
        rig.establish()
        #expect(rig.out(rig.query(Wire.name("deb.debian.org"), id: 1)) == .forward)
        #expect(answerWithCNAME(rig, id: 1, name: "deb.debian.org", target: "debian.map.fastly.net") != nil)
        let cdn = Wire.name("debian.map.fastly.net")
        #expect(rig.out(rig.query(cdn, id: 2)) == .forward)
        #expect(rig.inbound(rig.answer(Wire.dnsAnswer(id: 2, name: cdn, answers: [Wire.a(Wire.questionPointer, "151.101.2.200")]))) != nil)
        #expect(rig.out(rig.guestTCP("151.101.2.200", 443)) == .forward)
        #expect(rig.out(rig.guestTCP("151.101.2.132", 443, sport: 40001)) == .forward)
        rig.filter.flushAll(now: rig.now)
        let viaAlias = try #require(rig.events.first { $0.ip == "151.101.2.200" })
        #expect(viaAlias.via == "debian.map.fastly.net")
        let direct = try #require(rig.events.first { $0.ip == "151.101.2.132" })
        #expect(direct.via == nil)
        let entry = try #require(EgressLogEntry(event: viaAlias, time: rig.now))
        #expect(entry.domain == "deb.debian.org" && entry.via == "debian.map.fastly.net")
    }
}

/// The TLS server name (SNI) check on the first payload of TCP flows to port 443.
@Suite(.italian) struct EgressSNIFilterTests {
    private static let fastlyIP = "151.101.2.132"
    private static let psh: UInt8 = 0x08

    /// A guest segment with `payload` on an open flow: sequence 1001, acknowledging 5001.
    private func segment(_ rig: Rig, _ payload: [UInt8], dst: String = fastlyIP, dport: UInt16 = 443,
                         sport: UInt16 = 40000, flags: UInt8 = Wire.ack | psh) -> [UInt8]
    {
        rig.guestIP(dst: dst, Wire.tcp(src: rig.lease, dst: Wire.ip(dst), sport: sport, dport: dport, flags: flags,
                                       payload, seq: 1001, ack: 5001))
    }

    /// A rig with `allow`, the gateway known and deb.debian.org learned at `fastlyIP`, and a TCP
    /// connection to it on `port` opened (SYN out, SYN+ACK in).
    private func connected(allow: [String] = ["deb.debian.org"], port: UInt16 = 443, sport: UInt16 = 40000) throws
        -> Rig
    {
        let rig = try Rig(allow: allow)
        rig.establish()
        #expect(rig.resolve("deb.debian.org", to: [Self.fastlyIP]) != nil)
        #expect(rig.out(rig.guestTCP(Self.fastlyIP, port, sport: sport)) == .forward)
        #expect(rig.inbound(rig.remoteTCP(Self.fastlyIP, port, dport: sport)) != nil)
        return rig
    }

    private func sniDenials(_ rig: Rig) -> [EgressEvent] {
        rig.events.filter { if case .denied(.verdict(.denyDomain)) = $0.kind { true } else { false } }
    }

    /// Another name on the same CDN address: the segment is dropped, the guest gets a reset, the
    /// flow is cut both ways and the name is reported as `denyDomain`.
    @Test func otherNameOnAnAllowedAddressIsCutWithAReset() throws {
        let rig = try connected()
        let hello = Wire.clientHello(sni: "www.python.org")
        guard case .reply(let reset) = rig.out(segment(rig, hello)) else {
            Issue.record("not refused")
            return
        }
        // Reset from the server's address and port to the guest's, in the guest's window.
        #expect(Array(reset[0..<6]) == Wire.guestMAC && Array(reset[6..<12]) == Wire.gatewayMAC)
        #expect(Wire.u32(reset, 26) == Wire.ip(Self.fastlyIP) && Wire.u32(reset, 30) == rig.lease)
        #expect(Wire.u16(reset, 34) == 443 && Wire.u16(reset, 36) == 40000)
        #expect(Wire.u32(reset, 38) == 5001)
        #expect(reset[47] == Wire.rst)
        #expect(Wire.ipChecksumValid(reset) && Wire.tcpChecksumValid(reset))

        let denial = try #require(sniDenials(rig).first)
        #expect(denial.kind == .denied(.verdict(.denyDomain("www.python.org"))))
        #expect(denial.proto == .tcp && denial.ip == Self.fastlyIP && denial.port == 443)
        let entry = try #require(EgressLogEntry(event: denial, time: rig.now))
        #expect(entry.verdict == .denyDomain && entry.domain == "www.python.org")
        #expect(denial.blockDescription == "bloccato tcp verso 151.101.2.132:443: www.python.org non è tra i domini permessi")

        // Nothing more of that flow passes, either way, and nothing more is reported.
        #expect(rig.out(segment(rig, hello)) == .drop)
        #expect(rig.out(segment(rig, [1, 2, 3])) == .drop)
        #expect(rig.inbound(rig.remoteTCP(Self.fastlyIP, 443, flags: Wire.ack)) == nil)
        #expect(sniDenials(rig).count == 1)

        // It ends silently: no allowed line for a refused flow.
        rig.now += EgressFilter.closingTimeout + 1
        rig.filter.sweep(now: rig.now)
        rig.now += EgressFilter.endWindow
        rig.filter.sweep(now: rig.now)
        rig.filter.flushAll(now: rig.now)
        #expect(rig.filter.flowCount == 0)
        #expect(!rig.events.contains { if case .ended = $0.kind { true } else { false } })
    }

    @Test func allowedNamesPassInAnyCase() throws {
        let rig = try connected()
        #expect(rig.out(segment(rig, Wire.clientHello(sni: "DEB.Debian.ORG."))) == .forward)
        #expect(rig.out(segment(rig, [1, 2, 3])) == .forward)
        #expect(rig.inbound(rig.remoteTCP(Self.fastlyIP, 443, flags: Wire.ack)) != nil)

        let wildcard = try connected(allow: ["*.debian.org"])
        #expect(wildcard.out(segment(wildcard, Wire.clientHello(sni: "security.debian.org"))) == .forward)
        #expect(wildcard.denials.isEmpty && rig.denials.isEmpty)
    }

    /// No name, a cut ClientHello or something else than TLS: the learned domain applies.
    @Test func absentNameOrNotTLSPasses() throws {
        let rig = try connected()
        #expect(rig.out(segment(rig, Wire.clientHello(sni: nil))) == .forward)
        let cut = try connected(sport: 40001)
        #expect(cut.out(segment(cut, Array(Wire.clientHello(sni: "www.python.org").prefix(60)), sport: 40001))
                    == .forward)
        let http = try connected(sport: 40002)
        #expect(http.out(segment(http, Array("GET / HTTP/1.1\r\n\r\n".utf8), sport: 40002)) == .forward)
        #expect(rig.denials.isEmpty && cut.denials.isEmpty && http.denials.isEmpty)
    }

    /// Only the first segment carrying data is read: pure ACKs wait, later segments never are.
    @Test func onlyTheFirstPayloadSegmentIsRead() throws {
        let rig = try connected()
        #expect(rig.out(segment(rig, [], flags: Wire.ack)) == .forward)
        guard case .reply = rig.out(segment(rig, Wire.clientHello(sni: "www.python.org"))) else {
            Issue.record("the first data segment after an ACK was not read")
            return
        }

        let late = try connected()
        #expect(late.out(segment(late, Wire.clientHello(sni: nil))) == .forward)
        #expect(late.out(segment(late, Wire.clientHello(sni: "www.python.org"))) == .forward)
        #expect(late.denials.isEmpty)

        // Data on the SYN (TCP Fast Open) is the first segment.
        let fastOpen = try Rig(allow: ["deb.debian.org"])
        fastOpen.establish()
        #expect(fastOpen.resolve("deb.debian.org", to: [Self.fastlyIP]) != nil)
        guard case .reply = fastOpen.out(segment(fastOpen, Wire.clientHello(sni: "www.python.org"), flags: Wire.syn))
        else {
            Issue.record("data on the SYN was not read")
            return
        }
    }

    @Test func otherPortsAndUDPAreNotRead() throws {
        let hello = Wire.clientHello(sni: "www.python.org")
        let alternate = try connected(port: 8443)
        #expect(alternate.out(segment(alternate, hello, dport: 8443)) == .forward)
        let quic = try Rig(allow: ["deb.debian.org"])
        quic.establish()
        #expect(quic.resolve("deb.debian.org", to: [Self.fastlyIP]) != nil)
        #expect(quic.out(quic.guestUDP(Self.fastlyIP, 443, hello)) == .forward)
        #expect(alternate.denials.isEmpty && quic.denials.isEmpty)
    }

    /// The CNAME target of an allowed name, learned from its answer, is the name the guest
    /// asked: allowed while live.
    @Test func liveAliasNameCountsAsAllowed() throws {
        let rig = try Rig(allow: ["deb.debian.org"])
        rig.establish()
        let wire = Wire.name("deb.debian.org")
        let cdn = Wire.name("debian.map.fastly.net")
        #expect(rig.out(rig.query(wire, id: 1)) == .forward)
        let answers = [Wire.rr(owner: Wire.questionPointer, type: 5, ttl: 40, cdn), Wire.a(cdn, Self.fastlyIP)]
        #expect(rig.inbound(rig.answer(Wire.dnsAnswer(id: 1, name: wire, answers: answers))) != nil)
        #expect(rig.out(rig.guestTCP(Self.fastlyIP, 443)) == .forward)
        #expect(rig.out(segment(rig, Wire.clientHello(sni: "debian.map.fastly.net"))) == .forward)

        // Once the alias expires, the same name on a new connection is refused.
        rig.now += 41
        rig.filter.sweep(now: rig.now)
        #expect(rig.out(rig.guestTCP(Self.fastlyIP, 443, sport: 40001)) == .forward)
        guard case .reply = rig.out(segment(rig, Wire.clientHello(sni: "debian.map.fastly.net"), sport: 40001)) else {
            Issue.record("expired alias still allowed")
            return
        }
    }

    /// The KELVIN SIGN (U+212A) never folds into an allowed "k".
    @Test func unicodeLookalikeIsRefused() throws {
        let rig = try connected(allow: ["deb.debian.org", "kernel.org"])
        let list = Wire.serverNameExtension([(0, Array("\u{212A}ernel.org".utf8))])
        guard case .reply = rig.out(segment(rig, Wire.clientHello(sni: nil, before: [list]))) else {
            Issue.record("look-alike passed")
            return
        }
        #expect(sniDenials(rig).first?.kind == .denied(.verdict(.denyDomain("???ernel.org"))))
    }

    /// The check uses the policy in force: a name added meanwhile passes on the next connection.
    @Test func checkFollowsTheLivePolicy() throws {
        let rig = try connected()
        guard case .reply = rig.out(segment(rig, Wire.clientHello(sni: "www.python.org"))) else {
            Issue.record("not refused")
            return
        }
        rig.filter.apply(EgressPolicy(v: 1, allow: try ["deb.debian.org", "www.python.org"].map(DomainPattern.init)),
                         now: rig.now)
        #expect(rig.out(rig.guestTCP(Self.fastlyIP, 443, sport: 40001)) == .forward)
        #expect(rig.out(segment(rig, Wire.clientHello(sni: "www.python.org"), sport: 40001)) == .forward)
    }

    /// A refused flow is not cut again (nor reported) when its domain is removed.
    @Test func refusedFlowIsNotCutAgain() throws {
        let rig = try connected()
        guard case .reply = rig.out(segment(rig, Wire.clientHello(sni: "www.python.org"))) else {
            Issue.record("not refused")
            return
        }
        rig.filter.apply(.empty, now: rig.now)
        #expect(!rig.events.contains { if case .denied(.cut) = $0.kind { true } else { false } })
        #expect(rig.filter.flowCount == 0)
    }

    /// Hostile segments on port 443 of an allowed address: never a trap.
    @Test func randomPayloadsNeverTrap() throws {
        let rig = try connected()
        var generator = SplitMix(state: 0x5EED_0008)
        let hello = Wire.clientHello(sni: "deb.debian.org")
        for round in 0..<3000 {
            var payload: [UInt8]
            if round % 2 == 0 {
                payload = hello
                for _ in 0..<3 { payload[Int.random(in: 0..<payload.count, using: &generator)] = .random(in: 0...255) }
                payload = Array(payload.prefix(Int.random(in: 1...payload.count, using: &generator)))
            } else {
                payload = (0..<Int.random(in: 1...400, using: &generator)).map { _ in .random(in: 0...255) }
            }
            let sport = UInt16(41000 + round)
            _ = rig.out(rig.guestTCP(Self.fastlyIP, 443, sport: sport))
            _ = rig.out(segment(rig, payload, sport: sport))
        }
    }
}
