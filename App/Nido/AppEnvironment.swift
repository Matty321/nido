// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore
import Observation

/// Long-lived services shared by every window of the app.
@MainActor
@Observable
final class AppEnvironment {
    /// Problems with the launch arguments (accepted only in DEBUG builds).
    enum LaunchError: LocalizedError, Equatable {
        case missingValue(String)
        case relativePath(String)
        case notADirectory(String)
        case invalidValue(String, String)
        case requiresRoot(String)

        var errorDescription: String? {
            switch self {
            case .missingValue(let flag):
                "Missing path after \(flag)."
            case .relativePath(let path):
                "The path \(path) must be absolute."
            case .notADirectory(let path):
                "\(path) exists but is not a directory."
            case .invalidValue(let flag, let value):
                "Invalid value for \(flag): \(value)."
            case .requiresRoot(let flag):
                "\(flag) requires -NidoRoot: tests never use the real VM root."
            }
        }
    }

    nonisolated static let rootFlag = "-NidoRoot"
    nonisolated static let imageFileFlag = "-NidoImageFile"
    /// DEBUG only: VM windows use sessions without a VM (UI tests of the window).
    nonisolated static let fakeSessionsFlag = "-NidoFakeSessions"
    /// DEBUG only: scripted fake VMs started at launch, "name=plan,…" (screenshot tests).
    nonisolated static let fakeStatesFlag = "-NidoFakeStates"
    /// DEBUG only: the wizard opens at launch in a fixed state (screenshot tests).
    nonisolated static let wizardFixtureFlag = "-NidoWizardFixture"
    /// DEBUG only: the AI bridge uses `DebugFakeRouter` and a dummy in-memory token (proofs; no
    /// network, never the user's Keychain).
    nonisolated static let fakeAIRouterFlag = "-NidoFakeAIRouter"
    /// DEBUG only: what the guests of fake VMs answer, "name=values+ollama,…" (`FakeGuest`,
    /// screenshot tests of the monitor, the provisioning and the AI view).
    nonisolated static let fakeGuestFlag = "-NidoFakeGuest"
    /// DEBUG only: the macOS tile of the wizard takes this IPSW instead of opening the panel.
    nonisolated static let ipswFileFlag = "-NidoIPSWFile"
    /// DEBUG only: macOS installations use `DebugFakeMacInstaller` (UI tests; nothing is installed).
    nonisolated static let fakeMacInstallerFlag = "-NidoFakeMacInstaller"
    /// DEBUG only: the window of this VM opens at launch and the VM starts (real proofs of the
    /// macOS window, where nothing may click the library's Avvia).
    nonisolated static let openVMFlag = "-NidoOpenVM"
    /// DEBUG only: "allowed" or "denied": block notices stay in memory (`DebugNotificationPoster`),
    /// never shown by the system, and the owner's confirmation is refused (UI and screenshot
    /// tests; never a real Touch ID prompt). Any DEBUG test root keeps notices in memory too.
    nonisolated static let notificationsFlag = "-NidoNotifications"
    /// DEBUG only: the updater exists but is never started, whatever the feed (UI tests of the
    /// "Cerca aggiornamenti…" item; no network, no Sparkle state).
    nonisolated static let updatesPreviewFlag = "-NidoUpdatesPreview"

