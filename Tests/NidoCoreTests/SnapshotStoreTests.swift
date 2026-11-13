// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCore

/// A stand-in for a running `VMSession`: records the calls, writes a fake saved state.
@MainActor
final class FakeStateSession: MachineStateSaving {
    let bundleURL: URL
    var state: VMRunState = .running
    let attachedStateHash: String
    var unsupportedReason: String?
    var resumeFails = false
    /// When true, the guest powers off while `pause` runs: the machine ends stopped.
    var stopsWhilePausing = false
    var calls: [String] = []

    init(bundle: VMBundle, hash: String = "fake-hash") {
        bundleURL = bundle.url
        attachedStateHash = hash
    }

    func validateSaveRestoreSupport() throws {
        if let unsupportedReason { throw NidoError.snapshotUnsupported(unsupportedReason) }
    }

    func pause() async throws {
        calls.append("pause")
        state = stopsWhilePausing ? .stopped : .paused
    }

    func resume() async throws {
        calls.append("resume")
        if resumeFails { throw NidoError.notRunning("vm") }
        state = .running
    }

    func saveMachineState(to url: URL) async throws {
        calls.append("save")
        guard state == .paused else { throw NidoError.notRunning("vm") }
        try Data("saved-state".utf8).write(to: url)
    }
}

@Suite(.italian) struct SnapshotStoreTests {
    struct Env {
        let tmp: URL
        let paths: NidoPaths
        let bundle: VMBundle

        /// `guest` `.macos`: the macOS file set (auxiliary storage, hardware model; no NVRAM, no seed).
        init(guest: GuestOS = .linux) throws {
            tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("nido-test-snap-\(UUID().uuidString)", isDirectory: true)
            paths = NidoPaths(root: tmp.appendingPathComponent("VMs", isDirectory: true))
            let config = VMConfig(
                id: UUID(), name: try VMName("vm"), guest: guest, cpuCount: 2,
                memoryBytes: 1 << 30, diskBytes: 1 << 20, macAddress: "02:00:00:00:00:01")
            bundle = try VMBundle.create(config: config, paths: paths)
            try write("disk-v1", to: bundle.diskURL)
            try write("machine-id", to: bundle.machineIdentifierURL)
            switch guest {
            case .linux:
                try write("nvram-v1", to: bundle.nvramURL)
                try write("seed", to: bundle.seedURL)
            case .macos:
                try write("aux-v1", to: bundle.auxiliaryStorageURL)
                try write("hardware-model", to: bundle.hardwareModelURL)
            }
        }

        func write(_ text: String, to url: URL) throws {
            try Data(text.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }

        func read(_ url: URL) -> String? {
            (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
        }

        func entries(_ url: URL) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
        }

        func store(
            capacity: UInt64 = 1 << 50, cloning: Bool = true, forceCopy: Bool = false,
            fault: (@Sendable (SnapshotStep) throws -> Void)? = nil
        ) -> SnapshotStore {
            var environment = SnapshotStore.Environment()
            environment.availableCapacity = { _ in capacity }
            environment.supportsCloning = { _ in cloning }
            environment.forceCopy = forceCopy
            environment.faultInjection = fault
            return SnapshotStore(bundle: bundle, environment: environment)
        }

        /// Entries starting with a dot, apart from the lock: restore leftovers.
        func leftovers() -> [String] {
            entries(bundle.url).filter { $0.hasPrefix(".") && $0 != ".lock" && $0 != ".config.lock" }
        }

        func cleanup() { try? FileManager.default.removeItem(at: tmp) }
    }

    struct Injected: Error {}

    func perms(_ url: URL) throws -> Int {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        return (a[.posixPermissions] as! NSNumber).intValue
    }

    @Test func createStoppedSnapshotClonesDiskAndNvram() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let snapshot = try await env.store().create(name: "prima", owner: .cli, session: nil)
        #expect(snapshot.name == "prima")
        #expect(!snapshot.hasSavedState)
        #expect(snapshot.configHash == (try env.bundle.readConfig()).stateHash())

        let dir = env.bundle.snapshotsURL.appendingPathComponent(snapshot.id.uuidString)
        #expect(env.entries(env.bundle.snapshotsURL) == [snapshot.id.uuidString])
        #expect(env.entries(dir) == ["disk.img", "meta.json", "nvram.efi"])
        #expect(env.read(dir.appendingPathComponent("disk.img")) == "disk-v1")
        #expect(env.read(dir.appendingPathComponent("nvram.efi")) == "nvram-v1")
        #expect(try perms(env.bundle.snapshotsURL) == 0o700)
        #expect(try perms(dir) == 0o700)
        for file in ["disk.img", "nvram.efi", "meta.json"] {
            #expect(try perms(dir.appendingPathComponent(file)) == 0o600)
        }
        // The clone is independent of the VM's disk.
        try env.write("disk-v2", to: env.bundle.diskURL)
        #expect(env.read(dir.appendingPathComponent("disk.img")) == "disk-v1")

        let listed = try env.store().list()
        #expect(listed.map(\.id) == [snapshot.id])
        #expect(listed.first?.name == "prima")
        #expect(try env.store().find("PRIMA").id == snapshot.id)
        #expect(try env.store().find(snapshot.id.uuidString).id == snapshot.id)
        // The lock is released afterwards.
        #expect(BundleLock.holder(env.bundle) == nil)
    }

