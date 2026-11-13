// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCore

private let validKey =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOO97YvP4YWGQwUFq+UeOnyDKkD29RZ8VdmeuGgPzeS6"
private let otherKey =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPpZ9F2m8o3X0q1kYvZ0nU5y1m3cR7wQe9a2bT4dS6hL"
private let mib: UInt64 = 1024 * 1024

/// A VM root with one prepared VM (`base`), its SSH key file, made with the real `hdiutil`.
private struct TemplateEnv {
    let tmp: URL
    let paths: NidoPaths
    let bundle: VMBundle
    let keyURL: URL

    init() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("nido-template-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        paths = NidoPaths(root: tmp.appendingPathComponent("VMs"))
        keyURL = tmp.appendingPathComponent("id_test.pub")
        try (validKey + "\n").write(to: keyURL, atomically: true, encoding: .utf8)
        let image = tmp.appendingPathComponent("base.img")
        try Data(repeating: 0xAB, count: Int(mib)).write(to: image)
        bundle = try VMFactory(paths: paths, runner: SystemProcessRunner()).createLinux(
            LinuxVMRequest(
                name: try VMName("base"), baseImage: image, cpuCount: 2, memoryBytes: 2048 * mib,
                diskBytes: 4 * mib, publicKey: validKey, profile: .init(essentialPackages: true, guestTools: true),
                sshPublicKeyPath: keyURL.path))
    }

    func cloner() -> VMCloner { VMCloner(paths: paths, runner: SystemProcessRunner()) }

    func makeTemplate() throws {
        try VMControl.editConfig(bundle, owner: .cliOperation) {
            $0.isTemplate = true
            $0.guestToolsVersion = "1.2.3"
        }
    }

    func cleanup() { try? FileManager.default.removeItem(at: tmp) }
}

