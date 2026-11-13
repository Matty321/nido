// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCLI
@testable import NidoCore

@Suite(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/hdiutil")), .italian)
struct TemplateCommandTests {
    private struct Env {
        let tmp: URL
        let paths: NidoPaths
        let key: URL

        init() throws {
            tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("nido-tests-template-cli-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            paths = NidoPaths(root: tmp.appendingPathComponent("VMs", isDirectory: true))
            let publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOO97YvP4YWGQwUFq+UeOnyDKkD29RZ8VdmeuGgPzeS6"
            key = tmp.appendingPathComponent("k.pub")
            try (publicKey + "\n").write(to: key, atomically: true, encoding: .utf8)
            let image = tmp.appendingPathComponent("base.img")
            try Data(count: 1 << 20).write(to: image)
            _ = try VMFactory(paths: paths, runner: SystemProcessRunner()).createLinux(
                LinuxVMRequest(
                    name: try VMName("vm"), baseImage: image, cpuCount: 2, memoryBytes: 1 << 30,
                    diskBytes: 4 << 20, publicKey: publicKey, sshPublicKeyPath: key.path))
        }

        func cleanup() { try? FileManager.default.removeItem(at: tmp) }
    }

    @Test func listShowsTemplate() throws {
        let env = try Env()
        defer { env.cleanup() }
        #expect(try CLISupport.listVMs(paths: env.paths).map(\.state) == ["ferma"])
        _ = try CLISupport.saveTemplate(vm: "vm", paths: env.paths)
        let rows = try CLISupport.listVMs(paths: env.paths)
        #expect(rows.map(\.state) == ["ferma (modello)"])
        #expect(CLISupport.formatList(rows).contains("ferma (modello)"))
        _ = try CLISupport.editTemplate(vm: "vm", paths: env.paths)
        #expect(try CLISupport.listVMs(paths: env.paths).map(\.state) == ["ferma"])
    }

    @Test func saveRefusesRunningAndEditRefusesNonTemplate() throws {
        let env = try Env()
        defer { env.cleanup() }
        let bundle = try VMBundle.open(try VMName("vm"), paths: env.paths)
        let lock = try BundleLock.acquire(bundle, owner: .app)
        #expect(throws: NidoError.vmMustBeStopped("vm")) { try CLISupport.saveTemplate(vm: "vm", paths: env.paths) }
        lock.release()
        #expect(throws: NidoError.notATemplate("vm")) { try CLISupport.editTemplate(vm: "vm", paths: env.paths) }
    }

    @Test func createFromTemplateAndRefusals() async throws {
        let env = try Env()
        defer { env.cleanup() }
        await #expect(throws: NidoError.notATemplate("vm")) {
            try await CLISupport.createFromTemplate(template: "vm", target: "n", sshKey: nil, paths: env.paths)
        }
        _ = try CLISupport.saveTemplate(vm: "vm", paths: env.paths)
        let text = try await CLISupport.createFromTemplate(template: "vm", target: "n", sshKey: nil, paths: env.paths)
        #expect(text.hasPrefix("VM n creata dal modello vm"))
        #expect(Set(try CLISupport.listVMs(paths: env.paths).map(\.name)) == ["vm", "n"])
        await #expect(throws: NidoError.isTemplate("vm")) {
            try await CLISupport.cloneVM(source: "vm", target: "c", paths: env.paths)
        }
        #expect(CLISupport.message(for: NidoError.isTemplate("vm"))
            == "vm è un modello: usa nido create --from-template o nido template edit")
    }
}
