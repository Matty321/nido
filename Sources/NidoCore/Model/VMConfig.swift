// SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Foundation
import Virtualization

/// Guest operating system family.
public enum GuestOS: String, Codable, Sendable {
    case linux
    /// A macOS guest installed from an IPSW the user provides (M3b).
    case macos
}

/// Persistent description of a virtual machine (`config.json`).
///
/// Schema 2 (M3a) adds `sharedFolders`, `rosetta`, `suspendedConfigHash`,
/// `guestMountsSharedFolders` and `guestRegistersRosetta`. A schema 1 file decodes with their defaults and keeps
/// `schemaVersion` 1 until it is written again (`VMBundle.writeConfig` writes the current schema).
/// Schema 3 (M3c) adds `provisioning`, `guestToolsVersion`, `sshPublicKeyPath` and `isTemplate`;
/// files of schema 1 and 2 decode with their defaults. `aiBridge` (M3c, schema 3 too) is absent on
/// every VM that never had the AI bridge set up: absent means off.
/// Schema 4 (M3b) adds `guest: macos`, `sshUser`, `osVersion` and (optional) `sshSucceeded`,
/// `minimumCPUCount`, `minimumMemoryBytes`; files of schema 1–3 decode as
/// Linux VMs without them. The M3c features (`provisioning`, `guestToolsVersion`, `isTemplate`,
/// `aiBridge`, `pendingProvisioning`) are Linux-only: a macOS VM keeps them nil or false.
/// Schema 5 (M3d) adds `controlledNetwork`. A file of schema 1–4 has no such field and decodes
/// with `false` (Apple's NAT, as before): the migration never turns an existing VM into a
/// controlled one. A build that knows only schema 4 or less refuses a schema 5 file
/// (`decode`), so it can never start a controlled VM on NAT, nor rewrite its config without the field.
public struct VMConfig: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 5

    public var schemaVersion: Int
    public var id: UUID
    public var name: VMName
    public var guest: GuestOS
    public var cpuCount: Int
    public var memoryBytes: UInt64
    public var diskBytes: UInt64
    public var macAddress: String
    public var clipboardSharing: Bool
    /// Folders of the Mac shown in the guest under `/mnt/nido` (one VirtioFS device, tag `nido`).
    public var sharedFolders: [SharedFolder]
    /// Rosetta for x86_64 Linux binaries (VirtioFS tag `rosetta`).
    public var rosetta: Bool
    /// `stateHash()` of the configuration a saved state (`state.vzvmsave`) was taken with.
    public var suspendedConfigHash: String?
    /// True when the guest's cloud-init installs `nido-shares.service`, which mounts the `nido`
    /// VirtioFS tag on `/mnt/nido` (VMs created from M3a on). False for older VMs: the user runs `SharedFolder.legacyGuestCommand`
    /// once in the guest.
    public var guestMountsSharedFolders: Bool
    /// True when the guest's cloud-init installs `nido-rosetta.service`, which mounts the
    /// `rosetta` VirtioFS tag on `/media/rosetta` and registers it with binfmt_misc (VMs created with Rosetta support). False for older VMs:
    /// the user runs `RosettaSupport.legacyGuestCommand` once in the guest. Not in `stateHash()`.
    public var guestRegistersRosetta: Bool
    /// What cloud-init phase 1 was asked to set up at creation; nil for VMs created without a profile.
    public var provisioning: ProvisioningProfile?
    /// Version of the Guest Tools written into the seed or installed over SSH; nil when none.
    public var guestToolsVersion: String?
    /// Path of the SSH public key authorized in the guest at creation (the private key is next to it).
    public var sshPublicKeyPath: String?
    /// True for a VM kept as a template to clone from.
    public var isTemplate: Bool
    /// Policy of the remote AI bridge; nil = bridge off. Not inherited by clones. Not in `stateHash()`.
    public var aiBridge: AIBridgePolicy?
    /// Phase 2 chosen at creation and not yet verified (Ollama, a model); nil = nothing pending.
    /// Not inherited by clones. Not in `stateHash()`.
    public var pendingProvisioning: PendingProvisioning?
    /// Guest account `nido ssh` logs in as (macOS: the account the user creates in Setup
    /// Assistant, see `validateSSHUser`); nil = `nido`, the account cloud-init makes on Linux.
    public var sshUser: String?
    /// macOS version installed in the guest ("26.1"), from the IPSW; nil for Linux VMs.
    public var osVersion: String?
    /// True once `nido ssh` reached the guest of a macOS VM (M3b): the app's "Accesso da
    /// terminale" panel stops opening by itself. Nil = never (not written until then).
    public var sshSucceeded: Bool?
    /// macOS: the fewest CPUs the installed image supports (`MacImageInfo.minimumCPUCount`),
    /// recorded at install time so Settings never go below it. Nil for Linux and for macOS VMs
    /// installed before it was recorded. Not in `stateHash()`.
    public var minimumCPUCount: Int?
    /// macOS: the least memory (bytes) the installed image supports, as `minimumCPUCount`.
    public var minimumMemoryBytes: UInt64?
    /// True: the VM's network goes through Nido's relay (`EgressRelay`): only the domains of its
    /// `egress.json` are reachable, and if the relay cannot start the VM has no network. Nil or
    /// false: Apple's NAT, unfiltered (every VM created before the controlled network; absent in
    /// the file decodes as false). New VMs get true: Linux with the base list (`VMFactory`),
    /// macOS with `EgressPolicy.macOSBase` (`MacInstaller`). Part of `stateHash()` when true (the network
    /// device's attachment differs).
    public var controlledNetwork: Bool?
    /// The catalog distribution a Linux VM was created from; nil = Debian 13 (every Linux VM
    /// created before Ubuntu joined the catalog, and every macOS VM). Chooses the base list of
    /// the controlled network (`EgressPolicy.base(for:)`) and the name the library and
    /// `nido list` show. Optional and additive, so no schema bump: a build without it ignores the
    /// key. A value this build does not know (from a newer build) reads as nil here but is kept
    /// in `distributionID` and written back unchanged, so a save never erases it. Clones and
    /// templates keep it.
    public var distribution: LinuxDistribution? {
        get { distributionID.flatMap(LinuxDistribution.init(rawValue:)) }
        set { distributionID = newValue?.rawValue }
    }
    /// The `distribution` key exactly as the file has it (nil when absent).
    public private(set) var distributionID: String?
    /// Linux: whether the guest's background requests Nido turns off (`GuestBackgroundRequests`)
    /// are off. True: the seed of a new VM (0.7.4 on, `VMFactory`) or "Spegni" did it; false:
    /// the user answered "Non ora" to the suggestion; nil: unknown (a VM created before), so the
    /// VM window suggests "Spegni" (`GuestBackgroundRequests.mayNeedQuieting`). Optional and
    /// additive, no schema bump. Clones and templates keep it (the guest's disk is copied).
    public var backgroundRequestsOff: Bool?

    public init(
        schemaVersion: Int = VMConfig.currentSchemaVersion,
        id: UUID,
        name: VMName,
        guest: GuestOS,
        cpuCount: Int,
        memoryBytes: UInt64,
        diskBytes: UInt64,
        macAddress: String,
        clipboardSharing: Bool = false,
        sharedFolders: [SharedFolder] = [],
        rosetta: Bool = false,
        suspendedConfigHash: String? = nil,
        guestMountsSharedFolders: Bool = false,
        guestRegistersRosetta: Bool = false,
        provisioning: ProvisioningProfile? = nil,
        guestToolsVersion: String? = nil,
        sshPublicKeyPath: String? = nil,
        isTemplate: Bool = false,
        aiBridge: AIBridgePolicy? = nil,
        pendingProvisioning: PendingProvisioning? = nil,
        sshUser: String? = nil,
        osVersion: String? = nil,
        sshSucceeded: Bool? = nil,
        minimumCPUCount: Int? = nil,
        minimumMemoryBytes: UInt64? = nil,
        controlledNetwork: Bool? = false,
        distribution: LinuxDistribution? = nil,
        backgroundRequestsOff: Bool? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.guest = guest
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes
        self.macAddress = macAddress
        self.clipboardSharing = clipboardSharing
        self.sharedFolders = sharedFolders
        self.rosetta = rosetta
        self.suspendedConfigHash = suspendedConfigHash
        self.guestMountsSharedFolders = guestMountsSharedFolders
        self.guestRegistersRosetta = guestRegistersRosetta
        self.provisioning = provisioning
        self.guestToolsVersion = guestToolsVersion
        self.sshPublicKeyPath = sshPublicKeyPath
        self.isTemplate = isTemplate
        self.aiBridge = aiBridge
        self.pendingProvisioning = pendingProvisioning
        self.sshUser = sshUser
        self.osVersion = osVersion
        self.sshSucceeded = sshSucceeded
        self.minimumCPUCount = minimumCPUCount
        self.minimumMemoryBytes = minimumMemoryBytes
        self.controlledNetwork = controlledNetwork
        self.distributionID = distribution?.rawValue
        self.backgroundRequestsOff = backgroundRequestsOff
    }

    /// The distribution of a Linux VM (Debian 13 when none is recorded); nil for macOS and for
    /// a distribution this build does not know.
    public var linuxDistribution: LinuxDistribution? {
        guard guest == .linux else { return nil }
        guard let distributionID else { return .debian13 }
        return LinuxDistribution(rawValue: distributionID)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, guest, cpuCount, memoryBytes, diskBytes, macAddress, clipboardSharing
        case sharedFolders, rosetta, suspendedConfigHash, guestMountsSharedFolders
        case guestRegistersRosetta, provisioning, guestToolsVersion, sshPublicKeyPath, isTemplate
        case aiBridge, pendingProvisioning, sshUser, osVersion, sshSucceeded
        case minimumCPUCount, minimumMemoryBytes, controlledNetwork
        case distributionID = "distribution"
        case backgroundRequestsOff
    }

    /// Fields missing from the file (older schemas) take their defaults; a missing
    /// `controlledNetwork` is false.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(VMName.self, forKey: .name)
        guest = try c.decode(GuestOS.self, forKey: .guest)
        cpuCount = try c.decode(Int.self, forKey: .cpuCount)
        memoryBytes = try c.decode(UInt64.self, forKey: .memoryBytes)
        diskBytes = try c.decode(UInt64.self, forKey: .diskBytes)
        macAddress = try c.decode(String.self, forKey: .macAddress)
        clipboardSharing = try c.decodeIfPresent(Bool.self, forKey: .clipboardSharing) ?? false
        sharedFolders = try c.decodeIfPresent([SharedFolder].self, forKey: .sharedFolders) ?? []
        rosetta = try c.decodeIfPresent(Bool.self, forKey: .rosetta) ?? false
        suspendedConfigHash = try c.decodeIfPresent(String.self, forKey: .suspendedConfigHash)
        guestMountsSharedFolders = try c.decodeIfPresent(Bool.self, forKey: .guestMountsSharedFolders) ?? false
        guestRegistersRosetta = try c.decodeIfPresent(Bool.self, forKey: .guestRegistersRosetta) ?? false
        provisioning = try c.decodeIfPresent(ProvisioningProfile.self, forKey: .provisioning)
        guestToolsVersion = try c.decodeIfPresent(String.self, forKey: .guestToolsVersion)
        sshPublicKeyPath = try c.decodeIfPresent(String.self, forKey: .sshPublicKeyPath)
        isTemplate = try c.decodeIfPresent(Bool.self, forKey: .isTemplate) ?? false
        aiBridge = try c.decodeIfPresent(AIBridgePolicy.self, forKey: .aiBridge)
        pendingProvisioning = try c.decodeIfPresent(PendingProvisioning.self, forKey: .pendingProvisioning)
        sshUser = try c.decodeIfPresent(String.self, forKey: .sshUser)
        osVersion = try c.decodeIfPresent(String.self, forKey: .osVersion)
        sshSucceeded = try c.decodeIfPresent(Bool.self, forKey: .sshSucceeded)
        minimumCPUCount = try c.decodeIfPresent(Int.self, forKey: .minimumCPUCount)
        minimumMemoryBytes = try c.decodeIfPresent(UInt64.self, forKey: .minimumMemoryBytes)
        controlledNetwork = try c.decodeIfPresent(Bool.self, forKey: .controlledNetwork) ?? false
        // A value of a newer build is kept as is; a non-string never fails the decoding.
        distributionID = (try? c.decodeIfPresent(String.self, forKey: .distributionID)) ?? nil
        backgroundRequestsOff = (try? c.decodeIfPresent(Bool.self, forKey: .backgroundRequestsOff)) ?? nil
    }

    /// Accepts a guest account name for `sshUser`: `^[a-z_][a-z0-9_-]{0,31}$` (ASCII only), so it
    /// is a valid short name in macOS and Linux and never an `ssh` option or a second argument.
    public static func validateSSHUser(_ user: String) throws(NidoError) {
        let bytes = Array(user.utf8)
        guard let first = bytes.first, bytes.count <= 32 else { throw .invalidSSHUser(user) }
        func isLower(_ b: UInt8) -> Bool { b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z") }
        func isDigit(_ b: UInt8) -> Bool { b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9") }
        guard isLower(first) || first == UInt8(ascii: "_") else { throw .invalidSSHUser(user) }
        for b in bytes.dropFirst()
        where !(isLower(b) || isDigit(b) || b == UInt8(ascii: "_") || b == UInt8(ascii: "-")) {
            throw .invalidSSHUser(user)
        }
    }

    /// SHA-256 (lowercase hex) of the parts of the configuration a saved machine state depends
    /// on: CPU count, memory, MAC address, shared folders, Rosetta and (M3d) the controlled
    /// network, encoded as JSON with sorted keys. A saved state is restored only while this is
    /// unchanged. `controlledNetwork` enters only when true, so a VM on Apple's NAT keeps the hash
    /// it had before M3d and its saved state still resumes; a state saved on NAT never resumes on
    /// the relay, nor the other way round. A controlled VM also records the relay's uplink
    /// (`gvproxy` since 0.6): a state saved by 0.5.x behind vmnet never resumes behind gvproxy,
    /// it is discarded with `SuspendedState.configChangedWarning` and the VM starts from cold.
    public func stateHash() -> String {
        struct MachineShape: Encodable {
            let cpuCount: Int
            let memoryBytes: UInt64
            let macAddress: String
            let sharedFolders: [SharedFolder]
            let rosetta: Bool
            /// Omitted (nil) unless true.
            let controlledNetwork: Bool?
            /// The relay's uplink, only for a controlled VM (nil before 0.6, vmnet).
            let controlledNetworkUplink: String?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let shape = MachineShape(
            cpuCount: cpuCount, memoryBytes: memoryBytes, macAddress: macAddress,
            sharedFolders: sharedFolders, rosetta: rosetta,
            controlledNetwork: controlledNetwork == true ? true : nil,
            controlledNetworkUplink: controlledNetwork == true ? "gvproxy" : nil)
        let data: Data
        do {
            data = try encoder.encode(shape)
        } catch {
            // Plain integers, strings and booleans always encode: a failure is a programming error,
            // and hashing empty data instead would make different machines look equal.
            preconditionFailure("VMConfig.stateHash: \(error)")
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// `stateHash()` of the machine actually built from this config: only the shared folders in
    /// `attachedShareNames` (a folder missing on the Mac is left out at start) and Rosetta only if
    /// its device was attached. A saved state stores this hash (ruling R-M3A-12): when every
    /// configured device is attached it equals `stateHash()`.
    public func effectiveStateHash(attachedShareNames: [String], rosettaAttached: Bool) -> String {
        var effective = self
        let attached = Set(attachedShareNames)
        effective.sharedFolders = sharedFolders.filter { attached.contains($0.name) }
        effective.rosetta = rosetta && rosettaAttached
        return effective.stateHash()
    }

    /// Decodes a config, rejecting schema versions this build does not understand.
    public static func decode(_ data: Data) throws -> VMConfig {
        let config = try JSONDecoder().decode(VMConfig.self, from: data)
        guard (1...currentSchemaVersion).contains(config.schemaVersion) else {
            throw NidoError.unsupportedSchema(config.schemaVersion)
        }
        return config
    }

    /// Pretty-printed JSON with sorted keys.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

/// The resource profiles proposed when creating a Linux VM.
public enum ResourcePreset: String, Sendable, CaseIterable {
    /// Debian with the essential packages and the Guest Tools.
    case debianBase
    /// Debian AI Starter: room for Ollama and a small model.
    case aiStarter
}

/// Validates CPU, memory and disk: CPU and memory against what Virtualization.framework allows on
/// this host, the disk against the image it is cloned from. Shared by the CLI, `VMFactory` and the app.
public enum ResourceLimits {
    private static let mebibyte: UInt64 = 1024 * 1024

    /// Most vCPUs a new or edited VM may have: the cores of this Mac, capped by what
    /// Virtualization.framework allows. Existing VMs above it still load and start.
    public static func maxCPUCount(hostCores: Int = ProcessInfo.processInfo.activeProcessorCount) -> Int {
        max(VZVirtualMachineConfiguration.minimumAllowedCPUCount,
            min(hostCores, VZVirtualMachineConfiguration.maximumAllowedCPUCount))
    }

    /// CPU counts accepted when creating or editing a VM on this host.
    public static func cpuCountRange(
        hostCores: Int = ProcessInfo.processInfo.activeProcessorCount
    ) -> ClosedRange<Int> {
        VZVirtualMachineConfiguration.minimumAllowedCPUCount...maxCPUCount(hostCores: hostCores)
    }

    public static var cpuCountRange: ClosedRange<Int> { cpuCountRange() }

    /// Memory sizes (bytes) Virtualization.framework accepts on this host.
    public static var memoryRange: ClosedRange<UInt64> {
        VZVirtualMachineConfiguration.minimumAllowedMemorySize...VZVirtualMachineConfiguration.maximumAllowedMemorySize
    }

    public static func validate(
        cpuCount: Int, memoryBytes: UInt64,
        hostCores: Int = ProcessInfo.processInfo.activeProcessorCount
    ) throws(NidoError) {
        let cpus = cpuCountRange(hostCores: hostCores)
        guard cpus.contains(cpuCount) else {
            throw .invalidResources(L10n.string("CPU: value \(String(cpuCount)) out of range (\(String(cpus.lowerBound))-\(String(cpus.upperBound)))"))
        }
        let memory = memoryRange
        let (minMem, maxMem) = (memory.lowerBound, memory.upperBound)
        guard memory.contains(memoryBytes) else {
            throw .invalidResources(L10n.string("memory: value \(String(memoryBytes)) out of range (\(String(minMem))-\(String(maxMem)) bytes)"))
        }
        guard memoryBytes % mebibyte == 0 else {
            throw .invalidResources(L10n.string("memory: must be a multiple of 1 MiB"))
        }
    }

    /// Macs with at most this much RAM get the smaller creation defaults.
    public static let smallHostMemory: UInt64 = 16 << 30

    /// Memory proposed for a new VM of `preset` (always editable). On a Mac with at most 16 GiB
    /// a smaller value: guest RAM overcommit on such Macs (several VMs, Docker) is what made the
    /// host lose guest memory in the crash investigation of M3c.
    public static func defaultMemoryBytes(
        for preset: ResourcePreset, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> UInt64 {
        let small = physicalMemory <= smallHostMemory
        switch preset {
        case .debianBase: return (small ? 2 : 4) << 30
        case .aiStarter: return (small ? 4 : 8) << 30
        }
    }

    /// The VM disk is a clone of the base image grown to `diskBytes`: it cannot be smaller.
    public static func validateDisk(diskBytes: UInt64, imageBytes: UInt64) throws(NidoError) {
        guard diskBytes >= imageBytes else {
            throw .invalidResources(L10n.string(
                "disk: \(String(diskBytes)) bytes is smaller than the image (\(String(imageBytes)) bytes)"))
        }
    }
}