    let paths: NidoPaths
    let registry: VMRegistry
    let imageStore: ImageStore
    let imageCacheRoot: URL
    /// DEBUG `-NidoImageFile`: the wizard's "Scarica" uses this local image instead of the network.
    let imageFile: URL?
    /// DEBUG `-NidoIPSWFile`: the IPSW of the wizard's macOS path (no panel).
    let ipswFile: URL?
    /// Checks IPSWs and installs macOS VMs (`LiveMacVMInstaller`; DEBUG `-NidoFakeMacInstaller`).
    let macInstaller: any MacVMInstalling
    /// The macOS installations: they outlive the wizard; the library and quitting see them.
    let macInstalls = MacInstallStore()
    /// The VM windows' models: one per VM run (or shown) by this app.
    let sessions: VMSessionStore
    /// The remote AI bridge's shared services (Keychain token, router, catalog, per-VM limiters).
    let aiBridge: AIBridgeServices
    /// Watches every VM's network log and notifies its blocks (M3d).
    let egress: EgressMonitor
    /// The RAM warning before a start and in the wizard (off with the DEBUG fakes).
    let checksMemoryHeadroom: Bool
    /// "Novità di Nido" opens by itself after an update only on the user's own VM root: never in
    /// the UI and screenshot tests (DEBUG `-NidoRoot`).
    let showsReleaseNotes: Bool
    /// Sparkle's updater: only with a feed in the build (`NIDO_FEED_URL`) and on the user's own VM
    /// root, never in the UI and screenshot tests (DEBUG `-NidoRoot`) nor in the unit-test host
    /// (no environment at all).
    let updates: UpdateController?
    /// The creation wizard while it is shown: quitting asks first while it downloads or creates.
    @ObservationIgnored weak var activeWizard: WizardModel?
    /// The library's model: quitting asks first while it clones a VM.
    @ObservationIgnored weak var library: LibraryModel?
    #if DEBUG
        /// DEBUG `-NidoWizardFixture`: the library opens the wizard in this state at launch.
        let wizardFixture: WizardModel.Fixture?
        /// DEBUG `-NidoOpenVM`: the library opens this VM's window at launch, once.
        @ObservationIgnored private var openAtLaunch: VMName?

        /// The VM of `-NidoOpenVM`, the first time only (a library window opened again does
        /// not reopen it).
        func takeOpenAtLaunch() -> VMName? {
            defer { openAtLaunch = nil }
            return openAtLaunch
        }
    #endif

