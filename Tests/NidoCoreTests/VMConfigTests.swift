// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import Virtualization
@testable import NidoCore

@Suite struct VMConfigTests {
    func makeConfig() throws -> VMConfig {
        VMConfig(
            id: UUID(),
            name: try VMName("debian-13"),
            guest: .linux,
            cpuCount: 2,
            memoryBytes: 4 * 1024 * 1024 * 1024,
            diskBytes: 20 * 1024 * 1024 * 1024,
            macAddress: "02:00:00:00:00:01"
        )
    }

    @Test func defaultsAreSafe() throws {
        let config = try makeConfig()
        #expect(config.clipboardSharing == false)
        #expect(config.schemaVersion == VMConfig.currentSchemaVersion)
    }

    @Test func roundtrip() throws {
        let config = try makeConfig()
        let data = try config.encoded()
        #expect(try VMConfig.decode(data) == config)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\n"))
        // Sorted keys: clipboardSharing < cpuCount < diskBytes.
        let keys = ["clipboardSharing", "cpuCount", "diskBytes"].compactMap { text.range(of: "\"\($0)\"")?.lowerBound }
        #expect(keys.count == 3 && keys == keys.sorted())
    }

    @Test func rejectsNewerSchema() throws {
        var config = try makeConfig()
        config.schemaVersion = VMConfig.currentSchemaVersion + 1
        let data = try config.encoded()
        #expect(throws: NidoError.unsupportedSchema(VMConfig.currentSchemaVersion + 1)) { try VMConfig.decode(data) }
    }

    @Test func v1ConfigDecodesWithDefaults() throws {
        let v1 = """
            {
              "clipboardSharing" : false,
              "cpuCount" : 2,
              "diskBytes" : 21474836480,
              "guest" : "linux",
              "id" : "8A1C2E4B-6D3F-4A5B-9C7D-0E1F2A3B4C5D",
              "macAddress" : "02:00:00:00:00:01",
              "memoryBytes" : 4294967296,
              "name" : "debian-13",
              "schemaVersion" : 1
            }
            """
        let config = try VMConfig.decode(Data(v1.utf8))
        #expect(config.schemaVersion == 1)
        #expect(config.sharedFolders.isEmpty)
        #expect(config.rosetta == false)
        #expect(config.suspendedConfigHash == nil)
        // Created before M3a: the guest has no fstab line for /mnt/nido.
        #expect(config.guestMountsSharedFolders == false)
        #expect(config.cpuCount == 2)
    }

    /// The wizard's phase-2 choice survives the app (Ollama and an optional model); a config
    /// without it decodes nil.
    @Test func pendingProvisioningRoundTrips() throws {
        var config = try makeConfig()
        config.pendingProvisioning = PendingProvisioning(ollama: true, model: "qwen3:0.6b")
        let decoded = try VMConfig.decode(try config.encoded())
        #expect(decoded.pendingProvisioning == PendingProvisioning(ollama: true, model: "qwen3:0.6b"))
        config.pendingProvisioning = nil
        let text = String(decoding: try config.encoded(), as: UTF8.self)
        #expect(!text.contains("pendingProvisioning"))
    }

    /// `sshSucceeded` (M3b): absent until `nido ssh` reached a macOS guest once; it
    /// changes no machine state (the suspended state still resumes).
    @Test func sshSucceededRoundTripsAndKeepsTheStateHash() throws {
        var config = try makeConfig()
        #expect(config.sshSucceeded == nil)
        #expect(!String(decoding: try config.encoded(), as: UTF8.self).contains("sshSucceeded"))
        let hash = config.stateHash()
        config.sshSucceeded = true
        let text = String(decoding: try config.encoded(), as: UTF8.self)
        #expect(text.contains("\"sshSucceeded\" : true"))
        #expect(try VMConfig.decode(try config.encoded()).sshSucceeded == true)
        #expect(config.stateHash() == hash)
    }

    @Test func newConfigIsSchema5() throws {
        let config = try makeConfig()
        #expect(VMConfig.currentSchemaVersion == 5)
        #expect(config.schemaVersion == 5)
        #expect(config.controlledNetwork == false)
        #expect(config.sshUser == nil)
        #expect(config.osVersion == nil)
        #expect(config.provisioning == nil)
        #expect(config.guestToolsVersion == nil)
        #expect(config.sshPublicKeyPath == nil)
        #expect(config.isTemplate == false)
        #expect(config.pendingProvisioning == nil)
        #expect(config.sharedFolders.isEmpty)
        #expect(config.rosetta == false)
        #expect(config.suspendedConfigHash == nil)
        let decoded = try VMConfig.decode(try config.encoded())
        #expect(decoded == config)
    }

