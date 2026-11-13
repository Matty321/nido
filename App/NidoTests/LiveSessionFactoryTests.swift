// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore
import Synchronization
import Testing
import Virtualization

@testable import Nido

/// Whether this process may create virtual machines (the app's test host is signed with the
/// virtualization entitlement; without it these tests are skipped).
private let canCreateVirtualMachines: Bool = {
    do {
        try VZVirtualMachineConfiguration().validate()
        return true
    } catch let error as NSError {
        return !(error.localizedFailureReason ?? "").contains("entitlement")
    }
}()

/// `LiveSessionFactory` on a macOS bundle: the AI bridge is Linux-only in M3b.
@MainActor
struct LiveSessionFactoryTests {
    /// A macOS bundle as `MacInstaller` leaves it (minus the installed system).
    private func makeMacBundle(in root: URL) throws -> VMBundle {
        let paths = NidoPaths(root: root.appendingPathComponent("VMs", isDirectory: true))
        let config = VMConfig(
            id: UUID(), name: try VMName("mac"), guest: .macos, cpuCount: 2, memoryBytes: 4 << 30,
            diskBytes: 1 << 30, macAddress: VZMACAddress.randomLocallyAdministered().string,
            sshUser: "mattia", osVersion: "26.1")
        let bundle = try VMBundle.create(config: config, paths: paths)
        // Private files as the installer writes them (0600); the disk is sparse.
        func write(_ data: Data, to url: URL) throws {
            try data.write(to: url, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        try write(Data(), to: bundle.diskURL)
        let disk = try FileHandle(forWritingTo: bundle.diskURL)
        try disk.truncate(atOffset: config.diskBytes)
        try disk.close()
        // A hardware model Virtualization accepts, made without an IPSW.
        let plist: [String: Any] = [
            "DataRepresentationVersion": 1, "MinimumSupportedOS": [13, 0, 0], "PlatformVersion": 2,
        ]
        let modelData = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let model = try #require(VZMacHardwareModel(dataRepresentation: modelData))
        _ = try VZMacAuxiliaryStorage(creatingStorageAt: bundle.auxiliaryStorageURL, hardwareModel: model, options: [])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bundle.auxiliaryStorageURL.path)
        try write(modelData, to: bundle.hardwareModelURL)
        try write(VZMacMachineIdentifier().dataRepresentation, to: bundle.machineIdentifierURL)
        return bundle
    }

    @Test(.enabled(if: canCreateVirtualMachines, "needs the virtualization entitlement"))
    func macSessionGetsNoAIBridge() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-app-factory-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeMacBundle(in: root)
        let services = AIBridgeServices(router: DebugFakeRouter(), tokenStore: DebugMemoryTokenStore())
        let factory = LiveSessionFactory(imageCache: root.appendingPathComponent("cache"), aiBridge: services)

        let handle = try await factory.makeSession(bundle: bundle)

        #expect(handle.aiBridgeAttached == nil)
        let session = try #require(handle as? VMSession)
        #expect(session.guest == .macos)
        #expect(session.aiBridge == nil)
        // Asked directly, the session refuses too: no vsock device, no bridge on a macOS guest.
        #expect(!session.attachAIBridge(try services.makeHost(for: bundle)))
        #expect(session.aiBridge == nil)
        #expect(handle.guestChannel == nil)
        #expect(handle.console == nil)
    }

    /// The relay of a controlled VM starts off the main actor (vmnet blocks up to 10 s), with
    /// the VM's MAC; its failure fails the session (never a VM on Apple's NAT).
    @Test func controlledVMStartsItsRelayOffTheMainActor() async throws {
        struct Sentinel: Error {}
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-app-factory-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NidoPaths(root: root.appendingPathComponent("VMs", isDirectory: true))
        let config = VMConfig(
            id: UUID(), name: try VMName("rete"), guest: .linux, cpuCount: 2, memoryBytes: 2 << 30,
            diskBytes: 1 << 30, macAddress: "02:00:00:00:00:07", controlledNetwork: true)
        let bundle = try VMBundle.create(config: config, paths: paths)
        let seen = Mutex<(onMain: Bool, mac: String)?>(nil)
        let factory = LiveSessionFactory(imageCache: root.appendingPathComponent("cache"), startRelay: { _, mac in
            seen.withLock { $0 = (Thread.isMainThread, mac) }
            throw Sentinel()
        })
        await #expect(throws: Sentinel.self) { _ = try await factory.makeSession(bundle: bundle) }
        let call = try #require(seen.withLock { $0 })
        #expect(!call.onMain)
        #expect(call.mac == "02:00:00:00:00:07")
    }

    /// A controlled macOS VM starts its relay the same way (M3d): never Apple's NAT.
    @Test func controlledMacVMStartsItsRelayOffTheMainActor() async throws {
        struct Sentinel: Error {}
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-app-factory-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeMacBundle(in: root)
        let mac = try bundle.updateConfig { $0.controlledNetwork = true }.macAddress
        let seen = Mutex<(onMain: Bool, mac: String)?>(nil)
        let factory = LiveSessionFactory(imageCache: root.appendingPathComponent("cache"), startRelay: { _, mac in
            seen.withLock { $0 = (Thread.isMainThread, mac) }
            throw Sentinel()
        })
        await #expect(throws: Sentinel.self) { _ = try await factory.makeSession(bundle: bundle) }
        let call = try #require(seen.withLock { $0 })
        #expect(!call.onMain)
        #expect(call.mac == mac)
    }
}
