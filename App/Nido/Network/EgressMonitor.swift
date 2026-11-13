// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore
import Observation
import UserNotifications

/// Posts the block notifications. Tests and the screenshot runs use a fake; the app uses
/// `UserNotificationPoster`.
@MainActor
protocol EgressNotificationPosting: AnyObject {
    /// Asks once (the system remembers the answer) and tells whether notifications are allowed.
    func authorize() async -> Bool
    func post(_ notice: EgressBlockNotice)
}

/// Watches the `egress.log` of every VM of the root, also those started by `nido start`, and
/// notifies their blocks (`EgressNoticeBatcher` merges repeats, never drops them). A
/// notification offers "Allow" (only when the block names a domain, behind the owner's
/// confirmation) and "Open Log". When notifications are not allowed, the VM window shows
/// how many blocks there were (`unseenBlocks`).
///
/// Where it stopped reading each log is kept in the user defaults, so blocks written while the
/// app was closed are notified at its next launch; a VM it never watched is read from the last
/// time the app watched any. All file reads run off the main actor.
@MainActor
@Observable
final class EgressMonitor {
    /// Blocks per VM name not looked at yet (their log not opened since), counted always; shown
    /// when notifications are not allowed.
    private(set) var unseenBlocks: [String: Int] = [:]
    /// nil until the system answered.
    private(set) var notificationsAllowed: Bool?
    /// A request to show the log of a VM ("Open Log"): the VM window shows its Network view.
    private(set) var logRequest: LogRequest?
    /// The outcome of the last "Allow" from a notification, posted as a notice of its own.
    private(set) var lastAllowOutcome: EgressPolicyEdits.AllowOutcome?

    struct LogRequest: Equatable {
        let vm: String
        let serial: Int
    }

    /// Opens the window of a VM (set by the library, which has `openWindow`).
    @ObservationIgnored var openWindow: ((VMName) -> Void)?

    @ObservationIgnored private let paths: NidoPaths
    @ObservationIgnored private let poster: any EgressNotificationPosting
    @ObservationIgnored let authenticator: any OwnerAuthenticator
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let readLog: @Sendable (VMBundle) -> [EgressLogEntry]
    @ObservationIgnored private let listNames: @Sendable (NidoPaths) -> [VMName]
    @ObservationIgnored private var batcher = EgressNoticeBatcher()
    @ObservationIgnored private var stamps: [String: LogStamp] = [:]
    /// VMs whose log could not be used at the last poll, already notified.
    @ObservationIgnored private var unusableLogs: Set<String> = []
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var requestSerial = 0

    static let pollInterval: Duration = .seconds(2)
    /// Defaults keys carry the root: two roots (a test one, the real one) never share a cursor.
    private var cursorPrefix: String { "egress.cursor.\(paths.root.path)/" }
    private var sinceKey: String { "egress.watchedUntil.\(paths.root.path)" }

    init(
        paths: NidoPaths, poster: any EgressNotificationPosting, authenticator: any OwnerAuthenticator,
        defaults: UserDefaults = .standard,
        readLog: @escaping @Sendable (VMBundle) -> [EgressLogEntry] = { EgressLog.readEntries(at: $0.egressLogURL) },
        listNames: @escaping @Sendable (NidoPaths) -> [VMName] = EgressMonitor.bundleNames
    ) {
        self.paths = paths
        self.poster = poster
        self.authenticator = authenticator
        self.defaults = defaults
        self.readLog = readLog
        self.listNames = listNames
    }

