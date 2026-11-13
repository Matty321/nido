// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The VMs running right now, in the app or with `nido start`, read from the bundle locks.
/// Used by the app's updater: an update is never installed while any VM runs.
public enum RunningVMs {
    /// Names of the VMs whose lock is held by the app (`.app`) or by `nido start` (`.cli`),
    /// sorted by name (case-insensitive). A maintenance command (`.cliOperation`) runs no VM and
    /// does not count. A held lock always means running: when `config.json` cannot be read the
    /// name comes from the bundle's folder. A root that cannot be listed gives no names.
    public static func names(paths: NidoPaths) -> [VMName] {
        var result: [VMName] = []
        for bundle in (try? VMBundle.list(paths: paths)) ?? [] {
            guard let owner = BundleLock.holder(bundle)?.owner, owner == .app || owner == .cli else { continue }
            if let config = try? bundle.readConfig() {
                result.append(config.name)
            } else if let name = try? VMName(bundle.displayName) {
                result.append(name)
            }
        }
        return result.sorted { $0.rawValue.lowercased() < $1.rawValue.lowercased() }
    }
}