    @Test func v2ConfigDecodesWithDefaults() throws {
        let v2 = """
            {"cpuCount":2,"diskBytes":21474836480,"guest":"linux","guestMountsSharedFolders":true,\
            "id":"8A1C2E4B-6D3F-4A5B-9C7D-0E1F2A3B4C5D","macAddress":"02:00:00:00:00:01",\
            "memoryBytes":4294967296,"name":"debian","rosetta":true,"schemaVersion":2}
            """
        let config = try VMConfig.decode(Data(v2.utf8))
        #expect(config.schemaVersion == 2)
        #expect(config.rosetta == true)
        #expect(config.provisioning == nil)
        #expect(config.guestToolsVersion == nil)
        #expect(config.sshPublicKeyPath == nil)
        #expect(config.isTemplate == false)
    }

    /// A schema 2 bundle is a Linux VM without `sshUser`/`osVersion`, and reading it never
    /// rewrites `config.json`.
    @Test func v2ConfigDecodesAsLinuxWithoutSSHUser() throws {
        let v2 = """
            {"cpuCount":2,"diskBytes":21474836480,"guest":"linux","guestMountsSharedFolders":true,\
            "id":"8A1C2E4B-6D3F-4A5B-9C7D-0E1F2A3B4C5D","macAddress":"02:00:00:00:00:01",\
            "memoryBytes":4294967296,"name":"debian","rosetta":true,"schemaVersion":2}
            """
        try expectDecodesAsLinuxWithoutRewrite(v2, schema: 2)
    }

    @Test func v3ConfigDecodesAsLinuxWithoutSSHUser() throws {
        let v3 = """
            {"cpuCount":2,"diskBytes":21474836480,"guest":"linux","guestToolsVersion":"1.3.0",\
            "id":"8A1C2E4B-6D3F-4A5B-9C7D-0E1F2A3B4C5D","isTemplate":false,"macAddress":"02:00:00:00:00:01",\
            "memoryBytes":4294967296,"name":"debian","schemaVersion":3}
            """
        try expectDecodesAsLinuxWithoutRewrite(v3, schema: 3)
    }

    /// Schema 5 (M3d): a config of every older schema, which has no `controlledNetwork`, decodes
    /// as NOT controlled, and stays so when it is written again in the current schema. A file
    /// that says true or false keeps it.
    @Test func olderConfigsAreNeverControlled() throws {
        let fields = """
            "cpuCount":2,"diskBytes":21474836480,"guest":"linux","id":"8A1C2E4B-6D3F-4A5B-9C7D-0E1F2A3B4C5D",\
            "macAddress":"02:00:00:00:00:01","memoryBytes":4294967296,"name":"debian"
            """
        for schema in 1...4 {
            let json = "{\(fields),\"schemaVersion\":\(schema)}"
            #expect(try VMConfig.decode(Data(json.utf8)).controlledNetwork == false, "schema \(schema)")

            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("nido-test-\(UUID().uuidString).nidovm", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let bundle = VMBundle(url: dir)
            try Data(json.utf8).write(to: bundle.configURL)
            // Reading never rewrites; the first write migrates to schema 5, still not controlled.
            #expect(try bundle.readConfig().controlledNetwork == false)
            #expect(try Data(contentsOf: bundle.configURL) == Data(json.utf8))
            try bundle.updateConfig { $0.cpuCount = 3 }
            let text = String(decoding: try Data(contentsOf: bundle.configURL), as: UTF8.self)
            #expect(text.contains("\"controlledNetwork\" : false"))
            #expect(text.contains("\"schemaVersion\" : 5"))
            #expect(try bundle.readConfig().controlledNetwork == false)
        }
        for value in [true, false] {
            let json = "{\(fields),\"schemaVersion\":5,\"controlledNetwork\":\(value)}"
            #expect(try VMConfig.decode(Data(json.utf8)).controlledNetwork == value)
        }
    }

    /// What a build of schema 4 does with a schema 5 file: `decode` of that build refuses any
    /// newer schema, so it can neither start a controlled VM on NAT nor rewrite its config
    /// without the field. This build behaves the same with schema 6.
    @Test func aNewerSchemaIsRefusedNotRewritten() throws {
        var config = try makeConfig()
        config.controlledNetwork = true
        config.schemaVersion = VMConfig.currentSchemaVersion + 1
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-test-\(UUID().uuidString).nidovm", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = VMBundle(url: dir)
        let data = try config.encoded()
        try data.write(to: bundle.configURL)
        #expect(throws: NidoError.unsupportedSchema(VMConfig.currentSchemaVersion + 1)) { try bundle.readConfig() }
        #expect(throws: NidoError.unsupportedSchema(VMConfig.currentSchemaVersion + 1)) {
            try bundle.updateConfig { $0.controlledNetwork = false }
        }
        #expect(try Data(contentsOf: bundle.configURL) == data)
    }

