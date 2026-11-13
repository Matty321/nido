// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import Synchronization
import Testing
@testable import NidoCLI
@testable import NidoCore

@Suite struct ConsoleMirrorTests {
    /// `--console` writes the guest's output to stdout; when stdout blocks (a pipe nobody reads,
    /// a terminal stopped with Ctrl-S) `finish(within:)` still returns on time, so `nido start`
    /// can release the lock (done here as StartCommand does) and exit instead of hanging.
    /// (Brief name: stalledStdoutDoesNotHoldLock.)
    @Test func finishIsBoundedWhenStdoutStalls() async throws {
        var fds: [Int32] = [-1, -1]
        try #require(pipe(&fds) == 0)
        // Closing the reader at the end unblocks the write with EPIPE, never SIGPIPE (the CLI
        // ignores SIGPIPE too).
        _ = fcntl(fds[1], F_SETNOSIGPIPE, 1)
        defer { close(fds[1]) }
        defer { close(fds[0]) }
        // Nobody reads fds[0]: a blocking write of more than the pipe buffer never returns.
        let out = FileHandle(fileDescriptor: fds[1], closeOnDealloc: false)
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        let mirror = ConsoleMirror(output: stream, write: { try? out.write(contentsOf: $0) })
        continuation.yield(Data("[  OK  ] Started.\n".utf8) + Data(repeating: 0x41, count: 256 * 1024))
        continuation.finish()

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-mirror-\(UUID().uuidString).nidovm", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = VMBundle(url: dir)
        let lock = try BundleLock.acquire(bundle, owner: .cli)

        let started = ContinuousClock.now
        let completed = await mirror.finish(within: .milliseconds(300))
        lock.release()
        let elapsed = ContinuousClock.now - started
        #expect(!completed)
        #expect(elapsed < .seconds(2), "attesa: \(elapsed)")
        #expect(BundleLock.holder(bundle) == nil)
    }

    /// With a stdout that reads, everything is printed before `finish` returns.
    @Test func mirrorPrintsEverythingWhenStdoutReads() async {
        let printed = Mutex(Data())
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        let mirror = ConsoleMirror(output: stream, write: { data in printed.withLock { $0.append(data) } })
        continuation.yield(Data("\u{1B}[31mFAILED\u{1B}[0m\n".utf8))
        continuation.yield(Data("login: ".utf8))
        continuation.finish()
        #expect(await mirror.finish(within: .seconds(5)))
        // Sanitised: no escape sequence reaches the terminal.
        #expect(printed.withLock { $0 } == Data("FAILED\nlogin: ".utf8))
    }
}

extension ConsoleMirrorTests {
    /// SWIFT m5: once the mirror finished, the timer of `finish` is cancelled (not left running).
    @Test func finishCancelsItsTimerOnceTheMirrorIsDone() async throws {
        let (output, continuation) = AsyncStream.makeStream(of: Data.self)
        let mirror = ConsoleMirror(output: output, write: { _ in })
        continuation.finish()
        let timerCancelled = Mutex<Bool?>(nil)
        let done = await mirror.finish(within: .seconds(60), sleep: { duration in
            try? await Task.sleep(for: duration)
            timerCancelled.withLock { $0 = Task.isCancelled }
        })
        #expect(done)
        for _ in 0..<200 where timerCancelled.withLock({ $0 }) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(timerCancelled.withLock { $0 } == true)
    }
}
