// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import Testing
@testable import NidoCore

@Suite struct ConsoleLogTests {
    private func makeDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nido-clog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return url
    }

    private func size(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// A guest that prints without end never fills the host disk: console.log stays under the cap,
    /// one rotated generation keeps the previous bytes, the newest bytes are in console.log.
    @Test func writingPastTheCapRotatesOnceAndKeepsTheNewestBytes() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("console.log")
        let cap = 1024
        let log = try ConsoleLog(url: url, cap: cap)
        var last = Data()
        for i in 0..<50 {
            last = Data(String(format: "line %04d ", i).utf8) + Data(repeating: 0x2E, count: 290) + Data("\n".utf8)
            log.write(last)
        }
        log.close()
        let rotated = dir.appendingPathComponent("console.log.1")
        #expect(size(url) <= cap)
        #expect(size(rotated) <= cap)
        #expect(size(url) + size(rotated) <= 2 * cap)
        let current = try Data(contentsOf: url)
        #expect(current.suffix(last.count) == last)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(names == ["console.log", "console.log.1"])
        for file in [url, rotated] {
            let mode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber)
            #expect(mode.intValue == 0o600)
        }
    }

    /// A single chunk larger than the cap keeps only its last `cap` bytes.
    @Test func chunkLargerThanTheCapKeepsItsTail() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("console.log")
        let log = try ConsoleLog(url: url, cap: 100)
        let chunk = Data((0..<1000).map { UInt8(truncatingIfNeeded: $0) })
        log.write(chunk)
        log.close()
        #expect(try Data(contentsOf: url) == chunk.suffix(100))
    }

    /// A console.log left over larger than the cap (before M2) is emptied, not rotated whole.
    @Test func oversizedExistingLogIsTruncatedNotRotated() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("console.log")
        try Data(repeating: 0x41, count: 5000).write(to: url)
        let log = try ConsoleLog(url: url, cap: 1000)
        log.write(Data("new\n".utf8))
        log.close()
        #expect(try Data(contentsOf: url) == Data("new\n".utf8))
        #expect(size(dir.appendingPathComponent("console.log.1")) <= 1000)
    }

    /// A symlink planted at console.log.1 is replaced by the rotation, never written through.
    @Test func rotationReplacesASymlinkedGeneration() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("console.log")
        let victim = dir.appendingPathComponent("victim")
        try Data("keep\n".utf8).write(to: victim)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("console.log.1"), withDestinationURL: victim)
        let log = try ConsoleLog(url: url, cap: 10)
        log.write(Data("0123456789".utf8))
        log.write(Data("abcdefghij".utf8))
        log.close()
        #expect(try String(contentsOf: victim, encoding: .utf8) == "keep\n")
        #expect(try String(contentsOf: url, encoding: .utf8) == "abcdefghij")
        #expect(try String(contentsOf: dir.appendingPathComponent("console.log.1"), encoding: .utf8) == "0123456789")
    }

    /// The app's tee is capped too.
    @Test func serialConsoleTeeIsCapped() async throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("console.log")
        let console = try SerialConsole(logURL: url, logCap: 4096, deliversOutput: false)
        let payload = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0 % 251) })
        try console.guestWriteHandle.write(contentsOf: payload)
        let rotated = dir.appendingPathComponent("console.log.1")
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if (try? Data(contentsOf: url))?.suffix(16) == payload.suffix(16) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        console.close()
        #expect(size(url) + size(rotated) <= 2 * 4096)
        #expect(try Data(contentsOf: url).suffix(16) == payload.suffix(16))
    }

    /// Without delivery (the CLI without --console) the stream ends at once and keeps nothing.
    @Test func consoleWithoutDeliveryEndsItsStream() async throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let console = try SerialConsole(logURL: dir.appendingPathComponent("console.log"), deliversOutput: false)
        defer { console.close() }
        try console.guestWriteHandle.write(contentsOf: Data("hello".utf8))
        var chunks = 0
        for await _ in console.output { chunks += 1 }
        #expect(chunks == 0)
    }
}
