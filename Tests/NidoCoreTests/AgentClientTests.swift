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

/// A channel whose far end is a fake helper on a socketpair: it reads the request frame, then
/// sends the canned frames, like the guest's Nido Agent would.
private struct FakeAgentChannel: GuestChannel {
    enum Behavior: @unchecked Sendable {
        case respond([Data])
        case fail(any Error)
        case hang
        /// `connect` ignores cancellation and returns only after `delay`; the peer never answers.
        case lateConnect(delay: Duration, peerSawClose: PeerWatch)
    }
    let behavior: Behavior

    func connect(port: UInt32) async throws -> FileHandle {
        #expect(port == AgentProtocol.port)
        switch behavior {
        case .fail(let error): throw error
        case .hang: return try Self.pair(frames: nil)
        case .respond(let frames): return try Self.pair(frames: frames)
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

    static func pair(frames: [Data]?, watch: PeerWatch? = nil) throws -> FileHandle {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw POSIXError(.EIO) }
        let client = fds[0]
        let server = fds[1]
        Thread {
            do { _ = try AgentFrame.read(from: server) } catch { watch?.closed.withLock { $0 = true } }  // the request, or EOF
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
    do {
        _ = try await client.perform(AgentRequest(action: action))
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
        #expect(result.png == nil)
    }

    @Test func screenshotCarriesPNG() async throws {
        let png = Data(repeating: 7, count: 3 << 20)
        let reply = AgentReply(ok: true, image: PixelSize(1280, 800), screen: ScreenSize(width: 1440, height: 900))
        let c = client(.respond([try json(reply), png]))
        let result = try await c.perform(AgentRequest(action: .screenshot(maxLongEdge: 1280)))
        #expect(result.png?.count == 3 << 20)
        #expect(result.png == png)
    }

    @Test func zoomCarriesPNG() async throws {
        let png = Data(repeating: 9, count: 1 << 20)
        let reply = AgentReply(ok: true, image: PixelSize(400, 200), screen: ScreenSize(width: 1440, height: 900))
        let c = client(.respond([try json(reply), png]))
        let result = try await c.perform(AgentRequest(action: .zoom(x: 1, y: 2, width: 3, height: 4, maxLongEdge: 800)))
        #expect(result.png == png)
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
}