    /// Resolves the VM root from the launch arguments and makes sure it exists. `sweepOrphans`
    /// runs once, off the main actor: by default it ends the `gvproxy` orphans a Nido killed with
    /// -9 left (`GvproxyProcess.sweepOrphans`), so their SSH port does not stay open on 127.0.0.1
    /// until the next controlled VM starts.
    init(
        arguments: [String], isDebug: Bool,
        sweepOrphans: @escaping @Sendable () -> Void = { GvproxyProcess.sweepOrphans() }
    ) throws {
        let root = try Self.resolveRoot(arguments: arguments, isDebug: isDebug)
        #if DEBUG
            // Fake VMs take real locks and the wizard fixtures fake a download: never on the
            // user's VMs. Checked before the root is even created.
            if isDebug, root == NidoPaths.defaultRoot() {
                for flag in [Self.fakeSessionsFlag, Self.fakeStatesFlag, Self.wizardFixtureFlag, Self.fakeAIRouterFlag,
                             Self.fakeGuestFlag, Self.ipswFileFlag, Self.fakeMacInstallerFlag, Self.openVMFlag,
                             Self.notificationsFlag]
                where arguments.contains(flag) {
                    throw LaunchError.requiresRoot(flag)
                }
            }
        #endif
        try Self.prepareRoot(root, isCustom: root != NidoPaths.defaultRoot())
        let paths = NidoPaths(root: root)
        self.paths = paths
        self.showsReleaseNotes = root == NidoPaths.defaultRoot()
        self.registry = VMRegistry(paths: paths)
        var updates = showsReleaseNotes ? UpdateController(paths: paths) : nil
        #if DEBUG
            if isDebug, arguments.contains(Self.updatesPreviewFlag) {
                updates = UpdateController(paths: paths, startingUpdater: false, requiresFeed: false)
            }
        #endif
        self.updates = updates
        var factory: (any SessionFactory)?
        var usesFixtures = false
        var aiBridge = AIBridgeServices(router: URLSessionRouterClient(), tokenStore: KeychainTokenStore())
        #if DEBUG
            if isDebug, arguments.contains(Self.fakeAIRouterFlag) {
                aiBridge = AIBridgeServices(router: DebugFakeRouter(), tokenStore: DebugMemoryTokenStore())
            }
            let fixture = try Self.debugValue(after: Self.wizardFixtureFlag, in: arguments, isDebug: isDebug)
                .map { value in
                    guard let fixture = WizardModel.Fixture(rawValue: value) else {
                        throw LaunchError.invalidValue(Self.wizardFixtureFlag, value)
                    }
                    return fixture
                }
            // The fixtures show a wizard that has downloaded nothing: an empty cache of its own,
            // never the user's.
            let cacheRoot = fixture == nil ? ImageStore.defaultCacheRoot()
                : FileManager.default.temporaryDirectory
                    .appendingPathComponent("nido-fixture-cache-\(UUID().uuidString)", isDirectory: true)
            self.wizardFixture = fixture
            self.openAtLaunch = try Self.resolveOpenVM(arguments: arguments, isDebug: isDebug)
            usesFixtures = fixture != nil
            let plans = try Self.debugValue(after: Self.fakeStatesFlag, in: arguments, isDebug: isDebug)
                .map { value in
                    guard let plans = FakeVMSessionFactory.parsePlans(value) else {
                        throw LaunchError.invalidValue(Self.fakeStatesFlag, value)
                    }
                    return plans
                }
            let guests = try Self.debugValue(after: Self.fakeGuestFlag, in: arguments, isDebug: isDebug)
                .map { value in
                    guard let guests = FakeGuest.parse(value) else {
                        throw LaunchError.invalidValue(Self.fakeGuestFlag, value)
                    }
                    return guests
                }
            if isDebug, plans != nil || guests != nil || arguments.contains(Self.fakeSessionsFlag) {
                factory = FakeVMSessionFactory(plans: plans ?? [:], guests: guests ?? [:])
            }
        #else
            let cacheRoot = ImageStore.defaultCacheRoot()
        #endif
        self.imageCacheRoot = cacheRoot
        self.imageStore = ImageStore(cacheRoot: cacheRoot, session: ImageStore.makeDownloadSession())
        self.imageFile = try Self.resolveImageFile(arguments: arguments, isDebug: isDebug)
        self.ipswFile = try Self.resolveIPSWFile(arguments: arguments, isDebug: isDebug)
        var macInstaller: any MacVMInstalling = LiveMacVMInstaller(paths: paths)
        #if DEBUG
            if isDebug, arguments.contains(Self.fakeMacInstallerFlag) { macInstaller = DebugFakeMacInstaller() }
        #endif
        self.macInstaller = macInstaller
        self.aiBridge = aiBridge
        // DEBUG fakes (UI and screenshot tests): no RAM warning, whatever this Mac runs.
        let checksHeadroom = factory == nil && !usesFixtures
        checksMemoryHeadroom = checksHeadroom
        let neverWarns: @Sendable (VMBundle) -> MemoryHeadroom? = { _ in nil }
        let sessions = VMSessionStore(
            paths: paths, factory: factory ?? LiveSessionFactory(imageCache: cacheRoot, aiBridge: aiBridge),
            aiBridge: aiBridge, checkHeadroom: checksHeadroom ? nil : neverWarns)
        self.sessions = sessions
        var poster: (any EgressNotificationPosting)?
        var authenticator: any OwnerAuthenticator = LocalOwnerAuthenticator()
        var egressDefaults = UserDefaults.standard
        #if DEBUG
            if isDebug, root != NidoPaths.defaultRoot() {
                // A test root keeps its log cursors in a throwaway domain, emptied at each launch.
                let suite = "io.gitlab.pichierri.Nido.debug-egress"
                egressDefaults = UserDefaults(suiteName: suite) ?? .standard
                egressDefaults.removePersistentDomain(forName: suite)
            }
            if let value = try Self.debugValue(after: Self.notificationsFlag, in: arguments, isDebug: isDebug) {
                guard value == "allowed" || value == "denied" else {
                    throw LaunchError.invalidValue(Self.notificationsFlag, value)
                }
                poster = DebugNotificationPoster(allowed: value == "allowed")
                authenticator = DebugRefusingAuthenticator()
            } else if isDebug, root != NidoPaths.defaultRoot() {
                // A test root (UI tests, proofs): no system prompt for the notification permission.
                poster = DebugNotificationPoster(allowed: true)
            }
        #endif
        if let poster {
            egress = EgressMonitor(paths: paths, poster: poster, authenticator: authenticator, defaults: egressDefaults)
        } else {
            let system = UserNotificationPoster()
            egress = EgressMonitor(paths: paths, poster: system, authenticator: authenticator, defaults: egressDefaults)
            system.monitor = egress
        }
        // Never on the main actor: ending an orphan waits up to a few seconds for it to exit.
        DispatchQueue.global(qos: .utility).async(execute: sweepOrphans)
        #if DEBUG
            // The scripted VMs start at once, without a window, as if opened earlier in this app.
            for (name, plan) in (plans ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard let vmName = try? VMName(name) else { continue }
                Task {
                    let model = sessions.model(for: vmName)
                    await model.start()
                    if plan == .paused { await model.pause() }
                }
            }
        #endif
    }

