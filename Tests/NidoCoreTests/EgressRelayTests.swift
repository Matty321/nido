// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
@testable import NidoCore

/// gvproxy stand-in: frames written by the relay are kept, frames injected are handed to the relay
/// as gvproxy would (an event on the relay's queue, then reads).
private final class FakeUplink: EgressUplink, @unchecked Sendable {
    let gateway = Wire.ip("192.168.66.1")
    let mask = Wire.ip("255.255.255.0")
    let maxPacketSize = 1514
    let guestAddress: UInt32?
    let gatewayMAC: EgressMAC?
    private let queue: DispatchQueue
    private let state = Mutex<(inbox: [[UInt8]], written: [[UInt8]], stopped: Bool)>(([], [], false))
    nonisolated(unsafe) private var handler: (() -> Void)?
    nonisolated(unsafe) private var lostHandler: ((String) -> Void)?

    init(queue: DispatchQueue, guestAddress: UInt32? = nil, gatewayMAC: EgressMAC? = nil) {
        self.queue = queue
        self.guestAddress = guestAddress
        self.gatewayMAC = gatewayMAC
    }

    func onPacketsAvailable(_ handler: @escaping () -> Void) { self.handler = handler }

    func onLost(_ handler: @escaping (String) -> Void) { lostHandler = handler }

    /// gvproxy is gone: reported on the relay's queue, as `GvproxyUplink` does.
    func lose(_ reason: String) {
        queue.async { self.lostHandler?(reason) }
    }

    func read(into buffers: [UnsafeMutableRawBufferPointer]) -> [Int] {
        state.withLock { state in
            var lengths: [Int] = []
            while !state.inbox.isEmpty, lengths.count < buffers.count {
                let frame = state.inbox.removeFirst()
                buffers[lengths.count].copyBytes(from: frame)
                lengths.append(frame.count)
            }
            return lengths
        }
    }

    func write(_ frames: [UnsafeRawBufferPointer]) {
        state.withLock { $0.written += frames.map { Array($0) } }
    }

    func stop() { state.withLock { $0.stopped = true } }

    func inject(_ frame: [UInt8]) {
        state.withLock { $0.inbox.append(frame) }
        queue.async { self.handler?() }
    }

    var written: [[UInt8]] { state.withLock { $0.written } }
    var stopped: Bool { state.withLock { $0.stopped } }
}

private final class Recorder: Sendable {
    private let events = Mutex<[EgressEvent]>([])
    func record(_ event: EgressEvent) { events.withLock { $0.append(event) } }
    var all: [EgressEvent] { events.withLock { $0 } }
}

private func makeBundle() throws -> VMBundle {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nido-relay-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return VMBundle(url: dir)
}

/// Waits up to `seconds` for `condition`.
private func eventually(_ seconds: Double = 3, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        usleep(20_000)
    }
    return condition()
}

/// The next frame the guest receives within `seconds`, or nil.
private func receive(_ fd: Int32, within seconds: Double = 2) -> [UInt8]? {
    var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    guard poll(&pollFD, 1, Int32(seconds * 1000)) == 1 else { return nil }
    var buffer = [UInt8](repeating: 0, count: 65536)
    let count = recv(fd, &buffer, buffer.count, MSG_DONTWAIT)
    return count > 0 ? Array(buffer[0..<count]) : nil
}

private func send(_ fd: Int32, _ frame: [UInt8]) {
    _ = frame.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
}

private let gateway = Wire.ip("192.168.66.1")
private let lease = Wire.ip("192.168.66.2")

private func dhcpAck() -> [UInt8] {
    Wire.eth(dst: Wire.broadcastMAC, src: Wire.gatewayMAC, type: 0x0800, Wire.udp(
        src: gateway, dst: 0xFFFF_FFFF, sport: 67, dport: 68,
        Wire.dhcp(op: 2, chaddr: Wire.guestMAC, yiaddr: lease, type: 5)))
}

private func gatewayARP() -> [UInt8] {
    Wire.eth(dst: Wire.guestMAC, src: Wire.gatewayMAC, type: 0x0806, Wire.arp(
        op: 2, senderMAC: Wire.gatewayMAC, senderIP: gateway, targetMAC: Wire.guestMAC, targetIP: lease))
}

