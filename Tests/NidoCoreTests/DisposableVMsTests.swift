// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCore

@Suite struct DisposableVMsTests {
    private func makeRoot() throws -> NidoPaths {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-disposable-\(UUID().uuidString)", isDirectory: true)
        let paths = NidoPaths(root: dir)
        try paths.ensureRoot()
        return paths
    }

    private func makeVM(
        _ name: String, guest: GuestOS = .macos, disposable: Bool? = true, in paths: NidoPaths,
        passwords: MemoryGuestPasswordStore
    ) throws -> (bundle: VMBundle, id: UUID) {
        let id = UUID()
        let config = VMConfig(
            id: id, name: try VMName(name), guest: guest, cpuCount: 2,
            memoryBytes: 2 << 30, diskBytes: 8 << 30, macAddress: "02:00:00:00:00:01",
            disposable: disposable)
        try passwords.save(try #require(GuestPassword("secret")), vm: id)
        return (try VMBundle.create(config: config, paths: paths), id)
    }

    @Test func deleteRemovesBundleAndPassword() throws {
        let paths = try makeRoot()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let passwords = MemoryGuestPasswordStore()
        let vm = try makeVM("fresca", in: paths, passwords: passwords)

        #expect(try DisposableVMs.delete(try VMName("fresca"), paths: paths, passwords: passwords))
        #expect(!FileManager.default.fileExists(atPath: vm.bundle.url.path))
        #expect(try !passwords.contains(vm: vm.id))
    }

    @Test func deleteRefusesNotDisposable() throws {
        let paths = try makeRoot()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let passwords = MemoryGuestPasswordStore()
        let plain = try makeVM("normale", disposable: nil, in: paths, passwords: passwords)
        let linux = try makeVM("linux", guest: .linux, in: paths, passwords: passwords)

        #expect(try !DisposableVMs.delete(try VMName("normale"), paths: paths, passwords: passwords))
        #expect(try !DisposableVMs.delete(try VMName("linux"), paths: paths, passwords: passwords))
        for vm in [plain, linux] {
            #expect(FileManager.default.fileExists(atPath: vm.bundle.url.path))
            #expect(try passwords.contains(vm: vm.id))
        }
    }

    @Test func deleteRefusesARunningVM() throws {
        let paths = try makeRoot()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let passwords = MemoryGuestPasswordStore()
        let vm = try makeVM("attiva", in: paths, passwords: passwords)
        let lock = try BundleLock.acquire(vm.bundle, owner: .cli)
        defer { lock.release() }

        #expect(throws: NidoError.self) {
            try DisposableVMs.delete(try VMName("attiva"), paths: paths, passwords: passwords)
        }
        #expect(FileManager.default.fileExists(atPath: vm.bundle.url.path))
        #expect(try passwords.contains(vm: vm.id))
    }

    @Test func claimClearsTheMark() throws {
        let paths = try makeRoot()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let vm = try makeVM("avanzo", in: paths, passwords: MemoryGuestPasswordStore())
        let lock = try BundleLock.acquire(vm.bundle, owner: .cli)
        defer { lock.release() }

        try DisposableVMs.claim(vm.bundle)

        let config = try vm.bundle.readConfig()
        #expect(config.disposable == nil)
        #expect(config.name.rawValue == "avanzo")
    }

    /// A copy the user claimed never follows its base's list any more.
    @Test func claimClearsFreshBase() throws {
        let paths = try makeRoot()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let vm = try makeVM("seguace", in: paths, passwords: MemoryGuestPasswordStore())
        _ = try vm.bundle.updateConfig { $0.freshBaseID = UUID() }
        let lock = try BundleLock.acquire(vm.bundle, owner: .cli)
        defer { lock.release() }

        try DisposableVMs.claim(vm.bundle)

        let config = try vm.bundle.readConfig()
        #expect(config.disposable == nil)
        #expect(config.freshBaseID == nil)
    }

    @Test func claimLeavesAnOrdinaryVMUnchanged() throws {
        let paths = try makeRoot()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let vm = try makeVM("normale", disposable: nil, in: paths, passwords: MemoryGuestPasswordStore())
        let before = try Data(contentsOf: vm.bundle.configURL)

        try DisposableVMs.claim(vm.bundle)

        #expect(try Data(contentsOf: vm.bundle.configURL) == before)
    }

    private let now = Date()

    @Test func sweepDeletesOldStoppedDisposables() throws {
        let paths = try makeRoot()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let passwords = MemoryGuestPasswordStore()
        let vm = try makeVM("vecchia", in: paths, passwords: passwords)
        let deleted = DisposableVMs.sweep(
            paths: paths, now: now, createdAt: { _ in now.addingTimeInterval(-601) }, passwords: passwords)
        #expect(deleted.map(\.rawValue) == ["vecchia"])
        #expect(!FileManager.default.fileExists(atPath: vm.bundle.url.path))
    }

    @Test func sweepKeepsRecentOnes() throws {
        let paths = try makeRoot()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let passwords = MemoryGuestPasswordStore()
        let vm = try makeVM("recente", in: paths, passwords: passwords)
        let deleted = DisposableVMs.sweep(
            paths: paths, now: now, createdAt: { _ in now.addingTimeInterval(-599) }, passwords: passwords)
        #expect(deleted.isEmpty)
        #expect(FileManager.default.fileExists(atPath: vm.bundle.url.path))
    }

    @Test func sweepSkipsRunning() throws {
        let paths = try makeRoot()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let passwords = MemoryGuestPasswordStore()
        let vm = try makeVM("attiva", in: paths, passwords: passwords)
        let lock = try BundleLock.acquire(vm.bundle, owner: .cli)
        defer { lock.release() }
        let deleted = DisposableVMs.sweep(
            paths: paths, now: now, createdAt: { _ in now.addingTimeInterval(-9999) }, passwords: passwords)
        #expect(deleted.isEmpty)
        #expect(FileManager.default.fileExists(atPath: vm.bundle.url.path))
    }

    @Test func sweepSkipsNotDisposable() throws {
        let paths = try makeRoot()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let passwords = MemoryGuestPasswordStore()
        let vm = try makeVM("normale", disposable: nil, in: paths, passwords: passwords)
        let deleted = DisposableVMs.sweep(
            paths: paths, now: now, createdAt: { _ in now.addingTimeInterval(-9999) }, passwords: passwords)
        #expect(deleted.isEmpty)
        #expect(FileManager.default.fileExists(atPath: vm.bundle.url.path))
    }

    @Test func creationDateIsTheFolderBirth() throws {
        let paths = try makeRoot()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let vm = try makeVM("nuova", in: paths, passwords: MemoryGuestPasswordStore())
        let created = try #require(DisposableVMs.creationDate(vm.bundle))
        #expect(abs(created.timeIntervalSinceNow) < 5)
    }

    @Test func freshStartLogIsPrivate() throws {
        let paths = try makeRoot()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let vm = try makeVM("log", in: paths, passwords: MemoryGuestPasswordStore())
        let handle = try vm.bundle.openFreshStartLog()
        try handle.close()
        var info = stat()
        #expect(lstat(vm.bundle.freshStartLogURL.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)

        try FileManager.default.removeItem(at: vm.bundle.freshStartLogURL)
        try FileManager.default.createSymbolicLink(
            at: vm.bundle.freshStartLogURL, withDestinationURL: paths.root.appendingPathComponent("elsewhere"))
        #expect(throws: NidoError.self) { _ = try vm.bundle.openFreshStartLog() }
    }
}
