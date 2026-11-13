// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import Virtualization
@testable import NidoCore

private let validKey =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOO97YvP4YWGQwUFq+UeOnyDKkD29RZ8VdmeuGgPzeS6"
private let mib: UInt64 = 1024 * 1024

private struct SeedRunner: ProcessRunner {
    func run(executable: URL, arguments: [String]) throws -> ProcessResult {
        if arguments.count > 6 {
            FileManager.default.createFile(
                atPath: arguments[6], contents: Data(count: 4096), attributes: [.posixPermissions: 0o644])
        }
        return ProcessResult(status: 0, stdout: Data(), stderr: Data())
    }
}

/// The standard x86_64 ELF binfmt_misc magic and mask (ELF64, little endian, e_type
/// EXEC or DYN, e_machine 0x3e), as in Apple's "Running Intel Binaries in Linux VMs with Rosetta".
private let x86Magic =
    #"\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00"#
private let x86Mask =
    #"\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff"#

@Suite(.italian) struct RosettaSupportTests {
    private struct Fixture {
        let tmp: URL
        let bundle: VMBundle
        let console: FileHandle

        init() throws {
            tmp = URL(fileURLWithPath: "/Users/Shared", isDirectory: true)
                .appendingPathComponent("nido-tests-rosetta-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let image = tmp.appendingPathComponent("base.img")
            try Data(count: Int(mib)).write(to: image)
            let factory = VMFactory(paths: NidoPaths(root: tmp.appendingPathComponent("VMs")), runner: SeedRunner())
            bundle = try factory.createLinux(
                LinuxVMRequest(
                    name: try VMName("vm1"), baseImage: image, cpuCount: 2,
                    memoryBytes: 2048 * mib, diskBytes: 4 * mib, publicKey: validKey))
            // Apple's NAT: these tests never start vmnet.
            try bundle.updateConfig { $0.controlledNetwork = false }
            let log = tmp.appendingPathComponent("console.log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            console = try FileHandle(forWritingTo: log)
        }

        func build(rosetta: Bool, state: RosettaState) throws -> GuestConfiguration {
            var config = try bundle.readConfig()
            config.rosetta = rosetta
            return try LinuxConfigurationBuilder.make(
                bundle: bundle, config: config, console: console, rosettaState: state)
        }

        func cleanup() {
            try? console.close()
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    private static func rosettaDevices(_ c: VZVirtualMachineConfiguration) -> [VZVirtioFileSystemDeviceConfiguration] {
        c.directorySharingDevices.compactMap { $0 as? VZVirtioFileSystemDeviceConfiguration }
            .filter { $0.tag == RosettaSupport.tag }
    }

    @Test func rosettaDeviceOnlyWhenInstalled() throws {
        let f = try Fixture()
        defer { f.cleanup() }

        // Rosetta turned off: never a device, nothing to say, whatever the Mac has.
        for state in [RosettaState.unsupported, .notInstalled, .installed] {
            let built = try f.build(rosetta: false, state: state)
            #expect(hasNoSharedDirectories(built.configuration))
            #expect(built.warnings.isEmpty)
        }

        // Turned on but not available: no device, the VM starts anyway and the warning says why.
        let unsupported = try f.build(rosetta: true, state: .unsupported)
        #expect(Self.rosettaDevices(unsupported.configuration).isEmpty)
        #expect(unsupported.warnings.count == 1)
        #expect(unsupported.warnings.first?.contains("non è disponibile su questo Mac") == true)

        let notInstalled = try f.build(rosetta: true, state: .notInstalled)
        #expect(Self.rosettaDevices(notInstalled.configuration).isEmpty)
        #expect(notInstalled.warnings.count == 1)
        #expect(notInstalled.warnings.first?.contains("non è installata") == true)
        #expect(notInstalled.warnings.first?.contains("nido rosetta install") == true)

        // Installed: one VirtioFS device, tag `rosetta`, backed by the Rosetta share.
        let installed = try f.build(rosetta: true, state: .installed)
        if RosettaState.current == .installed {
            let devices = Self.rosettaDevices(installed.configuration)
            #expect(devices.count == 1)
            #expect(devices.first?.share is VZLinuxRosettaDirectoryShare)
            #expect(installed.warnings.isEmpty)
        } else {
            // The injected state says installed, but the share cannot be made on this Mac:
            // still no failure, a warning instead.
            #expect(Self.rosettaDevices(installed.configuration).isEmpty)
            #expect(installed.warnings.count == 1)
        }
    }

    @Test(.enabled(if: RosettaState.current == .installed, "Rosetta is not installed on this Mac"))
    func rosettaSitsNextToSharedFolders() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let folder = f.tmp.appendingPathComponent("Progetti", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var config = try f.bundle.readConfig()
        config.rosetta = true
        config.sharedFolders = [SharedFolder(name: "Progetti", hostPath: folder.path, readOnly: true)]
        let built = try LinuxConfigurationBuilder.make(
            bundle: f.bundle, config: config, console: f.console,
            imageCache: f.tmp.appendingPathComponent("cache"), rosettaState: .installed)
        let tags = built.configuration.directorySharingDevices
            .compactMap { ($0 as? VZVirtioFileSystemDeviceConfiguration)?.tag }
        #expect(tags == [SharedFolder.tag, RosettaSupport.tag])
        #expect(built.warnings.isEmpty)
    }

    @Test func cloudInitRegistersBinfmt() throws {
        #expect(RosettaSupport.binfmtRule
            == ":rosetta:M::\(x86Magic):\(x86Mask):/media/rosetta/rosetta:F")
        #expect(RosettaSupport.binfmtConfigPath.hasPrefix("/etc/"))

        let ud = CloudInitSeed.userData(username: "nido", publicKey: validKey)
        // No fstab line for the tag: on a VM with Rosetta off its mount unit would fail at
        // every boot. The unit mounts it instead.
        #expect(!ud.contains(#"["rosetta""#))
        // The rule is written verbatim (YAML literal block: backslashes are kept).
        #expect(ud.contains("  - path: \(RosettaSupport.binfmtConfigPath)\n"))
        #expect(ud.contains("      \(RosettaSupport.binfmtRule)\n"))
        // Registered by a unit that mounts the tag read-only on /media/rosetta and is skipped
        // (ExecCondition) when there is no such tag, after systemd-binfmt's own flush.
        #expect(ud.contains("  - path: \(RosettaSupport.unitPath)\n"))
        for line in RosettaSupport.unitText.split(separator: "\n") {
            #expect(ud.contains("      \(line)\n"))
        }
        #expect(RosettaSupport.unitText.contains(
            #"ExecCondition=/bin/sh -c "mkdir -p /media/rosetta && { mountpoint -q /media/rosetta || mount -t virtiofs -o ro,nosuid,nodev rosetta /media/rosetta; }""#))
        #expect(RosettaSupport.unitText.contains("After=local-fs.target systemd-binfmt.service"))
        #expect(RosettaSupport.unitText.contains("PartOf=systemd-binfmt.service"))
        #expect(RosettaSupport.unitText.contains(
            "ExecStart=/usr/lib/systemd/systemd-binfmt \(RosettaSupport.binfmtConfigPath)"))
        #expect(ud.contains("runcmd:\n  - [systemctl, daemon-reload]\n  - [systemctl, enable, --now, nido-shares.service, nido-rosetta.service]\n"))
        #expect(RosettaSupport.unitText.contains("/usr/lib/systemd/systemd-binfmt"))

        // The one-time command for older VMs writes the same rule and unit.
        let legacy = RosettaSupport.legacyGuestCommand
        #expect(legacy.hasPrefix("sudo sh -c '"))
        #expect(legacy.contains(RosettaSupport.binfmtRule))
        #expect(!legacy.contains("fstab"))
        #expect(legacy.contains("systemctl enable --now nido-rosetta.service"))
        #expect(legacy.filter { $0 == "'" }.count == 2)  // one single-quoted sh -c script
    }

