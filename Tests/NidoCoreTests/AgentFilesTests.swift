// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import NidoAgentKit
import Testing
@testable import NidoCore

@Suite struct AgentFilesTests {
    private func makeBundle() throws -> (tmp: URL, bundle: VMBundle) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let config = VMConfig(
            id: UUID(), name: try VMName("mac"), guest: .macos, cpuCount: 4,
            memoryBytes: 8 * 1024 * 1024 * 1024, diskBytes: 64 * 1024 * 1024 * 1024,
            macAddress: "02:00:00:00:00:01")
        return (tmp, try VMBundle.create(config: config, paths: NidoPaths(root: tmp.appendingPathComponent("VMs"))))
    }

    private func mode(_ path: String) -> (type: mode_t, permissions: mode_t)? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return (info.st_mode & S_IFMT, info.st_mode & 0o777)
    }

    @Test func stagedFilesArePrivateAndTakenOnce() throws {
        let (tmp, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let data = Data([0, 1, 2, 0xFF, 0x0A])
        let name = try AgentFiles.stage(data, in: bundle)
        #expect(AgentFiles.isStagedName(name))
        #expect(bundle.agentFilesURL.lastPathComponent == "agent-files")
        #expect(mode(bundle.agentFilesURL.path)?.permissions == 0o700)
        let file = bundle.agentFilesURL.appendingPathComponent(name).path
        #expect(mode(file)?.type == S_IFREG)
        #expect(mode(file)?.permissions == 0o600)

        #expect(try AgentFiles.take(name, in: bundle) == data)
        #expect(mode(file) == nil)
        #expect(throws: (any Error).self) { try AgentFiles.take(name, in: bundle) }
    }

    @Test func emptyFileIsStaged() throws {
        let (tmp, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let name = try AgentFiles.stage(Data(), in: bundle)
        #expect(try AgentFiles.take(name, in: bundle) == Data())
    }

    /// Only `<lowercase uuid>.bin` names a staged file: anything else is refused before any file
    /// is opened.
    @Test func stagedNameRefused() throws {
        let (tmp, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let real = try AgentFiles.stage(Data("x".utf8), in: bundle)
        let uuid = String(real.dropLast(4))

        let outside = tmp.appendingPathComponent("outside.bin")
        try Data("secret".utf8).write(to: outside)
        for name in ["", "../x", "/tmp/x", "x.bin", "\(uuid)", "\(uuid).png", "\(uuid.uppercased()).bin",
                     "../\(real)", "./\(real)", "\(uuid).bin/", outside.path, "\(uuid)x.bin", ".\(real)"] {
            #expect(!AgentFiles.isStagedName(name), "\(name)")
            #expect(throws: (any Error).self, "\(name)") { try AgentFiles.take(name, in: bundle) }
        }
        #expect(AgentFiles.isStagedName(real))
        #expect(try Data(contentsOf: outside) == Data("secret".utf8))
        // The real one is still there, untouched by the refusals.
        #expect(try AgentFiles.take(real, in: bundle) == Data("x".utf8))
    }

    @Test func symlinkedStagedFileRefused() throws {
        let (tmp, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try AgentFiles.stage(Data(), in: bundle)  // creates the folder

        let outside = tmp.appendingPathComponent("config.json")
        try Data("secret".utf8).write(to: outside)
        let name = UUID().uuidString.lowercased() + ".bin"
        let link = bundle.agentFilesURL.appendingPathComponent(name)
        #expect(symlink(outside.path, link.path) == 0)
        #expect(throws: (any Error).self) { try AgentFiles.take(name, in: bundle) }
        #expect(try Data(contentsOf: outside) == Data("secret".utf8))
    }

    @Test func hardLinkAndFifoRefused() throws {
        let (tmp, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try AgentFiles.stage(Data(), in: bundle)

        let outside = tmp.appendingPathComponent("other")
        try Data("secret".utf8).write(to: outside)
        let linked = UUID().uuidString.lowercased() + ".bin"
        #expect(link(outside.path, bundle.agentFilesURL.appendingPathComponent(linked).path) == 0)
        #expect(throws: (any Error).self) { try AgentFiles.take(linked, in: bundle) }
        #expect(try Data(contentsOf: outside) == Data("secret".utf8))

        let fifo = UUID().uuidString.lowercased() + ".bin"
        #expect(mkfifo(bundle.agentFilesURL.appendingPathComponent(fifo).path, 0o600) == 0)
        #expect(throws: (any Error).self) { try AgentFiles.take(fifo, in: bundle) }
    }

    @Test func folderReplacedBySymlinkRefused() throws {
        let (tmp, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let elsewhere = tmp.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let name = UUID().uuidString.lowercased() + ".bin"
        try Data("planted".utf8).write(to: elsewhere.appendingPathComponent(name))
        #expect(symlink(elsewhere.path, bundle.agentFilesURL.path) == 0)

        #expect(throws: (any Error).self) { try AgentFiles.take(name, in: bundle) }
        #expect(throws: (any Error).self) { try AgentFiles.stage(Data("x".utf8), in: bundle) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path) == [name])
    }

    @Test func tooLargeStagedFileRefused() throws {
        let (tmp, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let name = try AgentFiles.stage(Data(), in: bundle)
        let path = bundle.agentFilesURL.appendingPathComponent(name).path
        #expect(truncate(path, off_t(AgentProtocol.maxTransferBytes + 1)) == 0)  // sparse
        #expect(throws: (any Error).self) { try AgentFiles.take(name, in: bundle) }
        #expect(mode(path) == nil)

        #expect(throws: (any Error).self) {
            try AgentFiles.stage(Data(count: AgentProtocol.maxTransferBytes + 1), in: bundle)
        }
        let full = try AgentFiles.stage(Data(count: AgentProtocol.maxTransferBytes), in: bundle)
        #expect(try AgentFiles.take(full, in: bundle).count == AgentProtocol.maxTransferBytes)
    }

    @Test func sweepDeletesOld() throws {
        let (tmp, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let old = try AgentFiles.stage(Data("old".utf8), in: bundle)
        let fresh = try AgentFiles.stage(Data("fresh".utf8), in: bundle)
        let leftover = bundle.agentFilesURL.appendingPathComponent(".\(old).\(UUID().uuidString).tmp")
        try Data("tmp".utf8).write(to: leftover)
        let tenMinutesAgo = Date().addingTimeInterval(-601)
        for path in [bundle.agentFilesURL.appendingPathComponent(old).path, leftover.path] {
            try FileManager.default.setAttributes([.modificationDate: tenMinutesAgo], ofItemAtPath: path)
        }

        AgentFiles.sweep(in: bundle, olderThan: 600)
        let left = try FileManager.default.contentsOfDirectory(atPath: bundle.agentFilesURL.path)
        #expect(left == [fresh])
        #expect(AgentFiles.maxAge == 600)

        // Staging sweeps too.
        try FileManager.default.setAttributes(
            [.modificationDate: tenMinutesAgo], ofItemAtPath: bundle.agentFilesURL.appendingPathComponent(fresh).path)
        let next = try AgentFiles.stage(Data(), in: bundle)
        #expect(try FileManager.default.contentsOfDirectory(atPath: bundle.agentFilesURL.path) == [next])
    }

    @Test func sweepWithoutFolderDoesNothing() throws {
        let (tmp, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: tmp) }
        AgentFiles.sweep(in: bundle, olderThan: 600)
        #expect(mode(bundle.agentFilesURL.path) == nil)
    }
}
