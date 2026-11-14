// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore
import Observation

/// State and actions of the creation wizard (S02–S06): Debian or Ubuntu Server, or macOS from an
/// IPSW (M3b).
///
/// The download is asked for on the Download step itself (S03): it shows the host and the most it
/// can download, and nothing reaches the network until "Scarica". Once the image is verified the
/// wizard moves on to Risorse by itself, so the happy path is: Avanti, Scarica, Avanti, Avanti,
/// Crea e avvia. The macOS path (M3b) is: the macOS tile (it opens the IPSW panel), Avanti
/// (the checked image), Avanti, Avanti, Avanti, Crea e installa; the installation then lives in
/// `MacInstallStore`, so the wizard can close while it runs.
@MainActor
@Observable
final class WizardModel: Identifiable {
    enum Step: Int, CaseIterable, Sendable {
        case system = 1, download, resources, access, summary
    }

    enum Phase: Equatable, Sendable {
        case idle
        /// On the Download step, before "Scarica": nothing has been requested yet.
        case confirmingDownload
        case downloading
        case verifying
        case creating
        /// macOS: `installation` runs (in `MacInstallStore`); the wizard may close meanwhile.
        case installing
        /// The message (in the UI language); on the Download or Summary step, with Try Again.
        case failed(String)
        case done(VMName)
    }

    /// A read-only row (InfoRow).
    struct Row: Hashable, Sendable {
        let label: String
        let value: String
        var note: String?
    }

    /// The profile of S02 (spec E): what the new VM gets, or a copy of a template.
    enum Profile: String, CaseIterable, Sendable {
        case debianBase, aiStarter, fromTemplate

        /// "Debian Base", "Ubuntu AI Starter": the family of the chosen distribution (profile
        /// names, never translated); "From Template".
        func title(for distribution: LinuxDistribution) -> String {
            let family = distribution.isUbuntu ? "Ubuntu" : "Debian"
            return switch self {
            case .debianBase: "\(family) Base"
            case .aiStarter: "\(family) AI Starter"
            case .fromTemplate: String(localized: "From Template", comment: "A wizard profile: a new VM from a template.")
            }
        }

        /// The tile's identifier for the UI tests (`profile-<id>`): the profile's name, and
        /// "Da modello" (the Italian title it had) for a template.
        func identifier(for distribution: LinuxDistribution) -> String {
            self == .fromTemplate ? "Da modello" : title(for: distribution)
        }
    }

    nonisolated static let baseName = "debian-13"
    /// The suggested name of a macOS VM.
    nonisolated static let macBaseName = "macos"
    /// macOS defaults (as `nido create --ipsw`): reduced to this Mac, raised to the image's minimums.
    nonisolated static let macDefaultCPUCount = 4
    nonisolated static let macDefaultMemoryGiB = 8
    nonisolated static let macDefaultDiskGiB = 64
    /// The disk the design recommends for macOS (not enforced: the installer checks the space).
    nonisolated static let macRecommendedDiskGiB = 40
    nonisolated static let stepCount = Step.allCases.count
    /// The download speed is the average over this window (for the time left).
    nonisolated static let speedWindow: Duration = .seconds(5)
    /// Steppers: the disk moves in larger steps than CPU and memory.
    nonisolated static let diskStepGiB = 8
    /// Debian Base: the disk of a plain VM; Debian AI Starter: room for Ollama and a model.
    nonisolated static let baseDiskGiB = 16
    nonisolated static let aiStarterDiskGiB = 32

    let id = UUID()
    var step: Step = .system
    var name: String = WizardModel.baseName
    var cpuCount = 2
    /// Starts at the Debian Base default for this Mac (2 GiB with 16 GiB of RAM or less).
    var memoryGiB = 4
    /// The proposed memory, shown as the recommendation.
    private(set) var defaultMemoryGiB = 4
    var diskGiB = 16
    private(set) var publicKeyURL: URL?
    /// Why the chosen key was refused, shown under the field.
    private(set) var keyError: String?
    private(set) var progress: DownloadProgress?
    private(set) var phase: Phase = .idle
    /// Size of the verified base image, once it is known: the disk cannot be smaller.
    var imageBytes: UInt64?

    /// S02: Debian Base (the default), Debian AI Starter, or a template.
    private(set) var profile: Profile = .debianBase
    /// S02: Linux (with its distribution and profile) or macOS from an IPSW.
    private(set) var system: GuestOS = .linux
    /// S02: the Linux distribution of the catalog (Debian 13 by default).
    private(set) var distribution: LinuxDistribution = .debian13

    // macOS (M3b)
    /// The chosen IPSW (only read), its size and what `inspect` found, or why it was refused.
    private(set) var ipswURL: URL?
    private(set) var ipswBytes: UInt64?
    private(set) var macImage: MacImageInfo?
    private(set) var macImageError: String?
    private(set) var macImageErrorDetail: String?
    private(set) var isInspectingImage = false
    /// The account the user creates in Setup Assistant: `nido ssh` logs in as it.
    var sshUser: String
    /// The running installation (it lives in `installs`), nil before Crea e installa.
    private(set) var installation: MacInstallation?
    /// Annulla during the installation asks first ("Annullare l'installazione di …?").
    var isConfirmingCancel = false
    /// DEBUG `-NidoIPSWFile`: the macOS tile takes this file instead of opening the panel.
    let presetIPSW: URL?
    /// Phase 1 (cloud-init), on by default (S05).
    var installEssentialPackages = true
    var installGuestTools = true {
        didSet { if !installGuestTools { installOllama = false } }
    }
    /// Phase 2, off by default: needs the Guest Tools (their `nido-provision` installs it).
    var installOllama = false {
        didSet { if installOllama, !installGuestTools { installOllama = false } }
    }
    /// The optional model downloaded after Ollama (one at most).
    var ollamaModel = ""
    /// "Da modello": the templates of the library, and the one chosen.
    private(set) var templates: [VMSummary] = []
    private(set) var selectedTemplate: String?
    /// "Da modello": another public key than the template's (nil keeps the template's).
    private(set) var templateKeyURL: URL?
    /// S04: the RAM of the running VMs with this one, read off the main actor.
    private(set) var headroom: MemoryHeadroom?
    #if DEBUG
        /// DEBUG `-NidoWizardFixture system-template|summary-template`: `load()` picks the first one.
        @ObservationIgnored private var fixtureSelectsFirstTemplate = false
    #endif

    /// The new VM's tint (S06 Colore): the library proposes one no VM has yet and keeps the
    /// chosen one once the VM exists.
    var tint: VMTint = .graphite
    /// After "Crea e avvia" succeeded: the library opens the VM's window.
    var onCreated: @MainActor (VMName) -> Void = { _ in }
    /// Annulla, or the wizard is done: the library closes the sheet.
    var onClose: @MainActor () -> Void = {}

    private let registry: any VMRegistryProviding
    private let images: WizardImageSource
    private let creator: any VMCreating
    private let freeDiskBytes: UInt64?
    private let physicalMemory: UInt64
    private let hostCores: Int
    private let checkHeadroom: (@Sendable (UInt64) async -> MemoryHeadroom?)?
    private let macInstaller: (any MacVMInstalling)?
    private let installs: MacInstallStore?
    /// Checks of an older IPSW are ignored.
    private var inspectAttempt = 0
    /// The name last suggested by the wizard: a system change replaces it, a typed one stays.
    private var suggestedName = WizardModel.baseName
    /// The wizard's sheet is shown: a failed installation is told here, else in the library.
    private var isPresented = true
    private var existingNames: Set<String> = []
    private var publicKey: String?
    private var imageURL: URL?
    /// The running download or creation: "Annulla" cancels it.
    private var activeTask: Task<Void, Never>?
    /// Progress callbacks of an older attempt are ignored.
    private var attempt = 0
    /// Set by Annulla: the wizard is gone and nothing starts any more.
    private(set) var isClosed = false
    /// The clock of the time left: samples older than `speedWindow` stop counting even when no
    /// progress update arrives (a stalled download). Injected by the tests.
    @ObservationIgnored var now: @MainActor () -> ContinuousClock.Instant = { .now }
    /// The download's speed: the moving average of the last `speedWindow`.
    private var downloadRate = ProgressRate(window: WizardModel.speedWindow)

    init(registry: any VMRegistryProviding, images: WizardImageSource, creator: any VMCreating,
         defaultKeyURL: URL? = WizardModel.defaultKeyURL(), freeDiskBytes: UInt64? = nil,
         physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
         hostCores: Int = ProcessInfo.processInfo.activeProcessorCount,
         checkHeadroom: (@Sendable (UInt64) async -> MemoryHeadroom?)? = nil,
         macInstaller: (any MacVMInstalling)? = nil, installs: MacInstallStore? = nil,
         defaultSSHUser: String = WizardModel.defaultSSHUser(), presetIPSW: URL? = nil) {
        self.physicalMemory = physicalMemory
        self.macInstaller = macInstaller
        self.installs = installs
        self.sshUser = defaultSSHUser
        self.presetIPSW = presetIPSW
        self.hostCores = hostCores
        self.checkHeadroom = checkHeadroom
        let proposed = Self.proposedMemoryGiB(.debianBase, physicalMemory: physicalMemory)
        defaultMemoryGiB = proposed
        memoryGiB = proposed
        self.registry = registry
        self.images = images
        self.creator = creator
        self.freeDiskBytes = freeDiskBytes
        // Preselected only when it exists and is a valid public key; otherwise silently empty.
        if let defaultKeyURL, FileManager.default.fileExists(atPath: defaultKeyURL.path),
           let key = try? VMControl.readPublicKey(at: defaultKeyURL) {
            publicKeyURL = defaultKeyURL
            publicKey = key
        }
    }

