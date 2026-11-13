// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCore

/// These tests run the real pinned `gvproxy` (`.build/gvproxy/gvproxy`, fetched by
/// `scripts/fetch-gvproxy.sh`), copied once into a temporary directory and signed ad hoc there with
/// `GvproxyBinary.signingIdentifier`. The original file is never changed.
@Suite(.italian) struct GvproxyProcessTests {
    /// The signed temporary copy, made once per test run.
    private static let signedBinary: Result<URL, GvproxyTestError> = {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/gvproxy/gvproxy")
        guard FileManager.default.fileExists(atPath: source.path) else {
            return .failure(GvproxyTestError("missing .build/gvproxy/gvproxy: run scripts/fetch-gvproxy.sh"))
        }
        // Signed once per pinned version and then reused as it is (`StableExecutables`): signing
        // and replacing it at every run crashed Gatekeeper.
        switch StableExecutables.signedCopy(of: source, identifier: GvproxyBinary.signingIdentifier) {
        case .success(let copy) where GvproxyBinary.hasValidSignature(copy):
            return .success(copy)
        case .success:
            return .failure(GvproxyTestError("firma ad hoc di gvproxy non valida"))
        case .failure(let error):
            return .failure(GvproxyTestError("copia firmata di gvproxy non riuscita: \(error)"))
        }
    }()

    /// A temporary NIDO root with one bundle and a short runtime root for the sockets.
    private struct Env {
        let tmp: URL
        let runtimeRoot: URL
        let bundle: VMBundle
        let config: VMConfig

        init(name: String = "debian", mac: String = "AA:2C:F8:A8:10:19", runtimeRoot: URL? = nil) throws {
            tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("gvt-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            // Kept short: the sockets live under it.
            self.runtimeRoot = runtimeRoot ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("gr-\(UUID().uuidString.prefix(8))", isDirectory: true)
            config = VMConfig(
                id: UUID(), name: try VMName(name), guest: .linux, cpuCount: 2,
                memoryBytes: 4 * 1024 * 1024 * 1024, diskBytes: 20 * 1024 * 1024 * 1024,
                macAddress: mac)
            bundle = try VMBundle.create(config: config, paths: NidoPaths(root: tmp.appendingPathComponent("VMs")))
        }

        func start(binary: URL? = nil, timeout: Duration = .seconds(10)) throws -> GvproxyProcess {
            try GvproxyProcess.start(
                vmID: config.id, bundle: bundle, binary: binary ?? GvproxyProcessTests.signedBinary.get(),
                runtimeRoot: runtimeRoot, timeout: timeout)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(at: runtimeRoot)
        }
    }

    private func perms(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as! NSNumber).intValue
    }

    private func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    /// True when 127.0.0.1:`port` accepts a TCP connection.
    private func acceptsTCP(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    /// True when some process has `argument` in its command line (`pgrep -f`).
    private func processRunning(withArgument argument: String) -> Bool {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", argument]
        pgrep.standardOutput = FileHandle.nullDevice
        pgrep.standardError = FileHandle.nullDevice
        guard (try? pgrep.run()) != nil else { return true }
        pgrep.waitUntilExit()
        return pgrep.terminationStatus == 0
    }

    /// Polls `condition` every 20 ms for at most `seconds`.
    private func eventually(_ seconds: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            usleep(20_000)
        }
        return condition()
    }

