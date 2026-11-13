// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation

/// Reads and writes a VM's `egress.json` (`VMBundle.egressPolicyURL`), kept apart from
/// `config.json` so the list can change while the VM runs (the relay reloads it).
///
/// Reading never widens: a missing file is the empty policy, and anything doubtful (a symlink,
/// a hard link, a FIFO or other non-regular file, a file of another user, more than `maxSize`
/// bytes, invalid UTF-8 or JSON nested too deep, another `v`, an invalid pattern) reads as nil,
/// so the caller keeps the last good policy.
///
/// Every change goes through `update`, under the `.egress.lock` of the bundle, so the app and
/// `nido net` editing at the same time never lose each other's change.
public enum EgressPolicyStore {
    /// Largest accepted `egress.json`. `EgressPolicy.maxPatterns` names of 253 characters fit.
    public static let maxSize = 256 * 1024

    /// The policy in `bundle`, `EgressPolicy.empty` when there is no file, nil when the file
    /// cannot be trusted or read.
    public static func load(bundle: VMBundle) -> EgressPolicy? {
        let url = bundle.egressPolicyURL
        let fd: Int32
        do {
            // Besides refusing an unsafe file, `PrivateFile.open` tightens its mode to 0600.
            fd = try PrivateFile.open(url, flags: O_RDONLY, label: url.lastPathComponent)
        } catch let error as POSIXError where error.code == .ENOENT {
            return .empty
        } catch {
            return nil
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let data = try? handle.read(upToCount: maxSize + 1), data.count <= maxSize,
            JSONDepth.check(data) == nil
        else { return nil }
        return try? JSONDecoder().decode(EgressPolicy.self, from: data)
    }

    /// Read-modify-write of `egress.json` under the bundle's `.egress.lock`: `edit` starts from
    /// the policy on disk (`EgressPolicy.empty` when there is no file) and the result is saved
    /// atomically and returned. A file that does not load (`load` is nil) throws
    /// `NidoError.invalidEgressPolicy` and is left as it is: it is never taken for the empty
    /// policy. When `edit` throws, nothing is written. `edit` must be short and must not call
    /// `update` (the lock is not reentrant).
    @discardableResult
    public static func update(bundle: VMBundle, _ edit: (inout EgressPolicy) throws -> Void) throws -> EgressPolicy {
        try bundle.withFileLock(bundle.egressLockURL) {
            guard var policy = load(bundle: bundle) else {
                throw NidoError.invalidEgressPolicy(L10n.string("egress.json is unreadable or invalid"))
            }
            try edit(&policy)
            try save(policy, bundle: bundle)
            return policy
        }
    }

    /// Replaces `egress.json` with `policy` under the lock, whatever the file holds now (also a
    /// file that does not load, or a symlink, which is replaced and never written through). The
    /// way out of a damaged file (`nido net reset`): the caller asks the owner first, since the
    /// new list may be wider than the one the relay keeps. Refuses what `save` refuses.
    public static func replace(bundle: VMBundle, with policy: EgressPolicy) throws {
        try bundle.withFileLock(bundle.egressLockURL) {
            try save(policy, bundle: bundle)
        }
    }

    /// `replace`, unless `refuse` (given the policy on disk under the lock, nil when it does not
    /// load) says no: then nothing is written and the result is false. Lets a caller that did not
    /// ask the owner write only a list that does not widen the one on disk at that moment.
    public static func replace(
        bundle: VMBundle, with policy: EgressPolicy, unless refuse: (EgressPolicy?) -> Bool
    ) throws -> Bool {
        try bundle.withFileLock(bundle.egressLockURL) {
            guard !refuse(load(bundle: bundle)) else { return false }
            try save(policy, bundle: bundle)
            return true
        }
    }

    /// Writes `policy` atomically (0600, a temporary file renamed over `egress.json`) WITHOUT the
    /// lock: only for a bundle nobody else can see yet (creation) and for tests. Every other
    /// writer uses `update`. Refuses (`NidoError.invalidEgressPolicy`) another version, more
    /// than `EgressPolicy.maxPatterns` patterns or more than `maxSize` bytes: what is saved
    /// always loads back.
    static func save(_ policy: EgressPolicy, bundle: VMBundle) throws {
        guard policy.v == EgressPolicy.currentVersion else {
            throw NidoError.invalidEgressPolicy(L10n.string("unsupported version \(String(policy.v))"))
        }
        guard policy.allow.count <= EgressPolicy.maxPatterns else {
            throw NidoError.invalidEgressPolicy(L10n.string("more than \(EgressPolicy.maxPatterns) domains"))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(policy)
        data.append(0x0A)
        guard data.count <= maxSize else { throw NidoError.invalidEgressPolicy(L10n.string("file too large")) }
        try PrivateFile.writeAtomically(data, to: bundle.egressPolicyURL)
    }
}
