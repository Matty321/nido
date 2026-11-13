// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore
import Observation

/// What S08 Guest Tools does in the guest: `LiveGuestToolsServices` over the background SSH in
/// the app, a fake in the tests. Every call blocks (or awaits) and runs off the main actor.
protocol GuestToolsServicing: Sendable {
    /// Installs the Guest Tools of this Nido in the running VM (`GuestToolsInstaller`).
    func install(on bundle: VMBundle) async throws -> GuestToolsInstaller.Outcome
    /// Writes the anti-hang settings (`GuestCommand.applyPanicSettings`).
    func applyPanicSettings(on bundle: VMBundle) async throws
    /// Turns off the background requests (`GuestCommand.quietBackground`).
    func quietBackground(on bundle: VMBundle, ubuntu: Bool) async throws
    /// Records `~/.ssh/id_ed25519.pub` when it is the key authorized in the VM (`GuestSSH.adoptDefaultKey`).
    func adoptDefaultKey(bundle: VMBundle) throws -> String?
    /// Whether `publicKey` (`"<type> <body>"`) is authorized in the VM's seed.
    func isAuthorized(publicKey: String, in bundle: VMBundle) -> Bool
    /// The installer to paste in the guest (`GuestToolsInstaller.manualInstallCommand`).
    func manualInstallCommand() throws -> String
}

struct LiveGuestToolsServices: GuestToolsServicing {
    func install(on bundle: VMBundle) async throws -> GuestToolsInstaller.Outcome {
        try await GuestToolsInstaller().install(on: bundle)
    }

    func applyPanicSettings(on bundle: VMBundle) async throws {
        let ssh = GuestSSH(bundle: bundle, config: try bundle.readConfig(), runner: SystemProcessRunner())
        _ = try await ssh.run(.applyPanicSettings, timeout: .seconds(180))
    }

    func quietBackground(on bundle: VMBundle, ubuntu: Bool) async throws {
        let ssh = GuestSSH(bundle: bundle, config: try bundle.readConfig(), runner: SystemProcessRunner())
        _ = try await ssh.run(.quietBackground(ubuntu: ubuntu), timeout: .seconds(120))
    }

    func adoptDefaultKey(bundle: VMBundle) throws -> String? {
        try GuestSSH.adoptDefaultKey(bundle: bundle, defaultKey: WizardModel.defaultKeyURL())
    }

    func isAuthorized(publicKey: String, in bundle: VMBundle) -> Bool {
        guard let userData = try? CloudInitSeed.readFile("user-data", fromISO: bundle.seedURL) else { return false }
        return userData.split(whereSeparator: \.isNewline).contains { line in
            line.contains(publicKey)
        }
    }

    func manualInstallCommand() throws -> String {
        try GuestToolsInstaller.manualInstallCommand()
    }
}

/// S08 Guest Tools of one VM (and the Monitor's "Installa Guest Tools"): installs the Guest
/// Tools over SSH in a VM created without them or before M3c, and applies the anti-hang settings
/// of the kernel. Only on the user's request, only with the VM running, with the VM's key.
///
/// A VM without a recorded key adopts `~/.ssh/id_ed25519.pub` when it is the authorized one;
/// otherwise the user chooses the `.pub` it was created with (`chooseKey`). A key that cannot be
/// used from the background (passphrase without agent, host key changed) offers the Terminal;
/// a guest SSH cannot reach or not Debian offers the manual installer.
@MainActor
@Observable
final class GuestToolsModel {
    enum Action: Equatable, Sendable { case install, panic, quiet }

    struct Failure: Equatable, Sendable {
        /// Localized, a sentence.
        let title: String
        let detail: String?
        /// "Apri il Terminale" (`nido ssh`).
        var offersTerminal = false
        /// "Copia i comandi" (the manual installer).
        var offersManual = false
    }

    let name: String
    private(set) var installedVersion: String?
    private(set) var sshKeyPath: String?
    /// Ubuntu (the row says what is turned off); nil until `load()`, false for Debian.
    private(set) var isUbuntu = false
    /// A VM created before 0.7.4 whose background requests nobody turned off: the Rete view
    /// suggests "Spegni" (`GuestBackgroundRequests.mayNeedQuieting`); false after "Spegni" or
    /// "Non ora", both recorded in the config.
    private(set) var suggestsQuieting = false
    private(set) var busy: Action?
    /// What the last action did (localized), nil after a failure.
    private(set) var message: String?
    private(set) var failure: Failure?
    /// The VM has no recorded key and the default one is not it: the user chooses the `.pub`.
    private(set) var needsKey = false
    /// Why the chosen key was refused (localized).
    private(set) var keyError: String?
    /// The manual installer, made when an automatic install failed.
    private(set) var manualCommand: String?

