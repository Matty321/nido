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

/// gvproxy stand-in that never has a frame.
private final class SilentUplink: EgressUplink, @unchecked Sendable {
    let gateway: UInt32 = 0xC0A8_4201
    let mask: UInt32 = 0xFFFF_FF00
    let guestAddress: UInt32? = nil
    let gatewayMAC: EgressMAC? = nil
    let maxPacketSize = 1514
    func onPacketsAvailable(_ handler: @escaping () -> Void) {}
    func onLost(_ handler: @escaping (String) -> Void) {}
    func read(into buffers: [UnsafeMutableRawBufferPointer]) -> [Int] { [] }
    func write(_ frames: [UnsafeRawBufferPointer]) {}
    func stop() {}
}

private struct Fixture {
    let tmp: URL
    let bundle: VMBundle
    let config: VMConfig
    let console: FileHandle
    init() throws {
        // Not in the temp directory: /private (the real /tmp and /var) cannot be shared.
        tmp = URL(fileURLWithPath: "/Users/Shared", isDirectory: true)
            .appendingPathComponent("nido-tests-lcb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let image = tmp.appendingPathComponent("base.img")
        try Data(count: Int(mib)).write(to: image)
        let factory = VMFactory(paths: NidoPaths(root: tmp.appendingPathComponent("VMs")), runner: SeedRunner())
        bundle = try factory.createLinux(
            LinuxVMRequest(
                name: try VMName("vm1"), baseImage: image, cpuCount: 2,
                memoryBytes: 2048 * mib, diskBytes: 4 * mib, publicKey: validKey))
        // On Apple's NAT: these tests build the machine without starting vmnet (the controlled
        // network has its own tests).
        config = try bundle.updateConfig { $0.controlledNetwork = false }
        let log = tmp.appendingPathComponent("console.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        console = try FileHandle(forWritingTo: log)
    }
    func cleanup() {
        try? console.close()
        try? FileManager.default.removeItem(at: tmp) }
}

/// Whether this process may validate/create virtual machines (`swift test` runs unsigned, without
/// the `com.apple.security.virtualization` entitlement; a signed host such as the app's tests has it).
let canCreateVirtualMachines: Bool = {
    do {
        try VZVirtualMachineConfiguration().validate()
        return true
    } catch let error as NSError {
        return !(error.localizedFailureReason ?? "").contains("entitlement")
    }
}()

/// True when no folder of the Mac is shared: the `nido` device is always attached (so the app can
/// add a folder to a running VM), but its share is empty; nothing else shares a directory.
func hasNoSharedDirectories(_ configuration: VZVirtualMachineConfiguration) -> Bool {
    configuration.directorySharingDevices.allSatisfy { device in
        guard let fs = device as? VZVirtioFileSystemDeviceConfiguration, fs.tag == SharedFolder.tag,
            let share = fs.share as? VZMultipleDirectoryShare
        else { return false }
        return share.directories.isEmpty
    }
}

@Suite(.italian) struct LinuxConfigurationBuilderTests {
    @Test func uncontrolledVMKeepsAppleNAT() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        #expect(f.config.controlledNetwork == false)
        for controlled in [nil, false] as [Bool?] {
            var config = f.config
            config.controlledNetwork = controlled
            let built = try LinuxConfigurationBuilder.make(bundle: f.bundle, config: config, console: f.console)
            #expect(built.configuration.networkDevices.first?.attachment is VZNATNetworkDeviceAttachment)
            #expect(built.egressRelay == nil)
        }
    }

    /// vmnet refused: the VM gets a relay attachment that leads nowhere (never Apple's NAT), and
    /// a warning says it has no network.
    @Test func controlledNetworkFailsClosed() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        var config = f.config
        config.controlledNetwork = true
        struct Refused: Error {}
        let built = try LinuxConfigurationBuilder.make(
            bundle: f.bundle, config: config, console: f.console,
            egress: EgressRelay.Options(startUplink: { _ in throw Refused() }))
        let relay = try #require(built.egressRelay)
        defer { relay.shutdownAndWait() }
        let net = try #require(built.configuration.networkDevices.first)
        #expect(net.attachment is VZFileHandleNetworkDeviceAttachment)
        #expect((net.attachment as? VZFileHandleNetworkDeviceAttachment)?.fileHandle === relay.guestHandle)
        #expect(net.macAddress.string == config.macAddress)
        #expect(relay.startFailure != nil)
        #expect(built.warnings.contains { $0.hasPrefix("Rete controllata non avviata") })
    }

