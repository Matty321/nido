// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
@testable import NidoCore

private let gib: UInt64 = 1 << 30

/// A fixed list of hypervisor processes.
private struct FakeProcesses: VirtualMachineProcessSource {
    let list: [VirtualMachineProcess]
    func virtualMachineProcesses() -> [VirtualMachineProcess] { list }
}

@Suite(.italian) struct MemoryHeadroomTests {
    @Test func headroomCountsNidoAndForeignVMs() {
        let docker = VirtualMachineProcess(
            pid: 100, footprintBytes: 5 * gib, openPaths: ["/Users/u/Library/Containers/docker/Docker.raw"])
        // The hypervisor process of a running Nido VM: counted by its configured memory instead.
        let nidoProcess = VirtualMachineProcess(
            pid: 200, footprintBytes: 3 * gib, openPaths: ["/dev/null", "/r/a.nidovm/disk.img"])
        // Same prefix, different bundle: not ours.
        let sibling = VirtualMachineProcess(pid: 300, footprintBytes: 1 * gib, openPaths: ["/r/a.nidovm2/disk.img"])
        let headroom = MemoryHeadroom.assess(
            physicalMemory: 16 * gib, startingBytes: 2 * gib,
            runningNidoVMs: [RunningNidoVM(bundlePath: "/r/a.nidovm", memoryBytes: 4 * gib)],
            processes: [docker, nidoProcess, sibling])
        #expect(headroom.nidoBytes == 4 * gib)
        #expect(headroom.foreignBytes == 6 * gib)
        #expect(headroom.startingBytes == 2 * gib)
        #expect(headroom.totalBytes == 12 * gib)
        #expect(headroom.warning == nil)  // exactly 75 %: not above
    }

    @Test func headroomWarnsAbove75Percent() {
        let atLimit = MemoryHeadroom.assess(
            physicalMemory: 16 * gib, startingBytes: 4 * gib,
            runningNidoVMs: [RunningNidoVM(bundlePath: "/r/a.nidovm", memoryBytes: 4 * gib)],
            processes: [VirtualMachineProcess(pid: 1, footprintBytes: 4 * gib, openPaths: [])])
        #expect(atLimit.totalBytes == 12 * gib)
        #expect(!atLimit.exceedsThreshold)
        #expect(atLimit.warning == nil)

        let over = MemoryHeadroom.assess(
            physicalMemory: 16 * gib, startingBytes: 4 * gib + (1 << 20),
            runningNidoVMs: [RunningNidoVM(bundlePath: "/r/a.nidovm", memoryBytes: 4 * gib)],
            processes: [VirtualMachineProcess(pid: 1, footprintBytes: 4 * gib, openPaths: [])])
        #expect(over.exceedsThreshold)
        #expect(over.warning
            == "la memoria delle VM accese supera il 75 % della RAM del Mac: rischio di crash del guest; riduci la memoria o chiudi altre VM/Docker")
        #expect(over.detail == "VM di Nido accese 4 GiB, altre VM (es. Docker) 4 GiB, questa VM 4 GiB: 12 GiB su 16 GiB")

