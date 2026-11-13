// SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Foundation
import Testing
import Virtualization
@testable import NidoCore

private let validKey =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOO97YvP4YWGQwUFq+UeOnyDKkD29RZ8VdmeuGgPzeS6"
private let mib: UInt64 = 1024 * 1024
private let hasHdiutil = FileManager.default.isExecutableFile(atPath: "/usr/bin/hdiutil")

/// A VM root with one VM (`source`) made by `VMFactory` with the real `hdiutil`.
private struct CloneEnv {
    let tmp: URL
    let paths: NidoPaths
    let source: VMBundle

    init(name: String = "sorgente", profile: ProvisioningProfile = .empty) throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("nido-clone-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        paths = NidoPaths(root: tmp.appendingPathComponent("VMs"))
        let image = tmp.appendingPathComponent("base.img")
        try Data(repeating: 0xAB, count: Int(mib)).write(to: image)
        source = try VMFactory(paths: paths, runner: SystemProcessRunner()).createLinux(
            LinuxVMRequest(
                name: try VMName(name), baseImage: image, cpuCount: 2, memoryBytes: 2048 * mib,
                diskBytes: 4 * mib, publicKey: validKey, profile: profile))
    }

    func cloner(_ environment: VMCloner.Environment = .init()) -> VMCloner {
        VMCloner(paths: paths, runner: SystemProcessRunner(), environment: environment)
    }

    /// Entries of the VM root (hidden ones too), sorted.
    func rootEntries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: paths.root.path).sorted()
    }

    /// SHA-256 of every file of the source bundle except `.lock`, by name: the source untouched.
    func sourceDigest() throws -> [String: String] {
        var result: [String: String] = [:]
        let fm = FileManager.default
        let names = try fm.subpathsOfDirectory(atPath: source.url.path).filter { $0 != ".lock" }
        for name in names {
            let url = source.url.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
                result[name] = "dir"
                continue
            }
            result[name] = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        }
        return result
    }

    func cleanup() { try? FileManager.default.removeItem(at: tmp) }
}

