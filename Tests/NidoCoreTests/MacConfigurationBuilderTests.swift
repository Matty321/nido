// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import Testing
import Virtualization
@testable import NidoCore

/// A complete macOS bundle (as `MacInstaller` leaves it, minus the installed system) in a root
/// under /Users/Shared (/private, the real /tmp and /var, cannot be shared).
struct MacFixture {
    let tmp: URL
    let paths: NidoPaths
    let bundle: VMBundle
    let config: VMConfig

    init() throws {
        tmp = URL(fileURLWithPath: "/Users/Shared", isDirectory: true)
            .appendingPathComponent("nido-tests-mcb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        paths = NidoPaths(root: tmp.appendingPathComponent("VMs", isDirectory: true))
        let config = VMConfig(
            id: UUID(), name: try VMName("mac"), guest: .macos, cpuCount: 2, memoryBytes: 4 << 30,
            diskBytes: 1 << 30, macAddress: VZMACAddress.randomLocallyAdministered().string,
            sshUser: "mattia", osVersion: "26.1")
        bundle = try VMBundle.create(config: config, paths: paths)
        self.config = config
        let fd = try PrivateFile.open(bundle.diskURL, flags: O_WRONLY | O_CREAT | O_EXCL, label: "disk.img")
        _ = ftruncate(fd, off_t(config.diskBytes))
        _ = Darwin.close(fd)
        let model = try #require(VZMacHardwareModel(dataRepresentation: testMacHardwareModel))
        _ = try VZMacAuxiliaryStorage(creatingStorageAt: bundle.auxiliaryStorageURL, hardwareModel: model, options: [])
        try MachineFileCopy.protect(bundle.auxiliaryStorageURL)
        try MachineFileCopy.writeNewFile(bundle.hardwareModelURL, data: testMacHardwareModel)
        try MachineFileCopy.writeNewFile(bundle.machineIdentifierURL, data: VZMacMachineIdentifier().dataRepresentation)
    }

    func folder(_ name: String) throws -> URL {
        let url = tmp.appendingPathComponent("shares/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: tmp)
    }
}

@Suite(.italian) struct MacConfigurationBuilderTests {
    /// A controlled macOS VM goes through Nido's relay like a Linux one; vmnet refused: the
    /// attachment leads nowhere (never Apple's NAT) and a warning says the VM has no network.
    @Test func controlledMacVMUsesTheRelayAndFailsClosed() throws {
        let f = try MacFixture()
        defer { f.cleanup() }
        var config = f.config
        config.controlledNetwork = true
        struct Refused: Error {}
        let built = try MacConfigurationBuilder.make(
            bundle: f.bundle, config: config, display: nil, imageCache: f.tmp.appendingPathComponent("cache"),
            egress: EgressRelay.Options(startUplink: { _ in throw Refused() }))
        let relay = try #require(built.egressRelay)
        defer { relay.shutdownAndWait() }
        let net = try #require(built.configuration.networkDevices.first)
        #expect(built.configuration.networkDevices.count == 1)
        #expect((net.attachment as? VZFileHandleNetworkDeviceAttachment)?.fileHandle === relay.guestHandle)
        #expect(net.macAddress.string == config.macAddress)
        #expect(relay.startFailure != nil)
        #expect(built.warnings.contains { $0.hasPrefix("Rete controllata non avviata") })
    }

    /// A relay already started by the caller (the app) is the one attached.
    @Test func controlledMacVMTakesTheStartedRelay() throws {
        let f = try MacFixture()
        defer { f.cleanup() }
        var config = f.config
        config.controlledNetwork = true
        struct Refused: Error {}
        let started = try EgressRelay(
            bundle: f.bundle, guestMAC: config.macAddress, options: .init(startUplink: { _ in throw Refused() }))
        defer { started.shutdownAndWait() }
        let built = try MacConfigurationBuilder.make(
            bundle: f.bundle, config: config, display: nil, imageCache: f.tmp.appendingPathComponent("cache"),
            relay: started)
        #expect(built.egressRelay === started)
        let net = try #require(built.configuration.networkDevices.first)
        #expect((net.attachment as? VZFileHandleNetworkDeviceAttachment)?.fileHandle === started.guestHandle)
    }

    @Test func uncontrolledMacVMKeepsAppleNAT() throws {
        let f = try MacFixture()
        defer { f.cleanup() }
        for controlled in [nil, false] as [Bool?] {
            var config = f.config
            config.controlledNetwork = controlled
            let built = try MacConfigurationBuilder.make(
                bundle: f.bundle, config: config, display: nil, imageCache: f.tmp.appendingPathComponent("cache"))
            #expect(built.configuration.networkDevices.first?.attachment is VZNATNetworkDeviceAttachment)
            #expect(built.egressRelay == nil)
        }
    }

    @Test func builderMacDevices() throws {
        let f = try MacFixture()
        defer { f.cleanup() }
        let built = try MacConfigurationBuilder.make(
            bundle: f.bundle, config: f.config, display: nil, imageCache: f.tmp.appendingPathComponent("cache"))
        let c = built.configuration
        #expect(built.warnings.isEmpty)
        #expect(!built.rosettaAttached)
        #expect(c.cpuCount == 2 && c.memorySize == 4 << 30)

        let platform = try #require(c.platform as? VZMacPlatformConfiguration)
        // Virtualization re-encodes the model: compare what it describes, not the bytes.
        let expected = try #require(VZMacHardwareModel(dataRepresentation: testMacHardwareModel))
        #expect(platform.hardwareModel.dataRepresentation == expected.dataRepresentation)
        #expect(platform.auxiliaryStorage?.url.path == f.bundle.auxiliaryStorageURL.path)
        #expect(platform.machineIdentifier.dataRepresentation == (try Data(contentsOf: f.bundle.machineIdentifierURL)))
        #expect(c.bootLoader is VZMacOSBootLoader)

        let graphics = try #require(c.graphicsDevices.first as? VZMacGraphicsDeviceConfiguration)
        #expect(c.graphicsDevices.count == 1)
        #expect(graphics.displays.count == 1)
        #expect(graphics.displays.first?.widthInPixels == 1920)
        #expect(graphics.displays.first?.heightInPixels == 1200)
        #expect(graphics.displays.first?.pixelsPerInch == 144)
        #expect(c.keyboards.count == 1 && c.keyboards.first is VZMacKeyboardConfiguration)
        #expect(c.pointingDevices.count == 1 && c.pointingDevices.first is VZMacTrackpadConfiguration)

        #expect(c.audioDevices.count == 1)
        let sound = try #require(c.audioDevices.first as? VZVirtioSoundDeviceConfiguration)
        #expect(sound.streams.count == 1)
        #expect(sound.streams.allSatisfy { $0 is VZVirtioSoundDeviceOutputStreamConfiguration })
        #expect(!sound.streams.contains { $0 is VZVirtioSoundDeviceInputStreamConfiguration })

        let network = try #require(c.networkDevices.first as? VZVirtioNetworkDeviceConfiguration)
        #expect(c.networkDevices.count == 1)
        #expect(network.attachment is VZNATNetworkDeviceAttachment)
        #expect(network.macAddress.string == f.config.macAddress)
        #expect(c.storageDevices.count == 1)
        let disk = try #require((c.storageDevices.first as? VZVirtioBlockDeviceConfiguration)?.attachment
            as? VZDiskImageStorageDeviceAttachment)
        #expect(disk.url.path == f.bundle.diskURL.path && !disk.isReadOnly)
        #expect(c.entropyDevices.count == 1)
        #expect(c.memoryBalloonDevices.count == 1)

        // No serial console, no vsock (the monitor and the AI bridge are Linux-only), no Rosetta.
        #expect(c.serialPorts.isEmpty)
        #expect(c.socketDevices.isEmpty)
        #expect(c.consoleDevices.isEmpty)
        // One automount device, empty: nothing of the Mac is shared by default.
        let shares = c.directorySharingDevices.compactMap { $0 as? VZVirtioFileSystemDeviceConfiguration }
        #expect(c.directorySharingDevices.count == 1)
        #expect(shares.first?.tag == VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
        #expect((shares.first?.share as? VZMultipleDirectoryShare)?.directories.isEmpty == true)
        #expect(built.attachedShareNames.isEmpty)
    }

    @Test func displaySpecSetsTheMacDisplay() throws {
        let f = try MacFixture()
        defer { f.cleanup() }
        let built = try MacConfigurationBuilder.make(
            bundle: f.bundle, config: f.config, display: DisplaySpec(widthInPixels: 2560, heightInPixels: 1600),
            imageCache: f.tmp.appendingPathComponent("cache"))
        let display = (built.configuration.graphicsDevices.first as? VZMacGraphicsDeviceConfiguration)?.displays.first
        #expect(display?.widthInPixels == 2560)
        #expect(display?.heightInPixels == 1600)
    }

    @Test func sharedFoldersUseTheAutomountTag() throws {
        let f = try MacFixture()
        defer { f.cleanup() }
        let docs = try f.folder("docs")
        let work = try f.folder("work")
        var config = f.config
        config.sharedFolders = [
            SharedFolder(name: "docs", hostPath: docs.path),
            SharedFolder(name: "work", hostPath: work.path, readOnly: false),
            SharedFolder(name: "gone", hostPath: f.tmp.appendingPathComponent("gone").path),
        ]
        let built = try MacConfigurationBuilder.make(
            bundle: f.bundle, config: config, display: nil, imageCache: f.tmp.appendingPathComponent("cache"))
        let device = try #require(
            built.configuration.directorySharingDevices.first as? VZVirtioFileSystemDeviceConfiguration)
        #expect(built.configuration.directorySharingDevices.count == 1)
        #expect(device.tag == VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
        let share = try #require(device.share as? VZMultipleDirectoryShare)
        #expect(share.directories.keys.sorted() == ["docs", "work"])
        #expect(share.directories["docs"]?.isReadOnly == true)
        #expect(share.directories["work"]?.isReadOnly == false)
        #expect(built.attachedShareNames == ["docs", "work"])
        #expect(built.warnings.count == 1)
        #expect(built.warnings.first?.contains("gone") == true)
    }

