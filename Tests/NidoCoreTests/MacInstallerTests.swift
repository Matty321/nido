// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import Virtualization
@testable import NidoCore

private let validKey =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOO97YvP4YWGQwUFq+UeOnyDKkD29RZ8VdmeuGgPzeS6"
private let gib: UInt64 = 1 << 30

/// `VZMacHardwareModel.dataRepresentation` of a model Virtualization accepts, made without an
/// IPSW (none is downloaded in tests). The format is not documented: if a future framework
/// refuses it, the tests that need a model fail at `VZMacHardwareModel(dataRepresentation:)`.
let testMacHardwareModel: Data = {
    let plist: [String: Any] = [
        "DataRepresentationVersion": 1, "MinimumSupportedOS": [13, 0, 0], "PlatformVersion": 2,
    ]
    return (try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)) ?? Data()
}()

/// Returns a fixed restore image description.
private struct FakeLoader: MacRestoreImageLoading {
    var major = 26
    var minimumCPUCount = 2
    var minimumMemoryBytes: UInt64 = 4 << 30
    /// Removes the image while "loading" it: the file is gone after `inspect` checked it.
    var deletesImage = false

    func load(_ url: URL) async throws -> LoadedMacRestoreImage {
        if deletesImage { try FileManager.default.removeItem(at: url) }
        return LoadedMacRestoreImage(
            buildVersion: "25B78",
            operatingSystemVersion: OperatingSystemVersion(majorVersion: major, minorVersion: 1, patchVersion: 0),
            isSupported: true,
            configuration: .init(
                hardwareModelSupported: true, hardwareModel: testMacHardwareModel,
                minimumCPUCount: minimumCPUCount, minimumMemoryBytes: minimumMemoryBytes))
    }
}

/// What the fake installer saw.
private final class InstallRecord: Sendable {
    struct Seen: Sendable {
        var bundleURL: URL
        var config: VMConfig
        var ipsw: URL
        var existingFiles: [String]
    }
    let seen = Mutex<Seen?>(nil)
    let started = Mutex(false)
}

/// Stands in for `VZMacOSInstaller`: reports `steps`, then fails, waits for cancellation or returns.
private struct FakeInstaller: MacOSInstalling {
    enum Ending: Sendable {
        case success
        case failure(NSError)
        case waitForCancellation
    }
    var steps: [Double] = []
    var ending: Ending = .success
    let record = InstallRecord()
    /// Called with the config when the installation starts.
    var onInstall: (@Sendable (VMConfig) -> Void)?

    func install(
        bundle: VMBundle, config: VMConfig, ipsw: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: bundle.url.path)) ?? []
        record.seen.withLock {
            $0 = InstallRecord.Seen(bundleURL: bundle.url, config: config, ipsw: ipsw, existingFiles: names.sorted())
        }
        onInstall?(config)
        for step in steps { progress(step) }
        switch ending {
        case .success:
            return
        case .failure(let error):
            throw error
        case .waitForCancellation:
            record.started.withLock { $0 = true }
            // Like the real installer: returns only once cancelled (`Task.sleep` throws then).
            try await Task.sleep(for: .seconds(600))
        }
    }
}

private struct InstallEnv {
    let tmp: URL
    let paths: NidoPaths
    let ipsw: URL

    init() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("nido-macinst-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        paths = NidoPaths(root: tmp.appendingPathComponent("VMs", isDirectory: true))
        ipsw = tmp.appendingPathComponent("UniversalMac_26.1_25B78_Restore.ipsw")
        try Data([0x50, 0x4B, 0x03, 0x04] + Array(repeating: 0, count: 60)).write(to: ipsw)
    }

    func installer(
        _ fake: FakeInstaller, loader: FakeLoader = FakeLoader(), available: UInt64 = 1 << 50,
        passwords: any GuestPasswordStore = MemoryGuestPasswordStore()
    ) -> MacInstaller {
        var environment = MacInstaller.Environment()
        environment.passwords = passwords
        environment.loader = loader
        environment.hostVersion = OperatingSystemVersion(majorVersion: 26, minorVersion: 7, patchVersion: 1)
        environment.availableCapacity = { _ in available }
        environment.installer = fake
        return MacInstaller(paths: paths, environment: environment)
    }

