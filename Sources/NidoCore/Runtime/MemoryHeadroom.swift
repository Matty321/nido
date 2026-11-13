// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation

/// A Nido VM that is running (its bundle lock is held by the CLI or the app).
public struct RunningNidoVM: Sendable, Equatable {
    /// `realpath` of the bundle directory.
    public let bundlePath: String
    /// Configured memory.
    public let memoryBytes: UInt64

    public init(bundlePath: String, memoryBytes: UInt64) {
        self.bundlePath = bundlePath
        self.memoryBytes = memoryBytes
    }
}

/// A Virtualization.framework hypervisor process (`com.apple.Virtualization.VirtualMachine`):
/// one per running VZ guest, whichever app started it (Nido, Docker Desktop, others).
public struct VirtualMachineProcess: Sendable, Equatable {
    public let pid: Int32
    /// `phys_footprint` of the process: the guest memory macOS currently holds for it.
    public let footprintBytes: UInt64
    /// Paths of the files it has open (its disk images among them).
    public let openPaths: [String]

    public init(pid: Int32, footprintBytes: UInt64, openPaths: [String]) {
        self.pid = pid
        self.footprintBytes = footprintBytes
        self.openPaths = openPaths
    }
}

/// Where the hypervisor processes come from (injectable for tests).
public protocol VirtualMachineProcessSource: Sendable {
    func virtualMachineProcesses() -> [VirtualMachineProcess]
}

/// Guest memory on this Mac against its RAM, checked before a VM starts. Overcommitting the
/// host's RAM with guests (in the investigation: 16 GiB of guests on a 16 GiB Mac with Docker)
/// made macOS lose guest memory pages under pressure, crashing the guest kernel. The check only
/// warns: starting the VM stays the user's choice.
public struct MemoryHeadroom: Sendable, Equatable {
    /// Above this fraction of the Mac's RAM the guests' memory is a risk.
    public static let warningFraction = 0.75

    public static var warningText: String {
        L10n.string("the running VMs’ memory is over 75% of the Mac’s RAM: the guest may crash; lower the memory or quit other VMs/Docker")
    }

    public let physicalMemory: UInt64
    /// Configured memory of the running Nido VMs (the starting one excluded).
    public let nidoBytes: UInt64
    /// Footprint of the other hypervisor processes (Docker Desktop, other apps' VMs).
    public let foreignBytes: UInt64
    /// Configured memory of the VM about to start.
    public let startingBytes: UInt64

    public init(physicalMemory: UInt64, nidoBytes: UInt64, foreignBytes: UInt64, startingBytes: UInt64) {
        self.physicalMemory = physicalMemory
        self.nidoBytes = nidoBytes
        self.foreignBytes = foreignBytes
        self.startingBytes = startingBytes
    }

    public var totalBytes: UInt64 { Self.sum([nidoBytes, foreignBytes, startingBytes]) }

    /// More than `warningFraction` of the RAM. False when the RAM is unknown (0).
    public var exceedsThreshold: Bool {
        physicalMemory > 0 && Double(totalBytes) > Double(physicalMemory) * Self.warningFraction
    }

    /// The localized warning, nil when within the limit.
    public var warning: String? { exceedsThreshold ? Self.warningText : nil }

    /// The figures behind the warning, localized.
    public var detail: String {
        let (nido, foreign, starting) = (Self.gib(nidoBytes), Self.gib(foreignBytes), Self.gib(startingBytes))
        let (total, ram) = (Self.gib(totalBytes), Self.gib(physicalMemory))
        return L10n.string("running Nido VMs use \(nido), other VMs (such as Docker) \(foreign), and this VM \(starting): \(total) of the Mac’s \(ram)")
    }

    /// Pure assessment. A hypervisor process with a file open inside the bundle of a running Nido
    /// VM is that VM's own: it is counted once, by the VM's configured memory.
    public static func assess(
        physicalMemory: UInt64, startingBytes: UInt64, runningNidoVMs: [RunningNidoVM],
        processes: [VirtualMachineProcess], ownBundlePaths: [String] = []
    ) -> MemoryHeadroom {
        let bundles = runningNidoVMs.map(\.bundlePath) + ownBundlePaths
        let foreign = processes.filter { process in
            !process.openPaths.contains { path in
                bundles.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
            }
        }
        return MemoryHeadroom(
            physicalMemory: physicalMemory, nidoBytes: sum(runningNidoVMs.map(\.memoryBytes)),
            foreignBytes: sum(foreign.map(\.footprintBytes)), startingBytes: startingBytes)
    }