    @ObservationIgnored private let bundle: VMBundle
    @ObservationIgnored private let services: any GuestToolsServicing
    @ObservationIgnored private let isRunning: @MainActor () async -> Bool
    /// Called after a successful install (the window's monitor expects the Guest Tools now).
    @ObservationIgnored var onInstalled: @MainActor () -> Void = {}

    init(bundle: VMBundle, name: String, services: any GuestToolsServicing = LiveGuestToolsServices(),
         isRunning: @escaping @MainActor () async -> Bool) {
        self.bundle = bundle
        self.name = name
        self.services = services
        self.isRunning = isRunning
    }

    /// The VM runs: in a window of this app (`inApp`), or its lock is held to run it (`nido start`,
    /// or this app: owners `.cli` and `.app`), read off the main actor.
    nonisolated static func runs(_ bundle: VMBundle, inApp: Bool) async -> Bool {
        if inApp { return true }
        return await Task.detached {
            switch BundleLock.holder(bundle)?.owner {
            case .cli?, .app?: true
            default: false
            }
        }.value
    }

    /// Reads the version and the key from the config (off the main actor).
    func load() async {
        let bundle = bundle
        let (config, suggests) = await Task.detached {
            (try? bundle.readConfig(), GuestBackgroundRequests.mayNeedQuieting(bundle: bundle))
        }.value
        installedVersion = config?.guestToolsVersion
        sshKeyPath = config?.sshPublicKeyPath
        isUbuntu = config?.linuxDistribution?.isUbuntu ?? false
        suggestsQuieting = suggests
    }

    /// "Non ora" on the suggestion: not asked again for this VM ("Spegni" stays in Impostazioni).
    func declineQuieting() async {
        suggestsQuieting = false
        await recordBackgroundRequests(off: false)
    }

    /// Records the answer in the config; a failed write only means the suggestion comes back.
    private func recordBackgroundRequests(off: Bool) async {
        let bundle = bundle
        await Task.detached { try? bundle.updateConfig { $0.backgroundRequestsOff = off } }.value
    }

    var isBusy: Bool { busy != nil }

    /// The current Guest Tools are newer than the VM's (or it has none).
    var isUpToDate: Bool { installedVersion == GuestToolsPayload.version }

    // MARK: - Actions

    /// "Installa Guest Tools" / "Reinstalla Guest Tools".
    func install() async {
        await perform(.install)
    }

    /// "Impostazioni anti-blocco · Applica".
    func applyPanicSettings() async {
        await perform(.panic)
    }

    /// "Richieste di sfondo · Spegni".
    func quietBackground() async {
        await perform(.quiet)
    }

    /// The suggestion in the Rete view (`suggestsQuieting`).
    var quietSuggestion: String {
        String(localized: "\(name) was created before Nido 0.7.4 and still makes background requests that end up in the log as blocks. Turn Off stops them right away, with the VM running; it’s also in Settings › Guest Tools.")
    }

    /// The note of the "Richieste di sfondo" row.
    var quietNote: String {
        isUbuntu
            ? String(localized: "Turns off snap, the news in the login message, Ubuntu Pro, the check for new releases, apt’s SRV queries and the changelogs apt-listchanges downloads: on the controlled network they only end up in the log as blocks. New Ubuntu VMs already have them off.")
            : String(localized: "Turns off the SRV queries apt makes before each archive and the changelogs apt-listchanges downloads every hour: on the controlled network they only end up in the log as blocks. New VMs already have them off.")
    }

    func dismissFailure() {
        failure = nil
    }

