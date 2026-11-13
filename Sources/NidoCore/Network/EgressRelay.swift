// SPDX-License-Identifier: Apache-2.0
import Darwin
import Dispatch
import Foundation
import Synchronization

/// The Mac side of a controlled VM's network: the VM's `gvproxy` (`GvproxyUplink`) in production,
/// a fake in tests. Every method is called on the relay's queue (the one given to
/// `EgressRelay.Options.startUplink`).
protocol EgressUplink: AnyObject {
    /// The gateway (which serves DHCP and DNS) and the subnet mask, host order.
    var gateway: UInt32 { get }
    var mask: UInt32 { get }
    /// The guest's address when the uplink knows it in advance (gvproxy's static lease): seeded
    /// into the filter at start, so a restored guest that sends no DHCP is let through.
    var guestAddress: UInt32? { get }
    /// The gateway's Ethernet address when the uplink knows it in advance (gvproxy's fixed one):
    /// seeded into the filter at start, so a resumed guest that sends no ARP is let through.
    var gatewayMAC: EgressMAC? { get }
    /// Largest frame read or written.
    var maxPacketSize: Int { get }
    /// `handler` runs on the relay's queue whenever frames may be waiting.
    func onPacketsAvailable(_ handler: @escaping () -> Void)
    /// `handler` runs on the relay's queue, at most once, when the uplink is gone for good (gvproxy
    /// exited or its socket died), with an `UplinkLoss` code. Never after `stop()`.
    func onLost(_ handler: @escaping (String) -> Void)
    /// Fills up to `buffers.count` buffers (each `maxPacketSize` bytes) with waiting frames and
    /// returns their lengths; empty when nothing waits.
    func read(into buffers: [UnsafeMutableRawBufferPointer]) -> [Int]
    func write(_ frames: [UnsafeRawBufferPointer])
    func stop()
    /// `stop()` after the uplink was lost while the VM still runs: what lets `nido ssh` say the
    /// network was interrupted (the SSH forward record) stays until the plain `stop()`.
    func stopKeepingForwardRecord()
}

extension EgressUplink {
    func stopKeepingForwardRecord() { stop() }
}

/// The controlled network of one VM: relays Ethernet frames between the guest
/// (`VZFileHandleNetworkDeviceAttachment` on `guestHandle`, a unixgram socketpair) and the VM's
/// own `gvproxy` (userspace DHCP, DNS and NAT, `GvproxyUplink`), and lets through only what
/// `EgressFilter` allows. Everything runs on one serial queue. No privilege and no IP forwarding
/// on the Mac are needed.
///
/// - The policy is `egress.json` of the bundle (`EgressPolicyStore.load`), read again when the
///   bundle directory changes and every 2 s; a file that does not load keeps the last good policy.
///   The relay never writes it.
/// - Fail closed: when gvproxy does not start, `startFailure` says why and the relay still owns
///   the guest's end, discarding every frame: the VM runs without a network, never on another
///   path. When gvproxy dies later, the relay reports `.uplinkLost` and from then on drops every
///   frame both ways until the VM stops.
/// - Every reported event is written to the VM's log (`EgressLog`: blocks and cuts in
///   `egress.log`, flow lines in `egress-flows.log`), then handed to `events` (progress, ends
///   and cuts of allowed flows, every denial), on a delivery queue of its own
///   (`EgressEventPipe`). Packet contents are never reported.
public final class EgressRelay: @unchecked Sendable {
    public typealias Events = @Sendable (EgressEvent) -> Void

    /// How the relay starts; tests replace gvproxy.
    public struct Options: Sendable {
        public var events: Events?
        var startUplink: @Sendable (VMBundle, DispatchQueue) throws -> any EgressUplink

        /// The VM's own `gvproxy`, for the VM id in the bundle's `config.json`.
        public init(events: Events? = nil) {
            self.events = events
            startUplink = { bundle, queue in
                let config: VMConfig
                do {
                    config = try bundle.readConfig()
                } catch {
                    throw NidoError.controlledNetworkUnavailable(L10n.string("the VM’s configuration is unreadable"))
                }
                return try GvproxyUplink.start(bundle: bundle, vmID: config.id, queue: queue)
            }
        }