    /// The assessment for starting `bundle` with `memoryBytes`: the other VMs of `paths` whose
    /// lock is held by the CLI or the app (an operation lock is not a running VM), the hypervisor
    /// processes of `processes` and the Mac's RAM. Best effort: an unreadable bundle is skipped.
    /// `bundle` nil: a VM not created yet (the app's creation wizard).
    public static func check(
        starting bundle: VMBundle?, memoryBytes: UInt64, paths: NidoPaths,
        processes: any VirtualMachineProcessSource = SystemVirtualMachineProcesses(),
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> MemoryHeadroom {
        let starting = bundle.map { canonicalPath($0.url) }
        var running: [RunningNidoVM] = []
        for other in (try? VMBundle.list(paths: paths)) ?? [] {
            let path = canonicalPath(other.url)
            guard path != starting, let owner = BundleLock.holder(other)?.owner,
                owner == .cli || owner == .app, let config = try? other.readConfig()
            else { continue }
            running.append(RunningNidoVM(bundlePath: path, memoryBytes: config.memoryBytes))
        }
        return assess(
            physicalMemory: physicalMemory, startingBytes: memoryBytes, runningNidoVMs: running,
            processes: processes.virtualMachineProcesses(), ownBundlePaths: starting.map { [$0] } ?? [])
    }

    /// `realpath(3)` (keeps `/private`, as the kernel reports open files), else the path itself.
    static func canonicalPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func sum(_ values: [UInt64]) -> UInt64 {
        values.reduce(0) { total, value in
            let (result, overflow) = total.addingReportingOverflow(value)
            return overflow ? .max : result
        }
    }

    /// "4 GiB", "1.5 GiB" ("1,5 GiB" in Italian): binary units, the UI language's decimal
    /// separator, one decimal at most.
    static func gib(_ bytes: UInt64) -> String {
        let tenths = Int((Double(bytes) / Double(1 << 30) * 10).rounded())
        if tenths % 10 == 0 { return "\(tenths / 10) GiB" }
        let separator = L10n.locale.decimalSeparator ?? "."
        return "\(tenths / 10)\(separator)\(tenths % 10) GiB"
    }
}

/// The hypervisor processes of this Mac, through libproc: `proc_listallpids`, `proc_pidpath`,
/// `proc_pid_rusage` (`RUSAGE_INFO_V4`, `ri_phys_footprint`) and the open vnodes
/// (`PROC_PIDLISTFDS`, `PROC_PIDFDVNODEPATHINFO`). Only processes of the same user are readable:
/// the others are skipped.
public struct SystemVirtualMachineProcesses: VirtualMachineProcessSource {
    static let executableName = "com.apple.Virtualization.VirtualMachine"
    static let frameworkPrefix = "/System/Library/Frameworks/Virtualization.framework/"

    public init() {}

    /// The XPC service executable inside the system's Virtualization.framework.
    static func isVirtualMachineExecutable(_ path: String) -> Bool {
        path.hasPrefix(frameworkPrefix) && (path as NSString).lastPathComponent == executableName
    }

    public func virtualMachineProcesses() -> [VirtualMachineProcess] {
        Self.allPIDs().compactMap { pid in
            guard let path = Self.executablePath(pid), Self.isVirtualMachineExecutable(path),
                let footprint = Self.footprint(pid), footprint > 0
            else { return nil }
            return VirtualMachineProcess(pid: pid, footprintBytes: footprint, openPaths: Self.openPaths(pid))
        }
    }

    private static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        // Room for processes started in between.
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        return pids.prefix(min(Int(count), pids.count)).filter { $0 > 0 }
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func footprint(_ pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return status == 0 ? info.ri_phys_footprint : nil
    }

    private static func openPaths(_ pid: pid_t) -> [String] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        // Room for descriptors opened in between.
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 16)
        let filled = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return [] }
        var paths: [String] = []
        for fd in fds.prefix(min(Int(filled) / stride, fds.count)) where fd.proc_fdtype == PROX_FDTYPE_VNODE {
            var info = vnode_fdinfowithpath()
            let read = proc_pidfdinfo(
                pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(MemoryLayout<vnode_fdinfowithpath>.size))
            guard read == Int32(MemoryLayout<vnode_fdinfowithpath>.size) else { continue }
            let path = withUnsafeBytes(of: &info.pvip.vip_path) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            if !path.isEmpty { paths.append(path) }
        }
        return paths
    }
}