    @Test func createWithoutSessionRefusedWhileRunning() async throws {
        let env = try Env()
        defer { env.cleanup() }
        // The lock is held by this process here, so the store sees a VM running without a session.
        let lock = try BundleLock.acquire(env.bundle, owner: .app)
        defer { lock.release() }
        await #expect(throws: NidoError.vmMustBeStopped("vm")) {
            _ = try await env.store().create(name: "prima", owner: .app, session: nil)
        }
        #expect(env.entries(env.bundle.url).contains("snapshots") == false)
    }

    @Test func runningElsewhereRefusal() {
        #expect(NidoError.runningInAnotherProcess.errorDescription
            == "la VM è in esecuzione in un altro processo: usa l'app o arrestala")
        let me = getpid()
        #expect(SnapshotStore.refusal(holder: LockHolder(pid: me + 1, owner: .app), name: "vm", ownPID: me)
            == .runningInAnotherProcess)
        #expect(SnapshotStore.refusal(holder: LockHolder(pid: -1, owner: .cli), name: "vm", ownPID: me)
            == .runningInAnotherProcess)
        #expect(SnapshotStore.refusal(holder: LockHolder(pid: me, owner: .app), name: "vm", ownPID: me)
            == .vmMustBeStopped("vm"))
    }

    @Test @MainActor func liveSnapshotPausesSavesClonesAndResumes() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let lock = try BundleLock.acquire(env.bundle, owner: .app)  // the VM runs in this process
        defer { lock.release() }
        let session = FakeStateSession(bundle: env.bundle, hash: "effective")
        let snapshot = try await env.store().create(name: "live", owner: .app, session: session)
        #expect(session.calls == ["pause", "save", "resume"])
        #expect(session.state == .running)
        #expect(snapshot.hasSavedState)
        #expect(snapshot.configHash == "effective")
        let dir = env.bundle.snapshotsURL.appendingPathComponent(snapshot.id.uuidString)
        #expect(env.entries(dir) == ["disk.img", "meta.json", "nvram.efi", "state.vzvmsave"])
        #expect(try perms(dir.appendingPathComponent("state.vzvmsave")) == 0o600)
    }

    @Test @MainActor func liveSnapshotUnsupportedIsRefused() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let lock = try BundleLock.acquire(env.bundle, owner: .app)
        defer { lock.release() }
        let session = FakeStateSession(bundle: env.bundle)
        session.unsupportedReason = "dispositivo non salvabile"
        await #expect(throws: NidoError.snapshotUnsupported("dispositivo non salvabile")) {
            _ = try await env.store().create(name: "live", owner: .app, session: session)
        }
        #expect(session.calls.isEmpty)
        #expect(env.entries(env.bundle.snapshotsURL).isEmpty)
    }

    @Test @MainActor func liveSnapshotFailureResumesAndCleansUp() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let lock = try BundleLock.acquire(env.bundle, owner: .app)
        defer { lock.release() }
        let session = FakeStateSession(bundle: env.bundle)
        let store = env.store(fault: { step in if step == .diskCloned { throw Injected() } })
        await #expect(throws: Injected.self) {
            _ = try await store.create(name: "live", owner: .app, session: session)
        }
        #expect(session.calls == ["pause", "save", "resume"])
        #expect(session.state == .running)
        #expect(env.entries(env.bundle.snapshotsURL).isEmpty)
    }

    @Test func restoreRefusedWhileRunning() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let snapshot = try await env.store().create(name: "prima", owner: .cli, session: nil)
        try env.write("disk-v2", to: env.bundle.diskURL)
        let before = env.entries(env.bundle.url)
        let config = try Data(contentsOf: env.bundle.configURL)
        for owner in [LockOwner.cli, .app] {
            let lock = try BundleLock.acquire(env.bundle, owner: owner)
            #expect(throws: NidoError.vmMustBeStopped("vm")) {
                try env.store().restore(snapshot.id, owner: .cli)
            }
            lock.release()
        }
        #expect(env.entries(env.bundle.url) == before)
        #expect(env.read(env.bundle.diskURL) == "disk-v2")
        #expect(env.read(env.bundle.nvramURL) == "nvram-v1")
        #expect(try Data(contentsOf: env.bundle.configURL) == config)
    }

    @Test func restoreReplacesDiskAtomically() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let snapshot = try await env.store().create(name: "prima", owner: .cli, session: nil)
        try env.write("disk-v2", to: env.bundle.diskURL)
        try env.write("nvram-v2", to: env.bundle.nvramURL)
        // A stale saved state from a later suspend: it does not belong to the snapshot's disk.
        try env.write("stale", to: env.bundle.stateURL)
        var config = try env.bundle.readConfig()
        config.suspendedConfigHash = "stale"
        try env.bundle.writeConfig(config)
        let before = env.entries(env.bundle.url)

        // A failure after the copies are prepared leaves the bundle as it was, no temp files.
        let failing = env.store(fault: { step in if step == .restorePrepared { throw Injected() } })
        #expect(throws: Injected.self) { try failing.restore(snapshot.id, owner: .cli) }
        #expect(env.entries(env.bundle.url) == before)
        #expect(env.read(env.bundle.diskURL) == "disk-v2")
        #expect(env.read(env.bundle.stateURL) == "stale")

        // A failure after the swap is rolled back as well.
        let late = env.store(fault: { step in if step == .restoreReplaced { throw Injected() } })
        #expect(throws: Injected.self) { try late.restore(snapshot.id, owner: .cli) }
        #expect(env.entries(env.bundle.url) == before)
        #expect(env.read(env.bundle.diskURL) == "disk-v2")
        #expect(env.read(env.bundle.nvramURL) == "nvram-v2")
        #expect(env.read(env.bundle.stateURL) == "stale")
        #expect(try env.bundle.readConfig().suspendedConfigHash == "stale")

        try env.store().restore(snapshot.id, owner: .cli)
        #expect(env.read(env.bundle.diskURL) == "disk-v1")
        #expect(env.read(env.bundle.nvramURL) == "nvram-v1")
        #expect(!FileManager.default.fileExists(atPath: env.bundle.stateURL.path))
        #expect(try env.bundle.readConfig().suspendedConfigHash == nil)
        #expect(env.entries(env.bundle.url).filter { $0.hasPrefix(".") && $0 != ".lock" && $0 != ".config.lock" }.isEmpty)
        #expect(try perms(env.bundle.diskURL) == 0o600)
        try env.bundle.verifyInnerFiles(for: .linux)
        // The snapshot is still there and independent of the restored disk.
        try env.write("disk-v3", to: env.bundle.diskURL)
        let dir = env.bundle.snapshotsURL.appendingPathComponent(snapshot.id.uuidString)
        #expect(env.read(dir.appendingPathComponent("disk.img")) == "disk-v1")
        #expect(BundleLock.holder(env.bundle) == nil)
    }

    @Test @MainActor func restoreWithSavedStateSetsSuspendedHash() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let snapshot: Snapshot
        do {
            let lock = try BundleLock.acquire(env.bundle, owner: .app)
            defer { lock.release() }
            snapshot = try await env.store().create(
                name: "live", owner: .app, session: FakeStateSession(bundle: env.bundle, hash: "effective"))
        }
        try env.store().restore(snapshot.id, owner: .app)
        #expect(env.read(env.bundle.stateURL) == "saved-state")
        #expect(try perms(env.bundle.stateURL) == 0o600)
        #expect(try env.bundle.readConfig().suspendedConfigHash == "effective")
        #expect(env.bundle.innerFileURLs(for: .linux).contains(env.bundle.stateURL))
        try env.bundle.verifyInnerFiles(for: .linux)
    }

    @Test func partialSnapshotIsRemovedOnFailure() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let seen = SeenSteps()
        let store = env.store(fault: { step in
            seen.append(step)
            if step == .diskCloned { throw Injected() }
        })
        await #expect(throws: Injected.self) {
            _ = try await store.create(name: "prima", owner: .cli, session: nil)
        }
        #expect(seen.steps.contains(.diskCloned))
        #expect(env.entries(env.bundle.snapshotsURL).isEmpty)
        #expect(env.read(env.bundle.diskURL) == "disk-v1")
        #expect(try env.store().list().isEmpty)
        #expect(BundleLock.holder(env.bundle) == nil)
    }

    @Test func insufficientSpaceRefused() async throws {
        let env = try Env()
        defer { env.cleanup() }
        // A volume that clones: only the margin.
        let margin = SnapshotStore.spaceMargin
        await #expect(throws: NidoError.insufficientSpace(needed: margin, available: margin - 1)) {
            _ = try await env.store(capacity: margin - 1).create(name: "prima", owner: .cli, session: nil)
        }
        #expect(env.entries(env.bundle.snapshotsURL).isEmpty)
        // One that cannot: also the allocated size of disk and NVRAM (a sparse copy).
        func allocated(_ url: URL) -> UInt64 {
            var info = stat()
            _ = lstat(url.path, &info)
            return UInt64(info.st_blocks) * 512
        }
        let needed = allocated(env.bundle.diskURL) + allocated(env.bundle.nvramURL) + margin
        await #expect(throws: NidoError.insufficientSpace(needed: needed, available: needed - 1)) {
            _ = try await env.store(capacity: needed - 1, cloning: false)
                .create(name: "prima", owner: .cli, session: nil)
        }
        _ = try await env.store(capacity: needed, cloning: false).create(name: "prima", owner: .cli, session: nil)
        #expect(NidoError.insufficientSpace(needed: 3 << 30, available: 1 << 30).errorDescription
            == "spazio insufficiente: servono 3 GiB, disponibili 1 GiB")
    }

    @Test func deleteRemovesDirectory() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let first = try await env.store().create(name: "uno", owner: .cli, session: nil)
        let second = try await env.store().create(name: "due", owner: .cli, session: nil)
        let lock = try BundleLock.acquire(env.bundle, owner: .app)
        #expect(throws: NidoError.vmMustBeStopped("vm")) { try env.store().delete(first.id, owner: .cli) }
        lock.release()
        try env.store().delete(first.id, owner: .cli)
        #expect(env.entries(env.bundle.snapshotsURL) == [second.id.uuidString])
        #expect(try env.store().list().map(\.name) == ["due"])
        #expect(throws: NidoError.snapshotNotFound(first.id.uuidString)) {
            try env.store().delete(first.id, owner: .cli)
        }
        #expect(throws: NidoError.snapshotNotFound("uno")) { _ = try env.store().find("uno") }
    }

    @Test func snapshotNamesValidated() async throws {
        let env = try Env()
        defer { env.cleanup() }
        for bad in ["", "-x", "a b", "a..b", "../x", String(repeating: "a", count: 64), "nome/x"] {
            await #expect(throws: NidoError.invalidSnapshotName(bad)) {
                _ = try await env.store().create(name: bad, owner: .cli, session: nil)
            }
        }
        _ = try await env.store().create(name: "Prima_1.0-a", owner: .cli, session: nil)
        await #expect(throws: NidoError.snapshotNameTaken("prima_1.0-A")) {
            _ = try await env.store().create(name: "prima_1.0-A", owner: .cli, session: nil)
        }
        #expect(try env.store().list().count == 1)
    }

    @Test func listIgnoresPartialAndForeignEntries() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let snapshot = try await env.store().create(name: "prima", owner: .cli, session: nil)
        let fm = FileManager.default
        try fm.createDirectory(
            at: env.bundle.snapshotsURL.appendingPathComponent(".\(UUID().uuidString).partial"),
            withIntermediateDirectories: false)
        try fm.createDirectory(
            at: env.bundle.snapshotsURL.appendingPathComponent("not-a-uuid"), withIntermediateDirectories: false)
        try fm.createSymbolicLink(
            at: env.bundle.snapshotsURL.appendingPathComponent(UUID().uuidString),
            withDestinationURL: env.bundle.snapshotsURL.appendingPathComponent(snapshot.id.uuidString))
        #expect(try env.store().list().map(\.id) == [snapshot.id])
    }

    // MARK: - macOS guests (M3b)

    @Test func macSnapshotIncludesAuxiliaryStorage() async throws {
        let env = try Env(guest: .macos)
        defer { env.cleanup() }
        let snapshot = try await env.store().create(name: "prima", owner: .cli, session: nil)
        let dir = env.bundle.snapshotsURL.appendingPathComponent(snapshot.id.uuidString)
        // Disk and auxiliary storage; the hardware model and the machine identifier stay the bundle's.
        #expect(env.entries(dir) == ["auxiliary-storage.img", "disk.img", "meta.json"])
        #expect(env.read(dir.appendingPathComponent("auxiliary-storage.img")) == "aux-v1")
        #expect(try perms(dir.appendingPathComponent("auxiliary-storage.img")) == 0o600)
        try env.write("aux-v2", to: env.bundle.auxiliaryStorageURL)
        #expect(env.read(dir.appendingPathComponent("auxiliary-storage.img")) == "aux-v1")
    }

    @Test @MainActor func macLiveSnapshotIncludesAuxiliaryStorage() async throws {
        let env = try Env(guest: .macos)
        defer { env.cleanup() }
        let lock = try BundleLock.acquire(env.bundle, owner: .app)
        defer { lock.release() }
        let session = FakeStateSession(bundle: env.bundle)
        let snapshot = try await env.store().create(name: "accesa", owner: .app, session: session)
        let dir = env.bundle.snapshotsURL.appendingPathComponent(snapshot.id.uuidString)
        #expect(env.entries(dir) == ["auxiliary-storage.img", "disk.img", "meta.json", "state.vzvmsave"])
        #expect(session.calls == ["pause", "save", "resume"])
    }

    /// The disk and the auxiliary storage always come back together: a crash at any step of a
    /// restore, then the recovery, leaves either both originals or both snapshot copies.
    @Test func macRestoreReplacesAuxiliaryStorageAtomically() async throws {
        let steps: [SnapshotStep] = [
            .restorePrepared, .restoreInvalidated, .restoreDiskReplaced, .restoreReplaced, .restoreCommitting,
        ]
        for step in steps {
            let env = try Env(guest: .macos)
            defer { env.cleanup() }
            let snapshot = try await env.store().create(name: "prima", owner: .cli, session: nil)
            try env.write("disk-v2", to: env.bundle.diskURL)
            try env.write("aux-v2", to: env.bundle.auxiliaryStorageURL)

            // A thrown error at this step rolls everything back.
            let failing = env.store(fault: { if $0 == step { throw Injected() } })
            #expect(throws: Injected.self) { try failing.restore(snapshot.id, owner: .cli) }
            #expect(env.read(env.bundle.diskURL) == "disk-v2", "\(step)")
            #expect(env.read(env.bundle.auxiliaryStorageURL) == "aux-v2", "\(step)")
            #expect(env.leftovers().isEmpty, "\(step)")

            // A crash at this step, then the recovery: both old or both new.
            let crashing = env.store(fault: { if $0 == step { throw SnapshotStore.SimulatedCrash() } })
            #expect(throws: SnapshotStore.SimulatedCrash.self) { try crashing.restore(snapshot.id, owner: .cli) }
            let lock = try BundleLock.acquire(env.bundle, owner: .cli)
            #expect(env.store().recoverInterruptedOperations().leftovers.isEmpty, "\(step)")
            lock.release()
            let pair = (env.read(env.bundle.diskURL), env.read(env.bundle.auxiliaryStorageURL))
            if step == .restoreCommitting {
                #expect(pair == ("disk-v1", "aux-v1"), "\(step)")
            } else {
                #expect(pair == ("disk-v2", "aux-v2"), "\(step)")
            }
            #expect(env.leftovers().isEmpty, "\(step)")
            try env.bundle.verifyInnerFiles(for: .macos)
            #expect(env.read(env.bundle.hardwareModelURL) == "hardware-model")
            #expect(env.read(env.bundle.machineIdentifierURL) == "machine-id")
        }

        let env = try Env(guest: .macos)
        defer { env.cleanup() }
        let snapshot = try await env.store().create(name: "prima", owner: .cli, session: nil)
        try env.write("disk-v2", to: env.bundle.diskURL)
        try env.write("aux-v2", to: env.bundle.auxiliaryStorageURL)
        try env.store().restore(snapshot.id, owner: .cli)
        #expect(env.read(env.bundle.diskURL) == "disk-v1")
        #expect(env.read(env.bundle.auxiliaryStorageURL) == "aux-v1")
        #expect(!FileManager.default.fileExists(atPath: env.bundle.nvramURL.path))
        #expect(env.leftovers().isEmpty)
        try env.bundle.verifyInnerFiles(for: .macos)
    }

    /// A snapshot that lost its auxiliary storage is refused before anything in the bundle changes:
    /// a disk without the matching auxiliary storage would not boot.
    @Test func macRestoreWithoutAuxiliaryStorageIsRefused() async throws {
        let env = try Env(guest: .macos)
        defer { env.cleanup() }
        let snapshot = try await env.store().create(name: "prima", owner: .cli, session: nil)
        let dir = env.bundle.snapshotsURL.appendingPathComponent(snapshot.id.uuidString)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("auxiliary-storage.img"))
        try env.write("disk-v2", to: env.bundle.diskURL)
        let before = env.entries(env.bundle.url)
        #expect(throws: (any Error).self) { try env.store().restore(snapshot.id, owner: .cli) }
        #expect(env.entries(env.bundle.url) == before)
        #expect(env.read(env.bundle.diskURL) == "disk-v2")
        #expect(env.read(env.bundle.auxiliaryStorageURL) == "aux-v1")
    }

    /// A macOS bundle is checked with its own file set: a symlinked auxiliary storage is refused.
    @Test func macSnapshotRefusesASymlinkedAuxiliaryStorage() async throws {
        let env = try Env(guest: .macos)
        defer { env.cleanup() }
        let elsewhere = env.tmp.appendingPathComponent("aux-elsewhere")
        try env.write("aux", to: elsewhere)
        try FileManager.default.removeItem(at: env.bundle.auxiliaryStorageURL)
        try FileManager.default.createSymbolicLink(at: env.bundle.auxiliaryStorageURL, withDestinationURL: elsewhere)
        await #expect(throws: NidoError.unsafePath(env.bundle.auxiliaryStorageURL.path)) {
            _ = try await env.store().create(name: "prima", owner: .cli, session: nil)
        }
    }

}

