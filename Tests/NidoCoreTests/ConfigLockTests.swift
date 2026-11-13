// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import Synchronization
import Testing
@testable import NidoCore

/// Config writes are serialized per bundle (`VMBundle.updateConfig`, `<bundle>/.config.lock`).
@Suite struct ConfigLockTests {
    func makeBundle() throws -> (tmp: URL, bundle: VMBundle) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let paths = NidoPaths(root: tmp.appendingPathComponent("VMs"))
        let config = VMConfig(
            id: UUID(), name: try VMName("debian"), guest: .linux, cpuCount: 2,
            memoryBytes: 4 * 1024 * 1024 * 1024, diskBytes: 20 * 1024 * 1024 * 1024,
            macAddress: "02:00:00:00:00:01")
        return (tmp, try VMBundle.create(config: config, paths: paths))
    }

    /// Takes `<bundle>/.config.lock` on a descriptor of its own, like another process would.
    func holdLockElsewhere(_ bundle: VMBundle) throws -> Int32 {
        let fd = Darwin.open(
            bundle.url.appendingPathComponent(".config.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        try #require(fd >= 0)
        try #require(flock(fd, LOCK_EX) == 0)
        return fd
    }

    /// Runs `work` on a thread of its own; the semaphore is signalled when it returns.
    func runInBackground(_ work: @escaping @Sendable () -> Void) -> DispatchSemaphore {
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            work()
            done.signal()
        }
        return done
    }

    @Test func concurrentIncrementsAreNeverLost() throws {
        let (tmp, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let base = try bundle.readConfig().diskBytes
        let writers = 48
        let failures = Mutex(0)
        DispatchQueue.concurrentPerform(iterations: writers) { _ in
            do {
                try bundle.updateConfig { config in
                    let seen = config.diskBytes
                    usleep(500)  // widens the read-modify-write window
                    config.diskBytes = seen + 1
                }
            } catch {
                failures.withLock { $0 += 1 }
            }
        }
        #expect(failures.withLock { $0 } == 0)
        #expect(try bundle.readConfig().diskBytes == base + UInt64(writers))
    }

    @Test func concurrentEditsOfDifferentFieldsAllSurvive() throws {
        let (tmp, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let edits: [@Sendable (inout VMConfig) -> Void] = [
            { $0.guestToolsVersion = "1.2.1" },
            { $0.sshPublicKeyPath = "/Users/x/.ssh/id_ed25519.pub" },
            { $0.suspendedConfigHash = "abc" },
            { $0.clipboardSharing = true },
            { $0.rosetta = true },
            { $0.pendingProvisioning = nil; $0.cpuCount = 3 },
        ]
        DispatchQueue.concurrentPerform(iterations: edits.count) { index in
            _ = try? bundle.updateConfig { config in
                usleep(2000)
                edits[index](&config)
            }
        }
        let config = try bundle.readConfig()
        #expect(config.guestToolsVersion == "1.2.1")
        #expect(config.sshPublicKeyPath == "/Users/x/.ssh/id_ed25519.pub")
        #expect(config.suspendedConfigHash == "abc")
        #expect(config.clipboardSharing)
        #expect(config.rosetta)
        #expect(config.cpuCount == 3)
    }

    /// Another descriptor (another process) holding the lock makes `updateConfig` wait.
    @Test func updateWaitsForALockHeldOnAnotherDescriptor() throws {
        let (tmp, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fd = try holdLockElsewhere(bundle)
        let done = runInBackground { _ = try? bundle.updateConfig { $0.guestToolsVersion = "9.9.9" } }
        #expect(done.wait(timeout: .now() + 0.3) == .timedOut)
        #expect(try bundle.readConfig().guestToolsVersion == nil)
        _ = flock(fd, LOCK_UN)
        _ = Darwin.close(fd)
        #expect(done.wait(timeout: .now() + 10) == .success)
        #expect(try bundle.readConfig().guestToolsVersion == "9.9.9")
    }

    @Test func blindWriteWaitsForTheLockToo() throws {
        let (tmp, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: tmp) }
        var changed = try bundle.readConfig()
        changed.cpuCount = 4
        let fd = try holdLockElsewhere(bundle)
        let config = changed
        let done = runInBackground { try? bundle.writeConfig(config) }
        #expect(done.wait(timeout: .now() + 0.3) == .timedOut)
        #expect(try bundle.readConfig().cpuCount == 2)
        _ = Darwin.close(fd)
        #expect(done.wait(timeout: .now() + 10) == .success)
        #expect(try bundle.readConfig().cpuCount == 4)
    }

    /// `SuspendedState` clears the hash through the same lock.
    @Test func suspendedStateDiscardWaitsForTheLock() throws {
        let (tmp, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try bundle.updateConfig { $0.suspendedConfigHash = "abc" }
        let fd = try holdLockElsewhere(bundle)
        let done = runInBackground { try? SuspendedState.discard(bundle) }
        #expect(done.wait(timeout: .now() + 0.3) == .timedOut)
        #expect(try bundle.readConfig().suspendedConfigHash == "abc")
        _ = Darwin.close(fd)
        #expect(done.wait(timeout: .now() + 10) == .success)
        #expect(try bundle.readConfig().suspendedConfigHash == nil)
    }

    @Test func lockFileIsPrivate() throws {
        let (tmp, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try bundle.updateConfig { $0.cpuCount = 4 }
        let lock = bundle.url.appendingPathComponent(".config.lock")
        let attrs = try FileManager.default.attributesOfItem(atPath: lock.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((attrs[.type] as? FileAttributeType) == .typeRegular)
    }

    @Test func symlinkedLockFileIsRefused() throws {
        let (tmp, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let target = tmp.appendingPathComponent("elsewhere")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(
            at: bundle.url.appendingPathComponent(".config.lock"), withDestinationURL: target)
        #expect(throws: NidoError.self) { try bundle.updateConfig { $0.cpuCount = 4 } }
        #expect(try bundle.readConfig().cpuCount == 2)
    }
}
