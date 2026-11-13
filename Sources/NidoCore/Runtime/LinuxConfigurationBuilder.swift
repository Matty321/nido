// SPDX-License-Identifier: Apache-2.0
import Foundation
import Virtualization

/// Size of the single virtio-gpu scanout of a VM with a window.
public struct DisplaySpec: Sendable, Equatable {
    public var widthInPixels: Int
    public var heightInPixels: Int

    public init(widthInPixels: Int, heightInPixels: Int) {
        self.widthInPixels = widthInPixels
        self.heightInPixels = heightInPixels
    }
}

/// A built configuration (Linux or macOS guest) and what the user should know about it (e.g. a
/// shared folder that is missing on the Mac and was left out).
public struct GuestConfiguration {
    public let configuration: VZVirtualMachineConfiguration
    /// Localized sentences, one per problem; empty when everything configured is there.
    public let warnings: [String]
    /// Names of the shared folders actually attached (those left out with a warning are not).
    public let attachedShareNames: [String]
    /// Whether the Rosetta device is actually attached.
    public let rosettaAttached: Bool
    /// The relay of a controlled network (`VMConfig.controlledNetwork`), already running; nil on
    /// Apple's NAT. Whoever keeps the configuration shuts it down when the machine is gone.
    public let egressRelay: EgressRelay?

    public init(
        configuration: VZVirtualMachineConfiguration, warnings: [String],
        attachedShareNames: [String] = [], rosettaAttached: Bool = false, egressRelay: EgressRelay? = nil
    ) {
        self.configuration = configuration
        self.warnings = warnings
        self.attachedShareNames = attachedShareNames
        self.rosettaAttached = rosettaAttached
        self.egressRelay = egressRelay
    }

    /// `VMConfig.effectiveStateHash` of `config` with the devices this configuration attaches:
    /// the hash a state saved from a machine built from it is stored with.
    public func stateHash(for config: VMConfig) -> String {
        config.effectiveStateHash(attachedShareNames: attachedShareNames, rosettaAttached: rosettaAttached)
    }
}

