// SPDX-License-Identifier: Apache-2.0
import AppKit
import NidoCore
import Observation
import OSLog
import Sparkle

/// Sparkle's updater for Nido ("Check for Updates…", the Preferences toggle) and its delegate:
/// an update is never installed while any VM runs, in the app or with `nido start`
/// (spec M4 §6.3; `UpdateGate` decides, `RunningVMs` reads the bundle locks).
///
/// First line: `updater(_:shouldProceedWithUpdate:updateCheck:)` refuses to offer an update while
/// a VM runs, so nothing is downloaded or staged then. The cases below cover a VM started later.
///
/// Which Sparkle 2.10.1 callbacks cover which case (read in `SPUUpdaterDelegate.h`,
/// `SPUInstallerDriver.m`, `SPUAutomaticUpdateDriver.m` and `Autoupdate/AppInstaller.m` of the
/// pinned checkout):
/// - "Installa e riavvia" (`installWithToolAndRelaunch:YES`, the only button of Sparkle's
///   "ready to install" window): `updater(_:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)`,
///   asked once per update. With a VM running it returns true, keeps the block, closes Sparkle's
///   window (it cannot be closed by the user and its button is spent) and tells which VMs block
///   the update; the VMs are checked every 5 s and the block runs when none is left (it installs
///   and relaunches, without asking again).
/// - Install on quit: once an update is downloaded, Sparkle's installer (Autoupdate) is already
///   running and installs it as soon as the app process ends, whatever the delegate says ("In
///   either case Sparkle will always attempt to install the update when the app terminates").
///   `updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)` is only the automatic
///   driver's notice of that (never reached here: `SUAllowsAutomaticUpdates` is NO in Info.plist,
///   so nothing is downloaded without the user's "Installa"); it returns false, Sparkle's own
///   handling. No public API cancels a prepared installer, so `AppDelegate.applicationShouldTerminate`
///   keeps Nido open (`quitBlockers`) after a user's quit while an update is pending and a VM the
///   quit does not stop (`nido start`) runs; never for a logout, restart or shutdown
///   (`UpdateGate.isSystemQuit`). The app's own VMs are stopped by the quit before the process ends.
@MainActor
@Observable
final class UpdateController: NSObject {
    /// How often the VMs are checked while a relaunch is postponed.
    nonisolated static let pollInterval: Duration = .seconds(5)

    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private let paths: NidoPaths
    /// The validated feed (`feedURL(info:)`), handed to Sparkle by `feedURLString(for:)`.
    @ObservationIgnored private let feed: URL?
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?
    @ObservationIgnored private var postponedInstall: (() -> Void)?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    private let log = Logger(subsystem: "io.gitlab.pichierri.Nido", category: "updates")

    /// Mirrors `SPUUpdater.canCheckForUpdates` (false while a session runs or before the start).
    private(set) var canCheckForUpdates = false
    /// True from the moment an update is downloaded: Sparkle's installer then waits for the app to
    /// end. Cleared when the user skips the version, the download fails or the session aborts
    /// with an error (unless a relaunch is postponed).
    private(set) var isInstallPending = false