    private func forwardFile(_ bundle: VMBundle) throws -> [String: Any] {
        let data = try Data(contentsOf: bundle.sshForwardURL)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func startsAndWritesTheForwardFile() throws {
        let env = try Env()
        defer { env.cleanup() }
        let process = try env.start()
        defer { process.stop() }

        var info = stat()
        #expect(lstat(process.socketURL.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK)
        #expect(acceptsTCP(process.sshPort))
        #expect(isAlive(process.pid))
        let forward = try forwardFile(env.bundle)
        #expect((forward["port"] as? NSNumber)?.intValue == Int(process.sshPort))
        #expect((forward["pid"] as? NSNumber)?.intValue == Int(process.pid))
        #expect(try perms(env.bundle.sshForwardURL) == 0o600)
        #expect(try perms(process.socketURL.deletingLastPathComponent()) == 0o700)
        #expect(try perms(env.bundle.gvproxyLogURL) == 0o600)
        let pidFile = process.socketURL.deletingLastPathComponent().appendingPathComponent("gvproxy.pid")
        // The PID, then its start time (so a reused PID is never taken for this gvproxy).
        let pidLines = try String(contentsOf: pidFile, encoding: .utf8).split(separator: "\n")
        #expect(pidLines.first.map(String.init) == "\(process.pid)")
        #expect(pidLines.count == 2 && pidLines.last.map(String.init) == GvproxyProcess.startTime(process.pid))
    }

    @Test func startsWithTokenAndStaticLease() throws {
        let env = try Env(mac: "AA:2C:F8:A8:10:19")
        defer { env.cleanup() }
        let process = try env.start()
        defer { process.stop() }

        let directory = process.socketURL.deletingLastPathComponent()
        let config = try String(contentsOf: directory.appendingPathComponent("gvproxy.yaml"), encoding: .utf8)
        #expect(config.contains("192.168.127.2: \"aa:2c:f8:a8:10:19\""))
        #expect(config.contains("\"127.0.0.1:\(process.sshPort)\": \"192.168.127.2:22\""))
        #expect(try perms(directory.appendingPathComponent("gvproxy.yaml")) == 0o600)

        let token = directory.appendingPathComponent("token")
        #expect(try perms(token) == 0o600)
        let tokenText = try String(contentsOf: token, encoding: .utf8)
        #expect(!tokenText.isEmpty)
        #expect(tokenText.count == 64 && tokenText.allSatisfy(\.isHexDigit))

        // gvproxy read the token: its API needs it.
        let log = try String(contentsOf: env.bundle.gvproxyLogURL, encoding: .utf8)
        #expect(log.contains("API token loaded"))
    }

    @Test func stopRemovesEverything() throws {
        let env = try Env()
        defer { env.cleanup() }
        let process = try env.start()
        let pid = process.pid
        let directory = process.socketURL.deletingLastPathComponent()
        process.stop()

        #expect(kill(pid, 0) != 0)
        #expect(!exists(directory))
        #expect(!exists(env.bundle.sshForwardURL))
        process.stop()
        #expect(!exists(directory))
    }

    /// gvproxy lost while the VM runs: the forward record stays, with the dead PID, so `nido ssh`
    /// says the controlled network was interrupted (`staleForwardFileIsNotRunning`), not "not on
    /// the network yet"; the VM's stop removes it.
    @Test func lossKeepsTheForwardRecordUntilTheVMStops() throws {
        let env = try Env()
        defer { env.cleanup() }
        let process = try env.start()
        let pid = process.pid
        let directory = process.socketURL.deletingLastPathComponent()
        process.stop(keepingForwardRecord: true)

        #expect(kill(pid, 0) != 0)
        #expect(!exists(directory))
        #expect((try forwardFile(env.bundle)["pid"] as? NSNumber)?.int32Value == pid)
        process.stop()
        #expect(!exists(env.bundle.sshForwardURL))
    }

    /// The record carries gvproxy's start time, and a stop removes only its own record: the VM
    /// restarted quickly, the old run's late teardown must not delete the new run's forward.
    @Test func stopRemovesOnlyItsOwnForwardRecord() throws {
        let env = try Env()
        defer { env.cleanup() }
        let process = try env.start()
        let forward = try forwardFile(env.bundle)
        #expect(forward["start"] as? String == GvproxyProcess.startTime(process.pid))
        // A newer run wrote its own record meanwhile.
        try FileManager.default.removeItem(at: env.bundle.sshForwardURL)
        try PrivateFile.writeAtomically(Data("{\"pid\":\(getpid()),\"port\":1234}".utf8), to: env.bundle.sshForwardURL)
        process.stop()
        #expect((try forwardFile(env.bundle)["pid"] as? NSNumber)?.int32Value == getpid())
    }

    @Test func exitIsReported() throws {
        let env = try Env()
        defer { env.cleanup() }
        let process = try env.start()
        defer { process.stop() }
        let reported = DispatchSemaphore(value: 0)
        process.onExit { _ in reported.signal() }
        kill(process.pid, SIGKILL)
        #expect(reported.wait(timeout: .now() + 2) == .success)
        // Registered after the exit: still called, once.
        let late = DispatchSemaphore(value: 0)
        process.onExit { _ in late.signal() }
        #expect(late.wait(timeout: .now() + 2) == .success)
    }

    @Test func sweepsOrphansFromPreviousRuns() throws {
        let env = try Env()
        defer { env.cleanup() }
        let process = try env.start()
        let pid = process.pid
        let directory = process.socketURL.deletingLastPathComponent()
        let port = process.sshPort
        defer { process.stop() }

        // A live owner: nothing is touched.
        GvproxyProcess.sweepOrphans(runtimeRoot: env.runtimeRoot)
        #expect(isAlive(pid))
        #expect(exists(directory))

        // Nido dies without stop(): its ownership lock goes with it.
        process.abandonForTesting()
        // abandonForTesting() closes the lock in a process that lives on and, with the tests that run
        // in parallel, keeps spawning: a posix_spawn in flight at that moment holds a copy of the
        // descriptor, and so the lock, until its exec closes it (O_CLOEXEC only acts at exec). A
        // sweep that falls in that window rightly sees a live owner and skips. A Nido that really
        // died leaves no such copy. So the sweep is retried for a while: a lock held for good (one
        // inherited by gvproxy, say) still fails here.
        #expect(eventually(3) {
            GvproxyProcess.sweepOrphans(runtimeRoot: env.runtimeRoot)
            return !exists(directory)
        })
        #expect(eventually(3) { !isAlive(pid) })
        #expect(eventually(3) { !acceptsTCP(port) })