    /// The network attachment is part of the saved machine: a state saved on Apple's NAT never
    /// resumes on the relay, nor the other way round. A VM that is not controlled keeps the hash
    /// it had before the field existed, so its saved state still resumes after the update.
    @Test func controlledNetworkIsPartOfTheStateHash() throws {
        var config = try makeConfig()
        config.controlledNetwork = false
        let nat = config.stateHash()
        config.controlledNetwork = nil
        #expect(config.stateHash() == nat)
        // The hash this machine had before M3d (SHA-256 of its JSON shape without the field).
        #expect(nat == "71e6bc2c83dedfddd322ccf78fcd58e9d1ff9a4a8da2198956ad5275e19471a9")
        config.controlledNetwork = true
        #expect(config.stateHash() != nat)
        #expect(config.effectiveStateHash(attachedShareNames: [], rosettaAttached: false) == config.stateHash())
    }

    /// macOS guests have the controlled network too (M3d): the flag is written, read back
    /// and turned off like on Linux.
    @Test func macConfigWithControlledNetworkIsWritten() throws {
        var config = try makeConfig()
        config.guest = .macos
        config.controlledNetwork = true
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-test-\(UUID().uuidString).nidovm", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = VMBundle(url: dir)
        try bundle.writeConfig(config)
        #expect(try bundle.readConfig().controlledNetwork == true)
        try bundle.updateConfig { $0.cpuCount = 4 }
        #expect(try bundle.readConfig().controlledNetwork == true)
        try bundle.updateConfig { $0.controlledNetwork = false }
        #expect(try bundle.readConfig().controlledNetwork == false)
    }