    func request(
        name: String = "mac", cpus: Int = 2, memory: UInt64 = 4 * gib, disk: UInt64 = 64 * gib,
        account: MacAccountRequest? = nil, agentAccess: Bool = false
    ) throws -> MacVMRequest {
        MacVMRequest(
            name: try VMName(name), ipsw: ipsw, cpuCount: cpus, memoryBytes: memory, diskBytes: disk,
            sshUser: "mattia", publicKey: validKey, account: account, agentAccess: agentAccess)
    }

    /// Entries of the root (hidden ones too), sorted; empty when the root does not exist.
    func rootEntries() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: paths.root.path)) ?? []).sorted()
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: tmp)
    }
}

private func mode(_ url: URL) -> Int? {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return nil }
    return Int(info.st_mode & 0o777)
}

/// Records when the password was saved, and what the root held at that moment; can create a folder
/// at the VM's final path while saving, so the rename after it fails.
private final class SpyPasswordStore: GuestPasswordStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [UUID: GuestPassword] = [:]
    var rootAtSave: [String]?
    var blockDestination: URL?
    let root: URL
    init(root: URL) { self.root = root }

    /// Every save fails as the Keychain would.
    var refuses = false
    func read(vm: UUID) throws -> GuestPassword? { lock.withLock { items[vm] } }
    func has(_ vm: UUID) -> Bool { lock.withLock { items[vm] != nil } }
    func save(_ password: GuestPassword, vm: UUID) throws {
        if refuses { throw GuestPasswordStoreError.keychain(-25293) }
        rootAtSave = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
        if let blockDestination {
            try FileManager.default.createDirectory(at: blockDestination, withIntermediateDirectories: true)
        }
        lock.withLock { items[vm] = password }
    }
    func delete(vm: UUID) throws { lock.withLock { items[vm] = nil } }
    var count: Int { lock.withLock { items.count } }
}

@Suite struct MacInstallerTests {
    @Test func installWritesAccountAndAgentAccess() async throws {
        let env = try InstallEnv()
        defer { env.cleanup() }
        let password = try #require(GuestPassword("abcde-fghjk-mnpqr-stuvw"))
        let store = MemoryGuestPasswordStore()
        let account = MacAccountRequest(fullName: "Mattia Pichierri", password: password)
        let bundle = try await env.installer(FakeInstaller(), passwords: store)
            .install(try env.request(account: account, agentAccess: true)) { _ in }
        let config = try bundle.readConfig()
        #expect(config.macAccountFullName == "Mattia Pichierri")
        #expect(config.agentAccess == true)
        #expect(config.macProvisioningSent == nil)
        #expect(try store.read(vm: config.id) == password)

        let plain = try await env.installer(FakeInstaller(), passwords: store)
            .install(try env.request(name: "plain")) { _ in }
        let plainConfig = try plain.readConfig()
        #expect(plainConfig.macAccountFullName == nil && plainConfig.agentAccess == nil)
        #expect(try store.read(vm: plainConfig.id) == nil)
    }