@Suite(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/hdiutil")))
struct TemplateTests {
    @Test func saveRequiresStoppedVM() throws {
        let env = try TemplateEnv()
        defer { env.cleanup() }
        let lock = try BundleLock.acquire(env.bundle, owner: .app)
        #expect(throws: NidoError.vmMustBeStopped("base")) {
            try VMTemplates.save(env.bundle, owner: .cliOperation)
        }
        lock.release()
        #expect(try env.bundle.readConfig().isTemplate == false)
        // Suspended state: refused too.
        try Data("state".utf8).write(to: env.bundle.stateURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: env.bundle.stateURL.path)
        try VMControl.editConfig(env.bundle, owner: .cli) { $0.suspendedConfigHash = $0.stateHash() }
        #expect(throws: NidoError.templateHasSuspendedState("base")) {
            try VMTemplates.save(env.bundle, owner: .cliOperation)
        }
        #expect(try env.bundle.readConfig().isTemplate == false)
    }

    @Test func saveKeepsSnapshots() async throws {
        let env = try TemplateEnv()
        defer { env.cleanup() }
        try await SnapshotStore(bundle: env.bundle).create(name: "pulito", owner: .cli, session: nil)
        try VMTemplates.save(env.bundle, owner: .cliOperation)
        #expect(try SnapshotStore(bundle: env.bundle).list().count == 1)
        #expect(try env.bundle.readConfig().isTemplate)
    }

    @MainActor @Test func templateCannotStart() throws {
        let env = try TemplateEnv()
        defer { env.cleanup() }
        try env.makeTemplate()
        #expect(throws: NidoError.isTemplate("base")) { _ = try VMSession(bundle: env.bundle) }
    }

    @Test func templateCannotBeClonedPlainly() async throws {
        let env = try TemplateEnv()
        defer { env.cleanup() }
        try env.makeTemplate()
        await #expect(throws: NidoError.isTemplate("base")) {
            _ = try await env.cloner().clone(try VMName("base"), as: try VMName("copia"), owner: .cli)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: env.paths.root.path) == ["base.nidovm"])
    }

    @Test func fromTemplateRefusesNonTemplate() async throws {
        let env = try TemplateEnv()
        defer { env.cleanup() }
        await #expect(throws: NidoError.notATemplate("base")) {
            _ = try await env.cloner().createFromTemplate(
                try VMName("base"), as: try VMName("nuova"), sshKeyPath: nil, owner: .cliOperation)
        }
    }

    @Test func fromTemplateGetsIdentityOnlySeed() async throws {
        let env = try TemplateEnv()
        defer { env.cleanup() }
        try env.makeTemplate()
        let vm = try await env.cloner().createFromTemplate(
            try VMName("base"), as: try VMName("nuova"), sshKeyPath: nil, owner: .cliOperation)
        let config = try vm.readConfig()
        let source = try env.bundle.readConfig()
        #expect(config.id != source.id && config.macAddress != source.macAddress)
        #expect(!config.isTemplate)
        #expect(config.sshPublicKeyPath == env.keyURL.path)
        let userData = try CloudInitSeed.readFile("user-data", fromISO: vm.seedURL)
        #expect(userData == CloudInitSeed.userDataForTemplateClone(username: "nido", publicKey: validKey))
        #expect(!userData.contains("packages") && !userData.contains("write_files") && !userData.contains("runcmd"))
        #expect(userData.contains("ssh_deletekeys: true"))
        let meta = try CloudInitSeed.readFile("meta-data", fromISO: vm.seedURL)
        #expect(meta == CloudInitSeed.metaData(instanceID: config.id, hostname: config.name))
        #expect(try Data(contentsOf: vm.diskURL) == (try Data(contentsOf: env.bundle.diskURL)))
        // The template is untouched and still a template.
        #expect(try env.bundle.readConfig().isTemplate)
    }

    @Test func fromTemplateUsesExplicitKeyAndStoresIt() async throws {
        let env = try TemplateEnv()
        defer { env.cleanup() }
        try env.makeTemplate()
        let other = env.tmp.appendingPathComponent("altra.pub")
        try (otherKey + "\n").write(to: other, atomically: true, encoding: .utf8)
        let vm = try await env.cloner().createFromTemplate(
            try VMName("base"), as: try VMName("nuova"), sshKeyPath: other, owner: .cliOperation)
        #expect(try vm.readConfig().sshPublicKeyPath == other.path)
        let userData = try CloudInitSeed.readFile("user-data", fromISO: vm.seedURL)
        #expect(userData.contains(otherKey) && !userData.contains(validKey))
    }

    @Test func fromTemplateMissingKeyAsksForSSHKey() async throws {
        let env = try TemplateEnv()
        defer { env.cleanup() }
        try env.makeTemplate()
        try FileManager.default.removeItem(at: env.keyURL)
        await #expect(throws: NidoError.templateKeyMissing(env.keyURL.path)) {
            _ = try await env.cloner().createFromTemplate(
                try VMName("base"), as: try VMName("nuova"), sshKeyPath: nil, owner: .cliOperation)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: env.paths.root.path) == ["base.nidovm"])
        let message = NidoError.templateKeyMissing(env.keyURL.path).errorDescription ?? ""
        #expect(message.contains("--ssh-key"))
    }

    @Test func fromTemplateHasNoSharedFolders() async throws {
        let env = try TemplateEnv()
        defer { env.cleanup() }
        try VMControl.editConfig(env.bundle, owner: .cli) {
            $0.sharedFolders = [SharedFolder(name: "progetti", hostPath: "/Users/Shared/progetti", readOnly: false)]
            $0.aiBridge = AIBridgePolicy(enabled: true, allowedModels: ["org/m"], privacyAcknowledged: true)
        }
        try env.makeTemplate()
        let vm = try await env.cloner().createFromTemplate(
            try VMName("base"), as: try VMName("nuova"), sshKeyPath: nil, owner: .cliOperation)
        #expect(try vm.readConfig().sharedFolders.isEmpty)
        #expect(try vm.readConfig().aiBridge == nil)
    }

    @Test func fromTemplateKeepsGuestToolsVersion() async throws {
        let env = try TemplateEnv()
        defer { env.cleanup() }
        try env.makeTemplate()
        let vm = try await env.cloner().createFromTemplate(
            try VMName("base"), as: try VMName("nuova"), sshKeyPath: nil, owner: .cliOperation)
        let config = try vm.readConfig()
        #expect(config.guestToolsVersion == "1.2.3")
        #expect(config.provisioning == (try env.bundle.readConfig()).provisioning)
        #expect(config.cpuCount == 2 && config.memoryBytes == 2048 * mib)
    }

    @Test func editMakesStartable() throws {
        let env = try TemplateEnv()
        defer { env.cleanup() }
        try env.makeTemplate()
        try VMTemplates.edit(env.bundle, owner: .cliOperation)
        let config = try env.bundle.readConfig()
        #expect(!config.isTemplate)
        // A VM that is not a template: edit refuses.
        #expect(throws: NidoError.notATemplate("base")) { try VMTemplates.edit(env.bundle, owner: .cliOperation) }
    }

    @Test func summaryShowsTemplate() async throws {
        let env = try TemplateEnv()
        defer { env.cleanup() }
        #expect(try await VMRegistry(paths: env.paths).summaries().map(\.isTemplate) == [false])
        try env.makeTemplate()
        #expect(try await VMRegistry(paths: env.paths).summaries().map(\.isTemplate) == [true])
    }
}