    /// Release builds always use `NidoPaths.defaultRoot()`. Debug builds honour
    /// `-NidoRoot <absolute path>` (used by the UI tests) and reject a relative path.
    nonisolated static func resolveRoot(arguments: [String], isDebug: Bool) throws -> URL {
        guard let path = try debugPath(after: rootFlag, in: arguments, isDebug: isDebug) else {
            return NidoPaths.defaultRoot()
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    /// Release builds always download the catalog image (nil). Debug builds honour
    /// `-NidoImageFile <absolute path to a .raw>` (used by the UI tests): no network, no checksum.
    nonisolated static func resolveImageFile(arguments: [String], isDebug: Bool) throws -> URL? {
        try debugPath(after: imageFileFlag, in: arguments, isDebug: isDebug)
            .map { URL(fileURLWithPath: $0, isDirectory: false).standardizedFileURL }
    }

    /// Release builds always ask for the IPSW (nil). Debug builds honour `-NidoIPSWFile <absolute
    /// path>` (used by the UI tests): the macOS tile takes it without the open panel.
    nonisolated static func resolveIPSWFile(arguments: [String], isDebug: Bool) throws -> URL? {
        try debugPath(after: ipswFileFlag, in: arguments, isDebug: isDebug)
            .map { URL(fileURLWithPath: $0, isDirectory: false).standardizedFileURL }
    }

    /// The VM named after `-NidoOpenVM`, only in DEBUG builds; nil when the flag is absent.
    nonisolated static func resolveOpenVM(arguments: [String], isDebug: Bool) throws -> VMName? {
        try debugValue(after: openVMFlag, in: arguments, isDebug: isDebug).map { value in
            guard let name = try? VMName(value) else { throw LaunchError.invalidValue(openVMFlag, value) }
            return name
        }
    }

    /// The absolute path following `flag`, only in DEBUG builds; nil when the flag is absent.
    nonisolated private static func debugPath(after flag: String, in arguments: [String], isDebug: Bool) throws
        -> String?
    {
        guard let path = try debugValue(after: flag, in: arguments, isDebug: isDebug) else { return nil }
        guard path.hasPrefix("/") else { throw LaunchError.relativePath(path) }
        return path
    }

    /// The value following `flag`, only in DEBUG builds; nil when the flag is absent.
    nonisolated static func debugValue(after flag: String, in arguments: [String], isDebug: Bool) throws
        -> String?
    {
        guard isDebug, let index = arguments.firstIndex(of: flag) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex, !arguments[valueIndex].isEmpty else {
            throw LaunchError.missingValue(flag)
        }
        return arguments[valueIndex]
    }

    /// Creates the root with mode 0700 when missing. A custom root that already exists is
    /// the caller's directory: it is used as is and its mode is left untouched.
    nonisolated static func prepareRoot(_ root: URL, isCustom: Bool) throws {
        var isDirectory: ObjCBool = false
        if isCustom, FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw LaunchError.notADirectory(root.path) }
            return
        }
        try NidoPaths(root: root).ensureRoot()
    }
}
