// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A `.nidovm` bundle directory. See `docs/BUNDLE-FORMAT.md`.
public struct VMBundle: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public var configURL: URL { url.appendingPathComponent("config.json") }
    public var diskURL: URL { url.appendingPathComponent("disk.img") }
    public var nvramURL: URL { url.appendingPathComponent("nvram.efi") }
    /// Linux: `VZGenericMachineIdentifier.dataRepresentation`; macOS: `VZMacMachineIdentifier.dataRepresentation`.
    public var machineIdentifierURL: URL { url.appendingPathComponent("machine-id.bin") }
    /// macOS only: the `VZMacAuxiliaryStorage` of the guest.
    public var auxiliaryStorageURL: URL { url.appendingPathComponent("auxiliary-storage.img") }
    /// macOS only: `VZMacHardwareModel.dataRepresentation` from the IPSW the VM was installed from.
    public var hardwareModelURL: URL { url.appendingPathComponent("hardware-model.bin") }
    public var seedURL: URL { url.appendingPathComponent("seed.iso") }
    public var consoleLogURL: URL { url.appendingPathComponent("console.log") }
    public var knownHostsURL: URL { url.appendingPathComponent("known_hosts") }
    /// macOS only: the SSH public key chosen at creation (0600), shown in the "Accesso da
    /// terminale" panel for the user to authorize in the guest. Not part of the machine.
    public var authorizedKeyURL: URL { url.appendingPathComponent("authorized_key.pub") }
    /// Tokens the AI bridge charged today (`AIBridgeLimiter`).
    public var aiBridgeUsageURL: URL { url.appendingPathComponent("ai-bridge-usage.json") }
    /// Content-free log of the AI bridge calls (`AIBridgeLog`); rotated to `ai-bridge.log.1`.
    public var aiBridgeLogURL: URL { url.appendingPathComponent("ai-bridge.log") }
    /// The egress allowlist of the controlled network (`EgressPolicyStore`).
    public var egressPolicyURL: URL { url.appendingPathComponent("egress.json") }
    /// The controlled network's content-free log of blocks, cuts and summaries (`EgressLog`),
    /// rotated into `egress.log.1`.
    public var egressLogURL: URL { url.appendingPathComponent("egress.log") }
    /// The allowed flows' lines of `EgressLog`, rotated apart (`egress-flows.log.1`) so a churn of
    /// flows never evicts a block.
    public var egressFlowLogURL: URL { url.appendingPathComponent("egress-flows.log") }
    /// `flock(2)` that serializes every read-modify-write of `egress.json`
    /// (`EgressPolicyStore.update`).
    public var egressLockURL: URL { url.appendingPathComponent(".egress.lock") }
    /// Controlled network: `{"port": <UInt16>, "pid": <Int32>}` (0600), the loopback port
    /// `gvproxy` forwards to the guest's SSH and the PID of that `gvproxy` (`GvproxyProcess`).
    /// Removed when `gvproxy` is stopped.
    public var sshForwardURL: URL { url.appendingPathComponent("ssh-forward.json") }
    /// Controlled network: what `gvproxy` prints (0600, emptied at the next start once over
    /// 1 MiB). Never traffic content.
    public var gvproxyLogURL: URL { url.appendingPathComponent("gvproxy.log") }
    public var lockURL: URL { url.appendingPathComponent(".lock") }
    /// `flock(2)` that serializes every write of `config.json` (`withConfigLock`).
    public var configLockURL: URL { url.appendingPathComponent(".config.lock") }
    /// The saved machine state of a suspended VM (or of a restored snapshot taken while running).
    public var stateURL: URL { url.appendingPathComponent("state.vzvmsave") }
    /// What a `nido start` process answers to `nido stop --suspend` when it cannot suspend
    /// (see `VMControl.writeSuspendResult`).
    public var suspendResultURL: URL { url.appendingPathComponent(".suspend-result") }
    /// `snapshots/<uuid>/`, see `SnapshotStore`.
    public var snapshotsURL: URL { url.appendingPathComponent("snapshots", isDirectory: true) }

    private static let suffix = ".nidovm"

    /// Creates a new bundle (0700) holding `config.json` (0600).
    /// The name collision check is case-insensitive even on case-sensitive volumes.
    public static func create(config: VMConfig, paths: NidoPaths) throws -> VMBundle {
        let fm = FileManager.default
        try paths.ensureRoot()
        let wanted = (config.name.rawValue + suffix).lowercased()
        let existing = try fm.contentsOfDirectory(atPath: paths.root.path)
        if existing.contains(where: { $0.lowercased() == wanted }) {
            throw NidoError.alreadyExists(config.name.rawValue)
        }
        let bundle = VMBundle(url: paths.bundleURL(for: config.name))
        try fm.createDirectory(
            at: bundle.url, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bundle.url.path)
        do {
            // A new bundle: nobody else can write its config yet, so no lock file is made.
            try bundle.writeConfigUnlocked(config)
        } catch {
            try? fm.removeItem(at: bundle.url)
            throw error
        }
        return bundle
    }

    /// Opens an existing bundle, rejecting symlinks and paths escaping the root.
    public static func open(_ name: VMName, paths: NidoPaths) throws -> VMBundle {
        let fm = FileManager.default
        let wanted = (name.rawValue + suffix).lowercased()
        let entries = (try? fm.contentsOfDirectory(atPath: paths.root.path)) ?? []
        let exact = name.rawValue + suffix
        guard let entry = entries.contains(exact) ? exact : entries.first(where: { $0.lowercased() == wanted })
        else { throw NidoError.notFound(name.rawValue) }
        let url = paths.root.appendingPathComponent(entry, isDirectory: true)
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try fm.attributesOfItem(atPath: url.path)  // lstat: does not follow symlinks
        } catch {
            throw NidoError.notFound(name.rawValue)
        }
        guard (attrs[.type] as? FileAttributeType) == .typeDirectory else {
            throw NidoError.unsafePath(name.rawValue)
        }
        guard isInside(url, root: paths.root) else { throw NidoError.unsafePath(name.rawValue) }
        return VMBundle(url: url)
    }

    /// Bundles in the root (`*.nidovm` directories containing a `config.json` entry), sorted by name.
    public static func list(paths: NidoPaths) throws -> [VMBundle] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.root.path) else { return [] }
        let names = try fm.contentsOfDirectory(atPath: paths.root.path)
        var result: [VMBundle] = []
        for entry in names where entry.lowercased().hasSuffix(suffix) {
            let url = paths.root.appendingPathComponent(entry, isDirectory: true)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                (attrs[.type] as? FileAttributeType) == .typeDirectory,
                isInside(url, root: paths.root)
            else { continue }
            let bundle = VMBundle(url: url)
            // lstat: a symlinked config.json still marks a bundle, but it is never followed
            // (`readConfig` refuses it).
            var info = stat()
            guard lstat(bundle.configURL.path, &info) == 0 else { continue }
            result.append(bundle)
        }
        return result.sorted {
            $0.url.lastPathComponent.lowercased() < $1.url.lastPathComponent.lowercased()
        }
    }

    /// Largest accepted `config.json`.
    public static let maxConfigSize = 64 * 1024

    /// Most `authorized_key.pub` may hold: an OpenSSH public key is far smaller.
    public static let maxAuthorizedKeySize = 16 * 1024

    /// The public key in `authorized_key.pub` (macOS VMs), without its trailing newlines; nil
    /// when the file does not exist. Opened through `PrivateFile` (no symlink, a regular file of
    /// this user with one link); a file over `maxAuthorizedKeySize` is refused too
    /// (`.unsafePath("authorized_key.pub")`).
    public func readAuthorizedKey() throws -> String? {
        let label = authorizedKeyURL.lastPathComponent
        let fd: Int32
        do {
            fd = try PrivateFile.open(authorizedKeyURL, flags: O_RDONLY, label: label)
        } catch let error as POSIXError where error.code == .ENOENT {
            return nil
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let data = try handle.read(upToCount: Self.maxAuthorizedKeySize + 1) ?? Data()
        guard data.count <= Self.maxAuthorizedKeySize else { throw NidoError.unsafePath(label) }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    /// Reads `config.json` without following symlinks: it must be a regular file of at most
    /// `maxConfigSize` bytes, otherwise `.unsafePath(<path>)`.
    public func readConfig() throws -> VMConfig {
        let path = configURL.path
        // O_NONBLOCK: never hang on a FIFO; regular-file reads are unaffected.
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            let err = errno
            if err == ELOOP { throw NidoError.unsafePath(path) }
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
            info.st_size <= Self.maxConfigSize
        else { throw NidoError.unsafePath(path) }
        let data = try handle.read(upToCount: Self.maxConfigSize + 1) ?? Data()
        guard data.count <= Self.maxConfigSize else { throw NidoError.unsafePath(path) }
        return try VMConfig.decode(data)
    }

    /// True when the VM looks suspended: `config` (this bundle's) has a `suspendedConfigHash` and
    /// `state.vzvmsave` is a non-empty regular file of this user with a single link (checked with
    /// `lstat`). Whether the state can really be resumed is decided at start (`SuspendedState.boot`).
    public func hasSuspendedState(_ config: VMConfig) -> Bool {
        config.suspendedConfigHash != nil && stateFileLooksValid()
    }

    /// `state.vzvmsave` is a non-empty regular file of this user with a single link (`lstat`).
    public func stateFileLooksValid() -> Bool {
        var info = stat()
        return lstat(stateURL.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
            && info.st_uid == getuid() && info.st_nlink == 1 && info.st_size > 0
    }

    /// Files the virtual machine of `guest` is built from; see `verifyInnerFiles(for:)`.
    /// Linux: config, disk, EFI variable store, machine identifier, cloud-init seed. macOS: config,
    /// disk, auxiliary storage, hardware model, machine identifier (no seed, no EFI store).
    /// `state.vzvmsave` is included only when an entry of that name exists (of any type: a symlink
    /// there is caught).
    public func innerFileURLs(for guest: GuestOS) -> [URL] {
        var urls: [URL]
        switch guest {
        case .linux: urls = [configURL, diskURL, nvramURL, machineIdentifierURL, seedURL]
        case .macos: urls = [configURL, diskURL, auxiliaryStorageURL, hardwareModelURL, machineIdentifierURL]
        }
        var info = stat()
        if lstat(stateURL.path, &info) == 0 { urls.append(stateURL) }
        return urls
    }

    /// Checks every file in `innerFileURLs(for: guest)` with `lstat`: each must be a regular file
    /// (not a symlink), owned by the current user, with a single hard link. Otherwise
    /// `.unsafePath(<path>)`. Call before handing the bundle's paths to Virtualization.framework.
    /// There is no default guest: every caller passes the one of the bundle's config, so a macOS
    /// bundle is never checked (or copied) as if it were Linux.
    public func verifyInnerFiles(for guest: GuestOS) throws {
        for url in innerFileURLs(for: guest) {
            var info = stat()
            guard lstat(url.path, &info) == 0,
                (info.st_mode & S_IFMT) == S_IFREG,
                info.st_uid == getuid(),
                info.st_nlink == 1
            else { throw NidoError.unsafePath(url.path) }
        }
    }

    /// Read-modify-write of `config.json` that changes only what `edit` changes, under the
    /// config lock (`withConfigLock`): every other writer of this bundle, in this process or
    /// another (app, `nido`), waits until the write is done, so no change is lost. The bundle
    /// lock does not serialize this: while a VM runs, its process holds the `BundleLock` and still
    /// writes the config (live shared folders, AI bridge policy, suspend). `edit` must be short
    /// and must not write the config itself or take a `BundleLock` (see `withConfigLock`).
    @discardableResult
    public func updateConfig(_ edit: (inout VMConfig) throws -> Void) throws -> VMConfig {
        try withConfigLock {
            var config = try readConfig()
            try edit(&config)
            try writeConfigUnlocked(config)
            return config
        }
    }

    /// Atomic write: temp file in the bundle created 0600, then renamed over `config.json`.
    /// Always writes the current schema: a schema 1 config read earlier is migrated here (and
    /// only here: reading never rewrites the file). Takes the config lock; prefer
    /// `updateConfig`, which also keeps what other writers changed.
    public func writeConfig(_ c: VMConfig) throws {
        try withConfigLock { try writeConfigUnlocked(c) }
    }

    /// Runs `body` holding `flock(LOCK_EX)` on `<bundle>/.config.lock` (0600, opened with
    /// `PrivateFile`: a symlink or a file of someone else is refused with `.unsafePath`). Each call
    /// opens its own descriptor, so it excludes other threads of this process too (`flock` locks
    /// belong to the open file description). The file is never deleted.
    ///
    /// Lock order: `BundleLock` (`.lock`) first, then this lock, never the other way round. This
    /// lock is a leaf: `body` must not take a `BundleLock`, call `updateConfig`/`writeConfig`
    /// (it is not reentrant) or wait for anything slow.
    func withConfigLock<T>(_ body: () throws -> T) throws -> T {
        try withFileLock(configLockURL, body)
    }

    /// Runs `body` holding `flock(LOCK_EX)` on `lockURL` (0600, opened with `PrivateFile`), a
    /// file that is never deleted. Each call opens its own descriptor, so threads of this process
    /// exclude each other too. Not reentrant.
    func withFileLock<T>(_ lockURL: URL, _ body: () throws -> T) throws -> T {
        let fd = try PrivateFile.open(lockURL, flags: O_RDWR | O_CREAT, label: lockURL.path)
        defer { _ = Darwin.close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        return try body()
    }

    /// `writeConfig` without the config lock: for a bundle nobody else can see yet, or under
    /// `withConfigLock`.
    func writeConfigUnlocked(_ c: VMConfig) throws {
        var current = c
        current.schemaVersion = VMConfig.currentSchemaVersion
        let data = try current.encoded()
        let tmp = url.appendingPathComponent(".config.json.\(UUID().uuidString).tmp")
        let fd = Darwin.open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var fdOpen = true
        do {
            try data.withUnsafeBytes { buf in
                var offset = 0
                while offset < buf.count {
                    let n = Darwin.write(fd, buf.baseAddress! + offset, buf.count - offset)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    offset += n
                }
            }
            guard fchmod(fd, 0o600) == 0, fsync(fd) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            fdOpen = false  // close exactly once, whatever its result
            guard Darwin.close(fd) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard Darwin.rename(tmp.path, configURL.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            if fdOpen { _ = Darwin.close(fd) }
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    /// Deletes the bundle directory; refuses to follow a symlink.
    public func remove() throws {
        let fm = FileManager.default
        let attrs = try fm.attributesOfItem(atPath: url.path)
        guard (attrs[.type] as? FileAttributeType) == .typeDirectory else {
            throw NidoError.unsafePath(url.lastPathComponent.replacingOccurrences(of: Self.suffix, with: ""))
        }
        try fm.removeItem(at: url)
    }

    /// Atomically renames the bundle directory to `<root>/.<name>.deleting-<uuid>` (same
    /// directory, so `rename(2)` never crosses filesystems) and returns the new URL.
    /// The tombstone has no `.nidovm` suffix, so `list` and `open` ignore it.
    /// Refuses a bundle path that is not a real directory.
    public func moveToTombstone() throws -> URL {
        let name = url.lastPathComponent.replacingOccurrences(of: Self.suffix, with: "", options: [.anchored, .backwards, .caseInsensitive])
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw NidoError.unsafePath(name)
        }
        let tombstone = url.deletingLastPathComponent()
            .appendingPathComponent(".\(name).deleting-\(UUID().uuidString)", isDirectory: true)
        guard Darwin.rename(url.path, tombstone.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return tombstone
    }

    /// Recursively removes a tombstone made by `moveToTombstone()`; refuses a symlink.
    public static func removeTombstone(at tombstone: URL) throws {
        var info = stat()
        guard lstat(tombstone.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw NidoError.unsafePath(tombstone.path)
        }
        try FileManager.default.removeItem(at: tombstone)
    }

    /// Tombstones older than this are removed by `sweepOrphanTombstones`.
    public static let tombstoneMaxAge: TimeInterval = 3600

    /// A `.creating-<uuid>` directory whose lock is free is removed once nothing in it changed for
    /// this long (`sweepOrphanTombstones`).
    public static let creatingUnlockedMaxAge: TimeInterval = 120

    /// Removes tombstones left behind by an interrupted delete: entries named exactly like
    /// `moveToTombstone()` output (`.<name>.deleting-<uuid>`) whose change time is more than
    /// `tombstoneMaxAge` before `now`; also the temporary directories of an interrupted clone
    /// (`.<name>.cloning-<uuid>`, `VMCloner`) or macOS installation (`.creating-<uuid>`,
    /// `MacInstaller`) when neither they nor any entry in them changed in that time. A
    /// `.creating-<uuid>` directory whose `.lock` is held (an installation still running, here or
    /// in another process, maybe paused by a sleeping Mac) is never removed; with the lock free it
    /// goes after `creatingUnlockedMaxAge` instead of the hour. Anything else in the root is left
    /// alone.
    /// The age is the `st_ctime` of the entry (`changeTime`, injectable for tests): `rename(2)`
    /// updates it, so it reflects when the bundle was tombstoned, whereas the directory's
    /// mtime/birthtime do not and could make an in-progress delete look old.
    /// Best effort: errors are ignored.
    public static func sweepOrphanTombstones(
        paths: NidoPaths, now: Date = Date(),
        changeTime: (URL) -> Date? = VMBundle.statChangeTime
    ) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: paths.root.path)
        else { return }
        for entry in entries {
            let url = paths.root.appendingPathComponent(entry, isDirectory: true)
            let changed: Date?
            if isTombstoneName(entry) {
                changed = changeTime(url)
            } else if isCreatingName(entry) {
                // A running installation holds the lock: never removed. Free lock: the installation
                // crashed (a large disk image must not stay hidden for an hour); the short age only
                // covers the moment between `mkdir` and taking the lock.
                if BundleLock.holder(VMBundle(url: url)) != nil { continue }
                let inside = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
                    .compactMap { changeTime(url.appendingPathComponent($0)) }
                guard let changed = ([changeTime(url)].compactMap { $0 } + inside).max(),
                    now.timeIntervalSince(changed) > creatingUnlockedMaxAge
                else { continue }
                try? removeTombstone(at: url)
                continue
            } else if isCloningName(entry) {
                // A clone still copying (a slow copy fallback) changes the file it writes, not
                // its directory: the newest change inside counts.
                let inside = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
                    .compactMap { changeTime(url.appendingPathComponent($0)) }
                changed = ([changeTime(url)].compactMap { $0 } + inside).max()
            } else {
                continue
            }
            guard let changed, now.timeIntervalSince(changed) > tombstoneMaxAge else { continue }
            try? removeTombstone(at: url)
        }
    }

    /// `st_ctime` from `lstat` (does not follow symlinks).
    public static func statChangeTime(_ url: URL) -> Date? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_ctimespec.tv_sec)
            + TimeInterval(info.st_ctimespec.tv_nsec) / 1e9)
    }

    /// `.<name>.cloning-<uuid>`: the temporary directory of a clone (`VMCloner`).
    private static func isCloningName(_ entry: String) -> Bool {
        guard entry.hasPrefix("."), let marker = entry.range(of: VMCloner.cloningInfix, options: .backwards)
        else { return false }
        let name = entry[entry.index(after: entry.startIndex)..<marker.lowerBound]
        return !name.isEmpty && UUID(uuidString: String(entry[marker.upperBound...])) != nil
    }

    /// `.creating-<uuid>`: the staging directory of a macOS installation (`MacInstaller`).
    static func isCreatingName(_ entry: String) -> Bool {
        guard entry.hasPrefix(MacInstaller.creatingPrefix) else { return false }
        return UUID(uuidString: String(entry.dropFirst(MacInstaller.creatingPrefix.count))) != nil
    }

    private static func isTombstoneName(_ entry: String) -> Bool {
        guard entry.hasPrefix("."), let marker = entry.range(of: ".deleting-", options: .backwards)
        else { return false }
        let name = entry[entry.index(after: entry.startIndex)..<marker.lowerBound]
        return !name.isEmpty && UUID(uuidString: String(entry[marker.upperBound...])) != nil
    }

    /// Directory name without the `.nidovm` suffix: the fallback name when `config.json`
    /// cannot be read.
    public var displayName: String {
        String(url.lastPathComponent.dropLast(Self.suffix.count))
    }

    private static func isInside(_ url: URL, root: URL) -> Bool {
        let r = root.resolvingSymlinksInPath().standardizedFileURL.path
        let p = url.resolvingSymlinksInPath().standardizedFileURL.path
        return p.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }
}
