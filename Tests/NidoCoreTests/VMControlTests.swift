// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCore

private let keyBody = "AAAAC3NzaC1lZDI1NTE5AAAAIOO97YvP4YWGQwUFq+UeOnyDKkD29RZ8VdmeuGgPzeS6"
private let validKey = "ssh-ed25519 \(keyBody)"

@Suite struct VMControlTests {
    private func makeTemp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeConfig(_ name: String, mac: String = "02:00:00:00:00:01") throws -> VMConfig {
        VMConfig(
            id: UUID(), name: try VMName(name), guest: .linux, cpuCount: 2,
            memoryBytes: 4 * 1024 * 1024 * 1024, diskBytes: 20 * 1024 * 1024 * 1024,
            macAddress: mac)
    }

    // MARK: - public key file

    @Test func readsAndValidatesPublicKey() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let url = tmp.appendingPathComponent("id_ed25519.pub")
        try Data("\(validKey) me@host\n".utf8).write(to: url)
        #expect(try VMControl.readPublicKey(at: url) == validKey)
    }

    @Test func rejectsPrivateKeyContentEvenInPubFile() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let url = tmp.appendingPathComponent("id_ed25519.pub")
        try Data("-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n".utf8).write(to: url)
        #expect(throws: NidoError.privateKeyRejected) { _ = try VMControl.readPublicKey(at: url) }
    }

    @Test func rejectsKeyPathWithoutPubSuffixBeforeOpening() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        // A private key: refused by name, its content is never read.
        let privateKey = tmp.appendingPathComponent("id_ed25519")
        try Data("-----BEGIN OPENSSH PRIVATE KEY-----\n".utf8).write(to: privateKey)
        #expect(throws: NidoError.keyPathNotPub(privateKey.path)) { _ = try VMControl.readPublicKey(at: privateKey) }
        // A missing file is refused by name too (an open would report it as unreadable).
        let missing = tmp.appendingPathComponent("missing.pub.bak")
        #expect(throws: NidoError.keyPathNotPub(missing.path)) { _ = try VMControl.readPublicKey(at: missing) }
        // A valid public key under a name without .pub is refused as well.
        let renamed = tmp.appendingPathComponent("id_ed25519.txt")
        try Data("\(validKey)\n".utf8).write(to: renamed)
        #expect(throws: NidoError.keyPathNotPub(renamed.path)) { _ = try VMControl.readPublicKey(at: renamed) }
    }

    /// `foo.pub -> id_ed25519`: a symlinked .pub is never followed (it could open a private key).
    @Test func rejectsSymlinkedPubFile() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let real = tmp.appendingPathComponent("real.pub")
        try Data("\(validKey)\n".utf8).write(to: real)
        let link = tmp.appendingPathComponent("link.pub")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(throws: NidoError.keyFileUnreadable(link.path)) { _ = try VMControl.readPublicKey(at: link) }
    }

    @Test func rejectsOversizedKeyFile() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let url = tmp.appendingPathComponent("big.pub")
        try Data(repeating: 0x41, count: 16 * 1024 + 1).write(to: url)
        #expect(throws: NidoError.keyFileTooLarge) { _ = try VMControl.readPublicKey(at: url) }
    }

    @Test func rejectsInvalidKeyContentAndDirectories() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let url = tmp.appendingPathComponent("junk.pub")
        try Data("not a key\n".utf8).write(to: url)
        #expect(throws: NidoError.invalidPublicKey) { _ = try VMControl.readPublicKey(at: url) }
        let directory = tmp.appendingPathComponent("dir.pub", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        #expect(throws: NidoError.keyFileUnreadable(directory.path)) { _ = try VMControl.readPublicKey(at: directory) }
    }

    // MARK: - delete / stop

    @Test func deleteWithLockHeldIsAlreadyRunning() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = NidoPaths(root: tmp)
        let bundle = try VMBundle.create(config: makeConfig("busy"), paths: paths)
        let lock = try BundleLock.acquire(bundle, owner: .cli)
        defer { lock.release() }
        #expect(throws: NidoError.alreadyRunning(pid: getpid())) {
            try VMControl.deleteVM(try VMName("busy"), paths: paths, owner: .cli)
        }
        #expect(FileManager.default.fileExists(atPath: bundle.configURL.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.path) == ["busy.nidovm"])
    }

    @Test func stopRefusesAppOwnedVM() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = NidoPaths(root: tmp)
        let bundle = try VMBundle.create(config: makeConfig("vm"), paths: paths)
        let lock = try BundleLock.acquire(bundle, owner: .app)
        defer { lock.release() }
        // Would signal this very process if the guard were missing: the test then dies visibly.
        #expect(throws: NidoError.ownedByApp("vm")) {
            try VMControl.requestStop(bundle: bundle, name: try VMName("vm"))
        }
    }

    @Test(arguments: [LockOwner.cli, .app])
    func deleteRecordsTheCallersOwnerInTheLock(_ owner: LockOwner) throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = NidoPaths(root: tmp)
        _ = try VMBundle.create(config: makeConfig("gone"), paths: paths)
        var seen: LockHolder?
        try VMControl.deleteVM(try VMName("gone"), paths: paths, owner: owner) { bundle in
            seen = BundleLock.holder(bundle)
        }
        #expect(seen == LockHolder(pid: getpid(), owner: owner))
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.path).isEmpty)
    }

    /// A lock line naming this very process (e.g. an app delete seen as "cli") is never signalled.
    @Test func stopNeverSignalsItsOwnProcess() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = NidoPaths(root: tmp)
        let bundle = try VMBundle.create(config: makeConfig("self"), paths: paths)
        let lock = try BundleLock.acquire(bundle, owner: .cli)
        defer { lock.release() }
        // Without the guard SIGTERM would reach this process: ignore it so the test fails visibly
        // instead of killing the runner.
        let previous = signal(SIGTERM, SIG_IGN)
        defer { signal(SIGTERM, previous) }
        #expect(throws: NidoError.ownedByApp("self")) {
            try VMControl.requestStop(bundle: bundle, name: try VMName("self"))
        }
    }

    @Test func deleteRemovesStoppedVM() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = NidoPaths(root: tmp)
        let bundle = try VMBundle.create(config: makeConfig("idle"), paths: paths)
        try VMControl.deleteVM(try VMName("IDLE"), paths: paths, owner: .cli)
        #expect(!FileManager.default.fileExists(atPath: bundle.url.path))
        // Neither the bundle nor its tombstone is left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.path).isEmpty)
        #expect(throws: NidoError.notFound("idle")) {
            try VMControl.deleteVM(try VMName("idle"), paths: paths, owner: .cli)
        }
    }

    @Test func stopOfStoppedVMIsNotRunning() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = NidoPaths(root: tmp)
        let bundle = try VMBundle.create(config: makeConfig("idle"), paths: paths)
        #expect(throws: NidoError.notRunning("idle")) {
            try VMControl.requestStop(bundle: bundle, name: try VMName("idle"))
        }
    }

    // MARK: - ip / known_hosts

    private func writeLeases(_ url: URL, ip: String = "192.168.64.7", hw: String = "2:0:0:0:0:1") throws {
        try Data("""
            {
            \tname=nido
            \tip_address=\(ip)
            \thw_address=1,\(hw)
            \tlease=0x6a000000
            }

            """.utf8).write(to: url)
    }

    /// Before the fixture lease (0x6a000000) expires.
    private let leaseClock = Date(timeIntervalSince1970: 0x69000000)

    @Test func resolveIPFromLeases() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = NidoPaths(root: tmp)
        let leases = tmp.appendingPathComponent("dhcpd_leases")
        try writeLeases(leases)
        let web = try VMBundle.create(config: makeConfig("web"), paths: paths)
        let webLock = try BundleLock.acquire(web, owner: .cli)
        defer { webLock.release() }
        #expect(try VMControl.resolveIP(bundle: web, leasesURL: leases, now: leaseClock) == "192.168.64.7")
        let db = try VMBundle.create(config: makeConfig("db", mac: "02:00:00:00:00:09"), paths: paths)
        let dbLock = try BundleLock.acquire(db, owner: .cli)
        defer { dbLock.release() }
        #expect(throws: NidoError.notOnNetwork("db")) {
            _ = try VMControl.resolveIP(bundle: db, leasesURL: leases, now: leaseClock)
        }
        let missing = tmp.appendingPathComponent("none")
        #expect(throws: NidoError.leasesUnreadable(missing.path)) {
            _ = try VMControl.resolveIP(bundle: web, leasesURL: missing, now: leaseClock)
        }
    }

    // MARK: - resolveSSH

    private func makeControlled(_ name: String, paths: NidoPaths, mac: String = "02:00:00:00:00:01") throws -> VMBundle {
        var config = try makeConfig(name, mac: mac)
        config.controlledNetwork = true
        return try VMBundle.create(config: config, paths: paths)
    }

    private func writeForward(_ bundle: VMBundle, port: UInt16, pid: Int32, start: String? = nil) throws {
        let startField = start.map { ",\"start\":\"\($0)\"" } ?? ""
        try? FileManager.default.removeItem(at: bundle.sshForwardURL)
        try Data("{\"pid\":\(pid),\"port\":\(port)\(startField)}".utf8).write(to: bundle.sshForwardURL)
        chmod(bundle.sshForwardURL.path, 0o600)
    }

    /// A running process whose name is `gvproxy`: a copy of `sleep` under that name, made once
    /// (`StableExecutables`; `dir` is no longer used).
    private func startFakeGvproxy(in dir: URL) throws -> Process {
        let process = Process()
        process.executableURL = try StableExecutables.fakeGvproxy.get()
        process.arguments = ["60"]
        try process.run()
        return process
    }

    @Test func natVMKeepsLeaseAddressAndPort22() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = NidoPaths(root: tmp)
        let leases = tmp.appendingPathComponent("dhcpd_leases")
        try writeLeases(leases)
        let web = try VMBundle.create(config: makeConfig("web"), paths: paths)
        let lock = try BundleLock.acquire(web, owner: .cli)
        defer { lock.release() }
        let endpoint = try VMControl.resolveSSH(bundle: web, leasesURL: leases, now: leaseClock)
        #expect(endpoint == SSHEndpoint(host: "192.168.64.7", port: 22))
        let args = try SSHArguments.make(endpoint: endpoint, vmID: UUID(), knownHosts: URL(fileURLWithPath: "/kh"), extra: [])
        #expect(!args.contains("-p"))
        #expect(args.contains("nido@192.168.64.7"))
    }

    @Test func controlledVMUsesTheForward() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = NidoPaths(root: tmp)
        let gv = try startFakeGvproxy(in: tmp); defer { gv.terminate(); gv.waitUntilExit() }
        let bundle = try makeControlled("c1", paths: paths)
        let lock = try BundleLock.acquire(bundle, owner: .cli)
        defer { lock.release() }
        try writeForward(bundle, port: 50123, pid: gv.processIdentifier)
        // The leases file does not exist: a controlled VM never reads it.
        let endpoint = try VMControl.resolveSSH(bundle: bundle, leasesURL: tmp.appendingPathComponent("none"))
        #expect(endpoint == SSHEndpoint(host: "127.0.0.1", port: 50123))
        // With the start time recorded: the same process passes; a gvproxy started at another time
        // (the dead one's PID reused by another VM's gvproxy) is not this VM's.
        let start = try #require(GvproxyProcess.startTime(gv.processIdentifier))
        try writeForward(bundle, port: 50123, pid: gv.processIdentifier, start: start)
        #expect(try VMControl.resolveSSH(bundle: bundle, leasesURL: tmp.appendingPathComponent("none")) == endpoint)
        #expect(!VMControl.isControlledNetworkInterrupted(bundle: bundle))
        try writeForward(bundle, port: 50123, pid: gv.processIdentifier, start: "1.2")
        #expect(throws: NidoError.controlledNetworkInterrupted) {
            _ = try VMControl.resolveSSH(bundle: bundle, leasesURL: tmp.appendingPathComponent("none"))
        }
        #expect(VMControl.isControlledNetworkInterrupted(bundle: bundle))
        try writeForward(bundle, port: 50123, pid: gv.processIdentifier)
        let config = try bundle.readConfig()
        let args = try SSHArguments.make(
            endpoint: endpoint, vmID: config.id, knownHosts: bundle.knownHostsURL, controlledNetwork: true, extra: [])
        let host = try #require(args.firstIndex(of: "nido@127.0.0.1"))
        #expect(Array(args[(host - 2)..<host]) == ["-p", "50123"])
        #expect(args.contains("ClearAllForwardings=yes"))
        #expect(args.contains("HostKeyAlias=nido-\(config.id.uuidString.lowercased())"))
    }

    @Test func staleForwardFileIsNotRunning() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = NidoPaths(root: tmp)
        let bundle = try makeControlled("c2", paths: paths)
        let lock = try BundleLock.acquire(bundle, owner: .cli)
        defer { lock.release() }
        let leases = tmp.appendingPathComponent("none")
        // No file at all.
        #expect(throws: NidoError.notOnNetwork("c2")) { _ = try VMControl.resolveSSH(bundle: bundle, leasesURL: leases) }
        // Not started yet is not interrupted (the Rete view stays green).
        #expect(!VMControl.isControlledNetworkInterrupted(bundle: bundle))
        // A dead PID: a child that has exited and been reaped. gvproxy is gone: the controlled
        // network was interrupted, the VM must be restarted.
        let dead = Process()
        dead.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try dead.run(); dead.waitUntilExit()
        try writeForward(bundle, port: 50124, pid: dead.processIdentifier)
        #expect(throws: NidoError.controlledNetworkInterrupted) {
            _ = try VMControl.resolveSSH(bundle: bundle, leasesURL: leases)
        }
        #expect(VMControl.isControlledNetworkInterrupted(bundle: bundle))
        // A live process that is not gvproxy (this one).
        try FileManager.default.removeItem(at: bundle.sshForwardURL)
        try writeForward(bundle, port: 50124, pid: getpid())
        #expect(throws: NidoError.controlledNetworkInterrupted) {
            _ = try VMControl.resolveSSH(bundle: bundle, leasesURL: leases)
        }
        // Garbage.
        try FileManager.default.removeItem(at: bundle.sshForwardURL)
        try Data("nope".utf8).write(to: bundle.sshForwardURL)
        chmod(bundle.sshForwardURL.path, 0o600)
        #expect(throws: NidoError.notOnNetwork("c2")) { _ = try VMControl.resolveSSH(bundle: bundle, leasesURL: leases) }
    }

    @Test func controlledVMNotRunningIsNotRunning() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let bundle = try makeControlled("c3", paths: NidoPaths(root: tmp))
        #expect(throws: NidoError.notRunning("c3")) {
            _ = try VMControl.resolveSSH(bundle: bundle, leasesURL: tmp.appendingPathComponent("none"))
        }
    }

    @Test func resolvesEachControlledVMToItsOwnPort() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = NidoPaths(root: tmp)
        let gvA = try startFakeGvproxy(in: tmp); defer { gvA.terminate(); gvA.waitUntilExit() }
        let other = tmp.appendingPathComponent("b"); try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let gvB = try startFakeGvproxy(in: other); defer { gvB.terminate(); gvB.waitUntilExit() }
        let a = try makeControlled("ca", paths: paths)
        let b = try makeControlled("cb", paths: paths, mac: "02:00:00:00:00:02")
        let lockA = try BundleLock.acquire(a, owner: .cli); defer { lockA.release() }
        let lockB = try BundleLock.acquire(b, owner: .cli); defer { lockB.release() }
        try writeForward(a, port: 50201, pid: gvA.processIdentifier)
        try writeForward(b, port: 50202, pid: gvB.processIdentifier)
        let none = tmp.appendingPathComponent("none")
        #expect(try VMControl.resolveSSH(bundle: a, leasesURL: none).port == 50201)
        #expect(try VMControl.resolveSSH(bundle: b, leasesURL: none).port == 50202)
    }

    @Test func resolveIPOfStoppedVMIsNotRunning() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let leases = tmp.appendingPathComponent("dhcpd_leases")
        try writeLeases(leases)
        let web = try VMBundle.create(config: makeConfig("web"), paths: NidoPaths(root: tmp))
        #expect(throws: NidoError.notRunning("web")) {
            _ = try VMControl.resolveIP(bundle: web, leasesURL: leases, now: leaseClock)
        }
    }

    @Test func resolveIPIgnoresNonIPv4Address() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let leases = tmp.appendingPathComponent("dhcpd_leases")
        try writeLeases(leases, ip: "-oProxyCommand=touch")
        let web = try VMBundle.create(config: makeConfig("web"), paths: NidoPaths(root: tmp))
        let lock = try BundleLock.acquire(web, owner: .cli)
        defer { lock.release() }
        #expect(throws: NidoError.notOnNetwork("web")) {
            _ = try VMControl.resolveIP(bundle: web, leasesURL: leases, now: leaseClock)
        }
    }

    @Test func resolveIPIgnoresExpiredLease() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let leases = tmp.appendingPathComponent("dhcpd_leases")
        try writeLeases(leases)
        let web = try VMBundle.create(config: makeConfig("web"), paths: NidoPaths(root: tmp))
        let lock = try BundleLock.acquire(web, owner: .cli)
        defer { lock.release() }
        #expect(throws: NidoError.notOnNetwork("web")) {
            _ = try VMControl.resolveIP(bundle: web, leasesURL: leases, now: Date(timeIntervalSince1970: 0x6a000001))
        }
    }

    @Test func knownHostsIsPreparedPrivately() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let bundle = try VMBundle.create(config: makeConfig("web"), paths: NidoPaths(root: tmp))
        try VMControl.prepareKnownHosts(bundle: bundle)
        let attrs = try FileManager.default.attributesOfItem(atPath: bundle.knownHostsURL.path)
        #expect((attrs[.posixPermissions] as! NSNumber).intValue == 0o600)
        try Data("host-key\n".utf8).write(to: bundle.knownHostsURL)
        try VMControl.prepareKnownHosts(bundle: bundle)  // existing file is kept
        #expect(try String(contentsOf: bundle.knownHostsURL, encoding: .utf8) == "host-key\n")
        try FileManager.default.removeItem(at: bundle.knownHostsURL)
        try FileManager.default.createSymbolicLink(at: bundle.knownHostsURL, withDestinationURL: tmp)
        #expect(throws: NidoError.unsafePath("known_hosts")) { try VMControl.prepareKnownHosts(bundle: bundle) }
    }

    @Test func hardLinkedKnownHostsIsRefused() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let bundle = try VMBundle.create(config: makeConfig("web"), paths: NidoPaths(root: tmp))
        let victim = tmp.appendingPathComponent("authorized_keys")
        try Data("key\n".utf8).write(to: victim)
        try FileManager.default.linkItem(at: victim, to: bundle.knownHostsURL)
        #expect(throws: NidoError.unsafePath("known_hosts")) { try VMControl.prepareKnownHosts(bundle: bundle) }
    }
}

