// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Operations on VMs shared by the `nido` CLI and the app: public key intake, stop, delete,
/// IP lookup and `known_hosts` preparation.
public enum VMControl {
    /// Largest accepted public key file.
    public static let maxKeyFileSize = 16 * 1024

    /// Reads an OpenSSH public key file and returns the validated `"<type> <body>"`.
    /// Refuses, before opening it, a path not ending in `.pub` (a private key is never opened);
    /// a `.pub` that is itself a symlink is not followed (`foo.pub -> id_ed25519` would open the
    /// private key) and reads as unreadable. Then rejects non-regular files, files over 16 KiB and
    /// anything that looks like a private key. The file content is never included in errors.
    public static func readPublicKey(at url: URL) throws -> String {
        guard url.path.hasSuffix(".pub") else { throw NidoError.keyPathNotPub(url.path) }
        // O_NONBLOCK: never hang on a FIFO; regular-file reads are unaffected.
        // O_NOFOLLOW: the last component must not be a symlink.
        let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NidoError.keyFileUnreadable(url.path) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw NidoError.keyFileUnreadable(url.path)
        }
        guard info.st_size <= maxKeyFileSize else { throw NidoError.keyFileTooLarge }
        let data: Data
        do {
            data = try handle.read(upToCount: maxKeyFileSize + 1) ?? Data()
        } catch {
            throw NidoError.keyFileUnreadable(url.path)
        }
        guard data.count <= maxKeyFileSize else { throw NidoError.keyFileTooLarge }
        let text = String(decoding: data, as: UTF8.self)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("-----BEGIN") || text.contains("PRIVATE KEY") {
            throw NidoError.privateKeyRejected
        }
        return try CloudInitSeed.validatePublicKey(text)
    }

    // MARK: - stop / delete

    /// Sends SIGTERM to the `nido start` process holding the bundle lock. Refuses a VM owned by
    /// the app (the signal would reach the app and close every VM it runs) and a lock held by a
    /// maintenance command (`.operationInProgress`: snapshot, clone, share… must not be killed
    /// mid-way). Never signals the calling process itself, whatever the lock line says (the app
    /// may hold a lock for a delete).
    public static func requestStop(bundle: VMBundle, name: VMName) throws {
        try signalHolder(bundle: bundle, name: name, signal: SIGTERM)
    }

    private static func signalHolder(bundle: VMBundle, name: VMName, signal: Int32) throws {
        guard let holder = BundleLock.holder(bundle) else { throw NidoError.notRunning(name.rawValue) }
        switch holder.owner {
        case .cli: break
        case .app: throw NidoError.ownedByApp(name.rawValue)
        case .cliOperation: throw NidoError.operationInProgress(name.rawValue, pid: holder.pid)
        }
        let pid = holder.pid
        guard pid > 0 else { throw NidoError.pidUnknown }
        guard pid != getpid() else { throw NidoError.ownedByApp(name.rawValue) }
        guard kill(pid, signal) == 0 else {
            let err = errno
            if err == ESRCH { throw NidoError.notRunning(name.rawValue) }
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EPERM)
        }
    }

    /// Signal a `nido start` process sends itself on `nido stop --suspend`: suspend, then exit.
    public static let suspendSignal = SIGUSR1

    /// `nido stop --suspend`: sends `suspendSignal` to the `nido start` process holding the bundle
    /// lock, which suspends the VM (`VMSession.suspend`) and exits. Refused like `requestStop`
    /// for a VM run by the app (only the app can suspend it) or by this very process.
    public static func requestSuspend(bundle: VMBundle, name: VMName) throws {
        try signalHolder(bundle: bundle, name: name, signal: suspendSignal)
    }

    /// Largest accepted `.suspend-result`.
    static let maxSuspendResultSize = 4096

    /// Written by the `nido start` process that cannot suspend (VM not running yet, configuration
    /// that cannot be saved, a failed save): `reason` localized, so `nido stop --suspend` stops
    /// waiting at once. A private file (`PrivateFile`: no symlink, FIFO or foreign file).
    public static func writeSuspendResult(bundle: VMBundle, reason: String) throws {
        let fd = try PrivateFile.open(bundle.suspendResultURL, flags: O_WRONLY | O_CREAT | O_TRUNC, label: ".suspend-result")
        defer { _ = Darwin.close(fd) }
        let data = Array(reason.utf8.prefix(maxSuspendResultSize))
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard written == data.count else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// The reason written by `writeSuspendResult`, nil when there is none (or it is not a private
    /// regular file). Never blocks, never follows a symlink.
    public static func readSuspendResult(bundle: VMBundle) -> String? {
        let fd = Darwin.open(bundle.suspendResultURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard (try? PrivateFile.check(fd, label: ".suspend-result")) != nil,
            let data = try? handle.read(upToCount: maxSuspendResultSize), !data.isEmpty
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Removes an old answer before a new request (`unlink`: never follows a symlink).
    public static func clearSuspendResult(bundle: VMBundle) {
        _ = unlink(bundle.suspendResultURL.path)
    }

    /// Removes a VM bundle so that a running VM can never be deleted and a concurrent `start`
    /// can never boot a half-deleted one: while holding the bundle lock the directory is
    /// atomically renamed to a tombstone (invisible to `open`/`list`); the lock is then released
    /// and the tombstone removed. `owner` is the caller's kind (`.cli` for `nido delete`, `.app`
    /// for the app): it is what the lock line says while the delete runs.
    public static func deleteVM(_ name: VMName, paths: NidoPaths, owner: LockOwner) throws {
        try deleteVM(name, paths: paths, owner: owner, whileLocked: { _ in })
    }

    /// `deleteVM` for the app: the lock is taken with `BundleLock.acquireAsync`, so a brief
    /// contention is retried without blocking the calling actor.
    public static func deleteVMAsync(_ name: VMName, paths: NidoPaths, owner: LockOwner) async throws {
        let bundle = try VMBundle.open(name, paths: paths)
        let tombstone: URL
        do {
            let lock = try await BundleLock.acquireAsync(bundle, owner: owner)
            defer { lock.release() }
            tombstone = try bundle.moveToTombstone()
        }
        try VMBundle.removeTombstone(at: tombstone)
    }

    /// `whileLocked` runs with the lock held, before the rename (test seam).
    static func deleteVM(
        _ name: VMName, paths: NidoPaths, owner: LockOwner, whileLocked: (VMBundle) throws -> Void
    ) throws {
        let bundle = try VMBundle.open(name, paths: paths)
        let tombstone: URL
        do {
            let lock = try BundleLock.acquire(bundle, owner: owner)
            defer { lock.release() }
            try whileLocked(bundle)
            tombstone = try bundle.moveToTombstone()
        }
        try VMBundle.removeTombstone(at: tombstone)
    }

    // MARK: - config edits

    /// Changes `config.json` of a VM that is stopped: takes the bundle lock (`owner` is the
    /// caller's kind), reads the config again under it, applies `edit` and writes it back (in the
    /// current schema). A VM that is running, here or elsewhere, is refused with
    /// `.vmMustBeStopped` and nothing is written. Returns the config as written.
    @discardableResult
    public static func editConfig(
        _ bundle: VMBundle, owner: LockOwner, _ edit: (inout VMConfig) throws -> Void
    ) throws -> VMConfig {
        let lock: BundleLock
        do {
            lock = try BundleLock.acquire(bundle, owner: owner)
        } catch NidoError.alreadyRunning {
            throw NidoError.vmMustBeStopped(bundle.displayName)
        }
        defer { lock.release() }
        return try rewriteConfig(bundle, edit)
    }

    /// `editConfig` for the app: the lock is taken with `BundleLock.acquireAsync`.
    @discardableResult
    public static func editConfigAsync(
        _ bundle: VMBundle, owner: LockOwner, _ edit: @Sendable (inout VMConfig) throws -> Void
    ) async throws -> VMConfig {
        let lock: BundleLock
        do {
            lock = try await BundleLock.acquireAsync(bundle, owner: owner)
        } catch NidoError.alreadyRunning {
            throw NidoError.vmMustBeStopped(bundle.displayName)
        }
        defer { lock.release() }
        return try rewriteConfig(bundle, edit)
    }

    private static func rewriteConfig(_ bundle: VMBundle, _ edit: (inout VMConfig) throws -> Void) throws -> VMConfig {
        try bundle.updateConfig(edit)
        return try bundle.readConfig()
    }

    // MARK: - ip

    /// The guest IP from the DHCP lease database, only for a VM that is running (its bundle
    /// lock is held): otherwise `.notRunning`. Only unexpired leases with an IPv4 literal count.
    public static func resolveIP(bundle: VMBundle, leasesURL: URL, now: Date = Date()) throws -> String {
        let config = try bundle.readConfig()
        guard BundleLock.holder(bundle) != nil else { throw NidoError.notRunning(config.name.rawValue) }
        guard let data = try? Data(contentsOf: leasesURL) else {
            throw NidoError.leasesUnreadable(leasesURL.path)
        }
        guard let ip = DHCPLeases.ipAddress(
            forMAC: config.macAddress, leases: String(decoding: data, as: UTF8.self), now: now)
        else { throw NidoError.notOnNetwork(config.name.rawValue) }
        return ip
    }

    // MARK: - ssh

    /// How `nido ssh` and the app's background commands reach a running VM. A VM on Apple's NAT:
    /// the address from the DHCP lease database (`resolveIP`), port 22. A controlled-network VM:
    /// `127.0.0.1` and the port in `ssh-forward.json`, only while the PID recorded there is alive
    /// and is a `gvproxy`: a stale file never sends ssh to a dead port, or to a port another program
    /// took. A missing or unreadable file is `.notOnNetwork` (gvproxy not started yet); a valid one
    /// whose PID is dead or not a `gvproxy` is `.controlledNetworkInterrupted` (gvproxy is gone).
    public static func resolveSSH(bundle: VMBundle, leasesURL: URL, now: Date = Date()) throws -> SSHEndpoint {
        try resolveSSH(bundle: bundle, leasesURL: leasesURL, now: now, isGvproxy: GvproxyProcess.isGvproxy)
    }

    /// `resolveSSH` with the "PID is a gvproxy" check injectable (tests).
    static func resolveSSH(
        bundle: VMBundle, leasesURL: URL, now: Date, isGvproxy: (Int32) -> Bool
    ) throws -> SSHEndpoint {
        let config = try bundle.readConfig()
        guard config.controlledNetwork == true else {
            return SSHEndpoint(host: try resolveIP(bundle: bundle, leasesURL: leasesURL, now: now), port: 22)
        }
        let name = config.name.rawValue
        guard BundleLock.holder(bundle) != nil else { throw NidoError.notRunning(name) }
        guard let forward = readSSHForward(bundle), forward.pid > 1, forward.port != 0
        else { throw NidoError.notOnNetwork(name) }
        // Name and start time: a dead gvproxy's PID given to another VM's gvproxy is not this one.
        guard GvproxyProcess.isLive(forward, isGvproxy: isGvproxy) else { throw NidoError.controlledNetworkInterrupted }
        return SSHEndpoint(host: "127.0.0.1", port: forward.port)
    }

    /// True while a running VM's `gvproxy` is gone: its `ssh-forward.json` is still there (kept
    /// when the uplink is lost) but its process is no longer the gvproxy that wrote it, so the VM
    /// has no network until it is restarted. False when the VM does not run or gvproxy has not
    /// started yet.
    public static func isControlledNetworkInterrupted(bundle: VMBundle) -> Bool {
        guard BundleLock.holder(bundle) != nil, let forward = readSSHForward(bundle), forward.pid > 1,
              forward.port != 0 else { return false }
        return !GvproxyProcess.isLive(forward)
    }

    /// The content of `ssh-forward.json`, nil when it is missing, not a private regular file or not
    /// valid.
    private static func readSSHForward(_ bundle: VMBundle) -> GvproxyProcess.SSHForward? {
        guard let fd = try? PrivateFile.open(bundle.sshForwardURL, flags: O_RDONLY, label: "ssh-forward.json")
        else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let data = try? handle.read(upToCount: 256) else { return nil }
        return try? JSONDecoder().decode(GvproxyProcess.SSHForward.self, from: data)
    }

    /// Makes sure the bundle's `known_hosts` exists as a private regular 0600 file (no symlink,
    /// FIFO, hard link or foreign owner: `.unsafePath("known_hosts")`) before ssh writes to it.
    public static func prepareKnownHosts(bundle: VMBundle) throws {
        let fd = try PrivateFile.open(bundle.knownHostsURL, flags: O_WRONLY | O_CREAT, label: "known_hosts")
        _ = Darwin.close(fd)
    }
}
