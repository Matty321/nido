// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCLI
@testable import NidoCore

@Suite(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/hdiutil")), .italian)
struct CloneCommandTests {
    private struct Env {
        let tmp: URL
        let paths: NidoPaths
        let bundle: VMBundle

        init() throws {
            tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("nido-tests-clone-cli-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            paths = NidoPaths(root: tmp.appendingPathComponent("VMs", isDirectory: true))
            let image = tmp.appendingPathComponent("base.img")
            try Data(count: 1 << 20).write(to: image)
            bundle = try VMFactory(paths: paths, runner: SystemProcessRunner()).createLinux(
                LinuxVMRequest(
                    name: try VMName("vm"), baseImage: image, cpuCount: 2, memoryBytes: 1 << 30,
                    diskBytes: 4 << 20,
                    publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOO97YvP4YWGQwUFq+UeOnyDKkD29RZ8VdmeuGgPzeS6"))
        }

        func cleanup() { try? FileManager.default.removeItem(at: tmp) }
    }

    @Test func clonesAStoppedVM() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let text = try await CLISupport.cloneVM(source: "vm", target: "vm-copia", paths: env.paths)
        #expect(text == "VM vm-copia creata come copia di vm: nuovo indirizzo di rete e nuova identità; al primo avvio il nome host diventa vm-copia.")
        #expect(Set(try CLISupport.listVMs(paths: env.paths).map(\.name)) == ["vm", "vm-copia"])
    }

    @Test func saysWhatIsNotCopied() async throws {
        let env = try Env()
        defer { env.cleanup() }
        try Data("state".utf8).write(to: env.bundle.stateURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: env.bundle.stateURL.path)
        var config = try env.bundle.readConfig()
        config.suspendedConfigHash = config.stateHash()
        try env.bundle.writeConfig(config)
        for name in ["a", "b"] {
            try await SnapshotStore(bundle: env.bundle).create(name: name, owner: .cli, session: nil)
        }
        let text = try await CLISupport.cloneVM(source: "vm", target: "copia", paths: env.paths)
        #expect(text.contains("Lo stato sospeso di vm non è stato copiato: la copia parte a freddo."))
        #expect(text.contains("Gli snapshot di vm (2) non sono stati copiati."))
    }

    /// One snapshot: the singular sentence, without the count.
    @Test func saysTheOnlySnapshotIsNotCopied() async throws {
        let env = try Env()
        defer { env.cleanup() }
        try await SnapshotStore(bundle: env.bundle).create(name: "a", owner: .cli, session: nil)
        let text = try await CLISupport.cloneVM(source: "vm", target: "copia", paths: env.paths)
        #expect(text.contains("L'unico snapshot di vm non è stato copiato."))
        #expect(!text.contains("(1)"))
    }

    @Test func refusesARunningVMInItalian() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let lock = try BundleLock.acquire(env.bundle, owner: .app)
        defer { lock.release() }
        do {
            _ = try await CLISupport.cloneVM(source: "vm", target: "copia", paths: env.paths)
            Issue.record("expected a refusal")
        } catch {
            #expect(CLISupport.message(for: error) == "la VM vm è in esecuzione: arrestala prima di clonarla")
        }
    }

    @Test func refusesATakenNameAndAnInvalidOne() async throws {
        let env = try Env()
        defer { env.cleanup() }
        await #expect(throws: NidoError.alreadyExists("VM")) {
            try await CLISupport.cloneVM(source: "vm", target: "VM", paths: env.paths)
        }
        await #expect(throws: NidoError.invalidName("../x")) {
            try await CLISupport.cloneVM(source: "vm", target: "../x", paths: env.paths)
        }
    }
}

/// `nido clone` of a macOS VM: the steps to run in the guest follow the summary.
@Suite(.italian) struct MacCloneCommandTests {
    @Test func macCloneShowsTheGuestSteps() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-tests-clone-mac-cli-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = NidoPaths(root: tmp.appendingPathComponent("VMs", isDirectory: true))
        let config = VMConfig(
            id: UUID(), name: try VMName("mac"), guest: .macos, cpuCount: 2, memoryBytes: 4 << 30,
            diskBytes: 1 << 20, macAddress: "02:00:00:00:00:01", sshUser: "mattia", osVersion: "26.1")
        let bundle = try VMBundle.create(config: config, paths: paths)
        // The cloner checks and copies files; their content is not read.
        for url in [bundle.diskURL, bundle.auxiliaryStorageURL, bundle.hardwareModelURL, bundle.machineIdentifierURL] {
            try MachineFileCopy.writeNewFile(url, data: Data("x".utf8))
        }

        let text = try await CLISupport.cloneVM(source: "mac", target: "mac-copia", paths: paths)

        #expect(text.hasPrefix("VM mac-copia creata come copia di mac: nuovo indirizzo di rete e nuovo identificatore della macchina."))
        #expect(!text.contains("nome host diventa"))
        for step in VMCloner.cloneNotes(guest: .macos, name: try VMName("mac-copia")) {
            #expect(text.contains("  " + step))
        }
        #expect(text.contains("sudo scutil --set ComputerName mac-copia"))
    }
}