private func mode(_ url: URL) throws -> Int {
    (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
}

private struct InjectedFailure: Error {}

@Suite(.enabled(if: hasHdiutil)) struct VMClonerTests {
    @Test func cloneDropsSharedFolders() async throws {
        let env = try CloneEnv()
        defer { env.cleanup() }
        var sourceConfig = try env.source.readConfig()
        sourceConfig.sharedFolders = [
            SharedFolder(name: "progetti", hostPath: "/Users/Shared/progetti", readOnly: false),
            SharedFolder(name: "docs", hostPath: "/Users/Shared/docs"),
        ]
        try env.source.writeConfig(sourceConfig)

        let clone = try await env.cloner().clone(try VMName("sorgente"), as: try VMName("copia"), owner: .cli)

        #expect(try clone.readConfig().sharedFolders.isEmpty)
        // The source keeps its own.
        #expect(try env.source.readConfig().sharedFolders.count == 2)
    }

    @Test func cloneDropsBridgePolicy() async throws {
        let env = try CloneEnv()
        defer { env.cleanup() }
        let policy = AIBridgePolicy(enabled: true, allowedModels: ["org/m"], privacyAcknowledged: true)
        _ = try env.source.updateConfig { $0.aiBridge = policy }

        let clone = try await env.cloner().clone(try VMName("sorgente"), as: try VMName("copia"), owner: .cli)

        // The clone starts with the bridge off; the source keeps its policy.
        #expect(try clone.readConfig().aiBridge == nil)
        #expect(try env.source.readConfig().aiBridge == policy)
    }

    @Test func cloneGetsNewIdentity() async throws {
        let env = try CloneEnv()
        defer { env.cleanup() }
        var sourceConfig = try env.source.readConfig()
        sourceConfig.sharedFolders = [SharedFolder(name: "progetti", hostPath: "/Users/Shared/progetti")]
        sourceConfig.rosetta = true
        try env.source.writeConfig(sourceConfig)

        let clone = try await env.cloner().clone(try VMName("sorgente"), as: try VMName("copia"), owner: .cli)

        #expect(clone.url.lastPathComponent == "copia.nidovm")
        let config = try clone.readConfig()
        #expect(config.name.rawValue == "copia")
        #expect(config.id != sourceConfig.id)
        #expect(config.macAddress != sourceConfig.macAddress)
        #expect(config.macAddress.range(of: #"^[0-9a-f]{2}(:[0-9a-f]{2}){5}$"#, options: .regularExpression) != nil)
        // Same machine shape, Rosetta and guest flags; shared folders are not inherited.
        #expect(config.cpuCount == sourceConfig.cpuCount)
        #expect(config.memoryBytes == sourceConfig.memoryBytes)
        #expect(config.diskBytes == sourceConfig.diskBytes)
        #expect(config.sharedFolders.isEmpty)
        #expect(config.rosetta == sourceConfig.rosetta)
        #expect(config.guestMountsSharedFolders == sourceConfig.guestMountsSharedFolders)
        #expect(config.guestRegistersRosetta == sourceConfig.guestRegistersRosetta)
        #expect(config.suspendedConfigHash == nil)

        // New machine identifier, same disk and NVRAM content.
        #expect(try Data(contentsOf: clone.machineIdentifierURL) != (try Data(contentsOf: env.source.machineIdentifierURL)))
        #expect(try Data(contentsOf: clone.diskURL) == (try Data(contentsOf: env.source.diskURL)))
        #expect(try Data(contentsOf: clone.nvramURL) == (try Data(contentsOf: env.source.nvramURL)))

        // New seed: new instance-id and hostname, DHCP on the new MAC, same user-data.
        let meta = try CloudInitSeed.readFile("meta-data", fromISO: clone.seedURL)
        let sourceMeta = try CloudInitSeed.readFile("meta-data", fromISO: env.source.seedURL)
        #expect(meta == CloudInitSeed.metaData(instanceID: config.id, hostname: config.name))
        #expect(meta != sourceMeta)
        #expect(meta.contains("local-hostname: copia\n"))
        #expect(try CloudInitSeed.readFile("network-config", fromISO: clone.seedURL)
            == (try CloudInitSeed.networkConfig(macAddress: config.macAddress)))
        let sourceUserData = try CloudInitSeed.readFile("user-data", fromISO: env.source.seedURL)
        let userData = try CloudInitSeed.readFile("user-data", fromISO: clone.seedURL)
        #expect(userData == CloudInitSeed.userDataForClone(sourceUserData))
        // The source's whole user-data: only the machine-id `bootcmd` item is put in its list.
        let machineID = "  - " + CloudInitSeed.newMachineIDBootCommand + "\n"
        #expect(userData.replacingOccurrences(of: machineID, with: "").hasPrefix(sourceUserData))
        #expect(userData.contains(CloudInitSeed.newMachineIDBootCommand))

        // Private files, nothing of the source's history.
        #expect(try mode(clone.url) == 0o700)
        for url in [clone.configURL, clone.diskURL, clone.nvramURL, clone.machineIdentifierURL, clone.seedURL] {
            #expect(try mode(url) == 0o600, "\(url.lastPathComponent)")
        }
        try clone.verifyInnerFiles(for: .linux)
        for url in [clone.knownHostsURL, clone.consoleLogURL, clone.stateURL, clone.snapshotsURL] {
            #expect(!FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent)")
        }
        #expect(try env.rootEntries() == ["copia.nidovm", "sorgente.nidovm"])
    }

    @Test func suspendedStateAndSnapshotsAreNotCopied() async throws {
        let env = try CloneEnv()
        defer { env.cleanup() }
        try "known".write(to: env.source.knownHostsURL, atomically: false, encoding: .utf8)
        try "console".write(to: env.source.consoleLogURL, atomically: false, encoding: .utf8)
        try Data("saved-state".utf8).write(to: env.source.stateURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: env.source.stateURL.path)
        var config = try env.source.readConfig()
        config.suspendedConfigHash = config.stateHash()
        try env.source.writeConfig(config)
        try await SnapshotStore(bundle: env.source).create(name: "prima", owner: .cli, session: nil)
        let before = try env.sourceDigest()

        let clone = try await env.cloner().clone(try VMName("sorgente"), as: try VMName("copia"), owner: .cli)

        #expect(try clone.readConfig().suspendedConfigHash == nil)
        #expect(!clone.hasSuspendedState(try clone.readConfig()))
        for url in [clone.knownHostsURL, clone.consoleLogURL, clone.stateURL, clone.snapshotsURL] {
            #expect(!FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent)")
        }
        // The source keeps its suspended state and its snapshot.
        #expect(try env.sourceDigest() == before)
        #expect(env.source.hasSuspendedState(try env.source.readConfig()))
    }

    /// The controlled network's temporary and lock files stay with their bundle: neither a clone,
    /// a VM made from a template, nor a snapshot carries them.
    @Test func egressTemporaryAndLockFilesAreNeverCopied() async throws {
        let env = try CloneEnv()
        defer { env.cleanup() }
        let leftovers = [".egress.json.\(UUID().uuidString).tmp", ".egress.lock"]
        for name in leftovers {
            try Data("x".utf8).write(to: env.source.url.appendingPathComponent(name))
        }
        try await SnapshotStore(bundle: env.source).create(name: "prima", owner: .cli, session: nil)
        let clone = try await env.cloner().clone(try VMName("sorgente"), as: try VMName("copia"), owner: .cli)
        try VMTemplates.save(env.source, owner: .cli)
        let key = env.tmp.appendingPathComponent("id_test.pub")
        try (validKey + "\n").write(to: key, atomically: true, encoding: .utf8)
        let fromTemplate = try await env.cloner().createFromTemplate(
            try VMName("sorgente"), as: try VMName("nuova"), sshKeyPath: key, owner: .cli)
        let fm = FileManager.default
        for url in [clone.url, fromTemplate.url, env.source.snapshotsURL] {
            let names = try fm.subpathsOfDirectory(atPath: url.path).map { ($0 as NSString).lastPathComponent }
            #expect(!names.contains { $0.hasPrefix(".egress") }, "\(url.lastPathComponent): \(names)")
        }
    }

    /// The controlled network follows a clone and a VM made from a template: the flag and the
    /// policy as the source has it now. The logs stay with the source (a clone starts with a
    /// clean log), and a snapshot holds no policy: restoring one never brings back an old list.
    @Test func clonesCopyTheEgressPolicyButNotTheLogs() async throws {
        let env = try CloneEnv()
        defer { env.cleanup() }
        #expect(try env.source.readConfig().controlledNetwork == true)
        let policy = try EgressPolicyStore.update(bundle: env.source) {
            $0.allow.append(try DomainPattern("example.com"))
        }
        #expect(policy != EgressPolicy.base)
        let logs = ["egress.log", "egress.log.1", "egress-flows.log", "egress-flows.log.1"]
        for name in logs {
            try Data("{}\n".utf8).write(to: env.source.url.appendingPathComponent(name))
        }
        try await SnapshotStore(bundle: env.source).create(name: "prima", owner: .cli, session: nil)
        let clone = try await env.cloner().clone(try VMName("sorgente"), as: try VMName("copia"), owner: .cli)
        try VMTemplates.save(env.source, owner: .cli)
        let key = env.tmp.appendingPathComponent("id_test.pub")
        try (validKey + "\n").write(to: key, atomically: true, encoding: .utf8)
        let fromTemplate = try await env.cloner().createFromTemplate(
            try VMName("sorgente"), as: try VMName("nuova"), sshKeyPath: key, owner: .cli)

        let fm = FileManager.default
        for vm in [clone, fromTemplate] {
            #expect(try vm.readConfig().controlledNetwork == true)
            #expect(EgressPolicyStore.load(bundle: vm) == policy)
            #expect(try mode(vm.egressPolicyURL) == 0o600)
            for name in logs {
                #expect(!fm.fileExists(atPath: vm.url.appendingPathComponent(name).path), "\(name)")
            }
        }
        let snapshotFiles = try fm.subpathsOfDirectory(atPath: env.source.snapshotsURL.path)
            .map { ($0 as NSString).lastPathComponent }
        #expect(!snapshotFiles.contains { $0.hasPrefix("egress") }, "\(snapshotFiles)")
        // The source keeps its own.
        #expect(EgressPolicyStore.load(bundle: env.source) == policy)
    }

    /// A source without `egress.json` (a VM from before the controlled network) gives a clone
    /// without one, still on NAT; a damaged one gives the empty list, never a wider one.
    @Test func cloneOfAnUncontrolledOrDamagedPolicy() async throws {
        let env = try CloneEnv()
        defer { env.cleanup() }
        try env.source.updateConfig { $0.controlledNetwork = false }
        try FileManager.default.removeItem(at: env.source.egressPolicyURL)
        let plain = try await env.cloner().clone(try VMName("sorgente"), as: try VMName("copia"), owner: .cli)
        #expect(try plain.readConfig().controlledNetwork == false)
        #expect(!FileManager.default.fileExists(atPath: plain.egressPolicyURL.path))

        try env.source.updateConfig { $0.controlledNetwork = true }
        try Data("{\"v\":1,\"allow\":[\"*.com\"]}".utf8).write(to: env.source.egressPolicyURL)
        let damaged = try await env.cloner().clone(try VMName("sorgente"), as: try VMName("copia2"), owner: .cli)
        #expect(try damaged.readConfig().controlledNetwork == true)
        #expect(EgressPolicyStore.load(bundle: damaged) == EgressPolicy.empty)
        #expect(FileManager.default.fileExists(atPath: damaged.egressPolicyURL.path))
    }

    @Test func cloneRefusedWhileRunning() async throws {
        let env = try CloneEnv()
        defer { env.cleanup() }
        let before = try env.sourceDigest()
        let lock = try BundleLock.acquire(env.source, owner: .app)
        defer { lock.release() }

        await #expect(throws: NidoError.cloneNeedsStoppedVM("sorgente")) {
            try await env.cloner().clone(try VMName("sorgente"), as: try VMName("copia"), owner: .cli)
        }
        #expect(try env.rootEntries() == ["sorgente.nidovm"])
        #expect(try env.sourceDigest() == before)
    }

    @Test(arguments: [CloneStep.locked, .diskCloned, .nvramCloned, .identityWritten, .seedBuilt, .readyToRename])
    func cloneFailureLeavesNoBundle(step: CloneStep) async throws {
        let env = try CloneEnv()
        defer { env.cleanup() }
        let before = try env.sourceDigest()
        var environment = VMCloner.Environment()
        environment.faultInjection = { current in
            if current == step { throw POSIXError(.ENOSPC) }
        }

        await #expect(throws: POSIXError(.ENOSPC)) {
            try await env.cloner(environment).clone(try VMName("sorgente"), as: try VMName("copia"), owner: .cli)
        }
        #expect(try env.rootEntries() == ["sorgente.nidovm"])
        #expect(try env.sourceDigest() == before)
        // The lock is released: the source can be used again.
        let lock = try BundleLock.acquire(env.source, owner: .cli)
        lock.release()
    }

    /// Quitting the app with "Annulla ed esci" cancels the clone's task: the copy stops at its
    /// next step and its `.cloning-*` folder is removed; the source is untouched and unlocked.
    @Test(arguments: [CloneStep.locked, .diskCloned, .identityWritten, .seedBuilt])
    func cancelledCloneLeavesNoStaging(step: CloneStep) async throws {
        let env = try CloneEnv()
        defer { env.cleanup() }
        let before = try env.sourceDigest()
        var environment = VMCloner.Environment()
        environment.faultInjection = { current in
            if current == step { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let cloner = env.cloner(environment)
        let task = Task { try await cloner.clone(try VMName("sorgente"), as: try VMName("copia"), owner: .app) }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try env.rootEntries() == ["sorgente.nidovm"])
        #expect(try env.sourceDigest() == before)
        let lock = try BundleLock.acquire(env.source, owner: .cli)
        lock.release()
    }

    /// The rename is the point of no return: a cancel arriving at `.readyToRename` is not checked
    /// any more, so the clone is made whole (never cut short after that point).
    @Test func cancelAtReadyToRenameKeepsTheWholeClone() async throws {
        let env = try CloneEnv()
        defer { env.cleanup() }
        var environment = VMCloner.Environment()
        environment.faultInjection = { current in
            if current == .readyToRename { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let cloner = env.cloner(environment)
        let task = Task { try await cloner.clone(try VMName("sorgente"), as: try VMName("copia"), owner: .app) }
        let clone = try await task.value
        #expect(try env.rootEntries() == ["copia.nidovm", "sorgente.nidovm"])
        try clone.verifyInnerFiles(for: .linux)
        #expect(try clone.readConfig().name.rawValue == "copia")
        #expect(try CloudInitSeed.readFile("user-data", fromISO: clone.seedURL).contains(CloudInitSeed.newMachineIDBootCommand))
    }

    @Test func failedSeedBuildLeavesNoBundle() async throws {
        struct FailingRunner: ProcessRunner {
            func run(executable: URL, arguments: [String]) throws -> ProcessResult {
                ProcessResult(status: 1, stdout: Data(), stderr: Data())
            }
        }
        let env = try CloneEnv()
        defer { env.cleanup() }
        let cloner = VMCloner(paths: env.paths, runner: FailingRunner(), environment: .init())
        await #expect(throws: NidoError.processFailed(executable: "/usr/bin/hdiutil", status: 1)) {
            try await cloner.clone(try VMName("sorgente"), as: try VMName("copia"), owner: .cli)
        }
        #expect(try env.rootEntries() == ["sorgente.nidovm"])
    }

    @Test func insufficientSpaceRefusedBeforeWork() async throws {
        let env = try CloneEnv()
        defer { env.cleanup() }
        var environment = VMCloner.Environment()
        environment.availableCapacity = { _ in 1 << 30 }
        environment.supportsCloning = { _ in true }
        await #expect(throws: NidoError.insufficientSpace(needed: SnapshotStore.spaceMargin, available: 1 << 30)) {
            try await env.cloner(environment).clone(try VMName("sorgente"), as: try VMName("copia"), owner: .cli)
        }
        #expect(try env.rootEntries() == ["sorgente.nidovm"])

        // On a volume that cannot clone, the copy's allocated size counts too.
        environment.availableCapacity = { _ in SnapshotStore.spaceMargin }
        environment.supportsCloning = { _ in false }
        await #expect(throws: NidoError.self) {
            try await env.cloner(environment).clone(try VMName("sorgente"), as: try VMName("copia"), owner: .cli)
        }
        #expect(try env.rootEntries() == ["sorgente.nidovm"])
    }

    @Test func copyFallbackMakesTheSameDisk() async throws {
        let env = try CloneEnv()
        defer { env.cleanup() }
        var environment = VMCloner.Environment()
        environment.forceCopy = true
        let clone = try await env.cloner(environment).clone(try VMName("sorgente"), as: try VMName("copia"), owner: .cli)
        #expect(try Data(contentsOf: clone.diskURL) == (try Data(contentsOf: env.source.diskURL)))
        #expect(try mode(clone.diskURL) == 0o600)
    }

    @Test func nameCollisionRefused() async throws {
        let env = try CloneEnv()
        defer { env.cleanup() }
        let image = env.tmp.appendingPathComponent("other.img")
        try Data(count: Int(mib)).write(to: image)
        _ = try VMFactory(paths: env.paths, runner: SystemProcessRunner()).createLinux(
            LinuxVMRequest(
                name: try VMName("Altra"), baseImage: image, cpuCount: 2, memoryBytes: 2048 * mib,
                diskBytes: 4 * mib, publicKey: validKey))
        var environment = VMCloner.Environment()
        environment.faultInjection = { step in
            Issue.record("no work expected, reached \(step)")
        }

        // Another VM's name, in any case, and the source's own name.
        for target in ["altra", "ALTRA", "Sorgente"] {
            await #expect(throws: NidoError.alreadyExists(target)) {
                try await env.cloner(environment).clone(try VMName("sorgente"), as: try VMName(target), owner: .cli)
            }
        }
        #expect(try env.rootEntries() == ["Altra.nidovm", "sorgente.nidovm"])
    }

    @Test func missingSourceIsNotFound() async throws {
        let env = try CloneEnv()
        defer { env.cleanup() }
        await #expect(throws: NidoError.notFound("nessuna")) {
            try await env.cloner().clone(try VMName("nessuna"), as: try VMName("copia"), owner: .cli)
        }
    }

    @Test func leftoversOfAnInterruptedRestoreRefuseTheClone() async throws {
        let env = try CloneEnv()
        defer { env.cleanup() }
        // A marker-less restore whose original cannot be put back: a directory blocks the rename.
        let tag = UUID().uuidString
        let old = env.source.url.appendingPathComponent(".disk.img.restore-\(tag).old")
        try Data("old".utf8).write(to: old)
        try FileManager.default.removeItem(at: env.source.diskURL)
        try FileManager.default.createDirectory(at: env.source.diskURL, withIntermediateDirectories: false)
        try "x".write(to: env.source.diskURL.appendingPathComponent("blocker"), atomically: false, encoding: .utf8)

        await #expect(throws: NidoError.restoreLeftovers([old.path])) {
            try await env.cloner().clone(try VMName("sorgente"), as: try VMName("copia"), owner: .cli)
        }
        #expect(try env.rootEntries() == ["sorgente.nidovm"])
    }

    @Test func staleCloningDirectoriesAreSwept() throws {
        let env = try CloneEnv()
        defer { env.cleanup() }
        let stale = env.paths.root.appendingPathComponent(".copia.cloning-\(UUID().uuidString)")
        let fresh = env.paths.root.appendingPathComponent(".nuova.cloning-\(UUID().uuidString)")
        let foreign = env.paths.root.appendingPathComponent(".copia.cloning-nonuuid")
        for dir in [stale, fresh, foreign] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
            try "x".write(to: dir.appendingPathComponent("disk.img"), atomically: false, encoding: .utf8)
        }
        let now = Date()
        VMBundle.sweepOrphanTombstones(paths: env.paths, now: now) { url in
            // Everything inside `fresh` changed a minute ago, the rest two hours ago.
            url.path.hasPrefix(fresh.path) ? now.addingTimeInterval(-60) : now.addingTimeInterval(-7200)
        }
        let entries = try env.rootEntries()
        #expect(!entries.contains(stale.lastPathComponent))
        #expect(entries.contains(fresh.lastPathComponent))
        #expect(entries.contains(foreign.lastPathComponent))
        #expect(try VMBundle.list(paths: env.paths).map(\.displayName) == ["sorgente"])
    }

    @Test func cloningDirectoryWithARecentFileIsKept() throws {
        let env = try CloneEnv()
        defer { env.cleanup() }
        let dir = env.paths.root.appendingPathComponent(".copia.cloning-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        let disk = dir.appendingPathComponent("disk.img")
        try "x".write(to: disk, atomically: false, encoding: .utf8)
        let now = Date()
        // A long copy: the directory is old, the disk being written is not.
        VMBundle.sweepOrphanTombstones(paths: env.paths, now: now) { url in
            url.path == disk.path ? now.addingTimeInterval(-10) : now.addingTimeInterval(-7200)
        }
        #expect(FileManager.default.fileExists(atPath: dir.path))
    }

    /// A VM made with the standard profile carries the Guest Tools in its user-data (well over
    /// 64 KiB): cloning it must read that seed back whole (found by the M3c integration run).
    @Test func cloneOfAStandardProfileVMKeepsItsWholeUserData() async throws {
        let env = try CloneEnv(profile: .standard)
        defer { env.cleanup() }
        let sourceUserData = try CloudInitSeed.readFile("user-data", fromISO: env.source.seedURL)
        #expect(sourceUserData.utf8.count > 64 << 10)
        let clone = try await env.cloner().clone(try VMName("sorgente"), as: try VMName("copia"), owner: .cli)
        let userData = try CloudInitSeed.readFile("user-data", fromISO: clone.seedURL)
        let machineID = "  - " + CloudInitSeed.newMachineIDBootCommand + "\n"
        #expect(userData.replacingOccurrences(of: machineID, with: "")
            .hasPrefix(sourceUserData.trimmingCharacters(in: .newlines)))
        #expect(userData.contains("ssh_deletekeys: true"))
    }

    /// The reader's cap per file (4 MiB): a user-data at the cap is read, one byte more is not.
    @Test func seedReaderCapsAFileAt4MiB() throws {
        let env = try CloneEnv()
        defer { env.cleanup() }
        let cap = CloudInitSeed.maxSeedFileSize
        #expect(cap == 4 << 20)
        for (size, readable) in [(cap, true), (cap + 1, false)] {
            let iso = env.tmp.appendingPathComponent("seed-\(size).iso")
            let userData = String(repeating: "a", count: size)
            try CloudInitSeed.buildISO(at: iso, userData: userData, metaData: "instance-id: x\n",
                                       runner: SystemProcessRunner())
            if readable {
                #expect(try CloudInitSeed.readFile("user-data", fromISO: iso).utf8.count == size)
            } else {
                #expect(throws: NidoError.seedUnreadable(iso.path)) {
                    try CloudInitSeed.readFile("user-data", fromISO: iso)
                }
            }
        }
    }

    @Test func seedReaderRejectsWhatIsNotAnISO() throws {
        let env = try CloneEnv()
        defer { env.cleanup() }
        let junk = env.tmp.appendingPathComponent("junk.iso")
        try Data("iso".utf8).write(to: junk)
        #expect(throws: NidoError.seedUnreadable(junk.path)) {
            try CloudInitSeed.readFile("user-data", fromISO: junk)
        }
        #expect(throws: NidoError.seedUnreadable(env.source.seedURL.path)) {
            try CloudInitSeed.readFile("vendor-data", fromISO: env.source.seedURL)
        }
        let link = env.tmp.appendingPathComponent("link.iso")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: env.source.seedURL)
        #expect(throws: NidoError.seedUnreadable(link.path)) {
            try CloudInitSeed.readFile("user-data", fromISO: link)
        }
        #expect(try CloudInitSeed.readFile("user-data", fromISO: env.source.seedURL)
            == CloudInitSeed.userData(
                username: "nido", publicKey: try CloudInitSeed.validatePublicKey(validKey), pinnedTimeServer: true,
                aptQuiet: true))
    }

    @Test func cloneOfACloneGetsTheMachineIDStepOnce() async throws {
        let env = try CloneEnv()
        defer { env.cleanup() }
        let first = try await env.cloner().clone(try VMName("sorgente"), as: try VMName("copia"), owner: .cli)
        let second = try await env.cloner().clone(try VMName("copia"), as: try VMName("copia2"), owner: .cli)
        let firstData = try CloudInitSeed.readFile("user-data", fromISO: first.seedURL)
        let secondData = try CloudInitSeed.readFile("user-data", fromISO: second.seedURL)
        #expect(secondData == firstData)
        #expect(secondData.components(separatedBy: "nido-machine-id").count == 2)
    }
}

