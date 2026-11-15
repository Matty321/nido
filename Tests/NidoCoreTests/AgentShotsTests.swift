// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import Testing
@testable import NidoCore

@Suite struct AgentShotsTests {
    private func makeBundle() throws -> (tmp: URL, bundle: VMBundle) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-shots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let config = VMConfig(
            id: UUID(), name: try VMName("mac"), guest: .macos, cpuCount: 4,
            memoryBytes: 8 * 1024 * 1024 * 1024, diskBytes: 64 * 1024 * 1024 * 1024,
            macAddress: "02:00:00:00:00:01")
        return (tmp, try VMBundle.create(config: config, paths: NidoPaths(root: tmp.appendingPathComponent("VMs"))))
    }

    @Test func shotsKeepLastTwenty() throws {
        let (tmp, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: tmp) }

        var written: [URL] = []
        for i in 0..<25 {
            written.append(try AgentShots.write(Data("png \(i)".utf8), in: bundle))
        }
        #expect(Set(written).count == 25)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: bundle.agentShotsURL.path)
        #expect(remaining.count == AgentShots.keep)
        #expect(AgentShots.keep == 20)
        for url in written.prefix(5) { #expect(!FileManager.default.fileExists(atPath: url.path)) }
        for (i, url) in written.enumerated().dropFirst(5) {
            #expect(try Data(contentsOf: url) == Data("png \(i)".utf8))
        }
    }

    @Test func shotsArePrivate() throws {
        let (tmp, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let url = try AgentShots.write(Data("png".utf8), in: bundle)
        #expect(url.deletingLastPathComponent().standardizedFileURL == bundle.agentShotsURL.standardizedFileURL)
        #expect(url.pathExtension == "png")
        var info = stat()
        #expect(lstat(url.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(lstat(bundle.agentShotsURL.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o700)
    }
}
