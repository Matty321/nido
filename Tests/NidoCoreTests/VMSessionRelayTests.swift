// SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import NidoCore

/// Writes the seed image `hdiutil` would make (argument 6), so a Linux bundle can be created.
private struct SeedRunner: ProcessRunner {
    func run(executable: URL, arguments: [String]) throws -> ProcessResult {
        if arguments.count > 6 {
            FileManager.default.createFile(
                atPath: arguments[6], contents: Data(count: 4096), attributes: [.posixPermissions: 0o644])
        }
        return ProcessResult(status: 0, stdout: Data(), stderr: Data())
    }
}

/// An uplink that counts its stops (the relay stops it exactly once, at its shutdown).
private final class CountingUplink: EgressUplink, @unchecked Sendable {
    let gateway: UInt32 = 0xC0A8_4201
    let mask: UInt32 = 0xFFFF_FF00
    let maxPacketSize = 1514
    let guestAddress: UInt32? = nil
    let gatewayMAC: EgressMAC? = nil
    private let stops = Mutex(0)
    func onPacketsAvailable(_ handler: @escaping () -> Void) {}
    func onLost(_ handler: @escaping (String) -> Void) {}
    func read(into buffers: [UnsafeMutableRawBufferPointer]) -> [Int] { [] }
    func write(_ frames: [UnsafeRawBufferPointer]) {}
    func stop() { stops.withLock { $0 += 1 } }
    var stopCount: Int { stops.withLock { $0 } }
}

/// The app starts the relay before the session (off the main actor): whatever makes the session
/// fail afterwards, the relay is shut down, once.
@MainActor
@Suite struct VMSessionRelayTests {
    private func makeBundle(template: Bool) throws -> (VMBundle, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-session-relay-\(UUID().uuidString)", isDirectory: true)
        let config = VMConfig(
            id: UUID(), name: try VMName("rete"), guest: .linux, cpuCount: 2, memoryBytes: 2 << 30,
            diskBytes: 1 << 30, macAddress: "02:00:00:00:00:09", isTemplate: template, controlledNetwork: true)
        return (try VMBundle.create(config: config, paths: NidoPaths(root: root)), root)
    }

    private func relay(_ bundle: VMBundle, uplink: CountingUplink) throws -> (EgressRelay, DispatchQueue) {
        let relayQueue = Mutex<DispatchQueue?>(nil)
        let relay = try EgressRelay(bundle: bundle, guestMAC: "02:00:00:00:00:09", options: .init(startUplink: { queue in
            relayQueue.withLock { $0 = queue }
            return uplink
        }))
        return (relay, try #require(relayQueue.withLock { $0 }))
    }

    @Test(arguments: [true, false])
    func relayIsShutDownWhenTheSessionFails(template: Bool) throws {
        // A template is refused before anything is built; a bundle without its disk and seed
        // fails while the configuration is built.
        let (bundle, root) = try makeBundle(template: template)
        defer { try? FileManager.default.removeItem(at: root) }
        let uplink = CountingUplink()
        let (started, relayQueue) = try relay(bundle, uplink: uplink)
        let console = try SerialConsole(logURL: root.appendingPathComponent("console.log"), deliversOutput: false)
        defer { console.close() }
        #expect(throws: (any Error).self) {
            _ = try VMSession(bundle: bundle, serialConsole: console, egressRelay: started)
        }
        // The shutdown runs on the relay's queue: once the queue has run what was queued, it is done.
        relayQueue.sync {}
        #expect(uplink.stopCount == 1)
        started.shutdown()
        relayQueue.sync {}
        #expect(uplink.stopCount == 1)
    }

    /// `nido start` on Linux: the relay is started while the configuration is built; when
    /// validation then fails, it is shut down (as on macOS).
    @Test func cliRelayIsShutDownWhenValidationFails() throws {
        // Not in the temp directory: /private (the real /tmp and /var) cannot be shared.
        let root = URL(fileURLWithPath: "/Users/Shared", isDirectory: true)
            .appendingPathComponent("nido-session-relay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("base.img")
        try Data(count: 1 << 20).write(to: image)
        let factory = VMFactory(paths: NidoPaths(root: root.appendingPathComponent("VMs")), runner: SeedRunner())
        let bundle = try factory.createLinux(LinuxVMRequest(
            name: try VMName("rete"), baseImage: image, cpuCount: 2, memoryBytes: 2 << 30, diskBytes: 4 << 20,
            publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOO97YvP4YWGQwUFq+UeOnyDKkD29RZ8VdmeuGgPzeS6"))
        _ = try bundle.updateConfig { $0.controlledNetwork = true }
        let uplink = CountingUplink()
        let relayQueue = Mutex<DispatchQueue?>(nil)
        struct Invalid: Error {}
        #expect(throws: Invalid.self) {
            _ = try VMSession(
                bundle: bundle, mirrorsConsole: false, display: nil, imageCache: root.appendingPathComponent("cache"),
                egress: EgressRelay.Options(startUplink: { queue in
                    relayQueue.withLock { $0 = queue }
                    return uplink
                }), validate: { _ in throw Invalid() })
        }
        // The shutdown runs on the relay's queue: once the queue has run what was queued, it is done.
        try #require(relayQueue.withLock { $0 }).sync {}
        #expect(uplink.stopCount == 1)
    }

    /// A controlled VM suspended with 0.5.x saved a machine attached to vmnet: it never resumes
    /// behind gvproxy, it starts from cold and the start says why.
    @Test func suspendedControlledVMStartsColdAfterUpgrade() async throws {
        let (bundle, root) = try makeBundle(template: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = try bundle.readConfig()
        // The hash 0.5.x recorded for this machine: SHA-256 of its JSON shape at the time.
        struct Shape05: Encodable {
            let cpuCount: Int
            let memoryBytes: UInt64
            let macAddress: String
            let sharedFolders: [SharedFolder]
            let rosetta: Bool
            let controlledNetwork: Bool?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let old = try encoder.encode(Shape05(
            cpuCount: config.cpuCount, memoryBytes: config.memoryBytes, macAddress: config.macAddress,
            sharedFolders: config.sharedFolders, rosetta: config.rosetta, controlledNetwork: true))
        let oldHash = SHA256.hash(data: old).map { String(format: "%02x", $0) }.joined()
        try Data("saved-state".utf8).write(to: bundle.stateURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bundle.stateURL.path)
        _ = try bundle.updateConfig { $0.suspendedConfigHash = oldHash }

        // The machine this build makes from the same config.
        let machine = FakeSuspendableMachine(bundle: bundle, hash: config.stateHash(), state: .stopped)
        #expect(config.stateHash() != oldHash)
        let outcome = try await SuspendedState.boot(machine, bundle: bundle)
        #expect(outcome == .discarded(SuspendedState.configChangedWarning))
        #expect(machine.calls == ["start"])
        #expect(!FileManager.default.fileExists(atPath: bundle.stateURL.path))
        #expect(try bundle.readConfig().suspendedConfigHash == nil)
    }
}