    /// `~/.ssh/id_ed25519.pub`, with `~` resolved like a shell does (`$HOME` first).
    nonisolated static func defaultKeyURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        homeDirectory(environment: environment).appendingPathComponent(".ssh/id_ed25519.pub", isDirectory: false)
    }

    /// The Mac's own short user name when it is a valid macOS account name, else empty: the
    /// guest's account often has the same.
    nonisolated static func defaultSSHUser() -> String {
        let user = NSUserName()
        return (try? VMConfig.validateSSHUser(user)) == nil ? "" : user
    }

    nonisolated static func homeDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let home = environment["HOME"], home.hasPrefix("/") { return URL(fileURLWithPath: home, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Reads the existing VM names (and the templates) and suggests a free name.
    func load() async {
        refreshImageOnDisk()
        let summaries = (try? await registry.summaries()) ?? []
        // The VMs being installed have no bundle yet: their names are taken too.
        let names = summaries.map(\.name) + (installs?.installations.map(\.name.rawValue) ?? [])
        existingNames = Set(names.map { $0.lowercased() })
        templates = summaries.filter(\.isTemplate).sorted { $0.name < $1.name }
        #if DEBUG
            if fixtureSelectsFirstTemplate, selectedTemplate == nil, let first = templates.first {
                selectedTemplate = first.name
            }
        #endif
        if name == suggestedName {
            name = Self.suggestedName(existing: names, base: suggestedBase)
            suggestedName = name
        }
    }

    /// The base of the suggested name: `macos`, or the distribution (`debian-13`, `ubuntu-26.04`).
    private var suggestedBase: String { isMac ? Self.macBaseName : distribution.rawValue }

    // MARK: - System (S02, M3b)

    var isMac: Bool { system == .macos }

    /// Debian or macOS. The resources go to the defaults of the system; a suggested name follows it.
    func selectSystem(_ system: GuestOS) {
        guard !isBusy, phase != .installing, self.system != system else { return }
        self.system = system
        followSuggestedName()
        if isMac {
            applyMacDefaults()
        } else {
            selectProfile(profile)
        }
    }

    /// Debian 13, Ubuntu 26.04 or 24.04 (also choosing Linux). Another distribution is another
    /// image: what was downloaded for the previous one is forgotten (the store keeps it cached).
    func selectDistribution(_ distribution: LinuxDistribution) {
        guard !isBusy, phase != .installing else { return }
        let changed = self.distribution != distribution
        self.distribution = distribution
        if changed, case .catalog = images {
            imageURL = nil
            imageBytes = nil
            buildCheck = .idle  // the check was for the other image
            refreshImageOnDisk()
        }
        if isMac { selectSystem(.linux) } else { followSuggestedName() }
    }

    /// The suggested name follows the system and the distribution until the user types one.
    private func followSuggestedName() {
        guard name == suggestedName else { return }
        name = Self.suggestedName(existing: Array(existingNames), base: suggestedBase)
        suggestedName = name
    }

    /// The image to download: the catalog's image of `distribution`.
    private var catalogImage: CloudImage? {
        guard case .catalog(let image, _, _) = images else { return nil }
        // The source's image is the default (tests give their own); another distribution, its own.
        return image.distribution == distribution ? image : distribution.image
    }

    /// "SHA-512" or "SHA-256", as the catalog image lists it.
    private var checksumName: String { catalogImage?.checksum == .sha256 ? "SHA-256" : "SHA-512" }

    /// 4 CPU, 8 GiB and 64 GiB, reduced to this Mac's limits (its cores; as for Linux, at most half
    /// of its memory) and raised to the image's minimums.
    private func applyMacDefaults() {
        let cpus = ResourceLimits.cpuCountRange(hostCores: hostCores)
        cpuCount = max(min(Self.macDefaultCPUCount, cpus.upperBound), macMinimumCPUCount ?? cpus.lowerBound)
        var cap = min(Self.macDefaultMemoryGiB, Self.maxMemoryGiB)
        if physicalMemory > 0 { cap = min(cap, Int((physicalMemory / 2) >> 30)) }
        memoryGiB = max(cap, macMinimumMemoryGiB ?? Self.minMemoryGiB)
        defaultMemoryGiB = memoryGiB
        diskGiB = Self.macDefaultDiskGiB
    }

    private var macMinimumCPUCount: Int? { isMac ? macImage?.minimumCPUCount : nil }
    private var macMinimumMemoryGiB: Int? { isMac ? macImage.map { Self.gibCeiling($0.minimumMemoryBytes) } : nil }

    // MARK: - Immagine macOS (S03, M3b)

    /// Checks the chosen IPSW (`MacRestoreImage.inspect`, off the main actor): nothing is created.
    /// Chosen from the macOS tile (S02), the wizard moves on to Immagine macOS by itself, where the
    /// check shows (F01 macOS: 6 clicks).
    func chooseIPSW(_ url: URL) async {
        guard let macInstaller, !isClosed, phase != .installing else { return }
        if step == .system, isMac {
            step = .download
            phase = .idle
        }
        inspectAttempt += 1
        let attempt = inspectAttempt
        ipswURL = url
        ipswBytes = Self.fileSize(url)
        macImage = nil
        macImageError = nil
        macImageErrorDetail = nil
        isInspectingImage = true
        let result: Result<MacImageInfo, any Error>
        do {
            result = .success(try await macInstaller.inspect(url))
        } catch {
            result = .failure(error)
        }
        // Another file was chosen meanwhile: its own check answers.
        guard attempt == inspectAttempt else { return }
        isInspectingImage = false
        switch result {
        case .success(let info):
            macImage = info
            applyMacDefaults()
        case .failure(let error):
            macImageError = Self.sentence(error)
            macImageErrorDetail = Self.imageErrorDetail(error)
        }
    }

    /// The open panel could not be limited to `.ipsw` files: it is not shown at all.
    func ipswPanelUnavailable() {
        guard ipswURL == nil else { return }
        macImageError = String(localized: "Can’t limit the choice to .ipsw files on this Mac.")
        macImageErrorDetail = nil
    }

    /// What to do about a refused IPSW.
    nonisolated static func imageErrorDetail(
        _ error: any Error, hostMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    ) -> String {
        if case NidoError.restoreImageUnsupported(_, _?) = error {
            return String(localized: "Choose a macOS \(hostMajor) IPSW (a \(hostMajor).x beta works too). Nido hasn’t created any files.",
                          comment: "Both numbers are this Mac's major macOS version (26). [not a count]")
        }
        return String(localized: "Choose the macOS .ipsw file downloaded from Apple’s developer site. Nido hasn’t created any files.")
    }

    /// "~/Downloads/UniversalMac_26.6_Restore.ipsw · 17.4 GiB", or "No file chosen".
    var ipswSummary: String {
        guard let ipswURL else { return String(localized: "No file chosen") }
        return Self.abbreviated(ipswURL) + (ipswBytes.map { " · \(ByteSize.text($0))" } ?? "")
    }

    /// The checked image (S03 compatibile).
    var ipswRows: [Row] {
        guard let macImage else { return [] }
        let memory = ByteSize.text(macImage.minimumMemoryBytes)
        return [
            Row(label: String(localized: "Version"), value: "macOS \(macImage.version) (\(macImage.buildVersion))"),
            Row(label: String(localized: "This Mac"), value: String(localized: "Compatible"),
                note: String(localized: "Virtualization supports the image and its hardware model.")),
            Row(label: String(localized: "Minimum requirements"),
                value: String(localized: "\(macImage.minimumCPUCount) CPUs · \(memory) of memory",
                              comment: "The minimum requirements of a macOS image; %@ is a size (4 GiB).")),
            Row(label: String(localized: "Installation"),
                value: String(localized: "4 to 20 minutes, depending on the Mac and the disk")),
        ]
    }

    // MARK: - Accesso (S05, M3b)

    /// The macOS account name: required and a valid short name (`VMConfig.validateSSHUser`).
    var sshUserError: String? {
        guard isMac else { return nil }
        if sshUser.isEmpty { return String(localized: "Enter the short name of the account you’ll create in macOS.") }
        do {
            try VMConfig.validateSSHUser(sshUser)
            return nil
        } catch {
            return Self.sentence(error)
        }
    }

    // MARK: - Installazione (S06, M3b)

    var installTitle: String {
        let version = installation?.version ?? macImage?.version ?? ""
        return String(localized: "Installing macOS \(version)", comment: "%@ is the macOS version (26.6).")
    }
    var installDetail: String { installation?.detailText ?? MacInstallation.percentText(0) }
    var installFraction: Double { installation?.fraction ?? 0 }
    var cancelQuestion: String {
        let vm = installation?.name.rawValue ?? name
        return String(localized: "Cancel installing \(vm)?", comment: "%@ is the VM's name.")
    }

    /// Annulla: during the installation it asks first; otherwise it closes the wizard.
    func requestCancel() {
        if phase == .installing {
            // Already cancelling: the installer is cleaning up, nothing to ask.
            guard installation?.isCancelling != true else { return }
            isConfirmingCancel = true
        } else {
            cancel()
        }
    }

    /// "Continua" in the confirmation: the installation goes on.
    func keepInstalling() {
        isConfirmingCancel = false
    }

    /// "Annulla l'installazione": stops it, waits for the installer's cleanup, closes the wizard.
    func confirmCancelInstall() async {
        isConfirmingCancel = false
        guard phase == .installing, let installation else { return }
        await installation.cancel()
        isPresented = false
        isClosed = true
        onClose()
    }

    /// "Continua nella libreria": the wizard closes, the installation goes on (its card shows it).
    func continueInLibrary() {
        guard phase == .installing else { return }
        isPresented = false
        onClose()
    }

    /// "Mostra" on the installing card: the same wizard is shown again.
    func reopen() {
        isPresented = true
        isClosed = false
    }

    /// The sheet went away (any path): an installation goes on, anything else is cancelled.
    func sheetClosed() {
        if phase == .installing {
            isPresented = false
            return
        }
        cancel()
    }

    private func startInstall() {
        guard let macInstaller, let installs, let ipswURL, let macImage, let publicKeyURL else { return }
        do {
            let vmName = try VMName(name)
            guard let diskBytes else { throw NidoError.invalidResources(Self.diskTooLarge) }
            // Read again: the file may have changed since it was chosen.
            let key = try VMControl.readPublicKey(at: publicKeyURL)
            let request = MacVMRequest(
                name: vmName, ipsw: ipswURL, cpuCount: cpuCount, memoryBytes: memoryBytes, diskBytes: diskBytes,
                sshUser: sshUser, publicKey: key, sshPublicKeyPath: publicKeyURL.path)
            phase = .installing
            isPresented = true
            installation = installs.start(request, version: macImage.version, installer: macInstaller, wizard: self)
        } catch {
            phase = .failed(Self.sentence(error))
        }
    }

    /// The installation ended with the VM in the library: it opens for Setup Assistant.
    func installationFinished(_ job: MacInstallation) {
        installation = nil
        existingNames.insert(job.name.rawValue.lowercased())
        phase = .done(job.name)
        onCreated(job.name)
        if isPresented {
            isPresented = false
            onClose()
        }
    }

    func installationCancelled() {
        installation = nil
        isConfirmingCancel = false
        if phase == .installing { phase = .idle }
    }

    /// A failed installation: back to the summary with the reason (a taken name goes back to the
    /// editable name). False when the wizard is not shown: the library tells it instead.
    func installationFailed(_ error: any Error) -> Bool {
        installation = nil
        isConfirmingCancel = false
        if case NidoError.alreadyExists(let taken) = error {
            existingNames.insert(taken.lowercased())
            phase = .idle
        } else {
            phase = .failed(MacInstallation.failureText(error))
        }
        return isPresented
    }

    // MARK: - Profiles (S02, spec E)

    /// The memory proposed for `preset` on this Mac: the default of `ResourceLimits`, never more
    /// than Virtualization.framework allows nor half of the Mac's RAM, in whole GiB.
    nonisolated static func proposedMemoryGiB(_ preset: ResourcePreset, physicalMemory: UInt64) -> Int {
        let preferred = ResourceLimits.defaultMemoryBytes(for: preset, physicalMemory: physicalMemory)
        var cap = ResourceLimits.memoryRange.upperBound
        if physicalMemory > 0 { cap = min(cap, physicalMemory / 2) }
        let gib = Int(min(preferred, cap) >> 30)
        return max(minMemoryGiB, gib)
    }

    /// Chooses the profile; Base and AI Starter set CPU, memory and disk for this Mac (always
    /// editable at Risorse).
    func selectProfile(_ profile: Profile) {
        guard !isBusy else { return }
        self.profile = profile
        let cpus = ResourceLimits.cpuCountRange(hostCores: hostCores)
        switch profile {
        case .debianBase:
            cpuCount = min(cpus.upperBound, max(cpus.lowerBound, 2))
            defaultMemoryGiB = Self.proposedMemoryGiB(.debianBase, physicalMemory: physicalMemory)
            memoryGiB = defaultMemoryGiB
            diskGiB = max(Self.baseDiskGiB, imageBytes.map(Self.gibCeiling) ?? 0)
        case .aiStarter:
            cpuCount = min(cpus.upperBound, max(cpus.lowerBound, 4))
            defaultMemoryGiB = Self.proposedMemoryGiB(.aiStarter, physicalMemory: physicalMemory)
            memoryGiB = defaultMemoryGiB
            diskGiB = max(Self.aiStarterDiskGiB, imageBytes.map(Self.gibCeiling) ?? 0)
        case .fromTemplate:
            if selectedTemplate == nil, templates.count == 1 { selectedTemplate = templates[0].name }
        }
    }

    /// The detail under a profile tile, with this Mac's numbers.
    func profileDetail(_ profile: Profile) -> String {
        let cpus = ResourceLimits.cpuCountRange(hostCores: hostCores)
        switch profile {
        case .debianBase:
            let memory = "\(Self.proposedMemoryGiB(.debianBase, physicalMemory: physicalMemory)) GiB"
            return String(localized: "\(min(cpus.upperBound, 2)) vCPUs · \(memory) · essential packages and Guest Tools",
                          comment: "Detail of the Base profile tile; %@ is the memory (4 GiB).")
        case .aiStarter:
            let memory = "\(Self.proposedMemoryGiB(.aiStarter, physicalMemory: physicalMemory)) GiB"
            return String(localized: "\(min(cpus.upperBound, 4)) vCPUs · \(memory) · disk space for Ollama and models",
                          comment: "Detail of the AI Starter profile tile; %@ is the memory (8 GiB).")
        case .fromTemplate:
            return String(localized: "A copy of a VM saved as a template")
        }
    }

    var isFromTemplate: Bool { !isMac && profile == .fromTemplate }

    func selectTemplate(_ name: String) {
        guard templates.contains(where: { $0.name == name }) else { return }
        selectedTemplate = name
    }

    /// "debian-ai-base": "4 CPUs · 8 GiB · 64 GiB disk".
    nonisolated static func templateDetail(_ vm: VMSummary) -> String {
        guard let cpu = vm.cpuCount, let memory = vm.memoryBytes, let disk = vm.diskBytes else {
            return LibraryModel.resources(of: vm)
        }
        return resourcesText(cpu: cpu, memory: ByteSize.text(memory), disk: ByteSize.text(disk))
    }

    /// "4 CPUs · 8 GiB · 64 GiB disk": the template rows and the summary.
    nonisolated static func resourcesText(cpu: Int, memory: String, disk: String) -> String {
        String(localized: "\(cpu) CPUs · \(memory) · \(disk) disk",
               comment: "A VM's resources: CPUs, memory (8 GiB), disk (64 GiB).")
    }

    /// "Da modello": the user chose another `.pub` than the template's.
    func chooseTemplateKey(_ url: URL) async {
        // Read off the main actor: the file may sit on a slow volume.
        let result = await Task.detached { () -> Result<Void, any Error> in
            Result { _ = try VMControl.readPublicKey(at: url) }
        }.value
        switch result {
        case .success:
            templateKeyURL = url
            keyError = nil
        case .failure(let error):
            keyError = Self.sentence(error)
        }
    }

    // MARK: - Software (S05)

    /// Ollama needs the Guest Tools (their `nido-provision` installs it).
    var canInstallOllama: Bool { installGuestTools }
    /// The model field is editable only with Ollama on.
    var isModelEditable: Bool { installOllama }

    /// The model typed, if any and only with Ollama on.
    private var chosenModel: String? {
        let trimmed = ollamaModel.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    var modelError: String? {
        guard installOllama, let model = chosenModel else { return nil }
        do {
            _ = try GuestCommand.validateModelName(model)
            return nil
        } catch {
            return String(localized: "Invalid model name: use Ollama’s name, for example llama3.2:1b.")
        }
    }

    /// Phase 2 as chosen: nil without Ollama (the model alone means nothing) and from a template.
    var phaseTwoPlan: ProvisioningPlan? {
        guard installOllama, installGuestTools, !isFromTemplate else { return nil }
        return ProvisioningPlan(model: chosenModel)
    }

    /// Phase 1 as chosen (never for a template: it has everything already).
    var provisioningProfile: ProvisioningProfile {
        ProvisioningProfile(essentialPackages: installEssentialPackages, guestTools: installGuestTools)
    }

    /// The model hint under the field: a suggestion for this memory, never a promise.
    var modelNote: String {
        String(localized: "Only one, downloaded after Ollama. With \(memoryGiB) GiB a small model is best: this is a suggestion, not a guarantee.",
               comment: "The VM's memory in GiB. [not a count]")
    }

    // MARK: - Memory headroom (S04)

    /// Reads the memory of the running VMs with this VM's (off the main actor).
    func refreshHeadroom() async {
        guard let checkHeadroom else { return }
        let bytes = memoryBytes
        let result = await checkHeadroom(bytes)
        // A newer value was typed meanwhile: its own refresh answers.
        guard bytes == memoryBytes else { return }
        headroom = result
    }

    /// `MemoryHeadroom.warningText` as a sentence; nil within the limit.
    var headroomWarning: String? {
        headroom?.warning.map(VMWindowModel.headroomSentence)
    }

    var headroomDetail: String? {
        guard headroom?.exceedsThreshold == true, let headroom else { return nil }
        return String(localized: "\(headroom.detail). Nido starts the VM anyway if you choose to.",
                      comment: "%@: the memory the running VMs and this one would take, a sentence without its final period.")
    }

    /// `debian-13`, else `debian-13-2`, `debian-13-3`… (case-insensitive, like the bundles on disk).
    nonisolated static func suggestedName(existing: [String], base: String = baseName) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    // MARK: - Step texts

    var title: String {
        switch step {
        case .system: String(localized: "System")
        case .download:
            isMac ? String(localized: "macOS Image")
                : String(localized: "Download (step)", defaultValue: "Download",
                         comment: "A download, a noun: the wizard step that downloads the system image (a title), and the label of a download’s progress (the Ollama archive, a model).")
        case .resources: String(localized: "Resources")
        case .access: isMac ? String(localized: "Access") : String(localized: "Access and Software")
        case .summary: phase == .installing ? String(localized: "Installation") : String(localized: "Summary")
        }
    }

    var subtitle: String {
        if isMac { return macSubtitle }
        return switch step {
        case .system:
            isFromTemplate ? String(localized: "Choose the template for the new virtual machine.")
                : String(localized: "Choose the system and profile of the new virtual machine.")
        case .download: String(localized: "Nido downloads the official image and checks its integrity before using it.")
        case .resources: resourcesSubtitle
        case .access:
            String(localized: "Sign in to \(name) over SSH with your key, no password, and choose what to set up at first boot.",
                   comment: "%@ is the new VM's name.")
        case .summary:
            if isFromTemplate, let selectedTemplate {
                String(localized: "Check your choices: Nido copies \(selectedTemplate) to \(name) and starts it.",
                       comment: "%1$@: the template; %2$@: the new VM.")
            } else {
                String(localized: "Check your choices: Nido creates \(name) and starts it as soon as it’s ready.",
                       comment: "%@ is the new VM's name.")
            }
        }
    }

    private var resourcesSubtitle: String {
        String(localized: "Choose how much of the Mac’s CPU, memory and disk to give \(name).",
               comment: "%@ is the new VM's name.")
    }

    private var macSubtitle: String {
        switch step {
        case .system: String(localized: "Choose the system of the new virtual machine.")
        case .download: String(localized: "Choose the macOS IPSW file you downloaded: Nido checks that this Mac can install it.")
        case .resources: resourcesSubtitle
        case .access:
            String(localized: "Sign in to \(name) from Terminal with nido ssh and your key, no password.",
                   comment: "%@ is the new VM's name.")
        case .summary:
            if phase == .installing {
                String(localized: "Nido is installing macOS \(installation?.version ?? macImage?.version ?? "") on \(installation?.name.rawValue ?? name). You can close the wizard: the progress stays in the library.",
                       comment: "%1$@: the macOS version; %2$@: the new VM's name.")
            } else {
                String(localized: "Check your choices: Nido installs macOS on \(name) and starts it for Setup Assistant.",
                       comment: "%@ is the new VM's name.")
            }
        }
    }

    /// "Da modello" has two steps: the template, then the summary.
    var stepNumber: Int {
        guard isFromTemplate else { return step.rawValue }
        return step == .summary ? 2 : 1
    }

    var stepTotal: Int { isFromTemplate ? 2 : Self.stepCount }

    var stepLabel: String {
        String(localized: "Step \(stepNumber) of \(stepTotal)", comment: "The wizard's progress. [not a count]")
    }

    var nextLabel: String {
        switch (step, phase) {
        case (.download, .confirmingDownload):
            String(localized: "Download", comment: "Button: downloads the system image (a verb).")
        case (.download, .failed), (.summary, .failed): String(localized: "Try Again")
        case (.summary, .installing): String(localized: "Continue in Library")
        case (.summary, _): isMac ? String(localized: "Create and Install") : String(localized: "Create and Start")
        default: String(localized: "Next", comment: "The wizard's button to the next step.")
        }
    }

    /// A download or a creation is running: Avanti and Indietro wait for it.
    var isBusy: Bool {
        switch phase {
        case .downloading, .verifying, .creating: true
        default: false
        }
    }

    /// Annulla closes the wizard, except while the bundle is being written.
    var canCancel: Bool { phase != .creating }
    /// Indietro works during the download and the checksum too (it cancels them, like Annulla);
    /// not while the bundle is being written nor during a macOS installation.
    var canGoBack: Bool { step != .system && phase != .creating && phase != .installing && !isDone }
    var isNextEnabled: Bool { !isBusy && nextBlocker == nil && !isDone }

    var isDone: Bool {
        if case .done = phase { true } else { false }
    }

    /// Why Next is disabled on this step (shown in the wizard), nil when it is not.
    var nextBlocker: String? {
        if isMac { return macNextBlocker }
        switch step {
        case .system:
            return isFromTemplate ? templateBlocker : nil
        case .download:
            // Scarica waits for "Cerca una nuova build": it decides whether the cached copy is replaced.
            return buildCheck == .checking ? String(localized: "Wait for the build check to finish.") : nil
        case .resources:
            return resourcesBlocker
        case .access:
            return keyBlocker ?? modelError
        case .summary:
            if isFromTemplate { return nameError ?? templateBlocker }
            return nameError ?? resourcesBlocker ?? keyBlocker ?? modelError
        }
    }

    private var macNextBlocker: String? {
        switch step {
        case .system:
            return nil
        case .download:
            return imageBlocker
        case .resources:
            return resourcesBlocker
        case .access:
            return keyBlocker ?? sshUserError
        case .summary:
            if phase == .installing { return nil }
            return nameError ?? imageBlocker ?? resourcesBlocker ?? keyBlocker ?? sshUserError
        }
    }

    private var imageBlocker: String? {
        if isInspectingImage { return String(localized: "The image is still being checked.") }
        guard macImage == nil else { return nil }
        return macImageError ?? String(localized: "Choose a macOS IPSW file.")
    }

    private var templateBlocker: String? {
        if templates.isEmpty { return String(localized: "No templates: first save a VM as a template from the library.") }
        return selectedTemplate == nil ? String(localized: "Choose a template.") : nil
    }

    private var resourcesBlocker: String? { cpuError ?? memoryError ?? diskError }

    private var keyBlocker: String? {
        keyError ?? (publicKeyURL == nil ? String(localized: "Choose an SSH public key.") : nil)
    }

    // MARK: - System (S02)

    /// The detail under the Linux tile of `distribution`: real data, never a guessed size (the
    /// cache is known for the selected distribution only).
    func systemDetail(for distribution: LinuxDistribution) -> String {
        switch images {
        case .catalog:
            distribution == self.distribution && cachedImageBytes != nil
                ? String(localized: "arm64 · cached") : String(localized: "arm64 · cloud image")
        case .localFile: String(localized: "arm64 · local image")
        }
    }

    // MARK: - Download (S03)

    /// The confirmation rows: where the image comes from and how much it can weigh, before any request.
    var downloadRows: [Row] {
        switch images {
        case .catalog:
            let image = catalogImage ?? distribution.image
            let size: String
            let most = ByteSize.text(image.maxBytes)
            if imageURL != nil, let bytes = imageBytes {
                // Returned by `ensureImage` in this session: verified against the checksum list.
                size = String(localized: "\(ByteSize.text(bytes)), verified", comment: "%@ is the image's size.")
            } else if buildCheck == .updateAvailable {
                size = String(localized: "up to \(most) to download · new build", comment: "%@ is a size.")
            } else if let bytes = cachedImageBytes {
                // Only the presence of the file and its sidecar is known here: the store checks the
                // copy again on Download and downloads it (up to maxBytes) if it is not valid.
                size = String(localized: "\(ByteSize.text(bytes)) in the cache · up to \(most) if it isn’t valid",
                              comment: "Both are sizes: the cached image, the most a new download takes.")
            } else {
                // The real size is only known from the response: the catalog's cap is an upper bound.
                size = String(localized: "up to \(most) to download", comment: "%@ is a size.")
            }
            let verification = image.signature != nil
                ? String(localized: "\(checksumName) checksum · Ubuntu signature", comment: "%@ is SHA-256.")
                : String(localized: "\(checksumName) checksum", comment: "%@ is SHA-512 or SHA-256.")
            return [Row(label: String(localized: "Source", comment: "Where the image comes from."),
                        value: image.url.host() ?? image.url.absoluteString),
                    Row(label: String(localized: "File"), value: image.fileName),
                    Row(label: String(localized: "Size"), value: size),
                    Row(label: String(localized: "Verification"), value: verification)]
        case .localFile(let url):
            let size = localImageBytes.map { ByteSize.text($0) }
                ?? String(localized: "unknown", comment: "The image's size is unknown.")
            return [Row(label: String(localized: "Source", comment: "Where the image comes from."),
                        value: String(localized: "local file (debug only)")),
                    Row(label: String(localized: "File"), value: url.lastPathComponent),
                    Row(label: String(localized: "Size"), value: size),
                    Row(label: String(localized: "Verification"),
                        value: String(localized: "none (local file)", comment: "No verification of a local image."))]
        }
    }

    var progressTitle: String {
        if phase == .verifying { return String(localized: "Verifying the image") }
        let system = distribution.displayName
        return String(localized: "Downloading \(system)", comment: "%@ is the system (Debian 13).")
    }

    var progressDetail: String {
        let total = progress?.expectedBytes
        if phase == .verifying {
            // The hash is computed while the image streams in; what is left is the comparison.
            let verifying = String(localized: "Verifying the \(checksumName) checksum", comment: "%@ is SHA-512 or SHA-256.")
            return ([verifying] + (total.map { [ByteSize.text($0)] } ?? [])).joined(separator: " · ")
        }
        let received = ByteSize.text(progress?.receivedBytes ?? 0)
        let amount = total.map {
            String(localized: "\(received) of \(ByteSize.text($0))",
                   comment: "Downloaded so far of the total: 0.4 GiB of 1.2 GiB.")
        } ?? received
        return ([downloadHost, amount] + (remainingTime.map { [Self.remainingText($0)] } ?? [])).joined(separator: " · ")
    }

    /// Time left of the download at the average speed of the last `speedWindow`; nil when the
    /// size or the speed is not known (fewer than two samples, or nothing received in the window).
    var remainingTime: Duration? {
        guard phase == .downloading, let progress, let total = progress.expectedBytes else { return nil }
        let left = Double(total > progress.receivedBytes ? total - progress.receivedBytes : 0)
        return downloadRate.remaining(left: left, now: now())
    }

    /// "about 2 min", or "less than a minute".
    nonisolated static func remainingText(_ time: Duration) -> String {
        let seconds = time / .seconds(1)
        guard seconds >= 60 else { return String(localized: "less than a minute", comment: "Time left.") }
        let minutes = Int((seconds / 60).rounded())
        return String(localized: "about \(minutes) min", comment: "Time left, in minutes.")
    }

    /// 0…1 when the size is known; nil shows an indeterminate bar.
    var progressFraction: Double? {
        guard phase == .downloading, let progress, let total = progress.expectedBytes, total > 0 else { return nil }
        return min(1, Double(progress.receivedBytes) / Double(total))
    }

    private var downloadHost: String {
        switch images {
        case .catalog:
            let image = catalogImage ?? distribution.image
            return image.url.host() ?? image.url.absoluteString
        case .localFile: return String(localized: "local file")
        }
    }

    /// Size of the cached catalog image (with its sidecar) or of the local file, read by
    /// `refreshImageOnDisk()` on load and on entering the Download step: never from `body`.
    private var cachedImageBytes: UInt64?
    private var localImageBytes: UInt64?

    // MARK: - New build of the cached image (S03)

    /// "Check for a New Build": the cached copy against the checksum list the catalog publishes
    /// now. Only on the user's click; kept across Back/Next, reset when the distribution changes or
    /// Download has used the image.
    enum BuildCheck: Equatable {
        case idle, checking, current, updateAvailable
        case failed(String)
    }

    private(set) var buildCheck: BuildCheck = .idle

    /// The notice under the download rows: only for a cached catalog image not yet used in this
    /// session, while the step waits for Scarica.
    struct BuildNotice: Equatable {
        var title: String
        var detail: String?
        var actionLabel: String?
        var isError = false
    }

    var buildNotice: BuildNotice? {
        guard case .catalog = images, cachedImageBytes != nil, imageURL == nil, !isBusy else { return nil }
        switch buildCheck {
        case .idle:
            let publisher = distribution.isUbuntu ? "Ubuntu" : "Debian"
            return BuildNotice(
                title: String(localized: "Image already in the cache."),
                detail: String(localized: "\(publisher) publishes new builds with security fixes. The check downloads only the checksum list.",
                               comment: "%@ is Debian or Ubuntu."),
                actionLabel: String(localized: "Check for a New Build"))
        case .checking:
            return BuildNotice(title: String(localized: "Checking for a new build…"))
        case .current:
            return BuildNotice(title: String(localized: "The cached copy is the current build."))
        case .updateAvailable:
            return BuildNotice(
                title: String(localized: "A new build is available."),
                detail: String(localized: "Download gets it and replaces the cached copy once it’s verified. Existing VMs don’t change.",
                               comment: "“Download” is the wizard's button."))
        case .failed(let message):
            return BuildNotice(title: String(localized: "The check failed."), detail: message,
                               actionLabel: String(localized: "Try Again"), isError: true)
        }
    }

    func checkForNewBuild() async {
        guard case .catalog(_, let store, _) = images, buildNotice?.actionLabel != nil else { return }
        let image = catalogImage ?? distribution.image
        buildCheck = .checking
        let result: BuildCheck
        do {
            switch try await store.checkForUpdate(image) {
            case .current: result = .current
            case .updateAvailable: result = .updateAvailable
            case .notCached: result = .idle
            }
        } catch {
            result = .failed(Self.sentence(error))
        }
        // The distribution may have changed meanwhile: that reset the check, keep it reset.
        guard buildCheck == .checking, image == (catalogImage ?? distribution.image) else { return }
        buildCheck = result
    }

    private func refreshImageOnDisk() {
        switch images {
        case .catalog(_, _, let cacheRoot):
            let image = catalogImage ?? distribution.image
            let file = cacheRoot.appendingPathComponent(image.fileName, isDirectory: false)
            let digest = cacheRoot.appendingPathComponent(image.sidecarName, isDirectory: false)
            cachedImageBytes = FileManager.default.fileExists(atPath: digest.path) ? Self.fileSize(file) : nil
        case .localFile(let url):
            localImageBytes = Self.fileSize(url)
        }
    }

    // MARK: - Resources (S04)

    /// `cpuCountRange` tops out at the number of cores of this Mac (`ResourceLimits.maxCPUCount()`).
    var cpuDetail: String {
        let upper = ResourceLimits.cpuCountRange.upperBound
        let most = String(localized: "at most \(upper) (this Mac’s cores)", comment: "CPUs. [not a count]")
        if isMac, let macImage {
            return String(localized: "At least \(macImage.minimumCPUCount) for macOS \(macImage.version) · \(most)",
                          comment: "CPUs; %2$@: the macOS version; %3$@: the most this Mac allows. [not a count]")
        }
        let recommended = isMac ? Self.macDefaultCPUCount : 2
        return String(localized: "Recommended: \(recommended) · \(most)",
                      comment: "CPUs; %@: the most this Mac allows. [not a count]")
    }

    var cpuError: String? {
        let range = ResourceLimits.cpuCountRange
        if cpuCount > range.upperBound {
            return String(localized: "Over the limit: at most \(range.upperBound) (this Mac’s cores).",
                          comment: "CPUs. [not a count]")
        }
        if let minimum = macMinimumCPUCount, let macImage, cpuCount < minimum {
            return String(localized: "macOS \(macImage.version) needs at least \(minimum) CPUs.")
        }
        if cpuCount < range.lowerBound { return String(localized: "At least \(range.lowerBound) CPUs are needed.") }
        return nil
    }

    var memoryDetail: String {
        if let minimum = macMinimumMemoryGiB, let macImage {
            return String(localized: "At least \(minimum) GiB for macOS \(macImage.version) · at most \(Self.maxMemoryGiB) GiB",
                          comment: "Memory sizes. [not a count]")
        }
        return String(localized: "Recommended: \(defaultMemoryGiB) GiB · at most \(Self.maxMemoryGiB) GiB",
                      comment: "Memory sizes. [not a count]")
    }

    var memoryError: String? {
        if memoryGiB > Self.maxMemoryGiB {
            return String(localized: "Over the limit: at most \(Self.maxMemoryGiB) GiB on this Mac.",
                          comment: "A memory size. [not a count]")
        }
        if let minimum = macMinimumMemoryGiB, let macImage, memoryGiB < minimum {
            return String(localized: "macOS \(macImage.version) needs at least \(minimum) GiB of memory.",
                          comment: "A memory size. [not a count]")
        }
        if memoryGiB < Self.minMemoryGiB {
            return String(localized: "At least \(Self.minMemoryGiB) GiB is needed.", comment: "A memory size. [not a count]")
        }
        do {
            try ResourceLimits.validate(cpuCount: ResourceLimits.cpuCountRange.lowerBound, memoryBytes: memoryBytes)
        } catch {
            return Self.sentence(error)
        }
        return nil
    }

    var diskDetail: String {
        let free = freeDiskBytes.map { ByteSize.text(($0 >> 30) << 30) }
        if isMac {
            let recommended = Self.macRecommendedDiskGiB
            guard let free else {
                return String(localized: "Recommended: at least \(recommended) GiB", comment: "A disk size. [not a count]")
            }
            return String(localized: "Recommended: at least \(recommended) GiB · free space on the Mac: \(free)",
                          comment: "A disk size; %@ is a size. [not a count]")
        }
        return free.map { String(localized: "Free space on the Mac: \($0)", comment: "%@ is a size.") }
            ?? String(localized: "The disk takes space on the Mac only when the VM writes data.")
    }

    var diskError: String? {
        guard diskGiB >= 1 else { return String(localized: "The disk must be at least 1 GiB.") }
        guard let diskBytes else {
            return String(localized: "Disk size too large: at most \(Self.maxDiskGiB) GiB.", comment: "A disk size. [not a count]")
        }
        guard !isMac, let imageBytes else { return nil }
        do {
            try ResourceLimits.validateDisk(diskBytes: diskBytes, imageBytes: imageBytes)
        } catch {
            return String(localized: "The disk must hold the image: at least \(Self.gibCeiling(imageBytes)) GiB.",
                          comment: "A disk size. [not a count]")
        }
        return nil
    }

    nonisolated static var maxMemoryGiB: Int { Int(ResourceLimits.memoryRange.upperBound >> 30) }
    nonisolated static var minMemoryGiB: Int { max(1, gibCeiling(ResourceLimits.memoryRange.lowerBound)) }

    /// Largest disk whose size in bytes fits a UInt64.
    nonisolated static let maxDiskGiB = Int(UInt64.max >> 30)

    /// Memory in bytes; saturates (and then fails validation) instead of wrapping.
    var memoryBytes: UInt64 { Self.gibToBytes(memoryGiB) ?? UInt64.max }
    /// Disk in bytes; nil when the typed value does not fit (never a wrapped size).
    var diskBytes: UInt64? { Self.gibToBytes(diskGiB) }

    nonisolated static func gibToBytes(_ gib: Int) -> UInt64? {
        let (bytes, overflow) = UInt64(max(0, gib)).multipliedReportingOverflow(by: 1 << 30)
        return overflow ? nil : bytes
    }

    /// Steppers stay inside the valid ranges; only a typed value can go out of them.
    func stepCPU(by delta: Int) {
        let range = ResourceLimits.cpuCountRange
        let lowest = max(range.lowerBound, macMinimumCPUCount ?? 0)
        cpuCount = min(range.upperBound, max(lowest, Self.clampedSum(cpuCount, delta)))
    }

    func stepMemory(by delta: Int) {
        let lowest = max(Self.minMemoryGiB, macMinimumMemoryGiB ?? 0)
        memoryGiB = min(Self.maxMemoryGiB, max(lowest, Self.clampedSum(memoryGiB, delta)))
    }

    func stepDisk(by delta: Int) {
        let minimum = isMac ? 1 : max(1, imageBytes.map(Self.gibCeiling) ?? 1)
        diskGiB = min(Self.maxDiskGiB, max(minimum, Self.clampedSum(diskGiB, delta * Self.diskStepGiB)))
    }

    /// `a + b` without trapping on a huge typed value.
    nonisolated private static func clampedSum(_ a: Int, _ b: Int) -> Int {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? (b > 0 ? Int.max : Int.min) : sum
    }

    // MARK: - Access (S05)

    /// Validates and takes the chosen file; a refused file leaves no key chosen.
    func choosePublicKey(_ url: URL) {
        do {
            publicKey = try VMControl.readPublicKey(at: url)
            publicKeyURL = url
            keyError = nil
        } catch {
            publicKey = nil
            publicKeyURL = nil
            keyError = Self.sentence(error)
        }
    }

    /// The open panel could not be limited to `.pub` files: it is not shown at all.
    func keyPanelUnavailable() {
        // A key already chosen stays valid: only an empty field gets the explanation.
        guard publicKeyURL == nil else { return }
        keyError = String(localized: "Can’t limit the choice to .pub files on this Mac.")
    }

    /// "~/.ssh/id_ed25519.pub · ssh-ed25519", or what to do when no key is chosen.
    var keySummary: String {
        guard let publicKeyURL else { return String(localized: "No key chosen") }
        let type = publicKey?.split(separator: " ").first.map(String.init)
        return Self.abbreviated(publicKeyURL) + (type.map { " · \($0)" } ?? "")
    }

    // MARK: - Summary (S06)

    var nameError: String? {
        do {
            _ = try VMName(name)
        } catch {
            return Self.sentence(error)
        }
        if existingNames.contains(name.lowercased())
            || installs?.installations.contains(where: { $0.name.rawValue.lowercased() == name.lowercased() }) == true {
            return String(localized: "A VM named \(name) already exists.")
        }
        return nil
    }

    var summaryRows: [Row] {
        let system = String(localized: "System")
        let resources = String(localized: "Resources")
        let access = String(localized: "Access")
        let noKey = String(localized: "no key")
        let resourcesValue = Self.resourcesText(cpu: cpuCount, memory: "\(memoryGiB) GiB", disk: "\(diskGiB) GiB")
        if isMac {
            let version = macImage?.version ?? ""
            let file = ipswURL?.lastPathComponent ?? String(localized: "no file")
            let key = publicKeyURL?.lastPathComponent ?? noKey
            return [
                Row(label: system, value: String(localized: "macOS \(version) · from \(file)",
                                                 comment: "%1$@: the macOS version; %2$@: the IPSW file's name.")),
                Row(label: resources, value: resourcesValue),
                Row(label: access, value: String(localized: "nido ssh as \(sshUser) · \(key)",
                                                 comment: "%1$@: the macOS account; %2$@: the key file's name.")),
                Row(label: String(localized: "Network and folders"),
                    value: String(localized: "Controlled, macOS base list · no shared folders", comment: "The controlled network."),
                    note: String(localized: "The VM can reach only Apple’s servers for activation, macOS updates and the clock. The App Store, iCloud and other sites stay blocked until you add their domains in the VM’s settings, Network section.")),
                Row(label: String(localized: "Installation"),
                    value: String(localized: "4 to 20 minutes, depending on the Mac and the disk"),
                    note: String(localized: "Then you complete macOS Setup Assistant in the VM’s window.")),
            ]
        }
        if isFromTemplate {
            let template = templates.first { $0.name == selectedTemplate }
            let detail = template.map(Self.templateDetail) ?? ""
            return [
                Row(label: String(localized: "Template", comment: "A VM saved to make new VMs."),
                    value: selectedTemplate ?? String(localized: "none", comment: "No template chosen.")),
                Row(label: resources, value: String(localized: "\(detail), like the template", comment: "%@ is the template's resources.")),
                Row(label: String(localized: "Space on the Mac"),
                    value: String(localized: "No extra space until the disks change", comment: "Space on the Mac."),
                    note: String(localized: "Instant copy of the disk (clonefile).")),
                Row(label: String(localized: "Identity"), value: String(localized: "New: MAC address, host name, SSH host keys")),
                Row(label: String(localized: "Shared folders and AI bridge"),
                    value: String(localized: "None · off", comment: "No shared folders, the AI bridge off."),
                    note: String(localized: "They don’t carry over from the template to the new VM: you choose them later.")),
            ]
        }
        var rows = [Row(label: system, value: "\(distribution.displayName) · arm64 · \(profile.title(for: distribution))"),
                    Row(label: resources, value: resourcesValue)]
        var firstBoot: [String] = []
        if installEssentialPackages { firstBoot.append(String(localized: "Essential packages")) }
        if installGuestTools { firstBoot.append("Guest Tools") }
        rows.append(Row(label: String(localized: "First boot"),
                        value: firstBoot.isEmpty ? String(localized: "User and network only") : firstBoot.joined(separator: " · ")))
        if let plan = phaseTwoPlan {
            rows.append(Row(label: String(localized: "After first boot"),
                            value: plan.model.map {
                                String(localized: "Ollama and the \($0) model", comment: "%@ is an Ollama model's name.")
                            } ?? "Ollama",
                            note: String(localized: "The VM is usable before then: the progress stays visible in its window.")))
        }
        rows.append(Row(label: access, value: "SSH · " + (publicKeyURL?.lastPathComponent ?? noKey)))
        // A zero-width space after each dot lets a long host name (the R2 bucket) wrap there
        // instead of in the middle of a label.
        let domains = EgressPolicy.base(for: distribution).allow
            .map { $0.description.replacingOccurrences(of: ".", with: ".\u{200B}") }
            .joined(separator: ", ")
        rows.append(Row(label: String(localized: "Network"),
                        value: String(localized: "Controlled · base list", comment: "The controlled network."),
                        note: String(localized: "The VM reaches only \(domains). You can add other domains in the VM’s settings, Network section.",
                                     comment: "%@ is a list of domains.")))
        return rows
    }

    /// "From Template": the key of the new VM.
    var templateKeySummary: String {
        templateKeyURL.map(Self.abbreviated) ?? String(localized: "The template’s key", comment: "The SSH public key of the new VM.")
    }

    var creationTitle: String { String(localized: "Creating \(name)", comment: "%@ is a VM's or a snapshot's name.") }
    var creationDetail: String {
        isFromTemplate ? String(localized: "Instant copy of the template and a new identity")
            : String(localized: "Copying the disk (\(diskGiB) GiB) and preparing cloud-init", comment: "A disk size. [not a count]")
    }

    // MARK: - Navigation

    func next() async {
        guard isNextEnabled, !isClosed else { return }
        switch step {
        case .system where isMac:
            step = .download
            phase = .idle
        case .download where isMac:
            guard macImage != nil else { return }
            step = .resources
        case .summary where isMac:
            if phase == .installing {
                continueInLibrary()
            } else {
                startInstall()
            }
        case .system where isFromTemplate:
            // A template has its disk and its software: straight to the summary.
            step = .summary
            phase = .idle
        case .system:
            refreshImageOnDisk()
            step = .download
            phase = imageURL == nil ? .confirmingDownload : .idle
        case .download:
            if imageURL != nil, phase == .idle {
                step = .resources
            } else {
                // Busy before the first suspension: a second queued next() finds Avanti disabled.
                phase = .downloading
                // A download left with Indietro may still be removing its partial file.
                let backs = attempt
                await activeTask?.value
                // Indietro or Annulla while waiting: nothing starts.
                guard !isClosed, attempt == backs, step == .download, phase == .downloading else { return }
                await run { await self.download() }
            }
        case .resources:
            step = .access
        case .access:
            step = .summary
        case .summary where isFromTemplate:
            guard selectedTemplate != nil else { return }
            phase = .creating
            await run { await self.createFromTemplate() }
        case .summary:
            guard imageURL != nil, publicKeyURL != nil else { return }
            phase = .creating
            await run { await self.create() }
        }
    }

    func back() {
        guard canGoBack else { return }
        switch step {
        case .system:
            break
        case .download where isMac:
            // A check still running is ignored when it ends.
            if isInspectingImage {
                inspectAttempt += 1
                isInspectingImage = false
                ipswURL = nil
                ipswBytes = nil
            }
            step = .system
            phase = .idle
        case .resources where isMac:
            step = .download
            phase = .idle
        case .download:
            // Declining the download (nothing was requested), or leaving one in progress: the same
            // cancellation as Annulla, so the store removes its partial file. The cancelled attempt
            // changes nothing any more.
            if phase == .downloading || phase == .verifying {
                attempt += 1
                activeTask?.cancel()
                progress = nil
                downloadRate.reset()
            }
            step = .system
            phase = .idle
        case .resources:
            refreshImageOnDisk()
            step = .download
            phase = imageURL == nil ? .confirmingDownload : .idle
        case .access:
            step = .resources
        case .summary:
            step = isFromTemplate ? .system : .access
            phase = .idle
        }
    }

    /// Annulla: stops a running download (the store removes its partial file) and closes the wizard.
    func cancel() {
        // An installation is cancelled only after asking (`requestCancel`).
        guard canCancel, phase != .installing else { return }
        // Closed for good: a Scarica still waiting for an older cleanup must not start afterwards,
        // and the running attempt changes nothing any more.
        isClosed = true
        attempt += 1
        activeTask?.cancel()
        onClose()
    }

    /// Waits for a cancelled download to finish its cleanup.
    func waitForCleanup() async {
        await activeTask?.value
    }

    private func run(_ work: @escaping @MainActor () async -> Void) async {
        let task = Task { await work() }
        activeTask = task
        await task.value
    }

    private func download() async {
        attempt += 1
        let attempt = attempt
        progress = nil
        downloadRate.reset()
        phase = .downloading
        do {
            let url: URL
            switch images {
            case .catalog(_, let store, _):
                let image = catalogImage ?? distribution.image
                // The confirmation is the Download step itself: "Scarica" was just pressed.
                // After "Cerca una nuova build" found one: the cached copy is replaced.
                url = try await store.ensureImage(
                    image, refresh: buildCheck == .updateAvailable, confirm: { _ in true }, progress: { [weak self] value in
                    Task { @MainActor in self?.receive(value, attempt: attempt) }
                })
            case .localFile(let file):
                try Task.checkCancellation()
                guard Self.fileSize(file) != nil else { throw NidoError.notFound(file.path) }
                url = file
            }
            try Task.checkCancellation()
            guard attempt == self.attempt else { return }
            imageURL = url
            buildCheck = .idle
            imageBytes = Self.diskSize(url)
            if let imageBytes, (diskBytes ?? 0) < imageBytes { diskGiB = Self.gibCeiling(imageBytes) }
            phase = .idle
            step = .resources
        } catch is CancellationError {
            // Left with Indietro: the wizard is already elsewhere.
            if attempt == self.attempt { phase = .confirmingDownload }
        } catch where attempt != self.attempt {
            return
        } catch NidoError.checksumMismatch {
            phase = .failed(checksumMismatchText)
        } catch {
            phase = .failed(Self.sentence(error))
        }
    }

    /// A progress update of download `attempt` (updates hop to the main actor one by one, so they
    /// may arrive out of order): a smaller count than the one shown is ignored, and the phase never
    /// goes back from verifying to downloading.
    func receive(_ value: DownloadProgress, attempt: Int, at time: ContinuousClock.Instant = .now) {
        guard attempt == self.attempt, phase == .downloading || phase == .verifying else { return }
        if let current = progress, value.receivedBytes < current.receivedBytes { return }
        progress = value
        downloadRate.record(Double(value.receivedBytes), at: time)
        // The last update comes at the end of the transfer: the checksum is then compared.
        if let total = value.expectedBytes, value.receivedBytes >= total { phase = .verifying }
    }

    private func create() async {
        guard let imageURL, let publicKeyURL else {
            phase = .idle
            return
        }
        phase = .creating
        do {
            let vmName = try VMName(name)
            guard let diskBytes else { throw NidoError.invalidResources(Self.diskTooLarge) }
            // Read again: the file may have changed since it was chosen.
            let key = try VMControl.readPublicKey(at: publicKeyURL)
            try await creator.create(LinuxVMRequest(
                name: vmName, baseImage: imageURL, cpuCount: cpuCount, memoryBytes: memoryBytes,
                diskBytes: diskBytes, publicKey: key, profile: provisioningProfile,
                sshPublicKeyPath: publicKeyURL.path,
                pendingProvisioning: phaseTwoPlan.map { PendingProvisioning(ollama: true, model: $0.model) },
                distribution: distribution))
            existingNames.insert(vmName.rawValue.lowercased())
            phase = .done(vmName)
            onCreated(vmName)
            onClose()
        } catch NidoError.alreadyExists(let taken) {
            // Back to the editable summary: the name field shows "A VM named … already exists" and blocks Try Again
            // until another name is typed.
            existingNames.insert(taken.lowercased())
            phase = .idle
        } catch {
            phase = .failed(Self.sentence(error))
        }
    }

    private func createFromTemplate() async {
        guard let selectedTemplate else {
            phase = .idle
            return
        }
        phase = .creating
        do {
            let vmName = try VMName(name)
            try await creator.createFromTemplate(try VMName(selectedTemplate), as: vmName, sshKeyPath: templateKeyURL)
            existingNames.insert(vmName.rawValue.lowercased())
            phase = .done(vmName)
            onCreated(vmName)
            onClose()
        } catch NidoError.alreadyExists(let taken) {
            existingNames.insert(taken.lowercased())
            phase = .idle
        } catch {
            phase = .failed(Self.sentence(error))
        }
    }

    // MARK: - Formatting

    /// A NidoError text as a sentence: capital first letter (not for "macOS"), final full stop.
    nonisolated static func sentence(_ error: any Error) -> String {
        var text = error.localizedDescription
        // "macOS" keeps its spelling at the start of a sentence.
        if let first = text.first, !text.hasPrefix("macOS") { text = first.uppercased() + text.dropFirst() }
        if !text.hasSuffix(".") { text += "." }
        return text
    }

    /// Why the resources are refused when the disk's size does not fit in bytes.
    nonisolated static var diskTooLarge: String {
        String(localized: "disk too large", comment: "Why the resources were refused, inside an error message.")
    }

    /// A failed checksum: the download was deleted, Try Again downloads it again.
    private var checksumMismatchText: String {
        String(localized: "The \(checksumName) checksum doesn’t match: the downloaded file was deleted. Try again: Nido downloads the image again.",
               comment: "%@ is SHA-512 or SHA-256.")
    }

    nonisolated static func gibCeiling(_ bytes: UInt64) -> Int {
        Int((bytes + (1 << 30) - 1) >> 30)
    }

    /// Size of the disk an image gives: a qcow2's virtual size, else the file's size.
    nonisolated static func diskSize(_ url: URL) -> UInt64? {
        Qcow2Image.isQcow2(url) ? try? Qcow2Image.virtualSize(of: url) : fileSize(url)
    }

    nonisolated static func fileSize(_ url: URL) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular
        else { return nil }
        return (attributes[.size] as? NSNumber)?.uint64Value
    }

    /// A path under the home folder as `~/…`.
    nonisolated static func abbreviated(_ url: URL) -> String {
        let home = homeDirectory().standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

#if DEBUG
    // MARK: - Screenshot fixtures (DEBUG `-NidoWizardFixture`)

    extension WizardModel {
        /// The wizard states of the design renders (S02–S06), set directly: the screenshot tests
        /// capture states that last a moment (download, checksum, creation) or need a failure.
        enum Fixture: String, CaseIterable, Sendable {
            case system
            case downloadConfirm = "download-confirm"
            case downloadProgress = "download-progress"
            case downloadVerify = "download-verify"
            case downloadChecksumError = "download-checksum-error"
            case resources
            case resourcesOverLimit = "resources-over-limit"
            case access
            case summary
            case creating
            case createError = "create-error"
            // M3c
            case systemTemplate = "system-template"
            case resourcesMemory = "resources-memory"
            case accessOllama = "access-ollama"
            case summaryAI = "summary-ai"
            case summaryTemplate = "summary-template"
            // M3b: the macOS path (ScreensMac.swift).
            case systemMac = "system-mac"
            case imageMacEmpty = "image-mac-empty"
            case imageMacChecking = "image-mac-checking"
            case imageMacCompatible = "image-mac-compatible"
            case imageMacUnsupported = "image-mac-unsupported"
            case resourcesMac = "resources-mac"
            case resourcesMacBelowMinimum = "resources-mac-below-minimum"
            case accessMac = "access-mac"
            case summaryMac = "summary-mac"
            case installMac = "install-mac"
            case installMacCancel = "install-mac-cancel"
            case installMacError = "install-mac-error"
            /// The wizard closed with "Continua nella libreria": the installing card (S01).
            case libraryMacInstalling = "library-mac-installing"

            var isMac: Bool {
                switch self {
                case .systemMac, .imageMacEmpty, .imageMacChecking, .imageMacCompatible, .imageMacUnsupported,
                     .resourcesMac, .resourcesMacBelowMinimum, .accessMac, .summaryMac, .installMac,
                     .installMacCancel, .installMacError, .libraryMacInstalling:
                    true
                default:
                    false
                }
            }
        }

        /// The design's values: 4 CPU, 8 GiB, 64 GiB, a 1,2 GiB image (0,4 GiB downloaded).
        func apply(_ fixture: Fixture) {
            if fixture.isMac {
                applyMac(fixture)
                return
            }
            let imageSize: UInt64 = 1_288_490_189
            // M3c: the AI VM of the renders (debian-ai, 4 CPU, 4 GiB, 64 GiB).
            switch fixture {
            case .systemTemplate, .summaryTemplate:
                // The templates arrive with `load()`: the first one is chosen then.
                profile = .fromTemplate
                fixtureSelectsFirstTemplate = true
                name = "debian-ai"
                step = fixture == .systemTemplate ? .system : .summary
                phase = .idle
                return
            case .resourcesMemory, .accessOllama, .summaryAI:
                apply(fixture == .resourcesMemory ? .resources : fixture == .accessOllama ? .access : .summary)
                profile = .aiStarter
                name = "debian-ai"
                cpuCount = 4
                memoryGiB = fixture == .resourcesMemory ? 8 : 4
                diskGiB = 64
                if fixture == .resourcesMemory {
                    // 4 GiB of running VMs, Docker's 4,9 GiB and this one's 8 GiB on a 16 GiB Mac.
                    headroom = MemoryHeadroom(
                        physicalMemory: 16 << 30, nidoBytes: 4 << 30, foreignBytes: 5_261_334_938,
                        startingBytes: 8 << 30)
                } else {
                    installOllama = true
                    ollamaModel = "llama3.2:1b"
                }
                return
            default:
                break
            }
            cpuCount = 4
            memoryGiB = 8
            diskGiB = 64
            progress = nil
            downloadRate.reset()
            switch fixture {
            case .system:
                step = .system
                phase = .idle
            case .downloadConfirm:
                step = .download
                phase = .confirmingDownload
            case .downloadProgress:
                step = .download
                phase = .downloading
                progress = DownloadProgress(receivedBytes: 429_496_730, expectedBytes: imageSize)
                // 7 MiB/s over the last 5 s: "circa 2 min" left, as in the render.
                // The clock is frozen, so the estimate stays however late the screenshot comes.
                let instant = ContinuousClock.now
                now = { instant }
                downloadRate = ProgressRate(window: Self.speedWindow, samples: [
                    .init(time: instant - Self.speedWindow, value: Double(429_496_730 - (35 << 20))),
                    .init(time: instant, value: 429_496_730),
                ])
            case .downloadVerify:
                step = .download
                phase = .verifying
                progress = DownloadProgress(receivedBytes: imageSize, expectedBytes: imageSize)
            case .downloadChecksumError:
                step = .download
                phase = .failed(checksumMismatchText)
            case .systemTemplate, .resourcesMemory, .accessOllama, .summaryAI, .summaryTemplate:
                break  // Handled above.
            case .systemMac, .imageMacEmpty, .imageMacChecking, .imageMacCompatible, .imageMacUnsupported,
                 .resourcesMac, .resourcesMacBelowMinimum, .accessMac, .summaryMac, .installMac, .installMacCancel,
                 .installMacError, .libraryMacInstalling:
                break  // applyMac.
            case .resources, .resourcesOverLimit, .access, .summary, .creating, .createError:
                // Past the download: a verified image (never read by the fixtures).
                imageURL = URL(fileURLWithPath: "/nido-fixture/debian-13-genericcloud-arm64.raw")
                imageBytes = imageSize
                phase = .idle
                switch fixture {
                case .resources:
                    step = .resources
                case .resourcesOverLimit:
                    step = .resources
                    // Over this Mac's limit, whatever it is (the design shows 16 GiB of 12).
                    memoryGiB = max(16, Self.maxMemoryGiB + 4)
                case .access:
                    step = .access
                default:
                    step = .summary
                    if fixture == .creating { phase = .creating }
                    if fixture == .createError {
                        phase = .failed(String(
                            localized: "Not enough disk space: 64 GiB needed, 41 GiB left on the Mac. Free up space or make the disk smaller in the Resources step.",
                            comment: "Screenshot fixture (debug builds): a failed creation."))
                    }
                }
            }
        }
    }
    extension WizardModel {
        /// The macOS states of the design (ScreensMac.swift): macos-agenti, the user agente, the
        /// IPSW ~/Downloads/UniversalMac_26.6_Restore.ipsw (17,4 GiB), 4 CPU, 8 GiB, 64 GiB.
        private func applyMac(_ fixture: Fixture) {
            let downloads = Self.homeDirectory().appendingPathComponent("Downloads", isDirectory: true)
            let info = MacImageInfo(buildVersion: "25G62", version: "26.6", minimumCPUCount: 2,
                                    minimumMemoryBytes: 4 << 30, hardwareModel: Data())
            system = .macos
            name = "macos-agenti"
            suggestedName = name
            sshUser = "agente"
            cpuCount = 4
            memoryGiB = 8
            defaultMemoryGiB = 8
            diskGiB = 64
            isConfirmingCancel = false
            isInspectingImage = false
            macImageError = nil
            macImageErrorDetail = nil
            ipswURL = downloads.appendingPathComponent("UniversalMac_26.6_Restore.ipsw", isDirectory: false)
            ipswBytes = 18_683_107_738
            macImage = info
            phase = .idle
            switch fixture {
            case .systemMac:
                step = .system
                ipswURL = nil
                ipswBytes = nil
                macImage = nil
            case .imageMacEmpty:
                step = .download
                ipswURL = nil
                ipswBytes = nil
                macImage = nil
            case .imageMacChecking:
                step = .download
                macImage = nil
                isInspectingImage = true
            case .imageMacCompatible:
                step = .download
            case .imageMacUnsupported:
                step = .download
                macImage = nil
                ipswURL = downloads.appendingPathComponent("UniversalMac_27.0_Restore.ipsw", isDirectory: false)
                ipswBytes = 19_434_628_710
                let error = NidoError.restoreImageUnsupported(version: "27.0", requiredHostMajor: 27)
                macImageError = Self.sentence(error)
                macImageErrorDetail = Self.imageErrorDetail(error, hostMajor: 26)
            case .resourcesMac:
                step = .resources
            case .resourcesMacBelowMinimum:
                step = .resources
                memoryGiB = 2
            case .accessMac:
                step = .access
            case .summaryMac:
                step = .summary
            case .installMac, .installMacCancel, .libraryMacInstalling:
                step = .summary
                phase = .installing
                isPresented = true
                if installation == nil, let installs, let vmName = try? VMName(name) {
                    installation = installs.addFixture(name: vmName, version: info.version, wizard: self)
                }
                if fixture == .installMacCancel { isConfirmingCancel = true }
                if fixture == .libraryMacInstalling { continueInLibrary() }
            case .installMacError:
                step = .summary
                phase = .failed(String(
                    localized: "The disk ran out of space during the installation: 66 GiB needed, 41 GiB left on the Mac. Nido deleted the files it created; the IPSW stays where it is.",
                    comment: "Screenshot fixture (debug builds): a failed installation."))
            default:
                break
            }
        }
    }
#endif
