// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import NidoCore
import Synchronization
import Testing

@testable import Nido

@MainActor
struct VMSettingsModelTests {
    private func makeBundle(cpuCount: Int = 2) throws -> (VMBundle, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-settings-\(UUID().uuidString)", isDirectory: true)
        let paths = NidoPaths(root: root)
        let config = VMConfig(
            id: UUID(), name: try VMName("debian-13"), guest: .linux, cpuCount: cpuCount,
            memoryBytes: UInt64(4) << 30, diskBytes: UInt64(32) << 30, macAddress: "52:54:00:12:34:56")
        return (try VMBundle.create(config: config, paths: paths), root)
    }

    private func makeMacBundle(user: String? = "agente", minimums: (Int, UInt64)? = nil) throws -> (VMBundle, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-settings-\(UUID().uuidString)", isDirectory: true)
        var config = VMConfig(
            id: UUID(), name: try VMName("macos-agenti"), guest: .macos, cpuCount: 4,
            memoryBytes: UInt64(8) << 30, diskBytes: UInt64(64) << 30, macAddress: "52:54:00:12:34:57",
            sshUser: user, osVersion: "26.6")
        config.minimumCPUCount = minimums?.0
        config.minimumMemoryBytes = minimums?.1
        return (try VMBundle.create(config: config, paths: NidoPaths(root: root)), root)
    }

