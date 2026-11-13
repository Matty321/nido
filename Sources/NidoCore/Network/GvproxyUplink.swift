// SPDX-License-Identifier: Apache-2.0
import Darwin
import Dispatch
import Foundation
import Synchronization

/// The relay's uplink to the VM's own `gvproxy` (`GvproxyProcess`): a connected `SOCK_DGRAM` Unix
/// socket carrying one raw Ethernet frame per datagram, without handshake (spike). The
/// network is gvproxy's fixed one: gateway `192.168.127.1` (DHCP, DNS), mask `/24`, and the guest
/// on its static lease `192.168.127.2`. Frames pass unchanged: the static lease ties the guest's
/// MAC to that address, so nothing is rewritten.
///
/// Every method but `init` runs on the relay's queue (`queue`). The loss of `gvproxy` (its exit,
/// or a socket error that means its end is gone) is reported once, on that queue, through
/// `onLost` (at once when it came before the handler), never after `stop()`.
final class GvproxyUplink: EgressUplink, @unchecked Sendable {
    /// gvproxy's network (spike).
    static let gatewayAddress: UInt32 = 0xC0A8_7F01  // 192.168.127.1
    static let subnetMask: UInt32 = 0xFFFF_FF00  // 255.255.255.0
    static let leaseAddress: UInt32 = 0xC0A8_7F02  // 192.168.127.2, GvproxyProcess.guestAddress

    let gateway: UInt32
    let mask: UInt32
    /// An Ethernet frame without FCS at MTU 1500.
    let maxPacketSize = 1514
    /// The static lease gvproxy gives the guest's MAC: seeded into the filter at start, so a
    /// restored guest (which sends no DHCP for a long time) is let through at once.
    var guestAddress: UInt32? { Self.leaseAddress }
    /// gvproxy's fixed gateway MAC (spike): seeded into the filter at start, so a resumed
    /// guest (which keeps its ARP cache and sends no ARP for a while) reaches the gateway at once.
    var gatewayMAC: EgressMAC? { Self.gatewayHardwareAddress }
    static let gatewayHardwareAddress = EgressMAC(bytes: [0x5A, 0x94, 0xEF, 0xE4, 0x0C, 0xDD])

    private let fd: Int32
    private let process: GvproxyProcess?
    private let queue: DispatchQueue
    private var readSource: (any DispatchSourceRead)?
    private var lostHandler: ((String) -> Void)?
    private var lost = false
    /// The reason of a loss seen before `onLost` was called: handed to the handler when it comes.
    private var pendingLoss: String?
    private var closed = false
    /// Read by `process`'s exit handler before it hops to `queue`; written by `stop()`.
    private let stopped = Mutex(false)
    /// One extra byte, so a datagram longer than a frame is seen as such (`MSG_TRUNC`) and dropped.
    private let discard = UnsafeMutableRawBufferPointer.allocate(byteCount: 1, alignment: 1)

