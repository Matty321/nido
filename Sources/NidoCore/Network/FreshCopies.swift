// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The disposable fresh Macs of a base (`nido mcp --fresh`), and how a change of the base's list
/// reaches them. One way only: a copy's own list never reaches its base. A copy follows while it
/// is disposable: a kept (`--keep`), claimed (`DisposableVMs.claim`) or cloned copy has no
/// `freshBaseID` any more. Shared by `nido net allow|deny` and the app's allow/remove.
public enum FreshCopies {
    /// Every VM whose config is `disposable` and names the `id` of `base` as its `freshBaseID`.
    /// Empty when the base's config can't be read. A copy whose config can't be read is skipped.
    public static func of(_ base: VMBundle, paths: NidoPaths) -> [VMBundle] {
        guard let baseID = try? base.readConfig().id else { return [] }
        return ((try? VMBundle.list(paths: paths)) ?? []).filter { bundle in
            guard let config = try? bundle.readConfig() else { return false }
            return config.disposable == true && config.freshBaseID == baseID
        }
    }

    /// Runs `edit` on the list of every copy of `base` (`EgressPolicyStore.update`, under each
    /// copy's own lock), after the caller wrote the base. Best effort: a copy that fails (its
    /// list does not load, `edit` throws, the write fails) is left as it is and listed in
    /// `failed` with the error's description, and `damagedList` when its `egress.json` is
    /// unreadable or invalid (`nido net reset` repairs it); the others still get the change. A
    /// copy deleted while the change ran (ENOENT, or its folder gone) is neither applied nor
    /// failed: there is nothing left to repair.
    public static func propagate(
        from base: VMBundle, paths: NidoPaths, _ edit: (inout EgressPolicy) throws -> Void
    ) -> (applied: [VMName], failed: [(name: VMName, reason: String, damagedList: Bool)]) {
        var applied: [VMName] = []
        var failed: [(name: VMName, reason: String, damagedList: Bool)] = []
        for copy in of(base, paths: paths) {
            // `of` just read it; a copy deleted since then is skipped.
            guard let name = try? copy.readConfig().name else { continue }
            do {
                try EgressPolicyStore.update(bundle: copy, edit)
                applied.append(name)
            } catch {
                if isGone(error, copy) { continue }
                // `save` throws the same error for a list at its limit: damaged only when the
                // file on disk does not load.
                var damaged = false
                if case NidoError.invalidEgressPolicy = error {
                    damaged = EgressPolicyStore.load(bundle: copy) == nil
                }
                failed.append((name, error.localizedDescription, damaged))
            }
        }
        return (applied, failed)
    }

    private static func isGone(_ error: any Error, _ copy: VMBundle) -> Bool {
        if let posix = error as? POSIXError, posix.code == .ENOENT { return true }
        return !FileManager.default.fileExists(atPath: copy.url.path)
    }
}
