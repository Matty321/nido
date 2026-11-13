// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Whether a VM is running, and which kind of process holds it.
public enum VMStatus: Equatable, Sendable {
    case stopped
    case running(LockOwner)
    /// `config.json` is missing, malformed or unsafe. `running` is who holds the bundle lock
    /// (nil when nobody does): a VM can keep running after its config.json got damaged.
    case unreadable(running: LockOwner?)
}

/// One row of the VM library. `configID` and the resource fields are nil when `config.json`
/// cannot be read; `name` then comes from the bundle directory name.
public struct VMSummary: Identifiable, Equatable, Sendable {
    public let configID: UUID?
    public let name: String
    public let status: VMStatus
    public let cpuCount: Int?
    public let memoryBytes: UInt64?
    public let diskBytes: UInt64?
    /// Stopped with a saved state (`VMBundle.hasSuspendedState`): the next start resumes it.
    public let isSuspended: Bool
    /// A template (`VMConfig.isTemplate`): not started, used to create VMs.
    public let isTemplate: Bool
    /// The guest system (`.linux` when the config is unreadable).
    public let guest: GuestOS
    /// The macOS version of a macOS guest ("26.6", `VMConfig.osVersion`); nil for Linux.
    public let osVersion: String?
    /// The distribution of a Linux guest (`VMConfig.linuxDistribution`); nil for macOS and when
    /// the config is unreadable.
    public let distribution: LinuxDistribution?

    public var id: String { name }

    public init(
        configID: UUID?, name: String, status: VMStatus, cpuCount: Int?, memoryBytes: UInt64?,
        diskBytes: UInt64?, isSuspended: Bool = false, isTemplate: Bool = false, guest: GuestOS = .linux,
        osVersion: String? = nil, distribution: LinuxDistribution? = nil
    ) {
        self.configID = configID
        self.name = name
        self.status = status
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes
        self.isSuspended = isSuspended
        self.isTemplate = isTemplate
        self.guest = guest
        self.osVersion = osVersion
        self.distribution = distribution
    }
}

/// Lists the VMs in the root with their live status.
public actor VMRegistry {
    private let paths: NidoPaths
    private let now: @Sendable () -> Date
    private let changeTime: @Sendable (URL) -> Date?

    /// `now` and `changeTime` are injectable so tests can control the tombstone age.
    public init(
        paths: NidoPaths, now: @escaping @Sendable () -> Date = { Date() },
        changeTime: @escaping @Sendable (URL) -> Date? = VMBundle.statChangeTime
    ) {
        self.paths = paths
        self.now = now
        self.changeTime = changeTime
    }

    /// Summaries sorted by name (case-insensitive). Also sweeps old orphan tombstones, best effort.
    public func summaries() throws -> [VMSummary] {
        VMBundle.sweepOrphanTombstones(paths: paths, now: now(), changeTime: changeTime)
        let rows = try VMBundle.list(paths: paths).map { bundle -> VMSummary in
            let holder = BundleLock.holder(bundle)
            guard let config = try? bundle.readConfig() else {
                return VMSummary(
                    configID: nil, name: bundle.displayName, status: .unreadable(running: holder?.owner), cpuCount: nil,
                    memoryBytes: nil, diskBytes: nil)
            }
            return VMSummary(
                configID: config.id, name: config.name.rawValue,
                status: holder.map { .running($0.owner) } ?? .stopped,
                cpuCount: config.cpuCount, memoryBytes: config.memoryBytes,
                diskBytes: config.diskBytes,
                isSuspended: holder == nil && bundle.hasSuspendedState(config),
                isTemplate: config.isTemplate, guest: config.guest, osVersion: config.osVersion,
                distribution: config.linuxDistribution)
        }
        return rows.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
}