private func query(_ name: String, id: UInt16) -> [UInt8] {
    Wire.eth(dst: Wire.gatewayMAC, src: Wire.guestMAC, type: 0x0800, Wire.udp(
        src: lease, dst: gateway, sport: 5353, dport: 53, Wire.dnsQuery(id: id, name: Wire.name(name))))
}

private let guestMACText = "52:54:00:aa:bb:cc"

@Suite(.serialized) struct EgressRelayTests {
    @Test func failedUplinkLeavesTheGuestUnconnected() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        struct Refused: Error {}
        let relay = try EgressRelay(
            bundle: bundle, guestMAC: guestMACText, options: .init(startUplink: { _ in throw Refused() }))
        defer { relay.shutdownAndWait() }
        #expect(relay.startFailure != nil)
        let guest = relay.guestHandle.fileDescriptor
        send(guest, Wire.eth(dst: Wire.broadcastMAC, src: Wire.guestMAC, type: 0x0800, Wire.udp(
            src: 0, dst: 0xFFFF_FFFF, sport: 68, dport: 67, Wire.dhcp(op: 1, chaddr: Wire.guestMAC, type: 1))))
        send(guest, query("example.com", id: 1))
        #expect(receive(guest, within: 0.5) == nil)
    }

    @Test func framesFlowThroughTheFilterBothWays() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        nonisolated(unsafe) var fake: FakeUplink?
        let recorder = Recorder()
        let relay = try EgressRelay(
            bundle: bundle, guestMAC: guestMACText,
            options: .init(events: { recorder.record($0) }, startUplink: { queue in
                let uplink = FakeUplink(queue: queue)
                fake = uplink
                return uplink
            }))
        let uplink = try #require(fake)
        #expect(relay.startFailure == nil)
        let guest = relay.guestHandle.fileDescriptor

        let discover = Wire.eth(dst: Wire.broadcastMAC, src: Wire.guestMAC, type: 0x0800, Wire.udp(
            src: 0, dst: 0xFFFF_FFFF, sport: 68, dport: 67, Wire.dhcp(op: 1, chaddr: Wire.guestMAC, type: 1)))
        send(guest, discover)
        #expect(eventually { uplink.written == [discover] })
        uplink.inject(dhcpAck())
        #expect(receive(guest) == dhcpAck())
        uplink.inject(gatewayARP())
        #expect(receive(guest) == gatewayARP())

        // Refused name: answered by the relay, nothing reaches the uplink.
        send(guest, query("example.com", id: 2))
        let reply = try #require(receive(guest))
        #expect(Wire.u16(reply, 34 + 8 + 2) & 0x000F == 3)
        #expect(uplink.written.count == 1)
        #expect(eventually { recorder.all.contains { $0.kind == .denied(.name("example.com")) } })
        // A frame the filter refuses is not delivered.
        uplink.inject(Wire.eth(dst: Wire.guestMAC, src: Wire.gatewayMAC, type: 0x0800, Wire.tcp(
            src: Wire.ip("93.184.215.14"), dst: lease, sport: 443, dport: 40000, flags: Wire.syn)))
        #expect(receive(guest, within: 0.3) == nil)

        relay.shutdown()
        #expect(eventually { uplink.stopped })
    }

    @Test func policyChangesApplyLiveAndAHostileFileKeepsTheLastGoodOne() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        nonisolated(unsafe) var fake: FakeUplink?
        let relay = try EgressRelay(
            bundle: bundle, guestMAC: guestMACText,
            options: .init(startUplink: { queue in
                let uplink = FakeUplink(queue: queue)
                fake = uplink
                return uplink
            }))
        defer { relay.shutdownAndWait() }
        let uplink = try #require(fake)
        let guest = relay.guestHandle.fileDescriptor
        uplink.inject(dhcpAck())
        uplink.inject(gatewayARP())
        #expect(receive(guest) != nil)
        #expect(receive(guest) != nil)

        send(guest, query("example.com", id: 1))
        #expect(receive(guest) != nil)  // NXDOMAIN

        try EgressPolicyStore.update(bundle: bundle) { $0.allow.append(try DomainPattern("example.com")) }
        var id: UInt16 = 10
        // Applied well within the 2 s backstop (the directory watch usually makes it immediate).
        #expect(eventually(3) {
            id += 1
            send(guest, query("example.com", id: id))
            return eventually(0.2) { uplink.written.contains(query("example.com", id: id)) }
        })

        // Garbage: the last good policy stays, once the relay has read the file again.
        try Data("{garbage".utf8).write(to: bundle.egressPolicyURL)
        let attempts = relay.reloadAttempts
        #expect(eventually(30) { relay.reloadAttempts > attempts })
        id += 1
        send(guest, query("example.com", id: id))
        #expect(eventually(1) { uplink.written.contains(query("example.com", id: id)) })

        try FileManager.default.removeItem(at: bundle.egressPolicyURL)
        try EgressPolicyStore.save(.empty, bundle: bundle)
        #expect(eventually(3) {
            id += 1
            send(guest, query("example.com", id: id))
            guard let reply = receive(guest, within: 0.2) else { return false }
            return Wire.u16(reply, 34 + 8 + 2) & 0x000F == 3
        })
    }

    @Test func leaseIsSeededFromTheUplink() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        nonisolated(unsafe) var fake: FakeUplink?
        let relay = try EgressRelay(
            bundle: bundle, guestMAC: guestMACText,
            options: .init(startUplink: { queue in
                let uplink = FakeUplink(queue: queue, guestAddress: lease)
                fake = uplink
                return uplink
            }))
        defer { relay.shutdownAndWait() }
        #expect(relay.lease == "192.168.66.2")
        _ = fake
    }

    /// A resumed guest keeps its ARP cache and sends no ARP for a while: the gateway's MAC the
    /// uplink knows in advance (gvproxy's fixed one) lets its unicast through at once.
    @Test func gatewayMACIsSeededFromTheUplink() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        try EgressPolicyStore.save(EgressPolicy(v: 1, allow: [try DomainPattern("example.com")]), bundle: bundle)
        nonisolated(unsafe) var fake: FakeUplink?
        let relay = try EgressRelay(
            bundle: bundle, guestMAC: guestMACText,
            options: .init(startUplink: { queue in
                let uplink = FakeUplink(queue: queue, guestAddress: lease, gatewayMAC: EgressMAC(bytes: Wire.gatewayMAC))
                fake = uplink
                return uplink
            }))
        defer { relay.shutdownAndWait() }
        let uplink = try #require(fake)
        // No DHCP ACK, no ARP from the gateway: the query goes out all the same.
        send(relay.guestHandle.fileDescriptor, query("example.com", id: 7))
        #expect(eventually { uplink.written.contains(query("example.com", id: 7)) })
    }

    /// gvproxy dies with the VM running: the loss is reported, and from then on nothing crosses
    /// the relay in either direction, through the uplink or any other way.
    @Test func uplinkLossDropsFramesAndReports() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        try EgressPolicyStore.save(EgressPolicy(v: 1, allow: [try DomainPattern("example.com")]), bundle: bundle)
        nonisolated(unsafe) var fake: FakeUplink?
        let recorder = Recorder()
        let relay = try EgressRelay(
            bundle: bundle, guestMAC: guestMACText,
            options: .init(events: { recorder.record($0) }, startUplink: { queue in
                let uplink = FakeUplink(queue: queue)
                fake = uplink
                return uplink
            }))
        defer { relay.shutdownAndWait() }
        let uplink = try #require(fake)
        let guest = relay.guestHandle.fileDescriptor
        uplink.inject(dhcpAck())
        uplink.inject(gatewayARP())
        #expect(receive(guest) != nil)
        #expect(receive(guest) != nil)
        // An allowed query goes out while the uplink lives.
        send(guest, query("example.com", id: 1))
        #expect(eventually { uplink.written.contains(query("example.com", id: 1)) })

        uplink.lose("gvproxy si è fermato (codice 137)")
        #expect(eventually {
            recorder.all.contains { $0.kind == .uplinkLost(reason: "gvproxy si è fermato (codice 137)") }
        })
        #expect(eventually { uplink.stopped })
        let before = uplink.written.count
        // The same allowed query, and a frame from the uplink, after the loss: dropped.
        send(guest, query("example.com", id: 2))
        uplink.inject(gatewayARP())
        #expect(receive(guest, within: 0.5) == nil)
        #expect(uplink.written.count == before)
        // A second report of the same loss is not another event.
        uplink.lose("di nuovo")
        relay.shutdownAndWait()
        #expect(recorder.all.filter { if case .uplinkLost = $0.kind { true } else { false } }.count == 1)
        // The log has the line.
        let lines = EgressLog.readEntries(bundle: bundle)
        #expect(lines.contains { $0.verdict == .uplinkLost && $0.reason == "gvproxy si è fermato (codice 137)" })
    }

    /// A guest that floods the relay cannot hold off a removal: the queue takes turns.
    @Test func floodDoesNotDelayAPolicyRemoval() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        try EgressPolicyStore.save(EgressPolicy(v: 1, allow: [try DomainPattern("example.com")]), bundle: bundle)
        nonisolated(unsafe) var fake: FakeUplink?
        let relay = try EgressRelay(
            bundle: bundle, guestMAC: guestMACText,
            options: .init(startUplink: { queue in
                let uplink = FakeUplink(queue: queue)
                fake = uplink
                return uplink
            }))
        defer { relay.shutdownAndWait() }
        _ = fake
        #expect(relay.policy?.allow.count == 1)
        let guest = relay.guestHandle.fileDescriptor
        let running = Atomic<Bool>(true)
        // Signalled once the flood is under way (this many frames sent): no wall-clock wait.
        let floodUnderWay = DispatchSemaphore(value: 0)
        let flooder = Thread {
            // Blocking sends: the guest's end is always full, as fast as the relay reads.
            let frame = Wire.eth(dst: Wire.gatewayMAC, src: Wire.otherMAC, type: 0x0800, [UInt8](repeating: 0, count: 1000))
            var sent = 0
            while running.load(ordering: .relaxed) {
                _ = frame.withUnsafeBytes { Darwin.send(guest, $0.baseAddress, $0.count, 0) }
                sent += 1
                if sent == 2000 { floodUnderWay.signal() }
            }
        }
        flooder.start()
        defer { running.store(false, ordering: .relaxed) }
        #expect(floodUnderWay.wait(timeout: .now() + 30) == .success)
        try EgressPolicyStore.update(bundle: bundle) { $0.allow = [] }
        // The first reload after the change already applies it: the flood never holds it off.
        let attempts = relay.reloadAttempts
        #expect(eventually(30) { relay.reloadAttempts > attempts })
        #expect(relay.policy?.allow.isEmpty == true)
    }

    /// Holds a pipe's consumer inside its first event until released: no wall-clock timing.
    private final class Gate: Sendable {
        private let entered = DispatchSemaphore(value: 0)
        private let opened = DispatchSemaphore(value: 0)
        private let isOpen = Atomic<Bool>(false)
        let delivered = Mutex<[EgressEvent]>([])

        /// The sink: records the event, then waits (at most 30 s) while the gate is closed.
        func sink(_ event: EgressEvent) {
            delivered.withLock { $0.append(event) }
            entered.signal()
            if !isOpen.load(ordering: .acquiring) { _ = opened.wait(timeout: .now() + 30) }
        }

        func waitEntered() -> Bool { entered.wait(timeout: .now() + 30) == .success }

        func open() {
            isOpen.store(true, ordering: .releasing)
            opened.signal()
        }

        var events: [EgressEvent] { delivered.withLock { $0 } }
    }

    /// Runs `posts` on another thread; true when it finished within 30 s.
    private func postsFinish(_ posts: @escaping @Sendable () -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0)
        Thread {
            posts()
            done.signal()
        }.start()
        return done.wait(timeout: .now() + 30) == .success
    }

    private func accounted(_ events: [EgressEvent]) -> Int {
        events.reduce(0) { total, event in
            if case .suppressed(let blocks, let flows, let noise) = event.kind { return total + blocks + flows + noise }
            return total + 1
        }
    }

    /// A consumer stuck in an event never blocks the relay: posts finish while it is held, the
    /// pool keeps `capacity` events, the excess is counted in one summary.
    @Test func slowEventConsumerNeverBlocksTheRelay() {
        let gate = Gate()
        let pipe = EgressEventPipe(capacity: 16) { gate.sink($0) }
        pipe.post(EgressEvent(kind: .denied(.dnsBypass), proto: .udp, ip: "8.8.8.8", port: 0))
        #expect(gate.waitEntered())
        #expect(postsFinish {
            for port in 1..<1000 {
                pipe.post(EgressEvent(kind: .denied(.dnsBypass), proto: .udp, ip: "8.8.8.8", port: UInt16(port)))
            }
        })
        gate.open()
        #expect(eventually(30) { accounted(gate.events) == 1000 })
        pipe.flush()
        // The held event, the full pool, one summary.
        let all = gate.events
        #expect(all.count == 1 + 16 + 1)
        #expect(all.last == EgressEvent(kind: .suppressed(blocks: 1000 - 17, flows: 0), proto: .other, ip: nil, port: nil))
    }

    /// Flow events wait in their own pool: a denial flood in a held consumer never drops a cut.
    @Test func pipeKeepsFlowEventsApartFromDenials() {
        let gate = Gate()
        let pipe = EgressEventPipe(capacity: 16) { gate.sink($0) }
        pipe.post(EgressEvent(kind: .denied(.dnsBypass), proto: .udp, ip: "8.8.8.8", port: 0))
        #expect(gate.waitEntered())
        #expect(postsFinish {
            for port in 1..<500 {
                pipe.post(EgressEvent(kind: .denied(.dnsBypass), proto: .udp, ip: "8.8.8.8", port: UInt16(port)))
            }
            for port in 0..<5 {
                pipe.post(EgressEvent(kind: .denied(.cut(domain: "deb.debian.org", bytesOut: 1, bytesIn: 2, count: 1)),
                                      proto: .tcp, ip: "151.101.2.132", port: UInt16(port)))
            }
            // A summary from the filter is merged into the pipe's own counts.
            pipe.post(EgressEvent(kind: .suppressed(blocks: 7, flows: 3), proto: .other, ip: nil, port: nil))
        })
        gate.open()
        #expect(eventually(30) { accounted(gate.events) == 500 + 5 + 10 })
        pipe.flush()
        let all = gate.events
        #expect(all.filter { if case .denied(.cut) = $0.kind { true } else { false } }.count == 5)
        #expect(all.count == 1 + 16 + 5 + 1)
        #expect(all.last == EgressEvent(kind: .suppressed(blocks: 500 - 17 + 7, flows: 3), proto: .other, ip: nil, port: nil))
    }

    /// The session shuts the relay down from the main actor: the call never waits for the
    /// teardown (here held by a consumer stuck in an event, so the final flush cannot finish).
    /// `shutdownAndWait` returns once the teardown ran.
    @MainActor @Test func shutdownNeverBlocksTheCaller() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let gate = Gate()
        nonisolated(unsafe) var fake: FakeUplink?
        let relay = try EgressRelay(
            bundle: bundle, guestMAC: guestMACText,
            options: .init(events: { gate.sink($0) }, startUplink: { queue in
                let uplink = FakeUplink(queue: queue)
                fake = uplink
                return uplink
            }))
        let uplink = try #require(fake)
        let guest = relay.guestHandle.fileDescriptor
        uplink.inject(dhcpAck())
        uplink.inject(gatewayARP())
        #expect(receive(guest) != nil)
        #expect(receive(guest) != nil)
        send(guest, query("example.com", id: 1))
        #expect(gate.waitEntered())
        relay.shutdown()
        // Returned while the teardown still waits for the consumer: the uplink is not stopped yet.
        #expect(!uplink.stopped)
        relay.shutdown()
        gate.open()
        relay.shutdownAndWait()
        #expect(uplink.stopped)
    }

    /// Local noise waits in its own pool: a multicast flood in a held consumer never drops a
    /// real denial, and its excess is counted as noise, not as blocks.
    @Test func pipeKeepsNoiseApartFromDenials() {
        let gate = Gate()
        let pipe = EgressEventPipe(capacity: 16) { gate.sink($0) }
        pipe.post(EgressEvent(kind: .denied(.dnsBypass), proto: .udp, ip: "8.8.8.8", port: 0))
        #expect(gate.waitEntered())
        #expect(postsFinish {
            for port in 0..<200 {
                pipe.post(EgressEvent(kind: .denied(.broadcast), proto: .udp, ip: "224.0.0.251", port: UInt16(port)))
            }
            pipe.post(EgressEvent(kind: .denied(.verdict(.denyUnknown(ip: "93.184.215.14"))), proto: .tcp,
                                  ip: "93.184.215.14", port: 443))
        })
        gate.open()
        #expect(eventually(30) { accounted(gate.events) == 1 + 200 + 1 })
        pipe.flush()
        let all = gate.events
        #expect(all.contains { $0.ip == "93.184.215.14" })
        #expect(all.last == EgressEvent(kind: .suppressed(blocks: 0, flows: 0, noise: 200 - 16), proto: .other,
                                        ip: nil, port: nil))
    }

    /// Shutting down writes what the relay still held: open flows end, merged ends and held
    /// repeats reach the log before the relay stops.
    @Test func shutdownFlushesTheLog() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        try EgressPolicyStore.save(EgressPolicy(v: 1, allow: [try DomainPattern("deb.debian.org")]), bundle: bundle)
        nonisolated(unsafe) var fake: FakeUplink?
        let relay = try EgressRelay(
            bundle: bundle, guestMAC: guestMACText,
            options: .init(startUplink: { queue in
                let uplink = FakeUplink(queue: queue)
                fake = uplink
                return uplink
            }))
        let uplink = try #require(fake)
        let guest = relay.guestHandle.fileDescriptor
        uplink.inject(dhcpAck())
        uplink.inject(gatewayARP())
        #expect(receive(guest) != nil)
        #expect(receive(guest) != nil)
        send(guest, query("deb.debian.org", id: 7))
        #expect(eventually { uplink.written.contains(query("deb.debian.org", id: 7)) })
        uplink.inject(Wire.eth(dst: Wire.guestMAC, src: Wire.gatewayMAC, type: 0x0800, Wire.udp(
            src: gateway, dst: lease, sport: 53, dport: 5353,
            Wire.dnsAnswer(id: 7, name: Wire.name("deb.debian.org"), answers: [Wire.a(Wire.questionPointer, "151.101.2.132")]))))
        #expect(receive(guest) != nil)
        let cdn = Wire.ip("151.101.2.132")
        let open = Wire.eth(dst: Wire.gatewayMAC, src: Wire.guestMAC, type: 0x0800,
                            Wire.tcp(src: lease, dst: cdn, sport: 40000, dport: 443, flags: Wire.syn))
        send(guest, open)
        #expect(eventually { uplink.written.contains(open) })
        // The same block three times: one report, two repeats held.
        let blocked = Wire.eth(dst: Wire.gatewayMAC, src: Wire.guestMAC, type: 0x0800,
                               Wire.tcp(src: lease, dst: Wire.ip("93.184.215.14"), sport: 40001, dport: 443, flags: Wire.syn))
        for _ in 0..<3 { send(guest, blocked) }
        #expect(eventually { EgressLog.readEntries(bundle: bundle).contains { $0.verdict == .denyUnknown } })
        relay.shutdownAndWait()
        let entries = EgressLog.readEntries(bundle: bundle)
        let ended = try #require(entries.first { $0.verdict == .allowed })
        #expect(ended.domain == "deb.debian.org" && ended.ip == "151.101.2.132" && ended.bytesOut == 40)
        let blocks = entries.filter { $0.verdict == .denyUnknown }
        #expect(blocks.reduce(0) { $0 + 1 + ($1.repeats ?? 0) } == 3)
    }

    /// The relay writes its own log (blocks at once, flows at their end or cut) without a byte
    /// of the packets' contents.
    @Test func relayLogsFlowsAndBlocksWithoutContent() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        try EgressPolicyStore.save(EgressPolicy(v: 1, allow: [try DomainPattern("deb.debian.org")]), bundle: bundle)
        nonisolated(unsafe) var fake: FakeUplink?
        let relay = try EgressRelay(
            bundle: bundle, guestMAC: guestMACText,
            options: .init(startUplink: { queue in
                let uplink = FakeUplink(queue: queue)
                fake = uplink
                return uplink
            }))
        defer { relay.shutdownAndWait() }
        let uplink = try #require(fake)
        let guest = relay.guestHandle.fileDescriptor
        uplink.inject(dhcpAck())
        uplink.inject(gatewayARP())
        #expect(receive(guest) != nil)
        #expect(receive(guest) != nil)

        let wire = Wire.name("deb.debian.org")
        send(guest, query("deb.debian.org", id: 7))
        #expect(eventually { uplink.written.contains(query("deb.debian.org", id: 7)) })
        uplink.inject(Wire.eth(dst: Wire.guestMAC, src: Wire.gatewayMAC, type: 0x0800, Wire.udp(
            src: gateway, dst: lease, sport: 53, dport: 5353,
            Wire.dnsAnswer(id: 7, name: wire, answers: [Wire.a(Wire.questionPointer, "151.101.2.132")]))))
        #expect(receive(guest) != nil)

        let secret = Array("NIDO-SECRET-PAYLOAD-4242".utf8)
        let cdn = Wire.ip("151.101.2.132")
        send(guest, Wire.eth(dst: Wire.gatewayMAC, src: Wire.guestMAC, type: 0x0800,
                             Wire.udp(src: lease, dst: cdn, sport: 40000, dport: 443, secret)))
        #expect(eventually { uplink.written.count == 2 })
        uplink.inject(Wire.eth(dst: Wire.guestMAC, src: Wire.gatewayMAC, type: 0x0800,
                               Wire.udp(src: cdn, dst: lease, sport: 443, dport: 40000, secret)))
        #expect(receive(guest) != nil)
        send(guest, Wire.eth(dst: Wire.gatewayMAC, src: Wire.guestMAC, type: 0x0800,
                             Wire.udp(src: lease, dst: Wire.ip("93.184.215.14"), sport: 40001, dport: 443, secret)))
        send(guest, query("example.com", id: 8))
        #expect(receive(guest) != nil)  // NXDOMAIN
        // Removing the domain cuts the open flow: its line carries the byte counts.
        try EgressPolicyStore.update(bundle: bundle) { $0.allow = [] }
        #expect(eventually(4) {
            EgressLog.readEntries(at: bundle.egressLogURL).contains { $0.verdict == .cut }
        })
        let entries = EgressLog.readEntries(at: bundle.egressLogURL)
        let cut = try #require(entries.first { $0.verdict == .cut })
        #expect(cut.domain == "deb.debian.org" && cut.ip == "151.101.2.132" && cut.port == 443 && cut.proto == .udp)
        #expect(cut.bytesOut == UInt64(28 + secret.count) && cut.bytesIn == UInt64(28 + secret.count))
        #expect(entries.contains { $0.verdict == .denyUnknown && $0.ip == "93.184.215.14" && $0.port == 443 })
        #expect(entries.contains { $0.verdict == .name && $0.domain == "example.com" })
        #expect(!entries.contains { $0.verdict == .allowed || $0.verdict == .open })
        let raw = try Data(contentsOf: bundle.egressLogURL)
        #expect(raw.range(of: Data(secret)) == nil)
        #expect(raw.range(of: Data("SECRET".utf8)) == nil)
        let mode = try FileManager.default.attributesOfItem(atPath: bundle.egressLogURL.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func monotonicTimeOnlyMovesForward() {
        let first = EgressRelay.monotonicNow()
        var previous = first
        var latest = first
        // Read until the clock has advanced (nanosecond resolution: a few reads), never backwards.
        for _ in 0..<10_000_000 where latest == first {
            latest = EgressRelay.monotonicNow()
            #expect(latest >= previous)
            previous = latest
        }
        #expect(latest > first)
    }

    @Test func invalidMACIsRefused() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        #expect(throws: NidoError.self) {
            try EgressRelay(bundle: bundle, guestMAC: "not-a-mac", options: .init(startUplink: { _ in
                Issue.record("started")
                throw CancellationError()
            }))
        }
    }
}
