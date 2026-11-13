// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import Testing
@testable import NidoCore

/// A channel that answers with canned bytes over a socketpair, like the guest would.
private struct FakeChannel: GuestChannel {
    enum Behavior: @unchecked Sendable {
        case respond(Data, closeAfter: Bool)
        case fail(any Error)
        case hang
        case connectNever
    }
    let behavior: Behavior

    func connect(port: UInt32) async throws -> FileHandle {
        #expect(port == 7700)
        switch behavior {
        case .fail(let error): throw error
        case .connectNever:
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        case .hang:
            return try Self.pair(response: nil, closeAfter: false)
        case .respond(let data, let closeAfter):
            return try Self.pair(response: data, closeAfter: closeAfter)
        }
    }

    /// Returns the client end; the other end writes `response` (after the request arrives).
    static func pair(response: Data?, closeAfter: Bool) throws -> FileHandle {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw POSIXError(.EIO) }
        let server = fds[1]
        let client = fds[0]
        var one: Int32 = 1
        setsockopt(server, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        Thread {
            var buffer = [UInt8](repeating: 0, count: 1024)
            _ = read(server, &buffer, buffer.count)  // the request
            if let response {
                response.withUnsafeBytes { _ = write(server, $0.baseAddress, $0.count) }
                if closeAfter { close(server) } else { sleep(3); close(server) }
            } else {
                sleep(5)
                close(server)
            }
        }.start()
        return FileHandle(fileDescriptor: client, closeOnDealloc: true)
    }
}

private func http(_ body: String, status: String = "200 OK", length: Int? = nil) -> Data {
    let n = length ?? body.utf8.count
    return Data("HTTP/1.0 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(n)\r\nConnection: close\r\n\r\n\(body)".utf8)
}

/// A client for tests whose outcome comes from the answer, not the clock: the fake guest answers
/// (or closes) at once, so the result is decided by the bytes. The 2 s default could expire first
/// when the full suite loads the machine, turning an expected error into `.timeout`; the timeout
/// itself is covered by `fetchTimesOut` and `cancellationIsRethrownNotATimeout`.
private func answeringClient(_ behavior: FakeChannel.Behavior) -> GuestMonitorClient {
    GuestMonitorClient(channel: FakeChannel(behavior: behavior), timeout: .seconds(60))
}

@Suite struct GuestMonitorClientTests {
    @Test func fetchesAndDecodes() async throws {
        let client = answeringClient(.respond(http(guestTools100Fixture), closeAfter: true))
        let s = try await client.fetch()
        #expect(s.hostname == "vm1")
        #expect(s.cpu?.vcpus == 4)
    }

    @Test func responseWithoutContentLengthReadsToEOF() async throws {
        let raw = Data(("HTTP/1.0 200 OK\r\n\r\n" + userAPIFixture).utf8)
        let client = answeringClient(.respond(raw, closeAfter: true))
        #expect(try await client.fetch().hostname == "debian-ai")
    }

    @Test func truncatedResponseIsInvalid() async {
        let truncated = http(guestTools100Fixture, length: guestTools100Fixture.utf8.count + 50)
        let client = answeringClient(.respond(truncated, closeAfter: true))
        await #expect(throws: MonitorError.invalidResponse) { _ = try await client.fetch() }

        let cut = Data(http(guestTools100Fixture).prefix(120))
        let client2 = answeringClient(.respond(cut, closeAfter: true))
        await #expect(throws: MonitorError.invalidResponse) { _ = try await client2.fetch() }
    }

    @Test func nonOKStatusAndGarbageAreInvalid() async {
        for data in [http("{}", status: "404 Not Found"), http("x", status: "500 Internal Server Error"),
                     Data("not http at all".utf8), Data()] {
            let client = answeringClient(.respond(data, closeAfter: true))
            await #expect(throws: MonitorError.invalidResponse) { _ = try await client.fetch() }
        }
    }

    @Test func hostileContentLengthIsInvalid() async {
        for value in ["9223372036854775807", "-1", "-9223372036854775808", "65537", "99999999999999999999", "abc"] {
            let raw = Data("HTTP/1.0 200 OK\r\nContent-Length: \(value)\r\n\r\n{}".utf8)
            let client = answeringClient(.respond(raw, closeAfter: true))
            await #expect(throws: MonitorError.invalidResponse, "Content-Length \(value)") {
                _ = try await client.fetch()
            }
        }
    }

    @Test func cancellationIsRethrownNotATimeout() async {
        for behavior in [FakeChannel.Behavior.hang, .connectNever] {
            let client = GuestMonitorClient(channel: FakeChannel(behavior: behavior), timeout: .seconds(30))
            let task = Task { try await client.fetch() }
            try? await Task.sleep(for: .milliseconds(150))
            task.cancel()
            let started = ContinuousClock.now
            do {
                _ = try await task.value
                Issue.record("expected cancellation")
            } catch is CancellationError {
            } catch {
                Issue.record("expected CancellationError, got \(error)")
            }
            #expect(ContinuousClock.now - started < .seconds(2))
        }
    }

    @Test func oversizedResponseIsInvalid() async {
        let big = http(String(repeating: "x", count: 70 * 1024))
        let client = answeringClient(.respond(big, closeAfter: true))
        await #expect(throws: MonitorError.invalidResponse) { _ = try await client.fetch() }
    }

    @Test func connectionRefusedMeansUnavailable() async {
        let refused = NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET))
        let client = answeringClient(.fail(refused))
        await #expect(throws: MonitorError.unavailable) { _ = try await client.fetch() }
    }

    @Test func fetchTimesOut() async {
        let started = ContinuousClock.now
        let silent = GuestMonitorClient(channel: FakeChannel(behavior: .hang), timeout: .milliseconds(300))
        await #expect(throws: MonitorError.timeout) { _ = try await silent.fetch() }
        let stuck = GuestMonitorClient(channel: FakeChannel(behavior: .connectNever), timeout: .milliseconds(300))
        await #expect(throws: MonitorError.timeout) { _ = try await stuck.fetch() }
        // Loose on purpose: a loaded machine running the suite in parallel took almost 4 s here.
        // The bound only proves that neither fetch hangs.
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test func defaultTimeoutIsTwoSeconds() {
        #expect(GuestMonitorClient.defaultTimeout == .seconds(2))
        #expect(GuestMonitorClient.maxResponseBytes == 64 * 1024)
    }

    @Test func futureMajorVersionIsReportedWithTheStatusStillAvailable() async throws {
        let future = #"{"agent":"Nido AI Monitor","version":"3.1","cpu":{"usage_percent":4}}"#
        let client = answeringClient(.respond(http(future), closeAfter: true))
        await #expect(throws: MonitorError.unsupportedVersion("3.1")) { _ = try await client.fetch() }
        let client2 = answeringClient(.respond(http(future), closeAfter: true))
        let partial = try await client2.fetchAllowingUnsupportedVersion()
        #expect(partial.cpu?.usagePercent == 4)
        #expect(!partial.isSupportedVersion)
    }

    @Test func twoChannelsNeverMix() async throws {
        func doc(_ name: String) -> String { #"{"agent":"Nido AI Monitor","version":"2.0","hostname":"\#(name)"}"# }
        let a = answeringClient(.respond(http(doc("alfa")), closeAfter: true))
        let b = answeringClient(.respond(http(doc("beta")), closeAfter: true))
        async let ra = a.fetch()
        async let rb = b.fetch()
        let (sa, sb) = try await (ra, rb)
        #expect(sa.hostname == "alfa")
        #expect(sb.hostname == "beta")
    }
}