        init(events: Events? = nil, startUplink: @escaping @Sendable (DispatchQueue) throws -> any EgressUplink) {
            self.events = events
            self.startUplink = { _, queue in try startUplink(queue) }
        }
    }

    /// Frames read from either side in one go.
    static let batchSize = 32
    /// Batches one turn of a pump handles before it yields the queue (and continues in a block
    /// queued behind the others), so a flood from either side never holds off a policy reload,
    /// a removal or a shutdown.
    static let batchesPerTurn = 8
    /// The policy is read again at least this often (s), and expired state is swept.
    static let reloadInterval: TimeInterval = 2

    /// The guest's end of the socketpair, for `VZFileHandleNetworkDeviceAttachment`.
    public let guestHandle: FileHandle
    /// Why gvproxy did not start (the VM then has no network), localized; nil when it runs.
    public let startFailure: String?
    /// Why the VM's log (`EgressLog`) could not be opened (e.g. a planted symlink), nil when it
    /// was. The network runs anyway with every block in force, but blocks reach neither the
    /// log nor the app's notifications (which read the log): only `events`, when given.
    public let logFailure: String?

    /// The warning for `logFailure` (localized), shown by the VM window and by `nido start`.
    public static var logUnavailableWarning: String {
        L10n.string("Network log unavailable: blocking stays on, but blocks aren’t logged or reported.")
    }

    private let queue = DispatchQueue(label: "nido.egress", qos: .userInitiated)
    private let hostFD: Int32
    private let bundle: VMBundle
    private let uplink: (any EgressUplink)?
    private let filter: EgressFilter?
    private let pipe: EgressEventPipe?
    /// Guest-side and uplink-side frame buffers, allocated once.
    private let guestBuffers: [UnsafeMutableRawBufferPointer]
    private let uplinkBuffers: [UnsafeMutableRawBufferPointer]
    private var readSource: (any DispatchSourceRead)?
    private var directorySource: (any DispatchSourceFileSystemObject)?
    private var timer: (any DispatchSourceTimer)?
    private let stopped = Mutex(false)
    /// Set on the queue once the uplink is gone (`EgressUplink.onLost`): every frame is dropped.
    private var uplinkLost = false
    /// Times the policy file was read again (on the queue); tests wait on it instead of a clock.
    private var reloadAttemptCount = 0

    /// Starts the relay for the VM of `bundle` whose guest has `guestMAC`. Throws only when the
    /// relay itself cannot exist (an invalid MAC, no socketpair); a gvproxy failure is
    /// `startFailure`.
    public init(bundle: VMBundle, guestMAC: String, options: Options = Options()) throws {
        guard let mac = EgressMAC(guestMAC) else { throw NidoError.invalidResources(L10n.string("invalid MAC address")) }
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else {
            throw NidoError.invalidResources("socketpair: \(String(cString: strerror(errno)))")
        }
        // Apple's guidance for VZFileHandleNetworkDeviceAttachment: receive buffer >= 2x send.
        for fd in fds {
            var send: Int32 = 1 << 20
            var receive: Int32 = 4 << 20
            var noSignal: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &send, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receive, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        }
        _ = fcntl(fds[1], F_SETFL, fcntl(fds[1], F_GETFL) | O_NONBLOCK)
        _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
        _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
        guestHandle = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
        hostFD = fds[1]
        self.bundle = bundle

        var uplink: (any EgressUplink)?
        var failure: String?
        do {
            uplink = try options.startUplink(bundle, queue)
        } catch {
            if case NidoError.controlledNetworkUnavailable(let reason) = error {
                failure = reason
            } else {
                failure = error.localizedDescription
            }
        }
        self.uplink = uplink
        startFailure = failure
        let packetSize = max(uplink?.maxPacketSize ?? 1514, 1514)
        // One spare byte: a datagram longer than a frame shows up as `packetSize + 1` and is dropped.
        guestBuffers = Self.allocate(Self.batchSize, size: packetSize + 1)
        uplinkBuffers = uplink == nil ? [] : Self.allocate(Self.batchSize, size: packetSize)

        if let uplink {
            // Every event goes to the VM's egress.log first (best effort: a log that cannot be
            // opened, e.g. a planted symlink, never stops the network, and is `logFailure`),
            // then to `events`.
            let log: EgressLog?
            do {
                log = try EgressLog(bundle: bundle)
                logFailure = nil
            } catch {
                log = nil
                logFailure = error.localizedDescription
            }
            let sink = options.events
            let pipe = EgressEventPipe { event in
                log?.record(event)
                sink?(event)
            }
            self.pipe = pipe
            let events: (EgressEvent) -> Void = { pipe.post($0) }
            filter = EgressFilter(
                network: EgressNetwork(gateway: uplink.gateway, mask: uplink.mask, guestMAC: mac),
                decision: EgressDecision(policy: EgressPolicyStore.load(bundle: bundle) ?? .empty),
                events: events)
        } else {
            filter = nil
            pipe = nil
            logFailure = nil
        }
        queue.sync {
            seedLease()
            startPumps()
        }
    }

