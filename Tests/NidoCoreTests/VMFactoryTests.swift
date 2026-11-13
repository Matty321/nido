// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCore

private let validKey =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOO97YvP4YWGQwUFq+UeOnyDKkD29RZ8VdmeuGgPzeS6"
private let mib: UInt64 = 1024 * 1024

private struct SeedRunner: ProcessRunner {
    let status: Int32
    func run(executable: URL, arguments: [String]) throws -> ProcessResult {
        if status == 0, arguments.count > 6 {
            FileManager.default.createFile(
                atPath: arguments[6], contents: Data("iso".utf8), attributes: [.posixPermissions: 0o644])
        }
        return ProcessResult(status: status, stdout: Data(), stderr: Data())
    }
}

private func mode(_ url: URL) throws -> Int {
    (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
}

private struct Env {
    let tmp: URL
    let paths: NidoPaths
    let image: URL
    init() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("nido-factory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        paths = NidoPaths(root: tmp.appendingPathComponent("VMs"))
        image = tmp.appendingPathComponent("base.img")
        try Data(count: Int(mib)).write(to: image)
    }
    func request(name: String = "vm1", disk: UInt64, image: URL? = nil, key: String = validKey) throws -> LinuxVMRequest {
        LinuxVMRequest(
            name: try VMName(name), baseImage: image ?? self.image, cpuCount: 2,
            memoryBytes: 2048 * mib, diskBytes: disk, publicKey: key)
    }
    func cleanup() { try? FileManager.default.removeItem(at: tmp) }
}

/// Records the staged `network-config` before writing a fake ISO.
private final class NetworkConfigRecorder: ProcessRunner, @unchecked Sendable {
    nonisolated(unsafe) var networkConfig: String?
    nonisolated(unsafe) var userData: String?
    func run(executable: URL, arguments: [String]) throws -> ProcessResult {
        networkConfig = try? String(contentsOfFile: arguments[7] + "/network-config", encoding: .utf8)
        userData = try? String(contentsOfFile: arguments[7] + "/user-data", encoding: .utf8)
        FileManager.default.createFile(
            atPath: arguments[6], contents: Data("iso".utf8), attributes: [.posixPermissions: 0o644])
        return ProcessResult(status: 0, stdout: Data(), stderr: Data())
    }
}

@Suite(.italian) struct VMFactoryTests {
    @Test func seedPinsDHCPIdentifierToTheVMMAC() throws {
        let env = try Env()
        defer { env.cleanup() }
        let recorder = NetworkConfigRecorder()
        let bundle = try VMFactory(paths: env.paths, runner: recorder).createLinux(try env.request(disk: 4 * mib))
        let config = try bundle.readConfig()
        #expect(recorder.networkConfig == (try CloudInitSeed.networkConfig(macAddress: config.macAddress)))
    }

    @Test func createsCompleteBundle() throws {
        let env = try Env()
        defer { env.cleanup() }
        let factory = VMFactory(paths: env.paths, runner: SeedRunner(status: 0))
        let bundle = try factory.createLinux(try env.request(disk: 4 * mib))

        let size = (try FileManager.default.attributesOfItem(atPath: bundle.diskURL.path)[.size] as! NSNumber).uint64Value
        #expect(size == 4 * mib)
        for url in [bundle.diskURL, bundle.nvramURL, bundle.machineIdentifierURL, bundle.seedURL, bundle.configURL] {
            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect(try mode(url) == 0o600)
        }
        let config = try bundle.readConfig()
        #expect(!config.macAddress.isEmpty)
        #expect(config.guest == .linux)
        #expect(config.diskBytes == 4 * mib)
        #expect(config.clipboardSharing == false)
        // Schema 2, no shares, and the guest mounts /mnt/nido by itself (cloud-init `mounts`).
        #expect(config.schemaVersion == VMConfig.currentSchemaVersion)
        #expect(config.sharedFolders.isEmpty)
        #expect(config.guestMountsSharedFolders)
        #expect(try Data(contentsOf: bundle.machineIdentifierURL).count > 0)
    }

    /// The phase-2 choice of the wizard is recorded in the new VM's config, never in its seed.
    @Test func pendingProvisioningIsRecorded() throws {
        let env = try Env()
        defer { env.cleanup() }
        var request = try env.request(disk: 4 * mib)
        request.pendingProvisioning = PendingProvisioning(ollama: true, model: "qwen3:0.6b")
        let bundle = try VMFactory(paths: env.paths, runner: SeedRunner(status: 0)).createLinux(request)
        #expect(try bundle.readConfig().pendingProvisioning == PendingProvisioning(ollama: true, model: "qwen3:0.6b"))
    }

    /// A new VM is on the controlled network from its first boot (gvproxy needs no IP forwarding
    /// on the Mac), with its distribution's base list: Debian and Ubuntu.
    @Test func newVMIsControlledWithTheBaseList() throws {
        let env = try Env()
        defer { env.cleanup() }
        for (name, distribution) in [("deb", LinuxDistribution.debian13), ("ubu", .ubuntu2604)] {
            var request = try env.request(name: name, disk: 4 * mib)
            request.distribution = distribution
            let bundle = try VMFactory(paths: env.paths, runner: SeedRunner(status: 0)).createLinux(request)
            #expect(try bundle.readConfig().controlledNetwork == true)
            // Its seed turns the background requests off: no "Spegni" suggestion.
            #expect(try bundle.readConfig().backgroundRequestsOff == true)
            #expect(!GuestBackgroundRequests.mayNeedQuieting(bundle: bundle))
            #expect(!EgressPolicy.base(for: distribution).allow.isEmpty)
            #expect(EgressPolicyStore.load(bundle: bundle) == EgressPolicy.base(for: distribution))
            #expect(try mode(bundle.egressPolicyURL) == 0o600)
        }
    }

    /// The new VM's seed points the guest clock at the base list's time server.
    @Test func newVMSyncsTimeWithTheBaseListServer() throws {
        let env = try Env()
        defer { env.cleanup() }
        let recorder = NetworkConfigRecorder()
        _ = try VMFactory(paths: env.paths, runner: recorder).createLinux(try env.request(disk: 4 * mib))
        let userData = try #require(recorder.userData)
        #expect(userData.contains("/etc/systemd/timesyncd.conf.d/nido.conf"))
        #expect(userData.contains("[systemctl, restart, systemd-timesyncd.service]"))
        #expect(userData.contains(GuestTimeSync.holdBootCommand))
        // Debian too: no apt SRV lookups, but none of Ubuntu's masks.
        #expect(userData.contains("  - path: \(GuestAptSRV.path)\n"))
        #expect(userData.contains("  - path: \(GuestAptListChanges.path)\n"))
        #expect(!userData.contains("nido-ubuntu-quiet"))
    }

    @Test func diskSmallerThanImageIsRejectedWithoutBundle() throws {
        let env = try Env()
        defer { env.cleanup() }
        let factory = VMFactory(paths: env.paths, runner: SeedRunner(status: 0))
        let req = try env.request(disk: mib / 2)
        #expect(throws: NidoError.self) { try factory.createLinux(req) }
        do { _ = try factory.createLinux(req) } catch let e as NidoError {
            guard case .invalidResources = e else { Issue.record("wrong error \(e)"); return }
        }
        #expect(!FileManager.default.fileExists(atPath: env.paths.bundleURL(for: req.name).path))
    }

    @Test func failingRunnerLeavesNoBundle() throws {
        let env = try Env()
        defer { env.cleanup() }
        let factory = VMFactory(paths: env.paths, runner: SeedRunner(status: 1))
        let req = try env.request(disk: 4 * mib)
        #expect(throws: NidoError.processFailed(executable: "/usr/bin/hdiutil", status: 1)) {
            try factory.createLinux(req)
        }
        #expect(!FileManager.default.fileExists(atPath: env.paths.bundleURL(for: req.name).path))
    }

    @Test func invalidKeyAndMissingImageCreateNothing() throws {
        let env = try Env()
        defer { env.cleanup() }
        let factory = VMFactory(paths: env.paths, runner: SeedRunner(status: 0))
        let badKey = try env.request(disk: 4 * mib, key: "nope")
        #expect(throws: NidoError.invalidPublicKey) { try factory.createLinux(badKey) }
        let missing = env.tmp.appendingPathComponent("missing.img")
        let noImage = try env.request(disk: 4 * mib, image: missing)
        #expect(throws: NidoError.notFound(missing.path)) { try factory.createLinux(noImage) }
        #expect(!FileManager.default.fileExists(atPath: env.paths.bundleURL(for: noImage.name).path))
    }

    @Test func symlinkedImageIsRejected() throws {
        let env = try Env()
        defer { env.cleanup() }
        let link = env.tmp.appendingPathComponent("link.img")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: env.image)
        let factory = VMFactory(paths: env.paths, runner: SeedRunner(status: 0))
        let req = try env.request(disk: 4 * mib, image: link)
        #expect(throws: NidoError.notFound(link.path)) { try factory.createLinux(req) }
    }
}

