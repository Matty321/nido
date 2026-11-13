// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore
import Observation

/// S08 Network: the controlled network of one VM. The switch (only while the VM is stopped), the
/// list of allowed domains and the way out of a damaged `egress.json`.
///
/// - Adding a domain asks the owner (Touch ID or the Mac password) right before the write; a
///   broad wildcard (`EgressPolicyEdits.isBroadWildcard`) first shows a warning that needs its
///   own confirmation. Removing asks nothing.
/// - Turning the controlled network on narrows what the VM reaches (from everything to the
///   list): it asks only for the confirmation of its explanation, and writes the base list of
///   the VM's guest when it has none (`EgressPolicy.base(for:)` on Linux,
///   `EgressPolicy.macOSBase` on macOS; an existing list, even empty, is kept). Turning it off
///   widens (back to Apple's NAT): the owner confirms too.
/// - Every write of `egress.json` goes through `EgressPolicyStore` (`EgressPolicyEdits`), off the
///   main actor; `config.json` is written under the bundle lock, like Save.
@MainActor
@Observable
final class NetworkSettingsModel {
    let name: String
    let guest: GuestOS
    /// The base list of the VM's guest: `EgressPolicy.base(for:)` of its distribution on Linux,
    /// `EgressPolicy.macOSBase` on macOS.
    private let basePolicy: EgressPolicy
    private(set) var controlled: Bool
    private(set) var patterns: [DomainPattern] = []
    /// `egress.json` does not load: the VM runs on its last good list (or none).
    private(set) var isMalformed = false
    /// The field of "Add…".
    var newDomain = "" {
        didSet { if newDomain != oldValue, messageIsError { message = nil } }
    }
    /// The outcome of the last action, localized.
    private(set) var message: String?
    private(set) var messageIsError = false
    /// A broad wildcard waiting for its extra confirmation.
    private(set) var pendingBroad: DomainPattern?
    /// The switch's new value waiting for the explanation's confirmation.
    private(set) var pendingToggle: Bool?
    /// "Reset to Base List…" waiting for its confirmation.
    private(set) var pendingReset = false
    private(set) var isBusy = false

    @ObservationIgnored private let bundle: VMBundle
    @ObservationIgnored private let authenticator: any OwnerAuthenticator
    @ObservationIgnored private let isRunning: @MainActor () -> Bool
    @ObservationIgnored private let onConfigurationChanged: @MainActor () -> Void

    init(
        bundle: VMBundle, config: VMConfig, authenticator: any OwnerAuthenticator,
        isRunning: @escaping @MainActor () -> Bool, onConfigurationChanged: @escaping @MainActor () -> Void = {}
    ) {
        self.bundle = bundle
        name = config.name.rawValue
        guest = config.guest
        basePolicy = config.guest == .macos ? EgressPolicy.macOSBase : EgressPolicy.base(for: config.distribution)
        controlled = config.controlledNetwork == true
        self.authenticator = authenticator
        self.isRunning = isRunning
        self.onConfigurationChanged = onConfigurationChanged
    }

    /// Reads the list again (off the main actor).
    func load() async {
        let policy = await EgressPolicyEdits.load(bundle)
        isMalformed = policy == nil
        patterns = policy?.allow ?? []
    }

    // MARK: - Texts

    var isLocked: Bool { isRunning() || isBusy }

    var toggleExplanation: String {
        if isRunning() { return Self.onlyWhenStopped }
        return controlled
            ? String(localized: "The VM reaches only the domains on the list. Every block ends up in the log and in a notice.")
            : String(localized: "Off: the VM connects to the internet through Apple’s NAT, unchecked.",
                     comment: "The controlled network’s switch is off.")
    }

    private static var onlyWhenStopped: String {
        String(localized: "Can be changed only with the VM stopped.")
    }

    var listIntro: String {
        controlled
            ? String(localized: "A domain applies only to itself; *.example.com also applies to its subdomains. Changes apply within a few seconds, even with the VM running.",
                     comment: "example.com is the example domain each language uses.")
            : String(localized: "The list applies when you turn on the controlled network.")
    }