    deinit {
        teardown()
        for buffer in guestBuffers + uplinkBuffers { buffer.deallocate() }
    }

    /// Stops gvproxy and the relay; the guest's end then leads nowhere. Never waits: the teardown
    /// (which first delivers the last events to the log, however slow their consumer) runs on the
    /// relay's queue after what is already queued, and that block keeps the relay alive until it
    /// has run. Safe from the main actor. Idempotent.
    public func shutdown() {
        queue.async { self.teardown() }
    }

    /// As `shutdown`, but returns once the teardown has run and the last events reached the log
    /// (`nido start` before it exits, the macOS installer, tests). Blocks: never on the main actor.
    public func shutdownAndWait() {
        queue.sync { teardown() }
    }

    /// How many times the relay has read `egress.json` again since it started (tests).
    var reloadAttempts: Int {
        queue.sync { reloadAttemptCount }
    }

    /// The policy in force (nil without an uplink).
    var policy: EgressPolicy? {
        queue.sync { filter?.decision.policy }
    }

    /// The relay's clock: monotonic (`CLOCK_MONOTONIC`, which keeps counting while the Mac
    /// sleeps), so a change of the wall clock never stretches or shortens learned entries and
    /// flows. Only compared with itself: flows, pending queries and the learner of this relay.
    static func monotonicNow() -> Date {
        Date(timeIntervalSinceReferenceDate: Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000)
    }

    /// The guest's address the relay accepts (dotted), nil until DHCP gives one.
    var lease: String? {
        queue.sync { filter?.lease.map(DNSLearner.dotted) }
    }

    // MARK: - Pumps

    private static func allocate(_ count: Int, size: Int) -> [UnsafeMutableRawBufferPointer] {
        (0..<count).map { _ in UnsafeMutableRawBufferPointer.allocate(byteCount: size, alignment: 16) }
    }

