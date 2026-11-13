// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCore

@Suite struct RunningVMsTests {
    private func makeRoot() throws -> NidoPaths {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-running-\(UUID().uuidString)", isDirectory: true)
        let paths = NidoPaths(root: dir)
        try paths.ensureRoot()
        return paths
    }

    @discardableResult
    private func makeVM(_ name: String, in paths: NidoPaths) throws -> VMBundle {
        let config = VMConfig(
            id: UUID(), name: try VMName(name), guest: .linux, cpuCount: 2,
            memoryBytes: 2 << 30, diskBytes: 8 << 30, macAddress: "02:00:00:00:00:01")
        return try VMBundle.create(config: config, paths: paths)
    }

    /// `nido start` and the app run a VM; a maintenance command (`.cliOperation`) and a bundle
    /// nobody holds do not.
    @Test func countsAppAndCLIHoldersOnly() throws {
        let paths = try makeRoot()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let started = try makeVM("avviata", in: paths)
        let busy = try makeVM("manutenzione", in: paths)
        try makeVM("spenta", in: paths)
        let cli = try BundleLock.acquire(started, owner: .cli)
        defer { cli.release() }
        let operation = try BundleLock.acquire(busy, owner: .cliOperation)
        defer { operation.release() }

        #expect(RunningVMs.names(paths: paths).map(\.rawValue) == ["avviata"])
    }

    /// Both kinds of runner, sorted by name.
    @Test func listsAppAndCLIRunnersSortedByName() throws {
        let paths = try makeRoot()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let zeta = try makeVM("zeta", in: paths)
        let alpha = try makeVM("Alpha", in: paths)
        let app = try BundleLock.acquire(zeta, owner: .app)
        defer { app.release() }
        let cli = try BundleLock.acquire(alpha, owner: .cli)
        defer { cli.release() }

        #expect(RunningVMs.names(paths: paths).map(\.rawValue) == ["Alpha", "zeta"])
    }

    /// A bundle whose `config.json` cannot be read, not running, is skipped without failing the
    /// listing; a missing root means no VM at all.
    @Test func ignoresUnreadableBundles() throws {
        let paths = try makeRoot()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let broken = try makeVM("rotta", in: paths)
        try Data("{ non è json".utf8).write(to: broken.configURL)
        let running = try makeVM("accesa", in: paths)
        let lock = try BundleLock.acquire(running, owner: .cli)
        defer { lock.release() }

        #expect(RunningVMs.names(paths: paths).map(\.rawValue) == ["accesa"])
        let missing = NidoPaths(root: paths.root.appendingPathComponent("assente", isDirectory: true))
        #expect(RunningVMs.names(paths: missing).isEmpty)
    }

    /// A running VM is never missed because its `config.json` is unreadable: held means running,
    /// and the name comes from the bundle's folder.
    @Test func countsRunningBundleWithUnreadableConfig() throws {
        let paths = try makeRoot()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let broken = try makeVM("rotta", in: paths)
        try Data("{ non è json".utf8).write(to: broken.configURL)
        let lock = try BundleLock.acquire(broken, owner: .cli)
        defer { lock.release() }

        #expect(RunningVMs.names(paths: paths).map(\.rawValue) == ["rotta"])
    }
}
