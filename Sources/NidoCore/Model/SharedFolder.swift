// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A folder of the Mac shown to a Linux guest in `/mnt/nido/<name>`.
///
/// Every shared folder of a VM goes through one VirtioFS device (tag `nido`, a
/// `VZMultipleDirectoryShare`), which the guest mounts on `/mnt/nido`: each folder is a
/// subdirectory named `name`. Read-only unless the user turns it off for that folder.
public struct SharedFolder: Codable, Equatable, Sendable {
    /// The subdirectory of `/mnt/nido` in the guest.
    public var name: String
    /// Absolute host path, as resolved by `validate` when the folder was added.
    public var hostPath: String
    public var readOnly: Bool

    public init(name: String, hostPath: String, readOnly: Bool = true) {
        self.name = name
        self.hostPath = hostPath
        self.readOnly = readOnly
    }

    /// The VirtioFS tag of the shared folders device.
    public static let tag = "nido"
    /// Where the guest mounts the device.
    public static let guestMountPoint = "/mnt/nido"

    public static let unitName = "nido-shares.service"
    public static let unitPath = "/etc/systemd/system/\(unitName)"

    /// Mounts the `nido` tag on `/mnt/nido` (`nosuid,nodev`; read-only folders are enforced by
    /// the Mac). A VM started without shared folders has no such tag: the `ExecCondition` skips
    /// the unit instead of failing (see `GuestSetup`). Nothing to run after the mount, but systemd
    /// refuses a service without `ExecStart`, hence `/bin/true`.
    public static let unitText = """
        [Unit]
        Description=Shared folders of the Mac (Nido)
        After=local-fs.target

        [Service]
        Type=oneshot
        RemainAfterExit=yes
        \(GuestSetup.mountCondition(tag: tag, mountPoint: guestMountPoint, options: "nosuid,nodev"))
        ExecStart=/bin/true

        [Install]
        WantedBy=multi-user.target
        """

    /// What the guest needs (cloud-init `write_files`).
    public static let guestFiles = [GuestFile(path: unitPath, content: unitText)]

    /// Run once in a guest created before M3a (its cloud-init did not set up the mount).
    public static let legacyGuestCommand = GuestSetup.legacyCommand(files: guestFiles, unitName: unitName)

    /// Where the folder shows up in a Linux guest: `guestPath(for: .linux)`.
    @available(*, deprecated, message: "use guestPath(for:)")
    public var guestPath: String { guestPath(for: .linux) }

    /// Where a macOS guest shows the folders of the automount device
    /// (`VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag`).
    public static let macGuestMountPoint = "/Volumes/My Shared Files"

    /// Where the folder shows up in a `guest` guest: `/mnt/nido/<name>` on Linux,
    /// `/Volumes/My Shared Files/<name>` on macOS.
    public func guestPath(for guest: GuestOS) -> String {
        switch guest {
        case .linux: "\(Self.guestMountPoint)/\(name)"
        case .macos: "\(Self.macGuestMountPoint)/\(name)"
        }
    }

    // MARK: - Names

    private static let namePattern = #"^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$"#

    /// `^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$`, otherwise `.invalidShareName`.
    public static func validateName(_ name: String) throws(NidoError) {
        guard name.range(of: namePattern, options: .regularExpression) != nil else {
            throw .invalidShareName(name)
        }
    }