    var malformedHint: String {
        String(localized: "egress.json isn’t valid or isn’t safe: the running VM stays on the last valid list, and at the next start it has no network. Rewrite it with the base list below, or from Terminal with nido net reset \(name).",
               comment: "%@ is the VM’s name.")
    }

    /// The base list as shown in the texts: its names, comma separated.
    private var baseNames: String { basePolicy.allow.map(\.description).joined(separator: ", ") }

    var toggleSheet: (title: String, message: String, action: String) {
        let turnOn = String(localized: "Turn on the controlled network for \(name)?", comment: "%@ is the VM’s name.")
        if pendingToggle == true, guest == .macos {
            return (turnOn,
                    String(localized: "From the next start, every connection of the VM goes through Nido: it can reach only the domains on the list, and everything else is blocked, logged and reported. If the VM doesn’t have a domain list yet, it starts with the base list for macOS (\(baseNames)): activation, macOS updates and the clock. The App Store, iCloud and other sites stay blocked until you add their domains. If the controlled network doesn’t start, the VM stays without a network instead of connecting unchecked. The VM’s saved state, if any, isn’t resumed.",
                           comment: "%@ lists the base list’s domains, separated by commas."),
                    String(localized: "Turn On"))
        }
        if pendingToggle == true {
            return (turnOn,
                    String(localized: "From the next start, every connection of the VM goes through Nido: it can reach only the domains on the list, and everything else is blocked, logged and reported. If the VM doesn’t have a domain list yet, it starts with the base list (\(baseNames)). If the controlled network doesn’t start, the VM stays without a network instead of connecting unchecked. Ollama is installed by downloading it on the Mac: the VM doesn’t contact GitHub. The VM’s saved state, if any, isn’t resumed.",
                           comment: "%@ lists the base list’s domains, separated by commas."),
                    String(localized: "Turn On"))
        }
        return (String(localized: "Turn off the controlled network for \(name)?", comment: "%@ is the VM’s name."),
                String(localized: "From the next start, the VM connects to the internet through Apple’s NAT, to any destination, and nothing is logged. The domain list is kept for when you turn it back on. You confirm with Touch ID or the Mac password."),
                String(localized: "Turn Off (network)", defaultValue: "Turn Off",
                       comment: "Turns off the controlled network (a setting, not a service)."))
    }

    func broadWarning(_ pattern: DomainPattern) -> String {
        String(localized: "\(pattern.description) applies to every name under \(pattern.name): the sites and services of anyone with an address there, not a single site. Add it only if you really need it; after this confirmation, Touch ID or the Mac password is needed too.",
               comment: "A wildcard (*.co.uk), then the name under it (co.uk).")
    }

    /// The button of the way out, on Linux and macOS alike.
    var resetLabel: String { String(localized: "Reset to Base List…") }

    var resetTitle: String { String(localized: "Reset to the base list?") }

    var resetMessage: String {
        var sentences = [String(localized: "\(name)’s egress.json is replaced with the base list (\(baseNames)).",
                                comment: "The VM’s name, then the base list’s domains separated by commas.")]
        if isRunning() {
            sentences.append(String(localized: "The VM is running: connections to domains outside the base list are cut."))
        }
        if EgressPolicyEdits.resetWidens(
            isMalformed ? nil : EgressPolicy(v: EgressPolicy.currentVersion, allow: patterns), to: basePolicy) {
            sentences.append(String(localized: "You confirm with Touch ID or the Mac password."))
        }
        return sentences.joined(separator: " ")
    }

    // MARK: - Switch

    func requestToggle(_ on: Bool) {
        guard on != controlled, !isLocked else { return }
        message = nil
        pendingToggle = on
    }

    func cancelToggle() { pendingToggle = nil }