    /// Starts watching (idempotent): asks for the notification permission, then polls.
    func start() {
        guard watcher == nil else { return }
        watcher = Task { [weak self] in
            guard let self else { return }
            self.notificationsAllowed = await self.poster.authorize()
            while !Task.isCancelled {
                await self.poll(now: Date())
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
    }

    // MARK: - Reading the logs

    /// The size and modification time of a log (both generations): unchanged, nothing to read.
    struct LogStamp: Equatable, Sendable {
        let current: [Int64]
        let rotated: [Int64]
    }

    /// One poll: lists the root, reads the logs that changed, notifies their new blocks, then
    /// the counts of the merge windows that are over.
    func poll(now: Date) async {
        let since = (defaults.object(forKey: sinceKey) as? Date) ?? now
        let (changed, unusable) = await Self.read(paths: paths, list: listNames, known: stamps, readLog: readLog)
        for vm in unusable.subtracting(unusableLogs).sorted() { poster.post(Self.unusableLogNotice(vm: vm)) }
        unusableLogs = unusable
        for item in changed {
            stamps[item.name] = item.stamp
            let (fresh, next) = EgressLogCursor.newEntries(item.entries, after: cursor(for: item.name), since: since)
            if let next { save(next, for: item.name) }
            record(fresh, vm: item.name, now: now)
        }
        for notice in batcher.flush(now: now) { poster.post(notice) }
        defaults.set(now, forKey: sinceKey)
    }

    private struct Changed: Sendable {
        let name: String
        let stamp: LogStamp
        let entries: [EgressLogEntry]
    }

    /// The logs that changed, and the VMs whose log the relay cannot open (`isUnusable`).
    @concurrent
    private static func read(
        paths: NidoPaths, list: @Sendable (NidoPaths) -> [VMName], known: [String: LogStamp],
        readLog: @Sendable (VMBundle) -> [EgressLogEntry]
    ) async -> ([Changed], Set<String>) {
        var out: [Changed] = []
        var unusable: Set<String> = []
        for vmName in list(paths).sorted(by: { $0.rawValue < $1.rawValue }) {
            let name = vmName.rawValue
            let bundle = VMBundle(url: paths.bundleURL(for: vmName))
            let url = bundle.egressLogURL
            if isUnusable(url) || isUnusable(bundle.egressFlowLogURL) { unusable.insert(name) }
            let rotated = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".1")
            let stamp = LogStamp(current: Self.stat(url), rotated: Self.stat(rotated))
            guard stamp != known[name], !stamp.current.isEmpty || !stamp.rotated.isEmpty else { continue }
            out.append(Changed(name: name, stamp: stamp, entries: readLog(bundle)))
        }
        return (out, unusable)
    }

    /// A log the relay refuses to open (`EgressLog`, by `lstat`): present but not a regular
    /// file, e.g. a planted symlink. The VM's blocks then stay in force but are neither logged
    /// nor notified (the relay of an app-started VM has no other outlet).
    nonisolated private static func isUnusable(_ url: URL) -> Bool {
        var info = Darwin.stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_mode & S_IFMT != S_IFREG
    }

    /// The notice of a log that cannot be used (`isUnusable`), once per VM until it is usable again.
    static func unusableLogNotice(vm: String) -> EgressBlockNotice {
        var notice = EgressBlockNotice(
            vm: ConsoleSanitizer.echoable(vm), destination: "egress.log",
            reason: String(localized: "blocking stays on, but blocks aren’t logged or reported", comment: "It follows a colon."),
            allowDomain: nil, count: 1, key: "\(vm)|registro")
        notice.subject = String(localized: "network log not available", comment: "A notification’s title, after the VM’s name.")
        return notice
    }

    /// Size and modification time (ns) by `lstat`; empty when missing.
    nonisolated private static func stat(_ url: URL) -> [Int64] {
        var info = Darwin.stat()
        guard lstat(url.path, &info) == 0 else { return [] }
        return [Int64(info.st_size), Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)]
    }

