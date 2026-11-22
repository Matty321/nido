// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation

/// Why a transfer was refused or failed: `badRequest` for what the agent asked (a bad path, a
/// missing file, a symbolic link, a folder where a file was expected, a file too large),
/// `internalError` for the rest. Messages are read by the agent model and stay in English.
public struct TransferError: Error, Equatable, Sendable, CustomStringConvertible {
    public var code: AgentErrorCode
    public var message: String

    public init(_ code: AgentErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { message }
}

/// The one guest folder files travel in and out of (`~/NidoTransfer`): paths are relative to
/// it, and nothing outside it is ever read, written or listed.
///
/// Every component is opened with `openat` and `O_NOFOLLOW` from the descriptor of the folder
/// above it, so a symbolic link (to `~/.ssh`, to `/etc`, ...) is never followed, wherever it
/// sits, and a component swapped for a link meanwhile is not followed either. Only regular files
/// are read or written; a write goes to a temporary name in the same folder and is renamed over
/// the target, so a reader never sees half a file and a failure leaves nothing behind.
public struct TransferFolder: Sendable {
    public static let maxComponents = 16
    public static let maxPathBytes = 1024
    /// The longest name a component may have (`NAME_MAX`).
    public static let maxNameBytes = 255
    /// Temporary files of a write in progress start with this.
    static let tempPrefix = ".nido-transfer-"

    /// The folder itself: created (0700) on first use; refused when it is a symbolic link or not
    /// a folder owned by this account. The path above it is the account's home and is trusted.
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `~/NidoTransfer` of the account Nido Agent runs as.
    public static var userFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("NidoTransfer", isDirectory: true)
    }

    // MARK: - Paths

    /// The components of `path`, relative to the folder. Refused: empty, absolute, a NUL byte,
    /// an empty, `.` or `..` component, more than 16 components, more than 1024 bytes, a name
    /// longer than 255 bytes. Split on the `/` byte, never on characters: a `/` followed by a
    /// combining mark still separates two components.
    public static func validate(_ path: String) throws -> [String] {
        guard !path.isEmpty else { throw bad("the path is empty: give a path relative to NidoTransfer") }
        let bytes = Array(path.utf8)
        guard bytes.count <= maxPathBytes else { throw bad("the path is longer than \(maxPathBytes) bytes") }
        guard !bytes.contains(0) else { throw bad("the path contains a NUL byte") }
        guard bytes.first != UInt8(ascii: "/") else {
            throw bad("the path must be relative to NidoTransfer, not absolute")
        }
        let parts = bytes.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
        guard parts.count <= maxComponents else { throw bad("the path has more than \(maxComponents) components") }
        for part in parts {
            if part.isEmpty || part.elementsEqual([UInt8(ascii: ".")]) || part.elementsEqual([UInt8(ascii: "."), UInt8(ascii: ".")]) {
                throw bad("the path may not have an empty, '.' or '..' component")
            }
            guard part.count <= maxNameBytes else { throw bad("a name in the path is longer than \(maxNameBytes) bytes") }
        }
        return parts.map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: - Operations

    /// Writes `data` to `path`, creating the folders above it (0700) and replacing a regular file
    /// there (keeping its permissions; a new file is 0600). Refuses a link, a folder or another
    /// special file at `path` or above it.
    public func write(_ data: Data, to path: String) throws {
        let components = try Self.validate(path)
        guard data.count <= AgentProtocol.maxTransferBytes else {
            throw Self.bad("the file is larger than \(AgentProtocol.maxTransferBytes) bytes (16 MiB)")
        }
        let rootFD = try openRoot()
        defer { close(rootFD) }
        let dir = try openFolder(components.dropLast(), from: rootFD, create: true)
        defer { close(dir) }
        let name = components[components.count - 1]

        Self.removeStaleTemps(in: dir)
        let temp = Self.tempPrefix + UUID().uuidString + ".tmp"
        let fd = openat(dir, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw Self.internalFailure("could not create a file in '\(Self.parent(of: components))'", errno)
        }
        var renamed = false
        defer { if !renamed { unlinkat(dir, temp, 0) } }
        do {
            try Self.writeAll(data, to: fd)
            // What is there now decides: a regular file is replaced (its permissions kept),
            // anything else refused. A link swapped in after this check is replaced by the rename,
            // never followed.
            switch Self.kind(of: name, in: dir) {
            case .missing:
                break
            case .file(let mode):
                guard fchmod(fd, mode & 0o777) == 0 else {
                    throw Self.internalFailure("could not set the permissions of '\(path)'", errno)
                }
            case .other(let kind):
                throw Self.refusal(kind, path, expected: .file)
            case .unreadable(let err):
                throw Self.internalFailure("could not look at '\(path)'", err)
            }
            guard fsync(fd) == 0 else { throw Self.internalFailure("could not write '\(path)'", errno) }
        } catch {
            close(fd)
            throw error
        }
        guard close(fd) == 0 else { throw Self.internalFailure("could not write '\(path)'", errno) }
        guard renameat(dir, temp, dir, name) == 0 else {
            throw Self.internalFailure("could not replace '\(path)'", errno)
        }
        renamed = true
    }

    /// Temporary files older than this are leftovers (a crash, a forced stop) and are removed.
    static let staleTempAge: TimeInterval = 600

    /// Best-effort: removes the regular files named like a temporary file in `dir` that were last
    /// modified more than `staleTempAge` ago. Looks at each name without following a link and
    /// unlinks through the descriptor; a failure is ignored.
    static func removeStaleTemps(in dir: Int32, now: Date = Date()) {
        let copy = dup(dir)
        guard copy >= 0 else { return }
        guard let stream = fdopendir(copy) else {
            close(copy)
            return
        }
        defer { closedir(stream) }
        let fd = dirfd(stream)
        rewinddir(stream)
        var stale: [String] = []
        while let item = readdir(stream) {
            let length = Int(item.pointee.d_namlen)
            let name = withUnsafeBytes(of: item.pointee.d_name) {
                String(bytes: $0.prefix(length), encoding: .utf8)
            }
            guard let name, name.hasPrefix(tempPrefix) else { continue }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
            let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
            if now.timeIntervalSince1970 - modified > staleTempAge { stale.append(name) }
        }
        for name in stale { _ = unlinkat(fd, name, 0) }
    }

    /// The regular file at `path`, refused when it is larger than `maxBytes`.
    public func read(_ path: String, maxBytes: Int) throws -> Data {
        let components = try Self.validate(path)
        let rootFD = try openRoot()
        defer { close(rootFD) }
        let dir = try openFolder(components.dropLast(), from: rootFD, create: false)
        defer { close(dir) }
        let name = components[components.count - 1]

        // O_NONBLOCK: a FIFO opens at once (and is then refused) instead of waiting for a writer.
        let fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Self.openFailure(errno, name, in: dir, path, expected: .file) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Self.internalFailure("could not look at '\(path)'", errno) }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw Self.refusal(info.st_mode & S_IFMT, path, expected: .file)
        }
        guard info.st_size <= maxBytes else { throw Self.tooLarge(path, maxBytes) }