    private func startPumps() {
        let read = DispatchSource.makeReadSource(fileDescriptor: hostFD, queue: queue)
        read.setEventHandler { [weak self] in self?.drainGuest() }
        let fd = hostFD
        read.setCancelHandler { close(fd) }
        read.resume()
        readSource = read
        guard let uplink else { return }
        uplink.onPacketsAvailable { [weak self] in self?.drainUplink() }
        uplink.onLost { [weak self] reason in self?.lose(reason) }

        let directory = open(bundle.url.path, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW)
        if directory >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: directory, eventMask: [.write, .rename, .delete, .link], queue: queue)
            source.setEventHandler { [weak self] in self?.reloadPolicy() }
            source.setCancelHandler { close(directory) }
            source.resume()
            directorySource = source
        }
        let tick = DispatchSource.makeTimerSource(queue: queue)
        tick.schedule(deadline: .now() + Self.reloadInterval, repeating: Self.reloadInterval, leeway: .milliseconds(200))
        tick.setEventHandler { [weak self] in self?.housekeeping() }
        tick.resume()
        timer = tick
    }

    /// Guest → uplink: every waiting frame goes through the filter; the allowed ones are written to
    /// the uplink in one call, synthesized answers go back to the guest. After the uplink's loss
    /// every frame is read and dropped.
    private func drainGuest() {
        guard !isStopped else { return }
        for _ in 0..<Self.batchesPerTurn {
            var lengths: [Int] = []
            while lengths.count < guestBuffers.count {
                let buffer = guestBuffers[lengths.count]
                let count = recv(hostFD, buffer.baseAddress, buffer.count, MSG_DONTWAIT)
                guard count > 0 else { break }
                lengths.append(count)
            }
            if lengths.isEmpty { return }
            if let filter, let uplink, !uplinkLost {
                let now = Self.monotonicNow()
                var forward: [UnsafeRawBufferPointer] = []
                for (index, length) in lengths.enumerated() where length <= uplink.maxPacketSize {
                    let frame = UnsafeMutableRawBufferPointer(rebasing: guestBuffers[index][0..<length])
                    switch filter.outbound(ByteView(frame), now: now) {
                    case .forward:
                        let view = ByteView(frame)
                        forward.append(UnsafeRawBufferPointer(rebasing: frame[0..<EgressFilter.forwardedLength(view)]))
                    case .drop: break
                    case .reply(let reply): sendToGuest(reply)
                    }
                }
                if !forward.isEmpty { uplink.write(forward) }
            }
            if lengths.count < guestBuffers.count { return }
        }
        // More may wait: the read source fires again, and this turn yields to what is queued.
        queue.async { [weak self] in self?.drainGuest() }
    }

    /// Uplink → guest.
    private func drainUplink() {
        guard !isStopped, !uplinkLost, let uplink, let filter else { return }
        for _ in 0..<Self.batchesPerTurn {
            let lengths = uplink.read(into: uplinkBuffers)
            if lengths.isEmpty { return }
            let now = Self.monotonicNow()
            for (index, length) in lengths.enumerated() where length > 0 && length <= uplinkBuffers[index].count {
                let frame = UnsafeMutableRawBufferPointer(rebasing: uplinkBuffers[index][0..<length])
                if filter.inbound(ByteView(frame), now: now) {
                    _ = send(hostFD, frame.baseAddress, length, MSG_DONTWAIT)
                }
            }
            if lengths.count < uplinkBuffers.count { return }
        }
        // A full batch: continue after what is queued meanwhile.
        queue.async { [weak self] in self?.drainUplink() }
    }

    private func sendToGuest(_ frame: [UInt8]) {
        _ = frame.withUnsafeBytes { send(hostFD, $0.baseAddress, $0.count, MSG_DONTWAIT) }
    }

    // MARK: - Policy and housekeeping

    private func reloadPolicy() {
        guard !isStopped, let filter else { return }
        reloadAttemptCount += 1
        // A file that does not load (link, garbage, too big...) keeps the last good policy.
        guard let policy = EgressPolicyStore.load(bundle: bundle), policy != filter.decision.policy else { return }
        // Cut connections are reset in the guest at once, not left to hang.
        for reset in filter.apply(policy, now: Self.monotonicNow()) { sendToGuest(reset) }
    }

    private func housekeeping() {
        guard !isStopped, let filter else { return }
        reloadPolicy()
        filter.sweep(now: Self.monotonicNow())
        if filter.lease == nil { seedLease() }
    }

    /// After a restore the guest keeps the address it had and sends no DHCP for a long time: the
    /// address the uplink gives the guest's MAC (gvproxy's static lease) is taken in advance. So is
    /// the gateway's MAC (gvproxy's fixed one), which the guest keeps in its ARP cache.
    private func seedLease() {
        guard let filter else { return }
        if filter.gatewayMAC == nil, let mac = uplink?.gatewayMAC { filter.seedGatewayMAC(mac) }
        guard filter.lease == nil, let address = uplink?.guestAddress else { return }
        filter.seedLease(address)
    }

    /// The uplink is gone (on the queue): reported once, then every frame is dropped both ways
    /// and the uplink is stopped (its runtime files go with it). The SSH forward record stays, its
    /// PID dead, so `nido ssh` says the network was interrupted; the VM's stop removes it.
    private func lose(_ reason: String) {
        guard !isStopped, !uplinkLost else { return }
        uplinkLost = true
        pipe?.post(EgressEvent(kind: .uplinkLost(reason: reason), proto: .other, ip: nil, port: nil))
        uplink?.stopKeepingForwardRecord()
    }

    private var isStopped: Bool { stopped.withLock { $0 } }

    /// On the queue, or from `deinit` (nothing else holds the relay then).
    private func teardown() {
        let already = stopped.withLock { stopped in
            defer { stopped = true }
            return stopped
        }
        guard !already else { return }
        // What the filter still holds (open flows, merged ends and cuts, held repeats) is
        // reported and delivered before the relay stops, so it reaches the log.
        filter?.flushAll(now: Self.monotonicNow())
        pipe?.flush()
        timer?.cancel()
        directorySource?.cancel()
        if let readSource {
            readSource.cancel()
        } else {
            close(hostFD)
        }
        uplink?.stop()
    }
}

