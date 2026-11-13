// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCLI
@testable import NidoCore

private let keyBody = "AAAAC3NzaC1lZDI1NTE5AAAAIOO97YvP4YWGQwUFq+UeOnyDKkD29RZ8VdmeuGgPzeS6"
private let validKey = "ssh-ed25519 \(keyBody)"

@Suite(.italian) struct CLIParsingTests {
    private func makeTemp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeConfig(_ name: String, mac: String = "02:00:00:00:00:01") throws -> VMConfig {
        VMConfig(
            id: UUID(), name: try VMName(name), guest: .linux, cpuCount: 2,
            memoryBytes: 4 * 1024 * 1024 * 1024, diskBytes: 20 * 1024 * 1024 * 1024,
            macAddress: mac)
    }

    private func parse(
        name: String = "vm", image: String? = "debian-13", imageFile: String? = nil,
        sshKey: String? = "/tmp/id.pub", cpus: Int = 2, memory: String = "4G", disk: String = "20G",
        noPackages: Bool = false, noGuestTools: Bool = false
    ) throws -> CreateOptions {
        try CLISupport.parseCreateOptions(
            name: name, image: image, imageFile: imageFile, sshKey: sshKey,
            cpus: cpus, memory: memory, disk: disk, noPackages: noPackages, noGuestTools: noGuestTools)
    }