        // A PID in gvproxy.pid now used by another program is not touched; the folder still goes.
        // The record carries that process's real start time, so only the name check protects it.
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        defer { sleeper.terminate(); sleeper.waitUntilExit() }
        let sleeperStart = try #require(GvproxyProcess.startTime(sleeper.processIdentifier))
        let stale = env.runtimeRoot.appendingPathComponent("0123abcd", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("\(sleeper.processIdentifier)\n\(sleeperStart)\n".utf8)
            .write(to: stale.appendingPathComponent("gvproxy.pid"))
        GvproxyProcess.sweepOrphans(runtimeRoot: env.runtimeRoot)
        #expect(sleeper.isRunning)
        #expect(!exists(stale))
    }

    @Test func sweepSparesAGvproxyStartedAtAnotherTime() throws {
        let env = try Env()
        defer { env.cleanup() }
        // A process named gvproxy (a copy of /bin/sleep, made once: `StableExecutables`) whose
        // start time differs from the record: the PID was reused by another gvproxy, which is not
        // the one Nido started.
        let sleeper = Process()
        sleeper.executableURL = try StableExecutables.fakeGvproxy.get()
        sleeper.arguments = ["30"]
        try sleeper.run()
        defer { sleeper.terminate(); sleeper.waitUntilExit() }
        #expect(eventually(2) { GvproxyProcess.processName(sleeper.processIdentifier) == "gvproxy" })
        let realStart = try #require(GvproxyProcess.startTime(sleeper.processIdentifier))
        #expect(realStart != "1.0")

        try FileManager.default.createDirectory(at: env.runtimeRoot, withIntermediateDirectories: true)
        let stale = env.runtimeRoot.appendingPathComponent("4567cdef", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("\(sleeper.processIdentifier)\n1.0\n".utf8).write(to: stale.appendingPathComponent("gvproxy.pid"))
        GvproxyProcess.sweepOrphans(runtimeRoot: env.runtimeRoot)
        usleep(200_000)
        #expect(sleeper.isRunning)
        #expect(!exists(stale))
    }

    @Test func runsInAProcessGroupOfItsOwn() throws {
        let env = try Env()
        defer { env.cleanup() }
        let process = try env.start()
        defer { process.stop() }
        // Ctrl-C / Ctrl-Z on the terminal reach the foreground process group: never gvproxy.
        let group = getpgid(process.pid)
        #expect(group > 0)
        #expect(group != getpgrp())
        #expect(group == process.pid)
    }

    @Test func twoProcessesGetDistinctSocketsAndPorts() throws {
        let first = try Env(name: "uno")
        defer { first.cleanup() }
        let second = try Env(name: "due", mac: "AA:2C:F8:A8:10:20", runtimeRoot: first.runtimeRoot)
        defer { second.cleanup() }
        let a = try first.start()
        defer { a.stop() }
        let b = try second.start()
        defer { b.stop() }

        #expect(a.socketURL.deletingLastPathComponent() != b.socketURL.deletingLastPathComponent())
        #expect(a.clientSocketURL != b.clientSocketURL)
        #expect(a.sshPort != b.sshPort)
        #expect(a.pid != b.pid)
        #expect(acceptsTCP(a.sshPort) && acceptsTCP(b.sshPort))
        #expect(isAlive(a.pid) && isAlive(b.pid))
    }

    @Test func socketPathStaysShortForLongNames() throws {
        let base = FileManager.default.temporaryDirectory.path + "/gl-"
        let longRoot = URL(fileURLWithPath: base + String(repeating: "x", count: 70 - base.utf8.count), isDirectory: true)
        #expect(longRoot.path.utf8.count == 70)
        let env = try Env(name: String(repeating: "n", count: VMName.maxLength), runtimeRoot: longRoot)
        defer { env.cleanup() }
        let process = try env.start()
        defer { process.stop() }
        #expect(process.socketURL.path.utf8.count < 104)
        #expect(process.clientSocketURL.path.utf8.count < 104)

        let tooLong = URL(fileURLWithPath: base + String(repeating: "y", count: 110 - base.utf8.count), isDirectory: true)
        let other = try Env(name: "lungo", runtimeRoot: tooLong)
        defer { other.cleanup() }
        #expect(throws: NidoError.controlledNetworkUnavailable("percorso del socket di gvproxy troppo lungo")) {
            _ = try other.start()
        }
        #expect(!exists(other.bundle.sshForwardURL))
    }