/// Builds a minimal-surface `VZVirtualMachineConfiguration` for a Linux guest:
/// EFI boot, virtio disk + read-only seed, network, entropy, balloon, serial console.
/// The network is Apple's NAT, or with `VMConfig.controlledNetwork` Nido's relay
/// (`EgressRelay`, started here with `egress`); never NAT for a controlled VM: when gvproxy does
/// not start, the relay's attachment leads nowhere and a warning says the VM has no network.
/// Graphics and input (USB keyboard, absolute pointer) only when a `DisplaySpec` is given.
/// One VirtioFS device (tag `nido`) sharing the config's folders that still pass
/// `SharedFolder.validate`; the others are left out and reported in `warnings`.
/// A second VirtioFS device (tag `rosetta`) only when the config turns Rosetta on and this Mac
/// has it installed (`rosettaState`, injectable for tests); otherwise a warning says why.
/// A virtio-socket device and the `nido` directory-sharing device (empty unless folders are
/// shared) are always attached; otherwise no graphics, input, audio or USB.
public enum LinuxConfigurationBuilder {
    /// Both overloads refuse bundles whose inner files are symlinks, hard links or owned by
    /// someone else (`VMBundle.verifyInnerFiles(for: .linux)`) before referencing any of them.
    ///
    /// The CLI's console: the guest writes to `console` (console.log), nothing is read from the host.
    public static func make(
        bundle: VMBundle, config: VMConfig, console: FileHandle,
        display: DisplaySpec? = nil, imageCache: URL = ImageStore.defaultCacheRoot(),
        rosettaState: RosettaState = .current, egress: EgressRelay.Options = .init()
    ) throws -> GuestConfiguration {
        try make(bundle: bundle, config: config, display: display, imageCache: imageCache,
                 rosettaState: rosettaState, egress: egress,
                 serial: VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: console))
    }

    /// The app's interactive console: the guest reads `serialConsole`'s input pipe and writes to
    /// its output pipe (tee'd into console.log by `SerialConsole`). Otherwise the same configuration.
    /// `relay`: the controlled network's relay, already started by the caller (the app starts it
    /// off the main actor: gvproxy may take seconds); nil starts one here with `egress`.
    public static func make(
        bundle: VMBundle, config: VMConfig, serialConsole: SerialConsole,
        display: DisplaySpec? = nil, imageCache: URL = ImageStore.defaultCacheRoot(),
        rosettaState: RosettaState = .current, egress: EgressRelay.Options = .init(), relay: EgressRelay? = nil
    ) throws -> GuestConfiguration {
        try make(bundle: bundle, config: config, display: display, imageCache: imageCache,
                 rosettaState: rosettaState, egress: egress, relay: relay,
                 serial: VZFileHandleSerialPortAttachment(
                    fileHandleForReading: serialConsole.guestReadHandle,
                    fileHandleForWriting: serialConsole.guestWriteHandle))
    }

    private static func make(
        bundle: VMBundle, config: VMConfig, display: DisplaySpec?, imageCache: URL,
        rosettaState: RosettaState, egress: EgressRelay.Options, relay started: EgressRelay? = nil,
        serial attachment: VZSerialPortAttachment
    ) throws -> GuestConfiguration {
        try bundle.verifyInnerFiles(for: .linux)
        guard let mac = VZMACAddress(string: config.macAddress) else {
            throw NidoError.invalidResources(L10n.string("invalid MAC address"))
        }
        let identifierData = try Data(contentsOf: bundle.machineIdentifierURL)
        guard let identifier = VZGenericMachineIdentifier(dataRepresentation: identifierData) else {
            throw NidoError.invalidResources(L10n.string("invalid machine identifier"))
        }

        let configuration = VZVirtualMachineConfiguration()
        configuration.cpuCount = config.cpuCount
        configuration.memorySize = config.memoryBytes

        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = VZEFIVariableStore(url: bundle.nvramURL)
        configuration.bootLoader = bootLoader

        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = identifier
        configuration.platform = platform

        // Main disk: host-cached reads/writes, every guest flush still a full sync (`F_FULLFSYNC`).
        // Measurements and decision: docs/DISK-CACHING.md. The seed is read-only and tiny, so the
        // default attachment is enough.
        let disk = try VZDiskImageStorageDeviceAttachment(
            url: bundle.diskURL, readOnly: false, cachingMode: .cached, synchronizationMode: .full)
        let seed = try VZDiskImageStorageDeviceAttachment(url: bundle.seedURL, readOnly: true)
        configuration.storageDevices = [
            VZVirtioBlockDeviceConfiguration(attachment: disk),
            VZVirtioBlockDeviceConfiguration(attachment: seed),
        ]

        let network = try networkDevice(bundle: bundle, config: config, mac: mac, egress: egress, started: started)
        var warnings = network.warnings
        let egressRelay = network.relay
        configuration.networkDevices = [network.device]

        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = attachment
        configuration.serialPorts = [serial]

        if let display {
            let graphics = VZVirtioGraphicsDeviceConfiguration()
            graphics.scanouts = [
                VZVirtioGraphicsScanoutConfiguration(
                    widthInPixels: display.widthInPixels, heightInPixels: display.heightInPixels)
            ]
            configuration.graphicsDevices = [graphics]
            configuration.keyboards = [VZUSBKeyboardConfiguration()]
            configuration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        }

        var attachedShareNames: [String] = []
        var rosettaAttached = false
        var directorySharing: [VZDirectorySharingDeviceConfiguration] = []
        // The `nido` device is always attached, even with nothing to share (an empty share), so a
        // folder can be added to the running VM later by replacing its `share`.
        let shared = sharedDirectories(
            config.sharedFolders, paths: NidoPaths(root: bundle.url.deletingLastPathComponent()),
            imageCache: imageCache)
        warnings += shared.warnings
        let nido = VZVirtioFileSystemDeviceConfiguration(tag: SharedFolder.tag)
        nido.share = VZMultipleDirectoryShare(directories: shared.directories)
        directorySharing.append(nido)
        attachedShareNames = shared.directories.keys.sorted()
        if config.rosetta {
            let rosetta = RosettaSupport.device(state: rosettaState)
            if let device = rosetta.device {
                directorySharing.append(device)
                rosettaAttached = true
            }
            if let warning = rosetta.warning { warnings.append(warning) }
        }
        configuration.directorySharingDevices = directorySharing
        // virtio-socket for the Guest Tools monitor (and later the AI bridge); nothing is
        // listening on the Mac side unless the session registers a listener.
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        return GuestConfiguration(
            configuration: configuration, warnings: warnings,
            attachedShareNames: attachedShareNames, rosettaAttached: rosettaAttached, egressRelay: egressRelay)
    }

    /// The network device of a guest (Linux or macOS) with the config's MAC address: Apple's NAT,
    /// or with `VMConfig.controlledNetwork` the relay's attachment (`started`, or a relay started
    /// here with `egress`). Never NAT for a controlled VM: when gvproxy does not start, the
    /// attachment leads nowhere and the warning says the VM has no network; a log the relay cannot
    /// open is a warning too (`EgressRelay.logUnavailableWarning`). Call it after every
    /// other check that can throw, so a relay started here is never left behind.
    static func networkDevice(
        bundle: VMBundle, config: VMConfig, mac: VZMACAddress, egress: EgressRelay.Options, started: EgressRelay?
    ) throws -> (device: VZVirtioNetworkDeviceConfiguration, relay: EgressRelay?, warnings: [String]) {
        let network = VZVirtioNetworkDeviceConfiguration()
        network.macAddress = mac
        guard config.controlledNetwork == true else {
            // A relay started for a config that turned out not to be controlled leads nowhere.
            started?.shutdown()
            network.attachment = VZNATNetworkDeviceAttachment()
            return (network, nil, [])
        }
        let relay = try started ?? EgressRelay(bundle: bundle, guestMAC: config.macAddress, options: egress)
        network.attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: relay.guestHandle)
        var warnings: [String] = []
        if let failure = relay.startFailure {
            warnings.append(ConsoleSanitizer.escapingControls(
                L10n.string("Controlled network not started (\(failure)): the VM starts without a network.")))
        }
        if relay.logFailure != nil { warnings.append(EgressRelay.logUnavailableWarning) }
        return (network, relay, warnings)
    }

    /// The shared folders that may be shared right now: each is validated again (it may have been
    /// moved, removed or replaced by a symlink since it was added). A folder that fails, has an
    /// invalid name or repeats a name is left out with a warning, never failing the start.
    /// So is one whose path now resolves somewhere else than the path saved when it was added
    /// (ruling R-M3A-23): a folder swapped for a symlink, even to a place that could be shared,
    /// is never followed silently.
    static func sharedDirectories(
        _ folders: [SharedFolder], paths: NidoPaths, imageCache: URL
    ) -> (directories: [String: VZSharedDirectory], warnings: [String]) {
        var directories: [String: VZSharedDirectory] = [:]
        var seen = Set<String>()
        var warnings: [String] = []
        for folder in folders {
            do {
                try SharedFolder.validateName(folder.name)
                guard seen.insert(folder.name.lowercased()).inserted else {
                    throw NidoError.shareNameTaken(folder.name)
                }
                let url = try SharedFolder.validate(hostPath: folder.hostPath, paths: paths, imageCache: imageCache)
                guard comparablePath(url.path) == comparablePath(folder.hostPath) else {
                    throw NidoError.sharedFolderRefused(L10n.string(
                        "\(folder.hostPath) now leads to \(url.path), not to the folder that was added; if that’s the right one, remove it and add it again"))
                }
                directories[folder.name] = VZSharedDirectory(url: url, readOnly: folder.readOnly)
            } catch {
                warnings.append(warning(for: folder, error: error))
            }
        }
        return (directories, warnings)
    }

    /// A path as compared with the one saved: case-insensitive, without a trailing slash, and with
    /// the data volume's firmlink prefix (`/System/Volumes/Data`) dropped, as `validate` does.
    static func comparablePath(_ path: String) -> String {
        var lower = path.lowercased()
        while lower.count > 1, lower.hasSuffix("/") { lower.removeLast() }
        let data = "/system/volumes/data"
        if lower.hasPrefix(data + "/") { lower = String(lower.dropFirst(data.count)) }
        return lower
    }

    /// The warning (localized) for a folder left out; control characters of a hand-edited
    /// `config.json` are escaped (it is printed in the terminal).
    private static func warning(for folder: SharedFolder, error: any Error) -> String {
        let text: String
        if case NidoError.sharedFolderMissing = error {
            text = L10n.string("Shared folder \(folder.name) not found on the Mac (\(folder.hostPath)): the VM starts without it.")
        } else {
            let reason = (error as? NidoError)?.errorDescription ?? error.localizedDescription
            text = L10n.string("Shared folder \(folder.name) left out (\(reason)): the VM starts without it.")
        }
        return ConsoleSanitizer.escapingControls(text)
    }
}
