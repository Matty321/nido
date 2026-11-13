// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCore

@Suite struct ChecksumsTests {
    let hexA = String(repeating: "ab", count: 64)
    let hexB = String(repeating: "CD", count: 64)

    @Test func parsesValidLines() {
        let text = "\(hexA)  debian-13-genericcloud-arm64.raw\n\(hexB) *other.qcow2\n"
        let map = Checksums.parseSHA512SUMS(text)
        #expect(map["debian-13-genericcloud-arm64.raw"] == hexA)
        #expect(map["other.qcow2"] == hexB.lowercased())
        #expect(map.count == 2)
    }

    @Test func ignoresMalformedLines() {
        let text = """

        short  file.raw
        \(String(repeating: "g", count: 128))  nothex.raw
        \(hexA)file-no-space.raw
        \(hexA)  
        \(String(repeating: "a", count: 129))  toolong.raw
        \(hexA)  good.raw
        """
        let map = Checksums.parseSHA512SUMS(text)
        #expect(map == ["good.raw": hexA])
    }

    @Test func sha512OfFixtureFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-checksum-\(UUID().uuidString)")
        try Data("nido\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try Checksums.sha512(of: url) == "6e7b22ca39d98e7d4d58b871636f341e320f75c03e9894d7c2c89a75be224951448bbd165843bf8ea18ec18206ca9969d9310662e970da2b94f673c407a02517")
    }

    @Test func sha512OfMissingFileThrows() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-missing-\(UUID().uuidString)")
        #expect(throws: (any Error).self) { try Checksums.sha512(of: url) }
    }
}