extension SnapshotStoreTests {
    /// A bundle with a snapshot of disk-v1/nvram-v1 and, since then, disk-v2/nvram-v2 and a
    /// suspended state "stale" with hash "stale".
    func restoreFixture() async throws -> (Env, Snapshot) {
        let env = try Env()
        let snapshot = try await env.store().create(name: "prima", owner: .cli, session: nil)
        try env.write("disk-v2", to: env.bundle.diskURL)
        try env.write("nvram-v2", to: env.bundle.nvramURL)
        try env.write("stale", to: env.bundle.stateURL)
        var config = try env.bundle.readConfig()
        config.suspendedConfigHash = "stale"
        try env.bundle.writeConfig(config)
        return (env, snapshot)
    }

    @Test func restoreInvalidatesBeforeReplacing() async throws {
        let (env, snapshot) = try await restoreFixture()
        defer { env.cleanup() }
        let seen = SeenValues()
        let bundle = env.bundle
        let store = env.store(fault: { step in
            guard step == .restoreDiskReplaced else { return }
            seen.set("hash", (try? bundle.readConfig().suspendedConfigHash ?? "nil") ?? "error")
            seen.set("state", FileManager.default.fileExists(atPath: bundle.stateURL.path) ? "present" : "absent")
            throw Injected()
        })
        #expect(throws: Injected.self) { try store.restore(snapshot.id, owner: .cli) }
        // While the disk was already the snapshot's, no saved state could be resumed.
        #expect(seen.get("hash") == "nil")
        #expect(seen.get("state") == "absent")
        // The thrown error rolled everything back, the original hash included.
        #expect(env.read(env.bundle.diskURL) == "disk-v2")
        #expect(env.read(env.bundle.nvramURL) == "nvram-v2")
        #expect(env.read(env.bundle.stateURL) == "stale")
        #expect(try env.bundle.readConfig().suspendedConfigHash == "stale")
        #expect(env.leftovers().isEmpty)
    }