    private func perform(_ action: Action) async {
        guard busy == nil else { return }
        message = nil
        failure = nil
        guard await isRunning() else {
            let title = switch action {
            case .install: String(localized: "Start \(name) to install the Guest Tools.")
            case .panic: String(localized: "Start \(name) to apply the hang protection settings.")
            case .quiet: String(localized: "Start \(name) to turn off the background requests.")
            }
            failure = Failure(title: title, detail: nil)
            return
        }
        busy = action
        defer { busy = nil }
        guard await ensureKey() else { return }
        let bundle = bundle
        let services = services
        do {
            switch action {
            case .install:
                let outcome = try await Task.detached { try await services.install(on: bundle) }.value
                await load()
                message = outcome == .unchanged
                    ? String(localized: "The Guest Tools of \(name) are already up to date.")
                    : String(localized: "Guest Tools installed in \(name). The monitor starts responding after the next restart, if it isn’t already.")
                onInstalled()
            case .panic:
                try await Task.detached { try await services.applyPanicSettings(on: bundle) }.value
                message = String(localized: "Hang protection settings applied: they take effect from the next restart of \(name).")
            case .quiet:
                let ubuntu = isUbuntu
                try await Task.detached { try await services.quietBackground(on: bundle, ubuntu: ubuntu) }.value
                suggestsQuieting = false
                await recordBackgroundRequests(off: true)
                message = String(localized: "Background requests turned off in \(name): this takes effect right away.")
            }
        } catch {
            failure = await describe(error, action: action)
        }
    }

    /// The key is recorded, or the default one is adopted; otherwise `needsKey`.
    private func ensureKey() async -> Bool {
        if sshKeyPath != nil { return true }
        let bundle = bundle
        let services = services
        let adopted = await Task.detached { try? services.adoptDefaultKey(bundle: bundle) }.value ?? nil
        if let adopted {
            sshKeyPath = adopted
            needsKey = false
            return true
        }
        needsKey = true
        failure = Failure(
            title: String(localized: "Choose the SSH key of \(name)"),
            detail: String(localized: "This VM has no recorded SSH key: choose the public key (.pub) it was created with."))
        return false
    }

    /// The user chose the `.pub` the VM was created with: recorded when it is authorized there.
    func chooseKey(_ url: URL) async {
        let bundle = bundle
        let services = services
        let result = await Task.detached { () -> Result<Void, any Error> in
            do {
                let key = try VMControl.readPublicKey(at: url)
                guard services.isAuthorized(publicKey: key, in: bundle) else {
                    return .failure(KeyNotAuthorized())
                }
                try bundle.updateConfig { $0.sshPublicKeyPath = url.path }
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success:
            sshKeyPath = url.path
            needsKey = false
            keyError = nil
            failure = nil
        case .failure(let error):
            keyError = error is KeyNotAuthorized
                ? String(localized: "This key isn’t authorized in \(name): choose the one used to create it.")
                : WizardModel.sentence(error)
        }
    }

    private struct KeyNotAuthorized: Error {}

    private func describe(_ error: any Error, action: Action) async -> Failure {
        let title = switch action {
        case .install: String(localized: "Automatic installation failed")
        case .panic: String(localized: "Hang protection settings not applied")
        case .quiet: String(localized: "Background requests not turned off")
        }
        let detail = WizardModel.sentence(error)
        switch error {
        case GuestSSHError.keyUnavailable, GuestSSHError.hostKeyChanged:
            return Failure(title: title, detail: detail, offersTerminal: true)
        case GuestSSHError.keyNotConfigured:
            needsKey = true
            return Failure(title: title, detail: detail)
        case is GuestToolsInstallError where action == .install:
            await loadManualCommand()
            return Failure(title: title, detail: [detail, String(localized: "You can install the Guest Tools yourself with the commands below, from a session in the VM.")]
                .joined(separator: " "),
                           offersManual: manualCommand != nil)
        case GuestSSHError.unreachable, GuestSSHError.timeout, GuestSSHError.commandFailed:
            guard action == .install else { return Failure(title: title, detail: detail) }
            await loadManualCommand()
            // The title says the guest does not answer: the error's own sentence is kept only when
            // it adds something (a timeout, a failed command), not for a plain "non risponde".
            let advice = String(localized: "Check that the VM is running and the ssh service is on, then click Try Again, or install the Guest Tools yourself with the commands below, from a session in the VM.")
            return Failure(
                title: String(localized: "Automatic installation failed: \(name) doesn’t respond over SSH"),
                detail: (error as? GuestSSHError) == .unreachable ? advice : [detail, advice].joined(separator: " "),
                offersManual: manualCommand != nil)
        default:
            return Failure(title: title, detail: detail)
        }
    }

    private func loadManualCommand() async {
        guard manualCommand == nil else { return }
        let services = services
        manualCommand = await Task.detached { try? services.manualInstallCommand() }.value ?? nil
    }

    /// The first line of the installer, for the page ("…" stands for the archive).
    var manualCommandPreview: String? {
        manualCommand?.split(separator: "\n").first.map { "\($0)\n…" }
    }
}
