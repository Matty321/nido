// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore
import Observation

/// State and actions of the settings of one VM (S08).
///
/// CPU and memory can be edited only while nobody runs the VM: `BundleLock.holder` is nil and the
/// VM is not open in this app. The check is repeated on every edit, but it is only a convenience:
/// the real protection is the bundle lock `save()` takes for the whole write, so a `nido start`
/// (or this app) cannot boot the VM while `config.json` is being rewritten.
@MainActor
@Observable
final class VMSettingsModel {
    /// Read-only: shown, never changed here.
    let name: String
    let macAddress: String
    let diskBytes: UInt64

    var cpuCount: Int {
        didSet { if !isReverting, !allowsEditing() { revert { cpuCount = oldValue } } }
    }
    var memoryGiB: Int {
        didSet { if !isReverting, !allowsEditing() { revert { memoryGiB = oldValue } } }
    }

    /// Who runs the VM right now (nil when it is stopped). Updated by `refresh()`.
    private(set) var runningOwner: LockOwner?
    /// Localized message for the last failed save.
    private(set) var error: String?
    /// True after a successful save, until the next edit.
    private(set) var didSave = false
    /// True while `save()` runs: Salva is disabled and a second save is ignored.
    private(set) var isSaving = false

    /// Condivisione: the VM's shared folders as last read or written.
    private(set) var sharedFolders: [SharedFolder]
    /// Why the next start would leave a shared folder out, by lowercased name (missing on the
    /// Mac, moved somewhere refused…), as `SharedFolder.validate` decides at start.
    private(set) var shareProblems: [String: String] = [:]
    /// Localized message for the last failed change to the shared folders.
    private(set) var shareError: String?
    /// True while a change to the shared folders is written: the controls are disabled.
    private(set) var isEditingShares = false
    /// The one-time guest command for a VM created before M3a (its guest does not mount
    /// /mnt/nido by itself); nil for newer VMs.
    let legacyGuestCommand: String?

    /// Rosetta for x86_64 binaries, as last read or written.
    private(set) var rosetta: Bool
    /// What this Mac has (`VZLinuxRosettaDirectoryShare.availability`), reread after an install.
    private(set) var rosettaState: RosettaState
    /// True while the system install of Rosetta runs.
    private(set) var isInstallingRosetta = false

    @ObservationIgnored private let bundle: VMBundle
    @ObservationIgnored private let isOpenInApp: @MainActor () -> Bool
    @ObservationIgnored private let stopAppVM: @MainActor (VMName) async -> Bool
    @ObservationIgnored private let requestStop: @Sendable (VMName) throws -> Void
    /// Assigning a property inside its own `didSet` re-enters the observation setter: this stops it.
    @ObservationIgnored private var isReverting = false
    @ObservationIgnored private var saved: (cpuCount: Int, memoryBytes: UInt64)
    @ObservationIgnored private let imageCache: URL
    @ObservationIgnored private let home: URL
    @ObservationIgnored private let guestRegistersRosetta: Bool
    @ObservationIgnored private let readRosettaState: @Sendable () -> RosettaState
    @ObservationIgnored private let systemInstallRosetta: @Sendable () async throws -> Void
    /// Tells the VM's window that the config changed (its stopped screen's message).
    @ObservationIgnored private let onConfigurationChanged: @MainActor () -> Void
    /// Gives the shared folders to the session of this app that runs the VM (spec G: a change
    /// has effect at once); nil when the app cannot (tests of a stopped VM).
    @ObservationIgnored private let applyLiveShares: (@MainActor ([SharedFolder]) throws -> [String])?
    /// The guest mounts /mnt/nido by itself (VMs from M3a on).
    @ObservationIgnored private let guestMountsSharedFolders: Bool
    /// The VM's system: where its guest shows the shared folders (`SharedFolder.guestPath(for:)`).
    let guest: GuestOS
    /// The fewest CPUs and GiB a changed value may have: Virtualization's limits, and for macOS the
    /// image's minimums recorded at install time (`macFloorCPUCount`/`macFloorMemoryBytes` for a VM
    /// installed before they were recorded).
    let cpuFloor: Int
    let memoryFloorGiB: Int