@Suite struct CloneUserDataTests {
    /// The two clone `bootcmd` items, in their order: a new machine-id, then missing SSH host
    /// keys regenerated (M3b: also for clones of VMs made before it).
    private let step = "  - " + CloudInitSeed.newMachineIDBootCommand + "\n"
        + "  - " + CloudInitSeed.regenerateHostKeysBootCommand + "\n"

    @Test func appendsABootcmdOnceAndOnlyOnce() {
        // A VM made since M3b has the host-key bootcmd already: the machine-id goes first.
        let base = CloudInitSeed.userData(username: "nido", publicKey: "ssh-ed25519 AAAA")
        let once = CloudInitSeed.userDataForClone(base)
        #expect(once == base.replacingOccurrences(
            of: "bootcmd:\n", with: "bootcmd:\n  - " + CloudInitSeed.newMachineIDBootCommand + "\n")
            + "ssh_deletekeys: true\n")
        #expect(once.components(separatedBy: CloudInitSeed.regenerateHostKeysBootCommand).count == 2)
        #expect(CloudInitSeed.userDataForClone(once) == once)
        // The seed of a VM made before: both commands are added.
        #expect(CloudInitSeed.userDataForClone(userDataBeforeM3c)
            == userDataBeforeM3c + "bootcmd:\n" + step + "ssh_deletekeys: true\n")
    }

    @Test func addsANewlineWhenMissing() {
        #expect(CloudInitSeed.userDataForClone("#cloud-config\nruncmd: []")
            == "#cloud-config\nruncmd: []\nbootcmd:\n" + step + "ssh_deletekeys: true\n")
    }

    @Test func mergesIntoAnExistingBootcmd() {
        let data = "#cloud-config\nbootcmd:\n    - [echo, hi]\nruncmd: []\n"
        #expect(CloudInitSeed.userDataForClone(data)
            == "#cloud-config\nbootcmd:\n    - " + CloudInitSeed.newMachineIDBootCommand
                + "\n    - " + CloudInitSeed.regenerateHostKeysBootCommand
                + "\n    - [echo, hi]\nruncmd: []\nssh_deletekeys: true\n")
    }

    /// SECURITY L3: the clone's SSH host keys are always regenerated, also when the source's
    /// user-data said otherwise (or is itself a clone's).
    @Test func hostKeysAreAlwaysDeleted() {
        #expect(CloudInitSeed.userDataForClone("#cloud-config\nssh_deletekeys: false\n")
            == "#cloud-config\nssh_deletekeys: true\nbootcmd:\n" + step)
        let base = CloudInitSeed.userData(username: "nido", publicKey: "ssh-ed25519 AAAA")
        let once = CloudInitSeed.userDataForClone(base)
        #expect(once.components(separatedBy: "ssh_deletekeys").count == 2)
        #expect(CloudInitSeed.userDataForClone(once) == once)
    }

    @Test func theCommandIsAPerInstanceMachineIDReset() {
        #expect(CloudInitSeed.newMachineIDBootCommand
            == "[cloud-init-per, instance, nido-machine-id, sh, -c, 'rm -f /etc/machine-id /var/lib/dbus/machine-id && systemd-machine-id-setup || exit 1; [ ! -d /var/lib/dbus ] || ln -sf /etc/machine-id /var/lib/dbus/machine-id; systemctl restart systemd-journald; exit 0']")
    }
}

