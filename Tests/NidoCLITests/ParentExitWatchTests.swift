// SPDX-License-Identifier: Apache-2.0
import Dispatch
import Foundation
import Synchronization
import Testing
@testable import NidoCLI

/// `ParentExitWatch` against real processes (`/bin/sleep`, `/usr/bin/true`).
@Suite struct ParentExitWatchTests {
    /// Counts the watch's calls from any queue.
    final class Calls: Sendable {
        private let count = Mutex(0)
        var value: Int { count.withLock { $0 } }
        func add() { count.withLock { $0 += 1 } }
    }

    @Test func firesWhenTheProcessExits() async throws {
        let process = try Self.launch("/bin/sleep", "30")
        defer { if process.isRunning { process.terminate() } }
        let calls = Calls()
        let watch = ParentExitWatch(pid: process.processIdentifier, queue: Self.queue()) { calls.add() }
        watch.start()
        defer { watch.cancel() }

        process.terminate()

        #expect(await Self.wait(within: .seconds(3)) { calls.value > 0 })
        // A later event (none should come) would have had time to arrive.
        try await Task.sleep(for: .milliseconds(300))
        #expect(calls.value == 1)
    }

    @Test func firesAtOnceForAGonePid() async throws {
        let process = try Self.launch("/usr/bin/true")
        process.waitUntilExit()
        let calls = Calls()
        let watch = ParentExitWatch(pid: process.processIdentifier, queue: Self.queue()) { calls.add() }

        watch.start()
        defer { watch.cancel() }

        #expect(await Self.wait(within: .seconds(1)) { calls.value > 0 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(calls.value == 1)
    }

    @Test func cancelledNeverFires() async throws {
        let process = try Self.launch("/bin/sleep", "30")
        defer { if process.isRunning { process.terminate() } }
        let calls = Calls()
        let watch = ParentExitWatch(pid: process.processIdentifier, queue: Self.queue()) { calls.add() }
        watch.start()

        watch.cancel()
        process.terminate()
        process.waitUntilExit()

        try await Task.sleep(for: .seconds(1))
        #expect(calls.value == 0)
    }

    @Test func secondStartChangesNothing() async throws {
        let process = try Self.launch("/bin/sleep", "30")
        defer { if process.isRunning { process.terminate() } }
        let calls = Calls()
        let watch = ParentExitWatch(pid: process.processIdentifier, queue: Self.queue()) { calls.add() }
        watch.start()
        defer { watch.cancel() }

        watch.start()
        process.terminate()

        #expect(await Self.wait(within: .seconds(3)) { calls.value > 0 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(calls.value == 1)
    }

    @Test func startAfterCancelNeverFires() async throws {
        let process = try Self.launch("/bin/sleep", "30")
        defer { if process.isRunning { process.terminate() } }
        let calls = Calls()
        let watch = ParentExitWatch(pid: process.processIdentifier, queue: Self.queue()) { calls.add() }
        watch.cancel()

        watch.start()
        process.terminate()
        process.waitUntilExit()

        try await Task.sleep(for: .seconds(1))
        #expect(calls.value == 0)
    }

    private static func launch(_ path: String, _ arguments: String...) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try process.run()
        return process
    }

    private static func queue() -> DispatchQueue {
        DispatchQueue(label: "ParentExitWatchTests")
    }

    /// Polls `condition` until it holds (true) or `limit` passes (false).
    private static func wait(within limit: Duration, _ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