// MARK: - Ubuntu

extension VMFactoryTests {
    /// An Ubuntu VM from a qcow2 base image: the disk is the converted raw grown to `diskBytes`,
    /// the config records the distribution, the controlled network starts from the Ubuntu base
    /// list, and the seed pins chrony (26.04) to the base list's time server.
    @Test func ubuntuVMFromQcow2() throws {
        let env = try Env()
        defer { env.cleanup() }
        let qcow2 = env.tmp.appendingPathComponent("ubuntu.img")
        try Data(Qcow2ImageTests.Fixture().bytes()).write(to: qcow2)
        var request = try env.request(disk: 4 * mib, image: qcow2)
        request.distribution = .ubuntu2604
        let recorder = NetworkConfigRecorder()
        let bundle = try VMFactory(paths: env.paths, runner: recorder).createLinux(request)

        let disk = try FileHandle(forReadingFrom: bundle.diskURL)
        defer { try? disk.close() }
        let head = try #require(try disk.read(upToCount: 1024))
        #expect(head.prefix(512).allSatisfy { $0 == UInt8(ascii: "A") })
        #expect(head.suffix(512).allSatisfy { $0 == UInt8(ascii: "B") })
        #expect(try disk.seekToEnd() == 4 * mib)
        #expect(try mode(bundle.diskURL) == 0o600)

        let config = try bundle.readConfig()
        #expect(config.distribution == .ubuntu2604)
        #expect(EgressPolicyStore.load(bundle: bundle) == EgressPolicy.ubuntuBase)
        let userData = try #require(recorder.userData)
        #expect(userData.contains(GuestTimeSync.chronyPath))
        #expect(userData.contains("[systemctl, restart, chrony.service]"))
        #expect(userData.contains(GuestTimeSync.chronyHoldBootCommand))
        #expect(!userData.contains("timesyncd"))
    }