    @Test func failureWhileCommittingIsRolledBack() async throws {
        // `.restoreCommitting` stands for the last step, the write of config.json, failing.
        let (env, snapshot) = try await restoreFixture()
        defer { env.cleanup() }
        let store = env.store(fault: { step in if step == .restoreCommitting { throw Injected() } })
        #expect(throws: Injected.self) { try store.restore(snapshot.id, owner: .cli) }
        #expect(env.read(env.bundle.diskURL) == "disk-v2")
        #expect(env.read(env.bundle.stateURL) == "stale")
        #expect(try env.bundle.readConfig().suspendedConfigHash == "stale")
        #expect(env.leftovers().isEmpty)
    }

    @Test func crashBeforeCommitIsRolledBackByRecovery() async throws {
        let (env, snapshot) = try await restoreFixture()
        defer { env.cleanup() }
        let crashing = env.store(fault: { step in
            if step == .restoreDiskReplaced { throw SnapshotStore.SimulatedCrash() }
        })
        #expect(throws: SnapshotStore.SimulatedCrash.self) { try crashing.restore(snapshot.id, owner: .cli) }
        // What a crash leaves: the snapshot's disk, the old NVRAM, no usable saved state.
        #expect(env.read(env.bundle.diskURL) == "disk-v1")
        #expect(env.read(env.bundle.nvramURL) == "nvram-v2")
        #expect(try env.bundle.readConfig().suspendedConfigHash == nil)
        #expect(!FileManager.default.fileExists(atPath: env.bundle.stateURL.path))
        #expect(!env.leftovers().isEmpty)

        let lock = try BundleLock.acquire(env.bundle, owner: .cli)
        env.store().recoverInterruptedOperations()
        lock.release()
        #expect(env.read(env.bundle.diskURL) == "disk-v2")
        #expect(env.read(env.bundle.nvramURL) == "nvram-v2")
        #expect(env.read(env.bundle.stateURL) == "stale")
        #expect(try env.bundle.readConfig().suspendedConfigHash == nil)  // stays unusable
        #expect(env.leftovers().isEmpty)
        try env.bundle.verifyInnerFiles(for: .linux)
    }