    /// S08 Guest Tools: install them over SSH, apply the anti-hang settings.
    let guestTools: GuestToolsModel
    /// After a change applied to the running VM: what happened (localized), until the next change.
    private(set) var liveNotice: String?

    private static let gibibyte: UInt64 = 1 << 30

    /// Reads the bundle's config. `isOpenInApp` tells whether a window of this app has the VM
    /// (a lock held by this very process shows in `BundleLock.holder` too; this is belt and braces).
    /// Arresta asks this app's window with `stopAppVM` (false: no window of this app runs it) and
    /// signals a `nido start` with `requestStop`. `rosettaState` reads what this Mac has and
    /// `installRosetta` is the system install, run only by `installRosetta()` (after the
    /// confirmation in the view).
    init(
        bundle: VMBundle, isOpenInApp: @escaping @MainActor () -> Bool = { false },
        stopAppVM: @escaping @MainActor (VMName) async -> Bool = { _ in false },
        requestStop: (@Sendable (VMName) throws -> Void)? = nil,
        imageCache: URL = ImageStore.defaultCacheRoot(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        rosettaState: @escaping @Sendable () -> RosettaState = { .current },
        installRosetta: @escaping @Sendable () async throws -> Void = { try await RosettaSupport.install() },
        onConfigurationChanged: @escaping @MainActor () -> Void = {},
        applyLiveShares: (@MainActor ([SharedFolder]) throws -> [String])? = nil,
        guestTools: GuestToolsModel? = nil,
        guestToolsServices: any GuestToolsServicing = LiveGuestToolsServices()
    ) throws {
        let config = try bundle.readConfig()
        self.bundle = bundle
        self.applyLiveShares = applyLiveShares
        guestMountsSharedFolders = config.guestMountsSharedFolders
        guest = config.guest
        (cpuFloor, memoryFloorGiB) = Self.floors(config)
        // The app passes the VM's one model (`VMSessionStore.guestTools`): its window shares it.
        self.guestTools = guestTools ?? GuestToolsModel(
            bundle: bundle, name: config.name.rawValue, services: guestToolsServices,
            isRunning: { await GuestToolsModel.runs(bundle, inApp: isOpenInApp()) })
        self.imageCache = imageCache
        self.home = home
        isTemplate = config.isTemplate
        sharedFolders = config.sharedFolders
        // A macOS guest mounts its folders by itself: the Linux fstab command never applies.
        legacyGuestCommand = config.guest == .macos || config.guestMountsSharedFolders
            ? nil : SharedFolder.legacyGuestCommand
        savedSSHUser = config.sshUser ?? "nido"
        sshUser = config.sshUser ?? "nido"
        rosetta = config.rosetta
        guestRegistersRosetta = config.guestRegistersRosetta
        readRosettaState = rosettaState
        systemInstallRosetta = installRosetta
        self.rosettaState = rosettaState()
        self.isOpenInApp = isOpenInApp
        self.onConfigurationChanged = onConfigurationChanged
        self.stopAppVM = stopAppVM
        self.requestStop = requestStop ?? { name in try VMControl.requestStop(bundle: bundle, name: name) }
        name = config.name.rawValue
        snapshotSummary = Self.snapshotSummary(bundle)
        macAddress = config.macAddress
        diskBytes = config.diskBytes
        cpuCount = config.cpuCount
        memoryGiB = Int(config.memoryBytes / Self.gibibyte)
        saved = (config.cpuCount, config.memoryBytes)
        refresh()
        checkMissingShares()
    }

    var isLocked: Bool { runningOwner != nil }

    // MARK: - What this guest has (R4)

    /// Rosetta runs Linux binaries: Linux only.
    var showsRosetta: Bool { guest == .linux }
    /// Guest Tools (monitor, provisioning, AI bridge) are Linux-only in M3b.
    var showsGuestTools: Bool { guest == .linux }
    /// "Nome utente per nido ssh": the account a macOS guest is reached as.
    var showsSSHUser: Bool { guest == .macos }
    /// The enabled sections of S08, in order, by id: the Italian names they always had, which
    /// also name the rows for the UI tests (`settings-section-<id>`). `sectionTitle` is the copy.
    var sectionNames: [String] {
        ["Generale", "Hardware", "Condivisione"] + (showsGuestTools ? ["Guest Tools"] : [])
    }

    /// The heading of the section `id` (`sectionNames`, and Accesso and Rete of the view).
    nonisolated static func sectionTitle(_ id: String) -> String {
        switch id {
        case "Generale": String(localized: "General")
        case "Hardware": String(localized: "Hardware")
        case "Condivisione": String(localized: "Sharing")
        case "Accesso": String(localized: "Access")
        case "Rete": String(localized: "Network")
        default: id  // Guest Tools: a name, never translated.
        }
    }
    /// Where the guest shows the shared folders.
    var guestMountPoint: String { guest == .macos ? SharedFolder.macGuestMountPoint : SharedFolder.guestMountPoint }
    /// A Linux VM created before M3a: it mounts the folders only after a one-time command.
    private var needsLegacyMount: Bool { guest == .linux && !guestMountsSharedFolders }

    // MARK: - Nome utente per nido ssh (macOS)

    var sshUserLabel: String { String(localized: "User name for nido ssh") }
    var sshUserNote: String {
        String(localized: "The macOS account nido ssh logs in to the VM with: the one created in Setup Assistant.")
    }
    /// The account name as typed.
    var sshUser: String {
        didSet { if sshUser != oldValue { didSaveSSHUser = false } }
    }
    /// The account name in the config (`nido` when unset).
    private(set) var savedSSHUser: String
    /// True after the account name was saved, until it is edited again.
    private(set) var didSaveSSHUser = false
    private(set) var isSavingSSHUser = false
    /// Why the last save of the account name failed (localized); Hardware's `error` is separate.
    private(set) var sshUserSaveError: String?

    private var typedSSHUser: String { sshUser.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Why the typed name is refused (`VMConfig.validateSSHUser`); nil when valid.
    var sshUserError: String? {
        do {
            try VMConfig.validateSSHUser(typedSSHUser)
            return nil
        } catch {
            return Self.sentence(error)
        }
    }

    var canSaveSSHUser: Bool {
        showsSSHUser && !isSavingSSHUser && sshUserError == nil && typedSSHUser != savedSSHUser
    }

    /// Writes the account name (`VMBundle.updateConfig`, also while the VM runs: it only changes
    /// what `nido ssh` logs in as). False when it is invalid or the write fails (`error`).
    @discardableResult
    func saveSSHUser() async -> Bool {
        guard showsSSHUser, !isSavingSSHUser, sshUserError == nil else { return false }
        isSavingSSHUser = true
        defer { isSavingSSHUser = false }
        sshUserSaveError = nil
        let user = typedSSHUser
        let bundle = bundle
        let result = await Task.detached { () -> Result<VMConfig, any Error> in
            do { return .success(try bundle.updateConfig { $0.sshUser = user }) } catch { return .failure(error) }
        }.value
        switch result {
        case .success(let config):
            savedSSHUser = config.sshUser ?? "nido"
            sshUser = savedSSHUser
            didSaveSSHUser = true
            return true
        case .failure(let failure):
            sshUserSaveError = String(localized: "Can’t save the user name: \(Self.sentence(failure))")
            return false
        }
    }

    /// A template (spec E): its shared folders and Rosetta do not change here; "Modifica
    /// modello" in the library makes it a VM again first.
    private(set) var isTemplate = false

    nonisolated static func templateMessage(_ name: String) -> String {
        String(localized: "\(name) is a template: choose Edit Template in the library to change it.")
    }

    /// True while the stopped VM holds a suspended state (a change discards it at the next start).
    private(set) var isSuspended = false
    /// True when the next start will discard that state (the settings changed since the suspend).
    private(set) var suspendedStateIsStale = false

    /// Under Hardware and Condivisione of a suspended VM: what a change does to its saved state.
    var suspendedNote: String? {
        guard isSuspended, !isLocked else { return nil }
        if suspendedStateIsStale {
            return String(localized: "The settings of \(name) changed after the suspend: the next start discards the saved state and the VM starts from scratch.")
        }
        return showsRosetta
            ? String(localized: "\(name) is suspended: if you change CPU, memory, shared folders or Rosetta, the next start discards the saved state and the VM starts from scratch.")
            : String(localized: "\(name) is suspended: if you change CPU, memory or shared folders, the next start discards the saved state and the VM starts from scratch.")
    }

    /// Rereads whether the VM is suspended and whether its state will still resume.
    private func refreshSuspendedState() {
        let config = try? bundle.readConfig()
        let suspended = config.map { bundle.hasSuspendedState($0) } ?? false
        let stale = suspended && !(config.map {
            SuspendedState.nextStartResumes(bundle: bundle, config: $0, imageCache: imageCache)
        } ?? true)
        if suspended != isSuspended { isSuspended = suspended }
        if stale != suspendedStateIsStale { suspendedStateIsStale = stale }
    }

    /// A change was written: this model and the VM's window reread the suspended state.
    private func configurationWritten() {
        refreshSuspendedState()
        onConfigurationChanged()
    }

    /// Rereads who runs the VM. The view calls it every second while the window is shown.
    func refresh() {
        runningOwner = BundleLock.holder(bundle)?.owner ?? (isOpenInApp() ? .app : nil)
        snapshotSummary = Self.snapshotSummary(bundle)
        if isLocked {
            if isSuspended { isSuspended = false }
        } else {
            refreshSuspendedState()
        }
    }

    /// Generale, the way to S09: "3 snapshot · l'ultimo, dopo-docker, del 24 ott 2026, 16:05".
    private(set) var snapshotSummary = String(localized: "No snapshots")

    /// Reads only `snapshots/` (no lock), so it is cheap enough for the once-a-second refresh.
    private static func snapshotSummary(_ bundle: VMBundle) -> String {
        guard let snapshots = try? SnapshotStore(bundle: bundle).list(), let last = snapshots.last else {
            return String(localized: "No snapshots")
        }
        return String(localized: "\(snapshots.count) snapshots · the latest, \(last.name), from \(SnapshotsModel.dateText(last.createdAt))")
    }

    private func revert(_ undo: () -> Void) {
        isReverting = true
        undo()
        isReverting = false
    }

    private func allowsEditing() -> Bool {
        refresh()
        didSave = false
        return !isLocked
    }

    var isDirty: Bool { cpuCount != saved.cpuCount || memoryBytes != saved.memoryBytes }

    /// A memory size that was not a whole number of GiB is kept as is until the user changes it.
    private var memoryBytes: UInt64 {
        memoryGiB == Int(saved.memoryBytes / Self.gibibyte) ? saved.memoryBytes : UInt64(max(0, memoryGiB)) << 30
    }

    /// macOS VMs without recorded minimums: a conservative floor.
    static let macFloorCPUCount = 2
    static let macFloorMemoryBytes: UInt64 = 4 << 30

    static func floors(_ config: VMConfig) -> (cpu: Int, memoryGiB: Int) {
        let cpu = ResourceLimits.cpuCountRange.lowerBound
        guard config.guest == .macos else { return (cpu, minMemoryGiB) }
        let memory = config.minimumMemoryBytes ?? macFloorMemoryBytes
        return (max(cpu, config.minimumCPUCount ?? macFloorCPUCount),
                max(minMemoryGiB, Int((memory + gibibyte - 1) / gibibyte)))
    }

    // MARK: - Texts

    static var maxMemoryGiB: Int { Int(ResourceLimits.memoryRange.upperBound >> 30) }
    static var minMemoryGiB: Int { max(1, Int((ResourceLimits.memoryRange.lowerBound + gibibyte - 1) / gibibyte)) }

    var introText: String { String(localized: "CPU and memory apply from the next start of \(name).") }
    var lockedDetail: String { String(localized: "Can’t be changed while \(name) is running") }
    var cpuDetail: String {
        guard !isLocked else { return lockedDetail }
        // The wizard's sentences (WizardModel.cpuDetail, memoryDetail).
        let most = String(localized: "at most \(ResourceLimits.maxCPUCount()) (this Mac’s cores)", comment: "CPUs. [not a count]")
        return String(localized: "Recommended: \(2) · \(most)", comment: "CPUs; %@: the most this Mac allows. [not a count]")
    }
    var memoryDetail: String {
        isLocked ? lockedDetail
            : String(localized: "Recommended: \(4) GiB · at most \(Self.maxMemoryGiB) GiB", comment: "Memory sizes. [not a count]")
    }
    var lockedNotice: String { String(localized: "Stop \(name) to change CPU and memory.") }
    /// Rete while the VM runs: the list changes live, the switch only when it is stopped.
    var networkLockedNotice: String {
        String(localized: "\(name) is running: changes to the allowed domains apply right away; the controlled network can be turned on or off only while the VM is stopped.")
    }

    var cpuError: String? {
        // The limit applies to a changed value only: a stored value above this Mac's cores stays valid.
        if cpuCount == saved.cpuCount { return nil }
        let range = cpuFloor...ResourceLimits.maxCPUCount()
        return range.contains(cpuCount) ? nil
            : String(localized: "Out of range: \(range.lowerBound) to \(range.upperBound) CPUs.", comment: "CPU limits. [not a count]")
    }

    var memoryError: String? {
        // Like the CPU count: an unchanged size below a macOS floor (an older VM) stays valid.
        let floor = memoryBytes == saved.memoryBytes ? min(memoryFloorGiB, Self.minMemoryGiB) : memoryFloorGiB
        guard memoryGiB < floor || memoryGiB > Self.maxMemoryGiB else { return nil }
        return String(localized: "Out of range: \(memoryFloorGiB) to \(Self.maxMemoryGiB) GiB.", comment: "Memory limits in GiB. [not a count]")
    }

    var canSave: Bool { !isSaving && !isLocked && isDirty && cpuError == nil && memoryError == nil }

    // MARK: - Actions

    func stepCPU(by delta: Int) {
        cpuCount = min(ResourceLimits.maxCPUCount(), max(cpuFloor, cpuCount + delta))
    }

    func stepMemory(by delta: Int) {
        memoryGiB = min(Self.maxMemoryGiB, max(memoryFloorGiB, memoryGiB + delta))
    }

    /// Validates, then rewrites `config.json` under the bundle lock (owner `.app`). The file is read
    /// again under the lock and only CPU and memory change, so nothing written meanwhile by someone
    /// else is lost. Returns false and sets `error` when the VM is running (checked again first),
    /// the values are out of limits, the lock cannot be taken, or the write fails.
    @discardableResult
    func save() async -> Bool {
        // A second Salva while this one waits for its lock would find that very lock held.
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        error = nil
        didSave = false
        // The VM may have started (here or elsewhere) since the last refresh.
        refresh()
        guard !isLocked else {
            error = Self.runningMessage(name)
            return false
        }
        // A macOS VM never goes below its image's minimums.
        if let message = cpuError ?? memoryError {
            error = message
            return false
        }
        do {
            // An unchanged CPU count is not re-validated (R-M3A-4): validate memory alone in that case.
            let cpuToCheck = cpuCount == saved.cpuCount ? ResourceLimits.cpuCountRange.lowerBound : cpuCount
            try ResourceLimits.validate(cpuCount: cpuToCheck, memoryBytes: memoryBytes)
        } catch {
            self.error = Self.sentence(error)
            return false
        }
        let lock: BundleLock
        do {
            // Retries a brief contention without blocking the main actor.
            lock = try await BundleLock.acquireAsync(bundle, owner: .app)
        } catch NidoError.alreadyRunning {
            refresh()
            self.error = Self.runningMessage(name)
            return false
        } catch {
            self.error = String(localized: "Can’t save the settings: \(Self.sentence(error))")
            return false
        }
        defer { lock.release() }
        do {
            let config = try bundle.updateConfig {
                $0.cpuCount = cpuCount
                $0.memoryBytes = memoryBytes
            }
            saved = (config.cpuCount, config.memoryBytes)
            didSave = true
            configurationWritten()
            return true
        } catch {
            self.error = String(localized: "Can’t save the settings: \(Self.sentence(error))")
            return false
        }
    }

    /// "Arresta" in the notice: this app stops a VM it runs itself; a VM run by `nido start` gets
    /// SIGTERM; a VM of another Nido cannot be stopped from here, and `error` says so with the
    /// library's message.
    func stop() async {
        error = nil
        refresh()
        guard let owner = runningOwner, let vmName = try? VMName(name) else { return }
        switch owner {
        case .app:
            if !(await stopAppVM(vmName)) { error = LibraryModel.otherInstanceStopMessage(name) }
        case .cli, .cliOperation:
            // A maintenance command (snapshot, clone…) is refused with its own message.
            let requestStop = requestStop
            do {
                try await Task.detached { try requestStop(vmName) }.value
            } catch {
                self.error = String(localized: "Can’t stop \(name): \(error.localizedDescription)")
            }
        }
        refresh()
    }

    // MARK: - Condivisione

    var sharesIntro: String {
        needsLegacyMount
            ? String(localized: "Folders on the Mac that the VM sees in \(guestMountPoint). Adding or removing a folder or changing its access takes effect right away, even while the VM is running in Nido. This VM, created with an earlier version of Nido, sees the folders only after it runs the command below once.")
            : String(localized: "Folders on the Mac that the VM sees in \(guestMountPoint). Adding or removing a folder or changing its access takes effect right away, even while the VM is running in Nido.")
    }
    var sharesLockedNotice: String {
        if !showsRosetta {
            return canEditSharesLive
                ? String(localized: "\(name) is running: changes to shared folders apply right away.")
                : String(localized: "Stop \(name) to change the shared folders.")
        }
        return canEditSharesLive
            ? String(localized: "Rosetta can be changed only while the VM is stopped: stop \(name) to change it.")
            : String(localized: "Stop \(name) to change the shared folders and Rosetta.")
    }

    /// The VM runs in this app's window: shared folders change at once in its session.
    var canEditSharesLive: Bool { runningOwner == .app && applyLiveShares != nil && isOpenInApp() }

    /// The shared-folder controls are usable: a stopped VM, or one running in this app.
    var canEditShares: Bool { (!isLocked || canEditSharesLive) && !isEditingShares && !isTemplate }

    func problem(for folder: SharedFolder) -> String? { shareProblems[folder.name.lowercased()] }

    /// Shares a folder of the Mac, read-only, named after the folder (made unique). Refused for a
    /// running VM and for the paths `SharedFolder.validate` refuses; `shareError` says why.
    @discardableResult
    func addSharedFolder(path: String) async -> Bool {
        let paths = NidoPaths(root: bundle.url.deletingLastPathComponent())
        let url: URL
        do {
            url = try SharedFolder.validate(hostPath: path, paths: paths, imageCache: imageCache, home: home)
        } catch {
            shareError = Self.sentence(error)
            return false
        }
        return await editShares { folders in
            let folder = SharedFolder(
                name: SharedFolder.defaultName(for: url, taken: folders.map(\.name)), hostPath: url.path, readOnly: true)
            folders = try SharedFolder.adding(folder, to: folders)
        }
    }

    @discardableResult
    func removeSharedFolder(_ name: String) async -> Bool {
        await editShares { folders in folders = try SharedFolder.removing(name, from: folders) }
    }

    @discardableResult
    func setReadOnly(_ readOnly: Bool, for name: String) async -> Bool {
        await editShares { folders in folders = try SharedFolder.settingReadOnly(readOnly, for: name, in: folders) }
    }

    /// Rewrites the shared folders under the bundle lock (owner `.app`), from the config read
    /// again under it: CPU and memory edits not yet saved are not written, nor lost. With the VM
    /// running in this app the lock is the session's: the config is rewritten in place
    /// (`VMBundle.updateConfig`) and the session's folders are replaced at once.
    private func editShares(_ edit: @escaping @Sendable (inout [SharedFolder]) throws -> Void) async -> Bool {
        guard !isTemplate else {
            shareError = Self.templateMessage(name)
            return false
        }
        refresh()
        if canEditSharesLive { return await editSharesLive(edit) }
        liveNotice = nil
        return await editSharing(runningMessage: Self.sharesRunningMessage(name)) { config in
            try edit(&config.sharedFolders)
        }
    }

    private func editSharesLive(_ edit: @escaping @Sendable (inout [SharedFolder]) throws -> Void) async -> Bool {
        guard !isEditingShares, let applyLiveShares else { return false }
        isEditingShares = true
        defer { isEditingShares = false }
        shareError = nil
        liveNotice = nil
        let bundle = bundle
        let result = await Task.detached { () -> Result<VMConfig, any Error> in
            do {
                return .success(try bundle.updateConfig { config in try edit(&config.sharedFolders) })
            } catch {
                return .failure(error)
            }
        }.value
        let config: VMConfig
        switch result {
        case .success(let written): config = written
        case .failure(let error):
            shareError = Self.sentence(error)
            return false
        }
        sharedFolders = config.sharedFolders
        checkMissingShares()
        configurationWritten()
        do {
            let warnings = try applyLiveShares(config.sharedFolders)
            var notice = [String(localized: "Applied at once: \(name) is running and now sees the folders as you set them.")]
            notice += warnings
            if needsLegacyMount {
                notice.append(String(localized: "This VM sees them in \(SharedFolder.guestMountPoint) only after it runs the command below once."))
            }
            liveNotice = notice.joined(separator: " ")
        } catch {
            // The VM stopped meanwhile (or has no folder device): the change is saved for the next start.
            shareError = String(localized: "Saved, but not applied to the running VM: \(Self.sentence(error)) It applies from the next start.")
        }
        return true
    }

    /// One change of the Condivisione section (shared folders or Rosetta) under the bundle lock
    /// (owner `.app`), from the config read again under it. Refused while the VM runs; the
    /// error goes to `shareError`.
    private func editSharing(
        runningMessage: String, _ edit: @escaping @Sendable (inout VMConfig) throws -> Void
    ) async -> Bool {
        guard !isEditingShares else { return false }
        isEditingShares = true
        defer { isEditingShares = false }
        shareError = nil
        refresh()
        guard !isLocked else {
            shareError = runningMessage
            return false
        }
        do {
            // Checked again in the config being written (it may have become a template since).
            let config = try await VMControl.editConfigAsync(bundle, owner: .app) { config in
                guard !config.isTemplate else { throw NidoError.isTemplate(config.name.rawValue) }
                try edit(&config)
            }
            sharedFolders = config.sharedFolders
            rosetta = config.rosetta
            checkMissingShares()
            configurationWritten()
            return true
        } catch NidoError.vmMustBeStopped {
            refresh()
            shareError = runningMessage
            return false
        } catch NidoError.isTemplate {
            isTemplate = true
            shareError = Self.templateMessage(name)
            return false
        } catch {
            shareError = Self.sentence(error)
            return false
        }
    }

    // MARK: - Rosetta

    /// The toggle is locked while the VM runs, while a change is written, and when Rosetta
    /// cannot be used on this Mac and is off (a VM that has it on can always turn it off).
    var isRosettaLocked: Bool {
        isLocked || isTemplate || isEditingShares || isInstallingRosetta || (!rosetta && rosettaState != .installed)
    }

    var rosettaExplanation: String {
        if isLocked { return String(localized: "Can be changed only with the VM stopped.") }
        if let reason = rosettaState.reason {
            if rosetta { return String(localized: "\(reason) The VM starts without Rosetta until it’s available.") }
            return rosettaState == .notInstalled ? String(localized: "\(reason) Install it to turn it on.") : reason
        }
        return rosetta
            ? String(localized: "The VM runs Linux programs for Intel (x86_64) with Rosetta.")
            : String(localized: "Runs Linux programs for Intel (x86_64) in the VM with Rosetta.")
    }

    /// "Installa Rosetta…" is offered only when this Mac supports it and it is missing.
    var canInstallRosetta: Bool { rosettaState == .notInstalled && !isInstallingRosetta }

    /// The one-time guest command for a VM created before Rosetta support, while Rosetta is on.
    var rosettaLegacyCommand: String? {
        rosetta && !guestRegistersRosetta ? RosettaSupport.legacyGuestCommand : nil
    }

    var rosettaInstallMessage: String {
        String(localized: "macOS will download and install Rosetta for Linux, a system component. It may ask you to confirm again.")
    }

    @discardableResult
    func setRosetta(_ on: Bool) async -> Bool {
        guard !isTemplate else {
            shareError = Self.templateMessage(name)
            return false
        }
        if on, rosettaState != .installed {
            shareError = rosettaState.reason
            return false
        }
        return await editSharing(runningMessage: Self.rosettaRunningMessage(name)) { config in
            config.rosetta = on
        }
    }

    /// Runs the system install (only after the user confirmed it), then rereads the state.
    func installRosetta() async {
        guard canInstallRosetta else { return }
        isInstallingRosetta = true
        defer { isInstallingRosetta = false }
        shareError = nil
        do {
            try await systemInstallRosetta()
        } catch {
            shareError = String(localized: "Couldn’t install Rosetta: \(Self.sentence(error))")
        }
        rosettaState = readRosettaState()
    }

    nonisolated static func rosettaRunningMessage(_ name: String) -> String {
        String(localized: "VM running: stop \(name) to change Rosetta.")
    }

    private func checkMissingShares() {
        let paths = NidoPaths(root: bundle.url.deletingLastPathComponent())
        var problems: [String: String] = [:]
        for folder in sharedFolders {
            do {
                _ = try SharedFolder.validate(hostPath: folder.hostPath, paths: paths, imageCache: imageCache, home: home)
            } catch .sharedFolderMissing {
                problems[folder.name.lowercased()] = String(localized: "Not found on the Mac: the VM starts without this folder.")
            } catch {
                problems[folder.name.lowercased()] = String(localized: "Left out at start: \(Self.sentence(error))")
            }
        }
        shareProblems = problems
    }

    nonisolated static func sharesRunningMessage(_ name: String) -> String {
        String(localized: "VM running outside this window (for example with nido start): stop \(name) to change the shared folders.")
    }

    nonisolated static func runningMessage(_ name: String) -> String {
        String(localized: "VM running: stop \(name) to change CPU and memory.")
    }

    private static func sentence(_ error: any Error) -> String {
        let text = error.localizedDescription
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst() + (text.hasSuffix(".") ? "" : ".")
    }
}