    /// egress.log cannot be opened (here a planted symlink): the network still runs with every
    /// block in force, the relay says why, and the warning tells the window (and `nido start`).
    @Test func unopenableEgressLogIsAWarning() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        var config = f.config
        config.controlledNetwork = true
        let target = f.tmp.appendingPathComponent("elsewhere.log")
        try FileManager.default.createSymbolicLink(at: f.bundle.egressLogURL, withDestinationURL: target)
        let built = try LinuxConfigurationBuilder.make(
            bundle: f.bundle, config: config, console: f.console,
            egress: EgressRelay.Options(startUplink: { _ in SilentUplink() }))
        let relay = try #require(built.egressRelay)
        defer { relay.shutdownAndWait() }
        #expect(relay.startFailure == nil)
        #expect(relay.logFailure != nil)
        #expect(built.warnings.contains(EgressRelay.logUnavailableWarning))
        #expect(EgressRelay.logUnavailableWarning
            == "Registro di rete non disponibile: i blocchi restano attivi ma non vengono registrati né notificati.")
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func linuxConfigHasVsock() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        for display in [nil, DisplaySpec(widthInPixels: 800, heightInPixels: 600)] {
            let configuration = try LinuxConfigurationBuilder.make(
                bundle: f.bundle, config: f.config, console: f.console, display: display).configuration
            #expect(configuration.socketDevices.count == 1)
            #expect(configuration.socketDevices.first is VZVirtioSocketDeviceConfiguration)
        }
        let serial = try SerialConsole(logURL: f.tmp.appendingPathComponent("serial.log"))
        defer { serial.close() }
        let app = try LinuxConfigurationBuilder.make(
            bundle: f.bundle, config: f.config, serialConsole: serial).configuration
        #expect(app.socketDevices.count == 1)
    }

    @Test(.enabled(if: canCreateVirtualMachines, "needs the virtualization entitlement"))
    func noFoldersStillAttachesAnEmptyValidNidoDevice() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let built = try LinuxConfigurationBuilder.make(bundle: f.bundle, config: f.config, console: f.console)
        try built.configuration.validate()
        #expect(built.configuration.directorySharingDevices.count == 1)
        #expect(hasNoSharedDirectories(built.configuration))
        #expect(built.attachedShareNames.isEmpty)
        #expect(built.warnings.isEmpty)
    }

    @Test func headlessConfigurationUnchanged() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let configuration = try LinuxConfigurationBuilder.make(
            bundle: f.bundle, config: f.config, console: f.console, display: nil).configuration
        #expect(configuration.graphicsDevices.isEmpty)
        #expect(configuration.keyboards.isEmpty)
        #expect(configuration.pointingDevices.isEmpty)
        // No shared folders, no Rosetta: no directory sharing device, nothing to warn about.
        #expect(hasNoSharedDirectories(configuration))
        #expect(try LinuxConfigurationBuilder.make(
            bundle: f.bundle, config: f.config, console: f.console, display: nil).warnings.isEmpty)
    }

    @Test func headlessSerialPortIsWriteOnly() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let configuration = try LinuxConfigurationBuilder.make(
            bundle: f.bundle, config: f.config, console: f.console, display: nil).configuration
        let attachment = configuration.serialPorts.first?.attachment as? VZFileHandleSerialPortAttachment
        #expect(configuration.serialPorts.first is VZVirtioConsoleDeviceSerialPortConfiguration)
        #expect(attachment?.fileHandleForReading == nil)
        #expect(attachment?.fileHandleForWriting === f.console)
    }

    @Test func serialConsoleIsBidirectionalAndHeadless() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let serial = try SerialConsole(logURL: f.tmp.appendingPathComponent("serial.log"))
        defer { serial.close() }
        let configuration = try LinuxConfigurationBuilder.make(
            bundle: f.bundle, config: f.config, serialConsole: serial, display: nil).configuration
        #expect(configuration.serialPorts.count == 1)
        #expect(configuration.serialPorts.first is VZVirtioConsoleDeviceSerialPortConfiguration)
        let attachment = configuration.serialPorts.first?.attachment as? VZFileHandleSerialPortAttachment
        #expect(attachment?.fileHandleForReading === serial.guestReadHandle)
        #expect(attachment?.fileHandleForWriting === serial.guestWriteHandle)
        #expect(configuration.graphicsDevices.isEmpty)
        #expect(configuration.keyboards.isEmpty)
        #expect(configuration.pointingDevices.isEmpty)
        #expect(configuration.storageDevices.count == 2)
        #expect(configuration.networkDevices.count == 1)
    }

    @Test func displayAddsGraphicsAndInput() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let configuration = try LinuxConfigurationBuilder.make(
            bundle: f.bundle, config: f.config, console: f.console,
            display: DisplaySpec(widthInPixels: 1280, heightInPixels: 800)).configuration
        #expect(configuration.graphicsDevices.count == 1)
        let graphics = configuration.graphicsDevices[0] as? VZVirtioGraphicsDeviceConfiguration
        #expect(graphics?.scanouts.count == 1)
        #expect(graphics?.scanouts[0].widthInPixels == 1280)
        #expect(graphics?.scanouts[0].heightInPixels == 800)
        #expect(configuration.keyboards.count == 1)
        #expect(configuration.keyboards[0] is VZUSBKeyboardConfiguration)
        #expect(configuration.pointingDevices.count == 1)
        #expect(configuration.pointingDevices[0] is VZUSBScreenCoordinatePointingDeviceConfiguration)
    }

    @Test func linuxDiskUsesCachedFull() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let configuration = try LinuxConfigurationBuilder.make(
            bundle: f.bundle, config: f.config, console: f.console).configuration
        let disk = try #require(configuration.storageDevices[0].attachment as? VZDiskImageStorageDeviceAttachment)
        #expect(disk.cachingMode == .cached)
        #expect(disk.synchronizationMode == .full)
        #expect(!disk.isReadOnly)
    }

    @Test func buildsMinimalSurfaceConfiguration() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let configuration = try LinuxConfigurationBuilder.make(
            bundle: f.bundle, config: f.config, console: f.console).configuration

        #expect(configuration.cpuCount == f.config.cpuCount)
        #expect(configuration.memorySize == f.config.memoryBytes)
        #expect(configuration.bootLoader is VZEFIBootLoader)
        #expect(configuration.platform is VZGenericPlatformConfiguration)

        #expect(configuration.storageDevices.count == 2)
        let disk = configuration.storageDevices[0].attachment as? VZDiskImageStorageDeviceAttachment
        let seed = configuration.storageDevices[1].attachment as? VZDiskImageStorageDeviceAttachment
        #expect(disk?.isReadOnly == false)
        #expect(seed?.isReadOnly == true)

        #expect(configuration.networkDevices.count == 1)
        let net = configuration.networkDevices[0]
        #expect(net.attachment is VZNATNetworkDeviceAttachment)
        #expect(net.macAddress.string == f.config.macAddress)

        #expect(configuration.entropyDevices.count == 1)
        #expect(configuration.memoryBalloonDevices.count == 1)
        #expect(configuration.serialPorts.count == 1)
        #expect(hasNoSharedDirectories(configuration))
        #expect(configuration.socketDevices.count == 1)
        #expect(configuration.audioDevices.isEmpty)
        #expect(configuration.graphicsDevices.isEmpty)
        #expect(configuration.keyboards.isEmpty)
        #expect(configuration.pointingDevices.isEmpty)
        #expect(configuration.usbControllers.isEmpty)
    }

    @Test(.disabled("requires virtualization entitlement; covered by scripts/integration-linux.sh"))
    func validateIsAccepted() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let configuration = try LinuxConfigurationBuilder.make(
            bundle: f.bundle, config: f.config, console: f.console).configuration
        try configuration.validate()
    }

    @Test func invalidMacAddressIsRejected() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        var bad = f.config
        bad.macAddress = "not-a-mac"
        #expect(throws: NidoError.invalidResources("indirizzo MAC non valido")) {
            try LinuxConfigurationBuilder.make(bundle: f.bundle, config: bad, console: f.console)
        }
    }

    @Test func invalidMachineIdentifierIsRejected() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try Data("garbage".utf8).write(to: f.bundle.machineIdentifierURL)
        #expect(throws: NidoError.invalidResources("identificatore della macchina non valido")) {
            try LinuxConfigurationBuilder.make(bundle: f.bundle, config: f.config, console: f.console)
        }
    }

    // MARK: - Inner file checks

    private static let innerFiles = ["config.json", "disk.img", "nvram.efi", "machine-id.bin", "seed.iso"]

    @Test(arguments: innerFiles)
    func symlinkedInnerFileIsRefused(_ name: String) throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let inner = f.bundle.url.appendingPathComponent(name)
        let moved = f.tmp.appendingPathComponent("moved-\(name)")
        try FileManager.default.moveItem(at: inner, to: moved)
        try FileManager.default.createSymbolicLink(at: inner, withDestinationURL: moved)
        #expect(throws: NidoError.unsafePath(inner.path)) {
            try LinuxConfigurationBuilder.make(bundle: f.bundle, config: f.config, console: f.console)
        }
    }

    @Test func hardLinkedDiskIsRefused() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try FileManager.default.linkItem(at: f.bundle.diskURL, to: f.tmp.appendingPathComponent("alias.img"))
        #expect(throws: NidoError.unsafePath(f.bundle.diskURL.path)) {
            try LinuxConfigurationBuilder.make(bundle: f.bundle, config: f.config, console: f.console)
        }
    }

    @Test func missingInnerFileIsRefused() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try FileManager.default.removeItem(at: f.bundle.seedURL)
        #expect(throws: NidoError.unsafePath(f.bundle.seedURL.path)) {
            try LinuxConfigurationBuilder.make(bundle: f.bundle, config: f.config, console: f.console)
        }
    }

    @MainActor
    @Test func sessionRefusesSymlinkedDiskBeforeBuilding() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let moved = f.tmp.appendingPathComponent("moved-disk.img")
        try FileManager.default.moveItem(at: f.bundle.diskURL, to: moved)
        try FileManager.default.createSymbolicLink(at: f.bundle.diskURL, withDestinationURL: moved)
        #expect(throws: NidoError.unsafePath(f.bundle.diskURL.path)) {
            _ = try VMSession(bundle: f.bundle)
        }
    }

    /// The app's init without a console is for macOS guests only: a Linux guest needs one.
    @MainActor
    @Test func appSessionOfLinuxNeedsASerialConsole() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        #expect(throws: NidoError.serialConsoleRequired) {
            _ = try VMSession(bundle: f.bundle, serialConsole: nil)
        }
    }
}