    @Test func createFlagsMapToProfile() throws {
        #expect(try parse().profile == .standard)
        #expect(try parse(noPackages: true).profile
            == ProvisioningProfile(essentialPackages: false, guestTools: true))
        #expect(try parse(noGuestTools: true).profile
            == ProvisioningProfile(essentialPackages: true, guestTools: false))
        #expect(try parse(noPackages: true, noGuestTools: true).profile == .empty)
    }

    // MARK: - create parsing

    @Test func createWithTraversalNameIsInvalidName() {
        #expect(throws: NidoError.invalidName("../x")) { _ = try parse(name: "../x") }
    }

    @Test func createWithBadMemoryIsInvalidSize() {
        #expect(throws: NidoError.invalidSize("4X")) { _ = try parse(memory: "4X") }
        #expect(throws: NidoError.invalidSize("20Q")) { _ = try parse(disk: "20Q") }
    }

    @Test func createWithoutSSHKeyIsParsingError() {
        #expect(throws: CLIError.missingSSHKey) { _ = try parse(sshKey: nil) }
    }

    @Test func createRequiresExactlyOneImageSource() {
        #expect(throws: CLIError.imageSourceRequired) { _ = try parse(image: nil, imageFile: nil) }
        #expect(throws: CLIError.imageSourceRequired) { _ = try parse(image: "debian-13", imageFile: "/x.raw") }
    }

    @Test func createWithUnknownCatalogImage() {
        #expect(throws: CLIError.unknownImage("ubuntu")) { _ = try parse(image: "ubuntu") }
    }

    @Test func createMemoryDefaultFollowsTheMac() throws {
        func parsed(_ physical: UInt64) throws -> UInt64 {
            try CLISupport.parseCreateOptions(
                name: "vm", image: "debian-13", imageFile: nil, sshKey: "/tmp/id.pub",
                cpus: 2, memory: nil, disk: "20G", physicalMemory: physical
            ).memoryBytes
        }
        #expect(try parsed(16 << 30) == 2 << 30)
        #expect(try parsed(32 << 30) == 4 << 30)
        // An explicit size always wins.
        #expect(try CLISupport.parseCreateOptions(
            name: "vm", image: "debian-13", imageFile: nil, sshKey: "/tmp/id.pub",
            cpus: 2, memory: "6G", disk: "20G", physicalMemory: 16 << 30
        ).memoryBytes == 6 << 30)
    }

    @Test func createParsesDefaultsAndSources() throws {
        let catalog = try parse()
        #expect(catalog.name == (try VMName("vm")))
        #expect(catalog.image == .catalog(CloudImageCatalog.debian13))
        #expect(catalog.sshKeyPath == URL(fileURLWithPath: "/tmp/id.pub"))
        #expect(catalog.cpuCount == 2)
        #expect(catalog.memoryBytes == 4 << 30)
        #expect(catalog.diskBytes == 20 << 30)

        let local = try parse(image: nil, imageFile: "/images/base.raw", cpus: 4, memory: "512M", disk: "8G")
        #expect(local.image == .file(URL(fileURLWithPath: "/images/base.raw")))
        #expect(local.cpuCount == 4)
        #expect(local.memoryBytes == 512 << 20)
        #expect(local.diskBytes == 8 << 30)
    }

    // MARK: - NIDO_ROOT

    @Test func pathsFromEnvironment() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(try CLISupport.paths(environment: ["NIDO_ROOT": tmp.path]).root.path == tmp.path)
        #expect(try CLISupport.paths(environment: [:]).root == NidoPaths.defaultRoot())
        #expect(throws: CLIError.invalidRoot("relative/dir")) {
            _ = try CLISupport.paths(environment: ["NIDO_ROOT": "relative/dir"])
        }
        let missing = tmp.appendingPathComponent("missing").path
        #expect(throws: CLIError.invalidRoot(missing)) {
            _ = try CLISupport.paths(environment: ["NIDO_ROOT": missing])
        }
        let file = tmp.appendingPathComponent("file")
        try Data().write(to: file)
        #expect(throws: CLIError.invalidRoot(file.path)) {
            _ = try CLISupport.paths(environment: ["NIDO_ROOT": file.path])
        }
    }

    // MARK: - list

    @Test func listReportsStateCPUAndMemory() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = NidoPaths(root: tmp)
        _ = try VMBundle.create(config: makeConfig("alpha"), paths: paths)
        let beta = try VMBundle.create(config: makeConfig("beta"), paths: paths)
        let lock = try BundleLock.acquire(beta, owner: .cli)
        defer { lock.release() }

        let rows = try CLISupport.listVMs(paths: paths)
        #expect(rows == [
            VMListing(name: "alpha", state: "ferma", system: "Debian 13", cpus: "2", memory: "4 GiB"),
            VMListing(name: "beta", state: "in esecuzione", system: "Debian 13", cpus: "2", memory: "4 GiB"),
        ])
        let table = CLISupport.formatList(rows)
        let lines = table.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("NOME"))
        #expect(lines[0].contains("STATO") && lines[0].contains("SISTEMA") && lines[0].contains("CPU") && lines[0].contains("MEMORIA"))
        #expect(lines[2].contains("in esecuzione"))
    }

    @Test func listMarksAppOwnedVM() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = NidoPaths(root: tmp)
        let bundle = try VMBundle.create(config: makeConfig("gamma"), paths: paths)
        let lock = try BundleLock.acquire(bundle, owner: .app)
        defer { lock.release() }
        #expect(try CLISupport.listVMs(paths: paths).map(\.state) == ["in esecuzione (app)"])
    }

    @Test func listDoesNotFollowSymlinkedConfig() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = NidoPaths(root: tmp.appendingPathComponent("VMs"))
        let bundle = try VMBundle.create(config: makeConfig("debian"), paths: paths)
        // A valid config elsewhere, with different values, reached only through the symlink.
        var other = try makeConfig("debian")
        other.cpuCount = 7
        let elsewhere = tmp.appendingPathComponent("config.json")
        try other.encoded().write(to: elsewhere)
        try FileManager.default.removeItem(at: bundle.configURL)
        try FileManager.default.createSymbolicLink(at: bundle.configURL, withDestinationURL: elsewhere)
        #expect(try CLISupport.listVMs(paths: paths) == [
            VMListing(name: "debian", state: "ferma", system: "?", cpus: "?", memory: "?"),
        ])
    }

    @Test func humanReadableBytes() {
        #expect(CLISupport.formatBytes(4 << 30) == "4 GiB")
        #expect(CLISupport.formatBytes(512 << 20) == "512 MiB")
        // The decimal separator follows the language: the test process is pinned to Italian.
        #expect(CLISupport.formatBytes(1536 << 20) == "1,5 GiB")
        #expect(CLISupport.formatBytes(1023) == "1023 B")
    }

    // MARK: - prompts and messages

    @Test func affirmativeAnswers() {
        for yes in ["s", "S", "si", "Sì", "SÌ", "y", "yes", " YES \n"] {
            #expect(CLISupport.isAffirmative(yes), "\(yes)")
        }
        for no in [nil, "", "n", "no", "sure", "ss"] as [String?] {
            #expect(!CLISupport.isAffirmative(no), "\(String(describing: no))")
        }
    }

    @Test func italianErrorMessages() {
        #expect(CLISupport.message(for: NidoError.alreadyRunning(pid: 42)) == "VM già in esecuzione (pid 42)")
        #expect(CLISupport.message(for: NidoError.notRunning("vm")) == "la VM vm non è in esecuzione")
        #expect(CLISupport.message(for: NidoError.notOnNetwork("vm")) == "VM non ancora in rete")
        #expect(CLISupport.message(for: NidoError.controlledNetworkInterrupted)
            == "rete controllata interrotta: riavvia la VM")
        #expect(CLISupport.message(for: NidoError.pidUnknown) == "VM in esecuzione ma PID sconosciuto")
        #expect(CLISupport.message(for: NidoError.keyPathNotPub("/k")) == "la chiave SSH deve essere un file .pub: /k")
        let checksum = CLISupport.message(for: NidoError.checksumMismatch(expected: "aa", actual: "bb"))
        #expect(checksum.contains("SHA-512"))
    }
}

// MARK: - Ubuntu

extension CLIParsingTests {
    @Test func createWithUbuntuCatalogImages() throws {
        #expect(try parse(image: "ubuntu-26.04").image == .catalog(CloudImageCatalog.ubuntu2604))
        #expect(try parse(image: "ubuntu-24.04").image == .catalog(CloudImageCatalog.ubuntu2404))
    }

    @Test func unknownImageListsTheWholeCatalog() {
        #expect(CLIError.unknownImage("x").errorDescription
            == "immagine sconosciuta: \"x\" (disponibili: debian-13, ubuntu-26.04, ubuntu-24.04)")
    }

    @Test func systemNameShowsTheDistribution() throws {
        var config = try makeConfig("vm")
        #expect(CLISupport.systemName(config) == "Debian 13")
        config.distribution = .ubuntu2604
        #expect(CLISupport.systemName(config) == "Ubuntu 26.04 LTS")
        config.distribution = .ubuntu2404
        #expect(CLISupport.systemName(config) == "Ubuntu 24.04 LTS")
    }
}