    /// The confirmed switch: off needs the owner first; then `config.json` under the bundle lock
    /// (refused while the VM runs), and on, the base list when the VM has no `egress.json`.
    func confirmToggle() async {
        guard let on = pendingToggle else { return }
        pendingToggle = nil
        guard !isLocked else { return show(Self.onlyWhenStopped, error: true) }
        isBusy = true
        defer { isBusy = false }
        if !on {
            guard await authenticator.authenticate(
                reason: String(localized: "turn off the controlled network of the VM \(name)",
                               comment: "The end of the system’s Touch ID sentence “Nido is trying to …”: %@ is the VM’s name."))
            else {
                return show(String(localized: "Controlled network still on: confirmation canceled or failed."), error: true)
            }
        }
        let lock: BundleLock
        do {
            lock = try await BundleLock.acquireAsync(bundle, owner: .app)
        } catch {
            return show(Self.onlyWhenStopped, error: true)
        }
        defer { lock.release() }
        do {
            let bundle = bundle
            _ = try await Task.detached { try bundle.updateConfig { $0.controlledNetwork = on } }.value
        } catch {
            return show(String(localized: "Couldn’t save: \(EgressPolicyEdits.sentence(error))", comment: "%@ is the error."), error: true)
        }
        controlled = on
        onConfigurationChanged()
        if on, !(await seedBaseList()) {
            await load()
            return
        }
        await load()
        if !isMalformed {
            show(on ? String(localized: "Controlled network turns on at the next start.")
                    : String(localized: "Controlled network turns off at the next start."), error: false)
        }
    }

    /// A VM without `egress.json` gets its guest's base list (a narrowing: it was on Apple's NAT).
    /// A failure is said inline: the VM stays fail closed (controlled, no list, no network). An
    /// existing list, even empty, is kept.
    private func seedBaseList() async -> Bool {
        var info = stat()
        guard lstat(bundle.egressPolicyURL.path, &info) != 0 else { return true }
        let base = basePolicy
        do {
            try await EgressPolicyEdits.write(bundle) { policy in
                if policy.allow.isEmpty { policy = base }
            }
            return true
        } catch {
            show(String(localized: "Controlled network on, but the base list wasn’t written: \(EgressPolicyEdits.sentence(error)). The VM stays without a network until you add a domain or reset to the base list.",
                        comment: "%@ is the error."), error: true)
            return false
        }
    }

    // MARK: - List

    /// "Add…": a broad wildcard first asks for the warning's confirmation.
    func addDomain() async {
        let text = newDomain.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !isBusy else { return }
        if let pattern = try? DomainPattern(text), EgressPolicyEdits.isBroadWildcard(pattern) {
            message = nil
            pendingBroad = pattern
            return
        }
        await add(text)
    }

    func confirmBroad() async {
        guard let pattern = pendingBroad else { return }
        pendingBroad = nil
        await add(pattern.description)
    }

    func cancelBroad() { pendingBroad = nil }

    private func add(_ text: String) async {
        isBusy = true
        defer { isBusy = false }
        let outcome = await EgressPolicyEdits.allow(text, vm: name, bundle: bundle, authenticator: authenticator)
        await load()
        switch outcome {
        case .added, .alreadyListed:
            newDomain = ""
            show(EgressMonitor.allowMessage(outcome, vm: name) + ".", error: false)
        default:
            show(EgressMonitor.allowMessage(outcome, vm: name) + ".", error: true)
        }
    }

    /// "Remove": no confirmation, the list only narrows.
    func remove(_ pattern: DomainPattern) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await EgressPolicyEdits.remove(pattern, bundle: bundle)
            show(String(localized: "Removed \(pattern.description): open connections to it are cut.", comment: "%@ is a domain."),
                 error: false)
        } catch NidoError.invalidEgressPolicy {
            show(malformedHint, error: true)
        } catch {
            show(String(localized: "Couldn’t remove the domain: \(EgressPolicyEdits.sentence(error))", comment: "%@ is the error."),
                 error: true)
        }
        await load()
    }

    // MARK: - Reset

    func requestReset() {
        message = nil
        pendingReset = true
    }

    func cancelReset() { pendingReset = false }

    func confirmReset() async {
        guard pendingReset else { return }
        pendingReset = false
        isBusy = true
        defer { isBusy = false }
        switch await EgressPolicyEdits.resetToBase(
            vm: name, bundle: bundle, authenticator: authenticator, base: basePolicy) {
        case .reset: show(String(localized: "List reset to the base list."), error: false)
        case .cancelled: show(String(localized: "List not changed: confirmation canceled or failed."), error: true)
        case .failed(let why): show(String(localized: "Couldn’t reset the list: \(why)", comment: "%@ is the error."), error: true)
        }
        await load()
    }

    private func show(_ text: String, error: Bool) {
        message = text
        messageIsError = error
    }
}