extension LinuxConfigurationBuilderTests {
    /// The CLI's console now goes through a `SerialConsole` (capped console.log, sanitised
    /// `--console`): the guest only gets its write end, the device set stays the headless one.
    @Test func cliConsoleThroughSerialConsoleKeepsTheHeadlessDeviceSet() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let serial = try SerialConsole(logURL: f.tmp.appendingPathComponent("serial.log"), deliversOutput: false)
        defer { serial.close() }
        let configuration = try LinuxConfigurationBuilder.make(
            bundle: f.bundle, config: f.config, console: serial.guestWriteHandle, display: nil).configuration
        let attachment = configuration.serialPorts.first?.attachment as? VZFileHandleSerialPortAttachment
        #expect(configuration.serialPorts.count == 1)
        #expect(configuration.serialPorts.first is VZVirtioConsoleDeviceSerialPortConfiguration)
        #expect(attachment?.fileHandleForReading == nil)
        #expect(attachment?.fileHandleForWriting === serial.guestWriteHandle)
        #expect(configuration.graphicsDevices.isEmpty)
        #expect(configuration.keyboards.isEmpty)
        #expect(configuration.pointingDevices.isEmpty)
        #expect(configuration.storageDevices.count == 2)
        #expect(configuration.networkDevices.count == 1)
        #expect(configuration.entropyDevices.count == 1)
        #expect(configuration.memoryBalloonDevices.count == 1)
        #expect(configuration.socketDevices.count == 1)
        #expect(hasNoSharedDirectories(configuration))
        #expect(configuration.audioDevices.isEmpty)
    }
}