    @Test func installSavesPasswordBeforeRename() async throws {
        let env = try InstallEnv()
        defer { env.cleanup() }
        let store = SpyPasswordStore(root: env.paths.root)
        let account = MacAccountRequest(fullName: "A B", password: try #require(GuestPassword("secret-1")))
        _ = try await env.installer(FakeInstaller(), passwords: store).install(try env.request(account: account)) { _ in }
        // At the save the VM did not exist yet: only the staging folder was in the root.
        let seen = try #require(store.rootAtSave)
        #expect(seen.count == 1 && seen[0].hasPrefix(".creating-"))
    }

    @Test func failedInstallDeletesPassword() async throws {
        let env = try InstallEnv()
        defer { env.cleanup() }
        let store = SpyPasswordStore(root: env.paths.root)
        // The folder appears at the final path while the password is saved: the rename fails.
        store.blockDestination = env.paths.bundleURL(for: try VMName("mac"))
        let account = MacAccountRequest(fullName: "A B", password: try #require(GuestPassword("secret-1")))
        await #expect(throws: NidoError.self) {
            _ = try await env.installer(FakeInstaller(), passwords: store)
                .install(try env.request(account: account)) { _ in }
        }
        #expect(store.count == 0)
    }

    // Install without a password stored when the install itself fails (installer error).
    @Test func installerFailureStoresNoPassword() async throws {
        let env = try InstallEnv()
        defer { env.cleanup() }
        let store = SpyPasswordStore(root: env.paths.root)
        let account = MacAccountRequest(fullName: "A B", password: try #require(GuestPassword("secret-1")))
        let fake = FakeInstaller(ending: .failure(NSError(domain: "x", code: 1)))
        await #expect(throws: (any Error).self) {
            _ = try await env.installer(fake, passwords: store).install(try env.request(account: account)) { _ in }
        }
        #expect(env.rootEntries().isEmpty)
        // Saved before the installer ran, removed again by its failure.
        #expect(store.rootAtSave != nil)
        #expect(store.count == 0)
    }

    /// The Keychain is asked before the long installation: a refusal ends it before the installer
    /// runs, and nothing is left behind.
    @Test func keychainRefusalStopsBeforeTheInstaller() async throws {
        let env = try InstallEnv()
        defer { env.cleanup() }
        let store = SpyPasswordStore(root: env.paths.root)
        store.refuses = true
        let account = MacAccountRequest(fullName: "A B", password: try #require(GuestPassword("secret-1")))
        let fake = FakeInstaller()
        await #expect(throws: GuestPasswordStoreError.keychain(-25293)) {
            _ = try await env.installer(fake, passwords: store).install(try env.request(account: account)) { _ in }
        }
        #expect(fake.record.seen.withLock { $0 } == nil)
        #expect(env.rootEntries().isEmpty)
    }

    /// The password is in the Keychain while the installer runs (keyed by the new VM's id).
    @Test func passwordIsSavedBeforeTheInstaller() async throws {
        let env = try InstallEnv()
        defer { env.cleanup() }
        let store = SpyPasswordStore(root: env.paths.root)
        let account = MacAccountRequest(fullName: "A B", password: try #require(GuestPassword("secret-1")))
        var fake = FakeInstaller()
        fake.onInstall = { config in #expect(store.has(config.id)) }
        _ = try await env.installer(fake, passwords: store).install(try env.request(account: account)) { _ in }
        #expect(fake.record.seen.withLock { $0 } != nil)
        #expect(store.count == 1)
    }

    /// What macOS would refuse at the first start is refused at the creation, before anything is
    /// created (needs the macOS 27 Virtualization; the account path needs a macOS 27 host).
    @Test(.enabled(if: MacFirstBoot.canValidate, "needs macOS 27 Virtualization"))
    func invalidAccountIsRefusedAtCreation() async throws {
        let env = try InstallEnv()
        defer { env.cleanup() }
        let store = SpyPasswordStore(root: env.paths.root)
        let fake = FakeInstaller()
        let short = MacAccountRequest(fullName: "A B", password: try #require(GuestPassword("abc")))
        await #expect(throws: MacProvisioningError.self) {
            _ = try await env.installer(fake, passwords: store).install(try env.request(account: short)) { _ in }
        }
        let blank = MacAccountRequest(fullName: "  ", password: try #require(GuestPassword("secret-1")))
        await #expect(throws: MacProvisioningError.self) {
            _ = try await env.installer(fake, passwords: store).install(try env.request(account: blank)) { _ in }
        }
        #expect(fake.record.seen.withLock { $0 } == nil)
        #expect(store.rootAtSave == nil)
        #expect(env.rootEntries().isEmpty)
    }

    @Test func installCreatesMacBundle() async throws {
        let env = try InstallEnv()
        defer { env.cleanup() }
        let fake = FakeInstaller()
        let bundle = try await env.installer(fake).install(try env.request()) { _ in }

        #expect(bundle.url.lastPathComponent == "mac.nidovm")
        #expect(env.rootEntries() == ["mac.nidovm"])
        #expect(mode(bundle.url) == 0o700)
        let config = try bundle.readConfig()
        #expect(config.guest == .macos)
        #expect(config.schemaVersion == VMConfig.currentSchemaVersion)
        // On the controlled network with the macOS base list (activation, updates, time).
        #expect(config.controlledNetwork == true)
        #expect(EgressPolicyStore.load(bundle: bundle) == EgressPolicy.macOSBase)
        #expect(config.osVersion == "26.1")
        #expect(config.sshUser == "mattia")
        // The image's minimums, for Settings.
        #expect(config.minimumCPUCount == 2)
        #expect(config.minimumMemoryBytes == 4 * gib)
        #expect(config.cpuCount == 2 && config.memoryBytes == 4 * gib && config.diskBytes == 64 * gib)
        #expect(VZMACAddress(string: config.macAddress) != nil)
        // The M3c features stay Linux-only.
        #expect(config.provisioning == nil && config.guestToolsVersion == nil)
        #expect(config.aiBridge == nil && config.pendingProvisioning == nil && !config.isTemplate)
        #expect(config.sharedFolders.isEmpty && !config.rosetta && !config.clipboardSharing)

        try bundle.verifyInnerFiles(for: .macos)
        for url in [bundle.configURL, bundle.diskURL, bundle.auxiliaryStorageURL, bundle.hardwareModelURL,
                    bundle.machineIdentifierURL, bundle.authorizedKeyURL] {
            #expect(mode(url) == 0o600, "\(url.lastPathComponent)")
        }
        #expect(!FileManager.default.fileExists(atPath: bundle.seedURL.path))
        #expect(!FileManager.default.fileExists(atPath: bundle.nvramURL.path))
        #expect(try Data(contentsOf: bundle.hardwareModelURL) == testMacHardwareModel)
        #expect(VZMacMachineIdentifier(dataRepresentation: try Data(contentsOf: bundle.machineIdentifierURL)) != nil)
        #expect(try String(contentsOf: bundle.authorizedKeyURL, encoding: .utf8) == validKey + "\n")
        let size = try FileManager.default.attributesOfItem(atPath: bundle.diskURL.path)[.size] as? NSNumber
        #expect(size?.uint64Value == 64 * gib)
        #expect(try MachineFileCopy.allocatedSize(bundle.diskURL) < 1 * gib)  // sparse

        // The installer ran on the complete staging folder, never on the final bundle.
        let seen = try #require(fake.record.seen.withLock { $0 })
        #expect(seen.bundleURL.lastPathComponent.hasPrefix(".creating-"))
        #expect(seen.ipsw == env.ipsw)
        #expect(seen.config == config)
        for name in [
            "auxiliary-storage.img", "config.json", "disk.img", "egress.json", "hardware-model.bin", "machine-id.bin",
        ] {
            #expect(seen.existingFiles.contains(name), "\(name)")
        }
    }

    @Test func progressIsForwarded() async throws {
        let env = try InstallEnv()
        defer { env.cleanup() }
        let received = Mutex<[Double]>([])
        _ = try await env.installer(FakeInstaller(steps: [0, 0.25, 0.5, 1])).install(try env.request()) { value in
            received.withLock { $0.append(value) }
        }
        #expect(received.withLock { $0 } == [0, 0.25, 0.5, 1])
    }

    @Test func installerRefusesTakenName() async throws {
        let env = try InstallEnv()
        defer { env.cleanup() }
        try env.paths.ensureRoot()
        try FileManager.default.createDirectory(
            at: env.paths.root.appendingPathComponent("MAC.nidovm"), withIntermediateDirectories: false)
        let fake = FakeInstaller()
        await #expect(throws: NidoError.alreadyExists("mac")) {
            _ = try await env.installer(fake).install(try env.request()) { _ in }
        }
        #expect(env.rootEntries() == ["MAC.nidovm"])
        #expect(fake.record.seen.withLock { $0 } == nil)
    }

    @Test func installerRefusesInsufficientSpace() async throws {
        let env = try InstallEnv()
        defer { env.cleanup() }
        let fake = FakeInstaller()
        await #expect(throws: NidoError.insufficientSpace(needed: 66 * gib, available: 10 * gib)) {
            _ = try await env.installer(fake, available: 10 * gib).install(try env.request()) { _ in }
        }
        #expect(env.rootEntries().isEmpty)
        #expect(fake.record.seen.withLock { $0 } == nil)
    }

    @Test func installerRefusesResourcesBelowTheImageMinimum() async throws {
        let env = try InstallEnv()
        defer { env.cleanup() }
        let fake = FakeInstaller()
        let loader = FakeLoader(minimumCPUCount: 4, minimumMemoryBytes: 8 * gib)
        for request in [try env.request(cpus: 2, memory: 8 * gib), try env.request(cpus: 4, memory: 4 * gib)] {
            await #expect {
                _ = try await env.installer(fake, loader: loader).install(request) { _ in }
            } throws: { error in
                guard case NidoError.invalidResources = error else { return false }
                return true
            }
        }
        #expect(env.rootEntries().isEmpty)
    }