    private func expectDecodesAsLinuxWithoutRewrite(_ json: String, schema: Int) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-test-\(UUID().uuidString).nidovm", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = VMBundle(url: dir)
        try Data(json.utf8).write(to: bundle.configURL)
        let config = try bundle.readConfig()
        #expect(config.schemaVersion == schema)
        #expect(config.guest == .linux)
        #expect(config.sshUser == nil)
        #expect(config.osVersion == nil)
        #expect(try Data(contentsOf: bundle.configURL) == Data(json.utf8))
    }

    /// The image's minimums are recorded at install time (optional fields of schema 4): a config
    /// without them still decodes, with nil.
    @Test func macMinimumsRoundTripAndAreOptional() throws {
        var config = try makeConfig()
        config.guest = .macos
        config.minimumCPUCount = 3
        config.minimumMemoryBytes = 6 << 30
        let data = try config.encoded()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"minimumCPUCount\" : 3"))
        #expect(text.contains("\"minimumMemoryBytes\" : 6442450944"))
        let decoded = try VMConfig.decode(data)
        #expect(decoded.minimumCPUCount == 3)
        #expect(decoded.minimumMemoryBytes == 6 << 30)
        // Not part of the saved machine state.
        #expect(decoded.stateHash() == { var c = decoded; c.minimumCPUCount = nil; c.minimumMemoryBytes = nil; return c.stateHash() }())

        config.minimumCPUCount = nil
        config.minimumMemoryBytes = nil
        let bare = String(decoding: try config.encoded(), as: UTF8.self)
        #expect(!bare.contains("minimumCPUCount") && !bare.contains("minimumMemoryBytes"))
        let old = try VMConfig.decode(Data(bare.utf8))
        #expect(old.minimumCPUCount == nil && old.minimumMemoryBytes == nil)
    }

    @Test func macConfigRoundTrips() throws {
        var config = try makeConfig()
        config.guest = .macos
        config.sshUser = "mattia"
        config.osVersion = "26.1"
        let data = try config.encoded()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"guest\" : \"macos\""))
        #expect(text.contains("\"sshUser\" : \"mattia\""))
        #expect(text.contains("\"osVersion\" : \"26.1\""))
        let decoded = try VMConfig.decode(data)
        #expect(decoded == config)
        #expect(decoded.guest == .macos)
        // Linux-only M3c features stay off on a macOS VM.
        #expect(decoded.provisioning == nil && decoded.guestToolsVersion == nil)
        #expect(decoded.aiBridge == nil && decoded.pendingProvisioning == nil && !decoded.isTemplate)
    }

    @Test func sshUserValidated() throws {
        for bad in ["Mattia", "a b", "", "1abc", "-abc", "àbc", String(repeating: "a", count: 33), "a\n"] {
            #expect(throws: NidoError.invalidSSHUser(bad)) { try VMConfig.validateSSHUser(bad) }
        }
        for good in ["mattia", "_svc", "a", "dev-1_x", String(repeating: "a", count: 32)] {
            try VMConfig.validateSSHUser(good)
        }
    }

    /// A macOS bundle is built from config, disk, auxiliary storage, hardware model and machine
    /// identifier: no seed, no EFI variable store.
    @Test func macInnerFilesHaveNoSeed() throws {
        let b = VMBundle(url: URL(fileURLWithPath: "/tmp/nido-no-such-dir/a.nidovm", isDirectory: true))
        #expect(b.auxiliaryStorageURL.lastPathComponent == "auxiliary-storage.img")
        #expect(b.hardwareModelURL.lastPathComponent == "hardware-model.bin")
        #expect(b.machineIdentifierURL.lastPathComponent == "machine-id.bin")
        #expect(b.innerFileURLs(for: .macos)
            == [b.configURL, b.diskURL, b.auxiliaryStorageURL, b.hardwareModelURL, b.machineIdentifierURL])
        #expect(b.innerFileURLs(for: .linux)
            == [b.configURL, b.diskURL, b.nvramURL, b.machineIdentifierURL, b.seedURL])
    }

    @Test func macInnerFilesAreVerifiedAndIncludeState() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-test-\(UUID().uuidString).nidovm", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let b = VMBundle(url: dir)
        for url in [b.configURL, b.diskURL, b.auxiliaryStorageURL, b.hardwareModelURL, b.machineIdentifierURL] {
            try Data("x".utf8).write(to: url)
        }
        try b.verifyInnerFiles(for: .macos)
        // The Linux set needs nvram.efi and seed.iso, which a macOS bundle does not have.
        #expect(throws: NidoError.unsafePath(b.nvramURL.path)) { try b.verifyInnerFiles(for: .linux) }
        try Data("s".utf8).write(to: b.stateURL)
        #expect(b.innerFileURLs(for: .macos).last == b.stateURL)
        try FileManager.default.removeItem(at: b.auxiliaryStorageURL)
        try FileManager.default.createSymbolicLink(at: b.auxiliaryStorageURL, withDestinationURL: b.diskURL)
        #expect(throws: NidoError.unsafePath(b.auxiliaryStorageURL.path)) { try b.verifyInnerFiles(for: .macos) }
    }

    @Test func schema3RoundtripKeepsProvisioning() throws {
        var config = try makeConfig()
        config.provisioning = .standard
        config.guestToolsVersion = "1.0.0"
        config.sshPublicKeyPath = "/Users/a/.ssh/id_ed25519.pub"
        config.isTemplate = true
        #expect(try VMConfig.decode(try config.encoded()) == config)
    }

    @Test func schema2RoundtripKeepsSharesAndHash() throws {
        var config = try makeConfig()
        config.sharedFolders = [SharedFolder(name: "progetti", hostPath: "/Users/a/Progetti", readOnly: true)]
        config.rosetta = true
        config.suspendedConfigHash = "abc"
        config.guestMountsSharedFolders = true
        #expect(try VMConfig.decode(try config.encoded()) == config)
    }

    @Test func stateHashIsDeterministicAndCoversTheMachine() throws {
        let config = try makeConfig()
        let hash = config.stateHash()
        #expect(hash.count == 64)
        #expect(hash.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(config.stateHash() == hash)
        // Fields outside the machine do not change it.
        var renamed = config
        renamed.name = try VMName("other")
        renamed.diskBytes += 1
        renamed.suspendedConfigHash = hash
        renamed.clipboardSharing = true
        #expect(renamed.stateHash() == hash)
        // Each machine field does.
        var changed = [config, config, config, config, config]
        changed[0].cpuCount += 1
        changed[1].memoryBytes += 1 << 20
        changed[2].macAddress = "02:00:00:00:00:02"
        changed[3].sharedFolders = [SharedFolder(name: "a", hostPath: "/a", readOnly: true)]
        changed[4].rosetta = true
        for other in changed { #expect(other.stateHash() != hash) }
        var readWrite = changed[3]
        readWrite.sharedFolders[0].readOnly = false
        #expect(readWrite.stateHash() != changed[3].stateHash())
    }

    @Test func existingConfigAboveLimitStillLoads() throws {
        // The limit applies to create and edit only: decoding never validates.
        var config = try makeConfig()
        config.cpuCount = 100_000
        let decoded = try VMConfig.decode(try config.encoded())
        #expect(decoded.cpuCount == 100_000)
    }

    @Test func rejectsZeroSchema() throws {
        var config = try makeConfig()
        config.schemaVersion = 0
        let data = try config.encoded()
        #expect(throws: NidoError.unsupportedSchema(0)) { try VMConfig.decode(data) }
    }
}