extension LinuxConfigurationBuilderTests {
    private func makeFolder(_ f: Fixture, _ name: String) throws -> URL {
        let url = f.tmp.appendingPathComponent("shares/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func builderAddsOneVirtioFSDevice() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let docs = try makeFolder(f, "docs")
        let work = try makeFolder(f, "work")
        var config = f.config
        config.sharedFolders = [
            SharedFolder(name: "docs", hostPath: docs.path, readOnly: true),
            SharedFolder(name: "work", hostPath: work.path, readOnly: false),
        ]
        let built = try LinuxConfigurationBuilder.make(bundle: f.bundle, config: config, console: f.console)
        #expect(built.warnings.isEmpty)
        #expect(built.configuration.directorySharingDevices.count == 1)
        let device = built.configuration.directorySharingDevices.first as? VZVirtioFileSystemDeviceConfiguration
        #expect(device?.tag == "nido")
        let share = device?.share as? VZMultipleDirectoryShare
        #expect(share?.directories.count == 2)
        #expect(share?.directories["docs"]?.isReadOnly == true)
        #expect(share?.directories["work"]?.isReadOnly == false)
        #expect(share?.directories["docs"]?.url.path == realPath(docs))
        // The rest of the device set is unchanged.
        #expect(built.configuration.storageDevices.count == 2)
        #expect(built.configuration.graphicsDevices.isEmpty)
    }

    @Test func missingFolderIsSkippedWithWarning() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let docs = try makeFolder(f, "docs")
        var config = f.config
        config.sharedFolders = [
            SharedFolder(name: "docs", hostPath: docs.path, readOnly: true),
            SharedFolder(name: "gone", hostPath: f.tmp.appendingPathComponent("gone").path, readOnly: true),
        ]
        let built = try LinuxConfigurationBuilder.make(bundle: f.bundle, config: config, console: f.console)
        let share = (built.configuration.directorySharingDevices.first as? VZVirtioFileSystemDeviceConfiguration)?
            .share as? VZMultipleDirectoryShare
        #expect(share?.directories.keys.sorted() == ["docs"])
        #expect(built.warnings.count == 1)
        #expect(built.warnings.first?.contains("gone") == true)
    }