        // The starting VM alone can be enough.
        let alone = MemoryHeadroom.assess(
            physicalMemory: 8 * gib, startingBytes: 7 * gib, runningNidoVMs: [], processes: [])
        #expect(alone.exceedsThreshold)
        // Unknown physical memory: no verdict, no crash.
        let unknown = MemoryHeadroom.assess(physicalMemory: 0, startingBytes: 4 * gib, runningNidoVMs: [], processes: [])
        #expect(!unknown.exceedsThreshold)
        #expect(unknown.warning == nil)
    }

    @Test func sumsSaturateInsteadOfOverflowing() {
        let headroom = MemoryHeadroom.assess(
            physicalMemory: 16 * gib, startingBytes: .max,
            runningNidoVMs: [RunningNidoVM(bundlePath: "/r/a.nidovm", memoryBytes: .max)],
            processes: [VirtualMachineProcess(pid: 1, footprintBytes: .max, openPaths: [])])
        #expect(headroom.totalBytes == .max)
        #expect(headroom.exceedsThreshold)
    }

    @Test func checkReadsRunningVMsFromTheRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-headroom-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NidoPaths(root: root)
        func make(_ name: String, memory: UInt64) throws -> VMBundle {
            try VMBundle.create(
                config: VMConfig(
                    id: UUID(), name: try VMName(name), guest: .linux, cpuCount: 2, memoryBytes: memory,
                    diskBytes: 20 * gib, macAddress: "02:00:00:00:00:01"),
                paths: paths)
        }
        let running = try make("running", memory: 4 * gib)
        let byApp = try make("app", memory: 3 * gib)
        _ = try make("stopped", memory: 8 * gib)
        let busy = try make("busy", memory: 6 * gib)  // a snapshot in progress: not running
        let starting = try make("starting", memory: 2 * gib)
        let locks = [
            try BundleLock.acquire(running, owner: .cli), try BundleLock.acquire(byApp, owner: .app),
            try BundleLock.acquire(busy, owner: .cliOperation), try BundleLock.acquire(starting, owner: .cli),
        ]
        defer { locks.forEach { $0.release() } }

        let realRunning = realPath(running.url)
        let processes = FakeProcesses(list: [
            VirtualMachineProcess(pid: 10, footprintBytes: 5 * gib, openPaths: ["/elsewhere/Docker.raw"]),
            VirtualMachineProcess(pid: 11, footprintBytes: 4 * gib, openPaths: [realRunning + "/disk.img"]),
        ])
        let headroom = MemoryHeadroom.check(
            starting: starting, memoryBytes: 2 * gib, paths: paths, processes: processes,
            physicalMemory: 16 * gib)
        #expect(headroom.nidoBytes == 7 * gib)
        #expect(headroom.foreignBytes == 5 * gib)
        #expect(headroom.startingBytes == 2 * gib)
        #expect(headroom.exceedsThreshold)
    }

    /// The wizard checks a VM that does not exist yet: every running VM of the root counts.
    @Test func checkWithoutABundleForANewVM() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-headroom-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NidoPaths(root: root)
        let running = try VMBundle.create(
            config: VMConfig(
                id: UUID(), name: try VMName("running"), guest: .linux, cpuCount: 2, memoryBytes: 8 * gib,
                diskBytes: 20 * gib, macAddress: "02:00:00:00:00:01"),
            paths: paths)
        let lock = try BundleLock.acquire(running, owner: .app)
        defer { lock.release() }
        let headroom = MemoryHeadroom.check(
            starting: nil, memoryBytes: 6 * gib, paths: paths, processes: FakeProcesses(list: []),
            physicalMemory: 16 * gib)
        #expect(headroom.nidoBytes == 8 * gib)
        #expect(headroom.startingBytes == 6 * gib)
        #expect(headroom.exceedsThreshold)
    }

    @Test func onlyVirtualizationProcessesAreHypervisors() {
        #expect(SystemVirtualMachineProcesses.isVirtualMachineExecutable(
            "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"))
        #expect(!SystemVirtualMachineProcesses.isVirtualMachineExecutable(
            "/Applications/Docker.app/Contents/MacOS/com.docker.virtualization"))
        #expect(!SystemVirtualMachineProcesses.isVirtualMachineExecutable("/tmp/com.apple.Virtualization.VirtualMachine.fake"))
    }

    @Test func systemSourceReturnsReadableProcessesOnly() {
        // Whatever runs on this Mac: every listed process has a footprint and no empty paths.
        for process in SystemVirtualMachineProcesses().virtualMachineProcesses() {
            #expect(process.pid > 0)
            #expect(process.footprintBytes > 0)
            #expect(!process.openPaths.contains(""))
        }
    }
}

@Suite struct CreationDefaultsTests {
    @Test func smallerDefaultsOn16GiB() {
        for small in [8 * gib, 16 * gib] {
            #expect(ResourceLimits.defaultMemoryBytes(for: .debianBase, physicalMemory: small) == 2 * gib)
            #expect(ResourceLimits.defaultMemoryBytes(for: .aiStarter, physicalMemory: small) == 4 * gib)
        }
        for large in [16 * gib + (1 << 20), 32 * gib, 64 * gib] {
            #expect(ResourceLimits.defaultMemoryBytes(for: .debianBase, physicalMemory: large) == 4 * gib)
            #expect(ResourceLimits.defaultMemoryBytes(for: .aiStarter, physicalMemory: large) == 8 * gib)
        }
        // Always valid sizes for Virtualization.framework.
        for preset in [ResourcePreset.debianBase, .aiStarter] {
            #expect(throws: Never.self) {
                try ResourceLimits.validate(
                    cpuCount: ResourceLimits.cpuCountRange.lowerBound,
                    memoryBytes: ResourceLimits.defaultMemoryBytes(for: preset, physicalMemory: 16 * gib))
            }
        }
    }
}
