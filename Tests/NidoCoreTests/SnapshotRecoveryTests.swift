// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCore

/// Ruling R-M3A-14: what recovery leaves behind blocks every operation on the bundle, and the
/// rollback and commit edge cases report what really happened.
extension SnapshotStoreTests {
    final class SyncLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func append(_ entry: String) { lock.withLock { stored.append(entry) } }
        var entries: [String] { lock.withLock { stored } }
    }

    func store(
        _ env: Env, fault: (@Sendable (SnapshotStep) throws -> Void)? = nil,
        sync: (@Sendable (URL) throws -> Void)? = nil
    ) -> SnapshotStore {
        var environment = SnapshotStore.Environment()
        environment.availableCapacity = { _ in 1 << 50 }
        environment.supportsCloning = { _ in true }
        environment.faultInjection = fault
        environment.syncDirectory = sync
        return SnapshotStore(bundle: env.bundle, environment: environment)
    }

    /// An uncommitted restore whose original disk cannot be put back: `disk.img` is a directory.
    func stuckOriginal(_ env: Env) throws -> URL {
        let old = env.bundle.url.appendingPathComponent(".disk.img.restore-\(UUID().uuidString).old")
        try env.write("disk-original", to: old)
        try FileManager.default.removeItem(at: env.bundle.diskURL)
        try FileManager.default.createDirectory(at: env.bundle.diskURL, withIntermediateDirectories: false)
        try env.write("x", to: env.bundle.diskURL.appendingPathComponent("blocker"))
        return old
    }

    @Test func recoveryWithNothingToDoHasNoLeftovers() throws {
        let env = try Env()
        defer { env.cleanup() }
        #expect(env.store().recoverInterruptedOperations().leftovers.isEmpty)
        try env.store().recoverBeforeUse()
    }

    @Test func recoveryReportsWhatItCouldNotPutBack() throws {
        let env = try Env()
        defer { env.cleanup() }
        let old = try stuckOriginal(env)
        let outcome = env.store().recoverInterruptedOperations()
        #expect(outcome.leftovers.map(\.lastPathComponent) == [old.lastPathComponent])
        // Kept, never deleted: it may be the VM's only disk.
        #expect(env.read(old) == "disk-original")
        #expect(throws: NidoError.restoreLeftovers([old.path])) { try env.store().recoverBeforeUse() }
        #expect(NidoError.restoreLeftovers([old.path]).localizedDescription.contains(old.path))
    }

    @Test func restoreAndCreateRefuseWhileLeftoversRemain() async throws {
        let (env, snapshot) = try await restoreFixture()
        defer { env.cleanup() }
        let old = try stuckOriginal(env)
        #expect(throws: NidoError.restoreLeftovers([old.path])) { try env.store().restore(snapshot.id, owner: .cli) }
        await #expect(throws: NidoError.restoreLeftovers([old.path])) {
            _ = try await env.store().create(name: "dopo", owner: .cli, session: nil)
        }
        #expect(try env.store().list().map(\.name) == ["prima"])
    }

    @Test func markerThatCannotBeRemovedIsADistinctError() async throws {
        let (env, snapshot) = try await restoreFixture()
        defer { env.cleanup() }
        let failing = store(env, fault: { step in
            if step == .restoreCommitting || step == .restoreMarkerRemoval { throw Injected() }
        })
        var kept: String?
        do {
            try failing.restore(snapshot.id, owner: .cli)
        } catch NidoError.restoreMarkerKept(let path) {
            kept = path
        }
        let marker = try #require(kept)
        #expect(marker.hasSuffix(".commit"))
        #expect(!NidoError.restoreMarkerKept(marker).localizedDescription.contains("originale"))
        // Committed: the snapshot's files, no saved state to resume; recovery finishes it.
        #expect(env.read(env.bundle.diskURL) == "disk-v1")
        #expect(try env.bundle.readConfig().suspendedConfigHash == nil)
        #expect(env.store().recoverInterruptedOperations().leftovers.isEmpty)
        #expect(env.leftovers().isEmpty)
        #expect(env.read(env.bundle.diskURL) == "disk-v1")
    }

    @Test func rollbackSyncsTheBundleBeforeWritingTheConfigBack() async throws {
        let (env, snapshot) = try await restoreFixture()
        defer { env.cleanup() }
        let log = SyncLog()
        let bundle = env.bundle
        let failing = store(env, fault: { step in
            if step == .restoreCommitting {
                log.append("fault")
                throw Injected()
            }
        }, sync: { url in
            if url.standardizedFileURL.path == bundle.url.standardizedFileURL.path {
                let disk = (try? String(contentsOf: bundle.diskURL, encoding: .utf8)) ?? "?"
                let hash = (try? bundle.readConfig().suspendedConfigHash) ?? nil
                log.append("sync \(disk) \(hash ?? "nil")")
            }
            try SnapshotStore.syncDirectoryNow(url)
        })
        #expect(throws: Injected.self) { try failing.restore(snapshot.id, owner: .cli) }
        // The first sync after the fault makes the marker's removal durable (still the
        // snapshot's disk); the next one the originals, put back while config.json has no hash.
        let afterFault = log.entries.drop { $0 != "fault" }.dropFirst()
        #expect(Array(afterFault.prefix(2)) == ["sync disk-v1 nil", "sync disk-v2 nil"])
        #expect(try env.bundle.readConfig().suspendedConfigHash == "stale")
    }

    @Test func failedSyncAfterTheCommitRenameIsAWarning() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let snapshots = env.bundle.snapshotsURL.standardizedFileURL.path
        let failing = store(env, sync: { url in
            if url.standardizedFileURL.path == snapshots { throw POSIXError(.EIO) }
            try SnapshotStore.syncDirectoryNow(url)
        })
        let (snapshot, warnings) = try await failing.createReportingWarnings(name: "prima", owner: .cli, session: nil)
        #expect(snapshot.name == "prima")
        #expect(warnings.count == 1)
        #expect(try env.store().list().map(\.name) == ["prima"])
        // The plain create succeeds as well.
        _ = try await failing.create(name: "seconda", owner: .cli, session: nil)
        #expect(try env.store().list().map(\.name) == ["prima", "seconda"])
    }
}