    @Test func onlyMissingFoldersMeansNoDevice() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        var config = f.config
        config.sharedFolders = [SharedFolder(name: "gone", hostPath: "/nonexistent-nido", readOnly: true)]
        let built = try LinuxConfigurationBuilder.make(bundle: f.bundle, config: config, console: f.console)
        #expect(hasNoSharedDirectories(built.configuration))
        #expect(built.warnings.count == 1)
    }

    @Test func folderMovedIntoForbiddenPlaceIsSkipped() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        // A share whose path now resolves inside the VM root (e.g. replaced by a symlink).
        let link = f.tmp.appendingPathComponent("sneaky")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.bundle.url)
        var config = f.config
        config.sharedFolders = [
            SharedFolder(name: "sneaky", hostPath: link.path, readOnly: true),
            SharedFolder(name: "bad name", hostPath: try makeFolder(f, "x").path, readOnly: true),
        ]
        let built = try LinuxConfigurationBuilder.make(bundle: f.bundle, config: config, console: f.console)
        #expect(hasNoSharedDirectories(built.configuration))
        #expect(built.warnings.count == 2)
    }

    /// Aliases of the home and of the data volume in config.json (hand-edited or from before the
    /// fix) are left out at start with a warning, never shared.
    @Test func aliasedHomeIsSkippedAtStart() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var config = f.config
        config.sharedFolders = [
            SharedFolder(name: "home", hostPath: "/System/Volumes/Data\(home)", readOnly: true),
            SharedFolder(name: "lib", hostPath: "/System/Volumes/Data\(home)/Library", readOnly: false),
            SharedFolder(name: "data", hostPath: "/System/Volumes/Data", readOnly: false),
            SharedFolder(name: "nf", hostPath: "/.nofollow\(home)", readOnly: true),
            SharedFolder(name: "sys", hostPath: "/System", readOnly: true),
            SharedFolder(name: "tmp", hostPath: "/tmp", readOnly: false),
        ]
        let built = try LinuxConfigurationBuilder.make(bundle: f.bundle, config: config, console: f.console)
        #expect(hasNoSharedDirectories(built.configuration))
        #expect(built.warnings.count == 6)
    }

    /// The cache passed in (the app's) is protected at start, not only the default one.
    @Test func givenImageCacheIsProtectedAtStart() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let cache = try makeFolder(f, "cache")
        let inside = try makeFolder(f, "cache/images")
        var config = f.config
        config.sharedFolders = [SharedFolder(name: "img", hostPath: inside.path, readOnly: true)]
        let built = try LinuxConfigurationBuilder.make(
            bundle: f.bundle, config: config, console: f.console, imageCache: cache)
        #expect(hasNoSharedDirectories(built.configuration))
        #expect(built.warnings.count == 1)
        #expect(built.warnings.first?.contains("esclusa") == true)
    }
}