    /// Ubuntu 24.04 still runs systemd-timesyncd.
    @Test func ubuntu2404KeepsTimesyncd() throws {
        let env = try Env()
        defer { env.cleanup() }
        var request = try env.request(disk: 4 * mib)
        request.distribution = .ubuntu2404
        let recorder = NetworkConfigRecorder()
        let bundle = try VMFactory(paths: env.paths, runner: recorder).createLinux(request)
        #expect(try bundle.readConfig().distribution == .ubuntu2404)
        let userData = try #require(recorder.userData)
        #expect(userData.contains(GuestTimeSync.holdBootCommand))
        #expect(!userData.contains("chrony"))
        #expect(userData.contains(UbuntuQuiet.bootCommand))
    }

    /// The disk is compared with the qcow2's virtual size, not with its file size.
    @Test func qcow2DiskSmallerThanVirtualSizeIsRejectedWithoutBundle() throws {
        let env = try Env()
        defer { env.cleanup() }
        let qcow2 = env.tmp.appendingPathComponent("ubuntu.img")
        var fixture = Qcow2ImageTests.Fixture()
        fixture.virtualSize = 8 * mib
        try Data(fixture.bytes()).write(to: qcow2)
        #expect(throws: NidoError.self) {
            try VMFactory(paths: env.paths, runner: SeedRunner(status: 0))
                .createLinux(try env.request(disk: 4 * mib, image: qcow2))
        }
        #expect((try? VMBundle.list(paths: env.paths))?.isEmpty ?? true)
    }

    /// A damaged qcow2 leaves no bundle behind.
    @Test func damagedQcow2LeavesNoBundle() throws {
        let env = try Env()
        defer { env.cleanup() }
        let qcow2 = env.tmp.appendingPathComponent("ubuntu.img")
        var fixture = Qcow2ImageTests.Fixture()
        fixture.firstEntry = 1 << 20 | 1 << 63
        try Data(fixture.bytes()).write(to: qcow2)
        #expect(throws: NidoError.unsupportedDiskImage("cluster fuori dal file")) {
            try VMFactory(paths: env.paths, runner: SeedRunner(status: 0))
                .createLinux(try env.request(disk: 4 * mib, image: qcow2))
        }
        #expect((try? VMBundle.list(paths: env.paths))?.isEmpty ?? true)
    }
}
