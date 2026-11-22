// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The fresh Macs of `nido mcp --fresh`: copies marked `disposable`, deleted when their session
/// ends or, if that did not happen, by the sweep.
public enum DisposableVMs {
    /// A disposable VM younger than this (its bundle folder's birth) is not swept: its session may
    /// still be starting.
    public static let grace: TimeInterval = 600

    /// Deletes `name` only if it is a disposable, non-template macOS VM, checked again under the
    /// bundle lock. False: it is not, nothing was removed. A VM that runs throws `.alreadyRunning`.
    @discardableResult
    public static func delete(
        _ name: VMName, paths: NidoPaths, passwords: any GuestPasswordStore = KeychainGuestPasswordStore()
    ) throws -> Bool {
        var refused = false
        do {
            try VMControl.deleteVM(name, paths: paths, owner: .cliOperation, passwords: passwords) { bundle in
                let config = try bundle.readConfig()
                guard config.disposable == true, config.guest == .macos, !config.isTemplate else {
                    refused = true
                    throw Refused()
                }
            }
        } catch is Refused {
            return false
        }
        return !refused
    }

    private struct Refused: Error {}

    /// A start that is not a fresh session's (`nido start` without `--parent-pid`, the app): a
    /// disposable VM the user starts becomes an ordinary one, so no session end or sweep deletes
    /// it later, and it no longer follows its base's list (`freshBaseID` is cleared too). The
    /// caller holds the bundle lock. Nothing is written when the VM is not disposable or its
    /// config can't be read (the start reports that itself).
    public static func claim(_ bundle: VMBundle) throws {
        guard (try? bundle.readConfig())?.disposable == true else { return }
        _ = try bundle.updateConfig {
            $0.disposable = nil
            $0.freshBaseID = nil
        }
    }

    /// Deletes every stopped disposable VM created at least `grace` seconds before `now`. A VM
    /// whose creation date is unknown is skipped; errors are swallowed. Returns the deleted names.
    @discardableResult
    public static func sweep(
        paths: NidoPaths, now: Date = Date(),
        createdAt: (VMBundle) -> Date? = DisposableVMs.creationDate,
        passwords: any GuestPasswordStore = KeychainGuestPasswordStore()
    ) -> [VMName] {
        var deleted: [VMName] = []
        for bundle in (try? VMBundle.list(paths: paths)) ?? [] {
            guard BundleLock.holder(bundle) == nil,
                let config = try? bundle.readConfig(), config.disposable == true,
                let created = createdAt(bundle), created <= now.addingTimeInterval(-grace)
            else { continue }
            if (try? delete(config.name, paths: paths, passwords: passwords)) == true {
                deleted.append(config.name)
            }
        }
        return deleted
    }

    /// The birth time of the bundle folder (`lstat`, `st_birthtimespec`); nil when unreadable.
    public static func creationDate(_ bundle: VMBundle) -> Date? {
        var info = stat()
        guard lstat(bundle.url.path, &info) == 0 else { return nil }
        let birth = info.st_birthtimespec
        return Date(timeIntervalSince1970: TimeInterval(birth.tv_sec) + TimeInterval(birth.tv_nsec) / 1e9)
    }
}