/// R-M3A-23: a shared folder replaced by a symlink to another place (even an allowed one) is not
/// followed: the path it resolves to must still be the one saved when it was added.
extension LinuxConfigurationBuilderTests {
    @Test func folderSwappedForASymlinkToAnAllowedPlaceIsExcluded() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let team = try makeFolder(f, "team")
        let documents = try makeFolder(f, "documents")
        let stored = try SharedFolder.validate(
            hostPath: team.path, paths: NidoPaths(root: f.bundle.url.deletingLastPathComponent()),
            imageCache: ImageStore.defaultCacheRoot()).path
        var config = f.config
        config.sharedFolders = [SharedFolder(name: "team", hostPath: stored, readOnly: false)]
        // Someone with write access to the parent swaps the folder for a symlink.
        try FileManager.default.removeItem(at: team)
        try FileManager.default.createSymbolicLink(at: team, withDestinationURL: documents)

        let built = try LinuxConfigurationBuilder.make(bundle: f.bundle, config: config, console: f.console)
        #expect(hasNoSharedDirectories(built.configuration))
        #expect(built.attachedShareNames.isEmpty)
        #expect(built.warnings.count == 1)
        #expect(built.warnings.first?.contains("team") == true)
        #expect(built.warnings.first?.contains("esclusa") == true)
    }

    /// The same folder saved with another case still matches (APFS is case-insensitive).
    @Test func folderSavedWithAnotherCaseStillMatches() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let docs = try makeFolder(f, "docs")
        let stored = try SharedFolder.validate(
            hostPath: docs.path, paths: NidoPaths(root: f.bundle.url.deletingLastPathComponent()),
            imageCache: ImageStore.defaultCacheRoot()).path
        var config = f.config
        config.sharedFolders = [SharedFolder(name: "docs", hostPath: stored.uppercased(), readOnly: true)]
        let built = try LinuxConfigurationBuilder.make(bundle: f.bundle, config: config, console: f.console)
        #expect(built.warnings.isEmpty)
        #expect(built.attachedShareNames == ["docs"])
    }

    /// A warning never carries control characters of a hand-edited config.json to the terminal.
    @Test func warningsEscapeControlCharacters() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        var config = f.config
        config.sharedFolders = [SharedFolder(name: "gone", hostPath: "/nonexistent-\u{1B}]52;c;x\u{07}", readOnly: true)]
        let built = try LinuxConfigurationBuilder.make(bundle: f.bundle, config: config, console: f.console)
        #expect(built.warnings.count == 1)
        #expect(built.warnings.first?.unicodeScalars.contains { $0.properties.generalCategory == .control } == false)
    }
}

