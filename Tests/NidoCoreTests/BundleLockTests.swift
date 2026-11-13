// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
@testable import NidoCore

@Suite struct BundleLockTests {
    private func makeBundle() throws -> VMBundle {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-lock-\(UUID().uuidString).nidovm", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return VMBundle(url: dir)
    }

    @Test func secondAcquireReportsHolderPID() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let lock = try BundleLock.acquire(bundle, owner: .cli)
        defer { lock.release() }
        #expect(throws: NidoError.alreadyRunning(pid: getpid())) {
            _ = try BundleLock.acquire(bundle, owner: .cli)
        }
        #expect(BundleLock.holder(bundle) == LockHolder(pid: getpid(), owner: .cli))
        let mode = (try FileManager.default.attributesOfItem(atPath: bundle.lockURL.path)[.posixPermissions]
            as! NSNumber).intValue
        #expect(mode == 0o600)
    }

    @Test func releaseFreesTheBundle() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let lock = try BundleLock.acquire(bundle, owner: .cli)
        lock.release()
        lock.release()  // idempotent
        #expect(BundleLock.holder(bundle) == nil)
        let again = try BundleLock.acquire(bundle, owner: .cli)
        again.release()
    }

    @Test func staleLockFileIsIgnored() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        try Data("99999\n".utf8).write(to: bundle.lockURL)
        #expect(BundleLock.holder(bundle) == nil)
        let lock = try BundleLock.acquire(bundle, owner: .cli)
        defer { lock.release() }
        let contents = try String(contentsOf: bundle.lockURL, encoding: .utf8)
        #expect(contents == "\(getpid()) cli\n")
    }

    @Test func missingLockFileMeansNotRunning() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        #expect(BundleLock.holder(bundle) == nil)
    }

    /// Holds the bundle lock through a separate open file description with arbitrary content.
    private func holdLock(_ bundle: VMBundle, content: String) throws -> Int32 {
        let fd = open(bundle.lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        try #require(fd >= 0)
        let bytes = Array(content.utf8)
        _ = bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
        try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)
        return fd
    }

    @Test func heldLockWithGarbageReportsUnknownPID() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let fd = try holdLock(bundle, content: "garbage")
        defer { close(fd) }
        #expect(BundleLock.holder(bundle) == LockHolder(pid: -1, owner: .cli))
    }

    @Test func heldLockWithEmptyFileReportsUnknownPID() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let fd = try holdLock(bundle, content: "")
        defer { close(fd) }
        #expect(BundleLock.holder(bundle) == LockHolder(pid: -1, owner: .cli))
        #expect(throws: NidoError.alreadyRunning(pid: -1)) {
            _ = try BundleLock.acquire(bundle, owner: .cli)
        }
    }

    @Test func acquireReplacesLongerStalePID() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let fd = open(bundle.lockURL.path, O_WRONLY | O_CREAT, 0o644)
        try #require(fd >= 0)
        _ = Array("99999999999\n".utf8).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
        let lock = try BundleLock.acquire(bundle, owner: .cli)
        defer { lock.release() }
        #expect(try String(contentsOf: bundle.lockURL, encoding: .utf8) == "\(getpid()) cli\n")
        let mode = (try FileManager.default.attributesOfItem(atPath: bundle.lockURL.path)[.posixPermissions]
            as! NSNumber).intValue
        #expect(mode == 0o600)
    }

    @Test func lockRecordsOwner() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let lock = try BundleLock.acquire(bundle, owner: .app)
        defer { lock.release() }
        #expect(BundleLock.holder(bundle) == LockHolder(pid: getpid(), owner: .app))
        #expect(try String(contentsOf: bundle.lockURL, encoding: .utf8) == "\(getpid()) app\n")
    }

    @Test func legacyPIDOnlyLineIsCLI() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let fd = try holdLock(bundle, content: "123\n")
        defer { close(fd) }
        #expect(BundleLock.holder(bundle) == LockHolder(pid: 123, owner: .cli))
    }

    /// A concurrent `holder` probe (LOCK_SH) must never make `acquire` fail with `.alreadyRunning`.
    @Test func concurrentProbeDoesNotFailAcquire() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let stop = Mutex<Bool>(false)
        let probes = Mutex(0)
        let finished = DispatchSemaphore(value: 0)
        let prober = Thread {
            while !stop.withLock({ $0 }) {
                _ = BundleLock.holder(bundle)
                probes.withLock { $0 += 1 }
            }
            finished.signal()
        }
        prober.start()
        // Make sure the prober is actually running before the acquires start.
        while probes.withLock({ $0 }) == 0 { usleep(100) }
        var failure: (any Error)?
        for _ in 0..<100 {
            do {
                let lock = try BundleLock.acquire(bundle, owner: .cli)
                lock.release()
            } catch {
                failure = error
                break
            }
        }
        stop.withLock { $0 = true }
        // Joined: the prober never outlives the bundle directory.
        #expect(finished.wait(timeout: .now() + 5) == .success)
        #expect(probes.withLock { $0 } > 0)
        #expect(failure == nil)
    }

    /// A released lock leaves no PID behind: the file is emptied before the unlock.
    @Test func releaseEmptiesTheLockFile() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let lock = try BundleLock.acquire(bundle, owner: .app)
        #expect(try String(contentsOf: bundle.lockURL, encoding: .utf8) == "\(getpid()) app\n")
        lock.release()
        #expect(try Data(contentsOf: bundle.lockURL).isEmpty)
        #expect(BundleLock.holder(bundle) == nil)
    }

    /// A `.lock` hard-linked to another file (e.g. a shell rc) is never written to.
    @Test func hardLinkedLockIsRefused() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let victim = bundle.url.appendingPathComponent("victim")
        try Data("export A=1\n".utf8).write(to: victim)
        try FileManager.default.linkItem(at: victim, to: bundle.lockURL)
        #expect(throws: NidoError.unsafePath(".lock")) { _ = try BundleLock.acquire(bundle, owner: .cli) }
        #expect(try String(contentsOf: victim, encoding: .utf8) == "export A=1\n")
    }

    /// A FIFO at `.lock` is refused at once by `acquire`, and `holder` does not hang on it.
    @Test func fifoLockIsRefusedWithoutHanging() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        try makeFIFO(bundle.lockURL)
        let acquired = withinTimeout { thrownError { _ = try BundleLock.acquire(bundle, owner: .cli) } }
        #expect(acquired == NidoErrorBox(NidoError.unsafePath(".lock")))
        let holder = withinTimeout { BundleLock.holder(bundle).map { "\($0)" } ?? "nil" }
        #expect(holder == "nil")
    }

    /// The app's lock: retries a brief contention (a `holder` probe) with `Task.sleep`, never
    /// blocking its thread, and still reports a real holder.
    @Test func acquireAsyncRetries() async throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        // A shared lock like a `holder` probe, released after 30 ms: the first attempt fails.
        let fd = open(bundle.lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        try #require(fd >= 0)
        try #require(flock(fd, LOCK_SH | LOCK_NB) == 0)
        let releaser = Task.detached {
            try await Task.sleep(for: .milliseconds(30))
            _ = flock(fd, LOCK_UN)
            close(fd)
        }
        let lock = try await BundleLock.acquireAsync(bundle, owner: .app)
        try await releaser.value
        #expect(BundleLock.holder(bundle) == LockHolder(pid: getpid(), owner: .app))

        // A real holder is still reported, after the retries.
        await #expect(throws: NidoError.alreadyRunning(pid: getpid())) {
            _ = try await BundleLock.acquireAsync(bundle, owner: .app)
        }
        lock.release()
        let again = try await BundleLock.acquireAsync(bundle, owner: .app)
        again.release()
    }

    @Test func runStateEquality() {
        #expect(VMRunState.error("x") == .error("x"))
        #expect(VMRunState.error("x") != .error("y"))
        #expect(VMRunState.running != .stopped)
    }
}
