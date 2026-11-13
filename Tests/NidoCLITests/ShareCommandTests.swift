// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCLI
@testable import NidoCore

@Suite(.italian) struct ShareCommandTests {
    private struct Env {
        let tmp: URL
        let paths: NidoPaths
        let cache: URL
        let home: URL
        let folder: URL
        let bundle: VMBundle

        init(guestMounts: Bool = true, guest: GuestOS = .linux) throws {
            let fm = FileManager.default
            // Not in the temp directory: /private (the real /tmp and /var) cannot be shared.
            tmp = URL(fileURLWithPath: "/Users/Shared", isDirectory: true)
                .appendingPathComponent("nido-tests-share-cli-\(UUID().uuidString)", isDirectory: true)
            paths = NidoPaths(root: tmp.appendingPathComponent("VMs", isDirectory: true))
            cache = tmp.appendingPathComponent("cache", isDirectory: true)
            home = tmp.appendingPathComponent("home", isDirectory: true)
            folder = home.appendingPathComponent("Progetti", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.createDirectory(at: cache, withIntermediateDirectories: true)
            var config = VMConfig(
                id: UUID(), name: try VMName("vm"), guest: guest, cpuCount: 2,
                memoryBytes: 4 << 30, diskBytes: 20 << 30, macAddress: "02:00:00:00:00:01")
            config.guestMountsSharedFolders = guestMounts
            bundle = try VMBundle.create(config: config, paths: paths)
        }

        func add(_ path: String? = nil, name: String? = nil, readWrite: Bool = false) throws -> String {
            try CLISupport.addShare(
                vm: "vm", path: path ?? folder.path, name: name, readWrite: readWrite,
                paths: paths, imageCache: cache, home: home)
        }

        func cleanup() { try? FileManager.default.removeItem(at: tmp) }
    }

    /// macOS shows the folders in /Volumes/My Shared Files (automount tag): no Linux mount path
    /// and no one-off Linux command, whatever `guestMountsSharedFolders` says.
    @Test func macShareListShowsVolumesPath() throws {
        let env = try Env(guestMounts: false, guest: .macos)
        defer { env.cleanup() }
        let added = try env.add()
        #expect(added.contains("→ /Volumes/My Shared Files/Progetti"))
        #expect(!added.contains("/mnt/nido"))
        #expect(!added.contains(SharedFolder.legacyGuestCommand))
        let list = try CLISupport.listShares(vm: "vm", paths: env.paths, imageCache: env.cache, home: env.home)
        #expect(list.contains("/Volumes/My Shared Files/Progetti"))
        #expect(!list.contains("/mnt/nido"))
        #expect(!list.contains(SharedFolder.legacyGuestCommand))
        #expect(!list.contains("versione precedente di Nido"))
        // Linux keeps its mount point.
        #expect(SharedFolder(name: "a", hostPath: "/x").guestPath(for: .linux) == "/mnt/nido/a")
        #expect(SharedFolder(name: "a", hostPath: "/x").guestPath(for: .macos) == "/Volumes/My Shared Files/a")
    }

    @Test func templateSharesAreRefused() throws {
        let env = try Env()
        defer { env.cleanup() }
        _ = try env.add()
        try env.bundle.updateConfig { $0.isTemplate = true }
        #expect(throws: NidoError.isTemplate("vm")) { _ = try env.add(name: "Altra") }
        #expect(throws: NidoError.isTemplate("vm")) {
            _ = try CLISupport.removeShare(vm: "vm", name: "Progetti", paths: env.paths)
        }
        #expect(try env.bundle.readConfig().sharedFolders.map(\.name) == ["Progetti"])
        #expect(CLISupport.message(for: NidoError.isTemplate("vm")).contains("è un modello"))
    }