    @Test func legacyCommandWritesTheRuleAndUnitVerbatim() throws {
        let written = try filesWrittenByLegacyCommand(RosettaSupport.legacyGuestCommand)
        #expect(written == [
            RosettaSupport.binfmtConfigPath: RosettaSupport.binfmtRule + "\n",
            RosettaSupport.unitPath: RosettaSupport.unitText + "\n",
        ])
    }

    @Test func newVMsRegisterRosettaOldOnesNeedTheCommand() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        #expect(try f.bundle.readConfig().guestRegistersRosetta)
        let v1 = """
            {"cpuCount":2,"diskBytes":1,"guest":"linux","id":"8A1C2E4B-6D3F-4A5B-9C7D-0E1F2A3B4C5D",
             "macAddress":"02:00:00:00:00:01","memoryBytes":4294967296,"name":"a","schemaVersion":1}
            """
        #expect(try VMConfig.decode(Data(v1.utf8)).guestRegistersRosetta == false)
        // Not part of the machine: it never invalidates a saved state.
        var config = try f.bundle.readConfig()
        let hash = config.stateHash()
        config.guestRegistersRosetta.toggle()
        #expect(config.stateHash() == hash)
        #expect(try VMConfig.decode(try config.encoded()) == config)
    }

    @Test func stateTextsSayWhy() {
        #expect(RosettaState.installed.reason == nil)
        #expect(RosettaState.notInstalled.reason?.contains("non è installata") == true)
        #expect(RosettaState.unsupported.reason?.contains("non è disponibile") == true)
        #expect(RosettaState(VZLinuxRosettaAvailability.installed) == .installed)
        #expect(RosettaState(VZLinuxRosettaAvailability.notInstalled) == .notInstalled)
        #expect(RosettaState(VZLinuxRosettaAvailability.notSupported) == .unsupported)
    }
}
