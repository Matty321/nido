// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import Synchronization
import NidoAgentKit
import Testing
@_spi(Testing) @testable import NidoCore

/// Whether the fake helper's read ended in EOF (the client closed or shut down) instead of a request.
private final class PeerWatch: Sendable {
    let closed = Mutex(false)
}

/// The frames the fake helper read, in order (the request first).
private final class FramesSeen: Sendable {
    let frames = Mutex<[Data]>([])
    var all: [Data] { frames.withLock { $0 } }
}

/// A channel whose far end is a fake helper on a socketpair: it reads the request frame, then
/// sends the canned frames, like the guest's Nido Agent would.
private struct FakeAgentChannel: GuestChannel {
    enum Behavior: @unchecked Sendable {
        case respond([Data])
        case fail(any Error)
        case hang
        /// `connect` ignores cancellation and returns only after `delay`; the peer never answers.
        case lateConnect(delay: Duration, peerSawClose: PeerWatch)
        /// Reads `read` frames (the request and what follows it), records them, then sends `frames`.
        case exchange(read: Int, frames: [Data], seen: FramesSeen)
    }
    let behavior: Behavior

    func connect(port: UInt32) async throws -> FileHandle {
        #expect(port == AgentProtocol.port)
        switch behavior {
        case .fail(let error): throw error
        case .hang: return try Self.pair(frames: nil)
        case .respond(let frames): return try Self.pair(frames: frames)
        case .exchange(let read, let frames, let seen): return try Self.pair(frames: frames, read: read, seen: seen)
        case .lateConnect(let delay, let watch):
            // Not cancellable, like a pending VZVirtioSocketDevice.connect.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int(delay.components.attoseconds / 1_000_000_000_000_000))) {
                    continuation.resume()
                }
            }
            return try Self.pair(frames: nil, watch: watch)
        }
    }

    static func pair(frames: [Data]?, watch: PeerWatch? = nil, read: Int = 1, seen: FramesSeen? = nil) throws -> FileHandle {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw POSIXError(.EIO) }
        let client = fds[0]
        let server = fds[1]
        // A client that gives up mid-frame must give the fake EPIPE, not kill the test run.
        var one: Int32 = 1
        setsockopt(server, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        Thread {
            for _ in 0..<read {
                do {
                    let frame = try AgentFrame.read(from: server)  // the request, or EOF
                    seen?.frames.withLock { $0.append(frame) }
                } catch {
                    watch?.closed.withLock { $0 = true }
                    break
                }
            }
            if let frames {
                for frame in frames { try? AgentFrame.write(frame, to: server) }
            } else {
                sleep(3)
            }
            close(server)
        }.start()
        return FileHandle(fileDescriptor: client, closeOnDealloc: true)
    }
}

private func json(_ reply: AgentReply) throws -> Data { try JSONEncoder().encode(reply) }

private let status = AgentStatus(
    helperVersion: "1.0.0", protocolVersion: 1, screenRecording: true, accessibility: true,
    screen: ScreenSize(width: 1440, height: 900))

private func client(_ behavior: FakeAgentChannel.Behavior, timeout: Duration = .seconds(30)) -> AgentClient {
    AgentClient(channel: FakeAgentChannel(behavior: behavior), timeout: timeout, screenshotTimeout: timeout)
}

private func failure(of client: AgentClient, _ action: AgentAction = .status) async -> AgentFailure? {
    await failure(of: client, AgentRequest(action: action))
}

private func failure(of client: AgentClient, _ request: AgentRequest) async -> AgentFailure? {
    do {
        _ = try await client.perform(request)
        return nil
    } catch {
        return error
    }
}

@Suite struct AgentClientTests {
    @Test func statusRoundTrip() async throws {
        let c = client(.respond([try json(AgentReply(ok: true, status: status))]))
        let result = try await c.perform(AgentRequest(action: .status))
        #expect(result.reply.status?.screen == ScreenSize(width: 1440, height: 900))
        #expect(result.data == nil)
    }