/// R-M3A-24: `nido stop` / `--suspend` signal only a `nido start`; a maintenance command holding
/// the lock (snapshot, clone, share, rosetta, delete) is refused at once, never signalled.
@Suite(.italian) struct MaintenanceLockTests {
    private func bundle() throws -> (URL, VMBundle) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-test-maint-\(UUID().uuidString)", isDirectory: true)
        let config = VMConfig(
            id: UUID(), name: try VMName("vm"), guest: .linux, cpuCount: 2,
            memoryBytes: 1 << 30, diskBytes: 1 << 20, macAddress: "02:00:00:00:00:01")
        return (tmp, try VMBundle.create(config: config, paths: NidoPaths(root: tmp)))
    }

    /// Holds the lock with `line` (another process's description: pid 1 is never ours).
    private func hold(_ bundle: VMBundle, line: String) throws -> Int32 {
        let fd = open(bundle.lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        try #require(fd >= 0)
        _ = Array(line.utf8).withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
        try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)
        return fd
    }

    @Test func maintenanceOwnerIsRecordedAndRead() throws {
        let (tmp, bundle) = try bundle()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let lock = try BundleLock.acquire(bundle, owner: .cliOperation)
        defer { lock.release() }
        #expect(try String(contentsOf: bundle.lockURL, encoding: .utf8) == "\(getpid()) cli-op\n")
        #expect(BundleLock.holder(bundle) == LockHolder(pid: getpid(), owner: .cliOperation))
    }

    @Test func stopAndSuspendRefuseAMaintenanceHolder() throws {
        let (tmp, bundle) = try bundle()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fd = try hold(bundle, line: "1 cli-op\n")
        defer { close(fd) }
        let expected = NidoError.operationInProgress("vm", pid: 1)
        #expect(throws: expected) { try VMControl.requestStop(bundle: bundle, name: try VMName("vm")) }
        #expect(throws: expected) { try VMControl.requestSuspend(bundle: bundle, name: try VMName("vm")) }
        #expect(expected.localizedDescription == "è in corso un'operazione su vm (pid 1): riprova al termine")
    }

    /// Lock files of older versions: "cli" (and a bare pid) is a `nido start`.
    // Signals pid 1 and relies on EPERM: never run it as root.
    @Test(.enabled(if: getuid() != 0)) func oldCLILinesStillMeanStart() throws {
        let (tmp, bundle) = try bundle()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fd = try hold(bundle, line: "1 cli\n")
        defer { close(fd) }
        #expect(BundleLock.holder(bundle) == LockHolder(pid: 1, owner: .cli))
        // Signalled (pid 1 refuses it: EPERM), not refused as an operation.
        #expect(throws: POSIXError.self) { try VMControl.requestStop(bundle: bundle, name: try VMName("vm")) }
    }
}