    /// `socket`: connected `SOCK_DGRAM`, owned from now on (made non-blocking, closed by `stop`).
    /// `process`: the `gvproxy` behind it, stopped by `stop` and watched for its exit; nil in tests.
    init(socket: Int32, gateway: UInt32, mask: UInt32, process: GvproxyProcess?, queue: DispatchQueue) {
        fd = socket
        self.gateway = gateway
        self.mask = mask
        self.process = process
        self.queue = queue
        // Apple's guidance for frame sockets: receive buffer at least twice the send buffer.
        var send: Int32 = 1 << 20
        var receive: Int32 = 4 << 20
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &send, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receive, socklen_t(MemoryLayout<Int32>.size))
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        process?.onExit { [weak self] code in
            guard let self, !self.stopped.withLock({ $0 }) else { return }
            let reason = code > 128 ? UplinkLoss.signal(code - 128) : UplinkLoss.exit(code)
            queue.async { [weak self] in self?.reportLost(reason) }
        }
    }

    deinit {
        discard.deallocate()
    }

    /// Starts `gvproxy` for the VM `vmID` of `bundle` (`GvproxyBinary.locate`, then
    /// `GvproxyProcess.start`), binds the client end to `clientSocketURL` (gvproxy answers only a
    /// named peer) and connects it to gvproxy's vfkit socket. Throws
    /// `NidoError.controlledNetworkUnavailable` (localized); nothing is left running then.
    @Sendable static func start(bundle: VMBundle, vmID: UUID, queue: DispatchQueue) throws -> GvproxyUplink {
        let binary = try GvproxyBinary.locate()
        let process = try GvproxyProcess.start(vmID: vmID, bundle: bundle, binary: binary)
        do {
            let fd = try connect(client: process.clientSocketURL, server: process.socketURL)
            return GvproxyUplink(socket: fd, gateway: gatewayAddress, mask: subnetMask, process: process, queue: queue)
        } catch {
            process.stop()
            throw error
        }
    }

    /// A `SOCK_DGRAM` socket bound to `client` and connected to `server`.
    private static func connect(client: URL, server: URL) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw NidoError.controlledNetworkUnavailable(L10n.string("socket to gvproxy not created")) }
        _ = Darwin.unlink(client.path)  // a stale one from a crash: the directory is ours (0700)
        guard withAddress(client, { bind(fd, $0, $1) }) == 0, withAddress(server, { Darwin.connect(fd, $0, $1) }) == 0
        else {
            Darwin.close(fd)
            throw NidoError.controlledNetworkUnavailable(L10n.string("couldn’t connect to gvproxy"))
        }
        return fd
    }

    /// Calls `body` with a `sockaddr_un` for `url` (whose path fits: `GvproxyProcess` checks it).
    private static func withAddress(_ url: URL, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(url.path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.count < capacity else { return -1 }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: path)
            raw[path.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    // MARK: - EgressUplink

    func onPacketsAvailable(_ handler: @escaping () -> Void) {
        guard readSource == nil, !closed, !stopped.withLock({ $0 }) else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler(handler: handler)
        source.resume()
        readSource = source
    }

    func onLost(_ handler: @escaping (String) -> Void) {
        guard !stopped.withLock({ $0 }) else { return }
        if let reason = pendingLoss {
            // gvproxy was lost before the relay asked: told now, once.
            pendingLoss = nil
            handler(reason)
            return
        }
        lostHandler = handler
    }

    func read(into buffers: [UnsafeMutableRawBufferPointer]) -> [Int] {
        guard !lost, !stopped.withLock({ $0 }) else { return [] }
        var lengths: [Int] = []
        var vectors = [iovec(), iovec()]
        // Each datagram lands in the next free buffer, plus one spare byte: a longer one is
        // dropped and its buffer reused.
        while lengths.count < buffers.count {
            let buffer = buffers[lengths.count]
            vectors[0] = iovec(iov_base: buffer.baseAddress, iov_len: buffer.count)
            vectors[1] = iovec(iov_base: discard.baseAddress, iov_len: 1)
            let count = vectors.withUnsafeMutableBufferPointer { iov -> Int in
                var message = msghdr()
                message.msg_iov = iov.baseAddress
                message.msg_iovlen = 2
                let count = recvmsg(fd, &message, MSG_DONTWAIT)
                if count >= 0, message.msg_flags & MSG_TRUNC != 0 { return -2 }
                return count
            }
            if count == -2 { continue }
            if count < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK, Self.isPeerGone(errno) {
                    reportLost(UplinkLoss.socketUnresponsive)
                }
                break
            }
            if count == 0 {
                // An empty datagram, or the end of a stream that has no peer any more.
                if hungUp { reportLost(UplinkLoss.socketClosed) }
                break
            }
            if count > buffer.count { continue }
            lengths.append(count)
        }
        return lengths
    }

    func write(_ frames: [UnsafeRawBufferPointer]) {
        guard !lost, !stopped.withLock({ $0 }) else { return }
        for frame in frames {
            // A full buffer drops the frame, as a congested link would; TCP in the guest recovers.
            if send(fd, frame.baseAddress, frame.count, MSG_DONTWAIT) < 0, Self.isPeerGone(errno) {
                reportLost(UplinkLoss.socketUnresponsive)
                return
            }
        }
    }

    /// Closes the socket and stops `gvproxy`. Idempotent; on the relay's queue (or its deinit).
    func stop() { stop(keepingForwardRecord: false) }

    /// gvproxy was lost and the VM still runs (`GvproxyProcess.stop`): the SSH forward record
    /// stays; a later `stop()` still removes it.
    func stopKeepingForwardRecord() { stop(keepingForwardRecord: true) }

    private func stop(keepingForwardRecord: Bool) {
        let first = stopped.withLock { stopped in
            defer { stopped = true }
            return !stopped
        }
        guard first else {
            process?.stop(keepingForwardRecord: keepingForwardRecord)
            return
        }
        lostHandler = nil
        closeSocket()
        process?.stop(keepingForwardRecord: keepingForwardRecord)
    }

    /// Once: through the read source's cancel handler when there is one, so the descriptor is
    /// never closed under a source still watching it.
    private func closeSocket() {
        guard !closed else { return }
        closed = true
        if let readSource {
            let fd = self.fd
            readSource.setCancelHandler { Darwin.close(fd) }
            readSource.cancel()
            self.readSource = nil
        } else {
            Darwin.close(fd)
        }
    }

    // MARK: - Loss

    /// Errors after which the other end will never answer again.
    private static func isPeerGone(_ code: Int32) -> Bool {
        [ECONNREFUSED, ECONNRESET, ENOTCONN, EPIPE, ENOENT, EDESTADDRREQ, EBADF].contains(code)
    }

    private var hungUp: Bool {
        var poll = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return Darwin.poll(&poll, 1, 0) == 1 && poll.revents & Int16(POLLHUP) != 0
    }

    /// Once: the socket is closed (no source keeps firing on a dead peer), then the relay hears of it.
    private func reportLost(_ reason: String) {
        guard !lost, !stopped.withLock({ $0 }) else { return }
        lost = true
        closeSocket()
        if let lostHandler {
            lostHandler(reason)
        } else {
            pendingLoss = reason
        }
    }
}
