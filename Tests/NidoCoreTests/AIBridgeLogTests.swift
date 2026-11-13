// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCore

@Suite struct AIBridgeLogTests {
    private func entry(_ index: Int) -> AIBridgeLogEntry {
        AIBridgeLogEntry(
            time: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)), model: "org/m", provider: "groq",
            inputTokens: index, outputTokens: 2 * index, estimated: false, status: 200, durationMs: 15)
    }

    @Test func logRotatesAt1MiB() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("nido-ailog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let url = tmp.appendingPathComponent("ai-bridge.log")
        let rotated = tmp.appendingPathComponent("ai-bridge.log.1")
        #expect(AIBridgeLog.cap == 1 << 20)

        let log = try AIBridgeLog(url: url)
        let lineSize = try AIBridgeLog.line(for: entry(1)).count
        let count = (1 << 20) / lineSize + 10
        for i in 0..<count { log.append(entry(i)) }
        log.close()

        let current = try Data(contentsOf: url)
        let previous = try Data(contentsOf: rotated)
        #expect(current.count <= 1 << 20)
        #expect(previous.count <= 1 << 20)
        #expect(previous.count > (1 << 20) - 2 * lineSize)
        for url in [url, rotated] {
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            #expect(mode == 0o600)
        }
        // Whole lines in both generations, and the newest last.
        let entries = AIBridgeLog.readEntries(at: url)
        #expect(entries.count == count)
        #expect(entries.last == entry(count - 1))
        #expect(entries.first == entry(0))
    }

    @Test func lineFormat() throws {
        var e = entry(3)
        e.provider = nil
        e.estimated = true
        let line = String(decoding: try AIBridgeLog.line(for: e), as: UTF8.self)
        #expect(line.hasSuffix("\n"))
        #expect(line.filter { $0 == "\n" }.count == 1)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(Set(object.keys) == ["time", "model", "inputTokens", "outputTokens", "estimated", "status", "durationMs"])
        #expect(object["time"] as? String == "2027-01-15T08:00:03Z")
    }

    @Test func refusesASymlinkedLog() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("nido-ailog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let url = tmp.appendingPathComponent("ai-bridge.log")
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: tmp.appendingPathComponent("elsewhere"))
        #expect(throws: NidoError.self) { _ = try AIBridgeLog(url: url) }
    }
}