    /// S08 for macOS (R4): no Rosetta, no Guest Tools, no one-time Linux mount command; the
    /// shared folders live in /Volumes/My Shared Files.
    @Test func macSettingsHideRosetta() async throws {
        let (bundle, root) = try makeMacBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try VMSettingsModel(bundle: bundle, rosettaState: { .installed })
        #expect(model.guest == .macos)
        #expect(!model.showsRosetta)
        #expect(!model.showsGuestTools)
        #expect(model.sectionNames == ["Generale", "Hardware", "Condivisione"])
        // A macOS config never has guestMountsSharedFolders: no Linux fstab command for it.
        #expect(model.legacyGuestCommand == nil)
        #expect(model.rosettaLegacyCommand == nil)
        #expect(model.guestMountPoint == "/Volumes/My Shared Files")
        #expect(model.sharesIntro.contains("/Volumes/My Shared Files"))
        #expect(!model.sharesIntro.contains("/mnt/nido"))
        #expect(!model.sharesLockedNotice.contains("Rosetta"))

        let (linuxBundle, linuxRoot) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: linuxRoot) }
        let linux = try VMSettingsModel(bundle: linuxBundle, rosettaState: { .installed })
        #expect(linux.showsRosetta && linux.showsGuestTools && !linux.showsSSHUser)
        #expect(linux.sectionNames == ["Generale", "Hardware", "Condivisione", "Guest Tools"])
        #expect(linux.guestMountPoint == "/mnt/nido")
    }

    /// A macOS VM never goes below its image's minimums (recorded at install time): the steppers
    /// stop there, and a typed lower value is refused.
    @Test func macSettingsKeepTheImageMinimums() async throws {
        let (bundle, root) = try makeMacBundle(minimums: (3, UInt64(6) << 30))
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try VMSettingsModel(bundle: bundle)
        #expect(model.cpuFloor == 3)
        #expect(model.memoryFloorGiB == 6)
        for _ in 0..<5 { model.stepCPU(by: -1) }
        #expect(model.cpuCount == 3)
        for _ in 0..<10 { model.stepMemory(by: -1) }
        #expect(model.memoryGiB == 6)
        model.cpuCount = 2
        #expect(model.cpuError == "Fuori limite: da 3 a \(ResourceLimits.maxCPUCount()) CPU.")
        #expect(!(await model.save()))
        model.cpuCount = 3
        model.memoryGiB = 5
        #expect(model.memoryError == "Fuori limite: da 6 a \(VMSettingsModel.maxMemoryGiB) GiB.")
        #expect(!(await model.save()))
        #expect(try bundle.readConfig().cpuCount == 4)
        model.memoryGiB = 6
        #expect(await model.save())
        let config = try bundle.readConfig()
        #expect(config.cpuCount == 3 && config.memoryBytes == UInt64(6) << 30)
    }

    /// A macOS VM without recorded minimums (made before they were) gets 2 CPU and 4 GiB as the
    /// floor; a Linux VM keeps Virtualization's own limits.
    @Test func macSettingsFloorWithoutRecordedMinimums() async throws {
        let (bundle, root) = try makeMacBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try VMSettingsModel(bundle: bundle)
        #expect(model.cpuFloor == 2)
        #expect(model.memoryFloorGiB == 4)
        for _ in 0..<5 { model.stepCPU(by: -1) }
        for _ in 0..<10 { model.stepMemory(by: -1) }
        #expect(model.cpuCount == 2 && model.memoryGiB == 4)

        let (linuxBundle, linuxRoot) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: linuxRoot) }
        let linux = try VMSettingsModel(bundle: linuxBundle)
        #expect(linux.cpuFloor == ResourceLimits.cpuCountRange.lowerBound)
        #expect(linux.memoryFloorGiB == VMSettingsModel.minMemoryGiB)
    }

    /// Generale of a macOS VM: "Nome utente per nido ssh", validated (`VMConfig.validateSSHUser`)
    /// and saved through `updateConfig`, also while the VM runs (it only changes `nido ssh`).
    @Test func sshUserEditable() async throws {
        let (bundle, root) = try makeMacBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try VMSettingsModel(bundle: bundle)
        #expect(model.showsSSHUser)
        #expect(model.sshUserLabel == "Nome utente per nido ssh")
        #expect(model.sshUser == "agente")
        #expect(!model.canSaveSSHUser)

        model.sshUser = "Mattia"
        #expect(model.sshUserError != nil)
        #expect(!model.canSaveSSHUser)
        #expect(await model.saveSSHUser() == false)
        #expect(try bundle.readConfig().sshUser == "agente")

        // The VM runs elsewhere: the account name still changes.
        let lock = try BundleLock.acquire(bundle, owner: .cli)
        defer { lock.release() }
        model.sshUser = " mattia "
        #expect(model.sshUserError == nil)
        #expect(model.canSaveSSHUser)
        #expect(await model.saveSSHUser())
        #expect(try bundle.readConfig().sshUser == "mattia")
        #expect(model.sshUser == "mattia")
        #expect(model.didSaveSSHUser)
        #expect(model.sshUserSaveError == nil)
        #expect(model.error == nil)
        #expect(!model.canSaveSSHUser)

        // A config without sshUser shows the default account of nido ssh.
        let (other, otherRoot) = try makeMacBundle(user: nil)
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        #expect(try VMSettingsModel(bundle: other).sshUser == "nido")
    }

    /// S08 Generale: the way to S09 says how many snapshots there are and which is the last.
    @Test func snapshotSummaryNamesTheLastOne() async throws {
        let (bundle, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try VMSettingsModel(bundle: bundle)
        #expect(model.snapshotSummary == "Nessuno snapshot")
        for (file, text) in [(bundle.diskURL, "d"), (bundle.nvramURL, "n"), (bundle.machineIdentifierURL, "m"),
                             (bundle.seedURL, "s")] {
            try Data(text.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        let store = SnapshotStore(bundle: bundle)
        try await store.create(name: "prima", owner: .app, session: nil)
        let last = try await store.create(name: "seconda", owner: .app, session: nil)
        model.refresh()
        #expect(model.snapshotSummary
            == "2 snapshot · l'ultimo, seconda, del \(SnapshotsModel.dateText(last.createdAt))")
    }

    /// A template's sharing and Rosetta do not change here: "Modifica modello" first.
    @Test func templateRefusesSharingChanges() async throws {
        let (bundle, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try bundle.updateConfig { $0.isTemplate = true }
        let model = try VMSettingsModel(bundle: bundle, rosettaState: { .installed })
        #expect(model.isTemplate)
        #expect(!model.canEditShares)
        #expect(model.isRosettaLocked)
        #expect(!(await model.setRosetta(true)))
        #expect(model.shareError == "debian-13 è un modello: scegli Modifica modello nella libreria per cambiarlo.")
        #expect(try bundle.readConfig().rosetta == false)
    }

    @Test func loadsReadOnlyFieldsAndEditableOnes() async throws {
        let (bundle, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try VMSettingsModel(bundle: bundle)
        #expect(model.name == "debian-13")
        #expect(model.macAddress == "52:54:00:12:34:56")
        #expect(model.diskBytes == UInt64(32) << 30)
        #expect(model.cpuCount == 2)
        #expect(model.memoryGiB == 4)
        #expect(!model.isLocked)
    }

    @Test func editingLockedWhileRunning() async throws {
        let (bundle, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try VMSettingsModel(bundle: bundle)
        let lock = try BundleLock.acquire(bundle, owner: .cli)
        model.refresh()
        #expect(model.isLocked)
        #expect(model.runningOwner == .cli)
        model.cpuCount = 3
        model.memoryGiB = 8
        #expect(model.cpuCount == 2)
        #expect(model.memoryGiB == 4)
        model.stepCPU(by: 1)
        #expect(model.cpuCount == 2)
        lock.release()
        model.refresh()
        #expect(!model.isLocked)
        model.cpuCount = 3
        #expect(model.cpuCount == 3)
    }

    @Test func lockedWhileOpenInThisApp() async throws {
        let (bundle, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let live = LiveFlag(true)
        let model = try VMSettingsModel(bundle: bundle, isOpenInApp: { live.value })
        #expect(model.isLocked)
        #expect(model.runningOwner == .app)
        live.value = false
        model.refresh()
        #expect(!model.isLocked)
    }

    @Test func unchangedOverLimitCPUDoesNotBlockSave() async throws {
        let (bundle, root) = try makeBundle(cpuCount: ResourceLimits.maxCPUCount() + 1)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try VMSettingsModel(bundle: bundle)
        #expect(model.cpuError == nil)
        model.memoryGiB = 6
        #expect(model.canSave)
        #expect(await model.save())
        let config = try bundle.readConfig()
        #expect(config.cpuCount == ResourceLimits.maxCPUCount() + 1)
        #expect(config.memoryBytes == UInt64(6) << 30)
    }

    @Test func changedCPUMustRespectLimit() async throws {
        let over = ResourceLimits.maxCPUCount() + 2
        let (bundle, root) = try makeBundle(cpuCount: over)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try VMSettingsModel(bundle: bundle)
        model.cpuCount = over + 1
        #expect(model.cpuError != nil)
        #expect(!(await model.save()))
        #expect(try bundle.readConfig().cpuCount == over)
        model.cpuCount = ResourceLimits.maxCPUCount()
        #expect(model.cpuError == nil)
        #expect(await model.save())
        #expect(try bundle.readConfig().cpuCount == ResourceLimits.maxCPUCount())
    }

    @Test func saveValidatesLimits() async throws {
        let (bundle, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try VMSettingsModel(bundle: bundle)
        model.cpuCount = ResourceLimits.cpuCountRange.upperBound + 1
        #expect(!(await model.save()))
        #expect(model.error != nil)
        #expect(try bundle.readConfig().cpuCount == 2)
        model.cpuCount = 2
        model.memoryGiB = Int(ResourceLimits.memoryRange.upperBound >> 30) + 1
        #expect(!(await model.save()))
        #expect(model.error != nil)
        #expect(try bundle.readConfig().memoryBytes == UInt64(4) << 30)
    }

    @Test func savePersistsConfig() async throws {
        let (bundle, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try bundle.readConfig()
        let model = try VMSettingsModel(bundle: bundle)
        model.cpuCount = 3
        model.memoryGiB = 6
        #expect(model.isDirty)
        #expect(await model.save())
        #expect(model.error == nil)
        #expect(!model.isDirty)
        let after = try bundle.readConfig()
        #expect(after.cpuCount == 3)
        #expect(after.memoryBytes == UInt64(6) << 30)
        // Everything else is untouched, and the file stays private.
        #expect(after.id == before.id && after.macAddress == before.macAddress && after.diskBytes == before.diskBytes)
        var info = stat()
        #expect(stat(bundle.configURL.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        // The save lock is gone again.
        #expect(BundleLock.holder(bundle) == nil)
    }

    @Test func saveRefusedWhileAnotherProcessHoldsTheLock() async throws {
        let (bundle, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try VMSettingsModel(bundle: bundle)
        model.cpuCount = 3
        // The VM starts between the edit and the save: the lock is the only protection.
        let lock = try BundleLock.acquire(bundle, owner: .cli)
        defer { lock.release() }
        #expect(!(await model.save()))
        #expect(model.error?.contains("in esecuzione") == true)
        #expect(try bundle.readConfig().cpuCount == 2)
    }

    @Test func saveKeepsConcurrentChangesToOtherFields() async throws {
        let (bundle, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try VMSettingsModel(bundle: bundle)
        var other = try bundle.readConfig()
        other.clipboardSharing = true
        try bundle.writeConfig(other)
        model.cpuCount = 4
        #expect(await model.save())
        let after = try bundle.readConfig()
        #expect(after.cpuCount == 4)
        #expect(after.clipboardSharing)
    }

    /// Only "already running" is reported as a running VM; other lock failures say what happened.
    @Test func saveReportsOtherLockFailuresAsSuch() async throws {
        let (bundle, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try VMSettingsModel(bundle: bundle)
        // A hard-linked .lock is refused by BundleLock.acquire with "percorso non sicuro".
        let other = bundle.url.appendingPathComponent("other")
        try Data().write(to: other)
        try FileManager.default.linkItem(at: other, to: bundle.lockURL)
        model.cpuCount = 3
        #expect(!(await model.save()))
        #expect(model.error?.hasPrefix("Impossibile salvare le impostazioni: ") == true, "\(model.error ?? "nil")")
        #expect(model.error != VMSettingsModel.runningMessage("debian-13"))
    }

    /// A VM opened in this app after the last refresh: save checks again before taking the lock.
    @Test func saveRechecksTheAppBeforeWriting() async throws {
        let (bundle, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let live = LiveFlag(false)
        let model = try VMSettingsModel(bundle: bundle, isOpenInApp: { live.value })
        model.cpuCount = 3
        live.value = true
        #expect(!(await model.save()))
        #expect(model.error == VMSettingsModel.runningMessage("debian-13"))
        #expect(try bundle.readConfig().cpuCount == 2)
    }

    /// Arresta in the settings of a VM run by another Nido: nothing to stop here, and the same
    /// message as the library card says where to stop it.
    @Test func settingsStopOfOtherNidoExplains() async throws {
        let (bundle, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let lock = try BundleLock.acquire(bundle, owner: .app)
        defer { lock.release() }
        var asked: [String] = []
        let model = try VMSettingsModel(bundle: bundle, stopAppVM: { name in
            asked.append(name.rawValue)
            return false  // no window of this app runs it
        })
        await model.stop()
        #expect(asked == ["debian-13"])
        #expect(model.error == LibraryModel.otherInstanceStopMessage("debian-13"))
        #expect(model.error == "Impossibile arrestare debian-13: è aperta in un'altra istanza di Nido, arrestala da lì.")
    }

    /// A Terminal VM gets SIGTERM; a failure is shown, never swallowed.
    @Test func settingsStopOfTerminalVMReportsFailure() async throws {
        let (bundle, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let lock = try BundleLock.acquire(bundle, owner: .cli)
        defer { lock.release() }
        let model = try VMSettingsModel(bundle: bundle, requestStop: { _ in throw NidoError.pidUnknown })
        await model.stop()
        #expect(model.error == "Impossibile arrestare debian-13: \(NidoError.pidUnknown.localizedDescription)")
    }

    /// A second click on Salva while the first save runs is ignored: it must not find the first
    /// save's own lock and report "VM in esecuzione".
    @Test func doubleSaveDoesNotReportItsOwnLock() async throws {
        let (bundle, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try VMSettingsModel(bundle: bundle)
        model.cpuCount = 3
        async let first = model.save()
        async let second = model.save()
        let results = await [first, second]
        #expect(results.filter { $0 }.count == 1, "\(results)")
        #expect(model.error == nil, "\(model.error ?? "")")
        #expect(!model.isSaving)
        #expect(try bundle.readConfig().cpuCount == 3)
    }

    /// Salva is disabled while a save runs.
    @Test func cannotSaveWhileSaving() async throws {
        let (bundle, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try VMSettingsModel(bundle: bundle)
        model.cpuCount = 3
        #expect(model.canSave)
        let task = Task { await model.save() }
        await Task.yield()
        if model.isSaving { #expect(!model.canSave) }
        #expect(await task.value)
        #expect(!model.isSaving)
    }

    // MARK: - Condivisione

    /// Not in the temp directory: /private (the real /tmp and /var) cannot be shared.
    private static let shareBase = URL(fileURLWithPath: "/Users/Shared", isDirectory: true)

    private func makeFolder(_ root: URL, _ name: String = "Progetti") throws -> URL {
        let url = Self.shareBase
            .appendingPathComponent("nido-tests-\(root.lastPathComponent)-shares/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cleanShares(_ root: URL) {
        try? FileManager.default.removeItem(
            at: Self.shareBase.appendingPathComponent("nido-tests-\(root.lastPathComponent)-shares"))
    }

    @Test func addsAReadOnlyShareAtOnce() async throws {
        let (bundle, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root); cleanShares(root) }
        let folder = try makeFolder(root)
        let model = try VMSettingsModel(bundle: bundle)
        #expect(model.sharedFolders.isEmpty)
        #expect(await model.addSharedFolder(path: folder.path))
        #expect(model.shareError == nil)
        #expect(model.sharedFolders.map(\.name) == ["Progetti"])
        #expect(model.sharedFolders.first?.readOnly == true)
        let config = try bundle.readConfig()
        #expect(config.sharedFolders == model.sharedFolders)
        #expect(config.schemaVersion == VMConfig.currentSchemaVersion)
        #expect(BundleLock.holder(bundle) == nil)
        // A second folder with the same name gets its own.
        let other = try makeFolder(root, "x/Progetti")
        #expect(await model.addSharedFolder(path: other.path))
        #expect(model.sharedFolders.map(\.name) == ["Progetti", "Progetti-2"])
    }

    @Test func refusesDangerousShares() async throws {
        let (bundle, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try VMSettingsModel(bundle: bundle)
        for path in ["/", FileManager.default.homeDirectoryForCurrentUser.path, root.path, bundle.url.path] {
            #expect(!(await model.addSharedFolder(path: path)), "\(path)")
            #expect(model.shareError?.contains("non condivisibile") == true, "\(model.shareError ?? "nil")")
        }
        #expect(try bundle.readConfig().sharedFolders.isEmpty)
    }

    @Test func shareEditsRefusedWhileRunning() async throws {
        let (bundle, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root); cleanShares(root) }
        let folder = try makeFolder(root)
        let model = try VMSettingsModel(bundle: bundle)
        #expect(await model.addSharedFolder(path: folder.path))
        let lock = try BundleLock.acquire(bundle, owner: .cli)
        defer { lock.release() }
        // The lock is found before the view refreshes: the edit must still be refused.
        #expect(!(await model.setReadOnly(false, for: "Progetti")))
        #expect(model.shareError == VMSettingsModel.sharesRunningMessage("debian-13"))
        #expect(!(await model.removeSharedFolder("Progetti")))
        #expect(!(await model.addSharedFolder(path: try makeFolder(root, "Altro").path)))
        let config = try bundle.readConfig()
        #expect(config.sharedFolders.count == 1)
        #expect(config.sharedFolders.first?.readOnly == true)
    }

    @Test func toggleReadOnlyAndRemove() async throws {
        let (bundle, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root); cleanShares(root) }
        let folder = try makeFolder(root)
        let model = try VMSettingsModel(bundle: bundle)
        #expect(await model.addSharedFolder(path: folder.path))
        #expect(await model.setReadOnly(false, for: "Progetti"))
        #expect(try bundle.readConfig().sharedFolders.first?.readOnly == false)
        #expect(model.sharedFolders.first?.readOnly == false)
        #expect(await model.removeSharedFolder("Progetti"))
        #expect(model.sharedFolders.isEmpty)
        #expect(try bundle.readConfig().sharedFolders.isEmpty)
    }

    @Test func missingFolderIsMarked() async throws {
        let (bundle, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        var config = try bundle.readConfig()
        config.sharedFolders = [SharedFolder(name: "via", hostPath: "/nonexistent-nido-share", readOnly: true)]
        try bundle.writeConfig(config)
        let model = try VMSettingsModel(bundle: bundle)
        #expect(model.problem(for: model.sharedFolders[0])?.hasPrefix("Non trovata sul Mac") == true)
    }

    /// A folder that now resolves to a refused place is shown as left out, as the start decides.
    @Test func refusedFolderIsMarked() async throws {
        let (bundle, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        var config = try bundle.readConfig()
        config.sharedFolders = [SharedFolder(name: "radice", hostPath: "/", readOnly: true),
                                SharedFolder(name: "tmp", hostPath: NSTemporaryDirectory(), readOnly: true)]
        try bundle.writeConfig(config)
        let model = try VMSettingsModel(bundle: bundle)
        #expect(model.problem(for: model.sharedFolders[0])?.hasPrefix("Esclusa all'avvio") == true)
        // The temp folder contains this test's VM root: refused too.
        #expect(model.problem(for: model.sharedFolders[1]) != nil)
    }

    @Test func olderVMShowsTheGuestCommand() async throws {
        let (bundle, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        // `makeBundle` builds the config by hand, as a VM from before M3a reads.
        #expect(try VMSettingsModel(bundle: bundle).legacyGuestCommand == SharedFolder.legacyGuestCommand)
        var config = try bundle.readConfig()
        config.guestMountsSharedFolders = true
        try bundle.writeConfig(config)
        #expect(try VMSettingsModel(bundle: bundle).legacyGuestCommand == nil)
    }

    // MARK: - Rosetta

    /// Counts the system installs asked for; the model must call it only from `installRosetta()`.
    private final class InstallSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        private var _state = RosettaState.notInstalled
        var calls: Int { lock.withLock { _calls } }
        var state: RosettaState { lock.withLock { _state } }
        func install() async throws { lock.withLock { _calls += 1; _state = .installed } }
    }

    @Test func rosettaToggleWritesConfigOnlyWhenStopped() async throws {
        let (bundle, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try VMSettingsModel(bundle: bundle, rosettaState: { .installed })
        #expect(!model.rosetta)
        #expect(!model.isRosettaLocked)
        #expect(await model.setRosetta(true))
        #expect(model.rosetta)
        #expect(try bundle.readConfig().rosetta)
        // Running: refused, nothing written.
        let lock = try BundleLock.acquire(bundle, owner: .cli)
        model.refresh()
        #expect(model.isRosettaLocked)
        #expect(await model.setRosetta(false) == false)
        #expect(model.shareError == VMSettingsModel.rosettaRunningMessage("debian-13"))
        #expect(try bundle.readConfig().rosetta)
        lock.release()
        model.refresh()
        #expect(await model.setRosetta(false))
        #expect(try bundle.readConfig().rosetta == false)
    }

    @Test func rosettaStaysOffWithTheReasonWhenMissing() async throws {
        let (bundle, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let unsupported = try VMSettingsModel(bundle: bundle, rosettaState: { .unsupported })
        #expect(unsupported.isRosettaLocked)
        #expect(unsupported.rosettaExplanation.contains("non è disponibile"))
        #expect(!unsupported.canInstallRosetta)
        #expect(await unsupported.setRosetta(true) == false)
        #expect(try bundle.readConfig().rosetta == false)

        let spy = InstallSpy()
        let missing = try VMSettingsModel(
            bundle: bundle, rosettaState: { spy.state }, installRosetta: { try await spy.install() })
        #expect(missing.isRosettaLocked)
        #expect(missing.rosettaExplanation.contains("non è installata"))
        #expect(missing.canInstallRosetta)
        #expect(spy.calls == 0)  // never installed by itself
        await missing.installRosetta()
        #expect(spy.calls == 1)
        #expect(missing.rosettaState == .installed)
        #expect(!missing.canInstallRosetta)
        #expect(!missing.isRosettaLocked)
    }

    @Test func rosettaOnButMissingCanStillBeTurnedOff() async throws {
        let (bundle, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        var config = try bundle.readConfig()
        config.rosetta = true
        try bundle.writeConfig(config)
        let model = try VMSettingsModel(bundle: bundle, rosettaState: { .notInstalled })
        #expect(model.rosetta)
        #expect(!model.isRosettaLocked)
        #expect(model.rosettaExplanation.contains("parte senza"))
        #expect(await model.setRosetta(false))
        #expect(try bundle.readConfig().rosetta == false)
    }

    @Test func olderVMShowsTheRosettaCommandWhenOn() async throws {
        let (bundle, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try VMSettingsModel(bundle: bundle, rosettaState: { .installed })
        #expect(model.rosettaLegacyCommand == nil)  // off: nothing to run
        #expect(await model.setRosetta(true))
        #expect(model.rosettaLegacyCommand == RosettaSupport.legacyGuestCommand)
        var config = try bundle.readConfig()
        config.guestRegistersRosetta = true
        try bundle.writeConfig(config)
        #expect(try VMSettingsModel(bundle: bundle, rosettaState: { .installed }).rosettaLegacyCommand == nil)
    }
}

/// CORE m5 / APP m6: S08 of a suspended VM says a change discards the saved state, and the VM
/// window's message follows the change.
@MainActor
struct VMSettingsSuspendedTests {
    private func suspendedBundle() throws -> (VMBundle, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-settings-\(UUID().uuidString)", isDirectory: true)
        var config = VMConfig(
            id: UUID(), name: try VMName("debian-13"), guest: .linux, cpuCount: 2,
            memoryBytes: UInt64(4) << 30, diskBytes: UInt64(32) << 30, macAddress: "52:54:00:12:34:56")
        let bundle = try VMBundle.create(config: config, paths: NidoPaths(root: root))
        try Data("state".utf8).write(to: bundle.stateURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bundle.stateURL.path)
        config = try bundle.readConfig()
        config.suspendedConfigHash = config.stateHash()
        try bundle.writeConfig(config)
        return (bundle, root)
    }

    @Test func suspendedNoteBeforeAndAfterAChange() async throws {
        let (bundle, root) = try suspendedBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        var changes = 0
        let model = try VMSettingsModel(bundle: bundle, onConfigurationChanged: { changes += 1 })
        #expect(model.suspendedNote == "debian-13 è sospesa: se cambi CPU, memoria, cartelle condivise o Rosetta, al prossimo avvio lo stato salvato verrà scartato e la VM partirà da capo.")
        model.cpuCount = 3
        #expect(await model.save())
        #expect(changes == 1)
        #expect(model.suspendedNote == "Le impostazioni di debian-13 sono cambiate dopo la sospensione: al prossimo avvio lo stato salvato verrà scartato e la VM partirà da capo.")
    }

    @Test func noNoteForAStoppedVM() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-settings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = VMConfig(
            id: UUID(), name: try VMName("debian-13"), guest: .linux, cpuCount: 2,
            memoryBytes: UInt64(4) << 30, diskBytes: UInt64(32) << 30, macAddress: "52:54:00:12:34:56")
        let bundle = try VMBundle.create(config: config, paths: NidoPaths(root: root))
        #expect(try VMSettingsModel(bundle: bundle).suspendedNote == nil)
    }

    /// S07: once the settings changed, the stopped screen no longer promises a resume.
    @Test func windowMessageFollowsTheChange() async throws {
        let (bundle, root) = try suspendedBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let window = VMWindowModel(
            name: try VMName("debian-13"), paths: NidoPaths(root: root), factory: FakeSessionFactory())
        #expect(window.isSuspended)
        #expect(window.stoppedMessage(now: Date()).hasPrefix("Lo stato della VM è salvato sul Mac"))
        var config = try bundle.readConfig()
        config.memoryBytes = UInt64(8) << 30
        try bundle.writeConfig(config)
        window.syncSuspendedState()
        #expect(window.stoppedMessage(now: Date())
            == "Le impostazioni sono cambiate dopo la sospensione: al prossimo avvio lo stato salvato verrà scartato e la VM partirà da capo.")
    }
}

/// The guest side of S08 Guest Tools, recorded: install, panic settings, the default key and
/// whether a chosen key is the one authorized in the VM.
final class FakeGuestToolsServices: GuestToolsServicing {
    private let state = Mutex<(calls: [String], installFailure: (any Error)?, adopted: String?, authorized: Bool)>(
        ([], nil, nil, true))

    var calls: [String] { state.withLock { $0.calls } }
    func failInstall(with error: (any Error)?) { state.withLock { $0.installFailure = error } }
    func adopt(_ path: String?) { state.withLock { $0.adopted = path } }
    func authorize(_ value: Bool) { state.withLock { $0.authorized = value } }

    func install(on bundle: VMBundle) async throws -> GuestToolsInstaller.Outcome {
        let failure = state.withLock { s -> (any Error)? in
            s.calls.append("install")
            return s.installFailure
        }
        if let failure { throw failure }
        try bundle.updateConfig { $0.guestToolsVersion = GuestToolsPayload.version }
        return .installed
    }

    func applyPanicSettings(on bundle: VMBundle) async throws {
        state.withLock { $0.calls.append("panic") }
    }

    func quietBackground(on bundle: VMBundle, ubuntu: Bool) async throws {
        state.withLock { $0.calls.append(ubuntu ? "quiet-ubuntu" : "quiet-debian") }
    }

    func adoptDefaultKey(bundle: VMBundle) throws -> String? {
        let adopted = state.withLock { s -> String? in
            s.calls.append("adopt")
            return s.adopted
        }
        if let adopted { try bundle.updateConfig { $0.sshPublicKeyPath = adopted } }
        return adopted
    }

    func isAuthorized(publicKey: String, in bundle: VMBundle) -> Bool {
        state.withLock { $0.authorized }
    }

    func manualInstallCommand() throws -> String { "base64 -d <<'NIDO_GUEST_TOOLS' | sudo /bin/sh -c '…'" }
}

/// A flag the test flips and a main-actor closure reads.
@MainActor
final class Switch {
    var on = false
}

@MainActor
struct VMSettingsLiveTests {
    private func makeBundle(keyPath: String? = "/Users/x/.ssh/id_ed25519.pub", mountsShares: Bool = true) throws -> (VMBundle, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-settings-\(UUID().uuidString)", isDirectory: true)
        let config = VMConfig(
            id: UUID(), name: try VMName("debian-13"), guest: .linux, cpuCount: 2,
            memoryBytes: UInt64(4) << 30, diskBytes: UInt64(32) << 30, macAddress: "52:54:00:12:34:56",
            guestMountsSharedFolders: mountsShares, sshPublicKeyPath: keyPath)
        return (try VMBundle.create(config: config, paths: NidoPaths(root: root)), root)
    }

    private static let shareBase = URL(fileURLWithPath: "/Users/Shared", isDirectory: true)

    private func makeFolder(_ root: URL, _ name: String = "Progetti") throws -> URL {
        let url = Self.shareBase
            .appendingPathComponent("nido-tests-\(root.lastPathComponent)-shares/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cleanShares(_ root: URL) {
        try? FileManager.default.removeItem(
            at: Self.shareBase.appendingPathComponent("nido-tests-\(root.lastPathComponent)-shares"))
    }

    /// S08 Condivisione with the VM running in this app: removing a folder is written and given
    /// to the session at once (`VMSession.updateSharedFolders`), and the page says so.
    @Test func liveShareRemovalAppliesNow() async throws {
        let (bundle, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root); cleanShares(root) }
        let folder = try makeFolder(root)
        let live = Switch()
        var applied: [[SharedFolder]] = []
        let model = try VMSettingsModel(
            bundle: bundle, isOpenInApp: { live.on },
            applyLiveShares: { folders in
                applied.append(folders)
                return []
            })
        #expect(await model.addSharedFolder(path: folder.path))
        #expect(applied.isEmpty, "stopped: nothing to give to a session")
        #expect(model.liveNotice == nil)

        live.on = true
        model.refresh()
        #expect(model.isLocked)
        #expect(model.canEditSharesLive)
        #expect(await model.setReadOnly(false, for: "Progetti"))
        #expect(applied.last?.first?.readOnly == false)
        #expect(await model.removeSharedFolder("Progetti"))
        #expect(applied.last == [])
        #expect(try bundle.readConfig().sharedFolders.isEmpty)
        #expect(model.sharedFolders.isEmpty)
        #expect(model.liveNotice?.hasPrefix("Ha effetto subito") == true)
        // Rosetta still waits for a stopped VM.
        #expect(model.isRosettaLocked)
    }

    /// A VM run by `nido start` (another process): no live change from here, as before.
    @Test func liveSharesNotForATerminalVM() async throws {
        let (bundle, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root); cleanShares(root) }
        var applied = 0
        let model = try VMSettingsModel(bundle: bundle, applyLiveShares: { _ in
            applied += 1
            return []
        })
        let lock = try BundleLock.acquire(bundle, owner: .cli)
        defer { lock.release() }
        #expect(!(await model.addSharedFolder(path: try makeFolder(root).path)))
        #expect(model.shareError == VMSettingsModel.sharesRunningMessage("debian-13"))
        #expect(applied == 0)
    }

    /// A VM created before M3a does not mount /mnt/nido by itself: the page says live changes
    /// reach it only after the one-time command.
    @Test func legacyGuestDoesNotSeeLiveFolders() async throws {
        let (bundle, root) = try makeBundle(mountsShares: false)
        defer { try? FileManager.default.removeItem(at: root); cleanShares(root) }
        let model = try VMSettingsModel(bundle: bundle, isOpenInApp: { true }, applyLiveShares: { _ in [] })
        #expect(await model.addSharedFolder(path: try makeFolder(root).path))
        #expect(model.liveNotice?.contains("comando") == true)
        #expect(model.sharesIntro.contains("comando"))
    }

    /// S08 Guest Tools: "Installa Guest Tools" on a running VM installs over SSH and records the
    /// version; on a stopped VM it explains and does nothing.
    @Test func installGuestToolsAction() async throws {
        let (bundle, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let services = FakeGuestToolsServices()
        let running = Switch()
        let model = try VMSettingsModel(bundle: bundle, isOpenInApp: { running.on }, guestToolsServices: services)
        let tools = model.guestTools
        await tools.load()
        #expect(tools.installedVersion == nil)
        await tools.install()
        #expect(services.calls.isEmpty)
        #expect(tools.failure?.title == "Avvia debian-13 per installare i Guest Tools.")

        running.on = true
        await tools.install()
        #expect(services.calls == ["install"])
        #expect(tools.failure == nil)
        #expect(tools.installedVersion == GuestToolsPayload.version)
        #expect(tools.message != nil)

        await tools.applyPanicSettings()
        #expect(services.calls == ["install", "panic"])
        #expect(tools.message?.contains("prossimo riavvio") == true)

        // Debian: only apt's SRV lookups.
        #expect(!tools.isUbuntu)
        #expect(tools.quietNote.hasPrefix("Spegne le query SRV"))
        await tools.quietBackground()
        #expect(services.calls == ["install", "panic", "quiet-debian"])
        #expect(tools.message == "Richieste di sfondo spente in debian-13: valgono da subito.")

        // Ubuntu: everything the seed of a new Ubuntu VM turns off.
        try bundle.updateConfig { $0.distribution = .ubuntu2604 }
        await tools.load()
        #expect(tools.isUbuntu)
        #expect(tools.quietNote.contains("Ubuntu Pro"))
        await tools.quietBackground()
        #expect(services.calls.last == "quiet-ubuntu")

        // Stopped: explained, nothing run.
        running.on = false
        await tools.quietBackground()
        #expect(tools.failure?.title == "Avvia debian-13 per spegnere le richieste di sfondo.")
        #expect(services.calls.count == 4)
    }

    /// A VM created before 0.7.4: the Rete view suggests "Spegni" until it is done or declined,
    /// and the answer is kept in the config.
    @Test func quietSuggestionUntilDoneOrDeclined() async throws {
        let (bundle, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = try CloudInitSeed.validatePublicKey(
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOO97YvP4YWGQwUFq+UeOnyDKkD29RZ8VdmeuGgPzeS6")
        try CloudInitSeed.buildISO(
            at: bundle.seedURL, userData: CloudInitSeed.userData(username: "nido", publicKey: key, pinnedTimeServer: true),
            metaData: "instance-id: x\nlocal-hostname: debian-13\n", runner: SystemProcessRunner())
        let services = FakeGuestToolsServices()
        let tools = GuestToolsModel(bundle: bundle, name: "debian-13", services: services, isRunning: { true })
        await tools.load()
        #expect(tools.suggestsQuieting)
        #expect(tools.quietSuggestion.hasPrefix("debian-13 è stata creata prima di Nido 0.7.4"))

        await tools.quietBackground()
        #expect(services.calls == ["quiet-debian"])
        #expect(!tools.suggestsQuieting)
        #expect(try bundle.readConfig().backgroundRequestsOff == true)
        await tools.load()
        #expect(!tools.suggestsQuieting)

        // "Non ora": not suggested again, nothing run in the guest.
        try bundle.updateConfig { $0.backgroundRequestsOff = nil }
        await tools.load()
        #expect(tools.suggestsQuieting)
        await tools.declineQuieting()
        #expect(!tools.suggestsQuieting)
        #expect(try bundle.readConfig().backgroundRequestsOff == false)
        await tools.load()
        #expect(!tools.suggestsQuieting)
        #expect(services.calls == ["quiet-debian"])
    }

    /// SSH failures: a key that cannot be used offers the Terminal; an unreachable guest offers
    /// the manual installer.
    @Test func installFailuresOfferTerminalOrManual() async throws {
        let (bundle, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let services = FakeGuestToolsServices()
        let model = try VMSettingsModel(bundle: bundle, isOpenInApp: { true }, guestToolsServices: services)
        let tools = model.guestTools
        await tools.load()
        services.failInstall(with: GuestSSHError.keyUnavailable("/Users/x/.ssh/id_ed25519"))
        await tools.install()
        #expect(tools.failure?.offersTerminal == true)
        #expect(tools.failure?.offersManual == false)
        services.failInstall(with: GuestSSHError.unreachable)
        await tools.install()
        #expect(tools.failure?.offersTerminal == false)
        #expect(tools.failure?.offersManual == true)
        #expect(tools.manualCommand?.hasPrefix("base64 -d") == true)
        // The title says it already: the detail does not repeat "non risponde via SSH" (S08 design).
        #expect(tools.failure?.detail?.hasPrefix("Controlla che la VM sia accesa") == true)
        services.failInstall(with: GuestToolsInstallError.unsupportedDistribution)
        await tools.install()
        #expect(tools.failure?.offersManual == true)
    }

    /// No key recorded (a VM created before Nido recorded it): the default key is adopted when it
    /// is the authorized one, otherwise the user chooses it; a key not authorized is refused.
    @Test func installWithoutKeyAdoptsOrAsks() async throws {
        let (bundle, root) = try makeBundle(keyPath: nil)
        defer { try? FileManager.default.removeItem(at: root) }
        let services = FakeGuestToolsServices()
        let model = try VMSettingsModel(bundle: bundle, isOpenInApp: { true }, guestToolsServices: services)
        let tools = model.guestTools
        await tools.load()
        await tools.install()
        #expect(services.calls == ["adopt"])
        #expect(tools.needsKey)

        let keyURL = root.appendingPathComponent("chiave.pub")
        try Data(validPublicKey.utf8).write(to: keyURL)
        services.authorize(false)
        await tools.chooseKey(keyURL)
        #expect(tools.needsKey)
        #expect(tools.keyError != nil)
        #expect(try bundle.readConfig().sshPublicKeyPath == nil)
        services.authorize(true)
        await tools.chooseKey(keyURL)
        #expect(!tools.needsKey)
        #expect(try bundle.readConfig().sshPublicKeyPath == keyURL.path)
        await tools.install()
        #expect(services.calls == ["adopt", "install"])

        // The default key matches: adopted, then installed in one go.
        let (other, otherRoot) = try makeBundle(keyPath: nil)
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        let adopting = FakeGuestToolsServices()
        adopting.adopt("/Users/x/.ssh/id_ed25519.pub")
        let second = try VMSettingsModel(bundle: other, isOpenInApp: { true }, guestToolsServices: adopting)
        await second.guestTools.load()
        await second.guestTools.install()
        #expect(adopting.calls == ["adopt", "install"])
    }
}

/// Whether the VM is open in the app, changed by a test after the model captured it.
private final class LiveFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Bool
    init(_ value: Bool) { current = value }
    var value: Bool {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}
