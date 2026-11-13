// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCore

@Suite struct VMBundleTests {
    func makeTemp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func makeConfig(_ name: String) throws -> VMConfig {
        VMConfig(
            id: UUID(), name: try VMName(name), guest: .linux, cpuCount: 2,
            memoryBytes: 4 * 1024 * 1024 * 1024, diskBytes: 20 * 1024 * 1024 * 1024,
            macAddress: "02:00:00:00:00:01")
    }

    func perms(_ url: URL) throws -> Int {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        return (a[.posixPermissions] as! NSNumber).intValue
    }

    /// `authorized_key.pub` of a macOS VM, read for the app's panel: missing is nil; a symlink,
    /// a file over 16 KiB or someone else's is refused; the trailing newline goes.
    @Test func readAuthorizedKeyIsSafe() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let bundle = try VMBundle.create(config: makeConfig("mac"), paths: NidoPaths(root: tmp.appendingPathComponent("VMs")))
        #expect(try bundle.readAuthorizedKey() == nil)

        try Data("ssh-ed25519 AAAA tu@mac\n".utf8).write(to: bundle.authorizedKeyURL)
        #expect(try bundle.readAuthorizedKey() == "ssh-ed25519 AAAA tu@mac")

        try FileManager.default.removeItem(at: bundle.authorizedKeyURL)
        let elsewhere = tmp.appendingPathComponent("other.pub")
        try Data("ssh-ed25519 BBBB x".utf8).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: bundle.authorizedKeyURL, withDestinationURL: elsewhere)
        #expect(throws: NidoError.unsafePath("authorized_key.pub")) { try bundle.readAuthorizedKey() }

        try FileManager.default.removeItem(at: bundle.authorizedKeyURL)
        try Data(repeating: UInt8(ascii: "A"), count: 16 * 1024 + 1).write(to: bundle.authorizedKeyURL)
        #expect(throws: NidoError.unsafePath("authorized_key.pub")) { try bundle.readAuthorizedKey() }
    }

    @Test func createSetsStrictPermissions() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = NidoPaths(root: tmp.appendingPathComponent("VMs"))
        let bundle = try VMBundle.create(config: makeConfig("debian"), paths: paths)
        #expect(try perms(paths.root) == 0o700)
        #expect(try perms(bundle.url) == 0o700)
        #expect(try perms(bundle.configURL) == 0o600)
        #expect(try bundle.readConfig().name.rawValue == "debian")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: bundle.url.path)
        #expect(leftovers == ["config.json"])
    }

    @Test func writeConfigKeepsPermissions() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = NidoPaths(root: tmp.appendingPathComponent("VMs"))
        let bundle = try VMBundle.create(config: makeConfig("debian"), paths: paths)
        var c = try bundle.readConfig(); c.cpuCount = 4
        try bundle.writeConfig(c)
        #expect(try bundle.readConfig().cpuCount == 4)
        #expect(try perms(bundle.configURL) == 0o600)
    }

    @Test func v1BundleIsReadAsIsAndMigratedOnWrite() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = NidoPaths(root: tmp.appendingPathComponent("VMs"))
        let bundle = try VMBundle.create(config: makeConfig("debian"), paths: paths)
        // A config.json written by M1/M2: schema 1, none of the schema 2 fields.
        let legacy = """
            {"clipboardSharing":false,"cpuCount":2,"diskBytes":21474836480,"guest":"linux",\
            "id":"8A1C2E4B-6D3F-4A5B-9C7D-0E1F2A3B4C5D","macAddress":"02:00:00:00:00:01",\
            "memoryBytes":4294967296,"name":"debian","schemaVersion":1}
            """
        try Data(legacy.utf8).write(to: bundle.configURL)
        let before = try Data(contentsOf: bundle.configURL)
        let read = try bundle.readConfig()
        #expect(read.schemaVersion == 1)
        #expect(try Data(contentsOf: bundle.configURL) == before)  // never rewritten to read it
        try bundle.writeConfig(read)
        let migrated = try bundle.readConfig()
        #expect(migrated.schemaVersion == VMConfig.currentSchemaVersion)
        #expect(migrated.guestMountsSharedFolders == false)
        #expect(String(decoding: try Data(contentsOf: bundle.configURL), as: UTF8.self).contains("sharedFolders"))
    }

    @Test func caseInsensitiveCollision() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = NidoPaths(root: tmp.appendingPathComponent("VMs"))
        _ = try VMBundle.create(config: makeConfig("debian"), paths: paths)
        #expect(throws: NidoError.alreadyExists("Debian")) {
            _ = try VMBundle.create(config: makeConfig("Debian"), paths: paths)
        }
    }

    @Test func openMissingIsNotFound() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = NidoPaths(root: tmp.appendingPathComponent("VMs"))
        try paths.ensureRoot()
        #expect(throws: NidoError.notFound("ghost")) {
            _ = try VMBundle.open(try VMName("ghost"), paths: paths)
        }
    }

    @Test func openRejectsSymlinkOutsideRoot() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = NidoPaths(root: tmp.appendingPathComponent("VMs"))
        try paths.ensureRoot()
        let outside = tmp.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: paths.root.appendingPathComponent("x.nidovm"), withDestinationURL: outside)
        #expect(throws: NidoError.self) {
            _ = try VMBundle.open(try VMName("x"), paths: paths)
        }
        do { _ = try VMBundle.open(try VMName("x"), paths: paths) } catch {
            #expect((error as? NidoError) == .unsafePath("x"))
        }
    }

    @Test func removeRefusesSymlink() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = NidoPaths(root: tmp.appendingPathComponent("VMs"))
        try paths.ensureRoot()
        let outside = tmp.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = paths.root.appendingPathComponent("x.nidovm")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let bundle = VMBundle(url: link)
        #expect(throws: NidoError.unsafePath("x")) { try bundle.remove() }
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func removeDeletesBundle() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = NidoPaths(root: tmp.appendingPathComponent("VMs"))
        let bundle = try VMBundle.create(config: makeConfig("debian"), paths: paths)
        try bundle.remove()
        #expect(!FileManager.default.fileExists(atPath: bundle.url.path))
    }

    @Test func bundleURLStaysInsideRoot() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = NidoPaths(root: tmp.appendingPathComponent("VMs"))
        try paths.ensureRoot()
        let url = paths.bundleURL(for: try VMName("debian-13"))
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        let root = paths.root.resolvingSymlinksInPath().standardizedFileURL.path
        #expect(resolved.hasPrefix(root + "/"))
        #expect(url.lastPathComponent == "debian-13.nidovm")
    }

    @Test func bundleFileNames() throws {
        let b = VMBundle(url: URL(fileURLWithPath: "/tmp/a.nidovm", isDirectory: true))
        #expect(b.configURL.lastPathComponent == "config.json")
        #expect(b.diskURL.lastPathComponent == "disk.img")
        #expect(b.nvramURL.lastPathComponent == "nvram.efi")
        #expect(b.machineIdentifierURL.lastPathComponent == "machine-id.bin")
        #expect(b.seedURL.lastPathComponent == "seed.iso")
        #expect(b.consoleLogURL.lastPathComponent == "console.log")
        #expect(b.knownHostsURL.lastPathComponent == "known_hosts")
        #expect(b.lockURL.lastPathComponent == ".lock")
    }

    @Test func ensureRootTightensExistingPermissions() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let root = tmp.appendingPathComponent("VMs")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try NidoPaths(root: root).ensureRoot()
        #expect(try perms(root) == 0o700)
    }

    @Test func listIgnoresNoise() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = NidoPaths(root: tmp.appendingPathComponent("VMs"))
        _ = try VMBundle.create(config: makeConfig("zeta"), paths: paths)
        _ = try VMBundle.create(config: makeConfig("alpha"), paths: paths)
        try Data().write(to: paths.root.appendingPathComponent("file.txt"))
        try Data().write(to: paths.root.appendingPathComponent("plain.nidovm"))
        try FileManager.default.createDirectory(
            at: paths.root.appendingPathComponent("empty.nidovm"), withIntermediateDirectories: true)
        let list = try VMBundle.list(paths: paths)
        #expect(list.map { $0.url.lastPathComponent } == ["alpha.nidovm", "zeta.nidovm"])
    }

    @Test func ensureRootCreatesEveryNewLevelWith0700() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let outer = tmp.appendingPathComponent("Nido")
        let root = outer.appendingPathComponent("VMs")
        try NidoPaths(root: root).ensureRoot()
        #expect(try perms(outer) == 0o700)
        #expect(try perms(root) == 0o700)
    }

    @Test func openMatchesCaseInsensitively() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = NidoPaths(root: tmp.appendingPathComponent("VMs"))
        _ = try VMBundle.create(config: makeConfig("debian"), paths: paths)
        let bundle = try VMBundle.open(try VMName("DEBIAN"), paths: paths)
        #expect(bundle.url.lastPathComponent == "debian.nidovm")
    }

    // MARK: - readConfig hardening

    @Test func readConfigRefusesSymlink() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = NidoPaths(root: tmp.appendingPathComponent("VMs"))
        let bundle = try VMBundle.create(config: makeConfig("debian"), paths: paths)
        let elsewhere = tmp.appendingPathComponent("config.json")
        try FileManager.default.moveItem(at: bundle.configURL, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: bundle.configURL, withDestinationURL: elsewhere)
        #expect(throws: NidoError.unsafePath(bundle.configURL.path)) { _ = try bundle.readConfig() }
    }

    @Test func readConfigRefusesOversizedFile() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = NidoPaths(root: tmp.appendingPathComponent("VMs"))
        let bundle = try VMBundle.create(config: makeConfig("debian"), paths: paths)
        var data = try Data(contentsOf: bundle.configURL)
        data.append(Data(repeating: 0x20, count: 64 * 1024))  // trailing whitespace: still valid JSON
        try data.write(to: bundle.configURL)
        #expect(throws: NidoError.unsafePath(bundle.configURL.path)) { _ = try bundle.readConfig() }
    }

    @Test func readConfigRefusesDirectory() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = NidoPaths(root: tmp.appendingPathComponent("VMs"))
        let bundle = try VMBundle.create(config: makeConfig("debian"), paths: paths)
        try FileManager.default.removeItem(at: bundle.configURL)
        try FileManager.default.createDirectory(at: bundle.configURL, withIntermediateDirectories: false)
        #expect(throws: NidoError.unsafePath(bundle.configURL.path)) { _ = try bundle.readConfig() }
    }

    // MARK: - Tombstones

    @Test func tombstoneIsIgnoredByListAndOpen() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = NidoPaths(root: tmp.appendingPathComponent("VMs"))
        let bundle = try VMBundle.create(config: makeConfig("debian"), paths: paths)
        let tombstone = try bundle.moveToTombstone()
        #expect(tombstone.deletingLastPathComponent().standardizedFileURL == paths.root.standardizedFileURL)
        #expect(tombstone.lastPathComponent.hasPrefix(".debian.deleting-"))
        #expect(FileManager.default.fileExists(atPath: tombstone.appendingPathComponent("config.json").path))
        #expect(!FileManager.default.fileExists(atPath: bundle.url.path))
        #expect(try VMBundle.list(paths: paths).isEmpty)
        #expect(throws: NidoError.notFound("debian")) { _ = try VMBundle.open(try VMName("debian"), paths: paths) }
        try VMBundle.removeTombstone(at: tombstone)
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.root.path).isEmpty)
    }

    @Test func removeTombstoneRefusesSymlink() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let outside = tmp.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = tmp.appendingPathComponent(".x.deleting-1")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(throws: NidoError.unsafePath(link.path)) { try VMBundle.removeTombstone(at: link) }
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }
}
