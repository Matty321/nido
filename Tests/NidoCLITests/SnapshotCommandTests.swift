// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCLI
@testable import NidoCore

@Suite(.italian) struct SnapshotCommandTests {
    private struct Env {
        let tmp: URL
        let paths: NidoPaths
        let bundle: VMBundle

        init() throws {
            tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("nido-tests-snapshot-cli-\(UUID().uuidString)", isDirectory: true)
            paths = NidoPaths(root: tmp.appendingPathComponent("VMs", isDirectory: true))
            let config = VMConfig(
                id: UUID(), name: try VMName("vm"), guest: .linux, cpuCount: 2,
                memoryBytes: 1 << 30, diskBytes: 1 << 20, macAddress: "02:00:00:00:00:01")
            bundle = try VMBundle.create(config: config, paths: paths)
            for (url, text) in [(bundle.diskURL, "disk-v1"), (bundle.nvramURL, "nvram"),
                                (bundle.machineIdentifierURL, "id"), (bundle.seedURL, "seed")] {
                try Data(text.utf8).write(to: url)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }

        func cleanup() { try? FileManager.default.removeItem(at: tmp) }
    }

    @Test func createListRestoreDelete() async throws {
        let env = try Env()
        defer { env.cleanup() }
        #expect(try CLISupport.listSnapshots(vm: "vm", paths: env.paths) == "Nessuno snapshot.")
        let created = try await CLISupport.createSnapshot(vm: "vm", name: "prima", paths: env.paths)
        #expect(created.hasPrefix("Snapshot prima di vm creato"))
        let list = try CLISupport.listSnapshots(vm: "vm", paths: env.paths)
        #expect(list.hasPrefix("NOME"))
        #expect(list.contains("prima"))
        #expect(list.contains("solo disco"))

        try Data("disk-v2".utf8).write(to: env.bundle.diskURL)
        let restored = try CLISupport.restoreSnapshot(vm: "vm", reference: "PRIMA", paths: env.paths)
        #expect(restored.contains("ripristinata allo snapshot prima"))
        #expect(try String(contentsOf: env.bundle.diskURL, encoding: .utf8) == "disk-v1")

        #expect(try CLISupport.deleteSnapshot(vm: "vm", reference: "prima", paths: env.paths)
            == "Snapshot prima eliminato.")
        #expect(throws: NidoError.snapshotNotFound("prima")) {
            _ = try CLISupport.deleteSnapshot(vm: "vm", reference: "prima", paths: env.paths)
        }
    }

    @Test func templateRestoreIsRefused() async throws {
        let env = try Env()
        defer { env.cleanup() }
        _ = try await CLISupport.createSnapshot(vm: "vm", name: "prima", paths: env.paths)
        try Data("disk-v2".utf8).write(to: env.bundle.diskURL)
        try env.bundle.updateConfig { $0.isTemplate = true }
        #expect(throws: NidoError.isTemplate("vm")) {
            _ = try CLISupport.restoreSnapshot(vm: "vm", reference: "prima", paths: env.paths)
        }
        #expect(try String(contentsOf: env.bundle.diskURL, encoding: .utf8) == "disk-v2")
    }

    @Test func refusedWhileRunning() async throws {
        let env = try Env()
        defer { env.cleanup() }
        _ = try await CLISupport.createSnapshot(vm: "vm", name: "prima", paths: env.paths)
        // Held by this process (as `nido start` would hold it in its own): the stopped-only paths refuse.
        let lock = try BundleLock.acquire(env.bundle, owner: .cli)
        defer { lock.release() }
        await #expect(throws: NidoError.vmMustBeStopped("vm")) {
            _ = try await CLISupport.createSnapshot(vm: "vm", name: "seconda", paths: env.paths)
        }
        #expect(throws: NidoError.vmMustBeStopped("vm")) {
            _ = try CLISupport.restoreSnapshot(vm: "vm", reference: "prima", paths: env.paths)
        }
    }
}

extension SnapshotCommandTests {
    private func suspend(_ env: Env, hash: String) throws {
        try Data("state".utf8).write(to: env.bundle.stateURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: env.bundle.stateURL.path)
        var config = try env.bundle.readConfig()
        config.suspendedConfigHash = hash
        try env.bundle.writeConfig(config)
    }

    /// CORE m4: a resume is promised only when the snapshot's state still fits the VM's config.
    @Test func restorePromisesAResumeOnlyWhenTheConfigMatches() async throws {
        let env = try Env()
        defer { env.cleanup() }
        try suspend(env, hash: try env.bundle.readConfig().stateHash())
        _ = try await CLISupport.createSnapshot(vm: "vm", name: "sospesa", paths: env.paths)
        #expect(try CLISupport.restoreSnapshot(vm: "vm", reference: "sospesa", paths: env.paths)
            .hasSuffix("Al prossimo avvio la VM riprende dallo stato salvato."))
        var config = try env.bundle.readConfig()
        config.cpuCount = 4
        try env.bundle.writeConfig(config)
        let message = try CLISupport.restoreSnapshot(vm: "vm", reference: "sospesa", paths: env.paths)
        #expect(message.hasSuffix("La configurazione è cambiata dopo lo snapshot: al prossimo avvio lo stato salvato verrà scartato e la VM partirà a freddo."))
    }

    /// CORE m6: the confirmation says what a restore loses.
    @Test func restoreQuestionMentionsTheSuspendedSession() throws {
        #expect(CLISupport.restoreQuestion(vm: "vm", snapshot: "prima", suspended: false)
            == "Ripristinare vm allo snapshot prima? Le modifiche successive al disco andranno perse. [s/N] ")
        #expect(CLISupport.restoreQuestion(vm: "vm", snapshot: "prima", suspended: true)
            == "Ripristinare vm allo snapshot prima? Le modifiche successive al disco e la sessione sospesa di vm andranno perse. [s/N] ")
    }
}