    @Test func installerRefusesBadUserOrKeyBeforeReadingTheImage() async throws {
        let env = try InstallEnv()
        defer { env.cleanup() }
        var badUser = try env.request()
        badUser.sshUser = "-oProxyCommand"
        await #expect(throws: NidoError.invalidSSHUser("-oProxyCommand")) {
            _ = try await env.installer(FakeInstaller()).install(badUser) { _ in }
        }
        var badKey = try env.request()
        badKey.publicKey = "not a key"
        await #expect(throws: NidoError.invalidPublicKey) {
            _ = try await env.installer(FakeInstaller()).install(badKey) { _ in }
        }
        #expect(env.rootEntries().isEmpty)
    }

    @Test func newerMajorImageIsRefusedBeforeAnyFile() async throws {
        let env = try InstallEnv()
        defer { env.cleanup() }
        await #expect(throws: NidoError.restoreImageUnsupported(version: "27.1", requiredHostMajor: 27)) {
            _ = try await env.installer(FakeInstaller(), loader: FakeLoader(major: 27)).install(try env.request()) { _ in }
        }
        #expect(env.rootEntries().isEmpty)
    }

    @Test func cancelledInstallLeavesNothing() async throws {
        let env = try InstallEnv()
        defer { env.cleanup() }
        let fake = FakeInstaller(ending: .waitForCancellation)
        let installer = env.installer(fake)
        let request = try env.request()
        let task = Task { try await installer.install(request) { _ in } }
        var waited = 0
        while !fake.record.started.withLock({ $0 }) && waited < 500 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        #expect(fake.record.started.withLock { $0 })
        #expect(env.rootEntries().count == 1)
        #expect(env.rootEntries().first?.hasPrefix(".creating-") == true)
        // The staging folder is never a VM of the library.
        #expect(try VMBundle.list(paths: env.paths).isEmpty)
        #expect(try await VMRegistry(paths: env.paths, passwords: nil).summaries().isEmpty)

        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(env.rootEntries().isEmpty)
    }

    @Test func failedInstallLeavesNothing() async throws {
        let env = try InstallEnv()
        defer { env.cleanup() }
        let failure = NSError(domain: VZErrorDomain, code: VZError.Code.installationFailed.rawValue)
        await #expect(throws: NSError.self) {
            _ = try await env.installer(FakeInstaller(steps: [0.3], ending: .failure(failure)))
                .install(try env.request()) { _ in }
        }
        #expect(env.rootEntries().isEmpty)
    }

    @Test func installationRequiresUpdateIsExplained() async throws {
        let env = try InstallEnv()
        defer { env.cleanup() }
        let failure = NSError(domain: VZErrorDomain, code: VZError.Code.installationRequiresUpdate.rawValue)
        await #expect(throws: NidoError.restoreImageUnsupported(version: "26.1")) {
            _ = try await env.installer(FakeInstaller(ending: .failure(failure))).install(try env.request()) { _ in }
        }
        #expect(env.rootEntries().isEmpty)
    }

    @Test func hugeDiskIsRefusedBeforeAnyFile() async throws {
        let env = try InstallEnv()
        defer { env.cleanup() }
        let fake = FakeInstaller()
        for disk in [UInt64.max, UInt64(Int64.max), UInt64(Int64.max) - SnapshotStore.spaceMargin + 1] {
            await #expect {
                _ = try await env.installer(fake).install(try env.request(disk: disk)) { _ in }
            } throws: { error in
                guard case NidoError.invalidResources = error else { return false }
                return true
            }
        }
        #expect(env.rootEntries().isEmpty)
        #expect(fake.record.seen.withLock { $0 } == nil)
    }

    @Test func imageRemovedBeforeInstallLeavesNothing() async throws {
        let env = try InstallEnv()
        defer { env.cleanup() }
        let fake = FakeInstaller()
        await #expect(throws: NidoError.notARestoreImage(env.ipsw.path)) {
            _ = try await env.installer(fake, loader: FakeLoader(deletesImage: true)).install(try env.request()) { _ in }
        }
        #expect(env.rootEntries().isEmpty)
        #expect(fake.record.seen.withLock { $0 } == nil)
    }

    @Test func imageCheckRefusesWhatIsNotARegularFile() throws {
        let env = try InstallEnv()
        defer { env.cleanup() }
        try MacInstaller.checkImageStillThere(env.ipsw)
        let link = env.tmp.appendingPathComponent("link.ipsw")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: env.ipsw)
        let dir = env.tmp.appendingPathComponent("dir.ipsw")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        for url in [link, dir, env.tmp.appendingPathComponent("missing.ipsw")] {
            #expect(throws: NidoError.notARestoreImage(url.path)) { try MacInstaller.checkImageStillThere(url) }
        }
    }

    @Test func creatingFoldersAreSwept() async throws {
        let env = try InstallEnv()
        defer { env.cleanup() }
        try env.paths.ensureRoot()
        let stale = env.paths.root.appendingPathComponent(".creating-\(UUID().uuidString)")
        let fresh = env.paths.root.appendingPathComponent(".creating-\(UUID().uuidString)")
        let inUse = env.paths.root.appendingPathComponent(".creating-\(UUID().uuidString)")
        let foreign = env.paths.root.appendingPathComponent(".creating-x")
        for dir in [stale, fresh, inUse, foreign] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
            try "x".write(to: dir.appendingPathComponent("disk.img"), atomically: false, encoding: .utf8)
        }
        // An install still running (in this process or another) holds the folder's lock.
        let lock = try BundleLock.acquire(VMBundle(url: inUse), owner: .cliOperation)
        defer { lock.release() }
        // A crashed install (lock free) is swept after a few minutes, not after the tombstone hour.
        let crashed = env.paths.root.appendingPathComponent(".creating-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: crashed, withIntermediateDirectories: false)
        let now = Date()
        let registry = VMRegistry(paths: env.paths, passwords: nil, now: { now }) { url in
            if url.path.hasPrefix(fresh.path) { return now.addingTimeInterval(-60) }
            if url.path.hasPrefix(crashed.path) { return now.addingTimeInterval(-180) }
            return now.addingTimeInterval(-7200)
        }
        #expect(try await registry.summaries().isEmpty)
        let entries = env.rootEntries()
        #expect(!entries.contains(stale.lastPathComponent))
        #expect(!entries.contains(crashed.lastPathComponent))
        // Just made, lock not taken yet: kept.
        #expect(entries.contains(fresh.lastPathComponent))
        #expect(entries.contains(inUse.lastPathComponent))
        #expect(entries.contains(foreign.lastPathComponent))
    }

    /// A crashed installation leaves its Keychain item (saved under the new VM's id before the
    /// installation): the sweep that removes its `.creating-<uuid>` folder removes that item too,
    /// read from the folder's `config.json`. An item of an existing VM, a folder still in use or
    /// too recent, and a folder without `config.json` leave the Keychain alone.
    @Test func sweptCreatingFolderTakesItsPasswordAlong() async throws {
        let env = try InstallEnv()
        defer { env.cleanup() }
        try env.paths.ensureRoot()
        let store = MemoryGuestPasswordStore()
        let password = try #require(GuestPassword("abcde-fghjk-mnpqr-stuvw"))
        func config(_ id: UUID, _ name: String) throws -> VMConfig {
            VMConfig(
                id: id, name: try VMName(name), guest: .macos, cpuCount: 2, memoryBytes: 4 * gib,
                diskBytes: 64 * gib, macAddress: "02:00:00:00:00:0a")
        }
        func staging(_ id: UUID) throws -> URL {
            let url = env.paths.root.appendingPathComponent(".creating-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            try VMBundle(url: url).writeConfigUnlocked(try config(id, "staged"))
            return url
        }
        // An existing VM whose id a staging folder also names (a copied folder): never its item.
        let existing = try VMBundle.create(config: try config(UUID(), "kept"), paths: env.paths)
        let existingID = try existing.readConfig().id
        let crashedID = UUID(), inUseID = UUID(), freshID = UUID()
        for id in [existingID, crashedID, inUseID, freshID] { try store.save(password, vm: id) }
        let crashed = try staging(crashedID)
        let copied = try staging(existingID)
        let inUse = try staging(inUseID)
        let fresh = try staging(freshID)
        let bare = env.paths.root.appendingPathComponent(".creating-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: false)
        let lock = try BundleLock.acquire(VMBundle(url: inUse), owner: .cliOperation)
        defer { lock.release() }

        let now = Date()
        let registry = VMRegistry(paths: env.paths, passwords: store, now: { now }, changeTime: { url in
            url.path.hasPrefix(fresh.path) ? now.addingTimeInterval(-60) : now.addingTimeInterval(-600)
        })
        #expect(try await registry.summaries().map(\.name) == ["kept"])
        let entries = env.rootEntries()
        #expect(!entries.contains(crashed.lastPathComponent))
        #expect(!entries.contains(copied.lastPathComponent))
        #expect(!entries.contains(bare.lastPathComponent))
        #expect(entries.contains(inUse.lastPathComponent))
        #expect(entries.contains(fresh.lastPathComponent))
        #expect(try store.read(vm: crashedID) == nil)
        #expect(try store.read(vm: existingID) == password)
        #expect(try store.read(vm: inUseID) == password)
        #expect(try store.read(vm: freshID) == password)
    }

    /// The item goes before the folder: a removal that stops half-way (config.json gone, the
    /// disk image left) must not leave an item whose id no later sweep can read.
    @Test func sweptCreatingFolderDeletesTheItemFirst() async throws {
        let env = try InstallEnv()
        defer { env.cleanup() }
        try env.paths.ensureRoot()
        /// Records whether the staging folder was still there when its item was deleted.
        final class OrderStore: GuestPasswordStore, @unchecked Sendable {
            let folder = Mutex<URL?>(nil)
            let deletes = Mutex<[(UUID, Bool)]>([])
            func read(vm: UUID) throws -> GuestPassword? { nil }
            func save(_ password: GuestPassword, vm: UUID) throws {}
            func delete(vm: UUID) throws {
                let present = folder.withLock { $0 }.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
                deletes.withLock { $0.append((vm, present)) }
            }
        }
        let store = OrderStore()
        let id = UUID()
        let staging = env.paths.root.appendingPathComponent(".creating-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        try VMBundle(url: staging).writeConfigUnlocked(VMConfig(
            id: id, name: try VMName("staged"), guest: .macos, cpuCount: 2, memoryBytes: 4 * gib,
            diskBytes: 64 * gib, macAddress: "02:00:00:00:00:0b"))
        store.folder.withLock { $0 = staging }
        let now = Date()
        _ = try await VMRegistry(
            paths: env.paths, passwords: store, now: { now }, changeTime: { _ in now.addingTimeInterval(-600) }
        ).summaries()
        #expect(!env.rootEntries().contains(staging.lastPathComponent))
        let deletes = store.deletes.withLock { $0 }
        #expect(deletes.map(\.0) == [id])
        #expect(deletes.map(\.1) == [true])
    }
}