    @Test func crashAfterCommitIsFinishedByRecovery() async throws {
        let (env, snapshot) = try await restoreFixture()
        defer { env.cleanup() }
        let crashing = env.store(fault: { step in
            if step == .restoreCommitting { throw SnapshotStore.SimulatedCrash() }
        })
        #expect(throws: SnapshotStore.SimulatedCrash.self) { try crashing.restore(snapshot.id, owner: .cli) }
        // The next restore (any locked operation) recovers first: here, a create.
        _ = try await env.store().create(name: "dopo", owner: .cli, session: nil)
        #expect(env.read(env.bundle.diskURL) == "disk-v1")
        #expect(env.read(env.bundle.nvramURL) == "nvram-v1")
        #expect(!FileManager.default.fileExists(atPath: env.bundle.stateURL.path))
        #expect(try env.bundle.readConfig().suspendedConfigHash == nil)
        #expect(env.leftovers().isEmpty)
    }

    @Test func failedUndoKeepsOriginalsAndRecoveryPutsThemBack() async throws {
        let (env, snapshot) = try await restoreFixture()
        defer { env.cleanup() }
        let store = env.store(fault: { step in
            if step == .restoreReplaced || step == .restoreUndo { throw Injected() }
        })
        var kept: String?
        do {
            try store.restore(snapshot.id, owner: .cli)
        } catch NidoError.restoreIncomplete(let path) {
            kept = path
        }
        let path = try #require(kept)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(path.contains(".restore-") && path.hasSuffix(".old"))
        #expect(try env.bundle.readConfig().suspendedConfigHash == nil)
        // Nothing of the user's was deleted: the next locked operation puts it back.
        try env.store().restore(snapshot.id, owner: .cli)  // recovers, then restores for real
        #expect(env.read(env.bundle.diskURL) == "disk-v1")
        #expect(env.leftovers().isEmpty)
        // And on its own (without a restore after it):
        let (env2, snapshot2) = try await restoreFixture()
        defer { env2.cleanup() }
        let store2 = env2.store(fault: { step in
            if step == .restoreReplaced || step == .restoreUndo { throw Injected() }
        })
        #expect(throws: (any Error).self) { try store2.restore(snapshot2.id, owner: .cli) }
        env2.store().recoverInterruptedOperations()
        #expect(env2.read(env2.bundle.diskURL) == "disk-v2")
        #expect(env2.read(env2.bundle.nvramURL) == "nvram-v2")
        #expect(env2.read(env2.bundle.stateURL) == "stale")
        #expect(env2.leftovers().isEmpty)
    }