    /// A valid name from the folder's last path component (characters outside the allowed set
    /// become `-`), made unique against `taken` (case-insensitive) with `-2`, `-3`…
    public static func defaultName(for url: URL, taken: [String]) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        var base = String(url.lastPathComponent.map { allowed.contains($0) ? $0 : "-" })
        while let first = base.first, !(first.isASCII && (first.isLetter || first.isNumber)) {
            base.removeFirst()
        }
        // A name made only of separators (e.g. non-ASCII letters) says nothing.
        if base.allSatisfy({ $0 == "-" || $0 == "." || $0 == "_" }) { base = L10n.string("folder") }
        base = String(base.prefix(56))
        let lowered = Set(taken.map { $0.lowercased() })
        var candidate = base
        var counter = 2
        while lowered.contains(candidate.lowercased()) {
            candidate = "\(base)-\(counter)"
            counter += 1
        }
        return candidate
    }

    // MARK: - Editing a list

    /// `folders` plus `folder`, after checking its name (valid, not taken ignoring case).
    public static func adding(_ folder: SharedFolder, to folders: [SharedFolder]) throws(NidoError) -> [SharedFolder] {
        try validateName(folder.name)
        guard !folders.contains(where: { $0.name.lowercased() == folder.name.lowercased() }) else {
            throw .shareNameTaken(folder.name)
        }
        return folders + [folder]
    }

    /// `folders` without the one called `name` (ignoring case), otherwise `.shareNotFound`.
    public static func removing(_ name: String, from folders: [SharedFolder]) throws(NidoError) -> [SharedFolder] {
        guard folders.contains(where: { $0.name.lowercased() == name.lowercased() }) else {
            throw .shareNotFound(name)
        }
        return folders.filter { $0.name.lowercased() != name.lowercased() }
    }

    /// `folders` with the read-only switch of `name` set to `readOnly`.
    public static func settingReadOnly(
        _ readOnly: Bool, for name: String, in folders: [SharedFolder]
    ) throws(NidoError) -> [SharedFolder] {
        guard let index = folders.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) else {
            throw .shareNotFound(name)
        }
        var result = folders
        result[index].readOnly = readOnly
        return result
    }

    // MARK: - Host paths

    /// Checks a host folder before it is shared (and again before every start) and returns its
    /// resolved URL.
    ///
    /// 1. The path must be absolute. It is resolved with `realpath` (symlinks, `.`, `..`): a
    ///    missing folder is `.sharedFolderMissing`; any other failure (permission, link loop, a
    ///    file in the middle) is a refusal that says so. It must be a directory.
    /// 2. Spellings `realpath` keeps are refused or folded: `/.nofollow`, `/.resolve`, `/.vol`
    ///    are refused; `/System/Volumes/Data/X` (the data volume's firmlinks) becomes `/X` when that
    ///    is the very same directory.
    /// 3. System areas are refused by prefix, after folding: `/System` and everything under it
    ///    (the home, the VMs and the cache all lie under `/System/Volumes/Data`, and an identity
    ///    walk from them never passes through `/System`), `/private` (the real `/tmp`, `/var`,
    ///    `/etc`: system and other processes' data) and `/dev`. Together with the `statfs`
    ///    mount-point rule (a volume root, `/` included), these prefix rules are the guard against
    ///    volume-level aliases: on an APFS volume group the system and data volumes cannot be told
    ///    apart reliably by `st_dev`.
    /// 4. The remaining rules compare identities (`st_dev`, `st_ino`) along the `openat(fd, "..")`
    ///    ancestry, never strings. Refused: the home itself; `~/Library` or anything inside it;
    ///    anything inside (or equal to) the VM root, the image cache or one of `alsoProtected` (by
    ///    default the standard VM root and image cache, whatever `paths` is); a folder that contains
    ///    the home, the VM root, the cache or `alsoProtected` (sharing it would expose them).
    ///    These checks fail closed: when an identity cannot be computed the folder is refused
    ///    ("impossibile verificare la cartella"). A protected folder that does not exist yet is
    ///    checked through its nearest existing parent.
    public static func validate(
        hostPath: String, paths: NidoPaths, imageCache: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        alsoProtected: [URL] = [NidoPaths.defaultRoot(), ImageStore.defaultCacheRoot()]
    ) throws(NidoError) -> URL {
        try validate(hostPath: hostPath, paths: paths, imageCache: imageCache, home: home,
                     alsoProtected: alsoProtected, ancestry: ancestry(of:))
    }

    /// `validate` with the identity walk injectable (tests: a walk that fails must refuse).
    static func validate(
        hostPath: String, paths: NidoPaths, imageCache: URL, home: URL, alsoProtected: [URL],
        ancestry: (String) -> [NodeID]?
    ) throws(NidoError) -> URL {
        guard hostPath.hasPrefix("/") else {
            throw .sharedFolderRefused(L10n.string("\(hostPath): an absolute path is needed"))
        }
        if hasAliasPrefix(hostPath) {
            throw .sharedFolderRefused(L10n.string("\(hostPath): special system path"))
        }
        var resolved = try resolve(hostPath)
        if hasAliasPrefix(resolved) {
            throw .sharedFolderRefused(L10n.string("\(hostPath): special system path"))
        }
        var info = stat()
        guard stat(resolved, &info) == 0 else { throw unverifiable(hostPath) }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw .sharedFolderRefused(L10n.string("\(hostPath): not a folder"))
        }
        let me = NodeID(dev: info.st_dev, ino: info.st_ino)
        resolved = try canonicalSystemVolumePath(resolved, id: me, original: hostPath)
        if resolved == "/" {
            throw .sharedFolderRefused(L10n.string("\(hostPath): the disk’s root can’t be shared"))
        }
        if let refusal = systemArea(resolved, shown: hostPath) {
            throw .sharedFolderRefused(refusal)
        }
        if isMountPoint(resolved) {
            throw .sharedFolderRefused(L10n.string("\(hostPath): a whole volume can’t be shared"))
        }
        guard let chain = ancestry(resolved), chain.first == me else { throw unverifiable(hostPath) }
        // Its parent on another device, or its own parent: a volume root `statfs` did not report.
        if chain.count == 1 || chain[1].dev != me.dev {
            throw .sharedFolderRefused(L10n.string("\(hostPath): a whole volume can’t be shared"))
        }

        let homeLine = try protectedLine(home, ancestry: ancestry, original: hostPath)
        if homeLine.exists, homeLine.chain.first == me {
            throw .sharedFolderRefused(L10n.string("\(hostPath): the whole Home folder can’t be shared"))
        }
        let libraryLine = try protectedLine(
            home.appendingPathComponent("Library"), ancestry: ancestry, original: hostPath)
        if libraryLine.exists, let library = libraryLine.chain.first, chain.contains(library) {
            throw .sharedFolderRefused(L10n.string("\(hostPath): ~/Library and its contents can’t be shared"))
        }
        // Each protected folder with the refusals for a folder inside it and for one containing it.
        let protected: [(url: URL, inside: String, contains: String)] = [
            (paths.root, L10n.string("\(hostPath): it’s inside Nido’s VM folder"),
             L10n.string("\(hostPath): it contains Nido’s VM folder")),
            (imageCache, L10n.string("\(hostPath): it’s inside Nido’s image cache"),
             L10n.string("\(hostPath): it contains Nido’s image cache")),
        ] + alsoProtected.map {
            ($0, L10n.string("\(hostPath): it’s inside a Nido folder"), L10n.string("\(hostPath): it contains a Nido folder"))
        }
        for (url, inside, contains) in protected {
            let line = try protectedLine(url, ancestry: ancestry, original: hostPath)
            if line.exists, let id = line.chain.first, chain.contains(id) {
                throw .sharedFolderRefused(inside)
            }
            // An existing protected folder: its strict ancestors. A missing one: its nearest
            // existing parent counts too (the folder would appear inside it).
            if (line.exists ? line.chain.dropFirst() : line.chain[...]).contains(me) {
                throw .sharedFolderRefused(contains)
            }
        }
        if (homeLine.exists ? homeLine.chain.dropFirst() : homeLine.chain[...]).contains(me) {
            throw .sharedFolderRefused(L10n.string("\(hostPath): it contains the Home folder"))
        }
        return URL(fileURLWithPath: resolved, isDirectory: true)
    }

    private static func unverifiable(_ path: String) -> NidoError {
        .sharedFolderRefused(L10n.string("\(path): can’t check the folder"))
    }

    /// `realpath`, with its failure turned into the right error: ENOENT → `.sharedFolderMissing`;
    /// anything else → a refusal naming the cause.
    private static func resolve(_ path: String) throws(NidoError) -> String {
        guard let resolved = Darwin.realpath(path, nil) else {
            let err = errno
            switch err {
            case ENOENT: throw .sharedFolderMissing(path)
            case EACCES: throw .sharedFolderRefused(L10n.string("\(path): permission denied on a folder in the path"))
            case ELOOP: throw .sharedFolderRefused(L10n.string("\(path): too many symbolic links"))
            case ENOTDIR: throw .sharedFolderRefused(L10n.string("\(path): an item in the path isn’t a folder"))
            default:
                throw .sharedFolderRefused("\(path): \(String(cString: strerror(err)))")
            }
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The identity line of a protected folder: its ancestry when it exists; when it does not
    /// (ENOENT), the ancestry of its nearest existing parent with `exists == false`. Any other
    /// failure refuses the share (fail closed).
    private static func protectedLine(
        _ url: URL, ancestry: (String) -> [NodeID]?, original: String
    ) throws(NidoError) -> (exists: Bool, chain: [NodeID]) {
        var path = url.standardizedFileURL.path
        var exists = true
        for _ in 0..<256 {
            var info = stat()
            if stat(path, &info) == 0 {
                guard let chain = ancestry(path), !chain.isEmpty else { throw unverifiable(original) }
                return (exists, chain)
            }
            guard errno == ENOENT, path != "/" else { throw unverifiable(original) }
            exists = false
            path = (path as NSString).deletingLastPathComponent
        }
        throw unverifiable(original)
    }

    /// The refusal of `shown` when its resolved `path` is a system area nobody shares, or nil.
    private static func systemArea(_ path: String, shown: String) -> String? {
        let lower = path.lowercased()
        func under(_ prefix: String) -> Bool { lower == prefix || lower.hasPrefix(prefix + "/") }
        if under("/system") { return L10n.string("\(shown): system folder (/System)") }
        if under("/private") { return L10n.string("\(shown): system folder (/private: /tmp, /var, /etc)") }
        if under("/dev") { return L10n.string("\(shown): devices folder (/dev)") }
        return nil
    }

    /// Prefixes that name a file by another route than its path (`realpath` keeps them).
    private static func hasAliasPrefix(_ path: String) -> Bool {
        let lower = path.lowercased()
        return ["/.nofollow", "/.resolve", "/.vol"].contains { lower == $0 || lower.hasPrefix($0 + "/") }
    }

    /// `/System/Volumes/Data/X` → `/X` when both are the same directory (the data volume's
    /// firmlinks); any other path under `/System/Volumes` is refused. Other paths are unchanged.
    private static func canonicalSystemVolumePath(
        _ path: String, id: NodeID, original: String
    ) throws(NidoError) -> String {
        let lower = path.lowercased()
        guard lower == "/system/volumes" || lower.hasPrefix("/system/volumes/") else { return path }
        let data = "/system/volumes/data"
        if lower.hasPrefix(data + "/") {
            let short = String(path.dropFirst(data.count))
            if let shortResolved = realPath(short), !shortResolved.lowercased().hasPrefix("/system/volumes"),
               nodeID(shortResolved) == id {
                return shortResolved
            }
        }
        throw .sharedFolderRefused(L10n.string("\(original): a path inside a system volume"))
    }

    private static func isMountPoint(_ path: String) -> Bool {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return false }
        let mountedOn = withUnsafeBytes(of: fs.f_mntonname) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return mountedOn == path
    }

    struct NodeID: Hashable {
        let dev: dev_t
        let ino: ino_t
    }

    private static func nodeID(_ path: String) -> NodeID? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return NodeID(dev: info.st_dev, ino: info.st_ino)
    }

    /// The directory at `path` and every directory above it, by identity, walking `..` from an
    /// open descriptor (so it follows the file system, not the spelling of the path): `[self,
    /// parent, …, /]`. nil when `path` is not a directory that can be opened.
    static func ancestry(of path: String) -> [NodeID]? {
        var fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var chain: [NodeID] = []
        defer { _ = Darwin.close(fd) }
        for _ in 0..<4096 {
            var info = stat()
            guard fstat(fd, &info) == 0 else { return nil }
            let id = NodeID(dev: info.st_dev, ino: info.st_ino)
            if chain.last == id { break }  // `/` is its own parent
            chain.append(id)
            let parent = openat(fd, "..", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard parent >= 0 else { return nil }
            _ = Darwin.close(fd)
            fd = parent
        }
        return chain
    }

    /// `realpath(3)`: absolute, without symlinks, `.` or `..`; nil when the path does not exist.
    private static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