    @Test func screenshotCarriesPNG() async throws {
        let png = Data(repeating: 7, count: 3 << 20)
        let reply = AgentReply(ok: true, image: PixelSize(1280, 800), screen: ScreenSize(width: 1440, height: 900))
        let c = client(.respond([try json(reply), png]))
        let result = try await c.perform(AgentRequest(action: .screenshot(maxLongEdge: 1280)))
        #expect(result.data?.count == 3 << 20)
        #expect(result.data == png)
    }

    @Test func zoomCarriesPNG() async throws {
        let png = Data(repeating: 9, count: 1 << 20)
        let reply = AgentReply(ok: true, image: PixelSize(400, 200), screen: ScreenSize(width: 1440, height: 900))
        let c = client(.respond([try json(reply), png]))
        let result = try await c.perform(AgentRequest(action: .zoom(x: 1, y: 2, width: 3, height: 4, maxLongEdge: 800)))
        #expect(result.data == png)
    }

    @Test func connectResetIsNotReady() async {
        let f = await failure(of: client(.fail(POSIXError(.ECONNRESET))))
        #expect(f?.code == .notReady)
        #expect(f?.message == L10n.string("waiting for login or Nido Agent"))
        #expect(L10n.string("waiting for login or Nido Agent", language: "en") == "waiting for login or Nido Agent")
    }

    @Test func virtualizationResetIsNotReady() async {
        let f = await failure(of: client(.fail(NSError(domain: NSPOSIXErrorDomain, code: 54))))
        #expect(f?.code == .notReady)
    }

    @Test func noSocketDeviceIsNotReady() async {
        let f = await failure(of: client(.fail(MonitorError.unavailable)))
        #expect(f?.code == .notReady)
    }

    @Test func silentHelperTimesOut() async {
        let start = ContinuousClock.now
        let f = await failure(of: client(.hang, timeout: .milliseconds(200)))
        #expect(f?.code == .timeout)
        #expect(ContinuousClock.now - start < .seconds(2.5))  // the fake helper holds on for 3 s
    }

    @Test func connectFinishingAfterTheDeadlineIsShutDown() async throws {
        let watch = PeerWatch()
        let c = client(.lateConnect(delay: .milliseconds(400), peerSawClose: watch), timeout: .milliseconds(100))
        let f = await failure(of: c)
        #expect(f?.code == .timeout)
        // The late socket must not stay open with a worker blocked on it: the peer sees EOF soon.
        let deadline = ContinuousClock.now + .seconds(3)
        while !watch.closed.withLock({ $0 }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(watch.closed.withLock { $0 })
    }

    @Test func helperErrorPassesThrough() async throws {
        let c = client(.respond([try json(AgentReply(ok: false, error: .screenChanged, message: "moved"))]))
        let result = try await c.perform(AgentRequest(action: .status))
        #expect(result.reply.error == .screenChanged)
        #expect(result.reply.ok == false)
    }

    @Test func versionMismatch() async throws {
        let c = client(.respond([try json(AgentReply(ok: false, error: .versionMismatch))]))
        let f = await failure(of: c)
        #expect(f?.code == .versionMismatch)
        #expect(f?.message == L10n.string("incompatible Nido Agent version: run nido agent setup to update Nido Agent"))
        #expect(L10n.string("incompatible Nido Agent version: run nido agent setup to update Nido Agent", language: "en").contains("update Nido Agent"))
    }

    @Test func droppedConnectionIsAFailureNotACrash() async {
        let c = client(.respond([]))  // helper reads the request, then closes without answering
        let f = await failure(of: c)
        #expect(f?.code == .internalError)
    }

    // MARK: - Files

    @Test func putFileSendsTheBytesAsASecondFrame() async throws {
        let seen = FramesSeen()
        let bytes = Data((0..<300_000).map { UInt8($0 % 251) })
        let c = client(.exchange(read: 2, frames: [try json(AgentReply(ok: true, bytes: bytes.count))], seen: seen))
        var request = AgentRequest(action: .putFile(path: "in/data.bin", size: bytes.count))
        request.payload = bytes
        let result = try await c.perform(request)
        #expect(result.reply.ok && result.reply.bytes == bytes.count)
        #expect(result.data == nil)
        let frames = seen.all
        try #require(frames.count == 2)
        let sent = try JSONDecoder().decode(AgentRequest.self, from: frames[0])
        #expect(sent.action == .putFile(path: "in/data.bin", size: bytes.count))
        #expect(frames[1] == bytes)
        // The payload never travels inside the JSON request.
        #expect(!String(decoding: frames[0], as: UTF8.self).contains("payload"))
    }

    @Test func putFileWithoutMatchingBytesIsNeverSent() async throws {
        for payload: Data? in [nil, Data("abc".utf8), Data(count: AgentProtocol.maxTransferBytes + 1)] {
            let seen = FramesSeen()
            let c = client(.exchange(read: 2, frames: [try json(AgentReply(ok: true))], seen: seen))
            var request = AgentRequest(action: .putFile(path: "a", size: payload.map { $0.count == 3 ? 4 : $0.count } ?? 1))
            request.payload = payload
            do {
                _ = try await c.perform(request)
                Issue.record("sent \(String(describing: payload?.count))")
            } catch {
                #expect(error.code == .badRequest)
            }
            #expect(seen.all.isEmpty)
            #expect(L10n.string("the file’s data is missing, too large or of the wrong size", language: "en")
                == "the file’s data is missing, too large or of the wrong size")
        }
    }