    @Test func copyFallbackCreatesAndRestores() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let store = env.store(forceCopy: true)
        let snapshot = try await store.create(name: "copia", owner: .cli, session: nil)
        let dir = env.bundle.snapshotsURL.appendingPathComponent(snapshot.id.uuidString)
        #expect(env.read(dir.appendingPathComponent("disk.img")) == "disk-v1")
        #expect(try perms(dir.appendingPathComponent("disk.img")) == 0o600)
        try env.write("disk-v2", to: env.bundle.diskURL)
        try store.restore(snapshot.id, owner: .cli)
        #expect(env.read(env.bundle.diskURL) == "disk-v1")
        #expect(env.leftovers().isEmpty)
    }

    @Test @MainActor func liveSnapshotRefusesAnotherBundlesSession() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let other = try Env()
        defer { other.cleanup() }
        let lock = try BundleLock.acquire(env.bundle, owner: .app)
        defer { lock.release() }
        let session = FakeStateSession(bundle: other.bundle)
        await #expect(throws: NidoError.notRunning("vm")) {
            _ = try await env.store().create(name: "live", owner: .app, session: session)
        }
        #expect(session.calls.isEmpty)
    }

    @Test @MainActor func failedResumeKeepsTheSnapshot() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let lock = try BundleLock.acquire(env.bundle, owner: .app)
        defer { lock.release() }
        let session = FakeStateSession(bundle: env.bundle)
        session.resumeFails = true
        await #expect(throws: NidoError.snapshotResumeFailed(snapshot: "live", reason: NidoError.notRunning("vm").localizedDescription)) {
            _ = try await env.store().create(name: "live", owner: .app, session: session)
        }
        #expect(try env.store().list().map(\.name) == ["live"])
    }

    @Test func metaWithInvalidNameIsSkipped() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let snapshot = try await env.store().create(name: "prima", owner: .cli, session: nil)
        let meta = env.bundle.snapshotsURL.appendingPathComponent(snapshot.id.uuidString)
            .appendingPathComponent("meta.json")
        let text = try #require(env.read(meta)).replacingOccurrences(of: "\"prima\"", with: "\"\\u001b[2Jx\"")
        try env.write(text, to: meta)
        #expect(try env.store().list().isEmpty)
    }
}