    @Test func timeoutFailsClosed() throws {
        let env = try Env()
        defer { env.cleanup() }
        let fake = env.tmp.appendingPathComponent("gvproxy")
        // A unique sleep length marks the fake so it can be found by argument. Under parallel load
        // the script may be killed before it runs a single line, so a pid file it writes cannot be
        // relied on.
        let marker = "30.\(UInt32.random(in: 100_000...999_999))"
        try Data("#!/bin/sh\nexec /bin/sleep \(marker)\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let began = Date()
        #expect(throws: NidoError.controlledNetworkUnavailable("gvproxy non risponde")) {
            _ = try env.start(binary: fake, timeout: .seconds(1))
        }
        #expect(Date().timeIntervalSince(began) < 4)
        #expect(eventually(2) { !processRunning(withArgument: marker) })
        #expect(!exists(env.bundle.sshForwardURL))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: env.runtimeRoot.path)) ?? []).isEmpty)
    }

    @Test func retriesOnceWhenThePortIsTaken() throws {
        let env = try Env()
        defer { env.cleanup() }
        // The first port handed out is already taken by someone else.
        let blocker = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(blocker) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(blocker, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        listen(blocker, 1)
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(blocker, $0, &length) }
        }
        let taken = UInt16(bigEndian: bound.sin_port)

        let ports = PortSequence([taken])
        let process = try GvproxyProcess.start(
            vmID: env.config.id, bundle: env.bundle, binary: Self.signedBinary.get(),
            runtimeRoot: env.runtimeRoot, timeout: .seconds(10), pickPort: ports.next)
        defer { process.stop() }
        #expect(process.sshPort != taken)
        #expect(acceptsTCP(process.sshPort))
    }
}

/// Hands out the given ports first, then free ones.
private final class PortSequence: @unchecked Sendable {
    private var queued: [UInt16]
    private let lock = NSLock()
    init(_ ports: [UInt16]) { queued = ports }
    func next() throws -> UInt16 {
        lock.lock()
        defer { lock.unlock() }
        if !queued.isEmpty { return queued.removeFirst() }
        return try GvproxyProcess.freeLoopbackPort()
    }
}

struct GvproxyTestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
