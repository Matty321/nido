// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore

/// Testable logic behind the `nido` commands. The ArgumentParser layer stays thin.
public enum CLISupport {
    // MARK: - Paths

    /// `NidoPaths` from `NIDO_ROOT` (absolute path of an existing directory) or the default root.
    public static func paths(environment: [String: String]) throws -> NidoPaths {
        guard let raw = environment["NIDO_ROOT"] else {
            return NidoPaths(root: NidoPaths.defaultRoot())
        }
        var isDirectory: ObjCBool = false
        guard raw.hasPrefix("/"),
            FileManager.default.fileExists(atPath: raw, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { throw CLIError.invalidRoot(raw) }
        return NidoPaths(root: URL(fileURLWithPath: raw, isDirectory: true))
    }

    /// `paths(environment:)` followed by `ensureRoot()`.
    public static func preparedPaths(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> NidoPaths {
        let paths = try paths(environment: environment)
        try paths.ensureRoot()
        return paths
    }

    // MARK: - create

    /// Validates `create` arguments without touching the disk or the network.
    public static func parseCreateOptions(
        name: String, image: String?, imageFile: String?, sshKey: String?,
        cpus: Int, memory: String?, disk: String, noPackages: Bool = false, noGuestTools: Bool = false,
        user: String? = nil,
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) throws -> CreateOptions {
        let vmName = try VMName(name)
        // The Linux guest's account is always `nido` (cloud-init).
        guard user == nil else { throw CLIError.userRequiresIPSW }
        // Without --memory: the Linux Base default for this Mac (smaller with 16 GiB or less).
        let memoryBytes = try memory.map(ByteSize.parse)
            ?? ResourceLimits.defaultMemoryBytes(for: .debianBase, physicalMemory: physicalMemory)
        let diskBytes = try ByteSize.parse(disk)
        guard let sshKey else { throw CLIError.missingSSHKey }
        let source: CreateOptions.ImageSource
        switch (image, imageFile) {
        case (let id?, nil):
            guard let catalogImage = CloudImageCatalog.image(id: id) else { throw CLIError.unknownImage(id) }
            source = .catalog(catalogImage)
        case (nil, let path?):
            source = .file(URL(fileURLWithPath: path))
        default:
            throw CLIError.imageSourceRequired
        }
        return CreateOptions(
            name: vmName, image: source, sshKeyPath: URL(fileURLWithPath: sshKey),
            cpuCount: cpus, memoryBytes: memoryBytes, diskBytes: diskBytes,
            profile: ProvisioningProfile(essentialPackages: !noPackages, guestTools: !noGuestTools))
    }

    // MARK: - list

    public static func listVMs(paths: NidoPaths) throws -> [VMListing] {
        try VMBundle.list(paths: paths).map { bundle in
            let owner = BundleLock.holder(bundle)?.owner
            var state = switch owner {
            case nil: L10n.string("stopped")
            case .cli: L10n.string("running")
            case .app: L10n.string("running (app)")
            case .cliOperation: L10n.string("busy")
            }
            guard let config = try? bundle.readConfig() else {
                return VMListing(name: bundle.displayName, state: state, system: "?", cpus: "?", memory: "?")
            }
            if owner == nil, bundle.hasSuspendedState(config) { state = L10n.string("suspended") }
            if config.isTemplate { state = L10n.string("\(state) (template)") }
            return VMListing(
                name: config.name.rawValue, state: state, system: systemName(config),
                cpus: String(config.cpuCount), memory: formatBytes(config.memoryBytes))
        }
    }

    /// The SYSTEM column: "macOS <version>" (the version recorded at creation, "macOS" without
    /// one); the distribution for a Linux guest ("Debian 13", "Ubuntu 26.04 LTS"; Debian 13 when
    /// the config records none, "Linux" for one this build does not know), as the app's library shows it.
    public static func systemName(_ config: VMConfig) -> String {
        switch config.guest {
        case .linux: config.linuxDistribution?.displayName ?? "Linux"
        case .macos: config.osVersion.map { "macOS \($0)" } ?? "macOS"
        }
    }

    /// Left-aligned table with the localized header `NAME STATE SYSTEM CPU MEMORY`.
    public static func formatList(_ rows: [VMListing]) -> String {
        let header = [L10n.string("NAME"), L10n.string("STATE"), L10n.string("SYSTEM"), "CPU", L10n.string("MEMORY")]
        return formatTable([header] + rows.map { [$0.name, $0.state, $0.system, $0.cpus, $0.memory] })
    }

    /// Rows of cells as left-aligned columns two spaces apart: each column as wide as its widest
    /// cell, the localized header included, so the columns line up in every language. The last
    /// column is not padded.
    static func formatTable(_ table: [[String]]) -> String {
        let widths = (table.first ?? []).indices.map { column in table.map { $0[column].count }.max() ?? 0 }
        return table.map { row in
            row.enumerated().map { column, cell in
                column == row.count - 1
                    ? cell : cell.padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }.joined(separator: "\n")
    }

    /// Binary units: `4 GiB`, `512 MiB`, `1.5 GiB`, `1023 B`.
    public static func formatBytes(_ bytes: UInt64) -> String { ByteSize.format(bytes) }

    // MARK: - stop --suspend

    /// What `nido stop --suspend` finds once it stopped waiting for the `nido start` process.
    public enum SuspendReport: Equatable, Sendable {
        /// The VM is stopped with a saved state.
        case suspended
        /// The VM is stopped, without a saved state (the suspend failed, or a stop won).
        case stoppedWithoutState
        /// The lock is still held after the wait: the suspend did not end in time.
        case stillRunning
        /// The `nido start` process answered that it cannot suspend: a `SuspendRefusal` code, or the
        /// text of the error that made the suspend fail.
        case refused(String)

        public func message(vm: String) -> String {
            switch self {
            case .suspended:
                L10n.string("VM \(vm) suspended.")
            case .stoppedWithoutState:
                L10n.string("The VM \(vm) stopped without saving its state: its next start will be a cold boot. See the terminal running nido start for details.")
            case .stillRunning:
                L10n.string("The VM \(vm) is still running: the suspend didn’t finish in time. See the terminal running nido start for details.")
            case .refused(let reason):
                L10n.string("The VM \(vm) wasn’t suspended: \(SuspendRefusal.text(reason))")
            }
        }
    }

    /// Why `nido start` refuses a suspend at once. The raw value, language-neutral, is what it
    /// answers `nido stop --suspend` (`VMControl.writeSuspendResult`), which may run in another
    /// language.
    public enum SuspendRefusal: String, CaseIterable, Sendable {
        case alreadyStopping = "suspend-refused:stopping"
        case resuming = "suspend-refused:resuming"
        case notRunningYet = "suspend-refused:not-running"

        /// The line `nido start` prints.
        public var line: String {
            switch self {
            case .alreadyStopping: L10n.string("Suspend refused: the VM is already stopping.")
            case .resuming: L10n.string("Suspend refused: the VM is resuming from its saved state; try again shortly.")
            case .notRunningYet: L10n.string("Suspend refused: the VM isn’t running yet; try again shortly.")
            }
        }

        /// The reason `nido stop --suspend` prints after "wasn’t suspended:".
        public var reason: String {
            switch self {
            case .alreadyStopping: L10n.string("it’s already stopping")
            case .resuming: L10n.string("it’s resuming from its saved state; try again shortly")
            case .notRunningYet: L10n.string("it isn’t running yet; try again shortly")
            }
        }

        /// A stored answer as text: a code in the UI language, anything else (an error message,
        /// an older `nido start`'s Italian text) unchanged.
        public static func text(_ stored: String) -> String {
            SuspendRefusal(rawValue: stored)?.reason ?? stored
        }
    }

    /// Waits for the `nido start` process asked to suspend (`VMControl.requestSuspend`): returns
    /// as soon as it answers that it cannot (`.refused`, its answer removed), or releases the lock
    /// (then the bundle says whether the VM is suspended), or after `timeout` (`.stillRunning`).
    public static func waitForSuspend(
        bundle: VMBundle, timeout: TimeInterval, pollInterval: TimeInterval = 0.2
    ) -> SuspendReport {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let reason = VMControl.readSuspendResult(bundle: bundle) {
                VMControl.clearSuspendResult(bundle: bundle)
                return .refused(reason)
            }
            let held = BundleLock.holder(bundle) != nil
            if !held || Date() >= deadline { return suspendReport(bundle: bundle, lockHeld: held) }
            usleep(useconds_t(pollInterval * 1_000_000))
        }
    }

    /// Reads the bundle after a suspend request: `lockHeld` is whether the VM's process still runs.
    public static func suspendReport(bundle: VMBundle, lockHeld: Bool) -> SuspendReport {
        if lockHeld { return .stillRunning }
        guard let config = try? bundle.readConfig(), bundle.hasSuspendedState(config) else {
            return .stoppedWithoutState
        }
        return .suspended
    }

    // MARK: - Prompts and messages

    /// The question before downloading a catalog image: what is verified (the checksum, and
    /// Ubuntu's signature when the image has one).
    public static func downloadQuestion(_ image: CloudImage) -> String {
        let url = image.url.absoluteString
        let checksum = image.checksum == .sha512 ? "SHA-512" : "SHA-256"
        return image.signature != nil
            ? L10n.string("Download \(url) and verify its \(checksum) checksum and Ubuntu’s signature? [y/N] ")
            : L10n.string("Download \(url) and verify its \(checksum) checksum? [y/N] ")
    }

    /// The answers that confirm a `[y/N]` question besides `y` and `yes`, per UI language: the
    /// letter each language's question offers and its word for yes.
    static let localizedYes: [String: Set<String>] = [
        "it": ["s", "si", "sì"],
        "de": ["j", "ja"],
        "es": ["s", "si", "sí"],
        "fr": ["o", "oui"],
    ]

    /// `y`, `yes` and the yes of `language` (`s`, `si`, `sì`; `j`, `ja`; `s`, `si`, `sí`; `o`, `oui`),
    /// case-insensitive, surrounding whitespace ignored.
    public static func isAffirmative(_ answer: String?, language: String = L10n.language) -> Bool {
        guard let answer else { return false }
        let normalized = answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["y", "yes"].contains(normalized) || localizedYes[language, default: []].contains(normalized)
    }

    /// A single-line message for any error, in the UI language, suitable for `Error: <msg>`.
    public static func message(for error: any Error) -> String {
        switch error {
        case let error as NidoError:
            return error.errorDescription ?? L10n.string("unknown error")
        case let error as CLIError:
            return error.errorDescription ?? L10n.string("unknown error")
        case let error as POSIXError:
            return L10n.string("system error: \(String(cString: strerror(error.code.rawValue)))")
        default:
            return error.localizedDescription
        }
    }
}
