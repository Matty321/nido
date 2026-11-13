// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import Synchronization
import Testing
@testable import NidoCore

/// `GvproxyUplink` over a `socketpair` standing in for gvproxy's vfkit socket: one raw Ethernet
/// frame per datagram, no handshake.
@Suite(.italian) struct GvproxyUplinkTests {
    private struct Pair {
        let uplink: GvproxyUplink
        /// gvproxy's end.
        let peer: Int32
        let queue: DispatchQueue
    }

    private func makePair() throws -> Pair {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else { throw POSIXError(.EIO) }
        // Room for a whole batch on gvproxy's side, as gvproxy has.
        var size: Int32 = 1 << 20
        setsockopt(fds[1], SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fds[1], SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        let queue = DispatchQueue(label: "test.gvproxy-uplink")
        let uplink = GvproxyUplink(
            socket: fds[0], gateway: GvproxyUplink.gatewayAddress, mask: GvproxyUplink.subnetMask, process: nil,
            queue: queue)
        return Pair(uplink: uplink, peer: fds[1], queue: queue)
    }

    private func frame(_ index: Int, length: Int) -> [UInt8] {
        (0..<length).map { UInt8(truncatingIfNeeded: $0 &+ index) }
    }

    private func buffers(_ count: Int, size: Int = 1514) -> [UnsafeMutableRawBufferPointer] {
        (0..<count).map { _ in UnsafeMutableRawBufferPointer.allocate(byteCount: size, alignment: 16) }
    }

    @Test func framesRoundTrip() throws {
        let pair = try makePair()
        defer {
            pair.queue.sync { pair.uplink.stop() }
            close(pair.peer)
        }
        #expect(pair.uplink.maxPacketSize == 1514)

        // Relay → gvproxy: in order, unchanged.
        let sent = (0..<40).map { frame($0, length: 60 + $0 * 30) }
        let pointers = sent.map { bytes in
            let pointer = UnsafeMutableRawBufferPointer.allocate(byteCount: bytes.count, alignment: 1)
            pointer.copyBytes(from: bytes)
            return pointer
        }
        defer { pointers.forEach { $0.deallocate() } }
        pair.queue.sync { pair.uplink.write(pointers.map { UnsafeRawBufferPointer($0) }) }
        var received: [[UInt8]] = []
        var scratch = [UInt8](repeating: 0, count: 2048)
        while received.count < 40 {
            let count = recv(pair.peer, &scratch, scratch.count, MSG_DONTWAIT)
            guard count > 0 else { break }
            received.append(Array(scratch[0..<count]))
        }
        #expect(received == sent)

        // gvproxy → relay: announced on the relay's queue, read in batches of at most buffers.count.
        let available = Mutex(0)
        pair.queue.sync { pair.uplink.onPacketsAvailable { available.withLock { $0 += 1 } } }
        let incoming = (0..<40).map { frame($0 + 7, length: 1514 - $0 * 20) }
        for bytes in incoming {
            #expect(bytes.withUnsafeBytes { send(pair.peer, $0.baseAddress, $0.count, 0) } == bytes.count)
        }
        let deadline = Date().addingTimeInterval(3)
        while available.withLock({ $0 }) == 0, Date() < deadline { usleep(10_000) }
        #expect(available.withLock { $0 } > 0)

        let batch = buffers(16)
        defer { batch.forEach { $0.deallocate() } }
        var read: [[UInt8]] = []
        while read.count < 40 {
            let lengths = pair.queue.sync { pair.uplink.read(into: batch) }
            if lengths.isEmpty { break }
            #expect(lengths.count <= batch.count)
            for (index, length) in lengths.enumerated() { read.append(Array(batch[index][0..<length])) }
        }
        #expect(read == incoming)
        #expect(pair.queue.sync { pair.uplink.read(into: batch) }.isEmpty)
    }

    @Test func oversizedDatagramIsDropped() throws {
        let pair = try makePair()
        defer {
            pair.queue.sync { pair.uplink.stop() }
            close(pair.peer)
        }
        let big = frame(1, length: 1515)
        let small = frame(2, length: 100)
        for bytes in [big, small] {
            #expect(bytes.withUnsafeBytes { send(pair.peer, $0.baseAddress, $0.count, 0) } == bytes.count)
        }
        let batch = buffers(4)
        defer { batch.forEach { $0.deallocate() } }
        let lengths = pair.queue.sync { pair.uplink.read(into: batch) }
        #expect(lengths == [100])
        #expect(Array(batch[0][0..<100]) == small)
    }

    @Test func gatewayMACIsGvproxysFixedOne() throws {
        let pair = try makePair()
        defer {
            pair.queue.sync { pair.uplink.stop() }
            close(pair.peer)
        }
        #expect(pair.uplink.gatewayMAC == EgressMAC("5a:94:ef:e4:0c:dd"))
    }

    /// gvproxy dies before the relay registers its handler: the loss is still reported, once.
    @Test func lossBeforeTheHandlerIsStillReported() throws {
        let pair = try makePair()
        close(pair.peer)
        let bytes = frame(4, length: 60)
        let pointer = UnsafeMutableRawBufferPointer.allocate(byteCount: bytes.count, alignment: 1)
        defer { pointer.deallocate() }
        pointer.copyBytes(from: bytes)
        pair.queue.sync { pair.uplink.write([UnsafeRawBufferPointer(pointer)]) }
        let reasons = Mutex<[String]>([])
        pair.queue.sync { pair.uplink.onLost { reason in reasons.withLock { $0.append(reason) } } }
        pair.queue.sync {}
        #expect(reasons.withLock { $0 } == [UplinkLoss.socketUnresponsive])
        pair.queue.sync { pair.uplink.stop() }

        // After stop() nothing is reported, pending or not.
        let other = try makePair()
        close(other.peer)
        other.queue.sync {
            other.uplink.write([UnsafeRawBufferPointer(pointer)])
            other.uplink.stop()
        }
        let late = Mutex(0)
        other.queue.sync { other.uplink.onLost { _ in late.withLock { $0 += 1 } } }
        other.queue.sync {}
        #expect(late.withLock { $0 } == 0)
    }

    @Test func peerGoneIsReportedOnceAndStopIsIdempotent() throws {
        let pair = try makePair()
        let reasons = Mutex<[String]>([])
        pair.queue.sync { pair.uplink.onLost { reason in reasons.withLock { $0.append(reason) } } }
        close(pair.peer)
        let bytes = frame(3, length: 60)
        let pointer = UnsafeMutableRawBufferPointer.allocate(byteCount: bytes.count, alignment: 1)
        defer { pointer.deallocate() }
        pointer.copyBytes(from: bytes)
        pair.queue.sync {
            pair.uplink.write([UnsafeRawBufferPointer(pointer)])
            pair.uplink.write([UnsafeRawBufferPointer(pointer)])
        }
        pair.queue.sync {}
        #expect(reasons.withLock { $0.count } == 1)
        pair.queue.sync {
            pair.uplink.stop()
            pair.uplink.stop()
        }
    }
}