extension LinuxConfigurationBuilderTests {
    @MainActor private static func nidoDevice(_ session: VMSession) -> VZVirtioFileSystemDevice? {
        session.virtualMachine.directorySharingDevices
            .compactMap { $0 as? VZVirtioFileSystemDevice }.first { $0.tag == SharedFolder.tag }
    }

    @Test(.enabled(if: canCreateVirtualMachines, "needs the virtualization entitlement"))
    @MainActor func socketDeviceIsThePlainFirstVsockDevice() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let session = try VMSession(bundle: f.bundle, imageCache: f.tmp.appendingPathComponent("cache"))
        defer { session.serialConsole?.close() }
        #expect(session.socketDevice != nil)
        #expect(session.socketDevice === session.virtualMachine.socketDevices.first)
    }

    @Test(.enabled(if: canCreateVirtualMachines, "needs the virtualization entitlement"))
    @MainActor func updateSharedFoldersReplacesShare() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let cache = f.tmp.appendingPathComponent("cache")
        let docs = f.tmp.appendingPathComponent("docs", isDirectory: true)
        let work = f.tmp.appendingPathComponent("work", isDirectory: true)
        for url in [docs, work] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        var config = f.config
        config.sharedFolders = [SharedFolder(name: "docs", hostPath: docs.path, readOnly: true)]
        try f.bundle.writeConfig(config)

        let session = try VMSession(bundle: f.bundle, imageCache: cache)
        defer { session.serialConsole?.close() }
        let device = try #require(Self.nidoDevice(session))
        func share() -> [String: VZSharedDirectory] { (device.share as? VZMultipleDirectoryShare)?.directories ?? [:] }
        #expect(share().keys.sorted() == ["docs"])
        #expect(share()["docs"]?.isReadOnly == true)

        // Back to read-only, a new folder with write access, and one left out with a warning.
        let warnings = try session.updateSharedFolders([
            SharedFolder(name: "docs", hostPath: docs.path, readOnly: false),
            SharedFolder(name: "work", hostPath: work.path, readOnly: true),
            SharedFolder(name: "gone", hostPath: f.tmp.appendingPathComponent("gone").path, readOnly: true),
        ])
        #expect(share().keys.sorted() == ["docs", "work"])
        #expect(share()["docs"]?.isReadOnly == false)
        #expect(share()["work"]?.isReadOnly == true)
        #expect(warnings.count == 1)

        // The hash a suspend stores follows the live change (it covers the attached shares).
        var live = config
        live.sharedFolders = [
            SharedFolder(name: "docs", hostPath: docs.path, readOnly: false),
            SharedFolder(name: "work", hostPath: work.path, readOnly: true),
        ]
        #expect(session.attachedStateHash == live.effectiveStateHash(attachedShareNames: ["docs", "work"], rosettaAttached: false))
        #expect(session.attachedStateHash != config.effectiveStateHash(attachedShareNames: ["docs"], rosettaAttached: false))

        // Revoked: an empty list leaves the device with an empty share.
        #expect(try session.updateSharedFolders([]).isEmpty)
        #expect(device.share is VZMultipleDirectoryShare)
        #expect(share().isEmpty)
        var none = config
        none.sharedFolders = []
        #expect(session.attachedStateHash == none.effectiveStateHash(attachedShareNames: [], rosettaAttached: false))
    }
}