        // Read at most one byte more than allowed: the file may have grown since `fstat`.
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while data.count <= maxBytes {
            let wanted = min(buffer.count, maxBytes + 1 - data.count)
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, wanted) }
            if n < 0 {
                if errno == EINTR { continue }
                throw Self.internalFailure("could not read '\(path)'", errno)
            }
            if n == 0 { break }
            data.append(contentsOf: buffer[0..<n])
        }
        guard data.count <= maxBytes else { throw Self.tooLarge(path, maxBytes) }
        return data
    }

    /// One level of the folder at `path` (the top when nil): regular files and folders, newest
    /// first (then by name), at most `limit` of them; `truncated` when there were more. Symbolic
    /// links and other special files are left out, as are names that are not valid UTF-8.
    public func list(_ path: String?, limit: Int) throws -> (entries: [TransferEntry], truncated: Bool) {
        let components = try path.map(Self.validate) ?? []
        let rootFD = try openRoot()
        defer { close(rootFD) }
        let dir = try openFolder(components[...], from: rootFD, create: false)
        guard let stream = fdopendir(dir) else {
            let err = errno
            close(dir)
            throw Self.internalFailure("could not list '\(path ?? ".")'", err)
        }
        defer { closedir(stream) }
        let fd = dirfd(stream)

        var entries: [TransferEntry] = []
        while true {
            errno = 0
            guard let item = readdir(stream) else {
                if errno != 0 { throw Self.internalFailure("could not list '\(path ?? ".")'", errno) }
                break
            }
            let length = Int(item.pointee.d_namlen)
            let name = withUnsafeBytes(of: item.pointee.d_name) {
                String(bytes: $0.prefix(length), encoding: .utf8)
            }
            guard let name, name != ".", name != ".." else { continue }
            // Leftovers of an interrupted write are not the agent's files.
            if name.hasPrefix(Self.tempPrefix) { continue }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)
                + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
            switch info.st_mode & S_IFMT {
            case S_IFREG:
                entries.append(TransferEntry(name: name, kind: TransferEntry.file, size: Int(info.st_size), modified: modified))
            case S_IFDIR:
                entries.append(TransferEntry(name: name, kind: TransferEntry.folder, size: 0, modified: modified))
            default:
                continue
            }
        }
        entries.sort { $0.modified != $1.modified ? $0.modified > $1.modified : $0.name < $1.name }
        let limit = max(0, limit)
        return (Array(entries.prefix(limit)), entries.count > limit)
    }

    // MARK: - Descriptors

    /// The folder's descriptor, creating it (0700) when missing. Never through a symbolic link,
    /// and only a folder owned by this account.
    private func openRoot() throws -> Int32 {
        let name = root.lastPathComponent
        let parentPath = root.deletingLastPathComponent().path
        let parent = open(parentPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw Self.internalFailure("could not open the folder above \(name)", errno) }
        defer { close(parent) }
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        var fd = openat(parent, name, flags)
        if fd < 0, errno == ENOENT {
            guard mkdirat(parent, name, 0o700) == 0 || errno == EEXIST else {
                throw Self.internalFailure("could not create \(name)", errno)
            }
            fd = openat(parent, name, flags)
        }
        guard fd >= 0 else {
            let err = errno
            if err == ELOOP || err == ENOTDIR {
                throw TransferError(.internalError,
                                    "\(name) in the home folder is a symbolic link or a file, not a folder: Nido Agent does not use it")
            }
            throw Self.internalFailure("could not open \(name)", err)
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            close(fd)
            throw TransferError(.internalError, "\(name) is not a folder owned by this account: Nido Agent does not use it")
        }
        return fd
    }

    /// The folder `components` name under `rootFD` (which the caller keeps), each opened without
    /// following a link; with `create`, missing folders are made (0700). The caller closes the
    /// descriptor returned.
    private func openFolder(_ components: ArraySlice<String>, from rootFD: Int32, create: Bool) throws -> Int32 {
        var current = dup(rootFD)
        guard current >= 0 else { throw Self.internalFailure("could not open the folder", errno) }
        var walked: [String] = []
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        for name in components {
            walked.append(name)
            var next = openat(current, name, flags)
            if next < 0, errno == ENOENT, create {
                guard mkdirat(current, name, 0o700) == 0 || errno == EEXIST else {
                    let err = errno
                    close(current)
                    throw Self.internalFailure("could not create the folder '\(walked.joined(separator: "/"))'", err)
                }
                next = openat(current, name, flags)
            }
            guard next >= 0 else {
                let failure = Self.openFailure(errno, name, in: current, walked.joined(separator: "/"), expected: .folder)
                close(current)
                throw failure
            }
            close(current)
            current = next
        }
        return current
    }

    // MARK: - Helpers

    private enum Kind {
        case missing
        case file(mode: mode_t)
        case other(mode_t)
        case unreadable(Int32)
    }

    private enum Expected { case file, folder }

    /// What `name` in `dir` is, without following a link.
    private static func kind(of name: String, in dir: Int32) -> Kind {
        var info = stat()
        guard fstatat(dir, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            return errno == ENOENT ? .missing : .unreadable(errno)
        }
        let type = info.st_mode & S_IFMT
        return type == S_IFREG ? .file(mode: info.st_mode) : .other(type)
    }

    /// Why `openat(dir, name)` failed with `err`, said from what `name` is.
    private static func openFailure(_ err: Int32, _ name: String, in dir: Int32, _ path: String,
                                    expected: Expected) -> TransferError {
        switch kind(of: name, in: dir) {
        case .missing:
            return bad("'\(path)' does not exist in NidoTransfer")
        case .file where expected == .folder:
            return bad("'\(path)' is a file, not a folder")
        case .other(let type):
            return refusal(type, path, expected: expected)
        case .file, .unreadable:
            if err == ENAMETOOLONG { return bad("'\(path)' is too long a name") }
            return internalFailure("could not open '\(path)'", err)
        }
    }

    /// The refusal for an item of type `type` (`S_IFMT` bits) where a file or a folder was expected.
    private static func refusal(_ type: mode_t, _ path: String, expected: Expected) -> TransferError {
        switch type {
        case S_IFLNK:
            return bad("'\(path)' is a symbolic link: Nido Agent never follows links")
        case S_IFDIR where expected == .file:
            return bad("'\(path)' is a folder, not a file")
        case S_IFREG where expected == .folder:
            return bad("'\(path)' is a file, not a folder")
        default:
            return bad("'\(path)' is not a regular file or folder")
        }
    }

    private static func tooLarge(_ path: String, _ maxBytes: Int) -> TransferError {
        bad(tooLargeMessage(path: path, maxBytes: maxBytes))
    }

    /// The message of `read`'s refusal of a file larger than `maxBytes`. The host tells this
    /// refusal from the others by its wording (`isTooLargeMessage`): `nido mcp` answers it with
    /// the hint to copy the file with `nido act`.
    public static func tooLargeMessage(path: String, maxBytes: Int) -> String {
        "'\(path)' is larger than \(maxBytes) bytes"
    }

    /// Whether `message` is the refusal of a file larger than `maxBytes` (`tooLargeMessage`),
    /// also once the host has cleaned it (control characters of the path turned into spaces,
    /// which leaves the end as it is). Every other refusal that names a path ends with a fixed
    /// phrase after it, so a path that holds this wording cannot fake it.
    public static func isTooLargeMessage(_ message: String, maxBytes: Int) -> Bool {
        message.hasPrefix("'") && message.hasSuffix("' is larger than \(maxBytes) bytes")
    }

    private static func parent(of components: [String]) -> String {
        components.count > 1 ? components.dropLast().joined(separator: "/") : "."
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw internalFailure("could not write the file", errno)
                }
                offset += n
            }
        }
    }

    static func bad(_ message: String) -> TransferError {
        TransferError(.badRequest, message)
    }

    private static func internalFailure(_ what: String, _ err: Int32) -> TransferError {
        TransferError(.internalError, "\(what): \(String(cString: strerror(err)))")
    }
}
