// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import Testing
@testable import NidoCore

private final class TempDir {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("nido-serial-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    var log: URL { url.appendingPathComponent("console.log") }
}

/// Collects `output` until it contains `expected` bytes (or the stream ends / times out).
private func collect(_ console: SerialConsole, until expected: Int, timeout: Duration = .seconds(5)) async -> Data {
    await withTaskGroup(of: Data?.self) { group in
        group.addTask {
            var received = Data()
            for await chunk in console.output {
                received.append(chunk)
                if received.count >= expected { break }
            }
            return received
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first ?? Data()
    }
}

/// Reads exactly `count` bytes from `fd` (blocking, with a poll timeout).
private func readExactly(_ fd: Int32, count: Int, timeoutMs: Int32 = 5000) -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while data.count < count {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, timeoutMs) > 0 else { break }
        let n = read(fd, &buffer, min(buffer.count, count - data.count))
        guard n > 0 else { break }
        data.append(contentsOf: buffer[0..<n])
    }
    return data
}

@Suite struct SerialConsoleTests {
    @Test func guestOutputReachesStreamAndLog() async throws {
        let dir = try TempDir()
        try Data("old boot\n".utf8).write(to: dir.log)
        chmod(dir.log.path, 0o600)
        let console = try SerialConsole(logURL: dir.log)
        defer { console.close() }

        let message = Data("Debian GNU/Linux 13 vm hvc0\r\n\r\nvm login: ".utf8)
        try console.guestWriteHandle.write(contentsOf: message)
        let received = await collect(console, until: message.count)

        #expect(received == message)
        console.close()
        let log = try Data(contentsOf: dir.log)
        #expect(log == Data("old boot\n".utf8) + message)
        let attributes = try FileManager.default.attributesOfItem(atPath: dir.log.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test func newLogIsCreatedWith0600() throws {
        let dir = try TempDir()
        let console = try SerialConsole(logURL: dir.log)
        defer { console.close() }
        let attributes = try FileManager.default.attributesOfItem(atPath: dir.log.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test func symlinkedLogIsRefused() throws {
        let dir = try TempDir()
        let target = dir.url.appendingPathComponent("elsewhere")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(at: dir.log, withDestinationURL: target)
        #expect(throws: (any Error).self) { _ = try SerialConsole(logURL: dir.log) }
        #expect(try Data(contentsOf: target).isEmpty)
    }

    /// A console.log hard-linked to another file never receives guest output.
    @Test func hardLinkedLogIsRefused() throws {
        let dir = try TempDir()
        let victim = dir.url.appendingPathComponent("zshrc")
        try Data("export A=1\n".utf8).write(to: victim)
        try FileManager.default.linkItem(at: victim, to: dir.log)
        #expect(throws: NidoError.unsafePath("console.log")) { _ = try SerialConsole(logURL: dir.log) }
        #expect(try String(contentsOf: victim, encoding: .utf8) == "export A=1\n")
    }

    /// A FIFO at console.log is refused without blocking the caller (the app's main actor).
    @Test func fifoLogIsRefusedWithoutHanging() throws {
        let dir = try TempDir()
        try makeFIFO(dir.log)
        let log = dir.log
        let outcome = withinTimeout { thrownError { _ = try SerialConsole(logURL: log) } }
        #expect(outcome == NidoErrorBox(NidoError.unsafePath("console.log")))
    }

    @Test func sentBytesReachTheGuest() throws {
        let dir = try TempDir()
        let console = try SerialConsole(logURL: dir.log)
        defer { console.close() }

        console.send(Data("root\r".utf8))
        console.send(Data([0x7F, 0x1B, 0x5B, 0x41]))

        let fd = console.guestReadHandle.fileDescriptor
        #expect(readExactly(fd, count: 9) == Data("root\r".utf8) + Data([0x7F, 0x1B, 0x5B, 0x41]))
        // Host input is not logged: console.log only has what the guest printed.
        #expect(try Data(contentsOf: dir.log).isEmpty)
    }

    @Test func sendIsBoundedWhenTheGuestDoesNotRead() throws {
        let dir = try TempDir()
        let console = try SerialConsole(logURL: dir.log)
        defer { console.close() }
        // Far more than a pipe holds: must return at once, never block the caller.
        let start = ContinuousClock.now
        for _ in 0..<64 { console.send(Data(repeating: 0x61, count: 64 * 1024)) }
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(console.pendingInputCount <= SerialConsole.maxPendingInput)
    }

    @Test func sendThatDoesNotFitIsDroppedWhole() throws {
        let dir = try TempDir()
        let console = try SerialConsole(logURL: dir.log)
        defer { console.close() }

        // Larger than the whole queue: nothing of it may reach the guest, not even a prefix.
        console.send(Data(repeating: 0x61, count: SerialConsole.maxPendingInput + 1))
        #expect(console.pendingInputCount == 0)
        console.send(Data("ok".utf8))

        let fd = console.guestReadHandle.fileDescriptor
        #expect(readExactly(fd, count: 2) == Data("ok".utf8))
        #expect(readExactly(fd, count: 1, timeoutMs: 200).isEmpty)
    }

    @Test func maxSizeChunkArrivesWhole() throws {
        let dir = try TempDir()
        let console = try SerialConsole(logURL: dir.log)
        defer { console.close() }
        let end = Data("\u{1B}[201~".utf8)
        let chunk = Data(repeating: 0x78, count: SerialConsole.maxPendingInput - end.count) + end

        console.send(chunk)

        let received = readExactly(console.guestReadHandle.fileDescriptor, count: chunk.count)
        #expect(received.count == chunk.count)
        #expect(received.suffix(end.count) == end)
    }

    @Test func guestNeverBlocksWhenNobodyReadsOutput() async throws {
        let dir = try TempDir()
        let console = try SerialConsole(logURL: dir.log)
        defer { console.close() }
        let size = 4 * 1024 * 1024
        let payload = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 % 251) })
        let handle = console.guestWriteHandle

        // Nobody iterates `output`: the guest's (blocking) write must still complete.
        let writer = Task.detached { try handle.write(contentsOf: payload) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while (try? Data(contentsOf: dir.log).count) ?? 0 < size, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await writer.value
        #expect(try Data(contentsOf: dir.log) == payload)
    }

    @Test func closeTwiceIsSafeAndEndsTheStream() async throws {
        let dir = try TempDir()
        let console = try SerialConsole(logURL: dir.log)
        console.close()
        console.close()
        console.send(Data("ignored".utf8))
        var chunks = 0
        for await _ in console.output { chunks += 1 }
        #expect(chunks == 0)
    }

    /// What the guest wrote before `close()` is still read into console.log (and `output`):
    /// the CLI closes the console right after the machine stops.
    @Test(arguments: [false, true])
    func cliDrainsConsoleBeforeClose(delivers: Bool) async throws {
        for round in 0..<20 {
            let dir = try TempDir()
            let console = try SerialConsole(logURL: dir.log, deliversOutput: delivers)
            let payload = Data("round \(round): ".utf8) + Data(repeating: 0x41, count: 16 * 1024) + Data("end\n".utf8)
            try console.guestWriteHandle.write(contentsOf: payload)
            await console.closeAndWait()
            var received = Data()
            for await chunk in console.output { received.append(chunk) }
            #expect(try Data(contentsOf: dir.log) == payload, "round \(round)")
            if delivers { #expect(received == payload, "round \(round)") }
        }
    }

    @Test func pipesAreCloseOnExec() throws {
        let dir = try TempDir()
        let console = try SerialConsole(logURL: dir.log)
        defer { console.close() }
        for fd in [console.guestReadHandle.fileDescriptor, console.guestWriteHandle.fileDescriptor] {
            #expect(fcntl(fd, F_GETFD) & FD_CLOEXEC != 0)
        }
    }
}