/// Hands relay events to a consumer on its own queue, so a slow consumer never holds up the
/// relay. Denials, progress reports and ends/cuts (`EgressEvent.pool`) wait in separate pools of
/// at most `capacity` events each, so neither a flood of denials nor a churn of flows pushes out
/// the others; local noise (`EgressEvent.isLocalNoise`) waits in a pool of its own too. Beyond
/// that, events are only counted (denials as blocks, noise as noise, the rest as flows) and the
/// counts are delivered as one `.suppressed` event; summaries from the filter are added to the
/// same counts.
final class EgressEventPipe: Sendable {
    private struct State {
        var waiting: [EgressEvent] = []
        var waitingByPool: [EgressEvent.Pool: Int] = [:]
        var droppedBlocks = 0
        var droppedFlows = 0
        var droppedNoise = 0
        var draining = false
    }

    private let state = Mutex(State())
    private let capacity: Int
    private let sink: EgressRelay.Events
    private let delivery = DispatchQueue(label: "nido.egress.events", qos: .utility)

    init(capacity: Int = 1024, sink: @escaping EgressRelay.Events) {
        self.capacity = capacity
        self.sink = sink
    }

    /// Returns once every event posted before the call was handed to the consumer (the
    /// relay's shutdown, so the last events reach the log).
    func flush() {
        delivery.sync {}
    }

    /// Never blocks.
    func post(_ event: EgressEvent) {
        let start = state.withLock { state -> Bool in
            if case .suppressed(let blocks, let flows, let noise) = event.kind {
                state.droppedBlocks += blocks
                state.droppedFlows += flows
                state.droppedNoise += noise
            } else if state.waitingByPool[event.pool, default: 0] < capacity {
                state.waiting.append(event)
                state.waitingByPool[event.pool, default: 0] += 1
            } else {
                switch event.pool {
                case .denial: state.droppedBlocks += 1
                case .noise: state.droppedNoise += 1
                case .progress, .lifecycle: state.droppedFlows += 1
                }
            }
            guard !state.draining else { return false }
            state.draining = true
            return true
        }
        if start { delivery.async { self.drain() } }
    }

    private func drain() {
        while true {
            let (batch, blocks, flows, noise) = state.withLock { state -> ([EgressEvent], Int, Int, Int) in
                let taken = (state.waiting, state.droppedBlocks, state.droppedFlows, state.droppedNoise)
                state.waiting = []
                state.waitingByPool = [:]
                state.droppedBlocks = 0
                state.droppedFlows = 0
                state.droppedNoise = 0
                if taken.0.isEmpty, taken.1 == 0, taken.2 == 0, taken.3 == 0 { state.draining = false }
                return taken
            }
            if batch.isEmpty, blocks == 0, flows == 0, noise == 0 { return }
            for event in batch { sink(event) }
            if blocks > 0 || flows > 0 || noise > 0 {
                sink(EgressEvent(kind: .suppressed(blocks: blocks, flows: flows, noise: noise),
                                 proto: .other, ip: nil, port: nil))
            }
        }
    }
}