    @Test func builderRefusesALinuxConfig() throws {
        let f = try MacFixture()
        defer { f.cleanup() }
        var config = f.config
        config.guest = .linux
        #expect(throws: NidoError.self) {
            _ = try MacConfigurationBuilder.make(
                bundle: f.bundle, config: config, display: nil, imageCache: f.tmp.appendingPathComponent("cache"))
        }
    }

    @Test func builderRefusesAMissingAuxiliaryStorage() throws {
        let f = try MacFixture()
        defer { f.cleanup() }
        try FileManager.default.removeItem(at: f.bundle.auxiliaryStorageURL)
        #expect(throws: NidoError.unsafePath(f.bundle.auxiliaryStorageURL.path)) {
            _ = try MacConfigurationBuilder.make(
                bundle: f.bundle, config: f.config, display: nil, imageCache: f.tmp.appendingPathComponent("cache"))
        }
    }

    /// The Linux builder checks the Linux file set explicitly: a macOS bundle is refused.
    @Test func linuxBuilderRefusesAMacBundle() throws {
        let f = try MacFixture()
        defer { f.cleanup() }
        let log = f.tmp.appendingPathComponent("console.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let console = try FileHandle(forWritingTo: log)
        defer { try? console.close() }
        #expect(throws: NidoError.unsafePath(f.bundle.nvramURL.path)) {
            _ = try LinuxConfigurationBuilder.make(bundle: f.bundle, config: f.config, console: console)
        }
    }

    @Test(.enabled(if: canCreateVirtualMachines, "needs the virtualization entitlement"))
    func macConfigurationValidatesWhenEntitled() throws {
        let f = try MacFixture()
        defer { f.cleanup() }
        let built = try MacConfigurationBuilder.make(
            bundle: f.bundle, config: f.config, display: nil, imageCache: f.tmp.appendingPathComponent("cache"))
        try built.configuration.validate()
    }
}