final class SeenValues: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func set(_ key: String, _ value: String) { lock.withLock { values[key] = value } }
    func get(_ key: String) -> String? { lock.withLock { values[key] } }
}

final class SeenSteps: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SnapshotStep] = []
    func append(_ step: SnapshotStep) { lock.withLock { stored.append(step) } }
    var steps: [SnapshotStep] { lock.withLock { stored } }
}

@Suite struct EffectiveStateHashTests {
    @Test func hashReflectsAttachedDevices() throws {
        var config = VMConfig(
            id: UUID(), name: try VMName("vm"), guest: .linux, cpuCount: 2,
            memoryBytes: 1 << 30, diskBytes: 1 << 20, macAddress: "02:00:00:00:00:01")
        config.sharedFolders = [
            SharedFolder(name: "a", hostPath: "/Users/Shared/a"),
            SharedFolder(name: "b", hostPath: "/Users/Shared/b"),
        ]
        config.rosetta = true
        // Everything attached: the plain config hash.
        #expect(config.effectiveStateHash(attachedShareNames: ["b", "a"], rosettaAttached: true)
            == config.stateHash())
        // A folder missing on the Mac, or Rosetta left out: a different machine.
        var withoutB = config
        withoutB.sharedFolders.removeLast()
        #expect(config.effectiveStateHash(attachedShareNames: ["a"], rosettaAttached: true)
            == withoutB.stateHash())
        var withoutRosetta = config
        withoutRosetta.rosetta = false
        #expect(config.effectiveStateHash(attachedShareNames: ["a", "b"], rosettaAttached: false)
            == withoutRosetta.stateHash())
        #expect(config.effectiveStateHash(attachedShareNames: ["a"], rosettaAttached: true)
            != config.stateHash())
    }
}

/// R-M3A-21: a snapshot of a suspended VM keeps its saved state.
extension SnapshotStoreTests {
    /// The bundle as a suspend leaves it: `state.vzvmsave` (0600) and the hash it was saved with.
    func suspend(_ env: Env, hash: String) throws {
        try env.write("suspended-state", to: env.bundle.stateURL)
        var config = try env.bundle.readConfig()
        config.suspendedConfigHash = hash
        try env.bundle.writeConfig(config)
    }

    @Test func snapshotOfASuspendedVMIncludesTheSavedState() async throws {
        let env = try Env()
        defer { env.cleanup() }
        try suspend(env, hash: "suspended-hash")
        let snapshot = try await env.store().create(name: "sospesa", owner: .cli, session: nil)
        #expect(snapshot.hasSavedState)
        #expect(snapshot.configHash == "suspended-hash")
        let dir = env.bundle.snapshotsURL.appendingPathComponent(snapshot.id.uuidString)
        #expect(env.entries(dir) == ["disk.img", "meta.json", "nvram.efi", "state.vzvmsave"])
        #expect(env.read(dir.appendingPathComponent("state.vzvmsave")) == "suspended-state")
        #expect(try perms(dir.appendingPathComponent("state.vzvmsave")) == 0o600)
        // The VM itself stays suspended.
        #expect(env.bundle.hasSuspendedState(try env.bundle.readConfig()))
        #expect(env.read(env.bundle.stateURL) == "suspended-state")
    }

    /// Snapshot of the suspended VM, later restore: the next start resumes that state.
    @Test @MainActor func restoringASuspendedSnapshotResumesOnTheNextStart() async throws {
        let env = try Env()
        defer { env.cleanup() }
        try suspend(env, hash: "fake-hash")
        let snapshot = try await env.store().create(name: "sospesa", owner: .cli, session: nil)
        // The VM is started (cold, say) and its disk changes; then the snapshot is restored.
        try SuspendedState.discard(env.bundle)
        try env.write("disk-v2", to: env.bundle.diskURL)
        try env.store().restore(snapshot.id, owner: .cli)
        #expect(env.read(env.bundle.diskURL) == "disk-v1")
        #expect(env.read(env.bundle.stateURL) == "suspended-state")
        #expect(try env.bundle.readConfig().suspendedConfigHash == "fake-hash")
        let machine = FakeSuspendableMachine(bundle: env.bundle, hash: "fake-hash", state: .stopped)
        #expect(try await SuspendedState.boot(machine, bundle: env.bundle) == .resumed)
        #expect(machine.calls == ["restore", "resume"])
    }

