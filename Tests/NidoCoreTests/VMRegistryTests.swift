// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCore

@Suite struct VMRegistryTests {
    private func makeRoot() throws -> NidoPaths {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-registry-\(UUID().uuidString)", isDirectory: true)
        let paths = NidoPaths(root: dir)
        try paths.ensureRoot()
        return paths
    }

    @discardableResult
    private func makeVM(_ name: String, cpus: Int = 2, in paths: NidoPaths) throws -> VMBundle {
        let config = VMConfig(
            id: UUID(), name: try VMName(name), guest: .linux, cpuCount: cpus,
            memoryBytes: 2 << 30, diskBytes: 8 << 30, macAddress: "02:00:00:00:00:01")
        return try VMBundle.create(config: config, paths: paths)
    }

    @Test func summariesReportStatusAndResources() async throws {
        let paths = try makeRoot()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try makeVM("idle", cpus: 2, in: paths)
        let busy = try makeVM("busy", cpus: 4, in: paths)
        let lock = try BundleLock.acquire(busy, owner: .app)
        defer { lock.release() }

        let result = try await VMRegistry(paths: paths).summaries()
        #expect(result.map(\.name) == ["busy", "idle"])
        #expect(result[0].status == .running(.app))
        #expect(result[0].cpuCount == 4)
        #expect(result[0].configID == (try busy.readConfig()).id)
        #expect(result[0].id == "busy")
        #expect(result[1].status == .stopped)
        #expect(result[1].cpuCount == 2)
        #expect(result[1].memoryBytes == 2 << 30)
        #expect(result[1].diskBytes == 8 << 30)
    }

    /// The library labels a macOS VM with its version (ruling R4): the summary carries both.
    @Test func summariesCarryGuestAndMacOSVersion() async throws {
        let paths = try makeRoot()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try makeVM("linux", in: paths)
        let mac = VMConfig(
            id: UUID(), name: try VMName("mac"), guest: .macos, cpuCount: 4, memoryBytes: 8 << 30,
            diskBytes: 64 << 30, macAddress: "02:00:00:00:00:02", sshUser: "agente", osVersion: "26.6")
        _ = try VMBundle.create(config: mac, paths: paths)

        let result = try await VMRegistry(paths: paths).summaries()
        #expect(result.map(\.name) == ["linux", "mac"])
        #expect(result[0].guest == .linux)
        #expect(result[0].osVersion == nil)
        #expect(result[1].guest == .macos)
        #expect(result[1].osVersion == "26.6")
    }

    @Test func unreadableConfigYieldsUnreadable() async throws {
        let paths = try makeRoot()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let bundle = try makeVM("broken", in: paths)
        try Data("{ not json".utf8).write(to: bundle.configURL)

        let result = try await VMRegistry(paths: paths).summaries()
        #expect(result.count == 1)
        #expect(result[0].name == "broken")
        #expect(result[0].status == .unreadable(running: nil))
        #expect(result[0].configID == nil)
        #expect(result[0].cpuCount == nil)
        #expect(result[0].memoryBytes == nil)
        #expect(result[0].diskBytes == nil)
    }

    /// A broken config.json does not hide that the VM runs, nor who runs it.
    @Test func unreadableRunningKeepsOwner() async throws {
        let paths = try makeRoot()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let bundle = try makeVM("broken", in: paths)
        try Data("{ not json".utf8).write(to: bundle.configURL)
        let lock = try BundleLock.acquire(bundle, owner: .cli)
        defer { lock.release() }

        let result = try await VMRegistry(paths: paths).summaries()
        #expect(result.map(\.status) == [.unreadable(running: .cli)])
    }

    @Test func sortedCaseInsensitively() async throws {
        let paths = try makeRoot()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try makeVM("beta", in: paths)
        try makeVM("Alpha", in: paths)
        let result = try await VMRegistry(paths: paths).summaries()
        #expect(result.map(\.name) == ["Alpha", "beta"])
    }

    @Test func oldTombstonesAreSwept() async throws {
        let paths = try makeRoot()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let fm = FileManager.default
        let now = Date()
        let old = try makeVM("old", in: paths).moveToTombstone()
        let recent = try makeVM("recent", in: paths).moveToTombstone()
        let other = paths.root.appendingPathComponent(".other.deleting-notauuid", isDirectory: true)
        try fm.createDirectory(at: other, withIntermediateDirectories: false)
        let ages: [String: TimeInterval] = [
            old.lastPathComponent: 2 * 3600, recent.lastPathComponent: 600,
            other.lastPathComponent: 3 * 3600,
        ]
        let changeTime: @Sendable (URL) -> Date? = { now.addingTimeInterval(-(ages[$0.lastPathComponent] ?? 0)) }
        // `other` is not a tombstone by name: it must survive even when old.
        try makeVM("kept", in: paths)

        let result = try await VMRegistry(paths: paths, now: { now }, changeTime: changeTime).summaries()
        #expect(result.map(\.name) == ["kept"])
        #expect(!fm.fileExists(atPath: old.path))
        #expect(fm.fileExists(atPath: recent.path))
        #expect(fm.fileExists(atPath: other.path))
    }

    @Test func freshlyRenamedTombstoneOfOldBundleIsNotSwept() async throws {
        let paths = try makeRoot()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let fm = FileManager.default
        let bundle = try makeVM("idle", in: paths)
        // The bundle sat idle for hours: old mtime, which rename(2) does not change.
        try fm.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-5 * 3600)], ofItemAtPath: bundle.url.path)
        let tombstone = try bundle.moveToTombstone()

        _ = try await VMRegistry(paths: paths).summaries()  // real clock, real ctime
        #expect(fm.fileExists(atPath: tombstone.path))
    }
}