    @Test func shareAddRequiresStoppedVM() throws {
        let env = try Env()
        defer { env.cleanup() }
        let lock = try BundleLock.acquire(env.bundle, owner: .cli)
        #expect(throws: NidoError.vmMustBeStopped("vm")) { _ = try env.add() }
        #expect(throws: NidoError.vmMustBeStopped("vm")) {
            _ = try CLISupport.removeShare(vm: "vm", name: "Progetti", paths: env.paths)
        }
        lock.release()
        #expect(try env.bundle.readConfig().sharedFolders.isEmpty)
    }

    @Test func cliShareOnRunningAppVMRefused() throws {
        let env = try Env()
        defer { env.cleanup() }
        _ = try env.add()
        let lock = try BundleLock.acquire(env.bundle, owner: .app)
        defer { lock.release() }
        let text = "la VM è accesa in Nido: cambia le cartelle dall'app o arrestala prima"
        #expect(NidoError.vmRunningInApp("vm").errorDescription == text)
        #expect(throws: NidoError.vmRunningInApp("vm")) { _ = try env.add(name: "altra") }
        #expect(throws: NidoError.vmRunningInApp("vm")) {
            _ = try CLISupport.removeShare(vm: "vm", name: "Progetti", paths: env.paths)
        }
        // Nothing changed.
        #expect(try env.bundle.readConfig().sharedFolders.map(\.name) == ["Progetti"])
    }

    @Test func addIsReadOnlyByDefaultAndListed() throws {
        let env = try Env()
        defer { env.cleanup() }
        let message = try env.add()
        #expect(message.contains("/mnt/nido/Progetti"))
        #expect(message.contains("sola lettura"))
        #expect(!message.contains("sudo"))  // created with the cloud-init mount
        let config = try env.bundle.readConfig()
        #expect(config.schemaVersion == VMConfig.currentSchemaVersion)
        #expect(config.sharedFolders == [SharedFolder(
            name: "Progetti", hostPath: realPath(env.folder), readOnly: true)])
        let list = try CLISupport.listShares(vm: "vm", paths: env.paths)
        #expect(list.contains("Progetti"))
        #expect(list.contains("sola lettura"))
        // The lock is released afterwards.
        #expect(BundleLock.holder(env.bundle) == nil)
    }

    @Test func addReadWriteWithNameAndRemove() throws {
        let env = try Env()
        defer { env.cleanup() }
        let message = try env.add(name: "lavoro", readWrite: true)
        #expect(message.contains("lettura e scrittura"))
        #expect(throws: NidoError.shareNameTaken("LAVORO")) { _ = try env.add(name: "LAVORO") }
        #expect(try env.bundle.readConfig().sharedFolders.first?.readOnly == false)
        _ = try CLISupport.removeShare(vm: "vm", name: "lavoro", paths: env.paths)
        #expect(try env.bundle.readConfig().sharedFolders.isEmpty)
        #expect(throws: NidoError.shareNotFound("lavoro")) {
            _ = try CLISupport.removeShare(vm: "vm", name: "lavoro", paths: env.paths)
        }
    }

    @Test func addRefusesDangerousPaths() throws {
        let env = try Env()
        defer { env.cleanup() }
        for path in ["/", env.home.path, env.paths.root.path, "Progetti"] {
            #expect(throws: NidoError.self) { _ = try env.add(path) }
        }
        #expect(try env.bundle.readConfig().sharedFolders.isEmpty)
    }

    @Test func olderVMGetsTheGuestCommand() throws {
        let env = try Env(guestMounts: false)
        defer { env.cleanup() }
        let message = try env.add()
        #expect(message.contains(SharedFolder.legacyGuestCommand))
        #expect(try CLISupport.listShares(vm: "vm", paths: env.paths).contains(SharedFolder.legacyGuestCommand))
    }

    @Test func emptyList() throws {
        let env = try Env()
        defer { env.cleanup() }
        #expect(try CLISupport.listShares(vm: "vm", paths: env.paths) == "Nessuna cartella condivisa.")
    }
}

private func realPath(_ url: URL) -> String {
    guard let resolved = realpath(url.path, nil) else { return url.path }
    defer { free(resolved) }
    return String(cString: resolved)
}

extension ShareCommandTests {
    /// CORE m5: an edit on a suspended VM says its saved state will be discarded.
    @Test func editsOfASuspendedVMWarnThatTheStateIsDiscarded() throws {
        let env = try Env()
        defer { env.cleanup() }
        let warning = "Attenzione: la VM è sospesa: al prossimo avvio lo stato salvato verrà scartato."
        #expect(!(try env.add()).contains(warning))
        // Suspended with the current config.
        try Data("state".utf8).write(to: env.bundle.stateURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: env.bundle.stateURL.path)
        var config = try env.bundle.readConfig()
        config.suspendedConfigHash = config.stateHash()
        try env.bundle.writeConfig(config)
        #expect(try CLISupport.removeShare(vm: "vm", name: "Progetti", paths: env.paths).contains(warning))
    }

    /// SECURITY L4: a path from config.json is printed without its control characters.
    @Test func listEscapesControlCharacters() throws {
        let env = try Env()
        defer { env.cleanup() }
        var config = try env.bundle.readConfig()
        config.sharedFolders = [SharedFolder(name: "x", hostPath: "/nonexistent\u{1B}]52;c;eA==\u{07}")]
        try env.bundle.writeConfig(config)
        let list = try CLISupport.listShares(vm: "vm", paths: env.paths, imageCache: env.cache, home: env.home)
        #expect(!list.unicodeScalars.contains { $0.properties.generalCategory == .control && $0 != "\n" })
        #expect(list.contains("\\u{1B}"))
    }
}
