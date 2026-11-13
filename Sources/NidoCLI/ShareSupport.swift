// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore

/// `nido share list|add|remove`: the logic, testable without ArgumentParser.
extension CLISupport {
    /// Refuses (`.vmRunningInApp`) when the app runs the VM: its folders change live from the app
    /// only. A VM run by `nido start` (owner `cli`) keeps the stopped-VM rule of `editConfig`.
    private static func refuseIfRunningInApp(_ bundle: VMBundle, _ name: VMName) throws {
        if BundleLock.holder(bundle)?.owner == .app { throw NidoError.vmRunningInApp(name.rawValue) }
    }

    /// Runs an edit; a VM the app started between the check and the lock is refused the same way.
    /// A template is refused (`.isTemplate`), as in the app, checked in the config read under the lock.
    private static func editShares(
        _ bundle: VMBundle, _ name: VMName, _ edit: (inout VMConfig) throws -> Void
    ) throws -> VMConfig {
        try refuseIfRunningInApp(bundle, name)
        do {
            return try VMControl.editConfig(bundle, owner: .cliOperation) { config in
                guard !config.isTemplate else { throw NidoError.isTemplate(config.name.rawValue) }
                try edit(&config)
            }
        } catch NidoError.vmMustBeStopped {
            try refuseIfRunningInApp(bundle, name)
            throw NidoError.vmMustBeStopped(bundle.displayName)
        }
    }

    /// Adds a shared folder to a stopped VM (bundle lock with owner `.cli`). Read-only unless
    /// `readWrite`; the name defaults to the folder's own. Returns the text for stdout.
    public static func addShare(
        vm: String, path: String, name: String?, readWrite: Bool, paths: NidoPaths,
        imageCache: URL = ImageStore.defaultCacheRoot(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> String {
        let vmName = try VMName(vm)
        let bundle = try VMBundle.open(vmName, paths: paths)
        let url = try SharedFolder.validate(hostPath: path, paths: paths, imageCache: imageCache, home: home)
        if let name { try SharedFolder.validateName(name) }
        var added = SharedFolder(name: name ?? "", hostPath: url.path, readOnly: !readWrite)
        let config = try editShares(bundle, vmName) { config in
            if name == nil {
                added.name = SharedFolder.defaultName(for: url, taken: config.sharedFolders.map(\.name))
            }
            config.sharedFolders = try SharedFolder.adding(added, to: config.sharedFolders)
        }
        var lines = [
            L10n.string("Shared folder: \(printable(added.hostPath)) → \(printable(added.guestPath(for: config.guest))) (\(accessLabel(added)))."),
            L10n.string("Takes effect at the next start of \(config.name.rawValue)."),
        ]
        lines += suspendedWarning(bundle, config, imageCache: imageCache)
        if needsLegacyHint(config) { lines += legacyHint }
        return lines.joined(separator: "\n")
    }

    /// For an edit of a suspended VM whose saved state the next start will no longer resume.
    static func suspendedWarning(
        _ bundle: VMBundle, _ config: VMConfig, imageCache: URL = ImageStore.defaultCacheRoot(),
        rosettaState: RosettaState = .current
    ) -> [String] {
        guard bundle.hasSuspendedState(config),
            !SuspendedState.nextStartResumes(
                bundle: bundle, config: config, imageCache: imageCache, rosettaState: rosettaState)
        else { return [] }
        return [L10n.string("Warning: the VM is suspended: at its next start, the saved state will be discarded.")]
    }

    /// A host path or name from `config.json` as printed in the terminal: no control characters.
    static func printable(_ text: String) -> String {
        ConsoleSanitizer.escapingControls(text)
    }

    /// Removes the shared folder `name` (ignoring case) from a stopped VM. Returns the stdout text.
    public static func removeShare(vm: String, name: String, paths: NidoPaths) throws -> String {
        let vmName = try VMName(vm)
        let bundle = try VMBundle.open(vmName, paths: paths)
        let config = try editShares(bundle, vmName) { config in
            config.sharedFolders = try SharedFolder.removing(name, from: config.sharedFolders)
        }
        return ([L10n.string("Shared folder \(printable(name)) removed. Takes effect at the next start of \(config.name.rawValue).")]
            + suspendedWarning(bundle, config)).joined(separator: "\n")
    }

    /// The VM's shared folders as a table (`NAME ACCESS PATH IN THE VM`). Each folder is
    /// checked as the next start will check it (`SharedFolder.validate`): one that would be left
    /// out is marked. Reads only: no lock.
    public static func listShares(
        vm: String, paths: NidoPaths, imageCache: URL = ImageStore.defaultCacheRoot(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> String {
        let bundle = try VMBundle.open(try VMName(vm), paths: paths)
        let config = try bundle.readConfig()
        guard !config.sharedFolders.isEmpty else { return L10n.string("No shared folders.") }
        let rows = config.sharedFolders.map { folder -> [String] in
            let note = startProblem(folder, paths: paths, imageCache: imageCache, home: home)
                .map { " (\($0))" } ?? ""
            return [printable(folder.name), accessLabel(folder), printable(folder.hostPath + note),
                    printable(folder.guestPath(for: config.guest))]
        }
        let header = [L10n.string("NAME"), L10n.string("ACCESS"), L10n.string("PATH"), L10n.string("IN THE VM")]
        var lines = [formatTable([header] + rows)]
        if needsLegacyHint(config) { lines += legacyHint }
        return lines.joined(separator: "\n")
    }

    /// A Linux VM created before M3a: its guest does not mount the folders by itself. A macOS
    /// guest mounts them in /Volumes/My Shared Files on its own: never.
    static func needsLegacyHint(_ config: VMConfig) -> Bool {
        config.guest == .linux && !config.guestMountsSharedFolders
    }

    /// Why the next start would leave `folder` out, or nil when it would share it.
    static func startProblem(_ folder: SharedFolder, paths: NidoPaths, imageCache: URL, home: URL) -> String? {
        do {
            _ = try SharedFolder.validate(hostPath: folder.hostPath, paths: paths, imageCache: imageCache, home: home)
            return nil
        } catch .sharedFolderMissing {
            return L10n.string("not found, left out at start")
        } catch {
            return L10n.string("left out at start: \(error.errorDescription ?? "")")
        }
    }

    static func accessLabel(_ folder: SharedFolder) -> String {
        folder.readOnly ? L10n.string("read only") : L10n.string("read & write")
    }

    /// For VMs created before M3a: their guest does not mount /mnt/nido by itself.
    static var legacyHint: [String] {
        ["",
         L10n.string("VM created with an earlier version of Nido: run this once in the VM"),
         "  \(SharedFolder.legacyGuestCommand)"]
    }
}