/// Clones of macOS guests (M3b): no seed; a new `VZMacMachineIdentifier` and MAC instead.
@Suite struct MacClonerTests {
    private func cloner(_ fixture: MacFixture, _ environment: VMCloner.Environment = .init()) -> VMCloner {
        VMCloner(paths: fixture.paths, runner: SystemProcessRunner(), environment: environment)
    }

    private func rootEntries(_ fixture: MacFixture) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: fixture.paths.root.path).sorted()
    }

    @Test func macCloneGetsNewMachineIdentifier() async throws {
        let fixture = try MacFixture()
        defer { fixture.cleanup() }
        let source = fixture.bundle
        try MachineFileCopy.writeNewFile(source.authorizedKeyURL, data: Data((validKey + "\n").utf8))
        try "known".write(to: source.knownHostsURL, atomically: false, encoding: .utf8)
        try source.updateConfig {
            $0.sharedFolders = [SharedFolder(name: "progetti", hostPath: "/Users/Shared/progetti")]
            $0.sshSucceeded = true
            $0.minimumCPUCount = 2
            $0.minimumMemoryBytes = 4 << 30
        }
        let sourceConfig = try source.readConfig()

        let result = try await cloner(fixture).cloneReportingNotes(
            try VMName("mac"), as: try VMName("copia"), owner: .cli)
        let clone = result.bundle

        #expect(clone.url.lastPathComponent == "copia.nidovm")
        let config = try clone.readConfig()
        #expect(config.guest == .macos)
        #expect(config.name.rawValue == "copia")
        #expect(config.id != sourceConfig.id)
        #expect(config.macAddress != sourceConfig.macAddress)
        #expect(VZMACAddress(string: config.macAddress) != nil)
        #expect(config.sshUser == sourceConfig.sshUser && config.osVersion == sourceConfig.osVersion)
        #expect(config.cpuCount == sourceConfig.cpuCount && config.memoryBytes == sourceConfig.memoryBytes)
        #expect(config.sharedFolders.isEmpty)
        #expect(config.suspendedConfigHash == nil && !config.isTemplate && config.aiBridge == nil)
        // The clone still needs its own SSH host keys: its "Accesso da terminale" panel opens again.
        #expect(config.sshSucceeded == nil)
        // Same image: the same minimums.
        #expect(config.minimumCPUCount == 2 && config.minimumMemoryBytes == 4 << 30)

        // A new Mac machine identifier; disk, auxiliary storage and hardware model cloned.
        let identifier = try Data(contentsOf: clone.machineIdentifierURL)
        #expect(identifier != (try Data(contentsOf: source.machineIdentifierURL)))
        #expect(VZMacMachineIdentifier(dataRepresentation: identifier) != nil)
        #expect(try Data(contentsOf: clone.auxiliaryStorageURL) == (try Data(contentsOf: source.auxiliaryStorageURL)))
        #expect(try Data(contentsOf: clone.hardwareModelURL) == (try Data(contentsOf: source.hardwareModelURL)))
        #expect(try MachineFileCopy.allocatedSize(clone.diskURL) < 1 << 30)  // sparse / cloned
        try clone.verifyInnerFiles(for: .macos)
        // The key to authorize comes along; no seed, no NVRAM, no known_hosts.
        #expect(try Data(contentsOf: clone.authorizedKeyURL) == (try Data(contentsOf: source.authorizedKeyURL)))
        for url in [clone.seedURL, clone.nvramURL, clone.knownHostsURL, clone.stateURL, clone.snapshotsURL] {
            #expect(!FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent)")
        }
        #expect(try mode(clone.url) == 0o700)
        for url in [clone.configURL, clone.diskURL, clone.auxiliaryStorageURL, clone.hardwareModelURL,
                    clone.machineIdentifierURL, clone.authorizedKeyURL] {
            #expect(try mode(url) == 0o600, "\(url.lastPathComponent)")
        }
        #expect(try rootEntries(fixture) == ["copia.nidovm", "mac.nidovm"])
    }

    @Test func macCloneWithoutAuthorizedKeyStillClones() async throws {
        let fixture = try MacFixture()
        defer { fixture.cleanup() }
        let clone = try await cloner(fixture).clone(try VMName("mac"), as: try VMName("copia"), owner: .cli)
        #expect(!FileManager.default.fileExists(atPath: clone.authorizedKeyURL.path))
        try clone.verifyInnerFiles(for: .macos)
    }

    @Test func macCloneNotesListGuestSteps() async throws {
        let fixture = try MacFixture()
        defer { fixture.cleanup() }
        let result = try await cloner(fixture).cloneReportingNotes(
            try VMName("mac"), as: try VMName("copia_2.dev"), owner: .cli)
        #expect(result.guest == .macos)
        let notes = result.cloneNotes.joined(separator: "\n")
        #expect(notes.contains("sudo rm /etc/ssh/ssh_host_* && sudo ssh-keygen -A"))
        #expect(notes.contains("sudo scutil --set ComputerName copia_2.dev"))
        // LocalHostName and HostName accept letters, digits and hyphens only.
        #expect(notes.contains("sudo scutil --set LocalHostName copia-2-dev"))
        #expect(notes.contains("sudo scutil --set HostName copia-2-dev"))
        #expect(result.cloneNotes == VMCloner.cloneNotes(guest: .macos, name: try VMName("copia_2.dev")))
        // A Linux clone needs nothing in the guest: cloud-init does it.
        #expect(VMCloner.cloneNotes(guest: .linux, name: try VMName("copia")).isEmpty)
    }

    @Test func macCloneFailureLeavesNothing() async throws {
        for step: CloneStep in [.diskCloned, .auxiliaryStorageCloned, .identityWritten, .readyToRename] {
            let fixture = try MacFixture()
            defer { fixture.cleanup() }
            var environment = VMCloner.Environment()
            environment.faultInjection = { if $0 == step { throw InjectedFailure() } }
            await #expect(throws: InjectedFailure.self, "\(step)") {
                try await cloner(fixture, environment).clone(try VMName("mac"), as: try VMName("copia"), owner: .cli)
            }
            #expect(try rootEntries(fixture) == ["mac.nidovm"], "\(step)")
        }
    }

    /// Ruling R4: templates are Linux-only. A macOS bundle marked as a template by hand is never
    /// used to create a VM.
    @Test func macTemplateIsNeverCreatedFrom() async throws {
        let fixture = try MacFixture()
        defer { fixture.cleanup() }
        try fixture.bundle.updateConfig { $0.isTemplate = true }
        await #expect(throws: NidoError.macTemplatesUnavailable) {
            try await cloner(fixture).createFromTemplate(
                try VMName("mac"), as: try VMName("copia"), sshKeyPath: nil, owner: .cli)
        }
        #expect(try rootEntries(fixture) == ["mac.nidovm"])
    }
}