    /// The "Cerca aggiornamenti automaticamente" preference (`SUEnableAutomaticChecks` absent:
    /// off until the user chooses, by Sparkle's question or here).
    var automaticallyChecksForUpdates: Bool {
        get {
            access(keyPath: \.automaticallyChecksForUpdates)
            return controller.updater.automaticallyChecksForUpdates
        }
        set {
            withMutation(keyPath: \.automaticallyChecksForUpdates) {
                controller.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    /// nil without a feed (`NIDO_FEED_URL` empty: no updater, no menu item, no preference).
    /// `startingUpdater` false (DEBUG preview for the UI tests): Sparkle is created but never
    /// started, so it reads no feed and never touches the network.
    init?(bundle: Bundle = .main, paths: NidoPaths, startingUpdater: Bool = true, requiresFeed: Bool = true) {
        feed = Self.feedURL(info: bundle.infoDictionary)
        guard !requiresFeed || feed != nil else { return nil }
        self.paths = paths
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: startingUpdater, updaterDelegate: self, userDriverDelegate: nil)
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
            [weak self] updater, _ in
            MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
    }

    /// The feed of the build (`SUFeedURL`, from `NIDO_FEED_URL`), nil when empty or not https.
    /// Plain http is accepted only on this Mac's loopback (local update test, see
    /// `scripts/release.sh`); updates stay EdDSA-signed either way.
    nonisolated static func feedURL(info: [String: Any]?) -> URL? {
        guard let text = (info?["SUFeedURL"] as? String)?.trimmingCharacters(in: .whitespaces),
              !text.isEmpty, let url = URL(string: text), let host = url.host
        else { return nil }
        switch url.scheme {
        case "https": return url
        case "http" where host == "127.0.0.1" || host == "localhost": return url
        default: return nil
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Sparkle's updater, for reading what it resolved (the feed).
    var updater: SPUUpdater { controller.updater }

    /// VMs that keep Nido open at quit: an update is pending and these run outside this app's
    /// sessions (`liveNames`, which the quit itself stops). Empty means the quit may go on.
    func quitBlockers(liveNames: [VMName]) -> [VMName] {
        guard isInstallPending else { return [] }
        return RunningVMs.names(paths: paths).filter { !liveNames.contains($0) }
    }

    private func showPostponedNotice(_ message: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Update postponed")
        alert.informativeText = message
        // No button added: AppKit's own OK.
        alert.runModal()
    }

    /// Checks the VMs every `pollInterval`; runs the postponed install once none is left.
    private func pollUntilNoVMRuns() {
        pollTask?.cancel()
        let paths = paths
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                let running = await Task.detached { RunningVMs.names(paths: paths) }.value
                guard UpdateGate.decision(running: running) == .proceed else { continue }
                self?.runPostponedInstall()
                return
            }
        }
    }

    private func runPostponedInstall() {
        guard let install = postponedInstall else { return }
        postponedInstall = nil
        pollTask = nil
        log.info("No VM running: installing the postponed update")
        install()
    }
}

extension UpdateController: SPUUpdaterDelegate {
    /// Sparkle asks the delegate first, before the Info.plist and before a `SUFeedURL` in the
    /// user defaults (which it would otherwise prefer): the feed is always the validated one,
    /// https or this Mac's loopback.
    func feedURLString(for updater: SPUUpdater) -> String? {
        feed?.absoluteString
    }

    func updater(
        _ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        isInstallPending = true
        guard case .postpone(let message) = UpdateGate.decision(running: RunningVMs.names(paths: paths)) else {
            return false
        }
        log.info("Update \(item.displayVersionString, privacy: .public) postponed: a VM is running")
        postponedInstall = installHandler
        controller.userDriver.dismissUpdateInstallation()
        pollUntilNoVMRuns()
        DispatchQueue.main.async { [weak self] in self?.showPostponedNotice(message) }
        return true
    }

    func updater(
        _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        // Sparkle installs at the end of the process anyway: the quit guard applies.
        isInstallPending = true
        return false
    }

    /// The early gate. Sparkle asks this once it found a newer item in the appcast, before showing
    /// it and before any download (`SPUBasicUpdateDriver.notifyFoundValidUpdateWithAppcastItem`,
    /// every kind of check; not for an update already downloaded that is being resumed). With a VM
    /// running it throws the gate's message: Sparkle shows it and nothing is downloaded or staged.
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem, updateCheck: SPUUpdateCheck)
        throws
    {
        if let error = UpdateGate.proceedError(running: RunningVMs.names(paths: paths)) {
            log.info("Update \(updateItem.displayVersionString, privacy: .public) not offered: a VM is running")
            throw error
        }
    }

    /// The update session ended with an error (download, extraction, installer, or the early
    /// gate): no installer waits for the quit. A postponed relaunch keeps its installer.
    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        if postponedInstall == nil { isInstallPending = false }
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        isInstallPending = true
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: any Error) {
        isInstallPending = false
    }

    func updater(
        _ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        // "Salta questa versione" also cancels a prepared installer (`SPUInstallerDriver.cancelUpdate`).
        if choice == .skip {
            isInstallPending = false
            postponedInstall = nil
            pollTask?.cancel()
            pollTask = nil
        }
    }
}