    /// The VM bundles of the root (`<name>.nidovm`; templates included: a log is a log).
    nonisolated static func bundleNames(_ paths: NidoPaths) -> [VMName] {
        let suffix = ".nidovm"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.root.path)) ?? []
        return names.compactMap { entry in
            guard entry.hasSuffix(suffix) else { return nil }
            return try? VMName(String(entry.dropLast(suffix.count)))
        }
    }

    private func record(_ entries: [EgressLogEntry], vm: String, now: Date) {
        var notices: [EgressBlockNotice] = []
        for entry in entries {
            // Not a block and never merged: the person learns at once that the VM is offline.
            if let lost = EgressNoticeText.uplinkLostNotice(for: entry, vm: vm) {
                poster.post(lost)
                continue
            }
            if let notice = EgressNoticeText.notice(for: entry, vm: vm) ?? EgressNoticeText.summaryNotice(for: entry, vm: vm) {
                notices.append(notice)
            }
        }
        guard !notices.isEmpty else { return }
        unseenBlocks[vm, default: 0] += notices.reduce(0) { $0 + $1.count }
        for notice in batcher.add(notices, now: now) { poster.post(notice) }
    }

    private func cursor(for vm: String) -> EgressLogCursor? {
        guard let data = defaults.data(forKey: cursorPrefix + vm) else { return nil }
        return try? JSONDecoder().decode(EgressLogCursor.self, from: data)
    }

    private func save(_ cursor: EgressLogCursor, for vm: String) {
        guard let data = try? JSONEncoder().encode(cursor) else { return }
        defaults.set(data, forKey: cursorPrefix + vm)
    }

    // MARK: - Actions

    /// The log of `vm` was looked at: its counter starts over.
    func markSeen(_ vm: String) {
        if unseenBlocks[vm] != nil { unseenBlocks[vm] = nil }
    }

    /// "Open Log": the VM's window, on its Network view.
    func openLog(_ vm: String) {
        guard let name = try? VMName(vm) else { return }
        requestSerial += 1
        logRequest = LogRequest(vm: vm, serial: requestSerial)
        openWindow?(name)
    }

    /// "Allow" of a notification: adds `domain` to `vm`'s list after the owner's confirmation
    /// (`EgressPolicyEdits.allow`); the outcome is told with a notice of its own.
    @discardableResult
    func allow(_ domain: String, vm: String) async -> EgressPolicyEdits.AllowOutcome {
        guard let name = try? VMName(vm) else { return .invalid(String(localized: "Invalid VM name.")) }
        let bundle = VMBundle(url: paths.bundleURL(for: name))
        let outcome = await EgressPolicyEdits.allow(domain, vm: vm, bundle: bundle, authenticator: authenticator)
        lastAllowOutcome = outcome
        poster.post(Self.outcomeNotice(outcome, vm: vm))
        return outcome
    }

    /// The domain of an "Allow" action, checked again when the action arrives (the payload
    /// comes back from the system): an exact, non-wildcard name that `DomainPattern` keeps as it
    /// is and the echo strip leaves unchanged; nil otherwise (the action then does nothing).
    nonisolated static func actionDomain(_ value: Any?) -> String? {
        guard let text = value as? String, let pattern = try? DomainPattern(text), !pattern.isWildcard,
            pattern.description == text, ConsoleSanitizer.echoable(text) == text
        else { return nil }
        return text
    }

    static func outcomeNotice(_ outcome: EgressPolicyEdits.AllowOutcome, vm: String) -> EgressBlockNotice {
        EgressBlockNotice(
            vm: ConsoleSanitizer.echoable(vm),
            destination: String(localized: "Allow", comment: "The notification’s button, named in the notice of its outcome."),
            reason: allowMessage(outcome, vm: vm),
            allowDomain: nil, count: 1, key: "\(vm)|consenti")
    }

    /// The localized sentence of an "add a domain" outcome, without its final period (a notice
    /// adds it).
    static func allowMessage(_ outcome: EgressPolicyEdits.AllowOutcome, vm: String) -> String {
        let vm = ConsoleSanitizer.echoable(vm)
        return switch outcome {
        case .added(let domain):
            String(localized: "\(domain) added to the allowed domains of \(vm): it applies within a few seconds, even with the VM running",
                   comment: "A domain, then the VM’s name. No final period: the app adds it.")
        case .alreadyListed(let domain):
            String(localized: "\(domain) is already one of the allowed domains of \(vm)",
                   comment: "A domain, then the VM’s name. No final period: the app adds it.")
        case .cancelled:
            String(localized: "No domain added: confirmation canceled or failed", comment: "No final period: the app adds it.")
        case .malformed:
            String(localized: "\(vm)’s egress.json isn’t valid: the VM stays on the last valid list. Reset to the base list from the VM’s settings (Network) or with nido net reset \(vm)",
                   comment: "%@ is the VM’s name, twice. No final period: the app adds it.")
        case .full:
            String(localized: "\(vm)’s list is full (\(EgressPolicy.maxPatterns) domains): remove some first",
                   comment: "The VM’s name, then the most domains a list holds. No final period: the app adds it.")
        case .invalid(let why): why
        case .failed(let why):
            String(localized: "Couldn’t add the domain: \(why)", comment: "%@ is the error. No final period: the app adds it.")
        }
    }
}

