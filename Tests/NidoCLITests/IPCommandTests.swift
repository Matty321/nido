// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import Testing
@testable import NidoCLI
@testable import NidoCore

@Suite(.italian) struct IPCommandTests {
    private func makeTemp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-ip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func config(_ name: String, controlled: Bool) throws -> VMConfig {
        var config = VMConfig(
            id: UUID(), name: try VMName(name), guest: .linux, cpuCount: 2, memoryBytes: 4 << 30,
            diskBytes: 20 << 30, macAddress: "02:00:00:00:00:01")
        config.controlledNetwork = controlled
        return config
    }

    @Test func controlledVMPrintsGvproxyAddressAndForward() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        // A running process named gvproxy: a copy of sleep, made once (`StableExecutables`).
        let gv = Process()
        gv.executableURL = try StableExecutables.fakeGvproxy.get()
        gv.arguments = ["60"]
        try gv.run()
        defer { gv.terminate(); gv.waitUntilExit() }

        let bundle = try VMBundle.create(config: config("ctl", controlled: true), paths: NidoPaths(root: tmp))
        let lock = try BundleLock.acquire(bundle, owner: .cli)
        defer { lock.release() }
        try Data("{\"pid\":\(gv.processIdentifier),\"port\":50123}".utf8).write(to: bundle.sshForwardURL)
        chmod(bundle.sshForwardURL.path, 0o600)
        let text = try CLISupport.ipDescription(bundle: bundle, leasesURL: tmp.appendingPathComponent("none"))
        #expect(text == "192.168.127.2 (SSH dal Mac: 127.0.0.1:50123)")
    }

    @Test func natVMPrintsTheLeaseAddressOnly() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let bundle = try VMBundle.create(config: config("nat", controlled: false), paths: NidoPaths(root: tmp))
        let lock = try BundleLock.acquire(bundle, owner: .cli)
        defer { lock.release() }
        let leases = tmp.appendingPathComponent("dhcpd_leases")
        try Data("""
            {
            \tname=nat
            \tip_address=192.168.64.5
            \thw_address=1,2:0:0:0:0:1
            \tlease=0x7fffffff
            }

            """.utf8).write(to: leases)
        #expect(try CLISupport.ipDescription(bundle: bundle, leasesURL: leases) == "192.168.64.5")
    }
}