    /// A state file without its hash (not a valid suspension) is not taken.
    @Test func snapshotOfAnInvalidSuspensionHasNoState() async throws {
        let env = try Env()
        defer { env.cleanup() }
        try env.write("stray", to: env.bundle.stateURL)
        let snapshot = try await env.store().create(name: "ferma", owner: .cli, session: nil)
        #expect(!snapshot.hasSavedState)
        let dir = env.bundle.snapshotsURL.appendingPathComponent(snapshot.id.uuidString)
        #expect(env.entries(dir) == ["disk.img", "meta.json", "nvram.efi"])
    }

    @Test func suspendedSnapshotCountsTheStateInTheSpaceCheck() async throws {
        let env = try Env()
        defer { env.cleanup() }
        try suspend(env, hash: "h")
        let needed = SnapshotStore.spaceMargin + (try MachineFileCopy.allocatedSize(env.bundle.diskURL))
            + (try MachineFileCopy.allocatedSize(env.bundle.nvramURL))
        // Enough for disk and NVRAM, not for the state as well (a volume that cannot clone).
        await #expect(throws: NidoError.self) {
            try await env.store(capacity: needed, cloning: false).create(name: "x", owner: .cli, session: nil)
        }
    }
}

extension SnapshotStoreTests {
    /// SWIFT m4: a failed live snapshot whose resume fails too says both.
    @Test @MainActor func liveFailureWithAFailedResumeSaysBoth() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let lock = try BundleLock.acquire(env.bundle, owner: .app)
        defer { lock.release() }
        let session = FakeStateSession(bundle: env.bundle)
        session.resumeFails = true
        let store = env.store(fault: { step in if step == .diskCloned { throw POSIXError(.ENOSPC) } })
        do {
            _ = try await store.create(name: "live", owner: .app, session: session)
            Issue.record("attesa un'eccezione")
        } catch NidoError.failedAndNotResumed(let reason, let resumeReason) {
            #expect(reason == POSIXError(.ENOSPC).localizedDescription)
            #expect(resumeReason == NidoError.notRunning("vm").localizedDescription)
        }
        #expect(env.entries(env.bundle.snapshotsURL).isEmpty)
    }

    /// SWIFT m6: the guest powering off while it is being paused aborts the live snapshot cleanly.
    @Test @MainActor func liveSnapshotAbortsWhenTheVMStopsDuringThePause() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let lock = try BundleLock.acquire(env.bundle, owner: .app)
        defer { lock.release() }
        let session = FakeStateSession(bundle: env.bundle)
        session.stopsWhilePausing = true
        await #expect(throws: NidoError.notRunning("vm")) {
            _ = try await env.store().create(name: "live", owner: .app, session: session)
        }
        #expect(session.calls == ["pause"])
        #expect(env.entries(env.bundle.snapshotsURL).isEmpty)
    }

    /// CORE m2: the removal of the commit marker is durable before the originals come back.
    @Test func rollbackSyncsTheMarkerRemovalBeforeUndoing() async throws {
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
                let markers = ((try? FileManager.default.contentsOfDirectory(atPath: bundle.url.path)) ?? [])
                    .filter { $0.hasSuffix(".commit") }
                log.append("sync \(disk) markers=\(markers.count)")
            }
            try SnapshotStore.syncDirectoryNow(url)
        })
        #expect(throws: Injected.self) { try failing.restore(snapshot.id, owner: .cli) }
        let afterFault = log.entries.drop { $0 != "fault" }.dropFirst()
        #expect(afterFault.first == "sync disk-v1 markers=0")
        #expect(env.read(env.bundle.diskURL) == "disk-v2")
    }
}

/// SWIFT m2: the app's restore and delete wait for the lock without blocking a thread.
extension SnapshotStoreTests {
    @Test func asyncRestoreAndDeleteBehaveLikeTheBlockingOnes() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let snapshot = try await env.store().create(name: "prima", owner: .app, session: nil)
        try env.write("disk-v2", to: env.bundle.diskURL)
        do {
            // Held by this process (a VM running in this app): refused, nothing touched.
            let lock = try BundleLock.acquire(env.bundle, owner: .app)
            defer { lock.release() }
            await #expect(throws: NidoError.vmMustBeStopped("vm")) {
                try await env.store().restoreAsync(snapshot.id, owner: .app)
            }
            await #expect(throws: NidoError.vmMustBeStopped("vm")) {
                try await env.store().deleteAsync(snapshot.id, owner: .app)
            }
        }
        #expect(env.read(env.bundle.diskURL) == "disk-v2")
        try await env.store().restoreAsync(snapshot.id, owner: .app)
        #expect(env.read(env.bundle.diskURL) == "disk-v1")
        try await env.store().deleteAsync(snapshot.id, owner: .app)
        #expect(try env.store().list().isEmpty)
        #expect(BundleLock.holder(env.bundle) == nil)
    }
}