@Suite(.italian) struct ResourceLimitsTests {
    let gib: UInt64 = 1024 * 1024 * 1024

    @Test func acceptsReasonableValues() throws {
        try ResourceLimits.validate(cpuCount: 2, memoryBytes: 4 * gib)
    }

    @Test func rejectsZeroCPU() {
        #expect(throws: NidoError.self) { try ResourceLimits.validate(cpuCount: 0, memoryBytes: 4 * gib) }
    }

    @Test func rejectsTooManyCPU() {
        #expect(throws: NidoError.self) { try ResourceLimits.validate(cpuCount: 100_000, memoryBytes: 4 * gib) }
    }

    @Test func cpuLimitIsHostCores() throws {
        try ResourceLimits.validate(cpuCount: 8, memoryBytes: 4 * gib, hostCores: 8)
        #expect(throws: NidoError.self) {
            try ResourceLimits.validate(cpuCount: 9, memoryBytes: 4 * gib, hostCores: 8)
        }
        #expect(ResourceLimits.maxCPUCount(hostCores: 8) == 8)
        #expect(ResourceLimits.maxCPUCount(hostCores: 100_000) == VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        #expect(ResourceLimits.cpuCountRange(hostCores: 8) == ResourceLimits.cpuCountRange.lowerBound...8)
    }

    @Test func rejectsMemoryBelowMinimum() {
        #expect(throws: NidoError.self) { try ResourceLimits.validate(cpuCount: 2, memoryBytes: 1024 * 1024) }
    }

    @Test func rejectsMemoryAboveMaximum() {
        #expect(throws: NidoError.self) { try ResourceLimits.validate(cpuCount: 2, memoryBytes: UInt64.max - 1) }
    }

    @Test func rejectsMemoryNotMultipleOfMiB() {
        #expect(throws: NidoError.self) { try ResourceLimits.validate(cpuCount: 2, memoryBytes: 4 * gib + 1) }
    }

    @Test func rangesMatchValidation() throws {
        let cpus = ResourceLimits.cpuCountRange
        let memory = ResourceLimits.memoryRange
        try ResourceLimits.validate(cpuCount: cpus.lowerBound, memoryBytes: 4 * gib)
        try ResourceLimits.validate(cpuCount: cpus.upperBound, memoryBytes: 4 * gib)
        #expect(throws: NidoError.self) { try ResourceLimits.validate(cpuCount: cpus.upperBound + 1, memoryBytes: 4 * gib) }
        #expect(memory.lowerBound <= 4 * gib && 4 * gib <= memory.upperBound)
    }

    @Test func diskMustHoldTheImage() throws {
        try ResourceLimits.validateDisk(diskBytes: 16 * gib, imageBytes: 3 * gib)
        try ResourceLimits.validateDisk(diskBytes: 3 * gib, imageBytes: 3 * gib)
        #expect(throws: NidoError.invalidResources(
            "disco: \(3 * gib - 1) byte inferiori alla dimensione dell'immagine (\(3 * gib))")) {
            try ResourceLimits.validateDisk(diskBytes: 3 * gib - 1, imageBytes: 3 * gib)
        }
    }
}