    /// The guest refuses an oversized put by closing without reading: a failure, never a crash.
    @Test func putFileToAGuestThatHangsUpIsAFailure() async {
        let bytes = Data(count: 4 << 20)
        let c = client(.respond([]))  // reads the request only, then closes
        var request = AgentRequest(action: .putFile(path: "a", size: bytes.count))
        request.payload = bytes
        let f = await failure(of: c, request)
        #expect(f?.code == .internalError)
    }

    @Test func getFileReadsTheBytesFrame() async throws {
        let bytes = Data((0..<200_000).map { UInt8($0 % 13) })
        let seen = FramesSeen()
        let c = client(.exchange(read: 1, frames: [try json(AgentReply(ok: true, bytes: bytes.count)), bytes], seen: seen))
        let result = try await c.perform(AgentRequest(action: .getFile(path: "out.log", maxBytes: 1 << 20)))
        #expect(result.reply.ok)
        #expect(result.data == bytes)
        #expect(seen.all.count == 1)
    }

    @Test func getFileFailureHasNoFrame() async throws {
        let c = client(.respond([try json(AgentReply(ok: false, error: .badRequest, message: "no such file"))]))
        let result = try await c.perform(AgentRequest(action: .getFile(path: "missing", maxBytes: 1 << 20)))
        #expect(!result.reply.ok)
        #expect(result.data == nil)
    }

    @Test func getFileRefusesAFrameOverTheLimit() async throws {
        let big = Data(count: 2048)
        let c = client(.respond([try json(AgentReply(ok: true, bytes: big.count)), big]))
        let f = await failure(of: c, AgentRequest(action: .getFile(path: "a", maxBytes: 1024)))
        #expect(f?.code == .internalError)

        // Never above the transfer limit, whatever `maxBytes` says.
        let huge = Data(count: AgentProtocol.maxTransferBytes + 1)
        let c2 = client(.respond([try json(AgentReply(ok: true, bytes: huge.count)), huge]))
        let f2 = await failure(of: c2, AgentRequest(action: .getFile(path: "a", maxBytes: Int.max)))
        #expect(f2?.code == .internalError)
    }

    @Test func getFileWhoseFrameDiffersFromItsSizeFails() async throws {
        let c = client(.respond([try json(AgentReply(ok: true, bytes: 10)), Data(count: 9)]))
        let f = await failure(of: c, AgentRequest(action: .getFile(path: "a", maxBytes: 1024)))
        #expect(f?.code == .internalError)
    }

    /// An ok `getFile` reply must say how many bytes follow.
    @Test func getFileReplyWithoutItsSizeFails() async throws {
        let c = client(.respond([try json(AgentReply(ok: true)), Data(count: 9)]))
        let f = await failure(of: c, AgentRequest(action: .getFile(path: "a", maxBytes: 1024)))
        #expect(f?.code == .internalError)
    }
}