/// The app's notifications through `UNUserNotificationCenter`: no sound (Nido has no sound
/// setting), "Allow" only on a notice that names a domain.
@MainActor
final class UserNotificationPoster: NSObject, EgressNotificationPosting, UNUserNotificationCenterDelegate {
    static let allowCategory = "nido.egress.allow"
    static let logCategory = "nido.egress.log"
    static let allowAction = "nido.egress.consenti"
    static let logAction = "nido.egress.registro"

    private let center = UNUserNotificationCenter.current()
    /// Where the actions go (the monitor; set after both exist).
    weak var monitor: EgressMonitor?

    override init() {
        super.init()
        let allow = UNNotificationAction(
            identifier: Self.allowAction, title: String(localized: "Allow…", comment: "Adds the blocked domain to the allowed domains."),
            options: [.foreground])
        let log = UNNotificationAction(
            identifier: Self.logAction, title: String(localized: "Open Log", comment: "Opens the VM’s network log."), options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.allowCategory, actions: [allow, log], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.logCategory, actions: [log], intentIdentifiers: []),
        ])
        center.delegate = self
    }

    func authorize() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .denied: return false
        case .notDetermined: return (try? await center.requestAuthorization(options: [.alert])) ?? false
        @unknown default: return false
        }
    }

    func post(_ notice: EgressBlockNotice) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = nil
        content.threadIdentifier = "nido.egress.\(notice.vm)"
        content.categoryIdentifier = notice.allowDomain == nil ? Self.logCategory : Self.allowCategory
        var info: [String: String] = ["vm": notice.vm]
        if let domain = notice.allowDomain { info["domain"] = domain }
        content.userInfo = info
        let request = UNNotificationRequest(identifier: "nido.egress.\(notice.key)", content: content, trigger: nil)
        center.add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let vm = info["vm"] as? String else { return }
        let domain = EgressMonitor.actionDomain(info["domain"])
        let action = response.actionIdentifier
        await MainActor.run {
            guard let monitor = self.monitor else { return }
            switch action {
            case Self.allowAction:
                if let domain { Task { await monitor.allow(domain, vm: vm) } }
            default:
                monitor.openLog(vm)
            }
        }
    }
}

#if DEBUG
    /// DEBUG `-NidoNotifications allowed|denied` (with `-NidoRoot`): notices are kept in memory,
    /// never shown by the system (UI and screenshot tests).
    @MainActor
    final class DebugNotificationPoster: EgressNotificationPosting {
        let allowed: Bool
        private(set) var posted: [EgressBlockNotice] = []

        init(allowed: Bool) { self.allowed = allowed }

        func authorize() async -> Bool { allowed }
        func post(_ notice: EgressBlockNotice) { posted.append(notice) }
    }

    /// DEBUG, with `DebugNotificationPoster`: the owner never confirms (no real prompt in tests).
    struct DebugRefusingAuthenticator: OwnerAuthenticator {
        func authenticate(reason: String) async -> Bool { false }
    }
#endif
