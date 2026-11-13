// SPDX-License-Identifier: Apache-2.0
import Foundation
import Virtualization

/// Builds the `VZVirtualMachineConfiguration` of a macOS guest (M3b):
/// - Mac platform from the bundle (`hardware-model.bin`, `auxiliary-storage.img`,
///   `machine-id.bin`) and the macOS boot loader;
/// - one Mac display (`DisplaySpec`, or 1920×1200 at 144 ppi), Mac keyboard and trackpad;
/// - the network with the config's MAC address: Apple's NAT, or with `VMConfig.controlledNetwork`
///   Nido's relay (`EgressRelay`), exactly as for Linux (`LinuxConfigurationBuilder.networkDevice`:
///   never NAT for a controlled VM); the virtio disk, entropy, memory balloon;
/// - audio output only (no microphone);
/// - one VirtioFS device with the macOS automount tag (the guest shows it in
///   `/Volumes/My Shared Files`), always attached and empty unless folders are shared; the same
///   rules and warnings as Linux (`LinuxConfigurationBuilder.sharedDirectories`).
/// Nothing else: no serial console, no virtio-socket (the Guest Tools monitor and the AI bridge are
/// Linux-only in M3b), no Rosetta device (a macOS guest installs Rosetta itself), no USB.
public enum MacConfigurationBuilder {
    /// The display of a VM built without a `DisplaySpec` (the installer, `nido start`).
    public static let defaultDisplay = DisplaySpec(widthInPixels: 1920, heightInPixels: 1200)
    /// Pixel density of the Mac display.
    public static let pixelsPerInch = 144

    /// VirtioFS tag of the shared folders device of a macOS guest.
    public static var sharedFolderTag: String { VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag }

    /// Refuses a config that is not `.macos` and a bundle whose macOS files are missing, symlinks,
    /// hard links or owned by someone else (`VMBundle.verifyInnerFiles(for: .macos)`) before
    /// referencing any of them.
    ///
    /// `relay`: the controlled network's relay, already started by the caller (the app starts it
    /// off the main actor: gvproxy may take seconds); nil starts one here with `egress`. The relay is
    /// started (or taken) only once nothing else can throw.
    public static func make(
        bundle: VMBundle, config: VMConfig, display: DisplaySpec? = nil,
        imageCache: URL = ImageStore.defaultCacheRoot(), egress: EgressRelay.Options = .init(),
        relay started: EgressRelay? = nil
    ) throws -> GuestConfiguration {
        guard config.guest == .macos else {
            throw NidoError.invalidResources(L10n.string("the VM \(config.name.rawValue) isn’t a macOS VM"))
        }
        try bundle.verifyInnerFiles(for: .macos)
        guard let mac = VZMACAddress(string: config.macAddress) else {
            throw NidoError.invalidResources(L10n.string("invalid MAC address"))
        }
        guard let hardwareModel = VZMacHardwareModel(dataRepresentation: try Data(contentsOf: bundle.hardwareModelURL))
        else { throw NidoError.invalidResources(L10n.string("invalid hardware model")) }
        guard let identifier = VZMacMachineIdentifier(
            dataRepresentation: try Data(contentsOf: bundle.machineIdentifierURL))
        else { throw NidoError.invalidResources(L10n.string("invalid machine identifier")) }

        let configuration = VZVirtualMachineConfiguration()
        configuration.cpuCount = config.cpuCount
        configuration.memorySize = config.memoryBytes

        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardwareModel
        platform.machineIdentifier = identifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: bundle.auxiliaryStorageURL)
        configuration.platform = platform
        configuration.bootLoader = VZMacOSBootLoader()

        // Same disk caching as Linux (docs/DISK-CACHING.md).
        let disk = try VZDiskImageStorageDeviceAttachment(
            url: bundle.diskURL, readOnly: false, cachingMode: .cached, synchronizationMode: .full)
        configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]

        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        let shown = display ?? defaultDisplay
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [
            VZMacGraphicsDisplayConfiguration(
                widthInPixels: shown.widthInPixels, heightInPixels: shown.heightInPixels,
                pixelsPerInch: pixelsPerInch)
        ]
        configuration.graphicsDevices = [graphics]
        configuration.keyboards = [VZMacKeyboardConfiguration()]
        configuration.pointingDevices = [VZMacTrackpadConfiguration()]

        // Output only: the guest never gets the Mac's microphone.
        let output = VZVirtioSoundDeviceOutputStreamConfiguration()
        output.sink = VZHostAudioOutputStreamSink()
        let sound = VZVirtioSoundDeviceConfiguration()
        sound.streams = [output]
        configuration.audioDevices = [sound]

        // Always attached, even with nothing to share, like the Linux `nido` device.
        let shared = LinuxConfigurationBuilder.sharedDirectories(
            config.sharedFolders, paths: NidoPaths(root: bundle.url.deletingLastPathComponent()),
            imageCache: imageCache)
        let device = VZVirtioFileSystemDeviceConfiguration(tag: sharedFolderTag)
        device.share = VZMultipleDirectoryShare(directories: shared.directories)
        configuration.directorySharingDevices = [device]

        // Last: nothing throws after the relay is started.
        let network = try LinuxConfigurationBuilder.networkDevice(
            bundle: bundle, config: config, mac: mac, egress: egress, started: started)
        configuration.networkDevices = [network.device]

        return GuestConfiguration(
            configuration: configuration, warnings: network.warnings + shared.warnings,
            attachedShareNames: shared.directories.keys.sorted(), rosettaAttached: false,
            egressRelay: network.relay)
    }
}
